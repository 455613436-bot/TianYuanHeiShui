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
const DIALOGUE_MIN_HEIGHT := 300.0
const DIALOGUE_MAX_HEIGHT := 520.0
const COMPACT_WIDTH := 1050.0
const OPENING_REQUEST := "请以角色身份自然地先开口打招呼，并生成适合玩家继续交谈的选项。不要提及这条要求。"
const REGENERATE_REQUEST := "请根据刚才 NPC 的最新回复，只重新生成 2 到 3 个含义不同、可由玩家直接说出口的简短选项。仍按约定的 JSON 格式输出。"

@onready var root_panel: Panel = $RootPanel
@onready var layout_box: HBoxContainer = $RootPanel/HBox
@onready var portrait_box: VBoxContainer = $RootPanel/HBox/Portrait
@onready var center_box: VBoxContainer = $RootPanel/HBox/Center
@onready var actions_box: VBoxContainer = $RootPanel/HBox/Actions
@onready var name_label: Label = $RootPanel/HBox/Portrait/NameLabel
@onready var portrait_rect: ColorRect = $RootPanel/HBox/Portrait/PortraitRect
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

var _session_id := 0
var _current_request_id := 0
var _current_request_purpose := "dialogue"
var _last_user_text := ""
var _last_request_purpose := "dialogue"
var _last_request_was_opening := false
var _timeout_timer: SceneTreeTimer = null


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
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var compact := viewport_size.x < COMPACT_WIDTH
	var panel_height := clampf(viewport_size.y * (0.68 if compact else 0.52), DIALOGUE_MIN_HEIGHT, DIALOGUE_MAX_HEIGHT)
	panel_height = minf(panel_height, viewport_size.y - 16.0)
	root_panel.offset_top = -panel_height
	layout_box.offset_left = 12.0
	layout_box.offset_right = -12.0
	layout_box.offset_top = 10.0
	layout_box.offset_bottom = -10.0
	portrait_box.visible = not compact and viewport_size.y >= 650.0
	actions_box.visible = viewport_size.x >= 820.0
	history_label.custom_minimum_size.y = 92.0 if compact else 150.0
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
	history.clear()
	name_label.text = profile.get("display_name", "???")
	portrait_rect.color = Color(0.2, 0.18, 0.16)
	_set_portrait_letter(String(profile.get("display_name", "?")).substr(0, 1))
	history_label.clear()
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
	var path := "RootPanel/HBox/Portrait/PortraitRect/PortraitLetter"
	var label: Label = get_node(path) if has_node(path) else null
	if label:
		label.text = value


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

	var request_profile := current_npc.duplicate(true)
	request_profile["unlocked_clues"] = GameState.clues.keys()
	_current_request_id = LLMService.chat(request_profile, request_history, user_text, _session_id, purpose)
	_start_timeout(_current_request_id, _session_id)


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

	_apply_meta(reply.get("meta", {}))
	GameState.advance_npc_dialogue_stage(npc_id)
	current_npc["dialogue_stage"] = GameState.get_npc_dialogue_stage(npc_id)
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
