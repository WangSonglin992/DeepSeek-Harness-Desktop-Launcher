from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


ICON_SIZES = (16, 24, 32, 48, 64, 128, 256)


def keep_largest_alpha_component(image: Image.Image) -> Image.Image:
    """Remove disconnected scan artifacts while preserving the main character."""
    alpha = image.getchannel("A")
    width, height = alpha.size
    occupied = bytearray(1 if value >= 8 else 0 for value in alpha.tobytes())
    visited = bytearray(width * height)
    largest: list[int] = []

    for start, value in enumerate(occupied):
        if not value or visited[start]:
            continue
        visited[start] = 1
        component: list[int] = []
        queue: deque[int] = deque([start])
        while queue:
            index = queue.popleft()
            component.append(index)
            x = index % width
            y = index // width
            for next_x, next_y in (
                (x - 1, y - 1), (x, y - 1), (x + 1, y - 1),
                (x - 1, y),                     (x + 1, y),
                (x - 1, y + 1), (x, y + 1), (x + 1, y + 1),
            ):
                if next_x < 0 or next_x >= width or next_y < 0 or next_y >= height:
                    continue
                next_index = next_y * width + next_x
                if occupied[next_index] and not visited[next_index]:
                    visited[next_index] = 1
                    queue.append(next_index)
        if len(component) > len(largest):
            largest = component

    if not largest:
        raise ValueError("No visible subject found in the source image")
    keep = bytearray(width * height)
    for index in largest:
        keep[index] = 1
    alpha_bytes = bytearray(alpha.tobytes())
    for index, value in enumerate(keep):
        if not value:
            alpha_bytes[index] = 0
    cleaned = image.copy()
    cleaned.putalpha(Image.frombytes("L", (width, height), bytes(alpha_bytes)))
    return cleaned


def build_icon(source: Path, preview: Path, icon: Path) -> None:
    image = Image.open(source).convert("RGBA")

    # Remove only near-white pixels connected to the outer canvas. This keeps
    # white costume details inside the outlined character intact.
    for seed in ((0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)):
        ImageDraw.floodfill(image, seed, (255, 255, 255, 0), thresh=18)

    image = keep_largest_alpha_component(image)

    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is None:
        raise ValueError("The source image became empty after background removal")
    image = image.crop(alpha_box)

    canvas_size = 1024
    padding = 52
    fitted = ImageOps.contain(
        image,
        (canvas_size - 2 * padding, canvas_size - 2 * padding),
        Image.Resampling.LANCZOS,
    )
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    position = ((canvas_size - fitted.width) // 2, (canvas_size - fitted.height) // 2)
    canvas.alpha_composite(fitted, position)

    preview.parent.mkdir(parents=True, exist_ok=True)
    icon.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(preview, format="PNG", optimize=True)
    canvas.save(icon, format="ICO", sizes=[(size, size) for size in ICON_SIZES])


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the DeepSeek Harness launcher icon")
    parser.add_argument("source", type=Path)
    parser.add_argument("preview", type=Path)
    parser.add_argument("icon", type=Path)
    args = parser.parse_args()
    build_icon(args.source, args.preview, args.icon)


if __name__ == "__main__":
    main()
