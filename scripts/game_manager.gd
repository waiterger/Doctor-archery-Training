extends Node
## 波次管理器：肉鸽骨架的核心状态机。
##
## 三个状态循环往复：
##   PREPARE (倒计时) → COMBAT (打靶) → 全部清空 → PREPARE (下一波)
##
## 解耦要点：GameManager 只发信号和加分数，不认识玩家、不认识箭矢；
## HUD 只收信号，不认识 GameManager 的内部变量；
## Target 只发 died 信号，不认识 GameManager。
## 三者之间零直接引用，加一个新系统（比如连击系统）不用改这三个文件。

## 状态枚举：让状态一目了然，比用 0/1/2 好读
enum State {
	PREPARE,   # 波次准备中，倒计时
	COMBAT,    # 战斗中，等靶子被打光
	GAME_OVER, # 玩家 HP 归零，游戏结束
}

## 金币数量变化（HUD 监听它刷新显示）
signal gold_changed(new_gold: int)

# ---- 难度曲线参数（肉鸽的「随进度变难」全靠这几个）----
## 加入 game_manager 组，方便靶子等任意节点用 get_first_node_in_group 找到它
## （GameManager 没有 class_name，不能静态引用）
@export var prepare_time: float = 3.0      # 每波开始前倒计时几秒
@export var targets_per_wave_base: int = 3 # 第 1 波几个靶子
@export var targets_per_wave_step: int = 1 # 每波多几个
@export var max_targets_per_wave: int = 9  # 上限，避免后期刷屏
@export var hp_base: float = 30.0          # 靶子基础血量
@export var hp_step: float = 12.0           # 每波血量增量
@export var reward_base: int = 10          # 击破基础分
@export var reward_step: int = 2           # 每波奖励增量
@export var target_speed_base: float = 100.0   # 第 1 波靶子巡逻速度
@export var target_speed_step: float = 15.0# 每波巡逻速度增量
@export var max_target_speed: float = 220.0# 速度上限，避免后期靶子快到看不清

# Spawner 和 HUD 是 GameManager 的「兄弟节点」（都在 Main 下面），
# 所以路径要从父节点算起：../Spawner、../HUD
@onready var spawner: Node2D = get_parent().get_node("Spawner")
@onready var hud: CanvasLayer = get_parent().get_node("HUD")
@onready var buff_ui: CanvasLayer = get_parent().get_node_or_null("BuffUI")
@onready var player: CharacterBody2D = get_parent().get_node("Player")
@onready var amiya: CanvasLayer = get_parent().get_node_or_null("Amiya")
@onready var buff_manager: Node = player.get_node_or_null("BuffManager")

# 正在等待玩家选择 buff（此时不推进波次）
var _awaiting_buff_choice: bool = false

# 当前状态与计时
var state: State = State.PREPARE
var wave: int = 0
var score: int = 0
var best_score: int = 0# 历史最高分（本次运行内记录）
var _timer: float = 0.0
## ★ 金币：击杀紫怪掉落。靶子死亡时通过 GameManager 拿（它在 targets 组之外的引用）
var gold: int = 0
var _alive_targets: Array[Node2D] = []


func _ready() -> void:
	print("[GameManager] 波次系统启动")
	# 把 Spawner 的靶子场景接上（也可以在检查器拖，但代码接更明确）
	spawner.target_scene = load("res://scenes/target.tscn")

	# 金币变化时同步刷新暂停菜单的技能面板（扩容按钮要跟着变灰/消失）
	gold_changed.connect(_on_gold_changed)

	# 连接 buff 界面：玩家选完才继续下一波
	if buff_ui != null and buff_ui.has_signal("buff_chosen"):
		buff_ui.buff_chosen.connect(_on_buff_chosen)
		# ★ 金币升级信号：三选一界面里点满级卡片会抛这个
		if buff_ui.has_signal("buff_upgraded"):
			buff_ui.buff_upgraded.connect(_on_buff_upgraded)
		# ★ 刷新卡牌信号（三选一界面右上角按钮）
		if buff_ui.has_signal("refresh_requested"):
			buff_ui.refresh_requested.connect(_on_refresh_requested)
		# ★ 跳过信号：玩家主动放弃本次选择，必须推进流程否则会卡死
		if buff_ui.has_signal("skipped"):
			buff_ui.skipped.connect(_on_buff_skipped)
		print("[GameManager] 已连接 BuffUI.buff_chosen / buff_upgraded / refresh_requested / skipped 信号")
	else:
		print("[GameManager] ⚠ 未找到 BuffUI 或其信号，波次将不弹强化界面")

	# 连接玩家的死亡信号：HP 归零 → 结算
	if player.has_signal("died"):
		player.died.connect(_on_player_died)
		print("[GameManager] 已连接 Player.died 信号")

	_enter_prepare()


# --------------------------------------------------
# 血量同步（GameManager 是唯一同时认识 player 和 hud 的地方）
# --------------------------------------------------
func _sync_player_hp() -> void:
	if player == null or hud == null:
		return
	if not player.has_method("get_hp"):
		return
	hud.update_hp(player.get_hp(), player.get_max_hp())


# --------------------------------------------------
# 状态切换
# --------------------------------------------------
## ★ 播放音效的通用入口（AudioManager 是 Autoload 单例，统一判空）
func _sfx(method_name: String) -> void:
	if not has_node("/root/AudioManager"):
		return
	var am: Node = get_node("/root/AudioManager")
	if am != null and am.has_method(method_name):
		am.call(method_name)


func _enter_prepare() -> void:
	state = State.PREPARE
	_timer = prepare_time
	wave += 1
	print("\n========== 第 ", wave, " 波 准备中 ==========")
	print("  倒计时 ", prepare_time, "s 后开始")
	# ★ 发令枪音效
	_sfx("play_wave_start")

	# 关键设计：准备阶段【不生成靶子】。
	# 如果这里就生成，玩家可以在倒计时期间把靶子打光，
	# 但 _process 还在 PREPARE 分支、不会检查清空条件，
	# 结果就是「靶子全没了却卡在准备阶段」——这是实际踩到的 bug。
	# 所以改成：倒计时结束 → 进入战斗 → 这时才生成靶子。
	hud.update_wave(wave)
	hud.update_remaining(0)


func _enter_combat() -> void:
	state = State.COMBAT
	_timer = 0.0

	# 难度随波次递增
	var count := mini(targets_per_wave_base + (wave - 1) * targets_per_wave_step,
		max_targets_per_wave)
	var hp := hp_base + (wave - 1) * hp_step
	var reward := reward_base + (wave - 1) * reward_step

	# 参数交给 Spawner，它在实例化之前就设好血量/奖励
	# 第 4 个参数 wave：Spawner 用它判断本波是否刷紫怪
	_alive_targets = spawner.spawn_wave(count, hp, reward, wave)

	# 靶子巡逻速度随波次递增，后期更有压迫感
	var speed := minf(target_speed_base + (wave - 1) * target_speed_step,
		max_target_speed)
	for t in _alive_targets:
		t.patrol_speed = speed

	# 只连信号，不再重复设参数
	for t in _alive_targets:
		t.died.connect(_on_target_died)
		# 紫怪超时消失：不加分，但必须从计数里移除，否则波次永远卡住
		if t.has_signal("vanished"):
			t.vanished.connect(_on_target_vanished)

	print(">>> 第 ", wave, " 波 正式开始！击破 ", _alive_targets.size(), " 个靶子")
	hud.update_remaining(_alive_targets.size())

	# 阿米娅冒一句（纯装饰，不影响任何逻辑）
	if amiya != null:
		amiya.speak()


func _process(delta: float) -> void:
	# 每帧把玩家血量同步给 HUD（低血量时 HUD 会变红）
	_sync_player_hp()

	# 游戏已结束：冻结一切，等玩家按 R
	if state == State.GAME_OVER:
		return

	# 玩家正在选 buff，游戏已暂停，这里直接跳过
	if _awaiting_buff_choice:
		return

	match state:
		State.PREPARE:
			_timer -= delta
			hud.update_timer(maxf(_timer, 0.0))
			if _timer <= 0.0:
				_enter_combat()

		State.COMBAT:
			# 传 -1 表示「不在倒计时」，HUD 会显示「战斗中」而不是「下一波 0s」
			hud.update_timer(-1.0)
			# 靶子全部被击破 → 弹出 buff 选择
			if _alive_targets.is_empty():
				_offer_buff_choice()


# --------------------------------------------------
# 波次结算：暂停并弹出 buff 选择
# --------------------------------------------------
## 清空一波后调用。暂停游戏 → 弹 3 张卡 → 等玩家选完再进入下一波。
func _offer_buff_choice() -> void:
	# 本波奖励结算分数
	var wave_bonus := wave * 5
	score += wave_bonus
	print("\n<<< 第 ", wave, " 波 清空！ 波次奖励 +", wave_bonus, " → 总分 ", score)
	# ★ 清波台词「能再一次和您并肩作战真是太好了，博士！」
	_sfx("play_wave_clear_voice")

	if buff_ui == null or buff_manager == null:
		print("[GameManager] 缺少 Buff 组件，跳过强化环节")
		_enter_prepare()
		return

	_awaiting_buff_choice = true
	var options: Array = buff_manager.roll_choices(buff_manager.choice_count)
	print("[GameManager] 请选择一个强化: ", options)
	# open() 内部会 get_tree().paused = true
	buff_ui.open(options)


## 玩家选完 buff 后由信号触发
# --------------------------------------------------

## ★ 玩家在三选一界面花金币升级满级 buff。
## 界面只负责判断和发信号，实际扣费在这里做（唯一改金币的地方）。
func _on_buff_upgraded(id: String) -> void:
	if buff_manager == null or not is_instance_valid(buff_manager):
		print("[GameManager] ⚠ 找不到 BuffManager，升级失败")
		return

	# ★★ v4：免费/付费由 BuffManager 统一判定（UI 也用同一口径）。
	# ⚠⚠ 【免费升级绝对不能扣金币，也不能因为 gold=0 被拦】
	#   —— 这正是截图里"1 级就提示消耗金币"的根因。
	var is_free: bool = buff_manager.is_free_upgrade(id)
	var cost: int = buff_manager.upgrade_price(id)   # 免费时为 0

	if not is_free and gold < cost:
		print("[GameManager] ⚠ 金币不足：需要 ", cost, " 持有 ", gold)
		# 金币被别处花掉了 → 刷新界面让玩家看到"金币不足"
		if buff_ui != null:
			buff_ui.refresh_cards()
		return

	# ⚠ 只在付费时才扣费。try_upgrade 内部也会再校验一次（双保险），
	#   但 try_upgrade 先改等级再返回，所以扣费放在它【之后】最安全。
	var res: Dictionary = buff_manager.try_upgrade(id, gold)
	if not res.get("ok", false):
		print("[GameManager] ⚠ 升级失败：", res.get("reason", ""))
		if buff_ui != null:
			buff_ui.refresh_cards()
		return

	# ★ 只有付费升级才扣钱；res["cost"] 是权威值（防止和 UI 口径不一致）
	var real_cost: int = int(res.get("cost", 0))
	if real_cost > 0:
		spend_gold(real_cost)
		print("[GameManager] 💰 「", buff_manager.get_display_name(id),
			"」付费升级 → Lv.", res.get("level", 0),
			"，花费 ", real_cost, " 剩余金币 ", gold)
	else:
		print("[GameManager] ✦ 「", buff_manager.get_display_name(id),
			"」免费升级 → Lv.", res.get("level", 0))

	# ⚠⚠ 升级 = 本次选择已完成，必须关闭界面并推进流程，
	# 否则 _awaiting_buff_choice 卡在 true → 波次死锁。
	_awaiting_buff_choice = false
	if buff_ui != null:
		buff_ui.close()
		hud.update_score(score)
	print("[GameManager] ↩ 升级完成，关闭三选一，进入下一波准备")
	_enter_prepare()


## ★ 三选一界面点「刷新」：扣 1 金币 + 重新 roll 三张卡。
## 复用 buff_manager 现有的随机池 / 权重逻辑，不另造一套。
func _on_refresh_requested() -> void:
	if buff_ui == null or buff_manager == null:
		print("[GameManager] ⚠ 组件缺失，刷新失败")
		return

	# ① 先扣钱（余额不足直接返回，界面刷新按钮会变灰）
	var cost: int = buff_ui.refresh_cost
	if gold < cost:
		print("[GameManager] ⚠ 金币不足：需要 ", cost, " 持有 ", gold)
		buff_ui.refresh_cards()
		return
	if not spend_gold(cost):
		buff_ui.refresh_cards()
		return

	# ② 重新 roll 三张卡（用和首次弹出完全相同的逻辑）
	# _awaiting_buff_choice 保持 true —— 玩家还在选，不能让流程断掉
	var options: Array = buff_manager.roll_choices(buff_manager.choice_count)
	_awaiting_buff_choice = true
	print("[GameManager] 🎲 刷新卡牌 → ", options, " 剩余金币 ", gold)
	buff_ui.open(options)


## ★ 玩家点了「跳过」：不选任何 buff，直接进入下一波准备。
## ⚠ 必须重置 _awaiting_buff_choice，否则波次流程会死锁在这里。
func _on_buff_skipped() -> void:
	if not _awaiting_buff_choice:
		return
	_awaiting_buff_choice = false
	print("[GameManager] ⏭ 玩家跳过强化，进入下一波准备")
	_enter_prepare()


##注：v3 已废除「点卡片直接获得 buff」。
## 三条出路全部走各自信号：
##   - 升级 → buff_upgraded（金币买+1 级）
##   - 刷新 → refresh_requested（重抽卡）
##   - 跳过 → skipped（什么都不选）
## 这个函数保留只为兼容旧存档的信号名，实际不会被调用。


func _on_buff_chosen(id: String) -> void:
	_awaiting_buff_choice = false
	buff_manager.add_buff(id)

	# HUD 提示一下当前加成
	hud.update_score(score)
	print("[GameManager] 强化已生效，进入下一波准备")
	_enter_prepare()


# --------------------------------------------------
# 商店支持
# --------------------------------------------------
## 商品「重新随机三选一」用：置位后，下一次弹出强化会重新抽一次。
var _reroll_pending: bool = false

## ★ 商店回血商品的已购次数（本局）。
## 回血价格递增：第 1 次买 1 金币，第 2 次 2 金币，第 3 次 3 金币……
## 即当前价格为 heal_purchase_count + 1。
## 放在 GameManager 而不是 ShopPanel，是因为 ShopPanel 属于暂停菜单，
## 生命周期跟着 UI 走；GameManager 才是本局状态的持有者。
var heal_purchase_count: int = 0

## ★ 护盾冷却缩减商品的已购次数（商店限制最多 2 次）
var shield_cd_bought: int = 0


##★ 强制重置本局全部运行时数据（金币 / 波次 / 分数）。
## 由 RunState.reset_run_data() 在切场景前调用 —— 因为 GameManager
## 自己是 main.tscn 的节点，切场景就没了，必须在切之前清。
## 波次/分数已在_ready 里初始化为 1 / 0，这里显式写一遍是双保险。
func reset_run_data() -> void:
	gold = 0
	score = 0
	wave = 1
	_awaiting_buff_choice = false
	heal_purchase_count = 0
	shield_cd_bought = 0
	_reroll_pending = false
	print("[GameManager] ♻运行时数据已归零：金币=0 波次=1 分数=0 商店计数=0")


## 商店买回血成功后调用，累加购买次数。
func mark_heal_purchased() -> void:
	heal_purchase_count += 1
	print("[GameManager] 🛒 回血已购买第 ", heal_purchase_count,
		" 次，下次价格 ", heal_price(), " 金币")


## 回血商品当前价格（= 已购次数 + 1）
## 公开给 ShopPanel 查询
func heal_price() -> int:
	return heal_purchase_count + 1


## 商店买「重新随机」后调用。
## 注意：只能在【下一次 buff_ui.open() 之前】有效，
## 如果玩家买了之后本局已经不再有强化环节，就白花钱了（UI 会提示）。
func request_reroll() -> bool:
	if buff_ui == null or buff_manager == null:
		return false
	# 必须正好处于「等玩家选强化」的状态才有意义
	if not _awaiting_buff_choice:
		return false
	_awaiting_buff_choice = false# 避免重抽时又被触发
	var options: Array = buff_manager.roll_choices(buff_manager.choice_count)
	_awaiting_buff_choice = true
	print("[GameManager] 🎲 重新随机三选一 → ", options)
	buff_ui.open(options)
	return true


## 加分数（商店备用商品「加 10 分」用）
func add_score(amount: int) -> void:
	score += amount
	hud.update_score(score)
	print("[GameManager] +", amount, " 分 → 总分 ", score)


# --------------------------------------------------
# 靶子被击破的回调
# --------------------------------------------------
func _on_target_died(target: Node2D, reward: int) -> void:
	_alive_targets.erase(target)

	score += reward
	print("  +", reward, " 分 → 总分 ", score)

	hud.update_score(score)
	hud.update_remaining(_alive_targets.size())


## 紫怪超时消失：只移除计数，不给分数也不掉金币
## （金币已在 Target._die 里结算过；这里走的是"没被打掉"的路径）
func _on_target_vanished(target: Node2D) -> void:
	_alive_targets.erase(target)
	hud.update_remaining(_alive_targets.size())
	print("  ⏰ 紫怪消失，剩余靶子 ", _alive_targets.size())


# --------------------------------------------------
# 金币
# --------------------------------------------------
## 金币变化时通知暂停菜单刷新技能面板（扩容按钮的可用性依赖金币数）
func _on_gold_changed(new_gold: int) -> void:
	var main := get_parent()
	if main == null:
		return
	var pm: Node = main.get_node_or_null("UILayer/PauseMenu")
	if pm == null:
		pm = main.get_node_or_null("PauseMenu")
	if pm != null and pm.has_method("refresh_skill_panel"):
		pm.refresh_skill_panel()


## 加金币并通知 HUD。靶子死亡时调用（紫怪掉金币）。
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount
	hud.update_gold(gold)
	gold_changed.emit(gold)
	print("[GameManager] 💰 金币 +", amount, " → 持有 ", gold)


## 扣金币（扩容消费）。金币不足时返回 false，不扣。
func spend_gold(amount: int) -> bool:
	if amount <= 0:
		return true
	if gold < amount:
		push_warning("[GameManager] 金币不足：需要 ", amount, " 持有 ", gold)
		return false
	gold -= amount
	hud.update_gold(gold)
	gold_changed.emit(gold)
	print("[GameManager] 💰 金币 -", amount, " → 剩余 ", gold)
	return true


## 金币组名。靶子用 get_first_node_in_group("game_manager") 找过来加金币。
const GM_GROUP := "game_manager"


# --------------------------------------------------
# 续局恢复（看视频复活后由main.gd 调用）
# --------------------------------------------------
## 把存档里的波次/分数灌回本局，并直接把状态推进到"下一波准备"。
## 不走 _enter_combat：复活后玩家需要喘息，不该一睁眼就被要求立刻开打。
func restore_from_stash(wave_v: int, score_v: int, gold_v: int = 0) -> void:
	wave = maxi(wave_v - 1, 0)   # 预备 _enter_prepare 会 wave += 1
	score = maxi(score_v, 0)
	gold = maxi(gold_v, 0)
	best_score = maxi(best_score, score)
	hud.update_score(score)
	hud.update_gold(gold)
	# 直接进准备阶段：倒计时给玩家喘息，同时能正常触发下一波刷靶
	_enter_prepare()
	print("[GameManager] ♻ 已恢复：波次=", wave, " 分数=", score, " 金币=", gold)


# --------------------------------------------------
# 失败结算
# --------------------------------------------------
## 玩家 HP 归零时由 Player.died 信号触发
func _on_player_died() -> void:
	if state == State.GAME_OVER:
		return
	state = State.GAME_OVER

	# 记录最高分
	var is_record := score > best_score
	if is_record:
		best_score = score

	# 清掉场上所有靶子，免得它们继续动、继续撞人
	for t in _alive_targets:
		if is_instance_valid(t):
			t.queue_free()
	_alive_targets.clear()

	# 兜底：切到结算场景前结束顿帧，保证结算界面是正常速度
	HitStop.restore()

	print("\n===== 训练结束 =====")
	print("  最终得分 = ", score, "   到达第 ", wave, " 波")

	# 把数据塞进 GameOver 的静态变量，然后切到结算场景
	# （由GameOver 自己 paused = true，所以这里不用手动暂停）
	var over_script: GDScript = load("res://scripts/game_over.gd")
	over_script.set("last_score", score)
	over_script.set("last_wave", wave)
	over_script.set("is_record", is_record)
	# ★ 金币也要传给 GameOver，复活时才能带回去
	over_script.set("last_gold", gold)
	# ★ 一并把Buff 等级和当前元素交出去：万一玩家选「看视频复活」，
	# GameOver 需要这些数据才能在切回 main.tscn 时原样还原。
	if buff_manager != null:
		over_script.set("saved_buffs", buff_manager.export_levels())
		over_script.set("saved_element", buff_manager.get_element())
		over_script.set("saved_expanded", buff_manager.export_expanded())
	print("[GameManager] → 切换到 GameOver 场景")
	# ★ 游戏结束音效
	_sfx("play_game_over")
	get_tree().change_scene_to_file("res://scenes/game_over.tscn")
