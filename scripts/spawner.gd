extends Node2D
## 靶子生成器：在场地里随机撒靶子，并保证它们「一定能被打到」。
##
## 【核心约束】随机生成的游戏物件必须满足：
##   1. 在摄像机可见范围内（否则玩家看不到 → 打不到 → 波次卡死）
##   2. 不与墙体重叠、且离墙有足够距离（否则箭矢被墙挡住 → 波次卡死）
##
## 墙体数据直接向墙节点查询（墙加入 "walls" 组），
## 不再在 main.tscn 里手写坐标，避免改了墙忘了改生成器。

@export var target_scene: PackedScene        # 拖入 target.tscn
@export var min_targets: int = 3             # 每波最少几个
@export var max_targets: int = 6             # 每波最多几个

# ---- 特殊怪（金币怪）刷新规则----
## 紫怪血量/速度/存活等「本体属性」（与刷新频率无关）
@export var special_hp_mult: float = 0.8     # 紫怪血量 = 普通 × 0.8（少 20%）
@export var special_speed_mult: float = 1.2# 紫怪速度 = 普通 × 1.2（快 20%）
@export var special_lifetime: float = 10.0   # 紫怪存活秒数
@export var special_gold: int = 1# 击杀掉几枚金币

## ★ 固定间隔刷新（全部可在检查器微调）
## 从第几波开始刷紫怪
@export var special_start_wave: int = 4
## 每隔几波刷一次（4、6、8、10… 即interval=2）
@export var special_wave_interval: int = 2
## 每次刷几只
@export var special_spawn_count: int = 2

## 本局累计刷出的紫怪总数（仅用于调试/统计，不再作为上限）
var _special_spawned_count: int = 0

# ---- 安全区（靶子只在这个矩形内生成，必须完全在摄像机可见范围内）----
@export var safe_min: Vector2 = Vector2(90, 90)
@export var safe_max: Vector2 = Vector2(1190, 630)
@export var margin_from_player: float = 150.0   # 与玩家的最小距离
@export var min_spacing: float = 90.0          # 靶子之间的最小间距
@export var max_tries: int = 60                # 每个靶子最多尝试多少次
@export var fallback_radius: float = 220.0     # 全部尝试失败时的兜底半径

# ---- 墙体安全距离：题目要求 100 像素 ----
@export var wall_clearance: float = 100.0

@onready var player: Node2D = get_parent().get_node("Player")


func _ready() -> void:
	# 等墙的 _ready 跑完再自检
	await get_tree().process_frame
	print("[Spawner] 初始化  安全区=", safe_min, "~", safe_max,
		"  距墙至少=", wall_clearance, "  场上墙体数=", get_tree().get_nodes_in_group("walls").size())


## 生成本波靶子。血量/奖励必须在 add_child 之前设好
## （Target._ready() 会用 max_hp 初始化 hp）
## wave 用于判断本波是否刷紫怪。
func spawn_wave(count: int, hp: float, reward: int, wave: int = 0) -> Array[Node2D]:
	var created: Array[Node2D] = []
	print("[Spawner] 生成本波靶子 数量=", count, " 血量=", int(hp), " 奖励=", reward)

	# 先放普通靶子
	for i in count:
		var pos := _find_free_position(created)
		var t := target_scene.instantiate() as Node2D
		t.max_hp = hp
		t.reward = reward
		t.position = pos
		add_child(t)
		created.append(t)

	# ★ 金币怪：固定间隔波次刷 special_spawn_count 只。
	# 关键：每只紫怪生成时都把它传进 existing 传给_find_free_position，
	# 所以后面的紫怪会自动避开前面已生成的（普通+紫怪都不会重叠）。
	var sp_count := special_count_for_wave(wave)
	if sp_count > 0:
		for i in sp_count:
			var sp := _make_special(created, hp, reward)
			if sp != null:
				created.append(sp)

	print("[Spawner] 生成完毕 ", created.size(), " 个，全部合法=", _all_valid(created))
	return created


## 本波要不要刷紫怪：固定间隔，无概率、无全局上限。
## 规则：从 special_start_wave 起，每隔 special_wave_interval 波刷一次。
## 例：start=4, interval=2 → 第 4、6、8、10… 波必定刷新。
## 判定用减法取模而不是「记录上次刷过的波次」——
## 这样即使中间跳过某波（比如改参数重来）也不会卡死。
func _should_spawn_special(wave: int) -> bool:
	if wave < special_start_wave:
		return false
	var interval := maxi(special_wave_interval, 1)
	return (wave - special_start_wave) % interval == 0


## 本波要刷几只紫怪（不满足条件返回 0）
func special_count_for_wave(wave: int) -> int:
	if not _should_spawn_special(wave):
		return 0
	return maxi(special_spawn_count, 1)


## 本局累计刷出的紫怪总数（仅统计用）
func special_spawned() -> int:
	return _special_spawned_count


## 下一次刷紫怪的波次（HUD / 调试用）。已经过了起始波次就往后推算。
func next_special_wave(from_wave: int) -> int:
	var interval := maxi(special_wave_interval, 1)
	if from_wave < special_start_wave:
		return special_start_wave
	return from_wave + interval


## 手动重置本局紫怪计数。
## 正常情况下 Spawner 随场景重建自然归零，不需要调；留着备用。
func reset_special_count() -> void:
	_special_spawned_count = 0


## 造一只紫怪并加入场地
func _make_special(existing: Array[Node2D], base_hp: float, reward: int) -> Node2D:
	var pos := _find_free_position(existing)
	var t := target_scene.instantiate() as Node2D
	# ★ 必须在 add_child 之前设好：_ready() 会读这些值
	t.is_special = true
	t.max_hp = base_hp * special_hp_mult# 血量少 20%
	t.reward = reward                    # 分数不变，金币是额外掉落
	t.special_speed_mult = special_speed_mult
	t.special_lifetime = special_lifetime
	t.gold_reward = special_gold
	t.position = pos
	add_child(t)
	_special_spawned_count += 1
	print("[Spawner] 💎 刷出紫怪！ 血量=", int(base_hp * special_hp_mult),
		"（普通 ", int(base_hp), "） 存活 ", special_lifetime,
		"s  掉落 ", special_gold, " 金币  [本局累计第 ", _special_spawned_count, " 只]")
	return t


## 随机取点：必须在安全区内、离玩家够远、离墙 >= wall_clearance
func _find_free_position(existing: Array[Node2D]) -> Vector2:
	var center := player.global_position

	for try in max_tries:
		var candidate := Vector2(
			randf_range(safe_min.x, safe_max.x),
			randf_range(safe_min.y, safe_max.y))

		if not _is_valid_point(candidate, center, existing):
			continue

		return candidate

	# 兜底：在玩家附近找，clamp 进安全区 + 检查墙体
	print("[Spawner] ⚠ 尝试 ", max_tries, " 次未找到空位，使用兜底位置")
	for try in max_tries:
		var ang := randf() * TAU
		var p := center + Vector2.RIGHT.rotated(ang) * randf_range(120.0, fallback_radius)
		p.x = clampf(p.x, safe_min.x, safe_max.x)
		p.y = clampf(p.y, safe_min.y, safe_max.y)
		if _is_valid_point(p, center, existing):
			return p

	# 极端情况：直接返回场地中心（中心离墙最远）
	print("[Spawner] ⚠⚠ 连兜底都失败，返回场地中心")
	var mid := Vector2((safe_min.x + safe_max.x) * 0.5, (safe_min.y + safe_max.y) * 0.5)
	return mid


## 单点合法性检查（这是保证「一定能打到」的核心）
func _is_valid_point(p: Vector2, player_pos: Vector2, existing: Array[Node2D]) -> bool:
	# 1. 离玩家不能太近
	if p.distance_to(player_pos) < margin_from_player:
		return false

	# 2. 离墙必须 >= wall_clearance（题目要求 100 像素）
	if _too_close_to_any_wall(p):
		return false

	# 3. 靶子之间不能重叠
	for e in existing:
		if p.distance_to(e.position) < min_spacing:
			return false

	return true


## 查询所有墙：点是否落在任一墙的危险区内
func _too_close_to_any_wall(p: Vector2) -> bool:
	for w in get_tree().get_nodes_in_group("walls"):
		# 墙实现了 is_too_close()，直接问它，不关心具体尺寸
		if w.has_method("is_too_close") and w.is_too_close(p, wall_clearance):
			return true
	return false


## 自检：所有靶子是否都合法（打印用，出问题一眼看出来）
func _all_valid(list: Array[Node2D]) -> bool:
	for t in list:
		var p: Vector2 = t.position
		if p.x < safe_min.x or p.x > safe_max.x:
			return false
		if p.y < safe_min.y or p.y > safe_max.y:
			return false
		if _too_close_to_any_wall(p):
			return false
	return true


func roll_count() -> int:
	return randi_range(min_targets, max_targets)
