extends Node
## Verifies that the release font uses a tiny local fallback for U+27F3.

const MAIN_FONT_PATH := "res://assets/fonts/SourceHanSerifSC-Game.otf"
const SYMBOL_FONT_PATH := "res://assets/fonts/TianyuanSymbols.ttf"
const GAME_FONT_PATH := "res://assets/fonts/game_font.tres"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_font := load(MAIN_FONT_PATH) as Font
	var symbol_font := load(SYMBOL_FONT_PATH) as Font
	var game_font := load(GAME_FONT_PATH) as Font
	if main_font == null or symbol_font == null or game_font == null:
		_fail("One or more release fonts could not be loaded")
		return
	if main_font.has_char(0x27F3):
		_fail("Main Chinese subset unexpectedly contains U+27F3")
		return
	if not symbol_font.has_char(0x27F3):
		_fail("Tiny symbol fallback does not contain U+27F3")
		return
	if not game_font.has_char(0x27F3):
		_fail("Composite game font cannot resolve U+27F3")
		return
	var dialogue_scene := load("res://scenes/ui/DialogueUI.tscn") as PackedScene
	var dialogue := dialogue_scene.instantiate()
	var regenerate := dialogue.get_node("RootPanel/HBox/Center/ChoiceRow/RegenerateChoices") as Button
	if regenerate.text != "⟳ 重新生成" or regenerate.custom_minimum_size.x < 168.0:
		_fail("Regenerate button text or width does not match the release contract")
		return
	dialogue.free()
	print("FONT_FALLBACK_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("FONT_FALLBACK_SMOKE_FAILED: " + message)
	get_tree().quit(1)
