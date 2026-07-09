extends Node
## LLMService
## 大模型对话服务（autoload 单例）。策略模式，可插拔 Provider。
##
## 关键设计：**meta 效果（污染/好感/道具/线索）不由 LLM 决定**，
## 而是 LLMService 自己根据 NPC profile 里的 triggers 关键词表匹配玩家输入来算。
## 原因：LLM 输出的结构化字段不可靠，会漏、会瞎给道具。触发器由规则控制，稳定。
##
## Provider 只负责生成 text，返回时 LLMService 会在 emit 之前合并 meta。

signal reply_received(npc_id: String, reply: Dictionary)
signal reply_failed(npc_id: String, error: String)
signal reply_chunk(npc_id: String, accumulated_text: String)

const MockLLMScript := preload("res://scripts/llm/MockLLM.gd")

var _provider: Node = null

## 当前正在进行的会话上下文：npc_id -> {profile, user_text}
## 用于在收到 provider 回复时能查回 triggers 计算 meta
var _inflight: Dictionary = {}


func _ready() -> void:
	# 默认装 Mock；LLMConfig 会在稍后一帧根据环境变量 / 用户配置切换
	var mock = MockLLMScript.new()
	mock.name = "MockLLM"
	add_child(mock)
	_provider = mock
	print("[LLMService] 已装载默认 Provider: MockLLM")


func set_provider(provider: Node) -> void:
	if _provider:
		_provider.queue_free()
	_provider = provider
	add_child(provider)
	# Provider 通过 service.reply_received.emit(...) 回调；不直接连信号
	print("[LLMService] 切换 Provider -> %s" % provider.name)


## 由 DialogueUI 调用
func chat(npc_profile: Dictionary, history: Array, user_text: String) -> void:
	if _provider == null:
		reply_failed.emit(npc_profile.get("id", "?"), "no provider")
		return
	var npc_id: String = String(npc_profile.get("id", "?"))
	# 记录本轮的上下文，用于收到 Provider 回复时合并 meta
	_inflight[npc_id] = {"profile": npc_profile, "user_text": user_text}
	_provider.generate(npc_profile, history, user_text, self)


## 覆盖 Node.emit_signal 无用，我们自己拦截 Provider 的信号发送
## 实际做法：Provider 直接 service.reply_received.emit(...)，我们在这里
## 通过 override 的 emit_signal 拦截，但 GDScript 不能 override 内置 emit_signal
## → 换一种做法：Provider 调用 service.emit_reply(...) / service.emit_failed(...)
##   来替代直接 emit，这样我们能合并 meta。
##
## 但为了兼容之前 Provider 里直接写的 emit，我们保留两种入口：
## - 直接 emit reply_received：走 _post_process 之前的路径。为此我们把
##   reply_received 连到自己的一个 pre-hook，去合并 meta 后再 relay。
##
## 我用一个更简单的方案：在这个类内定义一个 relay 方法给 Provider 调。
## 修改 Provider：把 service.reply_received.emit(...) 改为 service.deliver_reply(...)

func deliver_reply(npc_id: String, reply: Dictionary) -> void:
	var ctx: Dictionary = _inflight.get(npc_id, {})
	_inflight.erase(npc_id)
	var final_meta: Dictionary = _compute_meta(ctx.get("profile", {}), ctx.get("user_text", ""))
	# 合并（Provider 也可能自己带 meta，Mock 就带；真 LLM 不带）
	var provider_meta: Dictionary = reply.get("meta", {})
	for k in provider_meta.keys():
		if not final_meta.has(k) or final_meta[k] == "" or final_meta[k] == 0:
			final_meta[k] = provider_meta[k]
	reply["meta"] = final_meta
	reply_received.emit(npc_id, reply)


func deliver_chunk(npc_id: String, accumulated_text: String) -> void:
	reply_chunk.emit(npc_id, accumulated_text)


func deliver_failure(npc_id: String, error: String) -> void:
	_inflight.erase(npc_id)
	reply_failed.emit(npc_id, error)


## 根据 profile.triggers 对 user_text 做关键词匹配，聚合所有命中项的 meta
func _compute_meta(profile: Dictionary, user_text: String) -> Dictionary:
	var meta := {
		"pollution_delta": 0,
		"affinity_delta": 0,
		"clue_id": "",
		"give_item": "",
	}
	if profile.is_empty() or user_text == "": return meta
	var lower := user_text.to_lower()
	for t in profile.get("triggers", []):
		var kws: Array = t.get("keywords", [])
		var hit := false
		for kw in kws:
			var kw_s := String(kw)
			if user_text.contains(kw_s) or lower.contains(kw_s.to_lower()):
				hit = true; break
		if not hit: continue
		meta["pollution_delta"] += int(t.get("pollution_delta", 0))
		meta["affinity_delta"]  += int(t.get("affinity_delta", 0))
		# clue_id / give_item：多个命中只保留第一个，避免重复给
		if meta["clue_id"] == "":   meta["clue_id"]   = String(t.get("clue_id", ""))
		if meta["give_item"] == "": meta["give_item"] = String(t.get("give_item", ""))
	return meta
