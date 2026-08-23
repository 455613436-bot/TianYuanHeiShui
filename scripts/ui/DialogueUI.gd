extends CanvasLayer
## Dialogue UI with explicit request/session ownership.

const MoodPortraitUtil := preload("res://scripts/ui/MoodPortrait.gd")
const ClueBookPopupScript := preload("res://scripts/ui/ClueBookPopup.gd")
const SceneItemInteractionScript := preload("res://scripts/ui/SceneItemInteraction.gd")
const NpcStoryEventScript := preload("res://scripts/llm/NpcStoryEvent.gd")

signal closed
## 公聊模式下由当前 DialogueUI 输入框提交给 GroupChatUI 的玩家文本。
signal group_message_submitted(text: String)
## 公聊模式下玩家点击离开，供 GroupChatUI 结束仍在进行的会话。
signal group_close_requested
signal fixed_story_event_completed(event_id: String)

enum DialogueState {
	CLOSED,
	OPENING,
	WAITING_PLAYER,
	WAITING_LLM,
	STREAMING,
	ERROR,
	REST_LOCKED,
}

const HISTORY_LIMIT := 20
const LLM_TIMEOUT_SEC := 90.0
const FIXED_STORY_TYPEWRITER_INTERVAL := 0.08
const COMPACT_WIDTH := 1050.0
const OPENING_REQUEST := "请以角色身份自然地先开口打招呼，并生成适合玩家继续交谈的选项。不要提及这条要求。"
const REGENERATE_REQUEST := "请根据刚才 NPC 的最新回复，只重新生成 2 到 3 个含义不同、可由玩家直接说出口的简短选项。仍按约定的 JSON 格式输出。"

@onready var root_panel: Panel = $RootPanel
@onready var dialogue_bg: TextureRect = $DialogueBg
@onready var layout_box: HBoxContainer = $RootPanel/HBox
@onready var portrait_box: VBoxContainer = $RootPanel/HBox/Portrait
@onready var center_box: VBoxContainer = $RootPanel/HBox/Center
@onready var actions_box: VBoxContainer = $Actions
@onready var portrait_overlay: Control = $PortraitOverlay
@onready var name_label: Label = $PortraitOverlay/PortraitRect/NameLabel
@onready var portrait_rect: ColorRect = $PortraitOverlay/PortraitRect
@onready var portrait_image: TextureRect = $PortraitOverlay/PortraitRect/PortraitImage
@onready var mood_badge: Label = $PortraitOverlay/PortraitRect/MoodBadge
@onready var history_label: RichTextLabel = $RootPanel/HBox/Center/History
@onready var token_row: HFlowContainer = $RootPanel/HBox/Center/TokenRow
@onready var input_row: HBoxContainer = $RootPanel/HBox/Center/InputRow
@onready var input_edit: LineEdit = $RootPanel/HBox/Center/InputRow/InputEdit
@onready var send_btn: BaseButton = $RootPanel/HBox/Center/InputRow/SendBtn
@onready var retry_btn: BaseButton = $RootPanel/HBox/Center/InputRow/RetryBtn
@onready var choice_row: HFlowContainer = $RootPanel/HBox/Center/ChoiceRow
@onready var regenerate_btn: Button = $RootPanel/HBox/Center/ChoiceRow/RegenerateChoices
@onready var btn_investigate: BaseButton = $Actions/Investigate
@onready var btn_bag: BaseButton = $Actions/OpenBag
@onready var btn_skill: BaseButton = $Actions/Skill
@onready var btn_leave: BaseButton = $Leave
@onready var choice_buttons: Array[Button] = [
	$RootPanel/HBox/Center/ChoiceRow/Choice1,
	$RootPanel/HBox/Center/ChoiceRow/Choice2,
]

var current_npc: Dictionary = {}
var history: Array = []
var state: DialogueState = DialogueState.CLOSED
## 当前立绘的表情 mood（happy / thinking / surprised），用于切换差分
var current_mood: String = MoodPortraitUtil.DEFAULT_MOOD

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
## 公聊复用同一 DialogUI 历史、输入框和立绘区域，不走私聊请求链。
var _group_mode := false
var _group_finished := false

## ─── 物品/道具相关 ────────────────────────────────────────────────
## 本次组合尚未提交时，玩家已经在输入区插入的道具 id 列表（有序）
var _pending_item_tokens: Array[String] = []
## 每个 token 对应的按钮节点，key = item_id, value = Button（在 token_row 下）
var _pending_token_buttons: Dictionary = {}
## 记录本轮 LLM 是否要求玩家出示物品（item_request），非空时 choice_row 变身为物品按钮
## 结构：{ "candidates": Array[String], "reason": String, "no_item_text": String }
var _pending_item_request: Dictionary = {}
## 缓存 ItemBagPopup 实例
var _bag_popup: CanvasLayer = null
## 线索册与其中“查看资料”时复用的通用资料预览器。
var _clue_book_popup: ClueBookPopup = null
var _clue_document_viewer: SceneItemInteraction = null

## Token 药丸配色（金色，与普通输入区分）
const TOKEN_BG_COLOR := Color(1.0, 0.85, 0.4, 1.0)
const TOKEN_FG_COLOR := Color(0.15, 0.10, 0.02, 1.0)
const TOKEN_PREFIX := "【使用道具】"
const ITEM_SHOW_PREFIX := "【出示道具】"
const CLUE_SHOW_PREFIX := "【出示线索】"

## ─── 通用「NPC 提议 / 请求」（offer_request）─────────────────────
## 挂起中的 offer；非空时 choice_row 会被占用为 [接受][拒绝] 两个按钮。
## 结构由 SuggestionGuard._parse_offer_request 生成；额外键 "source" 用于区分来源：
##   "llm"           - LLM 直接输出 offer_request
##   "meta_give"     - 由旧 give_item 关键词触发合成，接受时会 add_item(item_id)
var _pending_offer: Dictionary = {}
## 正在展示的固定剧情事件；多段事件仅允许玩家点击“继续”推进，避免被自由输入打断。
var _active_fixed_event: Dictionary = {}
var _fixed_event_pages: Array[String] = []
var _fixed_event_page_index := 0
var _fixed_event_outcome: Dictionary = {}
var _fixed_typewriter_generation := 0
var _fixed_typewriter_running := false
var _fixed_typewriter_history_index := -1
var _fixed_choice_typewriter_generation := 0
var _fixed_choice_typewriter_running := false
var _fixed_choice_typewriter_history_index := -1
var _fixed_choice_typewriter_full_text := ""
var _fixed_choice_typewriter_choice_text := ""


func _ready() -> void:
	add_to_group("dialogue_ui")
	btn_investigate.tooltip_text = "打开线索册（J）"
	history_label.tooltip_text = "NPC 出字时点击可立即显示完整回复"
	get_viewport().size_changed.connect(_apply_responsive_layout)
	send_btn.pressed.connect(_on_send)
	retry_btn.pressed.connect(_on_retry)
	regenerate_btn.pressed.connect(_on_regenerate_choices)
	input_edit.text_submitted.connect(func(_text): _on_send())
	history_label.gui_input.connect(_on_dialogue_fast_forward_input)
	btn_investigate.pressed.connect(_on_open_clue_book_pressed)
	btn_bag.pressed.connect(_on_open_bag_pressed)
	btn_skill.pressed.connect(_on_open_skill_menu)
	btn_leave.pressed.connect(_on_leave)
	for button in choice_buttons:
		button.pressed.connect(_on_choice_pressed.bind(button))
	# 离开按钮独立定位在常驻操作区上方，显示/隐藏不再改变其余三个按钮的位置。

	LLMService.reply_received.connect(_on_llm_reply)
	LLMService.reply_started.connect(_on_llm_reply_started)
	LLMService.reply_failed.connect(_on_llm_failed)
	LLMService.reply_chunk.connect(_on_llm_chunk)
	LLMService.summary_ready.connect(_on_summary_ready)
	LLMService.summary_failed.connect(_on_summary_failed)
	# 进入场景时立即隐藏对话框（默认是关闭的），让玩家看到场景
	root_panel.visible = false
	if is_instance_valid(dialogue_bg):
		dialogue_bg.visible = false
	if is_instance_valid(portrait_overlay):
		portrait_overlay.visible = false
	actions_box.visible = true
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var viewport_size := viewport.get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# 所有位置/大小均在 Godot 编辑器中通过 tscn 定义，代码不再强制覆盖。
	# 右侧操作区在普通模式下常驻；公聊仍只保留离开按钮。
	portrait_box.visible = false
	actions_box.visible = viewport_size.x >= 820.0 and (not _group_mode or is_open())
	if is_instance_valid(portrait_overlay):
		portrait_overlay.visible = is_open()

func _exit_tree() -> void:
	_cancel_current_request()


func is_open() -> bool:
	return state != DialogueState.CLOSED


func is_ui_open() -> bool:
	return is_open()


func close_top_ui() -> void:
	close_dialogue()


func request_fast_forward() -> bool:
	if _fixed_typewriter_running:
		return _fast_forward_fixed_story_page()
	if _fixed_choice_typewriter_running:
		return _fast_forward_fixed_choice_reply()
	if _group_mode:
		for node in get_tree().get_nodes_in_group("group_chat_ui"):
			if node.has_method("fast_forward_current_reply") and bool(node.fast_forward_current_reply()):
				return true
		return false
	if _current_request_id != 0:
		return LLMService.fast_forward_request(_current_request_id)
	return false


func _on_dialogue_fast_forward_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and event.pressed
		and request_fast_forward()
	):
		history_label.accept_event()


func prepare_for_map_navigation() -> void:
	if is_instance_valid(_bag_popup) and _bag_popup.has_method("close_ui"):
		_bag_popup.close_ui()
	if is_instance_valid(_clue_book_popup) and _clue_book_popup.has_method("close_ui"):
		_clue_book_popup.close_ui()
	close_dialogue()

func open_dialogue(profile: Dictionary) -> void:
	var night_taoist := String(profile.get("id", "")) == "li_leshui_night"
	if is_open() or (GameState.night_rest_required and not night_taoist):
		return
	var npc_id: String = String(profile.get("id", ""))
	if NpcRegistry.is_npc_hostile(npc_id):
		_show_hostile_refusal(profile)
		return
	_session_id += 1
	current_npc = profile
	_pending_user_text_for_memory = ""
	_active_fixed_event = {}
	_fixed_event_pages = []
	_fixed_event_page_index = 0
	_fixed_event_outcome = {}
	history.clear()
	name_label.text = profile.get("display_name", "???")
	portrait_rect.color = Color(0.2, 0.18, 0.16)
	_set_portrait_letter(String(profile.get("display_name", "?")).substr(0, 1))
	_apply_mood(MoodPortraitUtil.DEFAULT_MOOD)
	history_label.clear()

	# 每次打开对话都先检查阶段性固定剧情；即使已有历史，任务完成后也必须能正常结算下一阶段。
	var opening_event: Dictionary = {}
	var forced_event_id := String(profile.get("_forced_opening_event_id", "")).strip_edges()
	if not forced_event_id.is_empty():
		var forced_event := NpcStoryEventScript.find_event(profile, forced_event_id)
		if not forced_event.is_empty() and NpcStoryEventScript.is_available(profile, forced_event):
			opening_event = forced_event
	if opening_event.is_empty():
		opening_event = NpcStoryEventScript.find_available_event(profile, "dialogue_open")
	var persisted: Array = MemoryStore.get_history(npc_id)
	if not persisted.is_empty():
		for entry in persisted:
			history.append(entry.duplicate(true))
		_append_history("system", "（你回想起之前与「%s」的对话……）" % profile.get("display_name", "???"))
		if not opening_event.is_empty():
			_play_fixed_story_event(opening_event, npc_id)
			return
		_redraw_history()
		_change_state(DialogueState.WAITING_PLAYER)
		# 若最后一轮 NPC 回复带有 choices，把它复原为按钮。
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
	if not opening_event.is_empty():
		_play_fixed_story_event(opening_event, npc_id)
		return
	_request_llm(OPENING_REQUEST, "dialogue", true)


func _show_hostile_refusal(profile: Dictionary) -> void:
	var interaction := SceneItemInteractionScript.new()
	interaction.name = "HostileNpcRefusal"
	get_tree().current_scene.add_child(interaction)
	var hostile_npc_id := String(profile.get("id", ""))
	var refusal_text := "%s对你的攻击十分愤怒，不愿再和你交谈。" % String(profile.get("display_name", "对方"))
	if SkillSystem.can_retry_hostile_attack(hostile_npc_id):
		interaction.choice_selected.connect(func(_interaction_id: String, choice_id: String, _result: Dictionary) -> void:
			if choice_id != "attack_again":
				return
			var scene := get_tree().current_scene
			if scene != null and scene.has_method("_open_attack_weapon_mode"):
				scene.call("_open_attack_weapon_mode", hostile_npc_id, interaction)
		, CONNECT_ONE_SHOT)
		interaction.open_choice({
			"id": "hostile_refusal::%s" % hostile_npc_id,
			"title": "拒绝交谈",
			"description": refusal_text,
			"choices": [
				{"id": "attack_again", "label": "再次攻击"},
				{"id": "leave", "label": "离开", "close": true},
			],
		})
		return
	interaction.open_paged_text("拒绝交谈", [refusal_text])


## 供场景任务脚本调用：关键剧情必须用确定性文本，而非要求 LLM 临场复述。
func play_fixed_story_event(event_id: String) -> bool:
	if not is_open() or _group_mode:
		return false
	var event := NpcStoryEventScript.find_event(current_npc, event_id)
	if event.is_empty() or not NpcStoryEventScript.is_available(current_npc, event):
		return false
	_play_fixed_story_event(event, String(current_npc.get("id", "")))
	return true


func _play_fixed_story_event(event: Dictionary, npc_id: String, user_text: String = "") -> void:
	var pages := NpcStoryEventScript.get_pages(event)
	if pages.is_empty():
		return
	_active_fixed_event = event.duplicate(true)
	_active_fixed_event["_npc_id"] = npc_id
	_active_fixed_event["_user_text"] = user_text
	_fixed_event_pages = pages
	_fixed_event_page_index = 0
	_fixed_event_outcome = {}
	_show_fixed_story_event_page()


func _show_fixed_story_event_page() -> void:
	if _active_fixed_event.is_empty() or _fixed_event_page_index >= _fixed_event_pages.size():
		return
	_fixed_typewriter_generation += 1
	_fixed_typewriter_running = true
	var page_text := _fixed_event_pages[_fixed_event_page_index]
	_apply_mood(MoodPortraitUtil.resolve_mood(String(_active_fixed_event.get("mood", "")), page_text, String(current_npc.get("id", ""))))
	_append_history("npc", "")
	_fixed_typewriter_history_index = history.size() - 1
	_hide_choices()
	_change_state(DialogueState.STREAMING)
	_type_fixed_story_event_page(
		_fixed_event_pages[_fixed_event_page_index],
		_fixed_typewriter_generation,
		_fixed_typewriter_history_index
	)


func _type_fixed_story_event_page(full_text: String, generation: int, history_index: int) -> void:
	var visible_characters := 0
	while visible_characters < full_text.length():
		await get_tree().create_timer(FIXED_STORY_TYPEWRITER_INTERVAL).timeout
		if (
			generation != _fixed_typewriter_generation
			or _active_fixed_event.is_empty()
			or history_index < 0
			or history_index >= history.size()
		):
			return
		visible_characters += 1
		history[history_index]["text"] = full_text.substr(0, visible_characters)
		_redraw_history()
	if generation != _fixed_typewriter_generation or _active_fixed_event.is_empty():
		return
	_complete_fixed_story_page()


func _fast_forward_fixed_story_page() -> bool:
	if (
		not _fixed_typewriter_running
		or _active_fixed_event.is_empty()
		or _fixed_event_page_index < 0
		or _fixed_event_page_index >= _fixed_event_pages.size()
		or _fixed_typewriter_history_index < 0
		or _fixed_typewriter_history_index >= history.size()
	):
		return false
	_fixed_typewriter_generation += 1
	history[_fixed_typewriter_history_index]["text"] = _fixed_event_pages[_fixed_event_page_index]
	_redraw_history()
	_complete_fixed_story_page()
	return true


func _complete_fixed_story_page() -> void:
	if not _fixed_typewriter_running or _active_fixed_event.is_empty():
		return
	_fixed_typewriter_running = false
	_fixed_typewriter_history_index = -1
	# 每一段固定剧情 NPC 文本都算作一轮输出，与 LLM 回复保持一致。
	TimeSystem.on_dialogue_turn_completed()
	var is_last_page := _fixed_event_page_index >= _fixed_event_pages.size() - 1
	if is_last_page:
		_finish_fixed_story_event()
		return
	_change_state(DialogueState.WAITING_PLAYER)
	input_edit.editable = false
	send_btn.disabled = true
	_show_choices(["继续"])
	regenerate_btn.hide()
	if not choice_buttons.is_empty():
		choice_buttons[0].set_meta("fixed_event_advance", true)
		choice_buttons[0].tooltip_text = "继续"
		choice_buttons[0].grab_focus()


func _advance_fixed_story_event() -> void:
	if _active_fixed_event.is_empty():
		return
	_fixed_event_page_index += 1
	_show_fixed_story_event_page()


func _finish_fixed_story_event() -> void:
	if _active_fixed_event.is_empty():
		return
	var event := _active_fixed_event.duplicate(true)
	var npc_id := String(event.get("_npc_id", ""))
	var raw_choices: Variant = event.get("choices", [])
	var choices: Array[String] = []
	if raw_choices is Array:
		for raw_choice in raw_choices:
			var choice := String(raw_choice).strip_edges()
			if not choice.is_empty():
				choices.append(choice)
	_fixed_event_outcome = NpcStoryEventScript.apply_event(event)
	MemoryStore.append_turn(npc_id, String(event.get("_user_text", "")), "\n\n".join(_fixed_event_pages), choices)
	var effects: Variant = event.get("effects", {})
	if bool(_fixed_event_outcome.get("document_added", false)) and effects is Dictionary:
		var document: Variant = (effects as Dictionary).get("document_clue", {})
		if document is Dictionary:
			SceneItemInteractionScript.show_content_added_toast(String((document as Dictionary).get("title", "资料")), "线索册")
	for item_id in _fixed_event_outcome.get("items_added", []):
		SceneItemInteractionScript.show_content_added_toast(ItemDB.get_display_name(String(item_id)), "物品栏")
	var completed_event_id := String(event.get("id", ""))
	_active_fixed_event = {}
	_fixed_event_pages = []
	_fixed_event_page_index = 0
	_fixed_typewriter_generation += 1
	_fixed_typewriter_running = false
	_fixed_typewriter_history_index = -1
	_change_state(DialogueState.WAITING_PLAYER)
	_show_choices(choices)
	var raw_choice_replies: Variant = event.get("choice_replies", {})
	var choice_replies: Dictionary = raw_choice_replies if raw_choice_replies is Dictionary else {}
	var raw_choice_effects: Variant = event.get("choice_effects", {})
	var choice_effects: Dictionary = raw_choice_effects if raw_choice_effects is Dictionary else {}
	for button in choice_buttons:
		var choice_text := String(button.get_meta("choice_text", ""))
		var local_reply := String(choice_replies.get(choice_text, "")).strip_edges()
		if not local_reply.is_empty():
			button.set_meta("fixed_choice_reply", local_reply)
		var local_effects: Variant = choice_effects.get(choice_text, {})
		if local_effects is Dictionary and not (local_effects as Dictionary).is_empty():
			button.set_meta("fixed_choice_effects", (local_effects as Dictionary).duplicate(true))
	fixed_story_event_completed.emit(completed_event_id)
	input_edit.grab_focus()


## 公聊入口：复用当前 DialogUI 的历史区、输入区和头像区域。
func open_group_chat(participant_ids: Array[String]) -> bool:
	if is_open() or participant_ids.size() < 2:
		return false
	var first_id := participant_ids[0]
	var first_profile := NpcRegistry.get_dialogue_profile(first_id)
	if first_profile.is_empty():
		return false
	_session_id += 1
	_group_mode = true
	_group_finished = false
	current_npc = first_profile
	history.clear()
	_pending_item_request = {}
	_pending_offer = {}
	_clear_all_item_tokens()
	name_label.text = String(first_profile.get("display_name", "???"))
	portrait_rect.color = Color(0.2, 0.18, 0.16)
	_set_portrait_letter(String(first_profile.get("display_name", "?")).substr(0, 1))
	_apply_mood(MoodPortraitUtil.DEFAULT_MOOD)
	history_label.clear()
	_append_history("system", "（%s围在一起，开始谈话……）" % _group_participant_names(participant_ids))
	input_edit.placeholder_text = "对所有在场的人说点什么... (Enter 发送)"
	_hide_choices()
	_change_state(DialogueState.WAITING_PLAYER)
	input_edit.grab_focus()
	return true


func begin_group_npc_turn(npc_id: String) -> void:
	if not _group_mode:
		return
	_set_group_speaker(npc_id, MoodPortraitUtil.MOOD_NORMAL)


func update_group_npc_speech(npc_id: String, accumulated_text: String) -> void:
	if not _group_mode:
		return
	_set_group_speaker(npc_id, MoodPortraitUtil.MOOD_NORMAL)
	var stream_index := _find_group_stream_index(npc_id)
	if stream_index >= 0:
		history[stream_index]["text"] = accumulated_text
	else:
		history.append({
			"role": "group_npc",
			"text": accumulated_text,
			"speaker_id": npc_id,
			"speaker_name": NpcRegistry.get_short_name(npc_id),
			"streaming": true,
		})
	_redraw_history()


func append_group_npc_speech(npc_id: String, text: String, mood_raw: String = "") -> void:
	if not _group_mode:
		return
	_set_group_speaker(npc_id, mood_raw)
	var stream_index := _find_group_stream_index(npc_id)
	if stream_index >= 0:
		history[stream_index]["text"] = text
		history[stream_index]["streaming"] = false
	else:
		history.append({
			"role": "group_npc",
			"text": text,
			"speaker_id": npc_id,
			"speaker_name": NpcRegistry.get_short_name(npc_id),
			"streaming": false,
		})
	_redraw_history()


func _set_group_speaker(npc_id: String, mood_raw: String) -> void:
	var profile := NpcRegistry.get_dialogue_profile(npc_id)
	if profile.is_empty():
		return
	current_npc = profile
	name_label.text = String(profile.get("display_name", "???"))
	_set_portrait_letter(String(profile.get("display_name", "?")).substr(0, 1))
	_apply_mood(mood_raw)


func _find_group_stream_index(npc_id: String) -> int:
	for index in range(history.size() - 1, -1, -1):
		var entry: Dictionary = history[index]
		if String(entry.get("role", "")) == "group_npc" and String(entry.get("speaker_id", "")) == npc_id and bool(entry.get("streaming", false)):
			return index
	return -1


func discard_group_npc_stream(npc_id: String) -> void:
	var stream_index := _find_group_stream_index(npc_id)
	if stream_index >= 0:
		history.remove_at(stream_index)
		_redraw_history()


func set_group_waiting() -> void:
	if not _group_mode:
		return
	_append_history("system", "（众人正在回应……）")
	_change_state(DialogueState.WAITING_LLM)


func complete_group_round() -> void:
	if not _group_mode or _group_finished:
		return
	_remove_thinking_message()
	_change_state(DialogueState.WAITING_PLAYER)
	input_edit.grab_focus()


func finish_group_chat(reason: String) -> void:
	if not _group_mode:
		return
	_remove_thinking_message()
	_group_finished = true
	var reason_text := "已结束" if reason == "player_ended" else "已达到本次谈话上限"
	if reason == "night_rest":
		reason_text = "已经到了晚上，请先回临时宿舍休息"
	_append_history("system", "（本次公聊%s；可点击“离开”关闭记录。）" % reason_text)
	_change_state(DialogueState.WAITING_PLAYER)
	input_edit.editable = false
	send_btn.disabled = true
	input_edit.placeholder_text = "本次公聊已结束"


func _group_participant_names(participant_ids: Array[String]) -> String:
	var names: PackedStringArray = []
	for raw_npc_id in participant_ids:
		names.append(NpcRegistry.get_short_name(String(raw_npc_id)))
	return "、".join(names)


func close_dialogue() -> void:
	if state == DialogueState.CLOSED:
		return
	if _group_mode and not _group_finished:
		group_close_requested.emit()
	_cancel_current_request()
	_fixed_typewriter_generation += 1
	_fixed_typewriter_running = false
	_fixed_typewriter_history_index = -1
	_fixed_choice_typewriter_generation += 1
	_fixed_choice_typewriter_running = false
	_fixed_choice_typewriter_history_index = -1
	_fixed_choice_typewriter_full_text = ""
	_fixed_choice_typewriter_choice_text = ""
	_session_id += 1
	_group_mode = false
	_group_finished = false
	current_npc = {}
	_clear_all_item_tokens()
	_pending_item_request = {}
	_pending_offer = {}
	_close_bag_popup()
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")
	closed.emit()


func _change_state(next_state: DialogueState) -> void:
	state = next_state
	var open := state != DialogueState.CLOSED
	root_panel.visible = open
	if is_instance_valid(dialogue_bg):
		dialogue_bg.visible = open
	if is_instance_valid(portrait_overlay):
		portrait_overlay.visible = open
	if is_instance_valid(actions_box):
		actions_box.visible = get_viewport().get_visible_rect().size.x >= 820.0 and (not _group_mode or open)
	if _group_mode:
		btn_investigate.visible = false
		btn_bag.visible = false
		btn_skill.visible = false
		btn_leave.visible = true
		btn_leave.tooltip_text = "结束并关闭公聊"
	else:
		btn_investigate.visible = true
		btn_bag.visible = true
		btn_skill.visible = true
		btn_leave.visible = open
		btn_leave.tooltip_text = "离开"
	var can_interact := state in [DialogueState.WAITING_PLAYER, DialogueState.ERROR] and not _group_finished
	var can_use_persistent_actions := not _group_mode and state not in [DialogueState.WAITING_LLM, DialogueState.STREAMING]
	input_row.visible = open
	input_edit.visible = open
	send_btn.visible = open
	input_edit.editable = can_interact
	send_btn.disabled = not can_interact
	retry_btn.visible = state == DialogueState.ERROR
	retry_btn.disabled = state != DialogueState.ERROR
	btn_investigate.disabled = not can_use_persistent_actions
	btn_bag.disabled = not can_use_persistent_actions
	btn_investigate.tooltip_text = "打开线索册（J）"
	btn_bag.tooltip_text = "打开背包（I）"
	# 右下角原有技能按钮是唯一入口：场景中可直接使用，对话中则锁定当前 NPC。
	btn_skill.disabled = _group_mode or state in [DialogueState.WAITING_LLM, DialogueState.STREAMING, DialogueState.OPENING] or not _active_fixed_event.is_empty()
	btn_leave.disabled = not open
	regenerate_btn.disabled = state != DialogueState.WAITING_PLAYER
	for button in choice_buttons:
		button.disabled = state != DialogueState.WAITING_PLAYER


func _set_portrait_letter(value: String) -> void:
	var path := "PortraitOverlay/PortraitRect/PortraitLetter"
	var label: Label = get_node(path) if has_node(path) else null
	if label:
		label.text = value


## 切换立绘表情差分。传入的 mood 会先经 MoodPortraitUtil.normalize_mood 规范化，非法值回退到 DEFAULT_MOOD。
## 传入 npc_id 以支持每 NPC 自定义 mood 集合（如林德山有 weary）。
func _apply_mood(mood_raw: String) -> void:
	var npc_id_for_mood: String = String(current_npc.get("id", ""))
	var mood := MoodPortraitUtil.normalize_mood(mood_raw, npc_id_for_mood)
	if mood == "":
		mood = MoodPortraitUtil.DEFAULT_MOOD
	current_mood = mood

	var npc_id: String = String(current_npc.get("id", ""))
	var portrait_size := Vector2i(200, 240)
	if is_instance_valid(portrait_rect) and portrait_rect.size.x > 8 and portrait_rect.size.y > 8:
		portrait_size = Vector2i(int(portrait_rect.size.x), int(portrait_rect.size.y))
	var texture: Texture2D = MoodPortraitUtil.load_or_generate(npc_id, mood, portrait_size)

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
		MoodPortraitUtil.MOOD_NORMAL, "thinking": return "平静"
		MoodPortraitUtil.MOOD_HAPPY: return "开心"
		MoodPortraitUtil.MOOD_ANGRY, "surprised": return "警觉"
		MoodPortraitUtil.MOOD_SAD, "weary": return "低落"
	return ""


func _on_send() -> void:
	if _group_mode:
		_submit_group_message(input_edit.text)
		return
	_submit_player_text(input_edit.text)


func _submit_group_message(raw_text: String) -> void:
	if state != DialogueState.WAITING_PLAYER or _group_finished:
		return
	var text := raw_text.strip_edges()
	if text == "":
		return
	input_edit.text = ""
	_append_history("user", text)
	set_group_waiting()
	group_message_submitted.emit(text)


func _on_choice_pressed(button: Button) -> void:
	if bool(button.get_meta("fixed_event_advance", false)):
		_advance_fixed_story_event()
		return
	# offer_request 分支：按钮携带 offer_decision meta，先走 offer 结算再作为一轮 user 消息发送
	if button.has_meta("offer_decision"):
		_on_offer_decision(bool(button.get_meta("offer_decision", false)))
		return
	# 若这是「我没有 / 不出示」的兜底按钮，先清空已挂 token，避免语义冲突
	if bool(button.get_meta("is_item_deny", false)):
		_clear_all_item_tokens()
	if button.has_meta("fixed_choice_effects"):
		_apply_fixed_choice_effects(button.get_meta("fixed_choice_effects", {}))
	if button.has_meta("fixed_choice_reply"):
		_submit_fixed_choice_reply(String(button.get_meta("choice_text", button.text)), String(button.get_meta("fixed_choice_reply", "")))
		return
	_submit_player_text(String(button.get_meta("choice_text", button.text)))


func _apply_fixed_choice_effects(raw_effects: Variant) -> void:
	if not raw_effects is Dictionary:
		return
	var effects: Dictionary = raw_effects
	var quest: Variant = effects.get("set_quest_stage", {})
	if quest is Dictionary:
		var quest_id := String((quest as Dictionary).get("id", "")).strip_edges()
		if not quest_id.is_empty():
			GameState.set_quest_stage(quest_id, int((quest as Dictionary).get("stage", 0)))
	var investigation: Variant = effects.get("set_investigation_state", {})
	if investigation is Dictionary:
		var state_id := String((investigation as Dictionary).get("id", "")).strip_edges()
		if not state_id.is_empty():
			GameState.set_investigation_state(state_id, (investigation as Dictionary).get("value", true))
	var clues: Variant = effects.get("trigger_clues", [])
	if clues is Array:
		for raw_clue in clues:
			var clue_id := String(raw_clue).strip_edges()
			if not clue_id.is_empty() and not GameState.has_clue(clue_id):
				GameState.trigger_clue(clue_id)
	var items: Variant = effects.get("add_items", [])
	if items is Array:
		for raw_item in items:
			var item_id := String(raw_item).strip_edges()
			if not item_id.is_empty() and not GameState.has_item(item_id):
				GameState.add_item(item_id)
				SceneItemInteractionScript.show_content_added_toast(ItemDB.get_display_name(item_id), "物品栏")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)


func _submit_fixed_choice_reply(choice_text: String, reply_text: String) -> void:
	if state != DialogueState.WAITING_PLAYER or reply_text.is_empty():
		return
	_append_history("user", choice_text)
	_apply_mood(MoodPortraitUtil.resolve_mood("", reply_text, String(current_npc.get("id", ""))))
	_append_history("npc", "")
	_fixed_choice_typewriter_generation += 1
	_fixed_choice_typewriter_running = true
	_fixed_choice_typewriter_history_index = history.size() - 1
	_fixed_choice_typewriter_full_text = reply_text
	_fixed_choice_typewriter_choice_text = choice_text
	_hide_choices()
	_change_state(DialogueState.STREAMING)
	_type_fixed_choice_reply(reply_text, _fixed_choice_typewriter_generation, _fixed_choice_typewriter_history_index)


func _type_fixed_choice_reply(reply_text: String, generation: int, history_index: int) -> void:
	for visible_characters in range(1, reply_text.length() + 1):
		await get_tree().create_timer(FIXED_STORY_TYPEWRITER_INTERVAL).timeout
		if (
			generation != _fixed_choice_typewriter_generation
			or not _fixed_choice_typewriter_running
			or state == DialogueState.CLOSED
			or history_index < 0
			or history_index >= history.size()
		):
			return
		history[history_index]["text"] = reply_text.substr(0, visible_characters)
		_redraw_history()
	if generation != _fixed_choice_typewriter_generation:
		return
	_complete_fixed_choice_reply()


func _fast_forward_fixed_choice_reply() -> bool:
	if (
		not _fixed_choice_typewriter_running
		or _fixed_choice_typewriter_history_index < 0
		or _fixed_choice_typewriter_history_index >= history.size()
	):
		return false
	_fixed_choice_typewriter_generation += 1
	history[_fixed_choice_typewriter_history_index]["text"] = _fixed_choice_typewriter_full_text
	_redraw_history()
	_complete_fixed_choice_reply()
	return true


func _complete_fixed_choice_reply() -> void:
	if not _fixed_choice_typewriter_running:
		return
	var choice_text := _fixed_choice_typewriter_choice_text
	var reply_text := _fixed_choice_typewriter_full_text
	_fixed_choice_typewriter_running = false
	_fixed_choice_typewriter_history_index = -1
	_fixed_choice_typewriter_full_text = ""
	_fixed_choice_typewriter_choice_text = ""
	MemoryStore.append_turn(String(current_npc.get("id", "")), choice_text, reply_text, [])
	TimeSystem.on_dialogue_turn_completed()
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	_change_state(DialogueState.WAITING_PLAYER)
	input_edit.grab_focus()


func _submit_player_text(raw_text: String) -> void:
	if not _active_fixed_event.is_empty():
		return
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var free_text := raw_text.strip_edges()
	# 组装 tokens 前缀。tokens 都是玩家点背包插入的"【使用道具】<name>"，
	# 顺序按点击先后。tokens 与自由文本用换行分隔，方便 LLM 识别。
	var token_prefix := _compose_token_prefix()
	# 若什么都没有（无 token 且无自由输入），拒绝提交
	if token_prefix.is_empty() and free_text.is_empty():
		return
	var text := token_prefix
	if free_text != "":
		if not token_prefix.is_empty():
			text += "\n"
		text += free_text
	input_edit.text = ""
	_clear_all_item_tokens()
	_append_history("user", text)
	_request_llm(text)


func _on_action(label: String) -> void:
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var text := "【动作】" + label
	_append_history("user", text)
	_request_llm(text)


func _on_open_skill_menu() -> void:
	if _group_mode or state in [DialogueState.WAITING_LLM, DialogueState.STREAMING, DialogueState.OPENING] or not _active_fixed_event.is_empty():
		return
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("open_skill_menu_for_npc"):
		var target_npc_id := String(current_npc.get("id", "")) if is_open() else ""
		var dialogue_context: Node = self if is_open() else null
		scene.open_skill_menu_for_npc(target_npc_id, dialogue_context)
		return
	if is_open():
		_append_history("system", "[当前场景尚未接入技能列表。]")


## LocationBase 完成理由输入与确定性检定后回调这里，让技能结果进入当前对话。
func resolve_scene_skill(skill_id: String, reason: String, check_result: Dictionary) -> void:
	if not is_open() or _group_mode or not _active_fixed_event.is_empty():
		return
	var npc_id := String(current_npc.get("id", ""))
	var skill_name := "劝离" if skill_id == "dismiss" else "说服同阵营（共同摧毁祭坛）"
	var user_line := "【使用技能：%s】\n理由：%s" % [skill_name, reason]
	_append_history("user", user_line)
	history.append({"role": "check", "text": CheckSystem.result_to_display_text(check_result), "check_result": check_result})
	_append_history("system", SkillSystem.social_breakdown(check_result))
	_redraw_history()
	var passed := bool(check_result.get("passed", false))
	MemoryStore.add_global_memory(
		"外来者以“%s”为理由对%s使用%s，检定%s。" % [reason, current_npc.get("short_name", "对方"), skill_name, "成功" if passed else "失败"],
		["skill", skill_id, npc_id]
	)
	if skill_id == "dismiss":
		var npc_reply := ""
		if passed:
			npc_reply = "%s接受了你的理由，收拾东西离开了这里。两小时后才会回来。" % current_npc.get("short_name", "对方")
		else:
			npc_reply = "%s摇了摇头，拒绝离开。" % current_npc.get("short_name", "对方")
		_append_history("npc", npc_reply)
		MemoryStore.append_turn(npc_id, user_line, npc_reply, [])
		if passed:
			NpcRegistry.dismiss_npc(npc_id, "被玩家以理由劝离：%s" % reason)
		GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		if passed:
			call_deferred("close_dialogue")
		else:
			_change_state(DialogueState.WAITING_PLAYER)
			input_edit.grab_focus()
		return
	if passed:
		GameState.add_affinity(npc_id, 1)
		GameState.set_investigation_state("altar_ally_%s" % npc_id, true)
		MemoryStore.add_belief(npc_id, "应该与外来者结成同盟，并共同摧毁祭坛", 3, reason, "altar_alliance_skill", "ally_destroy_altar")
		if npc_id == "wu_zhiyuan":
			GameState.add_item("village_chief_safe_silver_key")
			GameState.trigger_clue("wu_chief_safe_key_given")
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	var feedback := CheckSystem.result_to_llm_feedback(check_result, String(current_npc.get("display_name", "")))
	feedback += "\n玩家使用了‘说服同阵营’技能，目标是拉拢你加入其阵营并共同摧毁祭坛，原话是：%s\n%s" % [reason, "检定成功：你已经正式答应加入该阵营，之后必须记得这一承诺并自然回应。" if passed else "检定失败：你没有加入该阵营，请按角色立场说明顾虑或拒绝。"]
	if passed and npc_id == "wu_zhiyuan":
		feedback += "\n这是村长：请在本轮回复中明确描写他从柜底取出并交给玩家一把保险柜钥匙，同时说明他希望玩家保护外乡人。"
	_request_llm(feedback, "check_followup")


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
	_pending_item_request = {}
	_pending_offer = {}
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

	var request_profile := NpcRegistry.build_llm_profile(current_npc)
	request_profile["unlocked_clues"] = GameState.clues.keys()
	# 把「全局记忆 + NPC 独立记忆文档 + 玩家持有物品」拼到 system_prompt 末尾
	var npc_id_for_mem: String = String(current_npc.get("id", ""))
	var memory_block: String = MemoryStore.build_memory_prompt_block(npc_id_for_mem)
	if memory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + memory_block
	var inventory_block: String = ItemDB.build_inventory_prompt_block(GameState.inventory)
	if inventory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + "\n\n" + inventory_block
	# 注入当前时间、地点与同地点人物；NPC 位置固定，不再附带日程或离场预告。
	var scene_block: String = NpcRegistry.build_scene_prompt_block(npc_id_for_mem)
	if scene_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + "\n\n" + scene_block

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


func _on_llm_reply_started(request_id: int, session_id: int, npc_id: String, mood: String, full_text: String) -> void:
	if not _matches_current(request_id, session_id, npc_id):
		return
	_apply_mood(MoodPortraitUtil.resolve_mood(mood, full_text, npc_id))


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
		history[-1]["text"] = _normalize_dialogue_spacing(accumulated)
		_redraw_history()
	else:
		history.append({"role": "npc", "text": _normalize_dialogue_spacing(accumulated), "streaming": true})
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
	# 剥离 [END_DIALOGUE] 等控制标签（玩家不应看到），但保留"是否离场"的判定（_advance_dialogue_clock 里用）
	text = _normalize_dialogue_spacing(_strip_dialogue_tags(text))
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
	var resolved_mood := MoodPortraitUtil.resolve_mood(String(reply.get("mood", "")), text, npc_id)
	_apply_mood(resolved_mood)

	# 检定分支：仅在非检定回填的普通对话轮次里检查 check_request；避免死循环。
	# 优先处理，避免同轮把物品/提议一并塞给玩家。
	var check_request: Dictionary = reply.get("check_request", {}) if reply.get("check_request", null) is Dictionary else {}
	var run_check := (not _current_is_check_followup) and (not check_request.is_empty())

	# meta 结算（污染/好感/线索立即生效；give_item 会合成一个挂起的 offer）
	# 检定分支下不合成 offer，避免 UI 状态混乱：走完检定的下一轮再送物。
	var meta_offered := false
	if not run_check:
		meta_offered = _apply_meta(reply.get("meta", {}))
	else:
		var check_meta: Dictionary = (reply.get("meta", {}) as Dictionary).duplicate(true) if reply.get("meta", null) is Dictionary else {}
		# 检定轮的关系变化只接受 check_request 中经过限幅的字段，避免与 meta 重复结算。
		check_meta.erase("affinity_delta")
		_apply_meta_no_offer(check_meta)

	# item_used：LLM 承认玩家在本轮使用/出示了某道具（顶层字段，独立于 meta）
	var item_used_value: Variant = reply.get("item_used", null)
	if item_used_value is Dictionary:
		_handle_item_used(item_used_value)

	GameState.advance_npc_dialogue_stage(npc_id)
	current_npc["dialogue_stage"] = GameState.get_npc_dialogue_stage(npc_id)

	# 将本轮 user+npc 写入 MemoryStore 长期历史，并按 5 轮阈值触发总结
	# 注意：text 已剥离控制标签；_persist_turn_to_memory 内部会把"是否触发离场"判定
	# 交给 _advance_dialogue_clock，那里需要原始（含 tag）的 text，故单独传 raw。
	_persist_turn_to_memory(npc_id, text, reply_choices, String(reply.get("text", "")))
	# 19:00 后完成本轮已进入休息锁定，不再启动检定、提议或下一轮输入流程。
	if GameState.night_rest_required:
		return

	if run_check:
		_run_check_flow(check_request)
		return

	# M5：LLM 说服裁决器（action 字段）。仅当 check_request 未触发时处理，
	# 避免与检定流程争抢；action 自带 dc/attribute 时走一次轻量检定。
	var llm_action: Dictionary = reply.get("action", {}) if reply.get("action", null) is Dictionary else {}
	if not llm_action.is_empty():
		_handle_llm_action(llm_action, npc_id)

	# offer_request：LLM 直接给出的"提议/请求"字段优先于 meta 合成的（若两者都有）
	var llm_offer: Dictionary = reply.get("offer_request", {}) if reply.get("offer_request", null) is Dictionary else {}
	if not llm_offer.is_empty():
		# 若 LLM 明确表态，覆盖 meta 合成的 give offer
		_pending_offer = llm_offer.duplicate(true)
		_pending_offer["source"] = "llm"

	# item_request：LLM 想让玩家从背包里挑一个物品；把 choice_row 变身为物品选择按钮。
	# 与 check_request 互斥（上面已 return），与 offer_request 互斥（下一个分支会占用 choice_row）
	var item_request: Dictionary = reply.get("item_request", {}) if reply.get("item_request", null) is Dictionary else {}
	_change_state(DialogueState.WAITING_PLAYER)
	if not _pending_offer.is_empty():
		_show_offer_choices(_pending_offer)
		input_edit.grab_focus()
		return
	if not item_request.is_empty() and _try_show_item_request(item_request):
		# 选项区已被物品按钮占用，就不再展示 LLM 原本的对话选项
		input_edit.grab_focus()
		return
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


## 处理 LLMService._compute_meta 计算出来的关键词触发效果。
## 关键设计：
## - pollution / affinity / clue：立即结算（是玩家已经"承受"的东西，不需要点确认）
## - give_item：**不再立即入包**，而是合成一个 offer_request 挂起，让玩家点"收下 / 婉拒"。
##   这样 NPC 给东西的节奏更自然，玩家也保有拒绝的权力。
## 返回 true 表示本轮已经合成了一个 offer 挂起（上层需要走 offer 分支渲染选项）。
func _apply_meta(meta: Dictionary) -> bool:
	_apply_meta_no_offer(meta)
	var item := String(meta.get("give_item", ""))
	if item == "" or GameState.has_item(item):
		return false
	# 合成一份 offer：玩家点"收下" → add_item + 系统提示；点"婉拒" → 不入包
	var display_name: String = ItemDB.get_display_name(item)
	var short_name: String = String(current_npc.get("short_name", current_npc.get("display_name", "对方")))
	_pending_offer = {
		"kind": "give_item",
		"item_id": item,
		"action_id": "",
		"prompt": "%s 要把「%s」递给你，收下吗？" % [short_name, display_name],
		"accept_label": "收下",
		"decline_label": "婉拒",
		"accept_text": "谢谢，我收下了。",
		"decline_text": "谢谢，不必了。",
		"source": "meta_give",
	}
	return true


## 与 _apply_meta 相同，但**跳过 give_item 合成**——用于本轮触发检定的场景，
## 避免检定 UI 和 offer UI 争抢 choice_row。give_item 会在检定后台面清爽下来的
## 下一轮由 NPC 再次触发关键词命中重新出现，或用 offer_request 明确送物。
func _apply_meta_no_offer(meta: Dictionary) -> void:
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


## 处理 LLM 回复顶层的 item_used 字段（已由 SuggestionGuard 做过基础字段校验）。
## 这里再做一次"运行时复核"——玩家真的持有 → 才写记忆、才可能消耗。
func _handle_item_used(used: Dictionary) -> void:
	if used.is_empty():
		return
	var item_id: String = String(used.get("item_id", "")).strip_edges()
	if item_id == "":
		return
	# LLM 若返回中文名，尝试反查 id
	if not ItemDB.exists(item_id) or not GameState.has_item(item_id):
		var resolved := ItemDB.resolve_id_by_name(item_id, GameState.inventory)
		if resolved != "" and GameState.has_item(resolved):
			item_id = resolved
	if not GameState.has_item(item_id):
		push_warning("[DialogueUI] LLM 声称玩家使用了未持有的道具：%s（已忽略）" % item_id)
		return
	var display_name: String = ItemDB.get_display_name(item_id)
	# 消耗判定：LLM 声明 consumed 且物品在 DB 中被标记为可消耗
	var llm_consumed: bool = bool(used.get("consumed", false))
	var db_consumable: bool = ItemDB.is_consumable(item_id)
	var will_consume: bool = llm_consumed and db_consumable
	if llm_consumed and not db_consumable:
		push_warning("[DialogueUI] LLM 声称消耗了不可消耗的道具：%s（已忽略消耗）" % item_id)
	if will_consume:
		if GameState.remove_item(item_id):
			_append_history("system", "[道具被消耗：%s]" % display_name)
			MemoryStore.add_global_memory("玩家使用并消耗了道具「%s」。" % display_name, ["item_used", item_id])
	else:
		_append_history("system", "[你出示了道具：%s]" % display_name)


## 剥离 LLM 输出里的控制标签（如 [END_DIALOGUE]），不展示给玩家
func _strip_dialogue_tags(text: String) -> String:
	var result := text
	for tag in ["[END_DIALOGUE]", "[end_dialogue]", "[END DIALOGUE]"]:
		result = result.replace(tag, "")
	return result.strip_edges()


func _normalize_dialogue_spacing(text: String) -> String:
	var result := text.replace("\r\n", "\n").replace("\r", "\n")
	while result.contains("\n\n"):
		result = result.replace("\n\n", "\n")
	return result.strip_edges()


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
		var text := _normalize_dialogue_spacing(String(entry.get("text", "")))
		match role:
			"user":
				history_label.push_color(Color(0.25, 0.35, 0.55))
				history_label.add_text("[你] " + text)
				history_label.pop()
			"npc":
				history_label.push_color(Color(0.45, 0.25, 0.1))
				history_label.add_text("[%s] %s" % [current_npc.get("short_name", "对方"), text])
				history_label.pop()
			"group_npc":
				history_label.push_color(Color(0.45, 0.25, 0.1))
				history_label.add_text("[%s] %s" % [entry.get("speaker_name", "对方"), text])
				history_label.pop()
			"system":
				history_label.push_color(Color(0.35, 0.35, 0.35))
				history_label.push_italics()
				history_label.add_text(text)
				history_label.pop()
				history_label.pop()
			"check":
				_redraw_check_entry(entry)
			_:
				history_label.add_text(text)
		history_label.add_text("\n")
	history_label.scroll_to_line(max(0, history_label.get_line_count() - 1))


func _show_choices(raw_choices: Variant) -> void:
	var choices: Array[String] = []
	if raw_choices is Array:
		for item in raw_choices:
			var choice := String(item).strip_edges()
			if choice == "" or choices.has(choice):
				continue
			choices.append(choice.left(80))
			if choices.size() >= choice_buttons.size():
				break

	# 用 modulate 透明度代替 visible，避免选项区显隐时挤压 History / InputRow
	var choices_visible := state == DialogueState.WAITING_PLAYER
	choice_row.modulate.a = 1.0 if choices_visible else 0.0
	regenerate_btn.visible = choices_visible
	regenerate_btn.disabled = not choices_visible
	for index in range(choice_buttons.size()):
		var button := choice_buttons[index]
		# 同时控制 visible 和 modulated 透明度，保证布局稳定 + 透明时不接收点击
		var show := choices_visible and (index < choices.size())
		button.visible = show
		if not show:
			button.disabled = true
			continue
		var full_text := choices[index]
		button.remove_meta("fixed_event_advance")
		button.remove_meta("fixed_choice_reply")
		button.remove_meta("offer_decision")
		button.remove_meta("is_item_deny")
		button.remove_meta("is_item_choice")
		button.text = full_text.left(18) + ("…" if full_text.length() > 18 else "")
		button.tooltip_text = full_text
		button.set_meta("choice_text", full_text)
		button.disabled = false


func _hide_choices() -> void:
	choice_row.modulate.a = 0.0
	for button in choice_buttons:
		button.visible = false
		button.disabled = true


# ─── 记忆持久化 & 总结 ────────────────────────────────────────────────

func _persist_turn_to_memory(npc_id: String, npc_text: String, choices: Variant, raw_npc_text: String = "") -> void:
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
			# check_followup 也算一轮对话推进时间
			_advance_dialogue_clock(npc_id, raw_npc_text if raw_npc_text != "" else npc_text, false)
		_pending_user_text_for_memory = ""
		return

	MemoryStore.append_turn(npc_id, _pending_user_text_for_memory, npc_text, choice_list)
	_pending_user_text_for_memory = ""
	_maybe_trigger_summary(npc_id)
	# 一轮玩家提问与 NPC 完整回复结束后推进时间，并在 19:00 后锁定至回宿舍休息。
	_advance_dialogue_clock(npc_id, raw_npc_text if raw_npc_text != "" else npc_text, true)


## 每轮对话推进十分钟；时间变化不会再改变 NPC 的固定地点。
func _advance_dialogue_clock(_npc_id: String, raw_npc_text: String, allow_rest_lock: bool) -> void:
	var rest_required: bool = false
	if allow_rest_lock:
		rest_required = GameState.complete_player_dialogue_round()
	else:
		TimeSystem.on_dialogue_turn_completed()
	if rest_required and is_open():
		_lock_for_night_rest()
		return
	var npc_replied_end := raw_npc_text.contains("[END_DIALOGUE]") or raw_npc_text.contains("[end_dialogue]")
	if npc_replied_end and is_open():
		_append_history("system", "（%s 结束了这段谈话。）" % current_npc.get("short_name", "对方"))
		call_deferred("close_dialogue")


func _lock_for_night_rest() -> void:
	_hide_choices()
	_clear_all_item_tokens()
	if TimeSystem.is_rest_lock_time():
		_append_history("system", "（已经 22:00，请回临时宿舍休息。今晚的调查到此结束。）")
		input_edit.placeholder_text = "请回宿舍休息"
	else:
		_append_history("system", "（天黑了，请先返回临时宿舍休整。）")
		input_edit.placeholder_text = "请先返回临时宿舍"
	_change_state(DialogueState.REST_LOCKED)


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


## M5：处理 LLM 说服裁决器的 action 字段（§8）。
## 用 action.dc/attribute 掷一次骰；成功才执行 action，失败则不变更位置。
func _handle_llm_action(action: Dictionary, npc_id: String) -> void:
	var dc := int(action.get("dc", 0))
	var attribute := String(action.get("attribute", "charisma"))
	var confidence := String(action.get("confidence", ""))
	if confidence == "refused":
		# NPC 明确拒绝
		return
	# 有 dc 就掷骰裁决
	if dc > 0:
		var result := CheckSystem.perform_check(attribute, dc, 0, "玩家说服 %s 改变行程" % npc_id)
		var passed := bool(result.get("passed", false))
		MemoryStore.add_global_memory(
			"外来者试图让%s%s（DC %d），%s（掷 %d）。" % [
				current_npc.get("short_name", "对方"),
				_describe_action(action),
				dc,
				"成功了" if passed else "失败了",
				int(result.get("roll", 0)),
			],
			["persuade", npc_id])
		if not passed:
			_append_history("system", "[说服失败] %s 不太情愿地摇了摇头。" % current_npc.get("short_name", "对方"))
			return
	# 裁决通过 → 走 NpcRegistry.apply_llm_action
	var outcome := NpcRegistry.apply_llm_action(npc_id, action)
	if bool(outcome.get("applied", false)):
		var desc := String(outcome.get("description", ""))
		if desc != "":
			_append_history("system", "[%s]" % desc)


func _describe_action(action: Dictionary) -> String:
	match String(action.get("type", "")):
		"follow_player": return "陪同一起走"
		"move_to": return "前往%s" % String(action.get("target_location", ""))
		"leave": return "告辞离开"
		"postpone_leave": return "推迟离场"
		_: return "改变行程"


# ─── 检定流程 ────────────────────────────────────────────────────────

func _run_check_flow(check_request: Dictionary) -> void:
	## 由 LLM 发起 check_request → 执行掷骰 → 展示 → 再调 LLM 让 NPC 反应
	var attribute_raw: String = String(check_request.get("attribute", ""))
	var difficulty: int = int(check_request.get("difficulty", 0))
	var reason: String = String(check_request.get("reason", ""))
	var check_kind: String = String(check_request.get("kind", "general"))
	var belief_claim: String = String(check_request.get("belief_claim", "")).strip_edges()
	var repeat_key: String = String(check_request.get("repeat_key", "")).strip_edges()
	if CheckSystem.normalize_attribute(attribute_raw) == "" or difficulty <= 0:
		# 非法请求 → 静默降级为普通回复：直接进入等待玩家状态
		_change_state(DialogueState.WAITING_PLAYER)
		input_edit.grab_focus()
		return
	var npc_id: String = String(current_npc.get("id", ""))
	var npc_name: String = String(current_npc.get("display_name", current_npc.get("short_name", "村民")))
	var check_context: String = _build_check_context_signature(npc_id)
	var player_attempt_key: String = _build_player_attempt_key()
	var repeated_topic: bool = not repeat_key.is_empty() and MemoryStore.is_failed_check_blocked(npc_id, repeat_key, check_context)
	var repeated_wording: bool = not player_attempt_key.is_empty() and MemoryStore.is_failed_check_blocked(npc_id, player_attempt_key, check_context)
	if repeated_topic or repeated_wording:
		_append_history("system", "[重复检定已阻止] 相同目标在当前情境下已经检定失败；需要取得新线索、物品或改变局势后才能重试。")
		var refusal_feedback := "【系统·重复检定被拒绝】玩家正在重复刚才已经失败的同一项请求或观点说服。当前证据与局势没有发生足以支持重试的变化，因此本轮不掷骰、不改变好感，也不得接受请求。请用角色口吻直接拒绝、表示不愿再谈，或要求玩家先带来新的依据；不要再次输出 check_request。"
		_request_llm(refusal_feedback, "check_followup", false)
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
	_apply_mood(MoodPortraitUtil.MOOD_NORMAL)

	# 关键叙事事件写入全局记忆；骰子过程本身不再单独写 NPC 历史
	# （NPC 后续 check_followup 的反应会被 _persist_turn_to_memory 正常记录）
	var passed: bool = bool(result.get("passed", false))
	var affinity_delta: int = int(check_request.get("affinity_on_success", 0)) if passed else int(check_request.get("affinity_on_failure", 0))
	affinity_delta = clampi(affinity_delta, 0, 1) if passed else clampi(affinity_delta, -2, 0)
	var affinity_reason: String = String(check_request.get("affinity_reason", "")).strip_edges()
	var relationship_feedback: String = ""
	if affinity_delta != 0:
		GameState.add_affinity(npc_id, affinity_delta)
		var relationship_label: String = "增加" if affinity_delta > 0 else "降低"
		_append_history("system", "[关系变化] %s好感度%s %d%s" % [npc_name, relationship_label, absi(affinity_delta), "：" + affinity_reason if not affinity_reason.is_empty() else ""])
		relationship_feedback = "\n【关系变化】本次检定使你对玩家的好感度%s %d。原因：%s。请在反应中自然体现，但不要直接说出数值。" % [relationship_label, absi(affinity_delta), affinity_reason if not affinity_reason.is_empty() else "本次交涉的性质影响了你们的关系"]
	var belief_feedback: String = ""
	if check_kind == "belief" and not belief_claim.is_empty():
		if passed:
			var belief_confidence: int = 3 if String(result.get("severity", "")) == "crit_success" else 2
			var stored_belief: Dictionary = MemoryStore.add_belief(
				npc_id,
				belief_claim,
				belief_confidence,
				reason,
				"dialogue_persuasion"
			)
			if not stored_belief.is_empty():
				_append_history("system", "[信念改变] %s现在相信：%s" % [npc_name, belief_claim])
				belief_feedback = "\n【持久化信念变化】检定成功。你现在%s这一观点：%s。之后的态度和措辞应持续受它影响，但仍须遵守核心人设与信息披露边界。" % ["坚定相信" if belief_confidence >= 3 else "相信", belief_claim]
				GameState.save_game(GameState.AUTO_SAVE_PATH, false)
		else:
			belief_feedback = "\n【信念未改变】检定失败。你没有被玩家说服，不得把以下观点当作自己已经相信的事实：%s。请按角色立场自然说明疑虑或反驳。" % belief_claim
	if passed:
		MemoryStore.clear_failed_check(npc_id, repeat_key)
		MemoryStore.clear_failed_check(npc_id, player_attempt_key)
	else:
		# 好感变化已经结算，使用结算后的情境签名，防止扣好感本身立刻绕过重复锁。
		var failed_context: String = _build_check_context_signature(npc_id)
		MemoryStore.record_failed_check(npc_id, repeat_key, failed_context)
		MemoryStore.record_failed_check(npc_id, player_attempt_key, failed_context)
	GameState.save_game(GameState.AUTO_SAVE_PATH, false)
	match String(result.get("severity", "")):
		"crit_success":
			MemoryStore.add_global_memory("玩家在与 %s 交涉时投出了大成功，交涉取得了超出预期的进展。" % npc_name, ["check", "crit_success"])
		"crit_failure":
			MemoryStore.add_global_memory("玩家在与 %s 交涉时投出了大失败，交涉遭遇了严重挫折。" % npc_name, ["check", "crit_failure"])

	# 再次调用 LLM，让 NPC 根据结果反应；purpose=check_followup 避免二次检定
	var feedback: String = CheckSystem.result_to_llm_feedback(result, npc_name)
	feedback += belief_feedback
	feedback += relationship_feedback
	_request_llm(feedback, "check_followup", false)


func _build_check_context_signature(npc_id: String) -> String:
	var clue_ids: Array = GameState.clues.keys()
	clue_ids.sort()
	var item_ids: Array = GameState.inventory.duplicate()
	item_ids.sort()
	var belief_ids: Array[String] = []
	for belief in MemoryStore.get_beliefs(npc_id):
		belief_ids.append(String(belief.get("id", "")))
	belief_ids.sort()
	var context: Dictionary = {
		"clues": clue_ids,
		"items": item_ids,
		"beliefs": belief_ids,
		"disclosure": NpcRegistry.get_disclosure_level(current_npc),
		"quest_stages": GameState.quest_stages,
		"investigation_states": GameState.investigation_states,
	}
	return JSON.stringify(context).sha256_text().left(32)


func _build_player_attempt_key() -> String:
	var normalized: String = _last_user_text.to_lower().replace("\r", " ").replace("\n", " ").replace("\t", " ").strip_edges()
	while normalized.contains("  "):
		normalized = normalized.replace("  ", " ")
	if normalized.is_empty():
		return ""
	return "input_" + normalized.sha256_text().left(20)


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


# ─── 线索册 ──────────────────────────────────────────────────────

## 原“调查环境”按钮改为线索册入口；按钮贴图可在后续直接替换。
func _on_open_clue_book_pressed() -> void:
	open_journal_page()


func open_journal_page() -> bool:
	if _group_mode or state in [DialogueState.WAITING_LLM, DialogueState.STREAMING]:
		return false
	var popup := _get_or_create_clue_book_popup()
	if popup == null:
		return false
	if popup.has_method("is_ui_open") and popup.is_ui_open():
		popup.close_ui()
		return true
	var allow_present := is_open() and state in [DialogueState.WAITING_PLAYER, DialogueState.ERROR] and _active_fixed_event.is_empty()
	popup.open_ui(GameState.get_clue_book_entries(), allow_present)
	return true


func _get_or_create_clue_book_popup() -> ClueBookPopup:
	if is_instance_valid(_clue_book_popup):
		return _clue_book_popup
	_clue_book_popup = ClueBookPopupScript.new()
	get_tree().current_scene.add_child(_clue_book_popup)
	_clue_book_popup.view_requested.connect(_on_clue_book_view_requested)
	_clue_book_popup.present_requested.connect(_on_clue_book_present_requested)
	return _clue_book_popup


func _on_clue_book_view_requested(entry: Dictionary) -> void:
	var viewer := _get_or_create_clue_document_viewer()
	if viewer == null:
		return
	if String(entry.get("entry_type", "")) == "story_clue":
		var story_summary := String(entry.get("summary", "")).strip_edges()
		if not story_summary.is_empty():
			viewer.open_paged_text(String(entry.get("title", "线索")), [story_summary])
		return
	if String(entry.get("entry_type", "")) == "text_pages":
		var pages: Array[String] = []
		for raw_page in entry.get("pages", []):
			if raw_page is String and not raw_page.strip_edges().is_empty():
				pages.append(raw_page)
		if not pages.is_empty():
			viewer.open_paged_text(String(entry.get("title", "教程")), pages)
		return
	var image_path := String(entry.get("image_path", ""))
	if not image_path.begins_with("res://assets/documents/"):
		return
	var image_texture := load(image_path) as Texture2D
	if image_texture != null:
		viewer.open_document(String(entry.get("title", "资料")), image_texture, {}, false)


func _on_clue_book_present_requested(entry: Dictionary) -> void:
	if _group_mode or not is_open() or not _active_fixed_event.is_empty():
		return
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var clue_ids := _clue_ids_for_entry(entry)
	if clue_ids.is_empty():
		return
	if is_instance_valid(_clue_book_popup):
		_clue_book_popup.close_ui()
	var title := String(entry.get("title", "线索")).strip_edges()
	var summary := String(entry.get("summary", "")).strip_edges()
	var presentation_text := "%s%s" % [CLUE_SHOW_PREFIX, title]
	if not summary.is_empty():
		presentation_text += "\n简述：" + summary
	_append_history("user", presentation_text)

	# Key evidence uses authored NPC JSON pages/effects and never relies on the
	# model to reproduce quest-critical dialogue or rewards.
	var fixed_event := NpcStoryEventScript.find_presented_clue_event(current_npc, clue_ids)
	if not fixed_event.is_empty():
		_play_fixed_story_event(fixed_event, String(current_npc.get("id", "")), presentation_text)
		return

	# Ordinary clues are supplied to the provider as concrete observed facts.
	# Existing trigger keyword matching still runs in LLMService, so configured
	# non-fixed effects remain deterministic while the wording stays free-form.
	_request_llm(presentation_text)


func _clue_ids_for_entry(entry: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var clue_id := String(entry.get("id", "")).strip_edges()
	if not clue_id.is_empty():
		result.append(clue_id)
	var linked: Variant = entry.get("linked_clue_ids", [])
	if linked is Array:
		for raw_id in linked:
			var linked_id := String(raw_id).strip_edges()
			if not linked_id.is_empty() and not result.has(linked_id):
				result.append(linked_id)
	return result


func _get_or_create_clue_document_viewer() -> SceneItemInteraction:
	if is_instance_valid(_clue_document_viewer):
		return _clue_document_viewer
	_clue_document_viewer = SceneItemInteractionScript.new()
	get_tree().current_scene.add_child(_clue_document_viewer)
	return _clue_document_viewer


# ─── 道具：Token 条 + 背包弹窗 ─────────────────────────────────────

## 玩家点击右侧"打开背包"按钮
func _on_open_bag_pressed() -> void:
	open_inventory_page()


func open_inventory_page() -> bool:
	if _group_mode or state in [DialogueState.WAITING_LLM, DialogueState.STREAMING]:
		return false
	var popup := _get_or_create_bag_popup()
	if popup == null:
		return false
	if popup.has_method("is_ui_open") and popup.is_ui_open():
		popup.close_ui()
		return true
	popup.set_meta("bound_dialogue", self)
	popup.open_ui(GameState.inventory, _pending_item_tokens, is_open())
	return true


func _get_or_create_bag_popup() -> CanvasLayer:
	if is_instance_valid(_bag_popup):
		return _bag_popup
	# 优先寻找场景里已存在的 ItemBagPopup（Main.tscn 里已实例化）
	var scene_root := get_tree().current_scene
	if scene_root:
		var found := scene_root.find_child("ItemBagPopup", true, false)
		if found is CanvasLayer:
			_bag_popup = found
	if _bag_popup == null:
		# 兜底：动态实例化
		var scene: PackedScene = load("res://scenes/ui/ItemBagPopup.tscn") as PackedScene
		if scene == null:
			push_warning("[DialogueUI] 找不到 ItemBagPopup.tscn")
			return null
		_bag_popup = scene.instantiate()
		get_tree().current_scene.add_child(_bag_popup)
	# 只连一次；重复 connect 会报错，故先断开
	if _bag_popup.has_signal("item_picked") and not _bag_popup.is_connected("item_picked", Callable(self, "_on_bag_item_picked")):
		_bag_popup.item_picked.connect(_on_bag_item_picked)
	return _bag_popup


func _close_bag_popup() -> void:
	if is_instance_valid(_bag_popup) and _bag_popup.has_method("close_ui"):
		_bag_popup.close_ui()


func _on_bag_item_picked(item_id: String) -> void:
	if item_id.is_empty():
		return
	# 已经在本次组合里 → 忽略（弹窗端也已经变灰，这是双保险）
	if _pending_item_tokens.has(item_id):
		return
	# 服务端复核：玩家真持有
	if not GameState.has_item(item_id):
		push_warning("[DialogueUI] 尝试插入未持有的道具 token：%s" % item_id)
		return
	_add_item_token(item_id)
	# 同步让弹窗把该 id 变灰
	if is_instance_valid(_bag_popup) and _bag_popup.has_method("set_disabled_ids"):
		_bag_popup.set_disabled_ids(_pending_item_tokens)
	# 让玩家继续在输入区补充自然语言
	input_edit.grab_focus()


## 往 TokenRow 里追加一个金色药丸标签；点击可移除
func _add_item_token(item_id: String) -> void:
	var display_name: String = ItemDB.get_display_name(item_id)
	var token := Button.new()
	token.text = TOKEN_PREFIX + display_name + "  ✕"
	token.tooltip_text = "点击移除该道具（本轮不再使用它）"
	token.focus_mode = Control.FOCUS_NONE
	token.custom_minimum_size = Vector2(0, 28)
	# 用主题覆盖模拟"药丸"外观：金色背景 + 深色文字
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = TOKEN_BG_COLOR
	sb_normal.set_corner_radius_all(14)
	sb_normal.set_content_margin_all(8)
	sb_normal.border_width_top = 1
	sb_normal.border_width_bottom = 1
	sb_normal.border_width_left = 1
	sb_normal.border_width_right = 1
	sb_normal.border_color = Color(0.85, 0.65, 0.15)
	var sb_hover := sb_normal.duplicate()
	(sb_hover as StyleBoxFlat).bg_color = TOKEN_BG_COLOR.lightened(0.08)
	token.add_theme_stylebox_override("normal", sb_normal)
	token.add_theme_stylebox_override("hover", sb_hover)
	token.add_theme_stylebox_override("pressed", sb_normal)
	token.add_theme_stylebox_override("focus", sb_normal)
	token.add_theme_color_override("font_color", TOKEN_FG_COLOR)
	token.add_theme_color_override("font_hover_color", TOKEN_FG_COLOR)
	token.add_theme_color_override("font_pressed_color", TOKEN_FG_COLOR)
	token.add_theme_font_size_override("font_size", 15)
	token.set_meta("item_id", item_id)
	token.pressed.connect(_on_token_pressed.bind(item_id))
	token_row.add_child(token)
	token_row.visible = true
	_pending_item_tokens.append(item_id)
	_pending_token_buttons[item_id] = token


func _on_token_pressed(item_id: String) -> void:
	_remove_item_token(item_id)
	# 同步弹窗（若还开着）把该道具重新可点
	if is_instance_valid(_bag_popup) and _bag_popup.visible and _bag_popup.has_method("set_disabled_ids"):
		_bag_popup.set_disabled_ids(_pending_item_tokens)


func _remove_item_token(item_id: String) -> void:
	var index := _pending_item_tokens.find(item_id)
	if index >= 0:
		_pending_item_tokens.remove_at(index)
	var btn: Variant = _pending_token_buttons.get(item_id, null)
	if btn is Button and is_instance_valid(btn):
		(btn as Button).queue_free()
	_pending_token_buttons.erase(item_id)
	token_row.visible = not _pending_item_tokens.is_empty()


func _clear_all_item_tokens() -> void:
	for btn in _pending_token_buttons.values():
		if btn is Button and is_instance_valid(btn):
			(btn as Button).queue_free()
	_pending_item_tokens.clear()
	_pending_token_buttons.clear()
	token_row.visible = false


## 发送前把 tokens 拼成一段自然语言前缀
func _compose_token_prefix() -> String:
	if _pending_item_tokens.is_empty():
		return ""
	var parts: PackedStringArray = []
	for item_id in _pending_item_tokens:
		parts.append(TOKEN_PREFIX + ItemDB.get_display_name(item_id))
	return " ".join(parts)


# ─── LLM 主动请求物品（item_request）：把 choice_row 变身为物品按钮 ───

## 返回 true 表示已成功把 choice_row 占用；返回 false 让上层继续走普通 choices 流程。
func _try_show_item_request(item_request: Dictionary) -> bool:
	var candidates_raw: Variant = item_request.get("candidates", [])
	if not (candidates_raw is Array):
		return false
	var owned: Array = ItemDB.filter_owned(candidates_raw, GameState.inventory)
	# 玩家一件相关的都没有 → 不占用选项区，让 LLM 的普通 choices 继续引导玩家用文字回答"没有"
	if owned.is_empty():
		return false
	_pending_item_request = {
		"candidates": owned,
		"reason": String(item_request.get("reason", "")),
	}
	# 让 choice_row 显示物品按钮 + 最后一颗"没有 / 不给"兜底按钮
	choice_row.modulate.a = 1.0
	regenerate_btn.visible = false
	regenerate_btn.disabled = true

	var count := mini(owned.size(), choice_buttons.size())
	for i in range(choice_buttons.size()):
		var btn := choice_buttons[i]
		btn.set_meta("is_item_choice", false)
		btn.set_meta("is_item_deny", false)
		if i < count:
			var item_id: String = String(owned[i])
			btn.visible = true
			btn.disabled = false
			var display_name: String = ItemDB.get_display_name(item_id)
			btn.text = "🎒 出示：" + display_name
			btn.tooltip_text = "把「%s」出示给对方" % display_name
			btn.set_meta("choice_text", "%s%s" % [ITEM_SHOW_PREFIX, display_name])
			btn.set_meta("is_item_choice", true)
		else:
			# 剩下的按钮里最后一个用来当"没有 / 我不给"
			if i == count and count < choice_buttons.size():
				btn.visible = true
				btn.disabled = false
				btn.text = "我没有 / 不出示"
				btn.tooltip_text = "如实告诉对方你身上没有这类东西"
				btn.set_meta("choice_text", "我身上没有你说的那种东西。")
				btn.set_meta("is_item_deny", true)
			else:
				btn.visible = false
				btn.disabled = true
	return true


# ─── 背包弹窗 API 暴露给外部按键（比如 I 键快捷键）——预留 ─────
func has_active_dialogue_bag() -> bool:
	return is_instance_valid(_bag_popup) and _bag_popup.visible


# ─── 通用 offer_request：NPC 主动送物 / 请求玩家做某事 ─────────────

## 把 choice_row 变成 [接受_label] [拒绝_label] 两个按钮；正上方 append 一条 system
## 提示 "对方提议：<prompt>" 让玩家一眼看到。
func _show_offer_choices(offer: Dictionary) -> void:
	if offer.is_empty():
		return
	var prompt_text: String = String(offer.get("prompt", ""))
	if prompt_text != "":
		_append_history("system", "[对方的提议] %s" % prompt_text)

	choice_row.modulate.a = 1.0
	regenerate_btn.visible = false
	regenerate_btn.disabled = true

	var accept_label: String = String(offer.get("accept_label", "接受"))
	var decline_label: String = String(offer.get("decline_label", "拒绝"))

	# 按钮 0 = 接受；按钮 1 = 拒绝；其余隐藏
	for index in range(choice_buttons.size()):
		var btn := choice_buttons[index]
		btn.set_meta("is_item_choice", false)
		btn.set_meta("is_item_deny", false)
		if btn.has_meta("offer_decision"):
			btn.remove_meta("offer_decision")
		if index == 0:
			btn.visible = true
			btn.disabled = false
			btn.text = "✓ " + accept_label
			btn.tooltip_text = prompt_text
			btn.set_meta("offer_decision", true)
		elif index == 1:
			btn.visible = true
			btn.disabled = false
			btn.text = "✕ " + decline_label
			btn.tooltip_text = prompt_text
			btn.set_meta("offer_decision", false)
		else:
			btn.visible = false
			btn.disabled = true


## 玩家点击"接受"或"拒绝"后：
## - 结算副作用（give_item 接受则入包）
## - 追加系统提示
## - 用 accept_text / decline_text 作为下一轮 user 消息回给 LLM
func _on_offer_decision(accepted: bool) -> void:
	if _pending_offer.is_empty():
		# 状态被别的分支清掉了，兜底：什么也不做
		return
	var offer := _pending_offer
	_pending_offer = {}
	# 接受/拒绝时清掉玩家在此期间意外插入的道具 token 与输入框内容，避免语义混杂
	_clear_all_item_tokens()
	input_edit.text = ""

	var kind: String = String(offer.get("kind", ""))
	var item_id: String = String(offer.get("item_id", ""))
	var accept_text: String = String(offer.get("accept_text", ""))
	var decline_text: String = String(offer.get("decline_text", ""))

	var display_name: String = ItemDB.get_display_name(item_id) if item_id != "" else ""
	if accepted:
		# 只有 give_item 走 add_item；其他 kind 由 LLM 后续叙事推动，DialogueUI 不动 GameState
		if kind == "give_item" and item_id != "":
			if not GameState.has_item(item_id):
				GameState.add_item(item_id)
			_append_history("system", "[你获得了道具：%s]" % display_name)
		else:
			_append_history("system", "[你答应了对方的提议]")
	else:
		if kind == "give_item" and display_name != "":
			_append_history("system", "[你婉拒了对方的赠予：%s]" % display_name)
		else:
			_append_history("system", "[你拒绝了对方的提议]")

	# 把玩家的应答作为下一轮 user 消息，让 NPC 有机会自然反应
	var reply_text: String = accept_text if accepted else decline_text
	if reply_text.strip_edges() == "":
		reply_text = "（默默地作出了回应。）"
	# 关键：在应答前加显式标签，让 LLM 明确"这是玩家对上一轮 offer 的回应"，
	# 避免它继续用"犹豫过渡"模板去回，或错把玩家应答当成新的疑问。
	var tag: String = "【接受提议】" if accepted else "【拒绝提议】"
	_submit_player_text(tag + reply_text)
