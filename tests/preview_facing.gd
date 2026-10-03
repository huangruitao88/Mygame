extends Node2D

## 朝向 QA：让敌兵**真的走起来**（不是手动指定动画帧），逐帧记录
## 「面朝方向 _facing」与「实际横向位移方向」是否一致。
## 这是唯一能证明「走路方向和面朝方向一致」的手段 —— 静态抓帧看不出朝向与位移的矛盾。
##
## 用法：
##   godot --path . --write-movie <绝对路径>/f.png --fixed-fps 60 res://tests/preview_facing.tscn
##
## 布局：敌兵站左侧、玩家站右侧 400px 外（在 detect_radius 之外则改靠巡逻）。
## 为了必然触发「朝右追击」，把敌兵 detect_radius 调到很大，玩家静止在右方。
## 逐物理帧输出 facing / x / dx 到 stdout，跑 120 帧后收工。

const MINION_POS := Vector2(240, 300)
const RUN_FRAMES := 120

var _player_pos := Vector2(360, 300)

var _minion: WuxiaEnemy
var _player: WuxiaPlayer
var _prev_x: float = 0.0
var _mismatch: int = 0
var _moved_frames: int = 0

func _ready() -> void:
	_build_ground()

	# 支持 --left 反向用例：玩家摆到敌兵**左侧**，逼敌兵朝左走。
	# 两个方向都过，才说明镜像在两个朝向上都成立（只测一边可能掩盖符号错误）。
	if "--left" in OS.get_cmdline_user_args():
		_player_pos = Vector2(120, 300)

	# 玩家：静态站位，不参与输入。放在敌兵一侧，逼敌兵追过来。
	_player = WuxiaPlayer.new()
	_player.position = _player_pos
	add_child(_player)
	_player.set_physics_process(false)
	_player.collision_layer = 0
	_player.collision_mask = 0
	_player.visible = true

	_minion = WuxiaEnemy.new()
	_minion.position = MINION_POS
	_minion.detect_radius = 900.0
	_minion.patrol_range = 900.0
	add_child(_minion)
	_prev_x = _minion.global_position.x
	print("[facing-qa] 开始：敌兵 x=%.1f 玩家 x=%.1f" % [
		_minion.global_position.x, _player.global_position.x])

	var cam := Camera2D.new()
	cam.position = Vector2(300, 255)
	add_child(cam)
	cam.make_current()

func _build_ground() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2(100, 360)
	add_child(body)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(1400, 120)
	shape.shape = rect
	body.add_child(shape)

func _physics_process(_delta: float) -> void:
	var frame := Engine.get_physics_frames()
	var x: float = _minion.global_position.x
	var dx: float = x - _prev_x
	_prev_x = x
	if absf(dx) > 0.5:
		_moved_frames += 1
		var moving_dir: int = 1 if dx > 0.0 else -1
		var ok: bool = moving_dir == _minion._facing
		if not ok:
			_mismatch += 1
		print("[facing-qa] f%-4d facing=%+d 位移=%+6.2f 方向=%+d %s" % [
			frame, _minion._facing, dx, moving_dir, "OK" if ok else "!! 朝向与位移相反 !!"])
	if frame >= RUN_FRAMES:
		print("[facing-qa] 结束：位移帧 %d，朝向不符帧 %d" % [_moved_frames, _mismatch])
		print("[facing-qa] %s" % ("通过：所有位移方向都与面朝方向一致" if _mismatch == 0 else "失败：存在朝向与位移相反"))
		get_tree().quit()
