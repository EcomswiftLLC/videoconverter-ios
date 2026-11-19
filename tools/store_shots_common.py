"""Shared layout code for the App Store screenshot scripts (make_store_shots.py, make_store_shots_ipad.py).

Every store slide is a REAL in-app capture (from the CI artifacts `screenshots` and `screenshots-ipad`) placed on the
deep ink Fluxa background (aurora mint glow upper left, violet lower right) under a short headline. Nothing in a slide
is drawn UI: if a capture is missing, the slide is skipped and reported, never invented.

Capture names are the screen names used by .github/workflows/ios.yml. The ten used for the store are listed in SLIDES
below (the ONLY place to change if CI delivers a different set): home-filled, setup-mp4, formats-grid, presets,
advanced, queue, result, audio-extract, gif-maker, formats-guide. Slide order on the store = order of SLIDES.
Store sizes: iPhone 6.9 inch 1320 x 2868 (make_store_shots.py), iPad 13 inch 2064 x 2752 (make_store_shots_ipad.py);
App Store Connect accepts up to 10 per size.
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Sources/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

INK = (8, 11, 18)          # #080B12
PAPER = (236, 239, 246)    # #ECEFF6 primary text
MIST = (154, 163, 181)     # #9AA3B5 secondary text
MINT = (122, 231, 211)     # #7AE7D3
VIOLET = (156, 140, 255)   # #9C8CFF
GLOW = MINT                # halo and hairline around the capture

# (capture name, headline lines, supporting line). Copy is limited to what the app does (VideoApps-Spec/SPEC.md,
# Sources/Model/Formats.swift). Re-check against the shipped build before upload. Order = order on the App Store.
SLIDES = [
    ("setup-mp4", ["Any format", "to MP4."], "MKV, AVI, WebM, MOV and dozens more."),
    ("formats-grid", ["MKV, AVI, WebM,", "MOV and more."], "11 video, 9 audio and 3 animated formats."),
    ("audio-extract", ["Extract audio", "as MP3."], "Or M4A, WAV, FLAC, OGG and Opus."),
    ("gif-maker", ["Turn clips", "into GIFs."], "Palette-optimised GIF, WebP and APNG."),
    ("queue", ["Batch convert", "in one go."], "Progress for every file in the queue."),
    ("presets", ["Free, fast", "presets."], "iPhone, Android, web, Windows and DVD."),
    ("advanced", ["Full control", "when you want it."], "Codec, resolution, frame rate and trim."),
    ("result", ["Save or share,", "no watermark."], "Free, with one short ad per export."),
    ("formats-guide", ["Know which", "format to pick."], "A plain guide to what each one is for."),
    ("home-filled", ["Honest and private:", "on-device."], "No account, no uploads. Free, with ads."),
]

# The slide that carries the app icon above its headline (the brand slide).
BRAND_SLIDE = "home-filled"

# Captures whose bottom edge carries pinned controls are shown whole instead of bleeding off the slide.
FIT_SLIDES = {"result"}


# The app's own typefaces (Instrument Serif and Manrope), so the store slides match the app.
FONT_DIR = Path(__file__).resolve().parent.parent / "Sources" / "Resources" / "Fonts"


def font(names, size):
    for n in names:
        for base in (str(FONT_DIR) + "/", "C:/Windows/Fonts/", "/usr/share/fonts/truetype/dejavu/", "/System/Library/Fonts/Supplemental/"):
            p = Path(base) / n
            if p.exists():
                return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def serif(size):
    return font(["InstrumentSerif-Regular.ttf", "georgia.ttf", "DejaVuSerif.ttf"], int(size * 1.1))


def sans(size):
    return font(["Manrope-Medium.ttf", "segoeui.ttf", "DejaVuSans.ttf"], size)


def background(W, H):
    """Deep ink with a lifted surface tone at the top, an aurora mint glow upper left and a violet glow lower right."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    t = (yy / H)[..., None]
    base = np.array((15, 20, 34), np.float32) * (1 - t) ** 2 + np.array(INK, np.float32) * (1 - (1 - t) ** 2)
    mint = np.exp(-(((xx - W * 0.10) / (W * 0.55)) ** 2 + ((yy - H * 0.06) / (H * 0.22)) ** 2))
    base += mint[..., None] * (np.array(MINT, np.float32) - base) * 0.16
    vi = np.exp(-(((xx - W * 0.95) / (W * 0.55)) ** 2 + ((yy - H * 0.78) / (H * 0.32)) ** 2))
    base += vi[..., None] * (np.array(VIOLET, np.float32) - base) * 0.15
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB")


def rounded_top(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height + radius], radius, fill=255)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out


def wrap_text(draw, text, fnt, max_w):
    """Greedy wrap, then rebalance two-line results so no line is a lone word (no orphans)."""
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if draw.textlength(trial, font=fnt) <= max_w:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if len(lines) == 2:
        best = None
        for i in range(1, len(words)):
            a, b = " ".join(words[:i]), " ".join(words[i:])
            w = max(draw.textlength(a, font=fnt), draw.textlength(b, font=fnt))
            if w <= max_w and (best is None or w < best[0]):
                best = (w, [a, b])
        if best:
            lines = best[1]
    return lines


def make_slide(W, H, shot_path, lines, caption, opts, brand=False, fit=False):
    canvas = background(W, H)
    d = ImageDraw.Draw(canvas)
    head_f, sub_f = serif(opts["head"]), sans(opts["sub"])
    y = opts["top"]
    if brand:
        ic = Image.open(ICON).convert("RGB").resize((opts["icon"], opts["icon"]), Image.LANCZOS)
        m = Image.new("L", ic.size, 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, ic.width - 1, ic.height - 1], int(ic.width * 0.2237), fill=255)
        canvas.paste(ic, ((W - ic.width) // 2, y), m)
        y += ic.height + opts["gap"]
    for line in lines:
        d.text((W / 2, y), line, font=head_f, fill=PAPER, anchor="ma")
        y += int(opts["head"] * 1.14)
    y += int(opts["head"] * 0.10)
    for sl in wrap_text(d, caption, sub_f, W * 0.86):
        d.text((W / 2, y), sl, font=sub_f, fill=MIST, anchor="ma")
        y += int(opts["sub"] * 1.38)
    # the capture: by default a rounded top bleeding off the bottom edge (a phone rising into frame). With fit=True the
    # whole capture is shown, scaled to the free height, for screens whose bottom edge carries controls (Export).
    shot = Image.open(shot_path).convert("RGB")
    top = max(y + opts["shot_gap"], opts["min_shot_top"])
    if fit:
        margin = opts["fit_margin"]
        sw = int((H - top - margin) * shot.width / shot.height)
        sh = H - top - margin
        shot = shot.resize((sw, sh), Image.LANCZOS)
        mask = Image.new("L", shot.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], opts["radius"], fill=255)
        framed = shot.convert("RGBA")
        framed.putalpha(mask)
        bottom = top + sh
    else:
        sw = opts["shot_w"]
        shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
        shot = shot.crop((0, 0, sw, min(shot.height, H - top)))
        framed = rounded_top(shot, opts["radius"])
        bottom = H + 40
    x = (W - sw) // 2
    halo = Image.new("L", (W, H), 0)
    ImageDraw.Draw(halo).rounded_rectangle([x - 6, top - 6, x + sw + 6, bottom + 6], opts["radius"] + 6, fill=255)
    halo_g = halo.filter(ImageFilter.GaussianBlur(opts["radius"] * 0.9)).point(lambda v: int(v * 0.30))
    canvas.paste(Image.new("RGB", (W, H), GLOW), (0, 0), halo_g)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x, top + 30, x + sw, bottom + 40], opts["radius"], fill=(0, 0, 0, 190))
    shadow = shadow.filter(ImageFilter.GaussianBlur(opts["radius"] * 0.5))
    canvas.paste(shadow, (0, 0), shadow)
    edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle([x - 4, top - 4, x + sw + 3, bottom + (opts["radius"] if not fit else 3)],
                                           opts["radius"] + 4, outline=PAPER + (60,), width=3)
    canvas.paste(edge, (0, 0), edge)
    canvas.paste(framed, (x, top), framed)
    return canvas.convert("RGB")


def run(argv, W, H, opts, ratio_name):
    if len(argv) < 3:
        sys.exit(f"Usage: python {Path(argv[0]).name} <folder-with-CI-pngs> <output-folder>\n"
                 f"Writes {W}x{H} {ratio_name} slides. Missing captures are skipped, never invented.")
    src, dst = Path(argv[1]), Path(argv[2])
    dst.mkdir(parents=True, exist_ok=True)
    wrote, missing = [], []
    n = 0
    for name, lines, caption in SLIDES:
        shot_path = src / f"{name}.png"
        if not shot_path.exists():
            missing.append(name)
            continue
        n += 1
        slide = make_slide(W, H, shot_path, lines, caption, opts, brand=(name == BRAND_SLIDE), fit=(name in FIT_SLIDES))
        out = dst / f"{n:02d}-{name}.png"
        slide.save(out, optimize=True)
        wrote.append(out.name)
        print("wrote", out)
    for name in missing:
        print("missing capture, slide skipped:", name)
    print(f"{len(wrote)} slides written, {len(missing)} skipped")
