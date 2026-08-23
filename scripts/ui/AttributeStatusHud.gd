extends CanvasLayer
## 左上角实时属性条：展示包含永久调整与当日增益在内的最终属性。

@onready var attribute_label: Label = $Panel/AttributeLabel


func _ready() -> void:
	# 高于对话、线索册和普通场景交互层，确保游戏过程中始终留在左上角。
	layer = 40
	if not GameState.attributes_changed.is_connected(_refresh):
		GameState.attributes_changed.connect(_refresh)
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
