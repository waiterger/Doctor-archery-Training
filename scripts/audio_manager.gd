extends Node
## 全自动音频管理器（Autoload 名：AudioManager）
##
## 设计原则：**完全代码驱动，编辑器里一个音频节点都不用拖**。
## 启动时自动创建 BGM / SFX / Voice 三条总线（父级=Master），
## 重启项目不会丢（AudioServer 的总线是运行时对象，必须代码建）。
##
## 文件路径说明（与磁盘实际文件名严格一致，注意全角/半角）：
##   - 语音目录是 sound-effect/sounds-amiya/（在 sound-effect 下，不在根目录）
##   -「欸？博士？(仅剩一滴血时)」用的是【半角括号 ?】
##   -「欸嘿嘿……（博士同时击败多个靶子时）」用的是【中文省略号 ……】
## 所有 load() 都做了 exists() 检查 + 找不到只报警不崩。
##
## 其他脚本调用示例：
##   AudioManager.play_shoot()
##   AudioManager.play_wave_start()
##   AudioManager.play_shield_voice()

const DIR_SFX := "res://sound-effect/sound-fight/"
const DIR_VOICE := "res://sound-effect/sounds-amiya/"

## 音频库key → 文件路径。统一在这里登记，方便核对和修改。
const LIB := {
	# ---- BGM ----
	"bgm_menu": DIR_SFX + "initializationmusic.mp3",
	"bgm_fight": DIR_SFX + "backgroundmusic.mp3",
	# ---- SFX ----
	"draw": DIR_SFX + "draw.mp3",
	"shoot": DIR_SFX + "Arrow whoosh.mp3",
	"hit": DIR_SFX + "Arrow hit wood.mp3",
	"hurt": DIR_SFX + "Player hurt.mp3",
	"click": DIR_SFX + "click.mp3",
	"wave_start": DIR_SFX + "race-start.mp3",
	"game_over": DIR_SFX + "game-over.mp3",
	"wood_break": DIR_SFX + "woodbroken.mp3",
	"burn": DIR_SFX + "Burn.mp3",
	"frozen": DIR_SFX + "frozen.mp3",
	# ---- Voice（阿米娅）----
	"v_start": DIR_VOICE + "行动开始.wav",
	"v_shield": DIR_VOICE + "我知道了（阿米娅技能时）.wav",
	"v_here": DIR_VOICE + "博士，我在这里。.wav",
	# ⚠ 注意结尾是「吧。.wav」——句号后面还有一个点，别写成「吧.wav」
	"v_rest": DIR_VOICE + "博士，辛苦了！累了的话请休息一会儿吧。.wav",
	"v_work": DIR_VOICE + "博士，您工作辛苦了.wav",
	"v_low_hp": DIR_VOICE + "欸？博士？(仅剩一滴血时).wav",
	"v_multi_kill": DIR_VOICE + "欸嘿嘿……（博士同时击败多个靶子时）.wav",
	"v_belief": DIR_VOICE + "无论多么艰难的任务，只要有博士在，就一定能完成，我一直这样坚信着！.wav",
	"v_glad": DIR_VOICE + "能再一次和您并肩作战真是太好了，博士！.wav",
}

const BUS_BGM := "BGM"
const BUS_SFX := "SFX"
const BUS_VOICE := "Voice"

const SETTINGS_PATH := "user://settings.cfg"

## 三条总线名（按顺序）
const BUS_NAMES := [BUS_BGM, BUS_SFX, BUS_VOICE]
## 默认音量 0~100
const DEFAULT_VOL := {BUS_BGM: 60, BUS_SFX: 100, BUS_VOICE: 80}

## 已加载的音频流缓存：{ key: AudioStream }
var _lib: Dictionary = {}
## 加载失败的 key（避免每帧重复报警刷屏）
var _missing: Dictionary = {}

## BGM 播放器（循环播放）
var _bgm_player: AudioStreamPlayer = null
## SFX 播放器组（多通道叠音）
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_index: int = 0
## Voice 播放器（独立，避免打断 SFX）
var _voice_player: AudioStreamPlayer = null
## 每条总线当前音量（0~100），存盘用
var _vol: Dictionary = {}
## 自动存档用
var _cfg := ConfigFile.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()      # ① 自动建总线
	_setup_players()    # ② 自动建播放器
	_load_library()     # ③ 自动加载全部音频
	_load_settings()    # ④ 读user://settings.cfg 并应用
	print("[AudioManager] 就绪：3 条总线 / %d 个音频 / BGM=%d SFX=%d Voice=%d"
		% [_lib.size(), _vol[BUS_BGM], _vol[BUS_SFX], _vol[BUS_VOICE]])


# ============================================================
# ① 音频总线
# ============================================================
## 自动创建 BGM / SFX / Voice 三条总线，父级都是 Master。
## 用代码建而不是编辑器拖 —— AudioServer 的总线是运行时对象，
## 不建的话重启项目就没了。
func _setup_buses() -> void:
	for bus_name in BUS_NAMES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx == -1:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			# ⚠ set_bus_send() 第一个参数是 bus「索引」不是名字
			AudioServer.set_bus_send(idx, "Master")
			print("[AudioManager] ✚ 新建总线：", bus_name)
		# 初始化音量存档（即使 cfg 里没这个键也有默认值）
		if not _vol.has(bus_name):
			_vol[bus_name] = int(DEFAULT_VOL[bus_name])


# ============================================================
# ② 播放器
# ============================================================
## 全部用代码创建 AudioStreamPlayer，编辑器里不需要任何节点。
func _setup_players() -> void:
	# BGM：循环 + 走 BGM 总线
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BGMPlayer"
	_bgm_player.bus = BUS_BGM
	_bgm_player.volume_db = 0.0
	add_child(_bgm_player)

	# SFX：建 8 个通道轮播，允许音效叠加不互相打断
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.name = "SFXPlayer%d" % i
		p.bus = BUS_SFX
		add_child(p)
		_sfx_players.append(p)

	# Voice：单通道
	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "VoicePlayer"
	_voice_player.bus = BUS_VOICE
	add_child(_voice_player)


# ============================================================
# ③ 音频库加载
# ============================================================
func _load_library() -> void:
	for key in LIB.keys():
		var path: String = LIB[key]
		if not ResourceLoader.exists(path):
			_missing[key] = path
			continue
		var res: Resource = load(path)
		if res is AudioStream:
			_lib[key] = res
		else:
			_missing[key] = path
	if not _missing.is_empty():
		push_warning("[AudioManager] ⚠ %d 个音频未找到：%s"
			% [_missing.size(), str(_missing)])


## 取音频流；找不到返回 null（不崩）
func _stream_of(key: String) -> AudioStream:
	if _lib.has(key):
		return _lib[key]
	if _missing.has(key):
		return null
	return null


# ============================================================
# 音量（设置面板调这里）
# ============================================================
## 设置总线音量。value范围 0~100，内部用 linear_to_db() 换算成 dB。
## value = 0 时直接静音（mute），避免 linear_to_db(0) = -inf 的边界问题。
func set_bus_volume(bus_name: String, value: float) -> void:
	var v := clampf(value, 0.0, 100.0)
	_vol[bus_name] = int(round(v))

	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	if v <= 0.0:
		# 0 = 静音。用mute 而不是 dB=-80，避免 log(0) 的边界问题
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		# 0~100 线性 → dB。100 → 0dB（原始音量）
		AudioServer.set_bus_volume_db(idx, linear_to_db(v / 100.0))


## 读总线当前音量（0~100）
func get_bus_volume(bus_name: String) -> int:
	if _vol.has(bus_name):
		return int(_vol[bus_name])
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return 100
	if AudioServer.is_bus_mute(idx):
		return 0
	# dB → 线性 → 0~100
	var db := AudioServer.get_bus_volume_db(idx)
	return int(round(db_to_linear(db) * 100.0))


## 启动时读user://settings.cfg 并应用。文件不存在则用默认值。
func _load_settings() -> void:
	if _cfg.load(SETTINGS_PATH) != OK:
		print("[AudioManager] 首次运行，使用默认音量")
		_apply_all_volumes()
		return
	for bus_name in BUS_NAMES:
		if _cfg.has_section_key("audio", bus_name):
			_vol[bus_name] = clampi(int(_cfg.get_value("audio", bus_name)),
				0, 100)
	_apply_all_volumes()
	print("[AudioManager] 已从 settings.cfg 读取音量设置：BGM=%d SFX=%d Voice=%d"
		% [int(_vol[BUS_BGM]), int(_vol[BUS_SFX]), int(_vol[BUS_VOICE])])
	print("音频总线初始化完成！")
	#★★ 诊断信息：一眼看出播放器是否真的挂进了场景树
	print("[AudioManager] 🔍 诊断：")
	print("  场景树节点数=", get_child_count(),
		"  BGM播放器=", _bgm_player != null,
		"  SFX通道=", _sfx_players.size(),
		"  Voice播放器=", _voice_player != null)
	print("  总线：", _dump_buses())
	print("  音频库条目=", _lib.size(), "  缺失=", _missing.size())
	print("  BGM音量 dB=", AudioServer.get_bus_volume_db(
		AudioServer.get_bus_index(BUS_BGM)),
		" 静音=", AudioServer.is_bus_mute(AudioServer.get_bus_index(BUS_BGM)))
	if _bgm_player != null:
		print("  BGM播放器 在树上=", _bgm_player.is_inside_tree(),
			" bus=", _bgm_player.bus)


## 把所有总线的名字/音量/mute 打出来，方便排查静音问题
func _dump_buses() -> String:
	var parts: Array[String] = []
	for i in AudioServer.bus_count:
		var nm := AudioServer.get_bus_name(i)
		var muted := AudioServer.is_bus_mute(i)
		parts.append("%s(dB=%.1f%s)" % [nm,
			AudioServer.get_bus_volume_db(i), ",MUTED" if muted else ""])
	return "[" + ", ".join(parts) + "]"


## 把 _vol 里的值真正应用到 AudioServer
func _apply_all_volumes() -> void:
	for bus_name in BUS_NAMES:
		set_bus_volume(bus_name, float(_vol[bus_name]))


## 音量改动后立刻存档
func save_settings() -> void:
	for bus_name in BUS_NAMES:
		_cfg.set_value("audio", bus_name, int(_vol[bus_name]))
	var err := _cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[AudioManager] ⚠ 音量保存失败：", err)
	else:
		print("[AudioManager] 💾 音量已保存 → ", SETTINGS_PATH)


# ============================================================
# 播放：内部通用
# ============================================================
## 在指定播放器上播一个 key。stream 为 null 时静默返回。
func _play_on(player: AudioStreamPlayer, key: String, vol_db: float = 0.0) -> void:
	if player == null or not is_instance_valid(player):
		return
	var stream := _stream_of(key)
	if stream == null:
		return
	player.stream = stream
	player.volume_db = vol_db
	player.play()


## 播SFX（轮播通道，可叠加）
func _play_sfx(key: String, vol_db: float = 0.0) -> void:
	if _sfx_players.is_empty():
		push_warning("[AudioManager] ⚠ SFX 通道数为0")
		return
	var stream := _stream_of(key)
	if stream == null:
		push_warning("[AudioManager] ⚠ SFX 音频未加载：", key)
		return
	# 找一个空闲通道；全忙就抢第一个
	var slot := -1
	for i in _sfx_players.size():
		if not _sfx_players[i].playing:
			slot = i
			break
	if slot == -1:
		slot = _sfx_index % _sfx_players.size()
	_sfx_index += 1
	_play_on(_sfx_players[slot], key, vol_db)


## 播Voice（单通道，新的会打断旧的）
func _play_voice(key: String, vol_db: float = 0.0) -> void:
	_play_on(_voice_player, key, vol_db)


# ============================================================
# Part 3：对外接口
# ============================================================

# ---------------- BGM ----------------
## 主菜单 BGM（循环）
func play_bgm_menu() -> void:
	_play_bgm("bgm_menu")


## 战斗 BGM（循环）
func play_bgm_fight() -> void:
	_play_bgm("bgm_fight")


func _play_bgm(key: String) -> void:
	print("正在播放BGM！ key=", key)
	if _bgm_player == null:
		push_warning("[AudioManager] ⚠ BGM 播放器为空")
		return
	var stream := _stream_of(key)
	if stream == null:
		push_warning("[AudioManager] ⚠ BGM 音频未加载：", key)
		return
	# 已经在放同一首就不重播
	if _bgm_player.stream == stream and _bgm_player.playing:
		return
	_bgm_player.stream = stream
	# ★ BGM 必须循环播放，否则放一遍就停
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	_bgm_player.play()
	print("[AudioManager] 🎵 BGM 播放中：", key)


## 停止 BGM
func stop_bgm() -> void:
	if _bgm_player != null and is_instance_valid(_bgm_player):
		_bgm_player.stop()


# ---------------- SFX ----------------
## 射击（箭矢破空）
func play_shoot() -> void:
	print("正在播放BGM！ key=shoot(SFX)")   # ★ 调试打印
	_play_sfx("shoot")


## 拉弓
func play_draw() -> void:
	_play_sfx("draw")


## 命中（木质）
func play_hit() -> void:
	_play_sfx("hit")


## 玩家受伤
func play_hurt() -> void:
	_play_sfx("hurt")


## UI 点击
func play_click() -> void:
	_play_sfx("click")


## 波次开始（发令枪）
func play_wave_start() -> void:
	_play_sfx("wave_start")


## 游戏结束
func play_game_over() -> void:
	_play_sfx("game_over")


## 木靶破碎
func play_wood_break() -> void:
	_play_sfx("wood_break")


## 燃烧状态
func play_burn() -> void:
	_play_sfx("burn")


## 冰冻状态
func play_frozen() -> void:
	_play_sfx("frozen")


# ---------------- Voice（阿米娅台词） ----------------
## 护盾技能台词「我知道了」
func play_shield_voice() -> void:
	_play_voice("v_shield")


## 清波台词「能再一次和您并肩作战真是太好了，博士！」
func play_wave_clear_voice() -> void:
	_play_voice("v_glad")


## 受伤台词
func play_hurt_voice() -> void:
	_play_voice("v_rest")


## 残血台词「欸？博士？」
func play_low_hp_voice() -> void:
	_play_voice("v_low_hp")


## 多杀台词「欸嘿嘿……」
func play_multi_kill_voice() -> void:
	_play_voice("v_multi_kill")


## 通用台词接口：给 amiya.gd 按台词内容挑语音用
func play_voice_key(key: String) -> void:
	_play_voice(key)


## 「行动开始」台词
func play_start_voice() -> void:
	_play_voice("v_start")


## 「博士，我在这里。」台词
func play_here_voice() -> void:
	_play_voice("v_here")


## 「博士，您工作辛苦了」台词
func play_work_voice() -> void:
	_play_voice("v_work")


## 「无论多么艰难的任务…」台词
func play_belief_voice() -> void:
	_play_voice("v_belief")