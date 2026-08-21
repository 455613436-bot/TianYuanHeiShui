# NPC 位置调度与多人对话系统 · 改造方案

> 面向 `siyuan-mystery` 项目：为NPC 增加"日程+位置"、说服临时改变行程、跟随玩家、私聊/公聊四大能力。
> 本文档只做设计，不改任何代码；确认方案后再按 M1–M6 分里程碑落地。

---

## 0. 现状快照（一句话摘要）

-已有：`GameState`（跨场景状态 + 存档）、`MemoryStore`（NPC 分层记忆）、`WorldMap`（硬编码 8 个地点）、`LocationBase`（占位场景）、`NpcInteractable`（每个 NPC 一个节点，硬钉在 tscn 里）、`DialogueUI`（成熟单 NPC 对话），LLM 层完整。
- 缺失：**游戏时钟、NPC 位置数据、NPC 与场景解耦、公聊链路**。
- 主要瓶颈：NPC 目前是**场景节点**而不是**数据实体**，改造第一步必须做实体化。

---

## 1. 目标功能清单

| 编号 | 目标 | 档次 |
|---|---|---|
| F1 | 每个 NPC 有 `current_location` 字段，随时间/事件变化 | L0 |
| F2 | 每个 NPC 有每日 `schedule`（时段→地点） | L1 |
| F3 | 场景里的 NPC 由数据动态生成，不再硬钉在 tscn | L1 |
| F4 | 世界地图显示"每个地点有谁"（占位头像+名字条） | L1 |
| F5 | 未探索地点的 NPC 显示为"？？？" | L1 |
| F6 | 时间以"对话轮=5 分钟"推进；到时段边界结束对话 | L1 |
| F7 | NPC 主动预告离场（比切换时段早 10 分钟） | L1 |
| F8 | 事件规则→临时覆盖 schedule（例：出示线索让 NPC 逃跑） | L2 |
| F9 | LLM 说服裁决器：玩家请求 NPC 换地点/跟随/离开 | L3-A |
| F10 | 跟随玩家：NPC 变companion，位置跟随玩家所在地点 | L2 |
| F11 | 多 NPC 共处时的"公聊"模式：显式按钮进入，每轮所有在场 NPC 并行独立调LLM，各自决定是否发言；上限 6 轮/30 分钟 | 独立模块 |
| F12 | NPC 上下文里注入"当前地点+同地点其他人"，并写进记忆 | 贯穿全流程 |

---

## 2. 总体架构

新增两个 autoload 单例 + 一个数据驱动的地点表 + 一个公聊协调器：

```
新增 autoload:
  TimeSystem        # 游戏时钟：分钟计数 → 时段
  NpcRegistry       # NPC 数据仓库 + 位置调度 + 事件规则

新增数据文件:
  data/locations.json                # 地点表，取代 WorldMap 里硬编码常量
  data/npcs/<id>.json 增加字段        # schedule/current_location/home_location
  data/npc_rules/<id>.json（可选）    # 事件→行为覆盖规则

新增脚本:
  scripts/autoload/TimeSystem.gd
  scripts/autoload/NpcRegistry.gd
  scripts/entities/NpcSpawner.gd# 场景里放一个 spawner，动态生成 NPC
  scripts/ui/GroupChatCoordinator.gd      # 公聊模式调度：并行调所有在场 NPC 的 LLM（F11）
  scripts/ui/NpcPresenceBar.gd            # 场景内"当前地点还有谁"横条 + 召集公聊按钮
  scripts/ui/MapNpcBadge.gd               # 地图上每个地点旁的 NPC 头像徽章

改动：
  WorldMap.gd     从 LOCATIONS 常量 → 读 data/locations.json + 显示 NPC 徽章
  Main.gd         把硬钉的 NpcWuZhiyuan 节点删掉，改用 NpcSpawner
  LocationBase.gd 加入 NpcSpawner（未来玩家进入占位地点也能看到 NPC）
  NpcInteractable.gd  `on_player_interact` 触发私聊；公聊由 NpcPresenceBar 按钮进入
  DialogueUI.gd   支持"当前地点场景状态"上下文；支持时段边界离场提示；支持公聊多气泡显示
  GameState.gd    保存/加载 TimeSystem + NpcRegistry 的状态
```

**核心原则**：**所有 NPC 位置的改动都只通过 `NpcRegistry.move_npc()` 唯一入口**，方便调试、记忆写入、存档一致性。schedule 层、事件规则层、LLM 说服层、跟随层最终都调它。

---

## 3. 数据模型

### 3.1 地点表 `data/locations.json`

替代 `WorldMap.gd::LOCATIONS`，让 UI 层可以纯数据驱动地显示 NPC。

```json
[
  {
    "id": "village_square",
    "number": "0",
    "name": "村口广场",
    "description": "外乡人进入田原村的第一站……",
    "map_position": [0.137, 0.468],
    "scene": "res://scenes/main/Main.tscn",
    "tags": ["outdoor", "public"]
  },
  {
    "id": "village_chief_house",
    "number": "3",
    "name": "村长家",
    "description": "村长吴志源的住处……",
    "map_position": [0.303, 0.263],
    "scene": "res://scenes/locations/VillageChiefHouse.tscn",
    "tags": ["indoor", "private"]
  }
]
```

> `id` 才是**位置的稳定主键**，scene 路径只是"进入哪个 tscn"。之后所有 NPC 的 `current_location` 都存 id，不存 scene 路径——这样即使多个 NPC 数据文件被改，也不会因路径变动而错乱。

### 3.2 NPC 数据文件扩展（追加，不破坏现有字段）

`data/npcs/wu_zhiyuan.json` 末尾追加：

```json
{
  "home_location": "village_chief_house",
  "current_location": "village_chief_house",
  "portrait_small": "res://assets/npcs/wu_zhiyuan_head.png",
  "importance": "main",
  "schedule": [
    { "period": "morning",   "location": "village_committee",   "reason": "开村委会晨会" },
    { "period": "noon",      "location": "village_chief_house", "reason": "回家吃饭" },
    { "period": "afternoon", "location": "farmland",            "reason": "巡视农田" },
    { "period": "evening",   "location": "village_chief_house", "reason": "回家用晚饭" },
    { "period": "night",     "location": "village_chief_house", "reason": "睡觉" }
  ]
}
```

字段说明：
- `home_location`：schedule 兜底、跟随结束回家、说服失败回落。
- `current_location`：**运行时字段**，启动时由 schedule 计算，之后由 NpcRegistry 维护。存档写这里。
- `importance`：`main` / `normal` / `ambient`，决定"能否被 LLM 说服"、"是否画头像徽章"、"是否参与公聊排序"。
- `schedule`：允许覆盖同 period 多次时用最后一条；缺失的 period 落回 `home_location`。
- `portrait_small`：**M1 阶段可以留空**，UI 层会用统一占位图+ 名字条兜底。

### 3.3 事件规则文件 `data/npc_rules/<id>.json`（L2，M4 引入）

```json
[
  {
    "id": "example_temporary_departure",
    "trigger": { "type": "clue_triggered", "clue_id": "example_clue" },
    "condition": { "affinity_lt": 30 },
    "action": {
      "type": "temp_move",
      "location": "back_mountain",
      "duration_minutes": 240,
      "reason": "临时离开",
      "log_global_memory": "某位 NPC 因剧情事件暂时前往后山。"
    }
  }
]
```

`trigger.type` 支持：`clue_triggered` / `event_triggered` / `quest_stage` / `time_period` / `affinity_below`。
`action.type` 支持：`temp_move`（临时改位置一段时间）/ `set_schedule`（覆盖整段schedule）/ `set_home`（永久搬家）/ `follow_player` / `stop_follow`。

---

## 4. TimeSystem 设计（F6, F7）

### 4.1 数据模型

```gdscript
extends Node
signal minute_changed(day: int, minute_of_day: int)
signal period_changed(new_period: String, day: int)
signal day_changed(new_day: int)

const PERIODS := [
    {"id": "morning",   "start":  360, "end":  660},   # 06:00-11:00
    {"id": "noon",      "start":  660, "end":  840},   # 11:00-14:00
    {"id": "afternoon", "start":  840, "end": 1080},   # 14:00-18:00
    {"id": "evening",   "start": 1080, "end": 1320},   # 18:00-22:00
    {"id": "night",     "start": 1320, "end": 1740},   # 22:00-05:00 next day
]

var current_day: int = 1
var minute_of_day: int = 540# 09:00 起始
var minutes_per_dialogue_turn: int = 5   # 你要求的"一轮对话=5分钟"
```

### 4.2 API

```gdscript
func advance_minutes(n: int) -> void                              # 唯一推进入口
func on_dialogue_turn_completed() -> void                         # DialogueUI 每轮结束调一次
func current_period() -> String
func minutes_until_next_period() -> int
func is_near_period_boundary(threshold_min: int = 10) -> bool     # F7 用
func format_clock() -> String                                     # "第 1 天 · 上午 09:35"
```

### 4.3 时段边界处理（F7 关键）

**触发点在 `DialogueUI` 的"玩家发送一条消息后"**：

1. 玩家提交消息 → 记住"即将 tick 1 轮 = +5 分钟"（此时还没tick）。
2. 调用 `TimeSystem.is_near_period_boundary(10)`：如果 tick 之后**会跨过时段边界**，则本次 LLM system prompt 里注入一个软指令：

   > "**场景状态**：距离你按日程要去 `{next_location.name}`（原因：{next_reason}）还有 {n} 分钟。请在这次回答中自然地提醒玩家你要走了；如果玩家没有强留，请在回答末尾用 `[END_DIALOGUE]` 标签表示你就此告辞离开。"

3. LLM 输出解析：若含 `[END_DIALOGUE]` 或 tick 之后 `current_period` 已变，则：
   - `DialogueUI` 展示完最后一句 → 关闭对话（走已有的 close 流程）。
   - `NpcRegistry.apply_schedule_for(npc_id)` 立即把该 NPC 挪到新时段的位置。
   - 全局记忆写入："`{npc}` 到点离开去了 `{new_loc}`。"

4. 若玩家出示物品/线索/发起说服，走L3-A 说服流程可**推迟离场**（写一个 `postpone_leave_until` 字段，默认 15 分钟）。

**为什么用软指令而不是硬打断**：硬打断会让对话显得机械，让 LLM 自然说"要不下次再聊，我得去村委会了"体验好得多，且 tag 标签是**兜底**。tag 缺失时用"tick 后 period 已变"作为第二重判定。

### 4.4 时间怎么推进（回答你的设定）

- **一次玩家发言 = 1 轮 = +5 分钟**，在 DialogueUI 收到 LLM 回答后调用 `TimeSystem.on_dialogue_turn_completed()`。
- 场景切换（世界地图→地点）**默认不推时间**，避免玩家来回切图产生时间黑洞；如果你希望"走路要花时间"，后续在 `GameState.enter_location()` 里加 +5~15 分钟即可。
- 关闭对话不推时间（因为每轮已经推过了）。
- 特殊动作（睡觉、休息、搜查）可以显式 `advance_minutes(N)`。

---

## 5. NpcRegistry 设计（F1, F2, F8, F10）

### 5.1 API 表

```gdscript
# 数据装载
func load_all() -> void              # 启动时扫 data/npcs/*.json、data/locations.json、data/npc_rules/*.json

# 查询
func get_npc(npc_id) -> Dictionary
func get_location_of(npc_id) -> String
func get_npcs_at(location_id) -> Array[String]   # 场景/地图 UI 调这个
func get_location_info(loc_id) -> Dictionary
func all_locations() -> Array
func known_npcs_at(location_id) -> Array[String] # 只返回"玩家探索过的"，未探索返回["?"]（F5）

# 位置变更（唯一入口）
func move_npc(npc_id, new_location_id, reason: String, source: String) -> void
    # source in {"schedule","event","llm","follow","manual"}
    # 内部：更新 current_location + 写 global_memory + emit 信号 + 存档标脏

# schedule
func apply_schedule_for(npc_id) -> void          # 按当前 period 把 NPC 挪到schedule 里对应的位置
func apply_all_schedules() -> void               # period_changed 时批量执行
func set_temp_override(npc_id, loc, minutes, reason) -> void  # L2 事件规则用

# 跟随（F10）
func start_follow(npc_id) -> void
func stop_follow(npc_id, drop_at_location_id: String = "") -> void
func following_npcs() -> Array[String]

# 事件规则（L2）
func on_event(event_name: String, payload: Dictionary) -> void
    # 内部匹配 npc_rules[*] 触发 action

# 信号
signal npc_moved(npc_id, from_loc, to_loc, reason)
signal follow_changed(npc_id, is_following)
```

### 5.2 与已有系统的钩子

- 连 `TimeSystem.period_changed` → `apply_all_schedules()`。
- 连 `GameState.clue_triggered` / 自定义 event → `on_event(...)`。
- 每次 `move_npc()` 都写一条 `MemoryStore.add_global_memory("{npc_name}在{time}去了{loc_name}（{reason}）", ["npc_move", npc_id])`，让**其他 NPC 也知道**（因为你的 MemoryStore 是村庄共享的）。
- 玩家进入场景时，`NpcSpawner._ready()` 里问 `get_npcs_at(current_loc_id)`，动态 `instantiate` `NpcInteractable`。

### 5.3 跟随（F10）实现细节

- `start_follow(npc)` 后：注册"跟随监听"→ 玩家 `enter_location(new_scene)` 时先算 new_loc_id → `move_npc(npc, new_loc_id, "跟随玩家", "follow")`。
- 跟随中的 NPC **暂停 schedule**（`apply_all_schedules()` 跳过 `following_npcs`）。
- 跟随可被以下条件打断：玩家显式请他离开、走到 NPC 拒绝去的地点（如"后山" for老人）、时间到深夜、亲密度骤降。
- 每次跨地点时插一句flavor 记忆："吴志源跟着外来者去了村委会。"，让其他 NPC 之后能提到。

### 5.4 未探索地点显示 "？？？"（F5）

`GameState.unlocked_locations[scene_path]` 已经有，但那是"能不能进"层面的。为 F5 增加一个**软概念**：

```gdscript
# GameState 新增
var visited_locations: Dictionary = {}   # loc_id -> true
func mark_visited(loc_id): visited_locations[loc_id] = true
func has_visited(loc_id) -> bool
```

- `WorldMap` 的 NPC 徽章渲染：若 `not GameState.has_visited(loc_id)` → 徽章显示 "？？？" + 灰色。
- 玩家进入地点后触发 `mark_visited`。**只需要访问过一次，之后 schedule 让谁去那，玩家在地图上都能看到**——但你也可以做得更严格：徽章只显示"上次访问时看到的人"，感觉更真实。默认走前者简单版，后者做为可选升级。

---

## 6. UI 改造（F3, F4, F5, F12）

### 6.1 场景内：NpcSpawner + NpcPresenceBar

- **NpcSpawner**：挂在 `Main.tscn` 和 `LocationBase.tscn` 的根节点下。`_ready()` 里：
  1. 从场景元数据/`@export` 读到当前 `location_id`。
  2. 查 `NpcRegistry.get_npcs_at(location_id)`。
  3. 为每个 NPC 实例化一份 `NpcInteractable`，喂 `npc_id` 让它自己 load profile。
  4. 定位摆放：M2 阶段用简单水平排列；后续再做每个地点的"占位点"数据。

- **NpcPresenceBar**（场景 HUD 顶部）：横条显示"这里还有：村长、萱萱"，点击某个头像 = 切换**私聊**对象。当当前地点有≥2 个 NPC 时，横条右侧额外亮起 **"召集所有人谈话"** 按钮 → 进入公聊模式（见 §9）。

### 6.2 世界地图：MapNpcBadge

- 每个热点按钮下方叠一个横向 `HBoxContainer`，装 `NpcRegistry.get_npcs_at(loc_id)` 里每个 NPC 的小头像（M1 用统一占位方块+名字条）。
- 未探索地点：整条替换成 "？？？"。
- 数据由 `NpcRegistry.npc_moved` 信号驱动刷新。

### 6.3 DialogueUI 上下文注入（F12）

在组 system prompt 时，除了原有的 `MemoryStore.build_memory_prompt_block(npc_id)`，追加一段：

```
## 当前场景状态
- 现在是：第 3 天 上午 09:35（morning）
- 你所在地点：村委会
- 同处此地的还有：萱萱（会计）
- 你按日程 11:05 需要回家吃饭
```

同时**每轮结束**（`MemoryStore.append_turn`）之后，追加一条"环境事件"到 npc_history：

```gdscript
# 伪代码
MemoryStore.append_turn(npc_id,
    user_text=msg,
    npc_text=reply,
    env_hint="[时间 09:35 · 你在村委会 · 在场：萱萱]")
```

env_hint 可以放在 npc_text 前作为不可见 system 行，或者直接不进 history 只进 prompt——**建议后者**，因为进 history 会污染 LLM 学到的"回答风格"。

---

## 7. 事件规则层（F8，L2）

### 7.1 触发接线

- `GameState.trigger_clue()` 已 emit `clue_triggered` → `NpcRegistry.on_event("clue_triggered", {clue_id})`。
- 新增 `GameState.emit_event(name, payload)` 通用入口，方便剧情脚本触发自定义事件。
- `TimeSystem.period_changed` 触发 `on_event("time_period", {period})`。

### 7.2 匹配与执行

`NpcRegistry._match_rule(rule, event) -> bool` 是纯函数，好测。匹配后：
- `apply_action(rule.action)` 走 `move_npc` / `set_temp_override` / `start_follow` 等。
- 每条规则可以配置 `once: true`，触发过就标`triggered_events[rule.id]=true`（复用你已有的 `GameState.triggered_events`）。
- 一次事件可以匹配多条规则；`priority` 字段决定顺序，冲突时后者覆盖前者。

### 7.3 与 LLM 层的关系

**规则层永远优先于 LLM 层**：LLM 的说服裁决器输出的位移，会先被规则层"是否允许"过滤（比如 NPC 处于 `flee` 状态时，说服不能让他回家除非玩家亲密度够高）。

---

## 8. LLM 说服裁决器（F9，L3 方案 A）

### 8.1 入口：什么时候调 LLM

**只在对话中**，且玩家发言被识别为"请求 NPC 行动"时才调（不是每轮都调，成本受控）：
- 触发关键词：`跟我`、`陪我`、`离开`、`回家`、`别在这`、`带我去`、`一起`、`留下`等（走 SuggestionGuard 已有的模式匹配）。
- 或者 NPC 主答LLM 输出结构化 tag `[REQUEST_ACTION: follow|move|leave]` 时，说明 NPC 自己在犹豫要不要动，触发裁决。

### 8.2 一次说服 = 一次 LLM 调用

**调用不是新增的独立请求，而是复用当轮对话的 LLM 调用**，只是把 system prompt 加一段"动作决策指令"，强制 JSON 输出扩展：

```json
{
  "reply": "……行吧，那我陪你去趟码头。",
  "action": {
    "type": "follow_player",         // none | follow_player | move_to | leave | postpone_leave
    "target_location": "lakeside_dock",
    "duration_minutes": 60,
    "confidence": "reluctant"        // eager | willing | reluctant | refused
  },
  "check": {
    "attribute": "charisma",
    "dc": 12         // NPC 自己评估的说服难度
  }
}
```

处理：
1. `CheckSystem` 用玩家 `charisma`掷 d20 + 属性 vs LLM 给出的 dc。
2. 成功 → 执行 `action`；失败 → NPC 说"再想想吧"并把 `reply` 结尾改成拒绝，`action` 不执行。
3. 结果写全局记忆："外来者试图让村长陪同去码头，成功了（14 vs DC 12）。"

### 8.3 成本估算

- 一次说服只是**在当轮对话的同一次 LLM 调用里多要一个 JSON 字段**，**几乎零额外成本**。
- 全流程 20 天、假设玩家和 5 个主 NPC 各说服 3 次 = 60 次调用，全都是"复用调用"，边际成本约等于 0。
- 关键护栏：`target_location` 必须在 `NpcRegistry.all_locations()` 白名单里、必须是 NPC 曾去过或有理由去的地点；否则丢弃。

### 8.4 与规则层的合并

裁决器不直接改位置，最终一律走 `NpcRegistry.move_npc(..., source="llm")`，被规则层同意后才生效。规则层可以强制某些 NPC 在某些剧情节点**拒绝任何说服**（例如"村长在祭祀日晚上无法被说服离开山洞"）。

---

## 9. 对话系统：私聊 + 公聊（F11）

### 9.1 两种模式

对话系统只有两种模式，UI 上互斥：

- **私聊（默认）**：与你现在的 DialogueUI 一致，玩家 1 对 1 与一个 NPC 说话。首次进入场景点开哪个 NPC，主对话对象就是谁；在 `NpcPresenceBar` 上点其他 NPC 头像可以关掉当前对话、开启与新目标的私聊。
- **公聊（Group Chat）**：当当前地点有 ≥2 个 NPC 时，`NpcPresenceBar` 右侧亮起 **"召集所有人谈话"** 按钮。玩家点击后进入公聊模式，**当前地点全部在场 NPC 一起参与**，每轮每人都会独立决定是否发言、说什么。

**关键设计原则**：**公聊和私聊使用完全一样的 LLM 规格**——每个 NPC 都会拿到自己的完整 `system_prompt`、`MemoryStore` 的完整 summary + history、场景状态注入。公聊不是"廉价缩水版"，只是把 1 个 NPC 换成了 N 个并行的 NPC，每个 NPC 收到的 prompt 结构与私聊时一模一样。

### 9.2 公聊触发与结束条件

- **进入**：玩家在场景内点击 `NpcPresenceBar` 右侧的"召集所有人谈话"按钮 → 弹出确认（"这将花费一段时间，NPC 会围过来"）→ 进入公聊。
- **参与者**：进入公聊的瞬间快照 `NpcRegistry.get_npcs_at(current_loc)`，之后新NPC 进场不加入，参与者中途离场会退出。
- **结束条件**（任一命中即结束）：
  1. **轮次上限**：公聊最多 **6 轮**（每轮 = 玩家发一句 + 所有 NPC 回一轮）。
  2. **时间上限**：公聊消耗 **30 分钟游戏时间**（6 轮 × 5 分钟/轮，与私聊同步的时间规则）。
  3. **玩家主动结束**：UI 上"结束谈话"按钮。
  4. **时段边界**：进入下一时段之前，所有 NPC 依据 §4.3 的软指令自然告辞离场。
  5. **参与者剩 <2**：跟随/事件把其他人都拉走了，自动回退到与剩余那个 NPC 的私聊。

结束时 UI 提示"谈话散场"，把公聊缓冲区归档到 `global_memory`（一句 LLM 总结或纯规则拼接），然后关对话或回退到私聊。

### 9.3 每轮流程

设当前地点公聊中有 N 个 NPC（例如 3 个：村长、萱萱、老龚）：

1. 玩家在公聊输入框输入一句话。
2. `GroupChatCoordinator` 为每个参与 NPC **并行**发起一次 LLM 调用，每次调用都是**完整规格**：
   - 完整 `system_prompt`
   - `MemoryStore.build_memory_prompt_block(npc_id)`（该 NPC 的记忆 summary + 村庄 global_memory）
   - 该 NPC 的对话历史 `npc_histories[npc_id]`（**注意**：这里放的是**该 NPC 视角的历史**，包含它自己以前私聊/公聊里说过的话；见 §9.5）
   - 场景状态（时间、地点、在场者名单）
   - **公聊上下文**：本次公聊此前几轮所有人（玩家 + 其他 NPC）的发言（见 §9.5缓冲区）
   - 玩家最新一句
   - **发言决策指令**：强制 JSON 输出
     ```json
     {
       "speak": true,
       "reply": "……",
       "reason": "萱萱正好提到账本，我得打断她",
       "action": { "type": "none" }
     }
     ```
     `speak=false` 表示该 NPC 这一轮选择沉默（`reply` 留空）。`action` 复用 §8 的说服裁决器 schema（每个 NPC 也可以在公聊里被说服跟随/离开）。
3. N 个请求异步回来后（`await` 所有完成），按下面规则决定显示顺序：
   - `speak=true` 的 NPC 才显示；
   - 排序：`importance` 高的优先（main > normal），同级内按 NPC 数据里 `sort_priority` 或响应到达时间；
   - **每轮至多显示 3 条 NPC 发言**（≥4 人时按上述排序取前 3，其余人本轮自动被压成沉默——避免刷屏）。
4. 依次播放发言（可加短延时或按空格继续），每条发言写入公聊缓冲区，并同步写入**每个 NPC 各自的 `npc_histories`**（详见 §9.5）。
5. `TimeSystem.on_dialogue_turn_completed()` 推进 5 分钟；检查是否触发结束条件。

### 9.4 并行调用 & 服务端 Prompt Cache

- **不是"每 NPC 一个 client 手动维护 KV cache"**：OpenAI 兼容 API 是无状态的，客户端没有 KV cache 可维护；服务端也不区分你 SDK 里是几个 client。KV cache 完全在服务端，按 prompt **前缀哈希**自动命中。
- **正确做法**：`GroupChatCoordinator` 用 **N 个独立的 `HTTPRequest` 实例并发**发送请求（Godot 的 `HTTPRequest` 是异步的，天然支持并行）。服务端会对每个请求独立算前缀哈希，命中各自 NPC 的稳定前缀。
- **让 cache 命中最大化的 prompt 分层**（必须严格保持顺序，每一段之间的分隔符要固定，一个字节都不能变）：
  ```
  [段1] NPC 静态 system_prompt              ← 该 NPC 永不变的部分，最容易命中
  [段2] NPC 记忆 summary（5 轮才更新一次）  ← 中等稳定
  [段3] 村庄共享 global_memory              ← 中等易变（有新事件才追加）
  [段4] 当前场景状态（时间、地点、在场者）  ← 每轮都变
  [段5] 该 NPC 的对话历史（15 轮）          ← 每轮尾部追加
  [段6] 公聊缓冲区（本次公聊内他人发言）    ← 每轮追加
  [段7] 玩家最新一句                        ← 每轮变
  ```
  - 段 1、2 是 cache 命中的核心，永远放最前面且**不要在里面拼动态数据**（比如"当前时间"绝不能塞进 system_prompt）。
  - 段 5、6 是"追加型"，前缀部分随着历史增长仍能命中，只有末尾几百token 是新内容。
  - 段 7 每次都不一样，本来就不指望命中。

- **成本估算**（DeepSeek 定价，2025 年：输入 miss ¥2/Mtok、hit ¥0.5/Mtok、输出 ¥8/Mtok）：
  - 一次公聊 6 轮 × 4 NPC = 24 次调用。
  - 单次约 2000 稳定 token + 800 易变 token + 150 输出 token。
  - 无 cache 假设：24 × 2800 输入 + 24 × 150 输出 ≈ **¥0.16**
  - 有 cache（稳定段命中率 ~85%）：约 **¥0.10**
  - **单次公聊约 1 毛钱**；全流程 20 天玩家开30 次公聊约 3 块钱。**成本瓶颈不是钱是延迟**（4 个并发请求首字节 1–3 秒，全部返回 3–8 秒，需要 loading 动画 + 依次显示的节奏感）。

### 9.5 上下文与记忆写入（关键，别错）

公聊里"谁能听到什么"的规则要事先明确，避免记忆污染：

- **公聊缓冲区** `scene_dialogue_buffer[session_id]`：本次公聊内**所有人**（玩家 + 每个 NPC）的发言，含 sender、text、round。仅在本次公聊内共享，散场时归档并丢弃。
- **写入 `npc_histories[npc_id]`（每 NPC 独立历史）**：
  - 玩家的每句话 → 追加到**所有参与者**的 history（`role: user`）。
  - NPC 自己说的话 → 追加到**自己**的 history（`role: npc`）。
  - **其他 NPC 说的话**不直接进本 NPC 的 history，而是**在下一轮 prompt 里通过"公聊缓冲区"（段 6）传入**。这样避免不同人的发言混进 history 让 LLM 学乱回答风格；同时 NPC 依然"听得到"其他人。
- **公聊散场时**：
  - 缓冲区丢弃；
  - 由本地规则或一次 LLM 总结（可选）生成一句 flavor 写入 `global_memory`，例如"外来者在村委会同时质问了村长和萱萱受贿账本，两人互相推诿。"
  - 每个 NPC 的 `_turns_since_summary` 按参与轮数累加，超阈值触发 MemoryStore 已有的常规总结流程。

### 9.6 与说服/跟随/时段边界的整合

- 公聊里每个 NPC 的 JSON 输出都可以带 `action`，走 §8 的说服裁决器。允许"公开被说服"，例如玩家在公聊里让村长跟去码头，成功后村长退出公聊变companion，其他 NPC 继续留在原地。
- 时段边界（§4.3）在公聊里对每个 NPC 独立判定，谁快到自己 schedule 的转场时间，谁就自然告辞离场；其他人继续。
- 事件规则层（§7）优先级仍高于 LLM 输出：如果规则规定某 NPC "此时必须离开"，即使 LLM 说"我留下听你说完"也被覆盖。

### 9.7 UI 与交互细节

- **入口**：`NpcPresenceBar` 右侧按钮"召集所有人谈话"，`enabled = (在场 NPC 数量 ≥ 2)`。可选加软条件"已建立至少一次私聊"让公聊感觉像熟络之后才能召集。
- **公聊 UI**：复用 DialogueUI，标题栏改成"公聊：村长、萱萱、老龚（第 3/6 轮 · 剩余 15 分钟）"，右上角"结束谈话"按钮。发言气泡用不同颜色/头像区分说话人。
- **loading**：玩家发言后显示"NPC 正在回应…"loading，收到第一条就开始播；同时后台其余请求继续加载。
- **@ 提示**：玩家输入框里输入 `@` 弹出在场 NPC 列表可选（可选功能）；被 @ 的 NPC 在 prompt 段 4 的"当前场景状态"里额外标注"玩家在直接问你"，LLM 会天然更倾向 `speak=true`。

### 9.8 边界情况

| 情况 | 处理 |
|---|---|
| 全员 `speak=false`（都选择沉默） | UI 提示"（大家沉默了一会儿）"；不算白花时间，本轮仍推进 5 分钟；玩家可继续问 |
| 某个 NPC 的 LLM 请求超时/失败 | 该 NPC 本轮视为沉默，其他 NPC 正常显示；不阻塞整轮 |
| 玩家在公聊中触发跟随成功 | 该 NPC 退出公聊变 companion；若剩余参与者 <2，公聊自动回退到私聊 |
| 玩家在公聊中拿出线索 → 事件规则让某 NPC 逃跑 | 该 NPC 立即退出公聊，缓冲区记录一句"XX 借故离开" |
| 玩家把公聊当作调LLM 用（无休止刷公聊） | 6 轮上限 + 时段边界 + 每次 5 分钟推进，天然节流 |

---

## 10. 与现有系统的兼容性

### 10.1 存档兼容

- `TimeSystem.to_dict()` / `NpcRegistry.to_dict()` 挂进 `GameState.save_game()` 的顶层 dict。
- 版本bump `SAVE_VERSION` 从 1 → 2；`load_game()` 里检测 1 时补齐默认（day=1、schedule 走默认）。
- MemoryStore 已经在存档里，公聊缓冲区**不进存档**（每次公聊结束就丢弃）。

### 10.2 场景转换兼容

- `Main.tscn` 目前**硬钉了 `NpcWuZhiyuan` 节点**：M2 里改为 `NpcSpawner`，同时保留一个 fallback（如果 spawner 生成失败就用原节点），迁移期不破坏现有体验。
- `LocationBase` 加一个 `@export var location_id: String`，让占位地点也能挂 spawner。

### 10.3 UI 层兼容

- 玩家按 E / 点立绘的路径不变，仍是 `NpcInteractable.on_player_interact()` → 打开**私聊**。
- **公聊入口是 `NpcPresenceBar` 上独立的"召集所有人谈话"按钮**，与私聊路径解耦；`GroupChatCoordinator` 只在公聊模式下被 NpcPresenceBar 调用。
- 私聊/公聊共用同一个 DialogueUI 面板，只是发言气泡数量、标题栏、结束条件不同。

---

## 11. 里程碑与工作量估算

| 里程碑 | 内容 | 预计 | 完成后可玩性 |
|---|---|---|---|
| **M1** | `TimeSystem` + `NpcRegistry`（只加载数据、无 schedule 执行）+ 存档兼容；给 `wu_zhiyuan.json` 加位置字段；`data/locations.json` 建好 | 0.5 天 | 无可见变化，基础设施就绪 |
| **M2** | `NpcSpawner` 替换 Main.tscn 硬节点；`LocationBase` 加 spawner；单 NPC 数据驱动生成 | 0.5 天 | 村长从数据生成，占位地点也能有 NPC |
| **M3** | schedule 生效 + 对话轮推进时间 + 时段边界离场（F6/F7）；DialogueUI 注入场景状态 prompt | 1 天 | **世界开始活过来**：村长会按时段挪窝、到点告辞 |
| **M4** | 地图/场景 UI：NpcPresenceBar + MapNpcBadge + "？？？"占位；`visited_locations` | 0.5 天 | 玩家一眼看到"谁在哪儿" |
| **M5** | 事件规则层（L2）+ 跟随（F10）+ 说服裁决器（L3-A） | 2 天 | 说服、跟随、剧情驱动位移都能用 |
| **M6** | `GroupChatCoordinator`：并行 N 路LLM 调用、公聊缓冲区、公聊 UI（气泡多条、6轮/30 分钟上限、@ 提示）| 2 天 | 玩家可以在多 NPC 在场时点"召集所有人谈话"，每人独立参与 |

**总计约 6.5 天**。M1–M3 是必须依次完成的地基；M4/M5/M6 之间弱依赖，可以并行/换序。

---

## 12. 风险与折中

| 风险 | 缓解 |
|---|---|
| LLM 输出的 `action` JSON 校验失败 | 白名单 + 结构失败即视为 `action.type=none`，不影响 reply 显示 |
| 时段边界导致对话被硬截断，破坏叙事节奏 | 用软指令让 NPC 自己说要走 + `[END_DIALOGUE]` tag 兜底；说服可延后 15 分钟 |
| 公聊中 N 个并发请求延迟高 | UI 显示 loading，先返回先显示；单个超时视为该 NPC 沉默，不阻塞整轮 |
| 公聊 ≥4 人时刷屏 | 每轮最多显示 3 条发言；其余人本轮压成沉默，按 importance + sort_priority 排序 |
| 公聊里 NPC 秘密相互串（人格泄漏） | 每个 NPC 独立 system_prompt + 独立 memory + 只通过公聊缓冲区听到别人说了什么，不会拿到别人的 history/summary |
| 存档跨版本迁移 | SAVE_VERSION bump + `_migrate_v1_to_v2()`；schedule 缺失时全部回落 `home_location` |
| NPC schedule 生成不合理（M5 若上LLM 每日晨规划） | 本方案**不做每日晨规划**，schedule 全部**人写死**，只有说服/事件规则能临时改，可控性最高 |
| 玩家在世界地图静置 → 时间不推 | 这是符合玩法的（时间由玩家行动推动），若想加"发呆"按钮再说 |

---

## 13. 快速答复：你问题中的 4 个具体点

1. **"能否做每日固定 schedule + 用户请求临时修改"** → 100% 可做。schedule 是死数据，临时修改统一走 `NpcRegistry.move_npc(source="llm"|"event")`。见 §5、§8。

2. **"陪同/跟随可否"** → 可做。见 §5.3。跟随中的 NPC 暂停 schedule，玩家每次 `enter_location` 时同步挪动，每步写全局记忆让其他 NPC "看见"。

3. **"NPC context 里要有当前位置 + 同地点其他人 + 存进记忆"** → 已并入 §6.3；prompt 层注入 + `MemoryStore` 记录 NPC 位置迁移，其他 NPC 因共享 `global_memory` 会自然感知到。

4. **"多人对话，私聊/公聊、公聊时每 NPC 独立完整调用 LLM"** → 见 §9。
   - **默认私聊**（点开谁跟谁聊，UI 与现在一致）。
   - **公聊入口**：`NpcPresenceBar` 上的"召集所有人谈话"按钮，仅当在场 NPC ≥2 时可用。
   - **公聊规格= 私聊规格**：每个 NPC 都用自己的完整 `system_prompt` + 完整 memory + 完整 history + 场景状态。
   - **调用方式**：N 个独立 `HTTPRequest` 实例并行发出，无需任何客户端 KV cache；服务端 Prompt Cache 按稳定前缀自动命中。
   - **上限**：6 轮 / 30 分钟游戏时间；每轮最多 3 条发言（>3 人时压排）。
   - **成本**：DeepSeek 单次公聊约 1 毛钱，全流程 20 天约 3 块钱；瓶颈是延迟不是钱。

---

## 14. 下一步

方案确认后从 M1 开工。M1 只碰以下文件、纯新增/追加字段，**不改任何已有逻辑**，风险最低：
- 新增：`scripts/autoload/TimeSystem.gd`、`scripts/autoload/NpcRegistry.gd`、`data/locations.json`
- 追加字段：`data/npcs/wu_zhiyuan.json`（加 `home_location/current_location/schedule/importance`）
- 追加：`project.godot` 的 autoload 段登记两个新单例
- 追加：`GameState.save_game/load_game` 里带上 TimeSystem/NpcRegistry 状态，bump SAVE_VERSION

M1 完成后即可开 M2，`NpcSpawner` 替换 Main.tscn 硬节点，从此 NPC 正式变数据实体。
