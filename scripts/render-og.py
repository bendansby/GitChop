#!/usr/bin/env python3
"""
Render Showcase/og-gitchop.png — the 1200x630 Open Graph preview image
linked from gitchop.html's meta tags. Background is a violet/indigo
gradient (matches the page accent), with the app icon and wordmark
centered.

Re-run any time Icon.png changes:

    python3 scripts/render-og.py
"""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHOWCASE = ROOT.parent.parent / "Showcase"

W, H = 1200, 630
ICON_SIZE = 240
ICON_RADIUS = 54

# ── Background: violet → indigo radial gradient + grain ────────────────
def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i+2], 16) for i in (0, 2, 4))

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Two color stops + a base, blended by distance from a focal point near
# top-left so the icon (centered) sits on the lighter zone.
focal = (0.18 * W, 0.22 * H)
near = hex_rgb("#7a47e8")    # violet
mid  = hex_rgb("#3a2c9c")    # deep indigo
far  = hex_rgb("#0d0a26")    # near-black

bg = Image.new("RGB", (W, H), far)
px = bg.load()
maxdist = ((W) ** 2 + (H) ** 2) ** 0.5
for y in range(H):
    for x in range(W):
        dx = (x - focal[0]) / W
        dy = (y - focal[1]) / H
        d = (dx * dx + dy * dy) ** 0.5
        # 0 at focal, ~1 at far corner
        t = min(1.0, d / 0.85)
        if t < 0.45:
            c = lerp(near, mid, t / 0.45)
        else:
            c = lerp(mid, far, (t - 0.45) / 0.55)
        px[x, y] = c

# Subtle grain
import random
rnd = random.Random(42)
grain = Image.new("L", (W, H))
gpx = grain.load()
for y in range(H):
    for x in range(W):
        gpx[x, y] = rnd.randint(0, 255)
bg = Image.composite(bg, Image.eval(bg, lambda v: max(0, v - 5)), grain.point(lambda v: 255 if v > 200 else 0))

# ── Icon, rounded ──────────────────────────────────────────────────────
icon_src = ROOT / "Icon.png"
icon = Image.open(icon_src).convert("RGBA").resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)

# Round its corners to match macOS app-icon shape
mask = Image.new("L", (ICON_SIZE, ICON_SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (0, 0, ICON_SIZE, ICON_SIZE), radius=ICON_RADIUS, fill=255
)
icon.putalpha(Image.composite(icon.split()[3], Image.new("L", icon.size, 0), mask))

# Soft drop shadow under the icon
shadow_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
shadow_mask = Image.new("L", (ICON_SIZE + 80, ICON_SIZE + 80), 0)
ImageDraw.Draw(shadow_mask).rounded_rectangle(
    (40, 40, 40 + ICON_SIZE, 40 + ICON_SIZE), radius=ICON_RADIUS, fill=180
)
from PIL import ImageFilter
shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(radius=24))
icon_x = (W - ICON_SIZE) // 2 - 220     # left of center, leave room for text
icon_y = (H - ICON_SIZE) // 2
shadow_layer.paste((0, 0, 0, 200), (icon_x - 40, icon_y - 20), shadow_mask)
bg = Image.alpha_composite(bg.convert("RGBA"), shadow_layer)
bg.paste(icon, (icon_x, icon_y), icon)

# ── Text: wordmark + tagline ───────────────────────────────────────────
draw = ImageDraw.Draw(bg)

# Find a font. Apple system fonts are at /System/Library/Fonts/Supplemental
# and /System/Library/Fonts. Use SF Pro if present, fall back to Helvetica.
def load(name_candidates, size):
    for path in name_candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()

font_title = load([
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/SFCompact.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
], 96)
font_tag = load([
    "/System/Library/Fonts/SFNS.ttf",
    "/Library/Fonts/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
], 30)

text_x = icon_x + ICON_SIZE + 60
title_y = icon_y + 30
draw.text((text_x, title_y), "GitChop", font=font_title, fill=(255, 255, 255, 255))

tag = "A visual git rebase -i for the Mac"
draw.text((text_x, title_y + 120), tag, font=font_tag, fill=(220, 200, 255, 235))

# URL footer
url = "bendansby.com/apps/gitchop"
font_url = load([
    "/System/Library/Fonts/SFMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
], 22)
draw.text((text_x, title_y + 200), url, font=font_url, fill=(180, 160, 230, 200))

# ── Save ───────────────────────────────────────────────────────────────
out = SHOWCASE / "og-gitchop.png"
bg.convert("RGB").save(out, "PNG", optimize=True)
print(f"Wrote {out} ({out.stat().st_size // 1024} KB)")
