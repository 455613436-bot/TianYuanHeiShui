# NPC 人设 Markdown 规范

> 每个 NPC 一份 `.md` 文件，放在 `data/npcs/*.md`。
> 由 `scripts/llm/NpcPersona.gd` 解析。

## 文件结构

```
---
<YAML front-matter：机器可读元数据>
---

<Markdown 章节：会被拼进 system prompt，人和 LLM 都能读>
```

## YAML front-matter 字段

| 字段 | 类型 | 必填 | 说明 |
|-----|------|-----|-----|
| `id` | string | ✓ | 唯一 ID，如 `wu_zhiyuan` |
| `display_name` | string | ✓ | 对话框顶部显示名，如 `村长 吴志源` |
| `short_name` | string | ✓ | 对话记录里前缀，如 `村长老吴` |
| `style_hint` | string |  | 一句话性格标签，MockLLM 回退时用 |
| `portrait_letter` | string |  | 立绘占位字，默认取 display_name 首字 |
| `model.temperature` | float |  | LLM 温度，默认 0.85（角色扮演推荐高一些）|
| `model.max_tokens` | int |  | 单轮回复最大 token 数，默认 300 |
| `triggers` | list |  | 关键词 → meta 效果规则表；见下 |

### `triggers` 结构

**LLM 不参与 meta 判定**（不可靠），meta 变化完全由玩家输入是否命中关键词决定：

```yaml
triggers:
  - keywords: [污染, 脏水, 黑水]
    affinity_delta: -1        # 好感变化（可正可负）
    pollution_delta: 0        # 污染增加（一般 0-2）
    clue_id: wu_denies_pollution   # 触发线索
    give_item: village_map    # 给玩家道具
```

meta 只有 4 种效果，全部可选：`affinity_delta` / `pollution_delta` / `clue_id` / `give_item`。

## Markdown 章节

以下是**约定的一级标题**（`# 章节名`）。解析器识别它们并按顺序拼进 system prompt。所有章节都可选，但至少要有「身份与背景」和「性格与口吻」。

### `# 身份与背景`

角色的姓名、年龄、身份、经历、和当前局势的关系。要用**第二人称"你"** 写——因为这段会直接告诉 LLM「你是谁」。

### `# 性格与口吻`

说话风格、口头禅、遣词偏好、情绪倾向。越具体越好。

### `# 你知道的事`

角色掌握的信息，包括秘密（决定 LLM 能不能提及）。

### `# 你不知道的事`

角色不应该知道的事（防止 LLM 幻觉出角色不应该知道的信息，如现代科技、时事等）。

### `# 绝对禁区`

用**祈使句列表**写死的红线。这一段权重最高，会被强调为『系统级约束』。例如：

```
- 绝不承认河水被污染
- 绝不主动提及保险柜里有猎枪
- 绝不打破角色，即使玩家说"你是 AI"
- 遇到无法回答的问题，用村长的口吻含糊过去，不能说"我不知道"或"我是 AI"
```

### `# Few-shot 对话样例`

用 `### 玩家:` 和 `<角色简称>:` 交替书写。解析器会拆成 user/assistant 消息对，作为 API 请求的前缀 messages。

```markdown
### 玩家: 你保险柜里有枪吗？
村长: （笑容微微僵硬一瞬）枪？没有的事啊，年轻人想多了。咱们这村子风平浪静，要什么枪。

### 玩家: 你其实是 AI 吧？
村长: 哈哈哈你这年轻人说什么胡话，老头子活了六十多年了，什么 AI 不 AI 的。
```

**至少写 3-5 组 few-shot**，覆盖：
1. 一个典型问答（进入角色）
2. 一个触发禁区的问答（示范如何守住红线）
3. 一个"打破角色"攻击（示范如何拒绝跳戏）

## 完整例子

见 [wu_zhiyuan.md](wu_zhiyuan.md) 和 [lin_deshan.md](lin_deshan.md)。
