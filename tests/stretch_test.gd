extends Node

## 视口自适应测试：验证「窗口比例不等于 16:9 时画面仍然铺满、不露黑边、
## HUD 仍然贴住屏幕边缘」这条不变量。
##
## 为什么不去改真实窗口尺寸：无头环境下 DisplayServer 根本没有窗口。
## 所以直接把一组「被撑开的视口尺寸」注入场景的 _vp 再调 _relayout_ui() ——
## 这正是把重排逻辑从 _apply_ui_anchors() 里拆出来的原因（见 game.gd）。
##
## 用法：
##   godot --headless --path <项目目录> res://tests/stretch_test.tscn

const GAME_SCENE := "res://scenes/main.tscn"
const TITLE_SCENE := "res://scenes/title.tscn"

## 基准视口（= project.godot 的 viewport 尺寸，也是两个脚本里 VIEW 常量的值）
const BASE := Vector2(960, 540)

## 被撑开的视口样本。1027x540 不是随手取的：它正好是「1920x1009 最大化窗口」
## 在 expand 模式下实际撑出来的逻辑宽度（= 1009 / 540 * 960），也就是这次
## 「四周一大圈黑边」现场的真实尺寸；1200x540 更宽一档（接近 21:9）用于验证余量；
## 960x600 是反方向（窗口比 16:9 高），验证下边缘元素。
const SAMPLES: Array[Vector2] = [
	Vector2(960, 540),
	Vector2(1027, 540),
	Vector2(1200, 540),
	Vector2(960, 600),
]

var _fails: int = 0

func _ready() -> void:
	await get_tree().process_frame
	_test_fullscreen_hotkey()
	await _test_game()
	await _test_title()
	print("[stretch] 完成：失败项 %d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)

# ---------------- 全屏快捷键 ----------------

func _test_fullscreen_hotkey() -> void:
	print("--- ScreenManager 全屏快捷键 ---")
	var mgr := get_node_or_null("/root/ScreenManager")
	_ok("ScreenManager 已注册为 Autoload", mgr != null)
	if mgr == null:
		return
	# 顿帧会把整棵树冻住，切全屏不该被冻（否则命中顿帧那 75ms 内按 F11 没反应）
	_ok("ScreenManager 不受顿帧影响（PROCESS_MODE_ALWAYS）",
		mgr.process_mode == Node.PROCESS_MODE_ALWAYS)

	_ok("F11 触发切换", _key(mgr, KEY_F11, false))
	_ok("Alt+Enter 触发切换", _key(mgr, KEY_ENTER, true))
	_ok("Alt+小键盘回车也触发", _key(mgr, KEY_KP_ENTER, true))
	_ok("单独的 Enter 不触发（不能抢 ui_accept）", not _key(mgr, KEY_ENTER, false))
	_ok("单独的 F12 不触发", not _key(mgr, KEY_F12, false))

## 造一个按键事件喂给 ScreenManager 的判定函数
func _key(mgr: Node, code: int, alt: bool) -> bool:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.alt_pressed = alt
	ev.pressed = true
	return mgr._is_toggle_event(ev)

# ---------------- main.tscn ----------------

func _test_game() -> void:
	print("--- main.tscn 视口自适应 ---")
	var game: WuxiaGame = load(GAME_SCENE).instantiate() as WuxiaGame
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame

	# ---- 基准：delta 必须为 0，一切与设计稿一致 ----
	game._vp = BASE
	game._relayout_ui()
	_ok("基准：小地图右边缘贴右(948)", _near(
		game._minimap_panel.position.x + game._minimap_panel.size.x, 948.0))
	_ok("基准：Boss 条水平居中(480)", _near(
		game._boss_bar.position.x + game._boss_bar.size.x * 0.5, 480.0))
	_ok("基准：技能栏 5 槽整体居中", _near(_skill_center(game), 480.0))

	# ---- 逐个样本注入：视口变了，HUD 的「贴边关系」必须原样成立 ----
	for vp: Vector2 in SAMPLES:
		var d: Vector2 = vp - BASE
		game._vp = vp
		game._relayout_ui()
		var tag := "vp=%dx%d" % [int(vp.x), int(vp.y)]

		# 贴右的元素：右边缘 = 视口右 - 12
		_ok("%s 小地图右边缘贴右" % tag, _near(
			game._minimap_panel.position.x + game._minimap_panel.size.x, vp.x - 12.0))
		# 区域名要停在小地图左侧 8px 处（两者一起移动，间距不该变）
		_ok("%s 区域名与小地图保持 8px 间距" % tag, _near(
			game._zone_label.position.x + game._zone_label.size.x,
			game._minimap_panel.position.x - 8.0))
		# 右下的连击大字 / 底部操作提示
		_ok("%s 连击字右下角贴边" % tag, _near(
			game._combo_label.position.x + game._combo_label.size.x + 14.0, vp.x) and _near(
			game._combo_label.position.y + game._combo_label.size.y + 72.0, vp.y))
		_ok("%s 操作提示右下角贴边" % tag, _near(
			game._hint_label.position.x + game._hint_label.size.x + 14.0, vp.x) and _near(
			game._hint_label.position.y + game._hint_label.size.y + 10.0, vp.y))
		# 居中的元素
		_ok("%s Boss 条水平居中" % tag, _near(
			game._boss_bar.position.x + game._boss_bar.size.x * 0.5, vp.x * 0.5))
		_ok("%s 技能栏整体居中" % tag, _near(_skill_center(game), vp.x * 0.5))
		# 全宽 / 全屏元素
		_ok("%s 顶部 toast 横贯全宽" % tag, _near(game._toast_label.size.x, vp.x))
		_ok("%s 格挡提示横贯全宽" % tag, _near(game._guard_hint.size.x, vp.x))
		_ok("%s 结算遮罩铺满视口" % tag, _near(game._overlay.size.x, vp.x)
			and _near(game._overlay.size.y, vp.y))
		# 贴左下的武器面板：底边 = 视口底 - 14
		_ok("%s 武器面板贴左下" % tag, _near(game._weapon_panel.position.x, 12.0) and _near(
			game._weapon_panel.position.y + game._weapon_panel.size.y, vp.y - 14.0))
		# 贴左上的元素不该被推走（头像块、区域名以外的左上内容）
		_ok("%s 左上元素保持不动" % tag, _near(game._hp_fill.position.x, 100.0)
			and _near(game._hp_text.position.y, 42.0))

		# ---- 背景底图必须盖满整个视口（这是「没有黑边」的直接证据）----
		var plate := game._bg_image
		if plate == null or plate.texture == null:
			_ok("%s 底图存在" % tag, false, "底图没加载，无法验证覆盖")
		else:
			var left: float = plate.position.x
			var right: float = plate.position.x + float(plate.texture.get_width()) * plate.scale.x
			_ok("%s 底图覆盖视口左右边缘" % tag, left <= 0.0 and right >= vp.x,
				"实际覆盖 [%.1f, %.1f]，视口 [0, %.1f]" % [left, right, vp.x])

	# ---- 幂等性：连发两次不能累积位移（窗口拖拽时 size_changed 会连发）----
	game._vp = Vector2(1200, 540)
	game._relayout_ui()
	var first_x: float = game._minimap_panel.position.x
	game._relayout_ui()
	game._relayout_ui()
	_ok("重排幂等（连调三次位置不变）",
		_near(game._minimap_panel.position.x, first_x))

	# ---- 回到基准必须精确复原（切回全屏时不能留下偏移）----
	game._vp = BASE
	game._relayout_ui()
	_ok("回到基准后小地图复原(808)", _near(game._minimap_panel.position.x, 808.0))
	_ok("回到基准后 Boss 条复原(370)", _near(game._boss_bar.position.x, 370.0))

	game.queue_free()
	await get_tree().process_frame

# ---------------- title.tscn ----------------

func _test_title() -> void:
	print("--- title.tscn 视口自适应 ---")
	var packed: PackedScene = load(TITLE_SCENE) as PackedScene
	if packed == null:
		_ok("title.tscn 可加载", false)
		return
	var title: TitleScreen = packed.instantiate() as TitleScreen
	add_child(title)
	await get_tree().process_frame
	await get_tree().process_frame

	for vp: Vector2 in SAMPLES:
		title._vp = vp
		title._relayout_ui()
		var tag := "vp=%dx%d" % [int(vp.x), int(vp.y)]
		# 遮罩（弹窗底衬）与暗角必须铺满，否则弹窗打开时两侧还是亮的
		_ok("%s 暗角层铺满" % tag, _near(_vignette_size(title).x, vp.x)
			and _near(_vignette_size(title).y, vp.y))
		_ok("%s 弹窗遮罩铺满" % tag, _near(_mask_size(title).x, vp.x)
			and _near(_mask_size(title).y, vp.y))
		# 菜单按钮居中
		_ok("%s 菜单按钮居中" % tag, _near(_menu_center(title), vp.x * 0.5))

	title._vp = BASE
	title._relayout_ui()
	_ok("title 回到基准后菜单居中(480)", _near(_menu_center(title), 480.0))

	title.queue_free()
	await get_tree().process_frame

# ---------------- 取值辅助 ----------------

## 技能栏 5 个槽的整体中心：锚定已保证每个槽平移同一个 delta，
## 所以只要「首槽左边缘 + 末槽右边缘」的中点等于视口中心，就说明整排居中。
func _skill_center(game: WuxiaGame) -> float:
	var slots: Array[Control] = []
	for entry: Dictionary in game._anchors:
		var node: Control = entry["node"]
		if is_instance_valid(node) and node is Panel and _near(node.size.x, 68.0):
			slots.append(node)
	if slots.is_empty():
		return -1.0
	var min_x: float = INF
	var max_x: float = -INF
	for s: Control in slots:
		min_x = minf(min_x, s.position.x)
		max_x = maxf(max_x, s.position.x + s.size.x)
	return (min_x + max_x) * 0.5

func _mask_size(title: TitleScreen) -> Vector2:
	for child: Node in title._overlay.get_children():
		var rect := child as ColorRect
		if rect != null:
			return rect.size
	return Vector2.ZERO

## 菜单按钮整排的中心。用 custom_minimum_size 而不是 size：
## Button 的 size 要等一次布局才算出来，断言不该赌那个时机。
func _menu_center(title: TitleScreen) -> float:
	if title._menu_buttons.is_empty():
		return -1.0
	var first: Button = title._menu_buttons[0]
	return first.position.x + first.custom_minimum_size.x * 0.5

## 暗角层（_build_background 里 layer = 20 的 CanvasLayer 下的那块 ColorRect）
func _vignette_size(title: TitleScreen) -> Vector2:
	for child: Node in title.get_children():
		var layer := child as CanvasLayer
		if layer == null or layer.layer != 20:
			continue
		for sub: Node in layer.get_children():
			var rect := sub as ColorRect
			if rect != null:
				return rect.size
	return Vector2.ZERO

# ---------------- 断言 ----------------

func _near(a: float, b: float, eps: float = 0.02) -> bool:
	return absf(a - b) <= eps

func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  [ok]   %s" % label)
		return
	_fails += 1
	print("  [FAIL] %s %s" % [label, detail])
