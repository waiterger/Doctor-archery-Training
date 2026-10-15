extends Camera2D
class_name ScreenShake
## 屏幕震动：命中时给相机一个短促的微小随机偏移。
##
## ⚠ 关键设计：震动只写 Camera2D.offset，绝不碰 position / zoom。
##本相机的 position 由 Player._update_camera + position_smoothing 驱动，
## 写position 会和跟随逻辑打架（镜头会卡住或抽搐）；zoom 更是被玩家
## 的拉近拉远逻辑独占。所以 offset 是唯一安全的震动通道。

const GROUP := "screen_shake"

@export var max_offset: float = 10.0   # 强度 1.0 时的最大偏移（像素）
@export var duration: float = 0.18# 一次震动持续多久（秒）
@export var frequency: float = 22.0# 抖动频率（Hz），越高越"脆"

var _time_left: float = 0.0
var _strength: float = 0.0
var _phase: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	# 相机最后更新，避免和玩家的 position_smoothing 抢写入顺序
	process_priority = 100


## 触发一次震动。strength 建议 0.3 ~ 1.5，dur <= 0 时用默认时长。
## 连击时取「更强的强度」而不是累加，防止多箭齐射把镜头震飞。
func shake(strength: float = 1.0, dur: float = -1.0) -> void:
	if strength <= 0.0:
		return
	_strength = maxf(_strength, clampf(strength, 0.0, 3.0))
	_time_left = duration if dur <= 0.0 else dur
	# 重置相位，保证每次震动的第一帧位移不同（不然连续命中会同相位、像没震）
	_phase = randf() * TAU


func _process(delta: float) -> void:
	if _time_left <= 0.0:
		return

	_time_left -= delta
	if _time_left <= 0.0:
		# 必须归零！否则残留 offset 会让画面永久偏移一小段
		offset = Vector2.ZERO
		_strength = 0.0
		return

	var ratio := clampf(_time_left / duration, 0.0, 1.0)
	# 二次方衰减：开头最猛、尾巴快速收干净，短促有力不拖泥带水
	var amp := max_offset * ratio * ratio * _strength

	_phase += delta * frequency
	# 正弦 + 随机抖动混合：
	# 纯正弦太平滑（像果冻），纯随机会"沙沙响"（像卡帧）
	var x := sin(_phase * TAU) * 0.65 + randf_range(-0.35, 0.35)
	var y := cos(_phase * TAU * 1.37) * 0.65 + randf_range(-0.35, 0.35)

	# 按 zoom 换算，保证「拉近时」和「拉远时」屏幕上的抖动像素一致
	var z := maxf(zoom.x, 0.001)
	offset = Vector2(x, y) * amp / z


## 强制立刻停止震动并归零。切场景 / 重开局时可以调用。
func reset() -> void:
	_time_left = 0.0
	_strength = 0.0
	offset = Vector2.ZERO


## 全局取用：任意节点都能拿到当前相机的震动组件
static func find_shake(host: Node = null) -> ScreenShake:
	var tree := host.get_tree() if (host != null and is_instance_valid(host)) \
		else (Engine.get_main_loop() as SceneTree)
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as ScreenShake


## 便捷入口：不用先取组件，直接震一下
static func shake_at(host: Node, strength: float = 1.0, dur: float = -1.0) -> void:
	var s := find_shake(host)
	if s != null:
		s.shake(strength, dur)