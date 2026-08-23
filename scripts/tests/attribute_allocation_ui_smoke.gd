extends Node


func _ready() -> void:
	GameState.reset_for_new_game()
	var packed := load("res://scenes/ui/AttributeAllocation.tscn") as PackedScene
	if packed == null:
		_fail("AttributeAllocation scene could not be loaded")
		return
	var allocation := packed.instantiate()
	add_child(allocation)
	await get_tree().process_frame
	await get_tree().process_frame
	if int(allocation.call("_remaining")) != 0:
		_fail("Starter allocation no longer spends all ten points")
		return
	var footer := allocation.get_node("Paper/Content/Footer") as Control
	if footer.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_fail("Footer overlay intercepts the attribute adjustment buttons")
		return
	var rows: Dictionary = allocation.get("_rows")
	var strength_row: Dictionary = rows.get("strength", {})
	var strength_minus := strength_row.get("minus") as TextureButton
	var strength_plus := strength_row.get("plus") as TextureButton
	if strength_minus == null or strength_plus == null:
		_fail("Strength adjustment buttons were not created")
		return
	strength_minus.emit_signal("pressed")
	if int(allocation.call("_remaining")) != 1:
		_fail("Minus button did not decrease strength and restore one point")
		return
	strength_plus.emit_signal("pressed")
	if int(allocation.call("_remaining")) != 0:
		_fail("Plus button did not increase strength and spend one point")
		return
	var reset_button := allocation.get_node("Paper/Content/Footer/ResetBtn") as TextureButton
	reset_button.emit_signal("pressed")
	if int(allocation.call("_remaining")) != GameState.ATTRIBUTE_TOTAL_POINTS:
		_fail("Reset button did not restore all available points")
		return
	strength_plus.emit_signal("pressed")
	if int(allocation.call("_remaining")) != GameState.ATTRIBUTE_TOTAL_POINTS - 1:
		_fail("Plus button did not update the remaining-points display state")
		return
	# Restore the reference layout before saving the visual regression preview.
	allocation.queue_free()
	await get_tree().process_frame
	allocation = packed.instantiate()
	add_child(allocation)
	await get_tree().process_frame
	await get_tree().process_frame
	if DisplayServer.get_name() == "headless":
		print("ATTRIBUTE_ALLOCATION_UI_SMOKE_OK")
		get_tree().quit(0)
		return
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		# Headless dummy renderer has no framebuffer; functional assertions above still ran.
		print("ATTRIBUTE_ALLOCATION_UI_SMOKE_OK")
		get_tree().quit(0)
		return
	var image := viewport_texture.get_image()
	if image == null:
		print("ATTRIBUTE_ALLOCATION_UI_SMOKE_OK")
		get_tree().quit(0)
		return
	var save_error := image.save_png("res://.godot/attribute_allocation_preview.png")
	if save_error != OK:
		_fail("Could not save attribute allocation preview")
		return
	print("ATTRIBUTE_ALLOCATION_UI_SMOKE_OK")
	get_tree().quit(0)

func _fail(message: String) -> void:
	push_error("ATTRIBUTE_ALLOCATION_UI_SMOKE_FAILED: " + message)
	get_tree().quit(1)
