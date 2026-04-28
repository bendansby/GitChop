#!/usr/bin/env python3
"""
Render GitChop's app icon at 1024x1024 to ../Icon.png.

Concept (v3): scissors as the hero, with a vertical commit chain
behind. The scissors descend diagonally from the upper right; blades
open ~25 degrees each; tips converge just past one of the commit dots
on the chain. Reads as "snip a commit out of the git graph" — chop +
rebase in one image.

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


# ── scissors ──────────────────────────────────────────────────────────

def tapered_blade_polygon(pivot, tip, base_w, tip_w):
    """
    Quadrilateral that tapers from `base_w` at `pivot` to `tip_w` at
    `tip`. Used to draw a single scissor blade as a sharp triangle-ish
    shape rather than a uniform-width line.
    """
    px, py = pivot
    tx, ty = tip
    dx, dy = tx - px, ty - py
    length = hypot(dx, dy)
    if length == 0:
        return [pivot, pivot, pivot, pivot]
    # Unit perpendicular (left side of the direction vector)
    nx, ny = -dy / length, dx / length
    p1 = (px + nx * base_w / 2, py + ny * base_w / 2)
    p2 = (px - nx * base_w / 2, py - ny * base_w / 2)
    p3 = (tx - nx * tip_w / 2,  ty - ny * tip_w / 2)
    p4 = (tx + nx * tip_w / 2,  ty + ny * tip_w / 2)
    return [p1, p2, p3, p4]


def render_scissors(canvas_size, pivot, length=520, opening_deg=24,
                    loop_opening_deg=32,
                    direction_deg=210, color=(255, 255, 255, 240)):
    """
    Draw a stylized scissors on a transparent layer the size of the
    icon. `direction_deg` is the angle the scissors point in (where the
    blade tips go); 0° = right, 90° = down (PIL convention with y-down).
    `opening_deg` is each blade's deflection from the centerline at the
    front; `loop_opening_deg` is the corresponding angle at the back —
    typically wider so the finger loops actually look like two separate
    handles instead of stacked rings.
    """
    layer = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    px, py = pivot

    # Blade geometry
    base_w = int(length * 0.115)   # chunky at the pivot
    tip_w  = max(2, int(length * 0.012))   # nearly a point at the tip

    # Blade angles (around direction_deg)
    aA = direction_deg - opening_deg
    aB = direction_deg + opening_deg
    tipA = (px + length * cos(radians(aA)), py + length * sin(radians(aA)))
    tipB = (px + length * cos(radians(aB)), py + length * sin(radians(aB)))

    # Blades — drawn as tapered polygons so they read as cutting blades
    d.polygon(tapered_blade_polygon(pivot, tipA, base_w, tip_w), fill=color)
    d.polygon(tapered_blade_polygon(pivot, tipB, base_w, tip_w), fill=color)

    # Finger loops — sit at the back of the scissors, on the opposite
    # side of the pivot from the tips. Loops splay wider than the
    # blades so the silhouette reads as a real pair of scissors and not
    # two stacked rings.
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

    # Loop "shafts" — short rounded bars from each loop toward the
    # pivot, so the loops feel attached rather than floating. They
    # also visually thicken the back of the scissors which reads as a
    # proper scissors silhouette.
    shaft_base_w = int(base_w * 0.95)
    shaft_tip_w  = int(base_w * 0.82)
    for cx, cy in (lA_center, lB_center):
        # From near the loop center to the pivot
        # Pull the start a bit toward the pivot so the shaft tucks
        # under the loop ring instead of starting at its edge.
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

    # Pivot rivet — small filled circle at the cross point to ground
    # everything visually.
    pivot_d = int(base_w * 1.05)
    d.ellipse(
        (px - pivot_d / 2, py - pivot_d / 2,
         px + pivot_d / 2, py + pivot_d / 2),
        fill=color,
    )
    # Inner pivot dot in the bg color for a subtle recessed look
    inner_d = int(pivot_d * 0.34)
    d.ellipse(
        (px - inner_d / 2, py - inner_d / 2,
         px + inner_d / 2, py + inner_d / 2),
        fill=(0x1B, 0x2A, 0x4E, 255),
    )

    return layer


# ── icon ──────────────────────────────────────────────────────────────

def render():
    # Background
    bg = vertical_gradient((SIZE, SIZE), (0x1B, 0x2A, 0x4E), (0x3D, 0x6B, 0xC9))
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), squircle_mask(SIZE))

    # ── git-graph chain (background layer) ──
    # Vertical line, four commit dots, slightly muted so the scissors
    # read as foreground.
    spine_x = int(SIZE * 0.28)
    spine_top = int(SIZE * 0.20)
    spine_bot = int(SIZE * 0.80)
    line_w = int(SIZE * 0.018)

    chain = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cd = ImageDraw.Draw(chain)
    cd.rounded_rectangle(
        (spine_x - line_w // 2, spine_top, spine_x + line_w // 2, spine_bot),
        radius=line_w // 2, fill=(255, 255, 255, 75),
    )
    icon.alpha_composite(chain)

    # Verb-chip palette
    PICK   = (0xB7, 0xC2, 0xD4, 255)
    SQUASH = (0x2C, 0x86, 0xF5, 255)
    FIXUP  = (0x3F, 0xB0, 0x6E, 255)
    DROP   = (0xE5, 0x4A, 0x4A, 255)

    dot_d = int(SIZE * 0.105)
    ring_w = int(SIZE * 0.011)
    dot_count = 4
    ys = [
        spine_top + int((spine_bot - spine_top) * i / (dot_count - 1))
        for i in range(dot_count)
    ]
    colors = [PICK, SQUASH, FIXUP, DROP]
    for y, color in zip(ys, colors):
        dot = filled_circle(dot_d, color, ring=((255, 255, 255, 200), ring_w))
        ws, _ = with_drop_shadow(
            dot, offset=(0, int(SIZE * 0.006)),
            blur=int(SIZE * 0.010), opacity=0.30,
        )
        d_w, d_h = ws.size
        icon.alpha_composite(
            ws,
            (spine_x - d_w // 2, y - d_h // 2),
        )

    # ── scissors (foreground hero) ──
    # Pivot is right of the chain at the same y as the squash commit
    # (second from top). Blades point straight left with a tight
    # opening — tips extend past the squash dot, framing it between
    # the two blades. Reads as "scissors closing on this commit".
    squash_y = ys[1]
    pivot = (int(SIZE * 0.70), squash_y)
    scissors_layer = render_scissors(
        canvas_size=(SIZE, SIZE),
        pivot=pivot,
        length=int(SIZE * 0.50),
        opening_deg=8,
        direction_deg=180,            # left
        color=(255, 255, 255, 245),
    )
    # Drop shadow under the entire scissors.
    sc_with_shadow, origin = with_drop_shadow(
        scissors_layer,
        offset=(0, int(SIZE * 0.018)),
        blur=int(SIZE * 0.022),
        opacity=0.40,
    )
    # The scissors_layer is already the size of the icon, so origin
    # represents the shadow padding. Composite at -origin to place
    # the scissors correctly.
    icon.alpha_composite(sc_with_shadow, (-origin[0], -origin[1]))

    # Re-mask so any shadow halo bled past the squircle is clipped.
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(icon, (0, 0), squircle_mask(SIZE))

    out.save(OUT, "PNG")
    print(f"Wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    render()
