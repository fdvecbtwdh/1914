extends Node2D
class_name HandManager

## 手牌/购买区/资源 UI — 从 BattleState 读取，响应 TurnManager 信号

signal card_purchased(card_id: String)
signal order_played(card_id: String)
signal end_turn_pressed()
signal skip_phase_pressed()

## 右侧面板配置
const PANEL_MIN_X: float = 500.0
const CARD_BTN_HEIGHT: float = 32.0

var turn_manager: TurnManager = null
var _board: Board = null
var _purchase_buttons: Dictionary = {}
var _hand_buttons: Dictionary = {}
var _purchase_order: Array[String] = []   # 按渲染顺序排列的 card_id
var _hand_order: Array[String] = []       # 按渲染顺序排列的 card_id
var _end_btn: Button = null
var _skip_btn: Button = null
var _cancel_btn: Button = null
var _g_label: Label = null
var _k_label: Label = null
var _z_label: Label = null
var _phase_label: Label = null
var _player_label: Label = null
var _turn_label: Label = null
var _pending_deploy_card: String = ""
var _banner: Label = null

## ── 表现层动画状态 ──
var _prev_ui_state: BattleState = null   # 上一帧状态，用于资源/回合数字差值
var _banner_text: String = ""            # 上次横幅文案（变化时才播入场动画）
var _end_breath: Tween = null            # 结束回合按钮的呼吸补间
var _end_btn_breathing: bool = false


func setup(tm: TurnManager) -> void:
	turn_manager = tm
	_build_ui()  # 先构建，再连接信号（避免 build 前的状态变更打到 null 控件）
	turn_manager.state_changed.connect(_on_state_changed)
	turn_manager.game_over.connect(_on_game_over)
	turn_manager.action_applied.connect(_on_action_applied)


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

	# ── 取消部署（触屏设备的显式取消路径；选中卡牌时才显示） ──
	_cancel_btn = Button.new()
	_cancel_btn.text = "取消部署"
	_cancel_btn.position = Vector2(btn_x, 80)
	_cancel_btn.size.x = BTN_W
	_cancel_btn.visible = false
	_cancel_btn.pressed.connect(cancel_deploy)
	add_child(_cancel_btn)

	# ── 操作提示（按平台显示对应方式） ──
	# ── 顶部中央横幅：回合归属 / 等待对手 / 胜负结果 ──
	_banner = Label.new()
	_banner.position = Vector2(vs.x / 2.0 - 150.0, 10)
	_banner.size = Vector2(300.0, 26.0)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 16)
	add_child(_banner)

	# ── 操作提示（按平台显示对应方式） ──
	var hint := Label.new()
	hint.text = _input_hint_text()
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


## 按平台返回操作提示：桌面显示键盘快捷键，触屏设备提示点按操作
func _input_hint_text() -> String:
	match DisplayServer.get_name():
		"Android", "iOS", "Web":
			return "点按卡牌选择  点棋盘格部署  再点已选卡取消"
	return "1-5 选卡  Space 下一阶段  Enter 结束回合  Esc 取消"


func _on_state_changed(new_state: BattleState) -> void:
	var prev := _prev_ui_state
	_prev_ui_state = new_state
	_pending_deploy_card = ""
	if _cancel_btn != null:
		_cancel_btn.visible = false
	if _board and is_instance_valid(_board):
		_board.clear_highlights()
	_clear_dynamic_ui()
	if new_state == null:
		return
	_update_info(new_state, prev)
	_update_resources(new_state, prev)
	_render_purchase_zone(new_state, prev)
	_render_hand(new_state, prev)
	_update_turn_ui(new_state, prev)


## 回合横幅 + 控制按钮可用性（联网按本地玩家视角，本地同屏按行动方）
func _update_turn_ui(state: BattleState, _prev: BattleState = null) -> void:
	if _banner == null:
		return
	var text := ""
	var color := Color(0.7, 0.7, 0.7)
	var controls := true
	var kind := "info"
	if state.winner != -1:
		text = "玩家 %d 获胜！" % (state.winner + 1)
		color = Color(1.0, 0.85, 0.2)
		controls = false
		kind = "win"
	elif NetworkManager.opponent_left:
		text = "对手已断线，本局无效"
		color = Color(1.0, 0.4, 0.4)
		controls = false
		kind = "error"
	elif GameManager.ai_player_idx >= 0 and state.active_player_index == GameManager.ai_player_idx:
		var diff_name: String = {"easy": "简单", "normal": "普通", "hard": "困难"}.get(GameManager.ai_difficulty, GameManager.ai_difficulty)
		text = "AI 行动中（%s）…" % diff_name
		color = Color(0.95, 0.75, 0.4)
		controls = false
		kind = "ai"
	else:
		var local := NetworkManager.local_player_idx if NetworkManager.is_network_game else state.active_player_index
		if state.active_player_index == local:
			text = "轮到你行动"
			color = Color(0.4, 1.0, 0.5)
			kind = "you"
		else:
			text = "等待对手行动…"
			color = Color(0.7, 0.7, 0.7)
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	if controls:
		# 结束回合仅在 action 阶段可用
		_end_btn.disabled = state.phase != "action"
		_skip_btn.disabled = false
	else:
		_end_btn.disabled = true
		_skip_btn.disabled = true
	# 可点状态下轻微呼吸，提示"现在轮到你操作"
	_update_end_btn_breath(controls and not _end_btn.disabled)
	# 横幅文案变化才播入场，避免每次 action 重绘都闪
	if text != _banner_text:
		_banner_text = text
		UiAnim.fade_in_scale(_banner, 0.92, 0.24)
		if kind == "win":
			UiAnim.pop(_banner, 1.35, 0.5)
		elif kind == "you":
			UiAnim.tint(_banner, Color(1.35, 1.35, 1.35), 0.55)


## 结束回合按钮呼吸（只在真正可点时开）
func _update_end_btn_breath(on: bool) -> void:
	if _end_btn == null:
		return
	if on == _end_btn_breathing:
		return
	_end_btn_breathing = on
	if _end_breath != null and _end_breath.is_valid():
		_end_breath.kill()
	_end_breath = null
	_end_btn.self_modulate = Color(1.0, 1.0, 1.0, 1.0)
	if not on:
		return
	var t := _end_btn.create_tween().set_loops()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(_end_btn, "self_modulate", Color(1.0, 1.0, 1.0, 0.72), 0.9)
	t.tween_property(_end_btn, "self_modulate", Color(1.0, 1.0, 1.0, 1.0), 0.9)
	_end_breath = t


## 指令卡使用反馈：横幅弹一下 + 卡片名飘字
func _on_action_applied(action: Dictionary) -> void:
	if str(action.get("type", "")) != "play_order":
		return
	var card_id := str(action.get("card_id", ""))
	var card_data: Resource = CardDataLoader.cards.get(card_id)
	var card_name := str(card_data.card_name) if card_data != null else card_id
	var vs := _get_viewport()
	UiAnim.float_text(self, "指令 · %s" % card_name, Vector2(vs.x * 0.5 - 46.0, 44.0),
		Color(1.0, 0.86, 0.42), 16, 28.0, 0.9)
	if _banner != null and is_instance_valid(_banner):
		UiAnim.pop(_banner, 1.18, 0.3)


func _on_game_over(winner: int) -> void:
	if _banner != null:
		_banner.text = "玩家 %d 获胜！" % (winner + 1)
		_banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
		_banner_text = _banner.text
		UiAnim.pop(_banner, 1.4, 0.5)
		UiAnim.tint(_banner, Color(1.6, 1.3, 0.7), 0.7)
	_set_controls_enabled(false)


func _set_controls_enabled(enabled: bool) -> void:
	if _end_btn != null:
		_end_btn.disabled = not enabled
	if _skip_btn != null:
		_skip_btn.disabled = not enabled


func _update_info(state: BattleState, prev: BattleState = null) -> void:
	_turn_label.text = "回合 %d" % state.turn
	_player_label.text = "玩家 %d" % (state.active_player_index + 1)
	_phase_label.text = "阶段: %s" % state.phase
	if prev == null:
		return
	# 数值变化时弹一下：回合数/行动方/阶段
	if prev.turn != state.turn:
		UiAnim.pop(_turn_label, 1.22, 0.3)
	if prev.active_player_index != state.active_player_index:
		UiAnim.pop(_player_label, 1.22, 0.3)
	if prev.phase != state.phase:
		UiAnim.pop(_phase_label, 1.18, 0.24)


func _update_resources(state: BattleState, prev: BattleState = null) -> void:
	var player = state.players[state.active_player_index]
	var g := int(player.resources["G"])
	var k := int(player.resources["K"])
	var z := int(player.resources["Z"])
	# 文本同步写成最终值：动画只做视觉余韵，不得改变最终读数
	_g_label.text = "G: %d" % g
	_k_label.text = "K: %d" % k
	_z_label.text = "Z: %d" % z
	if prev == null or prev.active_player_index != state.active_player_index:
		return  # 换人时资源归位，不做差值动画
	var pp = prev.players[prev.active_player_index]
	_animate_resource_delta(_g_label, "G", g, int(pp.resources["G"]))
	_animate_resource_delta(_k_label, "K", k, int(pp.resources["K"]))
	_animate_resource_delta(_z_label, "Z", z, int(pp.resources["Z"]))


## 资源数字变化：弹一下 + 涨绿跌红 + 浮动增量
func _animate_resource_delta(lbl: Label, key: String, now: int, before: int) -> void:
	if lbl == null or not is_instance_valid(lbl) or now == before:
		return
	var delta := now - before
	var up := delta > 0
	UiAnim.pop(lbl, 1.25, 0.24)
	UiAnim.tint(lbl, Color(0.6, 1.0, 0.6) if up else Color(1.0, 0.55, 0.55), 0.5)
	var txt := ("+%d" % delta) if up else str(delta)
	UiAnim.float_text(self, "%s %s" % [key, txt], lbl.position + Vector2(0, -6),
		Color(0.5, 1.0, 0.55) if up else Color(1.0, 0.5, 0.5), 13, 20.0, 0.65)


func _render_purchase_zone(state: BattleState, prev: BattleState = null) -> void:
	var player = state.players[state.active_player_index]
	_purchase_order.clear()
	if player.purchase_zone.is_empty():
		return
	var px := _get_panel_x()
	var py := _get_panel_top_y()
	# 新出现的购买选项滑入（首帧/换人时全部滑入，同回合补货只滑新卡）
	var prev_ids: Array = []
	var animate_all := prev == null or prev.active_player_index != state.active_player_index
	if prev != null:
		prev_ids = prev.players[prev.active_player_index].purchase_zone
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
		# 6.2 稀有度标识 + 每回合购买上限（银3/金2）达到时置灰
		var rarity_tag := _rarity_tag(str(card_data.rarity))
		btn.text = "[%d]%s %s (G:%d)" % [idx, rarity_tag, card_data.card_name, card_data.cost_g]
		var rarity := str(card_data.rarity)
		var bought: int = int(player.purchases_this_turn.get(rarity, 0))
		var limit: int = GameLogic.PURCHASE_LIMITS.get(rarity, 99)
		if bought >= limit:
			btn.disabled = true
			btn.text += " 已达上限"
		var card_cost: int = card_data.cost_g
		if player.resources["G"] < card_cost:
			btn.disabled = true  # G 不足也置灰（原逻辑为静默点击无效）
		btn.position = Vector2(px, py)
		btn.size.x = 190.0
		btn.pressed.connect(_make_purchase_handler(card_id))
		add_child(btn)
		if animate_all or not prev_ids.has(card_id):
			UiAnim.slide_in(btn, Vector2(16, 0), 0.22)
		_purchase_buttons[card_id] = btn
		_purchase_order.append(card_id)
		py += CARD_BTN_HEIGHT + 4.0


func _rarity_tag(rarity: String) -> String:
	match rarity:
		"silver":
			return "[银]"
		"gold":
			return "[金]"
	return "[铜]"


func _render_hand(state: BattleState, prev: BattleState = null) -> void:
	var player = state.players[state.active_player_index]
	# 新手牌滑入：首帧全部滑入；同回合内只有真正新抽到的卡滑入
	var prev_ids: Array = []
	if prev != null:
		prev_ids = prev.players[prev.active_player_index].hand
	var animate_all := prev == null
	var same_player := prev != null and prev.active_player_index == state.active_player_index
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
	var in_deploy_phase := state.phase == "deploy"
	for card_id in player.hand:
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null:
			continue
		idx += 1
		var btn := Button.new()
		var is_order: bool = card_data.type == "order"
		if is_order:
			# 6A.1 指令卡：K 费标识，行动阶段 K 足够即可使用
			btn.text = "[%d] ↯ %s (K:%d)" % [idx, card_data.card_name, card_data.cost_k]
			var can_play: bool = state.phase == "action" and state.active_player_index == _ui_player_idx(state) and state.players[_ui_player_idx(state)].resources["K"] >= card_data.cost_k
			if not can_play:
				btn.disabled = true
				btn.tooltip_text = "行动阶段且指挥点 K 足够时才能使用"
			else:
				btn.tooltip_text = str(card_data.effect_text)
			btn.pressed.connect(_make_order_handler(card_id))
		else:
			btn.text = "[%d] %s (Z:%d) %d/%d" % [idx, card_data.card_name, card_data.cost_z, card_data.attack, card_data.defense]
			# 4.3 部署就绪标识：部署阶段基于引擎判定显示可/不可部署及原因
			if in_deploy_phase:
				var verdict: Dictionary = GameLogic.can_deploy(state, state.active_player_index, card_id)
				if bool(verdict.get("ok", false)):
					btn.text = "✓ " + btn.text
					btn.tooltip_text = "本回合可以部署"
				else:
					btn.text = "✗ " + btn.text
					btn.disabled = true
					btn.tooltip_text = str(verdict.get("reason", "本回合不能部署"))
			btn.pressed.connect(_make_deploy_handler(card_id))
		btn.position = Vector2(px, py)
		btn.size.x = 190.0
		add_child(btn)
		if animate_all or (same_player and not prev_ids.has(card_id)):
			UiAnim.slide_in(btn, Vector2(18, 0), 0.22)
		_hand_buttons[card_id] = btn
		_hand_order.append(card_id)
		py += CARD_BTN_HEIGHT + 4.0


func _ui_player_idx(state: BattleState) -> int:
	if NetworkManager.is_network_game:
		return NetworkManager.local_player_idx
	if GameManager.ai_player_idx >= 0:
		return 1 - GameManager.ai_player_idx
	return state.active_player_index


func _make_order_handler(card_id: String) -> Callable:
	return func():
		var state := turn_manager.get_state()
		if state == null or state.phase != "action":
			return
		var player = state.players[_ui_player_idx(state)]
		var card_data: Resource = CardDataLoader.cards.get(card_id)
		if card_data == null or player.resources["K"] < card_data.cost_k:
			return
		order_played.emit(card_id)


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
	if player.resources["Z"] < card_data.cost_z:
		return  # Z 不够
	# 响应词条：本回合购买的卡（无响应）当回合不能部署，不给予选中
	var purchase_turn: int = player.hand_card_purchase_turn.get(card_id, -1)
	if purchase_turn == state.turn and not card_data.abilities.has("响应"):
		return
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
	if _cancel_btn != null:
		_cancel_btn.visible = _pending_deploy_card != ""
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
