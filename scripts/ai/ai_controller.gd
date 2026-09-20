extends Node
class_name AIDirector

## AI 回合驱动 — 行动 → 状态变化 → 重新评估 → 下一行动（docs/ai-design.md 第 6 节）
## 全部行动走 TurnManager.submit_action（与玩家同一校验链，零规则绕过）
## 驱动模式：_process 轮询（每帧检查是否轮到 AI、间隔是否到），无协程生命周期风险
## 防软锁：连续拒绝强制推进 + 单回合行动计数上限 + game_over 即停

const ACTION_INTERVAL := 0.45   # 行动间隔（秒），玩家可感知 AI 在行动
const MAX_ACTIONS_PER_TURN := 200

var turn_manager: TurnManager = null
var ai_player_idx: int = 1
var difficulty: String = "normal"
var action_interval: float = ACTION_INTERVAL  # 测试可置 0（每帧一行动，快速对局）
var debug_log: bool = false                   # 调试开关：输出候选行动与评分

var _evaluator: AIEvaluator = null
var _accum := 0.0
var _actions_this_turn := 0
var _reject_count := 0
var _last_submit_rejected := false
var _last_turn_key := -1


func setup(tm: TurnManager, player_idx: int, difficulty_: String, interval: float = ACTION_INTERVAL) -> void:
	turn_manager = tm
	ai_player_idx = player_idx
	difficulty = difficulty_
	action_interval = maxf(0.0, interval)
	_evaluator = AIEvaluator.new(difficulty)


func _process(delta: float) -> void:
	if turn_manager == null:
		return
	var st := turn_manager.battle_state
	if st == null or st.winner != -1:
		return
	if st.active_player_index != ai_player_idx:
		return
	_accum += delta
	if _accum < action_interval:
		return
	_accum = 0.0
	_step(st)


## 执行一步：重新评估当前局面 → 提交最佳行动 / 推进阶段
func _step(st: BattleState) -> void:
	# 新回合重置行动计数
	var turn_key: int = st.turn * 10 + st.active_player_index
	if turn_key != _last_turn_key:
		_last_turn_key = turn_key
		_actions_this_turn = 0
	# 拒绝防护：连续 3 次提交无状态变化 → 强制推进阶段
	if _last_submit_rejected:
		_reject_count += 1
		if _reject_count >= 3:
			printerr("[AI] 3 consecutive rejected actions — force advancing phase")
			_reject_count = 0
			_last_submit_rejected = false
			_advance_phase()
			return
	else:
		_reject_count = 0
	# 行动超限保险
	if _actions_this_turn >= MAX_ACTIONS_PER_TURN:
		printerr("[AI] action limit reached — advancing phase")
		_advance_phase()
		return

	var action := _evaluator.choose_action(st, ai_player_idx)
	if action.is_empty():
		# 本阶段无正收益行动 → 跳到下一阶段（action 阶段 skip 即结束回合）
		if debug_log:
			print("[AI] phase %s exhausted, advancing" % st.phase)
		_advance_phase()
		return
	_actions_this_turn += 1
	if debug_log:
		print("[AI] #%d %s score=%.1f (alternatives=%d)" % [_actions_this_turn, action.get("type", "?"), action.get("score", 0.0), action.get("_alternatives", 0)])
	var accepted := _submit(action)
	if not accepted:
		_last_submit_rejected = true


## 无候选时的阶段正确退出：purchase/deploy 阶段用 skip_phase，action 阶段 skip 即结束回合
func _advance_phase() -> void:
	if turn_manager.battle_state != null and turn_manager.battle_state.phase == "action":
		_submit({"type": "end_turn", "player_idx": ai_player_idx})
	else:
		_submit({"type": "skip_phase", "player_idx": ai_player_idx})


## 提交行动并检测是否被引擎接受（状态变化检测；purchase 不写日志但改资源/手牌）
func _submit(action: Dictionary) -> bool:
	var st := turn_manager.battle_state
	var g_before: int = st.players[ai_player_idx].resources["G"]
	var z_before: int = st.players[ai_player_idx].resources["Z"]
	var hand_before: int = st.players[ai_player_idx].hand.size()
	turn_manager.submit_action(action)
	var st2 := turn_manager.battle_state
	var accepted: bool = st2.phase != st.phase \
		or st2.turn != st.turn \
		or st2.active_player_index != st.active_player_index \
		or st2.action_log.size() != st.action_log.size() \
		or st2.players[ai_player_idx].resources["G"] != g_before \
		or st2.players[ai_player_idx].resources["Z"] != z_before \
		or st2.players[ai_player_idx].hand.size() != hand_before
	return accepted
