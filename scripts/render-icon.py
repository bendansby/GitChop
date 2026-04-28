#!/usr/bin/env python3
"""
Render GitChop's app icon at 1024x1024 to ../Icon.png.

Concept (v2): the actual visual of an interactive rebase. A vertical
git-graph spine — a thin line with four commit dots — sits on the left
half of the icon. One of the dots is lifted off the spine and shown
mid-drag at the right, with a soft shadow to suggest elevation and a
curved dotted trail back to the gap it left. The dot colors match the
app's verb palette: gray (pick), blue (squash), green (fixup), red
(drop). The lifted commit gets the squash blue.

This icon should read instantly as "git rebase reorder" to anyone who's
used `git rebase -i`, and stays unique against the workspace's other
list-shaped apps.

Run:
    python3 scripts/render-icon.py
"""

from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
from math import pi, cos, sin

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "Icon.png"


# ── shapes ────────────────────────────────────────────────────────────

def squircle_mask(size, radius_ratio=0.225):
    big = size * 4
    radius = int(big * radius_ratio)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, big - 1, big - 1), radius=radius, fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGB", size, top)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line(
            [(0, y), (w, y)],
            fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)),
        )
    return img


def with_drop_shadow(layer, offset, blur, opacity):
    """Composite layer with a soft shadow underneath. Returns RGBA."""
    w, h = layer.size
    pad = max(blur * 3, 24)
    out = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    alpha = layer.split()[-1]
    shadow = Image.new("RGBA", out.size, (0, 0, 0, 0))
    shadow.paste(
        (0, 0, 0, int(255 * opacity)),
        (pad + offset[0], pad + offset[1]),
        alpha,
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    out.alpha_composite(shadow)
    out.alpha_composite(layer, (pad, pad))
    return out, (pad, pad)


def filled_circle(diameter, color, ring=None):
    """Solid circle with optional outer ring (color, width)."""
    pad = ring[1] if ring else 0
    s = diameter + pad * 2
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if ring:
        d.ellipse((0, 0, s - 1, s - 1), fill=ring[0])
        d.ellipse(
            (pad, pad, pad + diameter - 1, pad + diameter - 1),
            fill=color,
        )
    else:
        d.ellipse((0, 0, diameter - 1, diameter - 1), fill=color)
    return img


# ── icon ──────────────────────────────────────────────────────────────

def render():
    # Squircle background — same deep blue → brighter blue gradient as v1.
    bg = vertical_gradient((SIZE, SIZE), (0x1B, 0x2A, 0x4E), (0x3D, 0x6B, 0xC9))
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), squircle_mask(SIZE))

    # ── git-graph spine ──
    # A vertical line with four evenly-spaced dots. The line sits on
    # the LEFT third of the icon, leaving the right two-thirds for the
    # plucked commit + trail.
    spine_x = int(SIZE * 0.32)
    spine_top = int(SIZE * 0.20)
    spine_bot = int(SIZE * 0.80)
    line_w = int(SIZE * 0.020)

    spine = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spine)
    sd.rounded_rectangle(
        (spine_x - line_w // 2, spine_top, spine_x + line_w // 2, spine_bot),
        radius=line_w // 2,
        fill=(255, 255, 255, 70),
    )
    icon.alpha_composite(spine)

    # Four dot positions, evenly spaced from spine_top to spine_bot.
    # Index 1 (second from top) is the one that's "missing" — lifted
    # off and shown to the right.
    dot_count = 4
    dot_d = int(SIZE * 0.115)
    ring_w = int(SIZE * 0.012)
    ys = [
        spine_top + int((spine_bot - spine_top) * i / (dot_count - 1))
        for i in range(dot_count)
    ]

    # Verb-chip palette (mirrors Models.swift):
    PICK   = (0xB7, 0xC2, 0xD4, 255)   # neutral gray-blue (lighter for visibility on the dark bg)
    SQUASH = (0x2C, 0x86, 0xF5, 255)   # blue, slightly punchier than the source #1A69D6 for icon use
    FIXUP  = (0x3F, 0xB0, 0x6E, 255)   # green
    DROP   = (0xE5, 0x4A, 0x4A, 255)   # red

    # Assign colors per row. The lifted one (index 1) becomes squash blue.
    dot_colors = [PICK, SQUASH, FIXUP, DROP]
    lifted_idx = 1

    # Draw the three stay-put dots on the spine.
    for i, (y, color) in enumerate(zip(ys, dot_colors)):
        if i == lifted_idx:
            # Empty slot where the lifted dot used to be — a thin ring,
            # no fill, so the gap reads as "this is where it came from".
            ring = filled_circle(
                dot_d - ring_w * 4,
                (0, 0, 0, 0),
                ring=((255, 255, 255, 100), ring_w),
            )
            r_w, r_h = ring.size
            icon.alpha_composite(ring, (spine_x - r_w // 2, y - r_h // 2))
            continue
        dot = filled_circle(dot_d, color, ring=((255, 255, 255, 200), ring_w))
        d_w, d_h = dot.size
        with_shadow, origin = with_drop_shadow(
            dot,
            offset=(0, int(SIZE * 0.008)),
            blur=int(SIZE * 0.012),
            opacity=0.32,
        )
        sx = spine_x - d_w // 2 - origin[0]
        sy = y - d_h // 2 - origin[1]
        icon.alpha_composite(with_shadow, (sx, sy))

    # ── lifted commit ──
    # Render the plucked dot to the right of where it would have been,
    # raised slightly, with a stronger shadow.
    lifted_y = ys[lifted_idx] - int(SIZE * 0.02)   # slight lift
    lifted_x = int(SIZE * 0.66)                    # right side
    lifted_d = int(dot_d * 1.18)                   # a touch larger to read as foreground
    lifted = filled_circle(
        lifted_d, dot_colors[lifted_idx], ring=((255, 255, 255, 230), ring_w + 1)
    )
    l_w, l_h = lifted.size
    lifted_shadowed, lo = with_drop_shadow(
        lifted,
        offset=(0, int(SIZE * 0.022)),
        blur=int(SIZE * 0.028),
        opacity=0.42,
    )
    icon.alpha_composite(
        lifted_shadowed,
        (lifted_x - l_w // 2 - lo[0], lifted_y - l_h // 2 - lo[1]),
    )

    # ── motion trail ──
    # A curved dotted line from the empty slot on the spine to the
    # lifted commit. Done as small filled circles along a Bezier-ish
    # curve so the dotting reads cleanly without dashed-line jitter.
    trail = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    td = ImageDraw.Draw(trail)
    start = (spine_x + dot_d // 2, ys[lifted_idx])
    end = (lifted_x - lifted_d // 2, lifted_y)
    # Quadratic Bezier control point: above the midpoint to give the
    # arc a natural "lifting up and over" feel.
    mid = ((start[0] + end[0]) // 2, (start[1] + end[1]) // 2 - int(SIZE * 0.05))
    DOT_R = int(SIZE * 0.0085)
    DOT_GAP = 11   # number of dots along the curve
    for i in range(1, DOT_GAP):
        t = i / DOT_GAP
        # Quadratic Bezier: (1-t)^2 * start + 2(1-t)t * mid + t^2 * end
        x = (1 - t) ** 2 * start[0] + 2 * (1 - t) * t * mid[0] + t ** 2 * end[0]
        y = (1 - t) ** 2 * start[1] + 2 * (1 - t) * t * mid[1] + t ** 2 * end[1]
        # Fade dots from start (more transparent, since it's on the spine)
        # to end (more opaque, near the lifted commit).
        alpha = int(80 + 120 * t)
        td.ellipse(
            (x - DOT_R, y - DOT_R, x + DOT_R, y + DOT_R),
            fill=(255, 255, 255, alpha),
        )
    icon.alpha_composite(trail)

    # Re-mask so any shadow halo bled past the squircle is clipped.
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(icon, (0, 0), squircle_mask(SIZE))

    out.save(OUT, "PNG")
    print(f"Wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    render()
