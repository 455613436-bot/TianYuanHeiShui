extends Node
## Cross-scene game state, scene snapshots, and versioned JSON saves.

signal pollution_changed(new_value: int)
signal affinity_changed(npc_id: String, new_value: int)
signal item_added(item_id: String)
signal clue_triggered(clue_id: String)
signal document_clue_added(entry: Dictionary)
signal save_completed(path: String)
signal load_completed(path: String)
signal load_failed(path: String, reason: String)
signal attributes_changed()
signal morning_report_ready(report: Dictionary)
signal night_return_required(message: String)

const MAX_POLLUTION := 6
const SAVE_VERSION := 5
## 可读取的历史存档版本；v5 新增祭坛供奉、结局和重置属性状态。
const READABLE_SAVE_VERSIONS := [1, 2, 3, 4, 5]
const VILLAGE_MAP_ITEM_ID := "village_map"
const MANUAL_SAVE_SLOT_COUNT := 5
const SAVE_PATH := "user://save_01.json"
const AUTO_SAVE_PATH := "user://save_auto.json"
const AUTO_SAVE_INTERVAL_SECONDS := 300.0
const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const WORLD_MAP_PACKED_SCENE := preload("res://scenes/map/WorldMap.tscn")
const MAP_OVERLAY_META := &"_world_map_overlay"
const MAP_OVERLAY_LAYER := 100
const DEFAULT_MAP_RETURN_SCENE := "res://scenes/locations/VillageChiefHouse.tscn"
const TEMP_DORM_LOCATION_ID := "temporary_dorm"
const TEMP_DORM_SCENE := "res://scenes/locations/TemporaryDorm.tscn"
const SCENE_ITEM_INTERACTION_SCRIPT := preload("res://scripts/ui/SceneItemInteraction.gd")

## 玩家初始仅携带相机；村庄手绘地图需在村长家由村长发放。
const INITIAL_INVENTORY: Array[String] = ["camera"]

## 玩家属性系统：4 维，每维 0-5，总分固定 10
const ATTRIBUTE_KEYS := ["strength", "agility", "intellect", "charisma"]
const ATTRIBUTE_MIN := 0
const ATTRIBUTE_MAX := 5
const ATTRIBUTE_TOTAL_POINTS := 10
const ATTRIBUTE_LABELS := {
	"strength": "力量",
	"agility": "敏捷",
	"intellect": "智力",
	"charisma": "魅力",
}

var player_role: String = "medic"
var player_name: String = "圆鸮"
var pollution: int = 0
var affinity: Dictionary = {}
var inventory: Array[String] = []
var clues: Dictionary = {}
## 场景资料线索册，元素为 {id, title, summary, image_path, linked_clue_ids}，按发现顺序保存。
var document_clues: Array[Dictionary] = []
## 玩家四维基础属性；初始分配为 0-5，剧情永久成长可以突破 5。
## 首次启动前为空 -> attributes_allocated()==false 时应该跳转到属性分配 UI。
var attributes: Dictionary = {}
var attributes_locked_in: bool = false
## 持久性属性调整用于未清洁惩罚；每天增益单独结算，不污染初始属性分配。
var attribute_adjustments: Dictionary = {}
var daily_attribute_bonuses: Dictionary = {}
## 水接触由场景交互调用 record_water_contact() 统一记录；按天保存以供次日九点结算。
var water_contact_count: int = 0
var water_contact_days: Dictionary = {}
var showered_days: Dictionary = {}
## 祭坛供奉：当天供奉会在次日提供全属性增益，同时永久提高相关检定难度。
var ritual_offering_days: Dictionary = {}
var ritual_offering_count: int = 0
var _latest_morning_report: Dictionary = {}

var map_return_scene_path: String = DEFAULT_MAP_RETURN_SCENE
var current_scene_path: String = MAP_SCENE
var scene_states: Dictionary = {}
var unlocked_locations: Dictionary = {DEFAULT_MAP_RETURN_SCENE: true}
## F5：玩家到过的地点（key = 地点 id，不是 scene 路径），地图上未探索地点的 NPC 显示为"？？？"
var visited_locations: Dictionary = {}
var quest_stages: Dictionary = {}
var investigation_states: Dictionary = {}
var npc_dialogue_stages: Dictionary = {}
var triggered_events: Dictionary = {}
var one_shot_items: Dictionary = {}
## 22:00 后置为 true；仅在临时宿舍休息到次日九点后解除。
var night_rest_required: bool = false
## 已为当天的 19:00 夜归提示弹过窗，避免同一晚重复打断玩家。
var _night_return_prompt_day: int = -1
var _night_return_dialog: Node

var _autosave_timer: Timer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_autosave_timer()
	if not TimeSystem.minute_changed.is_connected(_on_time_changed):
		TimeSystem.minute_changed.connect(_on_time_changed)
	# 延迟到首个场景就绪后再检查，兼容读取到夜间存档后直接进入地点的情况。
	call_deferred("_enforce_night_rules")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game(AUTO_SAVE_PATH)


## 新游戏开始前把所有玩家进度归零，并发放 INITIAL_INVENTORY 里配置的初始物品。
## TitleScreen._on_new_game 应在跳转到属性分配 UI 之前调用此函数。
func reset_for_new_game() -> void:
	if is_instance_valid(EndingController):
		EndingController.reset_for_new_game()
	pollution = 0
	affinity = {}
	inventory = []
	clues = {}
	document_clues = []
	attributes = {}
	attributes_locked_in = false
	attribute_adjustments = {}
	daily_attribute_bonuses = {}
	water_contact_count = 0
	water_contact_days = {}
	showered_days = {}
	ritual_offering_days = {}
	ritual_offering_count = 0
	_latest_morning_report = {}
	unlocked_locations = {DEFAULT_MAP_RETURN_SCENE: true}
	visited_locations = {}
	quest_stages = {}
	investigation_states = {}
	npc_dialogue_stages = {}
	triggered_events = {}
	one_shot_items = {}
	night_rest_required = false
	_night_return_prompt_day = -1
	scene_states = {}
	map_return_scene_path = DEFAULT_MAP_RETURN_SCENE
	current_scene_path = MAP_SCENE
	# 时钟归零，并按 NPC JSON 的固定 current_location 重新初始化人物位置。
	TimeSystem.reset_to_start()
	NpcRegistry.reset_runtime()
	# 发放初始物品；不 emit item_added 以免弹出"获得道具"toast（这时候还没进入任何场景）
	for item_id in INITIAL_INVENTORY:
		if not item_id.is_empty() and not inventory.has(item_id):
			inventory.append(item_id)
	pollution_changed.emit(pollution)


## ─── 属性系统 ────────────────────────────────────────────────────────
func get_attribute(key: String) -> int:
	var base := int(attributes.get(key, 0))
	var adjustment := int(attribute_adjustments.get(key, 0))
	var daily_bonus := int(daily_attribute_bonuses.get(key, 0))
	return maxi(ATTRIBUTE_MIN, base + adjustment + daily_bonus)


func attributes_allocated() -> bool:
	if not attributes_locked_in:
		return false
	for key in ATTRIBUTE_KEYS:
		if not attributes.has(key):
			return false
		var raw: Variant = attributes.get(key)
		if not (raw is int or raw is float) or int(raw) < ATTRIBUTE_MIN:
			return false
	# 初始分配必须恰好为 10 点，但任务提供的永久成长会让总和超过 10。
	# 因此锁定后只验证四项属性存在，不能再用“总和等于 10”判断 UI 是否显示。
	return true


func set_attributes(values: Dictionary, lock_in: bool = true) -> bool:
	## 严格校验：只接受 4 个已知维度、每维 0-5、总和 ATTRIBUTE_TOTAL_POINTS
	var normalized: Dictionary = {}
	var total := 0
	for key in ATTRIBUTE_KEYS:
		var raw: Variant = values.get(key, 0)
		if not (raw is int or raw is float):
			return false
		var v := clampi(int(raw), ATTRIBUTE_MIN, ATTRIBUTE_MAX)
		if v != int(raw):
			return false
		normalized[key] = v
		total += v
	if total != ATTRIBUTE_TOTAL_POINTS:
		return false
	attributes = normalized
	attributes_locked_in = lock_in
	attribute_adjustments = {}
	daily_attribute_bonuses = {}
	attributes_changed.emit()
	return true


## 水潭重置保留当前基础属性与永久成长的总点数，不清除每日临时状态。
func respec_attributes(values: Dictionary) -> bool:
	var expected_total := 0
	for key in ATTRIBUTE_KEYS:
		expected_total += int(attributes.get(key, ATTRIBUTE_MIN))
	var normalized: Dictionary = {}
	for key in ATTRIBUTE_KEYS:
		var raw: Variant = values.get(key, ATTRIBUTE_MIN)
		if not (raw is int or raw is float):
			return false
		var value := clampi(int(raw), ATTRIBUTE_MIN, expected_total)
		if value != int(raw):
			return false
		normalized[key] = value
	if expected_total <= 0 or normalized.values().reduce(func(total: int, value: Variant) -> int: return total + int(value), 0) != expected_total:
		return false
	attributes = normalized
	attributes_locked_in = true
	attributes_changed.emit()
	save_game(AUTO_SAVE_PATH, false)
	return true


func attributes_summary_text() -> String:
	var parts: PackedStringArray = []
	for key in ATTRIBUTE_KEYS:
		parts.append("%s %d" % [ATTRIBUTE_LABELS.get(key, key), get_attribute(key)])
	return "  ".join(parts)


## 为任务奖励等永久成长提供统一入口；永久成长允许突破初始分配上限。
func grant_permanent_attribute(attribute: String, amount: int = 1) -> int:
	var key := attribute.strip_edges().to_lower()
	if not ATTRIBUTE_KEYS.has(key) or amount <= 0:
		return 0
	var previous := int(attributes.get(key, ATTRIBUTE_MIN))
	var updated := previous + amount
	attributes[key] = updated
	attributes_changed.emit()
	return updated - previous


## 通用水接触入口：任何涉及饮水、涉水、沐浴等内容的交互都可调用。
func record_water_contact(source_id: String = "") -> bool:
	var source := source_id.strip_edges()
	if source.is_empty():
		return false
	water_contact_count += 1
	water_contact_days[str(TimeSystem.current_day)] = true
	return true


func get_water_contact_count() -> int:
	return water_contact_count


func has_contacted_water_on_day(day: int) -> bool:
	return bool(water_contact_days.get(str(maxi(day, 1)), false))


func has_showered_on_day(day: int) -> bool:
	return bool(showered_days.get(str(maxi(day, 1)), false))


## 淋浴每天仅可进行一次；洗澡视为一次与水的接触，并立即恢复到初始魅力。
func shower_today() -> bool:
	var day_key := str(TimeSystem.current_day)
	if bool(showered_days.get(day_key, false)):
		return false
	showered_days[day_key] = true
	record_water_contact("shower")
	attribute_adjustments["charisma"] = 0
	attributes_changed.emit()
	save_game(AUTO_SAVE_PATH, false)
	return true


func offer_ritual_fish() -> bool:
	var day_key := str(TimeSystem.current_day)
	if not has_item("fresh_fish") or bool(ritual_offering_days.get(day_key, false)):
		return false
	remove_item("fresh_fish")
	ritual_offering_days[day_key] = true
	ritual_offering_count += 1
	save_game(AUTO_SAVE_PATH, false)
	return true


func get_ritual_offering_penalty() -> int:
	return ritual_offering_count


func get_latest_morning_report() -> Dictionary:
	return _latest_morning_report.duplicate(true)


func add_pollution(amount: int = 1) -> void:
	if is_game_ended():
		return
	pollution = clampi(pollution + amount, 0, MAX_POLLUTION)
	pollution_changed.emit(pollution)
	if pollution >= MAX_POLLUTION:
		trigger_event("ending_mituu")
		clue_triggered.emit("ending_mituu")


func is_game_ended() -> bool:
	return bool(get_investigation_state("game_ended", false))


func get_ending_id() -> String:
	return String(get_investigation_state("ending_id", ""))


func finish_game(ending_id: String) -> void:
	if ending_id.is_empty() or is_game_ended():
		return
	set_investigation_state("game_ended", true)
	set_investigation_state("ending_id", ending_id)
	trigger_event("ending:%s" % ending_id)
	save_game(AUTO_SAVE_PATH, false)


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
	MemoryStore.add_global_memory("外来者在村里揭开了一件事：%s" % clue_id, ["clue", clue_id])
	clue_triggered.emit(clue_id)


func has_clue(clue_id: String) -> bool:
	return bool(clues.get(clue_id, false))


func add_document_clue(entry: Dictionary) -> bool:
	var clue_id := _safe_string(entry.get("id", ""), "").strip_edges()
	var title := _safe_string(entry.get("title", ""), "").strip_edges()
	var summary := _safe_string(entry.get("summary", ""), "").strip_edges()
	var image_path := _safe_string(entry.get("image_path", ""), "").strip_edges()
	var pages := _safe_text_pages(entry.get("pages", []))
	var linked_clue_ids := _string_array(entry.get("linked_clue_ids", []))
	if clue_id.is_empty() or title.is_empty():
		return false
	var is_image_document := not image_path.is_empty()
	if is_image_document:
		# 只允许读取项目内资料资源，避免由存档数据注入任意资源路径。
		if not image_path.begins_with("res://assets/documents/") or not ResourceLoader.exists(image_path):
			return false
	elif pages.is_empty():
		return false
	for existing in document_clues:
		if String(existing.get("id", "")) == clue_id:
			return false
	var normalized := {
		"id": clue_id,
		"title": title,
		"summary": summary,
		"entry_type": "image" if is_image_document else "text_pages",
		"image_path": image_path,
		"pages": pages,
		"linked_clue_ids": linked_clue_ids,
	}
	document_clues.append(normalized)
	# A clue-book document is itself a clue. Optional linked ids let one physical
	# document satisfy existing story conditions without duplicating UI entries.
	trigger_clue(clue_id)
	for linked_id in linked_clue_ids:
		trigger_clue(linked_id)
	document_clue_added.emit(normalized.duplicate(true))
	return true


func get_document_clues() -> Array[Dictionary]:
	return document_clues.duplicate(true)


## Unified clue-book view ordered by acquisition time. Godot Dictionary keeps
## insertion order, and every document also registers its own id in `clues`, so
## iterating `clues` reconstructs the exact mixed document/story-clue sequence.
func get_clue_book_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var documents_by_id: Dictionary = {}
	for document in document_clues:
		var document_id := String(document.get("id", "")).strip_edges()
		if not document_id.is_empty():
			documents_by_id[document_id] = document
	var seen_ids: Dictionary = {}
	for raw_id in clues.keys():
		var clue_id := String(raw_id).strip_edges()
		if clue_id.is_empty():
			continue
		if documents_by_id.has(clue_id):
			result.append((documents_by_id[clue_id] as Dictionary).duplicate(true))
			seen_ids[clue_id] = true
			continue
		var metadata: Dictionary = ClueDB.get_entry(clue_id)
		result.append({
			"id": clue_id,
			"title": String(metadata.get("title", clue_id)),
			"summary": String(metadata.get("summary", "")),
			"entry_type": "story_clue",
			"image_path": "",
			"pages": [],
			"linked_clue_ids": [clue_id],
		})
		seen_ids[clue_id] = true
	# Legacy saves may contain documents created before document ids were also
	# registered in `clues`. Keep them visible, after all entries with known time.
	for document in document_clues:
		var document_id := String(document.get("id", "")).strip_edges()
		if not document_id.is_empty() and not seen_ids.has(document_id):
			result.append(document.duplicate(true))
			seen_ids[document_id] = true
	return result


func unlock_location(location_id: String) -> void:
	if not location_id.is_empty():
		unlocked_locations[location_id] = true


func is_location_unlocked(location_id: String) -> bool:
	return bool(unlocked_locations.get(location_id, false))


## F5：进入过一次地点即视为"探索过"，地图徽章才会显示那里的 NPC
func mark_visited(loc_id: String) -> void:
	if not loc_id.is_empty():
		visited_locations[loc_id] = true


func has_visited(loc_id: String) -> bool:
	return bool(visited_locations.get(loc_id, false))


## 通用剧情事件入口：剧情脚本可触发自定义事件，NpcRegistry 事件规则层会消费
func emit_event(event_name: String, payload: Dictionary = {}) -> void:
	if event_name.is_empty():
		return
	NpcRegistry.on_event(event_name, payload)


## 触发"event_triggered"类规则的便捷入口
func emit_story_event(event_id: String) -> void:
	if event_id.is_empty():
		return
	trigger_event(event_id)
	emit_event("event_triggered", {"event_id": event_id})


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


func is_night_outing_time() -> bool:
	return TimeSystem.is_night_outing_time()


func can_night_travel() -> bool:
	return has_item("lantern")


func can_enter_location(location_id: String) -> bool:
	if night_rest_required:
		return location_id == TEMP_DORM_LOCATION_ID
	if is_night_outing_time():
		return can_night_travel() and location_id in [TEMP_DORM_LOCATION_ID, "village_chief_house", "taoist_temple"]
	return true


func can_enter_scene(scene_path: String) -> bool:
	if night_rest_required:
		return scene_path == TEMP_DORM_SCENE
	if scene_path == MAP_SCENE:
		return not is_night_outing_time() or can_night_travel()
	if is_night_outing_time():
		if scene_path == TEMP_DORM_SCENE:
			return true
		return can_night_travel() and scene_path in ["res://scenes/locations/VillageChiefHouse.tscn", "res://scenes/locations/TaoistTemple.tscn"]
	return true


## 完成玩家提出问题并收到 NPC 回复的一整轮后调用。
## 夜间规则由 TimeSystem.minute_changed 的全局监听统一处理，避免遗漏地点切换、检定等其他计时路径。
func complete_player_dialogue_round() -> bool:
	TimeSystem.on_dialogue_turn_completed()
	if TimeSystem.is_rest_lock_time():
		return true
	if is_night_outing_time():
		return true
	return false


func confirm_night_return() -> void:
	_dismiss_night_return_dialog()
	_force_return_to_dorm()


func _on_time_changed(_day: int, _minute_of_day: int) -> void:
	# 场景切换本身也会推进时间；延迟一帧可确保弹窗附着在抵达后的当前场景上。
	call_deferred("_enforce_night_rules")


func _enforce_night_rules() -> void:
	if TimeSystem.is_rest_lock_time():
		night_rest_required = true
		_dismiss_night_return_dialog()
		_force_return_to_dorm()
		return
	if not TimeSystem.is_night_outing_time() or _night_return_prompt_day == TimeSystem.current_day:
		return
	_night_return_prompt_day = TimeSystem.current_day
	var message := "夜深了，请先回临时宿舍。无论是否持有灯笼，都需要先回去；持有灯笼后，才可再次前往村长家或道观进行夜间调查。"
	night_return_required.emit(message)
	_show_night_return_dialog(message)


func _show_night_return_dialog(message: String) -> void:
	if is_instance_valid(_night_return_dialog):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	_night_return_dialog = SCENE_ITEM_INTERACTION_SCRIPT.new()
	_night_return_dialog.name = "NightReturnInteraction"
	scene.add_child(_night_return_dialog)
	_night_return_dialog.paged_text_completed.connect(_on_night_return_acknowledged)
	var pages: Array[String] = [message]
	_night_return_dialog.open_paged_text("夜间休整", pages, "night_return", {}, true, "返回宿舍")


func _on_night_return_acknowledged(interaction_id: String) -> void:
	if interaction_id == "night_return":
		confirm_night_return()


func _dismiss_night_return_dialog() -> void:
	if is_instance_valid(_night_return_dialog):
		_night_return_dialog.queue_free()
	_night_return_dialog = null


func _force_return_to_dorm() -> void:
	if current_scene_path == TEMP_DORM_SCENE:
		return
	change_scene(TEMP_DORM_SCENE, false, true)


## 只有位于临时宿舍时才能休息到次日九点并解除夜间锁定。
func rest_at_location(location_id: String) -> bool:
	if night_rest_required and location_id != TEMP_DORM_LOCATION_ID:
		return false
	var completed_day := TimeSystem.current_day
	TimeSystem.rest_until_next_day(9, 0)
	if night_rest_required:
		night_rest_required = false
	_latest_morning_report = _apply_morning_status(completed_day)
	save_game(AUTO_SAVE_PATH, false)
	morning_report_ready.emit(_latest_morning_report.duplicate(true))
	return true


func _apply_morning_status(completed_day: int) -> Dictionary:
	var previous_daily_bonuses: Dictionary = daily_attribute_bonuses.duplicate(true)
	var before_values := _attribute_values_snapshot()
	var charisma_adjustment_before := int(attribute_adjustments.get("charisma", 0))
	daily_attribute_bonuses = {}
	# 每天早九点结算前一日清洁状态：未洗澡降低魅力，洗澡则维持初始魅力。
	var showered := has_showered_on_day(completed_day)
	if showered:
		attribute_adjustments["charisma"] = 0
	else:
		var base_charisma := int(attributes.get("charisma", 0))
		var current_adjustment := int(attribute_adjustments.get("charisma", 0))
		attribute_adjustments["charisma"] = max(-base_charisma, current_adjustment - 1)
	var charisma_adjustment_after := int(attribute_adjustments.get("charisma", 0))
	var cleanliness := {
		"showered": showered,
		"charisma_adjustment_before": charisma_adjustment_before,
		"charisma_adjustment_after": charisma_adjustment_after,
		"charisma_adjustment_delta": charisma_adjustment_after - charisma_adjustment_before,
	}

	var report := {
		"day": TimeSystem.current_day,
		"show": false,
		"title": "清晨",
		"pages": [],
		"ending_id": "",
		"attribute_changes": [],
		"cleanliness": cleanliness,
	}
	var pages: Array[String] = []
	if bool(ritual_offering_days.get(str(completed_day), false)):
		for key in ATTRIBUTE_KEYS:
			_grant_daily_attribute_bonus(key)
		pages.append("昨夜祭台上的供品似乎仍在回应你。它带来的力量只在今天有效。")
	# 兼容已经看过最高侵蚀文本、却因旧逻辑未结算结局的存档：达到最高阶段后，
	# 即使当天没有再次接触水，下一次清晨也会重新显示最终文本并进入结局。
	if has_contacted_water_on_day(completed_day) or water_contact_count >= 6:
		var level := _water_contact_level()
		pages.append(_water_contact_text(level))
		match level:
			1:
				_grant_daily_attribute_bonus("agility")
			2:
				_grant_daily_attribute_bonus("agility")
				_grant_daily_attribute_bonus("strength")
			3, 4:
				for key in ATTRIBUTE_KEYS:
					_grant_daily_attribute_bonus(key)
			5:
				# 由宿舍清晨弹窗在玩家确认这段文字后触发，避免结局遮住阶段文本。
				report["ending_id"] = "pollution_follower"

	var after_values := _attribute_values_snapshot()
	var attribute_changes := _build_morning_attribute_changes(
		before_values,
		after_values,
		previous_daily_bonuses,
		daily_attribute_bonuses
	)
	report["attribute_changes"] = attribute_changes
	var status_page := _format_morning_attribute_status(attribute_changes, cleanliness)
	if not status_page.is_empty():
		pages.append(status_page)
	report["show"] = not pages.is_empty()
	report["pages"] = pages
	attributes_changed.emit()
	return report


func _attribute_values_snapshot() -> Dictionary:
	var values := {}
	for key in ATTRIBUTE_KEYS:
		values[key] = get_attribute(key)
	return values


func _build_morning_attribute_changes(
	before_values: Dictionary,
	after_values: Dictionary,
	previous_bonuses: Dictionary,
	current_bonuses: Dictionary
) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	for key in ATTRIBUTE_KEYS:
		var before := int(before_values.get(key, 0))
		var after := int(after_values.get(key, 0))
		var previous_bonus := int(previous_bonuses.get(key, 0))
		var current_bonus := int(current_bonuses.get(key, 0))
		if before == after and previous_bonus == 0 and current_bonus == 0:
			continue
		var status := "maintained"
		if current_bonus == 0 and previous_bonus > 0:
			status = "expired"
		elif previous_bonus == 0 and current_bonus > 0:
			status = "added"
		elif current_bonus > previous_bonus:
			status = "increased"
		elif current_bonus < previous_bonus:
			status = "reduced"
		elif current_bonus == 0:
			status = "increased" if after > before else "reduced"
		changes.append({
			"key": key,
			"label": String(ATTRIBUTE_LABELS.get(key, key)),
			"before": before,
			"after": after,
			"previous_bonus": previous_bonus,
			"current_bonus": current_bonus,
			"status": status,
		})
	return changes


func _format_morning_attribute_status(changes: Array[Dictionary], cleanliness: Dictionary) -> String:
	if changes.is_empty() and int(cleanliness.get("charisma_adjustment_delta", 0)) == 0:
		return ""
	var lines: PackedStringArray = [
		"[b]清晨状态结算[/b]",
		"每日临时加成会在下一次清晨重新结算，不会永久累计。",
	]
	var cleanliness_delta := int(cleanliness.get("charisma_adjustment_delta", 0))
	if cleanliness_delta < 0:
		lines.append("[color=indian_red]昨日未洗澡：魅力持续调整 %d。洗澡后可恢复。[/color]" % cleanliness_delta)
	elif cleanliness_delta > 0:
		lines.append("[color=sea_green]清洁状态改善：魅力持续调整 +%d。[/color]" % cleanliness_delta)
	for change in changes:
		var label := String(change.get("label", "属性"))
		var before := int(change.get("before", 0))
		var after := int(change.get("after", 0))
		var previous_bonus := int(change.get("previous_bonus", 0))
		var current_bonus := int(change.get("current_bonus", 0))
		match String(change.get("status", "")):
			"added":
				lines.append("新增临时加成：%s +%d（%d → %d）" % [label, current_bonus, before, after])
			"increased":
				if current_bonus > 0:
					lines.append("临时加成提升：%s +%d → +%d（%d → %d）" % [label, previous_bonus, current_bonus, before, after])
				else:
					lines.append("属性变化：%s（%d → %d）" % [label, before, after])
			"maintained":
				lines.append("维持临时加成：%s +%d（%d → %d）" % [label, current_bonus, before, after])
			"reduced":
				if current_bonus > 0:
					lines.append("临时加成降低：%s +%d → +%d（%d → %d）" % [label, previous_bonus, current_bonus, before, after])
				else:
					lines.append("属性变化：%s（%d → %d）" % [label, before, after])
			"expired":
				lines.append("昨日临时加成失效：%s（%d → %d）" % [label, before, after])
	return "\n".join(lines)


func _grant_daily_attribute_bonus(key: String) -> bool:
	if not ATTRIBUTE_KEYS.has(key):
		return false
	daily_attribute_bonuses[key] = int(daily_attribute_bonuses.get(key, 0)) + 1
	return true


func _water_contact_level() -> int:
	if water_contact_count <= 2:
		return 1
	if water_contact_count == 3:
		return 2
	if water_contact_count == 4:
		return 3
	if water_contact_count == 5:
		return 4
	return 5


func _water_contact_text(level: int) -> String:
	match level:
		1:
			return "清晨醒来时，你想起一段并不存在的童年：窗外有水声，某个模糊的声音在反复呼唤你的名字。记忆很快消失，只留下异常轻快的脚步和挥之不去的安宁。"
		2:
			return "你梦见自己站在一片没有倒影的黑水前。水面下传来缓慢而整齐的敲击声，像在模仿你的心跳。醒来后，村庄的道路显得比昨天更熟悉，仿佛有什么东西替你记住了这里。"
		3:
			return "清晨的村庄短暂出现了重影。屋檐、树影和远山都朝同一个方向微微倾斜，耳边的低语开始组成零碎词句。几秒后景象恢复正常，但你无法确定哪一层才是真实。"
		4:
			return "你醒来时确信自己已经在村里生活了很多年。陌生人的面孔变得亲切，地图上的危险地点也显得值得依赖。直到钟声响起，那些不属于你的记忆才像退潮一样散去。"
		_:
			return "耳边的低语终于清晰：利库伊，生命之源。它不断重复这句话，并试图替你解释每一处异常。你知道那不是自己的念头，却越来越难以拒绝。"


func change_scene(scene_path: String, remember_return: bool = false, autosave: bool = true) -> Error:
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return ERR_FILE_NOT_FOUND
	if not can_enter_scene(scene_path):
		return ERR_UNAUTHORIZED
	capture_current_scene()
	if remember_return:
		var scene := get_tree().current_scene
		if scene != null:
			remember_map_return_scene(String(scene.scene_file_path))
	current_scene_path = scene_path
	_notify_scene_arrival(scene_path)
	if autosave:
		save_game(AUTO_SAVE_PATH, false)
	return get_tree().change_scene_to_file(scene_path)


## 玩家到达新场景的钩子：仅标记地点已探索；NPC 固定在各自配置地点。
func _notify_scene_arrival(scene_path: String) -> void:
	var loc_id := NpcRegistry.location_id_for_scene(scene_path)
	if loc_id.is_empty():
		return
	mark_visited(loc_id)


func can_open_world_map() -> bool:
	return has_item(VILLAGE_MAP_ITEM_ID)


func open_world_map() -> Error:
	if not can_open_world_map():
		return ERR_UNAUTHORIZED
	if get_tree().get_first_node_in_group("world_map") != null:
		return OK
	var scene := get_tree().current_scene
	if scene == null:
		return ERR_UNAVAILABLE
	# 地图只是一层导航 UI。保留当前地点场景，避免 Web 端同步释放/重建整棵
	# 场景树时让音频工作缓冲短暂断流；打开地图也不再触发一次无意义的存档写入。
	capture_current_scene()
	remember_map_return_scene(String(scene.scene_file_path))
	var map_instance := WORLD_MAP_PACKED_SCENE.instantiate()
	if map_instance == null:
		return ERR_CANT_CREATE
	map_instance.set_meta(MAP_OVERLAY_META, true)
	var overlay_layer := CanvasLayer.new()
	overlay_layer.name = "WorldMapOverlay"
	overlay_layer.layer = MAP_OVERLAY_LAYER
	overlay_layer.add_child(map_instance)
	AudioManager.set_map_bgm_ducked(true)
	scene.add_child(overlay_layer)
	return OK


func close_world_map() -> Error:
	var map_instance := get_tree().get_first_node_in_group("world_map")
	if map_instance != null and bool(map_instance.get_meta(MAP_OVERLAY_META, false)):
		AudioManager.set_map_bgm_ducked(false)
		var overlay_layer := map_instance.get_parent()
		if overlay_layer is CanvasLayer:
			overlay_layer.queue_free()
		else:
			map_instance.queue_free()
		return OK
	if night_rest_required:
		return change_scene(TEMP_DORM_SCENE)
	var target := map_return_scene_path
	if target.is_empty() or target == MAP_SCENE or not ResourceLoader.exists(target):
		target = DEFAULT_MAP_RETURN_SCENE
	return change_scene(target)


func enter_location(scene_path: String) -> Error:
	var location_id: String = NpcRegistry.location_id_for_scene(scene_path)
	if location_id == "" or not can_enter_location(location_id):
		return ERR_UNAUTHORIZED
	var source_scene_path: String = current_scene_path
	if source_scene_path == MAP_SCENE:
		source_scene_path = map_return_scene_path
	var source_location_id: String = NpcRegistry.location_id_for_scene(source_scene_path)
	var is_location_change: bool = not source_location_id.is_empty() and source_location_id != location_id
	unlock_location(location_id)
	var change_error: Error = change_scene(scene_path, false, false)
	if change_error != OK:
		return change_error
	if is_location_change:
		TimeSystem.on_location_changed()
		if TimeSystem.is_rest_lock_time():
			night_rest_required = true
			call_deferred("_force_return_to_dorm")
	save_game(AUTO_SAVE_PATH, false)
	return OK


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
		"document_clues": document_clues,
		"unlocked_locations": unlocked_locations,
		"visited_locations": visited_locations,
		"quest_stages": quest_stages,
		"investigation_states": investigation_states,
		"npc_dialogue_stages": npc_dialogue_stages,
		"triggered_events": triggered_events,
		"one_shot_items": one_shot_items,
		"night_rest_required": night_rest_required,
		"scene_states": scene_states,
		"memory": MemoryStore.to_dict(),
		"time_system": TimeSystem.to_dict(),
		"npc_registry": NpcRegistry.to_dict(),
		"attributes": attributes.duplicate(true),
		"attributes_locked_in": attributes_locked_in,
		"attribute_adjustments": attribute_adjustments.duplicate(true),
		"daily_attribute_bonuses": daily_attribute_bonuses.duplicate(true),
		"water_contact_count": water_contact_count,
		"water_contact_days": water_contact_days.duplicate(true),
		"showered_days": showered_days.duplicate(true),
		"ritual_offering_days": ritual_offering_days.duplicate(true),
		"ritual_offering_count": ritual_offering_count,
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
	if not (version_value is int or version_value is float) or not READABLE_SAVE_VERSIONS.has(int(version_value)):
		load_failed.emit(path, "不支持的存档版本")
		return ERR_FILE_UNRECOGNIZED
	var save_version := int(version_value)

	var loaded_scene := _safe_scene_path(data.get("current_scene", MAP_SCENE), MAP_SCENE)
	var loaded_return := _safe_scene_path(data.get("map_return_scene", DEFAULT_MAP_RETURN_SCENE), DEFAULT_MAP_RETURN_SCENE)
	player_role = _safe_string(data.get("player_role", "medic"), "medic")
	player_name = _safe_string(data.get("player_name", "圆鸮"), "圆鸮")
	pollution = clampi(_safe_int(data.get("pollution", 0), 0), 0, MAX_POLLUTION)
	affinity = _int_dictionary(data.get("affinity", {}))
	inventory = _string_array(data.get("inventory", []))
	# 清理已废弃物品；拾取物品的旧存档恢复在 one_shot_items 载入后执行。
	inventory.erase("farmland_straw_hat")
	inventory.erase("bronze_fragment")
	clues = _bool_dictionary(data.get("clues", {}))
	document_clues = _sanitize_document_clues(data.get("document_clues", []))
	# 兼容旧存档：删除已废弃的重复工具箱资料，只保留线索 gong_toolbox_lead。
	for i in range(document_clues.size() - 1, -1, -1):
		if String(document_clues[i].get("id", "")) == "gong_toolbox_missing":
			document_clues.remove_at(i)
	# Backward-compatible migration: old saves kept visible documents and story
	# clue ids in separate containers. Make every restored document presentable.
	for document in document_clues:
		var document_id := String(document.get("id", "")).strip_edges()
		if not document_id.is_empty():
			clues[document_id] = true
		for linked_id in document.get("linked_clue_ids", []):
			if linked_id is String and not linked_id.is_empty():
				clues[linked_id] = true
	unlocked_locations = _bool_dictionary(data.get("unlocked_locations", {}))
	visited_locations = _bool_dictionary(data.get("visited_locations", {}))
	quest_stages = _int_dictionary(data.get("quest_stages", {}))
	investigation_states = _dictionary_copy(data.get("investigation_states", {}))
	if bool(data.get("game_ended", false)) and not String(data.get("ending_id", "")).is_empty():
		investigation_states["game_ended"] = true
		investigation_states["ending_id"] = String(data.get("ending_id", ""))
	npc_dialogue_stages = _int_dictionary(data.get("npc_dialogue_stages", {}))
	triggered_events = _bool_dictionary(data.get("triggered_events", {}))
	one_shot_items = _bool_dictionary(data.get("one_shot_items", {}))
	if bool(triggered_events.get("niu_lanshan_bird_task_reward", false)) and not inventory.has("rusty_shovel"):
		inventory.append("rusty_shovel")
	if bool(one_shot_items.get("steel_pipe", false)) and not inventory.has("steel_pipe"):
		inventory.append("steel_pipe")
	var rest_lock_raw: Variant = data.get("night_rest_required", false)
	night_rest_required = bool(rest_lock_raw) if rest_lock_raw is bool else false
	scene_states = _sanitize_scene_states(data.get("scene_states", {}))
	MemoryStore.load_from_dict(data.get("memory", {}))
	_load_attributes(data.get("attributes", {}), data.get("attributes_locked_in", false))
	_load_attribute_runtime_state(
		data.get("attribute_adjustments", {}),
		data.get("daily_attribute_bonuses", {}),
		data.get("water_contact_count", 0),
		data.get("water_contact_days", {}),
		data.get("showered_days", {}),
		data.get("ritual_offering_days", {}),
		data.get("ritual_offering_count", 0)
	)
	# 旧存档没有时间与 NPC 状态时，仍按 JSON 固定地点初始化。
	if save_version == 1:
		TimeSystem.reset_to_start()
		NpcRegistry.reset_runtime()
	else:
		TimeSystem.load_from_dict(data.get("time_system", {}))
		NpcRegistry.load_from_dict(data.get("npc_registry", {}))
	# 兼容旧版本在 19:00 就写入的整夜锁定；19:00–22:00 持灯笼仍可夜间出行。
	if night_rest_required and not TimeSystem.is_rest_lock_time():
		night_rest_required = false
	if night_rest_required and loaded_scene != MAP_SCENE and loaded_scene != TEMP_DORM_SCENE:
		loaded_scene = TEMP_DORM_SCENE
	current_scene_path = loaded_scene
	map_return_scene_path = loaded_return
	if not scene_states.has(current_scene_path) and data.has("player_position"):
		scene_states[current_scene_path] = {
			"player_position": _vector_to_array(_read_vector2(data["player_position"], Vector2.ZERO)),
			"nodes": {},
		}
	unlocked_locations[DEFAULT_MAP_RETURN_SCENE] = true
	# 向后兼容：老存档没发过初始物品时，加载后补发（避免玩家手里没有相机等基本工具）
	for initial_item in INITIAL_INVENTORY:
		if not initial_item.is_empty() and not inventory.has(initial_item):
			inventory.append(initial_item)

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
	if attributes_allocated():
		lines.append("【玩家属性】" + attributes_summary_text())
	lines.append("【污染度】%d/%d" % [pollution, MAX_POLLUTION])
	if not inventory.is_empty():
		lines.append("【已持有道具】%s" % ", ".join(inventory))
	if not clues.is_empty():
		lines.append("【已触发线索】%s" % ", ".join(clues.keys()))
	var global_memory_text := MemoryStore.get_global_memory_text()
	if global_memory_text != "":
		lines.append("【村庄共享记忆】\n" + global_memory_text)
	return "\n".join(lines)


func get_manual_save_path(slot: int) -> String:
	var safe_slot := clampi(slot, 1, MANUAL_SAVE_SLOT_COUNT)
	return "user://save_%02d.json" % safe_slot


func get_manual_save_availability() -> Dictionary:
	if is_game_ended():
		return {"allowed": false, "reason": "结局阶段不能保存。"}
	if not attributes_allocated():
		return {"allowed": false, "reason": "完成初始属性分配后才能保存。"}
	var scene_path := current_scene_path.strip_edges()
	var is_exploration_scene := (
		scene_path == MAP_SCENE
		or scene_path.begins_with("res://scenes/locations/")
		or scene_path.begins_with("res://scenes/main/")
	)
	if not is_exploration_scene:
		return {"allowed": false, "reason": "当前阶段不能保存。"}
	return {"allowed": true, "reason": ""}


func get_save_metadata(path: String) -> Dictionary:
	var result := {
		"path": path,
		"exists": FileAccess.file_exists(path),
		"valid": false,
		"save_kind": "",
		"saved_at_unix": 0,
		"saved_at_text": "",
		"current_scene": "",
		"location_id": "",
		"location_name": "",
		"day": 0,
		"minute_of_day": 0,
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
	if not (version is int or version is float) or not READABLE_SAVE_VERSIONS.has(int(version)):
		return result
	result["valid"] = true
	result["save_kind"] = _safe_string(parsed.get("save_kind", "manual"), "manual")
	result["saved_at_unix"] = _safe_int(parsed.get("saved_at_unix", 0), 0)
	result["saved_at_text"] = _safe_string(parsed.get("saved_at_text", ""), "")
	var scene_path := _safe_string(parsed.get("current_scene", ""), "")
	result["current_scene"] = scene_path
	var metadata_scene := scene_path
	if scene_path == MAP_SCENE:
		metadata_scene = _safe_string(parsed.get("map_return_scene", DEFAULT_MAP_RETURN_SCENE), DEFAULT_MAP_RETURN_SCENE)
	var location_id := NpcRegistry.location_id_for_scene(metadata_scene)
	result["location_id"] = location_id
	result["location_name"] = NpcRegistry.get_location_name(location_id) if not location_id.is_empty() else ("村庄地图" if scene_path == MAP_SCENE else "未知地点")
	var time_data: Variant = parsed.get("time_system", {})
	if time_data is Dictionary:
		result["day"] = maxi(1, _safe_int(time_data.get("current_day", 1), 1))
		result["minute_of_day"] = clampi(_safe_int(time_data.get("minute_of_day", 0), 0), 0, TimeSystem.MINUTES_PER_DAY - 1)
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


func _sanitize_document_clues(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	var seen_ids := {}
	for raw_entry in value:
		if not raw_entry is Dictionary:
			continue
		var clue_id := _safe_string(raw_entry.get("id", ""), "").strip_edges()
		var title := _safe_string(raw_entry.get("title", ""), "").strip_edges()
		var summary := _safe_string(raw_entry.get("summary", ""), "").strip_edges()
		var image_path := _safe_string(raw_entry.get("image_path", ""), "").strip_edges()
		var pages := _safe_text_pages(raw_entry.get("pages", []))
		var linked_clue_ids := _string_array(raw_entry.get("linked_clue_ids", []))
		if clue_id.is_empty() or title.is_empty() or seen_ids.has(clue_id):
			continue
		var is_image_document := not image_path.is_empty()
		if is_image_document:
			if not image_path.begins_with("res://assets/documents/") or not ResourceLoader.exists(image_path):
				continue
		elif pages.is_empty():
			continue
		seen_ids[clue_id] = true
		result.append({
			"id": clue_id,
			"title": title,
			"summary": summary,
			"entry_type": "image" if is_image_document else "text_pages",
			"image_path": image_path,
			"pages": pages,
			"linked_clue_ids": linked_clue_ids,
		})
	return result


func _safe_text_pages(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is not Array:
		return result
	for raw_page in value:
		if raw_page is String:
			var page: String = raw_page.strip_edges()
			if not page.is_empty() and result.size() < 12:
				result.append(page)
	return result


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


func _load_attribute_runtime_state(adjustments_value: Variant, bonuses_value: Variant, water_count_value: Variant, contact_days_value: Variant, shower_days_value: Variant, offering_days_value: Variant = {}, offering_count_value: Variant = 0) -> void:
	attribute_adjustments = _attribute_delta_dictionary(adjustments_value)
	# 供奉与水接触可能在同一天叠加多个临时点数；读取存档时不能再把
	# 实时加成压回 1，也不再以初始属性上限 5 限制最终属性。
	daily_attribute_bonuses = _attribute_delta_dictionary(bonuses_value, 0, 99)
	water_contact_count = clampi(_safe_int(water_count_value, 0), 0, 9999)
	water_contact_days = _bool_dictionary(contact_days_value)
	showered_days = _bool_dictionary(shower_days_value)
	ritual_offering_days = _bool_dictionary(offering_days_value)
	ritual_offering_count = clampi(_safe_int(offering_count_value, 0), 0, 99)
	_latest_morning_report = {}


func _attribute_delta_dictionary(value: Variant, min_value: int = -5, max_value: int = 5) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in ATTRIBUTE_KEYS:
		var raw: Variant = (value as Dictionary).get(key, 0)
		if raw is int or raw is float:
			result[key] = clampi(int(raw), min_value, max_value)
	return result


func _load_attributes(value: Variant, locked_in_value: Variant) -> void:
	var candidate: Dictionary = {}
	if value is Dictionary:
		for key in ATTRIBUTE_KEYS:
			var raw: Variant = (value as Dictionary).get(key, 0)
			var v: int = int(raw) if (raw is int or raw is float) else 0
			# ATTRIBUTE_MAX 只约束初始分配；任务奖励允许基础属性永久超过 5。
			candidate[key] = maxi(v, ATTRIBUTE_MIN)
	var lock_in: bool = false
	if locked_in_value is bool:
		lock_in = locked_in_value
	if candidate.is_empty():
		attributes = {}
		attributes_locked_in = false
		return
	# 初始分配至少有 10 点；高于 10 的部分来自永久成长，必须随存档保留。
	var total := 0
	for key in ATTRIBUTE_KEYS:
		total += int(candidate.get(key, 0))
	if total < ATTRIBUTE_TOTAL_POINTS:
		attributes = {}
		attributes_locked_in = false
		return
	attributes = candidate
	attributes_locked_in = lock_in




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
