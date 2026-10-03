extends Node

## 冒烟测试驱动：加载 main.tscn 并脚本化模拟操作，把核心玩法路径全部走一遍
## （移动 / 跳跃 / 二段跳 / 冲刺 / 三段连击 / 受击 / 斩杀 / 出关 / 死亡
##  + 守关 Boss 生成与击杀 / 武器掉落 / 按拾取键（E）拾取 / 单槽替换
##  + 能量球掉落 / 进入磁吸圈自动飞向玩家 / 永久加成在换武器后仍然存在）。
## 任何 GDScript 层面的错误都会打印到控制台，同时输出断言结果。
##
## 用法：
##   godot --headless --path <项目目录> res://tests/smoke_test.tscn

const SCENE_PATH := "res://scenes/main.tscn"
const REQUIRED_ACTIONS: PackedStringArray = [
	"move_left", "move_right", "jump", "attack", "dash", "restart", "pickup",
	"guard", "evade",
]
const MAX_FRAMES := 1200

var _frame: int = 0
var _fails: int = 0
var _game: WuxiaGame
var _player: WuxiaPlayer
var _enemies: Node
var _pickups: Node
var _orbs: Node
var _rng := RandomNumberGenerator.new()
var _release_at: Dictionary = {}
## 场上一颗能量球的数值快照：吸取后要拿它跟永久加成层比对，验证「写的多少就加多少」
var _orb_node: WuxiaEnergyOrb = null
var _orb_stat: int = WuxiaWeapon.Stat.ATTACK
var _orb_value: float = 0.0
## 玩家落点与球心的距离，用于证明球是「被磁吸过来」而不是被踩到的
var _magnet_gap_before: float = 0.0
## 死亡后放在尸体旁的球：用来验证「玩家倒下则磁吸失效」
var _dead_orb: WuxiaEnergyOrb = null
var _dead_orb_pos: Vector2 = Vector2.ZERO
var _dead_perm_before: float = 0.0
## 背景底图节点与「起跑时」的横向位置：跑完整关后要拿它验证视差确实产生了位移
var _bg_plate: Sprite2D = null
var _bg_x_start: float = 0.0
## 主角序列帧节点（见 _check_player_anim），以及待机时的绘制偏移（用来验证切动画会换偏移）
var _player_anim: AnimatedSprite2D = null
var _anim_offset_idle: Vector2 = Vector2.ZERO
## 残影容器（见 _check_dash_ghosts_*）与「前冲用例」起手时的横坐标
var _ghosts: Node = null
var _lunge_x: float = 0.0
## 前冲 / 屏震都按**窗口**采样，而不是赌某一帧：
## 三段连击的后摇时长不等（0.12/0.14/0.28s），加上攻击循环每 20 帧点一次，
## 「哪一帧正好在判定帧」是会变的；屏震更是由 game 的空闲帧写 camera.offset，
## 物理帧里读到的是上一帧的值。窗口取极值才稳。
var _lunge_vmax: float = 0.0
var _shake_seen: bool = false
## 探针掉出的球 —— 只记「有没有掉出来」「有没有被吸走」两个事实，不记节点引用：
## 球被吸走后 0.18s 就 queue_free 了，到断言那一帧引用早悬空了。
var _drop_probe: Area2D = null
var _probe_spawned: bool = false
var _probe_collected: bool = false
## 竖井（480~620）的下层石室。这些数字全部由 PLATFORMS 现算，不抄常量 ——
## 关卡一改尺寸，断言跟着一起变，不会变成一份过期的说明书。
var _pit_left: float = 0.0
var _pit_right: float = 0.0
## 坑底可站立面的 y，以及「第一级石阶」的顶面 y
var _pit_floor_top: float = 0.0
var _pit_step_top: float = 0.0
## 主地面顶面与底边：用来验证坑底与主地面底边齐平（不留夹缝）
var _main_ground_top: float = 0.0
var _ground_bottom: float = 0.0
## 掉进竖井前的血量：坠落本身不该扣血
var _pit_hp_before: int = 0
## 封边岩壁用例：左壁的壁面 x 与壁顶 y，以及窗口内玩家到过的「最左 x / 最高 y」
var _wall_face: float = 0.0
var _wall_top: float = 0.0
var _wall_min_x: float = 0.0
var _wall_min_y: float = 0.0
## 攀墙用例：被翻的那道墙（取最高的一道），以及本轮窗口内玩家到过的最大 x
var _climb_wall: Rect2 = Rect2()
var _climb_max_x: float = 0.0

## ---------------- 闪避 / 防御用例的状态 ----------------
## 翻滚：起手前的 x（用来量位移）、窗口内是否出现过无敌
var _evade_x: float = 0.0
var _evade_invuln_seen: bool = false
var _evade_moved: float = 0.0
## 翻滚位移窗口内玩家到过的最远 x
var _evade_max_x: float = 0.0
## 防御：受击前的血量 / 架势，用来断言「扣了多少」
var _guard_hp_before: int = 0
var _guard_value_before: float = 0.0
## 完美格挡是否触发过（信号只有 0.12s 的窗口，必须在窗口内采样）
var _parry_seen: bool = false
## 破防是否触发过
var _break_seen: bool = false
## 破防硬直期间尝试举盾后，盾是否真的没生效
var _break_guard_probe: bool = false
## 移动力：翻滚与冲刺都必须在「速度归零」时测量，才能干净地比出大小
var _evade_speed_max: float = 0.0
var _dash_speed_max: float = 0.0
## 举盾时的峰值移速（验证「能缓步挪但明显更慢」）
var _guard_move_speed_max: float = 0.0

func _ready() -> void:
	_rng.randomize()
	for action: String in REQUIRED_ACTIONS:
		_assert(InputMap.has_action(action), "输入映射存在：%s" % action)

	var packed: PackedScene = load(SCENE_PATH) as PackedScene
	_assert(packed != null, "main.tscn 可加载")
	if packed == null:
		_finish()
		return

	_game = packed.instantiate() as WuxiaGame
	add_child(_game)
	_player = _game.get_node_or_null("Player") as WuxiaPlayer
	_enemies = _game.get_node_or_null("Enemies")
	_pickups = _game.get_node_or_null("Pickups")
	_orbs = _game.get_node_or_null("Orbs")
	_assert(_player != null, "Player 节点存在")
	_assert(_enemies != null, "Enemies 节点存在")
	_assert(_pickups != null, "Pickups 节点存在（武器掉落挂载点）")
	_assert(_orbs != null, "Orbs 节点存在（能量球挂载点）")
	if _enemies != null:
		_assert(_enemies.get_child_count() == 4, "生成 4 个敌兵（实际 %d）" % _enemies.get_child_count())
	print("[smoke] 驱动开始")

func _physics_process(_delta: float) -> void:
	_frame += 1
	_flush_releases()

	match _frame:
		# —— Boss 与掉落（放在杂兵战斗之前，避免两条玩法线互相干扰）——
		2: _check_boss_spawned()
		5:
			_check_background()
			_check_player_anim()
			_check_lunge_config()
			_check_pit_geometry()
			_check_end_walls()
			_check_walls()
		6: _kill_boss()
		# 10 帧时玩家还在起点，能量球应该躺在 Boss 尸体旁边
		10: _check_energy_orb()
		12: _check_weapon_drop()
		# 16 帧：玩家只是「走近」了 28px，没碰、没按键，球应当已自己飞过来被吸走
		16: _check_magnet_pull()
		20: _tap("pickup")
		26: _check_weapon_equipped()
		32:
			_check_orb_absorbed()
			_player.global_position = Vector2(60, 280)
		36: _check_permanent_bonus()
		46: _check_drops_cleared()
		# —— 原有玩法主线 ——
		30: _hold("move_right", 400)
		40: _hold("jump", 8)
		80:
			_hold("jump", 8)
			_check_player_anim_running()
		120: _tap("dash")
		# 冲刺残影：起手就落一张，之后按间隔补；FADE 之后必须自己回收干净
		121: _check_dash_ghosts_spawned()
		210: _check_dash_ghosts_cleared()
		260: _tap("dash")
		# —— 掉落物的物理回调用例（趁玩家还在疾跑，敌人未近身）——
		# —— 攀墙用例：同一道墙，单跳翻不过 / 接上二段跳能翻过 ——
		# 「真实挥砍能击杀敌兵」这条回归断言（判定盒后沿曾从身前 14px 起算，贴身整场挥空）
		# 必须在**清空敌兵之前**断言：攀墙用例会把场上敌兵全清掉，放在它后面就是恒真断言了。
		258: _assert(_enemies.get_child_count() < 4, "真实挥砍能击杀敌兵（攀墙前剩余 %d 人）" % _enemies.get_child_count())
		# 272 / 330 两轮落点完全相同，差别只在 357 那一下二段跳
		272: _start_wall_climb()
		278: _hold("jump", 21)
		326: _check_wall_single_jump_fails()
		330: _start_wall_climb()
		336: _hold("jump", 22)
		# 顶点在第 21 帧（JUMP_FORCE / GRAVITY ≈ 0.343s），此时接二段跳才是最大爬升。
		# **松手与再按必须错开至少一帧**：同一帧里先 release 再 press 的话，
		# 玩家那帧既读到 just_pressed（起跳）也读到 just_released（松手截断 JUMP_CUT），
		# 新跳的初速度会被当场砍掉 55% —— 实测只能爬 15px，墙自然翻不过去。
		# 所以上一段按 22 帧（松手发生在顶点之后，截断掉的只有十几 px/s 的余速），
		# 再按放在松手的下一帧。
		359: _hold("jump", 22)
		393: _check_wall_double_jump_clears()
		400: _arm_drop_probe()
		406: _step_onto_drop_probe()
		425: _check_probe_orb_absorbed()
		430:
			_release("move_right")
			_report("停手")
		# —— 攻击前冲：先把玩家挪到一段没有坑、也不挨着敌兵的平地上 ——
		# 有了前冲，一路按右跑会推进得快很多，这一段本来就会滑进 480~620 的竖井；
		# 竖井里现在是坑底与石阶（不是平地），在空中测前冲会失去「脚踩在地上」的语义，
		# 所以显式归位。
		432: _player.global_position = Vector2(640, 280)
		# 等玩家站定（无输入），此时速度只可能来自前冲
		437: _check_lunge_ready()
		474: _check_lunge_applied()
		460:
			_player.take_damage(25, _player.global_position + Vector2(-40, 0))
		494: _check_feedback_fired()
		500, 540: _kill_one_enemy()
		600: _player.global_position = Vector2(1640, 280)
		620: _check_background_parallax()
		640: _report("进入关门后")
		# —— 竖井：掉下去不致死，还能原地爬回主层（这一段以前是无底的）——
		645: _clear_enemies()
		650: _drop_into_pit()
		690: _check_pit_landed()
		695: _hold("move_right", 105)
		# 按住右起跳：单跳 82px 越过 45px 的一级落差绰绰有余
		700: _hold("jump", 16)
		750: _check_on_pit_step()
		755: _hold("jump", 16)
		800: _check_climbed_out()
		# —— 关卡两端的封边岩壁：以前走出地形就一直往下掉 ——
		805: _start_wall_probe()
		# 跳满 20 帧（松手会被 player 的「松手截断跳跃高度」砍掉一截，那样只爬到 110px 上下，
		# 压不到最坏情况）；单跳顶点在第 21 帧（JUMP_FORCE / GRAVITY = 480/1400 ≈ 0.343s），
		# 所以第 829 帧正好在顶点接二段跳 —— 这才是理论最高的翻墙尝试。
		# 改 JUMP_FORCE 就得同步改这个帧号，否则二段跳接早了，探针就压不满最坏情况。
		808: _hold("jump", 20)
		829: _hold("jump", 20)
		870: _check_wall_blocked()
		# —— 闪避（翻滚）：位移 / 无敌 / 比冲刺慢 ——
		# 时间线上的每个场景都必须等**上一个场景的瞬态（无敌帧 / 翻滚）彻底走完**再开始。
		# 这不是保守：_face_input 在翻滚期间会早退，朝向类的前提设置会被静默吞掉（踩过一次）。
		872: _reset_flat_stance()
		874: _hold("move_right", 3)
		880: _check_evade_ready()
		882: _tap("evade")
		900: _check_evade_effect()
		# 冲刺对照：与翻滚在**完全相同的条件下**（平地、静止起手、朝右）测一次。
		# 不复用第 120 帧那次冲刺 —— 那时玩家是跑动中冲刺，量出来的峰值不可比，
		# 对照组不可比就等于没有对照。
		906: _reset_flat_stance()
		908: _hold("move_right", 3)
		# 留足落地时间：_try_dash 有「空中不可冲刺」的保护（_jumps_left >= MAX_JUMPS），
		# 重置后玩家悬在地面上方 20px，不等落地就按冲刺会被直接拒收（实测峰值 0）。
		922: _tap("dash")
		940: _check_dash_reference()
		# —— 翻滚取消出招：挥刀后 2 帧就翻滚，此刻还在 wind（0.05s ≈ 3 帧）里 ——
		946: _tap("attack")
		948: _tap("evade")
		954: _check_evade_cancelled_attack()
		# —— 防御（举盾 / 完美格挡 / 架势 / 破防）——
		# 等 948 那次翻滚走完（0.26s ≈ 16 帧）再定朝向，否则 _face_input 早退、朝左会失败
		970: _reset_flat_stance()
		972: _hold("move_left", 3)
		976: _check_facing_left()
		# ① 举盾时可以缓步移动：速度有明显衰减但**不为零**。
		#    这条曾静默失效 —— 举盾被当成「出招中」走了减速到 0 的分支，
		#    GUARD_MOVE_SCALE 成了死代码，玩家举着盾一步都挪不动。
		978: _probe_guard_move()
		998: _check_guard_move()
		# 这一步按了 18 帧的「右」，朝向已经翻过去了 —— 必须重新定回朝左。
		# 朝向是「背后攻击不吃格挡」的前提，不重设的话测出来的就不是「盾只挡正面」。
		1000: _hold("move_left", 3)
		1004: _check_facing_left()
		# ② 背后来的攻击照常吃满：盾只挡正面。**先测这一条** ——
		#    不格挡的受击会给 0.65s 无敌帧，放到后面会把随后的格挡用例全部吃掉。
		1006: _begin_guard_probe()
		1010: _hit_player_from_back(20)
		1012: _check_back_not_blocked()
		1014: _release("guard")
		# 等无敌帧走完（0.65s ≈ 39 帧，从 1010 起算 → 1049）
		# ③ 普通格挡：举盾熬过 PARRY_WINDOW（0.18s = 11 帧）之后再挨打
		1056: _begin_guard_probe()
		1070: _hit_player_from_front(20)
		1072: _check_front_block()
		# ④ 完美格挡：收起盾再按一次 → 计时重置 → 窗口内挡下 = 零伤害 + 回架势
		1074: _release("guard")
		1076: _begin_guard_probe()
		1078: _hit_player_from_front(20)
		1080: _check_perfect_parry()
		# ⑤ 架势打空 → 破防；破防期间举盾必须无效
		1082: _release("guard")
		1084: _begin_guard_probe()
		1098: _hit_player_from_front(60)
		1100: _check_guard_broken()
		1102: _probe_guard_during_break()
		1104: _check_guard_dead_during_break()
		# —— 死亡 ——
		1108: _player.take_damage(999, _player.global_position + Vector2(-40, 0))
		# 玩家已倒下：往尸体旁放一颗球，磁吸必须不生效
		1112: _spawn_orb_beside_corpse()
		1152:
			_check_dead_player_ignored()
			_check_shake_settled()

	# 连击循环：每 20 帧挥砍一次，覆盖 wind → hit → recover → 续段
	# 攀墙用例那一段刻意不出招：出招会把水平速度压到 0（_physics_move 的 busy 分支），
	# 玩家在越顶那几帧就挪不过去 —— 翻墙断言会被连击节奏污染，量到的就不是跳跃能力了。
	if _frame >= 140 and _frame <= 580 and (_frame - 140) % 20 == 0 and not (_frame >= 330 and _frame <= 393):
		_tap("attack")

	# 窗口采样：这一段没有方向键输入，横向速度只可能来自攻击前冲。
	if _frame >= 437 and _frame <= 470:
		_lunge_vmax = maxf(_lunge_vmax, absf(_player.velocity.x))
	# 屏震全程采样。刻意不绑在某一帧某一次伤害上：挨打可能落在 0.65s 无敌帧里被拒收，
	# 而命中敌人、被打死都会发同样的反馈，整段跑下来只要出现过非零偏移就算数。
	_shake_seen = _shake_seen or _camera_offset().length() > 0.01
	# 封边采样：玩家到过的「最左 x」（有没有越过左壁）与「最高 y」（有没有跳上壁顶）
	if _frame >= 805 and _frame <= 870 and _player.is_alive():
		_wall_min_x = minf(_wall_min_x, _player.global_position.x)
		_wall_min_y = minf(_wall_min_y, _player.global_position.y)
	# 攀墙采样：窗口内玩家到过的最大 x（翻没翻过去只看最远到过哪，不必等他落地）
	if _frame >= 272 and _frame <= 393 and _player.is_alive():
		_climb_max_x = maxf(_climb_max_x, _player.global_position.x)

	# 翻滚采样：窗口内「出现过无敌」与「到过的最远 x」。
	# 无敌帧只有 0.34s（约 20 帧），窗口内取极值比赌某一帧稳。
	if _frame >= 882 and _frame <= 900 and _player.is_alive():
		if float(_player.get("_evade_timer")) > 0.0:
			_evade_invuln_seen = _evade_invuln_seen or float(_player.get("_invuln")) > 0.0
		_evade_max_x = maxf(_evade_max_x, _player.global_position.x)
		_evade_speed_max = maxf(_evade_speed_max, absf(_player.velocity.x))
	# 冲刺对照采样（第 922 帧那次冲刺，与翻滚同条件）。
	# **只取冲刺计时器还在跑的那几帧**：窗口放宽会把「按右跑」的 170px/s 也当成冲刺速度，
	# 对照就成了假的（实测放宽到 940 帧时峰值里混着跑步速度）。
	if _frame >= 922 and _frame <= 942 and _player.is_alive():
		if float(_player.get("_dash_timer")) > 0.0:
			_dash_speed_max = maxf(_dash_speed_max, absf(_player.velocity.x))
	# 举盾移速采样：只取真的在举盾的帧
	if _frame >= 978 and _frame <= 1000 and _player.is_alive() and _player.is_guarding():
		_guard_move_speed_max = maxf(_guard_move_speed_max, absf(_player.velocity.x))
	# 完美格挡只有 0.18s 窗口，且信号发出后转瞬即逝 —— 全程挂标记，别赌某一帧
	if _frame >= 976 and _frame <= 1104 and _player.is_alive():
		_parry_seen = _parry_seen or _player.last_guard_result() == &"perfect"
		_break_seen = _break_seen or _player.is_guard_broken()

	if _frame == 1180:
		_assert(not _player.is_alive(), "死亡路径：is_alive() 为 false")
		_assert(_enemies.get_child_count() < 4, "斩杀路径：敌兵数量减少")
		_report("结束前")

	if _frame >= MAX_FRAMES:
		_finish()

# ---------------- 背景底图 ----------------

## 关卡背景必须真的用上了场景底图，而不是静默回退到程序化背景。
## 贴图是按「480 视口 + 视差滑移余量」定宽处理的（tools/make_background.py），
## 宽度一旦不够，关卡两端就会露出底图外的空白，所以宽度本身就是一条断言。
func _check_background() -> void:
	var layer: Node = _game.get_node_or_null("Background")
	_assert(layer != null, "背景层 Background 存在（场景底图已接入）")
	if layer == null:
		return
	_bg_plate = layer.get_node_or_null("ScenePlate") as Sprite2D
	_assert(_bg_plate != null, "底图节点 ScenePlate 存在")
	if _bg_plate == null:
		return
	_assert(_bg_plate.texture != null, "底图贴图已加载")
	if _bg_plate.texture == null:
		return
	var tw: int = _bg_plate.texture.get_width()
	# 需要多宽：底图以「相机行程中点」为原点、按 BG_MOTION_X 跟随，
	# 最大滑移 = BG_MOTION_X × 相机中心行程 / 2，左右各要这么多留量 → 视口宽 + 两倍滑移。
	# 写成算式而不是硬编码 551：相机限位一改（比如为了让两端岩壁留在画面里而放宽），
	# 这个数就该跟着变，硬编码的话它会悄悄失效。
	var cam: Camera2D = _camera()
	var travel: float = (float(cam.limit_right) - float(cam.limit_left)) - WuxiaGame.VIEW.x
	var need: float = WuxiaGame.VIEW.x + WuxiaGame.BG_MOTION_X * travel
	_assert(float(tw) >= need, "底图宽度够盖住视口 + 视差滑移（实际 %d，需 ≥ %.0f）" % [tw, need])
	_assert(_bg_plate.position.y == 0.0, "底图顶边贴住屏幕顶边（实际 %.1f）" % _bg_plate.position.y)
	_bg_x_start = _bg_plate.position.x

## 视差是「相机右移 → 底图左滑」，且滑移量必须远小于相机行程（远景）。
## 只断言「有位移」不够：把底图当普通世界物体挂上去也会产生位移，但那就不是视差了。
func _check_background_parallax() -> void:
	if _bg_plate == null:
		return
	var dx: float = _bg_plate.position.x - _bg_x_start
	var cam_travel: float = _game.get_node("Player").global_position.x - 60.0
	_assert(dx < -1.0, "相机右移时底图向左滑移（dx = %.1f）" % dx)
	_assert(absf(dx) < absf(cam_travel) * 0.2, "底图滑移远小于相机行程，属远景（dx = %.1f）" % dx)

# ---------------- 主角序列帧 ----------------

## 每条动画期望的「帧数 / 帧率」。帧率是用户明确要求的 9 FPS，这里把它钉死。
const ANIM_SPEC: Array = [[&"idle", 20], [&"run", 9]]

## 主角身体必须真的换成了序列帧（贴图在、两条动画、帧数与帧率对、
## 每帧取自不同格子），而不是静默回退成多边形小人。回退能保证游戏不废，但绝不能悄悄发生。
func _check_player_anim() -> void:
	_player_anim = _player.get_node_or_null("Visuals/Anim") as AnimatedSprite2D
	_assert(_player_anim != null, "主角序列帧节点 Visuals/Anim 存在（贴图已接入）")
	if _player_anim == null:
		return
	var frames: SpriteFrames = _player_anim.sprite_frames
	_assert(frames != null, "序列帧 SpriteFrames 已建立")
	if frames == null:
		return
	for spec: Array in ANIM_SPEC:
		var anim: StringName = spec[0]
		var want: int = spec[1]
		_assert(frames.has_animation(anim), "动画 %s 已建立" % anim)
		if not frames.has_animation(anim):
			continue
		var count: int = frames.get_frame_count(anim)
		_assert(count == want, "动画 %s 共 %d 帧（实际 %d）" % [anim, want, count])
		_assert(frames.get_animation_speed(anim) == 9.0,
			"动画 %s 帧率 9 FPS（实际 %.1f）" % [anim, frames.get_animation_speed(anim)])
		# 每一帧都必须落在不同的格子上：行列算错会让某一格重复出现、另一格永远不播
		var regions: Dictionary = {}
		for i: int in count:
			var at: AtlasTexture = frames.get_frame_texture(anim, i) as AtlasTexture
			if at != null:
				regions[at.region] = true
		_assert(regions.size() == count,
			"动画 %s 的 %d 帧分别取自不同格子（实际 %d）" % [anim, count, regions.size()])
	# 此刻还没按任何移动键：应当是待机动画在播（呼吸循环），不是停在跑步姿势上
	_assert(_player_anim.animation == &"idle",
		"站着不动时切到待机动画（实际 %s）" % _player_anim.animation)
	_assert(_player_anim.is_playing(), "待机动画在播")
	_anim_offset_idle = _player_anim.offset

## 玩家从第 30 帧起一直按着向右 —— 此时必须已切到跑步动画，且绘制偏移跟着换过。
func _check_player_anim_running() -> void:
	if _player_anim == null:
		return
	_assert(_player_anim.animation == &"run",
		"跑动时切到跑步动画（实际 %s）" % _player_anim.animation)
	_assert(_player_anim.is_playing(), "跑步动画在播")
	# 两条序列图的格子尺寸与帧锚点都不同，偏移必须跟着换 ——
	# 否则切换瞬间角色会纵向跳一下（待机格 40x53，跑步格 56x56）
	_assert(_player_anim.offset != _anim_offset_idle, "切动画时绘制偏移同步更新")

# ---------------- 打击感：前冲 / 屏震 / 顿帧 / 残影 ----------------

## 前冲是数据表驱动的：先确认每段都有正的冲量，后面的位移断言才有意义。
func _check_lunge_config() -> void:
	for i: int in WuxiaPlayer.COMBO.size():
		var lunge: float = float(WuxiaPlayer.COMBO[i]["lunge"])
		_assert(lunge > 0.0, "第 %d 段有正的攻击前冲（%.0f）" % [i + 1, lunge])

## 前冲的前提：玩家没有按住方向键。
## 注意**不能**要求「速度为 0」—— 上一段连击的前冲还在自然衰减中（实测 437 帧时还剩 105），
## 那属于同一类位移，不该把它判成脏数据。真正要排除的只有「玩家自己按出来的速度」。
func _check_lunge_ready() -> void:
	_ghosts = _player.get_node_or_null("Ghosts")
	_assert(_ghosts != null, "残影容器 Ghosts 存在")
	_lunge_x = _player.global_position.x
	_assert(not Input.is_action_pressed("move_left") and not Input.is_action_pressed("move_right"),
		"前冲用例前提：没按住左右方向键（位置 %s）" % _player.global_position)

## 前冲的结果：窗口内出现过的最大横向速度、以及这一段的净前移量。
## 窗口取极值而不是某一帧 —— 三段连击的后摇长短不一，判定帧落在哪一帧会变。
func _check_lunge_applied() -> void:
	var vmax: float = _lunge_vmax
	_assert(vmax > 100.0, "判定帧给到前冲冲量（窗口内 max |velocity.x| = %.1f）" % vmax)
	# 上界一起卡住：前冲是小步前压，不是第二段冲刺
	_assert(vmax < 350.0, "前冲强度没有冲到冲刺量级（max |velocity.x| = %.1f）" % vmax)
	var moved: float = _player.global_position.x - _lunge_x
	_assert(moved > 4.0, "前冲把玩家推前了 %.1f px（起点 x = %.1f）" % [moved, _lunge_x])

## 屏震与顿帧是全局效果，可观察量在相机和树上，不在玩家身上。
func _camera() -> Camera2D:
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam == null:
		_assert(false, "能取到关卡相机（检查屏震 / 限位用）")
	return cam

func _camera_offset() -> Vector2:
	var cam: Camera2D = _camera()
	return Vector2.ZERO if cam == null else cam.offset

## 顿帧与屏震都必须真的触发过。
## 顿帧只能看 game.hitstop_count：整棵树被暂停时测试自己的帧计数也停了，
## 「正在暂停」这件事在 _physics_process 里根本观察不到。
func _check_feedback_fired() -> void:
	_assert(_game.hitstop_count > 0, "打斗中触发了顿帧（累计 %d 次）" % _game.hitstop_count)
	_assert(_shake_seen, "打斗中触发了屏震（全程 camera.offset 出现过非零值）")

## 到这一步屏震必须已经衰减干净（否则镜头会永远差零点几像素），
## 顺便确认顿帧没把整棵树留在暂停态 —— 那会让之后的一切都不再推进。
func _check_shake_settled() -> void:
	_assert(not get_tree().paused, "顿帧结束后整棵树已恢复，没卡在暂停")
	var off: Vector2 = _camera_offset()
	_assert(off == Vector2.ZERO, "屏震已衰减归零（camera.offset = %s）" % off)

func _check_dash_ghosts_spawned() -> void:
	if _ghosts == null:
		_ghosts = _player.get_node_or_null("Ghosts")
	_assert(_ghosts != null, "残影容器 Ghosts 存在")
	if _ghosts == null:
		return
	_assert(_ghosts.get_child_count() > 0,
		"冲刺掉出了残影（当前 %d 张）" % _ghosts.get_child_count())
	if _ghosts.get_child_count() == 0:
		return
	var ghost: Sprite2D = _ghosts.get_child(0) as Sprite2D
	_assert(ghost != null and ghost.texture != null, "残影是带贴图的 Sprite2D")
	if ghost != null:
		# top_level 是残影能「留在原地」的关键：不设它，残影会跟着主角走，成了身上叠重影
		_assert(ghost.top_level, "残影是脱离父变换的定格快照（top_level）")

func _check_dash_ghosts_cleared() -> void:
	if _ghosts == null:
		return
	_assert(_ghosts.get_child_count() == 0,
		"残影淡出后自行回收（剩 %d 张）" % _ghosts.get_child_count())

# ---------------- 闪避（翻滚） ----------------

## 把玩家放到一段没坑、没敌兵的平地上，并**归零速度**。
## 位移量断言的前提是「速度只可能来自这次技能」——
## 上一段用例可能还留着冲刺或前冲的余速，不归零的话量出来的位移是脏的。
## 落点 y=280 与地面差 20px，所以调用方要留几帧让它落地（见调用处的帧号间隔）。
func _reset_flat_stance() -> void:
	_player.global_position = Vector2(700, 280)
	_player.velocity = Vector2.ZERO
	_evade_invuln_seen = false
	_evade_speed_max = 0.0
	_dash_speed_max = 0.0

## 翻滚的前提：站在地面上、面朝右。
## 面朝右是因为 _try_evade 的位移方向取 `_facing`，朝左会把玩家往回推，
## 后面量到的「推前了多少」就成了负数。由调用处用一次极短的方向键定朝向。
## 「站得不够稳」不算失败 —— 落点本来就离地面 20px，几帧内必落地，
## 这里只把它作为上下文打印出来，不当作断言（否则这条断言会变成对帧号的隐性依赖）。
func _check_evade_ready() -> void:
	_assert(WuxiaPlayer.EVADE_COOLDOWN > WuxiaPlayer.DASH_COOLDOWN,
		"翻滚冷却 %.2fs 长于冲刺 %.2fs（翻滚换的是无敌帧，不是机动性）"
		% [WuxiaPlayer.EVADE_COOLDOWN, WuxiaPlayer.DASH_COOLDOWN])
	_assert(WuxiaPlayer.EVADE_INVULN > WuxiaPlayer.DASH_TIME,
		"翻滚无敌 %.2fs 长于冲刺位移 %.2fs（这是翻滚不能被冲刺替代的唯一理由）"
		% [WuxiaPlayer.EVADE_INVULN, WuxiaPlayer.DASH_TIME])
	_evade_x = _player.global_position.x

## 翻滚的三条结果：位移、无敌、以及位移小于冲刺。
func _check_evade_effect() -> void:
	var moved: float = _evade_max_x - _evade_x
	_assert(moved > 8.0, "翻滚把玩家推前了 %.1f px" % moved)
	_assert(_evade_invuln_seen, "翻滚期间处于无敌（翻滚中观察到 _invuln > 0）")
	# 翻滚的位移必须小于冲刺 —— 否则冲刺就没人用了，两个键会退化成同一个
	_assert(_evade_speed_max > 0.0 and _evade_speed_max < WuxiaPlayer.DASH_SPEED,
		"翻滚速度 %.0f 低于冲刺 %.0f（机动性归冲刺）" % [_evade_speed_max, WuxiaPlayer.DASH_SPEED])

## 冲刺对照：同条件（平地 / 静止起手 / 朝右）下测的峰值速度，必须高于翻滚。
## 对照组与被对照组的条件必须一致 —— 否则「翻滚比冲刺慢」这条结论是不成立的。
func _check_dash_reference() -> void:
	_assert(_dash_speed_max > _evade_speed_max,
		"同条件对照：冲刺峰值 %.0f > 翻滚 %.0f（冲刺才是机动手段）"
		% [_dash_speed_max, _evade_speed_max])

## 翻滚取消出招：起手挥刀，在 wind 阶段立刻翻滚。
## 两帧之间没有别的输入，所以「判定盒开着」只可能是出招留下的。
func _check_evade_cancelled_attack() -> void:
	var area: Area2D = _player.get_node_or_null("AttackHitbox") as Area2D
	_assert(String(_player.get("_atk_phase")) == "idle",
		"翻滚打断了出招（_atk_phase = %s）" % str(_player.get("_atk_phase")))
	_assert(area != null and not area.monitoring,
		"翻滚后攻击判定盒已关闭（monitoring = %s）" % ("null" if area == null else str(area.monitoring)))

# ---------------- 防御（举盾 / 完美格挡 / 架势 / 破防） ----------------

## 站定并面朝左。这样「从左边打」= 正面、「从右边打」= 背后，
## 与 _visuals.scale.x = facing 的视觉朝向严格一致。
## 这个函数必须在上一个动作（翻滚 / 冲刺）**彻底结束之后**调用：
## _face_input 在翻滚与冲刺期间会早退，此时按方向键是无效的（实测被静默吞掉过一次）。
func _stand_facing_left() -> void:
	_hold("move_left", 3)

## 朝向是「背后攻击不吃格挡」这条断言的前提，必须先钉住它 ——
## 朝向错了，测出来的就不是「盾只挡正面」，而是「盾什么都不挡」。
func _check_facing_left() -> void:
	_assert(int(_player.get("_facing")) == -1,
		"防御用例前提：玩家面朝左（实际 facing=%d），背面朝右" % int(_player.get("_facing")))

## 举盾 + 按住方向键：峰值速度应当**明显低于**正常跑速，但**不为零**。
## 两侧都要卡：只卡上界的话，举盾完全不能动也能通过；
## 只卡下界的话，减伤就没代价了 —— 举着盾全速跑，防御就成了纯赚。
func _probe_guard_move() -> void:
	_guard_move_speed_max = 0.0
	_press("guard")
	_hold("move_right", 18)

func _check_guard_move() -> void:
	_assert(_guard_move_speed_max > 0.0,
		"举盾时仍然能缓步移动（峰值 %.0f，不是一步都挪不动）" % _guard_move_speed_max)
	_assert(_guard_move_speed_max < WuxiaPlayer.SPEED,
		"举盾移速 %.0f 低于正常跑速 %.0f（防御有代价）"
		% [_guard_move_speed_max, WuxiaPlayer.SPEED])
	_release("guard")
	_release("move_right")

## 举盾。用 _press 而不是 _tap：guard 是**按住**型动作，
## _tap 会在下一帧就松开，靠 _sync_guard_hold 读 Input.is_action_pressed 的实现根本看不到。
func _begin_guard_probe() -> void:
	_guard_hp_before = int(_player.get("_health"))
	_guard_value_before = _player.guard_value()
	_press("guard")

## 从正面打一下（玩家面朝左，所以来源在左边 = 正面）
func _hit_player_from_front(amount: int) -> void:
	_player.take_damage(amount, _player.global_position + Vector2(-30.0, 0.0))

## 从背后打一下
func _hit_player_from_back(amount: int) -> void:
	_player.take_damage(amount, _player.global_position + Vector2(30.0, 0.0))

## 普通格挡（**已经熬过完美格挡窗口**）：吃减伤后的伤害（20 × 30% = 6），框架式照扣（20 × 1.6 = 32）。
## 断言「吃了伤」与「没吃满」两侧 —— 只断一边的话，把伤害全免掉也能通过。
func _check_front_block() -> void:
	var hp_now: int = int(_player.get("_health"))
	var taken: int = _guard_hp_before - hp_now
	_assert(taken > 0, "举盾挡下正面攻击仍然吃减伤后的伤害（%d）" % taken)
	_assert(taken < 20, "举盾把 20 点伤害减到 %d 点（减伤 %.0f%%）"
		% [taken, WuxiaPlayer.GUARD_REDUCTION * 100.0])
	_assert(_player.guard_value() < _guard_value_before,
		"格挡扣除架势（%.0f → %.0f）" % [_guard_value_before, _player.guard_value()])

## 完美格挡：零伤害 + 回架势。这是防御系统的收益来源，必须真的零伤 ——
## 只断言「触发了 perfect」不够，免不免伤才是玩家能感知到的那件事。
func _check_perfect_parry() -> void:
	_assert(_parry_seen or _player.last_guard_result() == &"perfect",
		"重新举盾后的前 %.2fs 内挡下 = 完美格挡（结果 = %s）"
		% [WuxiaPlayer.PARRY_WINDOW, str(_player.last_guard_result())])
	_assert(int(_player.get("_health")) == _guard_hp_before,
		"完美格挡零伤害（%d → %d）" % [_guard_hp_before, int(_player.get("_health"))])
	_assert(_player.guard_value() >= _guard_value_before,
		"完美格挡回架势而不是扣（%.0f → %.0f）" % [_guard_value_before, _player.guard_value()])

## 背后来敌照常吃满：盾只挡正面。这条不成立的话，举着盾就无敌了。
func _check_back_not_blocked() -> void:
	var taken: int = _guard_hp_before - int(_player.get("_health"))
	_assert(taken == 20, "背后来的 20 点伤害照常吃满（实际 %d）—— 盾只挡正面" % taken)

## 架势被打空 → 破防。60 点伤害 × 1.6 = 96 > 满架势 60，一次就该打空。
func _check_guard_broken() -> void:
	_assert(_break_seen or _player.is_guard_broken(),
		"架势被打空后进入破防状态（架势 = %.0f）" % _player.guard_value())
	_assert(is_equal_approx(_player.guard_value(), 0.0),
		"破防时架势归零（实际 %.1f）" % _player.guard_value())

## 破防硬直期间按住盾：状态上必须**没有**生效。
func _probe_guard_during_break() -> void:
	_assert(_player.is_guard_broken(), "破防硬直中（剩余 %.2fs）" % float(_player.get("_guard_break")))
	_press("guard")
	_break_guard_probe = true

func _check_guard_dead_during_break() -> void:
	_assert(_break_guard_probe, "已尝试在破防硬直中举盾")
	_assert(not _player.is_guarding(),
		"破防硬直期间举不起盾（is_guarding = %s）" % str(_player.is_guarding()))
	_release("guard")

# ---------------- 掉落物：在物理回调里生成 ----------------

## 回归用例：**在物理查询回调里**生成的掉落物，必须照样能用。
##
## 游戏里的真实时序就是这么走的 —— 玩家挥砍 → player 攻击判定的 `body_entered`（物理正在 flush）
## → 敌兵 _die → 广播 died → game 掉球。走真实战斗流程只能靠 40% 的掉落概率撞运气，
## 所以这里造一个只认玩家的哨兵 Area2D，在它自己的 `body_entered` 回调里掉一颗球：
## 同一个 flush 窗口，可稳定复现。
##
## 它钉的是「掉落物的物理注册被推迟到 flush 之后」这条约定（见 energy_orb._setup_physics）：
## 推迟本身引入了一帧延迟，万一 `_setup_physics()` 哪天没被调用、或调得太晚，
## 球的判定圈就不存在，玩家站在球上也不会被吸走 —— 这条断言会直接失败。
##
## 它**抓不到**「flush 期间的 ERROR 日志」：引擎拒绝的只是形状的 enabled 状态同步
## （形状本身已经注册上、默认就是启用的），所以旧写法下球照样能吸走，只有日志在报警。
## 那部分只能靠在运行输出里 grep `Can't change this state while flushing queries` 来确认。
func _arm_drop_probe() -> void:
	_drop_probe = Area2D.new()
	_drop_probe.name = "DropProbe"
	_drop_probe.collision_layer = 0
	_drop_probe.collision_mask = 2
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(16, 56)
	shape.shape = rect
	_drop_probe.add_child(shape)
	# 先摆 40px 外：玩家半宽 6 + 哨兵半宽 8 = 14，此刻不重叠，保证 fires 的是 406 帧那次传送
	_drop_probe.global_position = _player.global_position + Vector2(40, 0)
	_drop_probe.body_entered.connect(_on_drop_probe_body_entered)
	_game.add_child(_drop_probe)

func _step_onto_drop_probe() -> void:
	if _drop_probe != null:
		_player.global_position = _drop_probe.global_position

## 这个函数体跑在 Area2D 的 body_entered 里 —— 也就是物理查询 flush 中。
func _on_drop_probe_body_entered(body: Node2D) -> void:
	if _probe_spawned or not body.is_in_group("player"):
		return
	_probe_spawned = true
	# 就在物理回调里掉球 —— 被修掉的那条路径
	var orb: WuxiaEnergyOrb = WuxiaEnergyOrb.roll(_rng)
	orb.position = body.global_position + Vector2(0, -10)
	orb.collected.connect(_on_probe_orb_collected)
	_orbs.add_child(orb)

func _on_probe_orb_collected(_stat: int, _value: float) -> void:
	_probe_collected = true

func _check_probe_orb_absorbed() -> void:
	if _drop_probe != null:
		_drop_probe.queue_free()
		_drop_probe = null
	_assert(_probe_spawned, "物理回调里成功掉出一颗能量球")
	# 球就落在玩家脚下：判定圈只要真注册上了，几帧之内必定被吸走
	_assert(_probe_collected, "物理回调里掉出的球仍能被吸取（碰撞体注册成功）")

# ---------------- 竖井与下层石室 ----------------

## 竖井的地形契约：掉下去必须能站住，而且必须能一路跳回主层。
##
## 这些数字全部从 PLATFORMS 现算，不抄常量 —— 关卡一改尺寸，断言跟着一起变，
## 不会退化成一份过期的说明书。三段契约：
##   ① 坑底存在，且顶面与主地面底边齐平（留缝的话玩家会卡在缝里，而不是站在坑底）；
##   ② 每一级落差都在单跳高度以内（超了就等于把坑变回无底洞）；
##   ③ 最高一级与主地面同高（否则还得再跳一次才走得出去）。
func _check_pit_geometry() -> void:
	var g0: Rect2 = WuxiaGame.PLATFORMS[0]
	var g1: Rect2 = WuxiaGame.PLATFORMS[1]
	# 竖井 = 主地面第一段的右端 与 第二段的左端 之间那个缺口
	_pit_left = g0.position.x + g0.size.x
	_pit_right = g1.position.x
	_main_ground_top = g0.position.y
	_ground_bottom = g0.position.y + g0.size.y

	var tops: Array[float] = _pit_ledges()
	# y 轴向下为正：数组升序的话，**头是最高的一级、末位才是坑底**
	if not tops.is_empty():
		_pit_floor_top = tops[tops.size() - 1]
	if tops.size() >= 2:
		_pit_step_top = tops[tops.size() - 2]
	_assert(tops.size() >= 3,
		"竖井里至少有坑底 + 两级石阶（实际 %d 个可站立面）" % tops.size())
	if tops.size() < 3:
		return

	_assert(is_equal_approx(_pit_floor_top, _ground_bottom),
		"坑底顶面 %.0f 与主地面底边 %.0f 齐平，中间不留夹缝" % [_pit_floor_top, _ground_bottom])
	_assert(absf(_pit_right - _pit_left) > 40.0,
		"这段确实是缺口而不是地面（宽 %.0fpx）" % (_pit_right - _pit_left))

	var jump_h: float = WuxiaPlayer.JUMP_FORCE * WuxiaPlayer.JUMP_FORCE / (2.0 * WuxiaPlayer.GRAVITY)
	for i: int in tops.size() - 1:
		# 越靠后 y 越大（越低），所以 i+1 那一级比 i 低，差值是正的爬升高度
		var rise: float = tops[i + 1] - tops[i]
		_assert(rise <= jump_h * 0.8,
			"竖井自上往下第 %d 级落差 %.0fpx 在单跳高度 %.0fpx 的 80%% 以内"
			% [tops.size() - 1 - i, rise, jump_h])
	_assert(is_equal_approx(tops[0], _main_ground_top),
		"竖井最高一级 %.0f 与主地面顶面 %.0f 同高，走上去就是主层"
		% [tops[0], _main_ground_top])

## 竖井里所有「可站立的顶面」：坑底、两级石阶（外加任何横跨这段缺口的台面）。
## 返回升序数组 —— 注意 y 轴向下为正，所以**头是最高的一级**。
##
## 「严格横向相交」这个判据是有意的：主地面那三块大石头正好贴着竖井的左右边界，
## 判据放宽成 `>=` 会把它们算进来，于是「最高一级 = 主地面顶面」就变成恒真断言了。
func _pit_ledges() -> Array[float]:
	var tops: Array[float] = []
	for r: Rect2 in WuxiaGame.PLATFORMS:
		if r.position.x < _pit_right and r.position.x + r.size.x > _pit_left:
			if not tops.has(r.position.y):
				tops.append(r.position.y)
	tops.sort()
	return tops

## 清掉场上所有敌兵。竖井用例要求「掉下去 → 爬上来」全程没有接触伤害干扰：
## 敌兵会一路追到竖井边缘站着（它有悬崖射线，不会跟着掉下去），
## 玩家爬出来的那一瞬间正好撞进它的接触判定，血量断言就没法钉死了。
func _clear_enemies() -> void:
	if _enemies == null:
		return
	for child: Node in _enemies.get_children():
		var e: Node2D = child as Node2D
		if e != null and e.has_method("take_damage"):
			e.call("take_damage", 9999, e.global_position + Vector2(-30.0, 0.0))

## 让玩家从竖井口正上方自然坠落。以前这里是**无底洞**：掉下去只能按 R 重开。
## 落点选在竖井左半（坑底裸露的那段），确保真的是「掉到坑底」而不是落到石阶上。
func _drop_into_pit() -> void:
	_player.global_position = Vector2(_pit_left + 20.0, _main_ground_top - 40.0)
	_pit_hp_before = int(_player.get("_health"))

## 坠落后的落点：活着、脚踩在坑底、且坠落本身不扣血。
## 三条合起来才是「不用死亡区域」——以前底下什么都没有，玩家会一直掉出关卡。
func _check_pit_landed() -> void:
	_assert(_player.is_alive(), "掉进竖井没有摔死（底下不是死亡区域）")
	_assert(_player.is_on_floor(), "落在坑底而不是一直往下掉")
	var feet: float = _player.global_position.y
	_assert(absf(feet - _pit_floor_top) < 2.0,
		"脚底停在坑底地面 y=%.0f（实际 %.1f）" % [_pit_floor_top, feet])
	_assert(int(_player.get("_health")) == _pit_hp_before,
		"坠落本身不扣血（%d → %d）" % [_pit_hp_before, int(_player.get("_health"))])

## 爬到一半：应当已经站上第一级石阶 —— 也就顺便证明了 45px 的一级落差确实一跳就够。
func _check_on_pit_step() -> void:
	_assert(_player.is_alive(), "爬坑途中依然存活")
	_assert(_player.is_on_floor(), "起跳后落到了石阶上（不是卡在半空）")
	var feet: float = _player.global_position.y
	_assert(absf(feet - _pit_step_top) < 3.0,
		"脚踏第一级石阶顶面 y=%.0f（实际 %.1f）" % [_pit_step_top, feet])

## 爬出竖井：脚底回到主地面高度、横向已越过竖井右沿 —— 可以继续往关门推进。
func _check_climbed_out() -> void:
	var feet: float = _player.global_position.y
	_assert(absf(feet - _main_ground_top) < 3.0,
		"爬回主层地面 y=%.0f（实际 %.1f）" % [_main_ground_top, feet])
	_assert(_player.global_position.x > _pit_right,
		"已越过竖井右沿 x=%.0f（实际 %.1f），能接着往下推关卡"
		% [_pit_right, _player.global_position.x])
	_assert(int(_player.get("_health")) == _pit_hp_before,
		"上下往返全程没有掉血（%d）" % _pit_hp_before)

# ---------------- 关卡两端的封边岩壁 ----------------

## 关卡两端必须封住：每端都有一道「内侧面与主地面外沿齐平」的岩壁，而且高到跳不过去。
## 以前两端是敞开的 —— 从起点往左、或走过关门继续往右都能走出地形，然后一直往下掉。
func _check_end_walls() -> void:
	var g0: Rect2 = WuxiaGame.PLATFORMS[0]
	var g2: Rect2 = WuxiaGame.PLATFORMS[2]
	var climb: float = _max_jump_climb()
	var bottom: float = float(_camera().limit_bottom)
	# 左壁贴在地面左外沿、右壁贴在地面右外沿
	for spec: Array in [
		["左", g0.position.x, true],
		["右", g2.position.x + g2.size.x, false],
	]:
		var label: String = spec[0]
		var edge: float = spec[1]
		var wall: Rect2 = _find_end_wall(edge, bool(spec[2]))
		_assert(wall.size.x > 0.0,
			"关卡%s端有封边岩壁（内侧面贴在地面外沿 %.0f 上）" % [label, edge])
		if wall.size.x <= 0.0:
			continue
		var margin: float = g0.position.y - wall.position.y
		_assert(margin >= climb,
			"关卡%s端岩壁高出地面 %.0fpx ≥ 单跳 + 二段跳的上限 %.0fpx（翻不过去）"
			% [label, margin, climb])
		# 一直伸到相机下界以下：不从底下留缝
		_assert(wall.position.y + wall.size.y >= bottom,
			"关卡%s端岩壁伸到相机下界 %.0f 以下（实际到 %.0f）"
			% [label, bottom, wall.position.y + wall.size.y])

## 找「某一端」的封边岩壁：内侧面正好落在地面外沿上、且顶面高于主地面的那块。
## 用「内侧面与地面外沿齐平」当判据，而不是抄一个 -160 / 1710 之类的坐标。
func _find_end_wall(edge: float, is_left: bool) -> Rect2:
	for r: Rect2 in WuxiaGame.PLATFORMS:
		var inner: float = r.position.x + r.size.x if is_left else r.position.x
		if is_equal_approx(inner, edge) and r.position.y < _main_ground_top:
			return r
	return Rect2()

## 一次单跳 + 一次「在顶点接上的」空中二段跳能爬升的总高度 —— 岩壁必须高过它。
##
## 用**逐帧离散累加**而不是连续公式 v²/2g：物理是「每帧先加重力、再用当前速度位移」的欧拉积分，
## 离散步长会多爬约 4px —— 480 的单跳连续算 82.3，引擎里实际 86.3。
## 这条约束的意义就是卡住最坏情况，必须算准；用偏小的近似值会让余量看起来比实际大。
## 二段跳在顶点接上是最大值：二段跳是**赋**速度而不是叠加速度（player.gd 里写死 `velocity.y = JUMP_FORCE * AIR_JUMP_SCALE`），
## 早接会丢掉剩余上升速度、晚接已经在下落。
func _max_jump_climb() -> float:
	var first: float = _jump_climb(WuxiaPlayer.JUMP_FORCE)
	return first + _jump_climb(WuxiaPlayer.JUMP_FORCE * WuxiaPlayer.AIR_JUMP_SCALE)

## 以某初速度起跳、每帧先加重力再位移，能爬升多少像素（与 player.gd 的 _fall + move_and_slide 同序）
func _jump_climb(v0: float) -> float:
	var dt: float = 1.0 / 60.0
	var v: float = v0
	var climb: float = 0.0
	while v < 0.0:
		climb -= v * dt
		v += WuxiaPlayer.GRAVITY * dt
	return climb

## 封边用例：把玩家放到左端岩壁旁，按住左、并连跳两次（单跳 + 二段跳 = 全套手段），
## 然后检查他既没越过岩壁、也没跳上壁顶。
func _start_wall_probe() -> void:
	# 竖井用例结束时还按着右，先松开，否则左右同时按下 get_axis 会互相抵消
	_release("move_right")
	var wall: Rect2 = _find_end_wall(WuxiaGame.PLATFORMS[0].position.x, true)
	_wall_face = WuxiaGame.PLATFORMS[0].position.x
	_wall_top = wall.position.y
	_wall_min_x = 99999.0
	_wall_min_y = 99999.0
	# 落点必须**正好踩在地面上**：悬在半空起跳会走成 0.92 倍的空中跳（coyote 也救不了，
	# player.gd 是按 is_on_floor() 选倍率的），那就压不到「从地面起跳」这个最坏情况了。
	_player.global_position = Vector2(_wall_face + 20.0, _main_ground_top)
	_hold("move_left", 60)

## 窗口内玩家到过的最左 x / 最高 y：两条断言一起才说明「翻不出去」——
## 只断言没越过，可能是他压根没走到墙边；只断言没跳上壁顶，可能是他站在远处跳的。
func _check_wall_blocked() -> void:
	_assert(_player.is_alive(), "撞到封边岩壁没有致死")
	_assert(_wall_min_x >= _wall_face,
		"按住左 + 连跳也越不过岩壁（最左只到 x=%.1f，壁面在 %.0f）" % [_wall_min_x, _wall_face])
	_assert(_wall_min_y > _wall_top,
		"跳不上岩壁顶面（最高只到 y=%.1f，壁顶在 %.0f）" % [_wall_min_y, _wall_top])

# ---------------- 关卡内墙（石墙） ----------------

## 内墙的地形契约：每道墙都翻得过去（不是软锁），且至少两道必须动用二段跳。
##
## 数字全部从 WuxiaGame.WALLS 现算，不抄常量。三条：
##   ① 墙顶高于主地面、墙底扎到主地面底边 → 真的是「挡路的墙」，底下也钻不过去；
##   ② 离地高度 ≤ 单跳 + 二段跳上限 → 翻得过去（这是墙与「封边岩壁」的根本区别：
##      后者就是要高到翻不过去，前者翻不过去就是软锁）；
##   ③ 至少两道高过单跳 → 单跳上不去，二段跳才是「够用的墙」。
func _check_walls() -> void:
	var walls: Array[Rect2] = WuxiaGame.WALLS
	_assert(walls.size() >= 3, "关卡里有 %d 道内墙（竖向墙体是关卡内容）" % walls.size())
	var single: float = _jump_climb(WuxiaPlayer.JUMP_FORCE)
	var climb: float = _max_jump_climb()
	var need_double: int = 0
	# 行为用例挑最高的一道：它翻得过去，其余的自然也翻得过去
	_climb_wall = walls[0] if not walls.is_empty() else Rect2()
	for i: int in walls.size():
		var w: Rect2 = walls[i]
		# 离地高度 = 墙顶面到主地面顶面的距离（y 轴向下为正，所以是「地面 y − 墙顶 y」）
		var height: float = _main_ground_top - w.position.y
		if w.position.y < _climb_wall.position.y:
			_climb_wall = w
		_assert(height > 0.0,
			"第 %d 道墙顶面 %.0f 高于主地面 %.0f（是挡路的墙，不是落脚台面）"
			% [i + 1, w.position.y, _main_ground_top])
		_assert(w.position.y + w.size.y >= _ground_bottom - 1.0,
			"第 %d 道墙扎到主地面底边 %.0f（底面 %.0f，底下不留缝）"
			% [i + 1, _ground_bottom, w.position.y + w.size.y])
		_assert(w.size.x >= 24.0, "第 %d 道墙顶宽 %.0fpx，翻上去站得下人" % [i + 1, w.size.x])
		_assert(height <= climb - 20.0,
			"第 %d 道墙离地 %.0fpx，二段跳上限 %.0fpx 还留 %.0fpx 余量（翻得过去，不软锁）"
			% [i + 1, height, climb, climb - height])
		if height > single:
			need_double += 1
	_assert(need_double >= 2,
		"至少两道墙高过单跳 %.0fpx（必须二段跳才上得去，实际 %d 道）" % [single, need_double])

## 攀墙用例：把玩家摆到最高那道墙跟前 —— **贴着墙面、正好站在地面上**。
##
## 单跳与「单跳 + 二段跳」各跑一遍，同一位置、同一输入，差的只有那一下二段跳。
## 这组对照才说明「这道墙非二段跳不可」；只测成功那一次，证明不了墙的必要性
## （也可能是玩家压根没跳好、或者墙矮到单跳就够）。
##
## 敌兵必须先清光：`_find_player()` 不看距离，全图敌兵都会一路追过来，
## 玩家会在越顶那几帧被撞下墙（接触伤害带击退），量到的就不是跳跃能力了。
func _start_wall_climb() -> void:
	_clear_enemies()
	_climb_max_x = -99999.0
	# 身体半宽 6px，落点取墙面往左 8px → 起跳后横向立刻被墙挡住，
	# 于是「翻没翻过去」纯粹由竖直高度决定，混不进助跑距离的干扰。
	_player.global_position = Vector2(_climb_wall.position.x - 8.0, _main_ground_top)
	_player.velocity = Vector2.ZERO

## 单跳对照组：86px 的爬升够不着 130px 的墙 —— 最远只到墙面。
func _check_wall_single_jump_fails() -> void:
	var face: float = _climb_wall.position.x
	var height: float = _main_ground_top - _climb_wall.position.y
	_assert(_player.is_alive(), "撞在墙上不会致死")
	_assert(_climb_max_x < face,
		"单跳翻不过 %.0fpx 的墙（最远只到 x=%.1f，墙面在 %.0f）" % [height, _climb_max_x, face])

## 补上二段跳：越顶之后继续向右推进，横向越过整道墙 —— 真的翻过去了。
func _check_wall_double_jump_clears() -> void:
	var right: float = _climb_wall.position.x + _climb_wall.size.x
	var height: float = _main_ground_top - _climb_wall.position.y
	_assert(_player.is_alive(), "翻墙途中存活（越顶没有被卡住或摔死）")
	_assert(_climb_max_x > right + 2.0,
		"单跳 + 二段跳翻过 %.0fpx 的墙（最远到 x=%.1f，墙右外沿在 %.0f）"
		% [height, _climb_max_x, right])

# ---------------- Boss 与武器掉落 ----------------

func _check_boss_spawned() -> void:
	var boss: WuxiaBoss = _game.get_node_or_null("Boss") as WuxiaBoss
	_assert(boss != null, "Boss 节点存在且是 WuxiaBoss")
	if boss == null:
		return
	_assert(boss.max_health > 100, "Boss 血量 %d 明显高于杂兵" % boss.max_health)
	_assert(boss.body_size.x > 20.0, "Boss 受击盒 %.0f×%.0f 大于杂兵" % [boss.body_size.x, boss.body_size.y])
	_assert(boss.knockback_scale < 1.0, "Boss 击退倍率 %.2f 抗打断" % boss.knockback_scale)
	_assert(not _player.has_weapon(), "拾取前装备槽为空")
	_assert(_player.attack_power() == 0, "开局攻击力加成为 0（无武器 / 无能量球）")
	_assert(_player.max_health == WuxiaPlayer.BASE_MAX_HEALTH, "开局生命上限为基础值")
	_assert(_pickups.get_child_count() == 0, "开局没有任何掉落物")
	_assert(_orbs.get_child_count() == 0, "开局没有任何能量球")

func _kill_boss() -> void:
	var boss: Node2D = _game.get_node_or_null("Boss")
	if boss != null and boss.has_method("take_damage"):
		boss.call("take_damage", 99999, boss.global_position + Vector2(-40.0, 0.0))

func _check_weapon_drop() -> void:
	_assert(_pickups.get_child_count() == 1, "Boss 死亡掉落 1 件武器（实际 %d）" % _pickups.get_child_count())
	if _pickups.get_child_count() == 0:
		return
	var drop: WuxiaWeaponDrop = _pickups.get_child(0) as WuxiaWeaponDrop
	_assert(drop != null, "掉落物是 WuxiaWeaponDrop")
	if drop == null or drop.weapon == null:
		_assert(false, "掉落物携带武器数据")
		return
	_check_weapon_roll(drop.weapon, "掉落武器")
	# 拾取提示上写的键必须和 InputMap 里实际绑定的一致 ——
	# 这里曾写死成 "K 拾取"，而键位早已改成 E，界面一直在教玩家按一个没用的键。
	# 独立从 InputMap 现取一遍（不复用掉落物自己的实现），才算真的对得上。
	var want_key: String = _action_key_label("pickup")
	var hint: Label = drop.get("_hint") as Label
	_assert(hint != null and hint.text.contains(want_key),
		"掉落物提示写的是拾取键 %s（实际「%s」）" % [want_key, hint.text if hint != null else ""])
	# 站到掉落物身上，下一物理帧 Area2D 才能侦测到玩家
	_player.global_position = drop.global_position
	# 记录落点与球心的距离。这里刻意断言「够不到接触判定」：
	# 球体半径 16 + 玩家半宽 6 = 22px 才碰得到，而落点相距 28px，
	# 所以稍后球被吸走只可能是磁吸的功劳，不可能是被踩到的。
	if is_instance_valid(_orb_node):
		_magnet_gap_before = _orb_node.global_position.distance_to(_player.global_position)
		_assert(_magnet_gap_before > 24.0, "落点距球 %.1fpx，超出 22px 的接触判定 —— 只有磁吸够得着" % _magnet_gap_before)

func _check_weapon_equipped() -> void:
	_assert(_player.has_weapon(), "按 %s 后武器已拾取并装备" % _action_key_label("pickup"))
	var first: WuxiaWeapon = _player.current_weapon()
	if first == null:
		return
	_assert(_player.attack_power() == _expected_attack(first) + _perm(WuxiaWeapon.Stat.ATTACK), "攻击力 = 主词条 + 攻击副词条 + 永久加成（%d）" % _player.attack_power())
	_assert(_player.max_health == WuxiaPlayer.BASE_MAX_HEALTH + _expected_health(first) + _perm(WuxiaWeapon.Stat.HEALTH), "生命上限已加上生命副词条与永久加成（%d）" % _player.max_health)

	# 单槽规则：再装一把必须整体替换，而不是把两把武器的词条叠在一起
	var second: WuxiaWeapon = WuxiaWeapon.roll(_rng)
	_check_weapon_roll(second, "第二把武器")
	_player.equip_weapon(second)
	_assert(_player.current_weapon() == second, "重复装备替换旧武器（装备槽只有一格）")
	_assert(_player.attack_power() == _expected_attack(second) + _perm(WuxiaWeapon.Stat.ATTACK), "替换后攻击力不叠加（%d）" % _player.attack_power())
	_assert(_player.max_health == WuxiaPlayer.BASE_MAX_HEALTH + _expected_health(second) + _perm(WuxiaWeapon.Stat.HEALTH), "替换后生命上限整体重算（%d）" % _player.max_health)
	_assert(_player.crit_rate() >= WuxiaPlayer.BASE_CRIT_RATE, "暴击率不低于基础值（%.3f）" % _player.crit_rate())
	_report("拾取武器后")

# ---------------- 能量球 ----------------

## 结构校验：Boss 必掉一颗，属性只能取自四选一，数值必须为正
func _check_energy_orb() -> void:
	_assert(_orbs.get_child_count() == 1, "Boss 死亡必掉 1 颗能量球（实际 %d）" % _orbs.get_child_count())
	if _orbs.get_child_count() == 0:
		return
	var orb: WuxiaEnergyOrb = _orbs.get_child(0) as WuxiaEnergyOrb
	_assert(orb != null, "掉落物是 WuxiaEnergyOrb")
	if orb == null:
		return
	_assert(WuxiaWeapon.STAT_NAME.has(orb.stat), "能量球属性取自 攻击/生命/暴击/暴击伤害（%s）" % WuxiaWeapon.format_stat(orb.stat, orb.value))
	_assert(orb.value > 0.0, "能量球数值为正（%s）" % WuxiaWeapon.format_stat(orb.stat, orb.value))
	# 掉落物之间不能自己吃掉对方：能量球的碰撞掩码只认玩家层
	_assert(orb.collision_mask == 2, "能量球只对玩家层生效（mask=%d）" % orb.collision_mask)
	# 两级半径：磁吸圈必须明显大于拾取圈，否则「磁吸」就退化成「判定圈放大」
	_assert(WuxiaEnergyOrb.MAGNET_RADIUS > WuxiaEnergyOrb.PICKUP_RADIUS, "磁吸半径 %.0f > 拾取半径 %.0f" % [WuxiaEnergyOrb.MAGNET_RADIUS, WuxiaEnergyOrb.PICKUP_RADIUS])
	var magnet: Area2D = orb.get_node_or_null("MagnetRange") as Area2D
	_assert(magnet != null, "能量球带独立磁吸圈 MagnetRange")
	if magnet != null:
		_assert(magnet.monitoring and magnet.collision_mask == 2, "磁吸圈处于监听态且只认玩家层（mask=%d）" % magnet.collision_mask)
	_orb_node = orb
	_orb_stat = orb.stat
	_orb_value = orb.value

## 磁吸的核心证据：玩家只是站到了 28px 外（够不到 22px 的接触判定），没碰、没按键，
## 球却自己缩短了距离并被吸走。这两条断言合起来才排除了「其实是被踩到的」。
func _check_magnet_pull() -> void:
	if not is_instance_valid(_orb_node):
		_assert(false, "磁吸：第 16 帧球节点仍在播消散动画（提前消失说明吸收时机与假设不符）")
		return
	_assert(_orb_node.is_taken(), "磁吸：进入 %.0fpx 磁吸圈后被自动吸取（未按任何键）" % WuxiaEnergyOrb.MAGNET_RADIUS)
	var gap: float = _orb_node.global_position.distance_to(_player.global_position)
	_assert(gap < _magnet_gap_before, "磁吸：球主动缩短与玩家的距离（%.1f → %.1f px）" % [_magnet_gap_before, gap])

## 数值原样入账：球上写多少，玩家的永久加成层就得加多少。
func _check_orb_absorbed() -> void:
	var got: float = _player.permanent_bonus(_orb_stat)
	_assert(is_equal_approx(got, _orb_value), "吸取后永久加成 = 球上数值（%s）" % WuxiaWeapon.format_stat(_orb_stat, got))

## 消散动画演完后两件掉落物都该自行释放（能量球 0.18s、武器 0.28s）。
## 这里不能提前到接触的下一帧断言：吸走是即时的，节点销毁要等动画结束。
func _check_drops_cleared() -> void:
	_assert(_pickups.get_child_count() == 0, "武器拾取后掉落物已自行释放（剩 %d）" % _pickups.get_child_count())
	_assert(_orbs.get_child_count() == 0, "能量球吸取动画结束后自行释放（剩 %d）" % _orbs.get_child_count())

## 能量球的核心回归点：加成必须落在「永久层」，且扛得住一次换武器。
## _recalc_stats() 是整体重算，若加成只增量写进 _attack_power，
## 这组断言会在 equip_weapon() 之后立刻炸掉。
func _check_permanent_bonus() -> void:
	var atk_before: int = _player.attack_power()
	var atk_perm_before: float = _player.permanent_bonus(WuxiaWeapon.Stat.ATTACK)
	_player.apply_bonus(WuxiaWeapon.Stat.ATTACK, 5.0)
	_assert(_player.attack_power() == atk_before + 5, "能量球攻击加成立即生效（%d）" % _player.attack_power())
	_assert(is_equal_approx(_player.permanent_bonus(WuxiaWeapon.Stat.ATTACK), atk_perm_before + 5.0), "永久攻击加成可查询（%.0f）" % _player.permanent_bonus(WuxiaWeapon.Stat.ATTACK))

	var hp_before: int = _player.max_health
	_player.apply_bonus(WuxiaWeapon.Stat.HEALTH, 20.0)
	_assert(_player.max_health == hp_before + 20, "能量球生命上限加成立即生效（%d）" % _player.max_health)

	var crit_before: float = _player.crit_rate()
	_player.apply_bonus(WuxiaWeapon.Stat.CRIT_RATE, 2.5)
	_assert(is_equal_approx(_player.crit_rate(), crit_before + 0.025), "能量球暴击率加成按百分点入账（%.3f）" % _player.crit_rate())

	var w: WuxiaWeapon = WuxiaWeapon.roll(_rng)
	_check_weapon_roll(w, "换装用武器")
	_player.equip_weapon(w)
	_assert(_player.attack_power() == _expected_attack(w) + _perm(WuxiaWeapon.Stat.ATTACK), "换武器后永久攻击加成仍在（%d）" % _player.attack_power())
	_assert(_player.max_health == WuxiaPlayer.BASE_MAX_HEALTH + _expected_health(w) + _perm(WuxiaWeapon.Stat.HEALTH), "换武器后永久生命加成仍在（%d）" % _player.max_health)
	_report("能量球加成后")

## 永久加成按「展示单位」取整：攻击 / 生命是点数，暴击系是百分点
func _perm(stat: int) -> int:
	return int(_player.permanent_bonus(stat))

## 永久加成的合计指纹：四条属性里任意一条变了都会让它变，用来断言「什么都没发生」
func _perm_signature() -> float:
	var total: float = 0.0
	for key: Variant in WuxiaWeapon.STAT_NAME.keys():
		total += _player.permanent_bonus(int(key))
	return total

# ---------------- 玩家倒下后的磁吸 ----------------

## 磁吸半径有 64px，而玩家倒地后节点仍留在 "player" 组里。
## 若不判存活，尸体会把附近的球吸过去 —— 而 player.apply_bonus() 会拒收死亡后的加成，
## 结果就是一颗球凭空蒸发。这里在尸体旁放一颗来钉住这条约束。
func _spawn_orb_beside_corpse() -> void:
	_assert(not _player.is_alive(), "死亡后玩家节点仍在（可用于验证磁吸不误吸）")
	_dead_perm_before = _perm_signature()
	_dead_orb = WuxiaEnergyOrb.roll(_rng)
	# 30px：进得了 64px 的磁吸圈，但够不到 22px 的接触判定
	_dead_orb.position = _player.global_position + Vector2(-30.0, 0.0)
	_orbs.add_child(_dead_orb)
	_dead_orb_pos = _dead_orb.global_position

func _check_dead_player_ignored() -> void:
	if not is_instance_valid(_dead_orb):
		_assert(false, "尸体旁的球应当仍在场（被吸走说明没有判存活）")
		return
	_assert(not _dead_orb.is_taken(), "玩家已倒下：磁吸不生效，球没被吞掉")
	_assert(_dead_orb.global_position.is_equal_approx(_dead_orb_pos), "玩家已倒下：球原地不动（%.1f, %.1f）" % [_dead_orb.global_position.x, _dead_orb.global_position.y])
	_assert(is_equal_approx(_perm_signature(), _dead_perm_before), "玩家已倒下：永久加成未发生任何变化")

## 校验掷出来的词条结构：主词条必为攻击，副词条只能出自四选一且不重复
func _check_weapon_roll(w: WuxiaWeapon, tag: String) -> void:
	var quality_ok: bool = w.quality >= 0 and w.quality < WuxiaWeapon.QUALITY_NAME.size()
	var quality_text: String = WuxiaWeapon.QUALITY_NAME[w.quality] if quality_ok else str(w.quality)
	_assert(quality_ok, "%s 品质合法（%s）" % [tag, quality_text])
	if not quality_ok:
		return
	_assert(w.main_value > 0, "%s 主词条固定为攻击 +%d" % [tag, w.main_value])
	_assert(w.substats.size() == w.quality + 1, "%s 副词条 %d 条（%s）" % [tag, w.substats.size(), quality_text])
	var valid: bool = true
	var seen: Dictionary = {}
	for sub: Dictionary in w.substats:
		var stat: int = int(sub["stat"])
		if not WuxiaWeapon.STAT_NAME.has(stat) or float(sub["value"]) <= 0.0 or seen.has(stat):
			valid = false
		seen[stat] = true
	_assert(valid, "%s 副词条取自 攻击/生命/暴击/暴击伤害 且互不重复" % tag)

func _expected_attack(w: WuxiaWeapon) -> int:
	var total: int = w.main_value
	for sub: Dictionary in w.substats:
		if int(sub["stat"]) == WuxiaWeapon.Stat.ATTACK:
			total += int(round(float(sub["value"])))
	return total

func _expected_health(w: WuxiaWeapon) -> int:
	var total: int = 0
	for sub: Dictionary in w.substats:
		if int(sub["stat"]) == WuxiaWeapon.Stat.HEALTH:
			total += int(round(float(sub["value"])))
	return total

# ---------------- 输入模拟 ----------------

func _press(action: String) -> void:
	Input.action_press(action)
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)

func _release(action: String) -> void:
	Input.action_release(action)
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = false
	Input.parse_input_event(ev)

## 单帧点按（攻击这类靠 _unhandled_input 捕获的动作）
func _tap(action: String) -> void:
	_press(action)
	_release_at[action] = _frame

## 持续按住若干帧（跳跃需要保持以检查松手截断高度）
func _hold(action: String, frames: int) -> void:
	_press(action)
	_release_at[action] = _frame + frames

func _flush_releases() -> void:
	for action: String in _release_at.keys():
		if _frame >= int(_release_at[action]):
			_release(action)
			_release_at.erase(action)

# ---------------- 辅助 ----------------

func _kill_one_enemy() -> void:
	if _enemies == null or _enemies.get_child_count() == 0:
		return
	var victim: Node2D = _enemies.get_child(0) as Node2D
	if victim != null and victim.has_method("take_damage"):
		victim.call("take_damage", 999, victim.global_position + Vector2(-30, 0))

## 某个动作在 InputMap 上绑定的按键名（取第一个键盘事件）。
## 与 weapon_drop.gd 各自独立实现：测试要能抓出「界面写错键」，就不能复用被测代码。
func _action_key_label(action: String) -> String:
	for ev: InputEvent in InputMap.action_get_events(action):
		var key: InputEventKey = ev as InputEventKey
		if key == null:
			continue
		var label: String = key.as_text_physical_keycode()
		if not label.is_empty():
			return label
	return ""

func _report(tag: String) -> void:
	var alive: int = 0 if _enemies == null else _enemies.get_child_count()
	var weapon: WuxiaWeapon = _player.current_weapon()
	print("[smoke] %s f=%d 玩家hp=%s 攻击=%d 永久加成(攻/命/暴击率)=%d/%d/%.1f%% 武器=%s 存活敌兵=%d 连击段=%s" % [
		tag, _frame, str(_player.get("_health")), _player.attack_power(),
		_perm(WuxiaWeapon.Stat.ATTACK), _perm(WuxiaWeapon.Stat.HEALTH),
		_player.permanent_bonus(WuxiaWeapon.Stat.CRIT_RATE),
		"无" if weapon == null else weapon.title(), alive, str(_player.get("_atk_step")),
	])

func _assert(ok: bool, message: String) -> void:
	if ok:
		print("  [ok]   %s" % message)
	else:
		_fails += 1
		print("  [FAIL] %s" % message)

func _finish() -> void:
	print("[smoke] 完成：失败项 %d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
