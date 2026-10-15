extends Control
## 局内商店：暂停菜单里的二级面板，用金币买强化。
##
## 节点结构（pause_menu.tscn 里的实例，路径以此为准）：
##   ShopPanel (Control, process_mode=ALWAYS, 默认隐藏)
##   ├─ Dim      (ColorRect, Full Rect, IGNORE)
##   ├─ Center   (CenterContainer, Full Rect)
##   │  └─ Panel (PanelContainer)
##   │     └─ VBox
##   │        ├─ Title    (Label "🛒 商店")
##   │        ├─ GoldLabel(Label 当前金币)
##   │        ├─ ItemList (VBoxContainer)← 商品动态生成
##   │        └─ BtnShopBack(Button "返回")
##
## 商品全部由代码动态生成到 ItemList 里，场景中只留容器。

## 购买成功时抛出，PauseMenu 用它做反馈（可据此播放音效/飘字）
signal purchase_done(item_name: String)

@onready var gold_label: Label = $Center/Panel/VBox/GoldLabel
@onready var item_list: VBoxContainer = $Center/Panel/VBox/ItemList
@onready var btn_back: Button = $Center/Panel/VBox/BtnShopBack

## 游戏世界引用（暂停菜单在主菜单场景也会被用到，那里找不到）
var _player: Node2D = null
var _gm: Node = null
var _bm: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	# ⚠ 隐藏时必须同时把 mouse_filter 设成 IGNORE。
	# Control 默认是 STOP，即使 visible=false 也不会让鼠标事件穿透下去，
	# 会挡住下面主菜单的按钮点击。
	_set_input_passthrough(true)
	btn_back.pressed.connect(close)
	print("[ShopPanel] 商店就绪")


## 隐藏状态下整体放行鼠标，open() 时再恢复拦截
func _set_input_passthrough(off: bool) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE if off else Control.MOUSE_FILTER_STOP
	for c in [get_node_or_null("Dim"), get_node_or_null("Center")]:
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE if off \
				else Control.MOUSE_FILTER_PASS


## 打开商店并刷新一批商品
func open() -> void:
	visible = true
	_set_input_passthrough(false)
	_cache_nodes()
	refresh()
	print("[ShopPanel] 打开商店")


func close() -> void:
	visible = false
	_set_input_passthrough(true)
	print("[ShopPanel] 关闭商店")


## 缓存玩家 / GameManager / BuffManager
func _cache_nodes() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _gm == null or not is_instance_valid(_gm):
		_gm = tree.get_first_node_in_group("game_manager")
	if _bm == null or not is_instance_valid(_bm):
		_bm = tree.get_first_node_in_group("buff_manager")
	if _player == null or not is_instance_valid(_player):
		_player = tree.get_first_node_in_group("player")


func _gold() -> int:
	return int(_gm.gold) if _gm != null and is_instance_valid(_gm) else 0


## ★ 回血商品当前价格：已购次数 + 1（1 → 2 → 3 …）
## 数据源在 GameManager（跨场景存活，重开商店不会丢）。
func _heal_price() -> int:
	if _gm != null and is_instance_valid(_gm) and _gm.has_method("heal_price"):
		return maxi(int(_gm.heal_price()), 1)
	return 1


## 回血商品已购买次数
func _heal_bought() -> int:
	if _gm != null and is_instance_valid(_gm):
		return int(_gm.get("heal_purchase_count"))
	return 0


# --------------------------------------------------
# 玩家 / 护盾状态读取（全部带判空，主菜单场景也能安全调用）
# --------------------------------------------------
func _hp() -> int:
	if _player != null and is_instance_valid(_player) \
			and _player.has_method("get_hp"):
		return int(_player.get_hp())
	return 0


func _max_hp() -> int:
	if _player != null and is_instance_valid(_player) \
			and _player.has_method("get_max_hp"):
		return int(_player.get_max_hp())
	return 0


## 护盾当前冷却上限（秒）
func _shield_cd_left() -> float:
	if _player != null and is_instance_valid(_player) \
			and _player.has_method("get_shield_cooldown"):
		return float(_player.get_shield_cooldown())
	return 90.0


## 护盾冷却商品已购买次数
func _shield_cd_bought() -> int:
	if _gm != null and is_instance_valid(_gm):
		return int(_gm.get("shield_cd_bought"))
	return 0


## 当前累计伤害加成百分比
func _damage_bonus() -> float:
	if _player != null and is_instance_valid(_player) \
			and _player.has_method("get_damage_bonus"):
		return float(_player.get_damage_bonus())
	return 0.0


# --------------------------------------------------
# 商品池
# --------------------------------------------------
##★ 商品种类。已删除「加10 分」和「刷新三选一」。
enum Item {
	HEAL,       # 恢复 1 点生命（价格递增 1→2→3）
	HEAL_FULL,  # 恢复满血
	MAX_HP,     # 生命上限 +1（永久）
	DAMAGE,     # 永久伤害 +15%（可叠加）
	SHIELD_CD,  # 护盾冷却 -15 秒（最多 2 次）
	ELEMENT,    # 随机未满级元素附魔
}

## 每次刷几个商品
@export var item_count: int = 4

## 护盾冷却商品最多可买次数
@export var shield_cd_max_purchase: int = 2

## 护盾冷却每次缩减秒数
@export var shield_cd_reduce: float = 15.0

## 永久伤害每次提升百分比
@export var damage_bonus_step: float = 0.15

## 各商品固定价格
const COST_HEAL_FULL := 2
const COST_MAX_HP := 3
const COST_DAMAGE := 3
const COST_SHIELD_CD := 3
const COST_ELEMENT := 2


## 生成一批商品（不重复）。
## 已买满/已达上限的商品不再出现，避免刷出无意义的条目。
func _roll_items() -> Array[int]:
	var pool: Array[int] = [Item.HEAL, Item.HEAL_FULL, Item.MAX_HP,
		Item.DAMAGE, Item.SHIELD_CD, Item.ELEMENT]
	# 逐个剔除「买了也没用」的商品
	var avail: Array[int] = []
	for it in pool:
		if _is_item_useful(it):
			avail.append(it)
	avail.shuffle()
	return avail.slice(0, mini(item_count, avail.size()))


## 某商品现在还有购买价值吗（已满级/已买满次数的剔除）
func _is_item_useful(item: int) -> bool:
	match item:
		Item.HEAL:
			# 满血时回血没意义，但也别完全剔除（玩家可能想看到价格）
			return true
		Item.HEAL_FULL:
			return _hp() < _max_hp()
		Item.ELEMENT:
			return _random_buff_id() != ""
		Item.SHIELD_CD:
			return _shield_cd_bought() < shield_cd_max_purchase \
				and _shield_cd_left() > 20.0
		_:
			return true# MAX_HP / DAMAGE 永久有效，不剔除


## 重建整个商品列表
func refresh() -> void:
	_cache_nodes()
	_refresh_gold_label()

	for c in item_list.get_children():
		item_list.remove_child(c)
		c.queue_free()

	for it in _roll_items():
		item_list.add_child(_make_item_button(it))


func _refresh_gold_label() -> void:
	if gold_label == null:
		return
	var g := _gold()
	gold_label.text = "当前金币：%d" % g
	gold_label.modulate = Color(1, 0.84, 0.32) if g > 0 else Color(0.6, 0.62, 0.68)


## 造一个商品按钮
func _make_item_button(item: int) -> Button:
	var title := ""
	var desc := ""
	var cost := 1
	var buyable := true
	## 不可买的「原因」（会显示在按钮上）
	var block_reason := ""

	match item:
		Item.HEAL:
			# 价格递增：1 → 2 → 3 …（由 GameManager.heal_purchase_count 决定）
			cost = _heal_price()
			title = "❤️ 恢复 1 点生命"
			desc = "当前 %d / %d  ·  已购买 %d 次" % [_hp(), _max_hp(), _heal_bought()]
			if _hp() >= _max_hp():
				buyable = false
				block_reason = "已满血"

		Item.HEAL_FULL:
			cost = COST_HEAL_FULL
			title = "💙 恢复满血"
			desc = "立刻回满全部生命（当前 %d / %d）" % [_hp(), _max_hp()]
			if _hp() >= _max_hp():
				buyable = false
				block_reason = "已满血"

		Item.MAX_HP:
			cost = COST_MAX_HP
			title = "💪 生命上限 +1"
			desc = "永久提升 1 点生命上限并回满血（%d → %d）" \
				% [_max_hp(), _max_hp() + 1]
			if _player == null or not _player.has_method("increase_max_hp"):
				buyable = false
				block_reason = "不可用"

		Item.DAMAGE:
			cost = COST_DAMAGE
			title = "⚔ 攻击力永久提升"
			desc = "所有箭矢伤害 +%d%%（可叠加，当前累计 +%d%%）" \
				% [int(damage_bonus_step * 100), int(_damage_bonus() * 100)]
			if _player == null or not _player.has_method("add_damage_bonus"):
				buyable = false
				block_reason = "不可用"

		Item.SHIELD_CD:
			cost = COST_SHIELD_CD
			var bought := _shield_cd_bought()
			title = "🛡 阿米娅护盾冷却缩减"
			desc = "冷却 -%d 秒（%d → %d 秒）  已购买 %d / %d 次" \
				% [int(shield_cd_reduce), int(_shield_cd_left()),
					int(maxf(_shield_cd_left() - shield_cd_reduce, 20.0)),
					bought, shield_cd_max_purchase]
			if bought >= shield_cd_max_purchase:
				buyable = false
				block_reason = "已买满"
			elif _shield_cd_left() <= 20.0:
				buyable = false
				block_reason = "已达冷却下限"

		Item.ELEMENT:
			cost = COST_ELEMENT
			var pick := _random_buff_id()
			if pick == "":
				title = "📖 元素附魔"
				desc = "随机获得一个未满级元素附魔"
				buyable = false
				block_reason = "所有附魔已满级"
			else:
				title = "📖 %s 升级" % _bm.get_display_name(pick)
				desc = "Lv.%d → Lv.%d  %s" % [_bm.count_of(pick),
					_bm.count_of(pick) + 1, _bm.get_display_desc(pick)]

	# ⚠ 金币不足：按钮变灰，并明确显示还差多少
	if buyable and _gold() < cost:
		buyable = false
		block_reason = "金币不足（需 %d 枚）" % cost

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 78)
	btn.focus_mode = Control.FOCUS_NONE
	btn.disabled = not buyable
	btn.modulate = Color.WHITE if buyable else Color(1, 1, 1, 0.45)

	# 价格行：买得起显示「花费 N💰」，买不起显示「金币不足（需 X 枚）」
	var price_line := "花费 %d 💰" % cost
	if block_reason != "":
		price_line = block_reason
	btn.text = "%s\n%s\n%s" % [title, desc, price_line]

	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 15)
	btn.set_meta("item", item)

	if buyable:
		btn.pressed.connect(_on_buy.bind(item))

	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	return btn


## 随机挑一个「未满级」的 buff id。全部满级返回 ""
func _random_buff_id() -> String:
	if _bm == null or not is_instance_valid(_bm):
		return ""
	var pool: Array[String] = []
	for id in _bm.owned_ids():
		if not _bm.is_maxed(id):
			pool.append(id)
	if pool.is_empty():
		# 一个都没拿过 buff 时，退而给随机池里的任意一个
		for id in _bm.BUFF_DEFS.keys():
			if not _bm.is_maxed(id):
				pool.append(id)
	if pool.is_empty():
		return ""
	pool.shuffle()
	return pool[0]


# --------------------------------------------------
# 购买
# --------------------------------------------------
## 各商品的固定价格集中在这里，避免和 _make_item_button 写两份
func _cost_of(item: int) -> int:
	match item:
		Item.HEAL: return _heal_price()
		Item.HEAL_FULL: return COST_HEAL_FULL
		Item.MAX_HP: return COST_MAX_HP
		Item.DAMAGE: return COST_DAMAGE
		Item.SHIELD_CD: return COST_SHIELD_CD
		Item.ELEMENT: return COST_ELEMENT
	return 1


## 购买前的可买性校验。返回空串=可以买，否则返回不可买的原因。
func _check_buyable(item: int) -> String:
	match item:
		Item.HEAL:
			if _hp() >= _max_hp():
				return "已满血"
		Item.HEAL_FULL:
			if _hp() >= _max_hp():
				return "已满血"
		Item.SHIELD_CD:
			if _shield_cd_bought() >= shield_cd_max_purchase:
				return "已买满"
			if _shield_cd_left() <= 20.0:
				return "已达冷却下限"
		Item.ELEMENT:
			if _random_buff_id() == "":
				return "所有附魔已满级"
	return ""


func _on_buy(item: int) -> void:
	_cache_nodes()
	if _gm == null or not is_instance_valid(_gm) \
			or not _gm.has_method("spend_gold"):
		print("[ShopPanel] ⚠ GameManager 不可用，购买取消")
		return

	# ① 校验能不能真的生效（不校验就扣钱 = 白扣）
	var reason := _check_buyable(item)
	if reason != "":
		print("[ShopPanel] ⚠ 无法购买「", item, "」：", reason)
		refresh()
		return

	# ② 余额检查
	var cost := _cost_of(item)
	if _gold() < cost:
		print("[ShopPanel] ⚠ 金币不足：需要 ", cost, " 持有 ", _gold())
		refresh()
		return

	# ③ 扣钱
	if not _gm.spend_gold(cost):
		print("[ShopPanel] ⚠ 扣款失败，购买取消")
		refresh()
		return

	# ④ 应用效果
	var ok := false
	var msg := ""
	match item:
		Item.HEAL:
			ok = _player != null and _player.has_method("heal") and _player.heal(1)
			msg = "恢复 1 点生命"
			if ok and _gm.has_method("mark_heal_purchased"):
				_gm.mark_heal_purchased()

		Item.HEAL_FULL:
			ok = _player != null and _player.has_method("heal_full") \
				and _player.heal_full()
			msg = "恢复满血"

		Item.MAX_HP:
			ok = _player != null and _player.has_method("increase_max_hp") \
				and _player.increase_max_hp(1)
			msg = "生命上限 +1"

		Item.DAMAGE:
			if _player != null and _player.has_method("add_damage_bonus"):
				_player.add_damage_bonus(damage_bonus_step)
				ok = true
			msg = "攻击力 +%d%%" % int(damage_bonus_step * 100)

		Item.SHIELD_CD:
			if _gm != null:
				_gm.set("shield_cd_bought", _shield_cd_bought() + 1)
			ok = _player != null and _player.has_method("reduce_shield_cooldown") \
				and _player.reduce_shield_cooldown(shield_cd_reduce)
			msg = "护盾冷却 -%d 秒" % int(shield_cd_reduce)

		Item.ELEMENT:
			var pick := _random_buff_id()
			if pick != "" and _bm != null:
				_bm.add_buff(pick)
				ok = true
				msg = "%s 升级！" % _bm.get_display_name(pick)
			else:
				msg = "没有可升级的附魔"

	if not ok:
		# 效果没生效说明白扣了，如实报告让玩家知道发生了什么
		print("[ShopPanel] ⚠ 购买未生效：", msg)

	print("[ShopPanel] ✅ 购买「", msg, "」花费 ", cost, " 金币，剩余 ", _gold())
	purchase_done.emit(msg)
	# ★ 立刻刷新（金币变了 / 属性变了 / 商品要变灰）
	refresh()