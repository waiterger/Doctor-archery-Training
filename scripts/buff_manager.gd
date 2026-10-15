extends Node
## Buff 管理器：挂在玩家身上，负责「持有哪些 Buff」并对外提供查询接口。
##
## 解耦要点：
## - Buff 的定义（名字/描述/效果）全部集中在这里，玩家和箭矢只查询「有没有」「多少倍」
## - 玩家不关心具体是哪个 Buff，只调 buff.get_charge_time() / get_damage_mult() 等
## - 新增一个 Buff 只需在 BUFF_DEFS 加一条数据 + 在下方某个 getter 里加一行
##
## 所有效果都是「叠乘」计算，所以同一 Buff 拿两次会更强，符合肉鸽直觉。

signal element_changed(element: String)
## 玩家点了 Q 键（无论有没有真的切换，都发一下，方便外部刷新 UI）
signal element_switch_attempted()
## buff 等级发生变化（新增或升级）。暂停菜单的技能面板监听它实时刷新。
signal buff_levels_changed()

## 每清空一波，弹出的选项数量
@export var choice_count: int = 3

## 默认等级上限。新增 Buff 时可在 BUFF_DEFS 里用 "max" 单独覆盖。
@export var default_max_level: int = 3

# 已拥有的 buff：{ buff_id: 当前等级 }
# ⚠ 从 Array[String] 改成 Dictionary 的原因：
# 平铺数组只能靠遍历计数，满级后无法区分「没拿过」和「已经拿满 3 层」，
# 也就没法把满级 Buff 从随机池里剔除。字典能直接判断。
var _buffs: Dictionary = {}

## 金币扩容：{ buff_id: 扩容后的上限 }。
## ★ v3：已废除扩容机制，无上限升级。此字典保留仅为兼容旧存档接口，
## 不再参与任何等级判定。
var _expanded_max: Dictionary = {}

## ★★ v4：升级一次需要多少金币（仅在【付费阶段】生效）
## ★ v5：这是【基础价】。实际价格 = base + 每级递增 step
@export var upgrade_cost: int = 2

## ★ v5：付费阶段每升一级，金币 +多少。
## upgrade_cost=2, step=1 → Lv3→4 花2、Lv4→5 花3、Lv5→6 花4...
@export var upgrade_cost_step: int = 1

## ★★ v4：等级 < 这个值的升级是【免费】的。
##   例：设3 → Lv.0→1、1→2、2→3 都免费；Lv.3→4 起才要花钱。
@export var free_upgrade_until: int = 3

## 元素附着的中文名，供 UI 显示
const ELEMENT_NAMES := {"fire": "火焰", "frost": "霜寒", "water": "流水"}
## Q 键的切换顺序
const ELEMENT_CYCLE: Array[String] = ["fire", "frost", "water"]

## 当前选中的附着元素 id（"" = 无元素）
var _element: String = ""

## 各 Buff 的定义表。新增 Buff 在这里加一条即可。
##
## 字段说明：
##  name/desc/color —— 显示用
##  weight          —— 随机池权重，越大越容易被抽到（缺省 1）
##  max             —— 等级上限（缺省用 default_max_level）
##  curse           —— 是否负面 Buff（预留，当前池里还没有诅咒）
const BUFF_DEFS := {
	"rapid_charge": {
		"name": "迅捷之握",
		"desc": "蓄力时间 -25%",
		"color": Color(0.35, 0.85, 1.0),
		"weight": 2,
	},
	"power": {
		"name": "锋锐之刃",
		"desc": "箭矢伤害 +40%",
		"color": Color(1.0, 0.45, 0.35),
		"weight": 3,
	},
	"multishot": {
		"name": "双矢连射",
		"desc": "一次射出 2 支箭，单支伤害 -25%",
		"color": Color(0.75, 0.55, 1.0),
		"weight": 3,
	},
	"fire": {
		"name": "烈焰附魔",
		"desc": "命中附加燃烧。搭配【潮湿】触发蒸发",
		"color": Color(1.0, 0.55, 0.15),
		"weight": 1,
	},
	"frost": {
		"name": "霜寒附魔",
		"desc": "命中附加减速与冻结。搭配【潮湿】触发冻结，搭配【火焰】触发融化",
		"color": Color(0.55, 0.85, 1.0),
		"weight": 1,
	},
	"water": {
		"name": "流水附魔",
		"desc": "命中施加潮湿。搭配【冰霜】触发冻结，搭配【火焰】触发蒸发",
		"color": Color(0.30, 0.60, 1.0),
		"weight": 1,
	},
	"pierce": {
		"name": "破甲穿透",
		"desc": "箭矢可穿透墙体与靶子",
		"color": Color(0.95, 0.85, 0.4),
		"weight": 1,
	},
}


## 某个 Buff 的抽取权重（没写 weight 视为 1）。
## 高权重 = 更容易出现在三选一里。
func weight_of(id: String) -> int:
	var d: Dictionary = BUFF_DEFS.get(id, {})
	return maxi(1, int(d.get("weight", 1)))


## 是不是负面 Buff（诅咒）。当前池里还没有，预留给以后加。
func is_curse(id: String) -> bool:
	var d: Dictionary = BUFF_DEFS.get(id, {})
	return bool(d.get("curse", false))


func _ready() -> void:
	print("[BuffManager] 初始化，可选 Buff 共 ", BUFF_DEFS.size(), " 种")


# --------------------------------------------------
# 对外查询接口（玩家/箭矢只调用这些，不关心具体 Buff）
# --------------------------------------------------

## 当前蓄满所需时间（秒）
func get_charge_time(base_time: float) -> float:
	var stacks := count_of("rapid_charge")
	return base_time * pow(0.75, stacks)


## 伤害总倍率
func get_damage_mult() -> float:
	var m := 1.0
	m *= pow(1.4, count_of("power"))
	# 多重射击让单支箭伤害降低
	m *= pow(0.75, count_of("multishot"))
	return m


## 一次射出几支箭
func get_projectile_count() -> int:
	return 1 + count_of("multishot")


func has_fire() -> bool:
	return count_of("fire") > 0


func has_frost() -> bool:
	return count_of("frost") > 0


func has_water() -> bool:
	return count_of("water") > 0


func has_pierce() -> bool:
	return count_of("pierce") > 0


# --------------------------------------------------
# 元素附着切换（空格键，见 project.godot 的 switch_element 动作）
# --------------------------------------------------
## 玩家真正拥有的元素列表。两种都拿/ 只有一种 / 都没有。
func get_owned_elements() -> Array[String]:
	var out: Array[String] = []
	for id in ELEMENT_CYCLE:
		if count_of(id) > 0:
			out.append(id)
	return out


## 当前选中的元素 id（"" = 无）
func get_element() -> String:
	return _element


## 当前元素的中文名（"火焰" / "霜寒" / "无元素"）
func get_element_name() -> String:
	if _element == "":
		return "无元素"
	return ELEMENT_NAMES.get(_element, _element)


## 是否可以切换（必须同时拥有两种元素）
func can_switch_element() -> bool:
	return get_owned_elements().size() >= 2


## 按 Q：切到下一个「已拥有」的元素。
## 只有一种元素时什么都不做（保持一直用那一种）。
func switch_element() -> void:
	element_switch_attempted.emit()

	var owned := get_owned_elements()
	if owned.size() < 2:
		# 只有一种（或没有）：默认一直用它，切换无效果。
		# ⚠ 这不是 bug —— 只有一个元素时"切换"没有意义。
		#   要看到切换效果，必须先拿到 2 种以上元素附魔。
		print("[BuffManager] ⚡ 元素切换无效：只拥有 ", owned.size(),
			" 种元素（需要 2 种以上才能切换），保持「", get_element_name(), "」")
		if owned.size() == 0:
			print("           提示：先在强化里拿到火焰/冰霜/流水附魔")
		else:
			print("           提示：再拿一种不同的元素附魔就能切换了")
		return

	# 找到当前元素在已拥有列表里的位置，切到下一个（循环）
	var idx := owned.find(_element)
	# 当前没有有效元素（比如刚拿到第二个元素）时，从头开始选
	var next_idx := 0 if idx < 0 else (idx + 1) % owned.size()
	_element = owned[next_idx]

	print("[BuffManager] ⚡ 元素切换 → 「", get_element_name(), "」（",
		idx + 1, "/", owned.size(), "）")
	element_changed.emit(_element)


## 拿到新 Buff 后自动校正当前元素：
## 只有一个元素时自动选中它；两个都有时保持玩家原来的选择不动。
func _auto_pick_element() -> void:
	var owned := get_owned_elements()
	if owned.is_empty():
		_element = ""
		return
	# 当前选中的元素如果已经没了（比如换场景），退回到第一个
	if _element != "" and not owned.has(_element):
		_element = owned[0]
		element_changed.emit(_element)
		return
	# 还没有选过元素时，自动选第一个
	if _element == "":
		_element = owned[0]
		print("[BuffManager] ⚡ 自动附着「", get_element_name(), "」")
		element_changed.emit(_element)


## 各附魔的强度层数（箭矢用来算DOT 伤害 / 减速时长）
func fire_stacks() -> int:
	return count_of("fire")


# ================================================================
# ★★★ 火焰附魔（燃烧）强度曲线 —— v5 重构
#
# 需求：
#   Lv.1 → 5/s，持续 3s
#   Lv.2 → 12/s，持续 4s      （伤害大幅跳跃）
#   Lv.3 → 20/s，持续 5s      （质变）
#   Lv.4+ → 每级 +5/s，每级 +0.5s（持续时间封顶 8s）
#
# ⚠ 性能兜底：BURN_DPS_MAX = 50 防止金币溢出把伤害堆到四位数。
# ================================================================

## Lv.1~3 的固定档位（索引 = 等级-1）
const BURN_TIER_DPS := [5.0, 12.0, 20.0]
const BURN_TIER_DURATION := [3.0, 4.0, 5.0]
## Lv.4+ 每级的增量
const BURN_DPS_PER_EXTRA_LEVEL := 5.0
const BURN_DURATION_PER_EXTRA_LEVEL := 0.5
## 上限（性能兜底）
const BURN_DPS_MAX := 50.0
const BURN_DURATION_MAX := 8.0


## 燃烧每秒伤害（按当前等级）
func fire_burn_dps() -> float:
	var lv := count_of("fire")
	if lv <= 0:
		return 0.0
	var dps := 0.0
	if lv <= BURN_TIER_DPS.size():
		# Lv.1~3 走固定档位
		dps = float(BURN_TIER_DPS[lv - 1])
	else:
		# Lv.4+ = Lv.3 基础 + 每级递增
		var extra := lv - 3
		dps = float(BURN_TIER_DPS[2]) \
			+ BURN_DPS_PER_EXTRA_LEVEL * float(extra)
	# ★ clamp 兜底：无论等级多高都不超过 50/s
	return clampf(dps, 0.0, BURN_DPS_MAX)


## 燃烧持续时间（按当前等级，封顶 8s）
func fire_burn_duration() -> float:
	var lv := count_of("fire")
	if lv <= 0:
		return 0.0
	var dur := 0.0
	if lv <= BURN_TIER_DURATION.size():
		dur = float(BURN_TIER_DURATION[lv - 1])
	else:
		var extra := lv - 3
		dur = float(BURN_TIER_DURATION[2]) \
			+ BURN_DURATION_PER_EXTRA_LEVEL * float(extra)
	return clampf(dur, 0.0, BURN_DURATION_MAX)


## 供UI 显示的等级描述（如"Lv.5 燃烧 35/s · 6.5s"）
func fire_burn_text() -> String:
	if not has_fire():
		return ""
	return "燃烧 %d/s · %.1fs" % [
		int(round(fire_burn_dps())), fire_burn_duration()]


## ★★ v6：冰霜曲线（Lv.1~3 固定档位，Lv.4+ 线性递增并封顶）
## 减速比例（0.30 = 减速 30%，靶子速度 ×0.70）
const FROST_SLOW_TIER := [0.30, 0.50, 0.65]
## 减速持续时间（秒）
const FROST_DURATION_TIER := [2.0, 3.0, 4.0]
## 冻结定身时间（秒）
const FROST_FREEZE_TIER := [1.5, 2.5, 3.5]
## Lv.4+ 每级增量
const FROST_SLOW_PER_EXTRA_LEVEL := 0.05
const FROST_FREEZE_PER_EXTRA_LEVEL := 0.5
const FROST_BURST_PER_EXTRA_LEVEL := 5.0
## Lv.3 冰爆基础伤害
const FROST_BURST_BASE := 20.0
## 上限（性能兜底）
const FROST_SLOW_MAX := 0.85
const FROST_DURATION_MAX := 4.0
const FROST_FREEZE_MAX := 5.0
const FROST_BURST_MAX := 50.0
## 冰爆半径（像素）
const FROST_BURST_RADIUS := 50.0


## 冰霜减速比例（0.30 表示减速 30%）。Lv.4+ 每级 +5%，封顶 85%。
func frost_slow_ratio() -> float:
	var lv := count_of("frost")
	if lv <= 0:
		return 0.0
	var r := 0.0
	if lv <= FROST_SLOW_TIER.size():
		r = float(FROST_SLOW_TIER[lv - 1])
	else:
		r = float(FROST_SLOW_TIER[2]) \
			+ FROST_SLOW_PER_EXTRA_LEVEL * float(lv - 3)
	return clampf(r, 0.0, FROST_SLOW_MAX)


## 冰霜减速持续时间（秒）。Lv.4+ 维持 Lv.3 的 4s（需求未要求继续增长）。
func frost_slow_duration() -> float:
	var lv := count_of("frost")
	if lv <= 0:
		return 0.0
	var d := 0.0
	if lv <= FROST_DURATION_TIER.size():
		d = float(FROST_DURATION_TIER[lv - 1])
	else:
		d = float(FROST_DURATION_TIER[2])
	return clampf(d, 0.0, FROST_DURATION_MAX)


## 冻结定身时间（秒）。Lv.4+ 每级 +0.5s，封顶 5s。
func frost_freeze_time() -> float:
	var lv := count_of("frost")
	if lv <= 0:
		return 0.0
	var t := 0.0
	if lv <= FROST_FREEZE_TIER.size():
		t = float(FROST_FREEZE_TIER[lv - 1])
	else:
		t = float(FROST_FREEZE_TIER[2]) \
			+ FROST_FREEZE_PER_EXTRA_LEVEL * float(lv - 3)
	return clampf(t, 0.0, FROST_FREEZE_MAX)


## 冰爆伤害（Lv.3 才解锁）。Lv.4+ 每级 +5，封顶 50。Lv.1/2 返回 0。
func frost_burst_damage() -> float:
	var lv := count_of("frost")
	if lv < 3:
		return 0.0
	var dmg := FROST_BURST_BASE + FROST_BURST_PER_EXTRA_LEVEL * float(lv - 3)
	return clampf(dmg, 0.0, FROST_BURST_MAX)


## 冰爆半径（像素）
func frost_burst_radius() -> float:
	return FROST_BURST_RADIUS


## 冰爆附带的「Lv.1 减速」——固定 30% / 2s
func frost_burst_slow_factor() -> float:
	return 1.0 - float(FROST_SLOW_TIER[0])


func frost_burst_slow_duration() -> float:
	return float(FROST_DURATION_TIER[0])


## UI 显示用
func frost_text() -> String:
	if not has_frost():
		return ""
	var s := "减速 %d%% · %.1fs · 定身 %.1fs" % [
		int(round(frost_slow_ratio() * 100.0)),
		frost_slow_duration(),
		frost_freeze_time()]
	if frost_burst_damage() > 0.0:
		s += " · 冰爆 %d" % int(round(frost_burst_damage()))
	return s


func frost_stacks() -> int:
	return count_of("frost")


## ★★ v6：流水曲线（Lv.1~3 固定档位，Lv.4+ 线性递增并封顶）
## 潮湿持续时间（秒）
const WATER_DURATION_TIER := [3.0, 5.0, 6.0]
## 反应伤害倍率（作用于蒸发/融化等反应伤害）
const WATER_REACT_TIER := [1.0, 1.5, 2.0]
## Lv.4+ 每级增量
const WATER_DURATION_PER_EXTRA_LEVEL := 0.5
const WATER_REACT_PER_EXTRA_LEVEL := 0.2
## 上限（性能兜底）
const WATER_DURATION_MAX := 10.0
const WATER_REACT_MAX := 3.0
## 潮湿传染半径（像素）
const WATER_SPREAD_RADIUS := 100.0
## Lv.10 起传染改为【范围内全部】而不是随机 1 个
const WATER_SPREAD_ALL_LEVEL := 10


## 潮湿持续时间（秒）。Lv.4+ 每级 +0.5s，封顶 10s。
func water_wet_duration() -> float:
	var lv := count_of("water")
	if lv <= 0:
		return 0.0
	var d := 0.0
	if lv <= WATER_DURATION_TIER.size():
		d = float(WATER_DURATION_TIER[lv - 1])
	else:
		d = float(WATER_DURATION_TIER[2]) \
			+ WATER_DURATION_PER_EXTRA_LEVEL * float(lv - 3)
	return clampf(d, 0.0, WATER_DURATION_MAX)


## 反应伤害倍率。Lv.4+ 每级 +0.2，封顶 3.0。
func water_react_mult() -> float:
	var lv := count_of("water")
	if lv <= 0:
		return 1.0
	var m := 1.0
	if lv <= WATER_REACT_TIER.size():
		m = float(WATER_REACT_TIER[lv - 1])
	else:
		m = float(WATER_REACT_TIER[2]) \
			+ WATER_REACT_PER_EXTRA_LEVEL * float(lv - 3)
	return clampf(m, 1.0, WATER_REACT_MAX)


## 潮湿传染目标数量：0 = 不传染；1 = 随机 1 个；-1 = 范围内全部。
## Lv.3 解锁随机 1 个，Lv.10 起改为全部。
func water_spread_count() -> int:
	var lv := count_of("water")
	if lv < 3:
		return 0
	if lv >= WATER_SPREAD_ALL_LEVEL:
		return -1
	return 1


## 潮湿传染半径（像素）
func water_spread_radius() -> float:
	return WATER_SPREAD_RADIUS


## UI 显示用
func water_text() -> String:
	if not has_water():
		return ""
	var s := "潮湿 %.1fs · 反应×%.1f" % [water_wet_duration(), water_react_mult()]
	var n := water_spread_count()
	if n == 1:
		s += " · 传染1体"
	elif n < 0:
		s += " · 传染全部"
	return s


func water_stacks() -> int:
	return count_of("water")


## 某个 Buff 的当前等级（没拿过 = 0）。
## 所有上层（player.gd / arrow.gd）都通过它取层数，语义 = 等级 = 原来的层数。
func count_of(id: String) -> int:
	return int(_buffs.get(id, 0))


## 某个 Buff 的等级上限。
## ★★ v3重构：已废除「扩容」概念 —— 现在是【无上限升级】，
##    所以这里返回一个"显示用"的大数字，永远不会挡住升级。
## 保留这个函数是为了兼容 player.gd / UI 的旧调用。
const UNLIMITED_MAX := 999
func max_level_of(id: String) -> int:
	return UNLIMITED_MAX


## ★★ v4：升级分【免费】和【付费】两种。
##   免费：当前等级 < free_upgrade_until（默认3），即 Lv.0→1、1→2、2→3
##   付费：当前等级 >= free_upgrade_until，即 Lv.3→4、Lv.4→5 ...
## 这是 UI 和扣费逻辑的【唯一判定口径】，避免两处判断不一致。
func is_free_upgrade(id: String) -> bool:
	return count_of(id) < free_upgrade_until


## 这次升级需要多少金币。
## 免费阶段返回 0；付费阶段【随等级递增】（要求：Lv3→4 花2，Lv4→5 花3）。
func upgrade_price(id: String) -> int:
	if is_free_upgrade(id):
		return 0
	# ★ 递增：base + (当前等级 - free_upgrade_until + 1) * step
	#   Lv.3→4 → base + 1*step
	#   Lv.4→5 → base + 2*step
	var lv := count_of(id)
	var steps := maxi(lv - free_upgrade_until + 1, 1)
	return maxi(upgrade_cost + upgrade_cost_step * (steps - 1), 1)


## ★★ v4 统一升级入口：免费/付费由is_free_upgrade() 自动判定。
## 返回 { ok: bool, reason: String, level: int, cost: int, free: bool }
func try_upgrade(id: String, gold: int) -> Dictionary:
	var reason := ""
	if not BUFF_DEFS.has(id):
		reason = "未知 Buff"

	var cost := 0
	var free := true
	if reason == "":
		free = is_free_upgrade(id)
		cost = upgrade_price(id)
		# ⚠ 只有【付费升级】才校验金币。免费阶段不能因为 gold=0 被拦，
		#    这是之前"1 级就提示消耗金币"的根因。
		if not free and gold < cost:
			reason = "金币不足（需要 %d）" % cost

	if reason != "":
		return {"ok": false, "reason": reason, "level": count_of(id),
			"cost": cost, "free": free}

	var lv := count_of(id) + 1
	_buffs[id] = lv
	# 首次获得时校正附着元素（从 0 级升到 1 级的情况）
	if lv == 1:
		_auto_pick_element()
	buff_levels_changed.emit()
	if free:
		print("[BuffManager] ✦ 免费升级「", get_display_name(id), "」→ Lv.", lv)
	else:
		print("[BuffManager] 💰 付费升级「", get_display_name(id), "」→ Lv.",
			lv, "（花费 ", cost, " 金币）")
	return {"ok": true, "reason": "", "level": lv, "cost": cost, "free": free}


## 升级一次需要多少金币（UI 显示用；免费阶段返回 0）
func get_upgrade_cost() -> int:
	return upgrade_cost


## ★ UI 判断按钮是否可点——【唯一口径】：
##   免费阶段 → 永远可点（不需要金币）
##   付费阶段 → 必须 gold >= upgrade_cost
func can_upgrade(id: String, gold: int) -> bool:
	if not BUFF_DEFS.has(id):
		return false
	if is_free_upgrade(id):
		return true
	return gold >= upgrade_cost


## 下一个等级（无上限，所以就是 +1）
func next_level_of(id: String) -> int:
	return count_of(id) + 1


## 该 Buff 是否已经满级
## ★★★ v3：已废除上限概念，任何等级都能继续升。
## 保留此函数仅为兼容旧调用（UI 卡片仍会问is_maxed）。
## 永远返回 false —— 这样「满级」相关的老分支都不会误触发。
func is_maxed(id: String) -> bool:
	return false


## 卡片状态文字。
##  - 等级 0        → "新"
##  - 0 < lv < 上限  → "Lv.X -> Lv.Y"
##  - lv >= 上限     → "已达上限"
func get_card_status_text(id: String) -> String:
	var lv := count_of(id)
	if lv <= 0:
		return "新"
	if is_maxed(id):
		return "已达上限"
	return "Lv.%d -> Lv.%d" % [lv, next_level_of(id)]


## 卡片状态文字颜色（UI 直接拿去设 modulate / font_color）。
##  - 新 → 绿
##  - 升级 → 黄
##  - 满级 → 灰
func get_card_status_color(id: String) -> Color:
	var lv := count_of(id)
	if lv <= 0:
		return Color(0.35, 0.85, 0.40)      # 绿
	if is_maxed(id):
		return Color(0.55, 0.57, 0.62)      # 灰
	return Color(1.0, 0.80, 0.25)          # 黄


# --------------------------------------------------
# Buff 的授予与随机抽取
# --------------------------------------------------

## 获得一个 Buff：等级 +1（满级则不变）
func add_buff(id: String) -> void:
	if not BUFF_DEFS.has(id):
		print("[BuffManager] ⚠ 未知 buff id: ", id)
		return

	# ★ v3：无上限，任何等级都能继续 +1
	var lv := count_of(id) + 1
	_buffs[id] = lv
	var d: Dictionary = BUFF_DEFS[id]
	print("[BuffManager] 获得「", d["name"], "」 Lv.", lv)
	print("当前全部: ", _summary())
	# 拿到火/冰/水时自动校正当前附着元素
	_auto_pick_element()
	# 通知外部（技能面板）刷新等级显示
	buff_levels_changed.emit()


## 随机抽 n 个不重复的选项供玩家三选一（带权重）。
##
## 权重实现（按需求的最简做法）：
##  把每个 Buff 按它的 weight 往临时数组里重复塞weight 次
##  （权重3 = 塞3 份），打乱后顺序取，取到已选过的 id 就跳过。
##  这样同一个 Buff 在候选池里占的格子数 ∝ 权重，
##  但一次三选一里仍保证【不出现重复的 Buff】。
##
## 已满级（lv >= max）的直接不塞进池子。
## 万一所有 Buff 都满级，返回空数组而不是崩。
## 抽 n 个选项给三选一界面。
## ⚠⚠ 保证【必定返回 n 个】：候选不足时会用「已满级但可扩容」的 buff 补，
## 再不够就允许重复。宁可给重复选项，也不能只给 1~2 张把玩家晾在那。
## ★★★ v4：生成三选一的选项池。
##
## ★ 返回的每个条目都是【一个 Dictionary】，携带升级类型标识：
##   {
##     "id":String,          # buff id
##     "kind":int,           # ★ 升级类型：FREE(免费) 或 PAID(付费)
##     "cost": int,          # 该条目所需金币（FREE 时为 0）
##     "from": int, "to": int,  # 升级前后等级，用于 UI 显示
##     "free": bool,         # 便捷字段：== (kind == FREE)
##   }
##
## 规则：
##   等级 < free_upgrade_until（默认3）→ FREE 条目（Lv.0→1、1→2、2→3）
##   等级 >= free_upgrade_until→ PAID 条目（Lv.3→4、4→5 ...）
##
## 保证必定返回 n 条（不足时允许重复）。
func roll_choices(n: int) -> Array:
	var out: Array = []
	## 先算出所有buff 的当前升级类型（免费的可能不止一个）
	var entries: Array = []
	for id in BUFF_DEFS.keys():
		var free := is_free_upgrade(id)
		entries.append({
			"id": id,
			"kind": OPTION_FREE if free else OPTION_PAID,
			"cost": upgrade_price(id),
			"from": count_of(id),
			"to": count_of(id) + 1,
			"free": free,
		})

	# 按权重打乱，让高权重 buff 更容易出现
	var weighted: Array = []
	for e in entries:
		var w := weight_of(e["id"])
		for i in range(w):
			weighted.append(e)
	weighted.shuffle()

	# 去重取前 n 个
	var seen: Dictionary = {}
	for e in weighted:
		if seen.has(e["id"]):
			continue
		seen[e["id"]] = true
		out.append(e)
		if out.size() >= n:
			break

	# ★ 不足 n 条 → 允许重复（复制已有条目并改 id 保证能真正升不同 buff）
	var guard := 0
	while out.size() < n and not out.is_empty() and guard < 200:
		var src: Dictionary = out[guard % out.size()]
		out.append(src.duplicate(true))
		guard += 1

	if out.size() < n:
		print("[BuffManager] ⚠ buff 池为空，无法凑够 ", n, " 条")
	return out


## 选项类型常量（UI 靠它区分卡片配色和文案）
const OPTION_FREE := 0   # 免费升级
const OPTION_PAID := 1   # 付费升级


## 判断一个选项条目是不是免费
func is_free_entry(entry: Dictionary) -> bool:
	return int(entry.get("free", true)) == 1 \
		or int(entry.get("kind", OPTION_FREE)) == OPTION_FREE


## 所有已持有的 buff id（技能面板用）
func owned_ids() -> Array[String]:
	var out: Array[String] = []
	for id in _buffs.keys():
		out.append(id)
	return out


# --------------------------------------------------
# 存档导出/ 导入（复活续局用）
# --------------------------------------------------
## 导出全部等级，供跨场景保存
func export_levels() -> Dictionary:
	return _buffs.duplicate(true)


## 从存档恢复等级（复活续局时调用）。
## 逐个add_buff 会受"满级上限"拦截，所以这里直接写字典，
## 保证存档里的等级原样恢复（哪怕以后改了上限也能还原）。
func import_levels(data: Dictionary) -> void:
	_buffs = data.duplicate(true)
	# 元素要跟着重新校正，否则空格切换会指向一个已不存在的元素
	_auto_pick_element()
	if _element == "" and not _buffs.is_empty():
		_element = get_owned_elements()[0]
	buff_levels_changed.emit()
	element_changed.emit(_element)
	print("[BuffManager] ♻ 已恢复 Buff 等级：", _summary())


## 导出扩容记录（复活后也要保留扩容后的上限）
func export_expanded() -> Dictionary:
	return _expanded_max.duplicate(true)


## 从存档恢复扩容记录
func import_expanded(data: Dictionary) -> void:
	_expanded_max = data.duplicate(true)
	print("[BuffManager] ♻ 已恢复扩容记录：", _expanded_max)


func get_display_name(id: String) -> String:
	return BUFF_DEFS[id]["name"] if BUFF_DEFS.has(id) else id


func get_display_desc(id: String) -> String:
	return BUFF_DEFS[id]["desc"] if BUFF_DEFS.has(id) else ""


func get_display_color(id: String) -> Color:
	return BUFF_DEFS[id]["color"] if BUFF_DEFS.has(id) else Color.WHITE


## UI 上显示的等级文本，如 "Lv.2 / 3"；满级时 "Lv.3 / 3 ★"
func get_level_text(id: String) -> String:
	var lv := count_of(id)
	var mx := max_level_of(id)
	if lv <= 0:
		return "未持有"
	return "Lv.%d / %d%s" % [lv, mx, "★" if lv >= mx else ""]


## 调试用：当前 buff 概况（带等级）
func _summary() -> String:
	if _buffs.is_empty():
		return "（无）"
	var parts: Array[String] = []
	for id in _buffs.keys():
		parts.append("%s Lv.%d/%d" % [
			BUFF_DEFS[id]["name"], count_of(id), max_level_of(id)])
	return ", ".join(parts)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	# ⚠ Q 键已改为「触发心流状态」，元素切换现在绑定【空格键】
	#（由 main.gd 通过 switch_element 动作调用 switch_element() 触发）。
	# 这里只保留 F2 调试。
	if event.keycode == KEY_F2:
		print("[BuffManager] === Buff 汇总 ===")
		print("           已获得: ", _summary())
		print("  蓄力时间倍率: ", snapped(get_charge_time(1.0) , 3))
		print("  伤害倍率: ", snapped(get_damage_mult(), 3))
		print("  箭矢数量: ", get_projectile_count())
		print("  火焰/冰霜/流水/穿透: ", has_fire(), " / ", has_frost(), " / ",
			has_water(), " / ", has_pierce())
		print("  当前元素: ", get_element_name(), "（拥有 ", get_owned_elements().size(), " 种）")
