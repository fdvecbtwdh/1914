extends Control
class_name BetaBanner

## 顶部测试版本提示横幅（类 EFT Beta 风格：深色半透明底 + 琥珀色上下边线 + 黄色文字）
## 用法：BetaBanner.attach(任意已入树节点)。
## 注意：不用 StyleBoxFlat 分边边框（部分导出模板无 border_color_top 等属性，
## 赋值失败会中断 _init）—— 边线用 ColorRect 自绘，跨平台一致。

const BANNER_TEXT := "注意！1914 当前为测试版本（Beta）· 功能与数值仍在调整中，可能存在 Bug 与性能问题 · 欢迎测试并反馈"
const HEIGHT := 24.0

var panel: Panel = null
var label: Label = null
var line_top: ColorRect = null
var line_bottom: ColorRect = null


static func attach(parent: Node) -> void:
	if parent == null:
		return
	if parent.has_node("BetaBanner"):
		return  # 已挂载，防重复
	var banner: BetaBanner = BetaBanner.new()
	banner.name = "BetaBanner"
	parent.add_child(banner)
	banner._follow_viewport()
	var vp := parent.get_viewport()
	if vp != null and not vp.size_changed.is_connected(banner._follow_viewport):
		vp.size_changed.connect(banner._follow_viewport)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	panel = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.03, 0.62)
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	line_top = ColorRect.new()
	line_top.color = Color(1.0, 0.78, 0.25, 0.85)
	line_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line_top)

	line_bottom = ColorRect.new()
	line_bottom.color = Color(1.0, 0.78, 0.25, 0.55)
	line_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line_bottom)

	label = Label.new()
	label.text = BANNER_TEXT
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


## 按当前视口逻辑尺寸铺满顶部（不依赖 anchors）
func _follow_viewport() -> void:
	var vs := Vector2(1152, 648)
	var vp := get_viewport()
	if vp != null:
		vs = vp.get_visible_rect().size
	position = Vector2.ZERO
	size = Vector2(vs.x, HEIGHT)
	panel.position = Vector2.ZERO
	panel.size = Vector2(vs.x, HEIGHT)
	line_top.position = Vector2.ZERO
	line_top.size = Vector2(vs.x, 2)
	line_bottom.position = Vector2(0, HEIGHT - 1)
	line_bottom.size = Vector2(vs.x, 1)
	label.position = Vector2.ZERO
	label.size = Vector2(vs.x, HEIGHT)
