class_name WuxiaPlayer
extends CharacterBody2D

## 侠影录 · 主角「剑客」
## 单一职责：移动 / 跳跃 / 冲刺 / 三段连击 / 生命值。
## 对外只广播信号，不反向访问父节点（可用 F6 单独运行验证）。

signal health_changed(current: int, maximum: int)
signal died
signal combo_changed(step: int)
signal attacked(step: int)
## 装备槽发生变化（首次拾取或替换武器）时广播，HUD 据此刷新武器面板
signal weapon_equipped(weapon: WuxiaWeapon)
## 本次命中触发暴击时广播，携带掷完暴击倍率后的最终伤害
signal crit_landed(amount: int)
## 吸收能量球、永久属性发生永久变化后广播，HUD 据此刷新永久加成面板
signal bonus_applied(stat: int, value: float)
## 打击反馈强度（0..1）。命中敌人、或自己挨打时广播。
## 只表达「这一下有多重」，不含任何表现细节 —— 顿帧多少毫秒、抖屏多少像素由 game.gd 决定，
## 手感参数集中在那一处调，不用回来翻招式表。
signal impact(strength: float)

## 架势（防御条）发生变化。回复过程同样广播 —— 玩家需要看见「什么时候能再挡」。
signal guard_changed(value: float, maximum: float)
## 完美格挡：在 PARRY_WINDOW 内挡下正面攻击。零伤害 + 回架势，是防御系统的收益来源。
signal parried
## 架势被打空（破防）。此后 GUARD_BREAK_STUN 内无法举盾，是「一直按着 L」的惩罚。
signal guard_broken
## 翻滚起手。与冲刺区分：翻滚是对招手段，冲刺是位移手段。
signal evaded

const SPEED := 170.0
const ACCEL := 1600.0
const FRICTION := 2000.0
const GRAVITY := 1400.0
const MAX_FALL := 620.0
## 起跳速度。跳跃高度由它和 GRAVITY 一起决定：连续公式 F²/(2×GRAVITY) ≈ 82px，
## 引擎里按帧离散累加实际 ≈ 86px（离散步会多爬一点，见 smoke_test.gd 的 _jump_climb）。
## 定这个数的依据是关卡里最高的一级「该单跳够得着」的落差（主地面 → 640 那块石台，86px）：
## 低于它就会出现「差一点点跳不上去」的手感。
## 改它必须同步核两处（方向恰好相反，别只顾一边）：
##   ① game.gd 的封边岩壁要仍然**翻不过去**（现高出地面 180px > 攀爬上限 160px）；
##   ② game.gd 的 WALLS 三道内墙要仍然**翻得过去**（最高一道 130px，余量只有 30px）。
const JUMP_FORCE := -480.0
const MAX_JUMPS := 2
## 空中二段跳的力度倍率。提成常量是为了让「关卡两端的岩壁要高到翻不过去」这件事
## 能被算出来、被断言守住（见 smoke_test.gd 的 _max_jump_climb）——
## 写成行内字面量的话，以后调跳跃手感就没有任何东西能提醒你墙该加高了。
const AIR_JUMP_SCALE := 0.92

const DASH_SPEED := 520.0
const DASH_TIME := 0.15
const DASH_COOLDOWN := 0.55
## 冲刺残影：掉一张快照的间隔与淡出时长。
## 按间隔生成而不是每帧生成 —— 60 帧撒 60 张纯属浪费，DASH_TIME 里落 3~4 张就够读出轨迹。
const GHOST_INTERVAL := 0.04
const GHOST_FADE := 0.24
## 残影色：偏冷、半透明。与主角本体拉开，才像「留在原地的一帧」而不是第二个主角。
const C_GHOST := Color(0.55, 0.8, 1.0, 0.5)

## ---------------- 闪避（翻滚） ----------------
##
## 与冲刺的分工是这个功能最容易做糊的地方：
## **冲刺是位移，闪避是对招**。冲刺 520px/s 跑得远、冷却短，但无敌帧只有 0.19s，
## 而且一旦按下就没法取消 —— 拿它躲是有风险的；翻滚距离短、冷却长，
## 换来的是更长的无敌帧与一次「取消出招后摇」的权利。
## 两者共用一套「看不到血条在掉」的反馈，但数值与用途刻意不同，别合并成一个键。
const EVADE_SPEED := 360.0
const EVADE_TIME := 0.26
const EVADE_COOLDOWN := 0.75
## 翻滚无敌时长。刻意长于位移时长（EVADE_TIME）：收招那几帧也是无敌的，
## 否则「滚出去正好被蹭到」会让玩家觉得翻滚没用 —— 无敌帧比位移更该有富余。
const EVADE_INVULN := 0.34
## 翻滚的摩擦。位移由「冲量 + 摩擦」自然收掉，与攻击前冲同一套做法。
const EVADE_FRICTION := 900.0
## 翻滚时的体积压扁，给「缩身滚过去」的形变
const EVADE_SQUASH := Vector2(1.3, 0.72)

## ---------------- 防御（举盾 / 完美格挡 / 架势） ----------------
##
## 三条规则，缺一条这套防御就会崩：
##   ① 只挡正面。背后的攻击照常吃满 —— 否则举着盾就天下无敌，战斗变成站桩。
##   ② 前 PARRY_WINDOW 秒内挡下是「完美格挡」：零伤害 + 回架势。它才是防御的收益，
##      让玩家愿意去读对手的前摇，而不是一直按着不放。
##   ③ 架势会空。非完美格挡按伤害扣架势，空了就破防硬直 —— 一直按着不放有代价。
const GUARD_MAX := 60.0
## 举盾时的减伤比例（0.7 = 只吃 30% 伤害）。不走「完全免伤」：完全免伤会让防御变成唯一解。
const GUARD_REDUCTION := 0.7
## 举盾期间的移速倍率。压低但不为 0：举着盾挪不动会让人不敢用，敢用才谈得上风险。
const GUARD_MOVE_SCALE := 0.45
## 举盾时**不**自动回架势。回架势只发生在「放下盾」的那一侧，逼出攻防节奏。
const GUARD_REGEN_IDLE := 26.0
const GUARD_REGEN_DELAY := 0.7
## 完美格挡窗口：从「举盾那一刻」起算（含收起后再按，不需要等冷却 —— 完美格挡靠的是时机）。
const PARRY_WINDOW := 0.18
## 完美格挡回多少架势
const PARRY_REGEN := 20.0
## 破防后的硬直：这段时间内举不起盾，是一个明确的惩罚窗口
const GUARD_BREAK_STUN := 0.9
## 每点（减伤前）伤害扣多少架势。伤害越高，破防越快。
const GUARD_COST_SCALE := 1.6

## 松手截断：上升途中松开跳跃键，竖直速度按这个比例砍掉 —— 短按矮跳、长按高跳。
## 注意它直接决定「轻点一下能跳多高」：0.45 意味着轻点只有约一半高度（≈50px），
## 够不上 68px 的石台。想让轻点也能上台就把这个数往上调（0.7 以上基本等于取消可变高度）。
const JUMP_CUT := 0.45

const JUMP_BUFFER := 0.12
const COYOTE_TIME := 0.10
const ATTACK_BUFFER := 0.22
const COMBO_WINDOW := 0.35

## 攻击判定盒后沿相对身体中线的前置偏移（负值 = 向后越过中线）
const ATK_BACK_MARGIN := -6.0

## 基础属性：武器词条在这套裸值之上叠加。没武器时玩家就是这套数值。
const BASE_MAX_HEALTH := 100
const BASE_CRIT_RATE := 0.05
## 额外暴击伤害，即暴击造成 (1 + 0.5) = 150% 伤害
const BASE_CRIT_BONUS := 0.5

## 三段连击：前摇 wind / 判定 hit / 后摇 recover，判定帧内开启攻击盒
##
## `lunge` 是判定帧给玩家的一次向前冲量（px/s）。没有它，挥砍是原地砍的，
## 三段连击就只有数值差异、没有重量差；有了它，第三段才会「压上去」。
##
## 实际前移距离 ≈ lunge² / (2 × FRICTION × 0.55)：冲量进去之后由 _physics_move() 的
## 攻击摩擦（FRICTION × 0.55 = 1100px/s²）自然收掉，所以 160 / 190 / 260 大约是
## 12 / 16 / 31px。想调手感只改这里，别忘了改完要重新算一遍前移距离。
const COMBO: Array[Dictionary] = [
	{"dmg": 10, "wind": 0.05, "hit": 0.10, "rec": 0.12, "box": Vector2(30, 24), "reach": 14.0, "lunge": 160.0},
	{"dmg": 12, "wind": 0.05, "hit": 0.10, "rec": 0.14, "box": Vector2(32, 22), "reach": 16.0, "lunge": 190.0},
	{"dmg": 20, "wind": 0.10, "hit": 0.14, "rec": 0.28, "box": Vector2(38, 30), "reach": 26.0, "lunge": 260.0},
]

const C_ROBE := Color("#2b3a55")
const C_SASH := Color("#b8352c")
const C_SKIN := Color("#e8d3b0")
const C_HAIR := Color("#1b1b1f")
const C_STEEL := Color("#cfd8dc")
## 盾：举盾中 / 完美格挡窗口 / 破防硬直。三种颜色是玩家读状态的唯一依据。
const C_SHIELD := Color("#cfd8dc")
const C_PARRY := Color("#ffd45e")
const C_BREAK := Color("#8a2f28")

## 主角序列帧。每条动画自带一套「贴图 / 网格 / 帧数 / 帧率 / 帧锚点」——
## 不同序列图的格子尺寸与角色大小都不一样（跑步图 4x3、待机图 5x4），
## 所以尺寸参数挂在动画配置里，不写成全局常量；新增动画只在这里加一条。
##
## 贴图都由 tools/make_player_sheet.py 按**目标角色高度 48px** 预缩放到 1:1，运行时不再缩放：
## 主角在 480x270 的视口里只有约 48px 高，原图 256px 的格子要缩到 0.22 倍 ——
## 交给 GPU 实时缩，4.6 倍最小化 + 无 mipmap 会一路闪烁。
## 按「角色高度」而不是「格子边长」缩放，才能保证两条动画切换时体型不变。
const ANIMS: Dictionary = {
	&"idle": {
		"sheet": "res://assets/sprites/player_idle.png",
		"cols": 5, "rows": 4, "frames": 20, "fps": 9.0,
		## 帧锚点：格子尺寸 × 该比例 = 角色「脚底中线」在格子里的位置。
		## 由 make_player_sheet.py 逐格量内容、再取中位数得到（比例形式，与缩放无关）。
		"anchor": Vector2(0.5117, 0.9384),
	},
	&"run": {
		"sheet": "res://assets/sprites/player_run.png",
		"cols": 4, "rows": 3, "frames": 9, "fps": 9.0,
		"anchor": Vector2(0.4727, 0.9297),
	},
	## 攻击：三段连击共用这一条序列帧（身体摆动 + 前冲），剑刃由多边形剑 _sword 叠加，
	## 与 idle/run 同工艺（贴图不含剑，剑是独立叠加物）。loop=false：出招期间播一次，
	## 状态机在 wind→hit→recover→idle 切换时会重新 play，于是每一击都重播这套挥砍。
	&"attack": {
		"sheet": "res://assets/sprites/player_attack.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 14.0,
		"anchor": Vector2(0.5, 0.9),
	},
	## 受击：被命中瞬间的后仰/踉跄。loop=false，由 _hurt_timer 驱动播一次。
	&"hurt": {
		"sheet": "res://assets/sprites/player_hurt.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 18.0,
		"anchor": Vector2(0.5, 0.9),
	},
	## 跳跃/下落：空中姿态共用这一条（升空与坠落都播），落地后回到 idle/run。
	&"jump": {
		"sheet": "res://assets/sprites/player_jump.png",
		"cols": 2, "rows": 2, "frames": 4, "fps": 10.0,
		"anchor": Vector2(0.5, 0.9),
	},
}
## 没有位移、也没有攻击（出招时另有长剑可看）时播的动画
const ANIM_IDLE := &"idle"
## 有水平位移时播的动画
const ANIM_RUN := &"run"
## 出招（三段连击）时播的动画
const ANIM_ATTACK := &"attack"
## 受击硬直时播的动画
const ANIM_HURT := &"hurt"
## 空中（跳跃/下落）时播的动画
const ANIM_JUMP := &"jump"
## 各动画是否循环：待机/奔跑/跳跃循环；攻击/受击是一次性动作，播完停住由状态机切走
const ANIM_LOOP := {
	&"idle": true, &"run": true, &"jump": true,
	&"attack": false, &"hurt": false,
}
## 主角的纹理过滤。与项目默认一致（最近邻）：序列帧是按 48px 高的 1:1 做的，
## 放大显示时最近邻才是硬像素块；线性过滤会把边缘插值成一层灰边，看着就是「糊」。
## 前提是像素对齐（见 _pixel_snap_offset），否则最近邻会让边缘逐帧跳动。
const PLAYER_TEXTURE_FILTER := CanvasItem.TEXTURE_FILTER_NEAREST

@export var max_health: int = BASE_MAX_HEALTH

var _health: int = 0
## 装备槽只有一格：拾取新武器整体替换旧武器，词条永不叠加
var _weapon: WuxiaWeapon = null
## 永久属性加成（能量球层）：与武器槽无关，换武器也不该被抹掉。
## 之所以独立成一层、而不是直接加进 _attack_power / max_health：
## _recalc_stats() 的做法是「基础值 + 永久加成 + 武器」整体重算，
## 增量式地写进结果值，会在下一次换武器时被整体重算抹平。
var _bonus_attack: int = 0
var _bonus_health: int = 0
## 存小数（0.05 = 5%），与 BASE_CRIT_RATE / BASE_CRIT_BONUS 同口径；
## 对外的 permanent_bonus() 再换算成百分点，避免调用方记两套单位。
var _bonus_crit_rate: float = 0.0
var _bonus_crit_dmg: float = 0.0
## 攻击力加成总计 = 永久加成 + 当前武器词条。招式伤害在此之上再加招式基础值。
var _attack_power: int = 0
var _crit_rate: float = BASE_CRIT_RATE
var _crit_bonus: float = BASE_CRIT_BONUS
var _rng := RandomNumberGenerator.new()
var _facing: int = 1
var _jumps_left: int = MAX_JUMPS
var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _dash_timer: float = 0.0
var _dash_cd: float = 0.0
var _invuln: float = 0.0
var _hurt_timer: float = 0.0

## 翻滚剩余时间与冷却
var _evade_timer: float = 0.0
var _evade_cd: float = 0.0
## 举盾中：当前是否按着 guard
var _guard_held: bool = false
## 已经举盾多久。前 PARRY_WINDOW 秒内算「完美格挡窗口」。
var _guard_time: float = 0.0
## 架势（防御条）。被打空 → 破防硬直。
var _guard: float = GUARD_MAX
## 距离上次受击过去多久，用来延迟回架势
var _guard_since_hit: float = GUARD_REGEN_DELAY
## 破防硬直剩余时间：> 0 时举不起盾
var _guard_break: float = 0.0
## 本次受击的处理结果（perfect / blocked / broken），只给表现层读一次
var _last_guard_result: StringName = &""

var _atk_step: int = 0
var _atk_phase: StringName = &"idle"
var _atk_timer: float = 0.0
var _atk_buffer: float = 0.0
var _combo_timer: float = 0.0
var _atk_hits: Array[Node2D] = []

var _visuals: Node2D
var _sword: Polygon2D
## 盾。挂在 _visuals 下，自动跟随朝向翻面 —— 盾在正面，判定也只认正面。
var _shield: Polygon2D
## 主角序列帧。贴在 _visuals 下 —— 朝向翻转、受击倾斜、无敌闪烁仍然归 _visuals 管，
## 精灵只负责「播哪条动画、画哪一帧」。贴图缺失时为 null，回退成多边形小人（见 _build_visuals）。
var _anim: AnimatedSprite2D
## 每条动画的绘制偏移（把「脚底中线」对到节点原点）。切动画时要跟着换 ——
## 两条序列图的格子尺寸与帧锚点都不同，共用一个 offset 会让角色在切换瞬间跳一下。
var _anim_offsets: Dictionary = {}
## 已应用到精灵上的动画名。刻意自己记一份、不拿 `_anim.animation` 当依据：
## 给 AnimatedSprite2D 赋 sprite_frames 时，引擎会自己把 animation 选成第一条，
## 于是首次 _apply_anim() 会被「同名」判据挡掉 —— 既不 play 也没设 offset，
## 角色会顶着一个零偏移错位浮在半空。自己记一份才不受引擎这个自动选择的影响。
var _anim_current: StringName = &""
## 残影容器。刻意先于 _visuals 加入 → 画在主角背后，残影是「拖在身后的轨迹」。
var _ghosts: Node2D
## 距离下一张残影还有多久
var _ghost_timer: float = 0.0
var _squash_v: Vector2 = Vector2.ONE
## 上一帧是否在地面：用来抓「刚着地」这一帧，触发落地压扁反馈。
## 落地反馈是一次性的，靠边沿检测实现 —— 不能用信号，CharacterBody2D 没有着地信号。
var _was_on_floor: bool = false
var _atk_area: Area2D
var _atk_shape: CollisionShape2D
var _atk_rect: RectangleShape2D

func _ready() -> void:
	add_to_group("player")
	collision_layer = 2
	# 1 = world，4 = enemy：敌兵作为实体阻挡，玩家不能直接穿过
	collision_mask = 1 | 4
	_rng.randomize()
	_health = max_health
	_build_visuals()
	_build_hitboxes()
	health_changed.emit(_health, max_health)

# ---------------- 对外 API ----------------

## 受击入口。除了无敌帧，这里还要处理「举盾挡下了没有」——
## 判定顺序是先无敌帧（翻滚 / 冲刺的帧里什么都不算），再正面判定，最后才结算架势。
##
## 返回 true 表示这次攻击被挡下（含完美格挡），调用方可以据此决定表现
## （比如敌人不该播「命中」的反馈）。返回值是新增的，旧调用方直接忽略即可。
func take_damage(amount: int, source_position: Vector2) -> bool:
	if _invuln > 0.0 or _health <= 0:
		return false
	# 举盾 && 攻击来自正面 && 没在破防硬直里 → 走格挡分支
	if _guard_active() and _is_frontal(source_position):
		_block(amount)
		return true
	_health = maxi(_health - amount, 0)
	_invuln = 0.65
	# 受击动画时长：足够把 4 帧受击序列帧播完（~0.22s）并留一点余量，否则挨打只闪一帧看不出「被打」了
	_hurt_timer = 0.32
	var away: float = signf(global_position.x - source_position.x)
	velocity.x = (away if away != 0.0 else float(-_facing)) * 160.0
	velocity.y = -140.0
	# 挨打会打断举盾并让架势暂停回复：不然「一边被打一边回架势」等于没代价
	_guard_since_hit = 0.0
	_last_guard_result = &"hit"
	health_changed.emit(_health, max_health)
	# 挨打的反馈比打人更重（顿帧更长、抖屏更狠）：不然玩家意识不到自己掉血了
	impact.emit(0.8)
	if _health == 0:
		_die()
	return false

## 格挡结算。完美格挡（举盾后极短时间内）与普通格挡的差别全在这里：
## 完美格挡零伤害、回满一截架势、给出额外的打击反馈 —— 它是「读招」的奖励。
func _block(amount: int) -> void:
	if _guard_time <= PARRY_WINDOW:
		_guard = minf(_guard + PARRY_REGEN, GUARD_MAX)
		_last_guard_result = &"perfect"
		# 短促的硬直无敌，避免完美格挡的下一帧被同一段多段伤害连吃
		_invuln = maxf(_invuln, 0.12)
		parried.emit()
		guard_changed.emit(_guard, GUARD_MAX)
		# 完美格挡也算「挡下了」，但反馈给得比普通格挡重，手感上要能分辨出来
		impact.emit(0.45)
		return

	# 普通格挡：吃减伤后的伤害，并扣架势
	var through: int = maxi(int(roundf(float(amount) * (1.0 - GUARD_REDUCTION))), 1)
	_health = maxi(_health - through, 0)
	_guard = maxf(_guard - float(amount) * GUARD_COST_SCALE, 0.0)
	_guard_since_hit = 0.0
	_hurt_timer = 0.08
	# 挡下也有击退感，但比挨打轻得多 —— 举着盾被推着走才对
	velocity.x = float(-_facing) * 60.0
	_last_guard_result = &"blocked"
	health_changed.emit(_health, max_health)
	impact.emit(0.3)

	if _guard <= 0.0:
		_guard_break = GUARD_BREAK_STUN
		_guard_held = false
		_guard_time = 0.0
		_last_guard_result = &"broken"
		guard_broken.emit()

## 举盾是否真的生效：按着键、没在破防硬直、没在翻滚、还活着。
## 收口成一个查询而不是散在各处 —— 「什么算举盾」这条规则只该有一处。
func _guard_active() -> bool:
	return (_guard_held and _guard_break <= 0.0 and _evade_timer <= 0.0
		and _dash_timer <= 0.0 and _health > 0)

## 攻击是否来自正面。用平局处理零向量：正上/正下的攻击按「正面」算，
## 免得有垂直方向的伤害莫名其妙绕过了盾。
func _is_frontal(source_position: Vector2) -> bool:
	var dx: float = source_position.x - global_position.x
	return dx * float(_facing) >= -0.001

func guard_value() -> float:
	return _guard

func is_guarding() -> bool:
	return _guard_active()

func is_guard_broken() -> bool:
	return _guard_break > 0.0

## 上一步受击的结果，表现层用（"hit" / "blocked" / "perfect" / "broken"）
func last_guard_result() -> StringName:
	return _last_guard_result

func heal(amount: int) -> void:
	if _health <= 0:
		return
	_health = mini(_health + amount, max_health)
	health_changed.emit(_health, max_health)

func is_alive() -> bool:
	return _health > 0

# ---------------- 属性：永久加成与武器词条 ----------------

## 吸收一颗能量球：把加成记进永久层并立即整体重算。
## stat 复用 WuxiaWeapon.Stat；value 为「展示单位」——攻击 / 生命是点数，暴击系是百分点。
## 死亡后再吸到球不加成：避免死亡瞬间被残留掉落物改数值，导致死亡画面数据跳动。
func apply_bonus(stat: int, value: float) -> void:
	if _health <= 0:
		return
	match stat:
		WuxiaWeapon.Stat.ATTACK:
			_bonus_attack += int(round(value))
		WuxiaWeapon.Stat.HEALTH:
			_bonus_health += int(round(value))
		WuxiaWeapon.Stat.CRIT_RATE:
			_bonus_crit_rate += value * 0.01
		WuxiaWeapon.Stat.CRIT_DMG:
			_bonus_crit_dmg += value * 0.01
		_:
			push_warning("WuxiaPlayer.apply_bonus: 未知属性 %d，已忽略" % stat)
			return
	_recalc_stats()
	bonus_applied.emit(stat, value)

## 永久加成的只读查询，单位与 WuxiaWeapon.format_stat() 入参口径一致（暴击系是百分点），
## HUD 拿到即可直接格式化。不直接暴露 _bonus_* 字段：只读语义比省一个函数重要。
func permanent_bonus(stat: int) -> float:
	match stat:
		WuxiaWeapon.Stat.ATTACK:
			return float(_bonus_attack)
		WuxiaWeapon.Stat.HEALTH:
			return float(_bonus_health)
		WuxiaWeapon.Stat.CRIT_RATE:
			return _bonus_crit_rate * 100.0
		WuxiaWeapon.Stat.CRIT_DMG:
			return _bonus_crit_dmg * 100.0
	return 0.0

## 装备武器。槽位只有一格：重复调用会整体替换旧武器并重算属性，词条绝不叠加。
func equip_weapon(weapon: WuxiaWeapon) -> void:
	if weapon == null:
		return
	_weapon = weapon
	_recalc_stats()
	weapon_equipped.emit(weapon)

func has_weapon() -> bool:
	return _weapon != null

func current_weapon() -> WuxiaWeapon:
	return _weapon

## 当前攻击力加成总计 = 能量球永久加成 + 武器词条。招式伤害 = 招式基础值 + 本值。
## HUD 与冒烟测试都读这个，不要在别处重复累加两层来源。
func attack_power() -> int:
	return _attack_power

func crit_rate() -> float:
	return _crit_rate

func crit_bonus() -> float:
	return _crit_bonus

## 三层的「基础值 + 永久加成 + 武器词条」整体重算，而不是增量加减：
## 只有一格武器槽，全量重算最不容易在替换武器时漏掉某一层（尤其是能量球那一层）。
func _recalc_stats() -> void:
	_attack_power = _bonus_attack
	var health_bonus: int = _bonus_health
	_crit_rate = BASE_CRIT_RATE + _bonus_crit_rate
	_crit_bonus = BASE_CRIT_BONUS + _bonus_crit_dmg
	if _weapon != null:
		_attack_power += _weapon.main_value
		for sub: Dictionary in _weapon.substats:
			var value: float = float(sub["value"])
			match int(sub["stat"]):
				WuxiaWeapon.Stat.ATTACK:
					_attack_power += int(round(value))
				WuxiaWeapon.Stat.HEALTH:
					health_bonus += int(round(value))
				WuxiaWeapon.Stat.CRIT_RATE:
					_crit_rate += value * 0.01
				WuxiaWeapon.Stat.CRIT_DMG:
					_crit_bonus += value * 0.01

	# 生命上限整体重算，涨出来的部分立刻补给玩家 —— 捡到血装当场回血，手感才对
	var new_max: int = BASE_MAX_HEALTH + health_bonus
	var gained: int = new_max - max_health
	max_health = new_max
	if gained > 0 and _health > 0:
		_health = mini(_health + gained, max_health)
	else:
		_health = mini(_health, max_health)
	health_changed.emit(_health, max_health)

## 招式伤害 = 招式基础值 + 攻击力加成总计（永久加成 + 武器词条）；再按暴击率掷一次，命中则乘上暴击倍率。
## 返回 {damage, crit} 而不是只返回伤害：命中处要据「是不是暴击」同时决定提示与打击反馈强度，
## 而这两件事都该发生在「真的打到了」的那一刻 —— 掷点阶段只负责算数。
func _roll_damage(base: int) -> Dictionary:
	var damage: int = base + _attack_power
	var crit: bool = _rng.randf() < _crit_rate
	if crit:
		damage = maxi(int(roundf(float(damage) * (1.0 + _crit_bonus))), 1)
	return {"damage": maxi(damage, 1), "crit": crit}

# ---------------- 输入 ----------------

func _unhandled_input(event: InputEvent) -> void:
	if _health <= 0:
		return
	if event.is_action_pressed("jump"):
		_jump_buffer = JUMP_BUFFER
	elif event.is_action_pressed("attack"):
		_atk_buffer = ATTACK_BUFFER
	elif event.is_action_pressed("dash"):
		_try_dash()
	elif event.is_action_pressed("evade"):
		_try_evade()
	elif event.is_action_pressed("guard"):
		_begin_guard()

# ---------------- 主循环 ----------------

func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_sync_guard_hold()

	if _health <= 0:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * delta)
		_fall(delta)
		move_and_slide()
		_was_on_floor = is_on_floor()
		return

	_advance_attack(delta)

	if is_on_floor():
		_coyote = COYOTE_TIME
		_jumps_left = MAX_JUMPS
	else:
		_coyote -= delta

	if _evade_timer > 0.0:
		_physics_evade(delta)
	elif _dash_timer > 0.0:
		_physics_dash(delta)
		_tick_dash_ghosts(delta)
	else:
		# busy 只表示「出招中」（脚下生根）。举盾**不算** busy ——
		# 它走的是「降速移动」这条路（GUARD_MOVE_SCALE），
		# 把举盾也塞进 busy 会让玩家举着盾一步都挪不动，那个常量就成了死代码。
		_physics_move(delta, _atk_phase != &"idle")
	_face_input()
	move_and_slide()
	# 落地反馈：上一帧还在空中、这一帧踩实了 —— 一次性触发压扁形变。
	# 用边沿检测而非信号：CharacterBody2D 没有着地信号，is_on_floor 必须在 move_and_slide 之后读。
	if not _was_on_floor and is_on_floor():
		_on_landed()
	_was_on_floor = is_on_floor()
	_update_visuals()

## 举盾的按住 / 松开状态每帧与输入对齐一次。
## 用 `Input.is_action_pressed` 而不是只在 `_unhandled_input` 里收 —— 后者收不到「松开」，
## 一旦切场景或松开时事件被别的节点吃掉，盾就会永远举着。
func _sync_guard_hold() -> void:
	# 破防硬直 / 死亡 / 翻滚期间强制放下盾，且不接受输入
	if _guard_break > 0.0 or _health <= 0 or _evade_timer > 0.0:
		_guard_held = false
		return
	var pressed: bool = Input.is_action_pressed("guard")
	if pressed == _guard_held:
		return
	_guard_held = pressed
	# 重新举盾要刷新计时：完美格挡窗口是「每次举盾」给的，不是全局冷却
	if pressed:
		_guard_time = 0.0

func _tick_timers(delta: float) -> void:
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_atk_buffer = maxf(_atk_buffer - delta, 0.0)
	_combo_timer = maxf(_combo_timer - delta, 0.0)
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	_evade_cd = maxf(_evade_cd - delta, 0.0)
	_invuln = maxf(_invuln - delta, 0.0)
	_hurt_timer = maxf(_hurt_timer - delta, 0.0)
	_guard_break = maxf(_guard_break - delta, 0.0)
	_guard_since_hit = minf(_guard_since_hit + delta, GUARD_REGEN_DELAY)

	if _guard_held and _guard_break <= 0.0:
		_guard_time += delta
	# 放下盾（且不在硬直里）延迟一会儿才开始回架势
	if not _guard_active() and _guard_since_hit >= GUARD_REGEN_DELAY and _guard < GUARD_MAX:
		var before: float = _guard
		_guard = minf(_guard + GUARD_REGEN_IDLE * delta, GUARD_MAX)
		if not is_equal_approx(before, _guard):
			guard_changed.emit(_guard, GUARD_MAX)

	if _atk_phase == &"idle" and _combo_timer <= 0.0 and _atk_step != 0:
		_atk_step = 0
		combo_changed.emit(0)

## 攻击状态机：wind → hit → recover → idle
func _advance_attack(delta: float) -> void:
	if _atk_phase == &"idle":
		return
	_atk_timer -= delta
	if _atk_timer > 0.0:
		return
	var data: Dictionary = COMBO[_atk_step]
	if _atk_phase == &"wind":
		_atk_phase = &"hit"
		_atk_timer = data["hit"]
		_apply_lunge(data)
		_open_hitbox()
	elif _atk_phase == &"hit":
		_close_hitbox()
		_atk_phase = &"recover"
		_atk_timer = data["rec"]
		_combo_timer = COMBO_WINDOW
		_atk_step = 0 if _atk_step + 1 >= COMBO.size() else _atk_step + 1
	else:
		_atk_phase = &"idle"
		if _combo_timer <= 0.0:
			_atk_step = 0
			combo_changed.emit(0)

## 移动。busy = 出招中：招式期间脚下生根，不接受方向输入（举盾不走这里，见调用处）。
func _physics_move(delta: float, busy: bool) -> void:
	var dir: float = Input.get_axis("move_left", "move_right")
	if busy:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * 0.55 * delta)
	else:
		var speed: float = SPEED * (GUARD_MOVE_SCALE if _guard_active() else 1.0)
		var rate: float = ACCEL if dir != 0.0 else FRICTION
		velocity.x = move_toward(velocity.x, dir * speed, rate * delta)
	_fall(delta)

	if _jump_buffer > 0.0 and (_coyote > 0.0 or _jumps_left > 0):
		_jump_buffer = 0.0
		_coyote = 0.0
		_jumps_left -= 1
		velocity.y = JUMP_FORCE * (1.0 if is_on_floor() else AIR_JUMP_SCALE)
		_squash(Vector2(0.78, 1.24))

	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= JUMP_CUT

	if _atk_buffer > 0.0:
		_atk_buffer = 0.0
		_start_attack()

func _physics_dash(delta: float) -> void:
	_dash_timer -= delta
	velocity.x = float(_facing) * DASH_SPEED
	velocity.y = 0.0
	if _dash_timer <= 0.0:
		velocity.x *= 0.4
		# 冲刺结束若还按着盾，盾立刻生效（举盾状态没被打断，只是冲刺期间不判定）
		if _guard_break <= 0.0:
			_guard_time = 0.0

## 翻滚的物理部分：位移靠冲量 + 摩擦自然收掉，与攻击前冲同一套做法。
## 不同的是**翻滚期间速度不被方向键覆盖** —— 否则玩家按住反方向就能原地滚，
## 「翻滚是把自己扔出去」这件事就不成立了。
func _physics_evade(delta: float) -> void:
	_evade_timer -= delta
	velocity.x = move_toward(velocity.x, 0.0, EVADE_FRICTION * delta)
	_fall(delta)
	_tick_dash_ghosts(delta)
	if _evade_timer <= 0.0:
		velocity.x *= 0.5

func _fall(delta: float) -> void:
	if not is_on_floor():
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL)

func _face_input() -> void:
	if _dash_timer > 0.0 or _evade_timer > 0.0:
		return
	var dir: float = Input.get_axis("move_left", "move_right")
	# 出招中不转身（招式方向在起手就定了）；但**举盾时允许转身** ——
	# 举着盾慢慢挪方向是防御的常规操作，不许转身会让「背后来敌」变成无解。
	if dir != 0.0 and _atk_phase == &"idle":
		_facing = 1 if dir > 0.0 else -1

# ---------------- 闪避（翻滚） ----------------

## 起手翻滚。三件事与冲刺刻意不同：
##   ① 无敌帧更长（0.34 vs 0.19）—— 它是躲招用的；
##   ② 可以取消出招的后摇（见下），所以「砍完接翻滚」是成立的连段；
##   ③ 冷却更长（0.75 vs 0.55），不能像冲刺那样连续用。
func _try_evade() -> void:
	if _evade_cd > 0.0 or _evade_timer > 0.0 or _health <= 0:
		return
	# 翻滚可以从「出招的任意阶段」起手：这是它作为对招手段的核心价值 ——
	# 看到对手起手时你不用等自己的三段连击打完。
	_cancel_attack_for_evade()

	_evade_timer = EVADE_TIME
	_evade_cd = EVADE_COOLDOWN
	# 无敌帧覆盖到翻滚结束之后，收招那几帧也是无敌的
	_invuln = maxf(_invuln, EVADE_INVULN)
	velocity.x = float(_facing) * EVADE_SPEED
	velocity.y = 0.0
	_squash(EVADE_SQUASH)
	_guard_held = false
	_guard_time = 0.0
	# 起手先落一张残影，翻滚轨迹才从起点开始拖；之后按间隔补（复用冲刺那套）
	_ghost_timer = GHOST_INTERVAL
	_spawn_ghost()
	evaded.emit()

## 打断当前招式。判定盒必须立刻关掉 —— 留着会在翻滚时继续吃伤害判定，
## 而玩家看到的是「我在滚」，这种不一致是最伤信任的 bug。
func _cancel_attack_for_evade() -> void:
	_close_hitbox()
	_atk_phase = &"idle"
	_atk_timer = 0.0
	_atk_buffer = 0.0
	_combo_timer = 0.0
	if _atk_step != 0:
		_atk_step = 0
		combo_changed.emit(0)

func evade_cooldown_ratio() -> float:
	if EVADE_COOLDOWN <= 0.0:
		return 0.0
	return clampf(_evade_cd / EVADE_COOLDOWN, 0.0, 1.0)

# ---------------- 防御（举盾） ----------------

## 举盾的即时反馈在 _sync_guard_hold() 里对齐，这里只处理「按下瞬间」的表现。
## 破防硬直期间按下无效 —— 那是惩罚窗口。
func _begin_guard() -> void:
	if _health <= 0 or _guard_break > 0.0 or _evade_timer > 0.0 or _dash_timer > 0.0:
		return
	_guard_held = true
	_guard_time = 0.0

# ---------------- 冲刺 ----------------

func _try_dash() -> void:
	if _dash_cd > 0.0 or _health <= 0:
		return
	if not is_on_floor() and _jumps_left >= MAX_JUMPS:
		return
	_dash_timer = DASH_TIME
	_dash_cd = DASH_COOLDOWN
	_invuln = maxf(_invuln, DASH_TIME + 0.04)
	_squash(Vector2(1.25, 0.8))
	# 起手先落一张，残影才会从冲刺的起点开始拖；之后交给 _tick_dash_ghosts 按间隔补
	_ghost_timer = GHOST_INTERVAL
	_spawn_ghost()

# ---------------- 连击 ----------------

func _start_attack() -> void:
	if _atk_phase != &"idle":
		return
	if _combo_timer <= 0.0:
		_atk_step = 0
	_atk_phase = &"wind"
	_atk_timer = COMBO[_atk_step]["wind"]
	_atk_hits.clear()
	combo_changed.emit(_atk_step + 1)

## 攻击前冲：判定帧给一次向前的速度冲量，之后由攻击摩擦自然收掉（数值换算见 COMBO 的 lunge 注释）。
## 位移单靠眼睛不容易察觉，所以同时给一点横向压扁 —— 形变才是「压上去」的重量来源。
func _apply_lunge(data: Dictionary) -> void:
	velocity.x = float(_facing) * float(data["lunge"])
	_squash(Vector2(1.15, 0.9))

func _open_hitbox() -> void:
	var data: Dictionary = COMBO[_atk_step]
	var size: Vector2 = data["box"]
	var reach: float = data["reach"]
	# 判定盒后沿越过身体中线：玩家与敌兵不做物理碰撞，贴身时敌兵会重叠到身体内部，
	# 若判定盒只从身前 reach 处起算就会整场挥空。
	var near: float = ATK_BACK_MARGIN
	var far: float = reach + size.x
	_atk_rect.size = Vector2(far - near, size.y)
	_atk_shape.position = Vector2(float(_facing) * ((near + far) * 0.5), -16.0)
	_atk_hits.clear()
	_atk_area.monitoring = true
	attacked.emit(_atk_step + 1)

func _close_hitbox() -> void:
	_atk_area.monitoring = false

func _on_attack_area_body_entered(body: Node2D) -> void:
	if body == self or _atk_hits.has(body) or _atk_phase != &"hit":
		return
	if not body.has_method("take_damage"):
		return
	_atk_hits.append(body)
	var roll: Dictionary = _roll_damage(int(COMBO[_atk_step]["dmg"]))
	var crit: bool = bool(roll["crit"])
	body.call("take_damage", int(roll["damage"]), global_position)
	if crit:
		crit_landed.emit(int(roll["damage"]))
	impact.emit(_impact_strength(_atk_step, crit))

## 命中反馈强度 0..1：招式段数决定基线，暴击再抬一档。
## 只给「相对轻重」——换算成多少毫秒顿帧、多少像素抖屏是 game.gd 的事。
func _impact_strength(step: int, crit: bool) -> float:
	return minf([0.35, 0.5, 0.75][clampi(step, 0, 2)] + (0.25 if crit else 0.0), 1.0)

# ---------------- 视觉 ----------------

## 形变收尾的吸附阈值：差值小于它就当成已经回到 1（见 _update_visuals）
const SQUASH_SNAP := 0.002

func _squash(scale_v: Vector2) -> void:
	_squash_v = scale_v

## 落地压扁反馈：着地那一下的形变是横版动作「踩实」的来源（重生细胞 / 神之亵渎都靠它）。
## 速度低（小于 0.5 × MAX_FALL）不反馈 —— 否则走路偶尔脚悬空半像素都「duang」一下就过头。
## 强度按速度映射，单跳（约 0.79）轻压扁、二段跳封顶（1.0）压扁更强但都不颠覆手感。
## 落地后由 _update_visuals 里的 lerp 自然收回 1，无需手动复位。
func _on_landed() -> void:
	var strength: float = clampf(absf(velocity.y) / MAX_FALL, 0.0, 1.0)
	if strength < 0.50:
		return
	var t: float = clampf((strength - 0.5) / 0.5, 0.0, 1.0)
	var sx: float = 1.0 + 0.22 * t
	var sy: float = 1.0 - 0.18 * t
	_squash(Vector2(sx, sy))

## 把精灵「补」回整数像素所需的局部偏移。
##
## 主角坐标是物理量（永远是小数），直接画就是在半个像素上采样 —— LINEAR 会糊、NEAREST 会抖。
## 三段参与者必须**同时**是整数才真的对齐：主角（这里）、相机位置、屏震 offset
## （见 game.gd 的 _process 与 _update_shake）。少任何一段，前面就白做了。
func _pixel_snap_offset() -> Vector2:
	return global_position.round() - global_position

func _update_visuals() -> void:
	if _visuals == null:
		return
	# 空中姿态先叠进 _squash_v：上升拉长 / 下落摊开是缺失跳/落贴图时的姿态替身。
	# 实现有强形变在身的几帧（起跳、落地、前冲、翻滚起手）会让位 —— 那几帧形变更重，需先自然收敛。
	_apply_air_pose()
	_squash_v = _squash_v.lerp(Vector2.ONE, 0.2)
	# 形变收尾要**吸附**回 1：lerp 是渐近的，永远差着 0.000x，
	# 于是主角长期挂在一个非整数缩放上被重采样 —— 哪怕站着不动也是糊的。
	if _squash_v.distance_to(Vector2.ONE) < SQUASH_SNAP:
		_squash_v = Vector2.ONE
	_visuals.scale = Vector2(_squash_v.x * float(_facing), _squash_v.y)
	# 像素对齐：主角坐标是物理量（小数），精灵跟着画在半个像素上就会被过滤抹糊（NEAREST 则逐帧抖）。
	# 这里用子节点位置把「世界坐标 - 相机」的差值补回整数，精灵便永远落在整像素上。
	_visuals.position = _pixel_snap_offset()
	_visuals.rotation = 0.12 * float(_facing) if _hurt_timer > 0.0 else 0.0
	_visuals.modulate.a = 1.0 if _invuln <= 0.0 else (0.35 if int(_invuln * 20.0) % 2 == 1 else 0.9)
	_update_sword_pose()
	_update_shield()
	_update_anim()

## 空中姿态：替缺失的跳/落序列帧承担姿势。
## 上升 → 拉长（蹬出去）；下落 → 摊开（准备踩实）。强度刻意弱（±5~8%）：
## 它要叠加在 _squash() 触发的强形变之上而不是替代 —— 起跳那一下压扁仍然最重。
## 触发太低的 vertical 跳变（步过斜坡、误抖）忽略。
func _apply_air_pose() -> void:
	if is_on_floor() or _dash_timer > 0.0 or _evade_timer > 0.0:
		return
	# 已有强形变在身（起跳 / 落地 / 前冲 / 翻滚）→ 让它先收敛，避免被空中态立刻覆盖
	if _squash_v.distance_to(Vector2.ONE) > 0.08:
		return
	if velocity.y < -60.0:
		_squash_v = Vector2(0.92, 1.08)
	elif velocity.y > 120.0:
		_squash_v = Vector2(1.05, 0.96)

## 长剑姿态：剑客恒持长剑，默认就挂在身侧，不依赖是否拾到武器掉落物
## （拾取只换数值词条，不改变「手里这把剑」）。分三条主轴：
## - 出招三段：wind 举剑过头 / hit 平劈出 / recover 收剑 —— 连击剑姿差异是横向卡顿感的载体。
## - 受击：剑被震得垂下；跳跃/下落：横持于身前（收拢不碍事）。
## - 翻滚：收剑（卷成一团），否则滚出去剑还会戳在身侧，像没缩起来。
func _update_sword_pose() -> void:
	if _sword == null:
		return
	# 翻滚时收剑；其余状态恒持
	var showing: bool = _evade_timer <= 0.0
	_sword.visible = showing
	if not showing:
		return
	match _atk_phase:
		&"wind":
			_sword.rotation = -1.55
		&"hit":
			_sword.rotation = 0.0
		&"recover":
			_sword.rotation = 0.85
		_:
			# 受击：剑被震得垂下；空中：横持身前；其余：身侧握剑预备姿
			if _hurt_timer > 0.0:
				_sword.rotation = 1.2
			elif not is_on_floor():
				_sword.rotation = 0.2
			else:
				_sword.rotation = 0.55

## 举盾必须有可见的盾：玩家要靠它判断「挡住了没有」，光凭血条纹丝不动是读不出来的。
## 盾挂在 _visuals 下，所以自动跟着朝向翻面 —— 盾永远在角色正面，背后来的攻击不生效，
## 视觉与判定天然对齐（这也是 _is_frontal 与之配套的原因）。
##
## 三种状态用颜色区分，一眼可读：
##   银白 = 举盾中 / 金黄 = 完美格挡窗口内（前 PARRY_WINDOW 秒）/ 暗红 = 破防硬直
func _update_shield() -> void:
	if _shield == null:
		return
	var active: bool = _guard_active()
	_shield.visible = active or _guard_break > 0.0
	if not _shield.visible:
		return
	if _guard_break > 0.0:
		_shield.color = C_BREAK
	elif _guard_time <= PARRY_WINDOW:
		_shield.color = C_PARRY
	else:
		_shield.color = C_SHIELD

## 动作状态机：受击 > 出招 > 空中 > 奔跑 > 待机。
## 优先级是这套规则里最容易做反的地方 —— 受击/出招必须压过「空中」「奔跑」，
## 否则挨打还在原地跑、出招还播着跑步，动作就全乱了。
##
## 攻击/受击是 loop=false 的一次性动画：_apply_anim 在「已是该动画」时会直接返回不重播，
## 所以每次重新进入（_atk_phase 从 idle 起手、或 _hurt_timer 从 0 变正）才会从头播，
## 正是「每一击/每一次挨打都重播」要的效果。
func _update_anim() -> void:
	if _anim == null:
		return
	var next: StringName
	if _hurt_timer > 0.0:
		next = ANIM_HURT
	elif _atk_phase != &"idle":
		next = ANIM_ATTACK
	elif not is_on_floor():
		next = ANIM_JUMP
	elif absf(velocity.x) > 1.0:
		next = ANIM_RUN
	else:
		next = ANIM_IDLE
	_apply_anim(next)

# ---------------- 冲刺残影 ----------------

## 按固定间隔落残影。只在冲刺期间被调用（见 _physics_process）。
func _tick_dash_ghosts(delta: float) -> void:
	_ghost_timer -= delta
	if _ghost_timer > 0.0:
		return
	_ghost_timer = GHOST_INTERVAL
	_spawn_ghost()

## 落一张残影：直接拿当前帧的 AtlasTexture 当定格快照，不复制动画状态。
##
## top_level = true 是这里的关键 —— 残影要留在**生成时那个位置**。
## 不设它，残影作为主角子节点会跟着主角一起走，那就成了「身上叠了个重影」而不是拖尾。
func _spawn_ghost() -> void:
	if _anim == null or _anim.sprite_frames == null:
		return
	var frame_tex: Texture2D = _anim.sprite_frames.get_frame_texture(_anim.animation, _anim.frame)
	if frame_tex == null:
		return

	var ghost := Sprite2D.new()
	ghost.texture = frame_tex
	ghost.centered = false
	ghost.offset = _anim.offset
	ghost.top_level = true
	ghost.texture_filter = _anim.texture_filter
	ghost.modulate = C_GHOST
	_ghosts.add_child(ghost)
	# 进树之后再写 global_* ：top_level 节点的 global 与 local 同义，但没进树时写 global_ 不可靠
	# 同样取整：残影是脱离主角的独立节点，不跟着 _visuals 的对齐补偿走
	ghost.global_position = global_position.round()
	ghost.global_scale = Vector2(float(_facing), 1.0)

	var tween := create_tween()
	tween.tween_property(ghost, "modulate:a", 0.0, GHOST_FADE)
	tween.tween_callback(ghost.queue_free)

func _die() -> void:
	_close_hitbox()
	set_physics_process(false)
	# 物理停了，_update_visuals 不再跑；不清掉的话尸体会一直原地跑步
	if _anim != null:
		_anim.pause()
	_visuals.rotation = -1.4
	_visuals.position = Vector2(0, 6)
	died.emit()

# ---------------- 节点构建 ----------------
# 多边形绘制工具已抽到 Gfx（scripts/gfx.gd）：Boss、武器掉落物都要画图，
# 让它们去依赖「主角」这个无关的类说不过去。

func _build_visuals() -> void:
	# 残影容器必须先加：同一 z 下按加入顺序绘制，先加才画在主角背后
	_ghosts = Node2D.new()
	_ghosts.name = "Ghosts"
	add_child(_ghosts)

	_visuals = Node2D.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	# 长剑（先画，位于身体后方；rotation 绕节点原点即握把处旋转）。
	# 序列帧里的角色是空手的，所以这把剑仍然保留：它是「正在出招」最直接的可视反馈。
	_sword = Gfx.make_poly(_visuals, Gfx.rect_poly(-2, -1.5, 26, 1.5), C_STEEL, Vector2(2, -20))
	_sword.visible = false
	# 盾（画在身体之前，压在身后；举盾时才是可见的）。多边形刻意做窄：
	# 480x270 的视口里角色只有 48px 高，太宽的盾会把身体整个遮住。
	_shield = Gfx.make_poly(_visuals, PackedVector2Array([
		Vector2(-3, -30), Vector2(4, -32), Vector2(7, -22),
		Vector2(7, -12), Vector2(0, -8), Vector2(-3, -14),
	]), C_SHIELD, Vector2(9, -20))
	_shield.visible = false
	_build_body()

## 主角身体：优先用序列帧，贴图缺失（新克隆的仓库、还没被编辑器导入）时回退成多边形小人。
## 回退不是可有可无的洁癖：一旦主角隐形，整局游戏就废了。
func _build_body() -> void:
	if _build_anim():
		return
	push_warning("主角序列帧缺失，本次改用多边形小人（见 player.gd 的 ANIMS 常量）")
	# 袍身
	Gfx.make_poly(_visuals, Gfx.rect_poly(-7, -28, 7, -2), C_ROBE)
	# 衣摆
	Gfx.make_poly(_visuals, PackedVector2Array([Vector2(-8, -4), Vector2(8, -4), Vector2(5, 2), Vector2(-5, 2)]), Color("#1f2b40"))
	# 腰带
	Gfx.make_poly(_visuals, Gfx.rect_poly(-7.5, -15, 7.5, -11), C_SASH)
	# 头
	Gfx.make_poly(_visuals, Gfx.rect_poly(-5, -39, 5, -28), C_SKIN)
	# 发髻
	Gfx.make_poly(_visuals, PackedVector2Array([Vector2(-6, -39), Vector2(6, -39), Vector2(6, -43), Vector2(0, -46), Vector2(-6, -43)]), C_HAIR)
	# 眼
	Gfx.make_poly(_visuals, Gfx.rect_poly(1, -35, 4, -33.5), C_HAIR)

## 建立 AnimatedSprite2D 并把 ANIMS 里每条动画都切好。返回 false 表示贴图没能加载，调用方走回退。
func _build_anim() -> bool:
	for anim_name: StringName in ANIMS:
		if not ResourceLoader.exists(ANIMS[anim_name]["sheet"]):
			return false

	var frames := SpriteFrames.new()
	# SpriteFrames 自带一条空动画，第一条直接改名复用，免得留一条没人播的 default
	var first := true
	for anim_name: StringName in ANIMS:
		var cfg: Dictionary = ANIMS[anim_name]
		var tex: Texture2D = load(cfg["sheet"]) as Texture2D
		if tex == null:
			return false
		if first:
			frames.rename_animation(&"default", anim_name)
			first = false
		else:
			frames.add_animation(anim_name)
		frames.set_animation_speed(anim_name, cfg["fps"])
		frames.set_animation_loop(anim_name, ANIM_LOOP.get(anim_name, true))
		_add_frames(frames, anim_name, tex, cfg)
		# 把「脚底中线」对到节点原点：主角的原点在脚底（受击盒 y -28..0、敌兵也按脚底对齐）
		var cell := Vector2(
			float(tex.get_width()) / float(cfg["cols"]),
			float(tex.get_height()) / float(cfg["rows"]))
		# 取整：锚点是比例（-cell × 0.5117 = -20.468 这类小数），留着它精灵就永远
		# 画在半个像素上，过滤时会把整帧抹糊。锚点差 0.5px 肉眼无感，对齐却差很多。
		_anim_offsets[anim_name] = (-cell * (cfg["anchor"] as Vector2)).round()

	_anim = AnimatedSprite2D.new()
	_anim.name = "Anim"
	_anim.sprite_frames = frames
	_anim.centered = false
	# 用项目默认的「最近邻」（project.godot 的 default_texture_filter=0）。
	# 之前这里单独开线性过滤，是为了压住「半像素位移 → 逐帧抖动」，代价是主角全场最糊。
	# 现在主角坐标、相机、屏震都做了整像素对齐（_pixel_snap_offset / game.gd），
	# 抖动的成因没了，就可以回到最近邻 —— 与其余像素素材同一套风格，放大是硬像素块。
	# 万一哪天又看到边缘在跳（多半是哪处对齐漏了），把这个常量改回 LINEAR 即可定位：
	# 改完立刻不抖 = 对齐的问题，不是过滤的问题。
	_anim.texture_filter = PLAYER_TEXTURE_FILTER
	_visuals.add_child(_anim)
	_apply_anim(ANIM_IDLE)
	# 朝向翻转交给 _visuals.scale（不用 AnimatedSprite2D.flip_h）：
	# 锚点已经对在 x=0 上，整体镜像后锚点仍在原处，翻面不会让角色横向跳一下。
	return true

## 把一条序列图按网格切成帧，追加到指定动画上。
## 用 AtlasTexture 切格而不是给 Sprite2D 设 hframes/vframes：那样得自己写逐帧累加器，
## 而帧率交给 SpriteFrames 是声明式的，也让「帧数 / 帧率」能在测试里直接断言。
## order 允许乱序播放（与敌兵管线同义）：攻击图第 0 格是举剑、第 2 格是下劈，
## 重排后动作才连顺；不填则按网格序 0,1,2,3 播放。
func _add_frames(frames: SpriteFrames, anim: StringName, tex: Texture2D, cfg: Dictionary) -> void:
	var cols: int = cfg["cols"]
	var cell_w: int = tex.get_width() / cols
	var cell_h: int = tex.get_height() / int(cfg["rows"])
	var order: Array = cfg.get("order", [])
	for order_index: int in int(cfg["frames"]):
		var i: int = order_index if order.is_empty() else int(order[order_index])
		var frame_tex := AtlasTexture.new()
		frame_tex.atlas = tex
		frame_tex.region = Rect2(
			float(i % cols * cell_w), float(i / cols * cell_h),
			float(cell_w), float(cell_h))
		frames.add_frame(anim, frame_tex)

## 切到指定动画。offset 必须跟着换 —— 两条序列图的格子尺寸与帧锚点都不同，
## 共用一个 offset 会让角色在切换的那一帧纵向跳一下。已是该动画时直接返回，不重播。
func _apply_anim(anim: StringName) -> void:
	if _anim == null or _anim_current == anim:
		return
	_anim_current = anim
	_anim.animation = anim
	_anim.offset = _anim_offsets.get(anim, Vector2.ZERO)
	_anim.play()

func _build_hitboxes() -> void:
	var body_rect := RectangleShape2D.new()
	body_rect.size = Vector2(12, 28)
	var body_shape := CollisionShape2D.new()
	body_shape.shape = body_rect
	body_shape.position = Vector2(0, -14)
	add_child(body_shape)

	_atk_rect = RectangleShape2D.new()
	_atk_shape = CollisionShape2D.new()
	_atk_shape.shape = _atk_rect
	_atk_area = Area2D.new()
	_atk_area.name = "AttackHitbox"
	_atk_area.collision_layer = 0
	_atk_area.collision_mask = 4
	_atk_area.monitoring = false
	_atk_area.add_child(_atk_shape)
	add_child(_atk_area)
	_atk_area.body_entered.connect(_on_attack_area_body_entered)
