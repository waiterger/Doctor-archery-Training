extends Control
## 设置面板：灵敏度滑条 + 准心颜色/尺寸按钮。
##
## 一个场景两处复用：
##  - 主菜单：Settings 打开，关掉回到主菜单
##  - 游戏内：暂停时打开，关掉自动恢复游戏
##
## 解耦：面板只和 Settings 单例打交道，不认识玩家、不认识 GameManager。
## 关闭方式是发signal，由调用方决定之后干什么。

signal closed
signal applied

const SD := preload("res://scripts/settings_data.gd")
const CF := preload("res://scripts/center_fix.gd")

@onready var sens_slider: HSlider = $Center/Panel/VBox/SensRow/Slider
@onready var sens_value: Label = $Center/Panel/VBox/SensRow/Value
@onready var color_btns: Array[Button] = [
	$Center/Panel/VBox/ColorRow/ColorRed,
	$Center/Panel/VBox/ColorRow/ColorGreen,
	$Center/Panel/VBox/ColorRow/ColorWhite,
]
@onready var size_btns: Array[Button] = [
	$Center/Panel/VBox/SizeRow/SizeSmall,
	$Center/Panel/VBox/SizeRow/SizeMedium,
	$Center/Panel/VBox/SizeRow/SizeLarge,
]
@onready var btn_close: Button = $Center/Panel/VBox/BtnClose
@onready var btn_default: Button = $Center/Panel/VBox/BtnDefault
@onready var preview: Node2D = $Center/Panel/VBox/PreviewBox/Preview/Crosshair

##★ 音量三条（节点路径：Center/Panel/VBox/<XxxRow>/{Slider,Value}）
@onready var bgm_slider: HSlider = $Center/Panel/VBox/BgmRow/Slider
@onready var bgm_value: Label = $Center/Panel/VBox/BgmRow/Value
@onready var sfx_slider: HSlider = $Center/Panel/VBox/SfxRow/Slider
@onready var sfx_value: Label = $Center/Panel/VBox/SfxRow/Value
@onready var voice_slider: HSlider = $Center/Panel/VBox/VoiceRow/Slider
@onready var voice_value: Label = $Center/Panel/VBox/VoiceRow/Value

var _syncing: bool = false      # 防止程序化赋值又触发回调


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	# 布局兜底：本面板铺满全屏，内部 Center 自动居中
	CF.fix_pause_menu(self)

	sens_slider.min_value = 0.1
	sens_slider.max_value = 5.0
	sens_slider.step = 0.1
	sens_slider.value_changed.connect(_on_sens_changed)

	# ★ 音量三条：范围 0~100，拖动实时生效 + 立即存档
	for s in [bgm_slider, sfx_slider, voice_slider]:
		s.min_value = 0.0
		s.max_value = 100.0
		s.step = 1.0
	bgm_slider.value_changed.connect(_on_bgm_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	voice_slider.value_changed.connect(_on_voice_changed)
	_sync_audio_ui()

	for i in color_btns.size():
		color_btns[i].pressed.connect(_on_color_pressed.bind(i))
	for i in size_btns.size():
		size_btns[i].pressed.connect(_on_size_pressed.bind(i))

	btn_close.pressed.connect(_on_close)
	btn_default.pressed.connect(_on_default)

	print("[SettingsPanel] 面板就绪（灵敏度0.1~5.0 准心3 色 3 尺寸 音量3条）")


# ============================================================
# 音量：UI ↔ AudioManager
# ============================================================
## 把 AudioManager 里存的值刷到三个滑条上（打开面板时调用）
func _sync_audio_ui() -> void:
	if not _has_audio_manager():
		return
	_syncing = true# 防止程序化赋值触发回调造成死循环
	bgm_slider.value = AudioManager.get_bus_volume("BGM")
	sfx_slider.value = AudioManager.get_bus_volume("SFX")
	voice_slider.value = AudioManager.get_bus_volume("Voice")
	_update_vol_labels()
	_syncing = false


## AudioManager 单例是否存在（设置面板在很多场景都用，判空更安全）
func _has_audio_manager() -> bool:
	return get_tree() != null and get_tree().root.has_node("AudioManager")


## 拖动时更新右侧数字
func _update_vol_labels() -> void:
	bgm_value.text = str(int(round(bgm_slider.value)))
	sfx_value.text = str(int(round(sfx_slider.value)))
	voice_value.text = str(int(round(voice_slider.value)))


## 三条的统一处理：设音量 + 存盘
func _apply_vol(bus_name: String, value: float) -> void:
	_update_vol_labels()
	if _syncing:
		return# 程序化赋值，不重复应用
	if not _has_audio_manager():
		return
	AudioManager.set_bus_volume(bus_name, value)
	# 拖动过程中就存盘，关闭面板时不用再存
	AudioManager.save_settings()


func _on_bgm_changed(v: float) -> void:
	_apply_vol("BGM", v)


func _on_sfx_changed(v: float) -> void:
	_apply_vol("SFX", v)


func _on_voice_changed(v: float) -> void:
	_apply_vol("Voice", v)


## 打开面板：把当前设置同步到控件上
func open() -> void:
	visible = true
	# 面板要能点按钮，所以把系统指针放出来（准心层会自动让位）
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sync_from_settings()
	# ★ 音量也同步一次（可能在上次面板打开后被别处改过）
	_sync_audio_ui()
	btn_close.grab_focus()
	print("[SettingsPanel] 打开设置")


func close() -> void:
	visible = false
	closed.emit()


# --------------------------------------------------
# 同步：设置 → 控件
# --------------------------------------------------
func _sync_from_settings() -> void:
	_syncing = true
	var d: RefCounted = Settings.data

	sens_slider.value = d.sensitivity
	sens_value.text = "%.2f×" % d.sensitivity

	for i in color_btns.size():
		color_btns[i].button_pressed = (i == d.color_index)
	for i in size_btns.size():
		size_btns[i].button_pressed = (i == d.size_index)

	_update_preview()
	_syncing = false


## 刷新面板里的准心预览（复用玩家准心的绘制脚本）
func _update_preview() -> void:
	var d: RefCounted = Settings.data
	preview.set("col", d.get_crosshair_color())
	preview.scale = Vector2.ONE * d.get_crosshair_scale() * 1.6
	preview.queue_redraw()


# --------------------------------------------------
# 控件 → 设置
# --------------------------------------------------
func _on_sens_changed(v: float) -> void:
	if _syncing:
		return
	var d: RefCounted = Settings.data
	d.sensitivity = v
	sens_value.text = "%.2f×" % v
	Settings.apply()          # 存盘 + 通知玩家和准心生效
	applied.emit()
	print("[SettingsPanel] 灵敏度 → ", snapped(v, 0.01))


func _on_color_pressed(index: int) -> void:
	if _syncing:
		return
	var d: RefCounted = Settings.data
	d.color_index = index
	_update_preview()
	Settings.apply()
	print("[SettingsPanel] 准心颜色 → ", SD.COLOR_NAMES[index])


func _on_size_pressed(index: int) -> void:
	if _syncing:
		return
	var d: RefCounted = Settings.data
	d.size_index = index
	_update_preview()
	Settings.apply()
	print("[SettingsPanel] 准心尺寸 → ", SD.SIZE_NAMES[index])


func _on_default() -> void:
	Settings.reset_to_default()
	_sync_from_settings()
	# ★ 音量也恢复默认（BGM=60 SFX=100 Voice=80）并存档
	if _has_audio_manager():
		AudioManager.set_bus_volume("BGM", 60.0)
		AudioManager.set_bus_volume("SFX", 100.0)
		AudioManager.set_bus_volume("Voice", 80.0)
		AudioManager.save_settings()
		_sync_audio_ui()
	applied.emit()
	print("[SettingsPanel] 已恢复默认（含音量）")


func _on_close() -> void:
	print("[SettingsPanel] 关闭设置")
	close()


func _unhandled_input(event: InputEvent) -> void:
	# 游戏内按 ESC 关面板（关掉后由调用方恢复游戏）
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()
