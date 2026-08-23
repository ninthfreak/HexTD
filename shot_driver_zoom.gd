extends Node
## Dev-only: spawn a spread of enemy sizes, aim the camera at them, and park it
## at ZOOM_DIST so on-screen detail at a given zoom can be judged from a frame.
## Enemy3D picks its own detail tier from apparent size, so this also exercises
## the distance LOD: at 1600 the small shapes drop their edge outline.

func drive(main) -> void:
	var dist := float(OS.get_environment("ZOOM_DIST")) if OS.get_environment("ZOOM_DIST") != "" else 400.0
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var picks := ["bit", "quadlet", "kibibyte", "tebibyte", "ecc_quadlet", "enc_octaword"]
	var d := 120.0
	var centre := Vector2.ZERO
	var n := 0
	for id in picks:
		var ed = main.content.enemy(id)
		if ed == null:
			continue
		var pl: Dictionary = main._forward_along(path_pts, d)
		var e := Enemy3D.new()
		e.setup(ed, path_pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
		e.take_damage(ed.health * 0.45, false)
		centre += e.pp
		n += 1
		d += 70.0
	if n > 0:
		centre /= float(n)
	main.cam_pivot.position = Vector3(centre.x, 0.0, centre.y)
	main.cam_distance = dist
	main._target_distance = dist
	main._update_camera_transform()
	for i in 5:
		await get_tree().process_frame
	print("ZOOM: dist=", main.cam_distance, " centre=", centre)
