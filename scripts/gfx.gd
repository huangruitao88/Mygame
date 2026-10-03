class_name Gfx
extends Object

## 侠影录 · 多边形绘制工具（纯静态，无状态、不依赖任何节点类型）
##
## 全项目所有「用 Polygon2D 拼像素风角色 / 地形 / 道具」的地方都走这里。
## 之所以从 WuxiaPlayer 里搬出来：武器掉落物、Boss 这类新类不该为了画一块多边形，
## 反过来去依赖「主角」这个完全无关的类（原本只有 3 个场景在用，现在是第 5 个）。

static func rect_poly(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])

## 正多边形顶点，用来画圆（能量球的光晕 / 内核）。
## segments 取 8~12 就足够圆：再多只是徒增顶点，像素风下肉眼看不出区别。
static func circle_poly(radius: float, segments: int = 12) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in segments:
		var angle: float = TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	return points

static func make_poly(parent: Node, points: PackedVector2Array, color: Color, pos := Vector2.ZERO) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.polygon = points
	poly.color = color
	poly.position = pos
	parent.add_child(poly)
	return poly

## 统一的中文界面字体。Godot 默认字体不含中文字形，不给 SystemFont 就是一片方块。
static func cjk_font() -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "SimHei", "Noto Sans SC", "sans-serif"])
	return font
