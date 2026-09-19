extends CanvasLayer
class_name ReviewScreen

## 对局复盘界面 — 左侧按「回合 → 阶段 → 操作」折叠的操作树，右侧无迷雾实时局面
## 录像来自服务器（ReplayApi 下载），快照重建局面渲染

var _replay: Dictionary = {}
var _viewer_idx: int = 0
var _named_players: bool = true

var _tree: Tree = null
var _title_label: Label = null
var _review_board: Board = null


func setup(replay: Dictionary, viewer_idx: int, named_players: bool) -> void:
	_replay = replay
	_viewer_idx = viewer_idx
	_named_players = named_players


func _ready() -> void:
	layer = 60
	_build_ui()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.07, 0.07, 0.09)
	root.add_child(bg)

	# ── 右侧：复盘棋盘（SubViewport 隔离布局，Board 按该视口尺寸居中） ──
	var vp_container := SubViewportContainer.new()
	vp_container.stretch = true
	vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp_container.offset_left = 372
	root.add_child(vp_container)
	var sub_vp := SubViewport.new()
	sub_vp.handle_input_locally = false
	vp_container.add_child(sub_vp)
	_review_board = Board.new()
	sub_vp.add_child(_review_board)

	# ── 左侧面板：操作树 + 控制 ──
	var left := PanelContainer.new()
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_right = 360
	root.add_child(left)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	left.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var title := Label.new()
	title.text = "对局复盘"
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)

	_title_label = Label.new()
	_title_label.text = "开局局面"
	_title_label.add_theme_font_size_override("font_size", 13)
	_title_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	box.add_child(_title_label)

	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 1
	_tree.item_selected.connect(_on_tree_selected)
	box.add_child(_tree)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	box.add_child(btn_row)

	var back_btn := Button.new()
	back_btn.text = "返回结算"
	back_btn.custom_minimum_size = Vector2(120, 38)
	back_btn.pressed.connect(func():
		var menu := ResultMenu.show_result(get_parent(), _replay, _viewer_idx, _named_players, ReplayApi.DEFAULT_BASE_URL)
		menu._status_label.text = ""
		queue_free()
	)
	btn_row.add_child(back_btn)

	var exit_btn := Button.new()
	exit_btn.text = "退出复盘"
	exit_btn.custom_minimum_size = Vector2(120, 38)
	exit_btn.pressed.connect(func():
		NetworkManager.leave()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	btn_row.add_child(exit_btn)

	_populate_tree()
	# 默认显示开局局面
	_show_snapshot(0, "开局局面")


func _populate_tree() -> void:
	_tree.clear()
	var hidden_root := _tree.create_item()
	var groups := ReplayStore.group_actions(_replay, _viewer_idx, _named_players)
	for g in groups:
		var turn_item := _tree.create_item(hidden_root)
		turn_item.set_text(0, str(g["label"]))
		turn_item.set_metadata(0, {"snapshot_idx": int(g["snapshot_idx"]), "label": "第%d回合 · 开局" % int(g["turn"])})
		for ph in g["phases"]:
			var ph_item := _tree.create_item(turn_item)
			ph_item.set_text(0, "├ " + str(ph["label"]))
			ph_item.set_metadata(0, {"snapshot_idx": int(g["snapshot_idx"]), "label": str(g["label"]) + " · " + str(ph["label"])})
			for entry in ph["actions"]:
				var leaf := _tree.create_item(ph_item)
				leaf.set_text(0, "%d. %s" % [int(entry["idx"]) + 1, str(entry["text"])])
				leaf.set_metadata(0, {"snapshot_idx": int(entry["idx"]) + 1, "label": str(entry["text"])})
	# 默认展开第一回合
	var first := hidden_root.get_first_child()
	if first != null:
		first.set_collapsed(false)


func _on_tree_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty():
		return
	_show_snapshot(int(meta.get("snapshot_idx", 0)), str(meta.get("label", "")))


## 渲染第 snapshot_idx 个快照（snapshots[0] = 开局）
func _show_snapshot(snapshot_idx: int, label: String) -> void:
	var snaps: Array = _replay.get("snapshots", [])
	if snapshot_idx < 0 or snapshot_idx >= snaps.size():
		return
	_title_label.text = "▸ " + label
	_review_board.render_review_state(ReplayStore.snapshot_to_state(snaps[snapshot_idx]))
