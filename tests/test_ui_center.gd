extends SceneTree
## UI 居中测试：Center / SettingsPanel 是否铺满全屏，Panel 是否居中

var passed: int = 0
var failed: int = 0
const CF := preload("res://scripts/center_fix.gd")


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)


func _init() -> void:
	await process_frame
	print("\n========== UI 居中测试 ==========")

	var scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node2D = scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	var pm: Control = find_pause_menu(main)
	pm.open()
	await process_frame
	await process_frame   # 等容器完成一次布局

	# 用视口尺寸做基准：PauseMenu 挂在 Node2D 下，自身 size 不可靠
	var vp: Vector2 = pm.get_viewport_rect().size
	print("   视口尺寸=", vp.round(), "  PauseMenu size=", pm.size.round())

	# --- 1. Center 铺满全屏 ---
	print("\n[1] Center 铺满全屏")
	var center: Control = pm.get_node("Center")
	_check("Center 锚点为 Full Rect", center.anchors_preset == Control.PRESET_FULL_RECT)
	_check("Center anchor_right = 1.0", is_equal_approx(center.anchor_right, 1.0))
	_check("Center anchor_bottom = 1.0", is_equal_approx(center.anchor_bottom, 1.0))
	_check("Center offset 全部归零",
		is_zero_approx(center.offset_left) and is_zero_approx(center.offset_top)
		and is_zero_approx(center.offset_right) and is_zero_approx(center.offset_bottom))
	_check("Center 宽度铺满", is_equal_approx(center.size.x, vp.x))
	_check("Center 高度铺满", is_equal_approx(center.size.y, vp.y))
	print("   Center size=", center.size.round())

	# --- 2. 主菜单 Panel 居中 ---
	print("\n[2] 主菜单 Panel 居中")
	var panel: Control = pm.get_node("Center/Panel")
	var pc: Vector2 = panel.get_combined_minimum_size()
	var ppos: Vector2 = panel.position
	var expect_x: float = (vp.x - panel.size.x) * 0.5
	var expect_y: float = (vp.y - panel.size.y) * 0.5
	print("   Panel size=", panel.size.round(), " pos=", ppos.round())
	print("   期望 pos≈", Vector2(expect_x, expect_y).round())
	_check("Panel 水平居中", absf(ppos.x - expect_x) < 2.0)
	_check("Panel 垂直居中", absf(ppos.y - expect_y) < 2.0)

	# --- 3. Dim 铺满（背景遮罩要盖全） ---
	print("\n[3] Dim 遮罩铺满")
	var dim: Control = pm.get_node("Dim")
	_check("Dim 铺满全屏",
		is_equal_approx(dim.size.x, vp.x) and is_equal_approx(dim.size.y, vp.y))

	# --- 4. SettingsPanel 铺满 ---
	print("\n[4] SettingsPanel 铺满全屏")
	var sp: Control = pm.get_node("SettingsPanel")
	sp.visible = true
	await process_frame
	_check("SettingsPanel 铺满",
		is_equal_approx(sp.size.x, vp.x) and is_equal_approx(sp.size.y, vp.y))
	_check("SettingsPanel anchor_right = 1.0", is_equal_approx(sp.anchor_right, 1.0))
	_check("SettingsPanel anchor_bottom = 1.0", is_equal_approx(sp.anchor_bottom, 1.0))
	print("   SettingsPanel size=", sp.size.round())

	# --- 5. 设置面板内部 Center 也铺满 + Panel 居中 ---
	print("\n[5] 设置面板内部居中")
	var sp_center: Control = sp.get_node("Center")
	_check("设置面板 Center 铺满",
		is_equal_approx(sp_center.size.x, vp.x) and is_equal_approx(sp_center.size.y, vp.y))
	var sp_panel: Control = sp.get_node("Center/Panel")
	var spp: Vector2 = sp_panel.position
	var sexp_x: float = (vp.x - sp_panel.size.x) * 0.5
	var sexp_y: float = (vp.y - sp_panel.size.y) * 0.5
	print("   设置 Panel size=", sp_panel.size.round(), " pos=", spp.round())
	print("   期望 pos≈", Vector2(sexp_x, sexp_y).round())
	_check("设置 Panel 水平居中", absf(spp.x - sexp_x) < 2.0)
	_check("设置 Panel 垂直居中", absf(spp.y - sexp_y) < 2.0)

	# --- 6. 中心点重合 ---
	print("\n[6] 几何校验")
	var mid: Vector2 = vp * 0.5
	_check("主菜单 Panel 中心 == 屏幕中心", CF.is_centered(vp, panel))
	_check("设置 Panel 中心 == 屏幕中心", CF.is_centered(vp, sp_panel))

	# --- 7. 按钮和信号没被破坏 ---
	print("\n[7] 逻辑未受影响")
	_check("继续按钮存在", pm.get_node_or_null("Center/Panel/VBox/BtnResume") != null)
	_check("设置按钮存在", pm.get_node_or_null("Center/Panel/VBox/BtnSetting") != null)
	_check("重开按钮存在", pm.get_node_or_null("Center/Panel/VBox/BtnRestart") != null)
	_check("主菜单按钮存在", pm.get_node_or_null("Center/Panel/VBox/BtnMenu") != null)
	_check("游戏仍处于暂停", paused)

	# 点设置按钮 → 面板应显示
	pm.get_node("Center/Panel/VBox/BtnSetting").emit_signal("pressed")
	await process_frame
	_check("点设置后设置面板可见", sp.visible)
	_check("打开设置时仍暂停", paused)

	print("\n========== 测试结果 ==========")
	print("通过: ", passed, "  失败: ", failed)
	print("🎉 全部通过！" if failed == 0 else "⚠ 有失败项")
	quit()


## 兼容查找：PauseMenu 现在挂在 Main/UILayer 下（CanvasLayer），
## 老测试脚本还在用 Main/PauseMenu，这里两个路径都试一遍。
static func find_pause_menu(main: Node) -> Node:
	if main == null:
		return null
	var n: Node = main.get_node_or_null("UILayer/PauseMenu")
	if n == null:
		n = main.get_node_or_null("PauseMenu")
	return n
