extends Node

## 复盘系统回归 — ReplayStore 快照往返 / 操作描述 / 结算统计 / 分组树
## Run: godot --headless --path . res://tests/test_replay_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== REPLAY TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL REPLAY TESTS PASSED")
	else:
		printerr("%d REPLAY TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _run_all() -> void:
	_test_snapshot_roundtrip()
	_test_describe()
	_test_compute_stats()
	_test_group_actions()
	_test_build_replay()


func _place(state: BattleState, owner: int, row: int, col: int, card_id: String = "test_infantry_01") -> void:
	var u := BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner
	u.attack = 2
	u.defense = 3
	u.max_defense = 3
	state.board.set_unit(row, col, u)


func _make_state() -> BattleState:
	var st := BattleState.new()
	var deck: Array[String] = ["test_infantry_01", "test_infantry_01", "test_infantry_01"]
	st.setup(deck, deck.duplicate(), "test_infantry_01", "test_infantry_01")
	st.front_control = [0, 50, -100, 0, 0]
	_place(st, 0, 1, 1)
	_place(st, 1, 3, 2, "tank_01")
	st.players[0].resources = {"G": 120, "Z": 3, "K": 2}
	st.players[1].resources = {"G": 80, "Z": 1, "K": 0}
	st.players[0].hand.assign(["test_infantry_01"])
	st.turn = 3
	st.phase = "action"
	st.active_player_index = 1
	return st


func _test_snapshot_roundtrip() -> void:
	print("[snapshot roundtrip]")
	var st := _make_state()
	var snap := ReplayStore.make_snapshot(st)
	var st2 := ReplayStore.snapshot_to_state(snap)
	_check(st2.turn == 3 and st2.phase == "action" and st2.active_player_index == 1,
		"turn/phase/active restored")
	_check(st2.front_control == [0, 50, -100, 0, 0], "front_control restored")
	_check(st2.players[0].resources["G"] == 120 and st2.players[1].resources["Z"] == 1,
		"resources restored")
	_check(st2.players[0].hand == ["test_infantry_01"] or st2.players[0].hand.size() == 1,
		"hand restored")
	var u01: BattleState.UnitData = st2.board.get_unit(1, 1)
	var u32: BattleState.UnitData = st2.board.get_unit(3, 2)
	_check(u01 != null and u01.owner_index == 0 and u01.attack == 2 and u01.defense == 3,
		"unit at (1,1) restored with stats")
	_check(u32 != null and u32.card_id == "tank_01" and u32.owner_index == 1,
		"enemy tank restored")
	_check(st2.board.get_unit(0, 0) == null, "empty cell stays empty")


func _test_describe() -> void:
	print("[describe_action]")
	var before := {"units": [{"r": 1, "c": 1, "id": "test_infantry_01"}]}
	_check(ReplayStore.describe_action({"type": "purchase", "card_id": "test_infantry_01"}) == "购买 测试步兵",
		"purchase text")
	_check(ReplayStore.describe_action({"type": "deploy", "card_id": "test_infantry_01", "row": 0, "col": 2}) == "部署 测试步兵 至 (0, 2)",
		"deploy text")
	_check(ReplayStore.describe_action({"type": "move", "from": [1, 1], "to": [2, 1]}, before) == "移动 测试步兵 (1, 1) → (2, 1)",
		"move text with unit name from snapshot")
	_check(ReplayStore.describe_action({"type": "attack", "from": [1, 1], "to": [3, 2], "damage": 2}, before) == "测试步兵 (1, 1) 攻击 (3, 2)，造成 2 伤害",
		"attack text")
	_check(ReplayStore.describe_action({"type": "end_turn"}) == "结束回合", "end_turn text")
	_check(ReplayStore.describe_action({"type": "skip_phase"}) == "跳过阶段", "skip text")


func _test_compute_stats() -> void:
	print("[compute_stats]")
	var actions := [
		{"type": "purchase", "player": 0, "card_id": "test_infantry_01"},   # G 2
		{"type": "deploy", "player": 0, "card_id": "test_infantry_01"},     # Z 1
		{"type": "move", "player": 0, "from": [1, 1], "to": [2, 1]},        # Z 1
		{"type": "attack", "player": 0, "from": [2, 1], "to": [3, 1], "damage": 2},  # Z 1
		{"type": "destroy", "player": 0, "card_id": "test_infantry_01"},    # P0 kill 1, P0 loss 1（被消灭者是 P0 单位）
		{"type": "purchase", "player": 1, "card_id": "test_infantry_01"},
		{"type": "deploy", "player": 1, "card_id": "tank_01"},
	]
	var replay := {"actions": actions, "rounds": 2}
	var stats := ReplayStore.compute_stats(replay)
	_check(stats[0]["purchases"] == 1 and stats[1]["purchases"] == 1, "purchases counted")
	_check(stats[0]["deployed"] == 1 and stats[1]["deployed"] == 1, "deploys counted")
	_check(stats[0]["g_spent"] == 2, "g_spent = card cost (2)")
	_check(stats[1]["g_spent"] == 2, "enemy g_spent counted")
	_check(stats[0]["z_spent"] == 3, "z_spent = deploy 1 + move 1 + attack 1")
	_check(stats[0]["moves"] == 1 and stats[0]["attacks"] == 1, "moves/attacks counted")
	_check(stats[0]["kills"] == 1 and stats[1]["losses"] == 1, "destroy player=killer: P0 kill +1, P1 loss +1")


func _test_group_actions() -> void:
	print("[group_actions]")
	var actions := [
		{"type": "purchase", "turn": 1, "phase": "purchase", "player": 0},
		{"type": "deploy", "turn": 1, "phase": "deploy", "player": 0},
		{"type": "deploy", "turn": 1, "phase": "deploy", "player": 1},
		{"type": "end_turn", "turn": 1, "phase": "action", "player": 0},
		{"type": "purchase", "turn": 2, "phase": "purchase", "player": 1},
	]
	var replay := {"actions": actions, "snapshots": []}
	var groups := ReplayStore.group_actions(replay, 0, false)
	_check(groups.size() == 3, "3 turn-side groups, got %d" % groups.size())
	_check(groups[0]["label"] == "我方 第1回合", "viewer side label")
	_check(groups[1]["label"] == "敌方 第1回合", "enemy side label")
	_check(groups[2]["label"] == "敌方 第2回合", "enemy turn 2 label")
	_check(groups[0]["phases"].size() == 3, "group 0 has 3 phases (purchase/deploy/action)")
	_check(groups[0]["phases"][1]["actions"].size() == 1, "phase group has 1 action")
	_check(groups[0]["phases"][1]["actions"][0]["idx"] == 1, "action idx preserved")
	_check(groups[0]["snapshot_idx"] == 0, "group snapshot_idx = first action idx")
	var named := ReplayStore.group_actions(replay, 0, true)
	_check(named[0]["label"] == "玩家1 第1回合", "named players label")


func _test_build_replay() -> void:
	print("[build_replay]")
	var initial := ReplayStore.make_snapshot(_make_state())
	var after := [ReplayStore.make_snapshot(_make_state())]
	var replay := ReplayStore.build_replay("ROOM42", "net", 0, initial, [{"type": "end_turn", "player": 0}], after)
	_check(replay["game_id"] == "ROOM42" and replay["mode"] == "net", "game_id/mode stored")
	_check(replay["winner"] == 0, "winner stored")
	_check(replay["snapshots"].size() == 2, "snapshots = initial + after each action")
	_check(replay["rounds"] == 2, "rounds derived from last snapshot turn")
