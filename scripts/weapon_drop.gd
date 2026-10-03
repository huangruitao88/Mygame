class_name WuxiaWeaponDrop
extends Area2D

## 侠影录 · 武器掉落物
##
## 单一职责：把一件 WuxiaWeapon 摆在地上、把完整词条展示清楚，玩家按「拾取」键后广播 picked_up。
## 刻意不调用 player.equip_weapon —— 装备时机、以及「最多只能装一件」的规则
## 由 game.gd / player.gd 决定，掉落物本身不关心装备槽长什么样。
##
## 可独立按 F6 运行：weapon 为空时自动掷一把，方便单独看视觉。

signal picked_up(weapon: WuxiaWeapon)

const C_STEEL := Color("#cfd8dc")
const C_HILT := Color("#6b4a2f")

## 使用前必须先赋值，再 add_child（_ready() 会据它构建悬浮字）
var weapon: WuxiaWeapon

var _visuals: Node2D
var _backdrop: ColorRect
var _stats_label: Label
var _hint: Label
var _bob: Tween
var _near: bool = false
var _taken: bool = false

func _ready() -> void:
	if weapon == null:
		weapon = WuxiaWeapon.roll(RandomNumberGenerator.new())
	_build_visuals()
	_build_labels()
	_start_bob()
	# 物理判定不在 _ready() 里直接建 —— 原因见 _setup_physics()
	_setup_physics.call_deferred()

## 物理侧（碰撞层 + 拾取范围）单独成函数，且延迟一帧执行 —— 与 energy_orb.gd 同因同解。
##
## Boss 被砍死时，这条 `_spawn_weapon_drop()` 就发生在 player 攻击判定的 body_entered 回调里，
## 那一刻物理服务器正在 flush 查询，给刚进树的 Area2D 注册碰撞体会被引擎拒绝
## （`Can't change this state while flushing queries`），每次击杀刷一条 ERROR。
## 详细成因与「为什么这不影响能不能捡起来」见 energy_orb.gd 的 _setup_physics()。
func _setup_physics() -> void:
	collision_layer = 0
	collision_mask = 2
	_build_shape()
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

# ---------------- 拾取 ----------------

func _unhandled_input(event: InputEvent) -> void:
	if _taken or not _near:
		return
	if event.is_action_pressed("pickup"):
		get_viewport().set_input_as_handled()
		_take()

func _on_body_entered(body: Node2D) -> void:
	if _taken or not body.is_in_group("player"):
		return
	_near = true
	_hint.visible = true

func _on_body_exited(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	_near = false
	_hint.visible = false

func _take() -> void:
	_taken = true
	_near = false
	monitoring = false
	_hint.visible = false
	if _bob != null and _bob.is_valid():
		_bob.kill()
	# 先广播再播放消散动画：拾取与装备不等动画演完
	picked_up.emit(weapon)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_visuals, "position:y", -26.0, 0.28)
	tween.tween_property(_visuals, "modulate:a", 0.0, 0.28)
	tween.tween_property(_stats_label, "modulate:a", 0.0, 0.2)
	tween.tween_property(_backdrop, "modulate:a", 0.0, 0.2)
	tween.chain().tween_callback(queue_free)

# ---------------- 构建 ----------------

func _build_shape() -> void:
	var rect := RectangleShape2D.new()
	rect.size = Vector2(28, 34)
	var shape := CollisionShape2D.new()
	shape.shape = rect
	add_child(shape)

func _build_visuals() -> void:
	_visuals = Node2D.new()
	_visuals.name = "Visuals"
	add_child(_visuals)

	var tint: Color = weapon.quality_color()
	# 地面光晕：颜色随品质走，远处也能一眼看出值不值得捡
	Gfx.make_poly(_visuals, PackedVector2Array([
		Vector2(0, -4), Vector2(18, 8), Vector2(0, 20), Vector2(-18, 8),
	]), Color(tint.r, tint.g, tint.b, 0.26))
	# 斜插在地上的剑身（rotation 绕节点原点转，支点就是护手处）
	var blade: Polygon2D = Gfx.make_poly(_visuals, Gfx.rect_poly(-2.5, -28, 2.5, 4), C_STEEL)
	blade.rotation = 0.3
	Gfx.make_poly(_visuals, Gfx.rect_poly(-9, 1, 9, 4), tint)
	Gfx.make_poly(_visuals, Gfx.rect_poly(-3, 4, 3, 14), C_HILT)

## 悬浮字挂在掉落物自身上、不挂 _visuals：剑在上下浮动，词条要保持稳定好读。
## 词条直接压在山影背景上几乎看不清，所以铺一块随行数伸缩的半透明底板。
## LINE_H 取 17 而不是字号 10：Label 的最小高度按字体行高走（实测 4 行≈65px），
## 估算偏小的话底板会矮于文字，最下面一行会漏出底板外。
## 底板下沿抬到 -34：玩家就站在掉落物上，贴太低会把自己的上身盖住。
func _build_labels() -> void:
	var font: SystemFont = Gfx.cjk_font()
	var lines: int = 1 + weapon.substats.size()
	var box_h: float = 6.0 + float(lines) * 17.0
	var box_top: float = -34.0 - box_h

	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.04, 0.03, 0.06, 0.72)
	_backdrop.position = Vector2(-136.0, box_top)
	_backdrop.size = Vector2(272.0, box_h)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	_stats_label = _make_label(Vector2(-132.0, box_top + 3.0), Vector2(264.0, box_h - 6.0), weapon.quality_color(), 10, font)
	_stats_label.text = weapon.describe()
	_hint = _make_label(Vector2(-130, 22), Vector2(260, 16), Color("#e8e0d0"), 12, font)
	_hint.text = "%s  拾取" % _pickup_key_label()
	_hint.visible = false

## 拾取键的名字从 InputMap 现取，不写字面量 ——
## 键位从 K 改成 E 时这里没跟着改，界面就一直教玩家按一个已经没用的键；
## 现取之后键位再怎么调，提示永远跟实际按键一致。没绑到键盘（比如只剩手柄）时退回 "E"。
func _pickup_key_label() -> String:
	for ev: InputEvent in InputMap.action_get_events("pickup"):
		var key: InputEventKey = ev as InputEventKey
		if key == null:
			continue
		var label: String = key.as_text_physical_keycode()
		if not label.is_empty():
			return label
	return "E"

func _make_label(pos: Vector2, box: Vector2, color: Color, size: int, font: Font) -> Label:
	var label := Label.new()
	label.position = pos
	label.size = box
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _start_bob() -> void:
	_bob = create_tween().set_loops()
	_bob.tween_property(_visuals, "position:y", -5.0, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob.tween_property(_visuals, "position:y", 0.0, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
