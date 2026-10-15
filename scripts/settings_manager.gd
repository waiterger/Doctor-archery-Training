extends Node
## 设置单例（Autoload 名为 Settings）：全局唯一的设置存放处。
##
## 为什么要有这一层：准心、玩家、主菜单都要读同一份设置，
## 让它们都去 load() 同一个 .gd 写文件很别扭，所以做成单例。

signal settings_changed

const SD := preload("res://scripts/settings_data.gd")

var data: RefCounted = SD.new()


func _ready() -> void:
	# 启动时自动读取并应用
	data.load_from_disk()
	print("[Settings] 单例就绪")


## 改完设置后统一调这个，外部监听 settings_changed 就能实时刷新
func apply() -> void:
	settings_changed.emit()
	data.save_to_disk()


func reset_to_default() -> void:
	data.reset_to_default()
	apply()
