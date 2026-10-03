class_name WuxiaBoss
extends WuxiaEnemy

## 侠影录 · 第一关守关 Boss「铁面刀客」
##
## 复用 WuxiaEnemy 的巡逻 / 射线探路 / 侦测追击 / 接触伤害 / 受击硬直 / 死亡广播，
## 只重写三件事：更大的体型与受击盒、更抗打断（击退倍率调低）、以及一段可预判的突进斩。
##
## 掉什么、怎么拾取、能不能装备一律不在这里处理 —— Boss 只负责「活着」与「死掉」，
## 父类的 died 信号就是掉落的触发点。

enum State { CHASE, WINDUP, DASH }

const BASE_TOUCH_DAMAGE := 14
const DASH_TOUCH_DAMAGE := 22
const DASH_INTERVAL := 2.8
## 首次突进的等待时间刻意短于循环间隔：一照面就给你一下，否则 Boss 站着不动像个木桩
const FIRST_DASH_DELAY := 0.8
const WINDUP_TIME := 0.45
const DASH_TIME := 0.5
const DASH_SPEED := 300.0

var _state: int = State.CHASE
var _timer: float = 0.0
var _cooldown: float = FIRST_DASH_DELAY
var _telegraph: Polygon2D

## Boss 序列帧（黑甲刀将）。锚点由 make_enemy_sheet.py 逐格量出，与杂兵不同。
## 刻意不叫 ANIMS：GDScript 不允许子类常量遮蔽父类同名成员，经 _sprite_anims() 提供给基类。
const BOSS_ANIMS: Dictionary = {
	&"idle": {
		"sheet": "res://assets/sprites/boss_idle.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 5.0,
		"anchor": Vector2(0.5, 0.9231), "order": [0, 1, 2, 3],
	},
	&"walk": {
		"sheet": "res://assets/sprites/boss_walk.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 6.0,
		"anchor": Vector2(0.5, 0.9231),
		# 相位序同小怪：f2=前伸 f0=触地 f3=后蹬 f1=收腿过渡（网格序会倒着走）
		"order": [2, 0, 3, 1],
	},
	&"attack": {
		"sheet": "res://assets/sprites/boss_attack.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 4.5,
		"anchor": Vector2(0.5, 0.9231), "order": [0, 1, 2, 3],
	},
	&"hurt": {
		"sheet": "res://assets/sprites/boss_hurt.png",
		"cols": 2, "rows": 2, "frames": 3, "fps": 8.0,
		"anchor": Vector2(0.5, 0.9231), "order": [0, 2, 3],
	},
}

func _ready() -> void:
	# 父类 _ready() 会拿这些数值去初始化血量、视觉与传感器，必须先摆好再 super()
	max_health = 260
	touch_damage = BASE_TOUCH_DAMAGE
	move_speed = 46.0
	chase_speed = 88.0
	detect_radius = 300.0
	patrol_range = 60.0
	tint = Color("#7b2f4a")
	knockback_scale = 0.18
	body_size = Vector2(26, 48)
	touch_size = Vector2(32, 48)
	super()
	add_to_group("boss")

# ---------------- 状态机 ----------------

func _physics_process(delta: float) -> void:
	# 只切状态、不碰速度：速度统一交给 _think() 写，避免两处互相打架
	_advance_state(delta)
	super(delta)

func _advance_state(delta: float) -> void:
	if _dead:
		return
	var prey: WuxiaPlayer = _find_player()
	match _state:
		State.CHASE:
			_cooldown = maxf(_cooldown - delta, 0.0)
			# 出招未收势时不接突进：近身横扫接突进连招可以，两套动作叠在同一拍不行
			if prey != null and _cooldown <= 0.0 and _attack_left <= 0.0 and absf(prey.global_position.y - global_position.y) < 46.0:
				_facing = 1 if prey.global_position.x > global_position.x else -1
				_state = State.WINDUP
				_timer = WINDUP_TIME
		State.WINDUP:
			_timer -= delta
			# 前摇期间仍缓慢跟枪，免得玩家绕到背后白嫖一整套
			if prey != null:
				_facing = 1 if prey.global_position.x > global_position.x else -1
			if _timer <= 0.0:
				_state = State.DASH
				_timer = DASH_TIME
				touch_damage = DASH_TOUCH_DAMAGE
		State.DASH:
			_timer -= delta
			if _timer <= 0.0 or is_on_wall():
				_state = State.CHASE
				_cooldown = DASH_INTERVAL
				touch_damage = BASE_TOUCH_DAMAGE
	_telegraph.visible = _state == State.WINDUP

## 父类 _think() 负责巡逻 / 追击并把结果写进 velocity.x；Boss 在突进前后接管这份职责。
func _think() -> void:
	match _state:
		State.CHASE:
			super()
		State.WINDUP:
			velocity.x = move_toward(velocity.x, 0.0, 60.0)
		State.DASH:
			velocity.x = float(_facing) * DASH_SPEED

# ---------------- 视觉 ----------------

## Boss 动画选择：前摇与突进都播 attack 序列帧（4 帧 @4.5fps ≈ 0.9s，正好罩住
## WINDUP 0.45s + DASH 0.5s 的整个动作段）；其余交给父类通用选择。
func _update_anim() -> void:
	if _anim != null and (_state == State.WINDUP or _state == State.DASH):
		_apply_anim(ANIM_ATTACK)
		return
	super()

func _sprite_anims() -> Dictionary:
	return BOSS_ANIMS

## 突进预警箭簇：只在前摇期间出现。做左右对称形状，
## 这样父类 _visuals.scale.x = facing 的镜像不会把它翻坏。
func _build_extras() -> void:
	_telegraph = Gfx.make_poly(_visuals, PackedVector2Array([
		Vector2(-10, -78), Vector2(10, -78), Vector2(0, -66),
	]), Color(0.92, 0.28, 0.22, 0.92))
	_telegraph.visible = false

## 多边形回退小人（序列帧缺失时）。与旧版逐像素一致。
func _build_fallback_visuals() -> void:
	# 披风（先画，压在身体后面）
	Gfx.make_poly(_visuals, PackedVector2Array([
		Vector2(-16, -42), Vector2(-27, -16), Vector2(-15, -8), Vector2(-9, -36),
	]), Color("#6d1f2a"))
	# 躯干 / 腰带
	Gfx.make_poly(_visuals, Gfx.rect_poly(-15, -48, 15, -2), tint)
	Gfx.make_poly(_visuals, Gfx.rect_poly(-15.5, -26, 15.5, -19), Color("#3a2b20"))
	# 头盔 / 铁面 / 红眼
	Gfx.make_poly(_visuals, Gfx.rect_poly(-9, -64, 9, -59), Color("#2a2118"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(-8, -60, 8, -48), Color("#8f97a0"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(-1.5, -57.5, 6, -55.5), Color("#e0402c"))
	# 宽刃大刀（最后画，压在身体之上）
	Gfx.make_poly(_visuals, Gfx.rect_poly(-8, -34, -4, -23), Color("#4a4f57"))
	Gfx.make_poly(_visuals, Gfx.rect_poly(-6, -32, 46, -25), Color("#cfd8dc"))

## 头顶血条几何覆写：身体到 -64、突进预警到 -78，血条放 -84 才不插进身体
func _hp_bar_w() -> float:
	return 34.0

func _hp_bar_y() -> float:
	return -84.0
