extends RefCounted
class_name GameLogic

## 核心游戏逻辑 — 纯函数，无状态，无 Godot 节点依赖
## 每个方法接收 BattleState，深拷贝后修改并返回新 state


## 统一 action_log 入口：自动补 turn/phase/player 元数据（复盘录像按回合/阶段分组依赖这些字段）
## info 中的 "player" 优先（反击击杀 by 守方等场景），否则用 active_player_index
static func _log_action(state: BattleState, info: Dictionary) -> void:
	var entry := {"turn": state.turn, "phase": state.phase}
	entry["player"] = info.get("player", state.active_player_index)
	for k in info:
		entry[k] = info[k]
	state.action_log.append(entry)


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


## 每回合购买数量上限（6.2，按稀有度；2026-09-20 起生效）
const PURCHASE_LIMITS := {"common": 99, "silver": 3, "gold": 2}


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
	if card_data.type != "unit":
		return null  # 指令卡（order）走指令区流程，当前阶段未实现
	if player.resources["G"] < card_data.cost_g:
		return null  # G 不够
	# 6.2 稀有度购买上限：与抽取数量无关
	var rarity: String = card_data.rarity
	if not player.purchases_this_turn.has(rarity):
		player.purchases_this_turn[rarity] = 0
	var limit: int = PURCHASE_LIMITS.get(rarity, 99)
	if player.purchases_this_turn[rarity] >= limit:
		return null  # 本回合该稀有度购买数已达上限
	player.resources["G"] -= card_data.cost_g
	player.purchase_zone.erase(card_id)
	player.hand.append(card_id)
	player.purchases_this_turn[rarity] = int(player.purchases_this_turn[rarity]) + 1
	player.hand_card_purchase_turn[card_id] = new_state.turn
	return new_state


## 4.3 部署就绪判定（供 UI 显示；UI 不自行猜测）
static func can_deploy(state: BattleState, player_idx: int, card_id: String) -> Dictionary:
	var player = state.players[player_idx]
	if not player.hand.has(card_id):
		return {"ok": false, "reason": "不在手牌"}
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data == null or card_data.type != "unit":
		return {"ok": false, "reason": "不可部署的卡"}
	if state.phase != "deploy":
		return {"ok": false, "reason": "不在部署阶段"}
	var purchase_turn: int = player.hand_card_purchase_turn.get(card_id, -1)
	if purchase_turn == state.turn and not card_data.abilities.has("响应"):
		return {"ok": false, "reason": "本回合购买，需\"响应\"才能部署"}
	if player.resources["Z"] < card_data.cost_z:
		return {"ok": false, "reason": "战争点 Z 不足（需 %d）" % card_data.cost_z}
	if get_deployable_rows(state, player_idx, card_id).is_empty():
		return {"ok": false, "reason": "无可部署位置"}
	return {"ok": true, "reason": ""}


static func deploy_unit(state: BattleState, player_idx: int, card_id: String, row: int, col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var player = new_state.players[player_idx]
	if not player.hand.has(card_id):
		return null
	var card_data = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return null
	if card_data.type != "unit":
		return null  # 非 unit 卡（指令卡等）不可部署
	# Phase 3: 响应词条检查 — 本回合购买的卡只能在有"响应"词条时部署
	var purchase_turn: int = player.hand_card_purchase_turn.get(card_id, -1)
	if purchase_turn == new_state.turn:
		if not card_data.abilities.has("响应"):
			return null  # 本回合购买但无响应词条，不能部署（与其它失败路径统一返回 null）
	if player.resources["Z"] < card_data.cost_z:
		return null
	if col < 0 or col >= new_state.board.cols:
		return null
	var deployable_rows: Array[int] = get_deployable_rows(new_state, player_idx, card_id)
	if not (row in deployable_rows):
		return null
	# 1.2 陆空图层：空军落在空域图层，陆军落在地面图层，互不占位
	var layer := "air" if _is_air_unit(card_data.unit_class) else "ground"
	if new_state.board.get_unit(row, col, layer) != null:
		return null
	player.resources["Z"] -= card_data.cost_z
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
	new_state.board.set_unit(row, col, unit, layer)
	_log_action(new_state, {"type": "deploy", "player": player_idx, "card_id": card_id, "row": row, "col": col})
	_refresh_guards(new_state)   # 新单位入场后重算全图守护关系
	return new_state


static func move_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, to_row: int, to_col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	# 1.2 陆空图层：单位在自身图层内移动
	var layer := "air" if new_state.board.get_unit(from_row, from_col, "air") != null else "ground"
	var unit: BattleState.UnitData = new_state.board.get_unit(from_row, from_col, layer)
	if unit == null or unit.owner_index != player_idx:
		return null  # 无效移动：状态不变

	# 1.3 部署回合行动限制：刚部署的单位不能移动（"突击"单位例外）
	if unit.deployed_this_turn and not unit.abilities.has("突击"):
		return null
	# 后退过的单位本回合行动已耗尽
	if unit.retreated:
		return null

	# 检查移动次数
	if unit.move_count >= unit.move_limit:
		return null  # 无效移动：状态不变

	# 标准单位：移动或攻击共一次（has_acted 检查）
	# 坦克/空军：has_acted 不阻挡（由 move_count/has_attacked 分别控制）
	if unit.move_limit <= 1 and not unit.can_move_after_attack:
		if unit.has_acted:
			return null  # 无效移动：状态不变

	# 目标格越界保护
	if to_row < 0 or to_row >= new_state.board.rows or to_col < 0 or to_col >= new_state.board.cols:
		return null  # 无效移动：状态不变

	# 八方向移动一格
	var dr: int = abs(to_row - from_row)
	var dc: int = abs(to_col - from_col)
	if dr > 1 or dc > 1 or (dr == 0 and dc == 0):
		return null  # 无效移动：状态不变

	# 向后 = 后退（1.3）：消耗全部行动；只能退一格，不能退出棋盘（越界已拒绝）
	var is_retreat := (player_idx == 0 and to_row < from_row) or (player_idx == 1 and to_row > from_row)
	if is_retreat:
		# 己方后排行（P0 行0 / P1 行4）不能再退
		if (player_idx == 0 and from_row == 0) or (player_idx == 1 and from_row == new_state.board.rows - 1):
			return null
		# 横移不算后退、斜向后不允许（后退只能直退）
		if dc != 0:
			return null

	# 目标格为空（本图层内检查，1.2 陆空分层互不占位）
	if new_state.board.get_unit(to_row, to_col, layer) != null:
		return null  # 无效移动：状态不变

	# Z 消耗（Phase 3: 移动消耗 Z）
	var player = new_state.players[player_idx]
	if player.resources["Z"] < 1:
		return null  # 无效移动：状态不变
	player.resources["Z"] -= 1

	# 执行移动
	new_state.board.set_unit(from_row, from_col, null, layer)
	new_state.board.set_unit(to_row, to_col, unit, layer)
	unit.move_count += 1
	unit.has_acted = true
	if is_retreat:
		unit.retreated = true
	_log_action(new_state, {"type": "move", "player": player_idx, "retreat": is_retreat, "from": [from_row, from_col], "to": [to_row, to_col]})
	_refresh_guards(new_state)   # 位置变化后重算全图守护关系
	return new_state

static func attack_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, target_row: int, target_col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	# 1.2 陆空图层：攻击者所在层（空军在空域层，陆军在地面层）
	var atk_layer := "air" if new_state.board.get_unit(from_row, from_col, "air") != null else "ground"
	var attacker: BattleState.UnitData = new_state.board.get_unit(from_row, from_col, atk_layer)
	if attacker == null:
		return null
	if attacker.card_id.begins_with("fort"):
		return null  # 工事无攻击力，不能发起攻击
	# 目标定层：空军打空军找空域层，其余找地面层（1.2 图层规则）
	var def_layer := "air" if atk_layer == "air" and new_state.board.get_unit(target_row, target_col, "air") != null else "ground"
	var defender: BattleState.UnitData = new_state.board.get_unit(target_row, target_col, def_layer)
	if defender == null:
		return null
	if attacker.owner_index != player_idx:
		return null
	if defender.owner_index == player_idx:
		return null  # 不能打友方
	# 检查是否已攻击
	if attacker.has_attacked:
		return null
	if attacker.retreated:
		return null  # 后退消耗全部行动
	# 射程检查（简化：相邻四格 + 火炮全图）
	if not _in_attack_range(attacker, from_row, from_col, target_row, target_col):
		return null
	# Phase 3: 空战规则 — 陆军不能攻击空军
	var attacker_card: Resource = CardDataLoader.cards.get(attacker.card_id)
	var defender_card: Resource = CardDataLoader.cards.get(defender.card_id)
	if attacker_card != null and defender_card != null:
		var atk_is_air := _is_air_unit(attacker_card.unit_class)
		var def_is_air := _is_air_unit(defender_card.unit_class)
		# 陆军攻击空军 → 无效
		if not atk_is_air and def_is_air:
			return null  # 无效攻击：状态不变
		# 轰炸机攻击空军 → 无效（轰炸机只能打陆军）
		if attacker_card.unit_class == "bomber" and def_is_air:
			return null  # 无效攻击：状态不变
	# 潜行：未揭示的敌方潜行单位不可被作为攻击目标
	if defender.stealthed and not defender.revealed and defender.owner_index != player_idx:
		return null  # 无效攻击：状态不变
	# 设计：标准单位移动或攻击共一次（移动后不可再攻击）
	if attacker.move_limit <= 1 and not attacker.can_move_after_attack and attacker.has_acted:
		return null
	# Z 消耗（Phase 3：移动/攻击消耗战争点）
	var player = new_state.players[player_idx]
	if player.resources["Z"] < 1:
		return null
	player.resources["Z"] -= 1

	# 3A 空战：空军发起攻击且目标阵线存在防守方巡逻战斗机 → 先进行该阵线空战阶段
	var atk_is_air_unit := _is_air_unit(_unit_class_of(attacker))
	if atk_is_air_unit:
		var combat_resolved := _resolve_air_combat(new_state, player_idx, attacker, from_row, from_col, target_row)
		if not combat_resolved:
			# 空战未清空防守巡逻机 → 原定攻击作废（行动已消耗）
			attacker.has_acted = true
			attacker.has_attacked = true
			attacker.attack_count += 1
			_log_action(new_state, {"type": "air_combat_blocked", "player": player_idx, "row": target_row})
			return new_state

	# Phase 3: 被守护单位伤害转移
	var actual_row: int = target_row
	var actual_col: int = target_col
	if defender.is_guarded:
		var guard_pos: Vector2i = defender.guarded_by
		var guard_unit: BattleState.UnitData = new_state.board.get_unit(guard_pos.x, guard_pos.y)
		if guard_unit != null and guard_unit.owner_index == defender.owner_index:
			defender = guard_unit  # 攻击目标改为守护单位
			actual_row = guard_pos.x
			actual_col = guard_pos.y

	# 伤害计算
	var damage: int = attacker.attack
	# Phase 3: 坚守减伤（含 5.4 工事为同阵线陆军提供的坚守）
	var effective_firm: int = max(defender.firm_level, _fort_firm_bonus(new_state, actual_row, defender.owner_index))
	if effective_firm > 0:
		damage = max(1, damage - effective_firm)
	# 施加伤害
	defender.defense -= damage

	# 战斗记录
	_log_action(new_state, {"type": "attack", "player": player_idx, "from": [from_row, from_col], "to": [actual_row, actual_col], "damage": damage})

	# 是否消灭
	if defender.defense <= 0:
		var card_data = CardDataLoader.cards.get(defender.card_id)
		var reward_g: int = 0
		if card_data != null:
			reward_g = int(card_data.cost_g * 0.25)
		# 收缴词条：50%
		if attacker.abilities.has("收缴"):
			reward_g = int(card_data.cost_g * 0.50) if card_data != null else 0
		player.resources["G"] += reward_g
		new_state.board.set_unit(actual_row, actual_col, null, "air" if defender.is_air else "ground")
		_log_action(new_state, {"type": "destroy", "player": player_idx, "card_id": defender.card_id, "reward_g": reward_g})
	else:
		# 反击（攻击者未被消灭时）
		_counter_attack(attacker, defender, from_row, from_col, actual_row, actual_col, new_state)

	attacker.has_acted = true
	attacker.has_attacked = true
	attacker.attack_count += 1
	attacker.patrolling = false  # 攻击后退出巡逻（3A.1）
	_refresh_guards(new_state)   # 击杀/守护变化后重算全图守护关系
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
			for layer in ["ground", "air"]:
				var unit: BattleState.UnitData = new_state.board.get_unit(r, c, layer)
				if unit != null and unit.owner_index == new_state.active_player_index:
					unit.has_acted = false
					unit.has_attacked = false
					unit.move_count = 0
					unit.deployed_this_turn = false
					unit.retreated = false
	player.purchases_this_turn = {"common": 0, "silver": 0, "gold": 0}
	_apply_supply(new_state, new_state.active_player_index)
	_apply_rear_repair(new_state, new_state.active_player_index)
	_update_stealth_reveal(new_state)
	new_state.phase = "purchase"
	return new_state


static func end_turn(state: BattleState) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	# 清空 K/Z
	new_state.players[new_state.active_player_index].resources["K"] = 0
	new_state.players[new_state.active_player_index].resources["Z"] = 0
	# 3A.1 巡逻确认：结束行动一方的回合结束时，本回合未攻击过的战斗机自动进入巡逻
	_confirm_patrol(new_state, new_state.active_player_index)
	# 切换玩家
	new_state.active_player_index = 1 - new_state.active_player_index
	if new_state.active_player_index == 0:
		# 完整回合结束（双方各行动一个轮次）→ 结算战线占领度
		new_state.turn += 1
		_update_front_control(new_state)
		var fv := check_front_victory(new_state)
		if fv != -1:
			new_state.winner = fv
			new_state.phase = "game_over"
			return new_state
	new_state.phase = "draw"
	return new_state


## 3A.1 巡逻状态确认（回合结束调用）：本回合未攻击的战斗机 → 巡逻；攻击过的 → 退出巡逻
static func _confirm_patrol(state: BattleState, player_idx: int) -> void:
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(r, c, "air")
			if unit == null or unit.owner_index != player_idx:
				continue
			var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
			if card_data == null or card_data.unit_class != "fighter":
				continue
			unit.patrolling = not unit.has_attacked


#region 3A 空战与巡逻（docs/game-mechanics.md 3A）

## 空战触发判定 + 单阵线空战阶段结算。
## 返回 true = 防守方巡逻机已清空，进攻者可继续原定攻击；false = 攻击作废。
## 结算顺序（3A.3）：① 巡逻拦截 ② 未被进攻的友方战斗机自动反击（免反击）③ 即时移除阵亡
## 约束：每个单位本阶段最多攻击一次；拦截不再递归触发巡逻判定；阵亡者不参与后续结算。
static func _resolve_air_combat(state: BattleState, player_idx: int, attacker: BattleState.UnitData, from_row: int, from_col: int, target_row: int) -> bool:
	var defender_idx := 1 - player_idx
	# 防守方该阵线全部巡逻战斗机（按列序）
	var patrols: Array = []
	for c in range(state.board.cols):
		var p: BattleState.UnitData = state.board.get_unit(target_row, c, "air")
		if p != null and p.owner_index == defender_idx and p.patrolling and _unit_class_of(p) == "fighter":
			patrols.append({"unit": p, "row": target_row, "col": c})
	if patrols.is_empty():
		return true  # 3A.2 无巡逻 → 不发生空战，统一结算

	# 进攻方参战名单：主动攻击者 + 同阵线（空域层）其余己方战斗机
	var attackers: Array = [{"unit": attacker, "row": from_row, "col": from_col}]
	for c in range(state.board.cols):
		if c == from_col:
			continue
		var f: BattleState.UnitData = state.board.get_unit(from_row, c, "air")
		if f != null and f.owner_index == player_idx and _unit_class_of(f) == "fighter":
			attackers.append({"unit": f, "row": from_row, "col": c})

	_log_action(state, {"type": "air_combat", "player": player_idx, "row": target_row})

	# ① 巡逻拦截：每架巡逻机攻击一个未被拦截过的进攻方单位（优先主动攻击者），正常攻防
	var engaged: Dictionary = {}  # 进攻方单位已被拦截攻击 → 不再参与②的自动反击
	for patrol in patrols:
		var victim := {}
		for a in attackers:
			if not engaged.has(a) and a["unit"].defense > 0:
				victim = a
				break
		if victim.is_empty():
			break  # 没有可拦截的目标
		engaged[victim] = true
		_air_strike(state, patrol["unit"], patrol["row"], patrol["col"], victim["unit"], victim["row"], victim["col"], false)

	# ② 未被进攻的进攻方战斗机自动攻击防守方剩余巡逻机，不受反击（3A.3 ②）
	var patrol_alive := false
	for patrol in patrols:
		if patrol["unit"].defense > 0:
			patrol_alive = true
			break
	if patrol_alive:
		for a in attackers:
			if engaged.has(a) or a["unit"].defense <= 0:
				continue
			# 找一架存活的防守巡逻机
			var tgt := {}
			for patrol in patrols:
				if patrol["unit"].defense > 0:
					tgt = patrol
					break
			if tgt.is_empty():
				break
			_air_strike(state, a["unit"], a["row"], a["col"], tgt["unit"], tgt["row"], tgt["col"], true)
			engaged[a] = true  # 已用掉本次空战攻击机会

	# ③ 空战结束判定：防守方巡逻机是否全灭
	for patrol in patrols:
		if patrol["unit"].defense > 0:
			return false
	return true


## 空战中的一次攻防（拦截或自动反击）。no_counter = 自动反击不受反击伤害（3A.3 ②）
static func _air_strike(state: BattleState, atk_unit: BattleState.UnitData, atk_row: int, atk_col: int, def_unit: BattleState.UnitData, def_row: int, def_col: int, no_counter: bool) -> void:
	var damage: int = atk_unit.attack
	var firm: int = max(def_unit.firm_level, _fort_firm_bonus(state, def_row, def_unit.owner_index))
	if firm > 0:
		damage = max(1, damage - firm)
	def_unit.defense -= damage
	_log_action(state, {"type": "air_strike", "player": atk_unit.owner_index, "attacker": atk_unit.card_id, "from": [atk_row, atk_col], "to": [def_row, def_col], "damage": damage, "no_counter": no_counter})
	if def_unit.defense <= 0:
		state.board.set_unit(def_row, def_col, null, "air")
		_log_action(state, {"type": "destroy", "player": atk_unit.owner_index, "card_id": def_unit.card_id, "reward_g": 0})
		return  # 目标已毁，不存在反击
	if no_counter:
		return  # 自动反击不受反击伤害
	# 被拦截者的反击（正常攻防；走 _counter_attack 的全部豁免规则）
	_counter_attack(atk_unit, def_unit, atk_row, atk_col, def_row, def_col, state)


## 5.4 工事：为同阵线友方陆军提供坚守 = 工事防御力 ÷ 2（向下取整，最高 2）
static func _fort_firm_bonus(state: BattleState, row: int, owner_idx: int) -> int:
	for c in range(state.board.cols):
		var fort: BattleState.UnitData = state.board.get_unit(row, c, "ground")
		if fort != null and fort.owner_index == owner_idx and _unit_class_of(fort) == "fort":
			return min(2, fort.defense / 2)
	return 0


static func _unit_class_of(unit: BattleState.UnitData) -> String:
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	return card_data.unit_class if card_data != null else ""


## 5.4 修筑工事：行动阶段，己方陆军单位在友方占领度 100% 的阵线修筑
## 消耗该单位全部行动 + 战争点 2；每阵线限 1 个；基础防御 2（同阵线有己方"工程"单位时 6）
static func build_fort(state: BattleState, player_idx: int, from_row: int, from_col: int, to_row: int, to_col: int) -> BattleState:
	var new_state: BattleState = state.duplicate(true)
	var builder: BattleState.UnitData = new_state.board.get_unit(from_row, from_col, "ground")
	if builder == null or builder.owner_index != player_idx:
		return null
	if _unit_class_of(builder) == "fort" or _is_air_unit(_unit_class_of(builder)):
		return null  # 只有陆军能修筑，工事自身不能再修
	if builder.retreated:
		return null  # 行动已耗尽
	# 占领度条件：友方占领度 100%
	var control: int = new_state.front_control[to_row] if to_row < new_state.front_control.size() else 0
	if player_idx == 0 and control < 100:
		return null
	if player_idx == 1 and control > -100:
		return null
	# 每阵线限 1 个工事
	for c in range(new_state.board.cols):
		var existing: BattleState.UnitData = new_state.board.get_unit(to_row, c, "ground")
		if existing != null and _unit_class_of(existing) == "fort":
			return null
	# 放置格为空（地面层）
	if new_state.board.get_unit(to_row, to_col, "ground") != null:
		return null
	# 战争点消耗
	var player = new_state.players[player_idx]
	if player.resources["Z"] < 2:
		return null
	player.resources["Z"] -= 2

	# 防御上限：同阵线存在己方"工程"单位 → 6，否则 2
	var cap := 2
	for c in range(new_state.board.cols):
		var u: BattleState.UnitData = new_state.board.get_unit(to_row, c, "ground")
		if u != null and u.owner_index == player_idx and u.abilities.has("工程"):
			cap = 6
	var fort := BattleState.UnitData.new()
	fort.card_id = "fort_01"
	fort.owner_index = player_idx
	fort.attack = 0
	fort.defense = cap
	fort.max_defense = cap
	fort.abilities = []
	fort.deployed_this_turn = true
	new_state.board.set_unit(to_row, to_col, fort, "ground")
	# 修筑消耗全部行动
	builder.has_acted = true
	builder.retreated = true
	builder.patrolling = false
	_log_action(new_state, {"type": "build_fort", "player": player_idx, "from": [from_row, from_col], "to": [to_row, to_col], "defense": cap})
	_refresh_guards(new_state)
	return new_state

#endregion

## ── 合法行动枚举（UI 与 AI 共用；AI 预演验证依赖这些枚举）──

## 指定单位的所有合法移动目标（含 1.3 后退格；1.2 图层内移动）
static func get_valid_move_targets(state: BattleState, from_row: int, from_col: int) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	var layer := "air" if state.board.get_unit(from_row, from_col, "air") != null else "ground"
	var unit: BattleState.UnitData = state.board.get_unit(from_row, from_col, layer)
	if unit == null or unit.owner_index != state.active_player_index:
		return targets
	if unit.deployed_this_turn and not unit.abilities.has("突击"):
		return targets
	if unit.retreated or unit.move_count >= unit.move_limit:
		return targets
	if unit.move_limit <= 1 and not unit.can_move_after_attack and unit.has_acted:
		return targets
	var player_idx := unit.owner_index
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			if dr == 0 and dc == 0:
				continue
			var tr: int = from_row + dr
			var tc: int = from_col + dc
			if tr < 0 or tr >= state.board.rows or tc < 0 or tc >= state.board.cols:
				continue
			var is_retreat := (player_idx == 0 and tr < from_row) or (player_idx == 1 and tr > from_row)
			if is_retreat:
				if dc != 0:
					continue
				if (player_idx == 0 and from_row == 0) or (player_idx == 1 and from_row == state.board.rows - 1):
					continue
			if state.board.get_unit(tr, tc, layer) != null:
				continue
			targets.append(Vector2i(tr, tc))
	return targets


## 指定单位的所有合法攻击目标（1.2 图层定层；不含迷雾过滤——调用方决定是否过滤）
static func get_valid_attack_targets(state: BattleState, player_idx: int, from_row: int, from_col: int) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	var atk_layer := "air" if state.board.get_unit(from_row, from_col, "air") != null else "ground"
	var unit: BattleState.UnitData = state.board.get_unit(from_row, from_col, atk_layer)
	if unit == null or unit.owner_index != player_idx:
		return targets
	if unit.has_attacked or unit.retreated:
		return targets
	if unit.move_limit <= 1 and not unit.can_move_after_attack and unit.has_acted:
		return targets
	var player = state.players[player_idx]
	if player.resources["Z"] < 1:
		return targets
	var attacker_card: Resource = CardDataLoader.cards.get(unit.card_id)
	var attacker_is_air := _unit_class_of(unit) == "fighter" or _unit_class_of(unit) == "bomber"
	for row in range(state.board.rows):
		for col in range(state.board.cols):
			var target: BattleState.UnitData = state.board.get_unit(row, col)
			if target == null and attacker_is_air:
				target = state.board.get_unit(row, col, "air")
			if target == null:
				continue
			if target.owner_index == player_idx:
				continue
			if not _in_attack_range(unit, from_row, from_col, row, col):
				continue
			var defender_card: Resource = CardDataLoader.cards.get(target.card_id)
			if attacker_card != null and defender_card != null:
				var def_is_air := _is_air_unit(defender_card.unit_class)
				if not attacker_is_air and def_is_air:
					continue
				if attacker_card.unit_class == "bomber" and def_is_air:
					continue
			if target.stealthed and not target.revealed:
				continue
			targets.append(Vector2i(row, col))
	return targets

#region 战线占领度（docs/game-mechanics.md 第 5 节）

## 占领贡献权重（仅三种陆军参与，其余兵种不贡献）
const FRONT_CONTROL_WEIGHTS := {"cavalry": 25, "infantry": 50, "tank": 100}


## 每个完整回合结束时结算：逐行统计双方贡献单位
## 双方并存或均无 → 不变；仅一方有 → 向该方推进权重和，封顶 ±100
static func _update_front_control(state: BattleState) -> void:
	while state.front_control.size() < state.board.rows:
		state.front_control.append(0)  # 兜底：未经 setup() 的 state
	for r in range(state.board.rows):
		var p0_score: int = 0
		var p1_score: int = 0
		for c in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(r, c)
			if unit == null:
				continue
			var weight: int = _front_weight(unit.card_id)
			if weight == 0:
				continue
			if unit.owner_index == 0:
				p0_score += weight
			else:
				p1_score += weight
		if p0_score > 0 and p1_score > 0:
			continue  # 双方并存，战线僵持
		if p0_score > 0:
			state.front_control[r] = clampi(state.front_control[r] + p0_score, -100, 100)
		elif p1_score > 0:
			state.front_control[r] = clampi(state.front_control[r] - p1_score, -100, 100)
		# 均无贡献单位 → 保持不变（已占领战线维持占领）


static func _front_weight(card_id: String) -> int:
	# 按卡牌数据声明的兵种（unit_class）取权重，而非 id 前缀
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return 0
	return FRONT_CONTROL_WEIGHTS.get(card_data.unit_class, 0)


## 5 条战线全部到 +100 → P1 胜；全部到 -100 → P2 胜
static func check_front_victory(state: BattleState) -> int:
	if state.front_control.size() < state.board.rows:
		return -1
	var all_p0 := true
	var all_p1 := true
	for r in range(state.board.rows):
		if state.front_control[r] < 100:
			all_p0 = false
		if state.front_control[r] > -100:
			all_p1 = false
	if all_p0:
		return 0
	if all_p1:
		return 1
	return -1

#endregion


## Phase 3: 战争点公式
## 先手 (player_idx=0): 1 + 2×(turn−1) → 1, 3, 5, 7, ...
## 后手 (player_idx=1): 2 + 2×(turn−1) → 2, 4, 6, 8, ...
## 上限 25
static func _calc_z(player_idx: int, turn: int) -> int:
	var base: int = 1 if player_idx == 0 else 2
	var z: int = base + 2 * (turn - 1)
	return min(z, 25)


static func _shuffle_deck(deck: Array) -> void:
	var n: int = deck.size()
	while n > 1:
		n -= 1
		var k: int = randi() % (n + 1)
		var tmp = deck[k]
		deck[k] = deck[n]
		deck[n] = tmp


static func _draw_one(state: BattleState, player_idx: int) -> void:
	var player = state.players[player_idx]
	if player.deck.is_empty():
		return
	var card_id: String = player.deck.pop_front()
	player.purchase_zone.append(card_id)


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
		"infantry", "cavalry", "tank", "fighter", "bomber":
			# 后方始终可部署；占领前线后可部署到前线（坦克/空军入场规则同步兵）
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
			return (dr + dc) == 1  # 十字四格，不含斜角
		"adjacent_8":
			return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
		"column_and_neighbors":
			# 本列 + 相邻两列，任意行
			return abs(from_col - target_col) <= 1 and not (dr == 0 and dc == 0)
		"global":
			return true
		_:
			return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)


static func _counter_attack(attacker: BattleState.UnitData, defender: BattleState.UnitData, atk_row: int, atk_col: int, def_row: int, def_col: int, state: BattleState) -> void:
	# Phase 2 规则：突击部署当回合免反击；冲锋首次攻击免反击
	if attacker.abilities.has("突击") and attacker.deployed_this_turn:
		return
	if attacker.abilities.has("冲锋") and attacker.attack_count == 0:
		return

	# Phase 3: 空战反击规则
	var attacker_card: Resource = CardDataLoader.cards.get(attacker.card_id)
	var defender_card: Resource = CardDataLoader.cards.get(defender.card_id)
	if attacker_card != null and defender_card != null:
		# 火炮不可被反击（Phase 2 规则，保留）
		if attacker_card.unit_class == "artillery":
			return
		# 轰炸机无法反击
		if defender_card.unit_class == "bomber":
			return
		# 非战斗机单位无法反击轰炸机
		if attacker_card.unit_class == "bomber" and defender_card.unit_class != "fighter":
			return
		# 陆军被空军攻击：只有防空词条能反击
		var def_is_air := _is_air_unit(defender_card.unit_class)
		var atk_is_air := _is_air_unit(attacker_card.unit_class)
		if atk_is_air and not def_is_air:
			if not defender.abilities.has("防空"):
				return

	# 防守方反击
	var counter_dmg: int = defender.attack
	# 坚守减伤（Phase 3: 使用 firm_level 替代固定值；3A 工事坚守对被攻击的陆军生效）
	var firm: int = max(attacker.firm_level, _fort_firm_bonus(state, atk_row, attacker.owner_index))
	if firm > 0:
		counter_dmg = max(1, counter_dmg - firm)
	attacker.defense -= counter_dmg
	_log_action(state, {"type": "counter", "player": defender.owner_index, "damage": counter_dmg})
	if attacker.defense <= 0:
		state.board.set_unit(atk_row, atk_col, null, "air" if attacker.is_air else "ground")
		_log_action(state, {"type": "destroy", "player": defender.owner_index, "card_id": attacker.card_id, "reward_g": 0})


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
			unit.can_move_after_attack = true
			# 空军：移动和攻击各一次独立（move_limit 限移动一次，has_attacked 限攻击一次）
		_:
			unit.move_limit = 1
			unit.can_move_after_attack = false

#region Phase 3: 守护词条

## 全量重算守护关系（部署/移动/击杀后调用）：
## 每个有守护词条的单位为其相邻八格同图层友方提供保护 —— 保证相邻关系动态生效
static func _refresh_guards(state: BattleState) -> void:
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u != null:
					u.is_guarded = false
					u.guarded_by = Vector2i(-1, -1)
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var guard: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if guard == null or not guard.abilities.has("守护"):
					continue
				for dr in range(-1, 2):
					for dc in range(-1, 2):
						if dr == 0 and dc == 0:
							continue
						var neighbor: BattleState.UnitData = state.board.get_unit(r + dr, c + dc, layer)
						if neighbor != null and neighbor.owner_index == guard.owner_index:
							neighbor.is_guarded = true
							neighbor.guarded_by = Vector2i(r, c)

#endregion

#region Phase 3: 视野判定

## 计算视角玩家的全部可见格子（docs/game-mechanics.md 4.2）
## UI 层用它渲染格子级迷雾：不在返回集合中的格子一律覆盖迷雾
## 陆空两层单位的视野都计入（1.2 图层共享行列坐标）
static func compute_visible_cells(state: BattleState, viewer_idx: int) -> Dictionary:
	var visible: Dictionary = {}  # {Vector2i: true}
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var unit: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if unit == null or unit.owner_index != viewer_idx:
					continue
				# 我方单位所在格始终可见（兵种视野不含自身脚下）
				visible[Vector2i(r, c)] = true
				var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
				if card_data == null:
					continue
				for tr in range(state.board.rows):
					for tc in range(state.board.cols):
						if _in_vision_range(card_data.vision_range, r, c, tr, tc, viewer_idx):
							visible[Vector2i(tr, tc)] = true
	return visible


## 视野范围判定（与攻击范围判定分开）
static func _in_vision_range(vision_str: String, from_row: int, from_col: int, to_row: int, to_col: int, owner_idx: int) -> bool:
	var dr := to_row - from_row  # 带符号的方向
	var adr: int = abs(dr)
	var adc: int = abs(to_col - from_col)
	# 确定"前方"方向：P1(owner=0) 前方是行号增大，P2(owner=1) 前方是行号减小
	var forward_dr: int = dr if owner_idx == 0 else -dr
	match vision_str:
		"adjacent_4":
			return (adr + adc) == 1  # 仅上下左右
		"adjacent_8":
			return adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0)
		"adjacent_8_forward":
			# 周围八格 + 向前第二格（共 12 格）
			if adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0):
				return true
			if forward_dr == 2 and adc == 0:
				return true
			return false
		"front_3x2":
			# 前方横向 3 列 × 2 行
			return forward_dr >= 1 and forward_dr <= 2 and adc <= 1
		"front_3x3":
			# 前方横向 3 列 × 3 行
			return forward_dr >= 1 and forward_dr <= 3 and adc <= 1
		"frontline_only":
			return dr == 0 and adc <= 1
		"none":
			return false
		_:
			return adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0)

#endregion

#region Phase 3: 补给与后方修复

## 补给词条：友方回合开始时，每个补给单位修复相邻一个已受伤友方
static func _apply_supply(state: BattleState, player_idx: int) -> void:
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(r, c)
			if unit == null or unit.owner_index != player_idx:
				continue
			if unit.supply_level <= 0:
				continue
			# 每个补给单位修复相邻八格中一个已受伤的友方单位
			var healed := false
			for dr in range(-1, 2):
				if healed:
					break
				for dc in range(-1, 2):
					if dr == 0 and dc == 0:
						continue
					var neighbor: BattleState.UnitData = state.board.get_unit(r + dr, c + dc)
					if neighbor != null and neighbor.owner_index == player_idx and neighbor.defense < neighbor.max_defense:
						neighbor.defense = min(neighbor.max_defense, neighbor.defense + unit.supply_level)
						_log_action(state, {"type": "supply", "player": player_idx, "from": [r, c], "to": [r + dr, c + dc], "amount": unit.supply_level})
						healed = true
						break


## 后方修复规则：处于后方（P1 行 0 / P2 行 4）的单位每回合恢复 1 防御力
static func _apply_rear_repair(state: BattleState, player_idx: int) -> void:
	var rear_row := 0 if player_idx == 0 else state.board.rows - 1
	for c in range(state.board.cols):
		var unit: BattleState.UnitData = state.board.get_unit(rear_row, c)
		if unit != null and unit.owner_index == player_idx and unit.defense < unit.max_defense:
			unit.defense = min(unit.max_defense, unit.defense + 1)
			_log_action(state, {"type": "rear_repair", "player": player_idx, "row": rear_row, "col": c})

#endregion

#region Phase 3: 潜行揭露

## 重新计算所有潜行单位的 revealed 状态
## 处于敌方步兵（地面层）或战斗机（空域层）视野范围内的潜行单位 → revealed = true
static func _update_stealth_reveal(state: BattleState) -> void:
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var unit: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if unit == null or not unit.stealthed:
					continue
				unit.revealed = false
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(r, c, "ground")
			if unit == null or not unit.stealthed:
				continue
			_try_reveal_from_enemies(state, unit, r, c)
			_try_reveal_from_enemies_air(state, unit, r, c)


static func _try_reveal_from_enemies(state: BattleState, unit: BattleState.UnitData, r: int, c: int) -> void:
	var enemy_idx := 1 - unit.owner_index
	for er in range(state.board.rows):
		for ec in range(state.board.cols):
			var enemy: BattleState.UnitData = state.board.get_unit(er, ec, "ground")
			if enemy == null or enemy.owner_index != enemy_idx:
				continue
			var enemy_card: Resource = CardDataLoader.cards.get(enemy.card_id)
			if enemy_card == null or enemy_card.unit_class != "infantry":
				continue
			if _in_vision_range(enemy_card.vision_range, er, ec, r, c, enemy_idx):
				unit.revealed = true
				return


static func _try_reveal_from_enemies_air(state: BattleState, unit: BattleState.UnitData, r: int, c: int) -> void:
	var enemy_idx := 1 - unit.owner_index
	for er in range(state.board.rows):
		for ec in range(state.board.cols):
			var enemy: BattleState.UnitData = state.board.get_unit(er, ec, "air")
			if enemy == null or enemy.owner_index != enemy_idx:
				continue
			var enemy_card: Resource = CardDataLoader.cards.get(enemy.card_id)
			if enemy_card == null or enemy_card.unit_class != "fighter":
				continue
			if _in_vision_range(enemy_card.vision_range, er, ec, r, c, enemy_idx):
				unit.revealed = true
				return

#endregion

#region 联网同步

## 状态指纹 — 两端对同一指令序列应产生相同指纹，不一致即失步
## 纯字符串拼接 + hash，Godot hash() 在同版本引擎间稳定（两端同版本为前提）
static func state_fingerprint(state: BattleState) -> String:
	var parts: Array[String] = []
	parts.append("t%d" % state.turn)
	parts.append(state.phase)
	parts.append("a%d" % state.active_player_index)
	parts.append("w%d" % state.winner)
	parts.append("fc%s" % str(state.front_control))
	for pi2 in range(2):
		parts.append("buy%s" % str(state.players[pi2].purchases_this_turn))
	for pi in range(state.players.size()):
		var p = state.players[pi]
		parts.append("p%d:g%d,k%d,z%d" % [pi, p.resources["G"], p.resources["K"], p.resources["Z"]])
		for cid in p.hand:
			parts.append("h:" + cid)
		for cid in p.purchase_zone:
			parts.append("z:" + cid)
		for cid in p.discard:
			parts.append("x:" + cid)
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u = state.board.get_unit(r, c, layer)
				if u != null:
					parts.append("u:%d,%d,%s,o%d,a%d,d%d,ac%s,at%s,mc%d,dk%s,gu%s,gb%s,sv%s,rv%s,ck%d,fm%d,md%d,ir%s,pt%s,rt%s" % [
						r, c, u.card_id, u.owner_index, u.attack, u.defense,
						str(u.has_acted), str(u.has_attacked), u.move_count,
						str(u.deployed_this_turn), str(u.is_guarded), str(u.guarded_by),
						str(u.stealthed), str(u.revealed), u.attack_count, u.firm_level, u.max_defense,
						str(u.is_air), str(u.patrolling), str(u.retreated)])
	parts.append("log%d" % state.action_log.size())
	return str(hash(",".join(parts)))

#endregion
