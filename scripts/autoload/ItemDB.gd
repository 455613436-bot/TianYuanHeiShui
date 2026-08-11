extends Node
## ItemDB
## 只读物品数据库 autoload。启动时扫描 res://data/items/*.json 全部载入。
##
## 数据字段（每个 item 一份 JSON）：
##   id              String     必填，与 GameState.inventory 里存的字符串对齐
##   display_name    String     必填，玩家/LLM 看到的名字
##   short_desc      String     可选，玩家在背包与检视界面看到的一句话说明
##   tags            Array[String]  可选，用于分类展示
##   usable_in_dialogue  bool   可选，默认 true；决定"打开背包 → 使用"按钮是否可点
##   consumable      bool       可选，默认 false；如果 LLM 判定被消耗且服务端复核通过则移除
##   usage_hints     Array[String]  可选，仅给 LLM 看的自然语言使用提示
##
## 未在 DB 里注册的 inventory id 也不会崩，但显示为 id 本身、hint 为空。

const ITEMS_DIR := "res://data/items/"

var _items: Dictionary = {}   # id -> Dictionary（原始 JSON 内容）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_all()


func _load_all() -> void:
	_items.clear()
	var dir := DirAccess.open(ITEMS_DIR)
	if dir == null:
		push_warning("[ItemDB] 找不到目录 %s，物品库为空" % ITEMS_DIR)
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension().to_lower() == "json":
			_load_one(ITEMS_DIR + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()


func _load_one(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[ItemDB] 无法读取 %s" % path)
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is not Dictionary:
		push_warning("[ItemDB] %s 不是合法 JSON 对象" % path)
		return
	var data: Dictionary = parsed
	var id: String = String(data.get("id", "")).strip_edges()
	if id.is_empty():
		push_warning("[ItemDB] %s 缺少 id 字段" % path)
		return
	_items[id] = data


## 判断物品 id 是否在 DB 中注册。
func exists(id: String) -> bool:
	return _items.has(id)


## 获取物品原始 dict；未注册的返回一个用 id 兜底的最小 dict，避免上层 crash。
func get_item(id: String) -> Dictionary:
	if _items.has(id):
		return (_items[id] as Dictionary).duplicate(true)
	return {
		"id": id,
		"display_name": id,
		"short_desc": "",
		"tags": [],
		"usable_in_dialogue": true,
		"consumable": false,
		"usage_hints": [],
	}


## 玩家/LLM 面向的显示名。找不到时回退为 id。
func get_display_name(id: String) -> String:
	if _items.has(id):
		var name: String = String((_items[id] as Dictionary).get("display_name", "")).strip_edges()
		if not name.is_empty():
			return name
	return id


## 是否允许在对话里"使用"（打开背包点击 / LLM 标记 item_used）。
func is_usable_in_dialogue(id: String) -> bool:
	if not _items.has(id):
		return true   # 未注册物品也允许 use，保持向后兼容
	return bool((_items[id] as Dictionary).get("usable_in_dialogue", true))


## 是否消耗品。
func is_consumable(id: String) -> bool:
	if not _items.has(id):
		return false
	return bool((_items[id] as Dictionary).get("consumable", false))


## 是否支持"检视"（弹出大图 + 详情窗）
func is_inspectable(id: String) -> bool:
	if not _items.has(id):
		return false
	return bool((_items[id] as Dictionary).get("inspectable", false))


## 获取物品缩略图（Texture2D）；不存在或加载失败则返回 null，UI 用占位图。
func get_icon(id: String) -> Texture2D:
	if not _items.has(id):
		return null
	var path: String = String((_items[id] as Dictionary).get("icon_path", "")).strip_edges()
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	return res as Texture2D


## 获取检视大图；缺失时回退到缩略图；再缺失则返回 null。
func get_inspect_image(id: String) -> Texture2D:
	if not _items.has(id):
		return null
	var data: Dictionary = _items[id]
	var path: String = String(data.get("inspect_image_path", "")).strip_edges()
	if path != "" and ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			return res
	# 回退到缩略图
	return get_icon(id)


## 给 LLM 看的自然语言"当前玩家持有清单"块。传空数组返回空串。
func build_inventory_prompt_block(inventory: Array) -> String:
	if inventory.is_empty():
		return "【玩家当前持有】（空）\n注意：玩家目前身上没有任何道具，不要在正文里承认或让玩家「拿出」任何东西。"
	var lines: PackedStringArray = []
	lines.append("【玩家当前持有】")
	for id_variant in inventory:
		var id: String = String(id_variant)
		if id.is_empty():
			continue
		var item: Dictionary = get_item(id)
		var name: String = String(item.get("display_name", id))
		var hints: Variant = item.get("usage_hints", [])
		var hint_parts: PackedStringArray = []
		if hints is Array:
			for hint in hints:
				var hint_text := String(hint).strip_edges()
				if hint_text != "":
					hint_parts.append(hint_text)
		var extra := ""
		if not hint_parts.is_empty():
			extra = "（使用提示：%s）" % "；".join(hint_parts)
		lines.append("- %s（id: %s）%s" % [name, id, extra])
	lines.append("注意：只有这份清单里的东西玩家才拥有；不得在正文里让玩家凭空拿出清单以外的物品。")
	return "\n".join(lines)


## 玩家 → 通过背包 UI 选择：过滤出"当前对话可用"的 id 列表。
func filter_usable(inventory: Array) -> Array:
	var result: Array = []
	for id_variant in inventory:
		var id: String = String(id_variant)
		if id.is_empty():
			continue
		if is_usable_in_dialogue(id):
			result.append(id)
	return result


## LLM item_request 处理：从 candidates 里过滤玩家真正持有的
func filter_owned(candidates: Array, inventory: Array) -> Array:
	var owned_set: Dictionary = {}
	for id_variant in inventory:
		owned_set[String(id_variant)] = true
	var result: Array = []
	for cand in candidates:
		var id: String = String(cand).strip_edges()
		if id != "" and owned_set.has(id) and not result.has(id):
			result.append(id)
	return result


## 依 display_name 反查 id（LLM 若返回中文名而不是 id 时兜底）。
func resolve_id_by_name(name_or_id: String, inventory: Array = []) -> String:
	var candidate := name_or_id.strip_edges()
	if candidate.is_empty():
		return ""
	if _items.has(candidate):
		return candidate
	# 遍历库找 display_name 匹配
	for id in _items.keys():
		var dn: String = String((_items[id] as Dictionary).get("display_name", ""))
		if dn == candidate:
			return String(id)
	# 兜底：inventory 内如果字面就是候选就直接返回
	for inv_id_variant in inventory:
		if String(inv_id_variant) == candidate:
			return candidate
	return ""
