extends Node

## Temporary Task 7 verification runner — HandManager renders purchase zone, hand, resources.
## Run: godot --headless --path . res://tests/task7_hand_manager_check.tscn
## Exit code 0 = all checks pass.

var _failures := 0
var _checks := 0

## 信号捕获用成员变量（lambda 按值捕获局部变量，需经 self 引用）
var _captured_purchase := ""
var _captured_deploy_id := ""
var _captured_deploy_row := -99
var _captured_deploy_col := -99
var _end_emitted := false
var _skip_emitted := false


func _ready() -> void:
	_run_all()
	print("\n========== HAND MANAGER TEST SUMMARY ==========")
	print("Checks: %d, Failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("ALL HAND MANAGER TESTS PASSED")
	else:
		printerr("%d HAND MANAGER TEST(S) FAILED" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: " + msg)
	else:
		_failures += 1
		printerr("  FAIL: " + msg)


## 构造可控的 BattleState：购买区 2 张、手牌 1 张、资源 120/2/3
func _make_state() -> BattleState:
	var st := BattleState.new()
	st.setup(["infantry_01", "cavalry_01", "artillery_01"],
	         ["infantry_01", "cavalry_01"],
	         "infantry_01", "infantry_01")
	st.turn = 3
	st.phase = "deploy"
	st.active_player_index = 0
	st.players[0].purchase_zone = ["infantry_01", "cavalry_01"]
	st.players[0].hand = ["artillery_01"]
	st.players[0].resources = {"G": 120, "K": 2, "Z": 3}
	return st


## 统计未被删除的标题 Label（"— xxx —"）
func _count_title_labels(hand: Node) -> int:
	var n := 0
	for child in hand.get_children():
		if child is Label and "—" in child.text and not child.is_queued_for_deletion():
			n += 1
	return n


func _find_button_by_text(hand: Node, text: String) -> Button:
	for child in hand.get_children():
		if child is Button and child.text == text:
			return child
	return null


func _make_hand_and_tm() -> Array:
	var tm := TurnManager.new()
	add_child(tm)
	var hand: HandManager = HandManager.new()
	add_child(hand)
	hand.setup(tm)
	return [tm, hand]


func _run_all() -> void:
	var cards := CardDataLoader.load_all_cards()
	if cards.is_empty():
		printerr("No cards loaded — aborting")
		get_tree().quit(1)
		return
	_test_class_extends_node2d()
	_test_setup_builds_persistent_ui()
	_test_state_changed_renders()
	_test_info_and_resource_labels()
	_test_purchase_button_signal()
	_test_deploy_button_signal()
	_test_control_button_signals()
	_test_clear_dynamic_ui_frees_buttons_and_titles()
	_test_re_render_after_clear()
	_test_null_state_clears()


func _test_class_extends_node2d() -> void:
	print("[class_name HandManager extends Node2D]")
	var hand := HandManager.new()
	_check(hand is Node2D, "HandManager instance is Node2D")
	hand.free()


func _test_setup_builds_persistent_ui() -> void:
	print("[setup builds persistent UI]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	_check(hand.turn_manager == tm, "turn_manager assigned after setup()")
	_check(tm.state_changed.is_connected(hand._on_state_changed), "state_changed connected to _on_state_changed")
	_check(hand._turn_label != null and hand._turn_label.is_inside_tree(), "turn label created and in tree")
	_check(hand._player_label != null and hand._phase_label != null, "player/phase labels created")
	_check(hand._g_label != null and hand._k_label != null and hand._z_label != null, "G/K/Z resource labels created")
	_check(_find_button_by_text(hand, "结束回合") != null, "结束回合 button created")
	_check(_find_button_by_text(hand, "跳过阶段") != null, "跳过阶段 button created")
	# 动态区初始为空
	_check(hand._purchase_buttons.is_empty(), "no purchase buttons before any state")
	_check(hand._hand_buttons.is_empty(), "no hand buttons before any state")
	hand.queue_free()
	tm.queue_free()


func _test_state_changed_renders() -> void:
	print("[state_changed renders purchase zone + hand]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	var st := _make_state()
	tm.state_changed.emit(st)
	_check(hand._purchase_buttons.size() == 2, "2 purchase buttons, got %d" % hand._purchase_buttons.size())
	_check(hand._hand_buttons.size() == 1, "1 hand button, got %d" % hand._hand_buttons.size())
	_check(_count_title_labels(hand) == 2, "2 section title labels, got %d" % _count_title_labels(hand))
	var pbtn: Button = hand._purchase_buttons.get("infantry_01")
	_check(pbtn != null and pbtn.text == "步兵 (G:30)", "purchase button text '%s'" % (pbtn.text if pbtn else ""))
	var hbtn: Button = hand._hand_buttons.get("artillery_01")
	_check(hbtn != null and hbtn.text == "火炮 (Z:1) 5/2", "hand button text '%s'" % (hbtn.text if hbtn else ""))
	hand.queue_free()
	tm.queue_free()


func _test_info_and_resource_labels() -> void:
	print("[info + resource labels updated]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	var st := _make_state()
	tm.state_changed.emit(st)
	_check(hand._turn_label.text == "回合 3", "turn label '%s'" % hand._turn_label.text)
	_check(hand._player_label.text == "玩家 1", "player label '%s'" % hand._player_label.text)
	_check(hand._phase_label.text == "阶段: deploy", "phase label '%s'" % hand._phase_label.text)
	_check(hand._g_label.text == "G: 120", "G label '%s'" % hand._g_label.text)
	_check(hand._k_label.text == "K: 2", "K label '%s'" % hand._k_label.text)
	_check(hand._z_label.text == "Z: 3", "Z label '%s'" % hand._z_label.text)
	hand.queue_free()
	tm.queue_free()


func _test_purchase_button_signal() -> void:
	print("[purchase button emits card_purchased(card_id)]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	tm.state_changed.emit(_make_state())
	_captured_purchase = ""
	hand.card_purchased.connect(func(id: String): _captured_purchase = id)
	var btn: Button = hand._purchase_buttons["infantry_01"]
	btn.pressed.emit()
	_check(_captured_purchase == "infantry_01", "card_purchased emits 'infantry_01', got '%s'" % _captured_purchase)
	hand.queue_free()
	tm.queue_free()


func _test_deploy_button_signal() -> void:
	print("[deploy button emits card_deployed(card_id, -1, -1)]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	tm.state_changed.emit(_make_state())
	_captured_deploy_id = ""
	_captured_deploy_row = -99
	_captured_deploy_col = -99
	hand.card_deployed.connect(func(id: String, r: int, c: int):
		_captured_deploy_id = id; _captured_deploy_row = r; _captured_deploy_col = c
	)
	var btn: Button = hand._hand_buttons["artillery_01"]
	btn.pressed.emit()
	_check(_captured_deploy_id == "artillery_01", "card_deployed emits 'artillery_01', got '%s'" % _captured_deploy_id)
	_check(_captured_deploy_row == -1 and _captured_deploy_col == -1, "row/col placeholders -1,-1 (Task 8), got (%d,%d)" % [_captured_deploy_row, _captured_deploy_col])
	hand.queue_free()
	tm.queue_free()


func _test_control_button_signals() -> void:
	print("[结束回合 / 跳过阶段 buttons emit signals]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	_end_emitted = false
	_skip_emitted = false
	hand.end_turn_pressed.connect(func(): _end_emitted = true)
	hand.skip_phase_pressed.connect(func(): _skip_emitted = true)
	var end_btn := _find_button_by_text(hand, "结束回合")
	var skip_btn := _find_button_by_text(hand, "跳过阶段")
	end_btn.pressed.emit()
	skip_btn.pressed.emit()
	_check(_end_emitted, "end_turn_pressed emitted")
	_check(_skip_emitted, "skip_phase_pressed emitted")
	hand.queue_free()
	tm.queue_free()


func _test_clear_dynamic_ui_frees_buttons_and_titles() -> void:
	print("[_clear_dynamic_ui frees dynamic buttons + title labels]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	tm.state_changed.emit(_make_state())
	var old_purchase: Button = hand._purchase_buttons["infantry_01"]
	var old_hand: Button = hand._hand_buttons["artillery_01"]
	_check(old_purchase != null and old_hand != null, "buttons rendered before clear")

	hand._clear_dynamic_ui()
	_check(hand._purchase_buttons.is_empty(), "purchase buttons dict cleared")
	_check(hand._hand_buttons.is_empty(), "hand buttons dict cleared")
	_check(old_purchase.is_queued_for_deletion(), "purchase button queued for deletion")
	_check(old_hand.is_queued_for_deletion(), "hand button queued for deletion")

	# 标题 Label 全部被清理（无未删除的 — xxx — 标题）
	_check(_count_title_labels(hand) == 0, "no active title labels remain after clear, got %d" % _count_title_labels(hand))
	# 持久按钮不受影响
	_check(not _find_button_by_text(hand, "结束回合").is_queued_for_deletion(), "结束回合 button survives clear")
	_check(not _find_button_by_text(hand, "跳过阶段").is_queued_for_deletion(), "跳过阶段 button survives clear")
	_check(not hand._turn_label.is_queued_for_deletion(), "turn label survives clear")
	_check(not hand._g_label.is_queued_for_deletion(), "resource label survives clear")
	hand.queue_free()
	tm.queue_free()


func _test_re_render_after_clear() -> void:
	print("[re-render clears old and re-creates fresh UI]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	var st := _make_state()
	tm.state_changed.emit(st)
	var old_btn: Button = hand._purchase_buttons["infantry_01"]

	var st2 := _make_state()
	st2.players[0].purchase_zone = ["cavalry_01"]
	tm.state_changed.emit(st2)
	_check(old_btn.is_queued_for_deletion(), "old purchase button queued after re-render")
	_check(hand._purchase_buttons.size() == 1, "1 purchase button after re-render, got %d" % hand._purchase_buttons.size())
	_check(hand._purchase_buttons.has("cavalry_01"), "re-render tracks cavalry_01")
	_check(not hand._purchase_buttons.has("infantry_01"), "infantry_01 removed from dict")
	_check(_count_title_labels(hand) == 2, "exactly 2 active title labels after re-render, got %d" % _count_title_labels(hand))
	hand.queue_free()
	tm.queue_free()


func _test_null_state_clears() -> void:
	print("[null state clears dynamic UI]")
	var result := _make_hand_and_tm()
	var tm: TurnManager = result[0]
	var hand: HandManager = result[1]
	tm.state_changed.emit(_make_state())
	_check(hand._purchase_buttons.size() == 2, "rendered before null state")
	tm.state_changed.emit(null)
	_check(hand._purchase_buttons.is_empty(), "null state clears purchase buttons dict")
	_check(hand._hand_buttons.is_empty(), "null state clears hand buttons dict")
	_check(_count_title_labels(hand) == 0, "null state clears title labels, got %d" % _count_title_labels(hand))
	hand.queue_free()
	tm.queue_free()
