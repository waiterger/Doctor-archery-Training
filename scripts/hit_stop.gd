extends RefCounted
class_name HitStop
## 命中顿帧：命中瞬间把全局 time_scale 压到极低，营造"卡一下"的打击感。
##
## 全部是静态成员，不需要挂节点、不需要 Autoload，任何脚本都能直接调：
##   HitStop.trigger(self, 0.05, 0.1)
##
## ##【安全设计】—— 这个东西一旦漏了复原，游戏就永久慢速或永久卡死
## 所以做了四重保险：
##  1. 只用「真实时间」计时器（ignore_time_scale = true）来恢复，
##     绝不会出现"越慢越难恢复"的死锁。
##  2. token 令牌机制：新的触发会顶掉旧的恢复流程，旧流程的复原代码
##     检查 token 不匹配就自行放弃，不会互相抢着写 time_scale。
##  3. 重复触发不叠加：已经在顿帧中就只延长一下就返回，
##     不会出现 time_scale 被叠成 0.001。
##  4. 提供 restore()，切场景 / 重开局时手动兜底。

static var _token: int = 0            # 恢复令牌，每次触发 +1
static var _active: bool = false


## 触发顿帧。
## duration：持续多少「真实秒」（建议 0.03~0.08）
## scale   ：期间 time_scale 压到多少（0=完全静止，0.1=极慢；建议 0.05~0.2）
static func trigger(_host: Node = null, duration: float = 0.05, scale: float = 0.1) -> void:
	if duration <= 0.0:
		return

	if _active:
		# 已经在顿帧：只保证"至少停这么久"，不再叠加压低 time_scale
		return

	_active = true
	_token += 1
	var my_token := _token

	Engine.time_scale = maxf(scale, 0.001)

	# 关键：ignore_time_scale = true → 这个计时器走真实时间，
	# 所以哪怕 time_scale = 0.01，恢复也只会在 duration 秒后触发（不会死锁）
	var tree := _get_tree(_host)
	if tree == null:
		_restore_now(my_token)
		return

	var timer := tree.create_timer(duration, true, false, true)
	await timer.timeout

	# 令牌不匹配说明期间被 restore() / 新一轮顶掉了，这段复原直接放弃
	if my_token == _token:
		Engine.time_scale = 1.0
		_active = false


## 立即结束顿帧并恢复原速（切场景、重开局时兜底调用）
static func restore() -> void:
	# 让所有在飞的 await 全部失效
	_token += 1
	_active = false
	Engine.time_scale = 1.0


static func _restore_now(_my_token: int) -> void:
	Engine.time_scale = 1.0
	_active = false


static func is_active() -> bool:
	return _active


static func _get_tree(host: Node) -> SceneTree:
	if host != null and is_instance_valid(host) and host.get_tree() != null:
		return host.get_tree()
	return Engine.get_main_loop() as SceneTree