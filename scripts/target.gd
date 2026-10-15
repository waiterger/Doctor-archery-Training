extends CharacterBody2D
## 靶子（移动靶）：在安全区内水平左右巡逻，撞墙反向。
##
## 这一步新增：
##  - 水平巡逻移动（撞墙/边界自动反向）→ 让「冰霜减速」Buff 有实际意义
##  - 接触玩家会造成伤害（玩家有无敌帧，不会一瞬间被秒）
##
## 为什么把根节点从 StaticBody2D 换成 CharacterBody2D：
##  CharacterBody2D 才能用 move_and_slide() 做「撞到东西就停下」的移动，
##  StaticBody2D 只能被推着走、不能自己动。
## 箭矢用的是 Area2D 的 body_entered，对任何物理体都生效，所以换成 CharacterBody2D 不影响命中。

## 靶子被打空时发出（GameManager 监听它来加分和推进波次）
signal died(target: Node, reward: int)
## 紫怪超时消失（不给分、不掉金币，GameManager 只需把它移出计数）
signal vanished(target: Node)

@export var max_hp: float = 100.0
@export var reward: int = 10          # 击破奖励分数
# ---- 移动参数 ----
@export var patrol_speed: float = 100.0  # 移动速度（会被冰霜减速影响）
@export var turn_min: float = 0.8           # 随机转向间隔下限（秒）
@export var turn_max: float = 2.0           # 随机转向间隔上限（秒）
@export var turn_jitter_deg: float = 70.0   # 每次随机转向的最大偏转角
@export var target_radius: float = 30.0     # 靶子半径（撞墙判定用，比碰撞体稍大）
@export var wall_padding: float = 8.0# 撞墙判定的额外余量：离墙这么近就提前转向
@export var arena_min: Vector2 = Vector2(30, 30)    # 靶子活动范围
@export var arena_max: Vector2 = Vector2(1250, 690)
@export var touch_damage: int = 1      #碰到玩家扣几点血
@export var touch_radius: float = 42.0  # 判定「碰到」的距离（靶子半径26 + 玩家半径16）
@export var touch_cooldown: float = 0.6 # 同一个靶子的最短伤害间隔
# ---- 元素状态时长（秒）----
@export var wet_duration: float = 3.0   # 潮湿持续时间
@export var slow_duration: float = 3.0   # 减速持续时间
@export var burn_duration: float = 2.0   # 燃烧持续时间
@export var wet_tint: Color = Color(0.30, 0.55, 1.0, 1.0)  # 潮湿时的靶子颜色
@export var freeze_duration: float = 2.0    # 冻结持续时间（定身）

# ---- 元素反应参数 ----
@export var steam_radius: float = 150.0    # 蒸发爆炸范围
@export var steam_damage: float = 22.0     # 蒸发对周围靶子的伤害
@export var steam_self_damage: float = 12.0 # 蒸发对本体（潮湿者）的额外伤害
@export var melt_damage: float = 35.0      # 融化单发高额伤害

# ---- 特殊怪（金币怪 / 紫怪）----
## 由Spawner 在特定波次按概率设置。普通靶子保持 false，走原有逻辑。
@export var is_special: bool = false        # 是否紫怪
@export var special_lifetime: float = 5.0   # 紫怪存活秒数，到点自动消失
@export var special_speed_mult: float = 1.2 # 紫怪速度×1.2（比普通快 20%）
@export var special_hp_mult: float = 0.8     # 紫怪血量×0.8（比普通少 20%）
@export var gold_reward: int = 1# 击杀掉落金币

var hp: float = 100.0
var is_dead: bool = false

# ---- 移动状态 ----
var _dir: Vector2 = Vector2.RIGHT# 当前移动方向（单位向量，X/Y 都有分量）
var last_turn_deg: float = 0.0      # 上一次随机转向的实际偏转角度
var _turn_timer: float = 0.0              # 距离下一次随机转向还剩几秒
var _touch_cd: float = 0.0               # 接触伤害冷却

# ---- 状态效果 ----
##【公开状态标记】箭矢读这些字段做元素反应判定
var is_wet: bool = false        # 潮湿（水）
var is_burning: bool = false        # 燃烧（火）
var is_slowed: bool = false     # 减速（冰）
var is_frozen: bool = false      # 冻结（定身，冰+水反应的产物）

## ---- 状态计时器（到点必清，见 _tick_states）----
var _wet_time_left: float = 0.0     # 潮湿剩余
## ★ v6 流水附魔快照：在【被水箭命中那一刻】由箭矢传入并锁定。
##   · react_mult —— 反应伤害倍率，按"结算瞬间的等级"生效，之后升级不影响已上身的潮湿
##   · spread_count / spread_radius —— 死亡时的潮湿传染配置
##   三个字段都【不随潮湿到点而清零】：反应可能在潮湿消失后才发生（融化），传染在死亡时发生。
var _wet_react_mult: float = 1.0
var _wet_spread_count: int = 0
var _wet_spread_radius: float = 0.0
var _burn_time_left: float = 0.0    # 燃烧剩余
var _burn_dps: float = 0.0          # 燃烧每秒伤害
var _slow_time_left: float = 0.0    # 减速剩余
var _slow_factor: float = 1.0       # 移动倍率（1=正常，0.5=半速）
var _frozen_time_left: float = 0.0# 冻结剩余

## ★ v6 冻结内置冷却（ICD）：冻结结束瞬间立刻获得 8 秒冰冻免疫。
## 免疫期间被冰箭命中【只能减速】，绝不会定身，也绝不会触发冰爆。
var freeze_immunity: float = 0.0
## 免疫时长（秒）
const FREEZE_IMMUNITY_DURATION := 8.0
## 本次冻结【结算瞬间】记下的冰爆数据（Lv.3+ 才 >0）。
## 按"冻结触发瞬间的冰霜等级"锁定，避免冻结期间升级导致结算错乱。
var _pending_burst_damage: float = 0.0
var _pending_burst_radius: float = 50.0
var _special_time_left: float = 0.0       # 紫怪剩余存活时间（普通怪恒为 0）

## ★ 紫怪专用色（当前全局没在用，不会和状态色撞车）
const SPECIAL_COLOR := Color(0.72, 0.30, 0.95, 1.0)
const SPECIAL_TINT := Color(0.88, 0.55, 1.0, 1.0)   # 紫怪受击闪色基线

const BASE_COLOR := Color(0.85, 0.3, 0.3, 1.0)
const BURN_COLOR := Color(1.0, 0.55, 0.2, 1.0)
const FROST_COLOR := Color(0.45, 0.7, 1.0, 1.0)
const FREEZE_COLOR := Color(0.75, 0.92, 1.0, 1.0)   # 冻结：偏白的高亮冰蓝

@onready var poly: Polygon2D = $Poly
@onready var special_label: Label = $SpecialLabel
@onready var hit_flash: HitFlash = $HitFlash

## ★★ v7 状态 UI：彻底废弃"一个 Label 拼 '💧 潮湿 3.0s'" 的写法。
## 改为「三行 HBoxContainer」= 图标(TextureRect) + 纯数字倒计时(Label)。
##分行排布保证火焰 / 冰霜 / 潮湿 各自独立，永远不会互相遮挡。
@onready var status_root: VBoxContainer = $StatusRoot
@onready var wet_row: HBoxContainer = $StatusRoot/WetRow
@onready var wet_time: Label = $StatusRoot/WetRow/Time
@onready var burn_row: HBoxContainer = $StatusRoot/BurnRow
@onready var burn_time: Label = $StatusRoot/BurnRow/Time
@onready var frost_row: HBoxContainer = $StatusRoot/FrostRow
@onready var frost_time: Label = $StatusRoot/FrostRow/Time
@onready var immune_row: HBoxContainer = $StatusRoot/ImmuneRow
@onready var immune_time: Label = $StatusRoot/ImmuneRow/Time

## ★★ 需求指定的倒计时文字颜色：RGB(76, 140, 255)
## 代码里每帧重新赋一遍，防止被主题或运行时其他逻辑覆盖掉。
const WET_TIME_COLOR := Color(0.298039, 0.549020, 1.0, 1.0)   # = Color8(76,140,255)
## 其余状态各自的文字色（潮湿之外，视觉上区分用）
const BURN_TIME_COLOR := Color(1.0, 0.678431, 0.290196, 1.0)
const FROST_TIME_COLOR := Color(0.607843, 0.831373, 1.0, 1.0)
const IMMUNE_TIME_COLOR := Color(0.784314, 0.839216, 1.0, 1.0)
## 倒计时文字统一字号
const STATUS_FONT_SIZE := 14

## ★ 极简血条：两层 ColorRect（Bg 底色 + Fill 前景），无任何文字。
## Fill 的右边界按 HP 比例缩放，形成"从左往右缩短"的效果。
@onready var hp_bar_bg: ColorRect = get_node_or_null("HealthBarBg")
@onready var hp_bar_fill: ColorRect = get_node_or_null("HealthBarFill")
## 血条满血时的宽度（像素），计算缩短量时要用
const HP_BAR_FULL_WIDTH := 39.0
var _player: Node2D = null


func _ready() -> void:
	# 注意：Spawner 是在 add_child() 之前就设好了 max_hp，
	# 所以这里读到的已经是本波的正确血量。
	hp = max_hp
	add_to_group("targets")

	# 随机初始方向（真正的2D 平面角度，不只是左右）
	_dir = Vector2.RIGHT.rotated(randf() * TAU)
	_turn_timer = randf_range(turn_min, turn_max)

	# 缓存玩家引用（玩家把自己加入 "player" 组）
	_player = get_tree().get_first_node_in_group("player")

	# ★ 紫怪初始化：速度×1.2、血量在 Spawner 里已按 0.8 传入、存活倒计时开启
	if is_special:
		patrol_speed *= special_speed_mult
		_special_time_left = special_lifetime
		special_label.visible = true
		special_label.text = "%.0f s" % _special_time_left
		# 紫怪颜色压过所有状态色，一眼能认出来
		if poly != null:
			poly.color = SPECIAL_COLOR

	_refresh_hp_bar()
	_refresh_status_label()
	print("[Target] 生成 血量=", int(hp), " 位置=", global_position.round(),
		" 巡逻速度=", int(patrol_speed),
		" 紫怪=", is_special)


func _physics_process(delta: float) -> void:
	if is_dead:
		return
	_tick_states(delta)
	_tick_patrol(delta)
	_tick_touch(delta)
	_tick_special(delta)


## 紫怪存活倒计时：到点自动消失（不计入击杀，不掉金币）。
## 关键：消失时必须【主动通知 GameManager 从 _alive_targets 里移除】，
## 否则场上的计数永远减不下去，波次会卡死等一个已经不存在的靶子。
func _tick_special(delta: float) -> void:
	if not is_special or is_dead:
		return
	if _special_time_left <= 0.0:
		return
	_special_time_left -= delta

	if special_label != null:
		special_label.text = "%.1f s" % maxf(_special_time_left, 0.0)
		# 最后 2 秒变红闪烁，制造"再不打就没了"的紧迫感
		if _special_time_left <= 2.0:
			special_label.modulate = Color(1, 0.3, 0.3, 1) \
				if fmod(_special_time_left, 0.5) > 0.25 else Color(1, 0.7, 0.7, 1)

	if _special_time_left > 0.0:
		return

	# 到点消失
	print("[Target] ⏰ 紫怪超时消失（没被打掉）")
	_vanish()


## 紫怪自然消失：从场上下架，但不发 died 信号、不给分数、不掉金币。
func _vanish() -> void:
	if is_dead:
		return
	is_dead = true
	if status_root != null:
		status_root.visible = false
	if special_label != null:
		special_label.visible = false
	remove_from_group("targets")
	# 发一个"静默消失"信号，GameManager 收到后只移除计数、不加分
	vanished.emit(self)
	queue_free()


# --------------------------------------------------
# 2D 平面移动（纯数学，不用物理碰撞）
# --------------------------------------------------
## 心流状态带来的额外减速倍率。
## ⚠⚠ 绝对不要用 Engine.time_scale 实现！
## time_scale 会把整个场景树放慢，连带影响：
##   - HitStop 顿帧（本身就是改time_scale 实现的，会互相打架）
##   - VideoStreamPlayer 复活视频（暂停态下会彻底卡死）
##   - 飘字/震屏的 Tween 动画
## 这里只乘一个局部倍率，物理时间流速完全不受影响。
func _flow_speed_mult() -> float:
	var tree := get_tree()
	if tree == null or not tree.root.has_node("Flow"):
		return 1.0
	var flow: Node = tree.root.get_node("Flow")
	if flow == null or not is_instance_valid(flow):
		return 1.0
	return float(flow.call("enemy_speed_mult"))


## 【为什么用纯数学，不用 move_and_slide / move_and_collide】
## 之前用物理碰撞做反弹，实测会把靶子卡进墙体里 —— 因为墙只有 60 像素宽，
## 靶子直径 52，斜着撞进去就再也推不出来，整局卡死。
## 现在改成：collision_mask = 0（物理上完全不碰任何东西），
## 位置只由「速度 × 时间」算出来，再用手写数学做边界反弹。
## 这样**结构上就不可能卡住**，同时保留「撞墙前提前反向」的智能表现。
##
## 流程：随机转向 → 预测下一步 → 预测撞墙就提前反轴 → 直接改位置 → 边界兜底
func _tick_patrol(delta: float) -> void:
	# 冻结中：速度直接归零，靶子完全静止
	if is_frozen:
		velocity = Vector2.ZERO
		return

	var real_speed := patrol_speed * _slow_factor * _flow_speed_mult()

	# --- 随机转向：到点了就偏转一点 ---
	_turn_timer -= delta
	if _turn_timer <= 0.0:
		_turn_timer = randf_range(turn_min, turn_max)
		# 在当前方向上叠加一个随机角度，形成「灵性」的不规则轨迹
		var jitter := deg_to_rad(randf_range(-turn_jitter_deg, turn_jitter_deg))
		_dir = _dir.rotated(jitter).normalized()
		# 记录本次实际偏转幅度（测试用；也方便 F1 调试观察）
		last_turn_deg = absf(rad_to_deg(jitter))

	var step := _dir * real_speed * delta

	# --- 撞墙前【提前】反向，而不是撞进去再反 ---
	# 分别试探「只走 X」「只走 Y」，看哪一步会撞，就反哪一轴。
	# 这样靶子会贴着墙提前转弯，不会糊在墙面上。
	var next_x := global_position + Vector2(step.x, 0.0)
	var next_y := global_position + Vector2(0.0, step.y)
	var hit_x := _will_hit(next_x)
	var hit_y := _will_hit(next_y)

	if hit_x:
		_dir.x = -_dir.x
	if hit_y:
		_dir.y = -_dir.y
	# 两轴都要撞（角落）：随机一个新方向，避免原地抖动
	if hit_x and hit_y:
		_dir = Vector2.RIGHT.rotated(randf() * TAU)

	_dir = _dir.normalized()
	step = _dir * real_speed * delta

	# --- 直接改位置（没有任何物理阻挡）---
	global_position += step
	velocity = _dir * real_speed

	# 让图形朝向移动方向，看起来更清楚在往哪走
	if poly != null and _dir.length() > 0.01:
		poly.rotation = _dir.angle()

	# --- 边界兜底 + 万一已在墙里则脱困 ---
	_clamp_to_arena()
	_unstick()


## 预测某个位置会不会撞墙/出界。
## 用「膨胀矩形」判断：墙的半尺寸加上靶子半径 + 安全余量。
func _will_hit(p: Vector2) -> bool:
	# 场地边界
	if p.x < arena_min.x or p.x > arena_max.x \
			or p.y < arena_min.y or p.y > arena_max.y:
		return true
	# 墙体
	for w in get_tree().get_nodes_in_group("walls"):
		if w.has_method("is_blocked") and w.is_blocked(p, wall_padding):
			return true
	return false


## 兜底 A：把靶子夹回场地内，夹到哪条边就反哪一轴
func _clamp_to_arena() -> void:
	var p := global_position
	if p.x >= arena_min.x and p.x <= arena_max.x \
			and p.y >= arena_min.y and p.y <= arena_max.y:
		return
	if p.x < arena_min.x or p.x > arena_max.x:
		_dir.x = -_dir.x
	if p.y < arena_min.y or p.y > arena_max.y:
		_dir.y = -_dir.y
	global_position.x = clampf(p.x, arena_min.x, arena_max.x)
	global_position.y = clampf(p.y, arena_min.y, arena_max.y)


## 兜底 B：万一已经陷在墙体里，沿最短的轴把它推出来并反向。
## 这条是「上一版卡死」的救生索，正常流程下永远不该触发。
func _unstick() -> void:
	var p := global_position
	for w in get_tree().get_nodes_in_group("walls"):
		if not w.has_method("get_overlap_rect"):
			continue
		var r: Rect2 = w.get_overlap_rect(target_radius)
		if not r.has_point(p):
			continue
		# 推到最近的一条边上（选距离最小的那个方向）
		var push_left := p.x - r.position.x
		var push_right := r.position.x + r.size.x - p.x
		var push_up := p.y - r.position.y
		var push_down := r.position.y + r.size.y - p.y
		var m := minf(minf(push_left, push_right), minf(push_up, push_down))
		if is_equal_approx(m, push_left):
			global_position.x = r.position.x - 1.0
			_dir.x = -1.0
		elif is_equal_approx(m, push_right):
			global_position.x = r.position.x + r.size.x + 1.0
			_dir.x = 1.0
		elif is_equal_approx(m, push_up):
			global_position.y = r.position.y - 1.0
			_dir.y = -1.0
		else:
			global_position.y = r.position.y + r.size.y + 1.0
			_dir.y = 1.0
		_dir = _dir.normalized()
		print("[Target] ⚠ 从墙体中脱困 → ", global_position.round())


# --------------------------------------------------
# 接触伤害
# --------------------------------------------------
## 用距离判定而不是物理信号，好处是：
## 玩家一直站在靶子上时，每隔 touch_cooldown 也会再掉一次血，不会只触发一次就免疫。
func _tick_touch(delta: float) -> void:
	if _touch_cd > 0.0:
		_touch_cd -= delta
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player")
		return
	if not _player.has_method("take_damage"):
		return

	if global_position.distance_to(_player.global_position) > touch_radius:
		return

	_touch_cd = touch_cooldown
	_player.take_damage(touch_damage, global_position)
	print("[Target] 碰到玩家！造成 ", touch_damage, " 点伤害")


# --------------------------------------------------
# 通用伤害接口（任何箭矢命中都走这里）
# --------------------------------------------------
## show_popup 只在「箭矢实打」时传 true。
## 燃烧 DOT 每帧都调这里，必须传 false，否则会一秒钟刷 60 个飘字。
func take_damage(amount: float, hit_pos: Vector2, show_popup: bool = true) -> void:
	if is_dead:
		return

	hp -= amount
	if show_popup:
		_flash()
		_popup_number(amount, hit_pos)
		_hit_feedback(amount)
		# ★ 箭矢命中木质靶子的音效
		_sfx("play_hit")
	print("[Target] 受到 ", snapped(amount, 0.1), " 伤害 → 剩余 ", hp,
		" 命中点=", hit_pos.round())

	if hp <= 0.0:
		_die()
	else:
		_refresh_hp_bar()


## 受击闪白：交给独立的 HitFlash 组件（shader 混白），
## 不再直接改 poly.color —— 这样冰冻蓝 / 燃烧橙的状态色不会被冲掉。
func _flash() -> void:
	if hit_flash != null:
		hit_flash.flash()


## 命中飘字：高伤害数字更大更黄，一眼看清打疼了没有
func _popup_number(amount: float, hit_pos: Vector2) -> void:
	DamageNumber.spawn(self, hit_pos, amount, Color(1.0, 0.95, 0.85), amount >= 30.0)


## 命中打击感：屏幕震动 + 顿帧。
## 和飘字放在一起调用 —— show_popup 为 true 才到这里，
## 所以燃烧 DOT 每帧的伤害【不会】触发震动和顿帧。
## 力度按伤害缩放：小箭轻震，重箭重震。
func _hit_feedback(amount: float) -> void:
	# 伤害 → 0.3~1.4 的强度区间，10 点小伤害也有反馈
	var ratio := clampf(amount / 40.0, 0.3, 1.4)
	ScreenShake.shake_at(self, ratio)
	# 顿帧时间和强度也跟伤害挂钩，重箭卡得更狠
	HitStop.trigger(self, lerpf(0.03, 0.07, ratio / 1.4), lerpf(0.15, 0.05, ratio / 1.4))


# --------------------------------------------------
# 附魔接口（箭矢命中时按需调用）
# --------------------------------------------------

## ★★★ 燃烧数值安全上限（性能兜底）。
## 玩家金币溢出可能把火焰等级堆到几十级，
## 没有这层 clamp 的话 _burn_dps 会变成四位数，
## 乘delta 之后单帧伤害爆炸，容易数值溢出 / 游戏卡顿。
const BURN_DPS_HARD_CAP := 50.0      # 每秒伤害硬上限
const BURN_DURATION_HARD_CAP := 8.0  # 持续时间硬上限（秒）


## 施加燃烧。重复命中【只重置倒计时】，DPS 取最强，不叠乘。
## ⚠ 入参和内部值都做 clamp —— 这是最后一道安全网，
##    即使上游 buff_manager 的曲线被改坏，这里也不会失控。
func _apply_burn(dps: float, duration: float = -1.0) -> void:
	if is_dead:
		return
	# ★ clamp 性能兜底
	var safe_dps := clampf(dps, 0.0, BURN_DPS_HARD_CAP)
	var d := burn_duration if duration <= 0.0 else duration
	var safe_dur := clampf(d, 0.0, BURN_DURATION_HARD_CAP)

	is_burning = true
	_burn_dps = maxf(_burn_dps, safe_dps)          # 取最强的一次，不叠乘
	_burn_time_left = maxf(_burn_time_left, safe_dur)  # 重置/延长倒计时
	# 双重保险：赋值后再夹一次
	_burn_dps = clampf(_burn_dps, 0.0, BURN_DPS_HARD_CAP)
	_refresh_tint()
	if dps > BURN_DPS_HARD_CAP or d > BURN_DURATION_HARD_CAP:
		push_warning("[Target] ⚠ 燃烧数值超限已夹取：dps=", dps,
			"→", _burn_dps, "  duration=", d, "→", safe_dur)
	print("[Target] 🔥 被点燃  每秒 ", snapped(_burn_dps, 1),
		"  剩余 ", snapped(_burn_time_left, 1), "s")


## 施加冰霜减速。
## 叠加规则：减速【不叠乘】，只在第一次生效，之后只把倒计时重置为 3 秒。
func _apply_slow(factor: float, duration: float = -1.0) -> void:
	if is_dead:
		return
	var d := slow_duration if duration <= 0.0 else duration
	if not is_slowed:
		_slow_factor = clampf(factor, 0.2, 1.0)   # 只有首次才记录倍率
	is_slowed = true
	_slow_time_left = maxf(_slow_time_left, d)     # 之后只重置倒计时
	_refresh_tint()
	print("[Target] ❄ 被减速  速度×", snapped(_slow_factor, 2),
		"  剩余 ", snapped(_slow_time_left, 1), "s")


## 施加潮湿（水）。★ v6 由箭矢一并传入反应倍率与传染配置并锁定。
func _apply_wet(duration: float = -1.0, react_mult: float = 1.0,
		spread_count: int = 0, spread_radius: float = 0.0) -> void:
	if is_dead:
		return
	var d := wet_duration if duration <= 0.0 else duration
	is_wet = true
	_wet_time_left = maxf(_wet_time_left, d)
	# 锁定本次水箭携带的流水等级数据（取最强的一次，不降级）
	_wet_react_mult = maxf(_wet_react_mult, clampf(react_mult, 1.0, 3.0))
	if spread_count != 0:
		_wet_spread_count = spread_count
		_wet_spread_radius = maxf(spread_radius, 0.0)
	_refresh_tint()
	_refresh_status_label()
	print("[Target] 💧 被淋湿剩余 ", snapped(_wet_time_left, 1),
		"s  反应×", snapped(_wet_react_mult, 2),
		"  传染=", _wet_spread_count)


## ★ v6 潮湿传染：带潮湿的靶子被击杀时，把潮湿传染给周围靶子。
##   spread_count == 1  → 随机 1 个
##   spread_count == -1 → 半径内全部
##   传染出去的是【同样的潮湿时长 + 同样的倍率/传染配置】，
##   所以被传染的靶子再死还能继续往下传，形成连锁。
func _spread_wet_on_death() -> void:
	if _wet_spread_count == 0 or _wet_spread_radius <= 0.0:
		return
	var candidates: Array[Node2D] = []
	for t in get_tree().get_nodes_in_group("targets"):
		if t == self:
			continue
		var node := t as Node2D
		if node == null:
			continue
		# 只传给还活着的、且确实在半径内的
		if bool(node.get("is_dead")):
			continue
		if global_position.distance_to(node.global_position) > _wet_spread_radius:
			continue
		candidates.append(node)

	if candidates.is_empty():
		return

	var hit: Array[Node2D] = []
	if _wet_spread_count < 0:
		# Lv.10+：范围内全部
		hit = candidates
	else:
		# 随机 1 个（洗牌后取第一个，避免每次都是同一只）
		candidates.shuffle()
		hit.append(candidates[0])

	var dur := maxf(_wet_time_left, 0.0)
	for node in hit:
		if node.has_method("_apply_wet"):
			node._apply_wet(dur, _wet_react_mult,
				_wet_spread_count, _wet_spread_radius)
	_popup_text("💧 传染！", Color(0.45, 0.72, 1.0), 26)
	print("[Target] 💧💧 潮湿传染 → ", hit.size(), " 个靶子（半径 ",
		snapped(_wet_spread_radius, 0), "）")


## 施加冻结（定身）。由冰+水反应触发。
## 不动 _slow_factor —— 命中流程里紧随其后还会调 _apply_slow()。
## ★ v6：bust_damage/bust_radius 是【命中瞬间由箭矢传入】的冰爆数据，
##    这里只锁定不下结算 —— 真正触发在冻结结束那一帧（见 _clear_frozen）。
func _apply_freeze(duration: float = -1.0, burst_damage: float = 0.0,
		burst_radius: float = 50.0) -> void:
	if is_dead:
		return
	var d := freeze_duration if duration <= 0.0 else duration
	is_frozen = true
	_frozen_time_left = maxf(_frozen_time_left, d)
	# 锁定本次冻结的冰爆数据（Lv.3+ 才有）
	_pending_burst_damage = maxf(_pending_burst_damage, burst_damage)
	_pending_burst_radius = maxf(burst_radius, 1.0)
	# ★ 冻结期间免疫归零（免疫只在"冻结结束"那一刻才给）
	freeze_immunity = 0.0
	print("[Target] 🧊 冻结！定身 ", snapped(_frozen_time_left, 1),
		"s  冰爆储备=", snapped(_pending_burst_damage, 0))
	_refresh_tint()
	_refresh_status_label()


## ★ v6 冰爆：以本靶子为圆心，对半径内【其他】靶子造成伤害 + 附加 Lv.1 减速。
## 只结算一次（结算后立刻清空储备），不会因为同帧多次调用而重复爆。
func _trigger_frost_burst() -> void:
	var dmg := _pending_burst_damage
	var radius := _pending_burst_radius
	_pending_burst_damage = 0.0
	if dmg <= 0.0 or radius <= 0.0:
		return

	_popup_text("❄ 冰爆！", Color(0.70, 0.94, 1.0), 30)

	# 冻结弹本身不吃自己的冰爆（伤害来自箭矢本体），只作用周围靶子。
	var hit := 0
	for t in get_tree().get_nodes_in_group("targets"):
		if t == self:
			continue
		var node := t as Node2D
		if node == null:
			continue
		if global_position.distance_to(node.global_position) > radius:
			continue
		hit += 1
		node.take_damage(dmg, node.global_position, false)
		node._popup_text("❄", Color(0.70, 0.94, 1.0), 22)
		# 冰爆附带的减速【固定为 Lv.1 档】：30% / 2s
		if node.has_method("_apply_slow"):
			node._apply_slow(1.0 - 0.30, 2.0)

	ScreenShake.shake_at(self, 1.0)
	HitStop.trigger(self, 0.07, 0.05)
	print("[Target] 💥 冰爆！半径 ", snapped(radius, 0),
		" 伤害 ", snapped(dmg, 0), " 波及 ", hit, " 个靶子")


# --------------------------------------------------
# ★★ v8 元素反应：无序检测 + 互斥锁 + 强制消耗
# --------------------------------------------------
#设计要点（彻底重写，不再依赖"谁先谁后"）：
#   ① 靶子身上挂着【一组元素】（火/冰/水），命中后重新做一次【组合检测】，
#      只要同时存在任意一对能反应的元素，立刻触发 —— 与施加顺序无关。
#      例：先冰后水、或先水后冰，都能冻结。
#   ② 全局反应冷却锁：任何反应触发后进入 0.2 秒冷场期，期间不再触发任何反应。
#      这是为了防止靶子同时挂三种元素时一波爆发连环触发导致卡顿。
#   ③ 同帧满足多个条件时，按【冻结 > 融化 > 蒸发】只触发一个。
#   ④ 反应触发后，参与反应的两种元素【立即被消耗】（状态 + 计时器全清），
#      头顶图标立刻消失，玩家必须重新挂元素才能再触发。

## ★ v8 反应冷却锁时长（秒）
const REACT_LOCK_TIME := 0.2
## 当前反应冷却剩余（>0 表示处于冷场期）
var _react_lock: float = 0.0


## 靶子身上是否拥有指定元素。
## 这是【无序检测】的基础 —— 不看顺序，只看"现在有没有"。
## · fire  = 燃烧中
## · frost = 冻结中 或 减速中（冰元素两种形态都算冰）
## · water = 潮湿中
func _has_element(id: String) -> bool:
	match id:
		"fire":
			return is_burning
		"frost":
			return is_frozen or is_slowed
		"water":
			return is_wet
	return false


## 清除指定元素（用于反应后的强制消耗）。
## 注意：清"冰"要同时清减速和冻结两种形态。
func _consume_element(id: String) -> void:
	match id:
		"fire":
			_clear_burn()
		"frost":
			# ★ 自然解冻不给免疫、不触发冰爆 —— 反应打断不算自然结束
			_clear_slow()
			_clear_frozen(false)
		"water":
			_clear_wet()


## ★★ v8 无序反应检测。由箭矢在【挂完元素之后】调用。
##
## 与旧版 try_react() 的区别：
##   旧版：箭矢带着"我是火/冰/水"来问靶子，靶子按箭矢元素找对手 → 有顺序依赖
##   新版：箭矢先把元素挂上去，再让靶子自己扫一遍全身 → 无顺序依赖
##
## 参数（都来自本次命中的箭矢，只在"确实要冻结"时才锁定）：
##   freeze_dur / burst_damage / burst_radius
## 返回是否触发了反应。
func evaluate_reactions(freeze_dur: float = -1.0,
		burst_damage: float = 0.0, burst_radius: float = 50.0) -> bool:
	if is_dead:
		return false

	# ★ 反应冷却锁：冷场期内一律不反应（元素附着照常，只是不再触发反应）
	if _react_lock > 0.0:
		return false

	var has_fire := _has_element("fire")
	var has_frost := _has_element("frost")
	var has_water := _has_element("water")

	# ---- 优先级判定：【冻结 > 融化 > 蒸发】，同帧只触发一个 ----
	# 冻结 = 冰 + 水（且必须不在冰冻免疫中）
	if has_frost and has_water and not has_freeze_immunity():
		_lock_reaction()
		_react_freeze(freeze_dur, burst_damage, burst_radius)
		return true

	# 融化 = 火 + 冰
	if has_fire and has_frost:
		_lock_reaction()
		_react_melt()
		return true

	# 蒸发 = 火 + 水
	if has_fire and has_water:
		_lock_reaction()
		_react_steam()
		return true

	return false


## 进入反应冷场期：本次反应已结算，0.2 秒内不再触发任何其他反应。
func _lock_reaction() -> void:
	_react_lock = REACT_LOCK_TIME


## 当前是否处于反应冷场期（调试/UI 用）
func is_react_locked() -> bool:
	return _react_lock > 0.0


## 蒸发：火 + 水 → 范围爆炸，并消耗掉【火】和【水】两种附着。
## splash 会伤到范围内【其他】靶子，所以内部一律用 show_popup=false 静默结算。
## ★ v6：所有伤害乘上 _wet_react_mult（流水等级带来的反应倍率）。
func _react_steam() -> void:
	# ⚠ 先取倍率再清状态 —— 消费会重置部分字段
	var mult := _wet_react_mult
	# ★ v8 强制消耗参与反应的两种元素（状态 + 计时器全清 → 图标立刻消失）
	_consume_element("fire")
	_consume_element("water")

	take_damage(steam_self_damage * mult, global_position, true)
	_popup_text("蒸发！", Color(0.55, 0.90, 1.0), 28)

	var hit := 0
	for t in get_tree().get_nodes_in_group("targets"):
		if t == self:
			continue
		var d: float = global_position.distance_to((t as Node2D).global_position)
		if d > steam_radius:
			continue
		hit += 1
		# 距离越近伤害越高（中心 100% → 边缘 40%）
		var falloff := lerpf(1.0, 0.4, d / steam_radius)
		t.take_damage(steam_damage * mult * falloff, (t as Node2D).global_position, false)
		(t as Node2D)._popup_text("🔥", Color(1.0, 0.6, 0.2), 22)
		# 溅射也把别人的潮湿烧干，避免连锁无限触发
		# ⚠ 只清"水"，不清别人的火 —— 别人的燃烧交给它自己走反应流程
		if t.has_method("_consume_element"):
			t._consume_element("water")

	# 范围伤害同样给打击感（比普通命中更重）
	var ratio := clampf(steam_damage * mult / 40.0, 0.8, 1.6)
	ScreenShake.shake_at(self, ratio)
	HitStop.trigger(self, 0.08, 0.05)
	print("[Target] 💨 蒸发！×", snapped(mult, 2),
		" 波及 ", hit, " 个靶子（火+水 已消耗）")


## 融化：火 + 冰 → 高额单发伤害，并消耗掉【火】和【冰】两种附着。
## ★ v6：伤害乘 _wet_react_mult（冻结源自水+冰，倍率沿用流水等级）。
func _react_melt() -> void:
	var mult := _wet_react_mult
	# ★ v8 强制消耗火与冰（_consume_element("frost") 内部会走 _clear_frozen(false)，
	#    即"被火焰吃掉" → 不给冰冻免疫、不触发冰爆）
	_consume_element("fire")
	_consume_element("frost")

	take_damage(melt_damage * mult, global_position, true)
	_popup_text("融化！", Color(1.0, 0.45, 0.25), 28)

	var ratio := clampf(melt_damage * mult / 40.0, 1.0, 1.6)
	ScreenShake.shake_at(self, ratio)
	HitStop.trigger(self, 0.09, 0.05)
	print("[Target] 🔆 融化！×", snapped(mult, 2),
		" 造成 ", snapped(melt_damage * mult, 0),
		" 点伤害（火+冰 已消耗）")


## 冻结：冰 + 水 → 定身，并消耗掉【水】。
## ★ 注意只消耗"水"，不消耗"冰"—— 冰在这里【转化成】冻结态本身，
##    也就是 reaction 的产物，不是残留。后续火打上来仍能触发融化（火+冰）。
func _react_freeze(duration: float = -1.0, burst_damage: float = 0.0,
		burst_radius: float = 50.0) -> void:
	# ★ v8 消耗水（潮湿转定身）
	_consume_element("water")
	_apply_freeze(duration, burst_damage, burst_radius)
	_popup_text("冻结！", Color(0.75, 0.92, 1.0), 28)
	print("[Target] 🧊 冻结反应！冰+水 → 定身（水已消耗，冰转为冻结态）")


## ★ v6 免疫判定：冰冻免疫期间只能减速，绝不定身 / 绝不冰爆。
func has_freeze_immunity() -> bool:
	return freeze_immunity > 0.0


## 兼容旧接口：v8 之后箭矢不再用它（改为挂完元素调 evaluate_reactions），
## 但保留转发壳，避免可能存在的外部调用点直接崩掉。
func try_react(arrow_element: String, duration: float = -1.0,
		burst_damage: float = 0.0, burst_radius: float = 50.0) -> bool:
	return evaluate_reactions(duration, burst_damage, burst_radius)


## 文字飘字（元素反应提示）
func _popup_text(text: String, color: Color, font_px: int = 26) -> void:
	DamageNumber.spawn_text(self, global_position, text, color, font_px)


# --------------------------------------------------
# 状态清除（反应和到点过期都走这里，保证不留残渣）
# --------------------------------------------------

func _clear_wet() -> void:
	if not is_wet:
		return
	is_wet = false
	_wet_time_left = 0.0
	_refresh_tint()
	_refresh_status_label()


func _clear_burn() -> void:
	if not is_burning and _burn_time_left <= 0.0:
		return
	is_burning = false
	_burn_time_left = 0.0
	_burn_dps = 0.0
	_refresh_tint()
	_refresh_status_label()   # ★ v8：燃烧图标必须立刻消失


func _clear_slow() -> void:
	if not is_slowed and _slow_time_left <= 0.0:
		return
	is_slowed = false
	_slow_time_left = 0.0
	_slow_factor = 1.0      # 必须还原，否则靶子永久半速
	# 解冻条件：减速没了，冻结也没了，速度才彻底恢复
	if not is_frozen:
		pass
	_refresh_tint()


## ★ v6：解除定身。
##   natural = true  → 由倒计时自然结束：立刻给 8 秒冰冻免疫 + 触发冰爆。
##   natural = false → 被融化/清除等"外力"打断：不给免疫、不触发冰爆。
func _clear_frozen(natural: bool = true) -> void:
	if not is_frozen:
		# 不处于冻结时也要把储备清干净，避免残留
		_pending_burst_damage = 0.0
		return
	is_frozen = false
	_frozen_time_left = 0.0
	if natural:
		# ① 先给免疫（顺序很重要：冰爆判定必须发生在免疫生效之后，
		#    这样"免疫期间绝不可能触发冰爆"这条规则天然成立）
		freeze_immunity = FREEZE_IMMUNITY_DURATION
		# ② 再在"由冻结恢复为自由"的这一瞬间触发冰爆
		_trigger_frost_burst()
	_refresh_tint()
	_refresh_status_label()


# --------------------------------------------------
# 状态生命周期：每帧推进，到点【强制清除】
# --------------------------------------------------
## 统一在一个函数里推进所有倒计时。
## 用 _process 计数器而不是 Timer 节点：靶子是动态生成的，
## Timer 需要额外管理 kill/创建，而且换场景时容易漏掉。
func _tick_states(delta: float) -> void:
	# --- 燃烧：到点或触发反应后立即停掉 DOT ---
	if _burn_time_left > 0.0:
		_burn_time_left -= delta
		# ★ 结算前再夹一次：单帧伤害 = dps * delta。
		#   即使 _burn_dps 被外部改坏，单帧伤害也有硬上限。
		var frame_dps := clampf(_burn_dps, 0.0, BURN_DPS_HARD_CAP)
		take_damage(frame_dps * delta, global_position, false)  # DOT 不刷飘字
		if _burn_time_left <= 0.0:
			_clear_burn()
			print("[Target] 燃烧自然熄灭")

	# --- 减速：到点强制恢复原速度 ---
	if _slow_time_left > 0.0:
		_slow_time_left -= delta
		if _slow_time_left <= 0.0:
			_clear_slow()
			print("[Target] 减速结束，恢复原速")

	# --- 潮湿：到点强制变干 ---
	if _wet_time_left > 0.0:
		_wet_time_left -= delta
		if _wet_time_left <= 0.0:
			_clear_wet()
			print("[Target] 潮湿已干")

	# --- 冻结：到点解除定身（自然解冻 → 给免疫 + 冰爆） ---
	if _frozen_time_left > 0.0:
		_frozen_time_left -= delta
		if _frozen_time_left <= 0.0:
			_clear_frozen(true)
			# 冻结没了但减速还在 → 速度由 _slow_factor 决定（仍是半速）
			print("[Target] 冻结解除 → 获得 8s 冰冻免疫")

	# --- ★ v6 冰冻免疫（ICD）倒计时 ---
	if freeze_immunity > 0.0:
		freeze_immunity = maxf(freeze_immunity - delta, 0.0)

	# --- ★ v8 反应冷却锁：0.2 秒冷场期倒计时 ---
	# 期间元素附着照常生效（倒计时照走），只是不再触发新的反应。
	if _react_lock > 0.0:
		_react_lock = maxf(_react_lock - delta, 0.0)

	#=============================================================
	# ★★ v7 状态 UI 倒计时 —— 每帧刷新（核心）
	# 放在所有状态推进【之后】，保证这一帧读到的是刚刚递减过的数值。
	# 归零的状态在上面已被 _clear_*() 置is_* = false，
	# 这里对应的 Row 会自动 visible = false —— 图标和倒计时一起消失。
	#=============================================================
	_refresh_status_ui()


## 保留旧接口名，内部转发到新逻辑（避免破坏可能的旧调用点）
func _tick_burn(delta: float) -> void:
	_tick_states(delta)


## 统一决定靶子当前该是什么颜色。按优先级算一次，谁优先级高谁赢。
func _refresh_tint() -> void:
	if poly == null or is_dead:
		return
	if is_frozen:
		poly.color = FREEZE_COLOR        # 冻结最高优先
	elif is_burning:
		poly.color = BURN_COLOR          # 燃烧
	elif is_slowed:
		poly.color = FROST_COLOR         # 减速
	elif is_wet:
		poly.color = wet_tint            # 潮湿
	elif is_special:
		poly.color = SPECIAL_COLOR       # 紫怪本体色
	else:
		poly.color = BASE_COLOR


##★★ v7 状态 UI 刷新（每帧调用）。
##  旧的 _refresh_status_label()（拼"💧 潮湿 3.0s"那种 Label）已删除。
## 现在每种状态独占一行 HBoxContainer：图标在左，纯数字倒计时在右。
##  ① 潮湿行：图标 + 纯数字，文字色强制 = RGB(76,140,255)
##  ② 冻结/减速合并成「冰霜行」（同属冰元素，分两行反而更乱）
##  ③ 燃烧行、④ 免疫行 —— 四行纵向排列，互不遮挡。
func _refresh_status_ui() -> void:
	if status_root == null:
		return
	if is_dead:
		status_root.visible = false
		return

	# ---- 潮湿行：图标 + 纯数字倒计时（颜色每帧强制定为 RGB(76,140,255)）----
	var show_wet := is_wet and _wet_time_left > 0.0
	wet_row.visible = show_wet
	if show_wet:
		wet_time.add_theme_color_override("font_color", WET_TIME_COLOR)
		wet_time.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
		wet_time.text = _fmt_seconds(_wet_time_left)

	# ---- 冰霜行：冻结优先显示冻结时长，否则显示减速时长 ----
	var show_frost := is_frozen or is_slowed
	frost_row.visible = show_frost
	if show_frost:
		frost_time.add_theme_color_override("font_color", FROST_TIME_COLOR)
		frost_time.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
		var ft := _frozen_time_left if is_frozen else _slow_time_left
		frost_time.text = _fmt_seconds(ft)

	# ---- 燃烧行 ----
	var show_burn := is_burning and _burn_time_left > 0.0
	burn_row.visible = show_burn
	if show_burn:
		burn_time.add_theme_color_override("font_color", BURN_TIME_COLOR)
		burn_time.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
		burn_time.text = _fmt_seconds(_burn_time_left)

	# ---- 免疫行 ----
	var show_immune := freeze_immunity > 0.0
	immune_row.visible = show_immune
	if show_immune:
		immune_time.add_theme_color_override("font_color", IMMUNE_TIME_COLOR)
		immune_time.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
		immune_time.text = _fmt_seconds(freeze_immunity)

	# 全部状态都没了 → 整个容器隐藏（图标和倒计时一起消失）
	status_root.visible = show_wet or show_frost or show_burn or show_immune


## 倒计时格式：纯数字 +单位，如 "3.0s"。
## < 10 秒保留一位小数，更长的就取整，避免 "12.34567s" 这种噪音。
func _fmt_seconds(t: float) -> String:
	var v := maxf(t, 0.0)
	if v < 10.0:
		return "%.1fs" % v
	return "%ds" % int(ceil(v))


## 兼容旧调用点：内部直接转调新的 _refresh_status_ui()。
func _refresh_status_label() -> void:
	_refresh_status_ui()


# --------------------------------------------------
func _die() -> void:
	if is_dead:
		return
	is_dead = true
	# 死亡时先摘掉状态提示，避免残留图标跟着飘一下才消失
	if status_root != null:
		status_root.visible = false
	if special_label != null:
		special_label.visible = false
	# ★ 血条也一并藏掉（尸体消散时留个空条很难看）
	_hide_hp_bar()

	# ★ v6 潮湿传染：必须在清状态【之前】做 —— 传染要用 is_wet 判断，
	#   也要在 remove_from_group【之前】做 —— 自己还属于 targets 组，
	#   传染逻辑靠 "t != self" 排除自己，但自己必须仍在组里才拿得到场景树。
	if is_wet:
		_spread_wet_on_death()

	# 全部状态清干净：万一还有未到期的 DOT，停手后 queue_free 之前不再结算
	_clear_wet()
	_clear_burn()
	_clear_slow()
	# 死亡时走"非自然解冻"：不给免疫、不触发冰爆
	_clear_frozen(false)
	freeze_immunity = 0.0
	# ★ v8：反应冷场期无需保留（对象即将销毁），显式清零保持状态干净
	_react_lock = 0.0

	# ★ 紫怪掉落金币：飘字 + 通知 GameManager 加钱
	if is_special and gold_reward > 0:
		_popup_text("获得金币 x%d！" % gold_reward, Color(1.0, 0.84, 0.25), 26)
		# GameManager 没有 class_name，用组查找（"game_manager"）
		var gm: Node = get_tree().get_first_node_in_group("game_manager")
		if gm != null and gm.has_method("add_gold"):
			gm.add_gold(gold_reward)
		else:
			push_warning("[Target] 找不到 GameManager，金币未发放")

	print("[Target] 被击破！奖励 ", reward, " 分", " 紫怪=", is_special)
	remove_from_group("targets")
	died.emit(self, reward)
	# 发完信号再销毁，避免在自己的信号回调里被引用
	queue_free()


## 刷新血量文字
## 血量文字。
## ⚠ 需求：靶子下方的「靶 186」太丑，已改为【默认不显示】。
## 节点保留但永久 hidden —— 万一以后要做「仅显示特殊状态」，
## 改这里就行，不会影响伤害飘字（DamageNumber）和血量扣除逻辑。
## ★ 播放音效的通用入口（AudioManager 是 Autoload 单例，统一判空）
func _sfx(method_name: String) -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method(method_name):
		am.call(method_name)


## ★ 刷新血条（替代原来的「靶 X」数字 Label）。
## 实现：Fill 的右边界往左收，宽度 =满血宽 × HP 比例。
## 例：HP 100/100 → 满宽；HP 20/100 → 只剩 20% 宽度。
func _refresh_hp_bar() -> void:
	if hp_bar_fill == null or max_hp <= 0.0:
		return
	var ratio := clampf(hp / max_hp, 0.0, 1.0)
	# Fill 的 anchor 是左上角（offset 控位置），所以改 offset_right 即可缩放
	hp_bar_fill.offset_right = hp_bar_fill.offset_left + HP_BAR_FULL_WIDTH * ratio
	# 血量越低越红，血量足偏绿——一眼能看出危险程度
	if ratio <= 0.25:
		hp_bar_fill.color = Color(0.95, 0.15, 0.18, 1.0)
	elif ratio <= 0.5:
		hp_bar_fill.color = Color(0.98, 0.65, 0.2, 1.0)
	else:
		hp_bar_fill.color = Color(0.35, 0.85, 0.45, 1.0)
	# 满血时血条没必要显示，省得画面杂乱
	if hp_bar_bg != null:
		hp_bar_bg.visible = ratio < 1.0


## 血量归零时把血条也藏掉（配合 _die 里的调用）
func _hide_hp_bar() -> void:
	if hp_bar_bg != null:
		hp_bar_bg.visible = false
	if hp_bar_fill != null:
		hp_bar_fill.visible = false