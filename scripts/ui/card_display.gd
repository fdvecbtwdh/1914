extends Node2D
class_name CardDisplay

## 单张卡牌的显示与拖拽行为

var card_data: Resource = null  # CardDataLoader.CardData

var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_position: Vector2 = Vector2.ZERO
var original_parent: Node = null

const CARD_SIZE: Vector2 = Vector2(80, 100)


func setup(data: Resource) -> void:
	card_data = data
	# 用 ColorRect 临时表示卡牌外观（后续替换为正式美术）
	var bg = ColorRect.new()
	bg.size = CARD_SIZE
	bg.color = Color(0.3, 0.4, 0.5, 1.0)
	add_child(bg)

	var label = Label.new()
	label.text = data.card_name
	label.add_theme_font_size_override("font_size", 12)
	label.position = Vector2(4, 4)
	add_child(label)

	print("[CardDisplay] Setup: %s" % data.card_name)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_try_start_drag(event.position)
			else:
				_try_end_drag(event.position)
	if is_dragging and event is InputEventMouseMotion:
		global_position = event.position - drag_offset


func _try_start_drag(mouse_pos: Vector2) -> void:
	# 检查鼠标是否在卡牌范围内
	var card_rect = Rect2(global_position, CARD_SIZE)
	if card_rect.has_point(mouse_pos):
		is_dragging = true
		original_position = global_position
		original_parent = get_parent()
		drag_offset = mouse_pos - global_position
		# 提升到最顶层以便拖拽时不被遮挡
		var root = get_tree().current_scene
		var old_global = global_position
		get_parent().remove_child(self)
		root.add_child(self)
		global_position = old_global
		print("[CardDisplay] Drag start: %s" % card_data.card_name)


func _try_end_drag(mouse_pos: Vector2) -> void:
	if not is_dragging:
		return
	is_dragging = false
	# 检测放置目标 — 遍历所有 board_slot 组节点
	var dropped = false
	var board_slots = get_tree().get_nodes_in_group("board_slot")
	for slot in board_slots:
		var slot_rect = Rect2(slot.global_position, CARD_SIZE)
		if slot_rect.has_point(mouse_pos) and slot.can_accept_card():
			var root = get_tree().current_scene
			root.remove_child(self)
			slot.place_card(self)
			dropped = true
			break
	if not dropped:
		# 回到原位
		var root = get_tree().current_scene
		root.remove_child(self)
		original_parent.add_child(self)
		global_position = original_position
		print("[CardDisplay] Drag cancelled — returned to original position")
