"""Builds the Fluxa website image assets into website/fluxa/assets/.

The mark geometry comes from tools/make_icon.py (two aurora ribbons that close into one loop around a play mark), so
the site, the app icon and the favicon are one drawing.

Writes: favicon.svg, fluxa-mark.svg, favicon-32.png, apple-touch-icon.png, icon-512.png, og-image.png and, once real
store slides exist in design/store/6.9, shots/slide-NN.jpg for the home page.
Usage: python website/make_site_assets.py     (needs Pillow and numpy; run tools/make_icon.py first)
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import make_icon  # noqa: E402

OUT = ROOT / "website" / "fluxa" / "assets"
ICON = ROOT / "Sources" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
OUT.mkdir(parents=True, exist_ok=True)

INK = (8, 11, 18)
PAPER = (236, 239, 246)
MUTED = (154, 163, 181)
MINT = (122, 231, 211)
VIOLET = (156, 140, 255)


def fonts(size, serif=True, bold=False):
    names = (["georgiab.ttf"] if bold else ["georgia.ttf"]) if serif else (["segoeuib.ttf"] if bold else ["segoeui.ttf"])
    for n in names:
        p = Path("C:/Windows/Fonts") / n
        if p.exists():
            return ImageFont.truetype(str(p), size)
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf" if serif else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]:
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def rounded_icon(px):
    icon = Image.open(ICON).convert("RGB").resize((px, px), Image.LANCZOS)
    mask = Image.new("L", (px * 4, px * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, px * 4 - 1, px * 4 - 1], radius=int(px * 4 * 0.2237), fill=255)
    mask = mask.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    return out


def og_image():
    W, H = 1200, 630
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    arr = np.zeros((H, W, 3), np.float32) + np.array(INK, np.float32)
    for (px, py, col, s, a) in ((0.78, 0.30, MINT, 0.30, 0.16), (0.86, 0.80, VIOLET, 0.34, 0.18)):
        g = np.exp(-(((xx - W * px) ** 2 + (yy - H * py) ** 2) / (2 * (W * s * 0.5) ** 2)))[..., None] * a
        arr = arr * (1 - g) + np.array(col, np.float32) * g
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    d.text((80, 118), "Video Converter", font=fonts(66), fill=PAPER)
    d.text((80, 198), "MP4 MKV", font=fonts(66), fill=PAPER)
    d.text((80, 292), "Fluxa", font=fonts(88), fill=MINT)
    d.text((80, 430), "MKV, AVI, WebM, MOV and more, to the format you need.", font=fonts(30, False), fill=MUTED)
    d.text((80, 474), "Free for iPhone and iPad. Converted on your device.", font=fonts(30, False), fill=MUTED)
    ic = rounded_icon(360)
    img.paste(ic, (W - 360 - 90, (H - 360) // 2), ic)
    # a thin aurora rule at the base
    rule = np.zeros((8, W, 3), np.float32)
    t = np.linspace(0, 1, W, dtype=np.float32)[None, :, None]
    rule[:] = np.array(MINT, np.float32) * (1 - t) + np.array(VIOLET, np.float32) * t
    img.paste(Image.fromarray(rule.astype(np.uint8), "RGB"), (0, H - 8))
    img.save(OUT / "og-image.png", optimize=True)


def main():
    (OUT / "favicon.svg").write_text(make_icon.mark_svg(100, background_tile=True, label="Fluxa", uid="fv"), encoding="utf-8")
    (OUT / "fluxa-mark.svg").write_text(make_icon.mark_svg(100, background_tile=False, label="", uid="mk"), encoding="utf-8")
    icon = Image.open(ICON).convert("RGB")
    icon.resize((180, 180), Image.LANCZOS).save(OUT / "apple-touch-icon.png", optimize=True)
    rounded_icon(512).save(OUT / "icon-512.png", optimize=True)
    rounded_icon(32).save(OUT / "favicon-32.png", optimize=True)
    og_image()
    # real app slides (from tools/make_store_shots.py) for the home page; skipped until they exist
    src = ROOT / "design" / "store" / "6.9"
    slides = sorted(src.glob("*.png")) if src.exists() else []
    shots_dir = OUT / "shots"
    if slides:
        shots_dir.mkdir(exist_ok=True)
        for old in shots_dir.glob("*.jpg"):
            old.unlink()
        for i, sp in enumerate(slides[:6], 1):
            im = Image.open(sp).convert("RGB")
            im = im.resize((660, round(im.height * 660 / im.width)), Image.LANCZOS)
            im.save(shots_dir / f"slide-{i:02d}.jpg", quality=82, optimize=True, progressive=True)
    print("assets written to", OUT, f"({len(slides[:6])} app slides)")


if __name__ == "__main__":
    main()
