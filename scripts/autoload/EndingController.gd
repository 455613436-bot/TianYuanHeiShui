extends CanvasLayer
## 统一处理祭坛、关键NPC存亡、污染与第8天夜间的结局裁决。

const ENDINGS := {
	"ancient_released": {
		"title": "古神释放",
		"text": "祭坛已被摧毁，道士也已死去。失去最后约束的利库伊从山洞深处扩散，村庄与水脉一同被吞没。"
	},
	"complete_seal": {
		"title": "彻底封印",
		"text": "原始仪式重新闭合了封印，而神秘人再也无法破坏它。洞中的水声终于沉寂，利库伊被压回了黑暗深处。"
	},
	"pollution_follower": {
		"title": "污染结局：利库伊的信徒",
		"text": "污染抵达极限。你不再把低语当成威胁，而把它当成幸福的召唤。你留在田原村，成为利库伊新的信徒。"
	},
	"suppression": {
		"title": "抑制结局",
		"text": "献祭没有如期完成，祭坛遭到破坏，利库伊的力量受到抑制。它仍在水脉深处等待，未来或许还会卷土重来。"
	},
	"sacrifice": {
		"title": "献祭结局",
		"text": "第八天的夜晚过去，祭坛仍在运转。村民被卷入献祭，山洞深处传来新的潮声——古神回应了召唤。"
	}
}

var _ending_started := false


func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameState.pollution_changed.connect(_on_pollution_changed)
	TimeSystem.day_changed.connect(_on_day_changed)
	call_deferred("evaluate_endings")


func _on_pollution_changed(value: int) -> void:
	if value >= GameState.MAX_POLLUTION:
		start_ending("pollution_follower")


func _on_day_changed(new_day: int) -> void:
	# 第8天的24:00就是第9天00:00。休息流程会跨越午夜，因此用换日信号保证必达。
	if new_day >= 9:
		evaluate_endings()


func on_altar_resolution_changed() -> void:
	evaluate_endings()


func on_npc_killed(_npc_id: String) -> void:
	evaluate_endings()


func evaluate_endings() -> void:
	if _ending_started or GameState.is_game_ended():
		return
	if GameState.pollution >= GameState.MAX_POLLUTION:
		start_ending("pollution_follower")
		return
	var altar_state := String(GameState.get_investigation_state("altar_resolution", "untouched"))
	var hermit_dead := NpcRegistry.is_npc_killed("mysterious_hermit")
	var taoist_dead := NpcRegistry.is_npc_killed("li_leshui_day") or NpcRegistry.is_npc_killed("li_leshui_night")
	if altar_state == "destroyed" and taoist_dead:
		start_ending("ancient_released")
		return
	if altar_state == "sealed" and hermit_dead:
		start_ending("complete_seal")
		return
	if TimeSystem.current_day >= 9:
		start_ending("suppression" if altar_state == "destroyed" else "sacrifice")


func start_ending(ending_id: String) -> void:
	if _ending_started or GameState.is_game_ended():
		return
	var ending: Dictionary = ENDINGS.get(ending_id, {})
	if ending.is_empty():
		return
	_ending_started = true
	GameState.finish_game(ending_id)
	var overlay := Control.new()
	overlay.name = "EndingOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dimmer := ColorRect.new()
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.color = Color(0.015, 0.02, 0.025, 0.94)
	overlay.add_child(dimmer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -380.0
	panel.offset_top = -180.0
	panel.offset_right = 380.0
	panel.offset_bottom = 180.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.075, 0.09, 0.10, 0.98)
	style.border_color = Color(0.76, 0.90, 0.96, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", style)
	overlay.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 20)
	panel.add_child(content)
	var title := Label.new()
	title.text = String(ending.get("title", "结局"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.93, 0.84, 0.60, 1.0))
	content.add_child(title)
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.custom_minimum_size = Vector2(650, 170)
	body.add_theme_font_size_override("normal_font_size", 21)
	body.add_theme_color_override("default_color", Color(0.90, 0.93, 0.90, 1.0))
	body.text = String(ending.get("text", ""))
	content.add_child(body)
	var hint := Label.new()
	hint.text = "结局已结算。"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.66, 0.75, 0.78, 1.0))
	content.add_child(hint)
	add_child(overlay)
	# 结局弹窗出现后暂停所有地点、对话和地图交互，当前游戏流程到此结束。
	get_tree().paused = true
