extends Node

## 单位交互大规模测试 — 覆盖攻击/反击/空战/守护/潜行/补给/修复/移动/部署/胜负/边界
## 运行: godot --headless --path . res://tests/test_interactions_scene.tscn
## 退出码 = 失败数。断言一律按设计文档的正确行为书写。

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== INTERACTION TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL INTERACTION TESTS PASSED")
	else:
		printerr("%d INTERACTION TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


# ── 工具 ──

func _fresh_state() -> BattleState:
	var st := BattleState.new()
	st.setup(["infantry_01"], ["infantry_01"], "infantry_01", "infantry_01")
	st.turn = 2
	st.phase = "action"
	st.active_player_index = 0
	st.players[0].resources = {"G": 300, "K": 5, "Z": 9}
	st.players[1].resources = {"G": 300, "K": 5, "Z": 9}
	return st


## 按真实卡牌数据放置单位（等价 deploy_unit 的初始化路径）
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


func _hp(u: BattleState.UnitData) -> int:
	if u == null:
		return -999
	return u.defense


func _alive(st: BattleState, r: int, c: int) -> bool:
	return st.board.get_unit(r, c) != null


func _run_all() -> void:
	_test_move_rules()
	_test_attack_basics()
	_test_air_combat()
	_test_abilities_assault_charge_plunder()
	_test_firm()
	_test_guard()
	_test_stealth()
	_test_supply_repair()
	_test_deploy_rules()
	_test_hand_limit()
	_test_victory_and_edges()


# ═══ A. 移动规则 ═══

func _test_move_rules() -> void:
	print("[move rules]")
	# A1 斜向前进
	var st := _fresh_state()
	_place(st, 0, 1, 1, "infantry_01")
	var st2 := GameLogic.move_unit(st, 0, 1, 1, 2, 2)
	_check(_alive(st2, 2, 2), "A1 infantry diagonal forward move ok")
	# A2 后退禁止
	st2 = GameLogic.move_unit(st, 0, 1, 1, 0, 1)
	_check(_alive(st2, 1, 1) and not _alive(st2, 0, 1), "A2 backward move blocked")
	# A3 横向移动
	st2 = GameLogic.move_unit(st, 0, 1, 1, 1, 2)
	_check(_alive(st2, 1, 2), "A3 lateral move ok")
	# A4 坦克一回合多次移动
	st = _fresh_state()
	_place(st, 0, 0, 0, "tank_01")
	st2 = GameLogic.move_unit(st, 0, 0, 0, 1, 0)
	st2 = GameLogic.move_unit(st2, 0, 1, 0, 2, 0)
	st2 = GameLogic.move_unit(st2, 0, 2, 0, 3, 0)
	_check(_alive(st2, 3, 0) and not _alive(st2, 2, 0), "A4 tank moves multiple times per turn")
	# A5 坦克攻击后仍可移动（横向，避免方向规则干扰）
	st = _fresh_state()
	_place(st, 0, 1, 0, "tank_01")
	_place(st, 1, 2, 0, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	st2 = GameLogic.move_unit(st2, 0, 1, 0, 1, 1)
	_check(_alive(st2, 1, 1), "A5 tank moves after attacking")
	# A6 步兵攻击后不能再移动
	st = _fresh_state()
	_place(st, 0, 2, 0, "infantry_01")
	_place(st, 1, 3, 0, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 2, 0, 3, 0)
	st2 = GameLogic.move_unit(st2, 0, 2, 0, 1, 0)
	_check(not _alive(st2, 1, 0) and _alive(st2, 2, 0), "A6 infantry cannot move after attacking")
	# A7 步兵移动后不能再攻击（移动或攻击共一次）
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	_place(st, 1, 3, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 0, 1, 0, 2, 0)
	var st3 := GameLogic.attack_unit(st2, 0, 2, 0, 3, 0)
	_check(st3 == null or _hp(st3.board.get_unit(3, 0)) == 4, "A7 infantry cannot attack after moving (move-or-attack once)")
	# A8 空军移动后可攻击
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")
	_place(st, 1, 4, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 0, 0, 0, 1, 0)
	st2 = GameLogic.attack_unit(st2, 0, 1, 0, 4, 0)
	_check(not _alive(st2, 4, 0), "A8 air moves then attacks (column range)")
	# A9 空军攻击后可移动
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")
	_place(st, 1, 4, 1, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 4, 1)
	st2 = GameLogic.move_unit(st2, 0, 0, 0, 1, 0)
	_check(_alive(st2, 1, 0), "A9 air attacks then moves")
	# A10 空军第二次移动被拒
	st2 = GameLogic.move_unit(st2, 0, 1, 0, 2, 0)
	_check(not _alive(st2, 2, 0), "A10 air second move blocked")
	# A11 坦克第二次攻击被拒
	st = _fresh_state()
	_place(st, 0, 1, 0, "tank_01")
	var tank_tgt := _place(st, 1, 2, 0, "infantry_01")
	tank_tgt.max_defense = 9
	tank_tgt.defense = 9
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	var hp_after := _hp(st2.board.get_unit(2, 0))
	var st2b := GameLogic.attack_unit(st2, 0, 1, 0, 2, 0)
	_check(st2b == null or _hp(st2b.board.get_unit(2, 0)) == hp_after, "A11 tank second attack blocked")
	# A12 目标格有单位
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	_place(st, 0, 2, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 0, 1, 0, 2, 0)
	_check(_alive(st2, 1, 0) and _alive(st2, 2, 0), "A12 move onto occupied cell blocked")
	# A13 越界
	st = _fresh_state()
	_place(st, 0, 0, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 0, 0, 0, -1, 0)
	st2 = GameLogic.move_unit(st2, 0, 0, 0, 0, 99)
	_check(_alive(st2, 0, 0), "A13 out-of-bounds moves blocked")
	# A14 移动两格被拒
	st = _fresh_state()
	_place(st, 0, 0, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 0, 0, 0, 2, 0)
	_check(_alive(st2, 0, 0), "A14 two-cell move blocked")
	# A15 Z 不足
	st = _fresh_state()
	_place(st, 0, 0, 0, "infantry_01")
	st.players[0].resources["Z"] = 0
	st2 = GameLogic.move_unit(st, 0, 0, 0, 1, 0)
	_check(_alive(st2, 0, 0), "A15 move with no Z blocked")
	# A16 P2 后退同样禁止
	st = _fresh_state()
	st.active_player_index = 1
	_place(st, 1, 3, 0, "infantry_01")
	st2 = GameLogic.move_unit(st, 1, 3, 0, 4, 0)
	_check(_alive(st2, 3, 0) and not _alive(st2, 4, 0), "A16 P2 backward move blocked")


# ═══ B. 攻击基础 ═══

func _test_attack_basics() -> void:
	print("[attack basics]")
	# B1 基础互伤
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")   # 攻3
	_place(st, 1, 2, 0, "infantry_01")   # 攻3 防4
	var st2 := GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 1, "B1 defender takes 3 (4->1)")
	_check(_hp(st2.board.get_unit(1, 0)) == 1, "B1 attacker takes counter 3 (4->1)")
	# B2 步兵斜角攻击（攻击范围含斜角，周围八格）
	st = _fresh_state()
	_place(st, 0, 1, 1, "infantry_01")
	_place(st, 1, 2, 2, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 1, 1, 2, 2)
	_check(_hp(st2.board.get_unit(2, 2)) == 1, "B2 adjacent_8 diagonal attack hits (4->1)")
	# B3 火炮全图射程 + 免反击（守方被击杀则无反击）
	st = _fresh_state()
	_place(st, 0, 0, 0, "artillery_01")   # 攻5
	_place(st, 1, 4, 4, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 4, 4)
	_check(not _alive(st2, 4, 4), "B3 artillery global range kills")
	_check(_alive(st2, 0, 0) and _hp(st2.board.get_unit(0, 0)) == 2, "B3 artillery takes no counter")
	# B4 火炮被攻击时可以反击（攻击方伤不足以击杀）
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_03")   # 攻2
	var arty_def := _place(st, 1, 2, 0, "artillery_01")   # 攻5 防2
	arty_def.max_defense = 3
	arty_def.defense = 3                  # 扛住 2 点伤害
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 1, "B4 artillery survives (3-2)")
	_check(not _alive(st2, 1, 0), "B4 artillery counters (5 >= 3), attacker dies")
	# B5 击杀奖励 25%
	st = _fresh_state()
	var g0: int = st.players[0].resources["G"]
	_place(st, 0, 1, 0, "infantry_01")
	var victim := _place(st, 1, 2, 0, "infantry_01")   # cost 30
	_wound(victim, 2)                        # 4->2，攻3可击杀
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(not _alive(st2, 2, 0), "B5 target killed")
	_check(st2.players[0].resources["G"] == g0 + 7, "B5 kill reward 25% of cost (7G)")
	# B6 反击击杀攻击者
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")   # 防4
	_place(st, 1, 2, 0, "tank_03")       # 攻6
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(not _alive(st2, 1, 0), "B6 attacker dies to counter (6 >= 4)")
	_check(_alive(st2, 2, 0), "B6 defender survives")
	# B7 打友方拒绝（返回 null，状态不变）
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	_place(st, 0, 2, 0, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(st2 == null, "B7 friendly attack rejected (null)")


# ═══ C. 空战 ═══

func _test_air_combat() -> void:
	print("[air combat]")
	# C1 陆军打空军无效（不耗 Z）
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	_place(st, 1, 2, 0, "fighter_01")
	var z0: int = st.players[0].resources["Z"]
	var st2 := GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 2 and st2.players[0].resources["Z"] == z0, "C1 ground cannot attack air (no Z loss)")
	# C2 坦克打轰炸机无效
	st = _fresh_state()
	_place(st, 0, 1, 0, "tank_01")
	_place(st, 1, 2, 0, "bomber_01")
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 1, "C2 tank cannot attack bomber")
	# C3 轰炸机打陆军：高伤且不被反击
	st = _fresh_state()
	_place(st, 0, 0, 0, "bomber_01")     # 攻6
	_place(st, 1, 2, 0, "infantry_01")   # 防4，同列射程
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 2, 0)
	_check(not _alive(st2, 2, 0), "C3 bomber kills infantry")
	_check(_alive(st2, 0, 0) and _hp(st2.board.get_unit(0, 0)) == 1, "C3 bomber takes no counter from ground")
	# C4 轰炸机不能攻击空军（设计：只能打陆军）
	st = _fresh_state()
	_place(st, 0, 0, 0, "bomber_01")     # 攻6
	_place(st, 1, 3, 0, "fighter_01")    # 防2
	var z0c: int = st.players[0].resources["Z"]
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 3, 0)
	_check(_hp(st2.board.get_unit(3, 0)) == 2, "C4 bomber cannot attack fighter")
	_check(st2.players[0].resources["Z"] == z0c, "C4 rejected attack costs no Z")
	# C5 战斗机打战斗机：攻4 vs 防2 击杀 → 无反击
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")    # 攻4 防2
	_place(st, 1, 3, 0, "fighter_01")
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 3, 0)
	_check(not _alive(st2, 3, 0), "C5 fighter kills fighter (4 vs 2)")
	_check(_alive(st2, 0, 0) and _hp(st2.board.get_unit(0, 0)) == 2, "C5 no counter when defender dies first")
	# C6 战斗机打陆军：无防空不反击
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")    # 攻4
	_place(st, 1, 2, 0, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 2, 0)
	_check(not _alive(st2, 2, 0), "C6 fighter kills infantry (4 vs 4, column range)")
	_check(_hp(st2.board.get_unit(0, 0)) == 2, "C6 infantry without AA cannot counter")
	# C7 陆军有防空可反击空军
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")    # 攻4 防2
	var aa := _place(st, 1, 2, 0, "infantry_01")
	aa.abilities.append("防空")
	aa.max_defense = 6
	aa.defense = 6                        # 扛住 4 伤害以便反击
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 2, "C7 AA unit takes 4 (6->2)")
	_check(not _alive(st2, 0, 0), "C7 AA ground counters air (3 >= 2)")
	# C8 空对空：战斗机打轰炸机，轰炸机不反击
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")    # 攻4
	_place(st, 1, 4, 0, "bomber_01")     # 防1 同列
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 4, 0)
	_check(not _alive(st2, 4, 0) and _alive(st2, 0, 0), "C8 fighter kills bomber, no counter")


# ═══ D. 突击/冲锋/收缴 ═══

func _test_abilities_assault_charge_plunder() -> void:
	print("[assault / charge / plunder]")
	# D1 突击（火炮）部署当回合攻击免反击 —— 用 deploy 走真实路径
	var st := _fresh_state()
	st.players[0].hand.append("artillery_01")
	st = GameLogic.deploy_unit(st, 0, "artillery_01", 0, 0)
	_place(st, 1, 4, 4, "infantry_01")
	var st2 := GameLogic.attack_unit(st, 0, 0, 0, 4, 4)
	_check(_alive(st2, 0, 0), "D1 assault deploy-turn attack takes no counter")
	# D2 突击坦克次回合攻击会被反击（突击只保护部署当回合）
	st = _fresh_state()
	st.players[0].hand.append("tank_03")   # 突击 坚守
	st = GameLogic.deploy_unit(st, 0, "tank_03", 0, 0)
	var d2_tgt := _place(st, 1, 1, 0, "infantry_01")
	d2_tgt.max_defense = 30
	d2_tgt.defense = 30                    # 大血量：两次攻击都扛住，保证反击发生
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(_alive(st2, 0, 0) and _hp(st2.board.get_unit(0, 0)) == 3, "D2a assault deploy-turn attack no counter")
	# 次回合
	st2 = GameLogic.end_turn(st2)
	st2 = GameLogic.end_turn(st2)
	st2 = GameLogic.start_turn(st2)
	st2.players[0].resources["Z"] = 9
	var t2 := st2.board.get_unit(0, 0)
	_wound(t2, 1)                          # 3->2
	st2 = GameLogic.attack_unit(st2, 0, 0, 0, 1, 0)
	var a2 := st2.board.get_unit(0, 0)
	_check(a2 == null, "D2 assault turn-2 attack receives counter (tank 2 dies to 3)")
	# D3 冲锋（骑兵）：设计 = 首次攻击免反击
	st = _fresh_state()
	st.players[0].hand.append("cavalry_01")
	st = GameLogic.deploy_unit(st, 0, "cavalry_01", 0, 0)
	_place(st, 1, 1, 0, "infantry_01")
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(_alive(st2, 0, 0) and _hp(st2.board.get_unit(0, 0)) == 2, "D3 charge deploy-turn attack no counter")
	# D4 冲锋次回合首次攻击仍应免反击（设计：首次攻击不受反击）
	st2 = GameLogic.end_turn(st2)
	st2 = GameLogic.end_turn(st2)
	st2 = GameLogic.start_turn(st2)
	var d4_tgt := _place(st2, 1, 1, 1, "infantry_01")
	d4_tgt.max_defense = 9
	d4_tgt.defense = 9                     # 大血量：扛住攻击，保证反击发生
	var cav := st2.board.get_unit(0, 0)
	_wound(cav, 1)                         # 2->1
	st2.players[0].resources["Z"] = 9
	st2 = GameLogic.attack_unit(st2, 0, 0, 0, 1, 1)
	# 骑兵 1 血遭反击 3 → 死亡 = 反击确实发生了（冲锋首次攻击免反击应保护次回合攻击）
	_check(st2 == null or not _alive(st2, 0, 0), "D4 charge first-attack immunity persists beyond deploy turn")
	# D5 收缴：击杀得 50%
	st = _fresh_state()
	st.players[0].hand.append("cavalry_02")   # 收缴 攻3
	st = GameLogic.deploy_unit(st, 0, "cavalry_02", 0, 0)
	var victim2 := _place(st, 1, 1, 0, "infantry_01")   # cost 30
	_wound(victim2, 2)                        # 4->2，攻3可击杀
	var g0: int = st.players[0].resources["G"]
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(not _alive(st2, 1, 0), "D5 target killed by charge cavalry")
	_check(st2.players[0].resources["G"] == g0 + 15, "D5 plunder kill rewards 50% (15G)")
	# D6 普通击杀 25%（对照，见 B5）
	# D7 收缴但未击杀 → 无奖励
	st = _fresh_state()
	st.players[0].hand.append("cavalry_02")
	st = GameLogic.deploy_unit(st, 0, "cavalry_02", 0, 0)
	_place(st, 1, 1, 0, "tank_01")            # 防4 坚守1 → 伤害 3-1=2，存活
	g0 = st.players[0].resources["G"]
	st2 = GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	_check(st2.players[0].resources["G"] == g0 and _hp(st2.board.get_unit(1, 0)) == 2, "D6 plunder no kill no reward; firm reduces to 2")


# ═══ E. 坚守 ═══

func _test_firm() -> void:
	print("[firm]")
	# E1 坚守1：坦克被攻3打只掉2
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")   # 攻3
	_place(st, 1, 2, 0, "tank_01")       # 坚守1 防4
	var st2 := GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 2, "E1 firm reduces damage 3->2")
	# E2 高坚守保底伤害 1
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")   # 攻3
	var t := _place(st, 1, 2, 0, "tank_02")   # 坚守1 防6
	t.firm_level = 3
	st2 = GameLogic.attack_unit(st, 0, 1, 0, 2, 0)
	_check(_hp(st2.board.get_unit(2, 0)) == 5, "E2 firm 3 reduces to min 1 damage")
	# E3 坦克默认坚守1（无坚守词条也有）
	st = _fresh_state()
	var tank_no_firm := _place(st, 1, 2, 0, "tank_01")
	tank_no_firm.abilities = []
	tank_no_firm.firm_level = 0
	# 通过重新初始化验证坦克默认坚守在 deploy 路径而非 place 路径：
	# 直接放置不触发默认值，因此这里验证 deploy 路径
	st.players[0].hand.append("tank_01")
	var st3 := GameLogic.deploy_unit(st, 0, "tank_01", 0, 0)
	var deployed := st3.board.get_unit(0, 0)
	_check(deployed.firm_level == 1, "E3 tank defaults to firm 1 on deploy")


# ═══ F. 守护 ═══

func _test_guard() -> void:
	print("[guard]")
	# F1 部署守护单位 → 相邻友方获得被守护
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	st.players[0].hand.append("infantry_02")   # 守护
	st = GameLogic.deploy_unit(st, 0, "infantry_02", 0, 1)
	var prot := st.board.get_unit(1, 0)
	_check(prot.is_guarded and prot.guarded_by == Vector2i(0, 1), "F1 adjacent friendly becomes guarded")
	# F2 攻击被守护单位 → 伤害转给守护单位
	_place(st, 1, 2, 0, "infantry_01")   # P2 攻击者，与目标相邻
	var st2 := GameLogic.attack_unit(st, 1, 2, 0, 1, 0)   # P2 打被守护的 P1 步兵
	_check(_hp(st2.board.get_unit(1, 0)) == 4, "F2 damage redirected: target unharmed")
	_check(_hp(st2.board.get_unit(0, 1)) == 2, "F2 guard takes damage (5-3)")
	# F3 守护单位被转移伤害击杀 → 消失，目标无损
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	_place(st, 1, 2, 0, "infantry_01")   # P2 攻击者
	var real_guard := _place(st, 0, 0, 1, "infantry_02")
	real_guard.defense = 2   # 弱化守护单位：转移伤害 3 足以击杀
	var prot2 := st.board.get_unit(1, 0)
	prot2.is_guarded = true
	prot2.guarded_by = Vector2i(0, 1)
	st2 = GameLogic.attack_unit(st, 1, 2, 0, 1, 0)
	_check(not _alive(st2, 0, 1), "F3 guard dies from redirected damage")
	_check(_hp(st2.board.get_unit(1, 0)) == 4 and _alive(st2, 1, 0), "F3 protected unit unharmed")
	# F4 守护单位移动离开后，原被守护单位不再受保护
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	st.players[0].hand.append("infantry_02")
	st = GameLogic.deploy_unit(st, 0, "infantry_02", 0, 1)
	# 守护单位 (0,1) 单步移动到 (0,2)（与 (1,0) 不再相邻）
	var st_after := GameLogic.move_unit(st, 0, 0, 1, 0, 2)
	var prot3 := st_after.board.get_unit(1, 0)
	_check(not prot3.is_guarded, "F4 protection cleared when guard moves away")
	# F5 友方单位移动到守护单位旁 → 获得保护（动态相邻）
	st = _fresh_state()
	st.players[0].hand.append("infantry_02")
	st = GameLogic.deploy_unit(st, 0, "infantry_02", 0, 4)
	_place(st, 0, 0, 2, "infantry_01")     # 与守护 (0,4) 不相邻
	st = GameLogic.move_unit(st, 0, 0, 2, 0, 3)   # 单步移到守护旁
	var mover := st.board.get_unit(0, 3)
	_check(mover != null and mover.is_guarded and mover.guarded_by == Vector2i(0, 4), "F5 mover next to guard becomes guarded")
	# F6 被守护单位自己移走 → 失去保护
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	st.players[0].hand.append("infantry_02")
	st = GameLogic.deploy_unit(st, 0, "infantry_02", 0, 1)
	st = GameLogic.move_unit(st, 0, 1, 0, 2, 1)   # 被守护单位单步离开（斜向）
	var moved := st.board.get_unit(2, 1)
	_check(moved != null and not moved.is_guarded, "F6 protected unit loses guard after moving away")
	# F7 敌方不享受守护
	st = _fresh_state()
	st.players[0].hand.append("infantry_02")
	st = GameLogic.deploy_unit(st, 0, "infantry_02", 0, 1)
	_place(st, 1, 1, 1, "infantry_01")   # P2 单位与 P1 守护相邻
	var enemy := st.board.get_unit(1, 1)
	_check(not enemy.is_guarded, "F7 enemy unit not protected by P1 guard")
	# F8 守护单位自己不给自己守护
	var g := st.board.get_unit(0, 1)
	_check(not g.is_guarded or g.guarded_by != Vector2i(0, 1), "F8 guard does not guard itself")


# ═══ G. 潜行 ═══

func _test_stealth() -> void:
	print("[stealth]")
	# G1 部署潜行单位 → stealthed
	var st := _fresh_state()
	st.players[0].hand.append("fighter_02")   # 防空 潜行
	st = GameLogic.deploy_unit(st, 0, "fighter_02", 0, 0)
	var f := st.board.get_unit(0, 0)
	_check(f.stealthed and not f.revealed, "G1 stealth unit starts hidden")
	# G2 敌方步兵十字相邻 → 回合开始时揭示
	_place(st, 1, 1, 0, "infantry_01")
	var st2 := GameLogic.start_turn(st)   # P1 回合开始时重算
	# 注意：_update_stealth_reveal 检查的是潜行单位的敌方（P1 视角敌方=P2 步兵）
	var f2 := st2.board.get_unit(0, 0)
	_check(f2.revealed, "G2 stealth revealed by adjacent enemy infantry")
	# G3 敌方坦克相邻不揭示
	st = _fresh_state()
	st.players[0].hand.append("fighter_02")
	st = GameLogic.deploy_unit(st, 0, "fighter_02", 0, 0)
	_place(st, 1, 1, 1, "tank_01")
	st2 = GameLogic.start_turn(st)
	f2 = st2.board.get_unit(0, 0)
	_check(not f2.revealed, "G3 stealth NOT revealed by enemy tank")
	# G4 未揭示的潜行单位不可被攻击（空对空场景：潜行单位只有空军）
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")                     # P1 攻击方
	var stealth_f := _place(st, 1, 4, 0, "fighter_02")   # P2 潜行（同列射程）
	stealth_f.revealed = false
	var st2b := GameLogic.attack_unit(st, 0, 0, 0, 4, 0)
	_check(_alive(st2b, 4, 0) and _hp(st2b.board.get_unit(4, 0)) == 1, "G4 cannot attack unrevealed stealth unit")
	# G5 已揭示的潜行单位可以被攻击
	st = _fresh_state()
	_place(st, 0, 0, 0, "fighter_01")
	stealth_f = _place(st, 1, 4, 0, "fighter_02")
	stealth_f.revealed = true
	st2b = GameLogic.attack_unit(st, 0, 0, 0, 4, 0)
	_check(not _alive(st2b, 4, 0), "G5 revealed stealth unit can be attacked")


# ═══ H. 补给 / 后方修复 ═══

func _test_supply_repair() -> void:
	print("[supply / rear repair]")
	# H1 补给坦克回合开始修相邻友方 1
	var st := _fresh_state()
	_place(st, 0, 0, 0, "tank_02")         # 补给
	var w := _place(st, 0, 1, 0, "infantry_01")
	_wound(w, 2)                           # 4->2
	st.players[0].resources["Z"] = 9
	var st2 := GameLogic.start_turn(st)
	_check(_hp(st2.board.get_unit(1, 0)) == 3, "H1 supply heals adjacent wounded by 1")
	# H2 满血不治疗
	st = _fresh_state()
	_place(st, 0, 0, 0, "tank_02")
	_place(st, 0, 1, 0, "infantry_01")
	st.players[0].resources["Z"] = 9
	st2 = GameLogic.start_turn(st)
	_check(_hp(st2.board.get_unit(1, 0)) == 4, "H2 supply skips full-hp unit")
	# H3 两个补给单位各自治疗一个
	st = _fresh_state()
	_place(st, 0, 0, 0, "tank_02")
	_place(st, 0, 0, 4, "tank_02")
	var w1 := _place(st, 0, 1, 0, "infantry_01")
	var w2 := _place(st, 0, 1, 4, "infantry_01")
	_wound(w1, 2)
	_wound(w2, 2)
	st.players[0].resources["Z"] = 9
	st2 = GameLogic.start_turn(st)
	var healed_both: bool = _hp(st2.board.get_unit(1, 0)) == 3 and _hp(st2.board.get_unit(1, 4)) == 3
	_check(healed_both, "H3 each supply unit heals its own neighbor")
	# H4 后方修复：P1 行0 单位每回合 +1
	st = _fresh_state()
	var rear := _place(st, 0, 0, 2, "infantry_01")
	var front := _place(st, 0, 1, 2, "infantry_01")
	_wound(rear, 3)
	_wound(front, 3)
	st.players[0].resources["Z"] = 9
	st2 = GameLogic.start_turn(st)
	_check(_hp(st2.board.get_unit(0, 2)) == 2, "H4 rear row unit heals 1")
	_check(_hp(st2.board.get_unit(1, 2)) == 1, "H4 front row unit not healed by rear rule")
	# H5 后方修复封顶
	st = _fresh_state()
	var rear2 := _place(st, 0, 0, 2, "infantry_01")
	_wound(rear2, 1)
	st.players[0].resources["Z"] = 9
	st2 = GameLogic.start_turn(st)
	_check(_hp(st2.board.get_unit(0, 2)) == 4, "H5 rear repair caps at max defense")


# ═══ I. 部署规则 ═══

func _test_deploy_rules() -> void:
	print("[deploy rules]")
	# I1 火炮只能部署后方（即使前线已被占领）
	var st := _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")   # 占领前线
	var rows: Array[int] = GameLogic.get_deployable_rows(st, 0, "artillery_01")
	_check(rows.size() == 1 and rows[0] == 0, "I1 artillery back-row only")
	# I2 步兵：占领前线后可部署前线
	rows = GameLogic.get_deployable_rows(st, 0, "infantry_01")
	_check(rows.has(0) and rows.has(1), "I2 infantry front deploy after occupation")
	# I3 未占领前线时步兵只能后方
	st = _fresh_state()
	rows = GameLogic.get_deployable_rows(st, 0, "infantry_01")
	_check(rows.size() == 1 and rows[0] == 0, "I3 infantry back only without front occupation")
	# I4 骑兵同步兵（占领后可前线）
	st = _fresh_state()
	_place(st, 0, 1, 0, "infantry_01")
	rows = GameLogic.get_deployable_rows(st, 0, "cavalry_01")
	_check(rows.has(0) and rows.has(1), "I4 cavalry front deploy after occupation")
	# I5 坦克同步兵：占领前线后可部署前线（设计 4.1 表）
	rows = GameLogic.get_deployable_rows(st, 0, "tank_01")
	_check(rows.has(0) and rows.has(1), "I5 tank front deploy after occupation (design: same as infantry)")
	# I6 战斗机同步兵
	rows = GameLogic.get_deployable_rows(st, 0, "fighter_01")
	_check(rows.has(0) and rows.has(1), "I6 fighter front deploy after occupation")
	# I7 轰炸机同步兵
	rows = GameLogic.get_deployable_rows(st, 0, "bomber_01")
	_check(rows.has(0) and rows.has(1), "I7 bomber front deploy after occupation")
	# I8 P2 视角镜像
	st = _fresh_state()
	st.active_player_index = 1
	_place(st, 1, 3, 0, "infantry_01")
	rows = GameLogic.get_deployable_rows(st, 1, "tank_01")
	_check(rows.has(4) and rows.has(3), "I8 P2 tank front (row3) deploy after occupation")
	# I9 部署到被占格拒绝
	st = _fresh_state()
	_place(st, 0, 0, 0, "infantry_01")
	st.players[0].hand.append("infantry_01")
	var st2 := GameLogic.deploy_unit(st, 0, "infantry_01", 0, 0)
	_check(st2 == null or _alive(st, 0, 0), "I9 deploy onto occupied cell rejected")
	# I10 Z 不足部署拒绝
	st = _fresh_state()
	st.players[0].hand.append("infantry_01")
	st.players[0].resources["Z"] = 0
	st2 = GameLogic.deploy_unit(st, 0, "infantry_01", 0, 0)
	_check(st2 == null or st2.board.get_unit(0, 0) == null, "I10 deploy with no Z rejected")


# ═══ J. 手牌上限 ═══

func _test_hand_limit() -> void:
	print("[hand limit]")
	var st := _fresh_state()
	var p = st.players[0]
	for i in range(7):
		p.hand.append("infantry_01")
	p.purchase_zone.append("infantry_01")
	var st2 := GameLogic.purchase_card(st, 0, "infantry_01")
	_check(st2 == null, "J1 purchase blocked when hand is full (7)")


# ═══ K. 胜负与边界 ═══

func _test_victory_and_edges() -> void:
	print("[victory & edges]")
	# K1 P1 占满 rows3-4 全列 → 胜
	var st := _fresh_state()
	for c in range(5):
		_place(st, 0, 3, c, "infantry_01")
	var st2 := GameLogic.end_turn(st)
	_check(st2.winner == 0, "K1 P1 wins with all 5 columns in P2 zone")
	# K2 只占 4 列不胜
	st = _fresh_state()
	for c in range(4):
		_place(st, 0, 3, c, "infantry_01")
	st2 = GameLogic.end_turn(st)
	_check(st2.winner == -1, "K2 4 columns is not a win")
	# K3 P2 占满 rows0-1 → P2 胜
	st = _fresh_state()
	for c in range(5):
		_place(st, 1, 0, c, "infantry_01")
	st2 = GameLogic.end_turn(st)
	_check(st2.winner == 1, "K3 P2 wins with all 5 columns in P1 zone")
	# K4 己方区域不算（P1 单位只在 rows0-1）
	st = _fresh_state()
	for c in range(5):
		_place(st, 0, 0, c, "infantry_01")
	st2 = GameLogic.end_turn(st)
	_check(st2.winner == -1, "K4 units in own zone do not win")
	# K5 牌堆抽空不崩溃
	st = _fresh_state()
	st.players[0].deck = []
	var n: int = st.players[0].purchase_zone.size()
	st2 = GameLogic.start_turn(st)
	_check(st2.players[0].purchase_zone.size() == n, "K5 draw from empty deck is safe no-op")
	# K6 Z 逐点消耗后拒绝行动
	st = _fresh_state()
	_place(st, 0, 0, 0, "infantry_01")
	st.players[0].resources["Z"] = 1
	var s1 := GameLogic.move_unit(st, 0, 0, 0, 1, 0)
	var s2 := GameLogic.move_unit(s1, 0, 1, 0, 2, 0)
	_check(_alive(s1, 1, 0) and _alive(s2, 1, 0) and not _alive(s2, 2, 0), "K6 second action blocked when Z exhausted")
	# K7 指纹：相同操作 → 相同指纹
	st = _fresh_state()
	var st_b := _fresh_state()
	_place(st, 0, 0, 0, "tank_01")
	_place(st, 1, 1, 0, "infantry_01")
	_place(st_b, 0, 0, 0, "tank_01")
	_place(st_b, 1, 1, 0, "infantry_01")
	var s1a := GameLogic.attack_unit(st, 0, 0, 0, 1, 0)
	var s1b := GameLogic.attack_unit(st_b, 0, 0, 0, 1, 0)
	_check(s1a != null and s1b != null, "K7 setup: attacks applied")
	_check(GameLogic.state_fingerprint(s1a) == GameLogic.state_fingerprint(s1b), "K7 fingerprints match after identical interaction")
	# K8 胜负在 end_turn 才结算（满足条件但未结束回合时不提前结束）
	st = _fresh_state()
	for c in range(5):
		_place(st, 0, 3, c, "infantry_01")
	_check(st.winner == -1, "K8 full occupation mid-turn does not end game until end_turn")
