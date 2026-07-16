extends CanvasLayer
## Dialogue UI with explicit request/session ownership.

signal closed

enum DialogueState {
	CLOSED,
	OPENING,
	WAITING_PLAYER,
	WAITING_LLM,
	STREAMING,
	ERROR,
}

const HISTORY_LIMIT := 20
const LLM_TIMEOUT_SEC := 30.0
const DIALOGUE_MIN_HEIGHT := 220.0
const DIALOGUE_MAX_HEIGHT := 320.0
const DIALOGUE_HEIGHT_RATIO := 0.34
const DIALOGUE_HEIGHT_RATIO_COMPACT := 0.48
const PORTRAIT_OVERLAY_TOP_OVERHANG := 120.0
const PORTRAIT_OVERLAY_WIDTH := 200.0
const PORTRAIT_OVERLAY_LEFT_MARGIN := 32.0
const COMPACT_WIDTH := 1050.0
const OPENING_REQUEST := "请以角色身份自然地先开口打招呼，并生成适合玩家继续交谈的选项。不要提及这条要求。"
const REGENERATE_REQUEST := "请根据刚才 NPC 的最新回复，只重新生成 2 到 3 个含义不同、可由玩家直接说出口的简短选项。仍按约定的 JSON 格式输出。"

@onready var root_panel: Panel = $RootPanel
@onready var layout_box: HBoxContainer = $RootPanel/HBox
@onready var portrait_box: VBoxContainer = $RootPanel/HBox/Portrait
@onready var center_box: VBoxContainer = $RootPanel/HBox/Center
@onready var actions_box: VBoxContainer = $RootPanel/HBox/Actions
@onready var portrait_overlay: Control = $PortraitOverlay
@onready var name_label: Label = $PortraitOverlay/NameLabel
@onready var portrait_rect: ColorRect = $PortraitOverlay/PortraitRect
@onready var portrait_image: TextureRect = $PortraitOverlay/PortraitRect/PortraitImage
@onready var mood_badge: Label = $PortraitOverlay/PortraitRect/MoodBadge
@onready var history_label: RichTextLabel = $RootPanel/HBox/Center/History
@onready var input_row: HBoxContainer = $RootPanel/HBox/Center/InputRow
@onready var input_edit: LineEdit = $RootPanel/HBox/Center/InputRow/InputEdit
@onready var send_btn: Button = $RootPanel/HBox/Center/InputRow/SendBtn
@onready var retry_btn: Button = $RootPanel/HBox/Center/InputRow/RetryBtn
@onready var choice_row: HFlowContainer = $RootPanel/HBox/Center/ChoiceRow
@onready var regenerate_btn: Button = $RootPanel/HBox/Center/ChoiceRow/RegenerateChoices
@onready var btn_investigate: Button = $RootPanel/HBox/Actions/Investigate
@onready var btn_give: Button = $RootPanel/HBox/Actions/GiveItem
@onready var btn_skill: Button = $RootPanel/HBox/Actions/Skill
@onready var btn_leave: Button = $RootPanel/HBox/Actions/Leave
@onready var choice_buttons: Array[Button] = [
	$RootPanel/HBox/Center/ChoiceRow/Choice1,
	$RootPanel/HBox/Center/ChoiceRow/Choice2,
	$RootPanel/HBox/Center/ChoiceRow/Choice3,
]

var current_npc: Dictionary = {}
var history: Array = []
var state: DialogueState = DialogueState.CLOSED
## 当前立绘的表情 mood（happy / thinking / surprised），用于切换差分
var current_mood: String = MoodPortrait.DEFAULT_MOOD

var _session_id := 0
var _current_request_id := 0
var _current_request_purpose := "dialogue"
var _last_user_text := ""
var _last_request_purpose := "dialogue"
var _last_request_was_opening := false
var _timeout_timer: SceneTreeTimer = null
## 缓存本轮玩家输入 → 收到 NPC 回复后一起写入 MemoryStore
var _pending_user_text_for_memory := ""
## 本轮请求是否属于「检定结果回填」，用于避免二次检定与选项覆盖
var _current_is_check_followup := false


func _ready() -> void:
	add_to_group("dialogue_ui")
	get_viewport().size_changed.connect(_apply_responsive_layout)
	send_btn.pressed.connect(_on_send)
	retry_btn.pressed.connect(_on_retry)
	regenerate_btn.pressed.connect(_on_regenerate_choices)
	input_edit.text_submitted.connect(func(_text): _on_send())
	btn_investigate.pressed.connect(func(): _on_action("调查"))
	btn_give.pressed.connect(func(): _on_action("给物品"))
	btn_skill.pressed.connect(func(): _on_action("使用技能"))
	btn_leave.pressed.connect(_on_leave)
	for button in choice_buttons:
		button.pressed.connect(_on_choice_pressed.bind(button))

	LLMService.reply_received.connect(_on_llm_reply)
	LLMService.reply_failed.connect(_on_llm_failed)
	LLMService.reply_chunk.connect(_on_llm_chunk)
	LLMService.summary_ready.connect(_on_summary_ready)
	LLMService.summary_failed.connect(_on_summary_failed)
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var compact := viewport_size.x < COMPACT_WIDTH
	var ratio := DIALOGUE_HEIGHT_RATIO_COMPACT if compact else DIALOGUE_HEIGHT_RATIO
	var panel_height := clampf(viewport_size.y * ratio, DIALOGUE_MIN_HEIGHT, DIALOGUE_MAX_HEIGHT)
	panel_height = minf(panel_height, viewport_size.y - 16.0)
	root_panel.offset_top = -panel_height
	layout_box.offset_left = 12.0
	layout_box.offset_right = -12.0
	layout_box.offset_top = 10.0
	layout_box.offset_bottom = -10.0
	portrait_box.visible = not compact and viewport_size.y >= 500.0
	actions_box.visible = viewport_size.x >= 820.0
	history_label.custom_minimum_size.y = 72.0 if compact else 108.0

	# PortraitOverlay：立绘作为 RootPanel 的兄弟节点绝对定位，让它从对话框顶部探出。
	# 可见性严格跟随对话框开关 —— 布局函数只负责摆位置，绝不主动打开它。
	if is_instance_valid(portrait_overlay):
		var should_show := is_open() and portrait_box.visible
		portrait_overlay.visible = should_show
		if should_show:
			var overhang := PORTRAIT_OVERLAY_TOP_OVERHANG
			# 立绘上沿 = 对话框顶部再往上 overhang，下沿 = 对话框底部内侧 16px
			portrait_overlay.offset_left = PORTRAIT_OVERLAY_LEFT_MARGIN
			portrait_overlay.offset_right = PORTRAIT_OVERLAY_LEFT_MARGIN + PORTRAIT_OVERLAY_WIDTH
			portrait_overlay.offset_top = -(panel_height + overhang)
			portrait_overlay.offset_bottom = -24.0

	var reserved_width := 48.0
	if portrait_box.visible:
		reserved_width += portrait_box.custom_minimum_size.x
	if actions_box.visible:
		reserved_width += actions_box.custom_minimum_size.x
	var center_width := maxf(240.0, viewport_size.x - reserved_width)
	for button in choice_buttons:
		button.custom_minimum_size = Vector2(center_width if compact else 0.0, 40.0)
	regenerate_btn.custom_minimum_size = Vector2(center_width if compact else 112.0, 40.0)

func _exit_tree() -> void:
	_cancel_current_request()


func is_open() -> bool:
	return state != DialogueState.CLOSED


func is_ui_open() -> bool:
	return is_open()


func close_top_ui() -> void:
	close_dialogue()

func open_dialogue(profile: Dictionary) -> void:
	if is_open():
		return
	_session_id += 1
	current_npc = profile
	_pending_user_text_for_memory = ""
	history.clear()
	name_label.text = profile.get("display_name", "???")
	portrait_rect.color = Color(0.2, 0.18, 0.16)
	_set_portrait_letter(String(profile.get("display_name", "?")).substr(0, 1))
	_apply_mood(MoodPortrait.DEFAULT_MOOD)
	history_label.clear()

	# 恢复该 NPC 的持久化历史（user/npc 交替），此处是"跨会话记忆"
	var npc_id: String = String(profile.get("id", ""))
	var persisted: Array = MemoryStore.get_history(npc_id)
	if not persisted.is_empty():
		for entry in persisted:
			history.append(entry.duplicate(true))
		_append_history("system", "（你回想起之前与「%s」的对话……）" % profile.get("display_name", "???"))
		_redraw_history()
		# 已有历史时，直接进入等待玩家状态，不再让 NPC 主动重开场白。
		_change_state(DialogueState.WAITING_PLAYER)
		# 若最后一轮 NPC 回复带有 choices，把它复原为按钮
		var last_choices: Variant = []
		for i in range(history.size() - 1, -1, -1):
			var probe: Dictionary = history[i]
			if String(probe.get("role", "")) == "npc":
				last_choices = probe.get("choices", [])
				break
		_show_choices(last_choices)
		input_edit.grab_focus()
		return

	_append_history("system", "你走近了「%s」。" % profile.get("display_name", "???"))
	_request_llm(OPENING_REQUEST, "dialogue", true)


func close_dialogue() -> void:
	if state == DialogueState.CLOSED:
		return
	_cancel_current_request()
	_session_id += 1
	current_npc = {}
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")
	closed.emit()


func _change_state(next_state: DialogueState) -> void:
	state = next_state
	var open := state != DialogueState.CLOSED
	root_panel.visible = open
	if is_instance_valid(portrait_overlay):
		portrait_overlay.visible = open and (portrait_box == null or portrait_box.visible)
	var can_interact := state in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]
	input_row.visible = open
	input_edit.visible = open
	send_btn.visible = open
	input_edit.editable = can_interact
	send_btn.disabled = not can_interact
	retry_btn.visible = state == DialogueState.ERROR
	retry_btn.disabled = state != DialogueState.ERROR
	btn_investigate.disabled = not can_interact
	btn_give.disabled = not can_interact
	btn_skill.disabled = not can_interact
	btn_leave.disabled = not open
	regenerate_btn.disabled = state != DialogueState.WAITING_PLAYER
	for button in choice_buttons:
		button.disabled = state != DialogueState.WAITING_PLAYER


func _set_portrait_letter(value: String) -> void:
	var path := "PortraitOverlay/PortraitRect/PortraitLetter"
	var label: Label = get_node(path) if has_node(path) else null
	if label:
		label.text = value


## 切换立绘表情差分。传入的 mood 会先经 MoodPortrait.normalize_mood 规范化，非法值回退到 DEFAULT_MOOD。
func _apply_mood(mood_raw: String) -> void:
	var mood := MoodPortrait.normalize_mood(mood_raw)
	if mood == "":
		mood = MoodPortrait.DEFAULT_MOOD
	current_mood = mood

	var npc_id: String = String(current_npc.get("id", ""))
	var portrait_size := Vector2i(200, 240)
	if is_instance_valid(portrait_rect) and portrait_rect.size.x > 8 and portrait_rect.size.y > 8:
		portrait_size = Vector2i(int(portrait_rect.size.x), int(portrait_rect.size.y))
	var texture: Texture2D = MoodPortrait.load_or_generate(npc_id, mood, portrait_size)

	if is_instance_valid(portrait_image):
		portrait_image.texture = texture
		portrait_image.visible = texture != null
	# 贴图存在时字母兜底就藏起来，避免"?"字盖脸
	var letter_label := get_node_or_null("PortraitOverlay/PortraitRect/PortraitLetter") as Label
	if letter_label:
		letter_label.visible = texture == null
	if is_instance_valid(mood_badge):
		mood_badge.text = _mood_badge_text(mood)


func _mood_badge_text(mood: String) -> String:
	match mood:
		MoodPortrait.MOOD_HAPPY: return "开心"
		MoodPortrait.MOOD_THINKING: return "思考"
		MoodPortrait.MOOD_SURPRISED: return "惊讶"
	return ""


func _on_send() -> void:
	_submit_player_text(input_edit.text)


func _on_choice_pressed(button: Button) -> void:
	_submit_player_text(String(button.get_meta("choice_text", button.text)))


func _submit_player_text(raw_text: String) -> void:
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var text := raw_text.strip_edges()
	if text == "":
		return
	input_edit.text = ""
	_append_history("user", text)
	_request_llm(text)


func _on_action(label: String) -> void:
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var text := "【动作】" + label
	_append_history("user", text)
	_request_llm(text)


func _on_leave() -> void:
	close_dialogue()


func _on_retry() -> void:
	if state != DialogueState.ERROR or _last_user_text == "":
		return
	_request_llm(_last_user_text, _last_request_purpose, _last_request_was_opening)


func _on_regenerate_choices() -> void:
	if state != DialogueState.WAITING_PLAYER:
		return
	_request_llm(REGENERATE_REQUEST, "choices_only")


func _request_llm(user_text: String, purpose: String = "dialogue", opening: bool = false) -> void:
	_cancel_current_request()
	_last_user_text = user_text
	_last_request_purpose = purpose
	_last_request_was_opening = opening
	_current_request_purpose = purpose
	_hide_choices()
	_append_history("system", "（%s 正在思考……）" % current_npc.get("short_name", current_npc.get("display_name", "对方")))
	_change_state(DialogueState.OPENING if opening else DialogueState.WAITING_LLM)

	var request_history: Array = history.duplicate(true)
	if not request_history.is_empty() and request_history[-1].get("role", "") == "system":
		request_history.pop_back()
	if purpose == "dialogue" and not request_history.is_empty():
		var last_entry: Dictionary = request_history[-1]
		if last_entry.get("role", "") == "user" and last_entry.get("text", "") == user_text:
			request_history.pop_back()

	# 只把最近 MAX_TURNS 轮送给 LLM，避免超上下文；更早内容靠 NPC 记忆文档承载
	request_history = _tail_turns(request_history, MemoryStore.NPC_TURNS_TO_SEND_LLM)

	var request_profile := current_npc.duplicate(true)
	request_profile["unlocked_clues"] = GameState.clues.keys()
	# 把「全局记忆 + NPC 独立记忆文档」拼到 system_prompt 末尾
	var npc_id_for_mem: String = String(current_npc.get("id", ""))
	var memory_block: String = MemoryStore.build_memory_prompt_block(npc_id_for_mem)
	if memory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + memory_block

	# 记住本轮玩家输入，等 NPC 回复回来时一并写入长期历史（非 opening / 非 choices_only 才算一轮）
	if purpose == "dialogue" and not opening:
		_pending_user_text_for_memory = user_text
	else:
		_pending_user_text_for_memory = ""

	_current_is_check_followup = (purpose == "check_followup")

	_current_request_id = LLMService.chat(request_profile, request_history, user_text, _session_id, purpose)
	_start_timeout(_current_request_id, _session_id)


func _tail_turns(entries: Array, max_turns: int) -> Array:
	## 从尾部往前，只保留最近 max_turns 个 user 行及其后续内容
	var kept_pairs := 0
	for i in range(entries.size() - 1, -1, -1):
		var role := String((entries[i] as Dictionary).get("role", ""))
		if role == "user":
			kept_pairs += 1
			if kept_pairs > max_turns:
				return entries.slice(i + 1)
	return entries


func _start_timeout(request_id: int, session_id: int) -> void:
	_timeout_timer = get_tree().create_timer(LLM_TIMEOUT_SEC)
	var timer := _timeout_timer
	timer.timeout.connect(func():
		if timer != _timeout_timer or request_id != _current_request_id or session_id != _session_id:
			return
		if state not in [DialogueState.OPENING, DialogueState.WAITING_LLM, DialogueState.STREAMING]:
			return
		LLMService.cancel_request(request_id)
		_current_request_id = 0
		_timeout_timer = null
		_remove_thinking_message()
		_append_history("system", "[LLM 超时] %d 秒内未收到完整响应，可重试或直接输入新内容。" % int(LLM_TIMEOUT_SEC))
		_change_state(DialogueState.ERROR)
		input_edit.grab_focus()
	)


func _cancel_timeout() -> void:
	_timeout_timer = null


func _cancel_current_request() -> void:
	if _current_request_id != 0:
		LLMService.cancel_request(_current_request_id)
		_current_request_id = 0
	_cancel_timeout()


func _matches_current(request_id: int, session_id: int, npc_id: String) -> bool:
	return (
		request_id == _current_request_id
		and session_id == _session_id
		and npc_id == String(current_npc.get("id", ""))
		and state != DialogueState.CLOSED
	)


func _on_llm_chunk(request_id: int, session_id: int, npc_id: String, accumulated: String) -> void:
	if not _matches_current(request_id, session_id, npc_id):
		return
	if _current_request_purpose == "choices_only":
		return
	if state not in [DialogueState.OPENING, DialogueState.WAITING_LLM, DialogueState.STREAMING]:
		return
	if state != DialogueState.STREAMING:
		_change_state(DialogueState.STREAMING)
		_remove_thinking_message()
	if not history.is_empty() and history[-1].get("role", "") == "npc" and history[-1].get("streaming", false):
		history[-1]["text"] = accumulated
		_redraw_history()
	else:
		history.append({"role": "npc", "text": accumulated, "streaming": true})
		_redraw_history()


func _on_llm_reply(request_id: int, session_id: int, npc_id: String, reply: Dictionary) -> void:
	if not _matches_current(request_id, session_id, npc_id):
		return
	_cancel_timeout()
	_current_request_id = 0
	var reply_choices: Variant = reply.get("choices", [])

	if _current_request_purpose == "choices_only":
		_remove_thinking_message()
		_change_state(DialogueState.WAITING_PLAYER)
		_show_choices(reply_choices)
		input_edit.grab_focus()
		return

	var text := String(reply.get("text", "……")).strip_edges()
	if text == "":
		text = "……"
	if not history.is_empty() and history[-1].get("role", "") == "npc" and history[-1].get("streaming", false):
		history[-1]["text"] = text
		history[-1]["streaming"] = false
		history[-1]["choices"] = reply_choices
		_redraw_history()
	else:
		_remove_thinking_message()
		history.append({"role": "npc", "text": text, "choices": reply_choices})
		_redraw_history()

	# 根据 LLM 输出的 mood（若有）+ 正文关键词兜底切换立绘表情
	var resolved_mood := MoodPortrait.resolve_mood(String(reply.get("mood", "")), text)
	_apply_mood(resolved_mood)

	_apply_meta(reply.get("meta", {}))
	GameState.advance_npc_dialogue_stage(npc_id)
	current_npc["dialogue_stage"] = GameState.get_npc_dialogue_stage(npc_id)

	# 将本轮 user+npc 写入 MemoryStore 长期历史，并按 5 轮阈值触发总结
	_persist_turn_to_memory(npc_id, text, reply_choices)

	# 检定分支：仅在非检定回填的普通对话轮次里检查 check_request；避免死循环。
	var check_request: Dictionary = reply.get("check_request", {}) if reply.get("check_request", null) is Dictionary else {}
	if not _current_is_check_followup and not check_request.is_empty():
		_run_check_flow(check_request)
		return

	_change_state(DialogueState.WAITING_PLAYER)
	_show_choices(reply_choices)
	input_edit.grab_focus()


func _on_llm_failed(request_id: int, session_id: int, npc_id: String, error: String) -> void:
	if not _matches_current(request_id, session_id, npc_id):
		return
	_cancel_timeout()
	_current_request_id = 0
	_remove_thinking_message()
	_append_history("system", "[LLM 错误] %s（可重试或直接输入新内容）" % error)
	_change_state(DialogueState.ERROR)
	_hide_choices()
	input_edit.grab_focus()


func _apply_meta(meta: Dictionary) -> void:
	var pollution_delta := int(meta.get("pollution_delta", 0))
	if pollution_delta > 0:
		GameState.add_pollution(pollution_delta)
		_append_history("system", "[你受到了 %d 点污染。当前 %d/%d]" % [pollution_delta, GameState.pollution, GameState.MAX_POLLUTION])
	var affinity_delta := int(meta.get("affinity_delta", 0))
	if affinity_delta != 0:
		GameState.add_affinity(current_npc.get("id", ""), affinity_delta)
	var clue := String(meta.get("clue_id", ""))
	if clue != "":
		GameState.trigger_clue(clue)
	var item := String(meta.get("give_item", ""))
	if item != "":
		GameState.add_item(item)
		_append_history("system", "[你获得了道具：%s]" % item)


func _append_history(role: String, text: String) -> void:
	history.append({"role": role, "text": text})
	if history.size() > HISTORY_LIMIT:
		history = history.slice(history.size() - HISTORY_LIMIT)
	_redraw_history()


func _remove_thinking_message() -> void:
	for index in range(history.size() - 1, -1, -1):
		if history[index].get("role", "") == "system" and String(history[index].get("text", "")).contains("正在思考"):
			history.remove_at(index)
			_redraw_history()
			return


func _redraw_history() -> void:
	history_label.clear()
	for entry in history:
		var role := String(entry.get("role", ""))
		var text := String(entry.get("text", ""))
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
			"check":
				_redraw_check_entry(entry)
			_:
				history_label.add_text(text)
		history_label.add_text("\n\n")
	history_label.scroll_to_line(max(0, history_label.get_line_count() - 1))


func _show_choices(raw_choices: Variant) -> void:
	var choices: Array[String] = []
	if raw_choices is Array:
		for item in raw_choices:
			var choice := String(item).strip_edges()
			if choice == "" or choices.has(choice):
				continue
			choices.append(choice.left(80))
			if choices.size() >= 3:
				break

	choice_row.visible = state == DialogueState.WAITING_PLAYER
	regenerate_btn.visible = state == DialogueState.WAITING_PLAYER
	regenerate_btn.disabled = state != DialogueState.WAITING_PLAYER
	for index in range(choice_buttons.size()):
		var button := choice_buttons[index]
		button.visible = index < choices.size()
		if not button.visible:
			continue
		var full_text := choices[index]
		button.text = full_text.left(18) + ("…" if full_text.length() > 18 else "")
		button.tooltip_text = full_text
		button.set_meta("choice_text", full_text)
		button.disabled = false


func _hide_choices() -> void:
	choice_row.visible = false
	for button in choice_buttons:
		button.visible = false
		button.disabled = true


# ─── 记忆持久化 & 总结 ────────────────────────────────────────────────

func _persist_turn_to_memory(npc_id: String, npc_text: String, choices: Variant) -> void:
	if npc_id == "":
		return
	var choice_list: Array = []
	if choices is Array:
		for c in (choices as Array):
			var s := String(c).strip_edges()
			if s != "":
				choice_list.append(s)

	if _pending_user_text_for_memory.strip_edges() == "":
		# 没有玩家输入的场景：
		# - opening / choices_only：不记
		# - check_followup：把 NPC 的最终反应作为一条独立 NPC 记录写入（属于对之前请求的回应）
		if _current_is_check_followup and npc_text.strip_edges() != "":
			MemoryStore.append_turn(npc_id, "", npc_text, choice_list)
			_maybe_trigger_summary(npc_id)
		_pending_user_text_for_memory = ""
		return

	MemoryStore.append_turn(npc_id, _pending_user_text_for_memory, npc_text, choice_list)
	_pending_user_text_for_memory = ""
	_maybe_trigger_summary(npc_id)


func _maybe_trigger_summary(npc_id: String) -> void:
	if not MemoryStore.should_summarize(npc_id):
		return
	var recent := MemoryStore.get_recent_turns_for_summary(npc_id, MemoryStore.SUMMARIZE_EVERY_TURNS)
	if recent.is_empty():
		return
	MemoryStore.mark_summarize_started(npc_id)
	var previous := MemoryStore.get_summary(npc_id)
	# profile 使用当前 npc 的原始 profile（不含记忆注入），避免记忆嵌套
	var profile := current_npc.duplicate(true)
	profile["id"] = npc_id
	LLMService.summarize(profile, previous, recent)


func _on_summary_ready(npc_id: String, summary: String) -> void:
	if npc_id == "":
		return
	MemoryStore.set_summary(npc_id, summary)
	MemoryStore.mark_summarize_finished(npc_id, true)


func _on_summary_failed(npc_id: String, error: String) -> void:
	push_warning("[DialogueUI] NPC %s 记忆总结失败: %s" % [npc_id, error])
	MemoryStore.mark_summarize_finished(npc_id, false)


# ─── 检定流程 ────────────────────────────────────────────────────────

func _run_check_flow(check_request: Dictionary) -> void:
	## 由 LLM 发起 check_request → 执行掷骰 → 展示 → 再调 LLM 让 NPC 反应
	var attribute_raw: String = String(check_request.get("attribute", ""))
	var difficulty: int = int(check_request.get("difficulty", 0))
	var reason: String = String(check_request.get("reason", ""))
	if CheckSystem.normalize_attribute(attribute_raw) == "" or difficulty <= 0:
		# 非法请求 → 静默降级为普通回复：直接进入等待玩家状态
		_change_state(DialogueState.WAITING_PLAYER)
		input_edit.grab_focus()
		return

	var result: Dictionary = CheckSystem.perform_check(attribute_raw, difficulty, 0, reason)
	if not bool(result.get("ok", false)):
		_append_history("system", "[检定异常] " + String(result.get("error", "")))
		_change_state(DialogueState.WAITING_PLAYER)
		input_edit.grab_focus()
		return

	# 记录到对话记录（醒目样式）
	var display_line: String = CheckSystem.result_to_display_text(result)
	history.append({"role": "check", "text": display_line, "check_result": result})
	_redraw_history()

	# 掷骰结果一出，NPC 立即切到"思考"状态；下一轮 check_followup 会根据结果重新解析 mood
	_apply_mood(MoodPortrait.MOOD_THINKING)

	# 关键叙事事件写入全局记忆；骰子过程本身不再单独写 NPC 历史
	# （NPC 后续 check_followup 的反应会被 _persist_turn_to_memory 正常记录）
	var npc_id: String = String(current_npc.get("id", ""))
	var npc_name: String = String(current_npc.get("display_name", current_npc.get("short_name", "村民")))
	match String(result.get("severity", "")):
		"crit_success":
			MemoryStore.add_global_memory("玩家在与 %s 交涉时投出了大成功，取得了对方额外的信任。" % npc_name, ["check", "crit_success"])
		"crit_failure":
			MemoryStore.add_global_memory("玩家在与 %s 交涉时投出了大失败，招致对方严厉的训斥。" % npc_name, ["check", "crit_failure"])

	# 再次调用 LLM，让 NPC 根据结果反应；purpose=check_followup 避免二次检定
	var feedback: String = CheckSystem.result_to_llm_feedback(result, npc_name)
	_request_llm(feedback, "check_followup", false)


func _redraw_check_entry(entry: Dictionary) -> void:
	## 让 check 类历史条目在 RichTextLabel 里有醒目样式
	var text := String(entry.get("text", ""))
	var passed := false
	if entry.has("check_result"):
		passed = bool((entry["check_result"] as Dictionary).get("passed", false))
	history_label.push_bold()
	history_label.push_color(Color(0.55, 1.0, 0.65) if passed else Color(1.0, 0.55, 0.55))
	history_label.add_text(text)
	history_label.pop()
	history_label.pop()
