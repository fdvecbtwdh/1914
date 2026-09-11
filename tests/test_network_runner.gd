extends Node

## 阶段4 联网测试（单进程无头）— 确定性回放
## 运行: godot --headless --path . res://tests/test_network_scene.tscn
## 退出码 = 失败数
##
## 同步模型的根基：同一种子 + 同一指令序列 → 两端 BattleState 完全一致（状态指纹相等）
## 传输层（握手/开局包/指令/指纹）由双进程测试覆盖：
##   godot --headless --path . -- --net=host --auto
##   godot --headless --path . -- --net=join:127.0.0.1 --auto

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== NETWORK TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL NETWORK TESTS PASSED")
	else:
		printerr("%d NETWORK TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _make_deck() -> Array[String]:
	var deck: Array[String] = []
	for i in range(9):
		deck.append("test_infantry_01")
	return deck


func _run_all() -> void:
	print("[determinism replay]")
	var deck := _make_deck()

	seed(20260912)
	var tm1 := TurnManager.new()
	tm1.start_game(deck.duplicate(), deck.duplicate(), "test_infantry_01", "test_infantry_01")
	seed(20260912)
	var tm2 := TurnManager.new()
	tm2.start_game(deck.duplicate(), deck.duplicate(), "test_infantry_01", "test_infantry_01")

	var fp1 := GameLogic.state_fingerprint(tm1.battle_state)
	var fp2 := GameLogic.state_fingerprint(tm2.battle_state)
	_check(fp1 == fp2, "same seed init → same fingerprint")
	_check(tm1.battle_state.players[0].hand == tm2.battle_state.players[0].hand, "same seed init → same hands")

	# 回放同一指令序列：P1 买卡过完回合1；P2 部署；P1 回合2 部署+移动
	var script := [
		{"type": "purchase", "card_id": "test_infantry_01"},
		{"type": "skip_phase"},
		{"type": "skip_phase"},
		{"type": "end_turn"},
		{"type": "purchase", "card_id": "test_infantry_01"},
		{"type": "skip_phase"},
		{"type": "deploy", "card_id": "test_infantry_01", "row": 4, "col": 0},
		{"type": "skip_phase"},
		{"type": "end_turn"},
		{"type": "skip_phase"},
		{"type": "deploy", "card_id": "test_infantry_01", "row": 0, "col": 1},
		{"type": "skip_phase"},
		{"type": "move", "from_row": 0, "from_col": 1, "to_row": 1, "to_col": 0},
	]

	var mismatch_at := -1
	for i in range(script.size()):
		tm1.submit_action(script[i])
		tm2.submit_action(script[i])
		if GameLogic.state_fingerprint(tm1.battle_state) != GameLogic.state_fingerprint(tm2.battle_state):
			mismatch_at = i
			break
	_check(mismatch_at == -1, "replay %d actions → fingerprints identical (mismatch_at=%d)" % [script.size(), mismatch_at])
	_check(tm1.battle_state.players[0].resources == tm2.battle_state.players[0].resources, "resources identical after replay")
	tm1.free()
	tm2.free()
