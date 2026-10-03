"""侠影录 · 地图贴图处理

把 AI 生成的贴图处理成关卡可平铺使用的样式：
  - 地面：整图可用，边缘交叉淡化（cross-fade）让横向/纵向接缝消失，缩到 256。
  - 石墙：生成图上下带竹林背景，裁出中间的砖墙条带再交叉淡化，缩到 256 宽。

用法：
  python tools/make_tiles.py <地面源图> <墙面源图> <地输出> <墙输出>
"""

import sys

import numpy as np
from PIL import Image

## 接缝淡化带宽度（源图像素）
BLEND = 48


def crossfade_tile(im: Image.Image, crop: tuple[int, int, int, int] | None, out_w: int) -> Image.Image:
    if crop is not None:
        im = im.crop(crop)
    im = im.convert("RGB")
    w, h = im.size
    arr = np.asarray(im).astype(np.float32)

    b = min(BLEND, w // 4, h // 4)
    # 横向：右边缘 b 列与左边缘 b 列交叉淡化（把右缘 wrap 一份再混）
    ramp = np.linspace(0.0, 1.0, b, dtype=np.float32)[None, :, None]
    left = arr[:, :b, :]
    right_wrapped = arr[:, -b:, :]
    # 把左缘前 b 列替换成「左缘与右缘的混合」，实现无缝循环
    arr[:, :b, :] = left * ramp + right_wrapped * (1.0 - ramp)
    # 纵向同理
    ramp_v = np.linspace(0.0, 1.0, b, dtype=np.float32)[:, None, None]
    top = arr[:b, :, :]
    bottom_wrapped = arr[-b:, :, :]
    arr[:b, :, :] = top * ramp_v + bottom_wrapped * (1.0 - ramp_v)

    out_h = max(int(round(out_w * h / w)), 1)
    return Image.fromarray(arr.astype(np.uint8)).resize((out_w, out_h), Image.LANCZOS)


def main() -> int:
    if len(sys.argv) < 5:
        print(__doc__)
        return 2
    ground_src, wall_src, ground_out, wall_out = sys.argv[1:5]

    ground = crossfade_tile(Image.open(ground_src), None, 256)
    ground.save(ground_out)
    print("地面贴图 -> %s %s" % (ground_out, ground.size))

    # 石墙：裁掉顶部竹林与底部竹林（目测砖墙条带在 20%..80% 高度之间）
    wall_im = Image.open(wall_src)
    w, h = wall_im.size
    wall = crossfade_tile(wall_im, (0, int(h * 0.20), w, int(h * 0.78)), 256)
    wall.save(wall_out)
    print("墙面贴图 -> %s %s" % (wall_out, wall.size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
