extends RefCounted
class_name ReplayStore

## 对局录像（复盘）— 纯数据结构，不含 UI / 网络
## 录像 = 操作日志（engine action_log，含 turn/phase/player 元数据）
##        + 每步操作后的精简棋盘快照（snapshots[0] = 开局，snapshots[i+1] = 第 i 步后）
## 上传服务器供双方赛后复盘：复盘数据取自服务器而非本端生成，本地无法伪造；
## 服务器 2 小时后过期删除（见 deploy/relay-server.js）。

const VERSION := 1


## 精简快照：复盘渲染所需的全部状态（不含 action_log）
static func make_snapshot(state: BattleState) -> Dictionary:
	var units: Array = []
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var u: BattleState.UnitData = state.board.get_unit(r, c)
			if u == null:
				continue
			units.append({"r": r, "c": c, "id": u.card_id, "o": u.owner_index,
				"a": u.attack, "d": u.defense, "md": u.max_defense})
	var players: Array = []
	for p in state.players:
		players.append({
			"res": {"G": p.resources["G"], "Z": p.resources["Z"], "K": p.resources["K"]},
			"hand": p.hand.duplicate(),
			"pz": p.purchase_zone.duplicate(),
		})
	return {
		"turn": state.turn,
		"phase": state.phase,
		"active": state.active_player_index,
		"winner": state.winner,
		"front": state.front_control.duplicate(),
		"players": players,
		"units": units,
	}


## 快照 → 可渲染 BattleState（供复盘 Board 显示局面；不含行为逻辑）
static func snapshot_to_state(snap: Dictionary) -> BattleState:
	var st := BattleState.new()
	var rows: int = clampi(int(snap.get("front", []).size()), 5, 7) if snap.has("front") else 5
	st.board = BattleState.BoardData.new()
	st.board.rows = rows
	st.board.cols = 5
	st.board._init_slots()
	st.turn = int(snap.get("turn", 1))
	st.phase = str(snap.get("phase", "action"))
	st.active_player_index = int(snap.get("active", 0))
	st.winner = int(snap.get("winner", -1))
	st.front_control.assign(snap.get("front", [0, 0, 0, 0, 0]))
	var players: Array = snap.get("players", [])
	while st.players.size() < 2:
		st.players.append(BattleState.PlayerData.new())
	for pi in range(2):
		var src: Dictionary = players[pi] if pi < players.size() else {}
		var res: Dictionary = src.get("res", {})
		st.players[pi].resources = {"G": int(res.get("G", 0)), "Z": int(res.get("Z", 0)), "K": int(res.get("K", 0))}
		var hand: Array = src.get("hand", [])
		var h: Array[String] = []
		h.assign(hand)
		st.players[pi].hand = h
		var pz: Array = src.get("pz", [])
		var z: Array[String] = []
		z.assign(pz)
		st.players[pi].purchase_zone = z
	for u in snap.get("units", []):
		var unit := BattleState.UnitData.new()
		unit.card_id = str(u.get("id", ""))
		unit.owner_index = int(u.get("o", 0))
		unit.attack = int(u.get("a", 0))
		unit.defense = int(u.get("d", 0))
		unit.max_defense = int(u.get("md", unit.defense))
		st.board.set_unit(int(u.get("r", 0)), int(u.get("c", 0)), unit)
	return st


## 组装完整录像。actions/snapshots 由 GameManager 在对局中逐步收集；
## initial_snapshot 是开局快照（成为 snapshots[0]）
static func build_replay(game_id: String, mode: String, winner: int,
		initial_snapshot: Dictionary, actions: Array, snapshots_after: Array) -> Dictionary:
	var rounds := 0
	if not snapshots_after.is_empty():
		rounds = int(snapshots_after[-1].get("turn", 1)) - 1
	var snapshots: Array = [initial_snapshot]
	snapshots.append_array(snapshots_after)
	return {
		"version": VERSION,
		"game_id": game_id,
		"mode": mode,
		"created_ms": Time.get_unix_time_from_system() * 1000.0,
		"winner": winner,
		"rounds": rounds,
		"actions": actions,
		"snapshots": snapshots,
	}


## 操作条目 → 中文描述（复盘列表文本）
## before = 该操作发生前的快照（用于查操作单位名；可空，退化为"单位"）
static func describe_action(a: Dictionary, before: Dictionary = {}) -> String:
	var t: String = str(a.get("type", ""))
	match t:
		"purchase":
			return "购买 %s" % _card_name(str(a.get("card_id", "")))
		"deploy":
			return "部署 %s 至 (%d, %d)" % [_card_name(str(a.get("card_id", ""))), int(a.get("row", 0)), int(a.get("col", 0))]
		"move":
			var f: Array = a.get("from", [0, 0])
			var to: Array = a.get("to", [0, 0])
			return "移动 %s (%d, %d) → (%d, %d)" % [_unit_label(a, before), f[0], f[1], to[0], to[1]]
		"attack":
			var f2: Array = a.get("from", [0, 0])
			var to2: Array = a.get("to", [0, 0])
			return "%s (%d, %d) 攻击 (%d, %d)，造成 %d 伤害" % [_unit_label(a, before), f2[0], f2[1], to2[0], to2[1], int(a.get("damage", 0))]
		"destroy":
			return "%s 被消灭" % _card_name(str(a.get("card_id", "")))
		"counter":
			return "反击，造成 %d 伤害" % int(a.get("damage", 0))
		"supply":
			return "补给：修复相邻友方 %d 点" % int(a.get("amount", 0))
		"rear_repair":
			return "后方修复 (%d, %d)" % [int(a.get("row", 0)), int(a.get("col", 0))]
		"end_turn":
			return "结束回合"
		"skip_phase":
			return "跳过阶段"
		_:
			return t


static func _card_name(card_id: String) -> String:
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data != null:
		return str(card_data.card_name)
	return card_id


## 攻击/移动描述中的单位名：操作前快照里按 from 坐标找，找不到退化为"单位"
static func _unit_label(a: Dictionary, before: Dictionary) -> String:
	var f: Array = a.get("from", [])
	if f.size() == 2:
		for u in before.get("units", []):
			if int(u.get("r", -1)) == int(f[0]) and int(u.get("c", -1)) == int(f[1]):
				return _card_name(str(u.get("id", "")))
	return "单位"


## 结算统计：从操作流精确推导双方数据（供结算菜单展示）
## g_spent = Σ 购买卡的经济G；z_spent = Σ(移动/攻击各1) + Σ(部署的战争点)
static func compute_stats(replay: Dictionary) -> Array:
	var stats := []
	for pi in range(2):
		stats.append({
			"deployed": 0, "kills": 0, "losses": 0, "purchases": 0,
			"g_spent": 0, "z_spent": 0, "moves": 0, "attacks": 0,
		})
	for a in replay.get("actions", []):
		var pi: int = int(a.get("player", -1))
		if pi < 0 or pi > 1:
			continue
		var t := str(a.get("type", ""))
		match t:
			"purchase":
				stats[pi]["purchases"] += 1
				var card_data: Resource = CardDataLoader.cards.get(str(a.get("card_id", "")))
				if card_data != null:
					stats[pi]["g_spent"] += int(card_data.cost_g)
			"deploy":
				stats[pi]["deployed"] += 1
				var card_data2: Resource = CardDataLoader.cards.get(str(a.get("card_id", "")))
				if card_data2 != null:
					stats[pi]["z_spent"] += int(card_data2.cost_z)
			"move":
				stats[pi]["moves"] += 1
				stats[pi]["z_spent"] += 1
			"attack":
				stats[pi]["attacks"] += 1
				stats[pi]["z_spent"] += 1
			"destroy":
				# engine 语义：destroy 条目的 player = 击杀方
				var killer: int = int(a.get("player", -1))
				if killer >= 0 and killer <= 1:
					stats[killer]["kills"] += 1
					stats[1 - killer]["losses"] += 1
	return stats


## 复盘左树分组：按完整回合 → 阶段 → 操作
## viewer_idx：本地玩家（决定"我方/敌方"措辞）；named_players：本地同屏用 "玩家1/玩家2"
## 返回结构：[{turn, side, label, snapshot_idx(回合起始快照), phases:[{phase,label,actions:[{idx,text}]}]}]
static func group_actions(replay: Dictionary, viewer_idx: int, named_players: bool) -> Array:
	var rounds: Array = []
	var actions: Array = replay.get("actions", [])
	for i in range(actions.size()):
		var a: Dictionary = actions[i]
		var turn: int = int(a.get("turn", 1))
		var player: int = int(a.get("player", 0))
		var phase: String = str(a.get("phase", "action"))
		var side_label: String
		if named_players:
			side_label = "玩家%d 第%d回合" % [player + 1, turn]
		else:
			side_label = ("我方" if player == viewer_idx else "敌方") + " 第%d回合" % turn
		var grp: Dictionary = {}
		for g in rounds:
			if int(g["turn"]) == turn and int(g["side"]) == player:
				grp = g
				break
		if grp.is_empty():
			grp = {"turn": turn, "side": player, "label": side_label, "snapshot_idx": i, "phases": []}
			rounds.append(grp)
		var phase_label: String = {"purchase": "购买", "deploy": "部署", "action": "行动"}.get(phase, phase)
		var ph: Dictionary = {}
		for p2 in grp["phases"]:
			if str(p2["phase"]) == phase:
				ph = p2
				break
		if ph.is_empty():
			ph = {"phase": phase, "label": phase_label, "actions": []}
			grp["phases"].append(ph)
		ph["actions"].append({"idx": i, "text": describe_action(a, replay.get("snapshots", [])[i] if i < replay.get("snapshots", []).size() else {})})
	return rounds
