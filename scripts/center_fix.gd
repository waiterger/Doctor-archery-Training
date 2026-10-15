extends RefCounted
## UI 居中兜底工具：确保菜单类节点铺满视口。
##
## ## 【2026-10-13 病因已修复】
## 原来这里写了一大段"因为 UI 挂在 Node2D 下锚点不生效，只能手动设size"的注释。
## 病因本身已经修掉了：main.tscn 里新建了 UILayer (CanvasLayer, layer=200)，
## PauseMenu 和它的 SettingsPanel 现在都挂在 CanvasLayer 下，锚点【原生生效】，
## 不再受 Camera2D 镜头影响。
##
## 这个类现在退化成"纯保险"：
##  - 根节点/子节点一律设Full Rect（正常情况下锚点已经对了，设了也不冲突）
##  - 额外监听视口尺寸变化，窗口缩放时重新铺满
##
## 用法（已内置在 pause_menu.gd / settings_panel.gd 的 _ready() 里）：
##     const CF := preload("res://scripts/center_fix.gd")
##     CF.fix_pause_menu(self)


## 把节点设为 Full Rect 锚点铺满视口。
static func fill_viewport(c: Control) -> void:
	if c == null:
		return
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0
	c.grow_horizontal = Control.GROW_DIRECTION_BOTH
	c.grow_vertical = Control.GROW_DIRECTION_BOTH
	c.custom_minimum_size = Vector2.ZERO
	# 兜底：如果锚点因为任何原因没生效（比如又被挂到非 Control 父级下），
	# 至少 position 归零，不会歪在左上角。
	c.position = Vector2.ZERO


## 一次性修好暂停菜单 / 设置面板的所有布局容器
static func fix_pause_menu(root: Control) -> void:
	if root == null:
		return
	fill_viewport(root)
	fill_viewport(root.get_node_or_null("Dim"))
	fill_viewport(root.get_node_or_null("Center"))

	# SettingsPanel 是独立实例：铺满它自己和它内部的 Center
	var sp: Node = root.get_node_or_null("SettingsPanel")
	if sp != null:
		fill_viewport(sp)
		fill_viewport(sp.get_node_or_null("Dim"))
		fill_viewport(sp.get_node_or_null("Center"))


## 检查并打印布局是否符合预期（给测试/调试用）
static func check(root: Control) -> Dictionary:
	var report := {}
	if root == null:
		return report
	var vp: Vector2 = root.get_viewport_rect().size
	for n in ["Center", "SettingsPanel", "SettingsPanel/Center", "Dim"]:
		var c: Control = root.get_node_or_null(NodePath(n))
		if c == null:
			report[n] = "缺失"
			continue
		var ok_w: bool = is_equal_approx(c.size.x, vp.x)
		var ok_h: bool = is_equal_approx(c.size.y, vp.y)
		report[n] = "铺满 %s" % c.size.round() if (ok_w and ok_h) else \
			"未铺满 size=%s 视口=%s" % [c.size.round(), vp.round()]
	return report


## 检查某个 Panel 是否真的在屏幕中心（容差 2 像素）
static func is_centered(vp_size: Vector2, panel: Control, tolerance: float = 2.0) -> bool:
	if panel == null:
		return false
	var mid: Vector2 = vp_size * 0.5
	return (panel.position + panel.size * 0.5).distance_to(mid) <= tolerance