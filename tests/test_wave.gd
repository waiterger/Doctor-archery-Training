extends SceneTree
## 肉鸽循环自动测试：验证 波次推进 / 分数累加 / 难度递增 / 靶子清理 四条链路。
## 用法：godot --headless --path . --script res://tests/test_wave.gd

var main: Node
var gm: Node
var player: CharacterBody2D
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

	gm = main.get_node("GameManager")
	player = main.get_node("Player")
	# 移动靶时代的新坑：靶子碰到玩家扣血，HP 归零会暂停游戏，
	# 暂停后 create_timer 不再计时 → 下面所有 await 永久挂起。
	# 波次测试只关心波次逻辑，所以全程给玩家无敌 + 满血。
	player.max_hp = 9999
	player.hp = 9999
	player.invuln_time = 9999.0
	player._invuln_left = 9999.0
	print("\n========== 肉鸽循环测试 ==========")

	# --- 1. 准备阶段不应有靶子 ---
	_check("第 1 波已进入准备阶段", gm.wave == 1)
	_check("准备阶段场上无靶子(倒计时后才生成)", _targets().is_empty())

	# 等倒计时结束进入战斗，靶子此时才生成
	# 用「时间」而不是「帧数」等待：headless 下帧率极高，按帧数等会等不到
	await create_timer(gm.prepare_time + 0.3).timeout
	var targets := _targets()
	_check("进入战斗后生成 3 个靶子", targets.size() == 3)

	# 血量应等于 hp_base
	# 靶子现在是 CharacterBody2D（会巡逻移动），别再按 StaticBody2D 标注
	var t0: CharacterBody2D = targets[0]
	_check("靶子血量 = hp_base(60)", is_equal_approx(t0.hp, 60.0))

	# --- 2. 靶子位置应随机分散，不能重叠 ---
	# 注意：靶子现在是移动靶，会边生成边走。
	# 所以要立刻取位置，而且阈值从85 放宽到 70——
	# 生成时的 90 像素间距约束是在「静止瞬间」生效的，
	# 走开几帧后两个靶子可能又靠近了一点，这是正常的巡逻行为不是 bug。
	var min_dist := 99999.0
	for i in targets.size():
		for j in range(i + 1, targets.size()):
			var d: float = targets[i].position.distance_to(targets[j].position)
			min_dist = min(min_dist, d)
	print("  最近两个靶子间距 = ", snapped(min_dist, 1))
	_check("靶子没有重叠(间距 >= 70)", min_dist >= 70.0)

	_check("当前处于战斗阶段", gm.state == 1)

	# --- 4. 打掉所有靶子，应弹出 Buff 三选一并暂停 ---
	for t in _targets():
		t.take_damage(999.0, t.position)

	# 波次推进发生在 GameManager._process() 里，所以必须等它跑几帧
	var buff_ui: Node = main.get_node_or_null("BuffUI")
	for i in 20:
		await process_frame
		if buff_ui != null and buff_ui.visible:
			break
	_check("清空波次后弹出 Buff 三选一", buff_ui != null and buff_ui.visible)
	_check("弹窗期间游戏已暂停", paused)

	# 分数 = 靶子奖励 3×10 + 波次结算奖励 wave*5
	var reward_wave1 := 10
	_check("分数累加正确(3×10 + 1×5 = 35)", gm.score == 3 * reward_wave1 + 5)

	# 自动选第一张卡，模拟玩家点击
	var picked := ""
	if buff_ui != null:
		# 节点路径：Root(MarginContainer)/VBox/CardRow
		# （buff_ui v2 布局重构后已从 Panel/CardRow 迁移到容器结构）
		var row: Node = buff_ui.get_node("Root/VBox/CardRow")
		var cards := row.get_children()
		if cards.size() > 0:
			var btn: Button = cards[0]
			# 卡片第一行大字是 Buff 英文 id 首字母，反查不方便；直接触发 pressed
			picked = str(btn.get_meta("buff_id", ""))
			# ⚠ v3：点击卡片 = 花金币升级，先给足金币
			gm.gold = 10
			btn.emit_signal("pressed")
	await process_frame
	_check("选卡后恢复游戏", not paused)
	_check("选中后进入第 2 波准备阶段", gm.wave == 2)
	if picked != "":
		var bm: Node = player.get_node("BuffManager")
		_check("Buff 已生效（层数 ≥ 1）", bm.count_of(picked) >= 1)

	# --- 5. 难度递增：第 2 波应该血量更高、数量更多 ---
	# 第 2 波现在处于准备阶段，要等倒计时结束靶子才会生成
	await create_timer(gm.prepare_time + 0.3).timeout
	var t2 := _targets()
	print("  第2波 靶子数=", t2.size(), " 血量=", int(t2[0].hp))
	_check("第 2 波靶子血量提升(78)", is_equal_approx(t2[0].hp, 78.0))
	_check("第 2 波靶子数量增加到 4", t2.size() == 4)

	# --- 6. 再清一波，验证循环可持续 ---
	for t in _targets():
		t.take_damage(999.0, t.position)
	for i in 20:
		await process_frame
		if buff_ui != null and buff_ui.visible:
			break
	if buff_ui != null and buff_ui.visible:
		buff_ui._on_card_pressed("power")   # 直接走信号路径，跳过按钮
	await process_frame
	_check("继续推进到第 3 波", gm.wave == 3)
	print("  累计分数 = ", gm.score)

	# --- 7. 第 3 波靶子已生成，旧波次无残留泄漏 ---
	await create_timer(gm.prepare_time + 0.3).timeout
	# 注意：第 3 波起紫怪有 30% 概率刷出，所以这里只统计【普通靶子】，
	# 紫怪（金币怪）不参与数量断言（它是特性不是回归项）。
	var t3 := _targets()
	var normal3 := 0
	var normal_hp := 0.0
	for t in t3:
		if not t.is_special:
			normal3 += 1
			if normal_hp == 0.0:
				normal_hp = t.hp
	print("  第3波 靶子数=", t3.size(), "（其中普通 ", normal3,
		" 紫怪 ", t3.size() - normal3, "） 普通靶血量=", int(normal_hp))
	_check("第 3 波普通靶子数=5 血量=96",
		normal3 == 5 and is_equal_approx(normal_hp, 96.0))
	# 第 3 波数量 5，第 1 波 3 个 + 第 2 波 4 个 = 7，应全部销毁只剩 5
	_check("旧波次靶子无残留泄漏", normal3 == 5)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()


func _targets() -> Array:
	var arr: Array = []
	for n in get_nodes_in_group("targets"):
		arr.append(n)
	return arr


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)
