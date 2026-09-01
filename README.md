# TianYuanHeiShui / 思源村探案

基于田原村设定的 Godot 叙事探案游戏。项目包含多地点探索、时间推进、NPC 对话、线索册、物品与技能检定，以及基于披露等级的 LLM NPC 剧情系统。

## 运行

需要 **Godot 4.7**（`project.godot` 中声明的引擎版本）。用 Godot 打开项目后按 `F5` 运行，按 `F6` 运行当前场景。首次启动会导入资源，耗时较长属正常。

不配置 LLM 也能正常游玩，只是 NPC 对话会走内置的 `MockLLM`（固定脚本回复）。想让 NPC 真正由大模型驱动，请看下面的「LLM 配置」。

## 主要目录

- `data/`：NPC、物品、线索、技能与地点数据。
- `scenes/`：标题、地图、地点与界面场景。
- `scripts/autoload/`：游戏状态、时间、NPC、物品、线索与技能系统。
- `scripts/llm/`：LLM 对话、披露等级与固定剧情事件系统。
- `scripts/locations/`：场景遮罩热点与地点交互。

## LLM 配置（拉下来想跑真实 NPC 对话必看）

从仓库 clone 下来后，项目里**没有** `llm_config.json` —— 它已被 `.gitignore` 忽略，因为里面要放 API Key。需要你自己新建。

### 1. 文件放在哪个目录

启动时按以下顺序查找，**命中第一个就停止**：

| 优先级 | 位置 | 说明 |
| --- | --- | --- |
| 1 | `siyuan-mystery/llm_config.json`（项目根目录，与 `project.godot` 同级，即 `res://llm_config.json`） | 最省事，推荐。本项目 `.gitignore` 已忽略它 |
| 2 | Godot 用户目录 `user://llm_config.json` | 跨项目共用。Windows：`%APPDATA%\Godot\app_userdata\思源村探案\llm_config.json`；macOS：`~/Library/Application Support/Godot/app_userdata/思源村探案/`；Linux：`~/.local/share/godot/app_userdata/思源村探案/` |
| 3 | 环境变量 | 见第 4 节，不需要建文件 |

> 两处文件同时存在时，项目根目录下的那份优先。
> 三个来源都没命中时，游戏不会报错，只是继续用 `MockLLM`，控制台会打印 `[LLMConfig] 未检测到任何 LLM 配置`。

### 2. 文件格式

最小写法（只指定 provider 和 key，地址与模型用默认值）：

```json
{ "provider": "qwen", "api_key": "在这里填你自己的 API Key" }
```

完整写法：

```json
{
  "provider": "deepseek",
  "api_key": "在这里填你自己的 API Key",
  "base_url": "https://api.deepseek.com/v1",
  "model": "deepseek-chat"
}
```

字段说明：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `provider` | 否 | 预设名，见第 3 节。写成预设名时可省略 `base_url` / `model`，会自动补默认值；写成 `openai_compatible` 或任意非预设值时，必须自己填全 `base_url` 和 `model` |
| `api_key` | 是 | 你的 API Key。**留空则整份配置被忽略**，退回 MockLLM |
| `base_url` | 否 | OpenAI Chat Completions 兼容地址（含末尾的 `/v1`）。留空取 `provider` 预设值；仍为空则退回 DeepSeek |
| `model` | 否 | 模型名。留空时规则同上 |

启动后看控制台输出确认是否读到：

```
[LLMConfig] 检测到配置文件: res://llm_config.json
[LLMConfig] Provider -> OpenAI 兼容: https://api.deepseek.com/v1 (deepseek-chat)
```

### 3. 可用的 provider 与默认模型

预设定义在 `scripts/autoload/LLMConfig.gd` 的 `PRESETS` 常量中：

| provider | 默认 base_url | 默认模型 |
| --- | --- | --- |
| `deepseek` | `https://api.deepseek.com/v1` | `deepseek-chat` |
| `openai` | `https://api.openai.com/v1` | `gpt-4o-mini` |
| `qwen` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-flash` |
| `glm` | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| `moonshot` | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| `ollama` | `http://localhost:11434/v1` | `qwen2.5:7b` |

任何兼容 OpenAI `/chat/completions` 协议的服务都能接：把 `provider` 写成 `openai_compatible`，再手动填 `base_url` 和 `model` 即可。

### 4. 不想建文件：用环境变量

找不到任何配置文件时，会依次检查以下环境变量，命中即按同名预设装载：

`DEEPSEEK_API_KEY`、`OPENAI_API_KEY`、`QWEN_API_KEY`、`GLM_API_KEY`、`MOONSHOT_API_KEY`

```powershell
$env:QWEN_API_KEY = "sk-xxxxxxxx"
# 然后在同一个终端里启动游戏
```

### 5. 要改默认值，去哪里改

| 想改什么 | 改哪里 |
| --- | --- |
| 增删 provider 预设、改默认 `base_url` / `model` | `scripts/autoload/LLMConfig.gd` 的 `PRESETS` 常量 |
| 改配置文件的查找顺序、新增环境变量名 | `scripts/autoload/LLMConfig.gd` 的 `_auto_detect_and_apply()` |
| 改请求超时、响应体大小上限、请求协议细节 | `scripts/llm/OpenAILLM.gd`（顶部 `@export` 变量） |
| 运行期临时切换 provider（调试脚本 / CLI） | 调用 `LLMConfig.apply_openai_compatible("<key>", "<base_url>", "<model>")`；切回 Mock 用 `LLMConfig.apply_mock()` |

### 6. 安全提醒

- `llm_config.json` 已在 `.gitignore` 中，**不要把 API Key 提交到仓库**。
- 打包分享或拷贝项目目录前，先删掉或移走这个文件。
- 误提交过 Key 的话，请直接去服务商后台吊销重新生成。
