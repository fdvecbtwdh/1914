extends Node

## 临时验证脚本 — GameLogic 纯函数引擎
## 通过场景运行（autoload 先注册，GameLogic 内 CardDataLoader 引用才能解析）：
##   godot --headless --path . tests/test_game_logic_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL TESTS PASSED")
	else:
		printerr("%d TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _run_all() -> void:
	_test_init_game()
	_test_draw_card()
	_test_start_turn()
	_test_purchase_card()
	_test_deploy_unit()
	_test_move_unit()
	_test_attack_unit()
	_test_counter_attack()
	_test_artillery_no_counter()
	_test_end_turn()
	_test_check_victory()


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


## 构造一个可预测的初始 state：全用 test_infantry_01，starter 相同
func _make_init_state() -> BattleState:
	var deck: Array[String] = []
	for i in range(9):
		deck.append("test_infantry_01")
	return GameLogic.init_game(deck, deck.duplicate(), "test_infantry_01", "test_infantry_01")


## 直接往棋盘放一个指定攻击/防御的单元（绕过部署规则，用于战斗测试）
func _place_unit(state: BattleState, owner: int, row: int, col: int, atk: int, def: int, card_id: String = "test_infantry_01") -> void:
	var u: BattleState.UnitData = BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner
	u.attack = atk
	u.defense = def
	u.max_defense = def
	u.has_acted = false
	u.deployed_this_turn = false
	state.board.set_unit(row, col, u)


func _test_init_game() -> void:
	print("[init_game]")
	var st := _make_init_state()
	_check(st.players.size() == 2, "two players")
	_check(st.players[0].deck.size() == 6, "P1 deck has 6 after drawing 3")
	_check(st.players[1].deck.size() == 6, "P2 deck has 6 after drawing 3")
	_check(st.players[0].purchase_zone.size() == 4, "P1 purchase_zone has 4 (3 drawn + starter)")
	_check(st.players[1].purchase_zone.size() == 4, "P2 purchase_zone has 4 (3 drawn + starter)")
	_check(st.phase == "draw", "initial phase is draw")
	_check(st.turn == 1 and st.active_player_index == 0, "P1 starts turn 1")
	_check(st.winner == -1, "no winner yet")


func _test_draw_card() -> void:
	print("[draw_card]")
	var st := _make_init_state()
	var before := st.players[0].purchase_zone.size()
	var st2 := GameLogic.draw_card(st, 0)
	_check(st2.players[0].purchase_zone.size() == before + 1, "purchase_zone grows by 1")
	_check(st2.players[0].deck.size() == st.players[0].deck.size() - 1, "deck shrinks by 1")
	# 原 state 不可变
	_check(st.players[0].purchase_zone.size() == before, "original state unchanged")


func _test_start_turn() -> void:
	print("[start_turn]")
	var st := _make_init_state()
	var st2 := GameLogic.start_turn(st)
	var p := st2.players[0]
	_check(p.resources["G"] == 150, "G = 150 at turn start")
	_check(p.resources["K"] == 1, "K = turn number")
	_check(p.resources["Z"] == 1, "Z = turn number")
	_check(st2.phase == "purchase", "phase becomes purchase")
	_check(st2.players[0].purchase_zone.size() == st.players[0].purchase_zone.size() + 1, "draw 1 at start_turn")


func _test_purchase_card() -> void:
	print("[purchase_card]")
	var st := GameLogic.start_turn(_make_init_state())
	var pid := "test_infantry_01"
	_check(st.players[0].purchase_zone.has(pid), "card present in purchase_zone")
	# 成功购买
	var st2 := GameLogic.purchase_card(st, 0, pid)
	_check(st2.players[0].hand.has(pid), "card moved to hand")
	_check(st2.players[0].purchase_zone.size() == st.players[0].purchase_zone.size() - 1, "card removed from purchase_zone (count -1)")
	_check(st2.players[0].resources["G"] == 148, "G deducted by cost_g(2)")
	# 原 state 不可变
	_check(not st.players[0].hand.has(pid), "original state unchanged")
	# 买不起：G 设 0
	var st3 := GameLogic.start_turn(_make_init_state())
	st3.players[0].resources["G"] = 0
	var st3b := GameLogic.purchase_card(st3, 0, pid)
	_check(st3b == null, "cannot purchase with no G (returns null)")
	# 购买区没有的卡
	var st4 := GameLogic.purchase_card(st, 0, "not_exist")
	_check(st4 == null, "cannot purchase card not in zone (returns null)")


func _test_deploy_unit() -> void:
	print("[deploy_unit]")
	var st := GameLogic.start_turn(_make_init_state())
	var pid := "test_infantry_01"
	st = GameLogic.purchase_card(st, 0, pid)
	# 合法部署：P1 行 0
	var st2 := GameLogic.deploy_unit(st, 0, pid, 0, 0)
	var unit := st2.board.get_unit(0, 0)
	_check(unit != null, "unit placed at (0,0)")
	if unit != null:
		_check(unit.card_id == pid and unit.owner_index == 0, "unit card_id/owner correct")
		_check(unit.attack == 2 and unit.defense == 3 and unit.max_defense == 3, "unit stats copied from CardData")
		_check(unit.deployed_this_turn, "deployed_this_turn set")
	_check(st2.players[0].resources["Z"] == 0, "Z deducted by cost_k(1)")
	_check(not st2.players[0].hand.has(pid), "card removed from hand")
	_check(st2.action_log.size() > st.action_log.size(), "deploy logged")
	# 非法部署：P1 行 2 不允许
	var st3 := GameLogic.deploy_unit(st, 0, pid, 2, 0)
	_check(st3 == null, "P1 cannot deploy at row 2 (returns null)")
	_check(st.players[0].resources["Z"] == 1, "no Z spent on illegal deploy")
	# 越界列保护
	var st4 := GameLogic.deploy_unit(st, 0, pid, 0, 99)
	_check(st4 == null, "out-of-bounds col deploy rejected (returns null)")
	_check(st.players[0].hand.has(pid), "hand preserved on out-of-bounds deploy")


func _test_move_unit() -> void:
	print("[move_unit]")
	var st := GameLogic.start_turn(_make_init_state())
	var pid := "test_infantry_01"
	st = GameLogic.purchase_card(st, 0, pid)
	st = GameLogic.deploy_unit(st, 0, pid, 0, 0)
	# 前进一格
	var st2 := GameLogic.move_unit(st, 0, 0, 0, 1, 0)
	var u := st2.board.get_unit(1, 0)
	_check(u != null and st2.board.get_unit(0, 0) == null, "unit moved to (1,0)")
	_check(u != null and u.has_acted, "unit marked has_acted")
	_check(st2.players[0].resources["K"] == 0, "K deducted by 1")
	# 后退一格（P1 禁止 to_row < from_row）
	var st3 := GameLogic.move_unit(st, 0, 0, 0, -1, 0)
	_check(st3 == null, "P1 cannot move backward (returns null)")
	# 越界保护
	var st4 := GameLogic.move_unit(st, 0, 0, 0, 99, 0)
	_check(st4 == null, "out-of-bounds move rejected (returns null)")
	_check(st.players[0].resources["K"] == 1, "no K spent on out-of-bounds move")
	# 已有行动单位不可再动
	var st5 := GameLogic.move_unit(GameLogic.move_unit(st, 0, 0, 0, 1, 0), 0, 1, 0, 2, 0)
	_check(st5 == null, "acted unit cannot move again (returns null)")


func _test_attack_unit() -> void:
	print("[attack_unit]")
	var st := _make_init_state()
	st.players[0].resources["K"] = 5
	_place_unit(st, 0, 0, 0, 3, 4)   # P1 步兵 (攻3防4)
	_place_unit(st, 1, 1, 0, 3, 4)   # P2 步兵 (攻3防4)，相邻
	var st2 := GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	var atk := st2.board.get_unit(0, 0)
	var def := st2.board.get_unit(1, 0)
	_check(def != null and def.defense == 1, "defender took 3 damage (4->1)")
	_check(atk != null and atk.defense == 1, "attacker counter-attacked (4->1)")
	_check(st2.players[0].resources["K"] == 4, "K deducted by 1")
	_check(st2.action_log.size() > st.action_log.size(), "attack logged")
	# 不能攻击友方
	var st3 := GameLogic.attack_unit(st, 0, 0, 0, 0, 0)
	_check(st3 == null, "cannot attack friendly (self) (returns null)")
	# 超出射程
	_place_unit(st, 1, 3, 0, 3, 4)
	var st4 := GameLogic.attack_unit(st, 0, 0, 0, 3, 0)
	_check(st4 == null, "out of range attack rejected (returns null)")


func _test_counter_attack() -> void:
	print("[counter_attack kill]")
	var st := _make_init_state()
	st.players[0].resources["K"] = 5
	_place_unit(st, 0, 0, 0, 1, 1)   # 脆皮攻击者
	_place_unit(st, 1, 1, 0, 5, 10)  # 高攻高防防守者
	var st2 := GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(st2.board.get_unit(0, 0) == null, "attacker destroyed by counter-attack")
	_check(st2.board.get_unit(1, 0) != null, "defender survives")


func _test_artillery_no_counter() -> void:
	print("[artillery no counter]")
	# 场景1：防守方存活，火炮免疫反击
	var st := _make_init_state()
	st.players[0].resources["K"] = 5
	_place_unit(st, 0, 0, 0, 5, 2, "artillery_01")  # 火炮 突击 全局射程
	_place_unit(st, 1, 1, 0, 9, 8, "infantry_01")   # 高防步兵，抗住第一击
	var st2 := GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	var art := st2.board.get_unit(0, 0)
	_check(art != null and art.defense == 2, "artillery takes no counter damage (surviving defender)")
	_check(st2.board.get_unit(1, 0) != null, "defender survives on 3 def")
	# 场景2：火炮击杀低防步兵
	var stb := _make_init_state()
	stb.players[0].resources["K"] = 5
	_place_unit(stb, 0, 2, 0, 5, 2, "artillery_01")
	_place_unit(stb, 1, 3, 0, 9, 3, "infantry_01")  # 全局射程可隔行打击
	var st2b := GameLogic.attack_unit(stb, 0, 2, 0, 3, 0)
	_check(st2b.board.get_unit(3, 0) == null, "artillery destroys infantry (5 atk vs 3 def)")
	_check(st2b.board.get_unit(2, 0) != null, "artillery survives")


func _test_end_turn() -> void:
	print("[end_turn]")
	var st := _make_init_state()
	GameLogic.start_turn(st)
	st.players[0].resources["K"] = 3
	st.players[0].resources["Z"] = 3
	var st2 := GameLogic.end_turn(st)
	_check(st2.players[0].resources["K"] == 0 and st2.players[0].resources["Z"] == 0, "K/Z cleared on end_turn")
	_check(st2.active_player_index == 1, "active player switches to P2")
	_check(st2.turn == 1, "turn stays 1 for P2")
	_check(st2.phase == "draw", "phase back to draw")
	# 一轮完整结束：P2 end → turn 2, P1 再动
	var st3 := GameLogic.end_turn(st2)
	_check(st3.active_player_index == 0 and st3.turn == 2, "turn 2 starts after both players act")


func _test_check_victory() -> void:
	print("[check_victory]")
	var st := _make_init_state()
	_check(GameLogic.check_victory(st) == -1, "no victory on empty board")
	# P1 占满 P2 区域（行3-4）每列
	var st_p1 := _make_init_state()
	for c in range(5):
		_place_unit(st_p1, 0, 3, c, 2, 3)
	_check(GameLogic.check_victory(st_p1) == 0, "P1 wins by occupying all cols of rows 3-4")
	# P2 占满 P1 区域（行0-1）每列
	var st_p2 := _make_init_state()
	for c in range(5):
		_place_unit(st_p2, 1, 0, c, 2, 3)
	_check(GameLogic.check_victory(st_p2) == 1, "P2 wins by occupying all cols of rows 0-1")
	# 部分占领不算赢
	var st_part := _make_init_state()
	for c in range(4):
		_place_unit(st_part, 0, 3, c, 2, 3)
	_check(GameLogic.check_victory(st_part) == -1, "partial occupation is not a win")
