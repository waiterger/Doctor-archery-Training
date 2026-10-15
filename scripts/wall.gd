extends StaticBody2D
## 掩体墙：不可穿透的障碍物，同时给靶子提供「躲藏」价值。
##
## 设计要点：
## 墙本身不参与任何逻辑，只是 StaticBody2D + 可见的 Polygon2D。
## 「玩家可以绕路」这一点由几何保证 —— 墙只有 400 高，
## 而场地高 720，上下都留有 160 像素的通道，足够玩家（半径16）绕过去。

# 墙的半尺寸，Spawner 需要知道这些数据来做安全距离检测
@export var half_size: Vector2 = Vector2(30, 200)

@onready var visual: Polygon2D = $Visual


func _ready() -> void:
	# 让 Spawner 能自动读取墙的位置和大小，
	# 这样以后改墙的位置/大小，不用同步去改 main.tscn 里的导出参数
	add_to_group("walls")
	print("[Wall] ", name, " 就位于 ", global_position.round(),
		"  半尺寸=", half_size, "（上下各留 ", 360 - half_size.y, " 像素通道，可绕行）")


## 供 Spawner 查询：给定点是否落在本墙的「危险区」内（含安全余量）
func is_too_close(p: Vector2, clearance: float) -> bool:
	var d := p - global_position
	return absf(d.x) < half_size.x + clearance and absf(d.y) < half_size.y + clearance


## 供移动靶查询：把墙膨胀 padding 后，是否会挡住这个点。
## 靶子用它做「撞墙前提前反向」的预测，这样就不会糊在墙面上。
func is_blocked(p: Vector2, padding: float) -> bool:
	return is_too_close(p, padding)


## 供移动靶查询：把墙按 radius 膨胀后的矩形（世界坐标）。
## _unstick() 用它把卡在墙里的靶子沿最短轴推出来。
func get_overlap_rect(radius: float) -> Rect2:
	return Rect2(global_position - half_size - Vector2.ONE * radius,
		(half_size + Vector2.ONE * radius) * 2.0)
