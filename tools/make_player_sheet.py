"""侠影录 · 主角序列帧处理脚本

把一张「cols 列 x rows 行」的序列图处理成游戏可直接用的贴图（默认 4x3 的跑步图）：

  1. 逐格量出角色内容的包围盒，算出**帧锚点** —— 即「脚底中线」在格子里的比例
  2. 按**目标角色高度**把整张图缩放到 1:1（默认游戏内 48px 高）

**目标高度而不是格子边长**：不同序列图的格子尺寸不一样（跑步图 256x256、待机图 256x341，
后者角色更高）。按格子边长缩放会让两条动画的角色大小对不上，一切换就「变大变小」；
按角色高度缩放才能保证待机 / 跑步是同一个体型。

**朝向约定**：游戏里美术一律朝 **+x（右）**。主角的翻面是靠 `_visuals.scale.x = _facing` 做的，
所以序列图必须本身朝右，否则会「倒着跑」。源图角色朝左时加 `--flip-x` 翻正 ——
脚本会顺带猜一下出图朝哪边，与约定对不上时会警告。

注意 `--flip-x` 是**逐格镜像**、不是整张图镜像：整张图翻会让格子顺序反过来
（第 0 帧跑到第 cols 格），帧序就全错了。

**锚点与目标高度都会打印出来**，前者要抄进 scripts/player.gd 的 ANIMS 常量。

用法：
  python tools/make_player_sheet.py <源序列图> <输出图> [--cols 5] [--rows 4] [--frames 20]
                                    [--target-h 48] [--flip-x]
"""

import sys

import numpy as np
from PIL import Image

## alpha 低于它的像素算全透明（抗锯齿边缘不算内容，免得把包围盒撑大）
ALPHA_FLOOR = 16
## 判「脸偏在哪边」用的肤色阈值（亮米色）。只是提示性启发式，不参与出图。
SKIN_MIN = (190, 170, 140)
## 只在内容顶部这么多比例里找脸 —— 手也是肤色，一起算会把结论带偏
HEAD_BAND = 0.30
## 头部区域里肤色像素少于这个数就认为测不准，不报朝向结论
SKIN_MIN_PIXELS = 40


def parse_args(argv: list[str]) -> dict:
    opts = {"cols": 4, "rows": 3, "frames": 0, "target_h": 48.0, "flip": False}
    pos: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--flip-x":
            opts["flip"] = True
        elif a in ("--cols", "--rows", "--frames", "--target-h"):
            i += 1
            key = a[2:].replace("-", "_")
            opts[key] = float(argv[i]) if key == "target_h" else int(argv[i])
        elif a.startswith("--"):
            print("未知参数：%s" % a)
        else:
            pos.append(a)
        i += 1
    opts["pos"] = pos
    return opts


def cells_alpha(alpha: np.ndarray, cols: int, rows: int) -> list[np.ndarray]:
    ch, cw = alpha.shape[0] // rows, alpha.shape[1] // cols
    return [alpha[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw]
            for r in range(rows) for c in range(cols)]


def frame_stats(alpha: np.ndarray, cols: int, rows: int, frames: int) -> list[dict]:
    stats: list[dict] = []
    for sub in cells_alpha(alpha, cols, rows):
        ys, xs = np.where(sub > ALPHA_FLOOR)
        if len(xs) == 0:
            continue
        stats.append({
            "idx": len(stats),
            "bbox": (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())),
            # 用中位数而不是包围盒中心：个别飘在外面的孤立像素会把中心带偏
            "x_center": float(np.median(xs)),
            # 脚底线取内容 y 的高分位：同样为了避开孤立像素
            "y_bottom": float(np.percentile(ys, 99.5)),
            "height": int(ys.max() - ys.min() + 1),
        })
    return stats[:frames] if frames > 0 else stats


def flip_cells(im: Image.Image, cols: int, rows: int) -> Image.Image:
    """逐格水平镜像。整张图直接翻会把帧序也翻过去，这里必须一格一格翻。"""
    cw, ch = im.size[0] // cols, im.size[1] // rows
    out = Image.new("RGBA", im.size)
    for r in range(rows):
        for c in range(cols):
            cell = im.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))
            out.paste(cell.transpose(Image.FLIP_LEFT_RIGHT), (c * cw, r * ch))
    return out


def face_side_ratios(rgba: np.ndarray, cols: int, rows: int, frames: int) -> list[float]:
    """逐帧猜角色朝哪边：**只看头部区域**的肤色像素中位横坐标，落在内容横向的百分之几处。

    只看头部是因为手也是肤色：待机姿势双手垂在身侧，全身一起算会得到 30%~53% 乱跳的结论。
    返回每帧一个比例（可能为空列表），由调用方判断可信度。
    """
    rgb, al = rgba[:, :, :3].astype(int), rgba[:, :, 3].astype(int)
    skin = ((al > 128)
            & (rgb[:, :, 0] > SKIN_MIN[0]) & (rgb[:, :, 1] > SKIN_MIN[1])
            & (rgb[:, :, 2] > SKIN_MIN[2]) & (rgb[:, :, 0] > rgb[:, :, 2]))
    cw, ch = rgba.shape[1] // cols, rgba.shape[0] // rows
    ratios: list[float] = []
    for i in range(min(frames or cols * rows, cols * rows)):
        r, c = i // cols, i % cols
        ys, xs = np.where(al[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw] > ALPHA_FLOOR)
        if len(xs) == 0:
            continue
        x0, x1, y0, y1 = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
        head_y1 = min(y0 + max(int((y1 - y0) * HEAD_BAND), 1), y1)
        band = skin[r * ch + y0:r * ch + head_y1, c * cw + x0:c * cw + x1 + 1]
        bys, bxs = np.where(band)
        span = float(x1 - x0)
        if len(bxs) < SKIN_MIN_PIXELS or span <= 0.0:
            continue
        ratios.append(float(np.median(bxs)) / span)
    return ratios


def report_facing(ratios: list[float], flipped: bool) -> None:
    """把朝向自检的结果讲清楚。判据是启发式的，所以同时给出**可信度**。

    逐帧比例如果是稳的（侧面姿势会稳），结论可信；如果帧间来回跳，那多半是正面姿势，
    或者画面里有别的东西在干扰 —— 这时只提示数字，不下结论。
    """
    if not ratios:
        print("\n朝向自检：没测到足够的头部肤色，跳过（请自己确认出图朝右）")
        return
    med = float(np.median(ratios))
    spread = float(np.percentile(ratios, 90) - np.percentile(ratios, 10))
    print("\n朝向自检：头部肤色落在内容横向 中位 %.0f%%（帧间波动 %.0f 个百分点，%d 帧）" % (
        100.0 * med, 100.0 * spread, len(ratios)))

    if spread > 0.15:
        print("  朝向不明显（多半是正面姿势，或画面里有别的东西在干扰肤色判据）—— 请自己看一眼，可忽略")
        return
    if med < 0.4:
        side = "朝左"
    elif med > 0.6:
        side = "朝右"
    else:
        print("  朝向不明显（正面姿势）—— 可忽略")
        return
    print("  结论：出图角色%s" % side)
    if med < 0.4:
        if flipped:
            print("  警告：加了 --flip-x 仍然朝左 —— 源图本来可能就朝右，这次翻反了")
        else:
            print("  警告：出图朝左，与游戏约定（朝右）相反 —— 请加 --flip-x")


def main() -> int:
    opts = parse_args(sys.argv[1:])
    pos = opts["pos"]
    if len(pos) < 2:
        print(__doc__)
        return 2

    src, out = pos[0], pos[1]
    cols, rows = int(opts["cols"]), int(opts["rows"])
    frames = int(opts["frames"])

    im = Image.open(src).convert("RGBA")
    if im.size[0] % cols or im.size[1] % rows:
        print("源图 %s 无法按 %dx%d 整除，请调整 --cols / --rows" % (im.size, cols, rows))
        return 1
    cw, ch = im.size[0] // cols, im.size[1] // rows

    if opts["flip"]:
        im = flip_cells(im, cols, rows)
        print("已逐格水平镜像（源图角色朝左 → 游戏约定朝右）")

    stats = frame_stats(np.asarray(im)[:, :, 3], cols, rows, frames)
    if not stats:
        print("没有识别到任何帧，检查 --cols / --rows / --frames")
        return 1
    print("源图 %s，格子 %dx%d，识别到 %d 帧" % (im.size, cw, ch, len(stats)))
    for s in stats:
        print("  frame %d  bbox=%s  高=%d  x_center=%.1f  y_bottom=%.1f" % (
            s["idx"], s["bbox"], s["height"], s["x_center"], s["y_bottom"]))

    x_center = float(np.median([s["x_center"] for s in stats]))
    y_bottom = float(np.median([s["y_bottom"] for s in stats]))
    body_h = float(np.median([s["height"] for s in stats]))
    scale = float(opts["target_h"]) / body_h
    out_cell = (round(cw * scale), round(ch * scale))

    print("\n缩放：角色高 %.0fpx -> %.0fpx（×%.4f），输出每格 %dx%d" % (
        body_h, float(opts["target_h"]), scale, out_cell[0], out_cell[1]))
    print("帧锚点（格子内比例，抄进 player.gd 的 ANIMS）：")
    print('  "anchor": Vector2(%.4f, %.4f),' % (x_center / cw, y_bottom / ch))

    face = face_side_ratios(np.asarray(im), cols, rows, frames)
    report_facing(face, bool(opts["flip"]))

    out_im = im.resize((out_cell[0] * cols, out_cell[1] * rows), Image.LANCZOS)
    out_im.save(out)
    print("\n已写出 %s（%dx%d，每格 %dx%d）" % (
        out, out_im.size[0], out_im.size[1], out_cell[0], out_cell[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
