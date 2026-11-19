#!/usr/bin/env python3
"""Runs FluxaFF.c through every source and target format and checks the results with ffprobe.

The option lists mirror FFmpegCommandBuilder.swift. CI installs Homebrew's FFmpeg only to make test clips and to
inspect results; the conversions themselves run through fxrun, which is FluxaFF.c.
"""
import json, os, subprocess, sys

FXRUN = os.path.abspath(sys.argv[1])
WORK = os.path.abspath(sys.argv[2])
os.makedirs(WORK, exist_ok=True)
FAILS = []
RESULTS = []


def sh(args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check)


def make_fixture(name, vcodec, acodec, extra=()):
    out = os.path.join(WORK, name)
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=4"]
    if vcodec:
        args += ["-c:v", vcodec, "-pix_fmt", "yuv420p"]
    else:
        args += ["-vn"]
    if acodec:
        args += ["-c:a", acodec]
    else:
        args += ["-an"]
    args += list(extra) + [out]
    r = sh(args, check=False)
    if r.returncode != 0:
        print(f"[fixture skipped] {name}: {r.stderr.strip()[:160]}")
        return None
    return out


def probe(path):
    r = sh(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path], check=False)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def run(label, src, out, opts, expect_video=None, expect_audio=None, duration=None, tol=0.8, vcodec=None, acodec=None):
    if os.path.exists(out):
        os.remove(out)
    args = [FXRUN, "run", "-hide_banner", "-nostdin", "-y"] + opts[0] + ["-i", src] + opts[1] + [out]
    r = sh(args, check=False)
    ok = r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0
    problems = []
    if not ok:
        tail = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else ""
        problems.append(f"exit {r.returncode}: {tail}")
    else:
        info = probe(out)
        if info is None:
            problems.append("output not readable by ffprobe")
        else:
            kinds = [s["codec_type"] for s in info["streams"]]
            names = {s["codec_type"]: s["codec_name"] for s in info["streams"]}
            if expect_video is True and "video" not in kinds:
                problems.append("no video stream")
            if expect_video is False and "video" in kinds:
                problems.append("unexpected video stream")
            if expect_audio is True and "audio" not in kinds:
                problems.append("no audio stream")
            if expect_audio is False and "audio" in kinds:
                problems.append("unexpected audio stream")
            if vcodec and names.get("video") != vcodec:
                problems.append(f"video codec {names.get('video')} != {vcodec}")
            if acodec and names.get("audio") != acodec:
                problems.append(f"audio codec {names.get('audio')} != {acodec}")
            d = float(info["format"].get("duration", 0) or 0)
            if duration is not None and abs(d - duration) > tol:
                problems.append(f"duration {d:.2f} != {duration}")
    status = "OK  " if not problems else "FAIL"
    print(f"{status} {label}" + ("" if not problems else "  -> " + "; ".join(problems)), flush=True)
    RESULTS.append((label, not problems))
    if problems:
        FAILS.append(label)


# Fixtures (source containers).
FIX = {}
FIX["mp4"] = make_fixture("src.mp4", "libx264", "aac")
FIX["mov"] = make_fixture("src.mov", "libx264", "aac")
FIX["mkv"] = make_fixture("src.mkv", "libx264", "aac")
FIX["mkv-ac3"] = make_fixture("src-ac3.mkv", "libx264", "ac3")
FIX["webm"] = make_fixture("src.webm", "libvpx-vp9", "libopus")
FIX["avi"] = make_fixture("src.avi", "mpeg4", "libmp3lame")
FIX["wmv"] = make_fixture("src.wmv", "wmv2", "wmav2")
FIX["flv"] = make_fixture("src.flv", "flv", "libmp3lame", ["-ar", "44100"])
FIX["3gp"] = make_fixture("src.3gp", "mpeg4", "aac")
FIX["mpg"] = make_fixture("src.mpg", "mpeg2video", "ac3")
FIX["ts"] = make_fixture("src.ts", "libx264", "aac")
FIX["ogv"] = make_fixture("src.ogv", "libtheora", "libvorbis")
FIX["mp3"] = make_fixture("src.mp3", None, "libmp3lame")
FIX["m4a"] = make_fixture("src.m4a", None, "aac")
FIX["flac"] = make_fixture("src.flac", None, "flac")
FIX["wav"] = make_fixture("src.wav", None, "pcm_s16le")
FIX["ogg"] = make_fixture("src.ogg", None, "libvorbis")
FIX["opus"] = make_fixture("src.opus", None, "libopus")
FIX["rot"] = None
# A phone-style clip with a stored rotation.
tmp = make_fixture("rot-src.mp4", "libx264", "aac")
if tmp:
    rotated = os.path.join(WORK, "src-rot.mp4")
    sh(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-display_rotation", "90", "-i", tmp, "-c", "copy", rotated], check=False)
    if os.path.exists(rotated):
        FIX["rot"] = rotated

AAC = ["-c:a", "aac", "-b:a", "128k", "-ar", "44100"]
MAPS = ["-sn", "-dn", "-map_metadata", "0", "-map", "0:v:0", "-map", "0:a:0"]

video_sources = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp", "mpg", "ts"]
if FIX.get("ogv"):
    video_sources.append("ogv")

targets = {
    "mp4-h264": ("mp4", MAPS + ["-c:v", "h264_videotoolbox", "-vf", "format=yuv420p", "-b:v", "1500k", "-allow_sw", "1", "-tag:v", "avc1"] + AAC + ["-movflags", "+faststart", "-f", "mp4"], "h264", "aac"),
    "mov-h264": ("mov", MAPS + ["-c:v", "h264_videotoolbox", "-vf", "format=yuv420p", "-b:v", "1500k", "-allow_sw", "1"] + AAC + ["-movflags", "+faststart", "-f", "mov"], "h264", "aac"),
    "mkv-vp9": ("mkv", MAPS + ["-c:v", "libvpx-vp9", "-vf", "format=yuv420p", "-b:v", "800k", "-deadline", "good", "-cpu-used", "5", "-row-mt", "1", "-threads", "0", "-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-vbr", "on", "-f", "matroska"], "vp9", "opus"),
    "webm-vp9": ("webm", MAPS + ["-c:v", "libvpx-vp9", "-vf", "format=yuv420p", "-b:v", "800k", "-deadline", "good", "-cpu-used", "5", "-row-mt", "1", "-threads", "0", "-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-vbr", "on", "-f", "webm"], "vp9", "opus"),
    "avi-mpeg4": ("avi", MAPS + ["-c:v", "mpeg4", "-vf", "format=yuv420p", "-b:v", "1500k", "-qmin", "2", "-vtag", "XVID", "-c:a", "libmp3lame", "-b:a", "128k", "-ar", "44100", "-f", "avi"], "mpeg4", "mp3"),
    "flv-flv1": ("flv", MAPS + ["-c:v", "flv", "-vf", "format=yuv420p", "-b:v", "1200k", "-c:a", "libmp3lame", "-b:a", "128k", "-ar", "44100", "-f", "flv"], "flv1", "mp3"),
    "wmv-wmv2": ("wmv", MAPS + ["-c:v", "wmv2", "-vf", "format=yuv420p", "-b:v", "1500k", "-c:a", "wmav2", "-b:a", "128k", "-ar", "44100", "-f", "asf"], "wmv2", "wmav2"),
    "mpg-mpeg2": ("mpg", MAPS + ["-c:v", "mpeg2video", "-vf", "fps=25,format=yuv420p", "-b:v", "2500k", "-maxrate", "3750k", "-bufsize", "1835k", "-c:a", "ac3", "-b:a", "192k", "-ar", "48000", "-f", "mpeg"], "mpeg2video", "ac3"),
    "ts-h264": ("ts", MAPS + ["-c:v", "h264_videotoolbox", "-vf", "format=yuv420p", "-b:v", "1500k", "-allow_sw", "1"] + AAC + ["-f", "mpegts"], "h264", "aac"),
    "3gp-h264": ("3gp", MAPS + ["-c:v", "h264_videotoolbox", "-vf", "scale=320:240,format=yuv420p", "-b:v", "400k", "-allow_sw", "1", "-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "2", "-movflags", "+faststart", "-f", "3gp"], "h264", "aac"),
}
for src_key in video_sources:
    src = FIX.get(src_key)
    if not src:
        continue
    for tname, (ext, opts, vc, ac) in targets.items():
        out = os.path.join(WORK, f"out-{src_key}-{tname}.{ext}")
        run(f"{src_key} -> {tname}", src, out, ([], opts), True, True, 4.0, vcodec=vc, acodec=ac)

# Lossless remux cases.
COPY = ["-sn", "-dn", "-map_metadata", "0", "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", "copy"]
for src_key, ext, mux in [("mkv", "mp4", "mp4"), ("mp4", "mkv", "matroska"), ("mp4", "mov", "mov"), ("ts", "mp4", "mp4"), ("mov", "mp4", "mp4"), ("avi", "mkv", "matroska"), ("flv", "mkv", "matroska"), ("mpg", "mkv", "matroska")]:
    src = FIX.get(src_key)
    if not src:
        continue
    out = os.path.join(WORK, f"remux-{src_key}.{ext}")
    extra = ["-movflags", "+faststart"] if ext in ("mp4", "mov") else []
    tag = ["-tag:v", "avc1"] if ext in ("mp4", "mov") and src_key in ("mkv", "ts", "mov", "mp4") else []
    run(f"remux {src_key} -> {ext}", src, out, ([], COPY + tag + extra + ["-f", mux]), True, True, 4.0)

# Copy the video, re-encode AC-3 audio to AAC.
if FIX.get("mkv-ac3"):
    out = os.path.join(WORK, "mixed-ac3.mp4")
    run("mkv(h264+ac3) -> mp4 (copy video, AAC audio)", FIX["mkv-ac3"], out, ([], MAPS + ["-c:v", "copy", "-tag:v", "avc1"] + AAC + ["-movflags", "+faststart", "-f", "mp4"]), True, True, 4.0, vcodec="h264", acodec="aac")

# Audio targets, from video sources and from audio sources.
audio_targets = {
    "mp3": ("mp3", ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "44100"], "mp3", "mp3"),
    "m4a": ("m4a", ["-c:a", "aac", "-b:a", "192k", "-ar", "44100"], "ipod", "aac"),
    "wav": ("wav", ["-c:a", "pcm_s16le", "-ar", "44100"], "wav", "pcm_s16le"),
    "aiff": ("aiff", ["-c:a", "pcm_s16be", "-ar", "44100"], "aiff", "pcm_s16be"),
    "flac": ("flac", ["-c:a", "flac", "-ar", "44100"], "flac", "flac"),
    "ogg": ("ogg", ["-c:a", "libvorbis", "-b:a", "160k", "-ar", "44100"], "ogg", "vorbis"),
    "opus": ("opus", ["-c:a", "libopus", "-b:a", "128k", "-ar", "48000", "-vbr", "on"], "opus", "opus"),
    "ac3": ("ac3", ["-c:a", "ac3", "-b:a", "192k", "-ar", "48000"], "ac3", "ac3"),
}
for src_key in ["mp4", "mkv", "webm", "avi", "wmv", "mp3", "m4a", "flac", "wav", "ogg", "opus"]:
    src = FIX.get(src_key)
    if not src:
        continue
    for tname, (ext, aopts, mux, ac) in audio_targets.items():
        out = os.path.join(WORK, f"aud-{src_key}-{tname}.{ext}")
        run(f"audio {src_key} -> {tname}", src, out, ([], ["-sn", "-dn", "-map_metadata", "0", "-vn", "-map", "0:a:0"] + aopts + ["-f", mux]), False, True, 4.0, acodec=ac)

# Animated images.
chain = "fps=10,scale=240:-2:flags=lanczos"
palette = ",split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
run("mp4 -> gif", FIX["mp4"], os.path.join(WORK, "anim.gif"), ([], ["-sn", "-dn", "-an", "-map", "0:v:0", "-vf", chain + palette, "-loop", "0", "-f", "gif"]), True, False, 4.0, vcodec="gif")
run("mkv -> webp", FIX["mkv"], os.path.join(WORK, "anim.webp"), ([], ["-sn", "-dn", "-an", "-map", "0:v:0", "-vf", chain, "-c:v", "libwebp_anim", "-lossless", "0", "-q:v", "70", "-loop", "0", "-f", "webp"]), True, False, 4.0, vcodec="webp")
run("mp4 -> apng", FIX["mp4"], os.path.join(WORK, "anim.apng"), ([], ["-sn", "-dn", "-an", "-map", "0:v:0", "-vf", chain + ",format=rgba", "-c:v", "apng", "-plays", "0", "-f", "apng"]), True, False, 4.0, vcodec="apng")

# Trim, resize, rotate, flip, mute, strip metadata.
run("trim 1s..3s mp4 -> mp4", FIX["mp4"], os.path.join(WORK, "trim.mp4"), (["-ss", "1.000"], ["-t", "2.000"] + MAPS + ["-c:v", "h264_videotoolbox", "-vf", "format=yuv420p", "-b:v", "1000k", "-allow_sw", "1"] + AAC + ["-f", "mp4"]), True, True, 2.0, tol=0.6)
run("trim mkv -> webm", FIX["mkv"], os.path.join(WORK, "trim.webm"), (["-ss", "1.000"], ["-t", "2.000"] + MAPS + ["-c:v", "libvpx-vp9", "-vf", "format=yuv420p", "-b:v", "500k", "-deadline", "good", "-cpu-used", "5", "-c:a", "libopus", "-b:a", "96k", "-ar", "48000", "-f", "webm"]), True, True, 2.0, tol=0.7)
run("scale + hflip + transpose", FIX["mp4"], os.path.join(WORK, "scaled.mp4"), ([], MAPS + ["-c:v", "h264_videotoolbox", "-vf", "transpose=1,hflip,scale=120:160:flags=lanczos,format=yuv420p", "-b:v", "500k", "-allow_sw", "1"] + AAC + ["-f", "mp4"]), True, True, 4.0)
run("mute (no audio)", FIX["mp4"], os.path.join(WORK, "mute.mp4"), ([], ["-sn", "-dn", "-map_metadata", "0", "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", "-f", "mp4"]), True, False, 4.0)
run("strip metadata", FIX["mp4"], os.path.join(WORK, "nometa.mp4"), ([], ["-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1", "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", "copy", "-f", "mp4"]), True, True, 4.0)

# Stored rotation must be applied (a 320x240 clip rotated 90 degrees is shown as 240x320).
if FIX.get("rot"):
    out = os.path.join(WORK, "rot-out.mp4")
    run("stored rotation applied on re-encode", FIX["rot"], out, ([], MAPS + ["-c:v", "h264_videotoolbox", "-vf", "format=yuv420p", "-b:v", "800k", "-allow_sw", "1"] + AAC + ["-f", "mp4"]), True, True, 4.0)
    info = probe(out)
    if info:
        v = [s for s in info["streams"] if s["codec_type"] == "video"][0]
        if (v["width"], v["height"]) != (240, 320):
            print(f"FAIL rotation output size {v['width']}x{v['height']} (expected 240x320)")
            FAILS.append("rotation size")
        else:
            print("OK   rotation output is 240x320")

# The probe JSON must parse and carry the facts the Swift parser reads.
for key in ["mp4", "mkv", "mp3"]:
    src = FIX.get(key)
    if not src:
        continue
    r = sh([FXRUN, "probe", src], check=False)
    try:
        data = json.loads(r.stdout)
        assert data["format"]["format_name"] and data["streams"]
        print(f"OK   probe json {key}: {data['format']['format_name']} {len(data['streams'])} streams")
    except Exception as e:
        print(f"FAIL probe json {key}: {e}")
        FAILS.append("probe " + key)

passed = len([x for x in RESULTS if x[1]])
print(f"\n{passed}/{len(RESULTS)} conversions passed")
if FAILS:
    print("FAILURES:\n  " + "\n  ".join(FAILS))
    sys.exit(1)
