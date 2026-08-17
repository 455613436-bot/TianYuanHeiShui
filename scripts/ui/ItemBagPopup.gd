extends CanvasLayer
## ItemBagPopup
## 对话中打开的物品选择弹窗。
## 用途：
##   - 「使用」按钮 → 通过 item_picked 信号把 id 抛给 DialogueUI，
##     DialogueUI 会在输入区插入一个 token（不消耗物品，只是"要说什么"）。
##   - 「检视」按钮 → 弹出 ItemInspectPopup 展示物品大图 + 完整描述。
## 已经在本次组合里选过的物品会被外部通过 set_disabled_ids 变灰。

signal item_picked(item_id: String)
signal weapon_picked(item_id: String)
signal closed

const InspectPopupScene := preload("res://scenes/ui/ItemInspectPopup.tscn")

const ROW_MIN_HEIGHT := 120.0
const ICON_SIZE := Vector2(96, 96)
const NAME_FONT_SIZE := 22
const DESC_FONT_SIZE := 14
const BTN_WIDTH := 92.0
const BTN_HEIGHT := 40.0

@onready var root_panel: PanelContainer = $Center/Panel
@onready var title_label: Label = $Center/Panel/VBox/Title
@onready var scroll: ScrollContainer = $Center/Panel/VBox/Scroll
@onready var list_box: VBoxContainer = $Center/Panel/VBox/Scroll/List
@onready var empty_label: Label = $Center/Panel/VBox/Empty
@onready var close_btn: Button = $Center/Panel/VBox/Footer/CloseBtn
@onready var hint_label: Label = $Center/Panel/VBox/Footer/Hint

var _disabled_ids: Dictionary = {}       # id -> true
var _use_buttons_by_id: Dictionary = {}  # id -> Button（"使用"按钮，用来 disable/enable）
var _inspect_popup: CanvasLayer = null
var _selection_mode: String = "dialogue"


func _ready() -> void:
	close_btn.pressed.connect(_on_close_pressed)


## 打开弹窗；inventory 是玩家背包 id 数组；disabled_ids 是已经插入过输入区、要变灰的 id
func open_ui(inventory: Array, disabled_ids: Array) -> void:
	visible = true
	_selection_mode = "dialogue"
	_disabled_ids.clear()
	for id_variant in disabled_ids:
		_disabled_ids[String(id_variant)] = true
	_rebuild(inventory)


## 场景攻击用的背包选择：展示所有持有物，而不局限于普通对话可用物。
func open_weapon_selection(inventory: Array) -> void:
	visible = true
	_selection_mode = "weapon"
	_disabled_ids.clear()
	title_label.text = "选择攻击用物品"
	hint_label.text = "选择后会先显示力量检定的最终难度，确认后才会发动攻击。"
	_rebuild(inventory)


func close_ui() -> void:
	# 若检视弹窗还开着，先关掉
	if is_instance_valid(_inspect_popup) and _inspect_popup.visible:
		_inspect_popup.close_ui()
	visible = false
	closed.emit()


func _rebuild(inventory: Array) -> void:
	for child in list_box.get_children():
		child.queue_free()
	_use_buttons_by_id.clear()

	var usable_ids: Array = ItemDB.filter_usable(inventory) if _selection_mode == "dialogue" else inventory.duplicate()
	if usable_ids.is_empty():
		empty_label.visible = true
		scroll.visible = false
		return
	empty_label.visible = false
	scroll.visible = true

	for id_variant in usable_ids:
		var id: String = String(id_variant)
		list_box.add_child(_build_row(id))


## 构建单行：[缩略图 96x96] [名称+简介 左对齐] [使用][检视?]
func _build_row(item_id: String) -> Control:
	var item: Dictionary = ItemDB.get_item(item_id)
	var display_name: String = String(item.get("display_name", item_id))
	var short_desc: String = String(item.get("short_desc", ""))
	var inspectable: bool = ItemDB.is_inspectable(item_id)

	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_MIN_HEIGHT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 给每行加一个淡背景，视觉上更像"卡片"
	var row_style := StyleBoxFlat.new()
	row_style.bg_color = Color(0.12, 0.11, 0.10, 0.65)
	row_style.set_corner_radius_all(6)
	row_style.set_content_margin_all(10)
	row.add_theme_stylebox_override("panel", row_style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(hbox)

	# ── 缩略图 ──
	var icon_box := PanelContainer.new()
	icon_box.custom_minimum_size = ICON_SIZE
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = Color(0.06, 0.05, 0.05, 1.0)
	icon_style.set_corner_radius_all(4)
	icon_style.border_color = Color(0.35, 0.30, 0.22)
	icon_style.set_border_width_all(1)
	icon_box.add_theme_stylebox_override("panel", icon_style)
	hbox.add_child(icon_box)

	var icon: Texture2D = ItemDB.get_icon(item_id)
	if icon != null:
		var tex_rect := TextureRect.new()
		tex_rect.texture = icon
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_box.add_child(tex_rect)
	else:
		var placeholder := Label.new()
		placeholder.text = "?"
		placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		placeholder.add_theme_font_size_override("font_size", 36)
		placeholder.add_theme_color_override("font_color", Color(0.45, 0.42, 0.35))
		icon_box.add_child(placeholder)

	# ── 名称 + 简介 ──
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 4)
	hbox.add_child(text_box)

	var name_label := Label.new()
	name_label.text = display_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.75))
	text_box.add_child(name_label)

	var desc_label := Label.new()
	desc_label.text = short_desc
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	desc_label.add_theme_font_size_override("font_size", DESC_FONT_SIZE)
	desc_label.add_theme_color_override("font_color", Color(0.80, 0.80, 0.76))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_box.add_child(desc_label)

	# ── 右侧按钮区 ──
	var btn_box := VBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 6)
	btn_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(btn_box)

	if inspectable:
		var inspect_btn := Button.new()
		inspect_btn.text = "检视"
		inspect_btn.tooltip_text = "查看物品大图 / 完整说明"
		inspect_btn.custom_minimum_size = Vector2(BTN_WIDTH, BTN_HEIGHT)
		inspect_btn.pressed.connect(_on_inspect_pressed.bind(item_id))
		btn_box.add_child(inspect_btn)

	var use_btn := Button.new()
	use_btn.text = "作为武器" if _selection_mode == "weapon" else "使用"
	use_btn.tooltip_text = "将该物品作为攻击武器" if _selection_mode == "weapon" else "在对话输入区插入「使用道具」标签"
	use_btn.custom_minimum_size = Vector2(BTN_WIDTH, BTN_HEIGHT)
	use_btn.disabled = _disabled_ids.has(item_id)
	use_btn.pressed.connect(_on_use_pressed.bind(item_id))
	btn_box.add_child(use_btn)
	_use_buttons_by_id[item_id] = use_btn

	return row


## 外部（DialogueUI）在弹窗打开期间改变了 "已选" 状态时刷新按钮启用/禁用
func set_disabled_ids(disabled_ids: Array) -> void:
	_disabled_ids.clear()
	for id_variant in disabled_ids:
		_disabled_ids[String(id_variant)] = true
	for id in _use_buttons_by_id.keys():
		var btn: Button = _use_buttons_by_id[id]
		if is_instance_valid(btn):
			btn.disabled = _disabled_ids.has(String(id))


func _on_use_pressed(id: String) -> void:
	if _selection_mode == "weapon":
		weapon_picked.emit(id)
		close_ui()
		return
	# 抛出信号；是否要在本次组合里禁用由 DialogueUI 决定（回调 set_disabled_ids）
	item_picked.emit(id)


func _on_inspect_pressed(id: String) -> void:
	var popup := _get_or_create_inspect_popup()
	if popup == null:
		return
	popup.open_ui(id)


func _get_or_create_inspect_popup() -> CanvasLayer:
	if is_instance_valid(_inspect_popup):
		return _inspect_popup
	_inspect_popup = InspectPopupScene.instantiate()
	# 把 inspect 弹窗挂在自己下面，layer=30 会覆盖 ItemBagPopup(20) 之上
	add_child(_inspect_popup)
	if _inspect_popup.has_signal("closed"):
		_inspect_popup.closed.connect(_on_inspect_closed)
	return _inspect_popup


func _on_inspect_closed() -> void:
	# 检视关闭后什么也不做，背包本身仍然可见 → 用户视觉上"回到了背包"
	pass


func _on_close_pressed() -> void:
	close_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# 若检视弹窗开着，让它自己吃 Esc（它 layer 更高）
	if is_instance_valid(_inspect_popup) and _inspect_popup.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close_ui()
			get_viewport().set_input_as_handled()
