extends Control

## 主菜单 — 本地对战 / 局域网创建 / 加入（手输 IP 或 UDP 自动发现）

var _status: Label
var _ip_edit: LineEdit
var _discover_btn: Button


func _ready() -> void:
	var title := Label.new()
	title.text = "1914"
	title.position = Vector2(40, 40)
	title.add_theme_font_size_override("font_size", 48)
	add_child(title)

	var sub := Label.new()
	sub.text = "第一次世界大战卡牌对战"
	sub.position = Vector2(42, 100)
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(sub)

	var box := VBoxContainer.new()
	box.position = Vector2(40, 170)
	box.custom_minimum_size = Vector2(260, 0)
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	_add_button(box, "本地对战（同屏）", func(): GameManager.start_local_game())
	_add_button(box, "创建局域网游戏", func(): GameManager.start_host_game())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.placeholder_text = "主机 IP"
	_ip_edit.custom_minimum_size = Vector2(160, 0)
	row.add_child(_ip_edit)
	_add_button_to(row, "加入游戏", _on_join_pressed)

	_discover_btn = _add_button(box, "搜索局域网主机", _on_discover_pressed)
	_add_button(box, "退出", func(): GameManager.quit_game())

	_status = Label.new()
	_status.position = Vector2(40, 520)
	_status.custom_minimum_size = Vector2(700, 0)
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
	_status.text = "本机地址: %s" % " | ".join(_local_lan_ips())
	add_child(_status)

	NetworkManager.net_status.connect(func(s: String): _status.text = s)
	NetworkManager.hosts_found.connect(_on_hosts_found)


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
