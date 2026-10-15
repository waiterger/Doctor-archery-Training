extends CanvasLayer
## Buff 选择界面：暂停游戏 → 弹 3 张卡 → 玩家点击选择 → 恢复游戏。
##
## 解耦要点：
## - 界面只认识「buff id 字符串」，通过 signal 把选中的 id 抛出去
## - 谁来弹卡、谁来授予 buff，它一概不管
## - 以后加「商店」「天赋树」也是同样模式：换界面脚本，signal 消费方不变
##
## 卡片结构（模板见 buff_ui.tscn 的 CardTemplate，运行时 clone）：
##   CardTemplate (Button)
##     └─ VBox
##        ├─ TitleLabel    Buff 名字
##        ├─ DescLabel     效果描述
##        └─ StatusLabel   "新"/"Lv.X -> Lv.Y"
##                      或 ★金币升级★："1💰升至Lv.4" / "金币不足"
##
## ★【金币升级只在这里】暂停菜单的技能面板是纯展示，绝不放花钱按钮。

## 玩家选中了某个 buff。GameManager 监听它来实际授予
signal buff_chosen(id: String)

## ★ 玩家花钱升级了某个已满级的 buff（signal 里带 id）。
## GameManager 监听它扣金币 + 提上限。
signal buff_upgraded(id: String)

## ★ 玩家花钱「刷新」了卡牌。GameManager 监听它扣1 金币后，
## 重新 roll 三张卡并调 buff_ui.open()。
signal refresh_requested()

## ★ 玩家点了「跳过」。GameManager 监听它推进到下一波准备
##（不能什么都不做，否则 _awaiting_buff_choice 卡在 true 会导致波次死锁）。
signal skipped()

# BuffManager 的路径，用来查名字/描述/颜色/等级（界面不自己存数据）
# ⚠ BuffUI 和 Player 是【兄弟】节点（都挂在 Main 下），所以只爬一层 "../"。
#    写成 "../../" 会取到 null，导致所有查询回落默认值 —— 等级永远读成 0，
#    卡片就永远显示"新"，看不到升级。已加 fallback 兜底。
@export var buff_manager_path: NodePath = "../Player/BuffManager"

## 卡片模板在场景里的路径（隐藏的 Button，运行时 clone 到 CardRow 下）
@export var card_template_path: NodePath = "CardTemplate"

@onready var dim: ColorRect = $Dim
##⚠ 节点路径变更（v2 布局重构）：
## 以前是 $Panel/... + 绝对 offset 定位，窗口尺寸一变就跑出屏幕
## （刷新按钮曾经飞到屏幕外）。现在改成 Root(MarginContainer) 下的 VBox，
## 全部交给容器排版，任何分辨率都不会溢出。
@onready var title_label: Label = $Root/VBox/Title
@onready var hint_label: Label = $Root/VBox/Hint
@onready var card_row: HBoxContainer = $Root/VBox/CardRow
## ★ 操作区（跳过 + 刷新），常驻在卡片下方，绝不会被裁掉
@onready var action_row: HBoxContainer = $Root/VBox/ActionRow
@onready var btn_skip: Button = $Root/VBox/ActionRow/BtnSkip
@onready var btn_refresh: Button = $Root/VBox/ActionRow/BtnRefresh
@onready var card_template: Button = get_node_or_null(card_template_path)

## ★ 当前展示的选项 id。金币不足时需要用它重建卡片做刷新。
var _current_entries: Array = []

## ★ 刷新一次的花费金币数（GameManager 扣费时会读它）
@export var refresh_cost: int = 1


func _ready() -> void:
	# 关键：游戏被暂停时，只有 PROCESS_MODE_ALWAYS 的节点才能继续响应鼠标
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	# 卡片本体必须是 STOP 才能接收点击；Dim 遮罩保持 IGNORE 不挡点击。
	# 这里显式钉死，避免在编辑器里被误改后排查半天。
	if dim != null:
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 刷新按钮必须 STOP 才能点
	if btn_refresh != null:
		btn_refresh.mouse_filter = Control.MOUSE_FILTER_STOP
		btn_refresh.focus_mode = Control.FOCUS_NONE
		btn_refresh.pressed.connect(_on_refresh_pressed)
	# ★ 跳过按钮：永远可点，防卡死。绝不设 disabled。
	if btn_skip != null:
		btn_skip.mouse_filter = Control.MOUSE_FILTER_STOP
		btn_skip.focus_mode = Control.FOCUS_NONE
		btn_skip.pressed.connect(_on_skip_pressed)
	print("[BuffUI] 界面就绪（暂停状态下仍可响应）")


## ★★ 【跳过】：不选任何 Buff，直接关闭并恢复游戏。
## 这是防卡死的最后一道保险 —— 玩家没金币、又不想选时也能离开。
func _on_skip_pressed() -> void:
	print("[BuffUI] ⏭ 玩家选择跳过，不选任何强化")
	skipped.emit()
	close()


## 弹出并展示这些选项，同时暂停游戏
func open(options: Array) -> void:
	visible = true
	get_tree().paused = true
	# ⚠ 关键：战斗中 pause_menu 会把系统指针藏起来（准心接管），
	# 这里必须重新显形，否则玩家看得见卡片但鼠标"不存在"，点了没反应。
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	title_label.text = "选择强化"
	_refresh_gold_display()
	_refresh_btn_state()
	_build_cards(options)
	print("[BuffUI] 游戏已暂停，弹出 ", options.size(), " 个选项")


## ★ 刷新按钮的可用状态。
## 金币不够 → disabled + modulate 压暗（和卡片同一套表现逻辑）。
func _refresh_btn_state() -> void:
	if btn_refresh == null:
		return
	var affordable := _gold() >= refresh_cost
	btn_refresh.disabled = not affordable
	btn_refresh.modulate = Color.WHITE if affordable else Color(1, 1, 1, 0.45)
	btn_refresh.text = "刷新（%d💰）" % refresh_cost if affordable \
		else "金币不足"


## ★ 点击刷新：抛信号给 GameManager 扣费并重新 roll。
## 界面自己不碰金币（唯一改金币的地方是 GameManager.spend_gold）。
func _on_refresh_pressed() -> void:
	if _gold() < refresh_cost:
		print("[BuffUI] ⚠ 金币不足，刷新失败（需 ", refresh_cost, "）")
		_refresh_btn_state()
		_refresh_gold_display()
		return
	print("[BuffUI] 🎲 请求刷新卡牌（花费 ", refresh_cost, " 金币）")
	refresh_requested.emit()


## ★ 顶部提示里带上金币，让玩家知道升级买得起买不起。
func _refresh_gold_display() -> void:
	var g := _gold()
	hint_label.text = "点击卡片确认 · 本局永久生效 ·  当前金币：%d" % g


## 当前金币（GameManager 在 "game_manager" 组里）
func _gold() -> int:
	var tree := get_tree()
	if tree == null:
		return 0
	var gm: Node = tree.get_first_node_in_group("game_manager")
	if gm != null and "gold" in gm:
		return int(gm.gold)
	return 0


## ★★ v3：升级一次需要多少金币（无扩容，改叫 upgrade）。
func _upgrade_cost() -> int:
	var bm := _buff_mgr()
	if bm != null and bm.has_method("get_upgrade_cost"):
		return maxi(int(bm.get_upgrade_cost()), 1)
	return 1


## ★ 供外部（GameManager）在金币变化/升级后刷新卡片显示。
## 不改变当前选项，只重画一遍。
func refresh_cards() -> void:
	if not visible or _current_entries.is_empty():
		return
	_refresh_gold_display()
	_refresh_btn_state()
	_build_cards(_current_entries)
	print("[BuffUI] 卡片已刷新")


## 关闭并恢复游戏
func close() -> void:
	visible = false
	for c in card_row.get_children():
		card_row.remove_child(c)
		c.queue_free()
	if get_tree().paused:
		get_tree().paused = false
	# 恢复战斗时的指针模式：玩家还在游戏场景里就藏回去，
	# 已经切到结算界面则保持可见。
	var in_game: bool = get_tree().current_scene != null \
		and get_tree().current_scene.name == "Main"
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if in_game \
		else Input.MOUSE_MODE_VISIBLE
	print("[BuffUI] 关闭界面，恢复游戏")


# --------------------------------------------------
# 动态创建卡片
# --------------------------------------------------
func _build_cards(options: Array) -> void:
	# ⚠ deep duplicate：条目是 Dictionary，必须深拷贝，
	# 否则刷新时改了某条的 cost 会污染到原始池子
	_current_entries = options.duplicate(true)
	for c in card_row.get_children():
		card_row.remove_child(c)
		c.queue_free()

	for id in options:
		card_row.add_child(_make_card(id))
	print("[BuffUI] 已创建 ", options.size(), " 张卡片")


## ★★★ v4：entry 是一个 Dictionary（来自 buff_manager.roll_choices），
## 结构：{ id, kind(FREE/PAID), cost, from, to, free }
## 免费条目显示绿色"免费升级"，付费条目显示金色"花 X💰"。
func _make_card(entry: Dictionary) -> Button:
	var id: String = str(entry.get("id", ""))
	var is_free: bool = bool(entry.get("free", true))
	var cost: int = int(entry.get("cost", 0))
	# 优先用tscn 里的模板（节点结构可视化、便于美术调整），
	# 模板缺失时回退到纯代码构建，保证不会因为场景改动而整个界面失效。
	var btn: Button = null
	if card_template != null and is_instance_valid(card_template):
		btn = card_template.duplicate() as Button
	if btn == null:
		btn = Button.new()
		btn.custom_minimum_size = Vector2(240, 240)
		_build_card_nodes_fallback(btn)

	btn.visible = true
	btn.modulate = Color.WHITE
	btn.custom_minimum_size = Vector2(240, 240)
	btn.focus_mode = Control.FOCUS_NONE     # 避免方向键移动焦点抢占操作
	# ⚠ 关键：duplicate() 会把模板的 mouse_filter 一并复制过来。
	#模板若设成 IGNORE，所有卡片都会点不动。这里强制回 STOP。
	btn.mouse_filter = Control.MOUSE_FILTER_STOP

	var color: Color = _query("get_display_color", Color(0.6, 0.7, 0.9), id)
	var lv: int = _query("count_of", 0, id)
	## ★★ v4：没有上限概念了。is_maxed 恒为 false，卡片永远走「可升级」样式。
	var is_maxed: bool = false

	btn.add_theme_stylebox_override("normal", _card_style(color, false, false))
	btn.add_theme_stylebox_override("hover", _card_style(color, true, false))
	btn.add_theme_stylebox_override("pressed", _card_style(color, true, false))
	btn.add_theme_stylebox_override("disabled", _card_style(color, false, false))

	# ---- 节点路径（见 buff_ui.tscn 的 CardTemplate）----
	var vb := btn.get_node_or_null("VBox") as VBoxContainer
	var title_lb := btn.get_node_or_null("VBox/TitleLabel") as Label
	var desc_lb := btn.get_node_or_null("VBox/DescLabel") as Label
	var status_lb := btn.get_node_or_null("VBox/StatusLabel") as Label

	var ink := Color(0.08, 0.09, 0.12)
	var desc_ink := Color(0.30, 0.32, 0.38)

	if title_lb != null:
		title_lb.text = _query("get_display_name", id, id)
		title_lb.add_theme_color_override("font_color", ink)
	if desc_lb != null:
		desc_lb.text = _query("get_display_desc", "", id)
		desc_lb.add_theme_color_override("font_color", desc_ink)

	# ================================================================
	# ★★★ v4 StatusLabel = 升级按钮的文字（免费/付费两种明确区分）
	#
	# ★ 【免费条目】（entry.free == true，即当前等级 < free_upgrade_until）
	#     "新 · 免费升级到 Lv.1"      lv=0
	#     "Lv.1 · 免费升级到 Lv.2"    lv=1,2
	#     → 绿色，不需要金币，永远可点
	#
	# ★ 【付费条目】（entry.free == false，即等级 >= free_upgrade_until）
	#     "Lv.3 · 花 1💰 升到 Lv.4"   金币够 → 亮金色，可点
	#     "Lv.3 · 金币不足（需1枚）"   金币不够 → 暗红，压暗但仍可点
	# ================================================================
	# ⚠ 判定用【entry 里的 cost】，不是 _upgrade_cost()——
	#   entry 是抽卡那一刻算好的快照，避免刷新后状态串味。
	var affordable := true if is_free else _gold() >= cost

	if status_lb != null:
		var status_text := ""
		var status_col := Color.WHITE
		if is_free:
			#免费阶段：绿色，明确写"免费"
			var prefix := "新" if lv <= 0 else "Lv.%d" % lv
			status_text = "%s · 免费升级到 Lv.%d" % [prefix, lv + 1]
			status_col = Color(0.35, 0.88, 0.45)      # 鲜绿
		elif affordable:
			status_text = "Lv.%d · 花 %d💰 升到 Lv.%d" % [lv, cost, lv + 1]
			status_col = Color(1.0, 0.78, 0.25)        # 亮金
		else:
			status_text = "Lv.%d · 金币不足（需%d枚）" % [lv, cost]
			status_col = Color(0.85, 0.35, 0.35)        # 暗红
		status_lb.text = status_text
		status_lb.add_theme_color_override("font_color", status_col)

	# ---- 卡片可点性 ----
	# ⚠ 【不要设 disabled=true】—— disabled 的 Button 不会触发 pressed，
	#    金币不足时点了就没反应，玩家会以为卡死。
	#    这里一律保持可点，用 modulate 表达"买不起"，点击时给出提示。
	btn.disabled = false
	btn.modulate = Color.WHITE if affordable else Color(1, 1, 1, 0.55)
	if not btn.pressed.is_connected(_on_card_pressed):
		btn.pressed.connect(_on_card_pressed.bind(id))
	print("[BuffUI] 卡片「", id, "」lv=", lv, "→", lv + 1,
		" 类型=", ("免费" if is_free else "付费 %d💰" % cost),
		" 金币=", _gold(), " 可点=", affordable)

	btn.set_meta("buff_id", id)# 方便测试/调试反查这张卡代表哪个 buff
	btn.set_meta("is_free", is_free)
	btn.set_meta("cost", cost)
	btn.set_meta("level", lv)
	btn.set_meta("affordable", affordable)
	return btn


## 模板节点缺失时的兜底：手动补出VBox/Title/Desc/Status 结构
func _build_card_nodes_fallback(btn: Button) -> void:
	if btn.get_node_or_null("VBox") != null:
		return
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vb)

	for n in ["TitleLabel", "DescLabel", "StatusLabel"]:
		var l := Label.new()
		l.name = n
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_font_size_override("font_size", 20 if n == "StatusLabel" else 18)
		vb.add_child(l)


func _card_style(color: Color, hover: bool, is_maxed: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if is_maxed:
		# 满级：整张卡压成灰色，一眼看出点不了
		sb.bg_color = Color(0.22, 0.23, 0.26) if hover else Color(0.17, 0.18, 0.21)
		sb.border_color = Color(0.40, 0.41, 0.45)
	else:
		# 卡面用 buff 颜色的浅色版，边框用原色，形成区分
		sb.bg_color = color.lightened(0.55) if hover else color.lightened(0.72)
		sb.border_color = color
	sb.border_width_left = 4
	sb.border_width_top = 4
	sb.border_width_right = 4
	sb.border_width_bottom = 4
	sb.set_corner_radius_all(12)
	return sb


# --------------------------------------------------
# 向 BuffManager 查询显示信息（界面不保存任何 Buff 数据）
# --------------------------------------------------
func _query(method: String, fallback, id: String):
	var mgr := get_node_or_null(buff_manager_path)
	# fallback：路径失效时用「按组查找」兜底，
	# 免得路径一改整个卡片显示就全部退化成默认值。
	if mgr == null:
		var tree := get_tree()
		if tree != null:
			mgr = tree.get_first_node_in_group("buff_manager")
	if mgr != null and mgr.has_method(method):
		return mgr.call(method, id)
	return fallback


func _on_card_pressed(id: String) -> void:
	## ★★ v4 规则：点击卡片 = 升级该 buff。
	## 【免费还是付费】由 buff_manager 依据当前等级判定，UI 不自己算——
	## 这样界面显示和实际扣费永远一致（要求 4）。
	_try_upgrade(id)


## ★★ 升级前置校验（仅提示，不扣费）。
## ⚠ 【免费升级绝不校验金币】—— 这正是截图里
##   "1 级就提示消耗金币"的根因：早期免费阶段被误当成付费。
func _try_upgrade(id: String) -> void:
	var bm := _buff_mgr()
	if bm == null or not is_instance_valid(bm):
		print("[BuffUI] ⚠ 找不到 BuffManager，无法升级")
		return

	var is_free: bool = bool(bm.is_free_upgrade(id))
	var cost: int = int(bm.upgrade_price(id))
	var g := _gold()

	if is_free:
		print("[BuffUI] ✦ 请求免费升级 ", id, "（Lv.",
			bm.count_of(id), " → ", bm.count_of(id) + 1, "，无需金币）")
	else:
		if g < cost:
			print("[BuffUI] ⚠ 金币不足：需要 ", cost, " 持有 ", g)
			# 不关界面，让玩家看清"金币不足"并换别的卡
			_refresh_all()
			return
		print("[BuffUI] 💰 请求付费升级 ", id, "（花费 ", cost, "，持有 ", g, "）")

	buff_upgraded.emit(id)


## 刷新金币显示 + 按钮状态 + 卡片（金币变化后统一调用）
func _refresh_all() -> void:
	_refresh_gold_display()
	_refresh_btn_state()
	if not _current_entries.is_empty():
		_build_cards(_current_entries)


## 拿 BuffManager 引用
func _buff_mgr() -> Node:
	var mgr := get_node_or_null(buff_manager_path)
	if mgr == null:
		var tree := get_tree()
		if tree != null:
			mgr = tree.get_first_node_in_group("buff_manager")
	return mgr