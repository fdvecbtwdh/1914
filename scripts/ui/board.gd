extends Node2D

## Board 根节点 — 管理 5×5 棋盘格子和单位

const GRID_SIZE: int = 5
const SLOT_SPACING: Vector2 = Vector2(90, 115)
const SLOT_SIZE: Vector2 = Vector2(80, 100)
const GRID_OFFSET: Vector2 = Vector2(200, 50)


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


func _spawn_test_card() -> void:
	var card_data = CardDataLoader.load_all_cards().get("test_infantry_01")
	if card_data == null:
		printerr("[Board] Test card not found!")
		return
	var card = spawn_card(card_data)
	card.position = Vector2(50, 300)
	add_child(card)
	print("[Board] Test card spawned at edge")
