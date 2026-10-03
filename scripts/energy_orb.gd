class_name WuxiaEnergyOrb
extends Area2D

## 侠影录 · 能量球
##
## 单一职责：把「一条永久属性加成」摆在地上，玩家靠近时飞过去被吸取，并广播 collected。
## 刻意不直接改玩家属性 —— 加成存在哪一层、换武器时怎么保住，是 player.gd 的事；
## 能量球只负责「掉在哪、长什么样、什么时候被吸走」。
##
## 属性枚举复用 WuxiaWeapon.Stat：能量球与武器词条属于同一套属性体系，
## 另立一套平行枚举只会让 player._recalc_stats() 里长出两套分支。
##
## 与武器掉落物（weapon_drop.gd）的两点刻意差异：
##   1. 不需要按拾取键 —— 靠近即被磁吸进来。永久成长要的是高频正反馈，不该再压一次按键；
##   2. 挂在 game 的 Orbs 容器下，与武器掉落物分家 —— 两者拾取方式与生命周期都不同。
##
## 两级半径（关键设计）：
##   PICKUP_RADIUS(16) —— 真正的拾取判定，碰到才算到手；
##   MAGNET_RADIUS(64) —— 纯激活圈，玩家一进来就开磁吸，把球拉进拾取圈里。
## 分成两个 Area2D 而不是把拾取圈直接放大：放大拾取圈会让「隔着半个身位就凭空吸走」
## 看起来像判定作弊，而两级半径的手感是「先被吸引、再贴上」。
##
## 可独立按 F6 运行：value 未赋值时自动掷一颗，方便单独看视觉。

## 被玩家吸取后广播。value 为「展示单位」：攻击 / 生命是点数，暴击系是百分点。
signal collected(stat: int, value: float)

## 接触拾取半径：球体本身的大小，也是真正触发吸取的判定圈
const PICKUP_RADIUS := 16.0
## 磁吸激活半径：明显大于拾取半径，玩家一进圈球就开始飞过来
const MAGNET_RADIUS := 64.0
## 磁吸速度区间（px/s）。离得远时慢、贴近时快 —— 起身慢收尾快，
## 观感上才像「被吸进去」，匀速平移会像球自己在地上滑。
const MAGNET_SPEED_FAR := 70.0
const MAGNET_SPEED_NEAR := 340.0
## 磁吸聚焦点：玩家原点在脚底（角色视觉从 y=0 往上长），
## 往脚下吸会让球贴着地面横移，抬高一点对准躯干中心更自然。
const MAGNET_FOCUS := Vector2(0.0, -16.0)

## 属性随机池（全部四条）与对应权重：攻击 / 生命常见，暴击系稀有。
## 两个数组按 index 对齐，改池子时必须同步改权重。
const STAT_POOL: Array[int] = [
	WuxiaWeapon.Stat.ATTACK, WuxiaWeapon.Stat.HEALTH,
	WuxiaWeapon.Stat.CRIT_RATE, WuxiaWeapon.Stat.CRIT_DMG,
]
const STAT_WEIGHT: Array[int] = [34, 34, 18, 14]

## 属性 → 数值区间。能量球是永久成长，数值刻意压得比武器词条小一个量级：
## 一颗球是一次小确幸，靠数量堆出 Build，而不是一颗球顶一把神兵。
const VALUE_RANGE: Dictionary = {
	WuxiaWeapon.Stat.ATTACK: Vector2(1.0, 3.0),
	WuxiaWeapon.Stat.HEALTH: Vector2(4.0, 10.0),
	WuxiaWeapon.Stat.CRIT_RATE: Vector2(0.5, 1.5),
	WuxiaWeapon.Stat.CRIT_DMG: Vector2(2.0, 6.0),
}

## 属性 → 颜色。与 STAT_POOL 同序，四色互不相近，混战里一眼能认出捡到了什么。
const STAT_COLOR: Array[Color] = [
	Color("#e0603a"), Color("#7fc98a"), Color("#e0a63c"), Color("#6fa8ff"),
]

const C_CORE := Color("#f4fbff")

## 掉落前赋值，必须在 add_child 之前设置好 —— _ready() 会据它构建外观与浮字
var stat: int = WuxiaWeapon.Stat.ATTACK
var value: float = 0.0

var _visuals: Node2D
var _label: Label
var _taken: bool = false
## 磁吸激活圈。与自身那圈拾取判定分开，只负责「玩家有没有靠近」。
var _magnet_range: Area2D
## 当前被吸引的目标（玩家）。为空时 _physics_process 关闭。
var _target: Node2D = null

func _ready() -> void:
	if value <= 0.0:
		# F6 单跑场景时的兜底：没人给数值就自己掷一颗
		var solo := RandomNumberGenerator.new()
		solo.randomize()
		stat = _pick_stat(solo)
		value = _pick_value(solo, stat)
	_build_visuals()
	_build_label()
	_play_pop()
	# 没人靠近的球不占任何逐帧开销：磁吸是「进圈才开」，不是常驻轮询
	set_physics_process(false)
	# 物理判定不在 _ready() 里直接建 —— 原因见 _setup_physics()
	_setup_physics.call_deferred()

## 物理侧（碰撞层 + 拾取圈 + 磁吸圈）单独成函数，且延迟一帧执行。
##
## 掉落物几乎都是在**攻击判定回调**里生成的：player 的 Area2D `body_entered` → 敌兵 _die
## → 敌兵广播 died → game 掉球。而那一刻物理服务器正在 flush 查询，
## 此时给刚进树的 Area2D 注册碰撞体会被引擎拒绝
## （`Can't change this state while flushing queries`）—— 表现是每次击杀刷 1~2 条 ERROR。
##
## 实测（回滚修复做变异测试）引擎拒绝的只是形状的 enabled 状态同步，形状本身注册成功、
## 默认就是启用的，所以球其实一直吸得走 —— 影响是日志噪音，不是玩法。
## 仍然要修：引擎明确拒绝的调用不该留着，日志里混着它会把真正的报错淹掉。
##
## 用 call_deferred 把这整块推到 flush 之后再执行。玩法上没有任何可感知的延迟：
## 球刚落地的那一帧，玩家不可能已经站在它身上。
func _setup_physics() -> void:
	collision_layer = 0
	# 2 = player：只有玩家能吸走，敌兵走过不会吞掉掉落物
	collision_mask = 2
	_build_shape()
	_build_magnet()
	body_entered.connect(_on_body_entered)

## 是否已被吸取。节点此时可能还在播消散动画、尚未 queue_free，
## 所以这个查询与 is_queued_for_deletion() 不是一回事。
func is_taken() -> bool:
	return _taken

# ---------------- 产出 ----------------

## 掷一颗能量球。掉落唯一入口，与 WuxiaWeapon.roll() 保持同一套「静态工厂」写法：
## 数值在数据类里掷，game.gd 只决定「掉在哪」。
static func roll(rng: RandomNumberGenerator) -> WuxiaEnergyOrb:
	var orb := WuxiaEnergyOrb.new()
	orb.stat = _pick_stat(rng)
	orb.value = _pick_value(rng, orb.stat)
	return orb

static func _pick_stat(rng: RandomNumberGenerator) -> int:
	var total: int = 0
	for weight: int in STAT_WEIGHT:
		total += weight
	var pick: int = rng.randi_range(1, total)
	var acc: int = 0
	for i: int in STAT_POOL.size():
		acc += STAT_WEIGHT[i]
		if pick <= acc:
			return STAT_POOL[i]
	return STAT_POOL[0]

static func _pick_value(rng: RandomNumberGenerator, stat_id: int) -> float:
	var span: Vector2 = VALUE_RANGE[stat_id]
	var raw: float = rng.randf_range(span.x, span.y)
	# 攻击 / 生命是整数点，暴击系保留一位小数 —— 与 WuxiaWeapon._roll_value 同一套取整规则
	if stat_id == WuxiaWeapon.Stat.ATTACK or stat_id == WuxiaWeapon.Stat.HEALTH:
		return roundf(raw)
	return roundf(raw * 10.0) / 10.0

# ---------------- 磁吸 ----------------

## 玩家进圈 → 激活磁吸。信号驱动而非逐帧查距离：场上没被靠近的球一次都不算。
func _on_magnet_body_entered(body: Node2D) -> void:
	if _taken or not _is_live_player(body):
		return
	_target = body
	set_physics_process(true)

func _on_magnet_body_exited(body: Node2D) -> void:
	if body != _target:
		return
	_target = null
	set_physics_process(false)

## 只在磁吸激活期间运行（进圈时 set_physics_process(true)）。
## 球是纯 Area2D、不走物理体，所以位移得自己写；没有速度、加速度的持久状态，
## 每帧按当前距离直接算速度即可 —— 越近越快，天然收尾利落。
func _physics_process(delta: float) -> void:
	if _taken or not is_instance_valid(_target):
		_stop_magnet()
		return
	# 玩家已倒下：吸过来也会被 player.apply_bonus() 拒收，白白吞掉一颗球
	if not _is_live_player(_target):
		_stop_magnet()
		return

	var offset: Vector2 = _target.global_position + MAGNET_FOCUS - global_position
	var distance: float = offset.length()
	if distance <= 0.001:
		return
	var closeness: float = 1.0 - clampf(distance / MAGNET_RADIUS, 0.0, 1.0)
	var speed: float = lerpf(MAGNET_SPEED_FAR, MAGNET_SPEED_NEAR, closeness)
	# 直接写 global_position 而不是 velocity：Area2D 没有 move_and_slide，
	# 而且这里要的就是「无视地形直接飞向玩家」——
	# 磁吸半径只有 64px，球不会穿墙飞太远，视觉上察觉不到。
	global_position += offset / distance * speed * delta

func _stop_magnet() -> void:
	_target = null
	set_physics_process(false)

## 活着的玩家才算有效目标。三处（拾取 / 进圈 / 逐帧追踪）共用一套判断，避免各写一份走味。
func _is_live_player(node: Node2D) -> bool:
	if not node.is_in_group("player"):
		return false
	return not node.has_method("is_alive") or bool(node.call("is_alive"))

# ---------------- 吸取 ----------------

func _on_body_entered(body: Node2D) -> void:
	if _taken or not _is_live_player(body):
		return
	_take()

func _take() -> void:
	# body_entered 是物理查询回调，回调里直接改 monitoring 会被引擎挡下
	# （"Can't change this state while flushing queries"），球就永远吃不掉了 —— 必须 deferred。
	# _taken 先行拦截：deferred 生效前可能再进来一次 body_entered。
	if _taken:
		return
	_taken = true
	_stop_magnet()
	set_deferred("monitoring", false)
	_magnet_range.set_deferred("monitoring", false)
	# 先广播再播动画：加成到手不等动画演完，免得动画期间玩家再受击时状态前后不一致
	collected.emit(stat, value)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_visuals, "position:y", -14.0, 0.18)
	tween.tween_property(_visuals, "scale", Vector2(1.6, 1.6), 0.18)
	tween.tween_property(_visuals, "modulate:a", 0.0, 0.18)
	tween.tween_property(_label, "modulate:a", 0.0, 0.1)
	tween.chain().tween_callback(queue_free)

# ---------------- 视觉 ----------------

## 属性 → 光晕颜色。Stat 本身是 0..3 的连续枚举，直接下标取，不用再查表。
func _tint() -> Color:
	if stat < 0 or stat >= STAT_COLOR.size():
		return STAT_COLOR[0]
	return STAT_COLOR[stat]

func _build_shape() -> void:
	var circle := CircleShape2D.new()
	circle.radius = PICKUP_RADIUS
	var shape := CollisionShape2D.new()
	shape.shape = circle
	add_child(shape)

## 磁吸圈是子 Area2D，与拾取判定各用各的半径。
## 它自己不做拾取、只发进圈 / 出圈信号，所以 mask 同样只认玩家层。
func _build_magnet() -> void:
	var circle := CircleShape2D.new()
	circle.radius = MAGNET_RADIUS
	var shape := CollisionShape2D.new()
	shape.shape = circle
	_magnet_range = Area2D.new()
	_magnet_range.name = "MagnetRange"
	_magnet_range.collision_layer = 0
	_magnet_range.collision_mask = 2
	_magnet_range.add_child(shape)
	add_child(_magnet_range)
	_magnet_range.body_entered.connect(_on_magnet_body_entered)
	_magnet_range.body_exited.connect(_on_magnet_body_exited)

func _build_visuals() -> void:
	_visuals = Node2D.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	var tint: Color = _tint()
	# 三层同心圆：外层大光晕 → 中层本体 → 白色内核。
	# 单色实心圆在深色山影上会糊成一块色斑，靠「中心更亮」才有发光感。
	Gfx.make_poly(_visuals, Gfx.circle_poly(13.0), Color(tint.r, tint.g, tint.b, 0.24))
	Gfx.make_poly(_visuals, Gfx.circle_poly(8.0), Color(tint.r, tint.g, tint.b, 0.72))
	Gfx.make_poly(_visuals, Gfx.circle_poly(3.5, 8), C_CORE)

## 数值浮字挂在本节点上、不挂 _visuals：球在弹跳缩放，文字要保持稳定好读。
func _build_label() -> void:
	_label = Label.new()
	_label.position = Vector2(-46.0, -34.0)
	_label.size = Vector2(92.0, 16.0)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_override("font", Gfx.cjk_font())
	_label.add_theme_font_size_override("font_size", 10)
	_label.add_theme_color_override("font_color", _tint())
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.text = WuxiaWeapon.format_stat(stat, value)
	add_child(_label)

## 出场弹跳：先小后大、先上后下，落在地上时刚好停稳。
## 顺序沿用 weapon_drop.gd 的 set_parallel() + chain() 写法 —— 前者是并行段，后者另起一段。
func _play_pop() -> void:
	_visuals.scale = Vector2(0.3, 0.3)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_visuals, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_visuals, "position:y", -6.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(_visuals, "position:y", 0.0, 0.22).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
