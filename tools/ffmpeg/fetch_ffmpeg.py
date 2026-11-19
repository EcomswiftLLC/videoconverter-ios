#!/usr/bin/env python3
"""Downloads the pinned LGPL FFmpeg xcframework and links it into project.yml.

Reads tools/ffmpeg/VERSION (one line: the release tag of EcomswiftLLC/ffmpeg-ios-lgpl). When the file is missing the
script does nothing and the app is built without FFmpeg (FluxaFF.c compiles to its stub and the app uses Apple's engine only).
Run it before `xcodegen generate`.
"""
import hashlib, os, re, shutil, subprocess, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VERSION_FILE = os.path.join(ROOT, "tools", "ffmpeg", "VERSION")
REPO = "EcomswiftLLC/ffmpeg-ios-lgpl"
VENDOR = os.path.join(ROOT, "Vendor", "FFmpegLGPL")

if not os.path.exists(VERSION_FILE):
    print("No tools/ffmpeg/VERSION: building without FFmpeg.")
    sys.exit(0)

tag = open(VERSION_FILE, encoding="utf-8").read().split()[0]
shutil.rmtree(VENDOR, ignore_errors=True)
os.makedirs(VENDOR)
subprocess.run(["gh", "release", "download", tag, "--repo", REPO, "--dir", VENDOR,
                "--pattern", "FFmpegLGPL.xcframework.zip", "--pattern", "FFmpegLGPL-headers.zip", "--pattern", "checksums.txt"], check=True)

# Verify the downloads against the published checksums.
sums = {}
for line in open(os.path.join(VENDOR, "checksums.txt"), encoding="utf-8"):
    parts = line.split()
    if len(parts) >= 2:
        sums[os.path.basename(parts[-1].lstrip("*"))] = parts[0]
for name in ["FFmpegLGPL.xcframework.zip", "FFmpegLGPL-headers.zip"]:
    digest = hashlib.sha256(open(os.path.join(VENDOR, name), "rb").read()).hexdigest()
    if sums.get(name) and sums[name] != digest:
        sys.exit(f"Checksum mismatch for {name}")
    print(f"{name}: sha256 {digest}")

for name, target in [("FFmpegLGPL.xcframework.zip", VENDOR), ("FFmpegLGPL-headers.zip", os.path.join(VENDOR, "include"))]:
    with zipfile.ZipFile(os.path.join(VENDOR, name)) as z:
        z.extractall(target)

# Find the folder that holds libavformat/avformat.h.
include = None
for base, dirs, files in os.walk(os.path.join(VENDOR, "include")):
    if os.path.basename(base) == "libavformat" and "avformat.h" in files:
        include = os.path.dirname(base)
        break
if not include:
    sys.exit("The headers zip has no libavformat/avformat.h")
framework = None
for base, dirs, files in os.walk(VENDOR):
    for d in dirs:
        if d.endswith(".xcframework"):
            framework = os.path.join(base, d)
            break
    if framework:
        break
if not framework:
    sys.exit("The release has no .xcframework")

rel = lambda p: os.path.relpath(p, ROOT).replace(os.sep, "/")
path = os.path.join(ROOT, "project.yml")
text = open(path, encoding="utf-8").read()
if "FFmpegLGPL" not in text:
    marker = "      - package: GoogleUserMessagingPlatform\n        product: GoogleUserMessagingPlatform\n"
    dep = marker + f"      - framework: {rel(framework)}\n        embed: true\n        codeSign: true\n"
    if marker not in text:
        sys.exit("project.yml: dependency marker not found")
    text = text.replace(marker, dep, 1)
    anchor = "        SWIFT_OBJC_BRIDGING_HEADER: Sources/FFmpegBridge/Fluxa-Bridging-Header.h\n"
    text = text.replace(anchor, anchor + f"        HEADER_SEARCH_PATHS: $(inherited) $(SRCROOT)/{rel(include)}\n", 1)
    open(path, "w", encoding="utf-8").write(text)
print("Linked", rel(framework), "with headers in", rel(include))
