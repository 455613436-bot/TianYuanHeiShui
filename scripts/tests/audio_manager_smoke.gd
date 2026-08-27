extends Node
## Headless regression smoke test for the global audio manager.

const LOCATIONS_PATH := "res://data/locations.json"
const SFX_PATHS := [
	"res://assets/audio/sfx/click.ogg",
	"res://assets/audio/sfx/confirm.ogg",
	"res://assets/audio/sfx/cancel.ogg",
	"res://assets/audio/sfx/error.ogg",
	"res://assets/audio/sfx/select.ogg",
]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null:
		_fail("AudioManager autoload was not created")
		return

	var locations_file := FileAccess.open(LOCATIONS_PATH, FileAccess.READ)
	if locations_file == null:
		_fail("Location data could not be opened")
		return
	var parsed: Variant = JSON.parse_string(locations_file.get_as_text())
	locations_file.close()
	if not parsed is Array or (parsed as Array).size() != 12:
		_fail("Expected exactly 12 locations in location data")
		return

	var paths := {}
	var first_id := ""
	var second_id := ""
	for raw_location in parsed:
		if not raw_location is Dictionary:
			_fail("Location data contains a non-dictionary entry")
			return
		var location: Dictionary = raw_location
		var location_id := String(location.get("id", ""))
		var bgm_path := String(location.get("bgm", ""))
		if location_id.is_empty() or bgm_path.is_empty() or not ResourceLoader.exists(bgm_path):
			_fail("Invalid or missing BGM mapping for %s" % location_id)
			return
		if paths.has(bgm_path):
			_fail("Two locations reuse the same BGM path: %s" % bgm_path)
			return
		paths[bgm_path] = location_id
		if first_id.is_empty():
			first_id = location_id
		elif second_id.is_empty():
			second_id = location_id

	for sfx_path in SFX_PATHS:
		if not ResourceLoader.exists(sfx_path):
			_fail("Missing SFX resource: %s" % sfx_path)
			return

	for raw_location in parsed:
		var location: Dictionary = raw_location
		var location_id := String(location.get("id", ""))
		var scene_path := String(location.get("scene", ""))
		var packed_scene := load(scene_path) as PackedScene
		if packed_scene == null:
			_fail("Location scene could not be loaded: %s" % scene_path)
			return
		var location_scene := packed_scene.instantiate()
		get_tree().root.add_child(location_scene)
		await get_tree().process_frame
		if String(audio.get("_current_track_key")) != "location:%s" % location_id:
			_fail("Location scene did not start its mapped BGM: %s" % location_id)
			return
		location_scene.queue_free()
		await get_tree().process_frame

	audio.call("play_location_bgm", first_id)
	await get_tree().process_frame
	if String(audio.get("_current_track_key")) != "location:%s" % first_id:
		_fail("First location BGM did not start")
		return
	var active_index := int(audio.get("_active_bgm_index"))
	audio.call("play_location_bgm", first_id)
	await get_tree().process_frame
	if int(audio.get("_active_bgm_index")) != active_index:
		_fail("Re-entering the same location restarted its BGM")
		return

	audio.call("play_location_bgm", second_id)
	await get_tree().process_frame
	if String(audio.get("_current_track_key")) != "location:%s" % second_id:
		_fail("Location BGM did not switch on scene change")
		return

	var button := Button.new()
	button.name = "AudioSmokeConfirmButton"
	add_child(button)
	var option := OptionButton.new()
	option.name = "AudioSmokeOptionButton"
	add_child(option)
	await get_tree().process_frame
	if not bool(button.get_meta("_audio_manager_bound", false)):
		_fail("Dynamic Button was not bound to AudioManager")
		return
	if not bool(option.get_meta("_audio_manager_bound", false)):
		_fail("Dynamic OptionButton was not bound to AudioManager")
		return
	var bgm_index_before_click := int(audio.get("_active_bgm_index"))
	var bgm_players: Array = audio.get("_bgm_players") as Array
	var bgm_player_before_click := bgm_players[bgm_index_before_click] as AudioStreamPlayer
	var bgm_position_before_click := bgm_player_before_click.get_playback_position()
	button.pressed.emit()
	await get_tree().process_frame
	var bgm_index_after_click := int(audio.get("_active_bgm_index"))
	var bgm_player_after_click := bgm_players[bgm_index_after_click] as AudioStreamPlayer
	if bgm_index_after_click != bgm_index_before_click or bgm_player_after_click != bgm_player_before_click:
		_fail("Button SFX restarted or swapped the active BGM player")
		return
	if bgm_player_after_click.get_playback_position() + 0.01 < bgm_position_before_click:
		_fail("Button SFX rewound the active BGM playback position")
		return
	var sfx_playing := false
	var sfx_players: Array = audio.get("_sfx_players") as Array
	for player in sfx_players:
		if player is AudioStreamPlayer and (player as AudioStreamPlayer).playing:
			sfx_playing = true
			break
	if not sfx_playing:
		_fail("Button press did not start a SFX player")
		return
	option.add_item("选择项")
	option.item_selected.emit(0)

	print("AUDIO_MANAGER_SMOKE_OK")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("AUDIO_MANAGER_SMOKE_FAILED: " + message)
	get_tree().quit(1)
