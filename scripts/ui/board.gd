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

## 当前最大行数（5 为基础，可扩展到 7）
var max_rows: int = 5
var turn_manager: TurnManager = null
var _unit_displays: Dictionary = {}
var _grid_offset: Vector2 = Vector2.ZERO
var _selected_unit_pos: Vector2i = Vector2i(-1, -1)
var _p1_marker: Label = null
var _p2_marker: Label = null


func _ready() -> void:
	print("[Board] Ready — waiting for TurnManager")
	_recalc_grid_offset()
	_create_board()
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


func add_extra_row(is_top: bool) -> void:
	if max_rows >= 7:
		print("[Board] Max rows already 7, cannot add more")
		return
	var row_idx: int
	if is_top:
		row_idx = 0
		for slot in get_tree().get_nodes_in_group("board_slot"):
			slot.slot_row += 1
			slot.position.y += SLOT_SPACING.y
	else:
		row_idx = max_rows
	var slot_scene = load("res://scenes/ui_components/board_slot.tscn")
	for col in range(GRID_SIZE):
		var slot: BoardSlot = slot_scene.instantiate()
		slot.slot_row = row_idx
		slot.slot_col = col
		slot.position = Vector2(
			_grid_offset.x + col * SLOT_SPACING.x,
			_grid_offset.y + row_idx * SLOT_SPACING.y
		)
		slot.add_to_group("board_slot")
		add_child(slot)
	max_rows += 1
	print("[Board] Added extra row %s, total rows: %d" % ["top" if is_top else "bottom", max_rows])


func _on_state_changed(new_state: BattleState) -> void:
	_deselect_unit()
	_clear_unit_displays()
	if new_state == null:
		return
	_update_markers(new_state.active_player_index)
	_render_units(new_state)


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
	var visible := _compute_visible_positions(state)
	for row in range(state.board.rows):
		for col in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(row, col)
			if unit == null:
				continue
			var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
			if card_data == null:
				continue
			var display := spawn_card(card_data)
			display.position = _grid_offset + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
			# 己方原色，敌方微偏红
			if unit.owner_index == state.active_player_index:
				_set_card_bg(display, Color(0.3, 0.4, 0.5, 1.0))
			else:
				_set_card_bg(display, Color(0.48, 0.3, 0.32, 1.0))
				if not (Vector2i(row, col) in visible):
					_fog_display(display)
			_update_unit_stats(display, unit.attack, unit.defense)
			add_child(display)
			_unit_displays[Vector2i(row, col)] = display


func _compute_visible_positions(state: BattleState) -> Array[Vector2i]:
	var visible: Array[Vector2i] = []
	for row in range(state.board.rows):
		for col in range(state.board.cols):
			var unit: BattleState.UnitData = state.board.get_unit(row, col)
			if unit == null:
				continue
			if unit.owner_index != state.active_player_index:
				continue
			var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
			if card_data == null:
				continue
			var vr: String = card_data.vision_range
			match vr:
				"adjacent_4":
					_add_adjacent_4_vision(visible, row, col, state)
				"front_3x3":
					_add_front_3x3_vision(visible, row, col, state)
				"adjacent_8_forward":
					_add_adjacent_8_forward_vision(visible, row, col, state)
				"front_3x2":
					_add_front_3x2_vision(visible, row, col, state)
				"frontline_only":
					_add_frontline_vision(visible, row, col, state)
				_:
					_add_adjacent_4_vision(visible, row, col, state)
	return visible


func _add_adjacent_4_vision(visible: Array[Vector2i], row: int, col: int, state: BattleState) -> void:
	for dr in [-1, 0, 1]:
		for dc in [-1, 0, 1]:
			if dr == 0 and dc == 0:
				continue
			var tr: int = row + dr
			var tc: int = col + dc
			if tr >= 0 and tr < state.board.rows and tc >= 0 and tc < state.board.cols:
				var v := Vector2i(tr, tc)
				if not (v in visible):
					visible.append(v)


func _add_front_3x3_vision(visible: Array[Vector2i], row: int, col: int, state: BattleState) -> void:
	# 向前方 3 列 × 3 行（P1 向下，P2 向上）
	var unit := state.board.get_unit(row, col)
	if unit == null:
		return
	var dir: int = 1 if unit.owner_index == 0 else -1
	for r in range(1, 4):
		var tr: int = row + dir * r
		if tr < 0 or tr >= state.board.rows:
			break
		for dc in [-1, 0, 1]:
			var tc: int = col + dc
			if tc >= 0 and tc < state.board.cols:
				var v := Vector2i(tr, tc)
				if not (v in visible):
					visible.append(v)


func _add_adjacent_8_forward_vision(visible: Array[Vector2i], row: int, col: int, state: BattleState) -> void:
	# 周围八格 + 向前额外一格
	_add_adjacent_4_vision(visible, row, col, state)
	var unit := state.board.get_unit(row, col)
	if unit == null:
		return
	var dir: int = 1 if unit.owner_index == 0 else -1
	var tr: int = row + dir * 2
	var tc: int = col
	if tr >= 0 and tr < state.board.rows:
		var v := Vector2i(tr, tc)
		if not (v in visible):
			visible.append(v)


func _add_front_3x2_vision(visible: Array[Vector2i], row: int, col: int, state: BattleState) -> void:
	var unit := state.board.get_unit(row, col)
	if unit == null:
		return
	var dir: int = 1 if unit.owner_index == 0 else -1
	for r in range(1, 3):
		var tr: int = row + dir * r
		if tr < 0 or tr >= state.board.rows:
			break
		for dc in [-1, 0, 1]:
			var tc: int = col + dc
			if tc >= 0 and tc < state.board.cols:
				var v := Vector2i(tr, tc)
				if not (v in visible):
					visible.append(v)


func _add_frontline_vision(visible: Array[Vector2i], row: int, col: int, state: BattleState) -> void:
	for c in range(state.board.cols):
		var v := Vector2i(row, c)
		if not (v in visible):
			visible.append(v)


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


func _fog_display(display: Control) -> void:
	var fog := ColorRect.new()
	fog.size = SLOT_SIZE
	fog.color = Color(0.35, 0.1, 0.1, 1.0)  # 不透明暗红 — 敌方（被迷雾遮盖）
	fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.add_child(fog)


## ── 部署高亮 ──

func highlight_deploy_zones(player_idx: int, card_id: String) -> void:
	if turn_manager == null:
		return
	var state := turn_manager.get_state()
	if state == null:
		return
	var deploy_rows: Array[int] = GameLogic.get_deployable_rows(state, player_idx, card_id)
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if slot.slot_row in deploy_rows and slot.can_accept_card():
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
	if unit.owner_index != state.active_player_index:
		return
	if unit.has_acted:
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
	# 添加选中指示器到己方单位
	var key := Vector2i(row, col)
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
		if _unit_displays.has(pos):
			var overlay := ColorRect.new()
			overlay.name = "_atk_overlay"
			overlay.size = SLOT_SIZE
			overlay.color = HIGHLIGHT_ATTACK
			overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_unit_displays[pos].add_child(overlay)


func _deselect_unit() -> void:
	_selected_unit_pos = Vector2i(-1, -1)
	clear_highlights()
	_clear_overlays()


func _get_valid_move_targets(from_row: int, from_col: int, state: BattleState) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	var unit := state.board.get_unit(from_row, from_col)
	if unit == null:
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
			if player_idx == 0 and tr < from_row:
				continue
			if player_idx == 1 and tr > from_row:
				continue
			if state.board.get_unit(tr, tc) != null:
				continue
			targets.append(Vector2i(tr, tc))
	return targets


func _get_valid_attack_targets(from_row: int, from_col: int, state: BattleState) -> Array[Vector2i]:
	var targets: Array[Vector2i] = []
	var unit := state.board.get_unit(from_row, from_col)
	if unit == null:
		return targets
	var card_data: Resource = CardDataLoader.cards.get(unit.card_id)
	if card_data == null:
		return targets
	var range_str: String = card_data.attack_range
	for row in range(state.board.rows):
		for col in range(state.board.cols):
			var target := state.board.get_unit(row, col)
			if target == null:
				continue
			if target.owner_index == unit.owner_index:
				continue
			var dr: int = abs(row - from_row)
			var dc: int = abs(col - from_col)
			var in_range: bool = false
			match range_str:
				"adjacent_4":
					in_range = dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
				"global":
					in_range = true
				_:
					in_range = dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
			if in_range:
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
