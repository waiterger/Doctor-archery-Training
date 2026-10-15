extends Node2D
## 主场景：只负责组装各系统 + 打印总览。具体逻辑都在各自的脚本里。

@onready var player: CharacterBody2D = $Player
@onready var gm: Node = $GameManager
@onready var hud: CanvasLayer = $HUD
@onready var pause_menu: Control = $UILayer/PauseMenu
@onready var buff_manager: Node = player.get_node_or_null("BuffManager")

var _print_timer: float = 0.0
## 空格切元素的去重锁：_unhandled_input 与 _process 轮询可能在同一帧都命中，
## 靠它保证一次按键只切换一次
var _element_locked: bool = false


func _ready() -> void:
	print("[Main] ===== 弓箭训练场 · 肉鸽原型 =====")
	print("[Main] WASD 移动 | 左键 或 M 蓄力射击 | 空格 切元素 | Q 心流")
	print("[Main] N 或 中键 开护盾 | R 重开 | Esc 暂停 | F1 状态 F2 看 Buff")
	print("[Main]⚠ 靶子会左右巡逻，碰到你会扣血；HP 归零即结束")
	print("[Main] 玩家: ", player.name, " 波次管理器: ", gm.name)

	# ★ 战斗 BGM
	_play_fight_bgm()

	# ★★★ 本次场景重载的原因判定。
	#
	# ⚠⚠ 这里【只读标记，不做任何重置】。
	#   重置的唯一执行者是各「重新开始」入口（game_over / pause_menu /
	#   title_screen / R 键），它们在切场景【之前】就调好了。
	#   如果这里再 reset_run_data()，日志就会打印两次 —— 那是 bug。
	#
	# 先清GameOver 的静态复活标记（static var 跨场景永存，不清会导致
	# "重新开始后进结算界面显示复活不可用"）。
	var go_script: Variant = load("res://scripts/game_over.gd")
	if go_script != null and go_script.has_method("on_entered_game_scene"):
		go_script.on_entered_game_scene()

	var rs := _run_state_or_null()
	var reviving: bool = false
	if rs != null and rs.has_method("consume_reviving"):
		# consume 读标志位后立刻复位成 false，防下一次误判
		reviving = bool(rs.consume_reviving())

	if reviving:
		# ===== 【看视频复活】恢复本局进度 =====
		# 具体恢复在下面的 _restore_revive_data()（内部有 has_pending 保护）
		print("[Main] ↻ 本次为【复活重载】，将恢复本局进度")
	else:
		#===== 【重新开始 / 正常开局】=====
		# 各入口已经清过了，这里什么都不做，保持干净的新局。
		print("[Main] ✦ 本次为【重新开局】，数据已由入口重置，本处不再处理")

	# 元素附着切换：BuffManager 一变就刷新 HUD 上的文字提示
	if buff_manager != null:
		buff_manager.element_changed.connect(_on_element_changed)
		buff_manager.element_switch_attempted.connect(_refresh_element_hud)
		_refresh_element_hud()
	else:
		print("[Main] ⚠ 找不到 BuffManager，元素切换不可用")

	# 心流状态：让 HUD 实时显示冷却/剩余时间
	var flow := _get_flow()
	if flow != null and flow.has_signal("flow_changed"):
		flow.flow_changed.connect(_on_flow_changed)
		hud.update_flow(flow.call("status_text"), float(flow.call("cooldown_ratio")),
			bool(flow.call("is_active")))
		print("[Main] 已连接 Flow.flow_changed")

	# 护盾状态：HUD 显示冷却/剩余时间
	if player != null and player.has_signal("shield_changed"):
		player.shield_changed.connect(_on_shield_changed)
		hud.update_shield(player.call("shield_status_text"),
			bool(player.call("shield_ready")), bool(player.get("is_shielded")))
		# ★ 台词挂在「成功释放」信号上，不挂在中键事件上——
		# 这样无论技能走 _unhandled_input 还是 _physics_process 轮询，
		# 只要真的放出去了，阿米娅就一定会说话。
		if player.has_signal("shield_activated"):
			player.shield_activated.connect(_on_shield_activated)
			print("[Main] 已连接 Player.shield_activated")

	# 看视频复活：把上一局暂存的进度灌回来（没有暂存数据时什么都不做）
	_restore_revive_data()


## 心流状态变化 → 刷新 HUD
func _on_flow_changed(active: bool, cooldown_left: float) -> void:
	var flow := _get_flow()
	if flow == null:
		return
	hud.update_flow(flow.call("status_text"), float(flow.call("cooldown_ratio")), active)


## 护盾状态变化 → 刷新 HUD
func _on_shield_changed(remaining: float, cooldown_left: float) -> void:
	if player == null:
		return
	hud.update_shield(player.call("shield_status_text"),
		bool(player.call("shield_ready")), bool(player.get("is_shielded")))


## ★ 护盾成功释放 → 阿米娅说一句话
func _on_shield_activated() -> void:
	say_shield_line()


## 复活续局：读 RunState 里的暂存数据并应用，读完即清。
func _restore_revive_data() -> void:
	if not _has_run_state() or not _run_state_has_pending():
		return

	var data: Dictionary = _run_state_take()
	var buffs: Dictionary = data.get("buffs", {})
	var wave_v: int = int(data.get("wave", 0))
	var score_v: int = int(data.get("score", 0))
	var element_v: String = String(data.get("element", ""))
	var gold_v: int = int(data.get("gold", 0))
	var expanded_v: Dictionary = data.get("expanded", {})

	# ① 还原 Buff 等级（必须在 GameManager 推进波次前完成）
	if buff_manager != null and not buffs.is_empty():
		buff_manager.import_levels(buffs)
	# ② 还原扩容记录（要在 import_levels 之后，它依赖等级判断上限）
	if buff_manager != null and not expanded_v.is_empty():
		buff_manager.import_expanded(expanded_v)

	# ③ 玩家回满血
	player.revive_full()

	# ④ 还原波次、分数与金币
	gm.restore_from_stash(wave_v, score_v, gold_v)

	# ⑤ 元素提示刷新（Buff 变了，HUD 上挂的元素名也要跟着变）
	_refresh_element_hud()

	print("[Main] ♻ 复活续局完成：波次=", wave_v, " 分数=", score_v,
		" 金币=", gold_v, " Buff=", buffs, " 扩容=", expanded_v,
		" 元素=", element_v)


func _has_run_state() -> bool:
	return get_tree() != null and get_tree().root.has_node("RunState")


func _run_state_has_pending() -> bool:
	return bool(_run_state().call("has_pending"))


func _run_state_take() -> Dictionary:
	return _run_state().call("take")


func _run_state() -> Node:
	return get_tree().root.get_node("RunState")


## 把当前元素显示到 HUD
func _refresh_element_hud() -> void:
	if buff_manager == null or hud == null:
		return
	var eid: String = buff_manager.get_element()
	var has_switch: bool = buff_manager.can_switch_element()
	# 没元素时用中性灰，不要去查 BUFF_DEFS[""]（查不到会返回白）
	var col: Color = buff_manager.get_display_color(eid) if eid != "" \
		else Color(0.6, 0.62, 0.7, 1.0)
	hud.update_element(buff_manager.get_element_name(), col, has_switch)


func _on_element_changed(_element: String) -> void:
	_refresh_element_hud()
	# ★ 切换后立刻打印一次当前状态，方便确认 HUD 是否真的更新了
	print("[Main] HUD 元素显示 → 「", buff_manager.get_element_name(),
		"」 可切换=", buff_manager.can_switch_element())


func _process(delta: float) -> void:
	# ★ 空格切元素：轮询兜底。
	# 必须放在【函数最前面】，不能被下面的 2 秒节流挡住，
	# 否则按键响应会延迟最多 2 秒。
	# 用动作系统轮询，不受 UI 事件拦截影响。
	_poll_switch_element()

	_print_timer += delta
	if _print_timer < 2.0:
		return
	_print_timer = 0.0

	print("[Main] 第 ", gm.wave, " 波 | 分数 ", gm.score,
		" | HP ", player.hp, "/", player.max_hp,
		" | 场上靶子 ", get_tree().get_nodes_in_group("targets").size(),
		" | 场上箭矢 ", get_tree().get_nodes_in_group("arrows").size())


## 空格切元素的轮询兜底（与 _unhandled_input 双保险）
func _poll_switch_element() -> void:
	# ⚠⚠ 暂停时禁止切换元素
	if get_tree().paused or pause_menu.visible:
		return
	if _element_locked:
		_element_locked = false
		return
	if not Input.is_action_just_pressed("switch_element"):
		return
	_element_locked = true
	print("空格切元素触发！（轮询路径）")
	if buff_manager != null:
		buff_manager.switch_element()


func _unhandled_input(event: InputEvent) -> void:
	# ⚠⚠ 暂停时【禁止一切热键响应】。
	# 这条守卫同时也挡住了「暂停时切元素」——暂停菜单开着时按空格
	# 不应该切换元素。
	if get_tree().paused or pause_menu.visible:
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			# ESC 交给暂停菜单处理（它会开设置面板）
			pause_menu.open()
		elif event.keycode == KEY_R:
			_restart()

	# Q = 心流状态（用动作而非 keycode，避免和输入法冲突）
	if event.is_action_pressed("flow_state"):
		_try_flow()

	# ★★ 空格 = 切换元素（已从鼠标右键迁移过来）
	# 只用 Input Map 动作判断，不再有任何MOUSE_BUTTON_RIGHT 代码。
	if event.is_action_pressed("switch_element"):
		_element_locked = true
		print("空格切元素触发！")
		if buff_manager != null:
			buff_manager.switch_element()
		return

	# ★ 护盾键 = 鼠标中键 或 键盘 N（兜底路径）。
	# 真正的检测在 player.gd（事件回调 + 轮询双保险），
	# 这里只在 player 没接收到事件时补一次。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_MIDDLE \
			and not event.echo:
		if not bool(player.get("_shield_input_locked")):
			print("检测到护盾键按下！（中键 或 N）")
			if player.has_method("activate_shield"):
				player.activate_shield()
		return
	if event is InputEventKey and event.pressed \
			and event.keycode == KEY_N and not event.echo:
		if not bool(player.get("_shield_input_locked")):
			print("检测到护盾键按下！（中键 或 N）")
			if player.has_method("activate_shield"):
				player.activate_shield()


## 释放阿米娅护盾（中键）。成功后让她说一句话。
func _try_shield() -> void:
	if player == null or not player.has_method("activate_shield"):
		return
	player.activate_shield()


## ★ 护盾台词接口。复用 Amiya 现有的台词系统；
## 找不到 Amiya 节点时静默跳过，不影响护盾本身生效。
func say_shield_line() -> void:
	var amiya := _get_amiya()
	if amiya == null or not amiya.has_method("say_shield_line"):
		print("[Main] ⚠ 找不到 Amiya 节点，跳过护盾台词")
		return
	amiya.say_shield_line()


func _get_amiya() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var n := tree.current_scene.get_node_or_null("Amiya")
	if n != null:
		return n
	return tree.get_first_node_in_group("amiya")


## 触发心流状态（Q 键）
func _try_flow() -> void:
	var flow := _get_flow()
	if flow == null:
		print("[Main] ⚠ 找不到 Flow 单例")
		return
	flow.try_activate()


func _get_flow() -> Node:
	var tree := get_tree()
	if tree == null or not tree.root.has_node("Flow"):
		return null
	return tree.root.get_node("Flow")


## 重开一局：重置分数和波次，重新加载场景最干净
func _restart() -> void:
	# 兜底：万一在顿帧的瞬间按了 R，先把时间倍率还原，
	# 否则新场景一出生就是慢放的
	HitStop.restore()
	# ★ R 键也是「重新开始」，同样要清全局状态。
	# reload_current_scene() 只重建当前场景树，Autoload 单例
	# （RunState / Flow）不受影响，不显式清就会带着上一局的复活次数过来。
	reset_run_data()
	print("[Main] 重新开始…")
	get_tree().reload_current_scene()


## ★ 「重新开始」统一入口（R 键 / 外部调用）。
## 顺序：标记新开局 → 强制清空全局状态 → 重载场景。
func reset_run_data() -> void:
	# ① 告诉下次进入 main.gd「不要恢复任何数据」
	var rs := _run_state_or_null()
	if rs != null:
		if rs.has_method("mark_new_run"):
			rs.mark_new_run()
		# ② 强制重置（复活次数 / 暂存数据 / is_reviving）
		if rs.has_method("reset_run_data"):
			rs.reset_run_data()
	# ③ 心流单例一并重置
	_reset_flow()


## 心流也要重置（否则新一局开局还在CD 里）
func _reset_flow() -> void:
	var flow := _get_flow()
	if flow != null and flow.has_method("hard_reset"):
		flow.hard_reset()


## ★ 播放战斗 BGM（AudioManager 单例判空保护）
func _play_fight_bgm() -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method("play_bgm_fight"):
		am.play_bgm_fight()


func _run_state_or_null() -> Node:
	var tree := get_tree()
	if tree == null or not tree.root.has_node("RunState"):
		return null
	return tree.root.get_node("RunState")
