"""Draws the Fluxa app icon: two aurora ribbons that chase each other into one closed loop around a play mark.

The mark: two curved ribbons, each growing from a fine tail into a full-width arrowhead. The head of each ribbon lies
over the tail of the other, so the pair reads as one continuous, interlocking loop (conversion that never breaks the
video). In the middle sits a soft rounded play triangle (video). Colours: aurora mint #7AE7D3 at each head, violet
#9C8CFF at each tail, on deep ink #080B12. No text.

Run: python tools/make_icon.py
Writes AppIcon-1024.png, AppIcon-1024-dark.png and AppIcon-1024-tinted.png (RGB, no alpha) into the asset catalog,
design/icon/preview.png (contact sheet at store and home-screen sizes) and website/assets/fluxa-mark.svg geometry
through mark_svg(), which website/make_site_assets.py also uses. Needs Pillow and numpy.
"""
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
PREVIEW = ROOT / "design/icon"

S = 4096            # supersampled canvas
FINAL = 1024

INK = np.array((8, 11, 18), np.float32)          # #080B12
SURFACE = np.array((24, 30, 48), np.float32)     # #181E30
MINT = np.array((122, 231, 211), np.float32)     # #7AE7D3
VIOLET = np.array((156, 140, 255), np.float32)   # #9C8CFF
PAPER = np.array((236, 239, 246), np.float32)    # #ECEFF6

# geometry, as fractions of the canvas
RING_R = 0.290          # centre line of the ribbons
RIB_W = 0.104           # full ribbon width
HEAD_W = 0.185          # arrowhead base width
HEAD_SWEEP = 40         # degrees the arrowhead covers along the ring
BODY_SWEEP = 160        # degrees from tail to arrowhead base
ROT = -135              # degrees: rotates the pair so the heads sit upper right and lower left


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def ribbon_outline(start_deg, size, n=220):
    """Return (body polygon, head polygon, tail centre, tail radius, tail point, head tip) for one ribbon.

    Angles run counter-clockwise on screen. The body grows from a thin tail to full width; the head is a curved
    arrowhead whose tip lies on the ring."""
    cx = cy = size / 2
    R = RING_R * size

    def pt(deg, r):
        a = math.radians(deg + ROT)
        return (cx + math.cos(a) * r, cy - math.sin(a) * r)

    outer, inner = [], []
    for i in range(n + 1):
        u = i / n
        deg = start_deg + BODY_SWEEP * u
        w = RIB_W * size * (0.22 + 0.78 * float(smooth(0.0, 0.6, u)))
        outer.append(pt(deg, R + w / 2))
        inner.append(pt(deg, R - w / 2))
    body = outer + inner[::-1]
    base = start_deg + BODY_SWEEP
    hw = HEAD_W * size / 2
    head = []
    # curved head: the outer and inner flanks follow arcs that meet at the tip on the ring
    m = 60
    for i in range(m + 1):
        u = i / m
        head.append(pt(base + HEAD_SWEEP * u, R + hw * (1 - u) ** 0.85))
    for i in range(m, -1, -1):
        u = i / m
        head.append(pt(base + HEAD_SWEEP * u, R - hw * (1 - u) ** 0.85))
    tail_w = RIB_W * size * 0.22
    return body, head, pt(start_deg, R), tail_w / 2, pt(start_deg, R), pt(base + HEAD_SWEEP, R)


RIBBON_STARTS = (0, 180)


def angle_map(size):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    c = size / 2
    ang = (np.degrees(np.arctan2(-(yy - c), xx - c)) - ROT) % 360
    rad = np.sqrt((xx - c) ** 2 + (yy - c) ** 2)
    return ang, rad


def mask_of(poly, size, circle=None):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.polygon(poly, fill=255)
    if circle:
        (x, y), r = circle
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return np.asarray(m, np.float32) / 255


def ribbon_colour(ang, rad, start_deg, size, mono=False):
    """Violet tail to mint head along the ribbon, with a lit outer edge and a slightly deeper inner edge."""
    rel = (ang - start_deg) % 360
    u = np.clip(rel / (BODY_SWEEP + HEAD_SWEEP), 0, 1)
    u = smooth(0.05, 0.92, u)[..., None]
    col = VIOLET * (1 - u) + MINT * u
    R = RING_R * size
    across = np.clip((rad - R) / (HEAD_W * size / 2), -1, 1)[..., None]   # -1 inner edge, +1 outer edge
    light = 1 + 0.10 * across - 0.06 * (across ** 2)
    col = np.clip(col * light, 0, 255)
    if mono:
        g = (col @ np.array([0.30, 0.55, 0.15], np.float32))[..., None]
        col = np.repeat(np.clip(g * 1.05, 0, 255), 3, axis=2)
    return col


def background(variant, size):
    if variant == "tinted":
        return np.zeros((size, size, 3), np.float32)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    lift = SURFACE if variant == "light" else (SURFACE * 0.6 + INK * 0.4)
    d = np.sqrt((xx - size * 0.32) ** 2 + (yy - size * 0.22) ** 2) / (size * 1.05)
    k = (np.clip(1 - d, 0, 1) ** 1.6)[..., None]
    arr = INK * (1 - k) + lift * k
    if variant == "light":
        # a faint aurora bloom behind the mark, mint up left, violet low right
        for (px, py, col, s, a) in ((0.38, 0.40, MINT, 0.36, 0.10), (0.64, 0.64, VIOLET, 0.40, 0.12)):
            g = np.exp(-(((xx - size * px) ** 2 + (yy - size * py) ** 2) / (2 * (size * s * 0.5) ** 2)))[..., None] * a
            arr = arr * (1 - g) + col * g
    return arr


def play_polygon(size, steps=24):
    """A rounded play triangle as a polygon, optically centred (its centroid sits on the canvas centre)."""
    c = size / 2
    h = size * 0.215
    w = h * 0.90
    x0 = c - w / 3            # centroid of the triangle on the centre
    pts = [(x0, c - h / 2), (x0 + w, c), (x0, c + h / 2)]
    r = size * 0.024
    out = []
    for i in range(3):
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % 3]
        v1 = (p0[0] - p1[0], p0[1] - p1[1])
        v2 = (p2[0] - p1[0], p2[1] - p1[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1, u2 = (v1[0] / l1, v1[1] / l1), (v2[0] / l2, v2[1] / l2)
        half = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1]))) / 2
        d = r / math.tan(half)
        a = (p1[0] + u1[0] * d, p1[1] + u1[1] * d)
        b = (p1[0] + u2[0] * d, p1[1] + u2[1] * d)
        bis = (u1[0] + u2[0], u1[1] + u2[1])
        bl = math.hypot(*bis)
        cc = (p1[0] + bis[0] / bl * r / math.sin(half), p1[1] + bis[1] / bl * r / math.sin(half))
        a0 = math.atan2(a[1] - cc[1], a[0] - cc[0])
        a1 = math.atan2(b[1] - cc[1], b[0] - cc[0])
        da = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        for k in range(steps + 1):
            t = a0 + da * k / steps
            out.append((cc[0] + math.cos(t) * r, cc[1] + math.sin(t) * r))
    return out


def play_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(play_polygon(size), fill=255)
    return np.asarray(m, np.float32) / 255


def blur(arr, r):
    if arr.ndim == 2:
        im = Image.fromarray(np.clip(arr * 255, 0, 255).astype(np.uint8), "L")
        return np.asarray(im.filter(ImageFilter.GaussianBlur(r)), np.float32) / 255
    im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")
    return np.asarray(im.filter(ImageFilter.GaussianBlur(r)), np.float32)


def compose(variant):
    mono = variant == "tinted"
    size = S
    img = background(variant, size)
    ang, rad = angle_map(size)

    shapes = []
    for st in RIBBON_STARTS:
        body, head, tc, tr, _, _ = ribbon_outline(st, size)
        shapes.append((st, mask_of(body, size, (tc, tr)), mask_of(head, size)))

    full = np.clip(sum(b + h for _, b, h in shapes), 0, 1)
    # soft glow under the whole loop
    if not mono:
        glow_col = ribbon_colour(ang, rad, 0, size) * 0.5 + ribbon_colour(ang, rad, 180, size) * 0.5
        g = blur(full, size * 0.035)[..., None] * (0.42 if variant == "light" else 0.30)
        img = img * (1 - g) + glow_col * g

    # bodies first, then each head with a contact shadow over the other ribbon's tail
    for st, body, _ in shapes:
        col = ribbon_colour(ang, rad, st, size, mono)
        a = body[..., None]
        img = img * (1 - a) + col * a
    for st, own_body, head in shapes:
        # the shadow falls only on the other ribbon, never across the seam with its own body
        sh = (blur(head, size * 0.012) * (1 - own_body))[..., None] * 0.55
        img = img * (1 - sh) + (INK * 0.5) * sh
        col = ribbon_colour(ang, rad, st, size, mono)
        # a hairline highlight on the head's leading flank keeps the overlap crisp at small sizes
        a = head[..., None]
        img = img * (1 - a) + col * a

    # play triangle, a soft paper fill lit from the top
    pm = play_mask(size)
    if not mono:
        psh = blur(pm, size * 0.018)[..., None] * 0.45
        shifted = np.roll(psh, int(size * 0.010), axis=0)
        img = img * (1 - shifted) + (INK * 0.3) * shifted
    yy = np.linspace(0, 1, size, dtype=np.float32)[:, None, None]
    pcol = PAPER * (1 - 0.10 * yy) if not mono else np.full((size, 1, 3), 235, np.float32)
    pa = pm[..., None]
    img = img * (1 - pa) + pcol * pa

    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    return out.resize((FINAL, FINAL), Image.LANCZOS)


# ----------------------------------------------------------------------------- SVG (website)
def mark_svg(size=100, background_tile=False, label="Fluxa", uid="fx"):
    """The same mark as SVG. Each ribbon uses a linear gradient from its tail (violet) to its head (mint)."""
    def path(poly):
        return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in poly) + " Z"

    defs, layers_body, layers_head = [], [], []
    for i, st in enumerate(RIBBON_STARTS):
        body, head, tc, tr, tail, tip = ribbon_outline(st, size, n=90)
        gid = f"{uid}g{i}"
        defs.append(f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{tail[0]:.2f}" y1="{tail[1]:.2f}" '
                    f'x2="{tip[0]:.2f}" y2="{tip[1]:.2f}"><stop offset="0" stop-color="#9C8CFF"/>'
                    f'<stop offset=".55" stop-color="#8FB9EC"/><stop offset="1" stop-color="#7AE7D3"/></linearGradient>')
        layers_body.append(f'<path d="{path(body)}" fill="url(#{gid})"/>'
                           f'<circle cx="{tc[0]:.2f}" cy="{tc[1]:.2f}" r="{tr:.2f}" fill="#9C8CFF"/>')
        layers_head.append(f'<path d="{path(head)}" fill="url(#{gid})" filter="url(#{uid}s)"/>')
    tri = path(play_polygon(size, steps=6))
    defs.append(f'<filter id="{uid}s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="0" '
                f'stdDeviation="{size * 0.008:.2f}" flood-color="#04060B" flood-opacity=".6"/></filter>')
    tile = (f'<rect width="{size}" height="{size}" rx="{size * 0.2237:.2f}" fill="#080B12"/>') if background_tile else ""
    head_attr = f'role="img" aria-label="{label}"><title>{label}</title>' if label else 'aria-hidden="true" focusable="false">'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" {head_attr}'
            f'<defs>{"".join(defs)}</defs>{tile}{"".join(layers_body)}{"".join(layers_head)}'
            f'<path d="{tri}" fill="#ECEFF6"/></svg>\n')


def preview(icons):
    PREVIEW.mkdir(parents=True, exist_ok=True)
    sizes = [120, 87, 60, 40]
    sheet = Image.new("RGB", (1140, 620), (236, 238, 242))
    sheet.paste(Image.new("RGB", (1140, 150), (20, 22, 28)), (0, 470))
    x = 30
    for name, im in icons.items():
        big = im.resize((300, 300), Image.LANCZOS)
        mask = Image.new("L", (300, 300), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, 299, 299], 67, fill=255)
        sheet.paste(big, (x, 20), mask)
        for row_y in (335, 485):
            sx = x
            for s in sizes:
                sm = im.resize((s, s), Image.LANCZOS)
                m = Image.new("L", (s, s), 0)
                ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], int(s * 0.2237), fill=255)
                sheet.paste(sm, (sx, row_y), m)
                sx += s + 12
        x += 370
    sheet.save(PREVIEW / "preview.png")
    print("wrote", PREVIEW / "preview.png")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icons = {}
    for variant, fname in (("light", "AppIcon-1024.png"), ("dark", "AppIcon-1024-dark.png"), ("tinted", "AppIcon-1024-tinted.png")):
        im = compose(variant).convert("RGB")
        im.save(OUT / fname, optimize=True)
        icons[variant] = im
        print("wrote", OUT / fname, im.mode, im.size)
    preview(icons)


if __name__ == "__main__":
    main()
