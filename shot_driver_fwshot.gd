extends Node
## Dev-only: place a Firewall Daemon, let it deploy its rules, and frame the
## camera on them so the deployed-rule graphic can actually be looked at.
func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "firewall"
	main._try_place(spot)
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	tw.data.fire_rate = 6.0          # deploy the whole set quickly for the shot
	for i in 240:
		await get_tree().process_frame
	# a couple of bodies crossing, so a partly-spent rule is visible too
	for k in 3:
		var ed := EnemyData.new()
		ed.health = 1e9
		ed.speed = 22.0
		ed.color = Color(0.9, 0.35, 0.35)
		ed.radius = 15.0
		var e := Enemy3D.new()
		e.setup(ed, pts)
		var pl: Dictionary = main._forward_along(pts, 30.0 + 26.0 * float(k))
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
	# frame on the tower's stretch of route
	var w: Vector2 = main.board.cell_center_world(spot)
	main.cam_pivot.position = Vector3(w.x, 0.0, w.y)
	main.cam_distance = 230.0
	main._target_distance = main.cam_distance
	main._update_camera_transform()
	for i in 90:
		await get_tree().process_frame
	var n := 0
	for c in main.board._entities.get_children():
		if c is FirewallRule3D and is_instance_valid(c):
			n += 1
	print("FWSHOT: %d rules on the board, camera at %.0f" % [n, main.cam_distance])
