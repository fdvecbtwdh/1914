extends Node2D
class_name BoardSlot

## 棋盘上的一个格子，可接受卡牌拖放

@export var slot_row: int = 0
@export var slot_col: int = 0

var occupied_card: Node2D = null


func _ready() -> void:
	add_to_group("board_slot")


func can_accept_card() -> bool:
	return occupied_card == null


func place_card(card: Node2D) -> void:
	occupied_card = card
	card.position = Vector2.ZERO
	add_child(card)
	print("[BoardSlot] Card placed at (%d, %d)" % [slot_row, slot_col])


func remove_card() -> void:
	occupied_card = null
