extends SceneTree
## Buff 系统验证：授予 / 三选一弹窗 / 暂停恢复 / 六种效果是否真的生效

var main: Node
var player: CharacterBody2D
var bm: Node
var gm: Node
var buff_ui: Node


func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	player = main.get_node("Player")
	bm = player.get_node("BuffManager")
	gm = main.get_node("GameManager")
	buff_ui = main.get_node("BuffUI")
	gm.prepare_time = 0.1
	# 移动靶时代的新坑：靶子撞到玩家会掉血，HP 归零会暂停游戏，
	# 暂停后 physics_frame 不再发射 → 测试永久挂起。这里拉满血 + 全程无敌。
	player.max_hp = 9999
	player.hp = 9999
	player.invuln_time = 9999.0
	player._invuln_left = 9999.0

	print("\n========== Buff 系统验证 ==========")
	var passed := 0
	var failed := 0

	# --- 1. 六种 Buff 都已定义 ---
	print("\n[1] Buff 定义完整性")
	var ids := ["rapid_charge", "power", "multishot", "fire", "frost", "pierce"]
	var all_defined := true
	for id in ids:
		var ok: bool = bm.get_display_name(id) != id
		if not ok: all_defined = false
		print("   ", "✅" if ok else "❌", " ", id, " → ", bm.get_display_name(id),
			" / ", bm.get_display_desc(id))
		if not ok: failed += 1
		else: passed += 1

	# --- 2. 各 Buff 的数值效果 ---
	print("\n[2] Buff 数值效果")

	# 攻速：蓄力时间应从 1.0 降到 0.75
	bm.add_buff("rapid_charge")
	var ct: float = bm.get_charge_time(1.0)
	print("   攻速×1 蓄力时间 = ", snapped(ct, 3), "s (期望 0.75)")
	if is_equal_approx(ct, 0.75): passed += 1; print("   ✅")
	else: failed += 1; print("   ❌")

	# 攻击：伤害倍率 1.4
	bm.add_buff("power")
	var dm: float = bm.get_damage_mult()
	print("   攻击×1 伤害倍率 = ", snapped(dm, 3), " (期望 1.4)")
	if absf(dm - 1.4) < 0.001: passed += 1; print("   ✅")
	else: failed += 1; print("   ❌")

	# 叠两层攻速应继续变快
	bm.add_buff("rapid_charge")
	var ct2: float = bm.get_charge_time(1.0)
	print("   攻速×2 蓄力时间 = ", snapped(ct2, 3), "s (期望 0.5625)")
	if absf(ct2 - 0.5625) < 0.01: passed += 1; print("   ✅")
	else: failed += 1; print("   ❌")

	# 清理，只测其余四项
	bm._buffs.clear()

	# 多重射击：2 支箭，单支伤害 ×0.75
	bm.add_buff("multishot")
	var cnt: int = bm.get_projectile_count()
	var dm2: float = bm.get_damage_mult()
	print("   多重射击 箭数 = ", cnt, " 伤害倍率 = ", snapped(dm2, 3))
	if cnt == 2 and absf(dm2 - 0.75) < 0.001: passed += 1; print("   ✅")
	else: failed += 1; print("   ❌")
	bm._buffs.clear()

	# --- 3. 三选一弹窗：暂停 → 选卡 → 恢复 ---
	print("\n[3] 三选一弹窗与暂停")
	var choices: Array = bm.roll_choices(3)
	print("   随机抽到 ", choices.size(), " 个: ", choices)
	if choices.size() == 3: passed += 1; print("   ✅ 数量为 3")
	else: failed += 1; print("   ❌")
	var uniq := {}
	# v4：roll_choices 返回 Dictionary 条目，去重按 id 来
	for c in choices: uniq[str(c.get("id", ""))] = true
	if uniq.size() == 3: passed += 1; print("   ✅ 选项不重复")
	else: failed += 1; print("   ❌ 有重复选项")

	buff_ui.open(choices)
	await process_frame
	print("   打开后 paused = ", paused, " visible = ", buff_ui.visible)
	if paused and buff_ui.visible: passed += 1; print("   ✅ 游戏已暂停且界面可见")
	else: failed += 1; print("   ❌")

	# 模拟玩家点击第一张卡
	# ⚠ v3：点击卡片 = 花金币升级，需要先给足金币才能成功生效
	var picked: String = str(choices[0].get("id", ""))
	print("   模拟点击: ", picked, "（先给 10 金币）")
	# 这个测试脚本继承 SceneTree（没有 get_tree()），
	# 且 root 是 Window 没有 get_first_node_in_group，
	# 所以从 buff_ui 自己的树往上找到 GameManager。
	var gm: Node = buff_ui.get_tree().get_first_node_in_group("game_manager")
	if gm != null:
		gm.gold = 10
	buff_ui._on_card_pressed(picked)
	await process_frame
	print("   点击后 paused = ", paused)
	if not paused and not buff_ui.visible: passed += 1; print("   ✅ 已恢复游戏")
	else: failed += 1; print("   ❌ 未恢复")

	if bm.count_of(picked) > 0: passed += 1; print("   ✅ Buff 已真正升级到玩家")
	else: failed += 1; print("   ❌ 未授予")

	# --- 4. 暂停期间游戏不推进 ---
	print("\n[4] 暂停时波次不推进")
	var wave_before: int = gm.wave
	buff_ui.open(bm.roll_choices(3))
	await create_timer(1.0).timeout
	if gm.wave == wave_before: passed += 1; print("   ✅ 波次保持在 ", gm.wave)
	else: failed += 1; print("   ❌ 波次偷偷推进了")
	buff_ui.close()
	await process_frame

	# --- 5. 六种效果实战验证 ---
	print("\n[5] 实战效果验证")
	bm._buffs.clear()

	# 多重射击 → 实际生成 2 支箭
	bm.add_buff("multishot")
	var n1: int = get_nodes_in_group("arrows").size()
	player._cooldown_left = 0.0
	player._fire(1.0)
	await process_frame
	var n2: int = get_nodes_in_group("arrows").size()
	print("   多重射击 箭矢数 ", n1, " → ", n2, " (期望 +2)")
	if n2 - n1 == 2: passed += 1; print("   ✅")
	else: failed += 1; print("   ❌")
	for a in get_nodes_in_group("arrows"): a.queue_free()
	bm._buffs.clear()

	# 火焰附魔 → 靶子应持续掉血
	bm.add_buff("fire")
	var t_scene: PackedScene = load("res://scenes/target.tscn")
	var t: CharacterBody2D = t_scene.instantiate()
	main.add_child(t)
	t.max_hp = 500.0
	t.patrol_speed = 0.0   # 固定靶，纯测附魔效果
	t.global_position = player.global_position + Vector2(260, 0)
	await process_frame
	t.hp = 500.0
	var hp0: float = t.hp
	player._cooldown_left = 0.0
	player.aim_pivot.rotation = 0.0
	player._fire(1.0)
	for i in 120:
		await physics_frame
	var hp1: float = t.hp
	print("   火焰附魔 血量 ", int(hp0), " → ", int(hp1))
	if hp1 < hp0: passed += 1; print("   ✅ 燃烧持续掉血生效")
	else: failed += 1; print("   ❌")
	t.queue_free()

	# 冰霜附魔 → 靶子应被减速
	bm._buffs.clear()
	bm.add_buff("frost")
	var t2: CharacterBody2D = t_scene.instantiate()
	main.add_child(t2)
	t2.max_hp = 500.0
	t2.patrol_speed = 0.0  # 固定靶
	t2.global_position = player.global_position + Vector2(260, 0)
	await process_frame
	t2.hp = 500.0
	player._cooldown_left = 0.0
	player.aim_pivot.rotation = 0.0
	player._fire(1.0)
	for i in 60:
		await physics_frame
	var slowed: float = t2._slow_factor
	print("   冰霜附魔 减速倍率 = ", slowed, " (期望 0.5)")
	if slowed < 1.0: passed += 1; print("   ✅ 减速生效")
	else: failed += 1; print("   ❌")
	t2.queue_free()

	# 穿透箭 → 应能穿过墙继续飞
	bm._buffs.clear()
	bm.add_buff("pierce")
	for a in get_nodes_in_group("arrows"): a.queue_free()
	# 把玩家放在墙左边，靶子放墙右边，中间是墙
	player.global_position = Vector2(160, 360)
	var t3: CharacterBody2D = t_scene.instantiate()
	main.add_child(t3)
	t3.max_hp = 500.0
	t3.patrol_speed = 0.0  # 固定靶，测穿墙
	t3.hp = 500.0
	t3.global_position = Vector2(300, 360)
	await physics_frame
	await physics_frame
	player._cooldown_left = 0.0
	player.aim_pivot.rotation = 0.0
	player._fire(1.0)
	for i in 150:
		await physics_frame
		if get_nodes_in_group("arrows").is_empty(): break
	print("   穿透箭 墙后靶子血量 = ", int(t3.hp), " (500=未穿透, 350左右=穿透成功)")
	if t3.hp < 500.0: passed += 1; print("   ✅ 穿墙命中后方靶子")
	else: failed += 1; print("   ❌ 被墙挡住")
	t3.queue_free()

	# --- 6. 无 Buff 时应保持原行为（回归检查）---
	print("\n[6] 无 Buff 时不受影响")
	bm._buffs.clear()
	if is_equal_approx(bm.get_charge_time(1.0), 1.0) \
			and bm.get_projectile_count() == 1 \
			and bm.get_damage_mult() == 1.0:
		passed += 1; print("   ✅ 蓄力1.0s / 1支箭 / 伤害x1.0")
	else: failed += 1; print("   ❌")

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()
