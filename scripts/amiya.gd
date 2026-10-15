extends CanvasLayer
## 阿米娅语音气泡：每波战斗开始时随机显示一句台词，2 秒后自动消失。
##
## 解耦：这是一个纯展示组件，不认识 GameManager，也不影响任何游戏逻辑。
## 游戏Manager 只要调speak() 就行，它自己不关心台词内容和时机。

signal line_started(text: String)
signal line_finished()

## 显示时长（秒）
@export var display_time: float = 2.0
## 台词库。想加句子直接往数组里塞就行
@export var lines: Array[String] = [
	"博士，注意左侧！",
	"蓄力瞄准，不要急。",
	"做得好，博士。",
	"靶子在移动，预判一下。",
	"别忘了切换元素，空格。",
	"博士，护盾还撑得住。",
	"就是现在，博士！",
	"瞄准线拉长一点会更准。",
	"我知道了。",
]

## 护盾相关的固定台词（say_shield_line 优先从这里挑）
@export var shield_lines: Array[String] = [
	"我知道了。",
	"护盾展开，放心上。",
	"交给我，博士。",
]

@onready var bubble: Control = $Bubble
@onready var label: Label = $Bubble/VBox/Speaker
@onready var line: Label = $Bubble/VBox/Line

var _timer: float = 0.0
var _showing: bool = false
var _last_index: int = -1
var _fade_tween: Tween = null    # 记住当前 tween，连着说话时先掐掉旧的


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停时也能正常消失
	bubble.visible = false
	bubble.modulate.a = 0.0
	print("[Amiya] 阿米娅提示就绪，台词 ", lines.size(), " 句")


## 随机抽一句显示。exclude_index 可以避开上一句，防止连续重复。
func speak(exclude_index: int = -1) -> void:
	if lines.is_empty():
		print("[Amiya] ⚠ 台词库是空的")
		return

	# 避免抽到和上次一样的话
	var idx := 0
	if lines.size() > 1:
		while true:
			idx = randi() % lines.size()
			if idx != exclude_index:
				break

	_last_index = idx
	_show_line(lines[idx])


## ★ 护盾台词接口（玩家释放护盾时调用）。
## 从 shield_lines 里随机挑一句；空了就空壳返回，不报错。
func say_shield_line() -> void:
	if shield_lines.is_empty():
		print("[Amiya] ⚠ shield_lines 为空，护盾台词跳过")
		return
	var idx := randi() % shield_lines.size()
	_last_index = -1      # 护盾台词不参与普通台词的去重计数
	_show_line(shield_lines[idx])


## 显示指定的一句话（speak 和 say_shield_line 共用的底层实现）
func _show_line(text: String) -> void:
	label.text = "阿米娅"
	line.text = text
	bubble.visible = true

	# 淡入（先掐掉旧的淡入淡出，防止抢同一个属性）
	_kill_fade()
	bubble.modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.tween_property(bubble, "modulate:a", 1.0, 0.15)

	_timer = display_time
	_showing = true
	line_started.emit(text)
	print("[Amiya] ", text)


func _process(delta: float) -> void:
	if not _showing:
		return

	_timer -= delta
	if _timer > 0.0:
		return

	_showing = false
	# 淡出，然后隐藏
	_kill_fade()
	_fade_tween = create_tween()
	_fade_tween.tween_property(bubble, "modulate:a", 0.0, 0.25)
	_fade_tween.tween_callback(func() -> void: bubble.visible = false)
	line_finished.emit()
	print("[Amiya] 提示消失")


## 掐掉还在跑的淡入淡出，避免新旧 tween 抢同一个属性
func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


## 当前是否正在显示（给测试用）
func is_showing() -> bool:
	return _showing
