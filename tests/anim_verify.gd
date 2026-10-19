extends Node2D

## 动画行为验证（headless + --fixed-fps 60，逐帧采样断言）。
## 用法：godot --headless --fixed-fps 60 --path . res://tests/anim_verify.tscn
## --fixed-fps 把 delta 固定为 1/60，逐帧等待在慢机上依然确定，因此可以进 CI。

var battle: Node = null
var tm: TurnManager = null
var board: Board = null
var hand: HandManager = null
var fails: Array[String] = []
var checks := 0
var done := {}
var rounds := 0


func _ready() -> void:
	await get_tree().process_frame
	battle = load("res://scenes/battle.tscn").instantiate()
	get_tree().root.add_child(battle)
	await get_tree().process_frame
	get_tree().current_scene = battle
	GameManager._setup_battle()
	await get_tree().process_frame
	tm = GameManager.turn_manager
	board = battle
	for c in battle.get_children():
		if c is HandManager:
			hand = c
	if tm == null or hand == null:
		printerr("[verify] setup failed")
		get_tree().quit(1)
		return
	check("初始渲染后有单位显示字典", board._unit_displays != null)
	check("初始无残留动画节点", _marked_children(board).is_empty())
	await _drive()
	# 收尾：所有动画结束后不留临时节点
	await frames(60)
	check("动画结束后无残留临时节点 (board)", _marked_children(board).is_empty(), str(_marked_children(board)))
	check("回合数已推进", tm.get_state().turn >= 2, "turn=%d" % tm.get_state().turn)
	# 复盘模式：不应产生任何临时动画节点（复盘是全图静态展示）
	board.review_mode = true
	board.render_review_state(tm.get_state())
	board._on_action_applied({"type": "move", "from_row": 0, "from_col": 0, "to_row": 1, "to_col": 1})
	await frames(3)
	check("复盘模式：不产生动画临时节点", _marked_children(board).is_empty(), "%d 个" % _marked_children(board).size())
	board.review_mode = false
	board._on_state_changed(tm.get_state())
	await frames(2)

	# 战线占领度标签：变化时弹动 + 飘增量（直接注入前后状态，与对局解耦）
	var fc_prev: BattleState = tm.get_state().duplicate(true)
	var fc_cur: BattleState = tm.get_state().duplicate(true)
	fc_cur.front_control[0] = int(fc_prev.front_control[0]) + 10
	fc_cur.front_control[1] = int(fc_prev.front_control[1]) - 5
	board._anim_front_control(fc_prev, fc_cur)
	await frames(2)
	var fc_floats := _float_labels(board, "+")
	var fc_floats2 := _float_labels(board, "-")
	check("战线：行标签弹动", board._front_labels[0].scale != Vector2.ONE, str(board._front_labels[0].scale))
	check("战线：飘出占领度增量", not fc_floats.is_empty() or not fc_floats2.is_empty(),
		"%s / %s" % [str(fc_floats.map(func(l): return l.text)), str(fc_floats2.map(func(l): return l.text))])
	await frames(50)
	check("战线：动画结束后标签 scale 归位", absf(board._front_labels[0].scale.x - 1.0) < 0.02, str(board._front_labels[0].scale))

	# 胜利横幅：注入一个 winner 状态验证动画（与真实对局解耦，最后执行）
	var win_state: BattleState = tm.get_state().duplicate(true)
	win_state.winner = 0
	hand._on_state_changed(win_state)
	await frames(2)
	check("胜利：横幅文案切换", hand._banner.text.begins_with("玩家 1 获胜"), hand._banner.text)
	check("胜利：横幅弹动", hand._banner.scale != Vector2.ONE, str(hand._banner.scale))
	check("胜利：结束回合按钮停止呼吸", not hand._end_btn_breathing, str(hand._end_btn_breathing))
	await frames(40)
	hand._on_state_changed(tm.get_state())
	await frames(2)
	_report()
	get_tree().quit(0 if fails.is_empty() else 1)


func _drive() -> void:
	for round_i in 24:
		rounds = round_i
		var st := tm.get_state()
		if st == null or st.winner != -1:
			return
		if st.phase == "purchase":
			var offer := _pick_offer(st)
			if offer != "":
				var before_text: String = hand._g_label.text
				_submit({"type": "purchase", "card_id": offer})
				await frames(3)
				if not done.has("buy"):
					done["buy"] = true
					check("购买：资源标签同步写为最终值", hand._g_label.text != before_text, "%s -> %s" % [before_text, hand._g_label.text])
					check("购买：资源数字有弹动", hand._g_label.scale != Vector2.ONE, str(hand._g_label.scale))
					var floats := _float_labels(hand, "G ")
					check("购买：飘出 G 增量文字", not floats.is_empty(), str(floats.map(func(l): return l.text)))
					await frames(40)
					check("购买：动画后资源文字仍为最终值（未被动画改写）", hand._g_label.text == ("G: %d" % int(tm.get_state().players[tm.get_state().active_player_index].resources["G"])), hand._g_label.text)
			else:
				await frames(2)
		if tm.get_state().phase == "purchase":
			_submit({"type": "skip_phase"})
			await frames(3)
			if not done.has("phase"):
				done["phase"] = true
				check("阶段切换：阶段标签弹出", hand._phase_label.scale != Vector2.ONE, str(hand._phase_label.scale))
				check("阶段切换：阶段文本最终值同步", hand._phase_label.text == "阶段: deploy", hand._phase_label.text)
		var dep := _pick_deploy(tm.get_state())
		while not dep.is_empty():
			_submit({"type": "deploy", "card_id": dep["card_id"], "row": dep["row"], "col": dep["col"]})
			await frames(3)
			if not done.has("deploy"):
				done["deploy"] = true
				check("部署：新单位缩放进场（scale < 1）", _min_display_scale() < 0.999, "min scale=%f" % _min_display_scale())
				await frames(30)
				check("部署：动画结束后新单位 scale 回 1", absf(_min_display_scale() - 1.0) < 0.02, "min scale=%f" % _min_display_scale())
			dep = _pick_deploy(tm.get_state())
		if tm.get_state().phase == "deploy":
			_submit({"type": "skip_phase"})
			await frames(3)
		if tm.get_state().phase == "action" and not done.has("breath"):
			done["breath"] = true
			check("行动阶段：结束回合按钮呼吸开启", hand._end_btn_breathing, str(hand._end_btn_breathing))
		var atk := _pick_attack(tm.get_state())
		if not atk.is_empty():
			var kill := _will_kill(atk)
			var atk_visible: bool = board._cell_visible(tm.get_state(), int(atk["target_row"]), int(atk["target_col"]))
			_submit({"type": "attack", "from_row": atk["from_row"], "from_col": atk["from_col"], "target_row": atk["target_row"], "target_col": atk["target_col"]})
			await frames(2)
			if atk_visible and not done.has("death") and not _unit_exists_at(int(atk["target_row"]), int(atk["target_col"])):
				done["death"] = true
				check("击破：死亡残影出现", not _death_ghosts().is_empty(), "%d ghost(s)" % _death_ghosts().size())
			if not done.has("attack") and atk_visible:
				done["attack"] = true
				var dmg_floats := _float_labels(board, "-")
				check("攻击：飘出伤害数字", not dmg_floats.is_empty(), str(dmg_floats.map(func(l): return l.text)))
				var lunge_ok := _attacker_offset(atk)
				check("攻击：攻击方前冲位移", lunge_ok != Vector2.ZERO, str(lunge_ok))
				await frames(6)
				if _unit_exists_at(int(atk["target_row"]), int(atk["target_col"])):
					check("攻击：目标抖动/染色中", _target_animating(atk), "target anim check")
				else:
					check("攻击：目标被击破 → 受击动画让位于击破残影", true)
				if kill:
					check("击破：死亡残影出现", not _death_ghosts().is_empty(), str(_death_ghosts().size()))
			await frames(40)
			if kill and not done.has("death_end"):
				done["death_end"] = true
				check("击破：残影淡出后清理", _death_ghosts().is_empty(), str(_death_ghosts().size()))
		var mv := _pick_move(tm.get_state())
		if not mv.is_empty():
			var from_cell := Vector2i(int(mv["from_row"]), int(mv["from_col"]))
			var to_cell := Vector2i(int(mv["to_row"]), int(mv["to_col"]))
			_submit({"type": "move", "from_row": from_cell.x, "from_col": from_cell.y, "to_row": to_cell.x, "to_col": to_cell.y})
			await frames(3)
			if not done.has("move"):
				done["move"] = true
				var ghosts := _ghosts()
				var a: Vector2 = board._cell_pos(from_cell.x, from_cell.y, false)
				var b: Vector2 = board._cell_pos(to_cell.x, to_cell.y, false)
				check("移动：出现滑行残影", not ghosts.is_empty(), "%d ghost(s)" % ghosts.size())
				if not ghosts.is_empty():
					var gp: Vector2 = ghosts[0].position
					check("移动：残影位于起点与终点之间", gp != a and gp != b and gp.distance_to(a) > 1.0, "ghost=%s from=%s to=%s" % [str(gp), str(a), str(b)])
				var dest = _display_for(to_cell.x, to_cell.y)
				check("移动：终点原位卡在滑行期间隐藏", dest != null and not dest.visible, "visible=%s" % str(dest.visible if dest != null else null))
				await frames(30)
				check("移动：滑行结束残影清理", _ghosts().is_empty(), "%d ghost(s)" % _ghosts().size())
				var dest2 = _display_for(to_cell.x, to_cell.y)
				check("移动：终点卡恢复可见", dest2 != null and dest2.visible, "visible=%s" % str(dest2.visible if dest2 != null else null))
				var b_air: Vector2 = board._cell_pos(to_cell.x, to_cell.y, true)
				check("移动：终点卡回到网格位置", dest2 != null and (dest2.position.distance_to(b) < 1.0 or dest2.position.distance_to(b_air) < 1.0),
					"pos=%s expect=%s|%s" % [str(dest2.position if dest2 != null else null), str(b), str(b_air)])
		if tm.get_state().phase == "action":
			_submit({"type": "end_turn"})
			await frames(3)
			if not done.has("end"):
				done["end"] = true
				check("结束回合：玩家标记弹动", board._p1_marker.scale != Vector2.ONE or board._p2_marker.scale != Vector2.ONE,
					"p1=%s p2=%s" % [str(board._p1_marker.scale), str(board._p2_marker.scale)])
			await frames(24)
		else:
			await frames(4)


# ───────── 采样辅助 ─────────
func _unit_exists_at(row: int, col: int) -> bool:
	var st := tm.get_state()
	if st == null:
		return false
	return st.board.get_unit(row, col, "ground") != null or st.board.get_unit(row, col, "air") != null


func _display_for(row: int, col: int):
	for k in board._unit_displays:
		if int(k.x) == row and int(k.y) == col:
			return board._unit_displays[k]
	return null

func _marked_children(host: Node) -> Array:
	var out := []
	for c in host.get_children():
		if UiAnim.is_marked(c):
			out.append(c)
	return out


func _float_labels(host: Node, prefix: String) -> Array:
	var out := []
	for c in host.get_children():
		if c is Label and UiAnim.is_marked(c) and String(c.text).begins_with(prefix):
			out.append(c)
	return out


func _ghosts() -> Array:
	var out := []
	for c in board.get_children():
		if c is CardDisplay and UiAnim.is_marked(c) and c.z_index == 5:
			out.append(c)
	return out


func _death_ghosts() -> Array:
	var out := []
	for c in board.get_children():
		if c is CardDisplay and UiAnim.is_marked(c) and c.z_index == 6:
			out.append(c)
	return out


func _min_display_scale() -> float:
	var m := 2.0
	for d in board._unit_displays.values():
		if is_instance_valid(d):
			m = minf(m, float(d.scale.x))
	return m


func _attacker_offset(atk: Dictionary) -> Vector2:
	var disp = _display_for(int(atk["from_row"]), int(atk["from_col"]))
	if disp == null or not is_instance_valid(disp):
		return Vector2.ZERO
	var base: Vector2 = board._cell_pos(int(atk["from_row"]), int(atk["from_col"]), false)
	return disp.position - base


func _target_animating(atk: Dictionary) -> bool:
	var disp = _display_for(int(atk["target_row"]), int(atk["target_col"]))
	if disp == null or not is_instance_valid(disp):
		return false
	var shaking: bool = float(disp.position.x) != float(board._cell_pos(int(atk["target_row"]), int(atk["target_col"]), false).x)
	var tinted: bool = disp.modulate != Color(1, 1, 1, 1)
	return shaking or tinted


# ───────── 对局驱动 ─────────
func _pick_offer(st: BattleState) -> String:
	var p = st.players[st.active_player_index]
	for card_id in p.purchase_zone:
		var card = CardDataLoader.cards.get(card_id)
		if card == null or str(card.type) != "unit":
			continue
		if int(p.resources["G"]) < int(card.cost_g):
			continue
		var rarity := str(card.rarity)
		if int(p.purchases_this_turn.get(rarity, 0)) >= int(GameLogic.PURCHASE_LIMITS.get(rarity, 99)):
			continue
		return str(card_id)
	return ""


func _pick_deploy(st: BattleState) -> Dictionary:
	var idx := st.active_player_index
	for card_id in st.players[idx].hand:
		if not bool(GameLogic.can_deploy(st, idx, card_id).get("ok", false)):
			continue
		var rows: Array = GameLogic.get_deployable_rows(st, idx, card_id)
		if rows.is_empty():
			continue
		var row: int = rows.max() if idx == 0 else rows.min()
		var card = CardDataLoader.cards[card_id]
		var layer := "air" if GameLogic._is_air_unit(str(card.unit_class)) else "ground"
		for col in [2, 1, 3, 0, 4]:
			if st.board.get_unit(row, int(col), layer) == null:
				return {"card_id": str(card_id), "row": row, "col": int(col)}
	return {}


func _pick_move(st: BattleState) -> Dictionary:
	var idx := st.active_player_index
	for each in _units_of(st, idx):
		var targets: Array = GameLogic.get_valid_move_targets(st, int(each[0]), int(each[1]))
		if targets.is_empty():
			continue
		var best: Vector2i = targets[0]
		var best_score := 999
		for t in targets:
			var score := _dist_to_enemy(st, idx, t)
			if score < best_score:
				best_score = score
				best = t
		return {"from_row": int(each[0]), "from_col": int(each[1]), "to_row": best.x, "to_col": best.y}
	return {}


func _pick_attack(st: BattleState) -> Dictionary:
	var idx := st.active_player_index
	for each in _units_of(st, idx):
		var targets: Array = GameLogic.get_valid_attack_targets(st, idx, int(each[0]), int(each[1]))
		if targets.is_empty():
			continue
		return {"from_row": int(each[0]), "from_col": int(each[1]), "target_row": int(targets[0].x), "target_col": int(targets[0].y)}
	return {}


func _will_kill(atk: Dictionary) -> bool:
	var st := tm.get_state()
	var u = st.board.get_unit(int(atk["target_row"]), int(atk["target_col"]))
	var a = st.board.get_unit(int(atk["from_row"]), int(atk["from_col"]))
	if u == null or a == null:
		return false
	return int(u.defense) - maxi(1, int(a.attack)) <= 0


func _dist_to_enemy(st: BattleState, idx: int, cell: Vector2i) -> int:
	var best := 99
	for r in st.board.rows:
		for c in st.board.cols:
			for layer in ["ground", "air"]:
				var u = st.board.get_unit(int(r), int(c), layer)
				if u != null and u.owner_index != idx:
					best = mini(best, absi(int(r) - cell.x) + absi(int(c) - cell.y))
	return best


func _units_of(st: BattleState, idx: int) -> Array:
	var out: Array = []
	for r in st.board.rows:
		for c in st.board.cols:
			for layer in ["ground", "air"]:
				var u = st.board.get_unit(int(r), int(c), layer)
				if u != null and u.owner_index == idx:
					out.append([int(r), int(c)])
	return out


func _submit(action: Dictionary) -> void:
	tm.submit_action(action)


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# ───────── 断言 ─────────
func check(label: String, ok: bool, detail := "") -> void:
	checks += 1
	if ok:
		print("  PASS: %s" % label)
	else:
		var line := "%s %s" % [label, detail]
		fails.append(line)
		print("  FAIL: %s" % line)


func _report() -> void:
	print("========== ANIM VERIFY ==========")
	print("Checks: %d, Failures: %d" % [checks, fails.size()])
	if fails.is_empty():
		print("ALL ANIM CHECKS PASSED (rounds used: %d)" % (rounds + 1))
	else:
		for f in fails:
			print("  - %s" % f)
		print("ANIM VERIFY FAILED")
