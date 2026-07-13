# NPC 对话系统 Bug 修复记录

## 基本信息

- 修复日期：2026-07-13
- 验证环境：Godot 4.7 Stable，Windows
- 修复范围：此前问题清单中的第 1、2、5 项
- 修复状态：代码已修改并通过无界面启动验证，尚未创建 Git 提交

## 修复摘要

| 编号 | 问题 | 主要影响 | 状态 |
| --- | --- | --- | --- |
| 1 | Markdown few-shot 解析失败 | NPC 开场、示例对话和 Mock 回复失效 | 已修复 |
| 2 | 当前玩家消息重复发送给真实 LLM | 模型重复理解问题，浪费 Token | 已修复 |
| 5 | 对话期间可移动、切换 NPC，迟到回复可能污染当前会话 | UI 状态与 NPC 上下文错位 | 已修复 |

## 1. 修复 Markdown few-shot 解析

### 问题现象

NPC 使用 `data/npcs/*.md` 加载人设时，`Few-shot 对话样例` 无法正确生成消息列表。可能表现为：

- NPC 开场只显示“……”；
- MockLLM 无法匹配示例问答；
- 真实 LLM 能回复，但没有收到设计好的示例对话，角色稳定性降低。

### 根因

`NpcPersona._parse_fewshots()` 使用 Lambda 作为 `flush` 函数。GDScript 的局部变量在 Lambda 创建时按值捕获，后续在外层修改 `mode` 不会更新 Lambda 内捕获的值。

因此 Lambda 一直读取到初始空字符串 `mode`，缓冲内容没有被写入 `fewshots`。

### 修复方式

- 删除捕获 `mode` 和 `buf` 的局部 Lambda；
- 新增 `_append_fewshot(out, mode, buf)` 静态辅助函数；
- 每次切换 user/assistant 模式时显式提交旧缓冲区；
- 提交后显式重置 `PackedStringArray`。

### 修改文件

- `scripts/llm/NpcPersona.gd`

## 2. 修复当前消息重复发送

### 问题现象

玩家发送一句话后，OpenAI 兼容接口收到两条内容相同的 user 消息。

### 根因

调用链原来是：

1. `DialogueUI` 先把当前玩家输入加入 UI 的 `history`；
2. `DialogueUI` 把包含当前输入的完整历史传给 `LLMService`；
3. `OpenAILLM._build_messages()` 再把独立参数 `user_text` 追加一次。

最终请求类似：

```text
user: 河水是不是被污染了？
user: 河水是不是被污染了？
```

### 修复方式

`DialogueUI._request_llm()` 现在创建独立的 `request_history`：

- 去掉只用于界面显示的“正在思考”系统消息；
- 如果历史末尾就是当前玩家输入，将其从请求历史中移除；
- 当前输入仅通过 `user_text` 交给 Provider 追加一次。

UI 显示历史保持不变，修复只影响发给模型的消息数组。

### 修改文件

- `scripts/ui/DialogueUI.gd`

## 3. 修复对话状态与异步回复错位

### 问题现象

原实现中，对话窗口打开后玩家仍能移动。等待大模型回复时还可以离开并与其他 NPC 对话，旧请求返回后可能：

- 取消新会话的超时计时器；
- 删除新会话的“正在思考”提示；
- 把新会话错误地恢复为可输入状态；
- 造成 NPC 上下文错位或回复被忽略。

### 修复方式

本次增加了多层防护：

1. `DialogueUI` 提供 `is_open()` 状态查询；
2. 对话已打开时，`open_dialogue()` 拒绝再次覆盖当前 NPC；
3. `Player` 检测到对话打开后，将速度归零并停止处理交互键；
4. `NpcInteractable` 在 UI 已打开时不再启动新对话；
5. `_on_llm_reply()` 和 `_on_llm_failed()` 在操作 UI 前核对 `npc_id`；
6. 等待 LLM 回复和打字机输出期间禁用“离开”按钮，回复完成或失败后恢复。

### 修改文件

- `scripts/entities/Player.gd`
- `scripts/entities/NpcInteractable.gd`
- `scripts/ui/DialogueUI.gd`

## 验证记录

执行了以下检查：

```powershell
git diff --check
Godot_v4.7-stable_win64.exe --headless --path . --quit-after 3
```

验证结果：

- Godot 4.7 正常启动；
- `Main.tscn` 正常加载；
- 两名 NPC 均从 Markdown 人设加载；
- 默认 MockLLM 正常初始化；
- `llm_config.json` 被检测后正常切换到 OpenAI 兼容 Provider；
- 没有 GDScript 编译错误或场景加载错误；
- 四个目标脚本通过 `git diff --check`。

无界面启动只验证编译、初始化和场景加载，不会主动向 LLM API 发送对话请求。

## 建议的人工回归测试

1. 打开游戏，分别靠近村长和河边老大爷，确认开场不再只有“……”；
2. 连续进行两轮对话，确认模型能够结合上一轮内容回答；
3. 对话窗口打开时按 WASD，确认玩家位置不变；
4. 等待回复时确认发送、动作和离开按钮均不可点击；
5. 回复完成后确认输入和离开按钮恢复；
6. 关闭对话后确认玩家能够继续移动并与另一名 NPC 交互；
7. 测试接口超时或错误，确认 30 秒兜底后输入功能恢复。

## 本次未包含的内容

以下项目属于未完成功能或独立工程问题，不在本次修复范围：

- 污染度触发规则和正式结局流程；
- 将 `GameState.summary_for_llm()` 注入大模型 Prompt；
- Godot MCP 标准 JSON-RPC 路由与网络安全加固；
- README 合并冲突和项目命名整理；
- 存档、任务、职业技能和物品选择系统。

## 配置与提交注意事项

- `llm_config.json` 已被 `.gitignore` 忽略，不应强制加入 Git；
- 提交前使用 `git status` 检查暂存区；
- `project.godot` 在修复前已经存在用户修改，本次修复没有主动改动该文件。

建议提交信息：

```text
fix: 修复 NPC 对话解析、重复请求和状态错位
```
