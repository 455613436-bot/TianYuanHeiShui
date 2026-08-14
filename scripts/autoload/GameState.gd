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

const MAX_POLLUTION := 6
const SAVE_VERSION := 4
## 可读取的历史存档版本；v4 新增饮水接触与每日属性结算状态。
const READABLE_SAVE_VERSIONS := [1, 2, 3, 4]
const VILLAGE_MAP_ITEM_ID := "village_map"
const MANUAL_SAVE_SLOT_COUNT := 5
const SAVE_PATH := "user://save_01.json"
const AUTO_SAVE_PATH := "user://save_auto.json"
const AUTO_SAVE_INTERVAL_SECONDS := 300.0
const MAP_SCENE := "res://scenes/map/WorldMap.tscn"
const DEFAULT_MAP_RETURN_SCENE := "res://scenes/locations/VillageChiefHouse.tscn"
const TEMP_DORM_LOCATION_ID := "temporary_dorm"
const TEMP_DORM_SCENE := "res://scenes/locations/TemporaryDorm.tscn"

## 开发调试期间默认发放村庄手绘地图，便于直接切换和测试各地点场景。
## 正式流程恢复时移除 "village_map"，由村长剧情发放。
const INITIAL_INVENTORY: Array[String] = ["camera", "village_map"]

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
## 场景资料线索册，元素为 {id, title, summary, image_path}，按发现顺序保存。
var document_clues: Array[Dictionary] = []
## 玩家四维属性，0-5；首次启动前为空 -> attributes_allocated()==false 时应该跳转到属性分配 UI
var attributes: Dictionary = {}
var attributes_locked_in: bool = false
## 持久性属性调整用于未清洁惩罚；每天增益单独结算，不污染初始属性分配。
var attribute_adjustments: Dictionary = {}
var daily_attribute_bonuses: Dictionary = {}
## 水接触由场景交互调用 record_water_contact() 统一记录；按天保存以供次日九点结算。
var water_contact_count: int = 0
var water_contact_days: Dictionary = {}
var showered_days: Dictionary = {}
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
## 19:00 后完成一整轮对话时置为 true；仅在临时宿舍休息到次日九点后解除。
var night_rest_required: bool = false

var _autosave_timer: Timer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_autosave_timer()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game(AUTO_SAVE_PATH)


## 新游戏开始前把所有玩家进度归零，并发放 INITIAL_INVENTORY 里配置的初始物品。
## TitleScreen._on_new_game 应在跳转到属性分配 UI 之前调用此函数。
func reset_for_new_game() -> void:
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
	_latest_morning_report = {}
	unlocked_locations = {DEFAULT_MAP_RETURN_SCENE: true}
	visited_locations = {}
	quest_stages = {}
	investigation_states = {}
	npc_dialogue_stages = {}
	triggered_events = {}
	one_shot_items = {}
	night_rest_required = false
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
	return clampi(base + adjustment + daily_bonus, ATTRIBUTE_MIN, ATTRIBUTE_MAX)


func attributes_allocated() -> bool:
	if not attributes_locked_in:
		return false
	var total := 0
	for key in ATTRIBUTE_KEYS:
		total += get_attribute(key)
	return total == ATTRIBUTE_TOTAL_POINTS


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


func attributes_summary_text() -> String:
	var parts: PackedStringArray = []
	for key in ATTRIBUTE_KEYS:
		parts.append("%s %d" % [ATTRIBUTE_LABELS.get(key, key), get_attribute(key)])
	return "  ".join(parts)


## 为任务奖励等永久成长提供统一入口；奖励不会突破基础属性上限。
func grant_permanent_attribute(attribute: String, amount: int = 1) -> int:
	var key := attribute.strip_edges().to_lower()
	if not ATTRIBUTE_KEYS.has(key) or amount <= 0:
		return 0
	var previous := int(attributes.get(key, ATTRIBUTE_MIN))
	var updated := clampi(previous + amount, ATTRIBUTE_MIN, ATTRIBUTE_MAX)
	if updated == previous:
		return 0
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


func get_latest_morning_report() -> Dictionary:
	return _latest_morning_report.duplicate(true)


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
	}
	document_clues.append(normalized)
	document_clue_added.emit(normalized.duplicate(true))
	return true


func get_document_clues() -> Array[Dictionary]:
	return document_clues.duplicate(true)


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


func can_enter_location(location_id: String) -> bool:
	return not night_rest_required or location_id == TEMP_DORM_LOCATION_ID


func can_enter_scene(scene_path: String) -> bool:
	return not night_rest_required or scene_path == MAP_SCENE or scene_path == TEMP_DORM_SCENE


## 完成玩家提出问题并收到 NPC 回复的一整轮后调用；达到 19:00 时锁定至回宿舍休息。
func complete_player_dialogue_round() -> bool:
	TimeSystem.on_dialogue_turn_completed()
	if not night_rest_required and TimeSystem.is_rest_lock_time():
		night_rest_required = true
		save_game(AUTO_SAVE_PATH, false)
	return night_rest_required


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
	daily_attribute_bonuses = {}
	# 每天早九点结算前一日清洁状态：未洗澡降低魅力，洗澡则维持初始魅力。
	if has_showered_on_day(completed_day):
		attribute_adjustments["charisma"] = 0
	else:
		var base_charisma := int(attributes.get("charisma", 0))
		var current_adjustment := int(attribute_adjustments.get("charisma", 0))
		attribute_adjustments["charisma"] = max(-base_charisma, current_adjustment - 1)

	var report := {
		"day": TimeSystem.current_day,
		"show": false,
		"title": "清晨",
		"pages": [],
	}
	if not has_contacted_water_on_day(completed_day):
		attributes_changed.emit()
		return report

	var level := _water_contact_level()
	var text := _water_contact_text(level)
	var gained: PackedStringArray = []
	match level:
		1:
			if _grant_daily_attribute_bonus("agility"):
				gained.append("敏捷 +1")
		2:
			if _grant_daily_attribute_bonus("agility"):
				gained.append("敏捷 +1")
			if _grant_daily_attribute_bonus("strength"):
				gained.append("力量 +1")
		3, 4:
			for key in ATTRIBUTE_KEYS:
				if _grant_daily_attribute_bonus(key):
					gained.append("%s +1" % ATTRIBUTE_LABELS.get(key, key))
		5:
			pass
	if not gained.is_empty():
		text += "\n\n[color=sea_green]今日增益：%s[/color]" % "、".join(gained)
	report["show"] = true
	report["pages"] = [text]
	attributes_changed.emit()
	return report


func _grant_daily_attribute_bonus(key: String) -> bool:
	if not ATTRIBUTE_KEYS.has(key) or get_attribute(key) >= ATTRIBUTE_MAX:
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
			return "你脑海中浮现出一段模糊的儿时记忆，随之而来的是一种难以言喻的幸福感，它恰到好处地将你温柔地包裹。你手脚变得轻快，各种担忧和疲惫也一扫而空。"
		2:
			return "有一个瞬间，你似乎回到了温暖、黑暗、湿润的子宫，急切地想与那流动的血肉贴合。下一刻你回到了熟悉的村庄，正用力呼吸着附近潮湿的空气。你擦掉额头上的汗珠，感受着一阵令人兴奋的眩晕。"
		3:
			return "低头抬头间，你感到焕然一新，仿佛身体重新被注入了更有力量的血液，它们汩汩地涌向每一块肌肉。身上的衣服穿着很紧，你想挣开衣服，用皮肤感受这块你无比着迷的土地。你的耳边响起难以分辨的低语。"
		4:
			return "你的根在地下紧握，你的叶与白云相触。你感知着身边一切事物的力量，他们也都欣欣向荣，像你一样。你不禁迈着大步前进，脚下的频率使你难以保持平衡。你的五官变得肿胀，你的衣服也崩开了。你只想与这离不开的地方融为一体。"
		_:
			return "耳边的声音如此清晰、亲切：利库伊！生命之源！利库伊利库伊利库伊利库伊……海又升起，让水淹没。"


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
	return change_scene(MAP_SCENE, true)


func close_world_map() -> Error:
	if night_rest_required:
		return change_scene(TEMP_DORM_SCENE)
	var target := map_return_scene_path
	if target.is_empty() or target == MAP_SCENE or not ResourceLoader.exists(target):
		target = DEFAULT_MAP_RETURN_SCENE
	return change_scene(target)


func enter_location(scene_path: String) -> Error:
	var location_id := NpcRegistry.location_id_for_scene(scene_path)
	if location_id == "" or not can_enter_location(location_id):
		return ERR_UNAUTHORIZED
	unlock_location(location_id)
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
	clues = _bool_dictionary(data.get("clues", {}))
	document_clues = _sanitize_document_clues(data.get("document_clues", []))
	unlocked_locations = _bool_dictionary(data.get("unlocked_locations", {}))
	visited_locations = _bool_dictionary(data.get("visited_locations", {}))
	quest_stages = _int_dictionary(data.get("quest_stages", {}))
	investigation_states = _dictionary_copy(data.get("investigation_states", {}))
	npc_dialogue_stages = _int_dictionary(data.get("npc_dialogue_stages", {}))
	triggered_events = _bool_dictionary(data.get("triggered_events", {}))
	one_shot_items = _bool_dictionary(data.get("one_shot_items", {}))
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
		data.get("showered_days", {})
	)
	# 旧存档没有时间与 NPC 状态时，仍按 JSON 固定地点初始化。
	if save_version == 1:
		TimeSystem.reset_to_start()
		NpcRegistry.reset_runtime()
	else:
		TimeSystem.load_from_dict(data.get("time_system", {}))
		NpcRegistry.load_from_dict(data.get("npc_registry", {}))
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
	if not (version is int or version is float) or not READABLE_SAVE_VERSIONS.has(int(version)):
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


func _load_attribute_runtime_state(adjustments_value: Variant, bonuses_value: Variant, water_count_value: Variant, contact_days_value: Variant, shower_days_value: Variant) -> void:
	attribute_adjustments = _attribute_delta_dictionary(adjustments_value)
	daily_attribute_bonuses = _attribute_delta_dictionary(bonuses_value, 0, 1)
	water_contact_count = clampi(_safe_int(water_count_value, 0), 0, 9999)
	water_contact_days = _bool_dictionary(contact_days_value)
	showered_days = _bool_dictionary(shower_days_value)
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
			candidate[key] = clampi(v, ATTRIBUTE_MIN, ATTRIBUTE_MAX)
	var lock_in: bool = false
	if locked_in_value is bool:
		lock_in = locked_in_value
	if candidate.is_empty():
		attributes = {}
		attributes_locked_in = false
		return
	# 严格校验总和；不合法则视为未分配，强制回退到分配 UI
	var total := 0
	for key in ATTRIBUTE_KEYS:
		total += int(candidate.get(key, 0))
	if total != ATTRIBUTE_TOTAL_POINTS:
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
