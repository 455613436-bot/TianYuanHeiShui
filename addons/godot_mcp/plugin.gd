@tool
extends EditorPlugin

## Runtime bridges used to be persisted into project.godot while the editor plugin
## was active. That made export contents depend on whether the editor happened to
## be open. Keep MCP editor tooling, but remove the runtime bridge from the game.
const LEGACY_RUNTIME_AUTOLOADS: Array[String] = [
	"autoload/MCPRuntimeBridge",
	"autoload/MCPInputBridge",
	"autoload/MCPScreenshotBridge",
]

var _websocket_client: Node
var _command_router: Node
var _release_sanitizer: EditorExportPlugin
var auto_dismiss_dialogs: bool = false


class MCPReleaseSanitizer extends EditorExportPlugin:
	var _saved_editor_plugins: Variant = null

	func _get_name() -> String:
		return "MCPReleaseSanitizer"

	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		_saved_editor_plugins = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
		# project.binary is generated from live ProjectSettings. Hide editor-only
		# plugin metadata for the duration of every production export.
		ProjectSettings.set_setting("editor_plugins/enabled", PackedStringArray())

	func _export_end() -> void:
		if _saved_editor_plugins != null:
			ProjectSettings.set_setting("editor_plugins/enabled", _saved_editor_plugins)
		_saved_editor_plugins = null


func _enter_tree() -> void:
	_remove_legacy_runtime_autoloads()
	_release_sanitizer = MCPReleaseSanitizer.new()
	add_export_plugin(_release_sanitizer)
	_command_router = preload("res://addons/godot_mcp/command_router.gd").new()
	_command_router.name = "MCPCommandRouter"
	_command_router.editor_plugin = self
	add_child(_command_router)

	_websocket_client = preload("res://addons/godot_mcp/websocket_client.gd").new()
	_websocket_client.name = "MCPWebSocketClient"
	_websocket_client.command_router = _command_router
	add_child(_websocket_client)
	_websocket_client.start()
	print("[Godot MCP] Plugin started")


func _exit_tree() -> void:
	if _release_sanitizer != null:
		remove_export_plugin(_release_sanitizer)
		_release_sanitizer = null
	if _websocket_client:
		_websocket_client.stop()
		_websocket_client.queue_free()
	if _command_router:
		_command_router.queue_free()
	print("[Godot MCP] Plugin stopped")


func _process(_delta: float) -> void:
	if not auto_dismiss_dialogs:
		return
	var base_control := get_editor_interface().get_base_control()
	if base_control:
		_dismiss_dialogs(base_control)


func _dismiss_dialogs(node: Node) -> void:
	if node is AcceptDialog and node.visible:
		node.hide()
	for child in node.get_children():
		_dismiss_dialogs(child)


func _remove_legacy_runtime_autoloads() -> void:
	var changed := false
	for key in LEGACY_RUNTIME_AUTOLOADS:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			changed = true
	if changed:
		ProjectSettings.save()
		print("[Godot MCP] Removed legacy runtime autoloads from project settings")
