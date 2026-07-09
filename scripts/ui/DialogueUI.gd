extends CanvasLayer
## DialogueUI
## 极乐迪斯科风格底部对话框。
##
## 布局：
##   全屏底部约 320px 高的 Panel，分三栏
##   ┌──────────┬─────────────────────────────────┬──────────┐
##   │ Portrait │  History (Scroll)               │  Actions │
##   │  (NPC)   │  最近 N 行对话                  │  调查    │
##   │ 立绘占位 │                                 │  给物品  │
##   │          ├─────────────────────────────────┤  技能    │
##   │          │  Input (LineEdit) + Send Button │  离开    │
##   └──────────┴─────────────────────────────────┴──────────┘
##
## 状态：closed / waiting_player / waiting_llm
## - 默认 closed（visible=false）
## - open_dialogue(profile) 时显示
## - 玩家按 Enter / Send：进入 waiting_llm，禁用输入，等 LLMService.reply_received

signal closed

const HISTORY_LIMIT := 20

@onready var root_panel: Panel        = $RootPanel
@onready var name_label: Label        = $RootPanel/HBox/Portrait/NameLabel
@onready var portrait_rect: ColorRect = $RootPanel/HBox/Portrait/PortraitRect
@onready var history_label: RichTextLabel = $RootPanel/HBox/Center/History
@onready var input_edit: LineEdit     = $RootPanel/HBox/Center/InputRow/InputEdit
@onready var send_btn: Button         = $RootPanel/HBox/Center/InputRow/SendBtn
@onready var btn_investigate: Button  = $RootPanel/HBox/Actions/Investigate
@onready var btn_give: Button         = $RootPanel/HBox/Actions/GiveItem
@onready var btn_skill: Button        = $RootPanel/HBox/Actions/Skill
@onready var btn_leave: Button        = $RootPanel/HBox/Actions/Leave

var current_npc: Dictionary = {}
var history: Array = []   # [{role, text}]
var state := "closed"


func _ready() -> void:
	add_to_group("dialogue_ui")
	root_panel.visible = false

	send_btn.pressed.connect(_on_send)
	input_edit.text_submitted.connect(func(_t): _on_send())
	btn_investigate.pressed.connect(func(): _on_action("调查"))
	btn_give.pressed.connect(func(): _on_action("给物品"))
	btn_skill.pressed.connect(func(): _on_action("使用技能"))
	btn_leave.pressed.connect(_on_leave)

	# 监听 LLMService
	LLMService.reply_received.connect(_on_llm_reply)
	LLMService.reply_failed.connect(_on_llm_failed)
	LLMService.reply_chunk.connect(_on_llm_chunk)


func open_dialogue(profile: Dictionary) -> void:
	current_npc = profile
	history.clear()
	name_label.text = profile.get("display_name", "???")
	# 立绘占位用 NPC 名字第一个字 + 色块
	var first_char: String = String(profile.get("display_name", "?")).substr(0, 1)
	portrait_rect.color = Color(0.2, 0.18, 0.16)
	_set_portrait_letter(first_char)
	history_label.clear()
	root_panel.visible = true
	_append_history("system", "你走近了「%s」。" % profile.get("display_name", "???"))
	# 开场不发 API：直接用本地预设台词做破冰，让玩家立刻能输入
	var greeting := _pick_greeting(profile)
	if greeting != "":
		_append_history("npc", greeting)
	# 直接进入 waiting_player，玩家可以马上打字
	state = "waiting_player"
	_set_input_enabled(true)
	input_edit.grab_focus()


## 选一句开场招呼：优先 few-shot 里第一条 assistant，其次 fallback_lines
func _pick_greeting(profile: Dictionary) -> String:
	var fs: Array = profile.get("fewshots", [])
	for m in fs:
		if m.get("role", "") == "assistant":
			return String(m.get("content", ""))
	var fbs: Array = profile.get("fallback_lines", [])
	if not fbs.is_empty():
		return String(fbs[0])
	return "……（对方看了你一眼，没说话）"


func close_dialogue() -> void:
	root_panel.visible = false
	state = "closed"
	current_npc = {}
	closed.emit()


func _set_portrait_letter(c: String) -> void:
	# 用 portrait 容器里的 Label 显示首字（场景中预置了 PortraitLetter）
	var lbl: Label = $RootPanel/HBox/Portrait/PortraitRect/PortraitLetter if has_node("RootPanel/HBox/Portrait/PortraitRect/PortraitLetter") else null
	if lbl:
		lbl.text = c


func _on_send() -> void:
	if state != "waiting_player":
		return
	var text := input_edit.text.strip_edges()
	if text == "":
		return
	input_edit.text = ""
	_append_history("user", text)
	_request_llm(text)


const LLM_TIMEOUT_SEC := 30.0

var _timeout_timer: SceneTreeTimer = null


func _request_llm(user_text: String) -> void:
	state = "waiting_llm"
	_set_input_enabled(false)
	_append_history("system", "（%s 正在思考...）" % current_npc.get("short_name", current_npc.get("display_name", "对方")))
	LLMService.chat(current_npc, history.duplicate(), user_text)
	# 兜底超时：无论 Provider 有没有回信号，30 秒后强制恢复输入
	_start_timeout()


func _start_timeout() -> void:
	_timeout_timer = get_tree().create_timer(LLM_TIMEOUT_SEC)
	var t := _timeout_timer
	t.timeout.connect(func():
		# 只在等待 API 响应阶段触发；streaming 阶段（打字机在跑）不超时
		if _timeout_timer == t and state == "waiting_llm":
			_pop_last_system()
			_append_history("system", "[LLM 超时] %d 秒内未收到 API 响应，请检查网络或 API Key。" % int(LLM_TIMEOUT_SEC))
			state = "waiting_player"
			_set_input_enabled(true)
			input_edit.grab_focus()
	)


func _cancel_timeout() -> void:
	_timeout_timer = null


func _on_llm_chunk(npc_id: String, accumulated: String) -> void:
	if npc_id != current_npc.get("id", ""): return
	if state != "waiting_llm" and state != "streaming": return
	# 收到第一个 chunk：取消超时、切到 streaming 状态
	if state == "waiting_llm":
		_cancel_timeout()
		state = "streaming"
		_pop_last_system()   # 移除"正在思考..."
	# 更新或插入 npc 气泡
	if history.size() > 0 and history[-1].get("role", "") == "npc" and history[-1].get("streaming", false):
		history[-1]["text"] = accumulated
		_redraw_history()
	else:
		history.append({"role": "npc", "text": accumulated, "streaming": true})
		_redraw_history()


func _on_llm_reply(npc_id: String, reply: Dictionary) -> void:
	_cancel_timeout()
	# 允许 waiting_llm（非流式直接完成）和 streaming（打字机完成）两种状态
	if state != "waiting_llm" and state != "streaming":
		return
	var text: String = reply.get("text", "……")
	# 把最后一条 streaming 气泡标记为完成，或直接追加
	if history.size() > 0 and history[-1].get("role", "") == "npc" and history[-1].get("streaming", false):
		history[-1]["text"] = text
		history[-1]["streaming"] = false
		_redraw_history()
	else:
		_pop_last_system()
		if npc_id == current_npc.get("id", ""):
			_append_history("npc", text)
		else:
			_append_history("system", "[收到了非当前 NPC 的回复，已忽略]")
	# 应用 meta
	if npc_id == current_npc.get("id", ""):
		var meta: Dictionary = reply.get("meta", {})
		_apply_meta(meta)
	state = "waiting_player"
	_set_input_enabled(true)
	input_edit.grab_focus()


func _on_llm_failed(_npc_id: String, error: String) -> void:
	_cancel_timeout()
	if state != "waiting_llm" and state != "streaming":
		return
	if state == "waiting_llm":
		_pop_last_system()
	_append_history("system", "[LLM 错误] %s" % error)
	state = "waiting_player"
	_set_input_enabled(true)
	input_edit.grab_focus()


func _apply_meta(meta: Dictionary) -> void:
	var p_delta := int(meta.get("pollution_delta", 0))
	if p_delta > 0:
		GameState.add_pollution(p_delta)
		_append_history("system", "[你受到了 %d 点污染。当前 %d/%d]" % [p_delta, GameState.pollution, GameState.MAX_POLLUTION])
	var a_delta := int(meta.get("affinity_delta", 0))
	if a_delta != 0:
		GameState.add_affinity(current_npc.get("id", ""), a_delta)
	var clue: String = meta.get("clue_id", "")
	if clue != "":
		GameState.trigger_clue(clue)
	var item: String = meta.get("give_item", "")
	if item != "":
		GameState.add_item(item)
		_append_history("system", "[你获得了道具：%s]" % item)


func _on_action(label: String) -> void:
	if state != "waiting_player":
		return
	_request_llm("【动作】" + label)


func _on_leave() -> void:
	close_dialogue()


# ─── History helpers ────────────────────────────────────────────────────────

func _append_history(role: String, text: String) -> void:
	history.append({"role": role, "text": text})
	if history.size() > HISTORY_LIMIT:
		history = history.slice(history.size() - HISTORY_LIMIT)
	_redraw_history()


func _pop_last_system() -> void:
	for i in range(history.size() - 1, -1, -1):
		if history[i].get("role", "") == "system":
			history.remove_at(i)
			_redraw_history()
			return


func _redraw_history() -> void:
	history_label.clear()
	for entry in history:
		var role: String = entry.get("role", "")
		var text: String = entry.get("text", "")
		match role:
			"user":
				history_label.push_color(Color(0.85, 0.92, 1.0))
				history_label.add_text("[你] " + text)
				history_label.pop()
			"npc":
				history_label.push_color(Color(1.0, 0.85, 0.6))
				history_label.add_text("[%s] %s" % [current_npc.get("short_name", "对方"), text])
				history_label.pop()
			"system":
				history_label.push_color(Color(0.6, 0.6, 0.6))
				history_label.push_italics()
				history_label.add_text(text)
				history_label.pop()
				history_label.pop()
			_:
				history_label.add_text(text)
		history_label.add_text("\n\n")
	# 滚动到底
	history_label.scroll_to_line(max(0, history_label.get_line_count() - 1))


func _set_input_enabled(enabled: bool) -> void:
	input_edit.editable = enabled
	send_btn.disabled = not enabled
	btn_investigate.disabled = not enabled
	btn_give.disabled = not enabled
	btn_skill.disabled = not enabled
