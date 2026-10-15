extends Area2D
## 箭矢：沿直线匀速飞行，命中造成伤害并施加附魔，超时/出界回收。
##
## 设计要点（解耦）：
## 1. 箭矢不自己决定伤害和附魔 —— 由玩家在生成时通过 setup() 传进来。
## 2. 伤害走通用接口 take_damage()；附魔走约定接口 _apply_burn() / _apply_slow()。
##    全部用 has_method() 检查后再调，所以箭矢不认识任何具体目标类型。
## 3. 回收用 queue_free()。原型阶段节点数量不大，完全够用且最简单。

# ---- 飞行参数 ----
@export var speed: float = 900.0        # 箭速（像素/秒）
@export var lifetime: float = 1.6       # 最多存活多少秒后自动消失
@export var despawn_margin: float = 200.0  # 超出屏幕多少像素后消失

# ---- 本次射击的数据（由玩家 setup() 填写）----
var damage: float = 10.0
var charge: float = 0.0                # 0~1 蓄力强度，只用于显示和特效
var shooter: Node = null

# ---- 附魔（由玩家 setup() 按持有的 Buff 传入）----
var can_pierce: bool = false           # 可穿透墙
var pierce_left: int = 0               # 还能穿透几个目标
var fire_dps: float = 0.0              # 燃烧每秒伤害，0=无
var fire_time: float = 2.5             # 燃烧持续时间
var frost_slow: float = 1.0            # 减速倍率，1=无减速
var frost_time: float = 1.5            # 减速持续时间
var water_time: float = 0.0# 潮湿持续时间，0=不带水元素
## ★ v6：流水附魔随等级变化
var water_react_mult: float = 1.0      # 反应伤害倍率（Lv1 1.0 → Lv10+ 3.0）
var water_spread_count: int = 0        # 潮湿传染目标数：0/1/-1(全部)
var water_spread_radius: float = 0.0   # 潮湿传染半径

## 这支箭当前携带的元素 id（"" / "fire" / "frost" / "water"）。
## 同一支箭只会带一种元素（由玩家的 _is_element_active 保证），
## 所以这里存一个 id 比逐个判断三个数值字段方便，元素反应就靠它。
var element_id: String = ""
## ★ v6：冰霜附魔随等级变化
var frost_burst_damage: float = 0.0      # 冰爆伤害（Lv.3 起 >0），0=无冰爆
## ★ v6：本次命中【结算瞬间】的冰霜定身时间（传给靶子的 _apply_freeze）
var frost_burst_radius: float = 50.0

## 潮湿冻结反应的持续时间
@export var freeze_time: float = 2.0

var _age: float = 0.0
var _hit_ids: Array[int] = []          # 已命中的目标 id，避免同一目标被反复计伤

@onready var visual: Polygon2D = $Visual
@onready var trail: Line2D = $Trail


## 玩家调用这个方法来「上膛」一发箭
##★ v5：新增 p_fire_time —— 燃烧持续时间随火焰等级变化，
##    之前完全没传，一直用 fire_time 的默认值 2.5s。
func setup(dir: Vector2, p_damage: float, p_charge: float, p_shooter: Node,
		p_pierce: int = 0, p_fire_dps: float = 0.0,
		p_frost_slow: float = 1.0, p_frost_time: float = 1.5,
		p_water_time: float = 0.0, p_fire_time: float = 2.5,
		p_frost_freeze_time: float = -1.0, p_frost_burst_damage: float = 0.0,
		p_water_react_mult: float = 1.0, p_water_spread_count: int = 0,
		p_water_spread_radius: float = 0.0) -> void:
	global_rotation = dir.angle()
	damage = p_damage
	charge = p_charge
	shooter = p_shooter

	# 穿透
	pierce_left = p_pierce
	can_pierce = p_pierce > 0

	# 附魔
	fire_dps = p_fire_dps
	# ⚠ 只有传了有效值才覆盖，<=0 时保持默认（避免无火焰时把时间设成 0）
	if p_fire_time > 0.0:
		fire_time = p_fire_time
	frost_slow = p_frost_slow
	frost_time = p_frost_time

	# 水
	water_time = p_water_time

	# ★ v6 流水：反应倍率 + 传染配置
	water_react_mult = clampf(p_water_react_mult, 1.0, 3.0)
	water_spread_count = p_water_spread_count
	water_spread_radius = maxf(p_water_spread_radius, 0.0)

	# ★ v6 冰霜：定身时间 + 冰爆参数
	if p_frost_freeze_time > 0.0:
		freeze_time = p_frost_freeze_time
	frost_burst_damage = maxf(p_frost_burst_damage, 0.0)

	# 推导元素 id：优先级 冰 > 火 > 水 > 无。
	# 用 has_method 式的「值判断」而不是问玩家，保持箭矢不认识 BuffManager。
	if frost_slow < 1.0:
		element_id = "frost"
	elif fire_dps > 0.0:
		element_id = "fire"
	elif water_time > 0.0:
		element_id = "water"
	else:
		element_id = ""

	# 蓄力越高颜色越偏红（纯视觉反馈，方便调试）
	var t := clampf(charge, 0.0, 1.0)
	var c := Color(0.45, 0.75, 1.0).lerp(Color(1.0, 0.45, 0.2), t)
	# 有附魔时用附魔色覆盖，一眼看出箭矢带了什么
	if fire_dps > 0.0:
		c = Color(1.0, 0.55, 0.15)
	elif frost_slow < 1.0:
		c = Color(0.5, 0.75, 1.0)
	elif water_time > 0.0:
		# 水用更深的蓝，和冰霜的浅蓝一眼能分开
		c = Color(0.25, 0.45, 1.0)
	if can_pierce:
		c = c.lerp(Color(0.98, 0.9, 0.4), 0.55)
	visual.color = c

	var thick := lerpf(2.0, 4.5, t)
	visual.scale = Vector2(1.0 + t * 0.5, thick / 3.0)
	trail.default_color = Color(c.r, c.g, c.b, 0.35)

	var extra := ""
	if can_pierce: extra += " 穿透x%d" % pierce_left
	if fire_dps > 0.0: extra += " 燃烧%.0f/s" % fire_dps
	if frost_slow < 1.0: extra += " 减速x%.2f" % frost_slow
	if water_time > 0.0: extra += " 潮湿%.1fs" % water_time
	print("[Arrow] 上膛 伤害=", damage, " 蓄力=", snapped(charge, 0.01),
		" 方向=", snapped(rad_to_deg(dir.angle()), 1), "°", extra)


func _ready() -> void:
	add_to_group("arrows")
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	# 只负责直线位移。用 position 而不是 velocity，
	# 因为 Area2D 没有 move_and_slide，自己挪最直观。
	position += Vector2.RIGHT.rotated(global_rotation) * speed * delta

	_age += delta
	_check_despawn()


# --------------------------------------------------
# 回收判定
# --------------------------------------------------
func _check_despawn() -> void:
	if _age >= lifetime:
		print("[Arrow] 超时回收，已飞 ", snapped(_age, 0.01), "s")
		_despawn()
		return

	# 出界。用视口矩形判断，换分辨率也不会出问题。
	var view_rect := get_viewport_rect()
	var screen_pos := get_global_transform_with_canvas().origin
	if (screen_pos.x < -despawn_margin
		or screen_pos.x > view_rect.size.x + despawn_margin
		or screen_pos.y < -despawn_margin
		or screen_pos.y > view_rect.size.y + despawn_margin):
		print("[Arrow] 出界回收 位置=", global_position.round())
		_despawn()


func _despawn() -> void:
	set_deferred("monitoring", false)  # 延迟关闭，避免在物理回调里改检测状态报错
	queue_free()


# --------------------------------------------------
# 命中处理
# --------------------------------------------------
func _on_body_entered(body: Node2D) -> void:
	# 同一目标只算一次伤害（穿透箭会连续经过同一体）
	if _hit_ids.has(body.get_instance_id()):
		return
	_hit_ids.append(body.get_instance_id())

	# 不打自己人
	if shooter != null and body == shooter:
		return

	if body.has_method("take_damage"):
		_apply_on_hit(body)
	elif body.is_in_group("walls"):
		_on_hit_wall(body)
	else:
		print("[Arrow] 撞到「", body.name, "」（无伤害接口），回收")
		_despawn()


## 命中可伤害目标：扣血 + 上附魔 + 元素反应 + 判断是否该消失
func _apply_on_hit(target: Node2D) -> void:
	# 命中点取箭自己的位置（碰撞发生处），而不是靶子中心 ——
	# 飘字才会准确出现在箭打中的地方。
	var hit_pos := global_position

	# ---------- 元素反应（调试用打印，状态在靶子侧已自带日志）----------
	# 用 target.get() 而不是 target.is_wet：箭矢也会打到玩家（没有这些字段），
	# 直接访问不存在的属性会报错并中断后续结算。
	print("[Arrow] 命中「", target.name, "」元素=", element_name(),
		" 靶子状态[湿:", target.get("is_wet"),
		" 冻:", target.get("is_frozen"),
		" 缓:", target.get("is_slowed"),
		" 燃:", target.get("is_burning"), "]")

	var extra := ""

	# ==============================================================
	# ★★ v8 元素附着 + 无序反应检测（顺序已彻底解耦）
	# ------------------------------------------------------------
	# 旧逻辑：先问靶子"我这个元素要不要反应"，反应成功就不挂附魔
	#       → 有顺序依赖（必须先水后冰），且反应后元素不消耗
	# 新逻辑：
	#   ① 【先无条件把本箭的元素挂上去】（燃烧/减速/潮湿）
	#   ② 再让靶子自己做【全身组合扫描】（evaluate_reactions）
	#      它只看"此刻身上有哪些元素"，完全不看施加顺序
	#      先冰后水冻结 ✓  先水后冰冻结 ✓
	#   ③ 反应触发后，参与的两种元素被靶子内部强制消耗（见 target.gd）
	#   ④ 靶子若处于 0.2s 反应冷场期，只挂元素不反应
	# ==============================================================

	# ---------- ① 无条件挂上本箭携带的元素 ----------
	# 火焰附魔：用约定接口，对方没有这个方法就跳过
	if fire_dps > 0.0 and target.has_method("_apply_burn"):
		target._apply_burn(fire_dps, fire_time)
		extra += " +燃烧"
	# 冰霜附魔
	if frost_slow < 1.0 and target.has_method("_apply_slow"):
		target._apply_slow(frost_slow, frost_time)
		extra += " +减速"
	# 水元素附魔（★ v6 一并把反应倍率与传染配置交给靶子记录）
	if water_time > 0.0 and target.has_method("_apply_wet"):
		target._apply_wet(water_time, water_react_mult,
			water_spread_count, water_spread_radius)
		extra += " +潮湿"

	# ---------- ② 让靶子做无序组合检测 ----------
	# 只在靶子有这套新接口时调用；老对象（玩家等）不受影响。
	if target.has_method("evaluate_reactions"):
		var reacted: bool = target.evaluate_reactions(freeze_time,
			frost_burst_damage, frost_burst_radius)
		if reacted:
			extra += " ✦反应"
		elif target.has_method("is_react_locked") and target.is_react_locked():
			extra += " ⏳冷场"

	print("[Arrow] 命中「", target.name, "」 伤害=", damage,
		" 命中坐标=", hit_pos.round(), extra)

	target.take_damage(damage, hit_pos)

	# 穿透箭：还有次数就继续飞，否则销毁
	if can_pierce and pierce_left > 0:
		pierce_left -= 1
		print("[Arrow]   ↳ 穿透！剩余穿透次数 ", pierce_left)
	else:
		_despawn()


## 元素 id 对应的中文名（日志用）
func element_name() -> String:
	match element_id:
		"fire": return "火焰"
		"frost": return "冰霜"
		"water": return "流水"
	return "无元素"


## 撞到墙：没有穿透能力就停下
func _on_hit_wall(wall: Node2D) -> void:
	if can_pierce and pierce_left > 0:
		pierce_left -= 1
		print("[Arrow] 穿透「", wall.name, "」！剩余 ", pierce_left)
		return
	print("[Arrow] 撞到「", wall.name, "」，回收")
	_despawn()
