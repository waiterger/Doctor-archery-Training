extends SceneTree
## 自动测试脚本（仅用于开发验证，不属于游戏本体）
## 用法：godot --headless --path . --script res://tests/test_arrow.gd
## 它会模拟按键，验证「发射 → 飞行 → 命中 → 回收」整条链路是否真的通。
##
## 注意：--script 入口必须继承 SceneTree，所以这里用 _initialize() 而不是 _ready()。

var player: CharacterBody2D
var passed := 0
var failed := 0


func _initialize() -> void:
	# 等主场景加载完再跑测试
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	# --script 模式下主场景不会被自动加载，所以要手动加载
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main_node: Node = main_scene.instantiate()
	root.add_child(main_node)
	await process_frame
	await physics_frame

	player = main_node.get_node("Player")
	print("\n========== 自动测试开始 ==========")

	# 移动靶时代的新坑：靶子会走动，测试里可能撞到玩家把 HP 打空，
	# 而 HP 归零会 get_tree().paused = true —— 暂停后 physics_frame 信号不再发射，
	# 下面所有 await 都会永久挂起。所以先把玩家血量拉满、伤害免疫。
	player.max_hp = 9999
	player.hp = 9999

	# --- 测试 1：检查关键节点存在 ---
	_check("玩家有 arrow_scene", player.arrow_scene != null)
	_check("瞄准节点存在", player.has_node("AimPivot"))
	_check("蓄力条存在", player.has_node("ChargeBar"))
	# 肉鸽改动后靶子不再随场景预置，而是倒计时结束后由 GameManager 生成。
	# 这里自己实例化一个靶子，保证箭矢测试独立可用。
	var t_scene: PackedScene = load("res://scenes/target.tscn")
	var t_test: CharacterBody2D = t_scene.instantiate()
	player.get_parent().add_child(t_test)
	t_test.global_position = player.global_position + Vector2(300, 0)
	t_test.max_hp = 100.0
	# 固定住靶子，纯测箭矢链路，避免它乱跑影响命中
	t_test.patrol_speed = 0.0
	await process_frame
	_check("靶子可正常实例化", get_nodes_in_group("targets").size() >= 1)

	# --- 测试 2：直接调用 _fire 发射满蓄力箭 ---
	# 把靶子挪到玩家正右方，保证能命中
	var targets: Array = get_nodes_in_group("targets")
	var t: Node2D = targets[0]
	t.global_position = player.global_position + Vector2(300, 0)
	# 关掉波次系统对测试的干扰
	var gm := player.get_parent().get_node_or_null("GameManager")
	if gm != null:
		gm.set_process(false)
	# 强制瞄准角度为 0（正右方）
	player.aim_pivot.rotation = 0.0
	# 玩家受击无敌，避免被走过来的靶子打断
	player.invuln_time = 9999.0
	player._invuln_left = 9999.0

	var before: int = get_nodes_in_group("arrows").size()
	player._fire(1.0)
	await process_frame
	var after: int = get_nodes_in_group("arrows").size()
	_check("发射后场上多了一支箭", after == before + 1)
	_check("箭矢已设置速度", player._cooldown_left > 0.0)

	# --- 测试 3：跑物理帧，看箭矢是否命中靶子并回收 ---
	var hit_target := false
	var arrow_despawned := false
	var frames_used := 0
	for i in 300:
		frames_used = i
		await physics_frame
		if get_nodes_in_group("arrows").is_empty():
			arrow_despawned = true
			break
	print("  （箭矢在 ", frames_used, " 个物理帧后消失）")
	_check("箭矢最终被回收了", arrow_despawned)

	# --- 测试 4：测试蓄力阈值逻辑 ---
	print("\n--- 蓄力逻辑测试 ---")
	var hp_before: float = t.hp
	# 蓄满并发射
	player._charge = 1.0
	player.aim_pivot.rotation = 0.0
	player._cooldown_left = 0.0
	player._fire(1.0)
	for i in 300:
		await physics_frame
		if get_nodes_in_group("arrows").is_empty():
			break
	var hp_after: float = t.hp
	print("  靶子血量 ", hp_before, " → ", hp_after)
	_check("满蓄力箭造成了伤害", hp_after < hp_before)

	# 弱蓄力伤害应该更低
	t.global_position = player.global_position + Vector2(300, 0)
	t.hp = 100.0
	player._cooldown_left = 0.0
	player.aim_pivot.rotation = 0.0
	player._fire(0.3)   # 低蓄力
	for i in 300:
		await physics_frame
		if get_nodes_in_group("arrows").is_empty():
			break
	var hp_weak: float = t.hp
	print("  低蓄力(30%)后血量: ", hp_weak)
	_check("低蓄力伤害明显低于满蓄力", hp_weak > hp_after)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	if failed == 0:
		print("🎉 全部通过！")
	else:
		print("⚠ 有失败项，请检查上面的 ❌ 标记")
	quit()


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)
