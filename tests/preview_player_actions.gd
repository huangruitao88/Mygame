extends Node2D

## 主角动作状态机 QA：把玩家放进一个最小带地面场景，逐一驱动到各动作状态，
## 断言 _anim.animation 选对（受击 > 出招 > 空中 > 奔跑 > 待机）。
## GDScript 运行期可访问 _ 前缀成员，故直接置 _atk_phase / _hurt_timer 驱动状态。
##
## 运行：godot --headless --path . res://tests/preview_player_actions.tscn
## 退出码 0 = 全过；1 = 有不符。

var _player: WuxiaPlayer
var _results: Array = []

func _ready() -> void:
	_player = WuxiaPlayer.new()
	add_child(_player)

	# 一块大地面，让玩家能落地（is_on_floor 才有意义）
	var floor_body := StaticBody2D.new()
	var fshape := CollisionShape2D.new()
	var frect := RectangleShape2D.new()
	frect.size = Vector2(4000, 40)
	fshape.shape = frect
	fshape.position = Vector2(0, 20)   # 顶面在 y=0
	floor_body.add_child(fshape)
	add_child(floor_body)

	_player.global_position = Vector2(0, -30)  # 落到 y=0 顶面

	# 等落地
	for i in 15:
		await get_tree().physics_frame

	# 注意 _case 内含 await，必须逐个 await 拿回结果数组；先赋给临时变量再 append（4.7 对协程调用更严格）
	var a1: Array = await _case("idle",   &"idle",   func(): _set_idle())
	var a2: Array = await _case("run",    &"run",    func(): _set_run())
	var a3: Array = await _case("attack", &"attack", func(): _set_attack())
	var a4: Array = await _case("hurt",   &"hurt",   func(): _set_hurt())
	var a5: Array = await _case("jump",   &"jump",   func(): _set_airborne())
	_results = [a1, a2, a3, a4, a5]

	var ok := true
	for r: Array in _results:
		if not r[1]:
			ok = false
		print("  [%-6s] 期望 %-7s 实际 %-7s  %s" % [r[0], r[2], r[3], "OK" if r[1] else "FAIL"])
	print("[qa] 主角动作状态机：%s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)

## 驱动到某状态后步进一帧，读取 _anim.animation
func _case(name: String, expect: StringName, setup: Callable) -> Array:
	setup.call()
	await get_tree().physics_frame
	var anim: StringName = &"<none>" if _player._anim == null else _player._anim.animation
	return [name, anim == expect, expect, anim]

func _set_idle() -> void:
	_player.velocity.x = 0.0
	_player._atk_phase = &"idle"
	_player._atk_timer = 0.0
	_player._hurt_timer = 0.0
	_player.global_position = Vector2(0, 0)   # 贴地

func _set_run() -> void:
	_player.velocity.x = 100.0
	_player._atk_phase = &"idle"
	_player._atk_timer = 0.0
	_player._hurt_timer = 0.0
	_player.global_position = Vector2(0, 0)

func _set_attack() -> void:
	_player.velocity.x = 0.0
	_player._atk_phase = &"wind"
	_player._atk_timer = 1.0   # 防止 _advance_attack 当帧切走
	_player._hurt_timer = 0.0
	_player.global_position = Vector2(0, 0)

func _set_hurt() -> void:
	_player.velocity.x = 0.0
	_player._atk_phase = &"idle"
	_player._atk_timer = 0.0
	_player._hurt_timer = 0.2
	_player.global_position = Vector2(0, 0)

func _set_airborne() -> void:
	_player.velocity.x = 0.0
	_player._atk_phase = &"idle"
	_player._atk_timer = 0.0
	_player._hurt_timer = 0.0
	_player.global_position = Vector2(0, -200)  # 抬离地面 -> is_on_floor 假
