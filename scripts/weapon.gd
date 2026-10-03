class_name WuxiaWeapon
extends Resource

## 侠影录 · 武器（纯数据资源）
##
## 词条结构：
##   主词条 —— 固定为「攻击」（定值加到每一段连击上）
##   副词条 —— 从「攻击 / 生命 / 暴击 / 暴击伤害」里不放回随机抽 1~4 条，数值也在区间内随机
## 副词条条数与主词条数值都由品质决定（凡品 1 条 → 神品 4 条），所以「随机掉落」是
## 品质 + 词条种类 + 词条数值 三层随机叠加的结果。
##
## 本类只承载数值：不持有节点、不掷伤害、不管装备。玩家读走数值后自行应用，
## 掉落与装备时机由 game.gd 决定（沿用「信号上行、调用下行」的约定）。

enum Stat { ATTACK, HEALTH, CRIT_RATE, CRIT_DMG }

const STAT_NAME: Dictionary = {
	Stat.ATTACK: "攻击",
	Stat.HEALTH: "生命",
	Stat.CRIT_RATE: "暴击",
	Stat.CRIT_DMG: "暴击伤害",
}

## 副词条随机池 → 取值范围。攻击 / 生命是定值，暴击 / 暴击伤害是百分比。
const SUB_RANGE: Dictionary = {
	Stat.ATTACK: Vector2(3.0, 9.0),
	Stat.HEALTH: Vector2(8.0, 26.0),
	Stat.CRIT_RATE: Vector2(2.0, 6.0),
	Stat.CRIT_DMG: Vector2(6.0, 18.0),
}

## 每级品质对副词条数值的加成系数（品质越高，同一条词条的数值也越靠上）
const QUALITY_VALUE_BONUS := 0.1

const QUALITY_NAME: PackedStringArray = ["凡品", "良品", "珍品", "神品"]
## 品质权重：凡品最常见、神品最稀有
## 注：PackedInt32Array / PackedColorArray 在 GDScript 里不能作常量表达式，只能用类型化数组
const QUALITY_WEIGHT: Array[int] = [40, 34, 20, 6]
const QUALITY_COLOR: Array[Color] = [
	Color("#9aa3b0"), Color("#7fc98a"), Color("#6fa8ff"), Color("#e0a63c"),
]

const NAME_POOL: PackedStringArray = [
	"青锋", "秋水", "断岳", "龙泉", "承影", "含光", "纯钧", "湛卢", "赤霄", "巨阙",
]

@export var display_name: String = "无名"
@export var quality: int = 0
## 主词条数值（攻击力，定值）
@export var main_value: int = 6
## 副词条：每项形如 {"stat": Stat, "value": float}
@export var substats: Array[Dictionary] = []

# ---------------- 产出 ----------------

## 掷出一把随机武器。Boss 掉落的唯一入口。
static func roll(rng: RandomNumberGenerator) -> WuxiaWeapon:
	var weapon := WuxiaWeapon.new()
	weapon.quality = _roll_quality(rng)
	weapon.display_name = "%s剑" % NAME_POOL[rng.randi_range(0, NAME_POOL.size() - 1)]
	weapon.main_value = rng.randi_range(6, 10) + weapon.quality * 3

	# 不放回抽取：同一把武器不会出现两条同名副词条
	var pool: Array[int] = [Stat.ATTACK, Stat.HEALTH, Stat.CRIT_RATE, Stat.CRIT_DMG]
	for _i: int in weapon.quality + 1:
		var stat: int = pool.pop_at(rng.randi_range(0, pool.size() - 1))
		weapon.substats.append({"stat": stat, "value": _roll_value(rng, stat, weapon.quality)})
	return weapon

static func _roll_quality(rng: RandomNumberGenerator) -> int:
	var total: int = 0
	for weight: int in QUALITY_WEIGHT:
		total += weight
	var pick: int = rng.randi_range(1, total)
	var acc: int = 0
	for i: int in QUALITY_WEIGHT.size():
		acc += QUALITY_WEIGHT[i]
		if pick <= acc:
			return i
	return 0

static func _roll_value(rng: RandomNumberGenerator, stat: int, quality: int) -> float:
	var span: Vector2 = SUB_RANGE[stat]
	var raw: float = rng.randf_range(span.x, span.y) * (1.0 + QUALITY_VALUE_BONUS * float(quality))
	if stat == Stat.ATTACK or stat == Stat.HEALTH:
		return roundf(raw)
	return roundf(raw * 10.0) / 10.0

# ---------------- 展示 ----------------

static func format_stat(stat: int, value: float) -> String:
	match stat:
		Stat.ATTACK:
			return "攻击 +%d" % int(value)
		Stat.HEALTH:
			return "生命 +%d" % int(value)
		Stat.CRIT_RATE:
			return "暴击 +%.1f%%" % value
		Stat.CRIT_DMG:
			return "暴击伤害 +%.1f%%" % value
	return ""

func title() -> String:
	return "[%s] %s" % [QUALITY_NAME[quality], display_name]

func quality_color() -> Color:
	return QUALITY_COLOR[quality]

## 逐行词条文本，掉落物悬浮字与 HUD 武器面板共用同一份，避免两处各写一套格式化。
func describe() -> String:
	var lines: PackedStringArray = ["%s  主·攻击 +%d" % [title(), main_value]]
	for sub: Dictionary in substats:
		lines.append("副·" + format_stat(int(sub["stat"]), float(sub["value"])))
	return "\n".join(lines)
