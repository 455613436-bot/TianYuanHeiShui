extends SceneTree
## LLM REPL —— 终端里跑的 NPC 对话调试工具。
##
## 完全复用游戏自身的 autoload（LLMConfig/LLMService/MemoryStore/GameState/
## NpcPersona/SuggestionGuard），保证 prompt 组装、检定触发、记忆更新与游戏一致。
##
## 启动：
##   godot-editor.exe --headless --path siyuan-mystery --script res://scripts/tools/llm_repl.gd
## 或者用工具目录里的 llm_repl.bat / llm_repl.ps1 一键跑起来。
##
## 交互命令（在提示符 `> ` 后输入）：
##   /help                          —— 命令帮助
##   /npc <id>                      —— 切换 NPC（data/npcs/<id>.md）
##   /npcs                          —— 列出可用 NPC
##   /reset                         —— 清空当前 NPC 的对话历史与记忆摘要
##   /reset all                     —— 清空所有 NPC 的记忆
##   /history                       —— 打印当前 NPC 完整对话历史
##   /memory                        —— 打印当前 NPC 的记忆摘要与全局记忆
##   /summarize                     —— 手动触发记忆总结（不等 5 轮阈值）
##   /clue <id>                     —— 手动解锁一条线索（模拟游戏中 unlocked_clues）
##   /clues                         —— 打印当前已解锁线索
##   /trace on|off                  —— 打开/关闭 trace 落盘
##   /where                         —— 打印当前 trace 目录路径
##   /provider                      —— 打印当前 LLM Provider 信息
##   /quit  或  /exit               —— 退出
##   其它任意文本                    —— 作为玩家输入发给 LLM

const NpcPersona := preload("res://scripts/llm/NpcPersona.gd")
const TraceLoggerScript := preload("res://scripts/tools/TraceLogger.gd")
const MemoryStoreScript := preload("res://scripts/autoload/MemoryStore.gd")

var _tracer: RefCounted = null
var _shutting_down: bool = false

var _current_npc_id: String = ""
var _current_profile: Dictionary = {}
var _current_request_id: int = 0
var _current_user_text: String = ""
var _stream_shown: bool = false
var _streaming_last_len: int = 0

## 引导只做一次
var _bootstrapped: bool = false
## 提示符是否已打（避免重复打）
var _prompt_shown: bool = false
## 等待 LLMConfig 完成 provider 探测的启动帧数
var _bootstrap_wait_frames: int = 0
const _BOOTSTRAP_MAX_WAIT_FRAMES: int = 60  ## 最多等 60 帧 (~1 秒 @ 60fps)

## stdin 后台线程：Godot 4 的 OS.read_string_from_stdin 是**阻塞式**的，
## 交互模式下会等到用户按回车才返回；若放在主线程 _process 里读，
## 会把整个主循环冻住，HTTPRequest 的回调也没机会 tick，导致
## "输入完卡住、NPC 永远不回话"。所以必须开一条后台线程读 stdin，
## 主线程只从 mutex 保护的队列里拿已完成的行。
var _stdin_thread: Thread = null
var _stdin_mutex: Mutex = Mutex.new()
## 待消费的完整行（不含末尾换行）
var _pending_lines: Array[String] = []
## 上一次 read 的残余（读到的最后一段没有换行结尾，留到下次拼上）
var _stdin_carry: String = ""
## 线程发现 stdin EOF 后置 true，让主线程走退出流程
var _stdin_eof: bool = false


func _init() -> void:
	# 让 SceneTree 保持活着（headless 也会有 quit 时机）
	auto_accept_quit = false


func _initialize() -> void:
	pass  # bootstrap 推迟到首帧 _process，那时候 autoload 都已 _ready


## 每帧被 SceneTree 调 process()；返回 true 表示退出
func _process(_delta: float) -> bool:
	if _shutting_down:
		return true

	if not _bootstrapped:
		# 等 LLMConfig 完成 provider 探测（它是 await process_frame 装的）
		_bootstrap_wait_frames += 1
		var svc0: Node = _get_llm_service()
		var provider0: Node = null
		if svc0 != null:
			provider0 = svc0.get("_provider")
		# name == "OpenAILLM" 表明 LLMConfig 已经完成切换；name == "MockLLM" 说明还没到
		var provider_ready := (provider0 != null and String(provider0.name) == "OpenAILLM")
		if not provider_ready and _bootstrap_wait_frames < _BOOTSTRAP_MAX_WAIT_FRAMES:
			return false
		_do_bootstrap()
		_bootstrapped = true
		return false

	# 有正在飞的请求 —— 让 HTTPRequest / 信号处理，不消费 stdin
	if _current_request_id != 0:
		return false

	# 从 stdin 后台线程的队列里把已完成的行拿出来处理
	var lines: Array[String] = _drain_pending_lines()
	for next_line in lines:
		_prompt_shown = false
		_dispatch_line(next_line.strip_edges())
		if _shutting_down:
			return true
		# 若 dispatch 发起了 LLM 请求，先返回等回复
		if _current_request_id != 0:
			return false

	# stdin 已 EOF 且队列消费完 —— 退出
	if _stdin_eof:
		_println("\n[EOF] stdin closed, exiting.")
		_shutting_down = true
		quit()
		return true

	if not _prompt_shown:
		_print_prompt()
		_prompt_shown = true

	return false


func _drain_pending_lines() -> Array[String]:
	var out: Array[String] = []
	_stdin_mutex.lock()
	if not _pending_lines.is_empty():
		out = _pending_lines.duplicate()
		_pending_lines.clear()
	_stdin_mutex.unlock()
	return out


## 后台线程：阻塞式 read stdin，把读到的行放进 mutex 队列。
## Godot 4 的 OS.read_string_from_stdin 可以在非主线程调用。
##
## 4.7 在不同 stdin 类型下行为差别很大（实测过）：
##   - CONSOLE（交互终端，get_stdin_type=1）
##       * read 是**阻塞**的，等到用户按下回车才返回
##       * 一次调用返回**一整行且 Godot 已经去掉行末的 \n**
##       * 直接把 chunk 视为一整行入队即可
##   - FILE / PIPE（重定向，get_stdin_type=2/3）
##       * 一次可能读到多行（含 \n）；空返回 = EOF
##       * 用 \n 拆分入队；残余段（不以 \n 结尾）用 carry 攒到下次
func _stdin_worker() -> void:
	var is_console: bool = true
	if OS.has_method("get_stdin_type"):
		var t: int = OS.call("get_stdin_type")
		is_console = (t == 1)  # STD_HANDLE_CONSOLE = 1

	while not _shutting_down:
		var chunk := OS.read_string_from_stdin(65535)

		if is_console:
			# 交互终端：chunk 就是一整行（可能为空 = 用户按了空行）
			# 空字符串在 CONSOLE 下**不会**由 Godot 返回；一旦 read 返回，
			# 就一定是用户按下了回车，chunk 是本行内容（可能是 ""）。
			_stdin_mutex.lock()
			_pending_lines.append(chunk)
			_stdin_mutex.unlock()
			continue

		# FILE / PIPE 模式
		if chunk == "":
			# 真 EOF —— 提交残余后退出
			_stdin_mutex.lock()
			if _stdin_carry != "":
				_pending_lines.append(_stdin_carry)
				_stdin_carry = ""
			_stdin_eof = true
			_stdin_mutex.unlock()
			return
		var combined := _stdin_carry + chunk
		combined = combined.replace("\r\n", "\n").replace("\r", "\n")
		var parts := combined.split("\n")
		var new_carry := ""
		if not combined.ends_with("\n"):
			new_carry = String(parts[parts.size() - 1])
			parts.remove_at(parts.size() - 1)
		_stdin_mutex.lock()
		_stdin_carry = new_carry
		for p in parts:
			_pending_lines.append(String(p))
		_stdin_mutex.unlock()


func _finalize() -> void:
	_shutting_down = true
	# stdin 线程可能还阻塞在 read 上；主线程无法优雅打断它，
	# 我们把标志位置好就直接返回，OS 在进程退出时会回收该线程。
	# （如果尝试 wait_to_finish() 反而会自己被卡住）
	_stdin_thread = null
	_println("再见。")


# ─── 启动引导 ────────────────────────────────────────────────────────

func _do_bootstrap() -> void:
	_println("")
	_println("=== 思源村探案 LLM REPL ===")
	_println("已加载 autoload: GameState / MemoryStore / LLMService / LLMConfig / CheckSystem")

	_tracer = TraceLoggerScript.new(true)

	# 挂 LLMService 信号
	var svc: Node = _get_llm_service()
	if svc != null:
		svc.reply_received.connect(_on_reply_received)
		svc.reply_failed.connect(_on_reply_failed)
		svc.reply_chunk.connect(_on_reply_chunk)
		svc.summary_ready.connect(_on_summary_ready)
		svc.summary_failed.connect(_on_summary_failed)

	# 把 tracer 挂到当前 provider（如果是 OpenAILLM）
	_install_tracer_on_provider()

	_cmd_provider_info()
	_bootstrap_default_npc()
	_println("")
	_print_help()

	# 启动 stdin 后台线程 —— 必须在这里，否则主线程 read stdin 会冻结主循环
	_stdin_thread = Thread.new()
	_stdin_thread.start(_stdin_worker)


# ─── 命令派发 ───────────────────────────────────────────────────────

func _dispatch_line(line: String) -> void:
	if line == "":
		return
	if line.begins_with("/"):
		_run_command(line)
		return
	# 普通文本 —— 作为玩家话发送
	if _current_profile.is_empty():
		_println("尚未加载 NPC。用 `/npcs` 查看，`/npc <id>` 切换。")
		_print_prompt()
		return
	if _current_request_id != 0:
		_println("上一轮还没回完，请稍等（或用 /cancel 也可以，但目前没实现）")
		_print_prompt()
		return
	_send_user_turn(line)


func _run_command(raw: String) -> void:
	var parts := raw.substr(1).split(" ", false)
	var cmd := String(parts[0]).to_lower()
	var args: Array = []
	for i in range(1, parts.size()):
		args.append(String(parts[i]))
	match cmd:
		"help", "h", "?":
			_print_help()
		"quit", "exit", "q":
			_shutting_down = true
			quit()
		"npcs", "list":
			_cmd_list_npcs()
		"npc":
			if args.is_empty():
				_println("用法：/npc <id>；例如 /npc wu_zhiyuan")
			else:
				_cmd_switch_npc(String(args[0]))
		"reset":
			var scope := String(args[0]).to_lower() if not args.is_empty() else ""
			_cmd_reset(scope)
		"history", "hist":
			_cmd_show_history()
		"memory", "mem":
			_cmd_show_memory()
		"summarize", "summary":
			_cmd_summarize_now()
		"clue":
			if args.is_empty():
				_println("用法：/clue <clue_id>")
			else:
				_cmd_add_clue(String(args[0]))
		"clues":
			_cmd_show_clues()
		"trace":
			var v := String(args[0]).to_lower() if not args.is_empty() else ""
			_cmd_trace_toggle(v)
		"where":
			_cmd_where()
		"provider", "prov":
			_cmd_provider_info()
		_:
			_println("未知命令 `/%s`；`/help` 看命令列表" % cmd)
	_print_prompt()


# ─── 命令实现 ───────────────────────────────────────────────────────

func _cmd_list_npcs() -> void:
	var dir := DirAccess.open("res://data/npcs")
	if dir == null:
		_println("找不到 res://data/npcs 目录")
		return
	dir.list_dir_begin()
	var entries: PackedStringArray = []
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if dir.current_is_dir() or not name.ends_with(".md"):
			continue
		entries.append(name.trim_suffix(".md"))
	dir.list_dir_end()
	entries.sort()
	_println("可用 NPC (%d)：" % entries.size())
	for e in entries:
		var marker := "  * " if String(e) == _current_npc_id else "    "
		_println("%s%s" % [marker, e])


func _cmd_switch_npc(npc_id: String) -> void:
	var md_path := "res://data/npcs/%s.md" % npc_id
	if not FileAccess.file_exists(md_path):
		_println("找不到 %s" % md_path)
		return
	var profile: Dictionary = NpcPersona.load_from_file(md_path)
	if profile.is_empty():
		_println("加载失败：%s" % md_path)
		return
	if profile.get("id", "") == "":
		profile["id"] = npc_id
	_current_profile = profile
	_current_npc_id = String(profile["id"])
	_println("已切换到 NPC：%s（%s）" % [_current_npc_id, profile.get("display_name", "?")])
	if _tracer != null:
		_tracer.call("log_event", "switch_npc", {"npc_id": _current_npc_id})


func _cmd_reset(scope: String) -> void:
	var mem: Node = _get_memory_store()
	if mem == null: return
	if scope == "all":
		mem.reset()
		_println("已清空所有 NPC 的记忆")
		if _tracer != null: _tracer.call("log_event", "reset_all", {})
		return
	if _current_npc_id == "":
		_println("尚未选择 NPC；如需清空所有，用 /reset all")
		return
	mem.clear_history(_current_npc_id)
	var summaries: Dictionary = mem.get("npc_summaries")
	if summaries.has(_current_npc_id):
		summaries.erase(_current_npc_id)
	_println("已清空 %s 的对话历史与记忆摘要" % _current_npc_id)
	if _tracer != null: _tracer.call("log_event", "reset", {"npc_id": _current_npc_id})


func _cmd_show_history() -> void:
	if _current_npc_id == "":
		_println("未选择 NPC")
		return
	var mem: Node = _get_memory_store()
	var hist: Array = mem.get_history(_current_npc_id)
	_println("--- history: %s (%d entries) ---" % [_current_npc_id, hist.size()])
	for entry in hist:
		var role := String(entry.get("role", ""))
		var text := String(entry.get("text", ""))
		_println("  [%s] %s" % [role, text])
	_println("---")


func _cmd_show_memory() -> void:
	if _current_npc_id == "":
		_println("未选择 NPC")
		return
	var mem: Node = _get_memory_store()
	var summary: String = mem.get_summary(_current_npc_id)
	var global_text: String = mem.get_global_memory_text()
	_println("=== NPC 记忆摘要 (%s) ===" % _current_npc_id)
	_println(summary if summary != "" else "(空)")
	_println("=== 全局记忆 ===")
	_println(global_text if global_text != "" else "(空)")


func _cmd_summarize_now() -> void:
	if _current_npc_id == "":
		_println("未选择 NPC")
		return
	var mem: Node = _get_memory_store()
	var svc: Node = _get_llm_service()
	var recent: Array = mem.get_recent_turns_for_summary(_current_npc_id, MemoryStoreScript.SUMMARIZE_EVERY_TURNS)
	if recent.is_empty():
		_println("没有可总结的对话")
		return
	mem.mark_summarize_started(_current_npc_id)
	var previous: String = mem.get_summary(_current_npc_id)
	var profile: Dictionary = _current_profile.duplicate(true)
	profile["id"] = _current_npc_id
	_println("已发起手动记忆总结（%d 条历史送去）……" % recent.size())
	svc.summarize(profile, previous, recent)


func _cmd_add_clue(clue_id: String) -> void:
	# 直接写到 GameState.clues；DialogueUI 里就是把 GameState.clues.keys() 塞 unlocked_clues
	var gs: Node = _get_game_state()
	if gs == null:
		_println("GameState 不可用")
		return
	gs.clues[clue_id] = true
	_println("已解锁线索 `%s`；当前 clues=%s" % [clue_id, str(gs.clues.keys())])
	if _tracer != null: _tracer.call("log_event", "unlock_clue", {"clue_id": clue_id})


func _cmd_show_clues() -> void:
	var gs: Node = _get_game_state()
	if gs == null:
		_println("GameState 不可用")
		return
	_println("已解锁线索：%s" % str(gs.clues.keys()))


func _cmd_trace_toggle(v: String) -> void:
	if _tracer == null:
		_println("tracer 未初始化")
		return
	match v:
		"on", "1", "true":
			_tracer.call("set_enabled", true)
			_println("trace: ON")
		"off", "0", "false":
			_tracer.call("set_enabled", false)
			_println("trace: OFF")
		_:
			_println("用法：/trace on|off")


func _cmd_where() -> void:
	if _tracer == null:
		_println("tracer 未初始化")
		return
	var dirs: Dictionary = _tracer.call("session_dirs")
	_println("Trace 目录:")
	_println("  user://   -> %s" % dirs.get("user", ""))
	_println("  mirror     -> %s" % (dirs.get("mirror", "") if dirs.get("mirror", "") != "" else "(disabled)"))


func _cmd_provider_info() -> void:
	var svc: Node = _get_llm_service()
	if svc == null:
		_println("LLMService 不可用")
		return
	var provider: Node = svc.get("_provider")
	if provider == null:
		_println("no provider")
		return
	# provider 的 name 由 LLMService/LLMConfig 设为 "OpenAILLM" / "MockLLM"
	var info: String = String(provider.name)
	if "model_name" in provider:
		info += "  model=%s  base=%s" % [provider.get("model_name"), provider.get("base_url")]
	if "api_key" in provider:
		var k: String = String(provider.get("api_key"))
		if k.length() >= 8:
			info += "  key=%s...%s" % [k.substr(0, 4), k.substr(k.length() - 4)]
		elif k.length() > 0:
			info += "  key=<%d chars>" % k.length()
		else:
			info += "  key=(empty)"
	_println("Provider: " + info)


# ─── 发送 & 收 LLM 回复 ─────────────────────────────────────────────

func _send_user_turn(user_text: String) -> void:
	var svc: Node = _get_llm_service()
	var mem: Node = _get_memory_store()
	if svc == null or mem == null:
		_println("service/memory 不可用")
		return

	# 复刻 DialogueUI._request_llm 的组装流程：
	# 1) profile 上加 unlocked_clues
	# 2) system_prompt 尾拼上 memory_block
	# 3) history 只送最近 NPC_TURNS_TO_SEND_LLM 轮
	var gs: Node = _get_game_state()
	var request_profile: Dictionary = _current_profile.duplicate(true)
	if gs != null:
		request_profile["unlocked_clues"] = gs.clues.keys()
	var memory_block: String = mem.build_memory_prompt_block(_current_npc_id)
	if memory_block != "":
		request_profile["system_prompt"] = String(request_profile.get("system_prompt", "")) + memory_block

	var history: Array = mem.get_history(_current_npc_id)
	history = _tail_turns(history, MemoryStoreScript.NPC_TURNS_TO_SEND_LLM)

	_current_user_text = user_text
	_stream_shown = false
	_streaming_last_len = 0
	_println("")  # 换行让下面的 NPC 输出干净
	_current_request_id = svc.chat(request_profile, history, user_text, 0, "dialogue")
	if _tracer != null:
		_tracer.call("log_event", "user_send", {
			"npc_id": _current_npc_id,
			"request_id": _current_request_id,
			"user_text": user_text,
			"history_len_sent": history.size(),
			"memory_block_chars": memory_block.length(),
			"unlocked_clues": request_profile.get("unlocked_clues", []),
		})


func _on_reply_chunk(request_id: int, _session_id: int, _npc_id: String, accumulated_text: String) -> void:
	if request_id != _current_request_id:
		return
	if not _stream_shown:
		_stdout("[%s] " % _current_profile.get("short_name", _current_profile.get("display_name", "NPC")))
		_stream_shown = true
	# 只追加新增字符
	if accumulated_text.length() > _streaming_last_len:
		var new_chunk := accumulated_text.substr(_streaming_last_len)
		_streaming_last_len = accumulated_text.length()
		_stdout(new_chunk)


func _on_reply_received(request_id: int, _session_id: int, npc_id: String, reply: Dictionary) -> void:
	if request_id != _current_request_id:
		return
	_current_request_id = 0
	_prompt_shown = false

	# 换行到 stream 之后
	if _stream_shown:
		_println("")
	else:
		# 没走流式（用了 Mock 或者错误路径）：一次性打印
		_println("[%s] %s" % [_current_profile.get("short_name", _current_profile.get("display_name", "NPC")), reply.get("text", "")])

	# 打印结构化字段
	var choices: Variant = reply.get("choices", [])
	if choices is Array and not (choices as Array).is_empty():
		_println("  choices:")
		for c in choices:
			_println("    - " + String(c))
	var check: Dictionary = reply.get("check_request", {})
	if not check.is_empty():
		_println("  check_request: %s" % JSON.stringify(check))
	var meta: Dictionary = reply.get("meta", {})
	if not meta.is_empty() and _meta_nonzero(meta):
		_println("  meta: %s" % JSON.stringify(meta))
	var mood: String = String(reply.get("mood", ""))
	if mood != "":
		_println("  mood: %s" % mood)

	# tracer：解析后的最终 reply
	if _tracer != null:
		_tracer.call("log_chat_final_reply", request_id, npc_id, reply)

	# 复刻 DialogueUI 的记忆写入
	var mem: Node = _get_memory_store()
	var npc_text := String(reply.get("text", ""))
	var choice_list: Array = []
	if choices is Array:
		for c in choices:
			choice_list.append(String(c))
	if mem != null and npc_text.strip_edges() != "":
		mem.append_turn(npc_id, _current_user_text, npc_text, choice_list)
	_current_user_text = ""

	# 应用 meta 的 pollution/affinity/item/clue（跟 DialogueUI 里一样，让它们真正影响后续对话）
	_apply_meta_to_gamestate(meta)

	# 记忆总结阈值到了就自动触发
	_maybe_trigger_summary(npc_id)

	_print_prompt()


func _on_reply_failed(request_id: int, _session_id: int, npc_id: String, error: String) -> void:
	if request_id != _current_request_id:
		return
	_current_request_id = 0
	_prompt_shown = false
	if _stream_shown:
		_println("")
	_println("[LLM 失败] %s: %s" % [npc_id, error])
	if _tracer != null:
		_tracer.call("log_chat_failure", request_id, npc_id, error)
	_print_prompt()


func _on_summary_ready(npc_id: String, summary: String) -> void:
	var mem: Node = _get_memory_store()
	if mem == null: return
	mem.mark_summarize_finished(npc_id, true)
	mem.set_summary(npc_id, summary)
	_println("  [summary ✓] %s: %s" % [npc_id, _truncate(summary, 80)])
	if _tracer != null:
		_tracer.call("log_summary_result", npc_id, true, summary)


func _on_summary_failed(npc_id: String, error: String) -> void:
	var mem: Node = _get_memory_store()
	if mem != null:
		mem.mark_summarize_finished(npc_id, false)
	_println("  [summary ✗] %s: %s" % [npc_id, error])
	if _tracer != null:
		_tracer.call("log_summary_result", npc_id, false, error)


func _maybe_trigger_summary(npc_id: String) -> void:
	var mem: Node = _get_memory_store()
	var svc: Node = _get_llm_service()
	if mem == null or svc == null:
		return
	if not mem.should_summarize(npc_id):
		return
	var recent: Array = mem.get_recent_turns_for_summary(npc_id, MemoryStoreScript.SUMMARIZE_EVERY_TURNS)
	if recent.is_empty():
		return
	mem.mark_summarize_started(npc_id)
	var previous: String = mem.get_summary(npc_id)
	var profile: Dictionary = _current_profile.duplicate(true)
	profile["id"] = npc_id
	_println("  [summary…] 触发记忆总结（%d 条）" % recent.size())
	svc.summarize(profile, previous, recent)


func _apply_meta_to_gamestate(meta: Dictionary) -> void:
	## 仅在 CLI 里做记录，让 clues 和 affinity 能持续影响后续对话；
	## 不去动 pollution UI 之类的东西。
	if meta.is_empty():
		return
	var gs: Node = _get_game_state()
	if gs == null:
		return
	var clue_id := String(meta.get("clue_id", ""))
	if clue_id != "" and not gs.clues.has(clue_id):
		gs.clues[clue_id] = true
		_println("  [meta] 解锁线索 `%s`" % clue_id)
	var aff_delta := int(meta.get("affinity_delta", 0))
	if aff_delta != 0 and _current_npc_id != "":
		gs.affinity[_current_npc_id] = int(gs.affinity.get(_current_npc_id, 0)) + aff_delta
		_println("  [meta] %s affinity %+d -> %d" % [_current_npc_id, aff_delta, gs.affinity[_current_npc_id]])
	var give_item := String(meta.get("give_item", ""))
	if give_item != "" and not gs.inventory.has(give_item):
		gs.inventory.append(give_item)
		_println("  [meta] 获得物品 `%s`" % give_item)
	var poll_delta := int(meta.get("pollution_delta", 0))
	if poll_delta != 0:
		gs.pollution += poll_delta
		_println("  [meta] pollution %+d -> %d" % [poll_delta, gs.pollution])


# ─── Tracer 桥接 ─────────────────────────────────────────────────────
# 把 OpenAILLM 的 tracer 钩子转成 TraceLogger 的方法。
# 之所以套一层：TraceLogger 需要额外上下文（memory_block/history_len/user_text），
# 而 provider 只知道 sent_messages。我们在这里做拼装。

func _install_tracer_on_provider() -> void:
	var svc: Node = _get_llm_service()
	if svc == null: return
	var provider: Node = svc.get("_provider")
	if provider == null: return
	if "tracer" in provider:
		provider.set("tracer", self)
	# 如果之后 LLMConfig 又切了 provider，这里没监听信号；不过 headless 里通常只切一次。


## OpenAILLM 会调这个方法（跟 TraceLogger 约定的方法名一致）。
func on_chat_request(request_id: int, npc_profile: Dictionary, sent_messages: Array, sent_payload: Dictionary, provider_info: Dictionary) -> void:
	if _tracer == null: return
	var mem: Node = _get_memory_store()
	var memory_block: String = mem.build_memory_prompt_block(_current_npc_id) if mem != null else ""
	var history: Array = mem.get_history(_current_npc_id) if mem != null else []
	_tracer.call("log_chat_request", request_id, npc_profile, memory_block, history, _current_user_text, provider_info, sent_messages, sent_payload)


func on_chat_raw_response(request_id: int, npc_id: String, http_status: int, raw_text: String, latency_ms: int) -> void:
	if _tracer == null: return
	_tracer.call("log_chat_raw_response", request_id, npc_id, http_status, raw_text, latency_ms)


func on_summary_request(npc_id: String, previous_summary: String, recent_turns: Array, sent_messages: Array) -> void:
	if _tracer == null: return
	_tracer.call("log_summary_request", npc_id, previous_summary, recent_turns, sent_messages)


func on_summary_raw_response(npc_id: String, http_status: int, raw_text: String, latency_ms: int) -> void:
	if _tracer == null: return
	_tracer.call("log_event", "summary_raw_response", {
		"npc_id": npc_id,
		"http_status": http_status,
		"latency_ms": latency_ms,
		"raw": raw_text,
	})


# ─── 引导 & 工具函数 ─────────────────────────────────────────────────

func _bootstrap_default_npc() -> void:
	# 优先 wu_zhiyuan
	for candidate in ["wu_zhiyuan", "lin_deshan"]:
		var path := "res://data/npcs/%s.md" % candidate
		if FileAccess.file_exists(path):
			_cmd_switch_npc(candidate)
			return


func _get_llm_service() -> Node:
	return root.get_node_or_null("LLMService")


func _get_memory_store() -> Node:
	return root.get_node_or_null("MemoryStore")


func _get_game_state() -> Node:
	return root.get_node_or_null("GameState")


func _tail_turns(entries: Array, max_turns: int) -> Array:
	var kept_pairs := 0
	for i in range(entries.size() - 1, -1, -1):
		if String((entries[i] as Dictionary).get("role", "")) == "user":
			kept_pairs += 1
			if kept_pairs > max_turns:
				return entries.slice(i + 1)
	return entries


func _meta_nonzero(meta: Dictionary) -> bool:
	for k in ["pollution_delta", "affinity_delta"]:
		if int(meta.get(k, 0)) != 0:
			return true
	for k in ["clue_id", "give_item"]:
		if String(meta.get(k, "")) != "":
			return true
	return false


func _truncate(s: String, n: int) -> String:
	if s.length() <= n: return s
	return s.substr(0, n) + "…"


func _print_help() -> void:
	_println("命令：")
	_println("  /npc <id>          切换 NPC          /npcs 列出可用 NPC")
	_println("  /history           查看当前 NPC 对话历史")
	_println("  /memory            查看当前记忆摘要 + 全局记忆")
	_println("  /summarize         手动触发记忆总结")
	_println("  /reset [all]       清空当前 NPC 记忆 / all=全部")
	_println("  /clue <id>         手动解锁线索       /clues 已解锁列表")
	_println("  /trace on|off      trace 开关         /where 打印 trace 目录")
	_println("  /provider          当前 LLM Provider 信息")
	_println("  /quit              退出")
	_println("  直接输入文本 = 玩家发言")


func _print_prompt() -> void:
	var tag := _current_npc_id if _current_npc_id != "" else "no-npc"
	_stdout("\n(%s) > " % tag)


func _println(s: String) -> void:
	print(s)


func _stdout(s: String) -> void:
	# print 不带换行的等价物：直接输出到 stdout
	printraw(s)
