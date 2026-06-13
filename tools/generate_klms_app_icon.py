#!/usr/bin/env python3
from __future__ import annotations

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
IOS_APPICON_DIR = ROOT / "apps" / "KLMSync" / "Xcode" / "KLMSiOS" / "KLMSiOS" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ASSET_DIR = ROOT / "apps" / "KLMSyncWindows" / "assets"
WINDOWS_SVG_PATH = WINDOWS_ASSET_DIR / "icon.svg"
WINDOWS_ICO_PATH = WINDOWS_ASSET_DIR / "icon.ico"

SCALE = 4
SIZE = 1024
W = SIZE * SCALE

PAPER = "#F8F7F2"
PANEL = "#FFFFFF"
SOFT = "#ECE9DF"
LINE = "#D7D1C4"
GRAPHITE = "#2A2A27"
DARK = "#10100F"
DARK_PANEL = "#1D1D1B"
IVORY = "#F0DFB8"
INK = "#171613"
MUTED = "#6D675D"


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


def rounded(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], radius: float, fill: str, outline: str | None = None, width: float = 1, alpha: int = 255) -> None:
    draw.rounded_rectangle(
        tuple(s(v) for v in box),
        radius=s(radius),
        fill=rgba(fill, alpha),
        outline=rgba(outline, alpha) if outline else None,
        width=max(1, s(width)),
    )


def rectangle(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], fill: str, alpha: int = 255) -> None:
    draw.rectangle(tuple(s(v) for v in box), fill=rgba(fill, alpha))


def make_shadow(box: tuple[int, int, int, int], radius: int, alpha: int, blur: int, offset_y: int = 0) -> Image.Image:
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(
        (box[0], box[1] + offset_y, box[2], box[3] + offset_y),
        radius=radius,
        fill=(0, 0, 0, alpha),
    )
    return layer.filter(ImageFilter.GaussianBlur(blur))


def draw_sync_mark(draw: ImageDraw.ImageDraw, cx: float, cy: float, scale: float, color: str) -> None:
    width = s(9 * scale)
    bbox_1 = tuple(s(v) for v in (cx - 34 * scale, cy - 31 * scale, cx + 34 * scale, cy + 37 * scale))
    bbox_2 = tuple(s(v) for v in (cx - 34 * scale, cy - 37 * scale, cx + 34 * scale, cy + 31 * scale))
    draw.arc(bbox_1, 205, 358, fill=rgba(color), width=width)
    draw.arc(bbox_2, 25, 178, fill=rgba(color), width=width)
    draw.polygon(
        [
            (s(cx + 35 * scale), s(cy + 1 * scale)),
            (s(cx + 55 * scale), s(cy - 11 * scale)),
            (s(cx + 45 * scale), s(cy + 15 * scale)),
        ],
        fill=rgba(color),
    )
    draw.polygon(
        [
            (s(cx - 35 * scale), s(cy - 1 * scale)),
            (s(cx - 55 * scale), s(cy + 11 * scale)),
            (s(cx - 45 * scale), s(cy - 15 * scale)),
        ],
        fill=rgba(color),
    )


def make_master_icon() -> Image.Image:
    canvas = Image.new("RGBA", (W, W), rgba(PAPER))

    app_box = (s(72), s(60), s(952), s(952))
    app_radius = s(184)
    canvas.alpha_composite(make_shadow(app_box, app_radius, alpha=72, blur=s(18), offset_y=s(22)))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(app_box, radius=app_radius, fill=rgba(PAPER), outline=rgba(DARK), width=s(22))

    # Top graphite rim, matching the browser mockup frame.
    rounded(draw, (106, 96, 918, 216), 62, GRAPHITE)
    rounded(draw, (122, 112, 902, 202), 46, DARK_PANEL)
    for x, color in [(160, "#D8D2C5"), (198, "#CFC8B9"), (236, "#BFB7A8")]:
        draw.ellipse((s(x), s(145), s(x + 22), s(167)), fill=rgba(color))
    rounded(draw, (296, 138, 470, 176), 18, IVORY, alpha=32)
    rounded(draw, (726, 138, 856, 176), 18, IVORY, alpha=42)

    # Main dashboard window.
    window_box = (s(126), s(224), s(898), s(868))
    canvas.alpha_composite(make_shadow(window_box, s(52), alpha=35, blur=s(12), offset_y=s(10)))
    rounded(draw, (126, 224, 898, 868), 52, PANEL, LINE, 4)
    rectangle(draw, (126, 224, 898, 290), SOFT)
    draw.line((s(126), s(290), s(898), s(290)), fill=rgba(LINE), width=s(4))

    # Dashboard headline bars.
    rounded(draw, (170, 326, 332, 368), 16, DARK)
    rounded(draw, (170, 386, 456, 410), 12, MUTED, alpha=120)
    rounded(draw, (718, 326, 818, 368), 20, SOFT, LINE, 2)
    rounded(draw, (832, 326, 872, 368), 20, SOFT, LINE, 2)

    # Important status banner.
    rounded(draw, (170, 438, 854, 516), 24, SOFT, LINE, 3)
    rounded(draw, (196, 462, 372, 486), 10, GRAPHITE, alpha=225)
    rounded(draw, (196, 492, 524, 504), 6, MUTED, alpha=110)
    draw.ellipse((s(796), s(458), s(836), s(498)), fill=rgba(IVORY))

    # Left rail panels.
    rounded(draw, (170, 552, 432, 796), 26, PANEL, LINE, 3)
    rounded(draw, (194, 584, 408, 662), 22, GRAPHITE)
    draw.polygon([(s(370), s(610)), (s(370), s(636)), (s(394), s(623))], fill=rgba(IVORY))
    draw_sync_mark(draw, 250, 623, 0.55, IVORY)
    for i in range(3):
        x0 = 194 + i * 72
        rounded(draw, (x0, 684, x0 + 58, 728), 14, SOFT, LINE, 2)
    rounded(draw, (194, 750, 408, 772), 10, DARK, alpha=225)

    # Metric cards, same order as the final dashboard.
    metric_boxes = [(462, 552, 552, 628), (574, 552, 664, 628), (686, 552, 776, 628), (798, 552, 854, 628)]
    metric_widths = [42, 26, 46, 24]
    for box, bar_width in zip(metric_boxes, metric_widths):
        rounded(draw, box, 20, PANEL, LINE, 3)
        rounded(draw, (box[0] + 16, box[1] + 16, box[0] + 16 + bar_width, box[1] + 34), 8, DARK)
        rounded(draw, (box[0] + 16, box[1] + 48, box[2] - 18, box[1] + 58), 5, MUTED, alpha=110)

    # Detail list cards.
    for idx, y in enumerate([664, 728, 792]):
        rounded(draw, (462, y, 854, y + 48), 16, SOFT if idx != 2 else PANEL, LINE, 2)
        rounded(draw, (486, y + 14, 670 - idx * 24, y + 26), 6, DARK, alpha=225)
        rounded(draw, (486, y + 32, 716 - idx * 10, y + 40), 4, MUTED, alpha=100)
        rounded(draw, (776, y + 13, 830, y + 35), 11, GRAPHITE if idx == 2 else "#D8D2C5")

    # Fine border highlights for depth.
    draw.rounded_rectangle(
        (s(92), s(80), s(932), s(932)),
        radius=s(164),
        outline=rgba("#FFFFFF", 120),
        width=s(3),
    )
    draw.rounded_rectangle(
        (s(78), s(66), s(946), s(946)),
        radius=s(178),
        outline=rgba(DARK, 60),
        width=s(4),
    )

    return canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS).convert("RGB")


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
    for path in ICONSET_DIR.glob("*.png"):
        if path.name not in sizes:
            path.unlink()
    for filename, size in sizes.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET_DIR / filename)


def write_ios_appiconset(master: Image.Image) -> None:
    IOS_APPICON_DIR.mkdir(parents=True, exist_ok=True)
    sizes = {
        "Icon-20@2x.png": 40,
        "Icon-20@3x.png": 60,
        "Icon-29@2x.png": 58,
        "Icon-29@3x.png": 87,
        "Icon-40@2x.png": 80,
        "Icon-40@3x.png": 120,
        "Icon-60@2x.png": 120,
        "Icon-60@3x.png": 180,
        "Icon-20-ipad.png": 20,
        "Icon-20-ipad@2x.png": 40,
        "Icon-29-ipad.png": 29,
        "Icon-29-ipad@2x.png": 58,
        "Icon-40-ipad.png": 40,
        "Icon-40-ipad@2x.png": 80,
        "Icon-76-ipad.png": 76,
        "Icon-76-ipad@2x.png": 152,
        "Icon-83.5-ipad@2x.png": 167,
        "Icon-1024.png": 1024,
    }
    for filename, size in sizes.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(IOS_APPICON_DIR / filename)


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


def write_windows_ico(master: Image.Image) -> None:
    WINDOWS_ASSET_DIR.mkdir(parents=True, exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    master.convert("RGBA").save(WINDOWS_ICO_PATH, sizes=[(size, size) for size in sizes])


def write_windows_svg() -> None:
    WINDOWS_ASSET_DIR.mkdir(parents=True, exist_ok=True)
    WINDOWS_SVG_PATH.write_text(
        f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img" aria-label="KLMS Sync">
  <rect width="256" height="256" fill="{PAPER}"/>
  <rect x="18" y="15" width="220" height="226" rx="45" fill="{PAPER}" stroke="{DARK}" stroke-width="6"/>
  <rect x="28" y="27" width="200" height="30" rx="15" fill="{GRAPHITE}"/>
  <circle cx="45" cy="42" r="3.6" fill="#D8D2C5"/>
  <circle cx="56" cy="42" r="3.6" fill="#CFC8B9"/>
  <circle cx="67" cy="42" r="3.6" fill="#BFB7A8"/>
  <rect x="31" y="63" width="194" height="161" rx="13" fill="{PANEL}" stroke="{LINE}" stroke-width="2"/>
  <rect x="31" y="63" width="194" height="17" fill="{SOFT}"/>
  <rect x="42" y="92" width="43" height="10" rx="3" fill="{DARK}"/>
  <rect x="42" y="107" width="76" height="5" rx="2.5" fill="{MUTED}" opacity=".55"/>
  <rect x="42" y="120" width="172" height="20" rx="6" fill="{SOFT}" stroke="{LINE}" stroke-width="1"/>
  <circle cx="203" cy="130" r="5" fill="{IVORY}"/>
  <rect x="42" y="150" width="66" height="61" rx="7" fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>
  <rect x="48" y="158" width="54" height="20" rx="5" fill="{GRAPHITE}"/>
  <path d="M92 164l8 4-8 4z" fill="{IVORY}"/>
  <path d="M62 174a9 9 0 0 1 15-8" fill="none" stroke="{IVORY}" stroke-width="2" stroke-linecap="round"/>
  <path d="M78 164l4 1-2-4" fill="none" stroke="{IVORY}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="118" y="150" width="23" height="19" rx="5" fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>
  <rect x="147" y="150" width="23" height="19" rx="5" fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>
  <rect x="176" y="150" width="23" height="19" rx="5" fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>
  <rect x="119" y="184" width="95" height="12" rx="4" fill="{SOFT}" stroke="{LINE}" stroke-width="1"/>
  <rect x="124" y="188" width="42" height="3" rx="1.5" fill="{DARK}"/>
</svg>
""",
        encoding="utf-8",
    )


def main() -> None:
    RESOURCE_DIR.mkdir(parents=True, exist_ok=True)
    master = make_master_icon()
    master.save(PNG_PATH)
    write_iconset(master)
    write_ios_appiconset(master)
    write_windows_svg()
    write_windows_ico(master)

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
