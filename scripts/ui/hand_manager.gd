extends Node2D
class_name HandManager

## 手牌/购买区/资源 UI — 从 BattleState 读取，响应 TurnManager 信号

signal card_purchased(card_id: String)
signal card_deployed(card_id: String, row: int, col: int)
signal end_turn_pressed()
signal skip_phase_pressed()

## 右侧面板配置
const PANEL_MIN_X: float = 500.0
const BUTTON_WIDTH: float = 100.0
const CARD_BTN_HEIGHT: float = 32.0

var turn_manager: TurnManager = null
var _board: Board = null
var _purchase_buttons: Dictionary = {}
var _hand_buttons: Dictionary = {}
var _purchase_order: Array[String] = []   # 按渲染顺序排列的 card_id
var _hand_order: Array[String] = []       # 按渲染顺序排列的 card_id
var _end_btn: Button = null
var _skip_btn: Button = null
var _g_label: Label = null
var _k_label: Label = null
var _z_label: Label = null
var _phase_label: Label = null
var _player_label: Label = null
var _turn_label: Label = null
var _pending_deploy_card: String = ""


func setup(tm: TurnManager) -> void:
	turn_manager = tm
	turn_manager.state_changed.connect(_on_state_changed)
	_build_ui()


func _get_panel_x() -> float:
	if _board and is_instance_valid(_board):
		return _board.get_grid_right_edge() + Board.PANEL_GAP
	var vs := get_viewport().get_visible_rect().size
	return max(PANEL_MIN_X, vs.x - 300.0)


func _get_viewport() -> Vector2:
	return get_viewport().get_visible_rect().size


func _build_ui() -> void:
	var vs := _get_viewport()

	# ── 左上角：回合 / 玩家 / 阶段 ──
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

	# ── 右上角：按钮（含快捷键提示，稍宽） ──
	const BTN_W: float = 150.0
	var btn_x := vs.x - BTN_W - 12.0

	_skip_btn = Button.new()
	_skip_btn.text = "下一阶段 [Space]"
	_skip_btn.position = Vector2(btn_x, 8)
	_skip_btn.size.x = BTN_W
	_skip_btn.pressed.connect(func(): skip_phase_pressed.emit())
	add_child(_skip_btn)

	_end_btn = Button.new()
	_end_btn.text = "结束回合 [Enter]"
	_end_btn.position = Vector2(btn_x, 44)
	_end_btn.size.x = BTN_W
	_end_btn.pressed.connect(func(): end_turn_pressed.emit())
	add_child(_end_btn)

	# ── 快捷键提示 ──
	var hint := Label.new()
	hint.text = "1-5 选卡  Space 下一阶段  Enter 结束回合  Esc 取消"
	hint.position = Vector2(10, vs.y - 38)
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1.0))
	add_child(hint)

	# ── 底部偏右：资源（给左下棋手标记留空间） ──
	var res_y := vs.y - 30.0
	var res_x := vs.x - 350.0
	_g_label = _make_resource_label(Vector2(res_x, res_y), "G: 0")
	_k_label = _make_resource_label(Vector2(res_x + 110, res_y), "K: 0")
	_z_label = _make_resource_label(Vector2(res_x + 220, res_y), "Z: 0")


func _make_resource_label(pos: Vector2, text: String) -> Label:
	var lbl := Label.new()
	lbl.position = pos
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	add_child(lbl)
	return lbl


func _on_state_changed(new_state: BattleState) -> void:
	_pending_deploy_card = ""
	if _board and is_instance_valid(_board):
		_board.clear_highlights()
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
	_purchase_order.clear()
	if player.purchase_zone.is_empty():
		return
	var px := _get_panel_x()
	var py := _get_panel_top_y()
	var title := Label.new()
	title.text = "— 待购买区 —"
	title.position = Vector2(px, py)
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)
	py += 22.0
	var idx := 0
	for card_id in player.purchase_zone:
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		idx += 1
		var btn := Button.new()
		btn.text = "[%d] %s (G:%d)" % [idx, card_data.card_name, card_data.cost_g]
		btn.position = Vector2(px, py)
		btn.size.x = 160.0
		btn.pressed.connect(_make_purchase_handler(card_id))
		add_child(btn)
		_purchase_buttons[card_id] = btn
		_purchase_order.append(card_id)
		py += CARD_BTN_HEIGHT + 4.0


func _render_hand(state: BattleState) -> void:
	var player = state.players[state.active_player_index]
	_hand_order.clear()
	if player.hand.is_empty():
		return
	var px := _get_panel_x()
	var py := _get_panel_top_y() + 22.0
	var purchase_count: int = player.purchase_zone.size()
	if purchase_count > 0:
		py += float(purchase_count) * (CARD_BTN_HEIGHT + 4.0) + 22.0 + 8.0
	var title := Label.new()
	title.text = "— 手牌 (%d/%d) —" % [player.hand.size(), player.hand_limit]
	title.position = Vector2(px, py)
	title.add_theme_font_size_override("font_size", 12)
	add_child(title)
	py += 22.0
	var idx := 0
	for card_id in player.hand:
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		idx += 1
		var btn := Button.new()
		btn.text = "[%d] %s (Z:%d) %d/%d" % [idx, card_data.card_name, card_data.cost_k, card_data.attack, card_data.defense]
		btn.position = Vector2(px, py)
		btn.size.x = 170.0
		btn.pressed.connect(_make_deploy_handler(card_id))
		add_child(btn)
		_hand_buttons[card_id] = btn
		_hand_order.append(card_id)
		py += CARD_BTN_HEIGHT + 4.0


func _get_panel_top_y() -> float:
	var vs := _get_viewport()
	var grid_h := Board.GRID_SIZE * Board.SLOT_SPACING.y
	return max(50.0, (vs.y - grid_h) / 2.0)


func _make_purchase_handler(card_id: String) -> Callable:
	return func():
		# G 不够时不触发购买
		var state := turn_manager.get_state()
		if state == null:
			return
		var player = state.players[state.active_player_index]
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			return
		if player.resources["G"] < card_data.cost_g:
			return
		card_purchased.emit(card_id)


func _try_select_for_deploy(card_id: String) -> void:
	var state := turn_manager.get_state()
	if state == null or state.phase != "deploy":
		return
	if _pending_deploy_card == card_id:
		cancel_deploy()
		return
	# 检查资源是否够
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	if card_data == null:
		return
	var player = state.players[state.active_player_index]
	if player.resources["Z"] < card_data.cost_k:
		return  # Z 不够
	# 检查是否有合法部署位置
	var deploy_rows: Array[int] = GameLogic.get_deployable_rows(state, state.active_player_index, card_id)
	if deploy_rows.is_empty():
		return  # 没有合法位置，不选中
	_pending_deploy_card = card_id
	_update_deploy_button_styles()
	if _board and is_instance_valid(_board):
		_board.highlight_deploy_zones(state.active_player_index, card_id)


func _make_deploy_handler(card_id: String) -> Callable:
	return func(): _try_select_for_deploy(card_id)


func cancel_deploy() -> void:
	_pending_deploy_card = ""
	_update_deploy_button_styles()
	if _board and is_instance_valid(_board):
		_board.clear_highlights()


func get_pending_deploy_card() -> String:
	return _pending_deploy_card


func _update_deploy_button_styles() -> void:
	for card_id in _hand_buttons:
		var btn: Button = _hand_buttons[card_id]
		if not is_instance_valid(btn):
			continue
		if card_id == _pending_deploy_card:
			btn.self_modulate = Color(0.3, 1.0, 0.3, 1.0)
		else:
			btn.self_modulate = Color(1.0, 1.0, 1.0, 1.0)


## ── 快捷键 ──

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var state := turn_manager.get_state() if turn_manager else null
	if state == null:
		return

	match event.keycode:
		KEY_SPACE:
			skip_phase_pressed.emit()
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			end_turn_pressed.emit()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			cancel_deploy()
			get_viewport().set_input_as_handled()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			_handle_number_key(event.keycode, state)


func _handle_number_key(keycode: int, state: BattleState) -> void:
	var idx: int = keycode - KEY_1  # 0-based index
	match state.phase:
		"purchase":
			if idx < _purchase_order.size():
				card_purchased.emit(_purchase_order[idx])
		"deploy":
			if idx < _hand_order.size():
				_try_select_for_deploy(_hand_order[idx])


func _clear_dynamic_ui() -> void:
	for i in range(get_child_count() - 1, -1, -1):
		var child := get_child(i)
		if child is Button:
			if child == _end_btn or child == _skip_btn:
				continue
			child.queue_free()
		elif child is Label and "—" in child.text:
			child.queue_free()
	_purchase_buttons.clear()
	_hand_buttons.clear()
	_purchase_order.clear()
	_hand_order.clear()
