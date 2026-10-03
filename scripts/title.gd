class_name TitleScreen
extends Node2D

## 侠影录 · 主界面（项目入口场景）
##
## 单一职责：把「水墨江湖」风格的主界面呈现出来，并把「开始游戏」交给场景切换。
## 刻意不持有任何玩法状态、不引入 Autoload —— 主界面只做一件事，
## 多了间接层只会变成没有人监听的死信号。
## 本场景可单独按 F6 运行，不依赖任何父节点。
##
## 视觉对齐参考版（剑雨江湖 · 水墨江湖主题）：
##   竖排大标题 + 副标题 + 题签、朱砂印章、月 / 远山 / 雾 / 落花动态背景、
##   三键主菜单（开始游戏·设置·存档）、设置与存档弹窗、上下键/回车/ Esc 键盘导航。

const VIEW := Vector2(960, 540)
const GAME_SCENE := "res://scenes/main.tscn"

## 主界面背景视频（Theora 编码的 .ogv，480x270 已在转码时合成横屏构图）。
## 加载失败（新克隆仓库未导入 / 文件缺失）时回退到程序化水墨背景。
const VIDEO_PATH := "res://assets/video/title_bg.ogv"

# ---- 设计令牌（水墨江湖主题，取自参考版的 ink/paper/cinnabar/gold 色板）----
const C_INK_900 := Color("#14110e")
const C_INK_800 := Color("#1d1916")
const C_INK_700 := Color("#2a241f")
const C_INK_600 := Color("#3a322b")
const C_INK_400 := Color("#6b5f52")
const C_PAPER := Color("#f4ecdc")
const C_PAPER_200 := Color("#e9dcc2")
const C_PAPER_300 := Color("#d9c6a3")
const C_CINNABAR := Color("#b23a2e")
const C_CINNABAR_DEEP := Color("#8f2a20")
const C_JADE := Color("#5e8b7e")
const C_JADE_DEEP := Color("#3f6358")
const C_GOLD := Color("#c8a45c")
const C_GOLD_SOFT := Color("#d9bd84")

var _sky_colors := PackedColorArray([Color("#161b22"), Color("#1d1916"), Color("#221a13")])

# ---- 菜单项定义：文本 + 动作标识 ----
const MENU_ITEMS: Array[Dictionary] = [
	{"label": "开 始 游 戏", "action": "start", "primary": true},
	{"label": "设    置", "action": "settings", "primary": false},
	{"label": "存    档", "action": "saves", "primary": false},
]

const MENU_START_Y := 304.0
const MENU_ITEM_H := 52.0
const MENU_ITEM_GAP := 14.0

# ---- 弹窗面板尺寸 ----
const PANEL_SIZE := Vector2(560, 424)
const PANEL_POS := Vector2((VIEW.x - PANEL_SIZE.x) / 2.0, 56.0)

# ---- 设置默认值 ----
var _settings := {
	"music": true,
	"sfx": true,
	"master": 70,
	"quality": 1,
	"subtitle": false,
}

# ---- 存档数据（演示用静态数据）----
const SAVE_SLOTS: Array[Dictionary] = [
	{"id": "壹", "title": "侠客行 · 第二回", "meta": "角色：无名 · 等级 17", "empty": false},
	{"id": "贰", "title": "剑冢秘境", "meta": "角色：叶知秋 · 等级 9", "empty": false},
	{"id": "叁", "title": "空槽位", "meta": "尚无记录", "empty": true},
]

var _font_title: SystemFont
var _font_ui: SystemFont

var _ui: Control
var _bg_root: Node2D
var _menu_layer: CanvasLayer
var _menu_buttons: Array[Button] = []
var _selected: int = 0

# ---- 弹窗 ----
var _overlay: Control
var _panel: PanelContainer
var _overlay_open: bool = false

# ---- 落花粒子 ----
var _petal_layer: Node2D
var _petal_pool: Array[Dictionary] = []

var _rng := RandomNumberGenerator.new()

## 实际视口尺寸（逻辑像素）。project.godot 用 stretch/aspect=expand：
## 窗口比 16:9 宽时视口会被横向撑开（而不是留黑边），撑开的尺寸存在这里。
## VIEW 仍是**布局基准**（960x540），上面所有坐标都按它写死 —— 撑出来的差值
## 由 _apply_ui_anchors() 统一摊开，所以这个文件的坐标一个都不用动。
var _vp: Vector2 = VIEW
## UI 锚定表，见 _anchor()。
var _anchors: Array[Dictionary] = []

func _ready() -> void:
	_rng.randomize()
	_font_title = _make_system_font(PackedStringArray(["KaiTi", "STKaiti", "SimSun", "Microsoft YaHei"]))
	_font_ui = _make_system_font(PackedStringArray(["Microsoft YaHei", "SimHei", "Noto Sans SC", "sans-serif"]))

	# 视口尺寸必须先同步：背景层要按它铺满，锚定表要按它记基准
	_sync_viewport_size()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_build_background()
	_build_menu()
	_build_overlay()
	_set_selected(0)
	_ui.modulate.a = 1.0

# ---------------- 输入 ----------------

func _unhandled_input(event: InputEvent) -> void:
	# 弹窗打开时：Esc / 关闭按钮关闭，其余输入不透传到菜单
	if _overlay_open:
		if event.is_action_pressed("ui_cancel"):
			_close_overlay()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_down"):
		_set_selected(_selected + 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up"):
		_set_selected(_selected - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_activate(_selected)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		_quit()
		get_viewport().set_input_as_handled()

# ---------------- 菜单 ----------------

func _build_menu() -> void:
	_menu_layer = CanvasLayer.new()
	_menu_layer.name = "MenuUI"
	add_child(_menu_layer)

	_ui = Control.new()
	_ui.size = VIEW
	_menu_layer.add_child(_ui)

	# 朱砂印章（左上角「侠」字）
	var seal := PanelContainer.new()
	seal.position = Vector2(32, 40)
	seal.custom_minimum_size = Vector2(80, 80)
	seal.add_theme_stylebox_override("panel", _style(Color(C_CINNABAR.r, C_CINNABAR.g, C_CINNABAR.b, 0.06), C_CINNABAR, 8))
	seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(seal)
	var seal_label := Label.new()
	seal_label.text = "侠"
	seal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seal_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	seal_label.add_theme_font_override("font", _font_title)
	seal_label.add_theme_font_size_override("font_size", 44)
	seal_label.add_theme_color_override("font_color", C_CINNABAR)
	seal.add_child(seal_label)

	# 竖排大标题「剑雨江湖」（逐字换行实现竖排；置于左侧，右侧留给视频人物）
	var name_label := Label.new()
	name_label.text = "剑\n雨\n江\n湖"
	name_label.position = Vector2(128, 16)
	name_label.size = Vector2(80, 240)
	name_label.add_theme_font_override("font", _font_title)
	name_label.add_theme_font_size_override("font_size", 48)
	name_label.add_theme_constant_override("line_spacing", 4)
	name_label.add_theme_color_override("font_color", C_PAPER)
	name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	name_label.add_theme_constant_override("shadow_offset_x", 2)
	name_label.add_theme_constant_override("shadow_offset_y", 4)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(name_label)

	# 标题右侧鎏金竖线（参考版 game-name::after）
	var title_bar := ColorRect.new()
	title_bar.color = Color(C_GOLD.r, C_GOLD.g, C_GOLD.b, 0.5)
	title_bar.position = Vector2(220, 24)
	title_bar.size = Vector2(4, 224)
	title_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(title_bar)

	# 副标题「JIANGHU」与题签（左置区域，与竖排标题对齐）
	_left_label(48, 244, 240, "J I A N G H U", _font_ui, 22, C_GOLD_SOFT)
	_left_label(48, 272, 240, "一 剑 霜 寒 十 四 州", _font_ui, 18, Color(C_PAPER.r, C_PAPER.g, C_PAPER.b, 0.6))

	# 菜单按钮（宽 360，居中）
	for i: int in MENU_ITEMS.size():
		var item: Dictionary = MENU_ITEMS[i]
		var btn := _make_menu_button(str(item["label"]), bool(item["primary"]))
		btn.position = Vector2(300, MENU_START_Y + float(i) * (MENU_ITEM_H + MENU_ITEM_GAP))
		_ui.add_child(btn)
		# 300 + 360/2 = 480 = 960/2 —— 按钮本就居中，锚 0.5 让它在更宽的视口里继续居中
		_anchor(btn, 0.5, 0.0)
		_menu_buttons.append(btn)

	# 操作提示
	_centered_label(500, "↑ ↓ 选择 · Enter 确认 · Esc 返回", _font_ui, 16, Color(C_PAPER.r, C_PAPER.g, C_PAPER.b, 0.45))

	# 页脚信息（右下角小字，避开提示行）
	var footer := Label.new()
	footer.text = "v1.0.0 · © 2026"
	footer.position = Vector2(740, 512)
	footer.size = Vector2(208, 24)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_theme_font_override("font", _font_ui)
	footer.add_theme_font_size_override("font_size", 14)
	footer.add_theme_color_override("font_color", Color(C_PAPER.r, C_PAPER.g, C_PAPER.b, 0.35))
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(footer)
	_anchor(footer, 1.0, 1.0)

func _make_menu_button(text: String, is_primary: bool) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(360, MENU_ITEM_H)
	btn.add_theme_font_override("font", _font_ui)
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", C_PAPER)
	btn.add_theme_color_override("font_hover_color", Color("#ffffff"))
	btn.add_theme_color_override("font_pressed_color", Color("#ffffff"))
	btn.add_theme_color_override("font_focus_color", C_PAPER)

	if is_primary:
		btn.add_theme_stylebox_override("normal", _style(C_CINNABAR, Color(1, 1, 1, 0.15), 6))
		btn.add_theme_stylebox_override("hover", _style(Color("#c6463a"), Color(C_GOLD.r, C_GOLD.g, C_GOLD.b, 0.6), 6))
		btn.add_theme_stylebox_override("focus", _style(C_CINNABAR, C_GOLD, 6))
		btn.add_theme_stylebox_override("pressed", _style(C_CINNABAR_DEEP, C_GOLD, 6))
	else:
		btn.add_theme_stylebox_override("normal", _style(Color(0.20, 0.18, 0.15, 0.65), Color(C_GOLD.r, C_GOLD.g, C_GOLD.b, 0.28), 6))
		btn.add_theme_stylebox_override("hover", _style(Color(0.28, 0.19, 0.16, 0.8), C_CINNABAR, 6))
		btn.add_theme_stylebox_override("focus", _style(Color(0.20, 0.18, 0.15, 0.8), C_GOLD, 6))
		btn.add_theme_stylebox_override("pressed", _style(Color(0.15, 0.13, 0.11, 0.9), C_CINNABAR, 6))
	return btn

func _set_selected(index: int) -> void:
	if _menu_buttons.is_empty():
		return
	_selected = int(posmod(index, _menu_buttons.size()))
	_menu_buttons[_selected].grab_focus()

func _activate(index: int) -> void:
	var item: Dictionary = MENU_ITEMS[index]
	var action: String = str(item["action"])
	match action:
		"start":
			_start_game()
		"settings":
			_open_overlay("settings")
		"saves":
			_open_overlay("saves")
		_:
			push_warning("TitleScreen: 未知菜单动作 '%s'" % action)

func _start_game() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)

func _quit() -> void:
	get_tree().quit()

# ---------------- 弹窗 ----------------

func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.size = VIEW
	# 容器本身不拦截：弹窗的鼠标拦截职责由 mask（全屏 STOP）承担。
	# 若容器也用 STOP，某些引擎版本下 visible=false 仍会盖住底层按钮，导致菜单点不动。
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_ui.add_child(_overlay)

	# 遮罩
	var mask := ColorRect.new()
	mask.color = Color(0.04, 0.03, 0.02, 0.55)
	mask.size = VIEW
	mask.mouse_filter = Control.MOUSE_FILTER_STOP
	mask.gui_input.connect(_on_mask_input)
	_overlay.add_child(mask)
	# 遮罩必须盖满整个视口：漏边的话弹窗打开时两侧仍是亮的，像没开全
	_anchor(mask, 0.0, 0.0, true, true)

	# 宣纸面板
	_panel = PanelContainer.new()
	_panel.position = PANEL_POS
	_panel.size = PANEL_SIZE
	_panel.add_theme_stylebox_override("panel", _style(Color(C_PAPER.r, C_PAPER.g, C_PAPER.b, 0.98), C_GOLD, 12))
	_overlay.add_child(_panel)
	# 弹窗横向居中（PANEL_POS 里的 x 就是按 960 基准算的中心位置）
	_anchor(_panel, 0.5, 0.0)

func _open_overlay(kind: String) -> void:
	_clear_panel()
	match kind:
		"settings":
			_build_settings_panel()
		"saves":
			_build_saves_panel()
		_:
			return
	_overlay_open = true
	_overlay.visible = true

func _close_overlay() -> void:
	_overlay_open = false
	_overlay.visible = false
	if not _menu_buttons.is_empty():
		_menu_buttons[_selected].grab_focus()

func _on_mask_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close_overlay()

func _clear_panel() -> void:
	# 先摘下再延迟释放：queue_free 到帧末才生效，直接留在容器里会挤占这一次的布局。
	for child: Node in _panel.get_children():
		_panel.remove_child(child)
		child.queue_free()

## 面板头：标题 + 副题 + 分隔线，返回承接各行内容的 VBox。
func _panel_header(title: String, subtitle: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.position = Vector2(32, 20)
	box.size = PANEL_SIZE - Vector2(64, 40)
	box.add_theme_constant_override("separation", 12)
	_panel.add_child(box)

	var title_label := Label.new()
	title_label.text = title
	title_label.add_theme_font_override("font", _font_title)
	title_label.add_theme_font_size_override("font_size", 44)
	title_label.add_theme_color_override("font_color", C_INK_800)
	box.add_child(title_label)

	var sub := Label.new()
	sub.text = subtitle
	sub.add_theme_font_override("font", _font_ui)
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", C_CINNABAR)
	box.add_child(sub)

	# 标题分隔线
	var rule := HSeparator.new()
	rule.modulate = Color(C_CINNABAR.r, C_CINNABAR.g, C_CINNABAR.b, 0.35)
	box.add_child(rule)

	return box

func _build_settings_panel() -> void:
	var box := _panel_header("设置", "SETTINGS")

	# 开关行
	_add_setting_row(box, "背景音乐", "江湖原声 · 古琴与笛", "music")
	_add_setting_row(box, "音效", "刀剑 · 脚步 · 环境", "sfx")
	_add_setting_row(box, "字幕", "剧情与对话字幕", "subtitle")

	# 主音量滑块
	_add_slider_row(box, "主音量", "master", 0, 100)
	# 画面品质滑块
	_add_slider_row(box, "画面品质", "quality", 0, 2)

func _add_setting_row(box: VBoxContainer, label: String, desc: String, key: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)

	var label_box := VBoxContainer.new()
	label_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label_box.add_theme_constant_override("separation", 0)
	row.add_child(label_box)

	var name_label := Label.new()
	name_label.text = label
	name_label.add_theme_font_override("font", _font_ui)
	name_label.add_theme_font_size_override("font_size", 26)
	name_label.add_theme_color_override("font_color", C_INK_700)
	label_box.add_child(name_label)

	var desc_label := Label.new()
	desc_label.text = desc
	desc_label.add_theme_font_override("font", _font_ui)
	desc_label.add_theme_font_size_override("font_size", 16)
	desc_label.add_theme_color_override("font_color", C_INK_400)
	label_box.add_child(desc_label)

	var toggle := CheckButton.new()
	toggle.button_pressed = bool(_settings[key])
	toggle.scale = Vector2(1.6, 1.6)
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.toggled.connect(func(on: bool) -> void: _settings[key] = on)
	row.add_child(toggle)

func _add_slider_row(box: VBoxContainer, label: String, key: String, min_val: int, max_val: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(row)

	var name_label := Label.new()
	name_label.text = label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_override("font", _font_ui)
	name_label.add_theme_font_size_override("font_size", 26)
	name_label.add_theme_color_override("font_color", C_INK_700)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = 1
	slider.value = int(_settings[key])
	slider.custom_minimum_size = Vector2(220, 28)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 朱砂圆点 grabber（程序化生成，参考版 slider-thumb）
	slider.add_theme_icon_override("grabber", _make_dot_icon(C_CINNABAR))
	slider.add_theme_icon_override("grabber_highlight", _make_dot_icon(Color("#c6463a")))
	slider.add_theme_icon_override("grabber_disabled", _make_dot_icon(C_INK_400))
	# 暗色圆角滑槽（参考版暗底细条）
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(C_INK_800.r, C_INK_800.g, C_INK_800.b, 0.22)
	groove.set_corner_radius_all(4)
	groove.content_margin_top = 4.0
	groove.content_margin_bottom = 4.0
	slider.add_theme_stylebox_override("slider", groove)
	row.add_child(slider)

	var val_label := Label.new()
	val_label.custom_minimum_size = Vector2(56, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_label.add_theme_font_override("font", _font_ui)
	val_label.add_theme_font_size_override("font_size", 22)
	val_label.add_theme_color_override("font_color", C_CINNABAR_DEEP)
	row.add_child(val_label)

	# 画面品质用文字档位显示
	var update_val := func(value: float) -> void:
		_settings[key] = int(value)
		if key == "quality":
			val_label.text = ["低", "高", "极致"][int(value)]
		else:
			val_label.text = str(int(value))
	update_val.call(slider.value)
	slider.value_changed.connect(update_val)

## 程序化画一枚圆形 grabber 图标（朱砂圆 + 纸白描边）
func _make_dot_icon(color: Color) -> ImageTexture:
	var size := 24
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size / 2.0 - 0.5, size / 2.0 - 0.5)
	for y: int in size:
		for x: int in size:
			var dist := Vector2(x, y).distance_to(center)
			if dist <= 8.0:
				img.set_pixel(x, y, color)
			elif dist <= 10.0:
				img.set_pixel(x, y, C_PAPER)
	return ImageTexture.create_from_image(img)

func _build_saves_panel() -> void:
	var box := _panel_header("存档", "SAVE & LOAD")

	for slot: Dictionary in SAVE_SLOTS:
		_add_save_slot(box, slot)

func _add_save_slot(box: VBoxContainer, slot: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.custom_minimum_size = Vector2(0, 68)
	box.add_child(row)

	var icon := PanelContainer.new()
	icon.custom_minimum_size = Vector2(60, 60)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var icon_label := Label.new()
	icon_label.text = str(slot["id"])
	icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_label.add_theme_font_override("font", _font_title)
	icon_label.add_theme_font_size_override("font_size", 30)
	icon_label.add_theme_color_override("font_color", C_PAPER)
	icon.add_child(icon_label)
	if bool(slot["empty"]):
		icon.add_theme_stylebox_override("panel", _style(Color("#5f5343"), Color(0, 0, 0, 0.2), 8))
	else:
		icon.add_theme_stylebox_override("panel", _style(C_JADE, Color(0, 0, 0, 0.2), 8))
	row.add_child(icon)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)

	var title_label := Label.new()
	title_label.text = str(slot["title"])
	title_label.add_theme_font_override("font", _font_ui)
	title_label.add_theme_font_size_override("font_size", 26)
	title_label.add_theme_color_override("font_color", C_INK_800)
	body.add_child(title_label)

	var meta_label := Label.new()
	meta_label.text = str(slot["meta"])
	meta_label.add_theme_font_override("font", _font_ui)
	meta_label.add_theme_font_size_override("font_size", 18)
	meta_label.add_theme_color_override("font_color", C_INK_400)
	body.add_child(meta_label)

	var act := Label.new()
	act.text = "新建 ›" if bool(slot["empty"]) else "读取 ›"
	act.add_theme_font_override("font", _font_ui)
	act.add_theme_font_size_override("font_size", 24)
	act.add_theme_color_override("font_color", C_CINNABAR_DEEP)
	row.add_child(act)

# ---------------- 背景 ----------------

func _build_background() -> void:
	_bg_root = Node2D.new()
	_bg_root.name = "Background"
	add_child(_bg_root)

	# 1. 最底层：视频背景（循环播放）；缺失时回退到天空渐变 + 月亮 + 远山
	if not _build_video_background():
		_build_fallback_background()

	# 2. 雾层（半透明，缓慢横向漂移；视频 / 程序化两条背景分支共用）
	_build_mist()

	# 3. 落花粒子
	_build_petals()

	# 4. 暗角
	var vignette := CanvasLayer.new()
	vignette.layer = 20
	add_child(vignette)
	var vig := ColorRect.new()
	vig.color = Color(0.0, 0.0, 0.0, 0.22)
	vig.size = VIEW
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.add_child(vig)
	# 暗角是「铺满」类：expand 撑宽后右侧露一条不压暗的亮边会很明显
	_anchor(vig, 0.0, 0.0, true, true)

## 尝试构建视频背景层。成功返回 true；视频缺失（未导入 / 文件不存在）返回 false。
func _build_video_background() -> bool:
	if not ResourceLoader.exists(VIDEO_PATH):
		push_warning("TitleScreen: 背景视频缺失，回退到程序化背景（%s）" % VIDEO_PATH)
		return false
	var stream: VideoStream = load(VIDEO_PATH) as VideoStream
	if stream == null:
		push_warning("TitleScreen: 背景视频加载失败，回退到程序化背景")
		return false

	# 视频画布在天空渐变同层（-10），完全盖住兜底渐变
	var layer := CanvasLayer.new()
	layer.layer = -10
	layer.name = "VideoBackground"
	add_child(layer)

	var player := VideoStreamPlayer.new()
	player.stream = stream
	player.loop = true
	player.expand = true
	player.size = VIEW
	player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	player.finished.connect(player.play)  # loop 之外的兜底，防止某些版本循环失效
	layer.add_child(player)
	# 视频是铺满类：expand 撑出来的宽度也要盖住，否则右侧一条黑
	_anchor(player, 0.0, 0.0, true, true)
	player.play()
	return true

## 程序化水墨背景（视频缺失时的兜底）：天空渐变 + 月亮 + 远山剪影
func _build_fallback_background() -> void:
	var sky := CanvasLayer.new()
	sky.layer = -10
	add_child(sky)
	var grad := Gradient.new()
	grad.colors = _sky_colors
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = int(VIEW.x)
	tex.height = int(VIEW.y)
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.size = VIEW
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.add_child(rect)
	_anchor(rect, 0.0, 0.0, true, true)

	_build_moon()

	var mountains := Node2D.new()
	_bg_root.add_child(mountains)
	_silhouette_band(mountains, 410.0, 180.0, 360, Color("#2c2620"), 0.5)
	_silhouette_band(mountains, 456.0, 140.0, 240, Color("#1a1511"), 1.0)

func _build_moon() -> void:
	var moon_layer := Node2D.new()
	_bg_root.add_child(moon_layer)
	# 月轮用多边形近似圆 + 光晕（参考版 top 9% / right 16% → 视口内约 (772, 80)）
	var halo := Polygon2D.new()
	halo.polygon = Gfx.circle_poly(60.0, 24)
	halo.color = Color(C_GOLD_SOFT.r, C_GOLD_SOFT.g, C_GOLD_SOFT.b, 0.16)
	halo.position = Vector2(772, 80)
	moon_layer.add_child(halo)
	var moon := Polygon2D.new()
	moon.polygon = Gfx.circle_poly(34.0, 20)
	moon.color = C_PAPER_200
	moon.position = Vector2(772, 80)
	moon_layer.add_child(moon)

func _build_mist() -> void:
	var mist := Node2D.new()
	_bg_root.add_child(mist)
	var band := Polygon2D.new()
	# 按实际视口宽度铺：雾带随 tween 在 x∈[0,48] 漂移，宽度不足时右边会露出没雾的一段
	band.polygon = Gfx.rect_poly(-40, 0, _vp.x + 40, 52)
	band.color = Color(C_PAPER.r, C_PAPER.g, C_PAPER.b, 0.06)
	band.position = Vector2(0, 392)
	mist.add_child(band)
	# 缓慢漂移动画
	var tween := create_tween().set_loops()
	tween.tween_property(band, "position:x", 48.0, 22.0)
	tween.tween_property(band, "position:x", 0.0, 22.0)

func _build_petals() -> void:
	_petal_layer = Node2D.new()
	_petal_layer.name = "Petals"
	_bg_root.add_child(_petal_layer)
	# 预生成 16 片落花，各自独立速度 / 相位 / 位置
	for i: int in 16:
		var petal := Polygon2D.new()
		var size: float = _rng.randf_range(6.0, 12.0)
		petal.polygon = PackedVector2Array([
			Vector2(0, 0),
			Vector2(size, size * 0.4),
			Vector2(size * 0.6, size),
			Vector2(0, size),
		])
		petal.color = Color(C_CINNABAR.r, C_CINNABAR.g, C_CINNABAR.b, _rng.randf_range(0.5, 0.9))
		_petal_layer.add_child(petal)
		_petal_pool.append({
			"node": petal,
			"speed": _rng.randf_range(28.0, 60.0),
			"x": _rng.randf_range(0.0, _vp.x),
			"y": _rng.randf_range(0.0, _vp.y),
			"sway": _rng.randf_range(8.0, 20.0),
			"phase": _rng.randf_range(0.0, TAU),
		})

func _process(delta: float) -> void:
	_update_petals(delta)

func _update_petals(delta: float) -> void:
	for petal: Dictionary in _petal_pool:
		var node: Polygon2D = petal["node"] as Polygon2D
		var speed: float = petal["speed"]
		var x: float = petal["x"]
		var y: float = petal["y"]
		var sway: float = petal["sway"]
		var phase: float = petal["phase"]
		y += speed * delta
		if y > _vp.y + 10.0:
			y = -10.0
			x = _rng.randf_range(0.0, _vp.x)
		petal["y"] = y
		var dx: float = x + sin(phase + y * 0.06) * sway
		node.position = Vector2(dx, y)

# ---------------- 视口自适应 ----------------

## 读一次真实视口尺寸。expand 模式下它 = 「按窗口比例横向展开后的逻辑尺寸」；
## 16:9 窗口下正好等于 VIEW，此时所有锚定增量都是 0，界面与展开前像素级一致。
func _sync_viewport_size() -> void:
	_vp = get_viewport_rect().size

func _ui_delta() -> Vector2:
	return _vp - VIEW

## 注册一个 UI 元素进锚定表：dx / dy 取 0 / 0.5 / 1，含义是「贴左·居中·贴右」
## 「贴上·居中·贴下」。纯贴左上的元素（印章、竖排标题、左侧题签）不用注册 ——
## 它们的补偿量恒为 0，注册了也只是白跑一遍。
##
## stretch_x / stretch_y：除了位移，宽度 / 高度也跟着补 delta（全屏层、全宽条）。
func _anchor(node: Control, dx: float, dy: float,
		stretch_x: bool = false, stretch_y: bool = false) -> void:
	_anchors.append({
		"node": node, "pos": node.position, "size": node.size,
		"dx": dx, "dy": dy, "sx": stretch_x, "sy": stretch_y,
	})

func _on_viewport_resized() -> void:
	if is_inside_tree():
		_apply_ui_anchors.call_deferred()

## 按当前 _vp 重排。拆成独立函数是为了可测：测试可以直接塞一个「被撑宽的视口尺寸」
## 进来验证锚定数学，不必真的去改窗口大小（无头环境下也改不了）。
## 幂等：每次都从「基准位置 + 当前 delta」重算，连发多少次都不积累误差。
func _apply_ui_anchors() -> void:
	_sync_viewport_size()
	_relayout_ui()

func _relayout_ui() -> void:
	var d := _ui_delta()
	for entry: Dictionary in _anchors:
		var node: Control = entry["node"]
		if not is_instance_valid(node):
			continue
		var pos: Vector2 = entry["pos"]
		node.position = pos + Vector2(float(entry["dx"]) * d.x, float(entry["dy"]) * d.y)
		var size: Vector2 = entry["size"]
		if entry["sx"]:
			size.x += d.x
		if entry["sy"]:
			size.y += d.y
		node.size = size

# ---------------- 工具 ----------------

func _make_system_font(names: PackedStringArray) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = names
	return font

func _style(bg: Color, border: Color, radius: int = 2) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb

func _centered_label(y: float, text: String, font: Font, size: int, color: Color) -> Label:
	var label := _left_label(0, y, VIEW.x, text, font, size, color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 这条提示是整幅宽度的居中文本，视口撑宽后要跟着中心走
	_anchor(label, 0.5, 0.0)
	return label

## 左对齐区域标签：在 [x, x+width] 内可指定对齐方式（默认居中于该区域）。
func _left_label(x: float, y: float, width: float, text: String, font: Font, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.position = Vector2(x, y)
	label.size = Vector2(width, float(size) + 10.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(label)
	return label

## 生成一条起伏剪影带（参考版的远山用两段不同起伏的 path，这里用三角带近似）
func _silhouette_band(parent: Node, base_y: float, height: float, step: int, color: Color, alpha: float) -> void:
	var host := Node2D.new()
	parent.add_child(host)
	var x: int = -60
	while x < int(_vp.x) + 60:
		var h: float = height * (0.55 + 0.45 * absf(sin(float(x) * 0.018 + base_y)))
		var poly := Polygon2D.new()
		poly.polygon = PackedVector2Array([
			Vector2(float(x), base_y),
			Vector2(float(x + step / 2), base_y - h),
			Vector2(float(x + step), base_y),
			Vector2(float(x + step), base_y + 200.0),
			Vector2(float(x), base_y + 200.0),
		])
		poly.color = Color(color.r, color.g, color.b, alpha)
		host.add_child(poly)
		x += step
