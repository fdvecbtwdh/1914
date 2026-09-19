extends Node2D
class_name Board

## 棋盘渲染 — 从 BattleState 读取数据，渲染格子和单位

const GRID_SIZE: int = 5
const SLOT_SPACING: Vector2 = Vector2(90, 115)
const SLOT_SIZE: Vector2 = Vector2(80, 100)

## 右侧面板预留宽度（HandManager 的购买区/手牌区域）
const RIGHT_PANEL_WIDTH: float = 280.0
const PANEL_GAP: float = 20.0

## 高亮颜色
const HIGHLIGHT_DEPLOY := Color(0.2, 0.8, 0.2, 0.35)   # 绿色 — 可部署
const HIGHLIGHT_MOVE   := Color(0.2, 0.6, 1.0, 0.35)   # 蓝色 — 可移动
const HIGHLIGHT_ATTACK := Color(1.0, 0.6, 0.1, 0.50)   # 橙色 — 可攻击
const HIGHLIGHT_SELECT := Color(1.0, 0.85, 0.2, 0.40)   # 金色 — 已选中

signal slot_clicked(row: int, col: int)
signal move_requested(from_row: int, from_col: int, to_row: int, to_col: int)
signal attack_requested(from_row: int, from_col: int, target_row: int, target_col: int)

var turn_manager: TurnManager = null
var _unit_displays: Dictionary = {}
var _grid_offset: Vector2 = Vector2.ZERO
var _selected_unit_pos: Vector2i = Vector2i(-1, -1)
var _p1_marker: Label = null
var _p2_marker: Label = null

## 格子级迷雾（docs/game-mechanics.md 4.1）：不可见格子全部覆盖
var _fog_layer: Control = null
var _fog_rects: Dictionary = {}   # {Vector2i: ColorRect}
## 战线占领度行标签（docs/game-mechanics.md 第 5 节）
var _front_labels: Array[Label] = []

## 复盘模式：无迷雾，全图局面公开显示（结算后复盘界面用）
var review_mode := false


func _ready() -> void:
	print("[Board] Ready — waiting for TurnManager")
	_recalc_grid_offset()
	_create_board()
	_create_fog_layer()
	_create_front_labels()
	get_tree().root.size_changed.connect(_on_window_resized)


func setup(tm: TurnManager) -> void:
	turn_manager = tm
	turn_manager.state_changed.connect(_on_state_changed)


func _recalc_grid_offset() -> void:
	var vs := get_viewport().get_visible_rect().size
	var grid_w := GRID_SIZE * SLOT_SPACING.x
	var grid_h := GRID_SIZE * SLOT_SPACING.y
	var total_w := grid_w + PANEL_GAP + RIGHT_PANEL_WIDTH
	_grid_offset.x = (vs.x - total_w) / 2.0
	_grid_offset.y = max(50.0, (vs.y - grid_h) / 2.0)


func _on_window_resized() -> void:
	_recalc_grid_offset()
	_reposition_all_slots()
	_reposition_markers()
	_reposition_fog_and_labels()
	if turn_manager and turn_manager.battle_state:
		_on_state_changed(turn_manager.battle_state)


func _reposition_markers() -> void:
	if _p1_marker:
		_p1_marker.position = Vector2(_grid_offset.x, _grid_offset.y - 22)
	if _p2_marker:
		var bottom_y := _grid_offset.y + GRID_SIZE * SLOT_SPACING.y + 6
		_p2_marker.position = Vector2(_grid_offset.x, bottom_y)


func _reposition_all_slots() -> void:
	for slot in get_tree().get_nodes_in_group("board_slot"):
		slot.position = _grid_offset + Vector2(slot.slot_col * SLOT_SPACING.x, slot.slot_row * SLOT_SPACING.y)


func _create_board() -> void:
	var slot_scene = load("res://scenes/ui_components/board_slot.tscn")
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var slot = slot_scene.instantiate()
			slot.slot_row = row
			slot.slot_col = col
			slot.position = _grid_offset + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
			add_child(slot)
	print("[Board] Created %d slots" % (GRID_SIZE * GRID_SIZE))
	_create_markers()


func _create_markers() -> void:
	# P1 标记 — 棋盘左上角外侧
	_p1_marker = Label.new()
	_p1_marker.text = "▲ 玩家 1"
	_p1_marker.add_theme_font_size_override("font_size", 13)
	_p1_marker.add_theme_color_override("font_color", Color(0.4, 0.65, 1.0, 1.0))
	_p1_marker.position = Vector2(_grid_offset.x, _grid_offset.y - 22)
	add_child(_p1_marker)

	# P2 标记 — 棋盘左下角外侧
	_p2_marker = Label.new()
	_p2_marker.text = "▼ 玩家 2"
	_p2_marker.add_theme_font_size_override("font_size", 13)
	_p2_marker.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5, 1.0))
	var bottom_y := _grid_offset.y + GRID_SIZE * SLOT_SPACING.y + 6
	_p2_marker.position = Vector2(_grid_offset.x, bottom_y)
	add_child(_p2_marker)


## 视角玩家：本地同屏=当前行动方；联网=本地玩家（对手回合己方单位不能被当成"敌方"）
func _viewer_idx(state: BattleState) -> int:
	if NetworkManager.is_network_game:
		return NetworkManager.local_player_idx
	return state.active_player_index


func _on_state_changed(new_state: BattleState) -> void:
	_deselect_unit()
	_clear_unit_displays()
	if new_state == null:
		return
	_update_markers(new_state.active_player_index)
	_render_units(new_state)
	_update_visibility(new_state)
	_update_front_labels(new_state)


func _update_markers(active_idx: int) -> void:
	if _p1_marker == null or _p2_marker == null:
		return
	if active_idx == 0:
		_p1_marker.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 1.0))  # 绿色 = 当前回合
		_p1_marker.text = "▲ 玩家 1 ◀"
		_p2_marker.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5, 1.0))
		_p2_marker.text = "▼ 玩家 2"
	else:
		_p2_marker.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 1.0))
		_p2_marker.text = "▼ 玩家 2 ◀"
		_p1_marker.add_theme_color_override("font_color", Color(0.4, 0.65, 1.0, 1.0))
		_p1_marker.text = "▲ 玩家 1"


func _clear_unit_displays() -> void:
	for display in _unit_displays.values():
		if is_instance_valid(display):
			display.queue_free()
	_unit_displays.clear()


func _render_units(state: BattleState) -> void:
	# 1.2 陆空双层渲染：地面层原位，空域层右上偏移并加 ✈ 标识
	for layer in ["ground", "air"]:
		for row in range(state.board.rows):
			for col in range(state.board.cols):
				var unit: BattleState.UnitData = state.board.get_unit(row, col, layer)
				if unit == null:
					continue
				var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
				if card_data == null:
					continue
				var display := spawn_card(card_data)
				display.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 棋盘单位不可拖拽（状态驱动渲染）
				var pos := _grid_offset + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
				var is_air: bool = layer == "air"
				if is_air:
					pos += Vector2(26, -18)  # 空军叠在陆军格上方，错位显示
				display.position = pos
				# 己方原色，敌方微偏红（联网按本地玩家视角）；空军加浅蓝调
				var viewer := _viewer_idx(state)
				var base := Color(0.3, 0.4, 0.5, 1.0) if unit.owner_index == viewer else Color(0.48, 0.3, 0.32, 1.0)
				if is_air:
					base = Color(0.3, 0.45, 0.62, 1.0) if unit.owner_index == viewer else Color(0.42, 0.34, 0.5, 1.0)
				_set_card_bg(display, base)
				_update_unit_stats(display, unit.attack, unit.defense)
				if is_air:
					_add_air_marker(display)
				_update_unit_tags(display, unit)
				add_child(display)
				_unit_displays[Vector3i(row, col, 1 if is_air else 0)] = display


## 4.3 单位状态标签：从单位状态数据读取（坚守/巡逻/守护/防空/补给/潜行/突击/冲锋/收缴/已行动）
func _update_unit_tags(display: Control, unit: BattleState.UnitData) -> void:
	var tags: Array[String] = []
	if unit.firm_level > 0:
		tags.append("坚%d" % unit.firm_level)
	if unit.patrolling:
		tags.append("巡")
	if unit.is_guarded:
		tags.append("护")
	if unit.abilities.has("防空"):
		tags.append("空")
	if unit.supply_level > 0:
		tags.append("补")
	if unit.abilities.has("突击"):
		tags.append("突")
	if unit.abilities.has("冲锋"):
		tags.append("锋")
	if unit.abilities.has("收缴"):
		tags.append("缴")
	if unit.stealthed and unit.revealed:
		tags.append("潜")
	if unit.has_acted:
		tags.append("已动")
	if tags.is_empty():
		return
	var tag_label := Label.new()
	tag_label.name = "_state_tags"
	tag_label.text = " ".join(tags)
	tag_label.add_theme_font_size_override("font_size", 10)
	tag_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
	tag_label.position = Vector2(4, 62)
	tag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.add_child(tag_label)


func _add_air_marker(display: Control) -> void:
	var marker := Label.new()
	marker.name = "_air_marker"
	marker.text = "✈"
	marker.add_theme_font_size_override("font_size", 12)
	marker.add_theme_color_override("font_color", Color(0.75, 0.9, 1.0))
	marker.position = Vector2(64.0, 2.0)
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.add_child(marker)


## 复盘入口：以无迷雾模式渲染任意快照局面（不接 TurnManager 也可用）
func render_review_state(state: BattleState) -> void:
	review_mode = true
	_on_state_changed(state)


## Phase 3: 迷雾可见性计算（引擎纯函数）+ 格子级迷雾渲染（4.1）
func _update_visibility(state: BattleState) -> void:
	if state == null:
		return
	var viewer_idx := _viewer_idx(state)
	if review_mode:
		# 复盘：无迷雾，一切公开
		for key in _fog_rects:
			var frect: ColorRect = _fog_rects[key]
			if is_instance_valid(frect):
				frect.visible = false
		for key2 in _unit_displays:
			var disp: CardDisplay = _unit_displays[key2]
			if is_instance_valid(disp):
				disp.set_visible_to_enemy(true, false, false)
		return
	var visible_cells := GameLogic.compute_visible_cells(state, viewer_idx)
	# 1. 更新每个敌方单位（两层）的显示（潜行规则不变）
	for key in _unit_displays:
		var k3: Vector3i = key
		var display: CardDisplay = _unit_displays[key]
		if not is_instance_valid(display):
			continue
		var layer := "air" if k3.z == 1 else "ground"
		var unit := state.board.get_unit(k3.x, k3.y, layer)
		if unit == null or unit.owner_index == viewer_idx:
			continue  # 跳过己方单位（始终可见）
		display.set_visible_to_enemy(visible_cells.has(Vector2i(k3.x, k3.y)), unit.stealthed, unit.revealed)
	# 2. 格子级迷雾：所有不可见格子一律覆盖
	_apply_fog_layer(state, visible_cells)


## ── 格子级迷雾层（盖在单位卡之上：z_index 高于默认 0）──

func _create_fog_layer() -> void:
	_fog_layer = Control.new()
	_fog_layer.name = "_fog_layer"
	_fog_layer.z_index = 100
	_fog_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fog_layer)


func _apply_fog_layer(state: BattleState, visible_cells: Dictionary) -> void:
	if _fog_layer == null:
		return
	for r in range(state.board.rows):
		for c in range(state.board.cols):
			var key := Vector2i(r, c)
			var rect: ColorRect = _fog_rects.get(key)
			if rect == null or not is_instance_valid(rect):
				rect = ColorRect.new()
				rect.size = SLOT_SIZE
				rect.color = Color(0.15, 0.15, 0.15, 1.0)
				rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
				rect.position = _grid_offset + Vector2(c * SLOT_SPACING.x, r * SLOT_SPACING.y)
				_fog_layer.add_child(rect)
				_fog_rects[key] = rect
			rect.visible = not visible_cells.has(key)


func _reposition_fog_and_labels() -> void:
	for key in _fog_rects:
		var rect: ColorRect = _fog_rects[key]
		if is_instance_valid(rect):
			rect.position = _grid_offset + Vector2(key.y * SLOT_SPACING.x, key.x * SLOT_SPACING.y)
	_reposition_front_labels()


## ── 战线占领度行标签（每行左侧）──

func _create_front_labels() -> void:
	var state := turn_manager.get_state() if turn_manager else null
	var rows := state.board.rows if state != null else GRID_SIZE
	for r in range(rows):
		var lbl := Label.new()
		lbl.text = "0"
		lbl.add_theme_font_size_override("font_size", 12)
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
		lbl.position = _front_label_pos(r)
		add_child(lbl)
		_front_labels.append(lbl)


func _front_label_pos(row: int) -> Vector2:
	var row_center_y := _grid_offset.y + row * SLOT_SPACING.y + SLOT_SIZE.y / 2.0 - 9
	return Vector2(max(2.0, _grid_offset.x - 46.0), row_center_y)


func _reposition_front_labels() -> void:
	for r in range(_front_labels.size()):
		_front_labels[r].position = _front_label_pos(r)


func _update_front_labels(state: BattleState) -> void:
	for r in range(_front_labels.size()):
		if r >= state.front_control.size():
			break
		var v: int = state.front_control[r]
		var lbl := _front_labels[r]
		lbl.text = "+%d" % v if v > 0 else str(v)
		if v >= 100:
			lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2, 1.0))  # 金色 = 完全占领
		elif v <= -100:
			lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))   # 红色 = 敌方完全占领
		elif v > 0:
			lbl.add_theme_color_override("font_color", Color(0.4, 0.65, 1.0, 1.0))  # 蓝 = P1 占优
		elif v < 0:
			lbl.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5, 1.0))   # 红 = P2 占优
		else:
			lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))   # 灰 = 中立


func _update_unit_stats(display: Control, atk: int, df: int) -> void:
	for child in display.get_children():
		if child is Label:
			var lbl := child as Label
			# 左侧小标签 = 攻击力，右侧小标签 = 防御力
			if lbl.position.x < 50 and lbl.position.y > 70:
				lbl.text = str(atk)
			elif lbl.position.x > 50 and lbl.position.y > 70:
				lbl.text = str(df)


func _set_card_bg(display: Control, color: Color) -> void:
	for child in display.get_children():
		if child is ColorRect:
			child.color = color
			return


## ── 部署高亮 ──

func highlight_deploy_zones(player_idx: int, card_id: String) -> void:
	if turn_manager == null:
		return
	var state := turn_manager.get_state()
	if state == null:
		return
	var deploy_rows: Array[int] = GameLogic.get_deployable_rows(state, player_idx, card_id)
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if slot.slot_row in deploy_rows and state.board.get_unit(slot.slot_row, slot.slot_col) == null:
			slot.show_highlight(HIGHLIGHT_DEPLOY)


func clear_highlights() -> void:
	for slot in get_tree().get_nodes_in_group("board_slot"):
		slot.hide_highlight()


func _clear_overlays() -> void:
	for display in _unit_displays.values():
		if not is_instance_valid(display):
			continue
		for child in display.get_children():
			if child is ColorRect and (child.name == "_atk_overlay" or child.name == "_select_overlay"):
				child.queue_free()


## ── 单位选中、移动、攻击 ──

func _select_unit(row: int, col: int) -> void:
	var state := turn_manager.get_state()
	if state == null:
		return
	var unit: BattleState.UnitData = state.board.get_unit(row, col)
	if unit == null:
		return
	if unit.owner_index != _viewer_idx(state):
		return
	# Standard units (move or attack once): blocked by has_acted
	if unit.move_limit <= 1 and not unit.can_move_after_attack:
		if unit.has_acted:
			return
	# Air units: blocked only when BOTH actions used
	elif unit.can_move_after_attack and unit.move_limit <= 1:
		if unit.has_attacked and unit.move_count >= unit.move_limit:
			return
	# Tank: blocked only when no moves remain AND already attacked
	else:
		if unit.move_count >= unit.move_limit and unit.has_attacked:
			return
	_selected_unit_pos = Vector2i(row, col)
	# 金色高亮选中单位（slot 层）
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if slot.slot_row == row and slot.slot_col == col:
			slot.show_highlight(HIGHLIGHT_SELECT)
			break
	# 蓝色高亮可移动目标（slot 层）
	var move_targets := _get_valid_move_targets(row, col, state)
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if Vector2i(slot.slot_row, slot.slot_col) in move_targets:
			slot.show_highlight(HIGHLIGHT_MOVE)
	# 橙色高亮可攻击目标 — 直接改敌方 CardDisplay 颜色
	_apply_attack_highlights(state, row, col)
	# 添加选中指示器到己方单位（所在层）
	var sel_layer := 1 if state.board.get_unit(row, col, "air") == unit else 0
	var key := Vector3i(row, col, sel_layer)
	if _unit_displays.has(key):
		var sel_overlay := ColorRect.new()
		sel_overlay.name = "_select_overlay"
		sel_overlay.size = SLOT_SIZE
		sel_overlay.color = Color(1.0, 0.85, 0.2, 0.25)
		sel_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_unit_displays[key].add_child(sel_overlay)


func _apply_attack_highlights(state: BattleState, from_row: int, from_col: int) -> void:
	var attack_targets := _get_valid_attack_targets(from_row, from_col, state)
	for pos in attack_targets:
		# 同格两层单位都可能是目标：全部加橙色高亮
		for layer in [0, 1]:
			var key := Vector3i(pos.x, pos.y, layer)
			if _unit_displays.has(key):
				var overlay := ColorRect.new()
				overlay.name = "_atk_overlay"
				overlay.size = SLOT_SIZE
				overlay.color = HIGHLIGHT_ATTACK
				overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_unit_displays[key].add_child(overlay)


func _deselect_unit() -> void:
	_selected_unit_pos = Vector2i(-1, -1)
	clear_highlights()
	_clear_overlays()


func _get_valid_move_targets(from_row: int, from_col: int, state: BattleState) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	# 1.2 图层：单位在自身图层内移动（含 1.3 后退：直退一格，消耗全部行动）
	var layer := "air" if state.board.get_unit(from_row, from_col, "air") != null else "ground"
	var unit := state.board.get_unit(from_row, from_col, layer)
	if unit == null:
		return targets
	if unit.deployed_this_turn and not unit.abilities.has("突击"):
		return targets  # 部署回合不能移动（突击例外）
	if unit.retreated:
		return targets
	var player_idx := unit.owner_index
	var directions: Array[int] = [-1, 0, 1]
	for dr in directions:
		for dc in directions:
			if dr == 0 and dc == 0:
				continue
			var tr: int = from_row + dr
			var tc: int = from_col + dc
			if tr < 0 or tr >= state.board.rows or tc < 0 or tc >= state.board.cols:
				continue
			var is_retreat := (player_idx == 0 and tr < from_row) or (player_idx == 1 and tr > from_row)
			if is_retreat:
				# 后退：只能直退（不斜退）；己方后排行不能再退
				if dc != 0:
					continue
				if (player_idx == 0 and from_row == 0) or (player_idx == 1 and from_row == state.board.rows - 1):
					continue
			if state.board.get_unit(tr, tc, layer) != null:
				continue
			targets.append(Vector2i(tr, tc))
	return targets


func _get_valid_attack_targets(from_row: int, from_col: int, state: BattleState) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	var attacker_is_air := false
	var unit := state.board.get_unit(from_row, from_col, "air")
	if unit != null:
		attacker_is_air = true
	else:
		unit = state.board.get_unit(from_row, from_col)
	if unit == null:
		return targets
	# 已攻击的单位本回合不能再攻击
	if unit.has_attacked:
		return targets
	# 后退消耗全部行动
	if unit.retreated:
		return targets
	# Z 不足时任何攻击都无效
	var player = state.players[unit.owner_index]
	if player.resources["Z"] < 1:
		return targets
	for row in range(state.board.rows):
		for col in range(state.board.cols):
			# 1.2 目标定层：地面攻击者只能打地面层；空军攻击者优先空域层，其次地面层
			var target := state.board.get_unit(row, col)
			if target == null and attacker_is_air:
				target = state.board.get_unit(row, col, "air")
			if target == null:
				continue
			if target.owner_index == unit.owner_index:
				continue
			# 射程判定复用引擎实现（与攻击合法性完全一致）
			if not GameLogic._in_attack_range(unit, from_row, from_col, row, col):
				continue
			# 陆军打不了空军；轰炸机只能打陆军
			var attacker_card: Resource = CardDataLoader.cards.get(unit.card_id)
			var defender_card: Resource = CardDataLoader.cards.get(target.card_id)
			if attacker_card != null and defender_card != null:
				var atk_is_air := GameLogic._is_air_unit(attacker_card.unit_class)
				var def_is_air := GameLogic._is_air_unit(defender_card.unit_class)
				if not atk_is_air and def_is_air:
					continue
				if attacker_card.unit_class == "bomber" and def_is_air:
					continue
			# 未揭示的潜行单位不可被作为目标
			if target.stealthed and not target.revealed:
				continue
			targets.append(Vector2i(row, col))
	return targets


## ── 输入处理 ──

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	var mouse_pos := get_global_mouse_position()
	for slot in get_tree().get_nodes_in_group("board_slot"):
		var slot_rect := Rect2(slot.global_position, SLOT_SIZE)
		if slot_rect.has_point(mouse_pos):
			_handle_slot_press(slot.slot_row, slot.slot_col)
			return


func _handle_slot_press(row: int, col: int) -> void:
	var state := turn_manager.get_state() if turn_manager else null

	# 模式 1：单位已选中 → 尝试移动或攻击
	if _selected_unit_pos.x >= 0:
		var from_r := _selected_unit_pos.x
		var from_c := _selected_unit_pos.y
		if state == null:
			_deselect_unit()
			return

		# 检查移动
		var move_targets := _get_valid_move_targets(from_r, from_c, state)
		if Vector2i(row, col) in move_targets:
			_deselect_unit()
			move_requested.emit(from_r, from_c, row, col)
			return

		# 检查攻击
		var attack_targets := _get_valid_attack_targets(from_r, from_c, state)
		if Vector2i(row, col) in attack_targets:
			_deselect_unit()
			attack_requested.emit(from_r, from_c, row, col)
			return

		# 点击同一单位 → 取消选中
		if row == from_r and col == from_c:
			_deselect_unit()
			return

		# 点击其他位置 → 取消选中
		_deselect_unit()
		return

	# 模式 2：无单位选中 → 发射 slot_clicked（供部署等用途）
	# 注意：行动阶段不发射 slot_clicked，由 Board 自行处理选中/移动/攻击
	if state == null or state.phase != "action":
		slot_clicked.emit(row, col)

	# 模式 3：行动阶段 → 尝试选中己方可行动单位
	if state == null:
		return
	if state.phase != "action":
		return
	_select_unit(row, col)


func spawn_card(card_data: Resource) -> Control:
	var card_scene = load("res://scenes/ui_components/card.tscn")
	var card = card_scene.instantiate()
	card.setup(card_data)
	return card


func get_grid_right_edge() -> float:
	return _grid_offset.x + GRID_SIZE * SLOT_SPACING.x
