extends Node2D
class_name Board

## 棋盘渲染 — 从 BattleState 读取数据，渲染格子和单位

const GRID_SIZE: int = 5
const SLOT_SPACING: Vector2 = Vector2(90, 115)
const SLOT_SIZE: Vector2 = Vector2(80, 100)
const GRID_OFFSET: Vector2 = Vector2(200, 50)

## 当前最大行数（5 为基础，可扩展到 7）
var max_rows: int = 5
var turn_manager: TurnManager = null
var _unit_displays: Dictionary = {}  # {(row,col): CardDisplay}


func _ready() -> void:
	print("[Board] Ready — waiting for TurnManager")
	_create_board()


func setup(tm: TurnManager) -> void:
	turn_manager = tm
	turn_manager.state_changed.connect(_on_state_changed)


func _create_board() -> void:
	var slot_scene = load("res://scenes/ui_components/board_slot.tscn")
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var slot = slot_scene.instantiate()
			slot.slot_row = row
			slot.slot_col = col
			slot.position = GRID_OFFSET + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
			add_child(slot)
	print("[Board] Created %d slots" % (GRID_SIZE * GRID_SIZE))


## 添加一行到棋盘顶部或底部（最多扩展到 7 行）
func add_extra_row(is_top: bool) -> void:
	if max_rows >= 7:
		print("[Board] Max rows already 7, cannot add more")
		return
	var row_idx: int
	var y_offset: float
	if is_top:
		row_idx = 0  # 最上方
		# 把现有所有行往下移一行
		for slot in get_tree().get_nodes_in_group("board_slot"):
			slot.slot_row += 1
			slot.position.y += SLOT_SPACING.y
	else:
		row_idx = max_rows  # 最下方
	# 创建新行
	var slot_scene = load("res://scenes/ui_components/board_slot.tscn")
	for col in range(GRID_SIZE):
		var slot: BoardSlot = slot_scene.instantiate()
		slot.slot_row = row_idx
		slot.slot_col = col
		y_offset = GRID_OFFSET.y + row_idx * SLOT_SPACING.y
		slot.position = Vector2(GRID_OFFSET.x + col * SLOT_SPACING.x, y_offset)
		slot.add_to_group("board_slot")
		add_child(slot)
	max_rows += 1
	print("[Board] Added extra row %s, total rows: %d" % ["top" if is_top else "bottom", max_rows])


func _on_state_changed(new_state: BattleState) -> void:
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
			display.position = GRID_OFFSET + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
			# 只有己方可见详细信息；对方单位显示为灰色迷雾方块
			if unit.owner_index != state.active_player_index:
				_fog_display(display)
			add_child(display)
			_unit_displays[Vector2i(row, col)] = display


func _fog_display(display: Control) -> void:
	# 用灰色覆盖隐藏对方单位信息
	var fog := ColorRect.new()
	fog.size = Vector2(80, 100)
	fog.color = Color(0.15, 0.15, 0.15, 1.0)
	fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.add_child(fog)


func spawn_card(card_data: Resource) -> Control:
	var card_scene = load("res://scenes/ui_components/card.tscn")
	var card = card_scene.instantiate()
	card.setup(card_data)
	return card
