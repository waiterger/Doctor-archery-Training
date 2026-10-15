extends Node2D
## 准心的实际绘制：一个空心圆 + 一个中心点。
## 颜色由外部（crosshair.gd）通过 queue_redraw() 触发刷新。

@export var radius: float = 14.0
@export var line_width: float = 2.0
@export var show_center_dot: bool = true

var col: Color = Color.WHITE


func _draw() -> void:
	# 空心圆：画一圈
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, col, line_width, true)

	# 四条短刻度线，比纯圆圈更「准」
	var t := line_width * 2.0
	var gap := radius * 0.55
	for i in 4:
		var ang := float(i) * TAU / 4.0
		var dir := Vector2.RIGHT.rotated(ang)
		draw_line(dir * gap, dir * (gap + t), col, line_width, true)

	# 中心点
	if show_center_dot:
		draw_circle(Vector2.ZERO, line_width * 0.9, col)
