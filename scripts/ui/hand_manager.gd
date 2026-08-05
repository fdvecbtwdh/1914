extends Node2D
class_name HandManager

## 手牌/购买区/资源 UI — 从 BattleState 读取，响应 TurnManager 信号

signal card_purchased(card_id: String)
signal card_deployed(card_id: String, row: int, col: int)
signal end_turn_pressed()
signal skip_phase_pressed()

var turn_manager: TurnManager = null
var _purchase_buttons: Dictionary = {}   # {card_id: Button}
var _hand_buttons: Dictionary = {}       # {card_id: Button}
var _g_label: Label = null
var _k_label: Label = null
var _z_label: Label = null
var _phase_label: Label = null
var _player_label: Label = null
var _turn_label: Label = null


func setup(tm: TurnManager) -> void:
	turn_manager = tm
	turn_manager.state_changed.connect(_on_state_changed)
	_build_ui()


func _build_ui() -> void:
	# 玩家/回合/阶段信息
	_turn_label = Label.new()
	_turn_label.position = Vector2(10, 10)
	_turn_label.add_theme_font_size_override("font_size", 16)
	add_child(_turn_label)

	_player_label = Label.new()
	_player_label.position = Vector2(10, 30)
	_player_label.add_theme_font_size_override("font_size", 14)
	add_child(_player_label)

	_phase_label = Label.new()
	_phase_label.position = Vector2(10, 50)
	_phase_label.add_theme_font_size_override("font_size", 12)
	add_child(_phase_label)

	# 资源显示
	_g_label = _make_resource_label(Vector2(10, 80), "G: 0")
	_k_label = _make_resource_label(Vector2(110, 80), "K: 0")
	_z_label = _make_resource_label(Vector2(210, 80), "Z: 0")

	# 结束回合按钮
	var end_btn := Button.new()
	end_btn.text = "结束回合"
	end_btn.position = Vector2(600, 10)
	end_btn.pressed.connect(func(): end_turn_pressed.emit())
	add_child(end_btn)

	# 跳过阶段按钮
	var skip_btn := Button.new()
	skip_btn.text = "跳过阶段"
	skip_btn.position = Vector2(600, 50)
	skip_btn.pressed.connect(func(): skip_phase_pressed.emit())
	add_child(skip_btn)


func _make_resource_label(pos: Vector2, text: String) -> Label:
	var lbl := Label.new()
	lbl.position = pos
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	add_child(lbl)
	return lbl


func _on_state_changed(new_state: BattleState) -> void:
	_clear_dynamic_ui()
	if new_state == null:
		return
	_update_info(new_state)
	_update_resources(new_state)
	_render_purchase_zone(new_state)
	_render_hand(new_state)


func _update_info(state: BattleState) -> void:
	_turn_label.text = "回合 %d" % state.turn
	_player_label.text = "玩家 %d" % (state.active_player_index + 1)
	_phase_label.text = "阶段: %s" % state.phase


func _update_resources(state: BattleState) -> void:
	var player = state.players[state.active_player_index]
	_g_label.text = "G: %d" % player.resources["G"]
	_k_label.text = "K: %d" % player.resources["K"]
	_z_label.text = "Z: %d" % player.resources["Z"]


func _render_purchase_zone(state: BattleState) -> void:
	var player = state.players[state.active_player_index]
	var x := 10.0
	var y := 110.0
	var title := Label.new()
	title.text = "— 待购买区 —"
	title.position = Vector2(x, y)
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)
	y += 20
	for card_id in player.purchase_zone:
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		var btn := Button.new()
		btn.text = "%s (G:%d)" % [card_data.card_name, card_data.cost_g]
		btn.position = Vector2(x, y)
		btn.pressed.connect(_make_purchase_handler(card_id))
		add_child(btn)
		_purchase_buttons[card_id] = btn
		x += 130


func _render_hand(state: BattleState) -> void:
	var player = state.players[state.active_player_index]
	var x := 10.0
	var y := 160.0
	var title := Label.new()
	title.text = "— 手牌 (%d/%d) —" % [player.hand.size(), player.hand_limit]
	title.position = Vector2(x, y)
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)
	y += 20
	for card_id in player.hand:
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		var btn := Button.new()
		btn.text = "%s (Z:%d) %d/%d" % [card_data.card_name, card_data.cost_k, card_data.attack, card_data.defense]
		btn.position = Vector2(x, y)
		btn.pressed.connect(_make_deploy_handler(card_id))
		add_child(btn)
		_hand_buttons[card_id] = btn
		x += 150


func _make_purchase_handler(card_id: String) -> Callable:
	return func(): card_purchased.emit(card_id)


func _make_deploy_handler(card_id: String) -> Callable:
	return func(): card_deployed.emit(card_id, -1, -1)  # row/col by click on board


func _clear_dynamic_ui() -> void:
	for btn in _purchase_buttons.values():
		if is_instance_valid(btn):
			btn.queue_free()
	_purchase_buttons.clear()
	for btn in _hand_buttons.values():
		if is_instance_valid(btn):
			btn.queue_free()
	_hand_buttons.clear()
	# 清除标题 Label（"— xxx —" 分隔线标题），遍历子节点从末尾清理，
	# 注意：不清理 _turn_label 等持久 UI（它们文本不含 "—"）
	for i in range(get_child_count() - 1, -1, -1):
		var child := get_child(i)
		if child is Label and "—" in child.text:
			child.queue_free()
