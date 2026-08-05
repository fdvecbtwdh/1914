extends Node

## 临时验证脚本 — TurnManager 回合编排
## 通过场景运行（autoload 先注册，GameLogic 内 CardDataLoader 引用才能解析）：
##   godot --headless --path . tests/test_turn_manager_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0

var _state_changed_count := 0
var _phase_changed_count := 0
var _last_phase := ""
var _game_over_winner := -2
var _action_failed_reasons: Array[String] = []


func _ready() -> void:
	_run_all()
	print("\n========== TURN MANAGER TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL TESTS PASSED")
	else:
		printerr("%d TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _run_all() -> void:
	_test_start_game()
	_test_purchase()
	_test_wrong_player_rejected()
	_test_unknown_type()
	_test_phase_enforcement()
	_test_skip_phase()
	_test_deploy()
	_test_end_turn_advances()
	_test_game_over()


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _reset() -> void:
	_state_changed_count = 0
	_phase_changed_count = 0
	_last_phase = ""
	_game_over_winner = -2
	_action_failed_reasons.clear()


## 9 张步兵的固定卡组（初始抽 3 + 首发都在购买区）
func _deck() -> Array[String]:
	var d: Array[String] = []
	for i in range(9):
		d.append("test_infantry_01")
	return d


func _make_tm() -> TurnManager:
	var tm := TurnManager.new()
	add_child(tm)
	tm.state_changed.connect(func(_s): _state_changed_count += 1)
	tm.phase_changed.connect(func(p): _phase_changed_count += 1; _last_phase = p)
	tm.game_over.connect(func(w): _game_over_winner = w)
	tm.action_failed.connect(func(r): _action_failed_reasons.append(r))
	return tm


func _place_unit(state: BattleState, owner: int, row: int, col: int) -> void:
	var u: BattleState.UnitData = BattleState.UnitData.new()
	u.card_id = "test_infantry_01"
	u.owner_index = owner
	u.attack = 2
	u.defense = 3
	u.max_defense = 3
	u.has_acted = false
	u.deployed_this_turn = false
	state.board.set_unit(row, col, u)


func _test_start_game() -> void:
	_reset()
	print("[start_game]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	var st := tm.battle_state
	_check(st != null, "battle_state set after start_game")
	_check(tm.get_state() == st, "get_state() returns battle_state")
	_check(st.phase == "purchase", "phase is purchase (init_game + start_turn), got %s" % st.phase)
	_check(st.active_player_index == 0, "P1 is active player")
	_check(st.players[0].resources["G"] == 150, "P1 G=150 after start_turn")
	_check(st.players[0].resources["K"] == 1 and st.players[0].resources["Z"] == 1, "P1 K=Z=1 (turn 1)")
	_check(_state_changed_count == 1, "state_changed emitted once")
	_check(_phase_changed_count == 1 and _last_phase == "purchase", "phase_changed emitted with 'purchase'")


func _test_purchase() -> void:
	_reset()
	print("[submit_action purchase]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	var zone_before := tm.battle_state.players[0].purchase_zone.size()
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	var st := tm.battle_state
	_check(st.players[0].hand.has("test_infantry_01"), "card moved to hand")
	_check(st.players[0].resources["G"] == 148, "G deducted by cost_g(2): 150-2=148")
	_check(st.players[0].purchase_zone.size() == zone_before - 1, "purchase_zone count -1 (one copy removed)")
	_check(_state_changed_count == 2, "state_changed emitted on purchase")


func _test_wrong_player_rejected() -> void:
	_reset()
	print("[submit_action wrong player]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	var before := tm.battle_state
	tm.submit_action({"type": "purchase", "player_idx": 1, "card_id": "test_infantry_01"})
	_check(_action_failed_reasons.size() == 1, "action_failed emitted once")
	_check(_action_failed_reasons.size() == 1 and _action_failed_reasons[0] == "不是你的回合",
		"reason is 不是你的回合, got '%s'" % (_action_failed_reasons[0] if _action_failed_reasons.size() > 0 else ""))
	_check(tm.battle_state == before, "state unchanged after rejected action")
	_check(_state_changed_count == 1, "no extra state_changed")


func _test_unknown_type() -> void:
	_reset()
	print("[submit_action unknown type]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	tm.submit_action({"type": "hack"})
	_check(_action_failed_reasons.size() == 1, "action_failed emitted once")
	_check(_action_failed_reasons.size() == 1 and _action_failed_reasons[0].begins_with("未知操作类型"),
		"reason starts with 未知操作类型, got '%s'" % (_action_failed_reasons[0] if _action_failed_reasons.size() > 0 else ""))


func _test_phase_enforcement() -> void:
	_reset()
	print("[phase_enforcement]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	# purchase 阶段：不能 deploy, move, attack, end_turn
	tm.submit_action({"type": "deploy", "card_id": "test_infantry_01", "row": 0, "col": 0})
	_check(_action_failed_reasons.size() == 1, "deploy rejected during purchase phase")
	_check(_action_failed_reasons[0] == "当前阶段不允许此操作", "reason is 当前阶段不允许此操作")
	# purchase 阶段：purchase 和 skip_phase 应该通过
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	_check(_action_failed_reasons.size() == 1, "purchase passes during purchase phase (no new failure)")
	tm.submit_action({"type": "skip_phase"})  # purchase → deploy
	# deploy 阶段：不能 purchase, move, attack, end_turn
	_reset()
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	_check(_action_failed_reasons.size() == 1, "purchase rejected during deploy phase")
	# action 阶段
	tm.submit_action({"type": "skip_phase"})  # deploy → action
	_reset()
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	_check(_action_failed_reasons.size() == 1, "purchase rejected during action phase")
	tm.submit_action({"type": "skip_phase"})
	_check(_action_failed_reasons.size() == 1, "skip_phase rejected during action phase (use end_turn)")
	tm.submit_action({"type": "end_turn"})
	_check(_action_failed_reasons.size() == 2, "end_turn passes during action phase (reason count +1 for skip_phase failure)")


func _test_skip_phase() -> void:
	_reset()
	print("[submit_action skip_phase]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	_check(tm.battle_state.phase == "purchase", "starts in purchase")
	tm.submit_action({"type": "skip_phase"})
	_check(tm.battle_state.phase == "deploy", "purchase -> deploy")
	tm.submit_action({"type": "skip_phase"})
	_check(tm.battle_state.phase == "action", "deploy -> action")
	tm.submit_action({"type": "skip_phase"})
	_check(tm.battle_state.phase == "action", "action phase skip is no-op (use end_turn instead)")


func _test_deploy() -> void:
	_reset()
	print("[submit_action deploy]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	tm.submit_action({"type": "skip_phase"})  # purchase → deploy
	tm.submit_action({"type": "deploy", "card_id": "test_infantry_01", "row": 0, "col": 0})
	var st := tm.battle_state
	var u := st.board.get_unit(0, 0)
	_check(u != null and u.owner_index == 0, "unit deployed at (0,0) by P1")
	_check(st.players[0].resources["Z"] == 0, "Z deducted by cost_k(1) on deploy")
	_check(not st.players[0].hand.has("test_infantry_01"), "card removed from hand after deploy")
	# 非法部署（行 2 对 P1 不允许）→ GameLogic 返回 null，TurnManager 静默忽略
	tm.submit_action({"type": "deploy", "card_id": "test_infantry_01", "row": 2, "col": 0})
	_check(tm.battle_state.board.get_unit(2, 0) == null, "illegal deploy (row 2) places nothing")


func _test_end_turn_advances() -> void:
	_reset()
	print("[submit_action end_turn]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	tm.submit_action({"type": "skip_phase"})  # purchase → deploy
	tm.submit_action({"type": "skip_phase"})  # deploy → action
	tm.submit_action({"type": "end_turn"})
	var st := tm.battle_state
	_check(st.active_player_index == 1, "active player switches to P2")
	_check(st.phase == "purchase", "P2 starts in purchase (start_turn auto-called after end_turn)")
	_check(st.players[1].resources["G"] == 150, "P2 G=150 after auto start_turn")
	_check(st.players[1].resources["K"] == 1 and st.players[1].resources["Z"] == 1, "P2 K=Z=1")
	_check(st.turn == 1, "turn stays 1 during P2's turn")
	_check(st.players[0].resources["K"] == 0 and st.players[0].resources["Z"] == 0, "P1 K/Z cleared on end_turn")
	_check(_game_over_winner == -2, "no game_over emitted")


func _test_game_over() -> void:
	_reset()
	print("[game_over]")
	var tm := _make_tm()
	tm.start_game(_deck(), _deck(), "test_infantry_01", "test_infantry_01")
	# 构造 P1 占满 P2 区域（行3-4）每列 → 触发胜利
	for c in range(5):
		_place_unit(tm.battle_state, 0, 3, c)
	tm.submit_action({"type": "skip_phase"})  # purchase → deploy
	tm.submit_action({"type": "skip_phase"})  # deploy → action
	tm.submit_action({"type": "end_turn"})
	_check(_game_over_winner == 0, "game_over(0) emitted")
	_check(tm.battle_state.winner == 0, "battle_state.winner == 0")
	_check(tm.battle_state.phase == "game_over", "phase is game_over")
	# 游戏结束后操作被静默忽略（不产生 action_failed）
	var ref := tm.battle_state
	tm.submit_action({"type": "purchase", "card_id": "test_infantry_01"})
	_check(tm.battle_state == ref, "post-game action ignored (state reference unchanged)")
	_check(_action_failed_reasons.is_empty(), "no action_failed after game over (silently ignored)")
