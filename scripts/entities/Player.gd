extends CharacterBody2D
## Player
## 2D 等距视角玩家角色。
## - WASD 移动；为了等距错觉，Y 方向速度压缩到 ~50%（视觉等距投影约 2:1）
## - 进入 NPC 的 InteractArea 时，按 E 触发对话
##
## 当前用 Polygon2D 占位绘制小人（项目还没立绘资源）。

const MOVE_SPEED := 220.0
const ISO_Y_RATIO := 0.5     # 等距视角下 Y 方向速度比例
const INTERACT_ACTION := "interact"

## 当前可交互的 NPC（None 表示玩家不在任何 NPC 触发区内）
var current_npc: Node = null


func _physics_process(_delta: float) -> void:
	var input_vec := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()
	# 等距投影补偿
	input_vec.y *= ISO_Y_RATIO
	velocity = input_vec * MOVE_SPEED
	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(INTERACT_ACTION) and current_npc != null:
		if current_npc.has_method("on_player_interact"):
			current_npc.on_player_interact(self)


## NpcInteractable 进入 / 离开时会调
func set_nearby_npc(npc: Node) -> void:
	current_npc = npc

func clear_nearby_npc(npc: Node) -> void:
	if current_npc == npc:
		current_npc = null
