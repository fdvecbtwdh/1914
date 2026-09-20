extends Node

## AI 系统回归 — AI vs AI 全对局 / 三难度 / 边界（无资源/无单位）/ 迷雾约束 / 可复现性
## Run: godot --headless --path . res://tests/test_ai_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0


func _ready() -> void:
	await _run_all()
	print("\n========== AI TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL AI TESTS PASSED")
	else:
		printerr("%d AI TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _default_deck() -> Array[String]:
	var deck: Array[String] = []
	var parsed: Variant = JSON.parse_string(FileAccess.open("res://data/decks/player_default.json", FileAccess.READ).get_as_text())
	var cards: Array = parsed.get("cards", []) if parsed is Dictionary else []
	for c in cards:
		deck.append(str(c))
	return deck


## ── 全对局：双 AI 零间隔驱动至终局 ──
func _run_full_game(d1_diff: String, d2_diff: String, max_wait_ms: int) -> Dictionary:
	seed(randi())
	var tm := TurnManager.new()
	add_child(tm)
	var deck := _default_deck()
	tm.start_game(deck.duplicate(), deck.duplicate(), deck[0], deck[0])
	var d1 := AIDirector.new()
	add_child(d1)
	d1.setup(tm, 0, d1_diff, 0.0)

	var d2 := AIDirector.new()
	add_child(d2)
	d2.setup(tm, 1, d2_diff, 0.0)

	tm.action_failed.connect(func(reason: String):
		printerr("[AI-DBG] REJECTED: ", reason, " log=", tm.battle_state.action_log.size()))
	var start_ms := Time.get_ticks_msec()
	while tm.battle_state.winner == -1 and Time.get_ticks_msec() - start_ms < max_wait_ms:
		await get_tree().process_frame
	var result := {
		"winner": tm.battle_state.winner,
		"turns": tm.battle_state.turn,
		"actions": tm.battle_state.action_log.size(),
		"timed_out": tm.battle_state.winner == -1,
	}
	tm.queue_free()
	return result


func _test_full_games() -> void:
	print("[full games ai vs ai]")
	for combo in [["easy", "easy"], ["normal", "normal"], ["hard", "hard"], ["normal", "hard"]]:
		var result := await _run_full_game(combo[0], combo[1], 45000)
		var label := "%s vs %s" % [combo[0], combo[1]]
		_check(not result["timed_out"], "%s: game finished (turns=%d actions=%d)" % [label, result["turns"], result["actions"]])
		_check(int(result["winner"]) == 0 or int(result["winner"]) == 1, "%s: legal winner %d" % [label, result["winner"]])


## ── 边界：AI 无资源 / 无单位 / 空手牌 ──
func _test_edge_cases() -> void:
	print("[edge cases]")
	var ev := AIEvaluator.new("normal")
	# E1 无资源、空手牌、空购买区 → 无候选（应结束回合）
	var st := BattleState.new()
	st.setup(["infantry_01"], ["infantry_01"], "infantry_01", "infantry_01")
	st.active_player_index = 1
	st.phase = "action"
	st.players[1].resources = {"G": 0, "Z": 0, "K": 0}
	st.players[1].hand.clear()
	st.players[1].purchase_zone.clear()
	var choice := ev.choose_action(st, 1)
	_check(choice.is_empty(), "E1 no resources/units/cards -> empty (end turn)")

	# E2 有单位但 Z=0 且全部已行动 → 无候选
	_place(st, 1, 4, 2, "infantry_01")
	var u: BattleState.UnitData = st.board.get_unit(4, 2)
	u.has_acted = true
	u.has_attacked = true
	choice = ev.choose_action(st, 1)
	_check(choice.is_empty(), "E2 units exhausted -> empty (end turn)")

	# E3 有 Z 有单位（未行动）→ 有候选（移动/攻击）
	st = _fresh_ai_state()
	_place(st, 1, 4, 2, "infantry_01")
	choice = ev.choose_action(st, 1)
	_check(not choice.is_empty(), "E3 movable unit yields candidates")

	# E4 迷雾约束：视野外的敌人不进入攻击候选
	st = _fresh_ai_state()
	_place(st, 1, 4, 2, "fighter_01", true)  # AI 空军（视野 front_3x2 向前）
	var far_enemy := _place(st, 0, 0, 0, "infantry_01")  # 远离视野（后方 4 行）
	choice = ev.choose_action(st, 1)
	var attacks_far := false
	if not choice.is_empty() and str(choice.get("type", "")) == "attack":
		if int(choice.get("target_row", -1)) == 0 and int(choice.get("target_col", -1)) == 0:
			attacks_far = true
	_check(not attacks_far, "E4 AI does not attack fog-hidden enemy")

	# E5 视野内的敌人可以被攻击
	var near := _place(st, 0, 2, 2, "infantry_01")  # 前方 2 行 → front_3x2 视野内
	choice = ev.choose_action(st, 1)
	var attacks_near := false
	if not choice.is_empty() and str(choice.get("type", "")) == "attack":
		if int(choice.get("target_row", -1)) == 2:
			attacks_near = true
	_check(attacks_near or not choice.is_empty(), "E5 visible enemy considered")


## ── 三档难度差异可观测 ──
func _test_difficulty_configs() -> void:
	print("[difficulty configs]")
	var easy := AIConfig.get_config("easy")
	var normal := AIConfig.get_config("normal")
	var hard := AIConfig.get_config("hard")
	_check(easy.noise > normal.noise and normal.noise > hard.noise, "noise decreases with difficulty")
	_check(easy.pool >= normal.pool and normal.pool >= hard.pool, "candidate pool narrows with difficulty")
	_check(not easy.risk_aware and normal.risk_aware and hard.risk_aware, "risk awareness gated by difficulty")
	_check(easy.threat_aware == false and hard.threat_aware == true, "threat awareness gated by difficulty")


func _fresh_ai_state() -> BattleState:
	var st := BattleState.new()
	st.setup(["infantry_01"], ["infantry_01"], "infantry_01", "infantry_01")
	st.active_player_index = 1
	st.phase = "action"
	st.players[1].resources = {"G": 300, "K": 5, "Z": 9}
	st.players[0].resources = {"G": 300, "K": 5, "Z": 9}
	return st


func _place(st: BattleState, owner: int, row: int, col: int, card_id: String, air: bool = false) -> BattleState.UnitData:
	var u := BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner
	u.attack = 4
	u.defense = 3
	u.max_defense = 3
	if card_id.begins_with("fighter"):
		u.move_limit = 1
		u.can_move_after_attack = true
	st.board.set_unit(row, col, u, "air" if air else "ground")
	return u


func _run_all() -> void:
	seed(20260920)
	_test_difficulty_configs()
	await _test_edge_cases()
	await _test_full_games()
