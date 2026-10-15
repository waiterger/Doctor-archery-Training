extends Node
## 续局容器（Autoload 名为 RunState）：保存"看视频复活"后要带进下一局的数据。
##
## 为什么要它：复活流程要 change_scene_to_file 回main.tscn，
## 而换场景会把整棵树重建 —— Buff 等级、波次、分数全没了。
## 所以在换场景【之前】把数据存进这个单例，
## 等main.gd 的 _ready() 里再读出来应用回去，然后立刻清空。
##
## 复活数据只在"死亡→看视频→复活"这一瞬间存在，
## 读走即清，绝不会污染正常开局的流程。

## 本局是否已经用过复活（一局只能一次）。
## ⚠ 开局必须是 false —— _ready() 里显式初始化一次，
## 避免任何异常路径把它带成 true（曾出现过"一进游戏就没复活机会"）。
var revive_used: bool = false

## ★★ 本次场景重载的原因标记。
## false = 重新开始 / 正常开局 → main.gd 不恢复任何数据
## true  = 看视频复活 → main.gd 恢复暂存数据
##
## ⚠⚠ 必须放在 Autoload 里，不能放 GameManager：
##   GameManager 是 main.tscn 的普通节点，切场景时被销毁，标志位会丢。
var is_reviving: bool = false

## 待恢复的数据。没复活过时 has_pending() 恒为 false。
var _pending: bool = false
var _buffs: Dictionary = {}     # { buff_id: 等级 }
var _wave: int = 0
var _score: int = 0
var _element: String = ""     # 玩家当时选中的附着元素
var _gold: int = 0      # 金币
var _expanded: Dictionary = {}  # { buff_id: 扩容后的上限 }


func _ready() -> void:
	# ⚠⚠ 显式初始化，绝不依赖变量默认值。
	# 复活状态必须在一局开始时干净地是 false。
	revive_used = false
	is_reviving = false
	clear()
	print("[RunState] 续局容器就绪  revive_used=false  is_reviving=false")


# --------------------------------------------------
# 写入（复活前调用）
# --------------------------------------------------

## 把当前进度打包存下来。
## 参数由调用方（game_over.gd）从即将被销毁的场景里收集。
func stash(buffs: Dictionary, wave: int, score: int, element: String,
		gold_v: int = 0, expanded: Dictionary = {}) -> void:
	_buffs = buffs.duplicate(true)
	_wave = wave
	_score = score
	_element = element
	_gold = gold_v
	_expanded = expanded.duplicate(true)
	_pending = true
	print("[RunState] 已暂存：波次=", wave, " 分数=", score,
		" 金币=", gold_v, " Buff=", buffs, " 元素=", element,
		" 扩容=", expanded)


# --------------------------------------------------
# 读取（main.gd _ready 里调用，读完即清）
# --------------------------------------------------

func has_pending() -> bool:
	return _pending


## 取出并【立即清空】暂存数据。
func take() -> Dictionary:
	var out := {
		"buffs": _buffs.duplicate(true),
		"wave": _wave,
		"score": _score,
		"element": _element,
		"gold": _gold,
		"expanded": _expanded.duplicate(true),
	}
	clear()
	return out


## 清空暂存（不返回数据）
func clear() -> void:
	_pending = false
	_buffs = {}
	_wave = 0
	_score = 0
	_element = ""
	_gold = 0
	_expanded = {}


# --------------------------------------------------
# 复活次数（一局一次）
# --------------------------------------------------

## 当前这一局是否还能用复活
func can_revive() -> bool:
	return not revive_used


## 标记复活已用掉
func mark_revive_used() -> void:
	revive_used = true
	print("[RunState] 复活次数已用掉（本局不能再用）")


## 开新一局时重置复活次数。
## 场景真正从主菜单重新开始时才调用，走复活流程时【不要】调用。
func reset_revive() -> void:
	revive_used = false
	clear()
	print("[RunState] 复活次数已重置")


## ★ 开新一局时的【完整】状态重置。所有"重开/开始新游戏"的入口
## （主菜单开始训练、暂停菜单重新开始、结算界面重新开始、
##   战斗中按 R 重开）都应该调它，而不是只调 reset_revive()。
##
## ⚠ 这个 bug 的教训：
##   revive_used 存在 Autoload 单例里，单例跨场景永生，
##   get_tree().reload_current_scene() / change_scene_to_file()
##   都不会重建它 —— 所以「重新开始」后复活次数仍然是上一局的值，
##   必须由代码显式清。
##
## 幂等：可以重复调用，不会产生副作用。
func reset_for_new_run() -> void:
	revive_used = false
	clear()             # 清掉_buffs/_wave/_score/_element/_gold/_expanded
	print("[RunState] ★ 新一局：复活次数、金币、Buff、波次、分数已全部重置")


# --------------------------------------------------
# ★ 场景重载原因标记（区分「重新开始」与「看视频复活」）
# --------------------------------------------------
## 【看视频复活】调用：标记本���重载要恢复数据。
## 必须由 GameManager 在stash() 之后、切场景之前调用。
func mark_reviving() -> void:
	is_reviving = true
	print("[RunState] ↻ 标记为「复活重载」，main.gd 将恢复金币/Buff/波次")


## 【重新开始 / 开新局】调用：标记本次重载不恢复任何数据。
func mark_new_run() -> void:
	is_reviving = false
	print("[RunState] ✦ 标记为「重新开局」，main.gd 不会恢复任何数据")


## main.gd 读完暂存数据后调用，把标记复位（防下一次误判成复活）
func consume_reviving() -> bool:
	var was := is_reviving
	is_reviving = false
	return was


## ★★★ 强制重置全部本局数据（用户要求的 reset_run_data）
## 无论之前是什么状态，一律清成"全新一局"：
##   revive_used（是否复活过）= false
##   gold（金币）/ wave / score= 0
##   Buff 列表 / 扩容记录 = 空
##   is_reviving = false
## 心流 / 护盾 CD 在 Flow 单例和 Player 节点上，由调用方一并处理
##（它们不在本单例里），main.gd 有对应兜底。
func reset_run_data() -> void:
	revive_used = false
	is_reviving = false
	clear()# _pending/_buffs/_wave/_score/_element/_gold/_expanded 全部清空
	print("[RunState] ★★★ reset_run_data(): 复活次数/金币/波次/分数/Buff 全部归零")