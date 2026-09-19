extends CanvasLayer
class_name ResultMenu

## 对局结算菜单 — 覆盖在战斗场景上：本局总结 + 复盘本局 / 返回主菜单
## 由 GameManager 在 game_over / 对手断开时创建

var _replay: Dictionary = {}
var _viewer_idx: int = 0
var _named_players: bool = true
var _base_url: String = ReplayApi.DEFAULT_BASE_URL
var _status_label: Label = null
var _review_btn: Button = null


## 工厂：构建并挂到当前场景
static func show_result(parent: Node, replay: Dictionary, viewer_idx: int, named_players: bool, base_url: String) -> ResultMenu:
	var menu := ResultMenu.new()
	menu._replay = replay
	menu._viewer_idx = viewer_idx
	menu._named_players = named_players
	menu._base_url = base_url
	parent.add_child(menu)
	return menu


func _ready() -> void:
	layer = 50
	_build_ui()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP  # 挡住下层棋盘交互
	add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	# ── 标题 ──
	var winner: int = int(_replay.get("winner", -1))
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 30)
	if winner == -1:
		title.text = "对局中止"
		title.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	elif _named_players:
		title.text = "玩家 %d 获胜！" % (winner + 1)
		title.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	elif winner == _viewer_idx:
		title.text = "胜利！"
		title.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	else:
		title.text = "战败"
		title.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var rounds: int = int(_replay.get("rounds", 0))
	var sub := Label.new()
	sub.text = ("历经 %d 个回合" % rounds) if winner != -1 else "对手已离开，本局不记成绩"
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	# ── 双方统计表 ──
	var stats := ReplayStore.compute_stats(_replay)
	var side_names := ["玩家 1", "玩家 2"]
	if not _named_players:
		side_names = ["我方", "敌方"]
		if _viewer_idx == 1:
			side_names = ["敌方", "我方"]
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)

	_grid_row(grid, "", side_names[0], side_names[1], true)
	_grid_row(grid, "部署单位", str(stats[0]["deployed"]), str(stats[1]["deployed"]))
	_grid_row(grid, "击杀 / 损失", "%d / %d" % [stats[0]["kills"], stats[0]["losses"]], "%d / %d" % [stats[1]["kills"], stats[1]["losses"]])
	_grid_row(grid, "购买卡牌", str(stats[0]["purchases"]), str(stats[1]["purchases"]))
	_grid_row(grid, "花费经济 G", str(stats[0]["g_spent"]), str(stats[1]["g_spent"]))
	_grid_row(grid, "消耗战争点 Z", str(stats[0]["z_spent"]), str(stats[1]["z_spent"]))
	_grid_row(grid, "移动 / 攻击", "%d / %d" % [stats[0]["moves"], stats[0]["attacks"]], "%d / %d" % [stats[1]["moves"], stats[1]["attacks"]])

	# ── 最终战线占领度 ──
	var snaps: Array = _replay.get("snapshots", [])
	if not snaps.is_empty():
		var front: Array = snaps[-1].get("front", [])
		if front.size() >= 5:
			var fl := Label.new()
			var parts: Array[String] = []
			for v in front:
				parts.append(str(int(v)))
			fl.text = "最终战线占领度：  " + "   ".join(parts)
			fl.add_theme_font_size_override("font_size", 13)
			fl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
			box.add_child(fl)

	box.add_child(HSeparator.new())

	# ── 按钮 ──
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 16)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(btn_row)

	_review_btn = Button.new()
	_review_btn.text = "复盘本局"
	_review_btn.custom_minimum_size = Vector2(150, 44)
	_review_btn.pressed.connect(_on_review_pressed)
	btn_row.add_child(_review_btn)

	var back_btn := Button.new()
	back_btn.text = "返回主菜单"
	back_btn.custom_minimum_size = Vector2(150, 44)
	back_btn.pressed.connect(func():
		NetworkManager.leave()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	btn_row.add_child(back_btn)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.3))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status_label)


func _grid_row(grid: GridContainer, a: String, b: String, c: String, header: bool = false) -> void:
	for item in [[a, Color(0.65, 0.65, 0.65)], [b, Color(0.55, 0.75, 1.0)], [c, Color(1.0, 0.6, 0.6)]]:
		var lbl := Label.new()
		lbl.text = item[0]
		lbl.add_theme_font_size_override("font_size", 15 if header else 14)
		lbl.add_theme_color_override("font_color", item[1] if header else Color(0.9, 0.9, 0.9))
		grid.add_child(lbl)


## 复盘本局：从服务器拉取录像（防伪造），成功 → 打开复盘界面
func _on_review_pressed() -> void:
	_review_btn.disabled = true
	_status_label.text = "正在从服务器获取录像…"
	ReplayApi.download(_base_url, str(_replay.get("game_id", "")), func(replay: Dictionary):
		_review_btn.disabled = false
		if replay.is_empty():
			_status_label.text = "获取失败（服务器不可用或录像已过期）"
			return
		var review := ReviewScreen.new()
		review.setup(replay, _viewer_idx, _named_players)
		get_parent().add_child(review)
		queue_free()  # 结算菜单暂时收起，复盘界面内可返回
	)
