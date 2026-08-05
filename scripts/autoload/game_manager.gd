extends Node

## 全局游戏管理 — 持有 TurnManager，加载卡组，初始化游戏

var turn_manager: TurnManager = null


func _ready() -> void:
	print("[GameManager] Initialized")
	# 延迟一帧等场景树就绪后自动开始
	call_deferred("_start_local_game")


func _start_local_game() -> void:
	# 加载卡组
	var deck_data := _load_deck("res://data/decks/player_default.json")
	if deck_data.is_empty():
		printerr("[GameManager] Failed to load deck!")
		return
	if not deck_data.has("cards") or not deck_data.has("starter"):
		printerr("[GameManager] Deck missing 'cards' or 'starter' field!")
		return
	var cards: Array = deck_data["cards"]
	var starter: String = deck_data["starter"]

	# 获取场景根节点（Board）
	var scene := get_tree().current_scene
	if scene == null:
		printerr("[GameManager] No current scene!")
		return

	# Board 是场景根节点
	var board := scene as Board
	if board == null:
		printerr("[GameManager] Scene root is not a Board!")
		return

	# 创建 TurnManager
	turn_manager = TurnManager.new()
	turn_manager.name = "TurnManager"
	scene.add_child(turn_manager)

	# 连接 Board
	board.setup(turn_manager)

	# 创建 HandManager
	var hand := HandManager.new()
	hand.name = "HandManager"
	scene.add_child(hand)
	hand.setup(turn_manager)

	# 连接 HandManager 信号 → TurnManager
	hand.card_purchased.connect(func(card_id: String):
		turn_manager.submit_action({"type": "purchase", "card_id": card_id})
	)
	hand.card_deployed.connect(func(card_id: String, _row: int, _col: int):
		var state := turn_manager.get_state()
		if state == null:
			return
		var player_idx := state.active_player_index
		var deploy_row := 0 if player_idx == 0 else 4
		turn_manager.submit_action({"type": "deploy", "card_id": card_id, "row": deploy_row, "col": 0})
	)
	hand.end_turn_pressed.connect(func():
		turn_manager.submit_action({"type": "end_turn"})
	)
	hand.skip_phase_pressed.connect(func():
		turn_manager.submit_action({"type": "skip_phase"})
	)

	# 游戏结束
	turn_manager.game_over.connect(func(winner: int):
		print("[GameManager] Game Over! Winner: Player %d" % (winner + 1))
	)

	# 开始游戏：双方共用同一套卡组
	turn_manager.start_game(cards.duplicate(), cards.duplicate(), starter, starter)
	print("[GameManager] Local game started")


func _load_deck(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("[GameManager] Cannot read deck: %s" % path)
		return {}
	var json_text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(json_text) != OK:
		printerr("[GameManager] JSON parse error in deck: %s" % path)
		return {}
	return json.get_data()
