extends CanvasLayer
## ItemInspectPopup
## 物品检视弹窗：全屏半透明遮罩 + 中间大图 + 名称 + 完整说明 + 右上角关闭。
## 使用方式：ItemBagPopup 实例化本场景（或复用），调用 open_ui(item_id)。
## 关闭时 emit closed 信号，由 ItemBagPopup 决定要不要重新弹回背包。

signal closed

@onready var backdrop: ColorRect = $Backdrop
@onready var panel: PanelContainer = $Center/Panel
@onready var title_label: Label = $Center/Panel/VBox/Header/Title
@onready var close_btn: Button = $Center/Panel/VBox/Header/CloseBtn
@onready var image_rect: TextureRect = $Center/Panel/VBox/Body/ImageBox/Image
@onready var image_placeholder: Label = $Center/Panel/VBox/Body/ImageBox/Placeholder
@onready var desc_label: RichTextLabel = $Center/Panel/VBox/Body/Description

var _current_item_id: String = ""


func _ready() -> void:
	close_btn.pressed.connect(_on_close_pressed)


func open_ui(item_id: String) -> void:
	_current_item_id = item_id
	var item: Dictionary = ItemDB.get_item(item_id)
	title_label.text = String(item.get("display_name", item_id))

	var img: Texture2D = ItemDB.get_inspect_image(item_id)
	if img != null:
		image_rect.texture = img
		image_rect.visible = true
		image_placeholder.visible = false
	else:
		image_rect.texture = null
		image_rect.visible = false
		image_placeholder.visible = true
		image_placeholder.text = "（暂无图像）"

	# 完整描述：short_desc + usage_hints
	var parts: PackedStringArray = []
	var short_desc: String = String(item.get("short_desc", ""))
	if short_desc != "":
		parts.append(short_desc)
	var hints_variant: Variant = item.get("usage_hints", [])
	if hints_variant is Array:
		for h in (hints_variant as Array):
			var s := String(h).strip_edges()
			if s != "":
				parts.append("· " + s)
	desc_label.clear()
	desc_label.append_text("\n\n".join(parts) if not parts.is_empty() else "（这件道具还没有更多说明。）")

	visible = true


func close_ui() -> void:
	visible = false
	_current_item_id = ""
	closed.emit()


func _on_close_pressed() -> void:
	close_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close_ui()
			get_viewport().set_input_as_handled()
