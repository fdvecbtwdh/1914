extends Node

## 迷雾/占领度渲染回归 — 格子级迷雾层 + 战线占领度标签
## Run: godot --headless --path . res://tests/test_fog_front_scene.tscn
## 退出码 0 = 全部通过

var _failures := 0
var _checks := 0


func _ready() -> void:
	_run_all()
	print("\n========== FOG/FRONT RENDER SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL FOG/FRONT RENDER TESTS PASSED")
	else:
		printerr("%d FOG/FRONT RENDER TEST(S) FAILED" % _failures)
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
	state.board.set_unit(row, col, u)


func _run_all() -> void:
	var board = load("res://scenes/battle.tscn").instantiate()
	add_child(board)
	var tm := TurnManager.new()
	add_child(tm)
	board.setup(tm)

	var st := BattleState.new()
	st.setup(["test_infantry_01"], ["test_infantry_01"], "test_infantry_01", "test_infantry_01")

	# 1. 无己方单位 → 25 格全部盖雾
	tm.battle_state = st
	tm.state_changed.emit(st)
	var fog_layer: Control = board._fog_layer
	_check(fog_layer != null, "fog layer created")
	_check(fog_layer.z_index == 100, "fog layer above unit cards (z=100)")
	var fogged := 0
	for key in board._fog_rects:
		if board._fog_rects[key].visible:
			fogged += 1
	_check(fogged == 25, "no friendly units -> all 25 cells fogged, got %d" % fogged)

	# 2. P0 步兵在 (1,1) → 5 格揭开，20 格仍雾
	_place_unit(st, 0, 1, 1)
	tm.state_changed.emit(st)
	fogged = 0
	for key in board._fog_rects:
		if board._fog_rects[key].visible:
			fogged += 1
	_check(fogged == 20, "infantry at (1,1) -> 20 cells fogged, got %d" % fogged)
	_check(not board._fog_rects[Vector2i(1, 1)].visible, "own cell un-fogged")
	_check(not board._fog_rects[Vector2i(0, 1)].visible, "vision cell un-fogged")
	_check(board._fog_rects[Vector2i(4, 4)].visible, "distant cell stays fogged")

	# 3. 敌方单位雾中被格子级雾覆盖（z 序）：敌方单位卡存在但被 fog 层遮住
	_place_unit(st, 1, 3, 3)
	tm.state_changed.emit(st)
	_check(board._unit_displays.has(Vector2i(3, 3)), "enemy display node exists")
	var enemy_disp: Control = board._unit_displays[Vector2i(3, 3)]
	_check(fog_layer.z_index > 0 and enemy_disp.z_index == 0, "enemy card drawn below fog layer")

	# 4. 占领度标签：文本与颜色
	st.front_control = [50, -25, 100, 0, -100]
	tm.state_changed.emit(st)
	_check(board._front_labels.size() == 5, "5 front labels")
	_check(board._front_labels[0].text == "+50", "label 0 shows +50")
	_check(board._front_labels[1].text == "-25", "label 1 shows -25")
	_check(board._front_labels[2].text == "+100", "label 2 shows +100")
	_check(board._front_labels[3].text == "0", "label 3 shows 0")
	_check(board._front_labels[4].text == "-100", "label 4 shows -100")
	_check(board._front_labels[2].get_theme_color("font_color") == Color(1.0, 0.85, 0.2, 1.0),
		"label +100 gold (fully captured)")
	_check(board._front_labels[4].get_theme_color("font_color") == Color(1.0, 0.3, 0.3, 1.0),
		"label -100 red (enemy captured)")
	_check(board._front_labels[3].get_theme_color("font_color") == Color(0.7, 0.7, 0.7, 1.0),
		"label 0 gray (neutral)")
