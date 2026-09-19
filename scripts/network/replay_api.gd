extends RefCounted
class_name ReplayApi

## 录像服务器 HTTP 客户端 — 上传/下载对局录像
## 服务器不可用时静默失败（上传）/ 回调返回 null（下载），不影响正常对局

## 默认录像/中继服务器（部署后改这里，与 main_menu DEFAULT_RELAY_URL 对应）
const DEFAULT_BASE_URL := "http://127.0.0.1:24566"


## ws://host:port → http://host:port（中继与录像存储同一个服务器进程）
static func base_from_ws(ws_url: String) -> String:
	if ws_url.begins_with("wss://"):
		return "https://" + ws_url.substr(6)
	if ws_url.begins_with("ws://"):
		return "http://" + ws_url.substr(5)
	return ws_url


## 后台上传（fire-and-forget）：成败只打日志，不阻塞结算流程
static func upload(base_url: String, replay: Dictionary) -> void:
	var body := JSON.stringify(replay)
	_request(base_url + "/replay", "POST", body, func(status: int, text: String):
		if status == 200:
			print("[ReplayApi] uploaded game_id=%s" % str(replay.get("game_id", "?")))
		else:
			printerr("[ReplayApi] upload failed (HTTP %d) — replay not stored" % status)
	)


## 下载录像：回调 (replay: Dictionary)（失败/超时传空字典）
static func download(base_url: String, game_id: String, on_done: Callable) -> void:
	_request(base_url + "/replay/" + game_id.uri_encode(), "GET", "", func(status: int, text: String):
		var replay := {}
		if status == 200:
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary:
				replay = parsed
		if replay.is_empty():
			printerr("[ReplayApi] download failed (HTTP %d)" % status)
		on_done.call(replay)
	)


## 底层 HTTP：创建临时 HTTPRequest 挂到场景树根，完成后自清理
static func _request(url: String, method: String, body: String, on_done: Callable) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		on_done.call(0, "")
		return
	var http := HTTPRequest.new()
	http.timeout = 10.0
	tree.root.add_child(http)
	var cb := func(result: int, status: int, _headers: PackedStringArray, body_bytes: PackedByteArray):
		var text := body_bytes.get_string_from_utf8()
		on_done.call(status, text)
		http.queue_free()
	http.request_completed.connect(cb)
	var err := http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST, body)
	if err != OK:
		on_done.call(0, "")
		http.queue_free()
