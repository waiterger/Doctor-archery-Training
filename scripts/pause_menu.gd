extends Control
## 游戏内暂停菜单：按ESC 打开。
## 面板本体复用 settings_panel.tscn，和主菜单用的是同一个场景。

const CF := preload("res://scripts/center_fix.gd")

@export var game_scene: String = "res://scenes/main.tscn"
@export var title_scene: String = "res://scenes/title_screen.tscn"

@onready var btn_resume: Button = $Center/Panel/VBox/BtnResume
@onready var btn_setting: Button = $Center/Panel/VBox/BtnSetting
@onready var btn_shop: Button = $Center/Panel/VBox/BtnShop
@onready var shop_panel: Control = $ShopPanel
@onready var btn_restart: Button = $Center/Panel/VBox/BtnRestart
@onready var btn_menu: Button = $Center/Panel/VBox/BtnMenu
@onready var settings_panel: Control = $SettingsPanel
@onready var _center: Control = $Center
@onready var skill_panel: VBoxContainer = $Center/Panel/VBox/SkillPanel
@onready var skill_list: VBoxContainer = $Center/Panel/VBox/SkillPanel/SkillList
@onready var skill_gold_label: Label = $Center/Panel/VBox/SkillPanel/GoldLabel
@onready var skill_empty: Label = $Center/Panel/VBox/SkillPanel/SkillList/Empty

## 技能面板读 BuffManager 用。
## PauseMenu 挂在 Main/UILayer 下，Player 在 Main 下，所以要往上爬两层。
@export var buff_manager_path: NodePath = "../../Player/BuffManager"

var _skill_rows: Dictionary = {}   # { buff_id: HBoxContainer }，用于增量刷新
var _skill_mgr: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	# 布局兜底：把 Center / SettingsPanel 强制铺满全屏，
	# 里面的 Panel 由 CenterContainer 自动居中。
	# 只动锚点，不碰任何按钮和信号。
	CF.fix_pause_menu(self)
	print("[PauseMenu] 布局修正完成: ", CF.check(self))

	btn_resume.pressed.connect(close)
	btn_setting.pressed.connect(_on_setting)
	btn_shop.pressed.connect(_on_shop)
	btn_restart.pressed.connect(_on_restart)
	btn_menu.pressed.connect(_on_menu)
	settings_panel.closed.connect(_on_settings_closed)

	# 商店买成功后给个视觉提示（按钮闪一下）
	if shop_panel != null and shop_panel.has_signal("purchase_done"):
		shop_panel.purchase_done.connect(_on_purchase_done)
		shop_panel.btn_back.pressed.connect(_on_shop_back)

	_connect_buff_manager()
	refresh_skill_panel()

	print("[PauseMenu] 暂停菜单就绪")


## 接上 BuffManager 的等级变化信号，实现「拿到 buff 实时刷新」
func _connect_buff_manager() -> void:
	if _skill_mgr != null and is_instance_valid(_skill_mgr):
		return

	# 先按导出路径找，失败再用玩家所在的 Main 场景找 —— 双保险，
	# 免得节点层级一改技能面板就整个失灵
	var mgr := get_node_or_null(buff_manager_path)
	if mgr == null:
		var main := get_tree().current_scene
		if main != null:
			var player := main.get_node_or_null("Player")
			if player != null:
				mgr = player.get_node_or_null("BuffManager")

	if mgr == null:
		# 暂停菜单在主菜单场景也会被用到，那里没有 Player，属正常情况
		print("[PauseMenu] 非战斗场景，跳过技能面板绑定")
		return

	_skill_mgr = mgr
	if _skill_mgr.has_signal("buff_levels_changed"):
		_skill_mgr.buff_levels_changed.connect(refresh_skill_panel)
		print("[PauseMenu] 已连接 BuffManager.buff_levels_changed")
	refresh_skill_panel()


# --------------------------------------------------
# 技能面板：显示「Buff 名称 + 当前等级」
# --------------------------------------------------
## 每次打开暂停菜单、以及每次 buff 等级变化时调用
func refresh_skill_panel() -> void:
	if skill_panel == null or skill_list == null:
		return
	# _skill_mgr 可能因为场景切换失效，每帧重新确认一次
	if _skill_mgr != null and not is_instance_valid(_skill_mgr):
		_skill_mgr = null
	if _skill_mgr == null:
		_connect_buff_manager()

	var ids: Array[String] = []
	if _skill_mgr != null and is_instance_valid(_skill_mgr):
		ids = _skill_mgr.owned_ids()

	# 金币 Label 独立刷新（即使一个 buff 都没有也要显示）
	if skill_gold_label != null:
		var g := _current_gold()
		skill_gold_label.text = "当前金币：%d" % g
		skill_gold_label.modulate = Color(1, 0.84, 0.32) if g > 0 \
			else Color(0.6, 0.62, 0.68)

	# 从没拿过任何 buff：整块面板不显示，避免菜单空一大块
	skill_panel.visible = not ids.is_empty()
	if ids.is_empty():
		return

	# 清掉旧的行。Empty 是常驻占位，用 remove_child 先摘下来，
	# 光设 visible=false 它仍然会占着布局高度把列表顶出一个空行。
	for c in skill_list.get_children():
		if c == skill_empty:
			continue
		skill_list.remove_child(c)
		c.queue_free()
	_skill_rows.clear()
	if skill_empty != null:
		skill_empty.visible = false
	else:
		# 没有占位节点就补一个，保持「无buff 时给提示」的行为
		skill_empty = Label.new()
		skill_empty.text = "（尚未获得任何强化）"
		skill_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		skill_empty.add_theme_font_size_override("font_size", 14)
		skill_empty.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
		skill_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		skill_list.add_child(skill_empty)
		skill_empty.visible = false

	for id in ids:
		skill_list.add_child(_make_skill_row(id))


## 生成一行。⚠ 强制用HBoxContainer 水平排版：
##   [色块] [Buff名称.....EXPAND] [等级]
## 名称用 SIZE_EXPAND_FILL 占掉多余宽度，等数自然贴右，永不重叠。
##
## ⚠⚠ 【纯展示，不允许出现任何花钱的按钮】
## 原来的「1💰升Lv.4」扩容按钮已彻底移除。
## 金币扩容只出现在【三选一界面 buff_ui】的卡片上。
## 暂停菜单只负责「看」：名字 + 等级。
func _make_skill_row(id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var color: Color = _skill_mgr.get_display_color(id)
	var lv: int = _skill_mgr.count_of(id)
	var mx: int = _skill_mgr.max_level_of(id)

	# 左侧色块
	var chip := ColorRect.new()
	chip.custom_minimum_size = Vector2(6, 20)
	chip.color = color
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(chip)

	# 名称（撑开剩余空间）
	var name_label := Label.new()
	name_label.text = _skill_mgr.get_display_name(id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color",
		Color(0.86, 0.88, 0.93) if lv < mx else color)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)

	# 等级
	var lv_label := Label.new()
	lv_label.text = _skill_mgr.get_level_text(id)
	lv_label.add_theme_font_size_override("font_size", 16)
	lv_label.add_theme_color_override("font_color",
		Color(1.0, 0.86, 0.5) if lv >= mx else Color(0.7, 0.73, 0.8))
	lv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lv_label)

	row.set_meta("buff_id", id)
	return row


## 当前金币（GameManager 在 "game_manager" 组里）。
## 只用于顶部 GoldLabel 的纯展示，不再参与任何购买逻辑。
func _current_gold() -> int:
	var tree := get_tree()
	if tree == null:
		return 0
	var gm: Node = tree.get_first_node_in_group("game_manager")
	if gm != null and "gold" in gm:
		return int(gm.gold)
	return 0


func open() -> void:
	visible = true
	get_tree().paused = true
	_show_cursor(true)
	# 每次打开都重算一次等级，显示永远是最新的
	refresh_skill_panel()
	# 保证是主菜单状态（可能上次是用 ESC 从商店退回来的）
	if _center != null:
		_center.visible = true
	if shop_panel != null:
		shop_panel.close()
	btn_resume.grab_focus()
	print("[PauseMenu] 暂停（鼠标已显形，可点击）")


func close() -> void:
	# 设置面板开着的话，先把它关掉（它会再调回来）
	if settings_panel.visible:
		settings_panel.close()
		return
	# 商店开着时，ESC 先回主菜单而不是直接关掉整个暂停菜单
	if shop_panel.visible:
		_on_shop_back()
		return
	visible = false
	get_tree().paused = false
	# 回到游戏，重新隐藏系统指针（准心接管）
	_show_cursor(false)
	print("[PauseMenu] 继续游戏")


## 统一切换系统指针。
## show = true 显示（菜单/设置面板，要能点按钮）
## show = false 隐藏（战斗中，准心接管鼠标）
func _show_cursor(show: bool) -> void:
	# 只在游戏内隐藏指针；主菜单/结算界面要一直看得见鼠标
	if show or not _is_in_game():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	print("[PauseMenu] 系统指针 → ", "显示" if show else "隐藏")


## 当前是不是在战斗场景里（战斗里才隐藏指针）
func _is_in_game() -> bool:
	return get_tree().current_scene != null \
		and get_tree().current_scene.name == "Main"


func _on_setting() -> void:
	print("[PauseMenu] 打开设置（游戏保持暂停）")
	settings_panel.open()


# --------------------------------------------------
# 商店
# --------------------------------------------------
## 点「🛒 商店」：隐藏主面板，显示商店
func _on_shop() -> void:
	print("[PauseMenu] 打开商店（游戏保持暂停）")
	_center.visible = false# 隐藏主菜单
	shop_panel.open()


## 商店里的「返回」：关商店，主面板回来
func _on_shop_back() -> void:
	shop_panel.close()
	_center.visible = true


## 购买成功反馈：主菜单的金币 Label 刷新一下
func _on_purchase_done(item_name: String) -> void:
	print("[PauseMenu] 🛒 购买成功：", item_name)
	refresh_skill_panel()


func _on_settings_closed() -> void:
	# 回到暂停菜单这一层，而不是直接恢复游戏。
	# 注意不要再把settings_panel.visible 改回 true——它自己 close() 时已经隐藏了。
	print("[PauseMenu] 设置已关闭，回到暂停菜单")
	btn_setting.grab_focus()


func _on_restart() -> void:
	print("[PauseMenu] 重新开始")
	# ★ 重开 = 放弃本局所有全局状态（复活次数、金币、Buff 等）。
	# RunState 是 Autoload 单例，切场景不会重建它，不显式清就会串局。
	_reset_run_state()
	_goto(game_scene)


func _on_menu() -> void:
	print("[PauseMenu] 返回主菜单")
	# 回主菜单了，下一次开始训练也必须是干净状态
	_reset_run_state()
	_goto(title_scene)


## ★ 「重新开始 / 返回主菜单」的统一处理。
## 标记为新开局 + 强制清空复活次数、金币、波次、分数、Buff。
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
	# ② 强制重置全局状态（复活次数 / 暂存数据 / is_reviving）
	if rs.has_method("reset_run_data"):
		rs.reset_run_data()
	# ③ 重置 GameManager 运行时数据（它是本场景节点，切场景就没了）
	var gm: Node = tree.get_first_node_in_group("game_manager")
	if gm != null and gm.has_method("reset_run_data"):
		gm.reset_run_data()
	# ④ 心流也是单例，冷却一并清掉
	if tree.root.has_node("Flow"):
		var flow: Node = tree.root.get_node("Flow")
		if flow != null and flow.has_method("hard_reset"):
			flow.hard_reset()


func _goto(path: String) -> void:
	visible = false
	get_tree().paused = false
	# 切场景后指针必须可见，否则新场景（主菜单）点不动
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(path)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	# 商店/设置 打开时，ESC 交给 close() 分层处理（见close 里的分支）
	if event.keycode == KEY_ESCAPE and not settings_panel.visible and not shop_panel.visible:
		get_viewport().set_input_as_handled()
		if visible:
			close()
		else:
			open()
