extends CanvasLayer
## 肉鸽 HUD：波次、分数、倒计时、场上剩余靶子。
## 用信号接收 GameManager 的状态变化，不主动去读别人的数据。

@onready var wave_label: Label = $WaveLabel
@onready var score_label: Label = $ScoreLabel
@onready var timer_label: Label = $TimerLabel
@onready var remain_label: Label = $RemainLabel
@onready var hp_label: Label = $HpLabel
@onready var gold_label: Label = $GoldLabel
@onready var flow_label: Label = $FlowLabel
@onready var flow_bar: ProgressBar = $FlowBar
@onready var shield_cd_label: Label = $ShieldCDLabel
@onready var element_label: Label = $ElementLabel

# 上一次显示的值，避免每帧重复设置（Label 频繁改 text 会触发重排）
var _last_wave := -1
var _last_score := -1
var _last_timer := -1.0
var _last_remain := -1
var _last_hp := -1
var _last_gold := -1
var _last_element := ""


func _ready() -> void:
	print("[HUD] 界面初始化")
	# 兜底自检：如果节点路径写错了，这里会立刻告诉我们，而不是后面一堆空引用报错
	for n in [["wave", wave_label], ["score", score_label],
			["timer", timer_label], ["remain", remain_label],
			["hp", hp_label],
			["gold", gold_label],
			["flow", flow_label],
			["flow_bar", flow_bar],
			["shield_cd", shield_cd_label],
			["element", element_label]]:
		if n[1] == null:
			push_warning("[HUD] ⚠ 找不到节点: ", n[0])


func update_wave(wave: int) -> void:
	if wave == _last_wave or wave_label == null:
		return
	_last_wave = wave
	wave_label.text = "第 %d 波" % wave


func update_score(score: int) -> void:
	if score == _last_score or score_label == null:
		return
	_last_score = score
	score_label.text = "分数 %d" % score


func update_timer(seconds: float) -> void:
	if timer_label == null:
		return

	# 战斗阶段传 -1，表示「不在倒计时」
	if seconds < 0.0:
		if _last_timer != -1.0:
			_last_timer = -1.0
			timer_label.modulate = Color(0.6, 0.9, 1.0)
			timer_label.text = "战斗中"
		return

	# 向上取整显示，玩家看到的是「还剩几秒」而不是一堆小数
	var s := int(ceil(seconds))
	if s == _last_timer:
		return
	_last_timer = s
	# 最后 5 秒变红，制造紧张感
	timer_label.modulate = Color(1, 0.4, 0.35) if s <= 5 else Color(1, 1, 1)
	timer_label.text = "下一波 %d s" % s


func update_remaining(n: int) -> void:
	if n == _last_remain or remain_label == null:
		return
	_last_remain = n
	remain_label.text = "剩余靶子 %d" % n


func update_hp(hp: int, max_hp: int) -> void:
	if hp == _last_hp or hp_label == null:
		return
	_last_hp = hp
	# 血量越低越红，给出压迫感
	hp_label.text = "HP %d / %d" % [hp, max_hp]
	if hp <= 1:
		hp_label.modulate = Color(1.0, 0.28, 0.28)
	elif hp <= 2:
		hp_label.modulate = Color(1.0, 0.55, 0.3)
	else:
		hp_label.modulate = Color(1, 1, 1)


## 金币显示（GameManager.add_gold 调用）
func update_gold(n: int) -> void:
	if n == _last_gold or gold_label == null:
		return
	_last_gold = n
	gold_label.text = "金币：%d" % n
	# 每满10 金币闪一下金色，给点正反馈
	gold_label.modulate = Color(1, 0.84, 0.32) if n % 10 == 0 else Color.WHITE


## 心流状态显示（Q 键技能）
## status: "心流：就绪" / "心流：生效中 4.2s" / "心流：冷却 12.5s"
## ratio:0~1 的冷却进度（就绪=1，生效中=1，冷却中按剩余比例）
## active: 是否正在生效
func update_flow(status: String, ratio: float, active: bool) -> void:
	if flow_label != null:
		if flow_label.text != status:
			flow_label.text = status
		# 生效中亮金，冷却中暗灰，就绪正常色
		if active:
			flow_label.modulate = Color(1, 0.9, 0.4)
		elif ratio >= 0.999:
			flow_label.modulate = Color(0.85, 0.95, 1)
		else:
			flow_label.modulate = Color(0.6, 0.62, 0.68)
	if flow_bar != null:
		flow_bar.value = clampf(ratio, 0.0, 1.0) * 100.0
		var fill := flow_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if fill != null:
			fill.bg_color = Color(1, 0.8, 0.25) if active else Color(0.4, 0.55, 0.7)


## 阿米娅护盾状态显示（中键技能）
## status: "阿米娅护盾：就绪（按中键释放）" / "生效中（剩余 X 秒）" / "冷却中（X 秒）"
## ready: 是否可用（就绪时高亮引导玩家去按）
## active: 是否正在生效
func update_shield(status: String, ready: bool, active: bool) -> void:
	if shield_cd_label == null:
		return
	if shield_cd_label.text != status:
		shield_cd_label.text = status
	if active:
		# 生效中：亮蓝 + 轻微脉动感（modulate 偏亮）
		shield_cd_label.modulate = Color(0.7, 0.95, 1.0)
	elif ready:
		# 就绪：金色高亮，提醒玩家可以按
		shield_cd_label.modulate = Color(1.0, 0.88, 0.45)
	else:
		# 冷却中：压暗
		shield_cd_label.modulate = Color(0.55, 0.58, 0.64)


## 显示当前附着的元素。
## ⚠ 元素切换已从 Q 键改为【空格键】。
## 只拥有一种元素时只显示元素名；两种以上才提示按空格切换。
func update_element(name: String, color: Color, can_switch: bool) -> void:
	if element_label == null:
		return
	var tip := "（空格 切换）" if can_switch else ""
	var txt := "当前：%s%s" % [name, tip]
	if txt == _last_element:
		return
	_last_element = txt
	element_label.text = txt
	element_label.modulate = color
