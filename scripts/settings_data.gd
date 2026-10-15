extends RefCounted
## 全局设置：鼠标灵敏度 + 准心外观，用 ConfigFile 存到 user://settings.cfg。
##
## 解耦：这是一个「纯数据 + 存取」的工具类，不认识任何节点。
## 别的脚本改了这里的值之后，自己去 apply（比如玩家读灵敏度、准心读颜色）。
## 想让设置实时生效，只要让消费方在 _process 里读这里的值就行。

const SAVE_PATH := "user://settings.cfg"

# ---- 准心可选值 ----
const COLOR_NAMES: Array[String] = ["红", "绿", "白"]
const COLOR_VALUES: Array[Color] = [
	Color(1.0, 0.32, 0.32, 1.0),
	Color(0.32, 1.0, 0.45, 1.0),
	Color(1.0, 1.0, 1.0, 1.0),
]
const SIZE_NAMES: Array[String] = ["小", "中", "大"]
const SIZE_SCALES: Array[float] = [0.6, 1.0, 1.6]
const DEFAULT_SIZE_INDEX := 1

# ---- 当前设置值 ----
var sensitivity: float = 1.0
var color_index: int = 1
var size_index: int = DEFAULT_SIZE_INDEX


## 从磁盘读取。文件不存在就用默认值（第一次运行必然走这条路）。
func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		print("[Settings] 没有找到 ", SAVE_PATH, "，使用默认设置")
		_reset_to_default()
		return

	sensitivity = float(cfg.get_value("aim", "sensitivity", 1.0))
	color_index = int(cfg.get_value("crosshair", "color_index", 1))
	size_index = int(cfg.get_value("crosshair", "size_index", DEFAULT_SIZE_INDEX))
	_sanitize()
	print("[Settings] 已读取设置：灵敏度=", sensitivity,
		" 准心=", COLOR_NAMES[color_index], "/", SIZE_NAMES[size_index])


## 写回磁盘
func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("aim", "sensitivity", sensitivity)
	cfg.set_value("crosshair", "color_index", color_index)
	cfg.set_value("crosshair", "size_index", size_index)

	var err := cfg.save(SAVE_PATH)
	if err == OK:
		print("[Settings] 已保存 → ", SAVE_PATH)
	else:
		print("[Settings] ✗ 保存失败，错误码 ", err)
	print("  灵敏度=", snapped(sensitivity, 0.01),
		" 准心=", COLOR_NAMES[color_index], "/", SIZE_NAMES[size_index])


## 恢复默认值并立刻存盘
func reset_to_default() -> void:
	_reset_to_default()
	save_to_disk()
	print("[Settings] 已恢复默认设置")


func _reset_to_default() -> void:
	sensitivity = 1.0
	color_index = 1
	size_index = DEFAULT_SIZE_INDEX


## 防止手改存档写出越界值
func _sanitize() -> void:
	sensitivity = clampf(sensitivity, 0.1, 5.0)
	color_index = clampi(color_index, 0, COLOR_NAMES.size() - 1)
	size_index = clampi(size_index, 0, SIZE_NAMES.size() - 1)


## 给准心用的便捷接口
func get_crosshair_color() -> Color:
	return COLOR_VALUES[clampi(color_index, 0, COLOR_VALUES.size() - 1)]


func get_crosshair_scale() -> float:
	return SIZE_SCALES[clampi(size_index, 0, SIZE_SCALES.size() - 1)]
