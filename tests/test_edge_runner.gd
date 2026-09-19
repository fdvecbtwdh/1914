extends Node

## 边界与组合规则测试 — 覆盖审计缺口的 18 项高价值场景
## 运行: godot --headless --path . res://tests/test_edge_scene.tscn
## 退出码 = 失败数

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== EDGE TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL EDGE TESTS PASSED")
	else:
		printerr("%d EDGE TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _fresh_state() -> BattleState:
	var st := BattleState.new()
	st.setup(["infantry_01"], ["infantry_01"], "infantry_01", "infantry_01")
	st.turn = 2
	st.phase = "action"
	st.active_player_index = 0
	st.players[0].resources = {"G": 300, "K": 5, "Z": 9}
	st.players[1].resources = {"G": 300, "K": 5, "Z": 9}
	return st


func _place(st: BattleState, owner: int, row: int, col: int, card_id: String) -> BattleState.UnitData:
	var cd: Resource = CardDataLoader.cards.get(card_id)
	var u: BattleState.UnitData = BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner
	u.attack = cd.attack
	u.defense = cd.defense
	u.max_defense = cd.defense
	u.abilities = cd.abilities.duplicate()
	GameLogic._init_unit_from_card(u, cd)
	st.board.set_unit(row, col, u)
	return u


func _wound(u: BattleState.UnitData, amount: int) -> void:
	u.defense = u.max_defense - amount


func _hp(u) -> int:
	return -999 if u == null else u.defense


func _alive(st: BattleState, r: int, c: int) -> bool:
	return st != null and st.board.get_unit(r, c) != null


func _run_all() -> void:
	_test_victory_priority()
	_test_resource_caps()
	_test_exact_resources()
	_test_hand_overflow()
	_test_frontline_deploy_exec()
	_test_frontline_deploy_exec()
	_test_air_double_attack()
	_test_firm_on_counter()
	_test_supply_one_neighbor()
	_test_kill_goes_nowhere()
	_test_stealth_midturn()
	_test_z1_deploy_attack_chain()
	_test_order_card_guard()
	_test_fingerprint_discrimination()


## 胜负边界
func _test_victory_priority() -> void:
	print("[victory priority]")
	# P2（后手）结束回合 = 完整回合边界 → 结算并判胜
	var st := _fresh_state()
	st.active_player_index = 1
	st.front_control = [100, 100, 100, 100, 100]
	var st2 := GameLogic.end_turn(st)
	_check(st2.winner == 0, "V1 P1 win detected at full-round boundary")
	# P1（先手）结束回合 = 半回合 → 不结算不判胜
	st = _fresh_state()
	st.front_control = [100, 100, 100, 100, 100]
	st2 = GameLogic.end_turn(st)
	_check(st2.winner == -1 and st2.active_player_index == 1, "V2 no verdict at half-turn boundary")
	_check(st2.front_control == [100, 100, 100, 100, 100], "V2b front_control untouched at half-turn")
	# 未满 5 线 → 不胜
	st = _fresh_state()
	st.active_player_index = 1
	st.front_control = [100, 100, 100, 100, 99]
	st2 = GameLogic.end_turn(st)
	_check(st2.winner == -1, "V3 line at 99 blocks victory")


## 资源封顶
func _test_resource_caps() -> void:
	print("[resource caps]")
	var st := _fresh_state()
	st.turn = 15
	st.active_player_index = 0
	var st2 := GameLogic.start_turn(st)
	_check(st2.players[0].resources["Z"] == 25, "R1 Z capped at 25 (first hand)")
	_check(st2.players[0].resources["K"] == 10, "R2 K capped at 10")
	st = _fresh_state()
	st.turn = 15
	st.active_player_index = 1
	st2 = GameLogic.start_turn(st)
	_check(st2.players[1].resources["Z"] == 25, "R3 second-hand Z also capped at 25")


## 资源恰好
func _test_exact_resources() -> void:
	print("[exact resources]")
	# G 恰好等于花费 → 购买成功且 G 归 0
	var st := GameLogic.start_turn(_fresh_state())
	st.players[0].resources["G"] = 30
	st.players[0].hand_card_purchase_turn = {}
	var st2 := GameLogic.purchase_card(st, 0, "infantry_01")
	_check(st2 != null and st2.players[0].resources["G"] == 0, "E1 exact-G purchase succeeds, G reaches 0")


## 手牌溢出
func _test_hand_overflow() -> void:
	print("[hand overflow]")
	var st := _fresh_state()
	st.players[0].deck = ["infantry_01", "infantry_01", "infantry_01"]
	st = GameLogic.start_turn(st)
	var p = st.players[0]
	for i in range(7):
		p.hand.append("infantry_01")
	var hand_n: int = p.hand.size()
	var zone_n: int = p.purchase_zone.size()
	var st2 := GameLogic.start_turn(st)
	_check(st2.players[0].hand.size() == hand_n, "E3 hand stays at 7 on draw")
	_check(st2.players[0].purchase_zone.size() == zone_n + 1, "E4 draw goes to purchase zone when hand full")


## 前线真实部署执行
func _test_frontline_deploy_exec() -> void:
	print("[frontline deploy exec]")
	var st := GameLogic.start_turn(_fresh_state())
	_place(st, 0, 1, 0, "infantry_01")   # 占领前线
	st.players[0].hand.append("tank_01")
	st = GameLogic.deploy_unit(st, 0, "tank_01", 1, 2)
	var u := st.board.get_unit(1, 2) if st != null else null
	_check(u != null and u.card_id == "tank_01", "D1 tank deploys to occupied front row")
	_check(st.players[0].resources["Z"] == 1, "D2 front deploy deducts Z (3-2)")
	# 部署到敌方行 → null
	var st3 := GameLogic.deploy_unit(st, 0, "tank_01", 3, 0) if st != null else null
	_check(st3 == null, "D3 deploy into enemy rows rejected")
	# 同一张手牌重复部署 → null（手牌已移除）
	var st4 := GameLogic.deploy_unit(st, 0, "tank_01", 1, 3) if st != null else null
	_check(st4 == null, "D4 redeploying consumed card rejected")


## 空军攻击后再攻击
func _test_air_double_attack() -> void:
	print("[air double attack]")
	var st := _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")    # 攻4
	var tgt := _place(st, 1, 4, 0, "infantry_01")
	tgt.max_defense = 30
	tgt.defense = 30
	var st2 := GameLogic.attack_unit(st, 0, 0, 0, 4, 0)
	var hp_after := _hp(st2.board.get_unit(4, 0))
	var st3 := GameLogic.attack_unit(st2, 0, 0, 0, 4, 0)
	_check(st3 == null or _hp(st3.board.get_unit(4, 0)) == hp_after, "A-EXP air cannot attack twice")


## 坚守降低所受反击
func _test_firm_on_counter() -> void:
	print("[firm on counter]")
	var st := _fresh_state()
	var tank := _place(st, 0, 1, 0, "tank_01")     # 坚守1 攻4
	var foe := _place(st, 1, 2, 0, "infantry_01")  # 攻3 防4
	foe.max_defense = 30
	foe.defense = 30
	var st2 := GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(1, 0)) == 2, "F1 firm reduces counter 3->2 (tank 4-2)")
	_check(_hp(st2.board.get_unit(2, 0)) == 26, "F2 foe took full 4 damage (30->26)")


## 补给只治一个邻居 + 不越上限
func _test_supply_one_neighbor() -> void:
	print("[supply]")
	var st := GameLogic.start_turn(_fresh_state())
	var sup := _place(st, 0, 0, 0, "tank_02")   # 补给1
	var w1 := _place(st, 0, 1, 0, "infantry_01")
	var w2 := _place(st, 0, 1, 1, "infantry_01")
	_wound(w1, 2)
	_wound(w2, 2)
	var wounded_w1 := _hp(w1) < w1.max_defense
	var wounded_w2 := _hp(w2) < w2.max_defense
	# start_turn 在 _fresh 之后手动触发
	var st2 := GameLogic.start_turn(st)
	var a := _hp(st2.board.get_unit(1, 0))
	var b := _hp(st2.board.get_unit(1, 1))
	var exactly_one: bool = (a == w1.max_defense - 1 and b == w2.max_defense - 2) \
		or (a == w1.max_defense - 2 and b == w2.max_defense - 1)
	_check(exactly_one, "S1 exactly one wounded neighbor healed per supply unit")
	_check(wounded_w1 and wounded_w2, "S2 (baseline) both wounded before heal")


## 击杀单位去向：不进任何区（v1 设计：彻底移除）
func _test_kill_goes_nowhere() -> void:
	print("[kill goes nowhere]")
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	var victim := _place(st, 1, 2, 0, "infantry_01")
	_wound(victim, 2)
	var st2 := GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(not _alive(st2, 2, 0), "K1 dead unit removed from board")
	var found := false
	for pi in range(2):
		for zone in [st2.players[pi].discard, st2.players[pi].hand, st2.players[pi].purchase_zone]:
			if zone.has("infantry_01") and pi == 1:
				found = true
	_check(not found, "K2 dead unit not moved to any zone (v1: removed)")


## 潜行揭示时机：回合中途移入视野不即时揭示
func _test_stealth_midturn() -> void:
	print("[stealth midturn]")
	var st := _fresh_state()
	_place(st, 0, 1, 0, "fighter_01")                       # P1 攻击方
	var stealth := _place(st, 1, 4, 0, "fighter_02")        # P2 潜行
	stealth.revealed = false
	# P1 行动阶段把步兵移到潜行单位旁（直接放置模拟移动后的位置）
	_place(st, 0, 4, 1, "infantry_01")                      # 与潜行单位十字相邻
	var st2 := GameLogic.attack_unit(st, 0, 4, 1, 4, 0)
	_check(st2 == null and stealth.revealed == false, "M1 mid-turn vision does not instantly reveal")
	# 下一次开始回合后揭示
	var st3 := GameLogic.start_turn(st2 if st2 != null else st)
	_check(st3.board.get_unit(4, 0).revealed, "M2 reveal happens at next start_turn")


## Z=1：部署成功后攻击被拒
func _test_z1_deploy_attack_chain() -> void:
	print("[Z=1 chain]")
	var st := GameLogic.start_turn(_fresh_state())
	st.players[0].hand.append("infantry_01")
	st.players[0].resources["Z"] = 1
	st = GameLogic.deploy_unit(st, 0, "infantry_01", 0, 0)
	_check(st != null and _alive(st, 0, 0), "Z1 deploy succeeds with Z=1")
	st.players[0].resources["Z"] = 0
	_place(st, 1, 1, 0, "infantry_01")
	var st3 := GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(st3 == null, "Z2 attack with zero Z rejected")


## order 卡守卫
func _test_order_card_guard() -> void:
	print("[order card guard]")
	var st := GameLogic.start_turn(_fresh_state())
	st.players[0].hand.append("__fake_order__")
	var fake: Resource = CardDataLoader.cards.get("infantry_01").duplicate()
	fake.type = "order"
	fake.id = "__fake_order__"
	CardDataLoader.cards["__fake_order__"] = fake
	st.players[0].hand.append("__fake_order__")
	var st2 := GameLogic.deploy_unit(st, 0, "__fake_order__", 0, 0)
	_check(st2 == null, "O1 order card cannot be deployed")
	var st3 := GameLogic.purchase_card(st, 0, "__fake_order__")
	_check(st3 == null, "O2 order card cannot be purchased")
	CardDataLoader.cards.erase("__fake_order__")


## 指纹区分度：关键字段不同 → 指纹必须不同
func _test_fingerprint_discrimination() -> void:
	print("[fingerprint discrimination]")
	var a := _fresh_state()
	var b := _fresh_state()
	_place(a, 0, 1, 0, "fighter_02")
	_place(b, 0, 1, 0, "fighter_02")
	var fa0 := GameLogic.state_fingerprint(a)
	var fb0 := GameLogic.state_fingerprint(b)
	_check(fa0 == fb0, "FP0 identical states -> identical fingerprints")
	# revealed 不同
	b.board.get_unit(1, 0).revealed = true
	_check(GameLogic.state_fingerprint(a) != GameLogic.state_fingerprint(b), "FP1 revealed difference changes fingerprint")
	b.board.get_unit(1, 0).revealed = false
	# attack_count 不同
	b.board.get_unit(1, 0).attack_count = 1
	_check(GameLogic.state_fingerprint(a) != GameLogic.state_fingerprint(b), "FP2 attack_count difference changes fingerprint")
	# 守护状态不同
	var c := _fresh_state()
	var d := _fresh_state()
	_place(c, 0, 1, 0, "infantry_01")
	_place(d, 0, 1, 0, "infantry_01")
	c.board.get_unit(1, 0).is_guarded = true
	_check(GameLogic.state_fingerprint(c) != GameLogic.state_fingerprint(d), "FP3 guard flag difference changes fingerprint")
