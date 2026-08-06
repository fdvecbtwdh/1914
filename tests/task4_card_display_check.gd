extends Node

## Temporary Task 4 verification runner — CardDisplay Control conversion.
## Run: godot --headless --path . res://tests/task4_card_display_check.tscn
## Exit code 0 = all checks pass.

var _failures := 0
var _checks := 0


func _ready() -> void:
	await _run_all()
	print("\n========== CARD DISPLAY TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL CARD DISPLAY TESTS PASSED")
	else:
		printerr("%d CARD DISPLAY TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


func _run_all() -> void:
	var card_data = CardDataLoader.load_all_cards().get("test_infantry_01")
	if card_data == null:
		printerr("test card not found — aborting")
		get_tree().quit(1)
		return

	_test_card_is_control(card_data)
	_test_setup_idempotent(card_data)
	_test_control_props(card_data)
	_test_place_card_accepts_control(card_data)
	_test_spawn_card_returns_control(card_data)
	await _test_gui_drag_drop(card_data)
	await _test_viewport_routing_probe()


func _make_card(data: Resource) -> Control:
	var card: Control = load("res://scenes/ui_components/card.tscn").instantiate()
	card.setup(data)
	return card


func _test_card_is_control(_data: Resource) -> void:
	print("[card is Control]")
	var card = load("res://scenes/ui_components/card.tscn").instantiate()
	_check(card is Control, "card root node is Control")
	_check(not (card is Node2D), "card root node is not Node2D")


func _test_setup_idempotent(data: Resource) -> void:
	print("[setup idempotent]")
	var card = _make_card(data)
	var first = card.get_child_count()
	card.setup(data)
	var second = card.get_child_count()
	_check(first == second, "setup() twice does not duplicate children (%d == %d)" % [first, second])
	_check(first == 3, "card has 3 children (bg + name label + stats label), got %d" % first)


func _test_control_props(data: Resource) -> void:
	print("[control props]")
	var card = _make_card(data)
	_check(card.mouse_filter == Control.MOUSE_FILTER_STOP, "mouse_filter is MOUSE_FILTER_STOP")
	_check(card.custom_minimum_size == Vector2(80, 100), "custom_minimum_size is CARD_SIZE (80x100)")


func _test_place_card_accepts_control(data: Resource) -> void:
	print("[place_card accepts Control]")
	var card = _make_card(data)
	var slot = load("res://scenes/ui_components/board_slot.tscn").instantiate()
	add_child(slot)
	slot.place_card(card)
	_check(slot.occupied_card == card, "slot.occupied_card set to Control card")
	_check(card.position == Vector2.ZERO, "placed card position zeroed")
	_check(card.get_parent() == slot, "card reparented into slot")


func _test_spawn_card_returns_control(data: Resource) -> void:
	print("[board.spawn_card return type]")
	var board = load("res://scenes/battle.tscn").instantiate()
	add_child(board)
	var card = board.spawn_card(data)
	_check(card is Control, "board.spawn_card() returns Control")
	_check(card is CardDisplay, "spawned card is CardDisplay")


func _test_gui_drag_drop(data: Resource) -> void:
	print("[_gui_input drag -> drop on slot (direct handler call)]")
	# headless 下鼠标位置固定为 (0,0)，因此把格子放在 rect 含 (0,0) 的位置
	var card = _make_card(data)
	card.position = Vector2(100, 300)
	add_child(card)

	var slot = load("res://scenes/ui_components/board_slot.tscn").instantiate()
	slot.position = Vector2(-40, -50)  # rect (-40,-50)-(40,50) 包含 (0,0)
	add_child(slot)
	slot.slot_row = 0
	slot.slot_col = 0

	# 等两帧让 Control 布局生效
	await get_tree().process_frame
	await get_tree().process_frame
	_check(card.size == Vector2(80, 100), "card.size becomes CARD_SIZE after entering tree, got %s" % card.size)

	# 1) 按下：_gui_input 收到的 position 是卡牌局部坐标 (40,20)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(40, 20)  # control-local
	press.global_position = Vector2(140, 320)
	card._gui_input(press)
	_check(card.is_dragging, "press starts drag")
	_check(card.drag_offset == Vector2(40, 20), "drag_offset = local grab point, got %s" % card.drag_offset)
	_check(card.get_parent() == get_tree().current_scene, "card reparented to scene root during drag")

	# 2) 喂一个 motion 给 _gui_input：应满足 global_position = 鼠标位置 - drag_offset
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(0, 0)
	motion.global_position = Vector2(0, 0)
	card._gui_input(motion)
	var expected_pos: Vector2 = card.get_global_mouse_position() - card.drag_offset
	_check(card.global_position == expected_pos,
		"card follows mouse: global_position == mouse - drag_offset (%s), got %s" % [expected_pos, card.global_position])

	# 3) 释放：鼠标 (0,0) 位于格子 rect (-40,-50)-(40,50) 内 → 应放入格子
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(0, 0)
	release.global_position = Vector2(0, 0)
	card._gui_input(release)
	_check(slot.occupied_card == card, "card dropped onto slot")
	_check(not card.is_dragging, "drag ended after release")


func _test_viewport_routing_probe() -> void:
	print("[viewport push_input GUI routing probe (informational)]")
	var probe := Control.new()
	probe.position = Vector2(200, 400)
	probe.size = Vector2(80, 100)
	var hit_count := 0
	probe.gui_input.connect(func(_ev): hit_count += 1)
	add_child(probe)
	await get_tree().process_frame
	await get_tree().process_frame

	var m := InputEventMouseMotion.new()
	m.position = Vector2(240, 450)
	m.global_position = Vector2(240, 450)
	get_viewport().push_input(m)
	await get_tree().process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(240, 450)
	press.global_position = Vector2(240, 450)
	get_viewport().push_input(press)
	await get_tree().process_frame
	# 仅记录，不判失败 —— headless 下 GUI 路由是引擎行为，与真实窗口不同
	print("  [info] headless push_input routed %d event(s) to a plain Control" % hit_count)
