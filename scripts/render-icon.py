#!/usr/bin/env python3
"""
Render GitChop's app icon at 1024x1024 to ../Icon.png.

Concept (v4): scissors closing on a commit in a git chain — same
composition as v3 — but rendered for macOS 26 ("Liquid Glass"). Brighter
saturated palette, top glass highlight, per-dot inner-light highlights,
and a soft inner shadow at the bottom for depth.

Run:
    python3 scripts/render-icon.py
"""

from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
from math import cos, sin, radians, hypot

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "Icon.png"


# ── shapes ────────────────────────────────────────────────────────────

def squircle_mask(size, radius_ratio=0.225):
    big = size * 4
    r = int(big * radius_ratio)
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, big - 1, big - 1), radius=r, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    """Vertical RGB gradient. Caller blends to RGBA later if needed."""
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
    w, h = layer.size
    pad = max(blur * 3, 24)
    out = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    alpha = layer.split()[-1]
    sh = Image.new("RGBA", out.size, (0, 0, 0, 0))
    sh.paste(
        (0, 0, 0, int(255 * opacity)),
        (pad + offset[0], pad + offset[1]),
        alpha,
    )
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out.alpha_composite(sh)
    out.alpha_composite(layer, (pad, pad))
    return out, (pad, pad)


def filled_circle(diameter, color, ring=None):
    pad = ring[1] if ring else 0
    s = diameter + pad * 2
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if ring:
        d.ellipse((0, 0, s - 1, s - 1), fill=ring[0])
        d.ellipse((pad, pad, pad + diameter - 1, pad + diameter - 1), fill=color)
    else:
        d.ellipse((0, 0, diameter - 1, diameter - 1), fill=color)
    return img


def vibrant_dot(diameter, base_color, ring_color=(255, 255, 255, 220), ring_w=12):
    """
    Filled dot with:
      • outer white ring (the bezel)
      • base fill in `base_color`
      • inner radial highlight near the top to give a "lit from above"
        glassy read.
    """
    s = diameter + ring_w * 2
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Bezel ring
    d.ellipse((0, 0, s - 1, s - 1), fill=ring_color)
    # Base fill
    d.ellipse((ring_w, ring_w, ring_w + diameter - 1, ring_w + diameter - 1), fill=base_color)

    # Subtle specular highlight: a wide soft ellipse near the top of
    # the dot. Drawn on its own RGBA layer, clipped to the dot's
    # interior via Image.composite (NOT Image.paste — paste with a
    # mask REPLACES alpha, which would erase the base color), then
    # alpha-composited onto the dot so the white-on-color blends
    # instead of overwriting.
    highlight = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hl_w = int(diameter * 0.78)
    hl_h = int(diameter * 0.32)
    hl_x = ring_w + (diameter - hl_w) // 2
    hl_y = ring_w + int(diameter * 0.05)
    hd.ellipse(
        (hl_x, hl_y, hl_x + hl_w, hl_y + hl_h),
        fill=(255, 255, 255, 95),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(int(diameter * 0.04)))

    # Build a mask of the dot's interior and use it to clip the
    # highlight to a transparent layer of the same size.
    interior_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(interior_mask).ellipse(
        (ring_w, ring_w, ring_w + diameter - 1, ring_w + diameter - 1),
        fill=255,
    )
    clipped_highlight = Image.composite(
        highlight,
        Image.new("RGBA", (s, s), (0, 0, 0, 0)),
        interior_mask,
    )
    img.alpha_composite(clipped_highlight)
    return img


# ── scissors ──────────────────────────────────────────────────────────

def tapered_blade_polygon(pivot, tip, base_w, tip_w):
    px, py = pivot
    tx, ty = tip
    dx, dy = tx - px, ty - py
    length = hypot(dx, dy)
    if length == 0:
        return [pivot, pivot, pivot, pivot]
    nx, ny = -dy / length, dx / length
    p1 = (px + nx * base_w / 2, py + ny * base_w / 2)
    p2 = (px - nx * base_w / 2, py - ny * base_w / 2)
    p3 = (tx - nx * tip_w / 2,  ty - ny * tip_w / 2)
    p4 = (tx + nx * tip_w / 2,  ty + ny * tip_w / 2)
    return [p1, p2, p3, p4]


def render_scissors(canvas_size, pivot, length=520, opening_deg=8,
                    loop_opening_deg=32, direction_deg=180,
                    color=(255, 255, 255, 245),
                    inner_pivot_color=(0x1B, 0x2A, 0x4E, 255)):
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    px, py = pivot

    base_w = int(length * 0.115)
    tip_w  = max(2, int(length * 0.012))

    aA = direction_deg - opening_deg
    aB = direction_deg + opening_deg
    tipA = (px + length * cos(radians(aA)), py + length * sin(radians(aA)))
    tipB = (px + length * cos(radians(aB)), py + length * sin(radians(aB)))

    d.polygon(tapered_blade_polygon(pivot, tipA, base_w, tip_w), fill=color)
    d.polygon(tapered_blade_polygon(pivot, tipB, base_w, tip_w), fill=color)

    loop_outer = int(length * 0.30)
    loop_ring  = int(length * 0.060)
    back_dir = direction_deg + 180
    loop_dist = int(length * 0.40)
    lA_angle = back_dir - loop_opening_deg
    lB_angle = back_dir + loop_opening_deg
    lA_center = (px + loop_dist * cos(radians(lA_angle)),
                 py + loop_dist * sin(radians(lA_angle)))
    lB_center = (px + loop_dist * cos(radians(lB_angle)),
                 py + loop_dist * sin(radians(lB_angle)))

    for cx, cy in (lA_center, lB_center):
        d.ellipse(
            (cx - loop_outer / 2, cy - loop_outer / 2,
             cx + loop_outer / 2, cy + loop_outer / 2),
            outline=color, width=loop_ring,
        )

    shaft_base_w = int(base_w * 0.95)
    shaft_tip_w  = int(base_w * 0.82)
    for cx, cy in (lA_center, lB_center):
        dx, dy = px - cx, py - cy
        dist = hypot(dx, dy)
        if dist == 0:
            continue
        ux, uy = dx / dist, dy / dist
        start = (cx + ux * (loop_outer / 2 - loop_ring * 0.4),
                 cy + uy * (loop_outer / 2 - loop_ring * 0.4))
        d.polygon(
            tapered_blade_polygon(start, pivot, shaft_base_w, shaft_tip_w),
            fill=color,
        )

    pivot_d = int(base_w * 1.05)
    d.ellipse(
        (px - pivot_d / 2, py - pivot_d / 2,
         px + pivot_d / 2, py + pivot_d / 2),
        fill=color,
    )
    inner_d = int(pivot_d * 0.34)
    d.ellipse(
        (px - inner_d / 2, py - inner_d / 2,
         px + inner_d / 2, py + inner_d / 2),
        fill=inner_pivot_color,
    )

    return layer


# ── glass effects ─────────────────────────────────────────────────────

def add_glass_highlight(canvas_size):
    """
    A soft white-to-transparent radial gloss at the top, mimicking how
    light catches a curved glass surface. Mostly affects the upper third
    of the squircle. Composited with mode=normal, alpha doing the work.
    """
    w, h = canvas_size
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # Big elliptical highlight — wider than the canvas so the falloff
    # at the corners is gradual.
    hl_w = int(w * 1.40)
    hl_h = int(h * 0.60)
    hl_cx = w // 2
    hl_cy = -int(h * 0.10)   # mostly above the canvas top
    # Build a faux radial gradient by stacking multiple semi-transparent
    # ellipses at decreasing alpha. Pillow doesn't have a native radial
    # gradient brush.
    layers = 26
    for i in range(layers):
        t = i / (layers - 1)
        ew = int(hl_w * (0.20 + 0.80 * t))
        eh = int(hl_h * (0.20 + 0.80 * t))
        alpha = int(70 * (1 - t) ** 2)
        if alpha <= 0:
            continue
        d.ellipse(
            (hl_cx - ew // 2, hl_cy - eh // 2,
             hl_cx + ew // 2, hl_cy + eh // 2),
            fill=(255, 255, 255, alpha),
        )
    return layer.filter(ImageFilter.GaussianBlur(int(w * 0.025)))


def add_bottom_inner_shadow(canvas_size, mask):
    """
    Subtle inner shadow at the bottom of the squircle — gives the icon
    a sense that the contents sit inside a curved enclosure with light
    coming from above.
    """
    w, h = canvas_size
    shadow = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    d = ImageDraw.Draw(shadow)
    # Dark band at the bottom, falling off toward the middle.
    band_h = int(h * 0.45)
    for y in range(band_h):
        t = y / (band_h - 1)
        # Strongest at the very bottom; quick falloff upward.
        alpha = int(75 * (t ** 3))
        d.line([(0, h - 1 - y), (w, h - 1 - y)], fill=(0, 0, 0, alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(w * 0.020)))

    # Clip to the squircle so the shadow doesn't extend past the corners.
    clipped = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    clipped.paste(shadow, (0, 0), mask)
    return clipped


# ── icon ──────────────────────────────────────────────────────────────

def render():
    # Background — vibrant electric-blue gradient, brighter than v3.
    # Picked for color-pop in both light and dark Dock chrome.
    bg = vertical_gradient((SIZE, SIZE), (0x18, 0x3C, 0xCC), (0x55, 0xA0, 0xFF))
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = squircle_mask(SIZE)
    icon.paste(bg, (0, 0), mask)

    # Top glass highlight — masked to the squircle so it follows the
    # rounded corners.
    highlight = add_glass_highlight((SIZE, SIZE))
    masked_highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    masked_highlight.paste(highlight, (0, 0), mask)
    icon.alpha_composite(masked_highlight)

    # ── git-graph chain ──
    spine_x = int(SIZE * 0.28)
    spine_top = int(SIZE * 0.20)
    spine_bot = int(SIZE * 0.80)
    line_w = int(SIZE * 0.020)

    # Brighter, more visible spine line.
    chain = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cd = ImageDraw.Draw(chain)
    cd.rounded_rectangle(
        (spine_x - line_w // 2, spine_top, spine_x + line_w // 2, spine_bot),
        radius=line_w // 2, fill=(255, 255, 255, 110),
    )
    icon.alpha_composite(chain)

    # Vibrant verb-chip palette — saturated enough to read against the
    # bright blue background. PICK lands as a warm slate so it doesn't
    # vanish into the bg; the other three are punched-up versions of
    # the in-app verb colors.
    PICK   = (0x6B, 0x82, 0xA8, 255)   # warm slate (readable on blue)
    SQUASH = (0x1E, 0x5B, 0xFF, 255)   # vivid cobalt
    FIXUP  = (0x16, 0xC1, 0x6C, 255)   # vivid emerald
    DROP   = (0xFF, 0x39, 0x4D, 255)   # vivid crimson

    dot_d = int(SIZE * 0.105)
    ring_w = int(SIZE * 0.012)
    dot_count = 4
    ys = [
        spine_top + int((spine_bot - spine_top) * i / (dot_count - 1))
        for i in range(dot_count)
    ]
    colors = [PICK, SQUASH, FIXUP, DROP]
    for y, color in zip(ys, colors):
        dot = vibrant_dot(dot_d, color,
                          ring_color=(255, 255, 255, 235),
                          ring_w=ring_w)
        ws, _ = with_drop_shadow(
            dot, offset=(0, int(SIZE * 0.008)),
            blur=int(SIZE * 0.014), opacity=0.32,
        )
        d_w, d_h = ws.size
        icon.alpha_composite(ws, (spine_x - d_w // 2, y - d_h // 2))

    # ── scissors ──
    squash_y = ys[1]
    pivot = (int(SIZE * 0.70), squash_y)
    scissors_layer = render_scissors(
        canvas_size=(SIZE, SIZE),
        pivot=pivot,
        length=int(SIZE * 0.50),
        opening_deg=8,
        loop_opening_deg=32,
        direction_deg=180,
        color=(255, 255, 255, 250),
        inner_pivot_color=(0x18, 0x3C, 0xCC, 255),
    )
    sc_with_shadow, origin = with_drop_shadow(
        scissors_layer,
        offset=(0, int(SIZE * 0.022)),
        blur=int(SIZE * 0.024),
        opacity=0.42,
    )
    icon.alpha_composite(sc_with_shadow, (-origin[0], -origin[1]))

    # Subtle bottom inner shadow for enclosure depth.
    icon.alpha_composite(add_bottom_inner_shadow((SIZE, SIZE), mask))

    # Re-mask in case any halo bled past the squircle.
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)

    out.save(OUT, "PNG")
    print(f"Wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    render()
