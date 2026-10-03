"""侠影录 · HUD 素材处理脚本

把 AI 生成的 UI 原图（assets/source_ai/）处理成游戏可直接使用的 HUD 贴图：
  1. 头像：以人脸为中心圆形裁切（避开右下角水印），输出 96x96 透明 PNG
  2. 技能图标：取圆形徽章包围盒，圆形裁切后缩到 80x80 透明 PNG

用法：
  python tools/make_ui_assets.py

输入固定为 assets/source_ai/ 下的生成图（文件名由 ImageGen 落盘时决定，
改动了生成批次就改下面的 INPUTS 表）；输出到 assets/ui/。
"""

import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "assets", "source_ai")
OUT_DIR = os.path.join(ROOT, "assets", "ui")

## (输出名, 源文件相对 source_ai 的路径, 裁切中心比例, 裁切半径占短边比例, 输出边长)
## 中心/半径用比例而不是像素：换一版同构图生成图时不用重新量。
INPUTS: list[tuple[str, str, tuple[float, float], float, int]] = [
    ("avatar.png", "Game_avatar_portrait_of_a_youn_2026-09-29T17-09-32.png",
     (0.500, 0.40), 0.335, 96),
    ("skill_attack.png", "2D_game_skill_icon__circular_e_2026-09-29T17-09-34.png",
     (0.500, 0.50), 0.490, 80),
    ("skill_evade.png", "2D_game_skill_icon__circular_e_2026-09-29T17-09-35.png",
     (0.500, 0.50), 0.490, 80),
    ("skill_guard.png", "2D_game_skill_icon__circular_e_2026-09-29T17-09-36.png",
     (0.500, 0.50), 0.490, 80),
    ("skill_jump.png", "2D_game_skill_icon__circular_e_2026-09-29T17-09-37.png",
     (0.500, 0.50), 0.490, 80),
    ("skill_dash.png", os.path.join("qinggong_dash_icon", "2D_game_skill_icon__circular_e_2026-09-29T17-10-18.png"),
     (0.500, 0.50), 0.490, 80),
]


def circle_crop(im: Image.Image, center: tuple[float, float], radius_ratio: float) -> Image.Image:
    """以比例指定的中心圆裁，返回以圆为界的正方形透明图。"""
    w, h = im.size
    side = min(w, h)
    cx, cy = center[0] * w, center[1] * h
    r = radius_ratio * side
    box = (int(cx - r), int(cy - r), int(cx + r), int(cy + r))
    cell = im.crop(box).convert("RGBA")
    # 4x 超采样画蒙版再缩小：直接 1x 画圆边缘会有明显的锯齿圈
    big = cell.size[0] * 4
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big, big), fill=255)
    mask = mask.resize(cell.size, Image.LANCZOS)
    cell.putalpha(mask)
    return cell


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, src, center, radius, out_size in INPUTS:
        path = os.path.join(SRC_DIR, src)
        if not os.path.exists(path):
            print("跳过（缺源图）:", name, "<-", src)
            continue
        im = Image.open(path).convert("RGBA")
        out = circle_crop(im, center, radius).resize((out_size, out_size), Image.LANCZOS)
        out_path = os.path.join(OUT_DIR, name)
        out.save(out_path)
        print("written:", os.path.relpath(out_path, ROOT), out.size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
