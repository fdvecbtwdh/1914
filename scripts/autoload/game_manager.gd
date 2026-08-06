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
	var raw_cards: Array = deck_data["cards"]
	var cards: Array[String] = []
	cards.assign(raw_cards)
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
	hand._board = board

	# 连接 HandManager 信号 → TurnManager
	hand.card_purchased.connect(func(card_id: String):
		turn_manager.submit_action({"type": "purchase", "card_id": card_id})
	)
	# 点击棋盘格子 → 如果有待部署的牌，部署到该格
	board.slot_clicked.connect(func(row: int, col: int):
		var pending := hand.get_pending_deploy_card()
		if pending == "":
			return
		turn_manager.submit_action({"type": "deploy", "card_id": pending, "row": row, "col": col})
		hand.cancel_deploy()
	)
	hand.end_turn_pressed.connect(func():
		turn_manager.submit_action({"type": "end_turn"})
	)
	hand.skip_phase_pressed.connect(func():
		turn_manager.submit_action({"type": "skip_phase"})
	)

	# 行动阶段：移动单位
	board.move_requested.connect(func(from_r: int, from_c: int, to_r: int, to_c: int):
		turn_manager.submit_action({"type": "move", "from_row": from_r, "from_col": from_c, "to_row": to_r, "to_col": to_c})
	)

	# 行动阶段：攻击单位
	board.attack_requested.connect(func(from_r: int, from_c: int, target_r: int, target_c: int):
		turn_manager.submit_action({"type": "attack", "from_row": from_r, "from_col": from_c, "target_row": target_r, "target_col": target_c})
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
