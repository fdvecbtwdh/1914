extends RefCounted
class_name GameEffects

## 6A 效果执行器 — 解释卡牌数据中的声明式效果（纯函数语义：接收 state 并就地修改）
## 效果以 JSON Dictionary 声明，op 字段选择原语；随机使用状态确定性 RNG（联机一致、测试可复现）
##
## ctx（上下文）：{owner_idx: int, source_unit: UnitData?, src_row: int, src_col: int, target_row: int, target_col: int}
## 常见 op：
##   suppress        {target: "enemy"|"enemy_row", count: n}          压制
##   buff            {scope: "self"|"friendly_field", filter: {...}, atk, def}  属性增减
##   economy         {who: "self"|"enemy"|"friendly"|"target_owner", amount: n} 经济变动
##   spawn           {card_id, count, where: "rear_line"|"hand"|"shop"|"field", row?, col?, mods:{atk,def}}
##   transform       {to, keep_position: true}                        亡计/入场转化
##   shop_transform  {from_card, to_card}                             商店中转化
##   shop_buff       {filter: {nation, unit_class}, atk, def}         商店卡牌模板增强（card_mods）
##   modify_card     {card_id, atk, def}                              卡牌模板修改（card_mods）
##   reveal_stealth  {count: n}                                       揭示敌方潜行单位
##   random          {branches: [{weight: n, actions: [...]}]}        加权随机分支
##   damage          {target: "enemy"|"context", amount: n}           直接伤害
##   destroy_random  {max_cost: n}                                    随机消灭费用≤n 的敌方单位
##   retreat_random  {}                                               随机使一个敌方单位后退
##   filter 字段：{ability: "响应", nation: "german_empire", unit_class: "tank", excludes_self: true}


## 执行一组效果（顺序结算）
static func run_effects(state: BattleState, effects: Array, ctx: Dictionary) -> void:
	for e in effects:
		if e is Dictionary:
			run_effect(state, e, ctx)


## 执行单个效果
static func run_effect(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var op: String = str(e.get("op", ""))
	match op:
		"suppress":
			_do_suppress(state, e, ctx)
		"buff":
			_do_buff(state, e, ctx)
		"economy":
			_do_economy(state, e, ctx)
		"spawn":
			_do_spawn(state, e, ctx)
		"transform":
			_do_transform(state, e, ctx)
		"shop_transform":
			_do_shop_transform(state, e, ctx)
		"shop_buff":
			_do_shop_buff(state, e, ctx)
		"modify_card":
			_do_modify_card(state, e)
		"reveal_stealth":
			_do_reveal_stealth(state, e, ctx)
		"random":
			_do_random(state, e, ctx)
		"damage":
			_do_damage(state, e, ctx)
		"destroy_random":
			_do_destroy_random(state, e, ctx)
		"retreat_random":
			_do_retreat_random(state, e, ctx)
		"debuff_target":
			_do_debuff_target(state, e, ctx)
		"economy_per_friendly":
			_do_economy_per_friendly(state, e, ctx)
		"suppress_area":
			_do_suppress_area(state, e, ctx)
		"destroy_self":
			_do_destroy_self(state, e, ctx)
		"add_to_hand":
			_do_add_to_hand(state, e, ctx)
		_:
			printerr("[GameEffects] unknown op: %s (recorded, skipped)" % op)
			# 未知效果不中断对局——记入日志便于发现卡牌数据问题


## ── 触发器查找与触发 ──

## 状态确定性 RNG：同状态同 salt → 同结果（联机两端一致）
static func state_rand(state: BattleState, salt: String) -> int:
	return absi(hash([state.turn, state.action_log.size(), salt]))


## 找出满足 filter 的单位（scope: field 两层全场 / friendly_field 己方 / enemy_field 敌方）
static func collect_units(state: BattleState, owner_idx: int, scope: String, filter: Dictionary, exclude_unit: BattleState.UnitData = null) -> Array:
	var out: Array = []
	var want_owner := -1
	if scope == "friendly_field":
		want_owner = owner_idx
	elif scope == "enemy_field":
		want_owner = 1 - owner_idx
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u == null or u == exclude_unit:
					continue
				if want_owner != -1 and u.owner_index != want_owner:
					continue
				if _matches_filter(state, u, filter):
					out.append({"unit": u, "row": r, "col": c, "layer": layer})
	return out


static func _matches_filter(state: BattleState, unit: BattleState.UnitData, filter: Dictionary) -> bool:
	if filter.is_empty():
		return true
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	var cls: String = card_data.unit_class if card_data != null else ""
	var nation: String = card_data.nation if card_data != null else ""
	if filter.has("ability") and not unit.abilities.has(str(filter["ability"])):
		return false
	if filter.has("nation") and nation != str(filter["nation"]):
		return false
	if filter.has("unit_class") and cls != str(filter["unit_class"]):
		return false
	if filter.has("max_cost") and card_data != null and card_data.cost_g > int(filter["max_cost"]):
		return false
	if filter.has("class_in") and not (cls in filter["class_in"]):
		return false
	if filter.has("card_id_prefix") and not unit.card_id.begins_with(str(filter["card_id_prefix"])):
		return false
	return true


## 模板数值（应用 card_mods）
static func template_atk(state: BattleState, card_id: String) -> int:
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	var base: int = card_data.attack if card_data != null else 0
	var mods: Dictionary = state.card_mods.get(card_id, {})
	return base + int(mods.get("atk", 0))


static func template_def(state: BattleState, card_id: String) -> int:
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	var base: int = card_data.defense if card_data != null else 0
	var mods: Dictionary = state.card_mods.get(card_id, {})
	return base + int(mods.get("def", 0))


## ── 原语实现 ──

static func _do_suppress(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var count: int = int(e.get("count", 1))
	var target_scope: String = str(e.get("target", "enemy_line"))
	# 目标：优先 ctx 指定行的敌方（enemy_line），count 很大视为全线压制
	var victims := collect_units(state, ctx.get("owner_idx", 0), "enemy_field", {}, null)
	if victims.is_empty():
		return
	if target_scope == "enemy_field":
		for v in victims:
			v["unit"].suppressed = true
		return
	var row: int = int(ctx.get("target_row", ctx.get("src_row", -1)))
	var in_row: Array = victims.filter(func(v): return v["row"] == row)
	if not in_row.is_empty():
		victims = in_row
	for i in range(min(count, victims.size())):
		victims[i]["unit"].suppressed = true


static func _do_buff(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var scope: String = str(e.get("scope", "friendly_field"))
	var filter: Dictionary = e.get("filter", {})
	var atk: int = int(e.get("atk", 0))
	var def: int = int(e.get("def", 0))
	if scope == "self":
		# self：只加强来源单位自身
		var su: BattleState.UnitData = ctx.get("source_unit", null)
		if su != null:
			su.attack += atk
			su.defense += def
			su.max_defense = max(su.max_defense, su.defense)
		return
	var targets := collect_units(state, ctx.get("owner_idx", 0), scope, filter, ctx.get("source_unit", null))
	for t in targets:
		t["unit"].attack += atk
		t["unit"].defense += def
		t["unit"].max_defense = max(t["unit"].max_defense, t["unit"].defense)


static func _do_economy(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var who: String = str(e.get("who", "enemy"))
	var amount: int = int(e.get("amount", 0))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var target_player := owner_idx
	match who:
		"enemy":
			target_player = 1 - owner_idx
		"self":
			target_player = owner_idx
		"friendly":
			target_player = owner_idx
		"target_owner":
			var t := state.board.get_unit(int(ctx.get("target_row", -1)), int(ctx.get("target_col", -1)))
			target_player = t.owner_index if t != null else owner_idx
	var res: Dictionary = state.players[target_player].resources
	res["G"] = maxi(0, res["G"] + amount)


static func _do_spawn(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var card_id: String = str(e.get("card_id", ""))
	var count: int = int(e.get("count", 1))
	var where: String = str(e.get("where", "rear_line"))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data == null:
		printerr("[GameEffects] spawn: unknown card %s" % card_id)
		return
	var atk_mod: int = int(e.get("mods", {}).get("atk", 0))
	var def_mod: int = int(e.get("mods", {}).get("def", 0))
	for i in range(count):
		match where:
			"hand":
				state.players[owner_idx].hand.append(card_id)  # 加入手牌不受手牌上限限制（6A）
			"shop":
				state.players[owner_idx].purchase_zone.append(card_id)
			"rear_line":
				var back_row := 0 if owner_idx == 0 else state.board.rows - 1
				var spawned := _spawn_on_line(state, owner_idx, card_id, back_row, atk_mod, def_mod)
				if not spawned:
					# 底线满：退而求其次相邻行
					var alt := back_row + (1 if owner_idx == 0 else -1)
					_spawn_on_line(state, owner_idx, card_id, alt, atk_mod, def_mod)
			"field":
				var layer := "air" if _is_air_card(card_id) else "ground"
				var row: int = int(e.get("row", ctx.get("src_row", 0)))
				var col: int = int(e.get("col", ctx.get("src_col", 0)))
				if state.board.get_unit(row, col, layer) == null:
					var u := _make_unit(state, card_id, owner_idx, atk_mod, def_mod)
					state.board.set_unit(row, col, u, layer)
					GameEffects._post_spawn(state, u, row, col, layer)


static func _spawn_on_line(state: BattleState, owner_idx: int, card_id: String, row: int, atk_mod: int, def_mod: int) -> bool:
	if row < 0 or row >= state.board.rows:
		return false
	var layer := "air" if _is_air_card(card_id) else "ground"
	for c in range(state.board.cols):
		if state.board.get_unit(row, c, layer) == null:
			var u := _make_unit(state, card_id, owner_idx, atk_mod, def_mod)
			state.board.set_unit(row, c, u, layer)
			_post_spawn(state, u, row, c, layer)
			return true
	return false


static func _is_air_card(card_id: String) -> bool:
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	return card_data != null and (card_data.unit_class == "fighter" or card_data.unit_class == "bomber")


static func _make_unit(state: BattleState, card_id: String, owner_idx: int, atk_mod: int, def_mod: int) -> BattleState.UnitData:
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	var u := BattleState.UnitData.new()
	u.card_id = card_id
	u.owner_index = owner_idx
	u.attack = template_atk(state, card_id) + atk_mod
	u.defense = template_def(state, card_id) + def_mod
	u.max_defense = u.defense
	u.abilities = card_data.abilities.duplicate() if card_data != null else []
	u.deployed_this_turn = true
	return u


## 生成后接线（触发 on_deploy 等）
static func _post_spawn(state: BattleState, unit: BattleState.UnitData, row: int, col: int, layer: String) -> void:
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	if card_data != null and card_data.triggers.has("on_deploy"):
		var ctx := {"owner_idx": unit.owner_index, "source_unit": unit, "src_row": row, "src_col": col}
		run_effects(state, card_data.triggers["on_deploy"], ctx)


static func _do_transform(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var to: String = str(e.get("to", ""))
	var src: BattleState.UnitData = ctx.get("source_unit", null)
	if src == null or CardDataLoader.cards.get(to) == null:
		return
	# 保留位置/阵营；属性按目标模板 + card_mods；行动状态重置
	var card_data: Resource = CardDataLoader.cards.get(to)
	src.card_id = to
	src.attack = template_atk(state, to)
	src.defense = template_def(state, to)
	src.max_defense = src.defense
	src.abilities = card_data.abilities.duplicate() if card_data != null else []
	src.has_acted = false
	src.has_attacked = false
	src.deployed_this_turn = false
	src.suppressed = false
	src.patrolling = false
	# 亡计转化：单位已从棋盘移除 → 重新放回原位（保留位置是转化的核心语义）
	var layer := "air" if src.is_air else "ground"
	if state.board.get_unit(src.row, src.col, layer) == null:
		state.board.set_unit(src.row, src.col, src, layer)


static func _do_shop_transform(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var from_card: String = str(e.get("from_card", ""))
	var to_card: String = str(e.get("to_card", ""))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var zone: Array = state.players[owner_idx].purchase_zone
	for i in range(zone.size()):
		if str(zone[i]) == from_card:
			zone[i] = to_card


static func _do_shop_buff(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	# 商店中符合 filter 的卡牌获得模板加成 → 记入 card_mods（该玩家视角；简化为双方共用模板）
	var filter: Dictionary = e.get("filter", {})
	var atk: int = int(e.get("atk", 0))
	var def: int = int(e.get("def", 0))
	for card_id in CardDataLoader.cards:
		var card_data: Resource = CardDataLoader.cards[card_id]
		var probe := BattleState.UnitData.new()
		probe.card_id = card_id
		probe.abilities = card_data.abilities
		if _matches_filter(state, probe, filter):
			var mods: Dictionary = state.card_mods.get(card_id, {})
			mods["atk"] = int(mods.get("atk", 0)) + atk
			mods["def"] = int(mods.get("def", 0)) + def
			state.card_mods[card_id] = mods


static func _do_modify_card(state: BattleState, e: Dictionary) -> void:
	var card_id: String = str(e.get("card_id", ""))
	if card_id == "":
		return
	var mods: Dictionary = state.card_mods.get(card_id, {})
	mods["atk"] = int(mods.get("atk", 0)) + int(e.get("atk", 0))
	mods["def"] = int(mods.get("def", 0)) + int(e.get("def", 0))
	state.card_mods[card_id] = mods


static func _do_reveal_stealth(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var count: int = int(e.get("count", 1))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var done := 0
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				if done >= count:
					return
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u != null and u.owner_index != owner_idx and u.stealthed and not u.revealed:
					u.revealed = true
					done += 1


static func _do_random(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var branches: Array = e.get("branches", [])
	if branches.is_empty():
		return
	var total := 0
	for b in branches:
		total += int(b.get("weight", 1))
	var roll := state_rand(state, str(e.get("salt", "rand"))) % maxi(1, total)
	for b in branches:
		roll -= int(b.get("weight", 1))
		if roll < 0:
			run_effects(state, b.get("actions", []), ctx)
			return


static func _do_damage(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var amount: int = int(e.get("amount", 1))
	var row: int = int(ctx.get("target_row", -1))
	var col: int = int(ctx.get("target_col", -1))
	var u := state.board.get_unit(row, col)
	if u == null:
		u = state.board.get_unit(row, col, "air")
	if u == null:
		return
	u.defense -= amount
	if u.defense <= 0:
		GameLogic.destroy_unit(state, row, col, "air" if u.is_air else "ground", ctx.get("owner_idx", 0))


static func _do_destroy_random(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var max_cost: int = int(e.get("max_cost", 999))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var filter: Dictionary = {"max_cost": max_cost}
	var victims := collect_units(state, owner_idx, "enemy_field", filter, null)
	if victims.is_empty():
		return
	var pick: Dictionary = victims[state_rand(state, "destroy_random") % victims.size()]
	GameLogic.destroy_unit(state, pick["row"], pick["col"], pick["layer"], owner_idx)


static func _do_retreat_random(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var victims := collect_units(state, owner_idx, "enemy_field", {}, null)
	if victims.is_empty():
		return
	var pick: Dictionary = victims[state_rand(state, "retreat_random") % victims.size()]
	# 强制后退一格（朝己方后方）；无路可退则原地受 1 点压制伤害（裁定：退无可退受 1 伤）
	var v: BattleState.UnitData = pick["unit"]
	var back_row: int = pick["row"] + (1 if v.owner_index == 0 else -1)
	var layer: String = pick["layer"]
	if back_row >= 0 and back_row < state.board.rows and state.board.get_unit(back_row, pick["col"], layer) == null:
		state.board.set_unit(pick["row"], pick["col"], null, layer)
		state.board.set_unit(back_row, pick["col"], v, layer)
	else:
		v.defense -= 1
		if v.defense <= 0:
			GameLogic.destroy_unit(state, pick["row"], pick["col"], layer, owner_idx)


## ── 触发器发射（由 GameLogic 在事件点调用）──

## 发射单位自身触发器。数据结构：triggers[name] = {actions: [...], once_per_turn: bool, condition: {...}}
static func fire_unit_trigger(state: BattleState, unit: BattleState.UnitData, row: int, col: int, layer: String, trigger_name: String, extra_ctx: Dictionary = {}) -> void:
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	if card_data == null or not card_data.triggers.has(trigger_name):
		return
	var trig: Dictionary = card_data.triggers[trigger_name]
	var actions: Array = trig.get("actions", [])
	if actions.is_empty():
		return
	# condition：如 {"target_class_in": [...]} 检查受伤目标兵种（on_damage_dealt 场景）
	var cond: Dictionary = trig.get("condition", {})
	if cond.has("target_class_in"):
		var tu: BattleState.UnitData = extra_ctx.get("target_unit", null)
		var ok_class := false
		if tu != null:
			var tcd: Resource = CardDataLoader.cards.get(tu.card_id)
			if tcd != null and str(tcd.unit_class) in cond["target_class_in"]:
				ok_class = true
		if not ok_class:
			return
	# filter：如 {"enemy_nation": "..."} 检查敌方主国（on_death 场景）
	var ev_filter: Dictionary = trig.get("filter", {})
	if ev_filter.has("enemy_nation"):
		var enemy := 1 - unit.owner_index
		# 敌方主国以对方起始卡组的 nation 简化判定：取场上任意敌方单位的 nation
		var enemy_nation := ""
		for scan_layer in ["ground", "air"]:
			for r in range(state.board.rows):
				for c in range(state.board.cols):
					var o: BattleState.UnitData = state.board.get_unit(r, c, scan_layer)
					if o != null and o.owner_index == enemy:
						var ocd: Resource = CardDataLoader.cards.get(o.card_id)
						if ocd != null:
							enemy_nation = ocd.nation
							break
		if enemy_nation != str(ev_filter["enemy_nation"]):
			return
	# once_per_turn：按「触发名@坐标」记录已触发回合
	if bool(trig.get("once_per_turn", false)):
		var key := "%s@%d,%d" % [trigger_name, row, col]
		if int(unit.trigger_log.get(key, -1)) == state.turn:
			return
		unit.trigger_log[key] = state.turn
	var ctx := {"owner_idx": unit.owner_index, "source_unit": unit, "src_row": row, "src_col": col, "trigger": trigger_name}
	ctx.merge(extra_ctx, true)
	run_effects(state, actions, ctx)


## 发射场上其他单位的响应式触发（如 on_friendly_deploy，带 filter 匹配触发条件中的事件单位）
static func fire_others_trigger(state: BattleState, event_unit: BattleState.UnitData, event_row: int, trigger_name: String) -> void:
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u == null or u == event_unit:
					continue
				var card_data: Resource = CardDataLoader.cards.get(u.card_id)
				if card_data == null or not card_data.triggers.has(trigger_name):
					continue
				var trig: Dictionary = card_data.triggers[trigger_name]
				var filter: Dictionary = trig.get("filter", {})
				# filter 匹配事件单位（如 {"nation": "german_empire"} = 友方德国单位部署时）
				if not filter.is_empty():
					var ev_card: Resource = CardDataLoader.cards.get(event_unit.card_id)
					if ev_card == null:
						continue
					if filter.has("nation") and ev_card.nation != str(filter["nation"]):
						continue
					if filter.has("unit_class") and ev_card.unit_class != str(filter["unit_class"]):
						continue
				var actions: Array = trig.get("actions", [])
				var ctx := {"owner_idx": u.owner_index, "source_unit": u, "src_row": r, "src_col": c, "event_unit": event_unit}
				run_effects(state, actions, ctx)


## 目标单位属性增减（on_damage_dealt 类触发的目标 debuff）
static func _do_debuff_target(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var t: BattleState.UnitData = ctx.get("target_unit", null)
	if t == null:
		return
	t.attack += int(e.get("atk", 0))
	t.defense += int(e.get("def", 0))


## 按友方单位数量施加经济压制（齐柏林 L11：每有友方齐柏林，敌失去 25，上限 8 次）
static func _do_economy_per_friendly(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var filter: Dictionary = e.get("filter", {})
	var per: int = int(e.get("per", 25))
	var cap: int = int(e.get("cap", 8))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	var src_u: BattleState.UnitData = ctx.get("source_unit", null)
	var count := 0
	for layer in ["ground", "air"]:
		for r in range(state.board.rows):
			for c in range(state.board.cols):
				var u: BattleState.UnitData = state.board.get_unit(r, c, layer)
				if u != null and u.owner_index == owner_idx and u != src_u and _matches_filter(state, u, filter):
					count += 1
	var enemy := 1 - owner_idx
	state.players[enemy].resources["G"] = maxi(0, state.players[enemy].resources["G"] - per * mini(count, cap))


## 压制目标左右两格（柯斯达迫击炮：压制被攻击目标同行的相邻单位）
static func _do_suppress_area(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var row: int = int(ctx.get("target_row", -1))
	var center: int = int(ctx.get("target_col", -1))
	if row < 0 or center < 0:
		return
	for dc in [-1, 0, 1]:
		var u: BattleState.UnitData = state.board.get_unit(row, center + dc)
		if u != null:
			u.suppressed = true


## 消灭自身（齐柏林 L70 失去战线时自毁）
static func _do_destroy_self(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var u: BattleState.UnitData = ctx.get("source_unit", null)
	if u == null:
		return
	var layer := "air" if u.is_air else "ground"
	GameLogic.destroy_unit(state, u.row, u.col, layer, 1 - u.owner_index)


## 将指定卡牌加入手牌（数量 count）
static func _do_add_to_hand(state: BattleState, e: Dictionary, ctx: Dictionary) -> void:
	var card_id: String = str(e.get("card_id", ""))
	var count: int = int(e.get("count", 1))
	var owner_idx: int = int(ctx.get("owner_idx", 0))
	for i in range(count):
		state.players[owner_idx].hand.append(card_id)
