extends CanvasLayer
## Dialogue UI with explicit request/session ownership.

const MoodPortraitUtil := preload("res://scripts/ui/MoodPortrait.gd")

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
@onready var btn_leave: BaseButton = $Actions/Leave
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

## Token 药丸配色（金色，与普通输入区分）
const TOKEN_BG_COLOR := Color(1.0, 0.85, 0.4, 1.0)
const TOKEN_FG_COLOR := Color(0.15, 0.10, 0.02, 1.0)
const TOKEN_PREFIX := "【使用道具】"
const ITEM_SHOW_PREFIX := "【出示道具】"

## ─── 通用「NPC 提议 / 请求」（offer_request）─────────────────────
## 挂起中的 offer；非空时 choice_row 会被占用为 [接受][拒绝] 两个按钮。
## 结构由 SuggestionGuard._parse_offer_request 生成；额外键 "source" 用于区分来源：
##   "llm"           - LLM 直接输出 offer_request
##   "meta_give"     - 由旧 give_item 关键词触发合成，接受时会 add_item(item_id)
var _pending_offer: Dictionary = {}


func _ready() -> void:
	add_to_group("dialogue_ui")
	get_viewport().size_changed.connect(_apply_responsive_layout)
	send_btn.pressed.connect(_on_send)
	retry_btn.pressed.connect(_on_retry)
	regenerate_btn.pressed.connect(_on_regenerate_choices)
	input_edit.text_submitted.connect(func(_text): _on_send())
	btn_investigate.pressed.connect(func(): _on_action("调查"))
	btn_bag.pressed.connect(_on_open_bag_pressed)
	btn_skill.pressed.connect(func(): _on_action("使用技能"))
	btn_leave.pressed.connect(_on_leave)
	for button in choice_buttons:
		button.pressed.connect(_on_choice_pressed.bind(button))

	LLMService.reply_received.connect(_on_llm_reply)
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
	actions_box.visible = false
	_change_state(DialogueState.CLOSED)
	call_deferred("_apply_responsive_layout")


func _apply_responsive_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# 所有位置/大小均在 Godot 编辑器中通过 tscn 定义，代码不再强制覆盖。
	# 这里只处理可见性跟随对话框开关。
	portrait_box.visible = false
	actions_box.visible = is_open() and viewport_size.x >= 820.0
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
	_apply_mood(MoodPortraitUtil.DEFAULT_MOOD)
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
		actions_box.visible = open
	var can_interact := state in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]
	input_row.visible = open
	input_edit.visible = open
	send_btn.visible = open
	input_edit.editable = can_interact
	send_btn.disabled = not can_interact
	retry_btn.visible = state == DialogueState.ERROR
	retry_btn.disabled = state != DialogueState.ERROR
	btn_investigate.disabled = not can_interact
	btn_bag.disabled = not can_interact
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


## 切换立绘表情差分。传入的 mood 会先经 MoodPortraitUtil.normalize_mood 规范化，非法值回退到 DEFAULT_MOOD。
func _apply_mood(mood_raw: String) -> void:
	var mood := MoodPortraitUtil.normalize_mood(mood_raw)
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
		MoodPortraitUtil.MOOD_HAPPY: return "开心"
		MoodPortraitUtil.MOOD_THINKING: return "思考"
		MoodPortraitUtil.MOOD_SURPRISED: return "惊讶"
	return ""


func _on_send() -> void:
	_submit_player_text(input_edit.text)


func _on_choice_pressed(button: Button) -> void:
	# offer_request 分支：按钮携带 offer_decision meta，先走 offer 结算再作为一轮 user 消息发送
	if button.has_meta("offer_decision"):
		_on_offer_decision(bool(button.get_meta("offer_decision", false)))
		return
	# 若这是「我没有 / 不出示」的兜底按钮，先清空已挂 token，避免语义冲突
	if bool(button.get_meta("is_item_deny", false)):
		_clear_all_item_tokens()
	_submit_player_text(String(button.get_meta("choice_text", button.text)))


func _submit_player_text(raw_text: String) -> void:
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

	var request_profile := current_npc.duplicate(true)
	request_profile["unlocked_clues"] = GameState.clues.keys()
	# 把「全局记忆 + NPC 独立记忆文档 + 玩家持有物品」拼到 system_prompt 末尾
	var npc_id_for_mem: String = String(current_npc.get("id", ""))
	var memory_block: String = MemoryStore.build_memory_prompt_block(npc_id_for_mem)
	if memory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + memory_block
	var inventory_block: String = ItemDB.build_inventory_prompt_block(GameState.inventory)
	if inventory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + "\n\n" + inventory_block

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
	var resolved_mood := MoodPortraitUtil.resolve_mood(String(reply.get("mood", "")), text)
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
		_apply_meta_no_offer(reply.get("meta", {}))

	# item_used：LLM 承认玩家在本轮使用/出示了某道具（顶层字段，独立于 meta）
	var item_used_value: Variant = reply.get("item_used", null)
	if item_used_value is Dictionary:
		_handle_item_used(item_used_value)

	GameState.advance_npc_dialogue_stage(npc_id)
	current_npc["dialogue_stage"] = GameState.get_npc_dialogue_stage(npc_id)

	# 将本轮 user+npc 写入 MemoryStore 长期历史，并按 5 轮阈值触发总结
	_persist_turn_to_memory(npc_id, text, reply_choices)

	if run_check:
		_run_check_flow(check_request)
		return

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
				history_label.push_color(Color(0.25, 0.35, 0.55))
				history_label.add_text("[你] " + text)
				history_label.pop()
			"npc":
				history_label.push_color(Color(0.45, 0.25, 0.1))
				history_label.add_text("[%s] %s" % [current_npc.get("short_name", "对方"), text])
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
	_apply_mood(MoodPortraitUtil.MOOD_THINKING)

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


# ─── 道具：Token 条 + 背包弹窗 ─────────────────────────────────────

## 玩家点击右侧"打开背包"按钮
func _on_open_bag_pressed() -> void:
	if state not in [DialogueState.WAITING_PLAYER, DialogueState.ERROR]:
		return
	var popup := _get_or_create_bag_popup()
	if popup == null:
		return
	popup.set_meta("bound_dialogue", self)
	popup.open_ui(GameState.inventory, _pending_item_tokens)


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
