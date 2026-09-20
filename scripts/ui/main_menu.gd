extends Control

## 主菜单 — 本地对战 / 局域网创建 / 加入（手输 IP 或 UDP 自动发现）
## 布局基于视口尺寸自适应（stretch canvas_items 下根节点 size 即逻辑分辨率）

var _status: Label
var _ip_edit: LineEdit
var _discover_btn: Button
var _title: Label
var _subtitle: Label
var _box: VBoxContainer
var _relay_url_edit: LineEdit
var _relay_room_edit: LineEdit

## 默认中继服务器（部署后改成你的域名，见 docs/server-relay-protocol.md）
const DEFAULT_RELAY_URL := "ws://127.0.0.1:24566"


func _ready() -> void:
	_build_ui()
	_relayout()
	resized.connect(_relayout)
	NetworkManager.net_status.connect(func(s: String): _status.text = s)
	NetworkManager.hosts_found.connect(_on_hosts_found)


func _build_ui() -> void:
	BetaBanner.attach(self)  # 顶部测试版本提示（全场景公共 UI）

	_title = Label.new()
	_title.text = "1914"
	_title.add_theme_font_size_override("font_size", 48)
	add_child(_title)

	_subtitle = Label.new()
	_subtitle.text = "第一次世界大战卡牌对战"
	_subtitle.add_theme_font_size_override("font_size", 14)
	_subtitle.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_subtitle)

	_box = VBoxContainer.new()
	_box.custom_minimum_size = Vector2(260, 0)
	_box.add_theme_constant_override("separation", 12)
	add_child(_box)

	_add_button(_box, "本地对战（同屏）", func(): GameManager.start_local_game())

	# ── 人机对战（三档难度） ──
	var ai_label := Label.new()
	ai_label.text = "— 人机对战 —"
	ai_label.add_theme_font_size_override("font_size", 12)
	ai_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_box.add_child(ai_label)
	var ai_row := HBoxContainer.new()
	ai_row.add_theme_constant_override("separation", 8)
	_box.add_child(ai_row)
	_add_button_to(ai_row, "简单", func(): GameManager.start_ai_game("easy"))
	_add_button_to(ai_row, "普通", func(): GameManager.start_ai_game("normal"))
	_add_button_to(ai_row, "困难", func(): GameManager.start_ai_game("hard"))

	_add_button(_box, "创建局域网游戏", func(): GameManager.start_host_game())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_box.add_child(row)
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.placeholder_text = "主机 IP"
	_ip_edit.custom_minimum_size = Vector2(160, 0)
	row.add_child(_ip_edit)
	_add_button_to(row, "加入游戏", _on_join_pressed)

	_discover_btn = _add_button(_box, "搜索局域网主机", _on_discover_pressed)

	# ── 跨网联机（中继，手机流量/异地可用） ──
	var relay_label := Label.new()
	relay_label.text = "— 跨网联机 —"
	relay_label.add_theme_font_size_override("font_size", 12)
	relay_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	_box.add_child(relay_label)

	_relay_url_edit = LineEdit.new()
	_relay_url_edit.text = DEFAULT_RELAY_URL
	_relay_url_edit.placeholder_text = "中继服务器地址"
	_relay_url_edit.custom_minimum_size = Vector2(260, 0)
	_box.add_child(_relay_url_edit)

	var relay_row := HBoxContainer.new()
	relay_row.add_theme_constant_override("separation", 8)
	_box.add_child(relay_row)
	_relay_room_edit = LineEdit.new()
	_relay_room_edit.text = "%04d" % (randi() % 10000)
	_relay_room_edit.placeholder_text = "房间码"
	_relay_room_edit.custom_minimum_size = Vector2(100, 0)
	relay_row.add_child(_relay_room_edit)
	_add_button_to(relay_row, "创建房间", _on_relay_create_pressed)
	_add_button_to(relay_row, "加入房间", _on_relay_join_pressed)

	_add_button(_box, "退出", func(): GameManager.quit_game())

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
	_status.text = "本机地址: %s" % " | ".join(_local_lan_ips())
	add_child(_status)


## 视口自适应布局：菜单列垂直居中偏上，状态栏贴底
func _relayout() -> void:
	var vs := size
	_title.position = Vector2(40, 30)
	_subtitle.position = Vector2(42, 92)
	_box.position = Vector2(40, max(150.0, vs.y * 0.26))
	_status.position = Vector2(40, vs.y - 46)
	_status.size = Vector2(max(400.0, vs.x - 80.0), 30)


func _add_button(parent: Node, text: String, handler: Callable) -> Button:
	return _add_button_to(parent, text, handler)


func _add_button_to(parent: Node, text: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(220, 36)
	btn.pressed.connect(handler)
	parent.add_child(btn)
	return btn


func _on_join_pressed() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		_status.text = "请输入主机 IP，或使用搜索"
		return
	GameManager.start_join_game(ip)


func _on_discover_pressed() -> void:
	_discover_btn.disabled = true
	_status.text = "正在搜索局域网主机…（约 3 秒）"
	NetworkManager.hosts_found.connect(func(_h): _discover_btn.disabled = false, CONNECT_ONE_SHOT)
	NetworkManager.start_discovery(3.0)


func _relay_args() -> Array:
	var url := _relay_url_edit.text.strip_edges()
	var room := _relay_room_edit.text.strip_edges().to_upper()
	if url == "" or room == "":
		_status.text = "请填写中继服务器地址和房间码"
		return []
	return [url, room]


func _on_relay_create_pressed() -> void:
	var args := _relay_args()
	if args.is_empty():
		return
	GameManager.start_host_relay(args[0], args[1])


func _on_relay_join_pressed() -> void:
	var args := _relay_args()
	if args.is_empty():
		return
	GameManager.start_join_relay(args[0], args[1])


func _on_hosts_found(found: Array) -> void:
	if found.is_empty():
		_status.text = "未发现局域网主机（确认对方已点「创建局域网游戏」）"
		return
	var ips: Array[String] = []
	for h in found:
		ips.append(h["ip"])
	_status.text = "发现主机: %s（已填入 IP，点「加入游戏」）" % ", ".join(ips)
	_ip_edit.text = found[0]["ip"]


func _local_lan_ips() -> Array[String]:
	var out: Array[String] = []
	for ip in IP.get_local_addresses():
		var s := str(ip)
		if s.begins_with("192.168.") or s.begins_with("10.") or s.begins_with("172."):
			out.append(s)
	if out.is_empty():
		out.append("127.0.0.1")
	return out
