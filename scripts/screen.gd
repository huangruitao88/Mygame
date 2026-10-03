extends Node

## 全局屏幕管理（Autoload 名 `ScreenManager`）。
##
## 存在理由：切换全屏是**跨场景的全局关注点** —— 标题界面和关卡里都要能按，
## 而且切换后要活过场景切换。放进任何一个场景都只覆盖一半（另一个场景按了没反应），
## 挂成普通节点又会被换场景销毁，所以用 Autoload。
## 它不持有任何玩法状态，只做「窗口模式切换」这一件事。
##
## 快捷键：F11 / Alt+Enter —— PC 游戏惯例，不占用项目已绑定的任何输入动作。
##
## 与 stretch 的关系：project.godot 用 stretch/mode=viewport + aspect=expand。
## 全屏时窗口 = 屏幕原生分辨率，此时 expand 不会展开任何东西（比例本就一致），
## 1920x1080 屏上倍率正好是整数 2 —— 也就是像素最锐利的那个状态。

func _ready() -> void:
	# 顿帧（get_tree().paused）会把整棵树冻住，但切全屏不该被冻：
	# 否则玩家在命中顿帧的那 75ms 里按 F11 会「按了没反应」。
	process_mode = Node.PROCESS_MODE_ALWAYS

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not _is_toggle_event(key):
		return
	toggle_fullscreen()
	get_viewport().set_input_as_handled()

## 这个按键是否要求切换全屏。抽成纯函数是为了可测：
## 无头环境下没法真的切窗口，但键位判定（尤其是 Alt+Enter 的组合键）
## 是纯逻辑，可以直接喂事件进来断言。
func _is_toggle_event(key: InputEventKey) -> bool:
	if not key.pressed or key.echo:
		return false
	if key.keycode == KEY_F11:
		return true
	return key.alt_pressed and (
		key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER)

## 窗口 ↔ 全屏互切。
##
## 用 WINDOW_MODE_FULLSCREEN（无边框窗口全屏）而不是 EXCLUSIVE_FULLSCREEN：
## 前者走系统合成器，切回窗口时不会重新枚举显示模式，对开发的打断最小。
func toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	var is_fullscreen: bool = mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	var next: int = DisplayServer.WINDOW_MODE_WINDOWED if is_fullscreen \
		else DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(next)
