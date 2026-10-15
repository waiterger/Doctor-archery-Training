extends Node
class_name HitFlash
## 受击闪白组件：受击瞬间整块纯白，duration 秒后平滑恢复原色。
##
## 挂在靶子的子节点上，自动给父节点下的 2D 图形（Polygon2D / Sprite2D / Line2D）
## 挂上同一个 shader 材质，只改 shader 参数，不碰节点自身的 color。
## 所以靶子被冰冻（蓝）或点燃（橙）时，闪白依然能正常播。
##
## 用法：$HitFlash.flash()  或  $HitFlash.flash(0.2)

const FLASH_SHADER := preload("res://scripts/hit_flash.gdshader")

@export var duration: float = 0.1   # 闪白持续秒数
@export var peak: float = 1.0# 闪白最亮程度（1 = 纯白）

var _mats: Array[ShaderMaterial] = []
var _tw: Tween = null


func _ready() -> void:
	var root := get_parent()
	if root == null:
		root = self

	for n in root.find_children("*", "", true, false):
		if not (n is Polygon2D or n is Sprite2D or n is AnimatedSprite2D or n is Line2D):
			continue
		var m := ShaderMaterial.new()
		m.shader = FLASH_SHADER
		m.set_shader_parameter("flash", 0.0)
		n.material = m
		_mats.append(m)


## 触发一次闪白。dur <= 0 时用 duration。
func flash(dur: float = -1.0) -> void:
	if _mats.is_empty():
		return
	# 连击时重新计时，不会出现「后一发被前一发的 tween 提前拉回」
	if _tw != null and _tw.is_valid():
		_tw.kill()

	_set_flash(peak)
	_tw = create_tween()
	_tw.tween_method(_set_flash, peak, 0.0, duration if dur <= 0.0 else dur)


func _set_flash(v: float) -> void:
	for m in _mats:
		if is_instance_valid(m):
			m.set_shader_parameter("flash", v)