extends Node
## CheckSystem
## 跑团检定系统 autoload。
##
## 契约：
##   perform_check(attribute, raw_difficulty, item_modifier=0, reason="") -> Dictionary
##
## 规则：
##   - 20 面骰：随机 1..20（uniform）
##   - 掷出 1：大失败（critical_failure），无视难度，必败
##   - 掷出 20：大成功（critical_success），无视难度，必成
##   - 其他：final_difficulty = clamp(raw_difficulty - attribute_value - item_modifier, 1, 30)
##          若 roll >= final_difficulty 则通过；否则失败
##   - degree = roll - final_difficulty（+ 越大成功越"顺利"，- 越大失败越"糟糕"）
##   - severity 分级：crit_success / big_success / success / failure / big_failure / crit_failure

signal check_performed(result: Dictionary)

const DIE_SIDES: int = 20
const MIN_DIFFICULTY: int = 1
const MAX_DIFFICULTY: int = 30
const RAW_DIFFICULTY_MIN: int = 1
const RAW_DIFFICULTY_MAX: int = 30
const ITEM_MODIFIER_MIN: int = -15
const ITEM_MODIFIER_MAX: int = 15
const ATTRIBUTE_ALIASES := {
	# 中文
	"力量": "strength",
	"敏捷": "agility",
	"智力": "intellect",
	"魅力": "charisma",
	# 英文小写
	"strength": "strength",
	"agility": "agility",
	"intellect": "intellect",
	"charisma": "charisma",
	# 常见变体
	"str": "strength",
	"dex": "agility",
	"agi": "agility",
	"int": "intellect",
	"cha": "charisma",
	"chr": "charisma",
}

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func normalize_attribute(attribute_raw: String) -> String:
	var key := attribute_raw.strip_edges().to_lower()
	if ATTRIBUTE_ALIASES.has(key):
		return ATTRIBUTE_ALIASES[key]
	# 也允许直接传入中文（未经 lower 处理）
	if ATTRIBUTE_ALIASES.has(attribute_raw.strip_edges()):
		return ATTRIBUTE_ALIASES[attribute_raw.strip_edges()]
	return ""


func perform_check(attribute_raw: String, raw_difficulty: int, item_modifier: int = 0, reason: String = "") -> Dictionary:
	## 主入口：返回完整结果 dict，UI 直接读用
	var breakdown := get_check_breakdown(attribute_raw, raw_difficulty, item_modifier)
	if not bool(breakdown.get("ok", false)):
		return breakdown
	var attribute := String(breakdown.get("attribute", ""))
	var difficulty := int(breakdown.get("raw_difficulty", RAW_DIFFICULTY_MIN))
	var attr_value := int(breakdown.get("attribute_value", 0))
	var mod := int(breakdown.get("item_modifier", 0))
	var final_difficulty := int(breakdown.get("final_difficulty", MIN_DIFFICULTY))
	var roll := _rng.randi_range(1, DIE_SIDES)

	var passed := false
	var severity := ""
	if roll == 1:
		passed = false
		severity = "crit_failure"
	elif roll == DIE_SIDES:
		passed = true
		severity = "crit_success"
	else:
		passed = roll >= final_difficulty
		var margin := roll - final_difficulty
		if passed:
			severity = "big_success" if margin >= 8 else "success"
		else:
			severity = "big_failure" if margin <= -8 else "failure"

	var result: Dictionary = {
		"ok": true,
		"attribute": attribute,
		"attribute_label": GameState.ATTRIBUTE_LABELS.get(attribute, attribute),
		"raw_difficulty": difficulty,
		"attribute_value": attr_value,
		"item_modifier": mod,
		"final_difficulty": final_difficulty,
		"roll": roll,
		"passed": passed,
		"severity": severity,
		"margin": roll - final_difficulty,
		"reason": reason.strip_edges(),
	}
	check_performed.emit(result)
	return result


func get_check_breakdown(attribute_raw: String, raw_difficulty: int, item_modifier: int = 0) -> Dictionary:
	## 预览与实际掷骰共享的纯计算入口，避免 UI 和裁决各自维护修正上限。
	var attribute := normalize_attribute(attribute_raw)
	if attribute == "":
		return _error_result("未知属性：%s" % attribute_raw)
	var difficulty := clampi(raw_difficulty, RAW_DIFFICULTY_MIN, RAW_DIFFICULTY_MAX)
	var attr_value := GameState.get_attribute(attribute)
	var mod := clampi(item_modifier, ITEM_MODIFIER_MIN, ITEM_MODIFIER_MAX)
	return {
		"ok": true,
		"attribute": attribute,
		"attribute_label": GameState.ATTRIBUTE_LABELS.get(attribute, attribute),
		"raw_difficulty": difficulty,
		"attribute_value": attr_value,
		"item_modifier": mod,
		"final_difficulty": clampi(difficulty - attr_value - mod, MIN_DIFFICULTY, MAX_DIFFICULTY),
	}


func result_to_display_text(result: Dictionary) -> String:
	## 生成给对话记录的人类可读一行
	if not bool(result.get("ok", false)):
		return "[检定异常] " + String(result.get("error", "未知错误"))
	var label := String(result.get("attribute_label", ""))
	var raw := int(result.get("raw_difficulty", 0))
	var attr_val := int(result.get("attribute_value", 0))
	var mod := int(result.get("item_modifier", 0))
	var final_dc := int(result.get("final_difficulty", 0))
	var roll := int(result.get("roll", 0))
	var passed := bool(result.get("passed", false))
	var severity := String(result.get("severity", ""))
	var severity_label := _severity_label(severity)

	var breakdown := "原始 %d - 属性 %d" % [raw, attr_val]
	if mod != 0:
		breakdown += " %s 修正 %d" % [("+" if mod < 0 else "-"), absi(mod)]
		# 说明：难度是"减"修正，item_modifier 正数会让难度更低
	breakdown += " = %d" % final_dc

	var arrow := " ≥ " if passed else " < "
	var trigger := ""
	var reason := String(result.get("reason", "")).strip_edges()
	if reason != "":
		trigger = "\n触发原因：%s" % reason
	return "🎲 %s 检定  掷出 %d %s 难度 %d  ·  %s  （%s）%s" % [label, roll, arrow, final_dc, severity_label, breakdown, trigger]



func result_to_llm_feedback(result: Dictionary, npc_display_name: String = "") -> String:
	## 生成回填给 LLM 的一段"系统旁白"，让 NPC 据此作出反应
	if not bool(result.get("ok", false)):
		return ""
	var label := String(result.get("attribute_label", ""))
	var reason := String(result.get("reason", ""))
	var roll := int(result.get("roll", 0))
	var final_dc := int(result.get("final_difficulty", 0))
	var passed := bool(result.get("passed", false))
	var severity := String(result.get("severity", ""))
	var severity_label := _severity_label(severity)
	var margin := int(result.get("margin", 0))

	var lines: PackedStringArray = []
	lines.append("【系统·检定结果】")
	if reason != "":
		lines.append("触发原因：" + reason)
	lines.append("属性：%s   掷骰：%d/20   最终难度：%d" % [label, roll, final_dc])
	var signed_margin := "%s%d" % [("+" if margin >= 0 else ""), margin]
	lines.append("结果：%s（%s，差值 %s）" % [
		"通过" if passed else "失败",
		severity_label,
		signed_margin,
	])
	var guidance := _reaction_guidance(severity, npc_display_name)
	if guidance != "":
		lines.append("反应指引：" + guidance)
	lines.append("请你（NPC）严格按照上述检定结果，用角色口吻做出对应反应；不要否认检定结果，不要再次触发检定。")
	return "\n".join(lines)


func _reaction_guidance(severity: String, npc_display_name: String) -> String:
	var who := npc_display_name if npc_display_name != "" else "你"
	match severity:
		"crit_success":
			return "%s 应当异常爽快、超出预期地满足玩家请求，甚至主动多透露一条有用信息或递出小物件。" % who
		"big_success":
			return "%s 明显被打动，痛快地满足玩家请求，语气热情、信息给足。" % who
		"success":
			return "%s 有些勉强但仍然答应了玩家请求，只给出适度的信息或有限的许可。" % who
		"failure":
			return "%s 婉拒或含糊搪塞，不满足玩家请求；语气可能带着不悦，但没有翻脸。" % who
		"big_failure":
			return "%s 明显生气或起疑，直接拒绝并且态度变冷；轻微降低好感（affinity_delta = -1 是合理的）。" % who
		"crit_failure":
			return "%s 大为光火，严厉训斥玩家；态度急剧恶化，好感降低（affinity_delta = -2 也合理），并且这个话题短期内会关闭。" % who
	return ""


func _severity_label(severity: String) -> String:
	match severity:
		"crit_success": return "大成功"
		"big_success": return "大胜"
		"success": return "通过"
		"failure": return "失败"
		"big_failure": return "惨败"
		"crit_failure": return "大失败"
	return "结算"


func _error_result(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
