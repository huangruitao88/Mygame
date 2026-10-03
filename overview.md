# 敌兵/Boss 序列帧动画 + 竹海地图贴图

## 概述

按参考图（小怪=破衣山贼斧手、一阶段 Boss=黑甲红披风长刀武将、地图=雾竹海）完成：
小怪与 Boss 各四套动画（待机/行走/攻击/受击）、同风格地图贴图接入平台与墙体、
场景文件与可直接运行的 GDScript。**冒烟测试 181 项全绿（0 失败）**，
`--write-movie` 真实渲染抓帧目检通过（锚点贴地、朝向镜像正确、无抠图破洞）。

## 新增资产

- `assets/sprites/minion_{idle,walk,attack,hurt}.png`、`boss_{idle,walk,attack,hurt}.png`
  （8 张归一化序列图，源图在 `assets/source_ai/{minion,boss}/`）
- `assets/backgrounds/ground_tile.png`、`wall_tile.png`（可平铺，源图 `assets/source_ai/tiles/`）
- ImageGen 共 10 张生成调用（角色 8 + 地形 2，逐张串行防同名覆盖）

## 新增/修改代码

| 文件 | 内容 |
| --- | --- |
| `tools/make_enemy_sheet.py` | 新：洪泛抠底（+封闭背景大区域清除，治「长杆与腿间白洞」）+ 最大连通域去水印 + 逐帧脚底带对齐 + 中位身高归一。锚点恒为 (0.5, 底部 pad 上沿)。**朝向自检 + `--flip-x` 逐格镜像**（见下） |
| `tools/make_tiles.py` | 新：地形贴图裁剪 + 边缘交叉淡化 + 缩到 256 |
| `scripts/enemy.gd` | `ANIMS` 四套动画 + `AnimatedSprite2D` 装配（`_build_sprite_visuals`，缺贴图回退 `_build_fallback_visuals` 多边形小人）；动画状态机 `_update_anim`（攻击>受击>移动>待机）；新增近身攻击：贴身停步→0.55s 出招→0.3s 处伤害帧（touch_damage+4）→1.25s 冷却，受击打断 |
| `scripts/boss.gd` | `BOSS_ANIMS`（不可叫 ANIMS，GDScript 禁止遮蔽父类常量！）经 `_sprite_anims()` 覆写提供；`_update_anim` 在 WINDUP/DASH 强制 attack 帧；预警箭簇挪到 `_build_extras()`；旧多边形小人降级为回退 |
| `scripts/game.gd` | `_make_tiled_sprite`（region+REPEAT 平铺贴图）+ `TILE_TINT/WALL_TINT` 压暗调色（AI 原图在夜战场景里太亮，0.62/0.72 灰度系数）；贴图缺失回退原纯色多边形 |
| `scenes/minion.tscn`、`scenes/boss_phase1.tscn` | 新：集成点（根 CharacterBody2D + 脚本，层级由 `_ready()` 组装） |
| `tests/preview_actors.tscn/.gd` | 新：视觉 QA 预览场景，时间轴轮播四套动画，配 `--write-movie` 抓帧 |
| `tests/preview_facing.tscn/.gd` | 新：**朝向 QA**——让敌兵真的追着玩家走，逐帧断言「面朝方向 == 实际位移方向」。不带参数测朝右，加 `-- --left` 测朝左，两向都必须 0 不符 |

## 关键决策

- **逐帧归一化**而非全局锚点：AI 序列图每帧位置/大小漂移大，逐帧按「脚底带横锚 + 包围盒底边」
  对齐后动作不再上下跳；攻击帧武器前伸也不会把身体带偏。
- 受击/攻击动画设 loop=false，由状态机切走；受击（`_stun`）天然打断出招。
- Boss 突进（WINDUP+DASH≈0.95s）与 attack 动画（4 帧 @4.5fps≈0.9s）时长对齐，一个动画罩全程。
- **美术一律朝 +x（右）**，运行时靠 `_visuals.scale.x = float(_facing)` 镜像。这条约定必须在
  素材管线（`make_enemy_sheet.py --flip-x`）就保证，不能在引擎里再翻一次——否则两个朝向总有一个是反的。

## 修复：行走方向与面朝方向搞反（本轮）

**症状**：小怪朝右走时，看着像「倒着走」/「面朝方向与行走方向相反」。

**定位过程（都是量出来的，不是猜的）**：

1. 逐帧量「脚底带（内容最低 12%）横向中位落在内容宽度的百分之几」：
   - 小怪 idle 65%、walk 42%、attack 70%、hurt 66% —— 全部偏右；
   - 按判据（**朝右站立时双脚重心天然落在身体中线后方，即 <50%**），说明为**朝左**出图；
   - 对照 Boss 68%/59%、玩家 51%（玩家本身就是半正面待机，中性）。
2. 真实渲染抓帧目检：小怪与 Boss 的**斧头/脸/刀全部指向左**，而引擎 `_facing=1` 时不镜像 → 朝右走却朝左画。

**根因**：AI 源图把角色画成了**朝左**，而项目约定是**朝右**。此前 `make_player_sheet.py` 有
`face_side_ratios()` / `--flip-x`，但 `make_enemy_sheet.py` **漏了这套朝向保障**，于是 8 张敌兵图全部朝左。

**修复**：

- `make_enemy_sheet.py` 补上 `facing_ratios()` + `report_facing()`（脚底带重心判据，输出中位比例
  与帧间波动，波动大只提示不下结论）+ `--flip-x`（**逐格**镜像，整张翻会把帧序也翻过去）。
- 8 张图（小怪 4 + Boss 4）全部带 `--flip-x` 重新处理，修后比例 27%~41%，一致朝右；
  锚点仍是 `(0.5, 0.8966)` / `(0.5, 0.9231)`（锚点 x 恒为 0.5，镜像天然保持有效）。
- 新增 `tests/preview_facing.tscn`：让敌兵**真的走起来**（而非手动指定动画帧），逐帧断言
  `移动方向 == _facing`。朝右、朝左两个用例各 58 个位移帧，**0 不符**。

## 踩坑记录（本轮新增）

1. **子类 const 遮蔽父类 const 是解析错误**：boss.gd 里写 `const ANIMS` 直接让
   `WuxiaBoss` 全局类解析失败 → 冒烟测试场景加载卡死（引擎只报 "Could not parse global class"）。
   排查手法：`godot --headless --check-only -s scripts/boss.gd` 能看到真实报错行。
2. **编辑器替换时吃掉缩进**：match 分支整体被降一级导致 `Expected an indented block after "match"`。
3. `frames` 数必须等于 `order` 长度（受击只取 3 帧时 frames 也要写 3），越界报
   `Invalid access of index '3' on Array`。
4. 抠底只做「边缘洪泛」不够：**角色姿态会合围出封闭背景**（长杆与两腿之间的三角空隙），
   必须再把「面积 ≥500px 的背景色封闭连通域」一并清除；甲胄高光是小面积中灰，不会误伤。
5. **朝向必须在素材管线里就保证**：动画「倒放」和「角色朝左」会表现出**同一个观感**（都在往后走），
   但根因完全不同——前者改 `order`，后者改逐格镜像。判据用「脚底带重心」而不是「整个人重心」：
   手持斧/刀的一侧会让整体重心偏移，脚底带才稳定。
6. **`--write-movie` 输出路径给 `Godot/preview_facing/` 这类嵌套目录不会自动创建**，
   帧会悄悄丢；给一个已存在的绝对路径（如 `/tmp` 映射的 Windows 路径）才写出。

## 验证

- `godot --headless --import` → 0 错误
- `godot --headless --path . res://tests/smoke_test.tscn` → 181 ok / 0 fail / 退出码 0
- `godot --headless --path . res://tests/preview_facing.tscn` → 58 位移帧 / 0 不符（朝右）
- `godot --headless --path . res://tests/preview_facing.tscn -- --left` → 58 位移帧 / 0 不符（朝左）
- `--write-movie` 抓帧：预览场景（四动画轮播 + 石墙）与主关卡（追击/镜像/贴图/HUD）目检通过；
  修后小怪与 Boss 的斧头/脸/刀**一致朝右**
