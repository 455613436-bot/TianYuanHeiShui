extends Node
## LLMConfig
## LLM 配置管理（autoload）。
## 启动时按优先级选择 Provider：
##   1. 用户设置文件 user://llm_config.json 存在 → 用它
##   2. 环境变量 DEEPSEEK_API_KEY / OPENAI_API_KEY / QWEN_API_KEY 之一存在 → 自动装
##   3. 否则保持默认 MockLLM
##
## 你拿到 API Key 之后，最简单的三种切换方式（任选其一）：
##
## 方式 A（推荐 / 最持久）：写用户配置文件
##     在 Godot 的 user:// 目录（Windows 下: %APPDATA%/Godot/app_userdata/思源村探案/ ）
##     创建 llm_config.json：
##     {
##       "provider": "openai_compatible",
##       "api_key":  "sk-xxxxxxxxxxxxxxx",
##       "base_url": "https://api.deepseek.com/v1",
##       "model":    "deepseek-chat"
##     }
##
## 方式 B（临时 / 命令行 / 环境变量）：
##     PowerShell:
##       $env:DEEPSEEK_API_KEY = "sk-xxx"
##       然后正常启动游戏；LLMConfig 会自动检测并装载 DeepSeek
##
## 方式 C（代码里手动装）：
##     LLMConfig.apply_openai_compatible("sk-xxx", "https://api.deepseek.com/v1", "deepseek-chat")

const CFG_PATH_USER := "user://llm_config.json"
const CFG_PATH_PROJECT := "res://llm_config.json"
const OpenAILLMScript := preload("res://scripts/llm/OpenAILLM.gd")

## 各家 API 的默认 base_url + 默认模型名映射
const PRESETS := {
	"deepseek": {"base_url": "https://api.deepseek.com/v1",                       "model": "deepseek-chat"},
	"openai":   {"base_url": "https://api.openai.com/v1",                         "model": "gpt-4o-mini"},
	"qwen":     {"base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1", "model": "qwen-turbo"},
	"glm":      {"base_url": "https://open.bigmodel.cn/api/paas/v4",              "model": "glm-4-flash"},
	"moonshot": {"base_url": "https://api.moonshot.cn/v1",                        "model": "moonshot-v1-8k"},
	"ollama":   {"base_url": "http://localhost:11434/v1",                         "model": "qwen2.5:7b"},
}


func _ready() -> void:
	# 稍等一帧，让 LLMService 先 _ready 装完默认 Mock
	await get_tree().process_frame
	_auto_detect_and_apply()


func _auto_detect_and_apply() -> void:
	# 1. 项目内 res://llm_config.json（最方便，直接放项目根即可）
	if _try_load_from(CFG_PATH_PROJECT):
		return

	# 2. 用户目录 user://llm_config.json（跨项目共用）
	if _try_load_from(CFG_PATH_USER):
		return

	# 3. 环境变量
	for env_name in ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "QWEN_API_KEY", "GLM_API_KEY", "MOONSHOT_API_KEY"]:
		var key := OS.get_environment(env_name)
		if key.strip_edges() != "":
			var provider: String = env_name.to_lower().replace("_api_key", "")
			var preset: Dictionary = PRESETS.get(provider, {})
			print("[LLMConfig] 检测到环境变量 %s，自动装载 %s" % [env_name, provider])
			apply_openai_compatible(key, String(preset.get("base_url", "")), String(preset.get("model", "")))
			return

	print("[LLMConfig] 未检测到任何 LLM 配置（res:// / user:// / env），继续使用 MockLLM")


func _try_load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return false
	var raw := f.get_as_text()
	f.close()
	var cfg = JSON.parse_string(raw)
	if typeof(cfg) != TYPE_DICTIONARY:
		push_warning("[LLMConfig] %s 不是合法 JSON，跳过" % path)
		return false
	print("[LLMConfig] 检测到配置文件: %s" % path)
	apply_dict(cfg)
	return true


## 通用入口：从 dict 装
func apply_dict(cfg: Dictionary) -> void:
	var provider: String = String(cfg.get("provider", "openai_compatible")).to_lower()
	var api_key: String = String(cfg.get("api_key", ""))
	var base_url: String = String(cfg.get("base_url", ""))
	var model: String = String(cfg.get("model", ""))

	# 允许 provider = 一个预设名（deepseek / qwen / ...）自动填 base_url
	if PRESETS.has(provider):
		if base_url == "": base_url = PRESETS[provider]["base_url"]
		if model == "":    model    = PRESETS[provider]["model"]

	apply_openai_compatible(api_key, base_url, model)


## 装载一个 OpenAI 兼容 Provider
func apply_openai_compatible(api_key: String, base_url: String, model: String) -> void:
	if api_key.strip_edges() == "":
		push_warning("[LLMConfig] api_key 为空，忽略切换请求")
		return
	if base_url.strip_edges() == "":
		base_url = PRESETS["deepseek"]["base_url"]
	if model.strip_edges() == "":
		model = PRESETS["deepseek"]["model"]

	var p := OpenAILLMScript.new()
	p.name = "OpenAILLM"
	p.api_key = api_key
	p.base_url = base_url
	p.model_name = model
	LLMService.set_provider(p)
	print("[LLMConfig] Provider -> OpenAI 兼容: %s (%s)" % [base_url, model])


## 主动切回 Mock（调试用）
func apply_mock() -> void:
	var mock := preload("res://scripts/llm/MockLLM.gd").new()
	mock.name = "MockLLM"
	LLMService.set_provider(mock)
