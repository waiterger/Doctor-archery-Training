extends Node
## 心流状态管理器（Autoload 名为 Flow）：
## Q 键触发，持续 5 秒，冷却 20 秒。
##
#### ⚠⚠ 绝对不要用 Engine.time_scale 实现减速！
## time_scale 会把【整个场景树的时间】一起放慢，包括：
##   - HitStop 顿帧（它本身就是靠 time_scale 实现的，会和心流互相打架）
##   - VideoStreamPlayer 播放复活视频（Godot 的视频走自己的时钟，
##     改time_scale 不保证表现一致，且容易在暂停态下彻底卡死）
##   - Tween 动画（飘字/震屏）
## 所以这里只改【靶子自己的速度倍率】和【玩家蓄力时间】，
## 全部是局部变量，物理时间流速完全不受影响。
##
## 效果：
##   - 全场靶子移速 × flow_enemy_slow（默认 0.5，即减速 50%）
##   - 玩家蓄力时间 × flow_charge_mult（默认 0.5，即蓄力加速一倍）
##   - 箭矢染成金色
##   5 秒后自动恢复。

## 心流状态变化（HUD 监听它刷新 CD 显示）
signal flow_changed(active: bool, cooldown_left: float)

@export var flow_duration: float = 5.0        # 持续秒数
@export var flow_cooldown: float = 20.0       # 冷却秒数
@export var flow_enemy_slow: float = 0.5      # 靶子速度倍率（0.5 = 减速 50%）
@export var flow_charge_mult: float = 0.5# 蓄力时间倍率（0.5 = 蓄力加速一倍）

var _active: bool = false
var _left: float = 0.0        # 剩余持续时间
var _cooldown_left: float = 0.0      # 剩余冷却时间
## 读界面的「可忽略冷却开关」：商店/事件可临时关掉冷却
var cooldown_enabled: bool = true


func _enter_tree() -> void:
	# ⚠ 必须在 _enter_tree 里设（比 _ready 更早生效），
	# 这样 Autoload 从加入场景树那一刻起就受暂停控制。
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	print("[Flow] 心流系统就绪  持续 ", flow_duration, "s  冷却 ", flow_cooldown, "s")


func _physics_process(delta: float) -> void:
	# ⚠⚠ 暂停时【冻结所有计时器】。
	# process_mode 已设 PAUSABLE，这里再加一道显式守卫做双保险：
	# ESC 暂停后心流持续时间和冷却时间都静止，恢复游戏才继续倒计时。
	if get_tree().paused:
		return

	var changed := false

	# 持续计时
	if _active:
		_left -= delta
		if _left <= 0.0:
			_active = false
			_left = 0.0
			if cooldown_enabled:
				_cooldown_left = flow_cooldown
			print("[Flow] 心流结束，敌人恢复原速")
			changed = true

	# 冷却计时
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - delta, 0.0)
		changed = true

	if changed:
		flow_changed.emit(_active, _cooldown_left)


## 玩家按 Q 时调用。返回是否成功触发。
func try_activate() -> bool:
	if _active:
		print("[Flow] 心流进行中，无法重复触发")
		return false
	if _cooldown_left > 0.0:
		print("[Flow] 心流冷却中，还剩 ", snapped(_cooldown_left, 1), "s")
		return false

	_active = true
	_left = flow_duration
	# 第一次触发时把 CD 排上（这样一结束玩家就知道还要等多久）
	if cooldown_enabled:
		_cooldown_left = flow_cooldown
	print("[Flow] ★ 心流启动！敌人减速 ", int((1.0 - flow_enemy_slow) * 100),
		"%，蓄力加速 ", int((1.0 - flow_charge_mult) * 100), "%  持续 ",
		flow_duration, "s")
	flow_changed.emit(_active, _cooldown_left)
	return true


# --------------------------------------------------
# 供其他节点查询（这就是「局部减速」的唯一入口）
# --------------------------------------------------

## 心流是否进行中
func is_active() -> bool:
	return _active


## 剩余持续秒数
func time_left() -> float:
	return _left


## 剩余冷却秒数
func cooldown_left() -> float:
	return _cooldown_left


## 靶子速度倍率：平时 1.0，心流中 0.5
func enemy_speed_mult() -> float:
	return flow_enemy_slow if _active else 1.0


## 玩家蓄力时间倍率：平时 1.0，心流中 0.5
func charge_time_mult() -> float:
	return flow_charge_mult if _active else 1.0


## 给 HUD 用的状态文本
func status_text() -> String:
	if _active:
		return "心流：生效中 %.1fs" % _left
	if _cooldown_left > 0.0:
		return "心流：冷却 %.1fs" % _cooldown_left
	return "心流：就绪"


## HUD 进度条用：就绪 1.0 / 冷却中按剩余比例 / 生效中 1.0
func cooldown_ratio() -> float:
	if _active:
		return 1.0
	if flow_cooldown <= 0.0:
		return 1.0
	return clampf(1.0 - _cooldown_left / flow_cooldown, 0.0, 1.0)


## ★ 强制重置为「就绪」状态。
## ⚠ 必须在「开始新一局」时调用：Flow 是 Autoload 单例，
## reload_current_scene() 不会重建它，新一局开局会带着上一局的
## 剩余冷却 / 生效中状态。
func hard_reset() -> void:
	var was_active := _active
	_active = false
	_left = 0.0
	_cooldown_left = 0.0
	if was_active:
		flow_changed.emit(false, 0.0)
	print("[Flow] ♻ 心流状态已重置为就绪")