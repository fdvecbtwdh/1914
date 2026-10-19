extends Node2D

## 一次性视觉验证脚本（不参与 CI）：本地开局 → 简单攻防推进 → 在动画中途/结束后截图。
## 用法：godot --path . --windowed --resolution 1280x720 res://tests/anim_shots.tscn

const OUT := "res://.anim_shots"

var battle: Node = null
var tm: TurnManager = null
var board: Board = null
var hand: HandManager = null
var shots := {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	clear_old()
	await get_tree().process_frame   # 先让 GameManager._auto_enter 跑过（此时 current_scene 是本场景，不会接线）
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
	if tm == null:
		printerr("[shots] no turn manager")
		get_tree().quit()
		return
	print("[shots] start: ", _dump(tm.get_state()))
	await shot("00_start")
	await _run()
	print("[shots] captured: ", str(shots))
	print("[shots] DONE")
	get_tree().quit()


func clear_old() -> void:
	var dir := DirAccess.open(OUT)
	if dir == null:
		return
	for f in dir.get_files():
		if f.ends_with(".png"):
			dir.remove(f)


func _run() -> void:
	for round_i in 40:
		var st := tm.get_state()
		if st == null or st.winner != -1:
			break
		print("[shots] round %d | %s" % [round_i, _dump(st)])
		# ── 购买阶段 ──
		if st.phase == "purchase":
			var offer := _pick_offer(st)
			if offer != "":
				_submit({"type": "purchase", "card_id": offer})
				await _maybe_shot("01_purchase", 5, 26)
			else:
				await frames(2)
		# ── 部署阶段 ──
		if tm.get_state().phase == "purchase":
			_submit({"type": "skip_phase"})
			await frames(3)
		var dep := _pick_deploy(tm.get_state())
		while not dep.is_empty():
			_submit({"type": "deploy", "card_id": dep["card_id"], "row": dep["row"], "col": dep["col"]})
			await _maybe_shot("03_deploy", 5, 24)
			dep = _pick_deploy(tm.get_state())
		if tm.get_state().phase == "deploy":
			_submit({"type": "skip_phase"})
			await frames(3)
		# ── 行动阶段：先打，再走 ──
		var atk := _pick_attack(tm.get_state())
		if not atk.is_empty():
			var tgt_gone := _will_kill(atk)
			_submit({"type": "attack", "from_row": atk["from_row"], "from_col": atk["from_col"],
				"target_row": atk["target_row"], "target_col": atk["target_col"]})
			await _maybe_shot("06_attack", 4, 24)
			if tgt_gone:
				await _maybe_shot("06b_destroy", 6, 24)
		var mv := _pick_move(tm.get_state())
		if not mv.is_empty():
			_submit({"type": "move", "from_row": mv["from_row"], "from_col": mv["from_col"],
				"to_row": mv["to_row"], "to_col": mv["to_col"]})
			await _maybe_shot("05_move", 6, 26)
		# ── 结束回合 ──
		if tm.get_state().phase == "action":
			_submit({"type": "end_turn"})
			await _maybe_shot("07_end_turn", 8, 30)
		else:
			await frames(4)
	print("[shots] last: ", _dump(tm.get_state()))


func _will_kill(atk: Dictionary) -> bool:
	var st := tm.get_state()
	var u = st.board.get_unit(int(atk["target_row"]), int(atk["target_col"]))
	var a = st.board.get_unit(int(atk["from_row"]), int(atk["from_col"]))
	if u == null or a == null:
		return false
	var dmg: int = maxi(1, int(a.attack) - int(u.firm_level) - _fort_bonus(st, u))
	return int(u.defense) - dmg <= 0


func _fort_bonus(st: BattleState, u) -> int:
	var code := 0
	if u.has_method("get_fort_bonus"):
		return int(u.get_fort_bonus())
	return code


func _maybe_shot(name: String, mid: int, settle: int) -> void:
	if not shots.has(name):
		shots[name] = true
		await shot(name + "_mid", mid)
		await shot(name + "_end", settle)
	else:
		await frames(4)


func _submit(action: Dictionary) -> void:
	tm.submit_action(action)
	print("[shots] submit ", action)


func _pick_offer(st: BattleState) -> String:
	var p = st.players[st.active_player_index]
	for card_id in p.purchase_zone:
		var card = CardDataLoader.cards.get(card_id)
		if card == null:
			continue
		if int(p.resources["G"]) < int(card.cost_g):
			continue
		var rarity := str(card.rarity)
		if int(p.purchases_this_turn.get(rarity, 0)) >= int(GameLogic.PURCHASE_LIMITS.get(rarity, 99)):
			continue
		if str(card.type) != "unit":
			continue
		return str(card_id)
	return ""


func _pick_deploy(st: BattleState) -> Dictionary:
	var idx := st.active_player_index
	var p = st.players[idx]
	for card_id in p.hand:
		var check: Dictionary = GameLogic.can_deploy(st, idx, card_id)
		if not bool(check.get("ok", false)):
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
		var t: Vector2i = targets[0]
		return {"from_row": int(each[0]), "from_col": int(each[1]),
			"target_row": int(t.x), "target_col": int(t.y)}
	return {}


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


func _dump(st: BattleState) -> String:
	if st == null:
		return "<null>"
	var p = st.players[st.active_player_index]
	return "turn=%d phase=%s active=%d winner=%d res=%s hand=%s" % [
		st.turn, st.phase, st.active_player_index, st.winner, str(p.resources), str(p.hand)]


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func shot(name: String, wait := 0) -> void:
	await frames(wait)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT, name]
	var err := img.save_png(path)
	print("[shots] save ", path, " err=", err)
