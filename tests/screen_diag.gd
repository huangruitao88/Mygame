extends SceneTree

## 屏幕 / 拉伸诊断工具（回归探针）。
##
## 用法（**不能加 --headless**，无头 DisplayServer 拿不到真实屏幕/窗口信息）：
##   godot --path . -s res://tests/screen_diag.gd
## 它会依次报告「启动窗口 / 全屏 / 最大化」三种状态下的实测缩放与黑边。
##
## 历史成因（2026-10-01 已修，保留说明以免回退）：
## 全屏或最大化时画面缩在中间、四周一大圈黑边，根因是
## `stretch/scale_mode=integer` 的向下取整：
##     scale = floor(min(win.x / base.x, win.y / base.y))
## 窗口高度只要被标题栏/任务栏吃掉几十像素，scale 就**整档掉下来**：
##   1920x1061 → min(2.0, 1.965) → floor = 1 → 画面 960x540 居中，黑边 480x260。
##
## 现在配置为 `scale_mode=fractional` + `aspect=expand`，判据变成：
##   **B/C 两段的 [实测] 黑边必须全为 0**，且 C 段的 logical 宽度应 > 960
##   （视口被撑开，而不是留边）。任一条不成立就是配置被改回去了。

const BASE := Vector2i(960, 540)

var _frame: int = 0
var _stage: int = 0

func _initialize() -> void:
	print("=== 屏幕 / 窗口诊断 ===")
	print("primary screen: %s  dpi=%s scale=%s" % [
		DisplayServer.screen_get_size(),
		DisplayServer.screen_get_dpi(),
		DisplayServer.screen_get_scale(),
	])
	print("stretch mode=%s aspect=%s scale_mode=%s" % [
		ProjectSettings.get_setting("display/window/stretch/mode"),
		ProjectSettings.get_setting("display/window/stretch/aspect"),
		ProjectSettings.get_setting("display/window/stretch/scale_mode"),
	])
	print("window override: %s x %s" % [
		ProjectSettings.get_setting("display/window/size/window_width_override"),
		ProjectSettings.get_setting("display/window/size/window_height_override"),
	])
	_report("A. 启动状态（窗口模式）")

func _process(_delta: float) -> bool:
	_frame += 1
	if _stage == 0 and _frame > 15:
		_stage = 1
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif _stage == 1 and _frame > 45:
		_stage = 2
		_report("B. 全屏后")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	elif _stage == 2 and _frame > 75:
		_report("C. 最大化窗口后")
		print("=== 诊断结束 ===")
		quit()
		return true
	return false

func _report(tag: String) -> void:
	var win := DisplayServer.window_get_size()
	var raw := Vector2(win) / Vector2(BASE)
	var int_scale := int(floorf(minf(raw.x, raw.y)))
	var frac_scale := minf(raw.x, raw.y)
	print("--- %s ---" % tag)
	print("  window size: %s（base %s）" % [win, BASE])
	print("  raw scale: (%.4f, %.4f)" % [raw.x, raw.y])
	print("  [integer] scale=%d -> 画面 %dx%d，黑边 左右%dpx 上下%dpx" % [
		int_scale, BASE.x * int_scale, BASE.y * int_scale,
		int((win.x - BASE.x * int_scale) * 0.5), int((win.y - BASE.y * int_scale) * 0.5),
	])
	print("  [fractional] scale=%.4f -> 画面 %dx%d，黑边 %.1fpx（若 aspect=keep 且比例不等）" % [
		frac_scale, int(roundf(BASE.x * frac_scale)), int(roundf(BASE.y * frac_scale)),
		maxf(0.0, (win.x - BASE.x * frac_scale) * 0.5),
	])
	# 实测：viewport -> 屏幕的仿射变换，origin 就是真实黑边宽度/高度
	var scr := root.get_screen_transform() if root != null else Transform2D.IDENTITY
	var vis := root.get_visible_rect().size if root != null else Vector2.ZERO
	var s := scr.get_scale()
	print("  [实测] logical %s  scale=(%.4f, %.4f)  offset=(%.1f, %.1f)" % [
		vis, s.x, s.y, scr.origin.x, scr.origin.y,
	])
	print("  [实测] 画面 %.1fx%.1f  黑边 左%.1f 右%.1f 上%.1f 下%.1f (px)" % [
		vis.x * s.x, vis.y * s.y,
		scr.origin.x, win.x - scr.origin.x - vis.x * s.x,
		scr.origin.y, win.y - scr.origin.y - vis.y * s.y,
	])
