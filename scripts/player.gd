extends CharacterBody2D
## 玩家角色：移动 + 瞄准 + 射击（含蓄力）。
##
## 这一步新增的东西：
##  - 瞄准模式（按住左Shift）：移速降低、镜头拉近、瞄准线变长变明显
##  - 蓄力射击（按住左键/空格）：蓄满后松开发射，蓄力映射到箭速与伤害
##
## 注意解耦：玩家只负责「决定射什么」，箭矢自己负责「怎么飞、怎么死」。
## 玩家完全不知道箭矢内部怎么实现。

# ==================== 移动 ====================
@export var move_speed: float = 320.0      # 正常移动速度
@export var aim_speed_scale: float = 0.45   # 瞄准模式下的移速倍率
@export var charge_speed_scale: float = 0.7 # 蓄力时的移速倍率

## ★ 心流期间箭矢的金色（只做视觉反馈，不影响任何数值）
const FLOW_ARROW_TINT := Color(1.0, 0.84, 0.30, 0.9)

# ==================== 瞄准 ====================
@export var aim_length: float = 70.0        # 普通状态的瞄准线长度
@export var aim_length_focused: float = 110.0  # 瞄准状态（按住左 Shift）的瞄准线长度

# ==================== 镜头 ====================
@export var zoom_normal: float = 1.0        # 正常镜头缩放（1 = 原始大小）
@export var zoom_focused: float = 1.6       # 瞄准时拉近到 1.6 倍
@export var zoom_lerp_speed: float = 8.0    # 缩放平滑速度，越大越跟手
# 灵敏度基准值。实际跟手程度 = 设置里的灵敏度 × 这个系数 × delta。
# 设置为 1.0 时，设置里的 1.0 就是默认手感；调到 5.0 就是极跟手。
@export var sens_base_speed: float = 14.0

# ==================== 蓄力 ====================
@export var charge_time: float = 1.0        # 蓄满需要几秒
@export var min_charge_ratio: float = 0.15  # 低于这个比例松手 = 取消射击
@export var fire_cooldown: float = 0.25     # 两次射击最小间隔

# ==================== 箭矢参数 ====================
@export var arrow_scene: PackedScene         # 把 arrow.tscn 拖进来
@export var arrow_min_speed: float = 550.0  # 蓄力 0% 时的箭速
@export var arrow_max_speed: float = 1600.0 # 蓄力 100% 时的箭速
@export var damage_min: float = 8.0         # 蓄力 0% 时的伤害
@export var damage_max: float = 35.0        # 蓄力 100% 时的伤害
@export var muzzle_offset: float = 26.0     # 箭矢出生点离角色多远

# ---- Buff 相关参数 ----
@export var multishot_spread_deg: float = 6.0   # 多重射击的散射角度
@export var fire_dps_per_stack: float = 12.0   # 每层火焰附魔的每秒伤害
@export var fire_duration: float = 2.5         # 燃烧持续时间
@export var frost_slow_per_stack: float = 0.5   # 每层冰霜的减速倍率（0.5=半速）
@export var frost_duration: float = 1.5         # 减速持续时间
@export var freeze_duration_fallback: float = 1.5 # 冻结定身时间（BuffManager 不可用时的兜底）
@export var water_duration: float = 3.0# 潮湿持续时间（BuffManager 不可用时的兜底）

# ---- 场地边界（与 main.tscn 的 Borders 碰撞体一致，留出玩家半径余量）----
@export var arena_min: Vector2 = Vector2(20, 20)    # 玩家中心最小坐标
@export var arena_max: Vector2 = Vector2(1260, 700) # 玩家中心最大坐标

# ==================== 生命值 ====================
## 血量归零时发出，GameManager 监听它来结算失败
signal died()
@export var max_hp: int = 5# 几条命
@export var invuln_time: float = 0.8    # 受击后的无敌时间，防止被连续接触瞬间秒
@export var print_interval: float = 0.2     # 调试打印间隔（秒）

# ==================== 节点引用 ====================
@onready var aim_pivot: Node2D = $AimPivot
@onready var aim_line: Line2D = $AimPivot/AimLine
@onready var body_poly: Polygon2D = $BodyPoly
@onready var camera: Camera2D = $Camera2D
# ==================== 阿米娅护盾 ====================
## 护盾持续秒数
@export var shield_duration: float = 20.0
## 护盾冷却秒数
@export var shield_cooldown: float = 90.0
## 护盾光圈半径 / 线宽
@export var shield_radius: float = 30.0
@export var shield_thickness: float = 4.0

## ★ 护盾状态。纯布尔+计时器控制，
##⚠ 绝不用 Engine.time_scale 或强制暂停实现（会卡死顿帧和视频播放）。
var is_shielded: bool = false
var _shield_left: float = 0.0
var _shield_cd_left: float = 0.0
## 中键去重标志：事件回调和轮询可能在同一帧都命中，靠它保证只触发一次
var _shield_input_locked: bool = false

## 护盾状态变化（HUD 监听它刷新倒计时显示）
signal shield_changed(remaining: float, cooldown_left: float)
## 护盾成功格挡了一次伤害（外部可接音效/特效）
signal shield_blocked()
## 护盾【成功释放】。外部（main.gd）监听它来让阿米娅说台词——
## 无论技能是从 _unhandled_input 还是 _physics_process 轮询触发的，
## 这个信号都会发，台词不会漏。
signal shield_activated()

@onready var shield_ring: Polygon2D = $ShieldRing
@onready var shield_sfx: AudioStreamPlayer = $ShieldSFX
@onready var charge_bar: Control = $ChargeBar
@onready var buff_manager: Node = get_node_or_null("BuffManager")

# ==================== 运行状态 ====================
var hp: int = 5# 当前血量
var is_dead: bool = false
var _invuln_left: float = 0.0     # 无敌帧剩余时间
var _charge: float = 0.0            # 当前蓄力 0~1
var _is_charging: bool = false      # 是否正在蓄力
var _is_aiming: bool = false        # 是否处于瞄准模式（按住左 Shift）

## ★ 商店「永久攻击力提升」累加的伤害加成（百分比，如 0.15 = +15%）
var _damage_bonus: float = 0.0
var _cooldown_left: float = 0.0     # 冷却剩余时间
var _print_timer: float = 0.0
var print_bounds_warned: bool = false    # 边界兜底只警告一次，避免刷屏
var _aim_point: Vector2 = Vector2.ZERO  # 平滑后的瞄准点（灵敏度作用在这）
var _aim_point_ready: bool = false

# 蓄力曲线：指数 > 1 表示「后面充得慢」，射速和伤害都用它做映射。
# 1.0 = 线性。1.5 这种值让轻蓄力很弱、满蓄力很强，手感更有层次。
@export var charge_curve: float = 1.4


func _ready() -> void:
	# ⚠⚠ 显式设成 PAUSABLE（可暂停）：ESC 暂停时，本节点的
	# 所有计时器（护盾持续/冷却、射击冷却、无敌帧）必须静止。
	# 不依赖继承，万一父级被改成 ALWAYS 也不会出问题。
	process_mode = Node.PROCESS_MODE_PAUSABLE

	print("[Player] 出生！")
	hp = max_hp
	# 关键：加入 "player" 组，靶子靠这个组找到我并造成接触伤害
	add_to_group("player")
	# 启动时读一次设置，打印当前灵敏度（无Settings 单例时用默认 1.0）
	var sens := 1.0
	if has_node("/root/Settings"):
		sens = Settings.data.sensitivity
	print("  移速=", move_speed, " 瞄准移速倍率=", aim_speed_scale)
	print("  灵敏度=", snapped(sens, 0.01), "×  (基准系数 ", sens_base_speed, ")")
	print("  生命值=", max_hp, " 无敌时间=", invuln_time, "s")
	print("  镜头缩放 ", zoom_normal, " → ", zoom_focused)
	print("  蓄力时长=", charge_time, "s 取消阈值=", min_charge_ratio)
	print("  箭速 ", arrow_min_speed, " ~ ", arrow_max_speed)
	print("  伤害 ", damage_min, " ~ ", damage_max)

	if arrow_scene == null:
		print("  ⚠ 警告：arrow_scene 没有设置！请在检查器把 arrow.tscn 拖进 Player 的 Arrow Scene")
	else:
		print("  箭矢场景已就绪")

	camera.zoom = Vector2.ONE * zoom_normal
	_update_aim_line()


func _physics_process(delta: float) -> void:
	# ⚠⚠ 暂停时【冻结所有计时器】。
	# process_mode 已设为 PAUSABLE，但为了绝对可靠（Autoload/场景切换等
	# 边界情况可能让回调仍然收到 delta），这里再加一道显式守卫。
	# 效果：ESC 暂停后，护盾持续、护盾冷却、射击冷却、无敌帧
	# 全都静止，恢复游戏后才继续倒计时。
	if get_tree().paused:
		return

	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	_invuln_left = maxf(_invuln_left - delta, 0.0)

	_update_aim_mode()
	_handle_move()
	_handle_aim(delta)
	_handle_charge(delta)
	_update_camera(delta)
	_tick_shield(delta)
	_poll_shield_input()#★ 轮询兜底（见_poll_shield_input 注释）
	# 去重锁每帧末尾释放，保证下次按下还能触发
	_shield_input_locked = false
	_debug_print(delta)


## ★ 中键轮询兜底。
## 为什么需要两条路：
##   _unhandled_input 依赖 Godot 的事件传播链，一旦某个全屏 UI 或
##   别的节点把事件标记为 handled，这个回调就收不到（之前中键按了没反应
##   就是这种情况）。而 Input.is_action_just_pressed() 走的是引擎的
##   动作系统，不受 UI 拦截影响，在 _physics_process 里轮询最可靠。
## 两条路的去重靠 _shield_input_locked，避免一次按下触发两次。
## ★★ 护盾支持【两种绑定】（见 project.godot 的 amiya_shield 动作）：
##     鼠标中键  或  键盘 N
##
## ★ 重复触发防护（三重保险）：
##   1. _poll_shield_input 用 is_action_just_pressed —— 同一帧只 true 一次，
##      且鼠标 + N 键同时按也只是「一个 just_pressed」，不会触发两次
##   2. _shield_input_locked 每帧末释放，防止事件回调和轮询双路重复
##   3. activate_shield() 内部有 is_shielded / _shield_cd_left 判断，重复调用无效
## ★ 长按防抖：事件回调里有 not event.echo 判断，
##   系统 key repeat 产生的重复 Key 事件不会再次触发
func _poll_shield_input() -> void:
	if Input.is_action_just_pressed("amiya_shield"):
		# 事件回调已经处理过就跳过（同一帧只响应一次）
		if _shield_input_locked:
			return
		print("检测到护盾键按下！（中键 或 N）")
		_shield_input_locked = true
		activate_shield()


# --------------------------------------------------
# 生命值 / 受击
# --------------------------------------------------
## 被靶子碰到时调用（约定接口，和 take_damage 同名不同对象——靶子不认识玩家内部）
func take_damage(amount: int, from_pos: Vector2) -> void:
	if is_dead:
		return

	# ★★★ 护盾免疫：必须在【所有】伤害判定之前拦截。
	# 护盾期间免疫一切伤害（靶子撞击、箭矢等），
	# 但移动/蓄力/射击完全不受影响。
	# ⚠ 这里只做状态判断，绝不碰 Engine.time_scale 或 get_tree().paused ——
	#   那会连带卡死 HitStop 顿帧和 VideoStreamPlayer 复活视频。
	if is_shielded:
		_play_shield_block()
		return

	# 无敌帧内不重复扣血，否则站在靶子上会被瞬间秒
	if _invuln_left > 0.0:
		return

	hp -= amount
	_invuln_left = invuln_time
	_flash_hurt()
	# ★ 玩家受伤音效
	_sfx("play_hurt")
	print("[Player] 受到 ", amount, " 点伤害 → 剩余 HP ", hp)

	# 轻微击退，给玩家「被撞了」的物理反馈
	var knock := (global_position - from_pos).normalized() * 140.0
	velocity = knock

	if hp <= 0:
		hp = 0
		_die()


## 血量归零
func _die() -> void:
	if is_dead:
		return
	is_dead = true
	# 玩家不再响应输入，交给 GameManager 弹结算面板
	set_physics_process(false)
	print("[Player] 💀 HP 归零，游戏结束")
	died.emit()


## 受击闪红，无敌帧结束后恢复
func _flash_hurt() -> void:
	if body_poly == null:
		return
	body_poly.color = Color(1.0, 0.3, 0.3, 1.0)
	var tw := create_tween()
	tw.tween_property(body_poly, "color", Color(1, 1, 1, 1), 0.25)


## 给 HUD 用的公开接口
func get_hp() -> int:
	return hp


func get_max_hp() -> int:
	return max_hp


func is_invulnerable() -> bool:
	return _invuln_left > 0.0


# ==================== 阿米娅护盾 ====================
## 释放护盾（鼠标中键）。返回是否成功。
func activate_shield() -> bool:
	if is_dead:
		return false
	if is_shielded:
		print("[Player] ⚠ 护盾已生效，无法重复释放")
		return false
	if _shield_cd_left > 0.0:
		print("[Player] ⚠ 护盾冷却中，还剩 ", snapped(_shield_cd_left, 1), "s")
		return false

	is_shielded = true
	_shield_left = shield_duration
	_shield_cd_left = shield_cooldown     # 释放瞬间就进入冷却
	_draw_shield_ring()
	play_shield_sound()
	# ★ 阿米娅护盾台词「我知道了」
	_sfx("play_shield_voice")
	print("[Player] 🛡 阿米娅护盾启动！持续 ", shield_duration,
		"s  冷却 ", shield_cooldown, "s")
	shield_changed.emit(_shield_left, _shield_cd_left)
	shield_activated.emit()
	return true


## 每帧推进护盾计时
func _tick_shield(delta: float) -> void:
	# ⚠ 暂停时绝不能推进任何计时（双保险：_physics_process 里已有一道，
	# 这里再加一道，防止将来被别的路径直接调用）
	if get_tree().paused:
		return

	# 冷却倒计时
	if _shield_cd_left > 0.0:
		_shield_cd_left = maxf(_shield_cd_left - delta, 0.0)

	# 持续倒计时
	if not is_shielded:
		if _shield_cd_left > 0.0:
			shield_changed.emit(0.0, _shield_cd_left)
		return

	_shield_left -= delta
	if _shield_left <= 0.0:
		is_shielded = false
		_shield_left = 0.0
		_hide_shield_ring()
		print("[Player] 🛡 护盾结束")
	shield_changed.emit(_shield_left, _shield_cd_left)


## 用 Polygon2D 画一圈蓝色光环（32 边形，代码生成不依赖美术资源）
func _draw_shield_ring() -> void:
	if shield_ring == null:
		return
	var pts := PackedVector2Array()
	var segments := 32
	for i in segments:
		var ang := TAU * float(i) / float(segments)
		pts.append(Vector2(cos(ang), sin(ang)) * shield_radius)
	shield_ring.polygon = pts
	shield_ring.visible = true
	# 轻微脉动，让玩家知道护盾"活着"
	shield_ring.modulate = Color(0.45, 0.8, 1.0, 0.6)
	shield_ring.scale = Vector2.ONE


func _hide_shield_ring() -> void:
	if shield_ring != null:
		shield_ring.visible = false
		shield_ring.modulate = Color(1, 1, 1, 1)


## 护盾格挡时的视觉反馈：光圈闪一下
func _play_shield_block() -> void:
	if shield_ring != null and shield_ring.visible:
		shield_ring.modulate = Color(0.9, 1.0, 1.0, 0.95)
		shield_ring.scale = Vector2.ONE * 1.18
		# 用 tween 弹回，不改time_scale
		var tw := create_tween()
		tw.tween_property(shield_ring, "scale", Vector2.ONE, 0.18)\
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(shield_ring, "modulate",
			Color(0.45, 0.8, 1.0, 0.6), 0.22)
	print("[Player] 🛡 护盾格挡了一次伤害")
	shield_blocked.emit()


## ★ 音频预留接口。
## player.tscn 里已放好 ShieldSFX 节点（AudioStreamPlayer，默认没挂音频文件）。
## 之后只要在 Godot 里选中该节点，把音效拖进 Stream 槽位即可，无需改代码。
## 没挂文件时 play() 是安全的空操作，不会报错。
func play_shield_sound() -> void:
	if shield_sfx == null:
		return
	if shield_sfx.stream == null:
		print("[Player] 🔇 ShieldSFX 未挂载音频文件（预留接口，跳过播放）")
		return
	shield_sfx.play()


## 给 HUD 用的状态文本
func shield_status_text() -> String:
	if is_shielded:
		return "阿米娅护盾：生效中（剩余 %.1f 秒）" % maxf(_shield_left, 0.0)
	if _shield_cd_left > 0.0:
		return "阿米娅护盾：冷却中（%.1f 秒）" % _shield_cd_left
	return "阿米娅护盾：就绪（按中键释放）"


## 护盾是否可用（给 HUD 决定要不要高亮）
func shield_ready() -> bool:
	return not is_shielded and _shield_cd_left <= 0.0


## 商店用：恢复生命。已满血时返回 false（不给白嫖）。
func heal(amount: int) -> bool:
	if is_dead:
		return false
	if hp >= max_hp:
		return false# 满血了，买不了
	var before := hp
	hp = mini(max_hp, hp + amount)
	print("[Player] ❤️ 回血 ", before, " → ", hp, "/", max_hp)
	return true


# ==================== 商店强化接口 ====================
## 【商店】恢复满血。返回是否真的回满了（已满血返回 false，防白嫖）。
func heal_full() -> bool:
	if is_dead:
		return false
	if hp >= max_hp:
		return false# 已满血，买它没意义
	var before := hp
	hp = max_hp
	print("[Player] ❤️💰 回满血 ", before, " → ", hp, "/", max_hp)
	return true


## 【商店】生命上限 +1，并回满血。永久变强。
## 返回是否成功。
func increase_max_hp(amount: int = 1) -> bool:
	if is_dead:
		return false
	max_hp += amount
	hp = max_hp# 顺带回满，避免上限加了但残血
	print("[Player] 💪 生命上限 +", amount, " → ", max_hp, "（已回满血）")
	return true


## 【商店】永久伤害加成（百分比叠加）。
## 与伤害区间的乘算见_damage_mult()。
func add_damage_bonus(percent: float) -> void:
	_damage_bonus += percent
	print("[Player] ⚔ 伤害加成 +", int(percent * 100), "%  累计 ",
		int(_damage_bonus * 100), "%")


## 【商店】护盾冷却缩减（秒）。
## shield_cooldown 不能低于 20 秒，避免玩家把护盾玩成 CD 5 秒的无脑技能。
func reduce_shield_cooldown(seconds: float) -> bool:
	var new_cd := maxf(shield_cooldown - seconds, 20.0)
	if is_equal_approx(new_cd, shield_cooldown):
		return false# 已经到底了，买它无效
	shield_cooldown = new_cd
	# 已经在冷却中的话，同步把剩余时间压下来，否则玩家感觉不到变化
	_shield_cd_left = minf(_shield_cd_left, shield_cooldown)
	print("[Player] 🛡 护盾冷却 →", int(shield_cooldown), "s")
	return true


## 当前护盾冷却上限（商店显示用）
func get_shield_cooldown() -> float:
	return shield_cooldown


## 当前累计伤害加成（商店显示用）
func get_damage_bonus() -> float:
	return _damage_bonus


## 单箭伤害倍率（Buff 加成 × 商店加成）
func _damage_mult() -> float:
	var m := 1.0
	if buff_manager != null:
		m = buff_manager.get_damage_mult()
	return m * (1.0 + _damage_bonus)


## 复活用：血量回满 + 解除死亡状态 + 短时间无敌保护。
## 不发 died 信号，也不移动位置。
func revive_full() -> void:
	hp = max_hp
	is_dead = false
	# 给 2 秒无敌，免得复活瞬间又碰到旁边的靶子被秒
	_invuln_left = maxf(_invuln_left, 2.0)
	# 护盾状态清干净：不复活带着护盾，免得玩家看到没触发的技能却在生效
	is_shielded = false
	_shield_left = 0.0
	_hide_shield_ring()
	print("[Player] ♻ 复活！血量恢复 ", hp, "/", max_hp)


# --------------------------------------------------
# 瞄准模式检测
# --------------------------------------------------
## 心流单例（Flow）。不存在时返回 null，所有调用都做了判空。
func _get_flow() -> Node:
	var tree := get_tree()
	if tree == null or not tree.root.has_node("Flow"):
		return null
	return tree.root.get_node("Flow")


## 心流是否进行中
func _is_flow_active() -> bool:
	var f := _get_flow()
	return f != null and bool(f.call("is_active"))


func _update_aim_mode() -> void:
	# ⚠ 鼠标右键已废弃：原「瞄准」移到左 Shift，右键曾用于切元素、现改为空格。
	# 瞄准改为「按住左Shift」（见 project.godot 的 aim_mode 绑定），
	# 保留原有的移速减速 + 镜头拉近，作为可选的辅助瞄准。
	_is_aiming = Input.is_action_pressed("aim_mode")


# --------------------------------------------------
# 移动（受瞄准/蓄力状态影响）
# --------------------------------------------------
func _handle_move() -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")

	# 根据当前状态决定实际移速倍率：蓄力减速比瞄准减速更优先
	var scale := 1.0
	if _is_charging:
		scale = charge_speed_scale
	elif _is_aiming:
		scale = aim_speed_scale

	velocity = input_dir * move_speed * scale
	# 顺序很重要：先滑动（碰撞体把玩家挡回来），再夹紧兜底。
	# 如果先 clamp 再 move_and_slide，玩家会在两者的夹缝里被推出去一帧。
	move_and_slide()

	_clamp_to_arena()


# --------------------------------------------------
# 场地边界限制
# --------------------------------------------------
## 把玩家夹在场地范围内。
## 场地四周已经有不可见的边界碰撞体（见 main.tscn 的 Borders），
## 这里只是兜底，防止极端情况下漏出边界。
func _clamp_to_arena() -> void:
	var p := global_position
	p.x = clampf(p.x, arena_min.x, arena_max.x)
	p.y = clampf(p.y, arena_min.y, arena_max.y)
	# 只有真的越界才写回，避免每帧无谓赋值
	if p != global_position:
		global_position = p
		if not print_bounds_warned:
			print_bounds_warned = true
			print("[Player] ⚠ 触发边界兜底（撞击边界碰撞体时的正常现象）")


# --------------------------------------------------
# 瞄准 + 角色翻转
# --------------------------------------------------
func _handle_aim(delta: float) -> void:
	var mouse_pos := get_global_mouse_position()

	# ---- 灵敏度：把鼠标位置平滑成瞄准点，灵敏度越高追得越快 ----
	var sens: float = 1.0
	if has_node("/root/Settings"):
		var d: RefCounted = Settings.data
		sens = d.sensitivity

	if not _aim_point_ready:
		# 第一帧直接吸附，之后才做平滑，避免开局甩一下
		_aim_point = mouse_pos
		_aim_point_ready = true
	else:
		var t := clampf(sens_base_speed * sens * delta, 0.0, 1.0)
		_aim_point = _aim_point.lerp(mouse_pos, t)

	var aim_dir := _aim_point - global_position

	if aim_dir.length() < 1.0:
		return

	aim_pivot.rotation = aim_dir.angle()

	# 角色翻转：面朝左时把身体沿 X 轴镜像。
	# 用 -1 而不是 1，是因为 Polygon2D 默认不翻转，取负数即可镜像。
	# 只看 X 分量的符号来判断左右，Y 无需处理（俯视角没有上下之分）。
	var facing_left := aim_dir.x < 0.0
	body_poly.scale.x = -1.0 if facing_left else 1.0

	# 瞄准线长度随状态变化
	var target_len := aim_length_focused if (_is_aiming or _is_charging) else aim_length
	if not is_equal_approx(aim_line.points[1].x, target_len):
		_update_aim_line(target_len)


# --------------------------------------------------
# 蓄力与射击
# --------------------------------------------------
## ★★ 蓄力开火支持【两种绑定】（见 project.godot 的 shoot 动作）：
##     鼠标左键  或  键盘 M
##
## 两种方式【共用同一套蓄力/松手发射逻辑】，行为完全一致。
##
## ★ 为什么同时按不会出错 / 不会双发：
##   走的是 Input.is_action_pressed("shoot") —— Godot action 系统会把
##   该action 的所有绑定（鼠标 + M 键）汇总成【一个布尔值】，
##   按住任意一个都为 true，两个都按住也仍然只是 true（不会叠加）。
##   所以：
##     - 先按鼠标 → 蓄力；再补按 M  → 状态不变，不会二次开始蓄力
##     - 鼠标按住 + M 一起松开     → 只结算一次发射
##     - 长按 / 连发              → _charge 用 minf() 封顶 1.0，不会无限增长
func _handle_charge(delta: float) -> void:
	var want_charge := Input.is_action_pressed("shoot")

	# 实际蓄力时间受「迅捷之握」Buff 和「心流状态」影响
	var real_charge_time := charge_time
	if buff_manager != null:
		real_charge_time = buff_manager.get_charge_time(charge_time)
	# ⚠ 心流让蓄力时间减半（局部变量，不动 Engine.time_scale）
	var flow: Node = _get_flow()
	if flow != null:
		real_charge_time *= float(flow.call("charge_time_mult"))

	if want_charge and _cooldown_left <= 0.0:
		if not _is_charging:
			_is_charging = true
			_charge = 0.0
			print("[Player] 开始蓄力… 需要 ", snapped(real_charge_time, 2), "s")
		# 边蓄边检测：超过蓄满时间就锁定为 1.0，不会无限增长
		_charge = minf(_charge + delta / real_charge_time, 1.0)

	elif _is_charging and not want_charge:
		# 松开（鼠标左键 或 M 键 任一）→ 结算。
		# ⚠ 两个绑定必须【都松开】才会进来这里（is_action_pressed 对
		# 多绑定返回并集），所以不会出现"鼠标还按着 M 已松开就发射"。
		_is_charging = false
		var ratio := _charge
		_charge = 0.0

		if ratio < min_charge_ratio:
			print("[Player] 蓄力 ", int(ratio * 100), "% 低于阈值 ",
				int(min_charge_ratio * 100), "% → 取消射击")
		else:
			_fire(ratio)


## 真正发射一枚箭
##★ 播放音效的通用入口。AudioManager 是 Autoload 单例，
## 这里统一判空，避免各处直接写 get_node 出一堆重复代码。
func _sfx(method_name: String) -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method(method_name):
		am.call(method_name)


func _fire(ratio: float) -> void:
	if arrow_scene == null:
		print("[Player] ✗ 无法发射：arrow_scene 未设置")
		return
	if _cooldown_left > 0.0:
		print("[Player] ✗ 冷却中，剩余 ", snapped(_cooldown_left, 0.01), "s")
		return

	# ★ 箭矢破空声
	_sfx("play_shoot")

	# 用蓄力曲线把 0~1 映射成「实际强度」
	var strength := pow(clampf(ratio, 0.0, 1.0), charge_curve)
	var spd := lerpf(arrow_min_speed, arrow_max_speed, strength)

	# 读取Buff：伤害倍率和箭矢数量都受强化影响。
	# ⚠ 用 _damage_mult()，它同时包含 Buff 加成和商店的永久伤害加成。
	var dmg_mult: float = _damage_mult()
	var shot_count: int = 1 if buff_manager == null else buff_manager.get_projectile_count()
	var dmg: float = lerpf(damage_min, damage_max, strength) * dmg_mult

	# 发射方向：从角色指向鼠标
	var base_dir := Vector2.RIGHT.rotated(aim_pivot.rotation)

	# 多重射击：呈扇形散开，第一发正中，后面的略微偏转
	var spread_deg := multishot_spread_deg
	for i in shot_count:
		# 以第一发为轴，向两侧对称偏移
		var offset_idx := float(i) - float(shot_count - 1) * 0.5
		var ang := deg_to_rad(offset_idx * spread_deg)
		var dir := base_dir.rotated(ang)

		var arrow := arrow_scene.instantiate() as Area2D
		# 先加到场景树再设置 global_position，否则坐标会不对
		get_parent().add_child(arrow)

		# 出生点往前挪一点，避免箭矢立刻撞到自己
		var muzzle := global_position + dir * muzzle_offset
		arrow.global_position = muzzle
		arrow.setup(dir, dmg, ratio, self,
			_pierce_count(),
			_fire_dps(),
			_frost_slow(),
			_frost_time(),
			_water_time(),
			_fire_time(),
			_frost_freeze_time(),
			_frost_burst_damage(),
			_water_react_mult(),
			_water_spread_count(),
			_water_spread_radius())

		# ★ 心流期间箭矢染成金色（只改 modulate，不碰元素附魔逻辑）
		if _is_flow_active():
			arrow.modulate = FLOW_ARROW_TINT

	# 进入冷却
	_cooldown_left = fire_cooldown

	print("[Player] 发射 ×", shot_count, " 蓄力=", int(ratio * 100),
		"% 强度=", snapped(strength, 0.01),
		" 单箭伤害=", snapped(dmg, 0.1),
		" 箭速=", int(spd),
		" Buff倍率=", snapped(dmg_mult, 2))


# --------------------------------------------------
# Buff 数值读取（BuffManager 不存在时全部返回「无强化」默认值）
# --------------------------------------------------
func _pierce_count() -> int:
	return 0 if buff_manager == null else buff_manager.count_of("pierce")


func _fire_dps() -> float:
	# 只在「当前元素 = 火焰」时才附带燃烧
	if not _is_element_active("fire"):
		return 0.0
	# ★ v5：伤害曲线搬到 BuffManager.fire_burn_dps()（含 clamp 兜底）。
	# 这里不再做线性叠层，避免和曲线逻辑两处各算一份。
	if buff_manager != null and buff_manager.has_method("fire_burn_dps"):
		return buff_manager.fire_burn_dps()
	#兜底：BuffManager 不可用时退回旧的线性公式
	return fire_dps_per_stack * buff_manager.fire_stacks()


## ★ v5：燃烧持续时间（随火焰等级 3→4→5... 递增，封顶 8s）
func _fire_time() -> float:
	if not _is_element_active("fire"):
		return 0.0
	if buff_manager != null and buff_manager.has_method("fire_burn_duration"):
		return buff_manager.fire_burn_duration()
	return fire_duration


## ★ v6：冰霜减速倍率（速度 = 1 - 减速比例）。曲线在 BuffManager 里。
func _frost_slow() -> float:
	# 只在「当前元素 = 霜寒」时才附带减速
	if not _is_element_active("frost"):
		return 1.0
	if buff_manager != null and buff_manager.has_method("frost_slow_ratio"):
		return clampf(1.0 - buff_manager.frost_slow_ratio(), 0.15, 1.0)
	return 1.0 - (1.0 - frost_slow_per_stack) * buff_manager.frost_stacks()


## ★ v6：减速持续时间（Lv1 2s / Lv2 3s / Lv3 4s）
func _frost_time() -> float:
	if not _is_element_active("frost"):
		return 0.0
	if buff_manager != null and buff_manager.has_method("frost_slow_duration"):
		return buff_manager.frost_slow_duration()
	return frost_duration


## ★ v6：冻结定身时间（Lv1 1.5s / Lv2 2.5s / Lv3 3.5s / Lv4+ +0.5s 封顶 5s）
func _frost_freeze_time() -> float:
	if not _is_element_active("frost"):
		return 0.0
	if buff_manager != null and buff_manager.has_method("frost_freeze_time"):
		return buff_manager.frost_freeze_time()
	return freeze_duration_fallback


## ★ v6：冰爆伤害（Lv.3 起 >0），交给箭矢 → 靶子。
func _frost_burst_damage() -> float:
	if not _is_element_active("frost"):
		return 0.0
	if buff_manager != null and buff_manager.has_method("frost_burst_damage"):
		return buff_manager.frost_burst_damage()
	return 0.0


## 水元素潮湿时长。只有「当前元素 = 流水」且确实拿了流水附魔时才 > 0，
## 0 表示这支箭不带水（箭矢据此跳过 _apply_wet）。
## ★ v6：时长曲线搬到 BuffManager（Lv1 3s / Lv2 5s / Lv3 6s / Lv4+ +0.5s 封顶 10s）
func _water_time() -> float:
	if buff_manager == null or not _is_element_active("water"):
		return 0.0
	if buff_manager.water_stacks() <= 0:
		return 0.0
	if buff_manager.has_method("water_wet_duration"):
		return buff_manager.water_wet_duration()
	return water_duration


## ★ v6：反应伤害倍率（随水箭一起传，靶子用它放大蒸发/融化反应伤害）。
func _water_react_mult() -> float:
	if buff_manager == null or not _is_element_active("water"):
		return 1.0
	if buff_manager.has_method("water_react_mult"):
		return buff_manager.water_react_mult()
	return 1.0


## ★ v6：潮湿传染配置。0=不传染，1=随机1个，-1=范围内全部。
## 由水箭打在靶子身上时记录，靶子死亡时用来传染。
func _water_spread_count() -> int:
	if buff_manager == null or not _is_element_active("water"):
		return 0
	if buff_manager.has_method("water_spread_count"):
		return buff_manager.water_spread_count()
	return 0


func _water_spread_radius() -> float:
	if buff_manager == null or not _is_element_active("water"):
		return 0.0
	if buff_manager.has_method("water_spread_radius"):
		return buff_manager.water_spread_radius()
	return 0.0


## 某个元素是不是当前选中的附着元素。
## 这是解决「火焰和冰霜互相覆盖」的关键：同一支箭只带一种元素。
func _is_element_active(id: String) -> bool:
	if buff_manager == null:
		return false
	return buff_manager.get_element() == id


# --------------------------------------------------
# 镜头缩放
# --------------------------------------------------
func _update_camera(delta: float) -> void:
	var target_zoom := zoom_focused if _is_aiming else zoom_normal
	var goal := Vector2.ONE * target_zoom
	# lerp 让镜头缩放平滑过渡，不会突然一缩
	camera.zoom = camera.zoom.lerp(goal, clampf(zoom_lerp_speed * delta, 0.0, 1.0))


# --------------------------------------------------
# 给蓄力条调用的公开接口
# --------------------------------------------------
func get_charge_ratio() -> float:
	return _charge


func is_charging() -> bool:
	return _is_charging


# --------------------------------------------------
# 调试打印
# --------------------------------------------------
func _debug_print(delta: float) -> void:
	_print_timer += delta
	if _print_timer < print_interval:
		return
	_print_timer = 0.0

	var mode := "正常"
	if _is_charging:
		mode = "蓄力中"
	elif _is_aiming:
		mode = "瞄准中"

	print("[Player] 位置=", global_position.round(),
		" 速度=", velocity.round(),
		" 模式=", mode,
		" HP=", hp, "/", max_hp,
		("  [无敌中]" if _invuln_left > 0.0 else ""),
		" 镜头=", snapped(camera.zoom.x, 0.01), "x",
		" 冷却=", snapped(_cooldown_left, 0.01))

	if is_on_wall():
		print("       ⚠ 正在撞墙")


func _update_aim_line(length: float = -1.0) -> void:
	if aim_line == null:
		return
	var l := aim_length if length < 0.0 else length
	aim_line.points = PackedVector2Array([Vector2.ZERO, Vector2(l, 0)])
	# 瞄准时线加粗，更醒目
	aim_line.width = 5.0 if (_is_aiming or _is_charging) else 4.0


func _unhandled_input(event: InputEvent) -> void:
	# ★ 护盾键 = 鼠标中键 或 键盘 N（与 _poll_shield_input 双保险）
	# ⚠ echo 过滤：长按时系统 key repeat 会连续发 Key 事件，
	#   不加这个判断会反复调 activate_shield
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_MIDDLE \
			and event.pressed \
			and not event.echo:
		print("检测到护盾键按下！（中键 或 N）")
		_shield_input_locked = true
		activate_shield()
		return
	if event is InputEventKey \
			and event.keycode == KEY_N \
			and event.pressed \
			and not event.echo:
		print("检测到护盾键按下！（中键 或 N）")
		_shield_input_locked = true
		activate_shield()
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		print("=== 状态总结 ===")
		print("  位置: ", global_position)
		print("  速度: ", velocity)
		print("  瞄准角: ", snapped(rad_to_deg(aim_pivot.rotation), 0.1), "°")
		print("  瞄准模式: ", _is_aiming, "  蓄力中: ", _is_charging, "  蓄力值: ", snapped(_charge, 0.01))
		print("  镜头缩放: ", snapped(camera.zoom.x, 0.01))
		print("  冷却剩余: ", snapped(_cooldown_left, 0.01))
		print("  在墙上: ", is_on_wall())
