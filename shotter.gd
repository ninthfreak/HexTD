extends Node
## Dev-only screenshot harness (not shipped). Reads SHOT_* env vars, loads the
## requested scene as a child, optionally runs a driver script against it,
## waits, then saves the viewport to a PNG and quits.

func _ready() -> void:
	var mode := OS.get_environment("SHOT_MODE")
	if mode == "":
		mode = "sandbox"
	var scene_path := OS.get_environment("SHOT_SCENE")
	if scene_path == "":
		scene_path = "res://scenes/main_3d.tscn"
	var out := OS.get_environment("SHOT_OUT")
	if out == "":
		out = "/tmp/shot.png"
	var frames := 40
	if OS.get_environment("SHOT_FRAMES") != "":
		frames = int(OS.get_environment("SHOT_FRAMES"))
	GameState.mode = mode
	GameState.selected_path = OS.get_environment("SHOT_MAP")

	var ps: PackedScene = load(scene_path)
	var inst := ps.instantiate()
	get_tree().root.add_child.call_deferred(inst)
	await get_tree().process_frame

	# Let the scene initialize a couple frames before driving it.
	for i in 3:
		await get_tree().process_frame

	var driver_path := OS.get_environment("SHOT_DRIVER")
	if driver_path != "":
		var drv: GDScript = load(driver_path)
		var d: Node = drv.new()
		get_tree().root.add_child(d)
		if d.has_method("drive"):
			await d.drive(inst)

	for i in frames:
		await get_tree().process_frame
	# Headless (benchmark) runs have no viewport texture — skip the capture but
	# still quit cleanly.
	var tex := get_viewport().get_texture()
	if tex != null and DisplayServer.get_name() != "headless":
		tex.get_image().save_png(out)
		print("SHOT SAVED: ", out)
	get_tree().quit()
