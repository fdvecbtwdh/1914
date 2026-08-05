extends Node

## Temporary Task 6 verification runner — Board renders units from BattleState.
## Run: godot --headless --path . res://tests/task6_board_render_check.tscn
## Exit code 0 = all checks pass.

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== BOARD RENDER TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL BOARD RENDER TESTS PASSED")
	else:
		printerr("%d BOARD RENDER TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _place_unit(state: BattleState, owner: int, row: int, col: int) -> void:
	var u := BattleState.UnitData.new()
	u.card_id = "test_infantry_01"
	u.owner_index = owner
	u.attack = 2
	u.defense = 3
	u.max_defense = 3
	u.has_acted = false
	u.deployed_this_turn = false
	state.board.set_unit(row, col, u)


func _run_all() -> void:
	var card_data = CardDataLoader.load_all_cards().get("test_infantry_01")
	if card_data == null:
		printerr("test card not found — aborting")
		get_tree().quit(1)
		return

	var board = load("res://scenes/battle.tscn").instantiate()
	add_child(board)

	_test_slots_created(board)
	_test_no_test_card_at_edge(board)
	_test_setup_connects_signal(board, card_data)
	_test_render_positions_and_keys(board, card_data)
	_test_fog_on_enemy_only(board, card_data)
	_test_re_render_clears_old(board, card_data)
	_test_null_state_clears(board, card_data)
	_test_spawn_card_returns_control(board, card_data)


func _test_slots_created(board: Node) -> void:
	print("[slots created]")
	var slots = get_tree().get_nodes_in_group("board_slot")
	_check(slots.size() == 25, "25 board_slot nodes in group, got %d" % slots.size())
	_check(board.max_rows == 5, "max_rows defaults to 5")


func _test_no_test_card_at_edge(board: Node) -> void:
	print("[no hardcoded test card]")
	var card_children: Array[Node] = []
	for child in board.get_children():
		if child is CardDisplay:
			card_children.append(child)
	_check(card_children.is_empty(),
		"board has 0 CardDisplay children before any state render, got %d (spawn_test_card removed)" % card_children.size())


func _test_setup_connects_signal(board: Node, card_data: Resource) -> void:
	print("[setup(tm) connects state_changed]")
	var tm := TurnManager.new()
	add_child(tm)
	board.setup(tm)
	_check(board.turn_manager == tm, "board.turn_manager assigned after setup()")
	_check(tm.state_changed.is_connected(board._on_state_changed),
		"state_changed signal connected to _on_state_changed")

	# 手动构造一个带单位的 state 并发出信号 → board 应渲染
	var st := BattleState.new()
	_place_unit(st, 0, 1, 2)
	tm.state_changed.emit(st)
	_check(board._unit_displays.size() == 1, "emit state_changed rendered 1 unit, got %d" % board._unit_displays.size())
	board._clear_unit_displays()
	_check(board._unit_displays.is_empty(), "manual clear empties _unit_displays")


func _test_render_positions_and_keys(board: Node, _card_data: Resource) -> void:
	print("[render positions and Vector2i keys]")
	var st := BattleState.new()
	st.active_player_index = 0
	_place_unit(st, 0, 0, 0)
	_place_unit(st, 1, 4, 4)
	board._on_state_changed(st)
	_check(board._unit_displays.size() == 2, "rendered 2 units, got %d" % board._unit_displays.size())
	var d00: CardDisplay = board._unit_displays.get(Vector2i(0, 0))
	var d44: CardDisplay = board._unit_displays.get(Vector2i(4, 4))
	_check(d00 != null and d44 != null, "keys are Vector2i (0,0) and (4,4)")
	_check(d00 is CardDisplay and d44 is CardDisplay, "both displays are CardDisplay")
	_check(board._unit_displays.has(Vector2i(0, 1)) == false, "no display key at empty cell (0,1)")
	var expected_44 := Vector2(200, 50) + Vector2(4 * 90, 4 * 115)
	_check(d44.position == expected_44, "unit at (4,4) rendered at %s == expected %s" % [d44.position, expected_44])


func _test_fog_on_enemy_only(board: Node, _card_data: Resource) -> void:
	print("[fog overlay on enemy units]")
	var st := BattleState.new()
	st.active_player_index = 0  # P1 回合：P2(owner=1) 是敌方
	_place_unit(st, 0, 0, 0)
	_place_unit(st, 1, 4, 4)
	board._on_state_changed(st)
	var d00: CardDisplay = board._unit_displays[Vector2i(0, 0)]
	var d44: CardDisplay = board._unit_displays[Vector2i(4, 4)]
	# CardDisplay setup 有 3 个子节点（bg + name + stats），加迷雾后 4 个
	_check(d00.get_child_count() == 3, "friendly unit has no fog (3 children), got %d" % d00.get_child_count())
	_check(d44.get_child_count() == 4, "enemy unit has fog (4 children), got %d" % d44.get_child_count())
	var fog = d44.get_child(3)
	_check(fog is ColorRect, "fog child is ColorRect")
	_check((fog as ColorRect).color == Color(0.15, 0.15, 0.15, 1.0), "fog color is gray (0.15,0.15,0.15)")
	_check((fog as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE, "fog passes through mouse input")


func _test_re_render_clears_old(board: Node, _card_data: Resource) -> void:
	print("[re-render clears old displays]")
	var st1 := BattleState.new()
	_place_unit(st1, 0, 0, 0)
	board._on_state_changed(st1)
	var old: CardDisplay = board._unit_displays.get(Vector2i(0, 0))
	_check(old != null, "first render places unit at (0,0)")

	var st2 := BattleState.new()
	_place_unit(st2, 0, 2, 2)
	board._on_state_changed(st2)
	_check(old.is_queued_for_deletion(), "old display queued for deletion after re-render")
	_check(board._unit_displays.size() == 1, "_unit_displays has exactly 1 entry after re-render, got %d" % board._unit_displays.size())
	_check(board._unit_displays.has(Vector2i(0, 0)) == false, "old cell key (0,0) removed")
	_check(board._unit_displays.has(Vector2i(2, 2)), "new cell key (2,2) present")


func _test_null_state_clears(board: Node, _card_data: Resource) -> void:
	print("[null state clears]")
	var st := BattleState.new()
	_place_unit(st, 0, 0, 0)
	board._on_state_changed(st)
	_check(board._unit_displays.size() == 1, "render before null")
	board._on_state_changed(null)
	_check(board._unit_displays.is_empty(), "null state clears _unit_displays")


func _test_spawn_card_returns_control(board: Node, card_data: Resource) -> void:
	print("[board.spawn_card returns Control]")
	var card: Control = board.spawn_card(card_data)
	_check(card is Control, "board.spawn_card() returns Control")
	_check(card is CardDisplay, "spawned card is CardDisplay")
