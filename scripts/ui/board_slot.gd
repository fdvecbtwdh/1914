extends Node2D
class_name BoardSlot

## 棋盘上的一个格子，可接受卡牌拖放

@export var slot_row: int = 0
@export var slot_col: int = 0

var occupied_card: Control = null
var _highlight: ColorRect = null


func _ready() -> void:
	add_to_group("board_slot")


func can_accept_card() -> bool:
	return occupied_card == null


func place_card(card: Control) -> void:
	occupied_card = card
	card.position = Vector2.ZERO
	add_child(card)
	hide_highlight()
	print("[BoardSlot] Card placed at (%d, %d)" % [slot_row, slot_col])


func remove_card() -> void:
	occupied_card = null


func show_highlight(color: Color) -> void:
	if _highlight == null:
		_highlight = ColorRect.new()
		_highlight.size = Vector2(80, 100)
		_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_highlight)
	_highlight.color = color
	_highlight.visible = true


func hide_highlight() -> void:
	if _highlight:
		_highlight.visible = false
