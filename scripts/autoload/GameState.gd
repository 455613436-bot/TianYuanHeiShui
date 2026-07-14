extends Node
## Cross-scene game state, scene snapshots, and versioned JSON saves.

signal pollution_changed(new_value: int)
signal affinity_changed(npc_id: String, new_value: int)
signal item_added(item_id: String)
signal clue_triggered(clue_id: String)
signal save_completed(path: String)
signal load_completed(path: String)
signal load_failed(path: String, reason: String)

const MAX_POLLUTION := 6
const SAVE_VERSION := 1
const MANUAL_SAVE_SLOT_COUNT := 5
const SAVE_PATH := "user://save_01.json"
const AUTO_SAVE_PATH := "user://save_auto.json"
const AUTO_SAVE_INTERVAL_SECONDS := 300.0
const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const DEFAULT_MAP_RETURN_SCENE := "res://scenes/main/Main.tscn"

var player_role: String = "medic"
var player_name: String = "圆鸮"
var pollution: int = 0
var affinity: Dictionary = {}
var inventory: Array[String] = []
var clues: Dictionary = {}

var map_return_scene_path: String = DEFAULT_MAP_RETURN_SCENE
var current_scene_path: String = MAP_SCENE
var scene_states: Dictionary = {}
var unlocked_locations: Dictionary = {DEFAULT_MAP_RETURN_SCENE: true}
var quest_stages: Dictionary = {}
var investigation_states: Dictionary = {}
var npc_dialogue_stages: Dictionary = {}
var triggered_events: Dictionary = {}
var one_shot_items: Dictionary = {}

var _autosave_timer: Timer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_autosave_timer()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game(AUTO_SAVE_PATH)


func add_pollution(amount: int = 1) -> void:
	pollution = clampi(pollution + amount, 0, MAX_POLLUTION)
	pollution_changed.emit(pollution)
	if pollution >= MAX_POLLUTION:
		trigger_event("ending_mituu")
		clue_triggered.emit("ending_mituu")


func add_affinity(npc_id: String, amount: int = 1) -> void:
	if npc_id.is_empty():
		return
	affinity[npc_id] = int(affinity.get(npc_id, 0)) + amount
	affinity_changed.emit(npc_id, affinity[npc_id])


func get_affinity(npc_id: String) -> int:
	return int(affinity.get(npc_id, 0))


func add_item(item_id: String) -> void:
	if item_id.is_empty() or inventory.has(item_id):
		return
	inventory.append(item_id)
	item_added.emit(item_id)


func has_item(item_id: String) -> bool:
	return inventory.has(item_id)


func remove_item(item_id: String) -> bool:
	var index := inventory.find(item_id)
	if index < 0:
		return false
	inventory.remove_at(index)
	return true


func collect_one_shot_item(item_id: String) -> bool:
	if item_id.is_empty() or one_shot_items.has(item_id):
		return false
	one_shot_items[item_id] = true
	add_item(item_id)
	return true


func is_one_shot_item_collected(item_id: String) -> bool:
	return bool(one_shot_items.get(item_id, false))


func trigger_clue(clue_id: String) -> void:
	if clue_id.is_empty() or clues.has(clue_id):
		return
	clues[clue_id] = true
	clue_triggered.emit(clue_id)


func has_clue(clue_id: String) -> bool:
	return bool(clues.get(clue_id, false))


func unlock_location(location_id: String) -> void:
	if not location_id.is_empty():
		unlocked_locations[location_id] = true


func is_location_unlocked(location_id: String) -> bool:
	return bool(unlocked_locations.get(location_id, false))


func set_quest_stage(quest_id: String, stage: int) -> void:
	if not quest_id.is_empty():
		quest_stages[quest_id] = maxi(stage, 0)


func get_quest_stage(quest_id: String) -> int:
	return int(quest_stages.get(quest_id, 0))


func set_investigation_state(point_id: String, state_value: Variant = true) -> void:
	if not point_id.is_empty():
		investigation_states[point_id] = _json_safe(state_value)


func get_investigation_state(point_id: String, default_value: Variant = false) -> Variant:
	return investigation_states.get(point_id, default_value)


func set_npc_dialogue_stage(npc_id: String, stage: int) -> void:
	if not npc_id.is_empty():
		npc_dialogue_stages[npc_id] = maxi(stage, 0)


func advance_npc_dialogue_stage(npc_id: String) -> int:
	var next_stage := get_npc_dialogue_stage(npc_id) + 1
	set_npc_dialogue_stage(npc_id, next_stage)
	return next_stage


func get_npc_dialogue_stage(npc_id: String) -> int:
	return int(npc_dialogue_stages.get(npc_id, 0))


func trigger_event(event_id: String) -> void:
	if not event_id.is_empty():
		triggered_events[event_id] = true


func has_triggered_event(event_id: String) -> bool:
	return bool(triggered_events.get(event_id, false))


func remember_map_return_scene(scene_path: String) -> void:
	if scene_path.is_empty() or scene_path == MAP_SCENE:
		return
	map_return_scene_path = scene_path


func capture_current_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := String(scene.scene_file_path)
	if path.is_empty():
		return
	current_scene_path = path
	var state: Dictionary = _dictionary_copy(scene_states.get(path, {}))
	var player := get_tree().get_first_node_in_group("player")
	if player is Node2D and _belongs_to_scene(scene, player):
		state["player_position"] = _vector_to_array(player.global_position)

	var node_states: Dictionary = _dictionary_copy(state.get("nodes", {}))
	for node in get_tree().get_nodes_in_group("persistent_scene_state"):
		if not _belongs_to_scene(scene, node):
			continue
		if not node.has_method("capture_scene_state"):
			continue
		var persistent_id := _persistent_node_id(scene, node)
		if persistent_id.is_empty():
			continue
		node_states[persistent_id] = _json_safe(node.capture_scene_state())
	state["nodes"] = node_states
	scene_states[path] = state


func restore_current_scene() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := String(scene.scene_file_path)
	if path.is_empty():
		return
	current_scene_path = path
	var state: Dictionary = _dictionary_copy(scene_states.get(path, {}))
	var player := get_tree().get_first_node_in_group("player")
	if player is Node2D and _belongs_to_scene(scene, player) and state.has("player_position"):
		player.global_position = _read_vector2(state["player_position"], player.global_position)

	var node_states: Dictionary = _dictionary_copy(state.get("nodes", {}))
	for node in get_tree().get_nodes_in_group("persistent_scene_state"):
		if not _belongs_to_scene(scene, node) or not node.has_method("restore_scene_state"):
			continue
		var persistent_id := _persistent_node_id(scene, node)
		if node_states.has(persistent_id) and node_states[persistent_id] is Dictionary:
			node.restore_scene_state(node_states[persistent_id])


func change_scene(scene_path: String, remember_return: bool = false, autosave: bool = true) -> Error:
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return ERR_FILE_NOT_FOUND
	capture_current_scene()
	if remember_return:
		var scene := get_tree().current_scene
		if scene != null:
			remember_map_return_scene(String(scene.scene_file_path))
	current_scene_path = scene_path
	if autosave:
		save_game(AUTO_SAVE_PATH, false)
	return get_tree().change_scene_to_file(scene_path)


func open_world_map() -> Error:
	return change_scene(MAP_SCENE, true)


func close_world_map() -> Error:
	var target := map_return_scene_path
	if target.is_empty() or target == MAP_SCENE or not ResourceLoader.exists(target):
		target = DEFAULT_MAP_RETURN_SCENE
	return change_scene(target)


func enter_location(scene_path: String) -> Error:
	unlock_location(scene_path)
	return change_scene(scene_path)


func save_game(path: String = SAVE_PATH, capture_scene: bool = true) -> Error:
	if capture_scene:
		capture_current_scene()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		load_failed.emit(path, "无法打开存档文件：%s" % error_string(open_error))
		return open_error
	var data := {
		"save_version": SAVE_VERSION,
		"saved_at_unix": int(Time.get_unix_time_from_system()),
		"saved_at_text": Time.get_datetime_string_from_system(false, true),
		"save_kind": "auto" if path == AUTO_SAVE_PATH else "manual",
		"current_scene": current_scene_path,
		"player_position": _dictionary_copy(scene_states.get(current_scene_path, {})).get("player_position", [0.0, 0.0]),
		"map_return_scene": map_return_scene_path,
		"player_role": player_role,
		"player_name": player_name,
		"pollution": pollution,
		"affinity": affinity,
		"inventory": inventory,
		"clues": clues,
		"unlocked_locations": unlocked_locations,
		"quest_stages": quest_stages,
		"investigation_states": investigation_states,
		"npc_dialogue_stages": npc_dialogue_stages,
		"triggered_events": triggered_events,
		"one_shot_items": one_shot_items,
		"scene_states": scene_states,
	}
	file.store_string(JSON.stringify(_json_safe(data), "\t"))
	file.close()
	save_completed.emit(path)
	return OK


func load_game(path: String = SAVE_PATH, switch_scene: bool = true) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		load_failed.emit(path, "无法读取存档：%s" % error_string(open_error))
		return open_error
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK or json.data is not Dictionary:
		load_failed.emit(path, "存档 JSON 已损坏")
		return ERR_PARSE_ERROR
	var data: Dictionary = json.data
	var version_value: Variant = data.get("save_version", 0)
	if not (version_value is int or version_value is float) or int(version_value) != SAVE_VERSION:
		load_failed.emit(path, "不支持的存档版本")
		return ERR_FILE_UNRECOGNIZED

	var loaded_scene := _safe_scene_path(data.get("current_scene", MAP_SCENE), MAP_SCENE)
	var loaded_return := _safe_scene_path(data.get("map_return_scene", DEFAULT_MAP_RETURN_SCENE), DEFAULT_MAP_RETURN_SCENE)
	player_role = _safe_string(data.get("player_role", "medic"), "medic")
	player_name = _safe_string(data.get("player_name", "圆鸮"), "圆鸮")
	pollution = clampi(_safe_int(data.get("pollution", 0), 0), 0, MAX_POLLUTION)
	affinity = _int_dictionary(data.get("affinity", {}))
	inventory = _string_array(data.get("inventory", []))
	clues = _bool_dictionary(data.get("clues", {}))
	unlocked_locations = _bool_dictionary(data.get("unlocked_locations", {}))
	quest_stages = _int_dictionary(data.get("quest_stages", {}))
	investigation_states = _dictionary_copy(data.get("investigation_states", {}))
	npc_dialogue_stages = _int_dictionary(data.get("npc_dialogue_stages", {}))
	triggered_events = _bool_dictionary(data.get("triggered_events", {}))
	one_shot_items = _bool_dictionary(data.get("one_shot_items", {}))
	scene_states = _sanitize_scene_states(data.get("scene_states", {}))
	current_scene_path = loaded_scene
	map_return_scene_path = loaded_return
	if not scene_states.has(current_scene_path) and data.has("player_position"):
		scene_states[current_scene_path] = {
			"player_position": _vector_to_array(_read_vector2(data["player_position"], Vector2.ZERO)),
			"nodes": {},
		}
	unlocked_locations[DEFAULT_MAP_RETURN_SCENE] = true

	pollution_changed.emit(pollution)
	load_completed.emit(path)
	if switch_scene:
		if get_tree().current_scene != null and get_tree().current_scene.scene_file_path == current_scene_path:
			call_deferred("restore_current_scene")
		else:
			var scene_error := get_tree().change_scene_to_file(current_scene_path)
			if scene_error != OK:
				load_failed.emit(path, "存档场景无法加载：%s" % error_string(scene_error))
				return scene_error
	return OK


func clear_save(path: String = SAVE_PATH) -> Error:
	if not FileAccess.file_exists(path):
		return OK
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func summary_for_llm() -> String:
	var lines: PackedStringArray = []
	lines.append("【玩家信息】职业：%s，姓名：%s" % [player_role, player_name])
	lines.append("【污染度】%d/%d" % [pollution, MAX_POLLUTION])
	if not inventory.is_empty():
		lines.append("【已持有道具】%s" % ", ".join(inventory))
	if not clues.is_empty():
		lines.append("【已触发线索】%s" % ", ".join(clues.keys()))
	return "\n".join(lines)


func get_manual_save_path(slot: int) -> String:
	var safe_slot := clampi(slot, 1, MANUAL_SAVE_SLOT_COUNT)
	return "user://save_%02d.json" % safe_slot


func get_save_metadata(path: String) -> Dictionary:
	var result := {
		"path": path,
		"exists": FileAccess.file_exists(path),
		"valid": false,
		"saved_at_unix": 0,
		"saved_at_text": "",
		"current_scene": "",
		"player_name": "",
	}
	if not result["exists"]:
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return result
	var version: Variant = parsed.get("save_version", 0)
	if not (version is int or version is float) or int(version) != SAVE_VERSION:
		return result
	result["valid"] = true
	result["saved_at_unix"] = _safe_int(parsed.get("saved_at_unix", 0), 0)
	result["saved_at_text"] = _safe_string(parsed.get("saved_at_text", ""), "")
	result["current_scene"] = _safe_string(parsed.get("current_scene", ""), "")
	result["player_name"] = _safe_string(parsed.get("player_name", ""), "")
	return result


func _setup_autosave_timer() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.name = "AutosaveTimer"
	_autosave_timer.wait_time = AUTO_SAVE_INTERVAL_SECONDS
	_autosave_timer.one_shot = false
	_autosave_timer.autostart = true
	_autosave_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_autosave_timer.timeout.connect(_perform_periodic_autosave)
	add_child(_autosave_timer)


func _perform_periodic_autosave() -> void:
	var error := save_game(AUTO_SAVE_PATH)
	if error != OK:
		push_warning("[GameState] 自动存档失败：%s" % error_string(error))


func _belongs_to_scene(scene: Node, node: Node) -> bool:
	return node == scene or scene.is_ancestor_of(node)


func _persistent_node_id(scene: Node, node: Node) -> String:
	if node.has_method("get_persistent_id"):
		return String(node.get_persistent_id())
	return String(scene.get_path_to(node))


func _safe_scene_path(value: Variant, fallback: String) -> String:
	var path := _safe_string(value, fallback)
	return path if ResourceLoader.exists(path) else fallback


func _safe_string(value: Variant, fallback: String) -> String:
	return String(value) if value is String else fallback


func _safe_int(value: Variant, fallback: int) -> int:
	return int(value) if value is int or value is float else fallback


func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is not Array:
		return result
	for item in value:
		if item is String and not item.is_empty() and not result.has(item):
			result.append(item)
	return result


func _dictionary_copy(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


func _int_dictionary(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in value:
		var item: Variant = value[key]
		if key is String and (item is int or item is float):
			result[key] = int(item)
	return result


func _bool_dictionary(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in value:
		if key is String and value[key] is bool:
			result[key] = value[key]
	return result


func _sanitize_scene_states(value: Variant) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for path in value:
		if path is not String or value[path] is not Dictionary:
			continue
		var state: Dictionary = value[path].duplicate(true)
		if state.has("player_position"):
			state["player_position"] = _vector_to_array(_read_vector2(state["player_position"], Vector2.ZERO))
		if state.has("nodes") and state["nodes"] is not Dictionary:
			state["nodes"] = {}
		result[path] = state
	return result


func _vector_to_array(value: Vector2) -> Array[float]:
	return [value.x, value.y]


func _read_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Array and value.size() >= 2:
		var x: Variant = value[0]
		var y: Variant = value[1]
		if (x is int or x is float) and (y is int or y is float):
			return Vector2(float(x), float(y))
	if value is Dictionary and value.has("x") and value.has("y"):
		var x: Variant = value["x"]
		var y: Variant = value["y"]
		if (x is int or x is float) and (y is int or y is float):
			return Vector2(float(x), float(y))
	return fallback


func _json_safe(value: Variant) -> Variant:
	if value is Vector2:
		return _vector_to_array(value)
	if value is Dictionary:
		var dictionary := {}
		for key in value:
			dictionary[String(key)] = _json_safe(value[key])
		return dictionary
	if value is Array:
		var array := []
		for item in value:
			array.append(_json_safe(item))
		return array
	if value is String or value is bool or value is int or value is float or value == null:
		return value
	return String(value)
