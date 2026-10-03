class_name WuxiaGame
extends Node2D

## 侠影录 · 关卡主控
## 职责：程序化搭建关卡、生成玩家 / 敌兵 / 守关 Boss、驱动摄像机与 HUD、编排掉落与拾取。
## 不参与任何战斗数值结算 —— 数值全部由 player.gd / enemy.gd / boss.gd / weapon.gd 负责，
## 这里只做「谁生谁死、死了掉什么、捡到给谁」这一层流程编排。

## HUD 的**布局基准** 960x540（与 project.godot 的 viewport 尺寸一致）。
##
## 注意它不等于「实际视口尺寸」：project.godot 用 stretch/aspect=expand，
## 窗口比 16:9 宽时视口会被**横向撑开**（而不是留黑边），撑开后的尺寸存在 _vp 里。
## 所有 HUD 坐标仍按 VIEW 写死 —— 撑出来的差值由 _apply_ui_anchors() 统一摊开，
## 所以这个常量永远不用跟着窗口改。
const VIEW := Vector2(960, 540)
## 世界内容放大倍率。zoom=2 时 48px 的主角在视口里占 96px、贴图像素密度 4x（窗口 1920），
## 画面比旧 3x 更锐利；相机限位 / 抖屏 / 像素对齐全部仍以世界像素为单位，一律不用改。
const CAMERA_ZOOM := 2.0
const TITLE_SCENE := "res://scenes/title.tscn"

## 场景底图（由 tools/make_background.py 从一张 AI 生成图处理后得到）。
## 贴图存在时，它取代「渐变天空 + 山影/竹影剪影」这套程序化背景；缺失则整体回退，
## 所以就算资源没被编辑器导入，关卡也不会变成一块空白。
const BG_TEXTURE_PATH := "res://assets/backgrounds/courtyard_hall_night.png"
## 地形贴图（由 tools/make_tiles.py 从 AI 生成图处理成可平铺样式）。
## 贴图存在时平台/墙体用它取代纯色多边形；缺失则整体回退，关卡不会白屏。
const GROUND_TILE_PATH := "res://assets/backgrounds/ground_tile.png"
const WALL_TILE_PATH := "res://assets/backgrounds/wall_tile.png"
## 贴图路径下的「顶面亮边」：可落脚的顶面要有可读的亮色信号，压在贴图上沿 4px。
const C_GRASS_TOP := Color("#5d8a4a")
## 地形贴图的压暗调色：AI 原图是为明亮场景画的，夜战关卡里直接用会喧宾夺主。
## 地面压得稍狠一点（面积大），墙体略亮（要靠砖缝读出「这是墙」）。
const TILE_TINT := Color(0.62, 0.66, 0.60)
const WALL_TINT := Color(0.72, 0.76, 0.70)
## 底图横向视差系数。取 0.05：相机整段行程约 1420px，背景一共只滑 71px —— 远景缓慢推移的量级。
## 底图宽度必须 ≥ 480(视口) + BG_MOTION_X * 1420(最大滑移) + 余量，
## 所以改这个系数要同步重跑 tools/make_background.py 的宽度参数，否则关卡两端会露出底图边缘。
const BG_MOTION_X := 0.05
## 相机横向行程的中点，视差以它为原点，底图在关卡两端留下的余量才是对称的。
## = (camera.limit_left + camera.limit_right) / 2 —— 改相机限位必须同步改这里，
## 不然滑移区间就不再对称，一端会比另一端多用掉留量（冒烟测试按这个式子算所需宽度）。
const BG_CAMERA_MID_X := 825.0
## 底图顶边贴着屏幕顶边。竖直方向刻意不参与视差（见 _update_background）：
## 跳跃时远景纹丝不动，也不会在上下露出边缘。
const BG_TOP_Y := 0.0

## 关卡地形：[x, y, w, h]，y 为平台顶面
const PLATFORMS: Array[Rect2] = [
	Rect2(-80, 300, 560, 90),
	Rect2(620, 300, 470, 90),
	Rect2(1090, 300, 620, 90),
	Rect2(160, 232, 120, 14),
	Rect2(340, 172, 110, 14),
	Rect2(640, 214, 130, 14),
	Rect2(840, 148, 120, 14),
	Rect2(1000, 210, 90, 14),
	Rect2(1060, 150, 22, 150),
	Rect2(1230, 202, 170, 14),
	# —— 480~620 竖井的下层石室：掉下去不致死，原地两级石阶就能爬回主层 ——
	# 坑底 = 下面那条「底层岩体」的顶面（390，正好是主地面底边 300 + 90）。
	# 它刻意铺满整关而不只是这一小段：底图是屏幕空间的，镜头往下一沉就会「穿透」到岩体
	# 下方 —— 只在竖井底下垫一小块的话，坑底看起来就是一块悬空的孤岛，四周能看见庭院地面。
	Rect2(-80, 390, 1790, 200),
	# 两级石阶各抬 45px。45 这个数是算出来的，不是抄来的：
	# 单跳高度 = JUMP_FORCE² / (2 × GRAVITY) = 480² / 2800 ≈ 82px，
	# 一级落差只占 55%，连「轻点一下的矮跳」都够，玩家不必动用二段跳。
	# 超过 82px 的话掉下去就再也上不来，等于把这个坑变回无底洞。
	Rect2(532, 345, 88, 45),
	# 最高一级顶面 300 与主地面同高、右边紧贴 620 —— 走上去就是主层，不再有台阶感
	Rect2(572, 300, 48, 45),
	# —— 关卡两端的封边岩壁：把「走出地形就一直往下掉」这条路堵掉 ——
	# 高度是算出来的：一次单跳 + 一次接在顶点的二段跳，实测上限 ≈ 160px
	# （逐帧离散累加，见 smoke_test.gd 的 _max_jump_climb）。这里高出地面 180px，留 20px 余量。
	# 内侧面与主地面的外沿齐平（左 -80 / 右 1710），一直延伸到 590（比相机下界 520 更低），
	# 所以两端不会留下任何能钻出去的缝。想调矮就必须同步确认仍然跳不过去。
	Rect2(-160, 120, 80, 470),
	Rect2(1710, 120, 80, 470),
]

## 关卡内墙（石墙）：[x, 顶 y, 宽, 高]，y 是墙顶面 —— 也就是站上去的那条边。
## 与 PLATFORMS 分家是刻意的：平台是「横向的落脚台面」，墙是「竖向的挡路障碍」，
## 两者的设计约束不同（墙的高度必须卡在跳跃能力之间，平台不用），分开才好在测试里各自断言。
##
## 三条硬约束，全部由冒烟测试从这份数据现算（不抄数字）：
##   ① 每道墙都必须翻得过去：离地高度 ≤ 单跳 + 二段跳的上限（实测 ≈160px）。
##      超了就是把玩家关在墙后面 —— 那不是难度，是软锁，只能按 R 重开。
##   ② 至少两道墙高过单跳（≈86px）：单跳上不去、必须二段跳，墙才是「关卡内容」而不是减速带。
##      玩家有 160px 的攀爬力却只有 86px 的墙可跳，正是「这点墙不够用」的由来。
##   ③ 墙顶宽 ≥ 24px：翻上去要有落脚点，否则越顶即坠落。
## 高度一律从主地面顶面（300）往上量，底面一律扎到 390（主地面底边）—— 底下不留缝。
const WALLS: Array[Rect2] = [
	# 60px：单跳轻松跨过。放在两道高墙之前当节奏，也让「高墙要二段跳」这件事有对照。
	Rect2(880, 240, 26, 150),
	# 120px：单跳 86px 够不着，必须二段跳（余量 40px）。
	Rect2(1150, 180, 30, 210),
	# 130px：全场最高的一道，离二段跳上限 160px 还有 30px 余量。
	# 它同时把守关 Boss（1420）划进了一道石墙围出的场地里 —— Boss 冲不过来，
	# 想打就得先翻墙进去，这正是「守关」该有的样子。
	Rect2(1480, 170, 30, 220),
]

const SPAWNS: Array[Vector2] = [Vector2(300, 298), Vector2(760, 298), Vector2(980, 298), Vector2(1300, 200)]
## 出生即落在主地面顶（y=300），不要留一段「掉进来」的下落 —— 那一小段空中会被
## 空中动画状态机当成跳跃来播，既难看又会让「站着不动=待机」这类断言在落地前误报。
const PLAYER_START := Vector2(60, 300)
const GOAL_POS := Vector2(1640, 300)
## 守关 Boss 守在关门之前：不打倒它，关门不开
const BOSS_SPAWN := Vector2(1420, 298)

## 杂兵死亡掉落能量球的概率。Boss 不掷概率、必掉一颗 ——
## 关卡高潮的成长反馈不该被一次随机数吃掉。
const ORB_DROP_CHANCE := 0.4
## Boss 双掉落（武器 + 能量球）的横向错开距离，免得两件掉落物叠在一处看不清
const BOSS_DROP_SPREAD := 28.0

const C_SKY := Color("#1d2330")
const C_MOUNTAIN := Color("#2c3244")
const C_CLOUD := Color("#3a3646")
const C_ROCK := Color("#24313d")
const C_ROCK_TOP := Color("#38505f")
## 墙体的石缝色：比石身更暗一档，用来画出砌石的层次（见 _make_wall）
const C_ROCK_SEAM := Color("#1a242e")
const C_BAMBOO := Color("#2f4038")
const C_BOSS_BAR := Color("#c0392b")
const C_GOLD := Color("#c9a227")
const C_MUTED := Color("#8b93a1")
## 能量球提示色：取冷色，与暴击/掉落武器的金色 toast 区分开
const C_ORB := Color("#8fd8ff")
## 架势条颜色：充足为青，告急转橙，破防转暗红
const C_GUARD := Color("#6fd0c0")
const C_GUARD_LOW := Color("#e0a03a")
const C_GUARD_BREAK := Color("#a0392f")
## 完美格挡的提示色，与武器金区分（偏亮黄白）
const C_PARRY := Color("#ffe9a0")

## ---------------- 打击反馈（顿帧 / 震屏） ----------------
## player 只上报一个 0..1 的强度，怎么表现由这里决定 ——
## 手感参数集中在这一处，调的时候不用回去翻招式表。
##
## 顿帧时长上限：命中越重停得越久。超过 ~0.1s 会开始像卡顿而不是「卡肉」。
const HITSTOP_MAX := 0.075
## 抖屏最大位移（px）。压得比较小是有意的：camera.offset 叠加在限位之后，
## 抖太狠会在关卡两端露出边界外的空白。
const SHAKE_MAX := 3.0
## 抖屏每秒衰减的创伤值
const TRAUMA_DECAY := 2.2

## 顿帧总开关。整棵树会被暂停，连冒烟测试自己的帧计数一起停 ——
## 因为测试的脚本化时间线是按帧号推进的，一起停才不会错位；但万一以后要用
## Engine.time_scale 之类不冻帧号的方案，得靠这个开关把测试时间线隔离出来。
var hitstop_enabled: bool = true

## 实际视口尺寸（逻辑像素）。expand 模式下它跟着窗口比例走：
## 16:9 窗口时等于 VIEW，窗口更宽时横向变大（多出来的部分就是本该变成黑边的那块）。
## 背景 / 雾 / 结算遮罩这些「要铺满」的东西用它；HUD 用 VIEW + 锚定增量。
var _vp: Vector2 = VIEW
## UI 锚定表（见 _anchor()）。视口尺寸变化时不重建节点、不丢状态，
## 只按 delta 把元素推过去 —— HUD 的血条数值、连击数、toast 全部原地保留。
var _anchors: Array[Dictionary] = []
## 上次装备的武器。视口变化要重排武器面板（它按「贴底往上长」定位，行数依赖武器），
## 而重排函数拿不到信号参数，得自己记一份。
var _weapon_cur: WuxiaWeapon = null
## 屏震创伤值 0..1，幅度取它的平方（见 _update_shake）
var _trauma: float = 0.0
## 正在顿帧。防重入：连续命中不要叠出多个协程各自去恢复暂停
var _frozen: bool = false
## 累计触发过多少次顿帧。留给冒烟测试当可观察量 —— 顿帧会把整棵树暂停，
## 测试自己的 _physics_process 在那几帧压根不执行，「正在暂停」它观察不到，
## 只能靠这个计数器确认代码路径真的走过。
var hitstop_count: int = 0

var _player: WuxiaPlayer
var _camera: Camera2D
## 场景底图节点。为 null 表示走的是程序化背景回退路径（_update_background 会直接返回）。
var _bg_image: Sprite2D
var _boss: WuxiaBoss
var _enemies: Array[WuxiaEnemy] = []
var _defeated: int = 0
var _finished: bool = false
var _rng := RandomNumberGenerator.new()

var _hp_fill: ColorRect
var _hp_text: Label
var _guard_fill: ColorRect
var _guard_hint: Label
var _guard_hint_tween: Tween
var _combo_label: Label
var _kill_label: Label
var _hint_label: Label
var _overlay: ColorRect
var _overlay_label: Label
var _font: SystemFont

var _pickups: Node2D
## 能量球容器。刻意与 _pickups 分家：拾取方式（接触即吸 vs 按拾取键 E）与生命周期都不同，
## 且冒烟测试按 _pickups 的子节点数断言武器掉落，混在一起会互相干扰。
var _orbs: Node2D
var _boss_bar: ColorRect
var _boss_fill: ColorRect
var _boss_label: Label
var _weapon_panel: ColorRect
var _weapon_label: Label
var _bonus_label: Label
var _toast_label: Label
var _toast_tween: Tween

## ---------------- 参考图重排 HUD 的新增部件 ----------------
## 右上角区域名与敌兵计数
var _zone_label: Label
var _enemy_count_label: Label
## 初始敌兵总数（敌人 N/M 的 M）
var _enemy_total: int = 0
## 小地图：深色圆角面板 + 玩家/敌兵/Boss/出口点位。世界坐标线性映射进面板。
var _minimap_panel: Panel
var _minimap_player: ColorRect
var _minimap_exit: ColorRect
var _minimap_boss: ColorRect
var _minimap_enemy_dots: Array[ColorRect] = []
## 底部技能栏：5 槽圆形图标 + 按键名（顺序与输入映射一一对应）
## 总连击数（右下大字）。与 player 的三段连击（combo_changed 的 1..3「式」）不同：
## 这里数的是「这一轮攻势里命中过多少刀」，attacked 逐刀累加、连击窗口超时清零。
var _hit_chain: int = 0
var _hit_chain_max: int = 0

func _ready() -> void:
	# 兜底：上一局若在顿帧中途被切场景，暂停状态会留在树上，新场景一进来就是冻的
	get_tree().paused = false
	_rng.randomize()
	_font = Gfx.cjk_font()
	# 视口尺寸必须在任何 _build_* 之前同步：背景要按它铺满，HUD 要按它定基准位置
	_sync_viewport_size()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_build_background()
	# HUD 必须先建：_spawn_player() 会立刻推送一次血量来初始化血条
	_build_hud()
	_build_level()
	_build_goal()
	_build_pickups()
	_spawn_player()
	_spawn_enemies()
	_spawn_boss()
	_build_camera()

func _process(delta: float) -> void:
	if _camera and is_instance_valid(_player):
		# 取整：相机停在半个像素上时，整个世界的采样点都偏半格 ——
		# 主角那边做了像素对齐也会被它抵消（见 player.gd 的 _pixel_snap_offset）。
		# 代价是镜头变成逐像素移动，但这正是像素风该有的样子，总比整屏发糊好。
		var cam_target: Vector2 = _player.global_position + Vector2(0, -20)
		_camera.global_position = _camera.global_position.lerp(cam_target, 8.0 * delta).round()
		# 视差挂在相机之后算：底图位置永远取自「本帧最终相机位置」，不会慢一帧
		_update_background()
	_update_minimap()
	_update_shake(delta)
	_check_fall_out()

func _exit_tree() -> void:
	# 顿帧期间切场景（R 重开 / Esc 回主界面）时把暂停还回去，否则下一个场景整棵树是冻的
	get_tree().paused = false

# ---------------- 视口自适应 ----------------

## 读一次真实视口尺寸。expand 模式下它 = 「按窗口比例横向展开后的逻辑尺寸」；
## 窗口正好 16:9 时它等于 VIEW —— 此时所有锚定增量都是 0，行为与展开前完全一致。
func _sync_viewport_size() -> void:
	_vp = get_viewport_rect().size

## 视口相对布局基准多出来的部分。贴右 / 居中 / 贴底 / 全宽的元素都要按它补偿。
func _ui_delta() -> Vector2:
	return _vp - VIEW

## 「基准坐标 + 按比例补偿」一次算完。给运行时自行定位的元素用（目前只有武器面板）。
func _ui_shift(baseline: Vector2, dx: float, dy: float) -> Vector2:
	var d := _ui_delta()
	return baseline + Vector2(dx * d.x, dy * d.y)

## 注册一个 HUD 元素进锚定表。
##
## dx / dy 取 0 / 0.5 / 1，含义是「贴左·居中·贴右」「贴上·居中·贴下」。
## 元素在基准视口下的 position/size 会被记下来，视口变化时按 delta 的对应比例整体推移。
## 纯贴上贴左的元素（左上角头像块那一坨、右下之外的所有固定块）不用注册 ——
## 它们的补偿量恒为 0，注册了也只是白跑一遍。
##
## stretch_x / stretch_y：除了位移，宽度 / 高度也跟着补 delta（全宽条、全屏遮罩）。
func _anchor(node: Control, dx: float, dy: float,
		stretch_x: bool = false, stretch_y: bool = false) -> void:
	_anchors.append({
		"node": node, "pos": node.position, "size": node.size,
		"dx": dx, "dy": dy, "sx": stretch_x, "sy": stretch_y,
	})

## 窗口尺寸变化（拖边框 / 切全屏 / 最大化）的统一入口。
## 延后一帧：size_changed 在拖拽时连发，且可能落在渲染回调中间，
## 在回调里直接改一堆 Control 属性容易踩到「正在绘制」的状态。
func _on_viewport_resized() -> void:
	if is_inside_tree():
		_apply_ui_anchors.call_deferred()

## 按锚定表把所有 HUD 摊开，并把铺满类元素对齐到新视口。
func _apply_ui_anchors() -> void:
	_sync_viewport_size()
	_relayout_ui()

## 按 **当前 _vp** 重排。拆成独立函数是为了可测：测试可以直接塞一个「被撑宽的
## 视口尺寸」进来验证锚定数学，不必真的去改窗口大小（无头环境下也改不了）。
## 幂等：每次都从「基准位置 + 当前 delta」重算，连发多少次都不积累误差。
func _relayout_ui() -> void:
	var d := _ui_delta()
	for entry: Dictionary in _anchors:
		var node: Control = entry["node"]
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = entry["pos"]
		node.position = pos + Vector2(float(entry["dx"]) * d.x, float(entry["dy"]) * d.y)
		var size: Vector2 = entry["size"]
		if entry["sx"]:
			size.x += d.x
		if entry["sy"]:
			size.y += d.y
		node.size = size
	# 武器面板按「贴底往上长」定位、高度随行数变化，由 _update_weapon_panel 自己维护，
	# 不在锚定表里（表里存的是构建时的快照，换过武器就不对了），单独重算一次。
	_update_weapon_panel(_weapon_cur)
	_update_background()

# ---------------- 打击反馈 ----------------

## 打击反馈统一入口。强度由 player 给（招式段数 / 暴击 / 挨打），这里翻译成具体表现。
func _on_impact(strength: float) -> void:
	_trauma = minf(_trauma + strength, 1.0)
	_freeze(HITSTOP_MAX * strength)

## 顿帧：把整棵树暂停一小会儿。
##
## 用 get_tree().paused 而不是 Engine.time_scale —— 后者只缩小 delta，帧号照常推进，
## 几十次顿帧会累计出可观的模拟时间偏差，把测试里「第 N 帧玩家应该到这里」那类断言全打散；
## 前者连测试自己的帧计数一起停，脚本化时间线天然保持对齐。观感上也更对：
## 相机跟随、受击压扁、toast 淡出会一起停，正是「整个世界顿一下」。
##
## `create_timer()` 的 `process_always` 必须给 true：暂停期间计时器不走的话，
## 这一等就永远等不到 timeout，整棵树被永久暂停。已在本项目引擎版本上实测通过。
## 万一以后它不灵，症状是「第一次命中就整局卡死」——冒烟测试会直接挂住，很好认。
func _freeze(duration: float) -> void:
	if not hitstop_enabled or _frozen or duration <= 0.0:
		return
	_frozen = true
	hitstop_count += 1
	get_tree().paused = true
	await get_tree().create_timer(duration, true).timeout
	get_tree().paused = false
	_frozen = false

## 屏震写到 camera.offset，**不能写 global_position**：_process() 里那行 lerp 正在写位置，
## 两处都写位置会互相打架（震动会把跟随目标顶掉一帧，远景会抽一下）。
##
## 幅度取创伤值的平方：轻击几乎不动、重击才明显。线性衰减会让每一次小命中都在抖，
## 抖多了就变成背景在晃，反而没有打击感。
func _update_shake(delta: float) -> void:
	if _camera == null:
		return
	_trauma = maxf(_trauma - TRAUMA_DECAY * delta, 0.0)
	var amp: float = SHAKE_MAX * _trauma * _trauma
	if amp <= 0.01:
		# 归零：不然最后一帧的随机偏移会留在画面上，镜头永远差着零点几像素
		_camera.offset = Vector2.ZERO
		return
	# 量化到整数像素：像素对齐之后没有「0.3 像素的抖动」这种东西 —— 亚像素偏移会让整屏
	# 在半格上重采样，一抖就糊。取 max(…, 1) 是为了别把轻击的反馈量化没了：
	# 1 个视口像素在 3 倍窗口下就是 3 个屏幕像素，够看得见。
	var step: float = maxf(roundf(amp), 1.0)
	_camera.offset = Vector2(_rng.randf_range(-step, step), _rng.randf_range(-step, step)).round()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart"):
		get_tree().reload_current_scene()
	elif event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file(TITLE_SCENE)

# ---------------- 关卡 ----------------

func _build_level() -> void:
	var terrain := Node2D.new()
	terrain.name = "Terrain"
	add_child(terrain)
	for r: Rect2 in PLATFORMS:
		_make_platform(terrain, r)
	for w: Rect2 in WALLS:
		_make_wall(terrain, w)

func _make_platform(parent: Node, r: Rect2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = r.position + r.size * 0.5
	parent.add_child(body)

	var rect := RectangleShape2D.new()
	rect.size = r.size
	var shape := CollisionShape2D.new()
	shape.shape = rect
	body.add_child(shape)

	var h: float = r.size.y * 0.5
	var w: float = r.size.x * 0.5
	if _make_tiled_sprite(body, GROUND_TILE_PATH, r.size, TILE_TINT):
		Gfx.make_poly(body, Gfx.rect_poly(-w, -h, w, -h + 4.0), C_GRASS_TOP)
	else:
		Gfx.make_poly(body, Gfx.rect_poly(-w, -h, w, h), C_ROCK)
		Gfx.make_poly(body, Gfx.rect_poly(-w, -h, w, -h + 4.0), C_ROCK_TOP)

## 在静态体上铺一张可平铺贴图。region + REPEAT 让任意尺寸的地形都能整面覆盖；
## 最近邻过滤与全项目像素素材同一套约定。贴图缺失/不可解析时返回 false 走回退。
## tint 用于把 AI 原图的明度压进场景氛围（夜战关卡里原亮度会喧宾夺主）。
func _make_tiled_sprite(parent: Node, path: String, size: Vector2, tint := Color.WHITE) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		return false
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.centered = false
	spr.region_enabled = true
	spr.region_rect = Rect2(Vector2.ZERO, size)
	spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.modulate = tint
	spr.position = Vector2(-size.x * 0.5, -size.y * 0.5)
	parent.add_child(spr)
	return true

## 墙体。碰撞与平台完全一样（都是静态实体），差别只在画面：
## 一块纯色竖条读不出「墙」，加上横向石缝才有砌石的体量感 ——
## 这也是它和「平台」在视觉上唯一的区分，玩法上则由 WALLS / PLATFORMS 两份数据分开管。
func _make_wall(parent: Node, r: Rect2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = r.position + r.size * 0.5
	parent.add_child(body)

	var rect := RectangleShape2D.new()
	rect.size = r.size
	var shape := CollisionShape2D.new()
	shape.shape = rect
	body.add_child(shape)

	var h: float = r.size.y * 0.5
	var w: float = r.size.x * 0.5
	if not _make_tiled_sprite(body, WALL_TILE_PATH, r.size, WALL_TINT):
		Gfx.make_poly(body, Gfx.rect_poly(-w, -h, w, h), C_ROCK)
		Gfx.make_poly(body, Gfx.rect_poly(-w, -h, w, -h + 4.0), C_ROCK_TOP)
		# 石缝自墙顶往下每 22px 一道，收在离底 8px 处（不压到底边，免得跟地面糊成一片）
		var seam: float = -h + 24.0
		while seam < h - 8.0:
			Gfx.make_poly(body, Gfx.rect_poly(-w, seam, w, seam + 2.0), C_ROCK_SEAM)
			seam += 22.0

func _build_goal() -> void:
	var gate := Node2D.new()
	gate.name = "Goal"
	gate.position = GOAL_POS
	add_child(gate)
	Gfx.make_poly(gate, Gfx.rect_poly(-4, -60, 4, 0), Color("#b8352c"), Vector2(-22, 0))
	Gfx.make_poly(gate, Gfx.rect_poly(-4, -60, 4, 0), Color("#b8352c"), Vector2(22, 0))
	Gfx.make_poly(gate, Gfx.rect_poly(-26, -66, 26, -58), Color("#c9a227"))

	var area := Area2D.new()
	area.collision_layer = 0
	area.collision_mask = 2
	var area_shape := CollisionShape2D.new()
	var area_rect := RectangleShape2D.new()
	area_rect.size = Vector2(90, 80)
	area_shape.shape = area_rect
	area_shape.position = Vector2(0, -34)
	area.add_child(area_shape)
	gate.add_child(area)
	area.body_entered.connect(_on_goal_body_entered)

func _build_background() -> void:
	var tex: Texture2D = _load_background_texture()
	if tex != null:
		_build_image_background(tex)
		# 底图本身已经是夜色山门，压一层薄雾只为把玩法层从背景里「抬」出来
		_build_haze(0.12)
	else:
		_build_procedural_background()
		_build_haze(0.28)

## 载入场景底图。资源尚未被编辑器导入（新建项目/CI 首次跑）时返回 null，由调用方回退。
func _load_background_texture() -> Texture2D:
	if not ResourceLoader.exists(BG_TEXTURE_PATH):
		push_warning("场景底图缺失，本次改用程序化背景：%s" % BG_TEXTURE_PATH)
		return null
	var tex: Texture2D = load(BG_TEXTURE_PATH) as Texture2D
	if tex == null:
		push_warning("场景底图无法解析，本次改用程序化背景：%s" % BG_TEXTURE_PATH)
	return tex

## 插画底图当远景：挂在负层 CanvasLayer（屏幕空间），位移由 _update_background() 手算。
## 不用 ParallaxBackground 的原因：它的分层锚点在自己内部，而这张图的要求是
## 「整段相机行程里始终盖满视口」—— 留量必须能直接从 BG_MOTION_X 算出来并对测试可见。
func _build_image_background(tex: Texture2D) -> void:
	var layer := CanvasLayer.new()
	layer.name = "Background"
	layer.layer = -10
	add_child(layer)

	_bg_image = Sprite2D.new()
	_bg_image.name = "ScenePlate"
	_bg_image.texture = tex
	# centered = false：position 即底图左上角，写测试时可以直接换算成屏幕坐标
	_bg_image.centered = false
	_bg_image.position.y = BG_TOP_Y
	# 底图按 1:1 渲染（贴图尺寸 = 屏上尺寸），所以用项目默认的「最近邻」就是最清晰的。
	# 原先单独开线性过滤是为了压住「视差让它长期停在半像素 → 逐帧抖动」；
	# 现在 _update_background() 把位置取整了，成因没了，就不需要靠糊来换稳定。
	_bg_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.add_child(_bg_image)
	_update_background()

func _build_procedural_background() -> void:
	# 天空渐变（最底层）
	var sky_layer := CanvasLayer.new()
	sky_layer.layer = -10
	add_child(sky_layer)

	var grad := Gradient.new()
	grad.colors = PackedColorArray([C_SKY, C_CLOUD, Color("#6b4a44")])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = int(VIEW.x)
	tex.height = int(VIEW.y)
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var bg := TextureRect.new()
	bg.texture = tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.size = VIEW
	sky_layer.add_child(bg)
	# 天空渐变是「铺满」类：跟着视口撑开，否则 expand 出来的右侧会露出一条黑
	_anchor(bg, 0.0, 0.0, true, true)

	# 视差剪影（山影 / 竹影）：独立 canvas 层，位于天空之上、玩法层之下
	var parallax := ParallaxBackground.new()
	parallax.name = "Parallax"
	parallax.layer = -5
	add_child(parallax)
	_add_parallax_strip(parallax, 0.25, -60.0, 250.0, C_MOUNTAIN, 260)
	_add_parallax_strip(parallax, 0.5, 30.0, 320.0, C_BAMBOO, 40)

## 空气透视雾（玩法层之下、背景之上）。底图路径只需要很薄一层，
## 程序化背景是一整片纯色渐变，得压得厚一点才有纵深。
func _build_haze(alpha: float) -> void:
	var haze := CanvasLayer.new()
	haze.layer = -3
	add_child(haze)
	var tint := ColorRect.new()
	tint.color = Color(0.08, 0.06, 0.12, alpha)
	tint.size = VIEW
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	haze.add_child(tint)
	# 雾层同样要铺满：漏一条边就是一条亮缝，比黑边还显眼
	_anchor(tint, 0.0, 0.0, true, true)

## 底图视差：以相机横向行程的中点为原点，按 BG_MOTION_X 跟随。
## 只算 x —— 竖直方向不跟随，跳跃时远景不上下窜，也省掉一份上下留量。
##
## 取的是**自己夹过限位的中心**，不是 `_camera.global_position`：
## Camera2D 的 `limit_*` 只约束「实际取景」，节点坐标照样一路跟着玩家跑
## （实测玩家贴住两端岩壁时 global_position 到了 -74 / 1704，而画面早就被夹住不动了）。
## 拿未夹的坐标算，玩家在关卡两端走动时画面明明停着、底图却还在滑，看起来是背景在飘；
## 而且底图需要的宽度也得按未夹的行程算，会比实际所需更宽。
## 不用 `get_screen_center_position()` 是因为它要等相机内部更新，会慢一帧
## （这个函数刻意紧跟相机之后调用，图的就是同一帧）。
func _update_background() -> void:
	if _bg_image == null or _camera == null or _bg_image.texture == null:
		return
	var half: float = _vp.x * 0.5
	var center_x: float = clampf(
		_camera.global_position.x,
		float(_camera.limit_left) + half,
		float(_camera.limit_right) - half)
	var drift: float = (center_x - BG_CAMERA_MID_X) * BG_MOTION_X
	# 覆盖判定：底图给的是 1080 宽，而 16:9 视口(960) + 两端滑移(±24.25) 只需要 1008.5，
	# 所以常规窗口下留量是够的。但 expand 模式会把视口横向撑开，一旦 need_w 超过底图宽度，
	# 两端就会露出底图边缘（黑条）—— 这里按需做**水平**拉伸顶上。
	# 关键性质：scale 在 16:9 及更窄的窗口下恒为 1，美术构图与设计稿完全一致；
	# 只有视口宽过 1080（比例 > 2:1）才会吃到这点轻微变形，代价远小于黑边。
	var tex_w: float = float(_bg_image.texture.get_width())
	var need_w: float = _vp.x + absf(drift) * 2.0 + 2.0
	var stretch: float = maxf(1.0, need_w / tex_w)
	_bg_image.scale = Vector2(stretch, 1.0)
	# 取整：视差系数 0.05 会把整数相机坐标又算回小数，底图 1:1 渲染时停在半像素就是糊的。
	# 代价是视差从「亚像素滑移」变成逐像素步进 —— 0.05 的系数下本来就是缓慢推移，看不出来。
	_bg_image.position.x = roundf(half - tex_w * stretch * 0.5 - drift)

## 生成一条可循环的视差剪影带
func _add_parallax_strip(parent: ParallaxBackground, scale_x: float, y: float, height: float, color: Color, step: int) -> void:
	var pl := ParallaxLayer.new()
	pl.motion_scale = Vector2(scale_x, 0.0)
	# 按**实际视口**的两倍铺剪影：expand 撑宽后如果还按基准 960 生成，右侧会缺一段剪影。
	# （底图存在时走不到这条回退路径，这里只保证缺贴图时也不露白。）
	pl.motion_mirroring = Vector2(_vp.x * 2.0, 0.0)
	parent.add_child(pl)
	var strip := Node2D.new()
	strip.position = Vector2(0, y)
	pl.add_child(strip)
	var x := -40
	while x < int(_vp.x * 2.0) + 80:
		var h: float = height * (0.6 + 0.4 * absf(sin(float(x) * 0.017)))
		Gfx.make_poly(strip, PackedVector2Array([
			Vector2(float(x), height), Vector2(float(x + step / 2), height - h),
			Vector2(float(x + step), height), Vector2(float(x + step), height + 200.0), Vector2(float(x), height + 200.0),
		]), color)
		x += step

# ---------------- 角色 ----------------

func _spawn_player() -> void:
	_player = WuxiaPlayer.new()
	_player.name = "Player"
	add_child(_player)
	_player.global_position = PLAYER_START
	_player.health_changed.connect(_on_health_changed)
	_player.combo_changed.connect(_on_combo_changed)
	_player.attacked.connect(_on_player_attacked)
	_player.crit_landed.connect(_on_crit_landed)
	_player.impact.connect(_on_impact)
	_player.died.connect(_on_player_died)
	_player.guard_changed.connect(_on_guard_changed)
	_player.parried.connect(_on_parried)
	_player.guard_broken.connect(_on_guard_broken)
	_on_health_changed(_player.max_health, _player.max_health)
	_on_guard_changed(_player.guard_value(), WuxiaPlayer.GUARD_MAX)

func _build_pickups() -> void:
	_pickups = Node2D.new()
	_pickups.name = "Pickups"
	add_child(_pickups)

	_orbs = Node2D.new()
	_orbs.name = "Orbs"
	add_child(_orbs)

func _spawn_enemies() -> void:
	var holder := Node2D.new()
	holder.name = "Enemies"
	add_child(holder)
	for p: Vector2 in SPAWNS:
		var e := WuxiaEnemy.new()
		# 先摆坐标再进树：enemy._ready() 会据此记录巡逻原点 _origin_x。
		# 若在 add_child 之后才设位置，原点会停在 0，敌兵会一路走到平台边缘发呆。
		e.position = p
		holder.add_child(e)
		e.died.connect(_on_enemy_died.bind(e))
		_enemies.append(e)
	_enemy_total = _enemies.size()
	_refresh_enemy_count()

## 守关 Boss。数值与行为在 boss.gd 里，这里只负责「放哪、连什么信号」。
func _spawn_boss() -> void:
	_boss = WuxiaBoss.new()
	_boss.name = "Boss"
	_boss.position = BOSS_SPAWN
	add_child(_boss)
	_boss.health_changed.connect(_on_boss_health_changed)
	_boss.died.connect(_on_boss_died)
	# 血条的首次初始化：_ready() 里那次 emit 发生在 connect 之前，接不到
	_on_boss_health_changed(_boss.max_health, _boss.max_health)

func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.position_smoothing_enabled = false
	# 视口翻倍到 960x540 后用 zoom 把可视世界范围压回 480x270：
	# HUD 获得 2 倍布局空间，世界内容保持原有屏幕占比（见 CAMERA_ZOOM 注释）。
	_camera.zoom = Vector2(CAMERA_ZOOM, CAMERA_ZOOM)
	# 横向限位要**把两端岩壁留在画面内**：岩壁内侧面在 -80 / 1710，
	# 相机边缘正好压在 -80 时那道壁会整根落在画面外，看起来像撞了空气墙。
	# 各往外放 60px（-140 / 1790），玩家贴住岩壁时能看见 60px 宽的岩柱。
	_camera.limit_left = -140
	_camera.limit_right = 1790
	_camera.limit_top = -200
	# 下界必须能容下竖井的下层石室（坑底 390 + 角色高度），否则玩家掉到坑底时
	# 镜头会被夹在主层高度上，人掉出画面外看不见。
	# 相机中心受限于 [limit_top + 135, limit_bottom - 135]，520 - 135 = 385 > 坑底取景所需的 370，
	# 所以站上坑底时不会被限位夹住。主层正常游玩时相机中心在 280，仍在旧范围内 —— 这段下界
	# 只在下井时才起作用，不影响原有取景。
	_camera.limit_bottom = 520
	add_child(_camera)
	_camera.global_position = _player.global_position
	_camera.make_current()

# ---------------- HUD ----------------

## HUD 按参考图（横版动作 + 武侠夜战）重排，全部在 960x540 屏幕空间：
##   左上 头像 + 名字 + 血条/架势条 · 左下 武器面板/加成
##   右上 区域名 + 敌兵计数 + 小地图      · 右下 连击大字
##   底部中央 5 槽技能栏（J/K/L/Shift/Space 恰好是现有输入映射）
##   顶部中央 Boss 血条；中部 toast / 格挡提示 / 结算遮罩
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)

	_build_avatar_block(layer)
	_build_zone_block(layer)
	_build_skill_bar(layer)
	_build_guard_bar_hint(layer)
	_build_boss_bar(layer)
	_build_weapon_panel(layer)

	# 永久加成面板：贴在武器面板上方，同列左对齐；一条加成都没有时整行留空
	_bonus_label = _make_label(layer, Vector2(14, 434), 12, C_ORB)
	_bonus_label.text = ""

	# 右下连击大字：参考图的「N 连击！」。_hit_chain 由 attacked 信号逐刀累加，
	# 连击窗口（COMBO_WINDOW）超时后随 combo_changed(0) 一起清零。
	_combo_label = _make_label(layer, Vector2(VIEW.x - 340.0, VIEW.y - 116.0), 30, C_GOLD)
	_combo_label.size = Vector2(326, 44)
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# 贴右下：视口横向撑开时跟着右边缘走，纵向撑开时跟着下边缘走
	_anchor(_combo_label, 1.0, 1.0)

	_kill_label = _make_label(layer, Vector2(14, 90), 12, Color("#9fb0a8"))
	_kill_label.text = "已斩 0 人"

	_hint_label = _make_label(layer, Vector2(VIEW.x - 330.0, VIEW.y - 26.0), 10, C_MUTED)
	_hint_label.size = Vector2(316, 16)
	_anchor(_hint_label, 1.0, 1.0)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint_label.text = "E 拾取 · R 重来 · Esc 菜单"

	# 顶部瞬时提示：暴击 / 掉落 / 关门未开，同一时刻只显示最后一条
	_toast_label = _make_label(layer, Vector2(0, 96), 14, C_GOLD)
	_toast_label.size = Vector2(VIEW.x, 20)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.modulate.a = 0.0
	# 整条横贯屏幕：贴左不动 + 宽度跟着补 delta
	_anchor(_toast_label, 0.0, 0.0, true)

	_overlay = ColorRect.new()
	_overlay.color = Color(0.04, 0.02, 0.06, 0.0)
	_overlay.size = VIEW
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_overlay)
	# 结算遮罩必须盖满整个视口（含撑开的部分），否则关底会露出一条画面
	_anchor(_overlay, 0.0, 0.0, true, true)

	_overlay_label = _make_label(layer, Vector2(0, VIEW.y * 0.5 - 40.0), 22, Color("#f0d9a8"))
	_overlay_label.size = Vector2(VIEW.x, 40)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_label.text = ""
	_anchor(_overlay_label, 0.0, 0.5, true)

## 左上头像块：金环头像 + 名字 + 血条（带数值）+ 架势条。
## 血条 / 架势条宽度统一 180（见 _on_health_changed / _on_guard_changed 的同步约束）。
func _build_avatar_block(layer: CanvasLayer) -> void:
	# 金环底座：StyleBoxFlat 圆角拉满即为圆。头像贴图缺失时它独自承担「这是头像位」。
	var ring := Panel.new()
	ring.position = Vector2(14, 14)
	ring.size = Vector2(72, 72)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ring_style := StyleBoxFlat.new()
	ring_style.bg_color = Color(0.09, 0.08, 0.13, 0.85)
	ring_style.border_color = C_GOLD
	ring_style.set_border_width_all(2)
	ring_style.set_corner_radius_all(36)
	ring.add_theme_stylebox_override("panel", ring_style)
	layer.add_child(ring)

	var avatar_path := "res://assets/ui/avatar.png"
	if ResourceLoader.exists(avatar_path):
		var avatar := TextureRect.new()
		avatar.texture = load(avatar_path) as Texture2D
		avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		avatar.stretch_mode = TextureRect.STRETCH_SCALE
		avatar.position = Vector2(18, 18)
		avatar.size = Vector2(64, 64)
		avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(avatar)
	else:
		# 贴图没导出（新克隆仓库）时的兜底：一个「侠」字占位，头像位不至于空白
		var placeholder := _make_label(layer, Vector2(14, 34), 26, C_GOLD)
		placeholder.size = Vector2(72, 40)
		placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder.text = "侠"

	var name_label := _make_label(layer, Vector2(98, 16), 18, C_GOLD)
	name_label.text = "侠客"

	var hp_bg := ColorRect.new()
	hp_bg.color = Color(0.06, 0.05, 0.08, 0.7)
	hp_bg.position = Vector2(98, 42)
	hp_bg.size = Vector2(184, 16)
	hp_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hp_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color = Color("#d4453a")
	_hp_fill.position = Vector2(100, 44)
	_hp_fill.size = Vector2(180, 12)
	layer.add_child(_hp_fill)

	_hp_text = _make_label(layer, Vector2(98, 42), 11, Color("#f2ece0"))
	_hp_text.size = Vector2(184, 16)
	_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var guard_bg := ColorRect.new()
	guard_bg.color = Color(0.06, 0.05, 0.08, 0.7)
	guard_bg.position = Vector2(98, 62)
	guard_bg.size = Vector2(184, 9)
	guard_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(guard_bg)

	_guard_fill = ColorRect.new()
	_guard_fill.color = C_GUARD
	_guard_fill.position = Vector2(100, 64)
	_guard_fill.size = Vector2(180, 5)
	layer.add_child(_guard_fill)

## 右上区域块：区域名 + 敌兵计数 + 小地图。
## 小地图把世界 x ∈ [相机 limit_left, limit_right]、y ∈ [80, 520] 线性映射进 140x84 面板；
## 点位在 _process 里逐帧重算（见 _update_minimap），敌人死后点位自动回收。
func _build_zone_block(layer: CanvasLayer) -> void:
	_zone_label = _make_label(layer, Vector2(VIEW.x - 352.0, 14), 18, C_GOLD)
	_zone_label.size = Vector2(192, 26)
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_zone_label.text = "夜袭 · 山门庭院"
	_anchor(_zone_label, 1.0, 0.0)

	_enemy_count_label = _make_label(layer, Vector2(VIEW.x - 352.0, 44), 13, Color("#e8e0d0"))
	_enemy_count_label.size = Vector2(192, 18)
	_enemy_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_enemy_count_label.text = "敌人"
	_anchor(_enemy_count_label, 1.0, 0.0)

	var map_style := StyleBoxFlat.new()
	map_style.bg_color = Color(0.05, 0.05, 0.1, 0.72)
	map_style.border_color = Color("#cfd8dc")
	map_style.set_border_width_all(1)
	map_style.set_corner_radius_all(6)
	_minimap_panel = Panel.new()
	_minimap_panel.position = Vector2(VIEW.x - 152.0, 14)
	_minimap_panel.size = Vector2(140, 84)
	_minimap_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap_panel.add_theme_stylebox_override("panel", map_style)
	layer.add_child(_minimap_panel)
	# 面板内的点位是**面板内坐标**（见 _minimap_pos），随面板一起走，不用单独锚定
	_anchor(_minimap_panel, 1.0, 0.0)

	# 点位先建满池子，_update_minimap 每帧按存活敌兵重排显示（池子大小 = 初始敌兵数）。
	# 点位挂面板下：position 直接用面板内坐标，跟随面板移动，不用手动加偏移。
	for i: int in SPAWNS.size():
		var dot := ColorRect.new()
		dot.color = Color("#e05050")
		dot.size = Vector2(5, 5)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_minimap_panel.add_child(dot)
		_minimap_enemy_dots.append(dot)

	_minimap_boss = _make_minimap_dot(_minimap_panel, Color("#ff3030"), Vector2(7, 7))
	_minimap_exit = _make_minimap_dot(_minimap_panel, Color("#7fe08a"), Vector2(6, 6))
	_minimap_player = _make_minimap_dot(_minimap_panel, Color("#8fd8ff"), Vector2(6, 6))
	_refresh_enemy_count()

## 小地图上一个点位。挂在面板下（position 即面板内坐标），z 序按加入顺序自然盖在面板上。
func _make_minimap_dot(parent: Node, color: Color, dot_size: Vector2) -> ColorRect:
	var dot := ColorRect.new()
	dot.color = color
	dot.size = dot_size
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(dot)
	return dot

## 底部技能栏：5 槽圆形图标（贴图由 tools/make_ui_assets.py 从 AI 生成图处理而来）。
## 槽序与输入映射一一对应 —— 玩家读按键名就能对上操作，不再需要旧版那行长提示。
func _build_skill_bar(layer: CanvasLayer) -> void:
	const SLOT := 68.0
	const GAP := 16.0
	const ICON := 64.0
	var skills: Array[Dictionary] = [
		{"icon": "res://assets/ui/skill_attack.png", "key": "J", "skill": "普通攻击"},
		{"icon": "res://assets/ui/skill_evade.png", "key": "K", "skill": "闪避"},
		{"icon": "res://assets/ui/skill_guard.png", "key": "L", "skill": "格挡"},
		{"icon": "res://assets/ui/skill_dash.png", "key": "Shift", "skill": "轻功"},
		{"icon": "res://assets/ui/skill_jump.png", "key": "Space", "skill": "跳跃"},
	]
	var total_w: float = float(skills.size()) * SLOT + float(skills.size() - 1) * GAP
	var start_x: float = (VIEW.x - total_w) * 0.5
	var slot_style := StyleBoxFlat.new()
	slot_style.bg_color = Color(0.07, 0.09, 0.16, 0.78)
	slot_style.border_color = Color("#c9a227")
	slot_style.set_border_width_all(1)
	slot_style.set_corner_radius_all(34)
	for i: int in skills.size():
		var cfg: Dictionary = skills[i]
		var slot_x: float = start_x + float(i) * (SLOT + GAP)
		var slot := Panel.new()
		slot.position = Vector2(slot_x, 418)
		slot.size = Vector2(SLOT, SLOT)
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_theme_stylebox_override("panel", slot_style)
		layer.add_child(slot)
		_anchor(slot, 0.5, 0.0)

		var name_label := _make_label(layer, Vector2(slot_x, 400), 10, Color("#cfd8dc"))
		name_label.size = Vector2(SLOT, 14)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.text = cfg["skill"]
		_anchor(name_label, 0.5, 0.0)

		if ResourceLoader.exists(cfg["icon"]):
			var icon := TextureRect.new()
			icon.texture = load(cfg["icon"]) as Texture2D
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_SCALE
			icon.position = Vector2(slot_x + (SLOT - ICON) * 0.5, 420)
			icon.size = Vector2(ICON, ICON)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			layer.add_child(icon)
			_anchor(icon, 0.5, 0.0)

		var key_label := _make_label(layer, Vector2(slot_x, 490), 12, Color("#f2ece0"))
		key_label.size = Vector2(SLOT, 16)
		key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_label.text = cfg["key"]
		_anchor(key_label, 0.5, 0.0)

## 玩家受击 / 格挡 / 破防的即时提示。与 toast 分开：
## toast 服务于「掉落 / 暴击」这类正向事件，格挡反馈是高频战斗信息，
## 混在一起会被掉落提示顶掉。
func _build_guard_bar_hint(layer: CanvasLayer) -> void:
	_guard_hint = _make_label(layer, Vector2(0, 170), 16, C_PARRY)
	_guard_hint.size = Vector2(VIEW.x, 24)
	_guard_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_guard_hint.modulate.a = 0.0
	_anchor(_guard_hint, 0.0, 0.0, true)

## Boss 血条：顶部居中（左上是头像块、右上是区域块，中间留给它）。
## 只服务于「守关 Boss」这一个目标，不做通用血条系统。
func _build_boss_bar(layer: CanvasLayer) -> void:
	_boss_label = _make_label(layer, Vector2(0, 10), 12, Color("#e8b0a0"))
	_boss_label.size = Vector2(VIEW.x, 18)
	_boss_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_anchor(_boss_label, 0.0, 0.0, true)

	_boss_bar = ColorRect.new()
	_boss_bar.color = Color(0.06, 0.05, 0.08, 0.6)
	_boss_bar.position = Vector2(VIEW.x * 0.5 - 110.0, 32)
	_boss_bar.size = Vector2(220, 11)
	layer.add_child(_boss_bar)
	_anchor(_boss_bar, 0.5, 0.0)

	_boss_fill = ColorRect.new()
	_boss_fill.color = C_BOSS_BAR
	_boss_fill.position = Vector2(VIEW.x * 0.5 - 109.0, 33)
	_boss_fill.size = Vector2(218, 9)
	layer.add_child(_boss_fill)
	_anchor(_boss_fill, 0.5, 0.0)

## 武器面板：贴着左下角往上长（右下角让给连击大字），行数随副词条条数变化。
func _build_weapon_panel(layer: CanvasLayer) -> void:
	_weapon_panel = ColorRect.new()
	_weapon_panel.color = Color(0.06, 0.05, 0.08, 0.5)
	_weapon_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_weapon_panel)

	_weapon_label = _make_label(layer, Vector2.ZERO, 11, C_GOLD)
	_weapon_label.size = Vector2(252, 22)
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_update_weapon_panel(null)

func _make_label(parent: Node, pos: Vector2, size: int, color: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(l)
	return l

# ---------------- 事件 ----------------

func _on_health_changed(current: int, maximum: int) -> void:
	var ratio: float = 0.0 if maximum == 0 else float(current) / float(maximum)
	# 宽度 180 与 _build_avatar_block 的血条尺寸硬性约定 —— 那边改宽这里必须跟着改
	_hp_fill.size.x = maxf(180.0 * ratio, 0.0)
	_hp_fill.color = Color("#d4453a") if ratio > 0.3 else Color("#e0603a")
	_hp_text.text = "%d / %d" % [current, maximum]

func _on_combo_changed(step: int) -> void:
	# combo_changed 的 step 是「三段连击的第几式」（起手 1..3、窗口过期 0）。
	# 右下大字显示的是 _hit_chain（这一轮攻势总共命中几刀），这里只负责清零时机；
	# 累加在 _on_player_attacked（每段判定帧一刀）。
	if step == 0:
		_hit_chain = 0
		_refresh_combo_label()

## 每一刀命中（判定帧）累计总连击。参考图右下角的「N 连击」就是它。
func _on_player_attacked(_step: int) -> void:
	_hit_chain += 1
	_hit_chain_max = maxi(_hit_chain_max, _hit_chain)
	_refresh_combo_label()

func _refresh_combo_label() -> void:
	if _hit_chain >= 2:
		_combo_label.text = "%d 连击" % _hit_chain
	else:
		_combo_label.text = ""

# ---------------- 防御（架势 / 完美格挡 / 破防） ----------------

## 架势条刷新。颜色分三档：充足 / 告急（低于 1/3）/ 破防。
## 破防状态优先显示为暗红 —— 此时的最重要信息是「现在举不起盾」，而不是还剩多少。
## 宽度 180 与 _build_avatar_block 的架势条尺寸硬性约定。
func _on_guard_changed(value: float, maximum: float) -> void:
	var ratio: float = 0.0 if maximum <= 0.0 else clampf(value / maximum, 0.0, 1.0)
	_guard_fill.size.x = maxf(180.0 * ratio, 0.0)
	if is_instance_valid(_player) and _player.is_guard_broken():
		_guard_fill.color = C_GUARD_BREAK
	else:
		_guard_fill.color = C_GUARD_LOW if ratio <= 0.34 else C_GUARD

func _on_parried() -> void:
	_show_guard_hint("完美格挡！", C_PARRY)
	# 完美格挡的反馈刻意与「打中敌人」同量级：它是最值得奖励的操作，不能只有一条小字
	_on_impact(0.6)

func _on_guard_broken() -> void:
	_show_guard_hint("架势崩了 · 举不起盾", C_GUARD_BREAK)
	_on_impact(0.7)

## 格挡提示：复用同一个 Label，新提示会顶掉旧的（战斗里同一时刻只该读一条）。
func _show_guard_hint(text: String, color: Color) -> void:
	if _guard_hint == null:
		return
	_guard_hint.text = text
	_guard_hint.add_theme_color_override("font_color", color)
	_guard_hint.modulate.a = 1.0
	if _guard_hint_tween != null and _guard_hint_tween.is_valid():
		_guard_hint_tween.kill()
	_guard_hint_tween = create_tween()
	_guard_hint_tween.tween_interval(0.35)
	_guard_hint_tween.tween_property(_guard_hint, "modulate:a", 0.0, 0.35)

## ---------------- 掉落兜底（防关卡死局） ----------------

## 掉到这条线以下就认为「 fell出关卡」。
## 底部岩体 Rect2(-80, 390, 1790, 200) 覆盖到 y=590，但**敌兵会被击退到岩体横向之外**
## （x < -80 或 x > 1710），那里没有地面托着，它会一路坠到无限远。
## 玩家在那种 x 上同样会掉 —— 只是掉得慢一些。
const FALL_KILL_Y := 720.0
## 玩家掉出关卡时回到的坐标（出生点）。
const RESPAWN_POS := PLAYER_START


## 逐帧检查玩家与全部敌兵有没有掉出关卡。
##
## 为什么必须有：掉出去的实体**玩家打不到**（攻击判定只覆盖相机附近），
## 于是「敌人 N/M」永远降不下来，Boss 死不掉、关门不开 —— 整局变成死局，
## 只能按 R 重开。这是**功能性缺陷**，不是画面瑕疵。
##
## 数据源用**group 而不是 _enemies 数组**：group 由 enemy._ready() 自己注册，
## 是「场上活着的敌兵」的唯一真相源。_enemies 数组只用于 died 时erase，
## 若实体因任何原因没进数组（中途生成、异常顺序），这里就会漏掉它 ——
## 而漏掉的后果是死局，所以宁可多遍历一次 group。
func _check_fall_out() -> void:
	if _player != null and is_instance_valid(_player) and _player.is_alive():
		if _player.global_position.y > FALL_KILL_Y:
			_respawn_player()
	for node: Node in get_tree().get_nodes_in_group("enemy"):
		var e: WuxiaEnemy = node as WuxiaEnemy
		if e == null or not is_instance_valid(e) or e.is_dead():
			continue
		if e.global_position.y > FALL_KILL_Y:
			# 不算击杀（不涨「已斩」计数、不给掉落），只是把走失的敌人送回它
			# 自己的出生点 —— 它本来就属于那里，掉出去纯属意外。
			e.respawn_at_origin()


## 玩家掉出关卡：原地拉回出生点。不算死亡（不触发 died、不扣存档进度）——
## 掉出关卡是关卡设计失误的兜底，不是玩家的战斗失败。
func _respawn_player() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_player.global_position = RESPAWN_POS
	_player.velocity = Vector2.ZERO
	# 硬直清零：带着击退速度重生会立刻又被弹出去。
	# 这两个计时器是 player.gd 的私有字段，用 set 写——跨类访问私有状态本该走公开方法，
	# 但这里是「关卡级复位」，语义上就该由关卡主导，且 player 没有对应的 reset API。
	_player.set("_invuln", 1.0)
	_player.set("_dash_timer", 0.0)
	_player.set("_evade_timer", 0.0)
	_show_toast("掉出关卡 · 已送回起点", C_GOLD)
	if _camera != null:
		_camera.global_position = _player.global_position + Vector2(0, -20)


func _on_enemy_died(enemy: WuxiaEnemy) -> void:
	_enemies.erase(enemy)
	_defeated += 1
	_kill_label.text = "已斩 %d 人" % _defeated
	_refresh_enemy_count()
	# died 是「先广播、后播消散动画」，所以此刻敌兵坐标仍然有效
	if _rng.randf() < ORB_DROP_CHANCE:
		_spawn_energy_orb(enemy.global_position)

## 右上角敌兵计数（敌人 N/M）。Boss 不计入 —— 它有自己的血条。
func _refresh_enemy_count() -> void:
	_enemy_count_label.text = "敌人  %d / %d" % [_enemies.size(), _enemy_total]

## 世界坐标 → 小地图面板内坐标。x 取相机横向限位全程，y 覆盖主层到坑底的取景范围。
func _minimap_pos(world: Vector2) -> Vector2:
	var cam: Camera2D = _camera
	var left: float = float(cam.limit_left) if cam != null else -140.0
	var right: float = float(cam.limit_right) if cam != null else 1790.0
	var x: float = clampf(
		inverse_lerp(left, right, world.x) * 128.0 + 6.0, 6.0, 128.0)
	var y: float = clampf(
		inverse_lerp(80.0, 520.0, world.y) * 66.0 + 9.0, 9.0, 75.0)
	return Vector2(x, y)

## 小地图逐帧刷新：玩家 / 出口 / Boss 常驻点位 + 存活敌兵点位。
## 敌兵点位不与具体敌人绑定 —— _enemies 死亡时会 erase 破坏索引对应，
## 每帧「先把池子全部藏起来、再按存活列表重排」是最不会错的同步方式。
func _update_minimap() -> void:
	if _minimap_player == null or _camera == null:
		return
	_minimap_player.position = _minimap_pos(_player.global_position)
	_minimap_exit.position = _minimap_pos(GOAL_POS)
	_minimap_boss.visible = _boss != null and is_instance_valid(_boss)
	if _minimap_boss.visible:
		_minimap_boss.position = _minimap_pos(_boss.global_position)
	for i: int in _minimap_enemy_dots.size():
		var dot: ColorRect = _minimap_enemy_dots[i]
		if i < _enemies.size():
			dot.visible = true
			dot.position = _minimap_pos(_enemies[i].global_position)
		else:
			dot.visible = false

func _on_player_died() -> void:
	_hit_chain = 0
	_refresh_combo_label()
	_show_overlay("侠客陨落 · R 重来 · Esc 主界面", Color(0.55, 0.0, 0.0, 0.45))

func _on_goal_body_entered(body: Node2D) -> void:
	if _finished or body != _player:
		return
	# 守关 Boss 没倒，关门不开：否则玩家可以直接冲刺溜过去，Boss 就成了摆设
	if is_instance_valid(_boss):
		_show_toast("关门未开 · 先斩守关 Boss", Color("#e0603a"))
		return
	_finished = true
	_show_overlay("出关 · 已斩 %d 人 · R 重来 · Esc 主界面" % _defeated, Color(0.9, 0.7, 0.25, 0.25))

func _show_overlay(text: String, color: Color) -> void:
	_overlay_label.text = text
	var tween := create_tween()
	tween.tween_property(_overlay, "color", color, 0.3)

# ---------------- Boss 与掉落 ----------------

func _on_boss_health_changed(current: int, maximum: int) -> void:
	var ratio: float = 0.0 if maximum == 0 else float(current) / float(maximum)
	_boss_fill.size.x = maxf(218.0 * ratio, 0.0)
	_boss_label.text = "守关 Boss · 铁面刀客    %d / %d" % [current, maximum]

func _on_boss_died() -> void:
	# _die() 里先 emit 再播放消散动画，所以此刻还能取到 Boss 的倒下坐标
	var drop_at: Vector2 = _boss.global_position if is_instance_valid(_boss) else BOSS_SPAWN
	_boss = null
	_defeated += 1
	_kill_label.text = "已斩 %d 人" % _defeated
	_boss_bar.visible = false
	_boss_fill.visible = false
	_boss_label.text = "守关 Boss 已斩 · 关门已开"
	_spawn_weapon_drop(drop_at)
	_spawn_energy_orb(Vector2(drop_at.x - BOSS_DROP_SPREAD, drop_at.y))

## 掉落一把随机武器。掉落物的词条在 weapon.gd 里掷，这里只决定「掉在哪」。
func _spawn_weapon_drop(at: Vector2) -> void:
	var drop := WuxiaWeaponDrop.new()
	drop.weapon = WuxiaWeapon.roll(_rng)
	drop.position = Vector2(at.x, at.y - 6.0)
	_pickups.add_child(drop)
	drop.picked_up.connect(_on_weapon_picked_up)

## 掉一颗能量球。掉哪条属性、加多少在 energy_orb.gd 里掷，这里只决定「掉在哪」。
## 位置必须先设再 add_child：orb._ready() 会立刻据 stat / value 建外观与浮字。
func _spawn_energy_orb(at: Vector2) -> void:
	var orb: WuxiaEnergyOrb = WuxiaEnergyOrb.roll(_rng)
	orb.position = Vector2(at.x, at.y - 10.0)
	_orbs.add_child(orb)
	orb.collected.connect(_on_orb_collected)

func _on_orb_collected(stat: int, value: float) -> void:
	if is_instance_valid(_player):
		_player.apply_bonus(stat, value)
	_show_toast("能量球 · %s" % WuxiaWeapon.format_stat(stat, value), C_ORB)
	_update_bonus_panel()

func _on_weapon_picked_up(weapon: WuxiaWeapon) -> void:
	if is_instance_valid(_player):
		_player.equip_weapon(weapon)
	_update_weapon_panel(weapon)
	_show_toast("获得 %s · 已装备" % weapon.title(), weapon.quality_color())

# ---------------- HUD 刷新 ----------------

## 面板贴着左下角往上长：行数 = 1 行标题 + N 行副词条，副词条多则面板高。
## LINE_H 取 20 而不是字号 11：Label 的最小高度按字体行高走，估算偏小会让最后一行漏出面板。
func _update_weapon_panel(weapon: WuxiaWeapon) -> void:
	const PANEL_W := 260.0
	const BOTTOM := 526.0
	const LINE_H := 20.0
	var lines: int = 1 if weapon == null else 1 + weapon.substats.size()
	var height: float = 8.0 + float(lines) * LINE_H
	# 记一份当前武器：视口变化时 _apply_ui_anchors() 要靠它重算面板高度
	_weapon_cur = weapon
	# 贴左下往上长：x 固定，y 从「基准底边往上」量，所以要补满 delta.y
	_weapon_panel.position = _ui_shift(Vector2(12.0, BOTTOM - height), 0.0, 1.0)
	_weapon_panel.size = Vector2(PANEL_W, height)
	_weapon_label.position = _ui_shift(Vector2(18.0, BOTTOM - height + 4.0), 0.0, 1.0)
	_weapon_label.size = Vector2(PANEL_W - 10.0, height - 8.0)
	if weapon == null:
		_weapon_label.add_theme_color_override("font_color", C_MUTED)
		_weapon_label.text = "武器  未装备"
	else:
		_weapon_label.add_theme_color_override("font_color", weapon.quality_color())
		_weapon_label.text = weapon.describe()

func _on_crit_landed(amount: int) -> void:
	_show_toast("暴击 · %d 伤害" % amount, C_GOLD)

## 永久加成面板：只列出已经吃到过的属性，一条都没有时整行留空。
## 遍历 STAT_NAME 的全部键（而不是某个随机掉落池）：这里展示的是「已经吃到的加成」，
## 不该因为掉落池以后改了条目，就把玩家已有的加成从界面上弄丢。
func _update_bonus_panel() -> void:
	if not is_instance_valid(_player):
		return
	var parts: PackedStringArray = []
	for key: Variant in WuxiaWeapon.STAT_NAME.keys():
		var stat: int = int(key)
		var total: float = _player.permanent_bonus(stat)
		if total > 0.0:
			parts.append(WuxiaWeapon.format_stat(stat, total))
	_bonus_label.text = "" if parts.is_empty() else "能量球 · %s" % " ".join(parts)

func _show_toast(text: String, color: Color) -> void:
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	_toast_label.modulate.a = 1.0
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(0.6)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)
