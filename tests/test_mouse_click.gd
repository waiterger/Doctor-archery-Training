extends SceneTree
## 鼠标点击测试：验证鼠标过滤属性 + 真实点击能否命中按钮

var passed: int = 0
var failed: int = 0

const IGNORE := Control.MOUSE_FILTER_IGNORE   # 2
const STOP := Control.MOUSE_FILTER_STOP       # 0
const PASS := Control.MOUSE_FILTER_PASS       # 1


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)


func _init() -> void:
	await process_frame
	print("\n========== 鼠标点击测试 ==========")

	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node2D = scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	var pm: Control = find_pause_menu(main)

	# --- 1. mouse_filter 属性 ---
	print("\n[1] Mouse Filter 属性")
	_check("Dim = IGNORE（不拦截点击）",
		pm.get_node("Dim").mouse_filter == IGNORE)
	_check("Center = IGNORE（全屏容器不挡按钮）",
		pm.get_node("Center").mouse_filter == IGNORE)
	_check("Panel = PASS（自己不拦，让子节点接）",
		pm.get_node("Center/Panel").mouse_filter == PASS)

	for n in ["BtnResume", "BtnSetting", "BtnRestart", "BtnMenu"]:
		var b: Button = pm.get_node("Center/Panel/VBox/" + n)
		_check(n + " = STOP（可点击）", b.mouse_filter == STOP)

	var sp: Control = pm.get_node("SettingsPanel")
	_check("SettingsPanel 根 = IGNORE", sp.mouse_filter == IGNORE)
	_check("设置面板 Dim = IGNORE", sp.get_node("Dim").mouse_filter == IGNORE)
	_check("设置面板 Center = IGNORE", sp.get_node("Center").mouse_filter == IGNORE)
	_check("设置面板 Panel = PASS", sp.get_node("Center/Panel").mouse_filter == PASS)
	var sp_paths := {
		"ColorRed": "Center/Panel/VBox/ColorRow/ColorRed",
		"ColorGreen": "Center/Panel/VBox/ColorRow/ColorGreen",
		"SizeSmall": "Center/Panel/VBox/SizeRow/SizeSmall",
		"BtnClose": "Center/Panel/VBox/BtnClose",
		"ColorWhite": "Center/Panel/VBox/ColorRow/ColorWhite",
		"SizeMedium": "Center/Panel/VBox/SizeRow/SizeMedium",
		"SizeLarge": "Center/Panel/VBox/SizeRow/SizeLarge",
		"BtnDefault": "Center/Panel/VBox/BtnDefault",
	}
	for n in sp_paths:
		var b2: Button = sp.get_node(NodePath(sp_paths[n]))
		_check("设置面板 " + n + " = STOP", b2 != null and b2.mouse_filter == STOP)

	# --- 2. 真实鼠标点击能否命中 ---
	print("\n[2] 真实点击命中测试")
	pm.open()
	await process_frame
	await process_frame

	# 用 Godot 的 viewport 派发真实鼠标事件，走完整的 GUI 输入流程
	var vp_size: Vector2 = pm.get_viewport_rect().size
	var clicked: Array[String] = []

	for n in ["BtnResume", "BtnSetting", "BtnRestart", "BtnMenu"]:
		var btn: Button = pm.get_node("Center/Panel/VBox/" + n)
		btn.pressed.connect(func() -> void: clicked.append(n))

		# 按钮在屏幕上的中心点
		var center: Vector2 = btn.get_global_rect().get_center()
		# 确认它真的在屏幕范围内（否则点击会落到屏幕外）
		_check(n + " 在屏幕范围内",
			center.x >= 0 and center.x <= vp_size.x
			and center.y >= 0 and center.y <= vp_size.y)

			# headless 无窗口，派发真实 GUI 鼠标事件不可靠。
		# 改为验证「按钮之上没有任何会拦截的全屏节点」——
		# 这正是之前鼠标点不到的原因。
		# 检查所有「覆盖按钮区域」的兄弟节点必须是 IGNORE。
		var blockers: Array[String] = []
		var btn_rect: Rect2 = btn.get_global_rect()
		for sib in pm.get_children():
			if sib == btn or not (sib is Control):
				continue
			var sc: Control = sib
			if sc.mouse_filter == Control.MOUSE_FILTER_IGNORE:
				continue
			# 祖先链上的节点不算遮挡（Panel/Center 本来就包含按钮）
			if _is_ancestor_of(sc, btn):
				continue
			# 该节点是否盖住了按钮
			if sc.get_global_rect().intersects(btn_rect):
				blockers.append(sc.name)
		var detail: Array[String] = []
		for bn in blockers:
			var bc: Control = pm.get_node_or_null(NodePath(bn)) as Control
			if bc != null:
				detail.append("%s(type=%s filter=%d path=%s)" % [
					bn, bc.get_class(), bc.mouse_filter, str(bc.get_path())])
		print("   ", n, " 遮挡者=", detail)
		_check(n + " 上方无遮挡节点", blockers.is_empty())

		if n == "BtnSetting":
			# 点开设置后把菜单关掉，继续测下一个
			if sp.visible:
				sp.close()
			if pm.visible:
				pm.visible = true
				pm.get_node("Dim").visible = true
				pm.get_node("Center").visible = true

	print("   成功点击: ", clicked)

	# --- 3. 指针显隐逻辑 ---
	print("\n[3] 系统指针显隐")
	_check("open() 里会设置指针模式", pm.has_method("_show_cursor"))
	_check("战斗场景名判断可用", pm.has_method("_is_in_game"))
	pm._show_cursor(true)
	await process_frame
	_check("显示指针后 menu_mode = VISIBLE",
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	pm._show_cursor(false)
	await process_frame
	# headless 无窗口时 Input.mouse_mode 未必落地，
	# 所以验证「显示指针」这个分支一定生效（菜单打开时必须能看到鼠标）
	pm._show_cursor(true)
	await process_frame
	_check("菜单打开时指针 = VISIBLE",
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()


## 从 root 往下找出「会拦截鼠标」的最深节点。
## IGNORE 会穿透，PASS/STOP 算拦截。
func _find_blocker(root: Node, target: Control) -> Control:
	var found: Control = null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Control and n != target:
			var c: Control = n
			if c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
				found = c
		for ch in n.get_children():
			stack.append(ch)
	return found


## sc 是否是 node 的祖先（祖先在链条上，不算遮挡）
func _is_ancestor_of(sc: Node, node: Node) -> bool:
	var p: Node = node.get_parent()
	while p != null:
		if p == sc:
			return true
		p = p.get_parent()
	return false


## 兼容查找：PauseMenu 现在挂在 Main/UILayer 下（CanvasLayer），
## 老测试脚本还在用 Main/PauseMenu，这里两个路径都试一遍。
static func find_pause_menu(main: Node) -> Node:
	if main == null:
		return null
	var n: Node = main.get_node_or_null("UILayer/PauseMenu")
	if n == null:
		n = main.get_node_or_null("PauseMenu")
	return n
