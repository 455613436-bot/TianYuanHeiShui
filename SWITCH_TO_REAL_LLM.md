# 拿到 API Key 后如何切换到真实大模型

> 三种方式，任选其一。**推荐方式 A**：一次配置，永久生效，不用改代码。

---

## 方式 A（推荐）：写用户配置文件

### 1. 找到用户配置目录

Godot 会把 `user://` 映射到系统的 app_userdata 目录：

**Windows**: `%APPDATA%\Godot\app_userdata\思源村探案\`

复制粘贴到资源管理器地址栏就能打开。如果目录不存在，先启动一次游戏就会自动创建。

### 2. 在该目录下创建 `llm_config.json`

选一家你有 Key 的服务商，复制对应模板：

**DeepSeek**（中文角色扮演优秀，便宜，推荐）：
```json
{
  "provider": "deepseek",
  "api_key": "sk-你的-deepseek-key"
}
```

**OpenAI**（原版 GPT）：
```json
{
  "provider": "openai",
  "api_key": "sk-你的-openai-key",
  "model": "gpt-4o-mini"
}
```

**通义千问**（阿里）：
```json
{
  "provider": "qwen",
  "api_key": "sk-你的-dashscope-key",
  "model": "qwen-plus"
}
```

**智谱 GLM**：
```json
{
  "provider": "glm",
  "api_key": "你的-zhipu-key",
  "model": "glm-4-flash"
}
```

**本地 Ollama**（免费，需自己跑）：
```json
{
  "provider": "ollama",
  "api_key": "ollama",
  "model": "qwen2.5:7b"
}
```

**任何其它 OpenAI 兼容 endpoint**（比如公司代理、自建）：
```json
{
  "provider": "openai_compatible",
  "api_key": "your-key",
  "base_url": "https://your-endpoint/v1",
  "model": "your-model-name"
}
```

### 3. 重启游戏

游戏启动时会打印一行：
```
[LLMConfig] 检测到 user://llm_config.json
[LLMConfig] Provider -> OpenAI 兼容: https://api.deepseek.com/v1 (deepseek-chat)
```

看到这句就 OK 了，接下来所有 NPC 对话会走真实大模型。

---

## 方式 B：环境变量（临时 / 命令行）

不想留文件，或者只是想测一下：

**PowerShell**（Windows）：
```powershell
$env:DEEPSEEK_API_KEY = "sk-xxx"
# 然后重启游戏
```

支持的环境变量名（按优先级）：
`DEEPSEEK_API_KEY` → `OPENAI_API_KEY` → `QWEN_API_KEY` → `GLM_API_KEY` → `MOONSHOT_API_KEY`

第一个不为空的会被自动装载。

---

## 方式 C：代码里手动切换

编辑 `scripts/Main.gd`，在 `_ready()` 里加：

```gdscript
LLMConfig.apply_openai_compatible(
    "sk-xxx",                              # api_key
    "https://api.deepseek.com/v1",         # base_url
    "deepseek-chat"                        # model
)
```

**⚠️ 安全提醒**：如果这样做，**别把改动 commit 进 git**，Key 会泄露。

---

## 如何验证是不是接上了

进入游戏对话时观察：

| 场景 | Mock（未接 API） | 真实 LLM |
|-----|-----|-----|
| 延迟 | 0.5-1.2 秒（固定） | 通常 2-5 秒 |
| 回复 | 从 few-shot 里选一条 | 每次都不一样，能理解你没预想过的问题 |
| 打「你叫什么名字」再问「你家住哪」 | 各自独立命中 few-shot | 会记住上文，答『我家就在思源湖边亭子』 |
| 玩家发挥创意话题 | 走 fallback，回答敷衍 | 大模型能顺着你的话往下扯 |

---

## 常见错误

### `HTTP 401: {"error":{"message":"Invalid API Key"}}`
Key 拼错或过期。DeepSeek 的 Key 应该以 `sk-` 开头。

### `HTTP 429: rate limit exceeded`
免费额度用完 / 速率限制。等一会儿或充值。

### `HTTP 404: model_not_found`
`model` 字段拼错。DeepSeek 是 `deepseek-chat`；OpenAI 是 `gpt-4o-mini`；通义是 `qwen-plus`。

### `网络错误 result=4`
连不上服务器。检查网络、防火墙、代理设置。中国大陆访问 OpenAI 需要代理，用 DeepSeek/Qwen/GLM 不需要。

### 回复出戏 / 太长 / 不像角色
可以调整对应 NPC 的 `.md` 文件：
- 在 `# 绝对禁区` 添加更明确的规则
- 在 `# Few-shot 对话样例` 加更多例子
- YAML 里降低 `temperature`（比如 0.6）会更稳定但也更呆板

---

## 想切回 Mock 调试？

删除 / 重命名 `llm_config.json`，重启游戏即可回到默认 Mock 模式。

或代码里调 `LLMConfig.apply_mock()`。
