extends Control
## TitleScreen
## 游戏首屏：标题 + 主菜单 + 背景音乐
##
## 功能：
## - 开始新游戏：清除自动存档，跳到属性分配 UI
## - 继续游戏：从 auto save 恢复（无档时按钮禁用）
## - 设置：打开 SettingsMenu autoload
## - 退出：quit
##
## 背景音乐 "title_lightless_dawn.ogg" 循环播放；离开本场景前淡出。

const NEW_GAME_SCENE := "res://scenes/ui/AttributeAllocation.tscn"
const SETTINGS_SCENE_PATH := "res://scenes/ui/SettingsMenu.tscn"  # 兜底：SettingsMenu autoload 缺失时手动打开
const FADE_OUT_SECONDS := 0.8

@onready var title_label: Label = $Center/VBox/Title
@onready var subtitle_label: Label = $Center/VBox/Subtitle
@onready var new_game_btn: Button = $Center/VBox/Buttons/NewGameBtn
@onready var continue_btn: Button = $Center/VBox/Buttons/ContinueBtn
@onready var settings_btn: Button = $Center/VBox/Buttons/SettingsBtn
@onready var quit_btn: Button = $Center/VBox/Buttons/QuitBtn
@onready var footer_label: Label = $Footer/FooterLabel

var _leaving := false


func _ready() -> void:
	title_label.text = "思源村探案"
	subtitle_label.text = "Siyuan Village Mystery"
	footer_label.text = "WASD 移动 · E 交互 · M 打开地图 · Esc 设置"

	new_game_btn.pressed.connect(_on_new_game)
	continue_btn.pressed.connect(_on_continue)
	settings_btn.pressed.connect(_on_open_settings)
	quit_btn.pressed.connect(_on_quit)

	_refresh_continue_button()
	AudioManager.play_title_bgm()
	new_game_btn.grab_focus()


func _refresh_continue_button() -> void:
	## 只有 auto save 存在且有效时，"继续游戏"才可用
	var meta := GameState.get_save_metadata(GameState.AUTO_SAVE_PATH)
	var has_save := bool(meta.get("exists", false)) and bool(meta.get("valid", false))
	continue_btn.disabled = not has_save
	if has_save:
		var when := String(meta.get("saved_at_text", ""))
		continue_btn.tooltip_text = "继续 " + when if when != "" else "继续之前的进度"
	else:
		continue_btn.tooltip_text = "尚无存档"


func _on_new_game() -> void:
	if _leaving:
		return
	# 清掉自动存档并把所有玩家进度归零，同时发放初始物品（相机等）；
	# 保证进入属性分配 UI 而不是被"已分配"跳过。
	GameState.clear_save(GameState.AUTO_SAVE_PATH)
	GameState.reset_for_new_game()
	MemoryStore.reset()
	await _fade_out_bgm()
	get_tree().change_scene_to_file(NEW_GAME_SCENE)


func _on_continue() -> void:
	if _leaving or continue_btn.disabled:
		return
	await _fade_out_bgm()
	var err := GameState.load_game(GameState.AUTO_SAVE_PATH, true)
	if err != OK:
		push_warning("[TitleScreen] 继续游戏失败：%s" % error_string(err))
		# 保底：加载失败就直接走新游戏流程
		get_tree().change_scene_to_file(NEW_GAME_SCENE)


func _on_open_settings() -> void:
	if _leaving:
		return
	# 复用现有的 SettingsMenu autoload
	for node in get_tree().get_nodes_in_group("settings_menu"):
		if node.has_method("open_ui"):
			node.open_ui()
			return
	# 兜底：如果 autoload 没就绪，直接实例化
	if ResourceLoader.exists(SETTINGS_SCENE_PATH):
		var packed: PackedScene = load(SETTINGS_SCENE_PATH)
		if packed != null:
			var instance := packed.instantiate()
			get_tree().root.add_child(instance)
			if instance.has_method("open_ui"):
				instance.call("open_ui")


func _on_quit() -> void:
	if _leaving:
		return
	_leaving = true
	await _fade_out_bgm()
	get_tree().quit()


func _fade_out_bgm() -> void:
	_leaving = true
	await AudioManager.fade_out_bgm(FADE_OUT_SECONDS)
