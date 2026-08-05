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
const HIGHLIGHT_SELECT := Color(1.0, 0.85, 0.2, 0.40)   # 金色 — 已选中

signal slot_clicked(row: int, col: int)
signal move_requested(from_row: int, from_col: int, to_row: int, to_col: int)

## 当前最大行数（5 为基础，可扩展到 7）
var max_rows: int = 5
var turn_manager: TurnManager = null
var _unit_displays: Dictionary = {}
var _grid_offset: Vector2 = Vector2.ZERO
var _selected_unit_pos: Vector2i = Vector2i(-1, -1)


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
	if turn_manager and turn_manager.battle_state:
		_on_state_changed(turn_manager.battle_state)


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
	_render_units(new_state)


func _clear_unit_displays() -> void:
	for display in _unit_displays.values():
		if is_instance_valid(display):
			display.queue_free()
	_unit_displays.clear()


func _render_units(state: BattleState) -> void:
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
			if unit.owner_index != state.active_player_index:
				_fog_display(display)
			add_child(display)
			_unit_displays[Vector2i(row, col)] = display


func _fog_display(display: Control) -> void:
	var fog := ColorRect.new()
	fog.size = SLOT_SIZE
	fog.color = Color(0.15, 0.15, 0.15, 1.0)
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


## ── 单位选中与移动 ──

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
		return  # 已行动过
	_selected_unit_pos = Vector2i(row, col)
	# 高亮选中单位
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if slot.slot_row == row and slot.slot_col == col:
			slot.show_highlight(HIGHLIGHT_SELECT)
			break
	# 高亮可移动目标格
	var targets := _get_valid_move_targets(row, col, state)
	for slot in get_tree().get_nodes_in_group("board_slot"):
		if Vector2i(slot.slot_row, slot.slot_col) in targets:
			slot.show_highlight(HIGHLIGHT_MOVE)


func _deselect_unit() -> void:
	_selected_unit_pos = Vector2i(-1, -1)
	clear_highlights()


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
			# 边界检查
			if tr < 0 or tr >= state.board.rows or tc < 0 or tc >= state.board.cols:
				continue
			# 禁止后退：P1 不能向上(row-)，P2 不能向下(row+)
			if player_idx == 0 and tr < from_row:
				continue
			if player_idx == 1 and tr > from_row:
				continue
			# 目标格必须为空
			if state.board.get_unit(tr, tc) != null:
				continue
			targets.append(Vector2i(tr, tc))
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

	# 模式 1：单位已选中 → 尝试移动
	if _selected_unit_pos.x >= 0:
		var from_r := _selected_unit_pos.x
		var from_c := _selected_unit_pos.y
		if state == null:
			_deselect_unit()
			return
		var targets := _get_valid_move_targets(from_r, from_c, state)
		if Vector2i(row, col) in targets:
			_deselect_unit()
			move_requested.emit(from_r, from_c, row, col)
			return
		# 点击同一单位 → 取消选中
		if row == from_r and col == from_c:
			_deselect_unit()
			return
		# 点击其他位置 → 取消选中
		_deselect_unit()
		return

	# 模式 2：无单位选中 → 总是发射 slot_clicked（供部署等用途）
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
