extends Label
class_name DamageNumber
## 命中飘字：在命中位置生成一个伤害数字，向上飘 + 渐隐 + 放大回弹后自毁。
##
## 不需要 .tscn，代码直接 new 出来用，避免场景里多一堆空节点。
##
## 用法（箭矢命中时调）：
##   DamageNumber.spawn(self, hit_pos, damage, Color(1, 0.9, 0.4))

const LAYER_GROUP := "damage_layer"   # 飘字挂载层，main.tscn 里的 DamageNumbers 节点

@export var rise_height: float = 46.0   # 上飘多少像素
@export var life_time: float = 0.7      # 总存活时间
@export var font_px: int = 22
@export var pop_scale: float = 1.35# 出现时的放大倍率


## 静态入口：在 world_pos 处飘一个数字
static func spawn(host: Node, world_pos: Vector2, amount: float,
		color: Color = Color(1.0, 1.0, 1.0), crit: bool = false) -> void:
	_show(host, world_pos, str(int(round(amount))), color, 22 if not crit else 32)


## 文字飘字：用于元素反应提示（"蒸发！" "融化！" "冻结！"）
static func spawn_text(host: Node, world_pos: Vector2, text: String,
		color: Color = Color(1.0, 0.85, 0.3), font_px: int = 26) -> void:
	_show(host, world_pos, text, color, font_px)


## 两个入口共用的实现
static func _show(host: Node, world_pos: Vector2, content: String,
		color: Color, font_px: int) -> void:
	if host == null or not is_instance_valid(host):
		return
	var layer := _get_layer(host)
	if layer == null:
		return

	var dn := DamageNumber.new()
	dn.text = content
	dn.font_px = font_px
	dn.z_index = 100# 飘在所有角色之上
	dn.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 描边：深色底 + 彩字，浅色场地/深色场地都看得清
	dn.add_theme_color_override("font_color", color)
	dn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	dn.add_theme_constant_override("outline_size", 7)
	dn.add_theme_font_size_override("font_size", dn.font_px)
	dn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	layer.add_child(dn)
	# 随机水平偏移，避免多个数字完全重叠
	dn.global_position = world_pos + Vector2(randf_range(-16.0, 16.0), -14.0)
	# Label 自身以左上角为锚点，往左上挪一半让文字中心对准命中点
	dn.position -= dn.size * 0.5

	dn._play()


## 找一个能承载飘字的父节点
static func _get_layer(host: Node) -> Node:
	var tree := host.get_tree()
	if tree == null:
		return null
	var n := tree.get_first_node_in_group(LAYER_GROUP)
	if n != null:
		return n
	# 找不到专属层就退而求其次，挂在场景根下
	return tree.current_scene


func _play() -> void:
	scale = Vector2(pop_scale, pop_scale)
	modulate = Color(color_tint(), 1.0)

	var tw := create_tween()
	tw.set_parallel(true)
	# 出现瞬间先放大再弹回 1.0，手感更「脆」
	tw.tween_property(self, "scale", Vector2.ONE, 0.14)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 向上飘
	tw.tween_property(self, "position:y", position.y - rise_height, life_time)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 后半程渐隐
	tw.tween_property(self, "modulate:a", 0.0, life_time * 0.55)\
		.set_delay(life_time * 0.45)
	# 到点自毁
	tw.set_parallel(false)
	tw.tween_callback(queue_free)


func color_tint() -> Color:
	return get_theme_color("font_color")