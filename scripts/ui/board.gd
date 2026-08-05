extends Node2D

## Board 根节点 — 管理 5×5 棋盘格子和单位

const GRID_SIZE: int = 5
const SLOT_SPACING: Vector2 = Vector2(90, 115)
const SLOT_SIZE: Vector2 = Vector2(80, 100)
const GRID_OFFSET: Vector2 = Vector2(200, 50)

## 当前最大行数（5 为基础，可扩展到 7）
var max_rows: int = 5


func _ready() -> void:
	print("[Board] BattleScene loaded")
	_create_board()
	_spawn_test_card()


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


func spawn_card(card_data: Resource) -> Node2D:
	var card_scene = load("res://scenes/ui_components/card.tscn")
	var card = card_scene.instantiate()
	card.setup(card_data)
	return card


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
	for col in range(5):
		var slot: BoardSlot = slot_scene.instantiate()
		slot.slot_row = row_idx
		slot.slot_col = col
		y_offset = GRID_OFFSET.y + row_idx * SLOT_SPACING.y
		slot.position = Vector2(GRID_OFFSET.x + col * SLOT_SPACING.x, y_offset)
		slot.add_to_group("board_slot")
		add_child(slot)
	max_rows += 1
	print("[Board] Added extra row %s, total rows: %d" % ["top" if is_top else "bottom", max_rows])


func _spawn_test_card() -> void:
	var card_data = CardDataLoader.load_all_cards().get("test_infantry_01")
	if card_data == null:
		printerr("[Board] Test card not found!")
		return
	var card = spawn_card(card_data)
	card.position = Vector2(50, 300)
	add_child(card)
	print("[Board] Test card spawned at edge")
