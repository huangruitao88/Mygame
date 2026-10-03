"""侠影录 · 背景底图处理脚本

把 AI 生成的场景图处理成游戏可直接使用的背景贴图：
  1. 修补右下角的工具水印（从同一行左侧取一块草地平移贴回，左边缘羽化）
  2. 按游戏内部视口取景缩放（默认 588x328，比 480x270 视口略宽，留给视差位移）

用法：
  python tools/make_background.py <输入图> <输出图> [目标宽]

目标宽 588 = 480(视口) + 0.05(视差) * 1420(相机横向行程) + 余量，
这样背景在整段关卡里都不可能滑出画面（见 scripts/game.gd 的 BG_* 常量）。

注意：贴图按 1:1 渲染（不缩放）= 最清晰。改目标宽要重跑本脚本，
不要改 sprite 的 scale。
"""

import sys

from PIL import Image

## 水印所在的右下角区域（1920x1072 底图上的实测范围）
WATERMARK_BOX = (1786, 995, 1920, 1072)


def remove_watermark(im: Image.Image) -> Image.Image:
    """镜像贴补掉右下角水印。

    不用羽化蒙版：从水印左侧取一块等宽草地**水平镜像**后贴到水印上，
    镜像轴两侧的像素本来就相邻（贴过去的第一列 = 原图第 1785 列），
    边界天然连续，不会有羽化残留把水印文字留下一层。
    """
    dst = im.copy()
    x0, y0, x1, y1 = WATERMARK_BOX
    patch = im.crop((x0 - (x1 - x0), y0, x0, y1)).transpose(Image.FLIP_LEFT_RIGHT)
    dst.paste(patch, (x0, y0))
    return dst


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    src_path, out_path = sys.argv[1], sys.argv[2]
    target_w = int(sys.argv[3]) if len(sys.argv) > 3 else 588

    im = Image.open(src_path).convert("RGB")
    print("source:", im.size)

    im = remove_watermark(im)

    target_h = round(target_w * im.size[1] / im.size[0])
    out = im.resize((target_w, target_h), Image.LANCZOS)
    out.save(out_path)
    print("written:", out_path, out.size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
