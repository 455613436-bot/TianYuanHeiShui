extends SceneTree

const NpcPersonaScript = preload("res://scripts/llm/NpcPersona.gd")

const NPC_IDS := [
	"gong_zhong",
	"lin_deshan",
	"mu_jiang",
	"mysterious_hermit",
	"niu_lanshan",
	"wu_xuan",
	"wu_zhiyuan",
	"yu_le",
	"li_leshui_day",
	"li_leshui_night",
]


func _init() -> void:
	for npc_id in NPC_IDS:
		var path := "res://data/npcs/%s.md" % npc_id
		var profile: Dictionary = NpcPersonaScript.load_from_file(path)
		if profile.is_empty():
			_fail("Failed to parse %s" % path)
			return
		var prompt := String(profile.get("base_system_prompt", ""))
		if not prompt.contains("## 对村中其他人的看法"):
			_fail("Missing relationship section in prompt: %s" % npc_id)
			return
		if not prompt.contains("## 事实边界与常识推断"):
			_fail("Missing fact-boundary section in prompt: %s" % npc_id)
			return
		if not prompt.contains("## 你所在场景有的东西"):
			_fail("Missing scene-object section in prompt: %s" % npc_id)
			return
		if not prompt.contains("不故弄玄虚") or not prompt.contains("绝不补写村中人物"):
			_fail("Missing concise grounded-response constraints: %s" % npc_id)
			return
		var fewshots: Array = profile.get("fewshots", [])
		if fewshots.size() < 10 or fewshots.size() % 2 != 0:
			_fail("Insufficient or malformed few-shots for %s: %d messages" % [npc_id, fewshots.size()])
			return
		for message in fewshots:
			if String((message as Dictionary).get("role", "")) == "assistant" and String((message as Dictionary).get("content", "")).length() > 180:
				_fail("Overlong few-shot reply in %s" % npc_id)
				return
	print("NPC_PERSONA_PROMPT_SMOKE_OK")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
