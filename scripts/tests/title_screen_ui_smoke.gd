extends Node


const TITLE_SCENE := "res://scenes/ui/TitleScreen.tscn"
const EXPECTED_TEXTURES := {
	"NewGameBtn": "res://assets/ui/title_screen/button_new_game.png",
	"ContinueBtn": "res://assets/ui/title_screen/button_continue.png",
	"SettingsBtn": "res://assets/ui/title_screen/button_settings.png",
	"QuitBtn": "res://assets/ui/title_screen/button_quit.png",
}


func _ready() -> void:
	var packed := load(TITLE_SCENE) as PackedScene
	if packed == null:
		_fail("TitleScreen scene could not be loaded")
		return
	var title := packed.instantiate()
	add_child(title)
	await get_tree().process_frame
	await get_tree().process_frame

	var previous_bottom := -1.0
	for button_name: String in EXPECTED_TEXTURES:
		var button := title.get_node("Menu/%s" % button_name) as TextureButton
		if button == null:
			_fail("%s is not a TextureButton" % button_name)
			return
		if button.pressed.get_connections().is_empty():
			_fail("%s has no pressed callback" % button_name)
			return
		if button.texture_normal == null or button.texture_normal.resource_path != EXPECTED_TEXTURES[button_name]:
			_fail("%s does not use the supplied artwork" % button_name)
			return
		var rect := button.get_global_rect()
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			_fail("%s has an empty click area" % button_name)
			return
		if rect.position.y < previous_bottom:
			_fail("%s overlaps the preceding button" % button_name)
			return
		if rect.end.y > get_viewport().get_visible_rect().end.y:
			_fail("%s extends below the viewport" % button_name)
			return
		previous_bottom = rect.end.y

	print("TITLE_SCREEN_UI_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("TITLE_SCREEN_UI_SMOKE_FAILED: " + message)
	get_tree().quit(1)
