extends RefCounted
class_name NpcStoryEvent
## 确定性关键剧情事件。
## 事件文本、奖励和状态变化由数据驱动，避免关键情报依赖 LLM 临场生成。


static func find_available_event(profile: Dictionary, when: String) -> Dictionary:
	var events: Variant = profile.get("fixed_story_events", [])
	if events is not Array:
		return {}
	for raw_event in events:
		if raw_event is not Dictionary:
			continue
		var event: Dictionary = raw_event
		if String(event.get("when", "")) != when:
			continue
		if is_available(profile, event):
			return event.duplicate(true)
	return {}


## Find a deterministic response that explicitly accepts one of the presented
## clue ids. Story requirements (quest stage, affinity, other clues, once) are
## still evaluated by is_available(), so presenting evidence cannot bypass
## progression gates.
static func find_presented_clue_event(profile: Dictionary, clue_ids: Array[String]) -> Dictionary:
	if clue_ids.is_empty():
		return {}
	var events: Variant = profile.get("fixed_story_events", [])
	if events is not Array:
		return {}
	for raw_event in events:
		if raw_event is not Dictionary:
			continue
		var event: Dictionary = raw_event
		if String(event.get("when", "")) != "clue_presented":
			continue
		var accepted: Variant = event.get("presented_clues", [])
		if accepted is not Array:
			continue
		var matches := false
		for raw_accepted in accepted:
			if clue_ids.has(String(raw_accepted)):
				matches = true
				break
		if matches and is_available(profile, event):
			return event.duplicate(true)
	return {}


## 固定事件可用 text（单段）或 pages（多段）定义；多段会逐页等待玩家确认。
static func get_pages(event: Dictionary) -> Array[String]:
	var pages: Array[String] = []
	var raw_pages: Variant = event.get("pages", [])
	if raw_pages is Array:
		for raw_page in raw_pages:
			var page := String(raw_page).strip_edges()
			if not page.is_empty():
				pages.append(page)
	if pages.is_empty():
		var text := String(event.get("text", "")).strip_edges()
		if not text.is_empty():
			pages.append(text)
	return pages


static func find_event(profile: Dictionary, event_id: String) -> Dictionary:
	var events: Variant = profile.get("fixed_story_events", [])
	if events is not Array:
		return {}
	for raw_event in events:
		if raw_event is Dictionary and String((raw_event as Dictionary).get("id", "")) == event_id:
			return (raw_event as Dictionary).duplicate(true)
	return {}


static func is_available(profile: Dictionary, event: Dictionary) -> bool:
	var event_id := String(event.get("id", "")).strip_edges()
	if event_id.is_empty():
		return false
	if bool(event.get("once", true)) and GameState.has_triggered_event(event_id):
		return false
	return NpcDisclosure._rule_matches({
		"all_of": event.get("all_of", []),
		"any_of": event.get("any_of", []),
	}, String(profile.get("id", "")))


static func apply_event(event: Dictionary) -> Dictionary:
	var result := {
		"applied": false,
		"items_added": [],
		"clues_added": [],
		"document_added": false,
	}
	var event_id := String(event.get("id", "")).strip_edges()
	if event_id.is_empty():
		return result
	var effects: Variant = event.get("effects", {})
	if effects is Dictionary:
		var data: Dictionary = effects
		var quest: Variant = data.get("set_quest_stage", {})
		if quest is Dictionary:
			var quest_id := String((quest as Dictionary).get("id", ""))
			if not quest_id.is_empty():
				GameState.set_quest_stage(quest_id, int((quest as Dictionary).get("stage", 0)))
		var investigation: Variant = data.get("set_investigation_state", {})
		if investigation is Dictionary:
			var state_id := String((investigation as Dictionary).get("id", ""))
			if not state_id.is_empty():
				GameState.set_investigation_state(state_id, (investigation as Dictionary).get("value", true))
		var current_time_state_id: String = String(data.get("record_current_time_state", "")).strip_edges()
		if not current_time_state_id.is_empty():
			GameState.set_investigation_state(current_time_state_id, {
				"day": TimeSystem.current_day,
				"minute": TimeSystem.minute_of_day,
				"total_minutes": TimeSystem.total_minutes(),
			})
		var affinity_delta := int(data.get("affinity_delta", 0))
		var affinity_npc_id := String(data.get("affinity_npc_id", ""))
		if affinity_delta != 0 and not affinity_npc_id.is_empty():
			GameState.add_affinity(affinity_npc_id, affinity_delta)
		var clues: Variant = data.get("trigger_clues", [])
		if clues is Array:
			for raw_clue in clues:
				var clue_id := String(raw_clue).strip_edges()
				if not clue_id.is_empty() and not GameState.has_clue(clue_id):
					GameState.trigger_clue(clue_id)
					(result["clues_added"] as Array).append(clue_id)
		var items: Variant = data.get("add_items", [])
		if items is Array:
			for raw_item in items:
				var item_id := String(raw_item).strip_edges()
				if not item_id.is_empty() and not GameState.has_item(item_id):
					GameState.add_item(item_id)
					(result["items_added"] as Array).append(item_id)
		var document: Variant = data.get("document_clue", {})
		if document is Dictionary:
			result["document_added"] = GameState.add_document_clue(document)
	GameState.trigger_event(event_id)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	result["applied"] = true
	return result
