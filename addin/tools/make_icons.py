"""生成加载项图标（简单条码图案的蓝色圆角方块）。"""
from PIL import Image, ImageDraw
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets")
os.makedirs(OUT, exist_ok=True)


def make(size: int, name: str) -> None:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = max(1, size // 10)
    d.rounded_rectangle(
        [pad // 2, pad // 2, size - 1 - pad // 2, size - 1 - pad // 2],
        radius=size // 5,
        fill=(31, 119, 187, 255),
    )
    bars = [0.06, 0.03, 0.05, 0.02, 0.07, 0.03, 0.04, 0.06]
    x = size * 0.18
    i = 0
    while x < size * 0.80:
        w = max(1, size * bars[i % len(bars)])
        d.rectangle([x, size * 0.28, x + w, size * 0.72], fill="white")
        x += w + size * 0.035
        i += 1
    img.save(os.path.join(OUT, name))
    print("saved", name)


for s in (16, 32, 80):
    make(s, f"icon-{s}.png")
