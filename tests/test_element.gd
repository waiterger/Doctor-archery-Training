extends SceneTree
## 元素切换专项测试：Q 键切换火焰/霜寒，单元素时 Q 无效，HUD 有文字提示

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
	print("\n========== 元素切换测试 ==========")

	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node2D = scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	var player: CharacterBody2D = main.get_node("Player")
	var bm: Node = player.get_node("BuffManager")
	var hud: CanvasLayer = main.get_node("HUD")
	var element_label: Label = hud.get_node("ElementLabel")

	# --- 1. 初始状态：没有任何元素 ---
	print("\n[1] 初始状态")
	_check("初始没有元素", bm.get_element() == "")
	_check("初始显示无元素", "无元素" in element_label.text)
	_check("初始不能切换", bm.can_switch_element() == false)

	# --- 2. 只有火焰：自动附着，Q 无效 ---
	print("\n[2] 只有火焰")
	bm.add_buff("fire")
	await process_frame
	_check("拿到火焰后自动附着", bm.get_element() == "fire")
	_check("显示文本是火焰", "火焰" in element_label.text)
	_check("只有一种不能切换", bm.can_switch_element() == false)
	_check("火焰时附带燃烧", player._fire_dps() > 0.0)
	_check("火焰时不带减速", is_equal_approx(player._frost_slow(), 1.0))

	var before: String = bm.get_element()
	bm.switch_element()
	await process_frame
	_check("单元素按 Q 无效果", bm.get_element() == before)
	_check("单元素时显示无切换提示", "Q 切换" not in element_label.text)

	# --- 3. 加上霜寒：现在可以切换了 ---
	print("\n[3] 加上霜寒 → 出现切换")
	bm.add_buff("frost")
	await process_frame
	_check("两种元素后可切换", bm.can_switch_element() == true)
	_check("自动选中第一个（火焰）", bm.get_element() == "fire")
	# HUD 去重：文案没变就不会重复设置。先切走再切回来，强制它刷新
	bm.switch_element()
	await process_frame
	bm.switch_element()
	await process_frame
	# 元素切换已从 Q 键改为【空格键】，HUD 提示文案同步改了
	_check("HUD 提示可以按空格切换", "空格 切换" in element_label.text)
	_check("此刻仍附着火焰", player._fire_dps() > 0.0)
	_check("此刻不带减速（互斥）", is_equal_approx(player._frost_slow(), 1.0))

	# --- 4. 按 Q 切到霜寒 ---
	print("\n[4] Q 切到霜寒")
	bm.switch_element()
	await process_frame
	_check("切换后是霜寒", bm.get_element() == "frost")
	_check("显示文本是霜寒", "霜寒" in element_label.text)
	_check("霜寒时带减速", player._frost_slow() < 1.0)
	_check("霜寒时不带燃烧（互斥）", is_equal_approx(player._fire_dps(), 0.0))

	# --- 5. 再按 Q 切回火焰（循环） ---
	print("\n[5] Q 切回火焰（循环）")
	bm.switch_element()
	await process_frame
	_check("切回火焰", bm.get_element() == "fire")
	bm.switch_element()
	await process_frame
	_check("再切一次回霜寒", bm.get_element() == "frost")
	_check("只有两种元素时循环不越界", bm.get_owned_elements().size() == 2)

	# --- 6. 信号 ---
	print("\n[6] 信号")
	_check("有 element_changed 信号", bm.has_signal("element_changed"))
	_check("有 element_switch_attempted 信号", bm.has_signal("element_switch_attempted"))

	var got: Array[String] = []
	bm.element_changed.connect(func(e: String) -> void: got.append(e))
	bm.switch_element()
	await process_frame
	_check("切换时发出 element_changed", got.size() >= 1)

	# lambda 捕获的是按值传递的副本，必须用数组或字典才能在外部观察改动
	var attempts: Array[int] = [0]
	bm.element_switch_attempted.connect(func() -> void: attempts[0] += 1)
	bm.switch_element()
	await process_frame
	_check("按 Q 时发出 attempted 信号", attempts[0] >= 1)

	# --- 7. HUD 颜色区分 ---
	print("\n[7] HUD 颜色")
	bm.switch_element()
	await process_frame
	var fire_text: String = element_label.text
	var fire_col: Color = element_label.modulate
	bm.switch_element()
	await process_frame
	var frost_text: String = element_label.text
	var frost_col: Color = element_label.modulate
	_check("两种元素文案不同", fire_text != frost_text)
	_check("两种元素颜色不同", not fire_col.is_equal_approx(frost_col))
	print("   ", fire_text, " / ", frost_text)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()
