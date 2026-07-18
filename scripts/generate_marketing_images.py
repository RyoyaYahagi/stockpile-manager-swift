#!/usr/bin/env python3
"""
capture_screenshots.sh で撮影したシミュレータのスクリーンショットに
タイトル・サブタイトルを合成し、App Store Connect提出用のマーケティング画像を生成する。

使い方:
  python3 scripts/generate_marketing_images.py [--locale ja]
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT_DIR = Path(__file__).resolve().parent.parent
CAPTIONS_PATH = ROOT_DIR / "scripts" / "screenshot_captions.json"
RAW_DIR = ROOT_DIR / "screenshots" / "raw"
OUTPUT_DIR = ROOT_DIR / "screenshots" / "marketing"

# App Store Connect の6.5インチ要求サイズ（1284×2778 / 1242×2688）に合わせる
CANVAS_SIZE = (1284, 2778)
TITLE_FONT_PATH = "/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc"
SUBTITLE_FONT_PATH = "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc"
TITLE_FONT_SIZE = 92
SUBTITLE_FONT_SIZE = 48
TEXT_TOP_MARGIN = 170
TEXT_BLOCK_GAP = 28
SCREENSHOT_TOP_MARGIN = 420
SCREENSHOT_SIDE_MARGIN = 90
CORNER_RADIUS = 64

BACKGROUND_TOP = (235, 245, 255)
BACKGROUND_BOTTOM = (214, 234, 250)
TITLE_COLOR = (17, 34, 51)
SUBTITLE_COLOR = (70, 90, 110)


def make_background(size: tuple[int, int]) -> Image.Image:
    width, height = size
    background = Image.new("RGB", size, BACKGROUND_TOP)
    top = BACKGROUND_TOP
    bottom = BACKGROUND_BOTTOM
    for y in range(height):
        ratio = y / max(height - 1, 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3))
        ImageDraw.Draw(background).line([(0, y), (width, y)], fill=color)
    return background


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), (size[0] - 1, size[1] - 1)], radius=radius, fill=255)
    return mask


def draw_wrapped_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont,
    max_width: int,
    center_x: int,
    top_y: int,
    fill: tuple[int, int, int],
    line_spacing: int = 12,
) -> int:
    lines: list[str] = []
    current = ""
    for char in text:
        candidate = current + char
        bbox = draw.textbbox((0, 0), candidate, font=font)
        if bbox[2] - bbox[0] > max_width and current:
            lines.append(current)
            current = char
        else:
            current = candidate
    if current:
        lines.append(current)

    y = top_y
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font)
        line_width = bbox[2] - bbox[0]
        line_height = bbox[3] - bbox[1]
        draw.text((center_x - line_width / 2, y - bbox[1]), line, font=font, fill=fill)
        y += line_height + line_spacing
    return y


def compose_image(screenshot_path: Path, title: str, subtitle: str, output_path: Path) -> None:
    canvas = make_background(CANVAS_SIZE)
    draw = ImageDraw.Draw(canvas)

    title_font = ImageFont.truetype(TITLE_FONT_PATH, TITLE_FONT_SIZE)
    subtitle_font = ImageFont.truetype(SUBTITLE_FONT_PATH, SUBTITLE_FONT_SIZE)
    text_max_width = CANVAS_SIZE[0] - 140

    next_y = draw_wrapped_text(
        draw, title, title_font, text_max_width, CANVAS_SIZE[0] // 2, TEXT_TOP_MARGIN, TITLE_COLOR
    )
    draw_wrapped_text(
        draw,
        subtitle,
        subtitle_font,
        text_max_width,
        CANVAS_SIZE[0] // 2,
        next_y + TEXT_BLOCK_GAP,
        SUBTITLE_COLOR,
    )

    screenshot = Image.open(screenshot_path).convert("RGB")
    target_width = CANVAS_SIZE[0] - SCREENSHOT_SIDE_MARGIN * 2
    scale = target_width / screenshot.width
    target_height = int(screenshot.height * scale)
    screenshot = screenshot.resize((target_width, target_height), Image.LANCZOS)

    mask = rounded_mask((target_width, target_height), CORNER_RADIUS)
    rounded_screenshot = Image.new("RGBA", (target_width, target_height))
    rounded_screenshot.paste(screenshot, (0, 0), mask)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_box = [
        SCREENSHOT_SIDE_MARGIN,
        SCREENSHOT_TOP_MARGIN + 24,
        SCREENSHOT_SIDE_MARGIN + target_width,
        SCREENSHOT_TOP_MARGIN + target_height + 24,
    ]
    shadow_draw.rounded_rectangle(shadow_box, radius=CORNER_RADIUS, fill=(20, 30, 45, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))

    canvas_rgba = canvas.convert("RGBA")
    canvas_rgba.alpha_composite(shadow)
    canvas_rgba.alpha_composite(rounded_screenshot, (SCREENSHOT_SIDE_MARGIN, SCREENSHOT_TOP_MARGIN))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas_rgba.convert("RGB").save(output_path, "PNG")
    print(f"  -> {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--locale", default="ja")
    args = parser.parse_args()

    captions = json.loads(CAPTIONS_PATH.read_text(encoding="utf-8"))
    locale_captions = captions.get(args.locale)
    if not locale_captions:
        raise SystemExit(f"'{args.locale}' のキャプション定義が見つかりません: {CAPTIONS_PATH}")

    raw_dir = RAW_DIR / args.locale
    output_dir = OUTPUT_DIR / args.locale

    for screen_key, caption in locale_captions.items():
        screenshot_path = raw_dir / f"{screen_key}.png"
        if not screenshot_path.exists():
            print(f"skip: {screenshot_path} が見つかりません（先に capture_screenshots.sh を実行してください）")
            continue

        output_path = output_dir / f"{screen_key}.png"
        print(f"== {screen_key} ==")
        compose_image(screenshot_path, caption["title"], caption["subtitle"], output_path)


if __name__ == "__main__":
    main()
