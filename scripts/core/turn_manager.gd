extends Node
class_name TurnManager

## 回合流转管理 — 持有 BattleState，编排 GameLogic 调用，发信号驱动 UI

signal state_changed(new_state: BattleState)
signal phase_changed(new_phase: String)
signal game_over(winner: int)
signal action_failed(reason: String)

var battle_state: BattleState = null


func start_game(p1_deck: Array[String], p2_deck: Array[String], p1_starter: String, p2_starter: String) -> void:
	battle_state = GameLogic.init_game(p1_deck, p2_deck, p1_starter, p2_starter)
	battle_state = GameLogic.start_turn(battle_state)
	_emit_all()


func submit_action(action: Dictionary) -> void:
	if battle_state == null:
		return
	if battle_state.winner != -1:
		return  # 游戏已结束

	var action_type: String = action.get("type", "")
	var player_idx: int = action.get("player_idx", battle_state.active_player_index)

	# 只允许当前活跃玩家操作
	if player_idx != battle_state.active_player_index:
		action_failed.emit("不是你的回合")
		return

	var new_state: BattleState = null

	match action_type:
		"purchase":
			new_state = GameLogic.purchase_card(battle_state, player_idx, action.get("card_id", ""))
		"deploy":
			new_state = GameLogic.deploy_unit(battle_state, player_idx, action.get("card_id", ""), action.get("row", -1), action.get("col", -1))
		"move":
			new_state = GameLogic.move_unit(battle_state, player_idx, action.get("from_row", -1), action.get("from_col", -1), action.get("to_row", -1), action.get("to_col", -1))
		"attack":
			new_state = GameLogic.attack_unit(battle_state, player_idx, action.get("from_row", -1), action.get("from_col", -1), action.get("target_row", -1), action.get("target_col", -1))
		"end_turn":
			new_state = GameLogic.end_turn(battle_state)
			if new_state.winner == -1:
				# 开始新回合
				new_state = GameLogic.start_turn(new_state)
		"skip_phase":
			new_state = _skip_phase(battle_state)
		_:
			action_failed.emit("未知操作类型: " + action_type)
			return

	if new_state == null or new_state == battle_state:
		return  # 操作无效，状态未变

	battle_state = new_state
	_emit_all()

	if battle_state.winner != -1:
		game_over.emit(battle_state.winner)


func _skip_phase(state: BattleState) -> BattleState:
	# 注意：duplicate(true) 返回 Resource 类型，需要显式转型为 BattleState
	var ns: BattleState = state.duplicate(true)
	match ns.phase:
		"purchase":
			ns.phase = "deploy"
		"deploy":
			ns.phase = "action"
		"action":
			pass  # 用 end_turn 跳过
		_:
			pass
	return ns


func get_state() -> BattleState:
	return battle_state


func _emit_all() -> void:
	state_changed.emit(battle_state)
	phase_changed.emit(battle_state.phase)
