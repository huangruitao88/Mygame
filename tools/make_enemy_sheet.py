"""侠影录 · 敌兵/Boss 序列帧处理脚本

与 make_player_sheet.py 同一条管线，但针对「AI 直出的 2x2 序列图」做了三件更强的事：

  1. **抠底**：源图是白底不透明 PNG。从图像边缘洪泛填充「低饱和亮色」，
     只有与边缘连通的白底会被抠掉 —— 角色内部的浅色（Boss 刀刃高光、皮肤亮部）
     被描边包住、不与边缘连通，天然不受影响。
  2. **去水印**：生成图右下角有「AI生成」水印。它不与角色相连，
     逐格做连通域标记、只保留最大连通域即可顺带清除，不需要写死坐标。
  3. **逐帧底心对齐**：AI 序列图的每一帧位置/大小都会漂。逐帧量内容包围盒、
     取「脚底带」（内容最低 12% 区域）的横坐标中位数当左右锚、包围盒底边当竖直锚，
     按中位身高统一缩放后贴到输出格的固定锚点上 —— 播放时角色不再上下乱跳、
     武器前伸也不会把身体带得前后晃。

输出是同网格的归一化序列图（游戏内 1:1 使用），帧锚点恒等于
「格子横向正中 + 底部 pad 上沿」，会打印出来抄进 enemy.gd / boss.gd 的 ANIMS。

**朝向**：游戏约定美术一律朝 **+x（右）**，运行时靠 `_visuals.scale.x = _facing` 镜像。
源图若朝左（脚底重心偏右），必须加 `--flip-x` 翻正 —— 否则敌兵朝右走时会「倒着走」。
`--flip-x` 是**逐格镜像**不是整张图镜像（整张翻转会连帧序一起翻过去）。

用法：
  python tools/make_enemy_sheet.py <源序列图> <输出图> [--target-h 46] [--pad 12] [--flip-x]
"""

import sys
from collections import deque

import numpy as np
from PIL import Image

## alpha 低于它的像素不算内容
ALPHA_FLOOR = 16
## 抠底判据：三通道都不低于它、且饱和度（max-min）不高于它 —— 覆盖纯白到浅灰
KEY_MIN_LEVEL = 195
KEY_MAX_CHROMA = 42
## 脚底带取内容高度的这一比例（最低 12%）
FOOT_BAND = 0.12
## 封闭背景区域的面积下限：角色姿态会合围出「内部背景」（如长杆与两腿之间的空隙），
## 边缘洪泛够不到它们。超过这个面积的背景色连通域一律视为背景清除 ——
## 甲胄高光这类合法浅色区域都是小面积中灰，不会误伤。
INTERIOR_BG_AREA = 500


def flip_cells(im: Image.Image, cols: int, rows: int) -> Image.Image:
    """逐格水平镜像。整张图直接翻会把帧序也翻过去，这里必须一格一格翻。"""
    cw, ch = im.size[0] // cols, im.size[1] // rows
    out = Image.new("RGBA", im.size)
    for r in range(rows):
        for c in range(cols):
            cell = im.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))
            out.paste(cell.transpose(Image.FLIP_LEFT_RIGHT), (c * cw, r * ch))
    return out


def facing_ratios(masks: list[np.ndarray]) -> list[float]:
    """逐帧猜朝向：**脚底带**（内容最低 12%）的横向中位，落在内容宽度的百分之几处。

    判据：朝右站立的角色，双脚的横向重心天然落在身体中线**后方（左）**，
    也就是 < 50%。反之脚底重心 > 50% 说明角色朝左。
    只看脚底带是因为手臂/武器也伸在身体外侧，全身一起算会被前伸的刀斧带偏。
    """
    ratios: list[float] = []
    for mask in masks:
        ys, xs = np.where(mask)
        if len(xs) == 0:
            continue
        x0, x1, y0, y1 = int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())
        span = float(x1 - x0)
        if span <= 0.0:
            continue
        band_top = y1 - max(int((y1 - y0) * FOOT_BAND), 1)
        _bys, bxs = np.where(mask[band_top:, :])
        if len(bxs) == 0:
            continue
        ratios.append((float(np.median(bxs)) - float(x0)) / span)
    return ratios


def report_facing(ratios: list[float], flipped: bool) -> None:
    """把朝向自检讲清楚：给中位比例 + 帧间波动，波动大就只提示不下结论。"""
    if not ratios:
        print("\n朝向自检：没量到脚底带，跳过（请自己确认出图朝右）")
        return
    med = float(np.median(ratios))
    spread = float(np.percentile(ratios, 90) - np.percentile(ratios, 10))
    print("\n朝向自检：脚底带重心落在内容横向 中位 %.0f%%（帧间波动 %.0f 个百分点，%d 帧）" % (
        100.0 * med, 100.0 * spread, len(ratios)))
    if spread > 0.20:
        print("  朝向不明显（脚底带帧间浮动大，多半是宽站姿/正面姿势）—— 请自己看一眼")
        return
    if med > 0.60:
        side, ok = "朝左", False
    elif med < 0.40:
        side, ok = "朝右", True
    else:
        print("  朝向不明显（接近正面）—— 可忽略")
        return
    print("  结论：出图角色%s" % side)
    if not ok and not flipped:
        print("  警告：出图朝左，与游戏约定（朝右）相反 —— 请加 --flip-x，否则会「倒着走」")
    elif not ok and flipped:
        print("  警告：加了 --flip-x 仍然朝左 —— 源图本来可能就朝右，这次翻反了")
    elif ok and flipped:
        print("  已翻正：现在与游戏约定（朝右）一致")


def key_out_background(rgba: np.ndarray) -> np.ndarray:
    """抠掉白底：与边缘连通的背景 + 面积足够的封闭背景连通域。
    已有真透明（模型直接出了 alpha）时原样返回。"""
    alpha = rgba[:, :, 3]
    if float((alpha < 128).mean()) > 0.05:
        print("源图自带透明通道，跳过抠底")
        return rgba
    rgb = rgba[:, :, :3].astype(int)
    level = rgb.min(axis=2)
    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    bg = (level >= KEY_MIN_LEVEL) & (chroma <= KEY_MAX_CHROMA)

    h, w = bg.shape
    visited = np.zeros((h, w), dtype=bool)
    queue: deque[tuple[int, int]] = deque()

    def flood_from(seeds: list[tuple[int, int]]) -> None:
        for y, x in seeds:
            if bg[y, x] and not visited[y, x]:
                visited[y, x] = True
                queue.append((y, x))
        while queue:
            y, x = queue.popleft()
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < h and 0 <= nx < w and bg[ny, nx] and not visited[ny, nx]:
                    visited[ny, nx] = True
                    queue.append((ny, nx))

    flood_from([(0, x) for x in range(w)] + [(h - 1, x) for x in range(w)]
               + [(y, 0) for y in range(h)] + [(y, w - 1) for y in range(h)])

    # 封闭背景连通域：洪泛没到、但面积足够的背景色区域（姿态合围出的内部背景）
    interior = 0
    for y0 in range(h):
        for x0 in range(w):
            if not bg[y0, x0] or visited[y0, x0]:
                continue
            comp = [(y0, x0)]
            visited[y0, x0] = True
            qi = 0
            while qi < len(comp):
                y, x = comp[qi]
                qi += 1
                for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                    if 0 <= ny < h and 0 <= nx < w and bg[ny, nx] and not visited[ny, nx]:
                        visited[ny, nx] = True
                        comp.append((ny, nx))
            if len(comp) >= INTERIOR_BG_AREA:
                interior += 1  # visited 已标记，清除阶段统一处理
            else:
                # 小块浅色保留（高光等合法内容）：从 visited 放回去
                for y, x in comp:
                    visited[y, x] = False

    out = rgba.copy()
    out[:, :, 3] = np.where(visited, 0, alpha)
    print("抠底：清除 %d%% 的像素（边缘连通 + %d 块封闭背景）" % (
        round(100.0 * float((out[:, :, 3] == 0).mean())), interior))
    return out


def largest_component(mask: np.ndarray) -> np.ndarray:
    """逐格最大连通域：水印、飘落的碎屑都和角色不相连，直接丢弃。"""
    h, w = mask.shape
    labels = np.zeros((h, w), dtype=np.int32)
    current = 0
    best_label, best_size = 0, 0
    for y0 in range(h):
        for x0 in range(w):
            if not mask[y0, x0] or labels[y0, x0] != 0:
                continue
            current += 1
            size = 0
            queue: deque[tuple[int, int]] = deque([(y0, x0)])
            labels[y0, x0] = current
            while queue:
                y, x = queue.popleft()
                size += 1
                for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and labels[ny, nx] == 0:
                        labels[ny, nx] = current
                        queue.append((ny, nx))
            if size > best_size:
                best_label, best_size = current, size
    return labels == best_label if best_label > 0 else np.zeros((h, w), dtype=bool)


def cell_content(rgba: np.ndarray, col: int, row: int, cols: int, rows: int) -> np.ndarray:
    """取出 (col,row) 格的 alpha，抠掉「非最大连通域」的杂散内容。"""
    ch, cw = rgba.shape[0] // rows, rgba.shape[1] // cols
    cell_alpha = rgba[row * ch:(row + 1) * ch, col * cw:(col + 1) * cw, 3]
    mask = cell_alpha > ALPHA_FLOOR
    if not mask.any():
        return mask
    return largest_component(mask)


def frame_anchors(mask: np.ndarray) -> tuple[float, float, int] | None:
    """返回（脚底带横锚、内容底边 y、内容高）。脚底带 = 最低 12% 区域的横坐标中位数。"""
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return None
    y0, y1 = int(ys.min()), int(ys.max())
    band_top = y1 - max(int((y1 - y0) * FOOT_BAND), 1)
    band_ys, band_xs = np.where(mask[band_top:, :])
    foot_cx = float(np.median(band_xs)) if len(band_xs) else float(np.median(xs))
    return foot_cx, float(y1) + 1.0, int(y1 - y0 + 1)


def main() -> int:
    args = sys.argv[1:]
    target_h, pad = 46.0, 12.0
    flipped = False
    pos: list[str] = []
    i = 0
    while i < len(args):
        if args[i] == "--target-h":
            i += 1
            target_h = float(args[i])
        elif args[i] == "--pad":
            i += 1
            pad = float(args[i])
        elif args[i] == "--flip-x":
            flipped = True
        elif args[i].startswith("--"):
            print("未知参数：%s" % args[i])
        else:
            pos.append(args[i])
        i += 1
    if len(pos) < 2:
        print(__doc__)
        return 2
    src, out = pos[0], pos[1]
    cols, rows = 2, 2

    im = Image.open(src).convert("RGBA")
    if im.size[0] % cols or im.size[1] % rows:
        print("源图 %s 无法按 %dx%d 整除" % (im.size, cols, rows))
        return 1
    if flipped:
        im = flip_cells(im, cols, rows)
        print("已逐格水平镜像（源图角色朝左 → 游戏约定朝右）")
    rgba = key_out_background(np.asarray(im))
    print("源图 %s，按 %dx%d 切格" % (im.size, cols, rows))

    masks = [[cell_content(rgba, c, r, cols, rows) for c in range(cols)] for r in range(rows)]
    flat = [m for row in masks for m in row]
    report_facing(facing_ratios(flat), flipped)
    infos = [frame_anchors(m) for m in flat]
    heights = [info[2] for info in infos if info is not None]
    if not heights:
        print("没有识别到任何帧内容")
        return 1
    body_h = float(np.median(heights))
    scale = target_h / body_h
    print("角色中位高 %.0fpx -> %.0fpx（×%.4f）" % (body_h, target_h, scale))

    # 输出格尺寸：取「缩放后最宽帧」决定格宽，格高统一 target_h + pad（底部留 pad/2 空隙）
    max_w = 0
    for mask in flat:
        ys, xs = np.where(mask)
        if len(xs):
            max_w = max(max_w, int(xs.max()) - int(xs.min()) + 1)
    cell_w = int(np.ceil(max_w * scale)) + int(pad) * 2
    cell_h = int(np.ceil(target_h)) + int(pad)
    foot_y = float(cell_h) - pad * 0.5

    sheet = Image.new("RGBA", (cell_w * cols, cell_h * rows), (0, 0, 0, 0))
    for idx, mask in enumerate(flat):
        info = infos[idx]
        if info is None:
            print("  frame %d：空帧，跳过" % idx)
            continue
        foot_cx, bottom, _ = info
        r, c = idx // cols, idx % cols
        ch, cw = rgba.shape[0] // rows, rgba.shape[1] // cols
        cell = Image.fromarray(rgba[r * ch:(r + 1) * ch, c * cw:(c + 1) * cw])
        # 目标位置：脚底带横锚对到格子中线、内容底边对到 foot_y
        dest_x = int(round(float(cell_w) * 0.5 - foot_cx * scale))
        dest_y = int(round(foot_y - bottom * scale))
        scaled = cell.resize((max(int(round(cw * scale)), 1), max(int(round(ch * scale)), 1)), Image.LANCZOS)
        sheet.paste(scaled, (c * cell_w + dest_x, r * cell_h + dest_y), scaled)
        print("  frame %d：脚锚 x=%.0f 底 y=%.0f -> 格(%d,%d) 偏移(%+d,%+d)" % (
            idx, foot_cx, bottom, r, c, dest_x, dest_y))

    sheet.save(out)
    print("\n已写出 %s（%dx%d，每格 %dx%d）" % (out, sheet.size[0], sheet.size[1], cell_w, cell_h))
    print("帧锚点（抄进 ANIMS）：")
    print('  "anchor": Vector2(0.5, %.4f),' % (foot_y / float(cell_h)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
