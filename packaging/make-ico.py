#!/usr/bin/env python3
"""生成托盘与安装器共用的 .ico。

不要直接把 addin/assets 里的 PNG 放大：那些是给网页用的（上限 80px），
Windows 图标需要 256px 源图，并且多个尺寸打包进同一个 .ico。
这里按 addin/tools/make_icons.py **相同的条码图案**重新绘制，保证桌面图标、
任务栏图标与加载项图标观感一致 —— 同一个产品，不该有两种长相。
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# 与 addin/tools/make_icons.py 保持一致的配色与构图
BG = (31, 119, 187, 255)
BAR_RATIOS = [0.06, 0.03, 0.05, 0.02, 0.07, 0.03, 0.04, 0.06]


def draw(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = max(1, size // 10)
    d.rounded_rectangle(
        [pad // 2, pad // 2, size - 1 - pad // 2, size - 1 - pad // 2],
        radius=size // 5,
        fill=BG,
    )
    x = size * 0.18
    i = 0
    while x < size * 0.80:
        w = max(1, size * BAR_RATIOS[i % len(BAR_RATIOS)])
        d.rectangle([x, size * 0.28, x + w, size * 0.72], fill="white")
        x += w + size * 0.035
        i += 1
    return img


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = Path(sys.argv[1]).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    source = draw(256)  # 256 是 ICO 的最大常规尺寸，Pillow 据此下采样出其余尺寸
    source.save(
        str(out),
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)],
    )
    print(f"saved {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
