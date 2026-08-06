extends RefCounted
class_name GameLogic

## 核心游戏逻辑 — 纯函数，无状态，无 Godot 节点依赖
## 每个方法接收 BattleState，深拷贝后修改并返回新 state


static func init_game(p1_deck: Array[String], p2_deck: Array[String], p1_starter: String, p2_starter: String) -> BattleState:
	var state := BattleState.new()
	state.setup(p1_deck, p2_deck, p1_starter, p2_starter)
	# 洗牌
	_shuffle_deck(state.players[0].deck)
	_shuffle_deck(state.players[1].deck)
	# 初始抽 3 张
	for i in range(3):
		_draw_one(state, 0)
		_draw_one(state, 1)
	# 首发牌加入购买区
	state.players[0].purchase_zone.append(state.players[0].starter_card_id)
	state.players[1].purchase_zone.append(state.players[1].starter_card_id)
	return state


static func draw_card(state: BattleState, player_idx: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	_draw_one(new_state, player_idx)
	return new_state


static func purchase_card(state: BattleState, player_idx: int, card_id: String) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var player = new_state.players[player_idx]
	if not player.purchase_zone.has(card_id):
		return null  # 待购买区无此卡
	if player.hand.size() >= player.hand_limit:
		return null  # 手牌已满
	var card_data = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return null
	if player.resources["G"] < card_data.cost_g:
		return null  # G 不够
	player.resources["G"] -= card_data.cost_g
	player.purchase_zone.erase(card_id)
	player.hand.append(card_id)
	return new_state


static func deploy_unit(state: BattleState, player_idx: int, card_id: String, row: int, col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var player = new_state.players[player_idx]
	if not player.hand.has(card_id):
		return null
	var card_data = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return null
	if player.resources["Z"] < card_data.cost_k:
		return null
	if col < 0 or col >= new_state.board.cols:
		return null
	var deployable_rows: Array[int] = get_deployable_rows(new_state, player_idx, card_id)
	if not (row in deployable_rows):
		return null
	if new_state.board.get_unit(row, col) != null:
		return null
	player.resources["Z"] -= card_data.cost_k
	player.hand.erase(card_id)
	var unit: BattleState.UnitData = BattleState.UnitData.new()
	unit.card_id = card_id
	unit.owner_index = player_idx
	unit.attack = card_data.attack
	unit.defense = card_data.defense
	unit.max_defense = card_data.defense
	unit.abilities = card_data.abilities.duplicate()
	unit.deployed_this_turn = true
	# Phase 3: 初始化扩展字段
	_init_unit_from_card(unit, card_data)
	new_state.board.set_unit(row, col, unit)
	new_state.action_log.append({"type": "deploy", "player": player_idx, "card_id": card_id, "row": row, "col": col})
	return new_state


static func move_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, to_row: int, to_col: int) -> BattleState:
	var new_state := state.duplicate(true)
	var unit := new_state.board.get_unit(from_row, from_col)
	if unit == null or unit.owner_index != player_idx:
		return new_state

	# 检查移动次数
	if unit.move_count >= unit.move_limit:
		return new_state

	# 标准单位：移动或攻击共一次（has_acted 检查）
	# 坦克/空军：has_acted 不阻挡（由 move_count/has_attacked 分别控制）
	if unit.move_limit <= 1 and not unit.can_move_after_attack:
		if unit.has_acted:
			return new_state

	# 八方向移动一格
	var dr := abs(to_row - from_row)
	var dc := abs(to_col - from_col)
	if dr > 1 or dc > 1 or (dr == 0 and dc == 0):
		return new_state

	# 禁止向后方移动
	if player_idx == 0 and to_row < from_row:
		return new_state
	if player_idx == 1 and to_row > from_row:
		return new_state

	# 目标格为空
	if new_state.board.get_unit(to_row, to_col) != null:
		return new_state

	# Z 消耗（Phase 3: 移动消耗 Z）
	var player = new_state.players[player_idx]
	if player.resources["Z"] < 1:
		return new_state
	player.resources["Z"] -= 1

	# 执行移动
	new_state.board.set_unit(from_row, from_col, null)
	new_state.board.set_unit(to_row, to_col, unit)
	unit.move_count += 1
	unit.has_acted = true
	new_state.action_log.append({"type": "move", "player": player_idx, "from": [from_row, from_col], "to": [to_row, to_col]})
	return new_state


static func attack_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, target_row: int, target_col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var attacker := new_state.board.get_unit(from_row, from_col)
	var defender := new_state.board.get_unit(target_row, target_col)
	if attacker == null or defender == null:
		return null
	if attacker.owner_index != player_idx:
		return null
	if defender.owner_index == player_idx:
		return null  # 不能打友方
	# 检查是否已攻击
	if attacker.has_attacked:
		return null
	# 射程检查（简化：相邻四格 + 火炮全图）
	if not _in_attack_range(attacker, from_row, from_col, target_row, target_col):
		return null
	# Z 消耗（Phase 3：移动/攻击消耗战争点）
	var player = new_state.players[player_idx]
	if player.resources["Z"] < 1:
		return null
	player.resources["Z"] -= 1

	# 伤害计算
	var damage: int = attacker.attack
	# 防守方坚守词条减伤
	if defender.abilities.has("坚守"):
		var firm_level := 1  # 默认坚守1
		# 坦克坚守上限4由 CardData 设定，这里统一取1
		damage = max(1, damage - firm_level)
	# 施加伤害
	defender.defense -= damage

	# 战斗记录
	new_state.action_log.append({"type": "attack", "player": player_idx, "from": [from_row, from_col], "to": [target_row, target_col], "damage": damage})

	# 是否消灭
	if defender.defense <= 0:
		var card_data = CardDataLoader.cards.get(defender.card_id)
		var reward_g := 0
		if card_data != null:
			reward_g = int(card_data.cost_g * 0.25)
		# 收缴词条：50%
		if attacker.abilities.has("收缴"):
			reward_g = int(card_data.cost_g * 0.50) if card_data != null else 0
		player.resources["G"] += reward_g
		new_state.board.set_unit(target_row, target_col, null)
		new_state.action_log.append({"type": "destroy", "card_id": defender.card_id, "reward_g": reward_g})
	else:
		# 反击（攻击者未被消灭时）
		_counter_attack(attacker, defender, from_row, from_col, target_row, target_col, new_state)

	attacker.has_acted = true
	attacker.has_attacked = true
	return new_state


static func start_turn(state: BattleState) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var player = new_state.players[new_state.active_player_index]
	# G +150（不变）
	player.resources["G"] += 150
	# Z = 先手 1+2x / 后手 2+2x, 上限 25
	player.resources["Z"] = _calc_z(new_state.active_player_index, new_state.turn)
	# K = 回合数, 上限 10
	player.resources["K"] = min(new_state.turn, 10)
	# 抽 1 张
	_draw_one(new_state, new_state.active_player_index)
	# 重置单位行动标记（Phase 3 扩展：同时重置 has_attacked, move_count）
	for r in range(new_state.board.rows):
		for c in range(new_state.board.cols):
			var unit := new_state.board.get_unit(r, c)
			if unit != null and unit.owner_index == new_state.active_player_index:
				unit.has_acted = false
				unit.has_attacked = false
				unit.move_count = 0
				unit.deployed_this_turn = false
	new_state.phase = "purchase"
	return new_state


static func end_turn(state: BattleState) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	# 清空 K/Z
	new_state.players[new_state.active_player_index].resources["K"] = 0
	new_state.players[new_state.active_player_index].resources["Z"] = 0
	# 检测胜利
	var result := check_victory(new_state)
	if result != -1:
		new_state.winner = result
		new_state.phase = "game_over"
		return new_state
	# 切换玩家
	new_state.active_player_index = 1 - new_state.active_player_index
	if new_state.active_player_index == 0:
		new_state.turn += 1
	new_state.phase = "draw"
	return new_state


static func check_victory(state: BattleState) -> int:
	# 占领对方全部5条阵线（每列至少一个己方单位在敌方区域内）
	# P1 胜：P1 单位在 P2 区域（行3-4）每列都有
	var p1_cols := {}
	var p2_cols := {}
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var unit := state.board.get_unit(r, c)
			if unit == null:
				continue
			if unit.owner_index == 0 and r >= 3:
				p1_cols[c] = true
			elif unit.owner_index == 1 and r <= 1:
				p2_cols[c] = true
	if p1_cols.size() == state.board.cols:
		return 0
	if p2_cols.size() == state.board.cols:
		return 1
	return -1


## Phase 3: 战争点公式
## 先手 (player_idx=0): 1 + 2×(turn−1) → 1, 3, 5, 7, ...
## 后手 (player_idx=1): 2 + 2×(turn−1) → 2, 4, 6, 8, ...
## 上限 25
static func _calc_z(player_idx: int, turn: int) -> int:
	var base := 1 if player_idx == 0 else 2
	var z := base + 2 * (turn - 1)
	return min(z, 25)


static func _shuffle_deck(deck: Array) -> void:
	var n := deck.size()
	while n > 1:
		n -= 1
		var k := randi() % (n + 1)
		var tmp = deck[k]
		deck[k] = deck[n]
		deck[n] = tmp


static func _draw_one(state: BattleState, player_idx: int) -> void:
	var player = state.players[player_idx]
	if player.deck.is_empty():
		return
	var card_id: String = player.deck.pop_front()
	player.purchase_zone.append(card_id)


static func _can_deploy_at(player_idx: int, row: int, col: int, card_data: Resource) -> bool:
	# 确认目标行在己方区域内
	var back_row: int
	var front_row: int
	if player_idx == 0:
		back_row = 0
		front_row = 1
		if row != 0 and row != 1:
			return false
	else:
		back_row = 4
		front_row = 3
		if row != 3 and row != 4:
			return false

	# 检查该行是否有己方单位（"占领阵线"）
	# 注意：_can_deploy_at 在 deploy_unit 中调用时 state 尚未修改，
	# 但我们需要访问 board 来判断占领状态。
	# 这里只做行列基本校验，具体规则放在 deploy_unit 中处理。
	return true


## 返回指定单位类型可部署的行
static func get_deployable_rows(state: BattleState, player_idx: int, card_id: String) -> Array[int]:
	var rows: Array[int] = []
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return rows

	var back_row: int
	var front_row: int
	if player_idx == 0:
		back_row = 0
		front_row = 1
	else:
		back_row = 4
		front_row = 3

	var unit_class: String = card_data.unit_class
	var back_occupied := _row_has_friendly(state, player_idx, back_row)
	var front_occupied := _row_has_friendly(state, player_idx, front_row)

	match unit_class:
		"infantry":
			# 后方始终可部署；占领前线后可部署到前线
			rows.append(back_row)
			if front_occupied:
				rows.append(front_row)
		"cavalry":
			# 底线始终可部署 + 占领前线后可部署到前线
			rows.append(back_row)
			if front_occupied:
				rows.append(front_row)
		"artillery":
			# 只能部署在后方
			rows.append(back_row)
		_:
			# 默认：后方可部署
			rows.append(back_row)

	return rows


static func _row_has_friendly(state: BattleState, player_idx: int, row: int) -> bool:
	for c in range(state.board.cols):
		var unit: BattleState.UnitData = state.board.get_unit(row, c)
		if unit != null and unit.owner_index == player_idx:
			return true
	return false


static func _in_attack_range(attacker: BattleState.UnitData, from_row: int, from_col: int, target_row: int, target_col: int) -> bool:
	var card_data = CardDataLoader.cards.get(attacker.card_id)
	if card_data == null:
		return false
	var range_str: String = card_data.attack_range
	var dr = abs(target_row - from_row)
	var dc = abs(target_col - from_col)
	match range_str:
		"adjacent_4":
			return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
		"global":
			return true
		_:
			return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)


static func _counter_attack(attacker: BattleState.UnitData, defender: BattleState.UnitData, atk_row: int, atk_col: int, def_row: int, def_col: int, state: BattleState) -> void:
	# 攻击者有"突击" + 首次攻击 → 免反击
	if attacker.abilities.has("突击") and attacker.deployed_this_turn:
		return
	# 攻击者有"冲锋" + 首次攻击 → 免反击（此处用 deployed_this_turn 近似）
	if attacker.abilities.has("冲锋") and attacker.deployed_this_turn:
		return
	# 火炮不可被反击
	var attacker_card = CardDataLoader.cards.get(attacker.card_id)
	if attacker_card != null and attacker_card.unit_class == "artillery":
		return
	# 防守方反击
	var counter_dmg := defender.attack
	if attacker.abilities.has("坚守"):
		counter_dmg = max(1, counter_dmg - 1)
	attacker.defense -= counter_dmg
	state.action_log.append({"type": "counter", "damage": counter_dmg})
	if attacker.defense <= 0:
		state.board.set_unit(atk_row, atk_col, null)
		state.action_log.append({"type": "destroy", "card_id": attacker.card_id, "reward_g": 0})


## 从 abilities 数组中解析带等级的词条
## 如 ["坚守2", "冲锋"] → _parse_ability_level(abilities, "坚守") 返回 2
##    _parse_ability_level(abilities, "补给") 返回 0（无此词条）
## 不带数字的默认为等级 1
static func _parse_ability_level(abilities: Array, prefix: String) -> int:
	for ability in abilities:
		var a: String = ability
		if a == prefix:
			return 1
		if a.begins_with(prefix) and a.length() > prefix.length():
			var suffix := a.substr(prefix.length())
			if suffix.is_valid_int():
				return suffix.to_int()
	return 0


## 判断单位类别是否为空军
static func _is_air_unit(unit_class: String) -> bool:
	return unit_class == "fighter" or unit_class == "bomber"


## 根据 CardData 初始化 UnitData 的 Phase 3 扩展字段
static func _init_unit_from_card(unit: BattleState.UnitData, card_data: Resource) -> void:
	# 坚守等级（坦克默认 1，其他从 abilities 解析）
	unit.firm_level = _parse_ability_level(card_data.abilities, "坚守")
	if card_data.unit_class == "tank" and unit.firm_level == 0:
		unit.firm_level = 1  # 坦克默认坚守 1
	# 补给等级
	unit.supply_level = _parse_ability_level(card_data.abilities, "补给")
	# 潜行
	unit.stealthed = card_data.abilities.has("潜行")
	unit.revealed = false
	# 移动规则
	match card_data.unit_class:
		"tank":
			unit.move_limit = 99              # 无限制
			unit.can_move_after_attack = true
		"fighter", "bomber":
			unit.move_limit = 1
			unit.can_move_after_attack = false
			# 空军：移动和攻击各一次（由 has_acted + has_attacked 分开控制）
		_:
			unit.move_limit = 1
			unit.can_move_after_attack = false
