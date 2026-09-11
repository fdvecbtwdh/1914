extends Node

## 网络对战自动测试驾驶 — GameManager._auto_enter 检测 --auto 时挂载
## 按预设脚本替本地玩家出牌，走真实 submit_action → 网络转发 → 指纹核对 全链路
## 退出码：0=通过  95=断线  96=异常胜利  97=状态失步  98=脚本停滞

var _queue: Array = []           # [{phase, action}]，head 先出
var _finished := false
var _last_progress_ms := 0
var _start_ms := 0


func _ready() -> void:
	print("[AUTO] autopilot up, local player = P%d" % (NetworkManager.local_player_idx + 1))
	_build_queue()
	_last_progress_ms = Time.get_ticks_msec()
	_start_ms = _last_progress_ms
	NetworkManager.sync_lost.connect(func(detail: String):
		printerr("[AUTO] SYNC LOST: " + detail)
		get_tree().quit(97)
	)
	NetworkManager.opponent_disconnected.connect(func():
		if not _finished:
			printerr("[AUTO] opponent disconnected before finish")
			get_tree().quit(95)
	)


func _build_queue() -> void:
	if NetworkManager.local_player_idx == 0:
		_queue = [
			# 回合1：购买步兵，直接送完阶段结束回合
			{"phase": "purchase", "action": {"type": "purchase", "card_id": "infantry_01"}},
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "end_turn"}},
			# 回合2：部署到 P1 后方并前进一格
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "deploy", "card_id": "infantry_01", "row": 0, "col": 0}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "move", "from_row": 0, "from_col": 0, "to_row": 1, "to_col": 0}},
			{"phase": "action", "action": {"type": "end_turn"}},
			# 回合3：推进到争夺区
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "move", "from_row": 1, "from_col": 0, "to_row": 2, "to_col": 0}},
			{"phase": "action", "action": {"type": "end_turn"}},
		]
	else:
		_queue = [
			# 回合1：镜像 P1
			{"phase": "purchase", "action": {"type": "purchase", "card_id": "infantry_01"}},
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "end_turn"}},
			# 回合2：部署到 P2 后方并前进一格
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "deploy", "card_id": "infantry_01", "row": 4, "col": 0}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "move", "from_row": 4, "from_col": 0, "to_row": 3, "to_col": 0}},
			{"phase": "action", "action": {"type": "end_turn"}},
			# 回合3：攻击进入争夺区的 P1 单位
			{"phase": "purchase", "action": {"type": "skip_phase"}},
			{"phase": "deploy", "action": {"type": "skip_phase"}},
			{"phase": "action", "action": {"type": "attack", "from_row": 3, "from_col": 0, "target_row": 2, "target_col": 0}},
			{"phase": "action", "action": {"type": "end_turn"}},
		]


func _process(_delta: float) -> void:
	if _finished:
		return
	var gm := get_node_or_null("/root/GameManager")
	var tm: TurnManager = gm.turn_manager if gm != null else null
	if tm == null or tm.battle_state == null:
		return
	var now := Time.get_ticks_msec()

	# 停滞看门狗
	if now - _last_progress_ms > 30000:
		printerr("[AUTO] STALL: queue_left=%d turn=%d phase=%s active=%d" % [
			_queue.size(), tm.battle_state.turn, tm.battle_state.phase, tm.battle_state.active_player_index])
		get_tree().quit(98)
		return

	var st := tm.battle_state
	if st.winner != -1:
		printerr("[AUTO] unexpected winner during script (turn %d)" % st.turn)
		get_tree().quit(96)
		return

	# 轮到自己且阶段匹配队头 → 出手
	if _queue.is_empty():
		return
	if st.active_player_index != NetworkManager.local_player_idx:
		return
	if st.phase != _queue[0]["phase"]:
		return
	var step: Dictionary = _queue.pop_front()
	_last_progress_ms = now
	_do_after(0.25, func():
		print("[AUTO] P%d submits %s (left %d)" % [NetworkManager.local_player_idx + 1, step["action"]["type"], _queue.size()])
		gm._submit_local(step["action"])
		if _queue.is_empty():
			_finish()
	)


func _finish() -> void:
	_finished = true
	# 等最后的指纹核对在两端跑完
	_do_after(3.0 if NetworkManager.local_player_idx == 0 else 2.0, func():
		var st: BattleState = get_node("/root/GameManager").turn_manager.battle_state
		print("[AUTO] PASS — local=P%d end turn=%d phase=%s fp=%s (%.1fs)" % [
			NetworkManager.local_player_idx + 1, st.turn, st.phase,
			GameLogic.state_fingerprint(st), (Time.get_ticks_msec() - _start_ms) / 1000.0])
		get_tree().quit(0)
	)


func _do_after(sec: float, fn: Callable) -> void:
	get_tree().create_timer(sec).timeout.connect(fn, CONNECT_ONE_SHOT)
