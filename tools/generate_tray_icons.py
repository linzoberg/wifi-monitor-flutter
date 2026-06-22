"""
Генератор PNG-иконок трея для Wi-Fi Монитора.
Запускается один раз вручную, кладёт tray_green.png и tray_red.png в assets/.
"""
from PIL import Image, ImageDraw
import os

# Цвета 1:1 с Python-версией (ui/icons.py + window.py)
GREEN = "#2ecc71"
RED = "#e74c3c"

# Рисуем в большом размере с SSAA-сглаживанием, потом ресайз вниз → ровные края
SUPER = 4
FINAL_SIZE = 64
SIZE = FINAL_SIZE * SUPER
MARGIN = 4 * SUPER  # как в оригинале: drawEllipse(4, 4, 56, 56)


def make_icon(color: str, path: str) -> None:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse(
        (MARGIN, MARGIN, SIZE - MARGIN, SIZE - MARGIN),
        fill=color,
    )
    img = img.resize((FINAL_SIZE, FINAL_SIZE), Image.LANCZOS)
    img.save(path, "PNG")
    print(f"  OK  {path}")


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(here, "..", "assets")
    out_dir = os.path.normpath(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    print("Generating tray icons...")
    make_icon(GREEN, os.path.join(out_dir, "tray_green.png"))
    make_icon(RED, os.path.join(out_dir, "tray_red.png"))
    print("Done.")


if __name__ == "__main__":
    main()
