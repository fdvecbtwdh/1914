extends Node

## 网络连接与同步管理 — 阶段4
## 模式：ENet 局域网 P2P 直连（本期主模式）+ UDP 局域网发现 + WebSocket 轻量中继（实验，服务器侧协议见 docs/server-relay-protocol.md）
## 同步模型：两端只交换「开局种子 + submit_action 指令字典 + 状态指纹」，不传游戏状态
## 前提：两端运行同一版本引擎与同一套卡牌 JSON（纯函数引擎保证同序列同结果）

signal net_status(status: String)          # 供菜单/UI 显示的文字状态
signal connected_ok()                       # 客机：已连上房主
signal opponent_joined()                    # 房主：对手已连上
signal game_start_received(payload: Dictionary)  # 双方：收到开局信息（seed/decks）
signal action_received(action: Dictionary)  # 双方：收到远端指令（GameManager 接入 TurnManager）
signal sync_lost(detail: String)            # 指纹不一致 → 两端状态已分叉
signal opponent_disconnected()
signal hosts_found(found: Array)            # 局域网发现结果更新

const DEFAULT_PORT := 24565
const DISCOVERY_PORT := 1914
const DISCOVERY_MAGIC := "1914_DISCOVER"
const DISCOVERY_REPLY := "1914_HOST"
const JOIN_TIMEOUT_MS := 10000

enum Mode { IDLE, HOSTING, JOINING, IN_GAME }

var mode: Mode = Mode.IDLE
var local_player_idx := 0        # 房主恒为 P1(0)，客机恒为 P2(1)
var is_network_game := false     # false = 本地同屏

var _local_scene_ready := false
var _remote_scene_ready := false
var _join_deadline_ms := 0
var _client_peer_id := 0         # 房主侧：对手的 ENet id

# ── UDP 发现 ──
var _udp_responder: PacketPeerUDP = null     # 房主：应答探测
var _udp_probe: PacketPeerUDP = null         # 客机：发探测收应答
var _probe_deadline_ms := 0
var _found_hosts: Array = []                 # [{ip, name}]

# ── WebSocket 中继（实验） ──
var _relay_ws: WebSocketPeer = null
var _relay_is_creator := false


func _enter_tree() -> void:
	# 使用场景树根的默认 MultiplayerAPI（由 SceneTree 自动 poll）
	get_multiplayer().peer_connected.connect(_on_peer_connected)
	get_multiplayer().peer_disconnected.connect(_on_peer_disconnected)
	get_multiplayer().connected_to_server.connect(_on_connected_to_server)
	get_multiplayer().connection_failed.connect(_on_connection_failed)
	get_multiplayer().server_disconnected.connect(_on_server_disconnected)


func _process(_delta: float) -> void:
	_poll_udp()
	_poll_relay()
	if mode == Mode.JOINING and Time.get_ticks_msec() > _join_deadline_ms:
		leave("加入超时，对方未响应")


# ═══════════════ ENet 局域网 ═══════════════

## 房主：创建主机等待连接
func host_game(port: int = DEFAULT_PORT) -> Error:
	reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 2)
	if err != OK:
		_emit_status("创建主机失败（端口 %d 被占用？）" % port)
		return err
	get_multiplayer().multiplayer_peer = peer
	mode = Mode.HOSTING
	local_player_idx = 0
	is_network_game = true
	_local_scene_ready = false
	_remote_scene_ready = false
	_start_udp_responder()
	_emit_status("主机已创建，等待玩家加入…（端口 %d）" % port)
	return OK


## 客机：连接房主
func join_game(ip: String, port: int = DEFAULT_PORT) -> void:
	reset()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		_emit_status("连接失败：%s" % ip)
		return
	get_multiplayer().multiplayer_peer = peer
	mode = Mode.JOINING
	local_player_idx = 1
	is_network_game = true
	_local_scene_ready = false
	_remote_scene_ready = false
	_join_deadline_ms = Time.get_ticks_msec() + JOIN_TIMEOUT_MS
	_emit_status("正在连接 %s:%d …" % [ip, port])


## GameManager 场景接线完成后调用；双方都就绪才发开局包
func set_local_scene_ready() -> void:
	_local_scene_ready = true
	if mode == Mode.HOSTING and _remote_scene_ready:
		_send_start()
	elif mode == Mode.JOINING:
		# ENet：告诉房主我准备好了；中继：同义 JSON
		if _relay_ws != null:
			_relay_send({"t": "ready"})
		else:
			_rpc_client_ready.rpc_id(1)


## 房主：发送开局包（种子 + 卡组）。内部在双方就绪后调用
func _send_start() -> void:
	if not _i_am_host():
		return
	var deck := _load_default_deck()
	var payload := {
		"seed": randi(),
		"p1_deck": deck.cards,
		"p2_deck": deck.cards.duplicate(),
		"p1_starter": deck.starter,
		"p2_starter": deck.starter,
	}
	if _relay_ws != null:
		_relay_send({"t": "start", "payload": payload})
	else:
		_rpc_start.rpc_id(_client_peer_id, payload)
	mode = Mode.IN_GAME
	# 房主自己也走同一条接收路径初始化，保证两端代码路径一致
	_handle_game_start(payload)


func send_action(action: Dictionary) -> void:
	if not is_network_game or mode != Mode.IN_GAME:
		return
	if _relay_ws != null:
		_relay_send({"t": "action", "action": action})
	else:
		_rpc_action.rpc_id(_opponent_rpc_id(), action)


func send_check(fingerprint: String) -> void:
	if not is_network_game or mode != Mode.IN_GAME:
		return
	if _relay_ws != null:
		_relay_send({"t": "check", "fp": fingerprint})
	else:
		_rpc_check.rpc_id(_opponent_rpc_id(), fingerprint)


func leave(reason: String = "") -> void:
	if reason != "":
		_emit_status(reason)
	reset()


## 彻底复位（回菜单时调用）
func reset() -> void:
	mode = Mode.IDLE
	is_network_game = false
	_local_scene_ready = false
	_remote_scene_ready = false
	_client_peer_id = 0
	_relay_is_creator = false
	_stop_udp()
	_close_relay()
	if get_multiplayer().multiplayer_peer != null:
		get_multiplayer().multiplayer_peer.close()
		get_multiplayer().multiplayer_peer = OfflineMultiplayerPeer.new()


# ── ENet 回调 ──

func _on_peer_connected(id: int) -> void:
	if mode == Mode.HOSTING:
		_client_peer_id = id
		_stop_udp()  # 有人加入即停发现应答
		_emit_status("玩家已连接！")
		opponent_joined.emit()
		if _local_scene_ready and _remote_scene_ready:
			_send_start()


func _on_peer_disconnected(_id: int) -> void:
	if mode != Mode.IDLE:
		opponent_disconnected.emit()
		_emit_status("对手已离开")
		reset()


func _on_connected_to_server() -> void:
	_emit_status("已连接！等待开局…")
	connected_ok.emit()


func _on_connection_failed() -> void:
	_emit_status("连接失败")
	reset()


func _on_server_disconnected() -> void:
	opponent_disconnected.emit()
	_emit_status("与主机断开")
	reset()


# ── RPC（ENet 通道）──

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_ready() -> void:
	_remote_scene_ready = true
	if mode == Mode.HOSTING and _local_scene_ready:
		_send_start()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_start(payload: Dictionary) -> void:
	_handle_game_start(payload)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_action(action: Dictionary) -> void:
	_handle_remote_action(action)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_check(fingerprint: String) -> void:
	_handle_remote_check(fingerprint)


func _handle_game_start(payload: Dictionary) -> void:
	seed(int(payload["seed"]))
	mode = Mode.IN_GAME
	game_start_received.emit(payload)


## 收到远端指令 → 发信号，由 GameManager 转交 TurnManager
func _handle_remote_action(action: Dictionary) -> void:
	action_received.emit(action)


func _handle_remote_check(fingerprint: String) -> void:
	var tm: TurnManager = _find_turn_manager()
	if tm == null or tm.battle_state == null:
		return
	var mine := GameLogic.state_fingerprint(tm.battle_state)
	if mine != fingerprint:
		var detail := "状态不同步！本地 %s vs 对端 %s（回合 %d）" % [mine, fingerprint, tm.battle_state.turn]
		printerr("[NetworkManager] " + detail)
		sync_lost.emit(detail)


func _find_turn_manager() -> TurnManager:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("TurnManager") as TurnManager


func _i_am_host() -> bool:
	return local_player_idx == 0


## RPC 目标：房主发给已连入的客机 id；客机发给服务器（恒为 id 1）
func _opponent_rpc_id() -> int:
	return _client_peer_id if _i_am_host() else 1


func _emit_status(s: String) -> void:
	print("[NetworkManager] " + s)
	net_status.emit(s)


# ═══════════════ UDP 局域网发现 ═══════════════

func _start_udp_responder() -> void:
	_udp_responder = PacketPeerUDP.new()
	if _udp_responder.bind(DISCOVERY_PORT) != OK:
		# 端口被占（如另一台本机实例）不影响主流程，只是本机不可被发现
		_udp_responder = null


func _stop_udp() -> void:
	if _udp_responder != null:
		_udp_responder.close()
		_udp_responder = null
	_stop_discovery()


func _poll_udp() -> void:
	# 房主：应答探测
	if _udp_responder != null:
		while _udp_responder.get_available_packet_count() > 0:
			var pkt := _udp_responder.get_packet()
			if pkt.get_string_from_utf8() == DISCOVERY_MAGIC:
				_udp_responder.set_dest_address(_udp_responder.get_packet_ip(), _udp_responder.get_packet_port())
				_udp_responder.put_packet((DISCOVERY_REPLY + ":" + str(DEFAULT_PORT)).to_utf8_buffer())
	# 客机：收集应答
	if _udp_probe != null:
		var changed := false
		while _udp_probe.get_available_packet_count() > 0:
			var reply := _udp_probe.get_packet().get_string_from_utf8()
			if reply.begins_with(DISCOVERY_REPLY):
				var ip := _udp_probe.get_packet_ip()
				var known := false
				for h in _found_hosts:
					if h["ip"] == ip:
						known = true
						break
				if not known:
					_found_hosts.append({"ip": ip, "name": "局域网主机 %s" % ip})
					changed = true
		if Time.get_ticks_msec() > _probe_deadline_ms:
			_stop_discovery()
			changed = true
		if changed:
			hosts_found.emit(_found_hosts.duplicate())


## 开始异步发现（结果经 hosts_found 信号分批给出）
func start_discovery(timeout_sec: float = 3.0) -> void:
	_stop_discovery()
	_found_hosts = []
	_udp_probe = PacketPeerUDP.new()
	if _udp_probe.bind(0) != OK:
		_udp_probe = null
		_emit_status("发现服务启动失败")
		return
	_udp_probe.set_broadcast_enabled(true)
	# 广播全网段 + 本机回环（后者保证同机测试可发现）
	for t in ["255.255.255.255", "127.0.0.1"]:
		_udp_probe.set_dest_address(t, DISCOVERY_PORT)
		_udp_probe.put_packet(DISCOVERY_MAGIC.to_utf8_buffer())
	_probe_deadline_ms = Time.get_ticks_msec() + int(timeout_sec * 1000)


func stop_discovery() -> void:
	_stop_discovery()


func _stop_discovery() -> void:
	if _udp_probe != null:
		_udp_probe.close()
		_udp_probe = null


# ═══════════════ WebSocket 轻量中继（实验） ═══════════════
## 服务器只按房间转发 JSON；协议见 docs/server-relay-protocol.md
## 先创建（房主/P1）或后加入（客机/P2）由服务器 joined 应答决定

func relay_create(url: String, room: String) -> void:
	_relay_begin(url, room, true)


func relay_join(url: String, room: String) -> void:
	_relay_begin(url, room, false)


func _relay_begin(url: String, room: String, create: bool) -> void:
	reset()
	_relay_ws = WebSocketPeer.new()
	_relay_is_creator = create
	var err := _relay_ws.connect_to_url(url)
	if err != OK:
		_emit_status("中继连接失败：%s" % url)
		_close_relay()
		return
	mode = Mode.JOINING if not create else Mode.HOSTING
	_join_deadline_ms = Time.get_ticks_msec() + JOIN_TIMEOUT_MS + 5000
	_emit_status("连接中继服务器…（房间 %s）" % room)


func _poll_relay() -> void:
	if _relay_ws == null:
		return
	_relay_ws.poll()
	var state := _relay_ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		while _relay_ws.get_available_packet_count() > 0:
			var pkt := _relay_ws.get_packet()
			_relay_on_json(JSON.parse_string(pkt.get_string_from_utf8()))
	elif state == WebSocketPeer.STATE_CLOSED:
		if mode != Mode.IDLE:
			opponent_disconnected.emit()
			_emit_status("中继连接已关闭")
			reset()


func _relay_send(msg: Dictionary) -> void:
	if _relay_ws != null and _relay_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_relay_ws.send_text(JSON.stringify(msg))


func _relay_on_json(m) -> void:
	if m == null or not (m is Dictionary):
		return
	match m.get("t", ""):
		"joined":
			# 创建者收到 peers:1 → 我是房主；加入者收到 peers:2 → 我是客机
			var peers := int(m.get("peers", 1))
			if _relay_is_creator:
				local_player_idx = 0
			elif peers >= 2:
				local_player_idx = 1
			is_network_game = true
			_emit_status("中继房间就绪，等待双方场景加载…")
		"ready":
			_remote_scene_ready = true
			if _relay_is_creator and _local_scene_ready:
				_send_start()
		"start":
			_handle_game_start(m.get("payload", {}))
		"action":
			_handle_remote_action(m.get("action", {}))
		"check":
			_handle_remote_check(str(m.get("fp", "")))
		"peer_left":
			opponent_disconnected.emit()
			_emit_status("对手已离开")
			reset()
		"error":
			_emit_status("中继错误：" + str(m.get("msg", "")))
			reset()


func _close_relay() -> void:
	if _relay_ws != null:
		if _relay_ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_relay_send({"t": "leave"})
		_relay_ws.close()
		_relay_ws = null


# ── 工具 ──

func _load_default_deck() -> Dictionary:
	var file := FileAccess.open("res://data/decks/player_default.json", FileAccess.READ)
	if file == null:
		return {"cards": [], "starter": "infantry_01"}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {"cards": [], "starter": "infantry_01"}
	var d: Dictionary = json.get_data()
	file.close()
	return d
