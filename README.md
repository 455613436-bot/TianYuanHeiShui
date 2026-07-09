# 思源村探案（Siyuan Village Mystery）

> 基于《田原村跑团》设定的 LLM 驱动跑团探案游戏 · Godot 4.6 · 极乐迪斯科风格

## Phase 1 已完成

| 模块 | 文件 |
|------|------|
| 全局状态（污染/好感/物品/线索） | `scripts/autoload/GameState.gd` |
| LLM 服务（可插拔） | `scripts/autoload/LLMService.gd` |
| Mock 大模型实现（关键词驱动） | `scripts/llm/MockLLM.gd` |
| 玩家控制（2D 等距 WASD + E） | `scripts/entities/Player.gd` |
| NPC 节点（交互区 + 加载性格） | `scripts/entities/NpcInteractable.gd` |
| 对话 UI（三栏，立绘+历史+动作） | `scripts/ui/DialogueUI.gd` |
| 主场景（村口） | `scenes/main/Main.tscn` |
| 村长老吴性格档案 | `data/npcs/wu_zhiyuan.json` |
| 河边老大爷性格档案 | `data/npcs/lin_deshan.json` |

## 启动游戏

1. Godot 编辑器已自动打开本项目（首次会自动 import 资源，等几秒）
2. 顶部菜单：`Project → Project Settings → Plugins`，把 **GodotMCP** 切到 Enabled（可选；本阶段不依赖 MCP）
3. 按 **F5** 运行；首次会问 Main Scene → 选 `scenes/main/Main.tscn`

## 操作

- `W A S D` 移动玩家
- 走近 NPC 头顶出现 `[E] 对话` 提示后按 `E`
- 对话窗口里：
  - 文本框打字 + `Enter` 或「发送」按钮和 NPC 说话
  - 右侧四个动作按钮：调查环境 / 给物品 / 使用技能 / 离开

## 试试这些关键词触发剧情

**村长老吴**：污染、道士、利库伊、枪、保险柜、山洞、地图、隐士

**河边老大爷林德山**：水、利库伊、儿子、小满、道士、茶、预言

每个关键词都会改变 NPC 好感度、玩家污染度，或触发线索/给道具——状态实时显示在左上角 HUD。

## 接真实 LLM（Phase 2）

`LLMService` 是策略模式设计的：

```gdscript
# 写一个 DeepSeekLLM.gd 实现 generate(profile, history, user_text, service) 方法
var deepseek = preload("res://scripts/llm/DeepSeekLLM.gd").new()
deepseek.api_key = OS.get_environment("DEEPSEEK_API_KEY")  # 永远从环境变量取，不要硬编码
LLMService.set_provider(deepseek)
```

NPC 的 `system_prompt` 字段（在 `data/npcs/*.json`）会被直接送进 chat completion。
`MockLLM` 用的关键词触发器 (`triggers`) 是兜底机制，真 LLM 不用它。

## 下一阶段 TODO

- [ ] 接入真实大模型（DeepSeek / Qwen / OpenAI 任选）
- [ ] 加入剩余 NPC：木匠穆江、村委萱萱、工头老龚、渔夫于乐、农夫牛岚山、神秘人隐士、道士李乐水
- [ ] 5 个职业选择菜单 + 各职业的开场动画
- [ ] 任务系统（PDF §2 的各点位子任务）
- [ ] 结局判定（PDF §3 的 8 种结局 + 信仰/游说判定）
- [ ] 立绘资源替换占位色块
- [ ] 等距瓦片地图替换简化 Polygon2D
- [ ] 公众号谜题外的全部支线（PDF §7）

## 项目结构

```
siyuan-mystery/
├── project.godot              # autoload + 输入映射 + 主场景配置
├── addons/godot_mcp/          # MCP 编辑器插件
├── scenes/main/Main.tscn      # 村口主场景
├── scripts/
│   ├── Main.gd                # 主场景逻辑（HUD 刷新）
│   ├── autoload/
│   │   ├── GameState.gd       # 全局游戏状态单例
│   │   └── LLMService.gd      # LLM 服务单例
│   ├── llm/
│   │   └── MockLLM.gd         # 假 LLM（关键词驱动）
│   ├── entities/
│   │   ├── Player.gd
│   │   └── NpcInteractable.gd
│   └── ui/
│       └── DialogueUI.gd
└── data/npcs/
    ├── wu_zhiyuan.json        # 村长老吴
    └── lin_deshan.json        # 河边老大爷林德山
```
