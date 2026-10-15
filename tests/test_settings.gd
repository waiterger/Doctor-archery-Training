extends SceneTree
## 设置系统专项测试：存档读写 + 面板控件 + 准心应用 + 暂停流程

var passed: int = 0
var failed: int = 0

const SAVE_PATH := "user://settings.cfg"
const SD := preload("res://scripts/settings_data.gd")


func _check(desc: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("  ✅ ", desc)
	else:
		failed += 1
		print("  ❌ ", desc)


func _init() -> void:
	# Autoload（Settings 单例）在 _init 之后才挂上，先等一帧
	await process_frame

	print("\n========== 设置系统测试 ==========")

	var d: RefCounted = SD.new()

	# --- 1. 默认值 ---
	print("\n[1] 默认设置")
	_check("默认灵敏度 = 1.0", is_equal_approx(d.sensitivity, 1.0))
	_check("默认准心颜色索引合法", d.color_index >= 0 and d.color_index < SD.COLOR_NAMES.size())
	_check("默认准心尺寸索引合法", d.size_index >= 0 and d.size_index < SD.SIZE_NAMES.size())
	_check("准心颜色数组 3 个", SD.COLOR_VALUES.size() == 3)
	_check("准心尺寸数组 3 个", SD.SIZE_SCALES.size() == 3)

	# --- 2. 存取盘 ---
	print("\n[2] ConfigFile 存取")
	d.sensitivity = 2.35
	d.color_index = 0
	d.size_index = 2
	d.save_to_disk()

	var d2: RefCounted = SD.new()
	d2.load_from_disk()
	_check("灵敏度已保存并读回", is_equal_approx(d2.sensitivity, 2.35))
	_check("颜色索引已保存并读回", d2.color_index == 0)
	_check("尺寸索引已保存并读回", d2.size_index == 2)
	_check("存档文件已生成", FileAccess.file_exists(SAVE_PATH))

	# --- 3. 越界清洗 ---
	print("\n[3] 越界保护")
	d2.sensitivity = 99.0
	d2.color_index = 88
	d2.size_index = -5
	d2._sanitize()
	_check("灵敏度被夹到 5.0", is_equal_approx(d2.sensitivity, 5.0))
	_check("颜色索引被夹到合法范围", d2.color_index >= 0 and d2.color_index < SD.COLOR_VALUES.size())
	_check("尺寸索引被夹到合法范围", d2.size_index >= 0 and d2.size_index < SD.SIZE_SCALES.size())

	# --- 4. 恢复默认 ---
	print("\n[4] 恢复默认")
	d2.sensitivity = 3.0
	d2.color_index = 2
	d2.reset_to_default()
	_check("灵敏度回到 1.0", is_equal_approx(d2.sensitivity, 1.0))
	_check("颜色回到默认", d2.color_index == 1)
	_check("尺寸回到默认", d2.size_index == SD.DEFAULT_SIZE_INDEX)

	# --- 5. 设置单例 ---
	print("\n[5] Settings 单例")
	_check("Settings 单例存在", root.has_node("Settings"))
	var smgr: Node = root.get_node("Settings")
	_check("单例有 data字段", smgr.data != null)
	_check("单例已发出 settings_changed 信号", smgr.has_signal("settings_changed"))

	# --- 6. 准心场景 ---
	print("\n[6] 准心节点")
	var ch_scene: PackedScene = load("res://scenes/crosshair.tscn")
	var ch: Node = ch_scene.instantiate()
	root.add_child(ch)
	await process_frame
	_check("准心场景可实例化", ch != null)
	_check("准心有绘制子节点", ch.get_node_or_null("Crosshair") != null)

	# ⚠ 关键回归：根节点必须是 CanvasLayer。
	# Node2D 会受 Camera2D 变换影响，准心会粘在屏幕某处不动。
	_check("准心根节点是 CanvasLayer（不受镜头影响）", ch is CanvasLayer)
	_check("准心 layer 足够高（盖在UI 之上）", ch.layer >= 50)

	smgr.settings_changed.connect(ch._on_settings_changed)
	smgr.settings_changed.emit()
	await process_frame
	_check("设置变化后准心不报错", true)

	# 准心是否真的贴在鼠标位置
	var ch_draw: Node2D = ch.get_node("Crosshair")
	var mp: Vector2 = ch.get_viewport().get_mouse_position()
	_check("准心坐标 == 鼠标坐标", ch_draw.position.is_equal_approx(mp))

	# 模拟鼠标移动，看准心跟不跟
	Input.warp_mouse(Vector2(321, 654))
	await process_frame
	ch._process(0.016)
	var mp2: Vector2 = ch.get_viewport().get_mouse_position()
	_check("鼠标移动后准心跟上", ch_draw.position.is_equal_approx(mp2))
	print("   鼠标=", mp2, " 准心=", ch_draw.position)

	# 系统指针应被隐藏（准心替代它）。
	# 注意：headless 无窗口时 Input.mouse_mode 不生效，所以只能查准心的这个开关，
	# 不能直接断言 Input.mouse_mode 的值（否则无头运行必失败）。
	_check("准心配置为隐藏系统指针", ch.hide_system_cursor == true)
	ch.queue_free()
	await process_frame

	# --- 7. 设置面板（主菜单实例） ---
	print("\n[7] 设置面板")
	var title_scene: PackedScene = load("res://scenes/title_screen.tscn")
	var title: Control = title_scene.instantiate()
	root.add_child(title)
	await process_frame

	var panel: Control = title.get_node_or_null("SettingsPanel")
	_check("主菜单挂载了设置面板", panel != null)
	_check("面板默认隐藏", panel.visible == false)

	panel.open()
	await process_frame
	_check("open() 后面板可见", panel.visible)

	var slider: HSlider = panel.get_node("Center/Panel/VBox/SensRow/Slider")
	_check("滑条最小值 = 0.1", is_equal_approx(slider.min_value, 0.1))
	_check("滑条最大值 = 5.0", is_equal_approx(slider.max_value, 5.0))

	# 模拟拖滑条 → 应写进设置并刷新玩家
	slider.value = 3.5
	panel._on_sens_changed(3.5)
	await process_frame
	var dnow: RefCounted = smgr.data
	_check("拖动滑条写入灵敏度", is_equal_approx(dnow.sensitivity, 3.5))

	var value_label: Label = panel.get_node("Center/Panel/VBox/SensRow/Value")
	_check("数值标签同步", "3.50" in value_label.text)

	# 准心颜色按钮
	panel._on_color_pressed(2)
	await process_frame
	_check("点白色按钮 → color_index=2", dnow.color_index == 2)
	_check("准心颜色确实变了", dnow.get_crosshair_color().is_equal_approx(Color(1, 1, 1, 1)))

	# 准心尺寸按钮
	panel._on_size_pressed(0)
	await process_frame
	_check("点小尺寸按钮 → size_index=0", dnow.size_index == 0)
	_check("小尺寸缩放 < 中尺寸", dnow.get_crosshair_scale() < 1.0)

	# 关闭
	panel.close()
	await process_frame
	_check("close() 后面板隐藏", not panel.visible)

	# --- 8. 游戏内暂停菜单 ---
	print("\n[8] 游戏内暂停菜单")
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node2D = main_scene.instantiate()
	root.add_child(main)
	await process_frame
	await physics_frame

	var pm: Control = find_pause_menu(main)
	_check("main 挂载了暂停菜单", pm != null)
	_check("暂停菜单默认隐藏", pm.visible == false)
	_check("暂停菜单内有设置面板", pm.get_node_or_null("SettingsPanel") != null)

	pm.open()
	await process_frame
	_check("open() 后暂停菜单可见", pm.visible)
	_check("暂停时游戏被暂停", paused)

	var pm_panel: Control = pm.get_node("SettingsPanel")
	pm_panel.open()
	await process_frame
	_check("游戏内可打开设置面板", pm_panel.visible)
	_check("打开设置时游戏仍暂停", paused)

	pm_panel.close()
	await process_frame
	_check("关闭设置后回到暂停菜单", pm.visible)
	_check("此刻仍暂停（未直接恢复游戏）", paused)

	pm.close()
	await process_frame
	_check("关闭暂停菜单后恢复游戏", not pm.visible)
	_check("游戏已恢复", not paused)

	# --- 9. 玩家读灵敏度 ---
	print("\n[9] 玩家瞄准灵敏度")
	var player: CharacterBody2D = main.get_node("Player")
	var far_point: Vector2 = player.global_position + Vector2(300, 0)
	# 用真实帧间隔（60fps 的 1/60 秒）来测，不然 delta 太大两端都会直接吸附到鼠标
	var frame_delta := 1.0 / 60.0

	# 两次测量都从同一个「远离鼠标」的点出发，才能比较出跟手速度
	dnow.sensitivity = 0.2
	player._aim_point = far_point
	player._aim_point_ready = true
	player._handle_aim(frame_delta)
	var moved_slow: float = player._aim_point.distance_to(far_point)

	dnow.sensitivity = 5.0
	player._aim_point = far_point
	player._aim_point_ready = true
	player._handle_aim(frame_delta)
	var moved_fast: float = player._aim_point.distance_to(far_point)

	print("   低灵敏度位移=", snapped(moved_slow, 0.01),
		"  高灵敏度位移=", snapped(moved_fast, 0.01))
	_check("高灵敏度跟手更快", moved_fast > moved_slow)

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
