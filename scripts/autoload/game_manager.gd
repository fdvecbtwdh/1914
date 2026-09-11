extends Node

## 全局游戏管理 — 持有 TurnManager，三模式入口（本地/局域网房主/局域网客机）
## 联网同步模型见 docs/superpowers/specs/2026-09-12-phase4-networking-design.md
## 两端只交换「种子 + 指令字典 + 状态指纹」：本端指令经 TurnManager 接受后转发对端；
## 远端指令走同一条 submit_action 校验链。action_applied 的回环用 _applying_remote 抑制。

enum GameMode { LOCAL, HOST, CLIENT }

var game_mode: GameMode = GameMode.LOCAL
var turn_manager: TurnManager = null

var _battle_ready := false       # 当前 battle 场景是否已接线
var _applying_remote := false    # 正在应用远端指令（抑制转发回环）


func _ready() -> void:
	print("[GameManager] Initialized")
	# 场景树就绪后：若直接运行 battle.tscn（场景根是 Board）→ 自动本地开局；
	# 若运行主菜单 → 等待菜单选择
	call_deferred("_auto_enter")


func _auto_enter() -> void:
	# 命令行直入（双进程自动化测试/快速联机）：
	#   godot --path . -- --net=host | --net=join:IP | --auto（脚本代打）
	var args := OS.get_cmdline_user_args()
	var want_auto := "--auto" in args
	for arg in args:
		if arg == "--net=host":
			game_mode = GameMode.HOST
			if NetworkManager.host_game() != OK:
				game_mode = GameMode.LOCAL
			_enter_battle()
			if want_auto:
				_spawn_autopilot()
			return
		if arg.begins_with("--net=join:"):
			game_mode = GameMode.CLIENT
			start_join_game(arg.substr("--net=join:".length()))
			if want_auto:
				_spawn_autopilot()
			return

	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene is Board:
		_setup_battle()
		if want_auto:
			_spawn_autopilot()


func _spawn_autopilot() -> void:
	var script := load("res://tests/net_autopilot.gd")
	if script == null:
		return
	var pilot: Node = script.new()
	pilot.name = "NetAutopilot"
	get_tree().root.add_child.call_deferred(pilot)


# ═══════════════ 模式入口（主菜单调用） ═══════════════

func start_local_game() -> void:
	game_mode = GameMode.LOCAL
	_enter_battle()


func start_host_game() -> void:
	game_mode = GameMode.HOST
	var err: Error = NetworkManager.host_game()
	if err != OK:
		game_mode = GameMode.LOCAL
		return
	_enter_battle()


func start_join_game(ip: String) -> void:
	game_mode = GameMode.CLIENT
	NetworkManager.join_game(ip)
	# 等连接建立（成功→进战斗场景；失败/超时→留在菜单）
	var connected := [false]
	var on_ok := func(): connected[0] = true
	NetworkManager.connected_ok.connect(on_ok)
	for i in range(120):
		if connected[0] or not NetworkManager.is_network_game:
			break
		await get_tree().create_timer(0.1).timeout
	NetworkManager.connected_ok.disconnect(on_ok)
	if connected[0]:
		_enter_battle()
	else:
		game_mode = GameMode.LOCAL


func quit_game() -> void:
	NetworkManager.leave()
	get_tree().quit()


func _enter_battle() -> void:
	get_tree().change_scene_to_file("res://scenes/battle.tscn")
	await get_tree().process_frame
	await get_tree().process_frame
	_setup_battle()


# ═══════════════ 战斗场景接线 ═══════════════

func _setup_battle() -> void:
	if _battle_ready:
		return
	var scene := get_tree().current_scene
	if scene == null:
		printerr("[GameManager] No current scene!")
		return
	var board := scene as Board
	if board == null:
		printerr("[GameManager] Scene root is not a Board!")
		return

	turn_manager = TurnManager.new()
	turn_manager.name = "TurnManager"
	scene.add_child(turn_manager)

	board.setup(turn_manager)

	var hand := HandManager.new()
	hand.name = "HandManager"
	scene.add_child(hand)
	hand.setup(turn_manager)
	hand._board = board

	# ── 本端 UI → 过滤 → TurnManager ──
	hand.card_purchased.connect(func(card_id: String):
		_submit_local({"type": "purchase", "card_id": card_id})
	)
	board.slot_clicked.connect(func(row: int, col: int):
		var pending := hand.get_pending_deploy_card()
		if pending == "":
			return
		_submit_local({"type": "deploy", "card_id": pending, "row": row, "col": col})
		hand.cancel_deploy()
	)
	hand.end_turn_pressed.connect(func():
		_submit_local({"type": "end_turn"})
	)
	hand.skip_phase_pressed.connect(func():
		_submit_local({"type": "skip_phase"})
	)
	board.move_requested.connect(func(from_r: int, from_c: int, to_r: int, to_c: int):
		_submit_local({"type": "move", "from_row": from_r, "from_col": from_c, "to_row": to_r, "to_col": to_c})
	)
	board.attack_requested.connect(func(from_r: int, from_c: int, target_r: int, target_c: int):
		_submit_local({"type": "attack", "from_row": from_r, "from_col": from_c, "target_row": target_r, "target_col": target_c})
	)

	# ── 指令被接受后 → 转发对端 + 状态指纹核对 ──
	turn_manager.action_applied.connect(func(action: Dictionary):
		if _applying_remote:
			return  # 远端指令不再回传
		if NetworkManager.is_network_game:
			NetworkManager.send_action(action)
			NetworkManager.send_check(GameLogic.state_fingerprint(turn_manager.battle_state))
	)

	# ── 远端指令 → TurnManager（同一条校验链） ──
	NetworkManager.action_received.connect(func(action: Dictionary):
		_applying_remote = true
		turn_manager.submit_action(action)
		_applying_remote = false
	)

	# ── 收到开局包（房主本地触发 / 客机网络触发，路径一致） ──
	NetworkManager.game_start_received.connect(_on_net_game_start)

	turn_manager.game_over.connect(func(winner: int):
		print("[GameManager] Game Over! Winner: Player %d" % (winner + 1))
	)

	_battle_ready = true

	# ── 启动对局 ──
	if game_mode == GameMode.LOCAL or not NetworkManager.is_network_game:
		var deck := _load_deck("res://data/decks/player_default.json")
		if deck.is_empty():
			return
		var cards: Array[String] = []
		cards.assign(deck["cards"])
		turn_manager.start_game(cards.duplicate(), cards.duplicate(), deck["starter"], deck["starter"])
		print("[GameManager] Local game started")
	else:
		NetworkManager.set_local_scene_ready()
		print("[GameManager] Battle scene ready, waiting for game start…")


func _on_net_game_start(payload: Dictionary) -> void:
	var p1_deck: Array[String] = []
	p1_deck.assign(payload["p1_deck"])
	var p2_deck: Array[String] = []
	p2_deck.assign(payload["p2_deck"])
	turn_manager.start_game(p1_deck, p2_deck, payload["p1_starter"], payload["p2_starter"])
	print("[GameManager] Network game started (local player = P%d)" % (NetworkManager.local_player_idx + 1))


## 本端输入统一入口：网络模式下只允许轮到自己时操作
func _submit_local(action: Dictionary) -> void:
	if NetworkManager.is_network_game and turn_manager != null and turn_manager.battle_state != null:
		if turn_manager.battle_state.active_player_index != NetworkManager.local_player_idx:
			print("[GameManager] 等待对手行动…")
			return
	turn_manager.submit_action(action)


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
