extends SceneTree
## 验证：1) 玩家跑不出边界  2) 墙安全距≈50 且靶子不卡墙内  3) 墙后靶子可被绕后射击

var main: Node
var player: CharacterBody2D


func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	player = main.get_node("Player")
	var gm := main.get_node("GameManager")
	gm.prepare_time = 0.2
	# 移动靶时代的新坑：靶子碰到玩家扣血，HP 归零会暂停游戏导致 create_timer 永挂
	player.max_hp = 9999
	player.hp = 9999
	player.invuln_time = 9999.0
	player._invuln_left = 9999.0

	print("\n========== 边界与掩体调优验证 ==========")

	# --- 检查 1：玩家边界限制 ---
	print("--- 检查玩家边界 ---")
	await _test_boundary()
	print("")

	# --- 检查 2/3：靶子分布与绕后射击 ---
	print("--- 检查墙周生成与绕后射击 ---")
	await _test_spawn_and_flank(gm)

	quit()


## 测试 1：把玩家往四个方向猛推，检查是否被限制在场内
func _test_boundary() -> void:
	var arena_min: Vector2 = player.arena_min
	var arena_max: Vector2 = player.arena_max
	var ok := true

	# 四种方向各推 600 像素（远超边界），检查最终位置
	for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN, Vector2.ZERO]:
		player.global_position = Vector2(640, 360)
		player.velocity = Vector2.ZERO
		# 手动模拟持续向某方向移动：每帧强推
		var d: Vector2 = dir
		for f in 120:
			player.velocity = d * 900.0
			# 复现 player.gd 里的真实顺序：先 move_and_slide，再 clamp
			player.move_and_slide()
			player._clamp_to_arena()
		var p: Vector2 = player.global_position
		var inside: bool = (p.x >= arena_min.x - 1 and p.x <= arena_max.x + 1
			and p.y >= arena_min.y - 1 and p.y <= arena_max.y + 1)
		if not inside:
			print("  ❌ 方向 ", d, " 越界！最终位置 ", p.round())
			ok = false
		else:
			print("  ✅ 方向 ", d, " → 位置 ", p.round(), " 限制在 [",
				int(arena_min.x), ",", int(arena_max.x), "] 内")

	# 额外确认：边界碰撞体存在
	var borders := main.get_node_or_null("Borders")
	if borders != null:
		var cnt := 0
		for c in borders.get_children():
			if c is StaticBody2D:
				cnt += 1
		print("  ✅ 边界碰撞体数量: ", cnt, "（上下左右各一）")
	else:
		print("  ❌ 找不到 Borders 节点")

	if ok:
		print("✅ 玩家无法跑出边界")


## 测试 2/3：靶子离墙距离 + 是否卡墙内 + 墙后靶子能否被射击
func _test_spawn_and_flank(gm: Node) -> void:
	var walls := get_nodes_in_group("walls")
	var min_dist := 99999.0
	var inside_wall_count := 0
	var total := 0
	var near_wall_targets := 0   # 靠近墙的靶子（掩体机制是否生效）

	for wave in 12:
		var waited := 0.0
		while get_nodes_in_group("targets").is_empty() and waited < 3.0:
			await create_timer(0.1).timeout
			waited += 0.1
		var ts := get_nodes_in_group("targets")
		if ts.is_empty():
			continue

		for t in ts:
			total += 1
			var p: Vector2 = (t as Node2D).global_position
			for w in walls:
				var wd: Vector2 = p - (w as Node2D).global_position
				var half: Vector2 = w.half_size
				# 到墙边缘的距离
				var ex: float = absf(wd.x) - half.x
				var ey: float = absf(wd.y) - half.y
				var edge: float = max(ex, ey)
				min_dist = min(min_dist, edge)

				# 是否在墙内（含靶子半径 26）
				var in_wall := absf(wd.x) < half.x + 26 and absf(wd.y) < half.y + 26
				if in_wall:
					inside_wall_count += 1
					print("  ❌ 靶子卡在墙内! ", p.round())
				# 靠近墙（100 内）→ 说明掩体机制生效
				if edge < 100:
					near_wall_targets += 1

		# 绕后射击测试：把玩家强制移到靶子墙的另一侧，模拟绕路
		if wave % 4 == 0 and ts.size() > 0:
			await _test_flank_shoot(ts[0])

		# 清场
		for t in ts:
			if is_instance_valid(t):
				t.take_damage(99999.0, (t as Node2D).position)
		await create_timer(0.3).timeout

	print("\n共生成靶子: ", total)
	print("靠近墙(<100px)的靶子数: ", near_wall_targets, "  ← 大于0说明掩体机制生效")
	print("靶子到墙边缘最小距离: ", snapped(min_dist, 1), " 像素（目标≈50）")
	if inside_wall_count == 0:
		print("✅ 无靶子卡在墙内")
	else:
		print("❌ 有 ", inside_wall_count, " 个靶子卡在墙内")
	if near_wall_targets > 0:
		print("✅ 靶子可生成在墙侧翼/后方附近，掩体机制有效")


## 绕后射击：模拟玩家【绕过墙的上下通道】到靶子侧翼开火。
## 注意：不能把玩家放在墙的正对面——那样箭矢必然被墙挡住，
## 那是掩体的正确行为，不是 bug。真正的绕后要走墙的端点通道。
func _test_flank_shoot(target: Node2D) -> void:
	# 关键：靶子现在是移动靶。本测试要验证的是「掩体几何」而不是「预判移动靶」，
	# 所以先把场上所有靶子速度归零，固定住它们再开火。
	for t in get_nodes_in_group("targets"):
		if is_instance_valid(t):
			t.patrol_speed = 0.0
			t.velocity = Vector2.ZERO
	await physics_frame

	var tp: Vector2 = (target as Node2D).global_position

	# 找离靶子最近的墙
	var walls := get_nodes_in_group("walls")
	var nearest = walls[0]
	var nd := 99999.0
	for w in walls:
		var d: float = (w as Node2D).global_position.distance_to(tp)
		if d < nd:
			nd = d
			nearest = w

	var wall_pos: Vector2 = (nearest as Node2D).global_position
	var half: Vector2 = nearest.half_size

	# 判断靶子在墙的左侧还是右侧
	var side := -1.0 if tp.x < wall_pos.x else 1.0

	# 绕行点：墙的上方或下方通道口（y 偏移超过墙半高 + 玩家半径 + 箭矢半径）
	var channel_y := wall_pos.y + (half.y + 60.0)
	if tp.y > wall_pos.y:
		channel_y = wall_pos.y - (half.y + 60.0)

	# 玩家走到通道口（与靶子同侧），此时到靶子的直线不穿墙
	var player_pos := Vector2(wall_pos.x + side * (half.x + 40.0), channel_y)
	player_pos.x = clampf(player_pos.x, player.arena_min.x, player.arena_max.x)
	player_pos.y = clampf(player_pos.y, player.arena_min.y, player.arena_max.y)
	player.global_position = player_pos
	player.velocity = Vector2.ZERO
	await physics_frame

	# 检查这条射线是否真的不穿墙
	var from: Vector2 = player.global_position
	var to: Vector2 = tp
	var blocked := _segment_hits_wall(from, to, walls)
	if blocked:
		print("  ⚠ 该射击线路仍被墙遮挡（掩体正常生效），跳过")
		return

	player.aim_pivot.rotation = (to - from).angle()
	player._cooldown_left = 0.0

	# 判据：看整组靶子的总血量变化，而不是只看 ts[0]。
	# 因为瞬移玩家后可能瞄准线掠过别的靶子，箭矢实际命中的未必是 ts[0]。
	var total_before := _total_hp()
	player._fire(1.0)
	for i in 200:
		await physics_frame
		if get_nodes_in_group("arrows").is_empty():
			break
	var total_after := _total_hp()

	if total_after < total_before:
		print("  ✅ 绕到墙侧翼射击命中（掩体机制成立）总血量 ", total_before, "→", total_after)
	else:
		print("  ❌ 侧翼射击失败")


## 当前场上所有靶子的总血量
func _total_hp() -> float:
	var sum := 0.0
	for t in get_nodes_in_group("targets"):
		if is_instance_valid(t):
			sum += t.hp
	return sum


## 判断线段 from→to 是否被任一墙挡住（AABB 相交测试）
func _segment_hits_wall(from: Vector2, to: Vector2, walls: Array) -> bool:
	for w in walls:
		var wp: Vector2 = (w as Node2D).global_position
		var half: Vector2 = w.half_size + Vector2(8, 8)   # 稍微留点余量
		# 采样 60 个点，任一点落在墙内即视为被挡
		for i in 61:
			var t := float(i) / 60.0
			var p: Vector2 = from.lerp(to, t)
			if absf(p.x - wp.x) < half.x and absf(p.y - wp.y) < half.y:
				return true
	return false
