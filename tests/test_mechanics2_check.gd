extends Node

## 机制审查回归 — 陆空图层/稀有度购买/部署限制/后退/工事/巡逻空战（3A 边界 A-H）
## Run: godot --headless --path . res://tests/test_mechanics2_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== MECHANICS2 TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL MECHANICS2 TESTS PASSED")
	else:
		printerr("%d MECHANICS2 TEST(S) FAILED" % _failures)
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
	st.phase = "action"
	st.active_player_index = 0
	st.players[0].resources = {"G": 300, "K": 5, "Z": 9}
	st.players[1].resources = {"G": 300, "K": 5, "Z": 9}
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
	var layer := "air" if air else "ground"
	st.board.set_unit(row, col, u, layer)
	return u


## 便捷：造一架防守方巡逻战斗机
func _place_patrol(st: BattleState, owner: int, row: int, col: int, attack: int = 4, defense: int = 2) -> BattleState.UnitData:
	var f := _place(st, owner, row, col, "fighter_01", true)
	f.attack = attack
	f.defense = defense
	f.max_defense = defense
	f.patrolling = true
	return f


# ═══ 1. 陆空图层 ═══

func _test_layers() -> void:
	print("[layers]")
	var st := _fresh_state()
	# L1 陆军占格不阻止空军进驻同格空域（行1=前线：地面单位使其可部署）
	_place(st, 0, 1, 2, "infantry_01")
	st.players[0].hand.append("fighter_01")
	var st2 := GameLogic.deploy_unit(st, 0, "fighter_01", 1, 2)
	_check(st2 != null, "L1 air deploy on ground-occupied cell ok")
	# L2 空军移动无视地面单位阻挡
	st = _fresh_state()
	_place(st, 0, 2, 2, "fighter_01", true)
	_place(st, 1, 2, 1, "infantry_01")  # 地面层阻挡物（目标格空域无单位）
	st2 = GameLogic.move_unit(st, 0, 2, 2, 2, 1)
	_check(st2 != null, "L2 air move ignores ground occupant")
	# L3 陆军移动不检查空域层
	st = _fresh_state()
	_place(st, 0, 2, 2, "fighter_01", true)
	st2 = GameLogic.move_unit(st, 0, 2, 2, 2, 1)
	_check(st2 != null, "L3 ground move ignores air occupant")
	# L4 陆军不能攻击空域层单位（目标查找只到地面层）
	st = _fresh_state()
	_place(st, 0, 2, 2, "infantry_01")
	_place(st, 1, 2, 1, "fighter_01", true)
	st2 = GameLogic.attack_unit(st, 0, 2, 2, 2, 1)
	_check(st2 == null, "L4 ground attacker cannot target air-layer unit")


# ═══ 2. 稀有度购买上限 ═══

func _test_purchase_limits() -> void:
	print("[purchase limits]")
	var st := BattleState.new()
	var deck: Array[String] = []
	for i in range(6):
		deck.append("tank_02")     # silver
		deck.append("bomber_02")   # gold
		deck.append("infantry_01") # common
	st.setup(deck, ["infantry_01"], "infantry_01", "infantry_01")
	st.players[0].purchase_zone.clear()
	st.players[0].purchase_zone = ["tank_02", "tank_02", "tank_02", "tank_02", "bomber_02", "bomber_02", "bomber_02", "infantry_01", "infantry_01", "infantry_01", "infantry_01", "infantry_01"]
	st.players[0].resources = {"G": 5000, "Z": 25, "K": 9}
	# P1 silver 上限 3
	var s1 := GameLogic.purchase_card(st, 0, "tank_02")
	var s2 := GameLogic.purchase_card(s1, 0, "tank_02")
	var s3 := GameLogic.purchase_card(s2, 0, "tank_02")
	var s4 := GameLogic.purchase_card(s3, 0, "tank_02")
	_check(s1 != null and s2 != null and s3 != null, "silver purchases 1-3 ok")
	_check(s4 == null, "P1 4th silver purchase blocked (limit 3)")
	# P2 gold 上限 2
	var g1 := GameLogic.purchase_card(st, 0, "bomber_02")
	var g2 := GameLogic.purchase_card(g1, 0, "bomber_02")
	var g3 := GameLogic.purchase_card(g2, 0, "bomber_02")
	_check(g1 != null and g2 != null, "gold purchases 1-2 ok")
	_check(g3 == null, "P2 3rd gold purchase blocked (limit 2)")
	# P3 common 不限（5 连买）
	var c := st
	var ok_count := 0
	for i in range(5):
		c = GameLogic.purchase_card(c, 0, "infantry_01")
		if c != null:
			ok_count += 1
	_check(ok_count == 5, "P3 common unlimited (5 bought)")


# ═══ 3. 部署回合限制 / 突击 / 部署当回合攻击 ═══

func _test_deploy_turn_rules() -> void:
	print("[deploy turn rules]")
	var st := _fresh_state()
	st.phase = "deploy"
	st.players[0].hand.append("infantry_01")
	st.players[0].resources["Z"] = 9
	var st2 := GameLogic.deploy_unit(st, 0, "infantry_01", 0, 0)
	_check(st2 != null, "deploy ok")
	# M1 部署当回合不能移动
	var st3 := GameLogic.move_unit(st2, 0, 0, 0, 1, 0)
	_check(st3 == null, "M1 newly deployed unit cannot move")
	# M2 突击单位部署当回合可移动
	st = _fresh_state()
	st.phase = "deploy"
	st.players[0].hand.append("tank_03")  # 坦克（突击）
	var st4 := GameLogic.deploy_unit(st, 0, "tank_03", 0, 0)
	_check(st4 != null, "assault deploy ok")
	var st5 := GameLogic.move_unit(st4, 0, 0, 0, 1, 0)
	_check(st5 != null, "M2 assault unit can move on deploy turn")
	# M3 部署当回合可以攻击（轰炸机部署后直接攻击陆军）
	st = _fresh_state()
	st.phase = "deploy"
	st.players[0].hand.append("bomber_01")
	var st6 := GameLogic.deploy_unit(st, 0, "bomber_01", 0, 2, )
	_check(st6 != null, "bomber deploy ok")
	_place(st6, 1, 2, 2, "infantry_01")
	var st7: BattleState = st6.duplicate(true)
	st7.phase = "action"
	var st8 := GameLogic.attack_unit(st7, 0, 0, 2, 2, 2)
	_check(st8 != null, "M3/B1 bomber can attack immediately after deploy")


# ═══ 4. 后退 ═══

func _test_retreat() -> void:
	print("[retreat]")
	var st := _fresh_state()
	_place(st, 0, 2, 2, "infantry_01")
	# R1 直退成功，消耗全部行动
	var st2 := GameLogic.move_unit(st, 0, 2, 2, 1, 2)
	_check(st2 != null, "R1 straight retreat ok")
	var u: BattleState.UnitData = st2.board.get_unit(1, 2)
	_check(u != null and u.retreated and u.has_acted, "R1b retreated flag set, action consumed")
	# R2 后退后不能攻击
	_place(st2, 1, 2, 1, "infantry_01")
	var st3 := GameLogic.attack_unit(st2, 0, 1, 2, 2, 1)
	_check(st3 == null, "R2 cannot attack after retreat")
	# R3 斜向后禁止
	st = _fresh_state()
	_place(st, 0, 2, 2, "infantry_01")
	var st4 := GameLogic.move_unit(st, 0, 2, 2, 1, 1)
	_check(st4 == null, "R3 diagonal retreat blocked")
	# R4 自己后排行不能再退
	st = _fresh_state()
	_place(st, 0, 0, 2, "infantry_01")
	var st5 := GameLogic.move_unit(st, 0, 0, 2, -1, 2)
	_check(st5 == null, "R4 retreat off-board blocked")


# ═══ 5. 工事 ═══

func _test_fort() -> void:
	print("[fort]")
	var st := _fresh_state()
	st.front_control = [100, 100, 0, 0, 0]
	_place(st, 0, 0, 0, "infantry_01")
	# F1 占领度不足 → null
	var st2 := GameLogic.build_fort(st, 0, 0, 0, 2, 1)
	_check(st2 == null, "F1 cannot build on non-100% line")
	# F2 100% 战线修筑成功
	var st3 := GameLogic.build_fort(st, 0, 0, 0, 0, 1)
	_check(st3 != null, "F2 build on 100% line ok")
	var fort: BattleState.UnitData = st3.board.get_unit(0, 1)
	_check(fort != null and fort.defense == 2, "F2b fort placed with defense 2")
	var builder: BattleState.UnitData = st3.board.get_unit(0, 0)
	_check(builder != null and builder.retreated, "F2c builder action consumed")
	# F3 每阵线限 1
	var st4 := GameLogic.build_fort(st3, 0, 0, 0, 0, 2)
	_check(st4 == null, "F3 second fort on same line blocked")
	# F5 工事坚守：同战线友军被打减伤 1（defense 2 → firm 1）
	st = _fresh_state()
	st.front_control = [100, 0, 0, 0, 0]
	st.board.set_unit(0, 0, _make_unit("fort_01", 0, 0, 2), "ground")
	var victim_pre := _place(st, 0, 0, 1, "infantry_01")  # 防 5
	victim_pre.defense = 5
	victim_pre.max_defense = 5
	_place(st, 1, 0, 2, "infantry_01")  # 攻 4
	var st5 := GameLogic.attack_unit(st, 1, 0, 2, 0, 1)
	_check(st5 != null, "F5 attack on fortified line resolves")
	if st5 != null:
		var victim: BattleState.UnitData = st5.board.get_unit(0, 1)
		# 坚守 1（工事防2 ÷ 2）：4 伤 - 1 = 3 → 残 2；无工事则残 1
		_check(victim != null and victim.defense == 2, "F5b fort firm reduces damage (5-3=2)")
	# F6 工事不能发起攻击
	st = _fresh_state()
	var fort_u := _make_unit("fort_01", 0, 0, 2)
	st.board.set_unit(0, 0, fort_u, "ground")
	_place(st, 1, 0, 1, "infantry_01")
	var st6 := GameLogic.attack_unit(st, 0, 0, 0, 0, 1)
	_check(st6 == null, "F6 fort cannot attack")


func _make_unit(card_id: String, owner: int, attack: int, defense: int) -> BattleState.UnitData:
	var u := BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner
	u.attack = attack
	u.defense = defense
	u.max_defense = defense
	return u


# ═══ 6. 空战与巡逻（3A 边界 A-H）═══

func _test_air_combat() -> void:
	print("[air combat]")
	# T1（测试 A）：敌巡逻拦截 → 敌灭 → 继续对地
	var st := _fresh_state()
	var my_f := _place(st, 0, 2, 2, "fighter_01", true)
	my_f.attack = 6
	my_f.defense = 9
	var my_tank := _place(st, 0, 2, 1, "tank_01")
	_place_patrol(st, 1, 2, 0, 2, 2)  # 敌巡逻机（攻2防2）
	var ground := _place(st, 1, 2, 3, "infantry_01")
	var st2 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st2 != null, "T1 attack resolves through air combat")
	if st2 != null:
		var g: BattleState.UnitData = st2.board.get_unit(2, 3)
		_check(g == null or g.defense < ground.defense, "T1b ground target damaged after air combat win")
		var patrol_gone := true
		for c in range(st2.board.cols):
			var p: BattleState.UnitData = st2.board.get_unit(2, c, "air")
			if p != null and p.owner_index == 1:
				patrol_gone = false
		_check(patrol_gone, "T1c enemy patrol destroyed")

	# T2（测试 B）：友方攻击者在空战中被击毁 → 攻击作废（陆军无损）
	st = _fresh_state()
	var weak := _place(st, 0, 2, 2, "fighter_01", true)
	weak.attack = 1
	weak.defense = 1
	var ground2 := _place(st, 1, 2, 3, "tank_01")
	ground2.defense = 9
	_place_patrol(st, 1, 2, 0, 6, 9)
	var st3 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st3 != null, "T2 attack attempt resolves (intercept kills attacker)")
	if st3 != null:
		var g2: BattleState.UnitData = st3.board.get_unit(2, 3)
		_check(g2 != null and g2.defense == 9, "T2b attack voided: ground target undamaged")
		var attacker_alive := st3.board.get_unit(2, 2, "air") != null
		_check(not attacker_alive, "T2c attacker shot down by patrol")

	# T3（测试 C）：无敌方巡逻 → 不触发空战，直接结算
	st = _fresh_state()
	var f3 := _place(st, 0, 2, 2, "fighter_01", true)
	var enemy_g := _place(st, 1, 2, 3, "infantry_01")
	enemy_g.defense = 2
	var st4 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st4 != null, "T3 attack without patrol resolves")
	var had_air_combat := false
	if st4 != null:
		for a in st4.action_log:
			if a.get("type", "") == "air_combat":
				had_air_combat = true
	_check(not had_air_combat, "T3b no air combat phase without patrol (unified settlement)")

	# T4（测试 D）：多战线独立判断
	st = _fresh_state()
	var f4 := _place(st, 0, 2, 2, "fighter_01", true)
	f4.attack = 6
	f4.defense = 9
	f4.move_count = 0
	_place_patrol(st, 1, 1, 0, 2, 2)   # 战线1有巡逻
	_place(st, 1, 4, 3, "infantry_01")  # 战线4无巡逻目标
	# 打战线4（无巡逻）→ 不空战
	var st5 := GameLogic.attack_unit(st, 0, 2, 2, 4, 3)
	var combat_on_4 := false
	if st5 != null:
		for a in st5.action_log:
			if a.get("type", "") == "air_combat" and int(a.get("row", -1)) == 4:
				combat_on_4 = true
	_check(st5 != null and not combat_on_4, "T4 line without patrol has no air combat")

	# T5（测试 E）：多架巡逻机只产生一次空战阶段
	st = _fresh_state()
	var f5 := _place(st, 0, 2, 2, "fighter_01", true)
	f5.attack = 6
	f5.defense = 9
	_place_patrol(st, 1, 2, 0, 1, 1)
	_place_patrol(st, 1, 2, 4, 1, 1)
	_place(st, 1, 2, 3, "infantry_01")
	var st6 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st6 != null, "T5 multi-patrol combat resolves")
	var combat_count := 0
	if st6 != null:
		for a in st6.action_log:
			if a.get("type", "") == "air_combat":
				combat_count += 1
	_check(combat_count == 1, "T5b exactly one air combat phase on the line")

	# T7（测试 G）：友方战斗机全灭后，轰炸机不能获得对地资格（仍被巡逻拦截）
	st = _fresh_state()
	var bomber := _place(st, 0, 2, 2, "bomber_01", true)
	bomber.attack = 6
	bomber.defense = 1
	_place_patrol(st, 1, 2, 0, 8, 9)  # 强巡逻
	var ground3 := _place(st, 1, 2, 3, "infantry_01")
	ground3.defense = 5
	var st7 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st7 != null, "T7 bomber attack attempt resolves")
	if st7 != null:
		var bomber_alive := st7.board.get_unit(2, 2, "air") != null
		var g3: BattleState.UnitData = st7.board.get_unit(2, 3)
		_check(not bomber_alive, "T7b bomber intercepted and destroyed")
		_check(g3 != null and g3.defense == 5, "T7c ground target untouched (no air-to-ground grant)")

	# T8（测试 H）：空战胜后对地攻击不再触发第二次空战
	st = _fresh_state()
	var f8 := _place(st, 0, 2, 2, "fighter_01", true)
	f8.attack = 8
	f8.defense = 9
	_place_patrol(st, 1, 2, 0, 1, 1)
	_place(st, 1, 2, 3, "infantry_01")
	var st8 := GameLogic.attack_unit(st, 0, 2, 2, 2, 3)
	_check(st8 != null, "T8 win-combat attack resolves")
	if st8 != null:
		var st9 := GameLogic.attack_unit(st8, 0, 2, 2, 2, 3)
		_check(st9 == null, "T8b attacker has_attacked prevents repeat attack")


# ═══ 7. 巡逻确认与未受进攻自动反击 ═══

func _test_patrol_confirmation() -> void:
	print("[patrol confirmation]")
	var st := _fresh_state()
	st.active_player_index = 0
	_place(st, 0, 2, 2, "fighter_01", true)
	var attacker_f := _place(st, 0, 2, 3, "fighter_01", true)
	attacker_f.has_attacked = true   # 本回合已攻击
	var inf := _place(st, 0, 1, 1, "infantry_01")
	inf.has_attacked = true
	var st2 := GameLogic.end_turn(st)
	# PC1 未攻击的战斗机 → 巡逻
	var p1: BattleState.UnitData = st2.board.get_unit(2, 2, "air")
	_check(p1 != null and p1.patrolling, "PC1 fighter without attack enters patrol at end of turn")
	# PC2 攻击过的战斗机 → 不巡逻
	var p2: BattleState.UnitData = st2.board.get_unit(2, 3, "air")
	_check(p2 != null and not p2.patrolling, "PC2 fighter that attacked does not patrol")
	# PC3 非战斗机不受影响（ground 单位无 patrolling 语义）
	var inf2: BattleState.UnitData = st2.board.get_unit(1, 1)
	_check(inf2 != null and not inf2.patrolling, "PC3 ground units unaffected")

	# U1 未被进攻的友方战斗机自动反击敌方巡逻机且免反击
	st = _fresh_state()
	_place(st, 1, 2, 2, "infantry_01")
	var helper := _place(st, 0, 2, 1, "fighter_01", true)   # 未被进攻的友机
	helper.attack = 5
	helper.defense = 4
	var main_a := _place(st, 0, 2, 3, "fighter_01", true)   # 主动攻击者
	main_a.attack = 2
	main_a.defense = 2
	_place_patrol(st, 1, 2, 0, 3, 5)  # 敌巡逻（拦主动攻击者）
	var enemy_g2 := _place(st, 1, 2, 2, "infantry_01")
	var st3 := GameLogic.attack_unit(st, 0, 2, 3, 2, 2)
	_check(st3 != null, "U1 combat resolves")
	if st3 != null:
		# 自动反击打了巡逻机 5 伤 → 巡逻机(防5)重伤/亡；主动攻击者被拦 3 伤后存活(防2-3<0 亡)
		var patrol_after: BattleState.UnitData = st3.board.get_unit(2, 0, "air")
		var patrol_dead := patrol_after == null or patrol_after.defense < 5
		_check(patrol_dead, "U1b auto-counter damaged enemy patrol")
		var helper_after: BattleState.UnitData = st3.board.get_unit(2, 1, "air")
		_check(helper_after != null and helper_after.defense == 4, "U1c auto-counter took no counter damage")


# ═══ 8. 巡逻不是无敌（敌方仍可主动攻击友方空军）═══

func _test_patrol_not_invincible() -> void:
	print("[patrol not invincible]")
	# 敌战斗机主动攻击我巡逻机所在战线 → 我巡逻机拦截（正常攻防，可被反击）
	var st := _fresh_state()
	st.active_player_index = 1
	var my_patrol := _place_patrol(st, 0, 2, 2, 3, 4)  # 我方巡逻机（攻3防4）
	var enemy_f := _place(st, 1, 2, 4, "fighter_01", true)  # 敌主动攻击者（射程本列±1）
	enemy_f.attack = 2
	enemy_f.defense = 9
	_place(st, 0, 2, 3, "infantry_01")  # 我地面目标
	# 敌攻击者打我地面单位 → 触发我巡逻机拦截
	var st2 := GameLogic.attack_unit(st, 1, 2, 4, 2, 3)
	_check(st2 != null, "N1 enemy attack resolves through my patrol intercept")
	if st2 != null:
		var patrol_after: BattleState.UnitData = st2.board.get_unit(2, 2, "air")
		_check(patrol_after != null and patrol_after.defense < 4, "N1b patrol intercepted and took damage (not invincible)")
		var enemy_after: BattleState.UnitData = st2.board.get_unit(2, 4, "air")
		_check(enemy_after != null and enemy_after.defense < 9, "N1c interceptor received counter damage")


func _run_all() -> void:
	_test_layers()
	_test_purchase_limits()
	_test_deploy_turn_rules()
	_test_retreat()
	_test_fort()
	_test_air_combat()
	_test_patrol_confirmation()
	_test_patrol_not_invincible()
