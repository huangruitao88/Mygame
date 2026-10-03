extends Node2D

## 视觉预览场景（临时 QA 工具）：把小怪与 Boss 摆上台，按时间轴轮流播放
## 待机 / 行走 / 攻击 / 受击，配合 --write-movie 抓真实渲染帧用。
##
## 用法：
##   godot --path . --write-movie <Windows绝对路径>/f.png --fixed-fps 60 res://tests/preview_actors.tscn
## 时间轴（帧）：0-59 待机 · 60-119 行走 · 120-179 攻击 · 180-239 受击，240 帧收工。
##
## 刻意 set_physics_process(false)：不让重力/思考逻辑跑，动画由时间轴直接指定，
## 帧号与画面的对应关系是确定的，方便逐帧检查。

const GROUND_RECT := Rect2(-200, 300, 1100, 120)
const WALL_RECT := Rect2(620, 190, 30, 110)
const GROUND_TILE := "res://assets/backgrounds/ground_tile.png"
const WALL_TILE := "res://assets/backgrounds/wall_tile.png"
const MINION_POS := Vector2(240, 300)
const BOSS_POS := Vector2(430, 300)

var _minion: WuxiaEnemy
var _boss: WuxiaBoss

func _ready() -> void:
	_build_ground()
	_build_wall()
	_minion = WuxiaEnemy.new()
	_minion.position = MINION_POS
	add_child(_minion)
	_boss = WuxiaBoss.new()
	_boss.position = BOSS_POS
	add_child(_boss)
	# 关掉自主行为：站位固定、动画全归时间轴管
	_minion.set_physics_process(false)
	_boss.set_physics_process(false)

	var cam := Camera2D.new()
	cam.position = Vector2(335, 255)
	add_child(cam)
	cam.make_current()

func _build_ground() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = GROUND_RECT.position + GROUND_RECT.size * 0.5
	add_child(body)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = GROUND_RECT.size
	shape.shape = rect
	body.add_child(shape)

	var tex: Texture2D = load(GROUND_TILE) as Texture2D
	if tex != null:
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.centered = false
		spr.region_enabled = true
		spr.region_rect = Rect2(Vector2.ZERO, GROUND_RECT.size)
		spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.position = -GROUND_RECT.size * 0.5
		body.add_child(spr)
	var half_w: float = GROUND_RECT.size.x * 0.5
	var half_h: float = GROUND_RECT.size.y * 0.5
	Gfx.make_poly(body, Gfx.rect_poly(-half_w, -half_h, half_w, -half_h + 4.0), Color("#5d8a4a"))

## 与 game.gd 同款压暗调色，保证预览看到的就是关卡里的样子
func _build_wall() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = WALL_RECT.position + WALL_RECT.size * 0.5
	add_child(body)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = WALL_RECT.size
	shape.shape = rect
	body.add_child(shape)
	var tex: Texture2D = load(WALL_TILE) as Texture2D
	if tex != null:
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.centered = false
		spr.region_enabled = true
		spr.region_rect = Rect2(Vector2.ZERO, WALL_RECT.size)
		spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.modulate = Color(0.72, 0.76, 0.70)
		spr.position = -WALL_RECT.size * 0.5
		body.add_child(spr)

func _physics_process(_delta: float) -> void:
	var frame := Engine.get_physics_frames()
	var anim: StringName = &"idle"
	if frame >= 180:
		anim = &"hurt"
	elif frame >= 120:
		anim = &"attack"
	elif frame >= 60:
		anim = &"walk"
	_apply_both(anim)
	if frame >= 240:
		get_tree().quit()

func _apply_both(anim: StringName) -> void:
	_minion._apply_anim(anim)
	_boss._apply_anim(anim)
