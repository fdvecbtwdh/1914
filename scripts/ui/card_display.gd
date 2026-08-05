extends Control
class_name CardDisplay

## 单张卡牌的显示与拖拽行为

var card_data: Resource = null  # CardDataLoader.CardData

var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_position: Vector2 = Vector2.ZERO
var original_parent: Node = null
var _initialized: bool = false

const CARD_SIZE: Vector2 = Vector2(80, 100)


func setup(data: Resource) -> void:
	if _initialized:
		return  # 幂等保护，防止重复初始化
	_initialized = true
	card_data = data
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = CARD_SIZE
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

	# 攻击力 — 左下
	var atk_label = Label.new()
	atk_label.text = str(data.attack)
	atk_label.add_theme_font_size_override("font_size", 11)
	atk_label.position = Vector2(6, 80)
	add_child(atk_label)

	# 防御力 — 右下
	var def_label = Label.new()
	def_label.text = str(data.defense)
	def_label.add_theme_font_size_override("font_size", 11)
	def_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4, 1.0))
	def_label.position = Vector2(CARD_SIZE.x - 18, 80)
	add_child(def_label)

	print("[CardDisplay] Setup: %s" % data.card_name)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_start_drag(event.position)
			else:
				_end_drag(event.position)
	if is_dragging and event is InputEventMouseMotion:
		global_position = get_global_mouse_position() - drag_offset


func _start_drag(mouse_pos: Vector2) -> void:
	is_dragging = true
	original_position = global_position
	original_parent = get_parent()
	drag_offset = mouse_pos
	# 提升到场景根，拖拽时不被遮挡
	var root = get_tree().current_scene
	var old_global = global_position
	var parent = get_parent()
	parent.remove_child(self)
	# 如果从棋盘格子中拖出，清除格子的占用记录
	if parent.has_method("remove_card"):
		parent.remove_card()
	root.add_child(self)
	global_position = old_global
	print("[CardDisplay] Drag start: %s" % card_data.card_name)


func _end_drag(mouse_pos: Vector2) -> void:
	if not is_dragging:
		return
	is_dragging = false
	# 检测放置目标 — 遍历所有 board_slot 组节点
	var dropped = false
	var board_slots = get_tree().get_nodes_in_group("board_slot")
	for slot in board_slots:
		var slot_rect = Rect2(slot.global_position, CARD_SIZE)
		if slot_rect.has_point(get_global_mouse_position()) and slot.can_accept_card():
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
