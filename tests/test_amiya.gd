extends SceneTree
## 阿米娅提示语测试：波次开始触发、随机抽取、2 秒后消失、不影响游戏逻辑

var passed: int = 0
var failed: int = 0


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)


func _init() -> void:
	await process_frame
	print("\n========== 阿米娅提示语测试 ==========")

	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node2D = scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	var amiya: Node = main.get_node_or_null("Amiya")
	var gm: Node = main.get_node("GameManager")
	var bubble: Control = amiya.get_node("Bubble")
	var line: Label = amiya.get_node("Bubble/VBox/Line")
	var speaker: Label = amiya.get_node("Bubble/VBox/Speaker")

	# 关键：把玩家设成无敌，不然被靶子碰到 HP 归零会切场景，
	# main 被释放、后续 await 全部永久挂起（这个坑踩过好几次了）
	var player: CharacterBody2D = main.get_node("Player")
	player.max_hp = 9999
	player.hp = 9999
	player.invuln_time = 9999.0
	player._invuln_left = 9999.0

	# --- 1. 节点与台词库 ---
	print("\n[1] 节点与台词库")
	_check("main 挂载了阿米娅节点", amiya != null)
	_check("气泡节点存在", bubble != null)
	_check("台词 Label 存在", line != null)
	_check("说话人标签是阿米娅", speaker.text == "阿米娅")
	_check("台词库非空", amiya.lines.size() > 0)
	_check("台词库至少 3 句", amiya.lines.size() >= 3)
	_check("初始气泡隐藏", not bubble.visible)

	# 位置：正中间偏上
	var bc: Vector2 = bubble.get_combined_minimum_size()
	print("   台词数=", amiya.lines.size(), " 显示时长=", amiya.display_time, "s")
	_check("显示时长是 2 秒", is_equal_approx(amiya.display_time, 2.0))

	# --- 2. speak() 能显示 ---
	print("\n[2] speak() 显示台词")
	amiya.speak()
	await process_frame
	_check("speak 后气泡可见", bubble.visible)
	_check("确实显示了台词", line.text != "" and line.text != "……")
	_check("台词在库里", line.text in amiya.lines)
	_check("正在显示中", amiya.is_showing())
	print("   「", line.text, "」")

	# --- 3. 随机性 ---
	print("\n[3] 随机抽取")
	var seen: Dictionary = {}
	for i in 40:
		amiya.speak()
		await process_frame
		seen[line.text] = true
	print("   40 次抽到 ", seen.size(), " 种不同台词")
	_check("多次抽取有变化（随机生效）", seen.size() >= 2)

	# 避免连续重复：把上一句的索引传给 speak()
	var prev: int = -1
	var same_count: int = 0
	for i in 30:
		amiya.speak(prev)
		await process_frame
		if amiya._last_index == prev:
			same_count += 1
		prev = amiya._last_index
	_check("不会连续抽到同一句", same_count == 0)

	# --- 4. 2 秒后自动消失 ---
	print("\n[4] 定时消失")
	amiya.speak()
	await process_frame
	_check("刚显示时可见", bubble.visible)
	# 走 2.4 秒（大于显示时长 2.0）
	amiya._process(2.4)
	await process_frame
	_check("2 秒后不再显示", not amiya.is_showing())

	# 分步验证：1 秒时还显示
	amiya.speak()
	await process_frame
	amiya._process(1.0)
	_check("1 秒时仍在显示（未到时间）", amiya.is_showing())
	amiya._process(1.2)
	_check("累计 2.2 秒后消失", not amiya.is_showing())

	# --- 5. 波次开始自动触发 ---
	print("\n[5] 波次开始触发")
	# 等到第 1 波正式开始（准备期 3 秒，用计时器等而不是帧数循环）
	await create_timer(3.6).timeout
	_check("已进入战斗状态", gm.state == gm.State.COMBAT)
	_check("波次开始时阿米娅开口了", amiya.is_showing() or line.text != "……")
	print("   第 ", gm.wave, " 波台词: 「", line.text, "」")

	# --- 6. 不影响核心逻辑 ---
	print("\n[6] 不影响核心逻辑")
	_check("波次管理器正常工作", gm.wave >= 1)
	_check("靶子正常生成", main.get_tree().get_nodes_in_group("targets").size() > 0)
	_check("玩家 HP 正常", player.hp > 0)

	# 关掉阿米娅后游戏照常跑
	amiya.visible = false
	amiya.speak()
	await process_frame
	_check("提示异常不会中断波次", gm.state == gm.State.COMBAT)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()
