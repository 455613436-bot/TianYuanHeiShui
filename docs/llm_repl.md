# LLM 对话调试 REPL

不用启动游戏、不用进对话场景，直接在终端里跟 NPC 对话，用于快速调 prompt / 检定 / 记忆效果。

## 一句话原理

用 Godot 的 `--headless --script` 模式跑起来，**直接复用游戏里已有的
`LLMConfig` / `LLMService` / `MemoryStore` / `GameState` / `NpcPersona` /
`SuggestionGuard`**。也就是说：这个 REPL 里发出去的每一次请求，
和你在游戏里点击"发送"发出去的，**是同一份代码组装的 prompt / 处理的响应 / 更新的记忆**。

## 启动

```powershell
# 项目根目录下
.\tools\llm_repl.bat
# 或者
powershell -ExecutionPolicy Bypass -File .\tools\llm_repl.ps1
```

如果你要手工敲命令：

```powershell
# 用你 Downloads 里那个 4.7.1 主 exe
& "$env:USERPROFILE\Downloads\Godot_v4.7.1-stable_win64.exe" `
	--headless --path .\siyuan-mystery `
	--script res://scripts/tools/llm_repl.gd

# 或者用 godot-editor/ 下的老 4.6 console.exe
.\godot-editor\Godot_v4.6-stable_win64_console.exe `
	--headless --path .\siyuan-mystery `
	--script res://scripts/tools/llm_repl.gd
```

### Godot 版本

- 项目 `project.godot` 的 `config/features` 写着 **4.7**，所以 4.7.x 是"官方推荐"版本。
- 4.6 也能跑（会给一堆 "downgrade" 提示，但不影响 REPL）。
- REPL 用到的 API（`OS.read_string_from_stdin` / `HTTPRequest` / `SceneTree` / autoload）在 4.6 → 4.7 之间**没有 breaking change**，换版本不用改代码。

`tools/llm_repl.bat` / `.ps1` 会按下面顺序自动挑一个 exe，找到就用：

1. 环境变量 `GODOT_EXE`（临时切版本最方便）
2. `%USERPROFILE%\Downloads\Godot_v4.7.1-stable_win64.exe`
3. `godot-editor\Godot_v4.7.1-stable_win64_console.exe`
4. `godot-editor\Godot_v4.7-stable_win64_console.exe`
5. `godot-editor\Godot_v4.6-stable_win64_console.exe`

想强制指定一个版本，一次性覆盖：

```powershell
$env:GODOT_EXE = "C:\Users\me\Downloads\Godot_v4.7.1-stable_win64.exe"
.\tools\llm_repl.bat
```

### Console vs 主 exe

Windows 下 Godot 发行版有两个 exe：

- `Godot_v4.7.1-stable_win64.exe` — 主 exe，无控制台窗口。**加了 `--headless` 一般也能挂到当前 PowerShell/cmd 的 stdin/stdout**，如果实测输入没反应或看不到输出，再换 console 版。
- `Godot_v4.7.1-stable_win64_console.exe` — 附带控制台。**stdin/stdout 一定稳定挂到当前终端**，最保险。

如果你只有主 exe，先试试看能不能跑；有问题就去 [godotengine.org](https://godotengine.org/download/windows/) 下 console 版。

启动时它会：

1. 加载所有 autoload（`GameState` / `MemoryStore` / `LLMService` / `LLMConfig` / `CheckSystem`）
2. 等 `LLMConfig` 完成 API Key 探测（读 `siyuan-mystery/llm_config.json` 或环境变量）
3. 打印当前 provider 信息（`OpenAILLM  model=qwen-flash  base=...  key=xxxx...yyyy`）
4. 自动载入 `data/npcs/wu_zhiyuan.md`（找不到时退回 `lin_deshan.md`）

之后就是提示符：

```
(wu_zhiyuan) >
```

直接打字就是玩家发言；`/xxx` 是命令。

## 命令

| 命令 | 说明 |
| --- | --- |
| `/help` | 打印命令帮助 |
| `/npcs` | 列出 `data/npcs` 下可用 NPC |
| `/npc <id>` | 切换到指定 NPC，例如 `/npc lin_deshan` |
| `/history` | 打印当前 NPC 完整的对话历史（进 LLM 请求时会送去的那一份） |
| `/memory` | 打印当前 NPC 的记忆摘要 + 全局记忆 |
| `/summarize` | 手动触发一次记忆总结（不用等自动的 5 轮阈值） |
| `/reset` | 清空当前 NPC 的历史 + 记忆摘要 |
| `/reset all` | 清空所有 NPC 的记忆 |
| `/clue <id>` | 手动解锁一条线索（作用等同于游戏里 `GameState.clues[id]=true`，会立刻影响之后请求的 `unlocked_clues` 字段） |
| `/clues` | 列出当前已解锁的线索 id |
| `/trace on` / `/trace off` | 开/关本次会话的 trace 落盘 |
| `/where` | 打印本次 trace 目录路径（`user://` + 项目根 mirror） |
| `/provider` | 打印当前 LLM Provider 的 model / base_url / key 头尾 |
| `/quit` 或 `/exit` | 退出 |

## 交互示例

```
(wu_zhiyuan) > 您好，我是刚到村里来的研究员。

[村长老吴] 哎哟，欢迎欢迎！你们打哪儿来的呀？
  choices:
    - 我们从省城来做水质调查。
    - 只是路过，想找地方歇歇脚。
    - 您就是村长？
  mood: happy

(wu_zhiyuan) > 我想看看你保险柜里有什么。

[村长老吴] （对方脸上的笑容凝固了一下，粗糙的手指反复摩挲着烟斗……）
  choices:
    - 我保证不会告诉别人。
    - 我们只是想帮村里。
    - 那算了，抱歉冒犯。
  check_request: {"attribute":"魅力","difficulty":22,"reason":"要求查看私密物品"}
  meta: {"pollution_delta":0,"affinity_delta":-1,"clue_id":"wu_hides_gun","give_item":""}
  mood: thinking

  [summary…] 触发记忆总结（10 条）
  [summary ✓] wu_zhiyuan: 一个陌生的外乡研究员来到村里，表现出对水质的兴趣，并且直接...
```

从这个片段能看到：
- **检定被触发**：因为在 profile 的"信息透露分级"里，看保险柜属 L3
- **meta 命中 keyword**：`wu_hides_gun` 线索被解锁、affinity -1（都是 `NPC.triggers` 里配的）
- **记忆自动总结**：MemoryStore 每 5 轮自动触发一次，与游戏里完全同步

## Trace 文件在哪

每次启动都会新建一个 session 目录，同时落两份：

- **`user://llm_trace/<时间戳>/`** — Godot 的 user 目录
	- Windows：`%APPDATA%\Godot\app_userdata\思源村探案\llm_trace\`
- **`siyuan-mystery/llm_trace/<时间戳>/`** — 项目根旁边的 mirror，便于直接翻看

每个 session 目录里：

```
session.log.jsonl        每一步的 JSONL 事件（含完整 messages / raw response）
turn_001.md              第一轮的人类可读版：memory_block + 全部 sent messages + raw + parsed reply
turn_002.md              ...
summary_001.md           每次记忆总结的送去 messages + 生成结果
```

**`turn_XXX.md` 的结构**（你调试时主要看这个）：

```markdown
# Turn 3 — 2026-07-23T18:23:47
- NPC: **村长 吴志源** (`wu_zhiyuan`)
- request_id: `4`
- provider: `OpenAILLM` @ `https://dashscope.aliyuncs.com/compatible-mode/v1` model=`qwen-flash`
- 玩家输入: `我想看看你保险柜里有什么。`

## 记忆块（拼在 system_prompt 尾部）
...

## Sent Messages (顺序 = 实际请求体)
### [0] role=system
...（NpcPersona 拼的人设 + OpenAILLM._build_messages 里那堆检定/分级/口吻规则 + 记忆块）...
### [1] role=user
（few-shot 玩家示例）
### [2] role=assistant
（few-shot NPC 示例，被压成 {"text":"..."} 一行）
...
### [N] role=user
我想看看你保险柜里有什么。

【系统补充】你上一轮说过：「...」。本轮请换一种措辞...

## Raw Response (HTTP 200, 3450ms)
{"id":"...","choices":[{"message":{"content":"{\"check_request\":..."}}...

## Final Parsed Reply (meta 已合并)
{
  "text": "...",
  "choices": [...],
  "check_request": {...},
  "meta": {...}
}
```

也就是说，**"prompt 是什么组成的" / "工具调用的细节" / "LLM 原文" / "解析后的字段" / "meta 是怎么算出来的"** 全都能在 turn markdown 里对上号，非常方便定位是 prompt 写歪了、还是 SuggestionGuard 过滤过头了、还是 LLM 输出不符合契约。

## 常见问题

**Q: 我改了 `data/npcs/wu_zhiyuan.md`，要重新启动 REPL 吗？**

A: 是的，或者用 `/npc wu_zhiyuan` 再切一次就能重新载入。REPL 内部通过 `NpcPersona.load_from_file()` 载入，跟游戏走同一份代码，所以你在这里验证过没问题的 md，直接进游戏一定能跑。

**Q: 记忆写到哪里去了？会影响正式游戏存档吗？**

A: 记忆在 `MemoryStore` 单例的内存里；REPL 退出后就丢掉，**不会**写到游戏存档
（`GameState.save_game()` 才写，REPL 从不调它）。你可以放心地用 `/reset all` 或者反复重启。

**Q: 我想用一个只是测试用的 API Key，不动 `llm_config.json`？**

A: 用环境变量：`$env:QWEN_API_KEY = "sk-xxx"` 然后启动 REPL。`LLMConfig` 优先级是
`res://llm_config.json` > `user://llm_config.json` > 环境变量，所以要走环境变量得先把
`siyuan-mystery/llm_config.json` 挪走或改名。

**Q: 我改动了 `OpenAILLM.gd` 里 `_build_messages()`，怎么快速验证 prompt 变化？**

A: 直接 `/reset` 清掉当前 NPC 记忆，然后重打一句同样的话，去看新 session 的
`turn_001.md` 对比前一次 session 的 `turn_001.md`，两个 system message 一 diff 就知道差异。
