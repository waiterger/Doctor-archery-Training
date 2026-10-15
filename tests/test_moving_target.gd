extends SceneTree
## 移动靶 + 玩家 HP + 失败结算 验证

var main: Node
var player: CharacterBody2D
var gm: Node
var over_ui: Node
var passed := 0
var failed := 0


func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	player = main.get_node("Player")
	gm = main.get_node("GameManager")

	print("\n========== 移动靶 + HP + 失败结算 ==========")

	# --- 1. 靶子节点类型与基础属性 ---
	print("\n[1] 靶子改造检查")
	_check("玩家 max_hp = 5", player.max_hp == 5)
	_check("玩家已加入 player 组", player.is_in_group("player"))

	var t_scene: PackedScene = load("res://scenes/target.tscn")
	var t: CharacterBody2D = t_scene.instantiate()
	main.add_child(t)
	t.global_position = Vector2(500, 560)   # 场地中央空旷处，远离墙
	t.patrol_speed = 100.0
	t._slow_factor = 1.0
	await physics_frame
	await physics_frame
	_check("靶子是 CharacterBody2D（能用 move_and_slide）", t is CharacterBody2D)
	_check("靶子巡逻速度 = 100", is_equal_approx(t.patrol_speed, 100.0))
	#关键：mask 必须是 0。靶子完全脱离物理系统，只靠数学算位置，
	# 这样结构上就不可能卡进墙里（上一版就是靠物理碰撞卡死的）。
	_check("靶子碰撞掩码 = 0（不参与物理，永不卡墙）", t.collision_mask == 0)

	# --- 2. 靶子做 2D 平面移动 ---
	print("\n[2] 靶子2D 平面移动")
	# 关掉随机转向，先测纯对角线直飞
	t.turn_min = 999.0
	t.turn_max = 999.0
	t._turn_timer = 999.0
	t._dir = Vector2(1, 1).normalized()   # 45° 斜向，不是纯水平
	var p0: Vector2 = t.global_position
	await create_timer(0.5).timeout
	var p1: Vector2 = t.global_position
	var dx: float = p1.x - p0.x
	var dy: float = p1.y - p0.y
	print("   0.5s 位移: dx=", snapped(dx, 1), " dy=", snapped(dy, 1))
	_check("X 轴有位移", absf(dx) > 10.0)
	_check("Y 轴也有位移（真·平面移动）", absf(dy) > 10.0)
	_check("斜向移动 X/Y 幅度接近", absf(absf(dx) - absf(dy)) < 12.0)
	# 方向单位向量（不因转向而变慢）
	_check("方向向量保持归一化", absf(t._dir.length() - 1.0) < 0.01)

	# --- 3. 随机转向让轨迹不那么直 ---
	print("\n[3] 随机转向")
	# 让靶子一直在中央空旷区跑，避免撞墙的 180° 翻转混进转向观测
	t.turn_min = 0.4
	t.turn_max = 0.6
	t.turn_jitter_deg = 70.0
	t._dir = Vector2.RIGHT
	t._turn_timer = 0.0      # 关键：重置倒计时，否则还停在 999，转向永远不会触发
	t.last_turn_deg = 0.0
	# 玩家挪到角落，别和被拉到中央的靶子撞上（掉血会让后面测试全乱）
	player.global_position = Vector2(60, 60)
	# 每次转向后立刻把靶子拉回中央，隔离掉碰撞反弹的干扰
	var turn_count := 0
	var max_turn_deg := 0.0
	for i in 900:
		await physics_frame
		if t.last_turn_deg > 0.0:
			max_turn_deg = maxf(max_turn_deg, t.last_turn_deg)
			turn_count += 1
			t.last_turn_deg = 0.0     # 归零，准备记录下一次
			t.global_position = Vector2(640, 360)
	print("   观测到 ", turn_count, " 次转向，单次最大偏转 = ", snapped(max_turn_deg, 1), "°")
	_check("随机转向确实触发了", turn_count > 3)
	_check("单次转向幅度不超 jitter 限制(≤70°)", max_turn_deg <= 70.0)
	_check("转向确实改变了方向", max_turn_deg > 1.0)
	_check("转向后仍然归一化", absf(t._dir.length() - 1.0) < 0.01)

	# --- 4. 撞墙前提前反向（分轴） ---
	print("\n[4] 撞墙提前反向（分轴反弹）")
	t.turn_min = 999.0
	t.turn_max = 999.0
	t._turn_timer = 999.0
	t._slow_factor = 1.0
	t._dir = Vector2.RIGHT     # 纯向右，朝左墙走
	t.global_position = Vector2(140, 500)
	# 墙在 x=220、半宽30，靶子半径30 + padding8 → 判定线在 x=182
	var wall_x: float = (get_nodes_in_group("walls")[0] as Node2D).global_position.x
	var hit_line: float = wall_x - (30.0 + t.wall_padding)
	# 只跑到「第一次反向」为止，避免观察窗口太长导致它又从边界弹回来
	var turned := false
	for i in 200:
		await physics_frame
		if t._dir.x < 0.0:
			turned = true
			break
	print("   位置=", t.global_position.round(), " 墙x=", int(wall_x),
		" 判定线x=", int(hit_line), " 方向=", t._dir.round())
	_check("到达墙前就提前反向（没贴到墙上）", turned)
	_check("反向点不越过判定线（提前刹车）", t.global_position.x <= hit_line + 2.0)
	_check("始终在墙的外侧", t.global_position.x < wall_x - t.target_radius)

	# 撞下边界：Godot Y 轴向下为正，「向下走」=+Y，反弹后向上 = _dir.y 为负
	t._dir = Vector2.DOWN
	t.global_position = Vector2(600, 680)
	await create_timer(1.5).timeout
	print("   撞下边界后 位置=", t.global_position.round(), " 方向=", t._dir.round())
	_check("撞下边界后 Y 分量反向（改为向上走）", t._dir.y < 0.0)
	_check("撞下边界后 X 分量保持不变", absf(t._dir.x) < 0.01)

	# --- 5. 【核心】长时间压力测试：绝不卡墙、绝不越界 ---
	print("\n[5] 卡墙压力测试（2000 帧）")
	t.turn_min = 0.3
	t.turn_max = 0.9
	var out_of_bounds := 0
	var in_wall_frames := 0
	var stuck_frames := 0
	var last: Vector2 = t.global_position
	for i in 2000:
		await physics_frame
		var p: Vector2 = t.global_position
		# 越界检查
		if p.x < 0.0 or p.x > 1280.0 or p.y < 0.0 or p.y > 720.0:
			out_of_bounds += 1
		# 卡墙检查：用墙体自己的膨胀矩形判断靶子中心是否落在墙里
		for w in get_nodes_in_group("walls"):
			if w.get_overlap_rect(t.target_radius * 0.9).has_point(p):
				in_wall_frames += 1
		if p.distance_to(last) < 0.05:
			stuck_frames += 1
		last = p
	print("   2000 帧中:越界=", out_of_bounds, " 卡在墙里=", in_wall_frames,
		" 几乎没动=", stuck_frames)
	_check("从不越界", out_of_bounds == 0)
	_check("从不卡在墙体里", in_wall_frames == 0)
	_check("不会卡住不动（每帧都有位移）", stuck_frames < 30)

	# 强制把靶子丢进墙体中心，验证脱困机制
	print("\n[5b] 强制丢进墙里，验证脱困")
	t._turn_timer = 999.0
	t.turn_min = 999.0
	t.turn_max = 999.0
	var wall0: Node2D = get_nodes_in_group("walls")[0]
	t.global_position = wall0.global_position      # 正中心，最坏情况
	t._dir = Vector2.RIGHT
	await physics_frame
	await physics_frame
	var escaped: bool = not wall0.get_overlap_rect(t.target_radius * 0.9).has_point(t.global_position)
	print("   丢进墙心后位置=", t.global_position.round(), " 已脱困=", escaped)
	_check("丢进墙里能自动脱困", escaped)

	# 从墙里出来后还能正常移动
	var before: Vector2 = t.global_position
	await create_timer(0.5).timeout
	_check("脱困后能恢复正常移动",
		t.global_position.distance_to(before) > 10.0)

	# --- 6. 冰霜减速真的有用 ---
	print("\n[6] 冰霜减速影响移动速度")
	t._slow_time_left = 0.0
	t._slow_factor = 1.0
	t.turn_min = 999.0
	t.turn_max = 999.0
	t._turn_timer = 999.0
	t._dir = Vector2.RIGHT
	t.global_position = Vector2(500, 560)
	await physics_frame
	var fast_v: float = t.velocity.length()
	# 等冰霜过期
	for i in 200:
		await physics_frame
		if t._slow_time_left <= 0.0:
			break
	t._apply_slow(0.2, 3.0)
	await physics_frame
	var slow_v: float = t.velocity.length()
	print("   正常速度 = ", snapped(fast_v, 1), "   冰冻速度 = ", snapped(slow_v, 1))
	_check("冰霜减速让靶子明显变慢", slow_v < fast_v * 0.5)
	_check("减速倍率符合 _slow_factor", absf(slow_v - 100.0 * 0.2) < 1.0)
	t.queue_free()

	# --- 7. 靶子碰到玩家扣血 ---
	print("\n[7] 接触伤害")
	for n in get_nodes_in_group("targets"):
		n.queue_free()
	await physics_frame

	player.hp = 5
	player.is_dead = false
	player._invuln_left = 0.0
	player.set_physics_process(true)
	player.global_position = Vector2(640, 360)

	# 手动造一个靶子，直接叠到玩家身上
	var t2: CharacterBody2D = t_scene.instantiate()
	main.add_child(t2)
	await physics_frame
	t2._player = player
	t2.touch_damage = 1
	t2.touch_cooldown = 0.0
	t2.global_position = Vector2(640, 360)   # 与玩家完全重合
	await physics_frame
	await physics_frame
	_check("靶子碰到玩家后玩家掉血", player.hp == 4)
	print("   玩家 HP = ", player.hp)

	# --- 6. 无敌帧 ---
	print("\n[8] 无敌帧保护")
	var hp_before: int = player.hp
	t2._touch_cd = 0.0
	t2.global_position = Vector2(640, 360)
	await physics_frame
	await physics_frame
	print("   HP ", hp_before, " → ", player.hp, "（无敌帧内应不变）")
	_check("无敌帧内不会连续掉血", player.hp == hp_before)

	# --- 7. HP 归零触发失败 ---
	print("\n[9a] HUD 血量显示")
	var hud: CanvasLayer = main.get_node("HUD")
	player.hp = 2
	gm._sync_player_hp()
	var hp_txt: String = hud.get_node("HpLabel").text
	print("HUD: ", hp_txt)
	_check("HUD 存在 HpLabel", hud.get_node_or_null("HpLabel") != null)
	_check("HUD 血量文本正确", hp_txt == "HP 2 / 5")

	print("\n[9] HP 归零 → 游戏结束")
	# 清掉场上靶子避免干扰
	t2.queue_free()
	for n in get_nodes_in_group("targets"):
		n.queue_free()
	await process_frame

	gm.score = 137
	player._invuln_left = 0.0
	player.take_damage(999, Vector2(640, 300))
	await process_frame

	_check("玩家 HP 归零", player.hp == 0)
	_check("玩家标记为死亡", player.is_dead)
	_check("GameManager 进入 GAME_OVER 状态", gm.state == gm.State.GAME_OVER)

	# 死亡后会切换到独立的 GameOver 场景
	for i in 10:
		await process_frame
	var go_scene: Node = root.get_node_or_null("GameOver")
	_check("已切换到 GameOver 场景", go_scene != null)
	_check("游戏已暂停", paused)

	# 结算面板上的数字
	var over_script: GDScript = load("res://scripts/game_over.gd")
	var score_val: int = over_script.get("last_score")
	var wave_val: int = over_script.get("last_wave")
	print("   结算: 得分=", score_val, " 波次=", wave_val)
	_check("结算数据已传入（得分）", score_val == 137)
	_check("结算数据已传入（波次）", wave_val >= 1)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)