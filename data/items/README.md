# 道具数据规范

> 每件道具一份 `<id>.json`，放在 `data/items/`。
> 由 autoload `scripts/autoload/ItemDB.gd` 在启动时扫描全部加载。

## 字段

| 字段 | 类型 | 必填 | 说明 |
|-----|------|-----|-----|
| `id` | string | ✓ | 与 `GameState.inventory` 里保存的字符串对齐，也是 NPC `triggers.give_item` 里写的值 |
| `display_name` | string | ✓ | 玩家 UI、LLM prompt 里出现的可读名字 |
| `short_desc` | string |  | 玩家可见的一句话说明；显示在背包道具行与检视弹窗，不注入 LLM prompt |
| `tags` | string[] |  | 分类标签，仅供检索/展示，逻辑上不用 |
| `usable_in_dialogue` | bool |  | 默认 `true`。为 `false` 时"打开背包"里不显示；LLM 也不能声明 `item_used` |
| `consumable` | bool |  | 默认 `false`。仅当为 `true`，LLM 声明 `consumed: true` 时才会真的从背包移除 |
| `inspectable` | bool |  | 默认 `false`。为 `true` 时物品栏行右侧多出「检视」按钮，点击弹出大图窗；用于藏有文字/图像细节的证物、字条、照片、地图之类 |
| `icon_path` | string |  | 缩略图资源路径；为空时自动按物品 `id` 匹配 `res://assets/items/<id>.png`，仍找不到才显示占位符 `?` |
| `inspect_image_path` | string |  | 检视大图路径；空时回退到 `icon_path`；两者都空则显示"暂无图像"占位 |
| `usage_hints` | string[] |  | 仅注入 LLM prompt 的自然语言使用提示，说明物品适用场景；每条建议 30~80 字，不在玩家 UI 展示。 |

## LLM 侧感知机制

DialogueUI 会在每次请求前把玩家当前持有的物品拼成一段 system prompt 追加块：

```
【玩家当前持有】
- 村庄手绘地图（id: village_map）（使用提示：想辨认方位、找路、指出村里某处的相对位置时，可以摊开地图给对方看。）
注意：只有这份清单里的东西玩家才拥有；不得在正文里让玩家凭空拿出清单以外的物品。
```

LLM 只有在该清单中出现的 id/名字才可以合法地在 `item_used` / `item_request` 里引用。

## 与对话系统的两种交互路径

**路径 A：玩家主动使用（打开背包 → 点击物品 → 输入区插入 token）**

对话 UI 右侧「打开背包」按钮 → 弹出 `ItemBagPopup` → 点击物品 → 在输入区上方插入一枚金色药丸标签
`【使用道具】<物品名>`。玩家可继续输入自由说明（"用它给他看这次生病的地方"），发送时 token 与自由文本
一并组装成一条 user 消息发给 LLM。已插入过的物品在背包中变灰，点击 token 药丸可移除。

**路径 B：LLM 主动请求（`item_request` 字段）**

LLM 在正文里问"你身上带地图吗？"，同一份 JSON 里输出 `item_request.candidates`，服务端过滤
出玩家真正持有的候选并把它们渲染为 `choice_row` 的按钮（"🎒 出示：村庄手绘地图"），
外加一颗兜底的"我没有 / 不出示"。玩家点击 = 提交 `【出示道具】<物品名>`。

## 道具消耗

只有 **同时满足**「LLM 输出 `item_used.consumed == true`」+「道具 DB 中 `consumable == true`」
两个条件时，才会真的从 `GameState.inventory` 移除。任一不满足只写一条系统日志
`[你出示了道具：xxx]`。这样把消耗决定权交给 LLM，但 DB 拿最终否决权，避免关键剧情道具被误消耗。

## 完整示例

见 [`village_map.json`](village_map.json)。
