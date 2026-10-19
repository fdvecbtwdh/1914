extends RefCounted
class_name UiAnim

## 表现层动画工具箱 — 全部基于 Tween，只动 scale / position / modulate，不读写任何游戏数据。
##
## 约定：
## - 所有入口都要求节点已在场景树中（Tween 绑定节点生命周期，节点释放时自动失效）。
## - 临时节点（飘字、残影）打上 ui_anim meta，方便宿主在重绘时统一清掉。
## - 动画只做"视觉余韵"：数据/标签文本始终由调用方同步写成最终值，动画之后不能改变最终状态。

const FLOAT_META := "ui_anim"
## 飘字层级：高于棋盘迷雾层（_fog_layer 的 z_index = 100）
const FLOAT_Z: int = 120


static func _ok(node: Variant) -> bool:
	if node == null or not (node is Node):
		return false
	if not is_instance_valid(node):
		return false
	return (node as Node).is_inside_tree()


## 标记为临时动画节点（重绘时统一回收）
static func mark(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.set_meta(FLOAT_META, true)


static func is_marked(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.has_meta(FLOAT_META)


## 快速"弹一下"：放大到 peak 再回原位。用于数字标签、卡牌、标记。
static func pop(node: CanvasItem, peak: float = 1.12, dur: float = 0.18) -> void:
	if not _ok(node):
		return
	if node is Control:
		var c := node as Control
		if c.size != Vector2.ZERO:
			c.pivot_offset = c.size * 0.5
	var base: Vector2 = node.scale
	var t := node.create_tween()
	t.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", base * peak, dur * 0.4)
	t.tween_property(node, "scale", base, dur * 0.6)


## 左右抖动。用于受击卡牌；结束时回到原位置。
static func shake(node: Control, amp: float = 6.0, dur: float = 0.26) -> void:
	if not _ok(node):
		return
	var base: Vector2 = node.position
	var steps := 6
	var t := node.create_tween()
	for i in range(steps):
		var dir := 1.0 if i % 2 == 0 else -1.0
		var decay := 1.0 - float(i) / float(steps)
		t.tween_property(node, "position", base + Vector2(amp * dir * decay, 0.0), dur / float(steps))
	t.tween_property(node, "position", base, dur / float(steps))


## 颜色闪烁（modulate 叠加染色，结束后还原）。
## 只改 RGB、不碰 alpha：否则会和淡入/淡出类动画抢同一个属性。
## 典型坑：缩放入场（alpha 0→1）与染色同时跑，染色把进场前捕获的 alpha=0 写回去，
## 动画结束后整张卡变全透明，要等下一次整屏重绘才"重新出现"。
static func tint(node: CanvasItem, color: Color, dur: float = 0.4) -> void:
	if not _ok(node):
		return
	var base: Color = node.modulate
	var from := Color(base.r, base.g, base.b)
	var peak := Color(color.r, color.g, color.b)
	var t := node.create_tween()
	t.tween_method(_apply_rgb.bind(node), from, peak, dur * 0.25)
	t.tween_method(_apply_rgb.bind(node), peak, from, dur * 0.75)


## 只写回 modulate 的 RGB，当前 alpha 原样保留（避免把别人的淡入淡出踩掉）。
static func _apply_rgb(c: Color, node: CanvasItem) -> void:
	if _ok(node):
		node.modulate = Color(c.r, c.g, c.b, node.modulate.a)


## 淡入 + 缩放入场（卡牌部署、横幅出现）。
static func scale_in(node: CanvasItem, dur: float = 0.26) -> void:
	if not _ok(node):
		return
	var target: Vector2 = node.scale
	node.scale = target * 0.55
	node.modulate.a = 0.0
	var t := node.create_tween()
	t.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", target, dur)
	t.parallel().tween_property(node, "modulate:a", 1.0, dur * 0.7)


## 淡入（透明度 + 轻微放大），用于文字横幅。
static func fade_in_scale(node: CanvasItem, from_scale: float = 0.92, dur: float = 0.22) -> void:
	if not _ok(node):
		return
	var target: Vector2 = node.scale
	node.scale = target * from_scale
	node.modulate.a = 0.0
	var t := node.create_tween()
	t.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", target, dur)
	t.parallel().tween_property(node, "modulate:a", 1.0, dur)


## 从左（offset 方向）滑入，用于新出现的手牌按钮。
static func slide_in(node: Control, offset: Vector2 = Vector2(18, 0), dur: float = 0.22) -> void:
	if not _ok(node):
		return
	var target: Vector2 = node.position
	node.position = target + offset
	node.modulate.a = 0.0
	var t := node.create_tween()
	t.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "position", target, dur)
	t.parallel().tween_property(node, "modulate:a", 1.0, dur)


## 灰化缩小淡出（单位被击毁的残影）。
static func fade_out(node: CanvasItem, dur: float = 0.4) -> void:
	if not _ok(node):
		return
	var target: Vector2 = node.scale
	var t := node.create_tween()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	t.tween_property(node, "modulate:a", 0.0, dur)
	t.parallel().tween_property(node, "scale", target * 0.62, dur)
	t.tween_callback(node.queue_free)


## 呼吸脉冲（可循环），返回 Tween 供调用方打断。用于选中框、可点按钮。
static func pulse_loop(node: CanvasItem, low: float = 0.25, high: float = 0.7, dur: float = 0.85) -> Tween:
	if not _ok(node):
		return null
	var c: Color = node.modulate
	c.a = low
	node.modulate = c
	var t := node.create_tween().set_loops()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(node, "modulate:a", high, dur)
	t.tween_property(node, "modulate:a", low, dur)
	return t


## 上浮飘字（伤害数字 / 资源增减 / 占领度变化）。返回 Label，便于调用方附加后续处理。
static func float_text(host: Node, text: String, pos: Vector2, color: Color,
		font_size: int = 18, rise: float = 34.0, dur: float = 0.72) -> Label:
	if not _ok(host):
		return null
	var host_node := host as Node
	var lbl := Label.new()
	lbl.text = text
	lbl.position = pos
	lbl.z_index = FLOAT_Z
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	lbl.add_theme_constant_override("outline_size", 4)
	mark(lbl)
	host_node.add_child(lbl)
	lbl.modulate.a = 1.0
	var t := lbl.create_tween()
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	t.set_parallel(true)
	t.tween_property(lbl, "position", pos + Vector2(0.0, -rise), dur)
	t.tween_property(lbl, "modulate:a", 0.0, dur)
	t.set_parallel(false)
	t.tween_callback(lbl.queue_free)
	return lbl
