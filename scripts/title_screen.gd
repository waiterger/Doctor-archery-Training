extends Control
## 起始页：三选一（开始训练 / 设置 / 退出）。
##
## 解耦：这个脚本只管「切场景」和「退出」，
## 完全不知道 main.tscn 里面有什么。

## 可调参数：各按钮跳转的目标场景
@export var game_scene: String = "res://scenes/main.tscn"

@onready var btn_start: Button = $Center/VBox/BtnStart
@onready var btn_setting: Button = $Center/VBox/BtnSetting
@onready var btn_quit: Button = $Center/VBox/BtnQuit
@onready var hint_label: Label = $Center/VBox/Hint
@onready var settings_panel: Control = $SettingsPanel


func _ready() -> void:
	print("[Title] ===== 博士的射击训练 · 主菜单 =====")
	btn_start.pressed.connect(_on_start)
	btn_setting.pressed.connect(_on_setting)
	btn_quit.pressed.connect(_on_quit)
	# 设置面板关掉时它自己会发 closed 信号，这里只管把焦点还回来
	settings_panel.closed.connect(_on_settings_closed)
	btn_start.grab_focus()
	# ★ 主菜单 BGM
	_play_menu_bgm()
	# ★ 给三个按钮挂上点击音（一次性挂，不用每个回调里写）
	for b in [btn_start, btn_setting, btn_quit]:
		var btn: Button = b
		if btn != null and not btn.pressed.is_connected(_on_any_click_sound):
			btn.pressed.connect(_on_any_click_sound)


## UI 点击音（按钮真正响应时才响，不影响原有 pressed 回调）
func _on_any_click_sound() -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method("play_click"):
		am.play_click()


## 播放主菜单 BGM（AudioManager 单例可能不存在，判空保护）
func _play_menu_bgm() -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method("play_bgm_menu"):
		am.play_bgm_menu()


func _on_start() -> void:
	print("[Title] 开始训练 → ", game_scene)
	# ★ 从主菜单开局 =全新一局，必须清掉上一局残留的全局状态
	#   （复活次数 / 金币 / Buff / 波次）。RunState 是 Autoload 单例，
	#   从结算界面或暂停菜单回主菜单时不会被销毁，不清就会串局。
	_reset_run_state()
	get_tree().paused = false          # 双保险：万一上局残留暂停
	get_tree().change_scene_to_file(game_scene)


## ★ 开局统一处理：标记新开局 + 强制清空全部本局数据。
## 必须在 change_scene_to_file【之前】调用。
func _reset_run_state() -> void:
	var tree := get_tree()
	if tree == null or not tree.root.has_node("RunState"):
		return
	var rs: Node = tree.root.get_node("RunState")
	if rs == null:
		return
	# ① 告诉 main.gd「不要恢复任何暂存数据」
	if rs.has_method("mark_new_run"):
		rs.mark_new_run()
	# ② 强制重置（复活次数 / 金币 / 波次 / 分数 / Buff / is_reviving）
	if rs.has_method("reset_run_data"):
		rs.reset_run_data()
	# ③ 心流单例一并重置
	if tree.root.has_node("Flow"):
		var flow: Node = tree.root.get_node("Flow")
		if flow != null and flow.has_method("hard_reset"):
			flow.hard_reset()


func _on_setting() -> void:
	print("[Title] 打开设置")
	settings_panel.open()


func _on_settings_closed() -> void:
	print("[Title] 设置已关闭，返回主菜单")
	btn_setting.grab_focus()


func _on_quit() -> void:
	print("[Title] 退出游戏")
	get_tree().quit()