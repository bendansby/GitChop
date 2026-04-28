#!/usr/bin/env python3
"""
Render GitChop's app icon at 1024x1024 to ../Icon.png.

Concept: a distilled view of the app's commit-row UI — three horizontal
rows in a squircle, each with a colored verb chip on the left and a
content bar to the right. The chips use the same accent colors the app
uses for the verbs (red = drop, green = fixup, blue = squash). The
top-left "pick" chip is lifted off the stack a touch with a softer
shadow, hinting that it's mid-drag.

Background is a developer-blueish gradient diagonal, distinct from the
green of MockHop and the brighter blues of StyleBop.

Run:
    python3 scripts/render-icon.py
"""

from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
from math import pi, cos, sin, pow as fpow

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "Icon.png"


def squircle_mask(size, radius_ratio=0.225, scale=4):
    """
    A squircle (n=5 superellipse) approximation, rendered at scale-x and
    downsampled for clean antialiased edges. Actual iOS/macOS app icons
    use a true superellipse; PIL's rounded_rectangle is close enough at
    1024px and far simpler.
    """
    big = size * scale
    radius = int(big * radius_ratio)
    mask = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, big - 1, big - 1), radius=radius, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def linear_gradient(size, top_color, bottom_color, angle_deg=135):
    """Diagonal linear gradient."""
    w, h = size
    grad = Image.new("RGB", size, top_color)
    px = grad.load()
    rad = angle_deg * pi / 180.0
    dx, dy = cos(rad), sin(rad)
    # Project each pixel onto the gradient axis, normalized 0..1
    proj_max = abs(dx) * (w - 1) + abs(dy) * (h - 1)
    for y in range(h):
        for x in range(w):
            t = (x * dx + y * dy) / proj_max
            t = max(0.0, min(1.0, t))
            r = int(top_color[0] + (bottom_color[0] - top_color[0]) * t)
            g = int(top_color[1] + (bottom_color[1] - top_color[1]) * t)
            b = int(top_color[2] + (bottom_color[2] - top_color[2]) * t)
            px[x, y] = (r, g, b)
    return grad


def fast_gradient(size, top, bottom):
    """Vertical gradient — faster than the per-pixel diagonal."""
    w, h = size
    grad = Image.new("RGB", size, top)
    d = ImageDraw.Draw(grad)
    for y in range(h):
        t = y / (h - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        d.line([(0, y), (w, y)], fill=(r, g, b))
    return grad


def drop_shadow(layer, offset=(0, 8), blur=12, opacity=0.35):
    """Composite layer + a soft shadow below it. Returns a new RGBA image."""
    w, h = layer.size
    pad = max(blur * 3, 20)
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    # Build shadow from the alpha of the layer
    alpha = layer.split()[-1]
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, int(255 * opacity)),
                 (pad + offset[0], pad + offset[1]),
                 alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(layer, (pad, pad))
    # Crop back to original layer bounds (lose the off-canvas blur halo
    # — that's fine for compositing into a larger background)
    return canvas, (pad, pad)


def chip(width, height, color, radius=None):
    """A solid filled rounded rectangle on transparent — the verb chip."""
    if radius is None:
        radius = height // 2
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, width - 1, height - 1), radius=radius, fill=color)
    return img


def commit_row(width, height, chip_color, bar_color, chip_w_ratio=0.32):
    """
    One commit row: a colored verb chip on the left, a content bar to
    the right of it. Both are rounded; both sit on transparent.
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    radius = height // 2
    chip_w = int(width * chip_w_ratio)
    # Chip
    d.rounded_rectangle((0, 0, chip_w, height), radius=radius, fill=chip_color)
    # Content bar (slightly shorter than the row, with a small gap after the chip)
    gap = int(height * 0.18)
    bar_x = chip_w + gap
    bar_h = int(height * 0.62)
    bar_y = (height - bar_h) // 2
    bar_w_end = width - int(height * 0.25)
    d.rounded_rectangle(
        (bar_x, bar_y, bar_w_end, bar_y + bar_h),
        radius=bar_h // 2,
        fill=bar_color,
    )
    return img


def render():
    # ── Background squircle ──
    # Deep developer-blue → brighter teal-blue. Distinct from MockHop's
    # mint green and StyleBop's brighter cobalt.
    bg = fast_gradient((SIZE, SIZE), (0x1B, 0x2A, 0x4E), (0x3D, 0x6B, 0xC9))
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = squircle_mask(SIZE)
    icon.paste(bg, (0, 0), mask)

    # ── Commit-row stack ──
    # Three rows, stacked vertically, slightly inset from the squircle.
    # The middle row is full-width; the others are nudged right and
    # narrower to suggest a draggable list with one row being moved.
    row_w = int(SIZE * 0.66)
    row_h = int(SIZE * 0.13)
    row_gap = int(SIZE * 0.045)
    stack_h = row_h * 3 + row_gap * 2
    stack_top = (SIZE - stack_h) // 2 + int(SIZE * 0.015)  # nudge down slightly
    center_x = SIZE // 2

    # Verb chip colors mirror the app (Models.swift):
    #   squash  #1A69D6  (blue)
    #   fixup   #2E8C55  (green)
    #   drop    #D93838  (red)
    rows = [
        # (chip_color, bar_brightness, x_offset_px)
        ((0x1A, 0x69, 0xD6, 255), 0.95, -int(SIZE * 0.018)),  # blue
        ((0x2E, 0x8C, 0x55, 255), 1.00,  0),                   # green (centered)
        ((0xD9, 0x38, 0x38, 255), 0.95, -int(SIZE * 0.018)),  # red
    ]
    bar_color = (255, 255, 255, 230)

    for i, (chip_color, _bar_b, x_off) in enumerate(rows):
        row = commit_row(row_w, row_h, chip_color, bar_color)
        with_shadow, origin = drop_shadow(row, offset=(0, int(row_h * 0.10)),
                                          blur=int(row_h * 0.18), opacity=0.30)
        rx = center_x - row_w // 2 + x_off - origin[0]
        ry = stack_top + (row_h + row_gap) * i - origin[1]
        icon.alpha_composite(with_shadow, (rx, ry))

    # Re-mask so any shadow halo that bled past the squircle gets clipped.
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)

    out.save(OUT, "PNG")
    print(f"Wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    render()
