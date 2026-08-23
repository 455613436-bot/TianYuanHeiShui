extends CanvasLayer
## 左上角实时属性条：展示包含永久调整与当日增益在内的最终属性。

const ATTRIBUTE_RULES_TOOLTIP := "初始属性每项 0–5、总计 10；剧情永久成长可突破 5，且没有最终硬上限；每日临时加成会在下一次清晨重新结算。"

@onready var attribute_label: Label = $Panel/AttributeLabel


func _ready() -> void:
	# 高于对话、线索册和普通场景交互层，确保游戏过程中始终留在左上角。
	layer = 40
	if not GameState.attributes_changed.is_connected(_refresh):
		GameState.attributes_changed.connect(_refresh)
	attribute_label.mouse_filter = Control.MOUSE_FILTER_STOP
	attribute_label.tooltip_text = ATTRIBUTE_RULES_TOOLTIP
	_refresh()


func _refresh() -> void:
	# 游戏内始终显示。尚未完成分配时以 0 展示，完成分配或获得增益后立即刷新。
	visible = true
	attribute_label.text = "力量 %d　敏捷 %d　智力 %d　魅力 %d" % [
		GameState.get_attribute("strength"),
		GameState.get_attribute("agility"),
		GameState.get_attribute("intellect"),
		GameState.get_attribute("charisma"),
	]
