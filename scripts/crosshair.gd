extends CanvasLayer
## 游戏内准心：跟随鼠标绘制，颜色和大小由 Settings 决定。
##
## ⚠ 关键：根节点必须是 CanvasLayer，不能是 Node2D。
## Node2D 会受 Camera2D 的镜头变换影响，把屏幕坐标当成世界坐标，
## 结果准心会「粘」在屏幕某处不动（之前就踩过这个坑）。
## CanvasLayer 是纯屏幕坐标系，get_viewport().get_mouse_position() 才对得上。
##
## layer 设得很高，保证画在 HUD / BuffUI / 暂停菜单之上，不会被UI 遮住。
## 同时隐藏系统鼠标指针，让准心成为唯一的瞄准指示。

@export var base_size: float = 14.0   # 中号准心的半径
@export var hide_system_cursor: bool = true

# ---- 节点引用 ----
@onready var crosshair: Node2D = $Crosshair

# 当前生效值
var _color: Color = Color.WHITE
var _scale: float = 1.0


func _ready() -> void:
	# 画在所有 CanvasLayer 之上（HUD/BuffUI/暂停菜单默认 layer 是 1~10）
	layer = 100
	# 暂停时也要能跟着鼠标，所以不能因为游戏暂停就停摆
	process_mode = Node.PROCESS_MODE_ALWAYS

	Settings.settings_changed.connect(_on_settings_changed)
	_apply()

	if hide_system_cursor:
		# 隐藏系统指针，用准心代替。关掉游戏时 Godot 会自动恢复
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

	# 立刻摆到鼠标上，避免第一帧闪在(0,0)
	_update_position()
	print("[Crosshair] 准心就绪（隐藏系统指针，跟随鼠标）")


func _exit_tree() -> void:
	# 离开这个场景（死亡结算、重开、回主菜单）时把系统指针还回去，
	# 否则主菜单会没有鼠标可点
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(_delta: float) -> void:
	_update_position()


## 准心贴住鼠标。
## get_viewport().get_mouse_position() 返回的是视口屏幕坐标，
## 和 CanvasLayer 子节点的坐标系一致，直接用就行。
func _update_position() -> void:
	crosshair.position = get_viewport().get_mouse_position()


func _on_settings_changed() -> void:
	_apply()


## 读取设置并刷新外观
func _apply() -> void:
	var d: RefCounted = Settings.data
	_color = d.get_crosshair_color()
	_scale = d.get_crosshair_scale()

	crosshair.scale = Vector2.ONE * _scale
	crosshair.visible = true
	# 颜色变了要重画，否则改的是上一帧的颜色
	crosshair.queue_redraw()
	_update_position()


## 供外部查询当前状态
func get_color() -> Color:
	return _color


## 注意：不能叫 get_scale()，会和 Node2D 的原生方法冲突
func get_crosshair_scale() -> float:
	return _scale


## 准心当前是否压在鼠标位置上（给测试用）
func is_on_cursor() -> bool:
	return crosshair.position.is_equal_approx(get_viewport().get_mouse_position())
