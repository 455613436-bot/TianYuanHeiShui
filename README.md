# TianYuanHeiShui / 思源村探案

基于田原村设定的 Godot 叙事探案游戏。项目包含多地点探索、时间推进、NPC 对话、线索册、物品与技能检定，以及基于披露等级的 LLM NPC 剧情系统。

## 运行

需要 **Godot 4.7**（`project.godot` 中声明的引擎版本）。用 Godot 打开项目后按 `F5` 运行，按 `F6` 运行当前场景。首次启动会导入资源，耗时较长属正常。


## 主要目录

- `data/`：NPC、物品、线索、技能与地点数据。
- `scenes/`：标题、地图、地点与界面场景。
- `scripts/autoload/`：游戏状态、时间、NPC、物品、线索与技能系统。
- `scripts/llm/`：LLM 对话、披露等级与固定剧情事件系统。
- `scripts/locations/`：场景遮罩热点与地点交互。

## LLM 配置（拉下来想跑真实 NPC 对话必看）

### 1. 文件放在哪个目录

**项目根目录** —— 也就是和 `project.godot` 同级的那个目录：

```
siyuan-mystery/
  project.godot
  llm_config.json   ← 就放这里
```

仓库里已经带了一份 `llm_config.json` 模板（Key 是占位值），clone 下来直接改那一行就能跑。

> 读不到配置时游戏不会报错，只是继续用 `MockLLM`，控制台会打印 `[LLMConfig] 未检测到任何 LLM 配置`。

### 2. 文件格式

推荐写法（只写 provider 和 key，地址与模型用默认值）：

```json
{
  "provider": "qwen",
  "api_key": "在这里填你自己的 API Key"
}
```

要换模型或地址时才写全：

```json
{
  "provider": "qwen",
  "api_key": "在这里填你自己的 API Key",
  "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
  "model": "qwen-flash"
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `provider` | 否 | 预设名，见第 3 节。写成预设名时可省略 `base_url` / `model`，会自动补默认值 |
| `api_key` | 是 | 你的 API Key。**留空则整份配置被忽略**，退回 MockLLM |
| `base_url` | 否 | OpenAI Chat Completions 兼容地址（含末尾的 `/v1`），留空取 `provider` 的预设值 |
| `model` | 否 | 模型名，留空取 `provider` 的预设值 |

启动后看控制台确认是否读到：

```
[LLMConfig] 检测到配置文件: res://llm_config.json
[LLMConfig] Provider -> OpenAI 兼容: https://dashscope.aliyuncs.com/compatible-mode/v1 (qwen-flash)
```

### 3. Provider 选择：建议用 qwen

**推荐 `qwen`（通义千问），这是目前唯一完整实测跑通过的 provider。** 默认走 `https://dashscope.aliyuncs.com/compatible-mode/v1`，默认模型 `qwen-flash`。

代码里还内置了下面这些预设（定义在 `scripts/autoload/LLMConfig.gd` 的 `PRESETS` 常量），但**都还没有经过实测**，用之前请自行验证，遇到问题欢迎提 issue：

| provider | 默认 base_url | 默认模型 | 状态 |
| --- | --- | --- | --- |
| `qwen` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-flash` | ✅ 已实测 |
| `deepseek` | `https://api.deepseek.com/v1` | `deepseek-chat` | ⚠️ 未测试 |
| `openai` | `https://api.openai.com/v1` | `gpt-4o-mini` | ⚠️ 未测试 |
| `glm` | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` | ⚠️ 未测试 |
| `moonshot` | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` | ⚠️ 未测试 |
| `ollama` | `http://localhost:11434/v1` | `qwen2.5:7b` | ⚠️ 未测试 |

理论上任何兼容 OpenAI `/chat/completions` 协议的服务都能接（把 `provider` 写成 `openai_compatible`，再手动填 `base_url` 和 `model`），但同样没有实测覆盖。

### 4. 要改默认值，去哪里改

| 想改什么 | 改哪里 |
| --- | --- |
| 增删 provider 预设、改默认 `base_url` / `model` | `scripts/autoload/LLMConfig.gd` 的 `PRESETS` 常量 |
| 改请求超时、响应体大小上限、请求协议细节 | `scripts/llm/OpenAILLM.gd`（顶部 `@export` 变量） |
| 运行期临时切换 provider（调试脚本 / CLI） | 调用 `LLMConfig.apply_openai_compatible("<key>", "<base_url>", "<model>")`；切回 Mock 用 `LLMConfig.apply_mock()` |

### 5. 别把你的 Key 提交上去

仓库里的 `llm_config.json` 是**占位模板**。填入真实 Key 后，`git status` 会看到它被修改，此时**不要 `git add` 它**。

省事的做法是让 Git 忽略本地改动：

```bash
git update-index --skip-worktree llm_config.json
```

这样你可以正常改 Key、正常 `git add .`，Git 也不会把它带进提交。要恢复跟踪就执行 `git update-index --no-skip-worktree llm_config.json`。

`.gitignore` 里额外忽略了 `llm_config.local.json`，需要单独保管真实配置时可以放这个文件（游戏不读它，仅作本地备份）。

万一 Key 真的被提交上去了，别只删文件，直接去服务商后台吊销重新生成一个。
