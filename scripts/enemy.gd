class_name WuxiaEnemy
extends CharacterBody2D

## 侠影录 · 敌兵「刀客」
## 单一职责：地面巡逻、侦测追击、接触伤害、受击与死亡。
## 死亡通过 died 信号广播，由生成者决定掉落/计分，敌兵自身不关心。

signal died
signal health_changed(current: int, maximum: int)
signal damaged(amount: int)

const GRAVITY := 1400.0
const MAX_FALL := 620.0
const KNOCKBACK := 190.0
const HITSTUN := 0.18

## ---------------- 近身攻击 ----------------
## 敌兵原本只有接触伤害，贴图动画进场后补一套「看得见的攻击」：
## 玩家近身时停步 → 前摇 → 挥砍伤害帧 → 收招冷却。数值刻意保守：
## 伤害只比接触伤害高一点，冷却够长，玩家有充足的惩罚窗口去练格挡。
const ATTACK_TIME := 0.55
## 伤害帧落在攻击动画的「挥出去」那一拍（前摇占一半多一点）
const ATTACK_HIT_AT := 0.3
const ATTACK_COOLDOWN := 1.25
## 攻击距离：从体型边缘再往前探一段（大于接触盒，贴身必触发）
const ATTACK_REACH := 26.0
## 攻击伤害比接触伤害高的那部分
const ATTACK_DAMAGE_BONUS := 4

## ---------------- 序列帧动画 ----------------
## 每条动画一套「贴图/网格/帧数/帧率/帧锚点/播放顺序」，由 tools/make_enemy_sheet.py
## 归一化产出：帧锚点恒为「格子横向正中 + 底部 pad 上沿」，运行时把「脚底中线」对到节点原点。
## order 允许乱序播放（攻击图第 2 格画的是下劈、第 3 格是横扫，重排后动作才连顺）。
const ANIMS: Dictionary = {
	&"idle": {
		"sheet": "res://assets/sprites/minion_idle.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 5.0,
		"anchor": Vector2(0.5, 0.8966), "order": [0, 1, 2, 3],
	},
	&"walk": {
		"sheet": "res://assets/sprites/minion_walk.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 8.0,
		"anchor": Vector2(0.5, 0.8966),
		# 相位序：源图 f2=前伸 f0=触地 f3=后蹬 f1=收腿过渡。
		# 按网格序播放会在「前伸→后蹬」处让前脚瞬移回身下，看起来像倒着走。
		"order": [2, 0, 3, 1],
	},
	&"attack": {
		"sheet": "res://assets/sprites/minion_attack.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 7.5,
		"anchor": Vector2(0.5, 0.8966), "order": [0, 3, 1, 2],
	},
	&"hurt": {
		"sheet": "res://assets/sprites/minion_hurt.png",
		"cols": 2, "rows": 2, "frames": 3, "fps": 10.0,
		"anchor": Vector2(0.5, 0.8966), "order": [0, 1, 3],
	},
}
## 循环与否：待机/行走循环；攻击/受击是一次性动作，播完停住由状态机切走
const ANIM_LOOP := {
	&"idle": true, &"walk": true, &"attack": false, &"hurt": false,
}
const ANIM_IDLE := &"idle"
const ANIM_WALK := &"walk"
const ANIM_ATTACK := &"attack"
const ANIM_HURT := &"hurt"

@export var max_health: int = 30
@export var move_speed: float = 62.0
@export var chase_speed: float = 104.0
@export var touch_damage: int = 8
@export var detect_radius: float = 170.0
@export var patrol_range: float = 110.0
@export var tint: Color = Color("#8c3b2f")
## 受击击退强度倍率。Boss 这类大体型要调小，否则挨一下就像纸片一样被推走。
@export var knockback_scale: float = 1.0
## 受击盒尺寸。放大体型时必须同步放大 —— 玩家攻击判定是独立 Area2D，盒对不上就整场挥空。
@export var body_size: Vector2 = Vector2(16, 30)
## 接触伤害盒尺寸，通常比受击盒略宽，贴身时更「咬得住」。
@export var touch_size: Vector2 = Vector2(20, 30)

var _health: int = 0
var _facing: int = 1
var _stun: float = 0.0
var _flash: float = 0.0
var _origin_x: float = 0.0
var _dead: bool = false

## 近身攻击状态：>0 表示正在出招（停步、不再巡逻/追击）
var _attack_cd: float = 0.0
var _attack_left: float = 0.0
var _attack_hit_done: bool = false

var _visuals: Node2D
## 序列帧精灵。贴图齐全时由 _build_visuals() 建好并接管表现；缺失时为 null，
## 回退成多边形小人（见 _build_fallback_visuals）—— 新克隆仓库也能直接跑。
var _anim: AnimatedSprite2D
## 每条动画的绘制偏移（把「脚底中线」对到节点原点），切动画时必须跟着换
var _anim_offsets: Dictionary = {}
## 已应用的动画名。自己记一份：给 AnimatedSprite2D 赋 sprite_frames 时引擎会自动
## 选中第一条动画，「同名判据」会因此漏掉首次应用（player.gd 踩过同一个坑）。
var _anim_current: StringName = &""
## 头顶血条：背景暗条 + 前景红条。满血隐藏、掉血才显示 —— 常显会让巡逻中的杂兵
## 也顶着一条红杠，画面太吵；掉血才出现正好是「这家伙残了」的强调。
## 刻意不挂 _visuals：_visuals.scale.x = _facing 会镜像血条，让填充方向跟着朝向翻面。
var _hp_bar_bg: Polygon2D
var _hp_bar_fg: Polygon2D
var _wall_ray: RayCast2D
var _ledge_ray: RayCast2D
var _touch_area: Area2D

## 头顶血条的几何：宽 24 / 高 3 / 顶边 y=-48（身体最高点 -41 再留 7px 空隙）。
## Boss 等大体型子类覆写这两个方法把血条抬到头顶、加宽到体型比例，
## 并在自己 override 的 _build_visuals() 里补一句 _build_hp_bar()。
const HP_BAR_H := 3.0

func _hp_bar_w() -> float:
	return 24.0

func _hp_bar_y() -> float:
	return -48.0

func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 4
	# 1 = world，2 = player：与玩家互为实体，避免玩家直接穿过敌兵
	collision_mask = 1 | 2
	_health = max_health
	_origin_x = global_position.x
	_build_visuals()
	_build_sensors()
	health_changed.emit(_health, max_health)

# ---------- 对外 API ----------

func take_damage(amount: int, source_position: Vector2) -> void:
	if _dead:
		return
	_health = maxi(_health - amount, 0)
	_stun = HITSTUN
	_flash = 0.12
	# 受击打断出招：挨打的人不该把这一斧头抡完
	_attack_left = 0.0
	var dir: float = signf(global_position.x - source_position.x)
	if dir == 0.0:
		dir = float(-_facing)
	velocity.x = dir * KNOCKBACK * knockback_scale
	velocity.y = -90.0 * knockback_scale
	damaged.emit(amount)
	health_changed.emit(_health, max_health)
	_refresh_hp_bar()
	if _health == 0:
		_die()

# ---------- 主循环 ----------

func _physics_process(delta: float) -> void:
	if _dead:
		return
	_stun = maxf(_stun - delta, 0.0)
	_flash = maxf(_flash - delta, 0.0)
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_visuals.modulate = Color(3.0, 3.0, 3.0) if _flash > 0.0 else Color.WHITE
	_visuals.scale.x = float(_facing)

	velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL)

	# 出招期间：停步站在原地，伤害帧到了才判定一次；受击硬直会打断出招
	if _attack_left > 0.0:
		_advance_attack(delta)
	elif _stun <= 0.0 and is_on_floor():
		_think()

	_update_anim()
	move_and_slide()

## 出招推进。伤害帧在 ATTACK_HIT_AT：此刻玩家还在攻击弧内就挨这一下。
func _advance_attack(delta: float) -> void:
	_attack_left = maxf(_attack_left - delta, 0.0)
	velocity.x = 0.0
	if not _attack_hit_done and _attack_left <= ATTACK_TIME - ATTACK_HIT_AT:
		_attack_hit_done = true
		var target: WuxiaPlayer = _find_player()
		if target != null:
			var dx: float = absf(target.global_position.x - global_position.x)
			var dy: float = absf(target.global_position.y - global_position.y)
			if dx < _attack_range() + 12.0 and dy < 44.0:
				target.take_damage(touch_damage + ATTACK_DAMAGE_BONUS, global_position)

## 近身攻击的触发判定挂在 _think 的最前面：玩家贴身且冷却好了就停步出招
func _try_start_attack() -> bool:
	if _attack_cd > 0.0:
		return false
	var target: WuxiaPlayer = _find_player()
	if target == null:
		return false
	var dx: float = target.global_position.x - global_position.x
	var dy: float = target.global_position.y - global_position.y
	if absf(dx) > _attack_range() or absf(dy) > 44.0:
		return false
	_facing = 1 if dx > 0.0 else -1
	_attack_cd = ATTACK_COOLDOWN
	_attack_left = ATTACK_TIME
	_attack_hit_done = false
	velocity.x = 0.0
	return true

## 攻击距离：体型边缘再往前探一段（Boss 大体型天然手长）
func _attack_range() -> float:
	return body_size.x * 0.5 + ATTACK_REACH

## 表现层动画选择：出招 > 受击 > 移动 > 待机。Boss 在 WINDUP/DASH 时覆写本方法
## 强制出招动画（突进斩共用 attack 序列帧）。
func _update_anim() -> void:
	if _anim == null:
		return
	var next: StringName
	if _attack_left > 0.0:
		next = ANIM_ATTACK
	elif _stun > 0.0:
		next = ANIM_HURT
	elif absf(velocity.x) > 5.0:
		next = ANIM_WALK
	else:
		next = ANIM_IDLE
	_apply_anim(next)

func _think() -> void:
	if _try_start_attack():
		return
	_wall_ray.target_position = Vector2(_probe_x() * float(_facing), 0.0)
	_ledge_ray.position = Vector2(_ledge_x() * float(_facing), -2.0)
	_wall_ray.force_raycast_update()
	_ledge_ray.force_raycast_update()
	# 前方是墙，或前方没有地面 → 本帧不再前进
	var blocked: bool = _wall_ray.is_colliding() or not _ledge_ray.is_colliding()

	var target: WuxiaPlayer = _find_player()
	if target != null:
		var dx: float = target.global_position.x - global_position.x
		var dy: float = target.global_position.y - global_position.y
		if absf(dx) > 20.0:
			_facing = 1 if dx > 0.0 else -1
		if blocked or (absf(dx) < 20.0 and absf(dy) < 30.0):
			velocity.x = 0.0
		else:
			velocity.x = float(_facing) * chase_speed
	else:
		if blocked:
			_facing = -_facing
			velocity.x = 0.0
		else:
			velocity.x = float(_facing) * move_speed
		if absf(global_position.x - _origin_x) > patrol_range:
			_facing = 1 if global_position.x < _origin_x else -1

func _find_player() -> WuxiaPlayer:
	var node: Node = get_tree().get_first_node_in_group("player")
	if node is WuxiaPlayer and node.is_alive():
		return node
	return null

# ---------- 接触伤害 ----------

func _on_touch_area_body_entered(body: Node2D) -> void:
	if _dead or body == self:
		return
	if body.has_method("take_damage"):
		body.call("take_damage", touch_damage, global_position)

# ---------- 死亡 ----------

func _die() -> void:
	_dead = true
	collision_layer = 0
	collision_mask = 0
	_touch_area.monitoring = false
	# 血条不进 _visuals，淡出动画盖不到它 —— 死亡即刻隐藏，尸体上不留一条红杠
	_hp_bar_bg.visible = false
	_hp_bar_fg.visible = false
	set_physics_process(false)
	died.emit()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_visuals, "modulate:a", 0.0, 0.35)
	tween.tween_property(_visuals, "scale", Vector2(1.3, 0.5), 0.35)
	tween.chain().tween_callback(queue_free)

# ---------- 构建 ----------

func _build_visuals() -> void:
	_visuals = Node2D.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	# 序列帧优先：贴图齐全就用 AI 生成角色；缺任何一张就整体回退多边形小人
	if _build_sprite_visuals():
		_build_extras()
		_build_hp_bar()
		return
	_build_fallback_visuals()
	_build_hp_bar()

## 子类额外的表现挂点（Boss 的突进预警箭簇）。建在精灵之后：箭簇画在角色上层。
func _build_extras() -> void:
	pass

## 多边形回退小人：与旧版逐像素一致，只在序列帧贴图缺失时出场
func _build_fallback_visuals() -> void:
	Gfx.make_poly(_visuals, Gfx.rect_poly(-8, -30, 8, -2), tint)
	Gfx.make_poly(_visuals, Gfx.rect_poly(-8.5, -16, 8.5, -12), Color("#3a2b20"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(-5, -41, 5, -30), Color("#d9b98e"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(-7, -41, 7, -38), Color("#2a2118"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(1, -37, 4, -35.5), Color("#1b1b1f"))
	# 腰刀
	Gfx.make_poly(_visuals, Gfx.rect_poly(-3, -20, 20, -17.5), Color("#b9c3c7"))

## 用 ANIMS 里的序列帧配置组装 AnimatedSprite2D。贴图缺一张就整体放弃（返回 false），
## 由调用方走多边形回退 —— 与 player.gd 的兜底策略一致：资源没导入也不白屏。
func _build_sprite_visuals() -> bool:
	var anims := _sprite_anims()
	for anim_name: StringName in anims:
		if not ResourceLoader.exists(anims[anim_name]["sheet"]):
			return false

	var frames := SpriteFrames.new()
	# SpriteFrames 自带一条空动画，第一条直接改名复用，免得留一条没人播的 default
	var first := true
	for anim_name: StringName in anims:
		var cfg: Dictionary = anims[anim_name]
		var tex: Texture2D = load(cfg["sheet"]) as Texture2D
		if tex == null:
			return false
		if first:
			frames.rename_animation(&"default", anim_name)
			first = false
		else:
			frames.add_animation(anim_name)
		frames.set_animation_speed(anim_name, cfg["fps"])
		frames.set_animation_loop(anim_name, ANIM_LOOP[anim_name])
		_add_frames(frames, anim_name, tex, cfg)
		# 把「脚底中线」对到节点原点：敌兵的原点在脚底（受击盒 y -body_size.y..0）
		var cell := Vector2(
			float(tex.get_width()) / float(cfg["cols"]),
			float(tex.get_height()) / float(cfg["rows"]))
		_anim_offsets[anim_name] = (-cell * (cfg["anchor"] as Vector2)).round()

	_anim = AnimatedSprite2D.new()
	_anim.name = "Anim"
	_anim.sprite_frames = frames
	_anim.centered = false
	# 最近邻：序列帧按游戏内 1:1 高度预缩放，放大显示时才是硬像素块（与主角同一套约定）
	_anim.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_visuals.add_child(_anim)
	_anim_current = &""
	_apply_anim(ANIM_IDLE)
	return true

## 序列帧配置。Boss 覆写换成自己的贴图；新怪种继承后也只需覆写这一个方法。
func _sprite_anims() -> Dictionary:
	return ANIMS

## 按播放顺序把一条序列图切成帧追加到动画上（order 支持乱序，见 ANIMS 注释）。
func _add_frames(frames: SpriteFrames, anim: StringName, tex: Texture2D, cfg: Dictionary) -> void:
	var cols: int = cfg["cols"]
	var cell_w: int = tex.get_width() / cols
	var cell_h: int = tex.get_height() / int(cfg["rows"])
	for order_index: int in int(cfg["frames"]):
		var i: int = order_index if cfg["order"].is_empty() else int(cfg["order"][order_index])
		var frame_tex := AtlasTexture.new()
		frame_tex.atlas = tex
		frame_tex.region = Rect2(
			float(i % cols * cell_w), float(i / cols * cell_h),
			float(cell_w), float(cell_h))
		frames.add_frame(anim, frame_tex)

## 切到指定动画。offset 必须跟着换 —— 各序列图格子尺寸不同，共用一个 offset
## 会让角色在切换瞬间跳一下。已是该动画时直接返回，不重播。
func _apply_anim(anim: StringName) -> void:
	if _anim == null or _anim_current == anim:
		return
	_anim_current = anim
	_anim.offset = _anim_offsets[anim]
	_anim.play(anim)

## 头顶血条（见字段注释）。宽度按血量比例从左往右缩：
## 血条不进 _visuals，所以不受朝向镜像影响，填充方向恒定。
func _build_hp_bar() -> void:
	var y: float = _hp_bar_y()
	var half: float = _hp_bar_w() * 0.5
	_hp_bar_bg = Gfx.make_poly(self, Gfx.rect_poly(-half, y, half, y + HP_BAR_H), Color(0.05, 0.05, 0.09, 0.8))
	_hp_bar_bg.z_index = 1
	_hp_bar_fg = Gfx.make_poly(self, Gfx.rect_poly(-half, y, half, y + HP_BAR_H), Color("#e04538"))
	_hp_bar_fg.z_index = 2
	_hp_bar_bg.visible = false
	_hp_bar_fg.visible = false

func _refresh_hp_bar() -> void:
	var ratio: float = 0.0 if max_health <= 0 else clampf(float(_health) / float(max_health), 0.0, 1.0)
	var shown: bool = ratio > 0.0 and ratio < 1.0
	_hp_bar_bg.visible = shown
	_hp_bar_fg.visible = shown
	if not shown:
		return
	var y: float = _hp_bar_y()
	var half: float = _hp_bar_w() * 0.5
	var w: float = half * 2.0 * ratio
	_hp_bar_fg.polygon = Gfx.rect_poly(-half, y, -half + w, y + HP_BAR_H)

## 前瞻射线的长度：从体型边缘再往前探一段
func _probe_x() -> float:
	return body_size.x * 0.5 + 6.0

## 悬崖探针的横向位置：略超出体型边缘
func _ledge_x() -> float:
	return body_size.x * 0.5 + 4.0

func _build_sensors() -> void:
	var body_shape := CollisionShape2D.new()
	var body_rect := RectangleShape2D.new()
	body_rect.size = body_size
	body_shape.shape = body_rect
	body_shape.position = Vector2(0, -body_size.y * 0.5)
	add_child(body_shape)

	_wall_ray = RayCast2D.new()
	_wall_ray.target_position = Vector2(_probe_x(), 0)
	_wall_ray.position = Vector2(0, -body_size.y * 0.5)
	add_child(_wall_ray)

	_ledge_ray = RayCast2D.new()
	_ledge_ray.target_position = Vector2(0, 22)
	_ledge_ray.position = Vector2(_ledge_x(), -2)
	add_child(_ledge_ray)

	var touch_shape := CollisionShape2D.new()
	var touch_rect := RectangleShape2D.new()
	touch_rect.size = touch_size
	touch_shape.shape = touch_rect
	touch_shape.position = Vector2(0, -touch_size.y * 0.5)
	_touch_area = Area2D.new()
	_touch_area.name = "TouchDamage"
	_touch_area.collision_layer = 0
	_touch_area.collision_mask = 2
	_touch_area.add_child(touch_shape)
	add_child(_touch_area)
	_touch_area.body_entered.connect(_on_touch_area_body_entered)
