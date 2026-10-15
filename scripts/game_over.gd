extends CanvasLayer
## 结算界面（独立场景）：显示得分与波次。
## 可「重新开始」「返回主菜单」，或「看视频复活（仅限一次）」。
##
## 根节点是 CanvasLayer(layer=200) —— 独立于游戏世界坐标，
## 镜头怎么动都不会把结算面板带偏。
##
## 数据传递：用静态变量传参，避免为了传两个数字去搞 autoload。
## 暂停：_ready 里自己paused = true，所以节点必须 PROCESS_MODE_ALWAYS。

## 场景路径（做成导出参数，方便以后换）
@export var game_scene: String = "res://scenes/main.tscn"
@export var title_scene: String = "res://scenes/title_screen.tscn"
## 复活视频路径（项目根目录下的 ogv，Godot 原生支持 Theora）
## ★ 已换成新视频 222383898-1-16.ogv（2026-10-14 替换）
@export var revive_video: String = "res://222383898-1-16.ogv"

## ★ 复活视频是否循环播放。
## false = 只播一遍（播完停在最后一帧）→ 配合 finished 信号触发续局
## true  = 一直循环（适合"背景氛围视频"）
@export var revive_video_loop: bool = false
## 播放视频前等待几秒（用来放"注意音量"提示）
@export var volume_warn_seconds: float = 2.0

## ★ 循环播放时【强制结束】视频的秒数（0 = 不启用）。
## 循环播放下 finished 信号永不触发，必须靠这个计时器兜底，
## 否则玩家会卡在视频里永远出不来。
## ⚠ 设为略大于视频实际时长即可（比如视频 12 秒，这里填 13）。
@export var video_max_seconds: float = 0.0

## GameManager 在切场景前把数据塞进来
static var last_score: int = 0
static var last_wave: int = 1
static var is_record: bool = false
## ★ 金币（复活时要带回去）
static var last_gold: int = 0

## ★ 复活流程要带进下一局的数据（GameOver 场景已销毁，只能靠静态变量传出去）
static var saved_buffs: Dictionary = {}
static var saved_element: String = ""
## ★ 扩容记录（复活后Buff 的上限要保留）
static var saved_expanded: Dictionary = {}
## 本局是否已经复活过（防止一路刷视频无限复活）。
## ⚠⚠ 这是 static var —— 静态变量【跨场景永存】，换了场景也不会自己清零。
##   曾经因为它一直是 true，导致"重新开始后进结算界面显示复活不可用"。
##   现在由 RunState.revive_used 作为唯一权威，本变量只在【本场景内】做防连点兜底。
static var revive_claimed: bool = false


##★ 游戏进入 main 场景时调用：清掉本局已复活的标记。
## 挂在 main.gd 的 _ready() 最前面，保证每次开局/复活回来都是 false。
static func on_entered_game_scene() -> void:
	revive_claimed = false
	print("[GameOver] ♻ revive_claimed 已重置（进入战斗场景）")

@onready var title_label: Label = $Center/Panel/VBox/Title
@onready var score_label: Label = $Center/Panel/VBox/ScoreLabel
@onready var wave_label: Label = $Center/Panel/VBox/WaveLabel
@onready var gold_label: Label = $Center/Panel/VBox/GoldLabel
@onready var btn_restart: Button = $Center/Panel/VBox/BtnRestart
@onready var btn_menu: Button = $Center/Panel/VBox/BtnMenu
@onready var btn_revive: Button = $Center/Panel/VBox/BtnRevive
@onready var revive_hint: Label = $Center/Panel/VBox/ReviveHint
@onready var volume_warning: Label = $VolumeWarningLabel
@onready var video_player: VideoStreamPlayer = $VideoPlayer

## 流程进行中标记：等待2 秒 + 播视频这段时间，禁止任何重复操作
var _busy: bool = false
## ★ 复活流程是否已收尾（防重入）。
## finished 信号和循环模式的兜底计时器都可能调收尾函数，
## 这个标志保证只执行一次切场景。
var _revive_finished: bool = false


func _ready() -> void:
	btn_restart.pressed.connect(_on_restart)
	btn_menu.pressed.connect(_on_menu)
	btn_revive.pressed.connect(_on_revive)
	video_player.finished.connect(_on_video_finished)

	# 暂停整棵树，但自己保持 ALWAYS 才能点按钮
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 视频节点也必须是 ALWAYS：游戏处于 paused 时它照常播放，
	# 否则会卡在第一帧不动。
	video_player.process_mode = Node.PROCESS_MODE_ALWAYS

	title_label.text = "训练结束"
	score_label.text = "最终得分 %d" % last_score
	wave_label.text = "到达第 %d 波%s" % [last_wave, "★ 新纪录！" if is_record else ""]
	if gold_label != null:
		gold_label.text = "💰 金币：%d" % last_gold

	_setup_revive_ui()

	print("[GameOver] ===== 结算 =====")
	print("  得分 = ", last_score, " 波次 = 第 ", last_wave, " 波 新纪录 = ", is_record)
	print("  复活可用 = ", _can_revive_now())


## 复活按钮的可用状态
func _setup_revive_ui() -> void:
	# 本局只能用一次：已经用过的，隐藏按钮并提示
	if not _can_revive_now():
		btn_revive.visible = false
		revive_hint.text = "（复活机会已用完）"
		revive_hint.visible = true
		return

	if not _video_available():
		# 视频文件缺失/导入失败 → 干脆不显示复活入口，避免玩家点了没反应
		btn_revive.visible = false
		revive_hint.text = "（复活视频不可用）"
		revive_hint.visible = true
		print("[GameOver] ⚠ 复活视频不可用：", revive_video)
		return

	btn_revive.visible = true
	btn_revive.disabled = false
	btn_revive.text = "看视频复活（仅限一次）"
	revive_hint.visible = true
	revive_hint.text = "死亡后每局仅有 1 次复活机会"
	volume_warning.visible = false
	video_player.visible = false


## 当前能不能复活：RunState 记录 + 静态兜底，双保险
func _can_revive_now() -> bool:
	if revive_claimed:
		return false
	var rs := _run_state()
	if rs != null:
		return rs.can_revive()
	return true


## 视频是否可用（文件存在 + 能被 Godot 识别成视频流）
func _video_available() -> bool:
	if not ResourceLoader.exists(revive_video):
		return false
	var res := ResourceLoader.load(revive_video)
	return res is VideoStream


func _run_state() -> Node:
	if Engine.has_singleton("RunState"):
		return Engine.get_singleton("RunState")
	# Autoload 节点在场景树的 /root 下
	var tree := get_tree()
	if tree != null and tree.root.has_node("RunState"):
		return tree.root.get_node("RunState")
	return null


# --------------------------------------------------
# 复活流程
# --------------------------------------------------
## 点击「看视频复活」
func _on_revive() -> void:
	if _busy:
		return
	if not _can_revive_now():
		print("[GameOver] 复活次数已用完，忽略")
		return

	_busy = true
	# ① 立刻隐藏按钮 + 禁用其他按钮，防止重复点击
	btn_revive.visible = false
	btn_restart.disabled = true
	btn_menu.disabled = true

	# ①-半 先做加载体检：资源缺失/类型不对就别往下走，直接给玩家提示
	var stream := _load_revive_stream()
	if stream == null:
		print("[GameOver] ❌ 复活视频加载失败，放弃复活流程")
		_abort_revive()
		return

	# ② 显示音量警告，等 2 秒
	volume_warning.text = "🎵 注意音量！视频即将播放..."
	volume_warning.visible = true
	print("[GameOver] 🎬 复活流程开始，", volume_warn_seconds, " 秒后播放视频")
	await get_tree().create_timer(volume_warn_seconds, true, false, true).timeout

	# ★ 安全检查：等待期间玩家可能已经退出场景
	if not is_instance_valid(video_player) or _revive_finished:
		return

	# ③ 隐藏警告，显示并播放视频
	volume_warning.visible = false

	# ★★ 静音其他音频（BGM / SFX / Voice 三条总线），避免和视频声音打架。
	#    视频走 VideoStreamPlayer 自己的 Master 总线，不受影响。
	_mute_other_audio(true)

	video_player.visible = true
	video_player.stream = stream

	# ★★★ 修复点：loop 属性在【VideoStreamPlayer】上，不在 VideoStream 上！
	#   旧代码写的是 (stream as VideoStream).loop = ... ，
	#   VideoStream 基类根本没有 loop 属性（已用 ClassDB 验证），
	#   这行会抛运行时错误并【中断整个 _on_revive() 协程】，
	#   导致后面的 video_player.play() 从未执行 → 永远黑屏。
	video_player.loop = revive_video_loop

	video_player.play()
	print("[GameOver] ▶ 开始播放复活视频：", revive_video,
		"  循环=", revive_video_loop)

	# ★ 播放兜底：无论循环与否，都加一个"最长等待"计时器。
	#   · 循环模式：finished 永不触发，只能靠计时器
	#   · 非循环模式：个别环境 finished 可能丢信号，计时器兜底
	#   用视频实际时长 + 2 秒余量，兜底值取不到时用 15 秒。
	var limit := video_max_seconds
	if limit <= 0.0:
		limit = _video_length_of(stream) + 2.0
		limit = maxf(limit, 3.0)
	await get_tree().create_timer(limit, true, false, true).timeout
	if is_instance_valid(video_player) and video_player.playing and not _revive_finished:
		print("[GameOver] ⏱ 达到 ", snapped(limit, 1), " 秒上限，强制结束视频")
		_finish_revive()


## ★ 加载复活视频流。失败返回 null（而不是让 load() 返回 null 后一路崩下去）。
func _load_revive_stream() -> VideoStream:
	if not ResourceLoader.exists(revive_video):
		push_warning("[GameOver] 复活视频不存在：", revive_video)
		return null
	var res := ResourceLoader.load(revive_video)
	if res is VideoStream:
		return res as VideoStream
	push_warning("[GameOver] 复活视频类型不对（不是 VideoStream）：", revive_video)
	return null


## 取视频时长（秒），取不到返回 0。
func _video_length_of(stream: VideoStream) -> float:
	var vp := VideoStreamPlayer.new()
	vp.stream = stream
	var len := vp.get_stream_length()
	vp.free()
	return len


## ★ 复活视频播放期间静音/恢复 BGM、SFX、Voice 三条总线。
##    刻意【不】静音 Master —— 视频自身的声音就走 Master，静了会一起没。
##    也不改 AudioManager 里存的音量值，只是临时 mute，复活后原样恢复。
func _mute_other_audio(muted: bool) -> void:
	for bus in ["BGM", "SFX", "Voice"]:
		var idx := AudioServer.get_bus_index(bus)
		if idx == -1:
			continue
		AudioServer.set_bus_mute(idx, muted)
	print("[GameOver] 🔇 其他音频已静音" if muted else "[GameOver] 🔊 其他音频已恢复")


## 复活流程中途失败（视频加载不了等）时的回滚：恢复 UI 和音频，把机会还给玩家。
func _abort_revive() -> void:
	_busy = false
	_revive_finished = false
	btn_revive.visible = _can_revive_now()
	btn_restart.disabled = false
	btn_menu.disabled = false
	revive_hint.visible = true
	revive_hint.text = "（复活视频加载失败，请重新开始）"
	volume_warning.visible = false
	if is_instance_valid(video_player):
		video_player.visible = false
		video_player.stop()
	_mute_other_audio(false)


## ★ 收尾：隐藏视频 + 存数据 + 回战斗场景。
## 非循环模式由 finished 信号调用，循环模式由计时器兜底调用，
## 两边统一走这里，避免逻辑分叉。
func _finish_revive() -> void:
	#防重入：已处理过就直接返回
	if _revive_finished:
		return
	_revive_finished = true

	if is_instance_valid(video_player):
		video_player.visible = false
		video_player.stop()

	# ★ 复活视频播完 → 立刻恢复 BGM / SFX / Voice（在切场景之前做，
	#   因为切场景会销毁本节点，那时再恢复就已经晚了）
	_mute_other_audio(false)

	# ④ 把当前进度交给 RunState，main.tscn 的 _ready 会读走并应用
	_stash_progress()

	print("[GameOver] ♻ 视频播放完毕，返回战斗场景续局")

	# ⑤ 回主场景。必须先解除暂停，否则新场景一出生就是暂停的
	get_tree().paused = false
	get_tree().change_scene_to_file(game_scene)


## 视频播放完毕 → 存数据 → 回主场景续局。
## ⚠ 循环播放时 finished 永远不会触发 —— 所以循环模式下要靠别的方式结束，
##见_on_replay_timeout（备用计时器）。
func _on_video_finished() -> void:
	if revive_video_loop:
		# 循环播放时理论上到不了这里，兜底防止误触发
		print("[GameOver] ⚠ 循环模式下收到 finished，忽略")
		return
	_finish_revive()


## 把分数/波次/Buff/元素写进全局容器
func _stash_progress() -> void:
	var rs := _run_state()
	if rs == null:
		push_warning("[GameOver] 找不到 RunState 单例，续局数据会丢失")
		return
	# ① 先把本局进度存进去（main.gd 要读它恢复）
	rs.stash(saved_buffs, last_wave, last_score, saved_element, last_gold, saved_expanded)
	# ② 标记「本次重载是因为复活」—— main.gd 读到它才会恢复数据
	rs.mark_reviving()
	# ③ 标记复活已用掉：本局不能再复活第二次
	rs.mark_revive_used()
	# ④ 静态标记同步置位，防同一局连点
	revive_claimed = true


# --------------------------------------------------
# 原有逻辑
# --------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	# 复活流程进行中时屏蔽 R，防止误触直接把流程打断
	if _busy:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_on_restart()


func _on_restart() -> void:
	if _busy:
		return
	print("[GameOver] 重新开始 → ", game_scene)
	# ★ 重新开始：只做三件事，绝不多余操作
	_reset_for_new_run()
	_goto(game_scene)


## ★★ 「重新开始」的完整处理（切场景前必须做完）。
## 只有四步，不碰 GameManager、不碰 main.gd：
##   ① mark_new_run()标记「这是新开局」（is_reviving = false）
##   ② reset_run_data()  清 revive_used / 暂存数据
##   ③ revive_claimed = false 清静态标记
##   ④ 切场景。main.gd 的 _ready() 只负责【读标记】，
##      不再重复 reset_run_data()，避免打印两次。
func _reset_for_new_run() -> void:
	# ③ 静态标记也要清（它是 static var，跨场景永存）
	revive_claimed = false

	var rs := _run_state()
	if rs == null:
		return
	# ① 告诉 main.gd「不要恢复任何暂存数据」
	if rs.has_method("mark_new_run"):
		rs.mark_new_run()
	# ② 强制重置全局状态（revive_used / 暂存数据 / is_reviving）
	if rs.has_method("reset_run_data"):
		rs.reset_run_data()


func _on_menu() -> void:
	if _busy:
		return
	print("[GameOver] 返回主菜单 → ", title_scene)
	_reset_for_new_run()
	_goto(title_scene)


## 切场景前必须先解除暂停，否则新场景默认就是暂停状态
func _goto(path: String) -> void:
	# 保险：任何离场路径都保证音频总线不留在静音状态
	_mute_other_audio(false)
	get_tree().paused = false
	get_tree().change_scene_to_file(path)