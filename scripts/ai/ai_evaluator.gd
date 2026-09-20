extends RefCounted
class_name AIEvaluator

## AI 局面分析与行动评分（纯函数，无节点依赖）
## 设计要点（docs/ai-design.md）：
## - 行动枚举采用 GameLogic 预演验证：候选必然被引擎接受
## - 信息范围：棋盘明面 + 自己手牌/资源；攻击目标受战争迷雾约束；不读敌方手牌
## - 评分可解释：每个候选 = {type, params, score}，调试模式可整体输出
## - 扩展性：新增行动类型 → 枚举加一项 + 评分函数加一节；新卡牌/单位 → 通用战力评估自动兼容

var cfg: AIConfig


func _init(difficulty: String = "normal") -> void:
	cfg = AIConfig.get_config(difficulty)


## 主入口：枚举全部合法行动并评分，返回按分排序的候选（含噪声，按难度池选择）
## 返回 {} 表示没有更有价值的行动 → 调用方应结束回合
func choose_action(state: BattleState, ai_idx: int) -> Dictionary:
	var candidates: Array = []
	# 阶段过滤（与 TurnManager._phase_allows 对齐）：预演绕过了阶段门控，必须在此过滤
	match state.phase:
		"purchase":
			candidates.append_array(_enum_purchases(state, ai_idx))
		"deploy":
			candidates.append_array(_enum_deploys(state, ai_idx))
		"action":
			candidates.append_array(_enum_moves(state, ai_idx))
			candidates.append_array(_enum_attacks(state, ai_idx))
			candidates.append_array(_enum_forts(state, ai_idx))
		_:
			return {}  # 未知阶段（draw/game_over）→ 结束回合
	if candidates.is_empty():
		return {}
	# 噪声 + 池选择
	var visible := GameLogic.compute_visible_cells(state, ai_idx)
	for c in candidates:
		c["score"] += randf_range(-cfg.noise, cfg.noise)
	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	var pick_n: int = mini(cfg.pool, candidates.size())
	# 只有明确正收益的行动才值得做；否则结束回合
	if candidates[0]["score"] <= 0.0:
		return {}
	var picked: Dictionary = candidates[randi() % pick_n]
	picked["_visible"] = visible
	picked["_alternatives"] = candidates.size()
	return picked


## ── 购买 ──

func _enum_purchases(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	var player = state.players[ai_idx]
	for card_id in player.purchase_zone:
		var new_state: BattleState = GameLogic.purchase_card(state, ai_idx, card_id)
		if new_state == null:
			continue  # G 不足/手牌满/稀有度上限——预演淘汰
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		var power: float = float(card_data.attack + card_data.defense)
		var efficiency: float = power / maxf(1.0, float(card_data.cost_g) * 0.25)
		# 困难 AI 适度克制：战力已占优时仍保持生产（经济可累积，生产不会亏）
		out.append({"type": "purchase", "card_id": card_id, "score": efficiency * 6.0})
	return out


## ── 部署 ──

func _enum_deploys(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	var player = state.players[ai_idx]
	for card_id in player.hand:
		var rows := GameLogic.get_deployable_rows(state, ai_idx, card_id)
		for row in rows:
			for col in range(state.board.cols):
				var new_state: BattleState = GameLogic.deploy_unit(state, ai_idx, card_id, row, col)
				if new_state == null:
					continue
				var card_data: Resource = CardDataLoader.cards.get(card_id)
				var power: float = float(card_data.attack + card_data.defense) if card_data != null else 4.0
				var score: float = 4.0 + power * 0.4
				# 部署到有敌方单位的战线 → 前线压力加成（侵略性）
				if _line_has_enemy(state, ai_idx, row):
					score += 3.0 * cfg.aggression
				# 部署到完全无人的战线 → 占领加成
				if _line_unit_count(state, ai_idx, row) == 0 and not _line_has_enemy(state, ai_idx, row):
					score += 2.0
				out.append({"type": "deploy", "card_id": card_id, "row": row, "col": col, "score": score})
	return out


## ── 移动 ──

func _enum_moves(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	var my_units := _my_units(state, ai_idx)
	for entry in my_units:
		var unit: BattleState.UnitData = entry["unit"]
		var targets := GameLogic.get_valid_move_targets(state, entry["row"], entry["col"])
		for t in targets:
			var new_state: BattleState = GameLogic.move_unit(state, ai_idx, entry["row"], entry["col"], t.x, t.y)
			if new_state == null:
				continue
			var score: float = _move_score(state, ai_idx, unit, entry, t)
			out.append({"type": "move", "from_row": entry["row"], "from_col": entry["col"], "to_row": t.x, "to_col": t.y, "score": score})
	return out


func _move_score(state: BattleState, ai_idx: int, unit: BattleState.UnitData, entry: Dictionary, t: Vector2i) -> float:
	var score := 1.0
	# 前进推进（向敌方方向）
	var forward := false
	if ai_idx == 0 and t.x > entry["row"]:
		forward = true
	elif ai_idx == 1 and t.x < entry["row"]:
		forward = true
	if forward:
		score += 2.0 * cfg.aggression
	# 部署当回合/已行动单位挪窝没有价值
	if unit.has_acted and unit.move_limit <= 1:
		score -= 5.0
	# 风险意识：从更强敌人的攻击范围里挪出去（threat_aware）
	if cfg.threat_aware:
		var danger_now := _threat_at(state, ai_idx, entry["row"], entry["col"], unit)
		var danger_then := _threat_at(state, ai_idx, t.x, t.y, unit)
		if unit.defense <= danger_now and danger_then < danger_now:
			score += 2.5  # 逃离致命格
		if danger_then > danger_now and unit.defense <= danger_then:
			score -= 2.5  # 走进致命格
	# 占领无人战线（占领度机制）
	if _line_unit_count(state, ai_idx, t.x) == 0 and not _line_has_enemy(state, ai_idx, t.x):
		score += 1.5
	return score


## ── 攻击 ──

func _enum_attacks(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	var visible := GameLogic.compute_visible_cells(state, ai_idx)
	var my_units := _my_units(state, ai_idx)
	for entry in my_units:
		var unit: BattleState.UnitData = entry["unit"]
		var targets := GameLogic.get_valid_attack_targets(state, ai_idx, entry["row"], entry["col"])
		for t in targets:
			# 迷雾约束：只能攻击视野内的敌人
			if not visible.has(t):
				continue
			var new_state: BattleState = GameLogic.attack_unit(state, ai_idx, entry["row"], entry["col"], t.x, t.y)
			if new_state == null:
				continue
			var score: float = _attack_score(state, ai_idx, unit, entry, t)
			out.append({"type": "attack", "from_row": entry["row"], "from_col": entry["col"], "target_row": t.x, "target_col": t.y, "score": score})
	return out


func _attack_score(state: BattleState, ai_idx: int, unit: BattleState.UnitData, entry: Dictionary, t: Vector2i) -> float:
	var layer := "air" if entry.get("air", false) else "ground"
	var target: BattleState.UnitData = state.board.get_unit(t.x, t.y)
	if target == null and layer == "air":
		target = state.board.get_unit(t.x, t.y, "air")
	if target == null:
		return -100.0
	var t_val := _unit_value(target)
	var damage: int = unit.attack
	var effective_firm: int = max(target.firm_level, GameLogic._fort_firm_bonus(state, t.x, target.owner_index))
	if effective_firm > 0:
		damage = max(1, damage - effective_firm)
	var kills := damage >= target.defense
	var score: float = t_val * (1.5 if kills else 0.6)
	# 预期反击损失（risk_aware）
	if cfg.risk_aware and not kills:
		var counter := _expected_counter(state, unit, entry, target, t)
		score -= float(counter) * 0.8 * _unit_value(unit) / 10.0
		# 空战风险：目标线有敌巡逻且我方空中力量单薄 → 攻击作废风险
		if _air_unit(unit) and _patrol_count(state, ai_idx, t.x) > 0:
			score -= 6.0
	else:
		score += 1.0  # 击杀免反击的确定性
	return score * cfg.aggression


## ── 工事 ──

func _enum_forts(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	for entry in _my_units(state, ai_idx):
		if entry.get("air", false):
			continue
		var unit: BattleState.UnitData = entry["unit"]
		if GameLogic._unit_class_of(unit) == "fort":
			continue
		for row in range(state.board.rows):
			# 占领度 100% 的战线
			var control: int = state.front_control[row] if row < state.front_control.size() else 0
			if (ai_idx == 0 and control < 100) or (ai_idx == 1 and control > -100):
				continue
			# 该线已有工事则跳过
			var has_fort := false
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(row, c, "ground")
				if u != null and GameLogic._unit_class_of(u) == "fort":
					has_fort = true
			if has_fort:
				continue
			for col in range(state.board.cols):
				if state.board.get_unit(row, col, "ground") != null:
					continue
				var new_state: BattleState = GameLogic.build_fort(state, ai_idx, entry["row"], entry["col"], row, col)
				if new_state == null:
					continue
				var score: float = 5.0 * cfg.fort_zeal
				if _line_has_enemy(state, ai_idx, row):
					score += 3.0 * cfg.fort_zeal
				out.append({"type": "build_fort", "from_row": entry["row"], "from_col": entry["col"], "row": row, "col": col, "score": score})
	return out


## ── 局面工具 ──

static func _my_units(state: BattleState, ai_idx: int) -> Array:
	var out: Array = []
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u != null and u.owner_index == ai_idx:
					out.append({"unit": u, "row": r, "col": c, "air": layer == "air"})
	return out


static func _unit_value(unit: BattleState.UnitData) -> float:
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	var cost: float = float(card_data.cost_g) if card_data != null else 10.0
	return float(unit.attack + unit.defense) + cost * 0.05


static func _air_unit(unit: BattleState.UnitData) -> bool:
	var cls := GameLogic._unit_class_of(unit)
	return cls == "fighter" or cls == "bomber"


static func _line_has_enemy(state: BattleState, ai_idx: int, row: int) -> bool:
	for c in range(state.board.cols):
		for layer in ["ground", "air"]:
			var u: BattleState.UnitData = state.board.get_unit(row, c, layer)
			if u != null and u.owner_index != ai_idx:
				return true
	return false


static func _line_unit_count(state: BattleState, ai_idx: int, row: int) -> int:
	var n := 0
	for c in range(state.board.cols):
		var u: BattleState.UnitData = state.board.get_unit(row, c, "ground")
		if u != null and u.owner_index == ai_idx:
			n += 1
	return n


## 该格若被多少攻击力打击会受创（威胁近似：相邻/射程内敌方的攻击力之和）
func _threat_at(state: BattleState, ai_idx: int, row: int, col: int, unit: BattleState.UnitData) -> int:
	var threat := 0
	for er in range(state.board.rows):
		for ec in range(state.board.cols):
			for layer in ["ground", "air"]:
				var e: BattleState.UnitData = state.board.get_unit(er, ec, layer)
				if e == null or e.owner_index == ai_idx:
					continue
				# 近似射程：八邻格 + 空军列射程 + 火炮全图
				var in_range: bool = abs(er - row) <= 1 and abs(ec - col) <= 1
				if not in_range and GameLogic._unit_class_of(e) == "artillery":
					in_range = true
				if not in_range and _air_unit(e) and abs(ec - col) <= 1:
					in_range = true
				if in_range:
					threat += e.attack
	return threat


## 反击预期伤害（近似 _counter_attack 规则：是否会被反击）
func _expected_counter(state: BattleState, unit: BattleState.UnitData, entry: Dictionary, target: BattleState.UnitData, t: Vector2i) -> int:
	var my_cls := GameLogic._unit_class_of(unit)
	var t_cls := GameLogic._unit_class_of(target)
	if t_cls == "bomber":
		return 0        # 3.8 轰炸机无法反击
	if my_cls == "artillery":
		return 0        # 3.6 火炮不可被反击
	if unit.abilities.has("冲锋") and unit.attack_count == 0:
		return 0        # 冲锋首击免反击
	if my_cls == "bomber":
		return 0        # 3.4 轰炸机打陆军不遭反击（陆军无防空时）
	if _air_unit(unit) and t_cls != "fighter" and not target.abilities.has("防空"):
		return 0        # 空军打无防空陆军
	return target.attack


static func _patrol_count(state: BattleState, ai_idx: int, row: int) -> int:
	var n := 0
	var enemy := 1 - ai_idx
	for c in range(state.board.cols):
		var p: BattleState.UnitData = state.board.get_unit(row, c, "air")
		if p != null and p.owner_index == enemy and p.patrolling:
			n += 1
	return n
