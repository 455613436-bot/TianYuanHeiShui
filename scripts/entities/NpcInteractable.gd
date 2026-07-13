extends Node2D
## NpcInteractable
## NPC 实体节点。
## 加载优先级：npc_md_path (.md) > npc_json_path (.json 兼容)
## 加载后维护交互触发区；玩家按 E 时打开 DialogueUI 并注入 profile。

@export var npc_id: String = ""
@export_file("*.md") var npc_md_path: String = ""
@export_file("*.json") var npc_json_path: String = ""

var profile: Dictionary = {}
@onready var prompt_label: Label = $PromptLabel if has_node("PromptLabel") else null


func _ready() -> void:
	_load_profile()
	if prompt_label:
		prompt_label.visible = false
	var area := $InteractArea if has_node("InteractArea") else null
	if area:
		area.body_entered.connect(_on_body_entered)
		area.body_exited.connect(_on_body_exited)


func _load_profile() -> void:
	# 1. 优先 .md
	if npc_md_path != "" and FileAccess.file_exists(npc_md_path):
		profile = NpcPersona.load_from_file(npc_md_path)
		if profile.get("id", "") == "" and npc_id != "":
			profile["id"] = npc_id
		print("[NPC %s] 从 md 加载: %s" % [npc_id, npc_md_path])
		return

	# 2. 回退 .json（旧版兼容）
	if npc_json_path != "" and FileAccess.file_exists(npc_json_path):
		var f := FileAccess.open(npc_json_path, FileAccess.READ)
		var text := f.get_as_text()
		f.close()
		var parsed = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			profile = parsed
			# JSON 版没有 fewshots；system_prompt 直接用旧字段
			if not profile.has("system_prompt"):
				profile["system_prompt"] = String(profile.get("system_prompt", ""))
			if not profile.has("fewshots"):
				profile["fewshots"] = []
			print("[NPC %s] 从 json 加载: %s" % [npc_id, npc_json_path])
			return

	push_warning("[NPC %s] 找不到人设文件（md 或 json）" % npc_id)


func _on_body_entered(body: Node) -> void:
	if body.has_method("set_nearby_npc"):
		body.set_nearby_npc(self)
	if prompt_label:
		prompt_label.visible = true


func _on_body_exited(body: Node) -> void:
	if body.has_method("clear_nearby_npc"):
		body.clear_nearby_npc(self)
	if prompt_label:
		prompt_label.visible = false


## 玩家按 E 调用
func on_player_interact(_player: Node) -> void:
	if profile.is_empty():
		push_warning("[NPC %s] profile 为空，无法对话" % npc_id)
		return
	var ui := get_tree().get_first_node_in_group("dialogue_ui")
	if ui == null:
		push_error("[NPC] 场景中没有 dialogue_ui 组的节点")
		return
	if ui.has_method("is_open") and ui.is_open():
		return
	if ui.has_method("open_dialogue"):
		ui.open_dialogue(profile)
