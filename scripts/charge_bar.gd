extends Control
## 蓄力进度条：挂在玩家身上，靠 _process 每帧读玩家的状态刷新自己。
## 用「拉长宽度」而不是 ProgressBar 节点，是为了让新手能直接看懂发生了什么。

# 玩家引用，直接在检查器里拖进来
@export var player_path: NodePath

@onready var bar_bg: Control = $BarBg
@onready var bar_fill: ColorRect = $BarBg/Fill
@onready var label: Label = $Label

# 背景条的完整宽度，用来算填充比例
var _full_width: float = 240.0


func _ready() -> void:
	print("[ChargeBar] 蓄力条初始化")
	visible = false  # 默认隐藏，只在蓄力时显示
	# 记录背景宽度（BarBg 的尺寸）
	_full_width = bar_bg.size.x
	print("[ChargeBar] 满格宽度 = ", _full_width, " 像素")


func _process(_delta: float) -> void:
	var player := get_node_or_null(player_path) as Node2D
	if player == null:
		return

	# 玩家身上有这两个变量；没有就说明还没写，先安全退出
	if not player.has_method("get_charge_ratio"):
		return

	var ratio: float = player.get_charge_ratio()
	var is_charging: bool = player.is_charging()

	# 没在蓄力就隐藏
	visible = is_charging
	if not is_charging:
		return

	# 拉长填充条
	bar_fill.size.x = _full_width * ratio

	# 颜色随蓄力从青变红
	bar_fill.color = Color(0.35, 0.85, 1.0).lerp(Color(1.0, 0.4, 0.25), ratio)

	# 文字提示，并标出「可发射阈值」
	label.text = "蓄力 %d%%" % int(ratio * 100.0)
