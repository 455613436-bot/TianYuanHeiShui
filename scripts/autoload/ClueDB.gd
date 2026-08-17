extends Node
## Central presentation metadata for every story clue id.
## Gameplay ownership remains in GameState; this database only supplies safe,
## player-facing titles and summaries for the clue book and NPC presentation.

const DATA_PATH := "res://data/clues.json"

var _entries: Dictionary = {}


func _ready() -> void:
	_reload()


func _reload() -> void:
	_entries.clear()
	if not FileAccess.file_exists(DATA_PATH):
		push_warning("[ClueDB] Missing clue catalog: %s" % DATA_PATH)
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		push_warning("[ClueDB] Cannot open clue catalog: %s" % DATA_PATH)
		return
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()
	if error != OK or json.data is not Dictionary:
		push_warning("[ClueDB] Invalid clue catalog JSON")
		return
	var raw_entries: Variant = (json.data as Dictionary).get("clues", {})
	if raw_entries is not Dictionary:
		return
	for raw_id in raw_entries:
		var clue_id := String(raw_id).strip_edges()
		var raw_entry: Variant = raw_entries[raw_id]
		if clue_id.is_empty() or raw_entry is not Dictionary:
			continue
		var title := String((raw_entry as Dictionary).get("title", "")).strip_edges()
		var summary := String((raw_entry as Dictionary).get("summary", "")).strip_edges()
		if title.is_empty():
			continue
		_entries[clue_id] = {
			"id": clue_id,
			"title": title,
			"summary": summary,
		}


func get_entry(clue_id: String) -> Dictionary:
	var key := clue_id.strip_edges()
	if key.is_empty():
		return {}
	if _entries.has(key):
		return (_entries[key] as Dictionary).duplicate(true)
	return {
		"id": key,
		"title": _fallback_title(key),
		"summary": "调查中获得的一条剧情线索。向相关人物出示，也许能得到新的回应。",
	}


func has_entry(clue_id: String) -> bool:
	return _entries.has(clue_id.strip_edges())


func _fallback_title(clue_id: String) -> String:
	return "线索：%s" % clue_id.replace("_", " ")
