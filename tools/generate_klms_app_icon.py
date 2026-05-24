#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_DIR = ROOT / "apps" / "KLMSync" / "Resources"
PNG_PATH = RESOURCE_DIR / "AppIcon.png"
ICONSET_DIR = RESOURCE_DIR / "AppIcon.iconset"
ICNS_PATH = RESOURCE_DIR / "AppIcon.icns"
SCALE = 4
SIZE = 1024
W = SIZE * SCALE


def rgba(hex_value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = hex_value.lstrip("#")
    return (
        int(value[0:2], 16),
        int(value[2:4], 16),
        int(value[4:6], 16),
        alpha,
    )


def s(value: float) -> int:
    return int(round(value * SCALE))


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def rounded_rect_mask(box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (W, W), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(box, radius=radius, fill=255)
    return mask


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int, int], bottom: tuple[int, int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    px = image.load()
    for y in range(height):
        t = y / max(1, height - 1)
        color = tuple(lerp(top[i], bottom[i], t) for i in range(4))
        for x in range(width):
            px[x, y] = color
    return image


def draw_glow(base: Image.Image, layer: Image.Image, blur: int, opacity: float = 1.0) -> None:
    glow = layer.filter(ImageFilter.GaussianBlur(blur))
    if opacity < 1:
        alpha = glow.getchannel("A").point(lambda value: int(value * opacity))
        glow.putalpha(alpha)
    base.alpha_composite(glow)
    base.alpha_composite(layer)


def arc_points(center: tuple[int, int], radius: int, start_deg: float, end_deg: float, count: int = 180) -> list[tuple[int, int]]:
    cx, cy = center
    return [
        (
            int(round(cx + math.cos(math.radians(start_deg + (end_deg - start_deg) * i / (count - 1))) * radius)),
            int(round(cy + math.sin(math.radians(start_deg + (end_deg - start_deg) * i / (count - 1))) * radius)),
        )
        for i in range(count)
    ]


def draw_round_polyline(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], color: tuple[int, int, int, int], width: int) -> None:
    if len(points) < 2:
        return
    draw.line(points, fill=color, width=width, joint="curve")
    radius = width // 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def draw_arrowhead(draw: ImageDraw.ImageDraw, point: tuple[int, int], angle_deg: float, color: tuple[int, int, int, int], size: int) -> None:
    angle = math.radians(angle_deg)
    spread = math.radians(32)
    p0 = point
    p1 = (
        int(round(point[0] - math.cos(angle - spread) * size)),
        int(round(point[1] - math.sin(angle - spread) * size)),
    )
    p2 = (
        int(round(point[0] - math.cos(angle + spread) * size)),
        int(round(point[1] - math.sin(angle + spread) * size)),
    )
    draw.polygon([p0, p1, p2], fill=color)


def make_master_icon() -> Image.Image:
    canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    app_box = (s(58), s(44), s(966), s(966))
    app_radius = s(188)
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (app_box[0] + s(8), app_box[1] + s(22), app_box[2] - s(8), app_box[3] + s(14)),
        radius=app_radius,
        fill=(0, 0, 0, 115),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(18))))

    base = vertical_gradient((W, W), rgba("#184f54"), rgba("#071d26"))
    base_mask = rounded_rect_mask(app_box, app_radius)
    base.putalpha(base_mask)
    canvas.alpha_composite(base)

    inner = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    inner_draw = ImageDraw.Draw(inner)
    inner_draw.rounded_rectangle(
        (app_box[0] + s(22), app_box[1] + s(22), app_box[2] - s(22), app_box[3] - s(22)),
        radius=s(158),
        outline=rgba("#02131a", 185),
        width=s(8),
    )
    inner_draw.rounded_rectangle(
        (app_box[0] + s(6), app_box[1] + s(6), app_box[2] - s(6), app_box[3] - s(6)),
        radius=s(180),
        outline=rgba("#dafcf4", 210),
        width=s(5),
    )
    canvas.alpha_composite(inner)

    grid = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    grid_draw = ImageDraw.Draw(grid)
    for offset in range(-600, 1500, 132):
        grid_draw.line((s(offset), s(950), s(offset + 520), s(160)), fill=rgba("#d5fff8", 105), width=s(2))
    for offset in range(-500, 1600, 116):
        grid_draw.line((s(125), s(offset), s(910), s(offset - 135)), fill=rgba("#bff6ee", 72), width=s(1.2))
    grid.putalpha(Image.composite(grid.getchannel("A"), Image.new("L", (W, W), 0), base_mask))
    canvas.alpha_composite(grid)

    highlight = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    high_draw = ImageDraw.Draw(highlight)
    high_draw.rounded_rectangle((s(112), s(78), s(900), s(308)), radius=s(120), fill=rgba("#65f4df", 36))
    highlight = highlight.filter(ImageFilter.GaussianBlur(s(28)))
    highlight.putalpha(Image.composite(highlight.getchannel("A"), Image.new("L", (W, W), 0), base_mask))
    canvas.alpha_composite(highlight)

    card = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    card_draw = ImageDraw.Draw(card)
    card_box = (s(330), s(246), s(735), s(733))
    card_draw.rounded_rectangle((card_box[0] + s(12), card_box[1] + s(20), card_box[2] + s(16), card_box[3] + s(22)), radius=s(34), fill=(0, 0, 0, 95))
    canvas.alpha_composite(card.filter(ImageFilter.GaussianBlur(s(9))))

    card = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    card_draw = ImageDraw.Draw(card)
    card_draw.rounded_rectangle(card_box, radius=s(32), fill=rgba("#f7fbf8"))
    card_draw.polygon([(s(645), s(246)), (s(735), s(336)), (s(645), s(336))], fill=rgba("#d9ebe4"))
    card_draw.line((s(645), s(246), s(645), s(336), s(735), s(336)), fill=rgba("#a9c9c0"), width=s(3))
    canvas.alpha_composite(card)

    mark = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    mark_draw = ImageDraw.Draw(mark)
    rows = [
        (s(392), s(407), rgba("#14a7c7"), s(255)),
        (s(392), s(503), rgba("#35b873"), s(235)),
        (s(392), s(599), rgba("#f2aa25"), s(214)),
    ]
    for x, y, color, line_end in rows:
        mark_draw.rounded_rectangle((x - s(19), y - s(19), x + s(19), y + s(19)), radius=s(10), fill=color)
        mark_draw.rounded_rectangle((s(420), y - s(13), line_end + s(392), y + s(13)), radius=s(13), fill=rgba("#263a43", 232))
        mark_draw.rounded_rectangle((s(420), y + s(30), line_end + s(346), y + s(46)), radius=s(8), fill=rgba("#263a43", 218))
    mark_draw.line((s(370), s(694), s(430), s(746), s(575), s(650)), fill=rgba("#24a467"), width=s(33), joint="curve")
    mark_draw.line((s(370), s(694), s(430), s(746), s(575), s(650)), fill=rgba("#2bd783"), width=s(12), joint="curve")
    canvas.alpha_composite(mark)

    ring = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ring_draw = ImageDraw.Draw(ring)
    center = (s(514), s(508))
    cyan = rgba("#48efe4")
    green = rgba("#4ed96d")
    dark_gap = rgba("#102b31", 0)
    _ = dark_gap
    arc1 = arc_points(center, s(330), 198, 356, 220)
    arc2 = arc_points(center, s(330), 20, 166, 210)
    arc3 = arc_points(center, s(292), 195, 43, 220)
    draw_round_polyline(ring_draw, arc1, green, s(50))
    draw_round_polyline(ring_draw, arc2, cyan, s(50))
    draw_round_polyline(ring_draw, arc3, rgba("#5bfff0", 145), s(11))
    draw_arrowhead(ring_draw, arc1[-1], 356 + 90, green, s(72))
    draw_arrowhead(ring_draw, arc2[-1], 166 + 90, cyan, s(72))
    ring_shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ring_shadow_draw = ImageDraw.Draw(ring_shadow)
    draw_round_polyline(ring_shadow_draw, arc1, rgba("#49ff77", 115), s(62))
    draw_round_polyline(ring_shadow_draw, arc2, rgba("#46fff2", 125), s(62))
    draw_glow(canvas, ring_shadow, s(16), 0.7)
    canvas.alpha_composite(ring)

    glare = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    glare_draw = ImageDraw.Draw(glare)
    glare_draw.line((s(135), s(126), s(850), s(18)), fill=rgba("#ffffff", 115), width=s(2))
    glare_draw.line((s(42), s(180), s(187), s(500)), fill=rgba("#ffffff", 180), width=s(4))
    glare_draw.line((s(705), s(180), s(820), s(395)), fill=rgba("#ffffff", 125), width=s(3))
    glare.putalpha(Image.composite(glare.getchannel("A"), Image.new("L", (W, W), 0), base_mask))
    canvas.alpha_composite(glare)

    return canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def write_iconset(master: Image.Image) -> None:
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for filename, size in sizes.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET_DIR / filename)


def write_icns() -> None:
    chunks = [
        ("icp4", ICONSET_DIR / "icon_16x16.png"),
        ("icp5", ICONSET_DIR / "icon_32x32.png"),
        ("icp6", ICONSET_DIR / "icon_32x32@2x.png"),
        ("ic07", ICONSET_DIR / "icon_128x128.png"),
        ("ic08", ICONSET_DIR / "icon_256x256.png"),
        ("ic09", ICONSET_DIR / "icon_512x512.png"),
        ("ic10", ICONSET_DIR / "icon_512x512@2x.png"),
    ]
    payload = bytearray()
    for code, path in chunks:
        data = path.read_bytes()
        payload.extend(code.encode("ascii"))
        payload.extend(struct.pack(">I", len(data) + 8))
        payload.extend(data)

    ICNS_PATH.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


def main() -> None:
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    master = make_master_icon()
    master.save(PNG_PATH)
    write_iconset(master)

    iconutil = shutil.which("iconutil")
    if iconutil:
        try:
            subprocess.run(
                [iconutil, "--convert", "icns", "--output", str(ICNS_PATH), str(ICONSET_DIR)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return
        except subprocess.CalledProcessError:
            write_icns()
    else:
        write_icns()


if __name__ == "__main__":
    main()
