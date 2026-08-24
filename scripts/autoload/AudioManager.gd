extends Node
## 全局音频管理器：地点 BGM、导航音乐和低干扰 UI 音效。
##
## BGM 使用两个播放器交叉淡化，避免地点切换时突然截断；按钮音效使用小型
## 播放器池，避免连续点击时打断前一个短音效。缺失资源只会警告并回退到
## 通用环境音，不阻塞场景加载。

const LOCATIONS_PATH := "res://data/locations.json"
const TITLE_BGM_PATH := "res://assets/audio/bgm/title_lightless_dawn.ogg"
## 地图是导航层，不占用 12 个地点自己的音轨；使用低干扰的户外环境音。
const MAP_BGM_PATH := "res://assets/audio/bgm/field_path.ogg"
const FALLBACK_BGM_PATH := "res://assets/audio/bgm/field_path.ogg"

const BGM_BUS_NAME := &"BGM"
const SFX_BUS_NAME := &"SFX"
const BGM_FADE_SECONDS := 1.2
## Web 浏览器和系统音量通常比桌面版更保守；-14dB 容易被误认为没有播放。
## 仍保持低于短促 UI 音效的环境声比例，但提升到可明确听见的水平。
const BGM_TARGET_DB := -7.0
## 地图打开时保留当前曲目，线性响度降至原来的 70%。
const MAP_BGM_DUCK_DB := -3.0980392
const MAP_BGM_DUCK_SECONDS := 0.2
const SFX_TARGET_DB := -10.0
const BGM_PLAYER_COUNT := 2
const SFX_PLAYER_COUNT := 6

const BUTTON_BOUND_META := &"_audio_manager_bound"
const BUTTON_SFX_META := &"audio_sfx"

const SFX_PATHS := {
	"click": "res://assets/audio/sfx/click.ogg",
	"confirm": "res://assets/audio/sfx/confirm.ogg",
	"cancel": "res://assets/audio/sfx/cancel.ogg",
	"error": "res://assets/audio/sfx/error.ogg",
	"select": "res://assets/audio/sfx/select.ogg",
}

var _location_tracks: Dictionary = {}
var _sfx_streams: Dictionary = {}
var _warned_paths: Dictionary = {}
var _bgm_players: Array[AudioStreamPlayer] = []
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_cursor := 0
var _active_bgm_index := 0
var _current_track_key := ""
var _current_track_path := ""
var _bgm_tween: Tween
var _bgm_bus_tween: Tween
var _map_bgm_ducked := false
var _web_bgm_retry_attempted := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_audio_bus(BGM_BUS_NAME)
	_ensure_audio_bus(SFX_BUS_NAME)
	_create_players()
	_load_location_tracks()
	_load_sfx_streams()
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)
	call_deferred("_scan_current_scene_buttons")


func _unhandled_input(event: InputEvent) -> void:
	if not OS.has_feature("web") or _web_bgm_retry_attempted:
		return
	var is_unlock_input: bool = (
		(event is InputEventMouseButton and event.pressed)
		or (event is InputEventScreenTouch and event.pressed)
		or (event is InputEventKey and event.pressed and not event.echo)
	)
	if is_unlock_input:
		retry_current_bgm_if_needed()


func _ensure_audio_bus(bus_name: StringName) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, bus_name)
	AudioServer.set_bus_send(bus_index, &"Master")


func _create_players() -> void:
	for index in range(BGM_PLAYER_COUNT):
		var player := AudioStreamPlayer.new()
		player.name = "BGMPlayer%d" % index
		player.bus = BGM_BUS_NAME
		player.volume_db = -80.0
		add_child(player)
		_bgm_players.append(player)

	for index in range(SFX_PLAYER_COUNT):
		var player := AudioStreamPlayer.new()
		player.name = "SFXPlayer%d" % index
		player.bus = SFX_BUS_NAME
		player.volume_db = SFX_TARGET_DB
		add_child(player)
		_sfx_players.append(player)


func _load_location_tracks() -> void:
	_location_tracks.clear()
	if not FileAccess.file_exists(LOCATIONS_PATH):
		push_warning("[AudioManager] 找不到地点表：%s" % LOCATIONS_PATH)
		return
	var file := FileAccess.open(LOCATIONS_PATH, FileAccess.READ)
	if file == null:
		push_warning("[AudioManager] 无法打开地点表：%s" % LOCATIONS_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Array:
		push_warning("[AudioManager] 地点表格式非法，无法读取 BGM 映射")
		return
	for raw_location in parsed:
		if not raw_location is Dictionary:
			continue
		var location: Dictionary = raw_location
		var location_id := String(location.get("id", "")).strip_edges()
		if location_id.is_empty():
			continue
		var path := String(location.get("bgm", "")).strip_edges()
		if path.is_empty():
			path = "res://assets/audio/bgm/%s.ogg" % location_id
		_location_tracks[location_id] = path


func _load_sfx_streams() -> void:
	_sfx_streams.clear()
	for effect_id in SFX_PATHS:
		var path := String(SFX_PATHS[effect_id])
		var stream := _load_stream(path, false)
		if stream != null:
			_sfx_streams[String(effect_id)] = stream


func play_title_bgm() -> void:
	_play_bgm("title", TITLE_BGM_PATH)


func play_map_bgm() -> void:
	_play_bgm("map", MAP_BGM_PATH)


func play_track(track_id: String) -> void:
	match track_id:
		"title":
			play_title_bgm()
		"map":
			play_map_bgm()
		_:
			play_location_bgm(track_id)


func set_map_bgm_ducked(ducked: bool, seconds: float = MAP_BGM_DUCK_SECONDS) -> void:
	if _map_bgm_ducked == ducked:
		return
	_map_bgm_ducked = ducked
	var bus_index := AudioServer.get_bus_index(BGM_BUS_NAME)
	if bus_index < 0:
		return
	if _bgm_bus_tween != null and _bgm_bus_tween.is_valid():
		_bgm_bus_tween.kill()
	var target_db := MAP_BGM_DUCK_DB if ducked else 0.0
	_bgm_bus_tween = create_tween()
	_bgm_bus_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bgm_bus_tween.tween_method(_set_bgm_bus_volume, AudioServer.get_bus_volume_db(bus_index), target_db, maxf(seconds, 0.0))


func _set_bgm_bus_volume(volume_db: float) -> void:
	var bus_index := AudioServer.get_bus_index(BGM_BUS_NAME)
	if bus_index >= 0:
		AudioServer.set_bus_volume_db(bus_index, volume_db)


func play_location_bgm(location_id: String) -> void:
	var path := String(_location_tracks.get(location_id, ""))
	if path.is_empty():
		push_warning("[AudioManager] 地点缺少 BGM 映射：%s，回退到通用环境音" % location_id)
		_play_bgm("fallback:%s" % location_id, FALLBACK_BGM_PATH)
		return
	_play_bgm("location:%s" % location_id, path)


func retry_current_bgm_if_needed() -> bool:
	if _bgm_players.is_empty():
		return false
	var active_player := _bgm_players[_active_bgm_index]
	if not OS.has_feature("web"):
		return active_player.playing
	if _web_bgm_retry_attempted:
		return active_player.playing
	_web_bgm_retry_attempted = true
	if _current_track_key.is_empty() or _current_track_path.is_empty():
		return false
	var track_key := _current_track_key
	var track_path := _current_track_path
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	for player in _bgm_players:
		player.stop()
		player.volume_db = -80.0
	_current_track_key = ""
	_current_track_path = ""
	_play_bgm(track_key, track_path)
	return _bgm_players[_active_bgm_index].playing


func _play_bgm(track_key: String, path: String) -> void:
	if _current_track_key == track_key:
		var active_player := _bgm_players[_active_bgm_index] if not _bgm_players.is_empty() else null
		if active_player != null and active_player.playing:
			return

	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()

	var stream := _load_stream(path, true)
	if stream == null and path != FALLBACK_BGM_PATH:
		push_warning("[AudioManager] BGM 不可用：%s，回退到通用环境音" % path)
		path = FALLBACK_BGM_PATH
		track_key = "fallback:%s" % track_key
		stream = _load_stream(path, true)
	if stream == null:
		return

	var old_player := _bgm_players[_active_bgm_index]
	var next_index := 1 - _active_bgm_index
	var next_player := _bgm_players[next_index]
	next_player.stop()
	next_player.stream = stream
	next_player.bus = BGM_BUS_NAME
	next_player.volume_db = -80.0
	next_player.play()

	_active_bgm_index = next_index
	_current_track_key = track_key
	_current_track_path = path

	var fade := create_tween().set_parallel(true)
	fade.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	fade.tween_property(next_player, "volume_db", BGM_TARGET_DB, BGM_FADE_SECONDS)
	if old_player.playing:
		fade.tween_property(old_player, "volume_db", -80.0, BGM_FADE_SECONDS)
		fade.finished.connect(_finish_crossfade.bind(old_player))
	_bgm_tween = fade


func _finish_crossfade(old_player: AudioStreamPlayer) -> void:
	if not is_instance_valid(old_player):
		return
	old_player.stop()
	old_player.volume_db = -80.0


func fade_out_bgm(seconds: float = BGM_FADE_SECONDS) -> void:
	if _bgm_players.is_empty():
		return
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	var track_key := _current_track_key
	var active_player := _bgm_players[_active_bgm_index]
	if not active_player.playing:
		_current_track_key = ""
		_current_track_path = ""
		return
	var fade := create_tween()
	fade.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	fade.tween_property(active_player, "volume_db", -80.0, maxf(seconds, 0.0))
	await fade.finished
	active_player.stop()
	active_player.volume_db = -80.0
	if _current_track_key == track_key:
		_current_track_key = ""
		_current_track_path = ""


func play_sfx(effect_id: String) -> void:
	if _sfx_players.is_empty():
		return
	var normalized_id := effect_id.strip_edges().to_lower()
	if normalized_id == "cancel" or normalized_id == "confirm":
		normalized_id = "click"
	var stream: AudioStream = _sfx_streams.get(normalized_id) as AudioStream
	if stream == null and normalized_id != "click":
		stream = _sfx_streams.get("click") as AudioStream
	if stream == null:
		var missing_path := String(SFX_PATHS.get(normalized_id, ""))
		if not missing_path.is_empty():
			_warn_missing(missing_path)
		return
	var player := _sfx_players[_sfx_cursor]
	_sfx_cursor = (_sfx_cursor + 1) % _sfx_players.size()
	player.stream = stream
	player.bus = SFX_BUS_NAME
	player.volume_db = SFX_TARGET_DB
	player.play()


func _load_stream(path: String, loop: bool) -> AudioStream:
	if path.is_empty() or not ResourceLoader.exists(path):
		_warn_missing(path)
		return null
	var stream := load(path) as AudioStream
	if stream == null:
		_warn_missing(path)
		return null
	if loop:
		_configure_loop(stream)
	return stream


func _configure_loop(stream: AudioStream) -> void:
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD


func _warn_missing(path: String) -> void:
	if path.is_empty() or _warned_paths.has(path):
		return
	_warned_paths[path] = true
	push_warning("[AudioManager] 音频资源缺失或无法加载：%s" % path)


func _on_tree_node_added(node: Node) -> void:
	if node is BaseButton:
		call_deferred("_bind_button", node)


func _scan_current_scene_buttons() -> void:
	var current_scene := get_tree().current_scene
	if current_scene != null:
		_scan_buttons(current_scene)


func _scan_buttons(node: Node) -> void:
	_bind_button(node)
	for child in node.get_children():
		_scan_buttons(child)


func _bind_button(node: Node) -> void:
	if not node is BaseButton:
		return
	var button := node as BaseButton
	if bool(button.get_meta(BUTTON_BOUND_META, false)):
		return
	button.set_meta(BUTTON_BOUND_META, true)
	if button is OptionButton:
		(button as OptionButton).item_selected.connect(_on_option_selected.bind(button))
	else:
		button.pressed.connect(_on_button_pressed.bind(button))


func _on_button_pressed(button: BaseButton) -> void:
	retry_current_bgm_if_needed()
	play_sfx(_button_effect_id(button))


func _on_option_selected(_index: int, option: OptionButton) -> void:
	retry_current_bgm_if_needed()
	var explicit_id := String(option.get_meta(BUTTON_SFX_META, "")).strip_edges()
	play_sfx(explicit_id if not explicit_id.is_empty() else "select")


func _button_effect_id(button: BaseButton) -> String:
	var explicit_id := String(button.get_meta(BUTTON_SFX_META, "")).strip_edges()
	if not explicit_id.is_empty():
		return explicit_id
	var caption := ""
	if button is Button:
		caption = String((button as Button).text)
	var haystack := (String(button.name) + " " + caption).to_lower()
	if _contains_any(haystack, ["cancel", "close", "back", "leave", "取消", "关闭", "返回", "离开"]):
		return "cancel"
	if _contains_any(haystack, ["confirm", "submit", "save", "start", "open", "use", "continue", "enter", "确认", "提交", "保存", "开始", "打开", "使用", "继续", "进入"]):
		return "confirm"
	return "click"


func _contains_any(value: String, candidates: Array[String]) -> bool:
	for candidate in candidates:
		if value.contains(candidate):
			return true
	return false
