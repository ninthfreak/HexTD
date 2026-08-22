extends Node
## Dev-only screenshot driver: populates the board with towers + enemies so a
## screenshot shows real gameplay. Loaded by shotter.gd via SHOT_DRIVER.

func drive(main) -> void:
	main.money = 999999
	var ids: Array = main.content.tower_ids()
	var path_pts: PackedVector2Array = main.board.get_path_points()
	# Rank buildable cells by distance to the path and take the nearest legal
	# footprints (the 7-cell footprint keeps centers a ring or two off the path).
	var ranked: Array = []
	for c in main.map.buildable:
		var w: Vector2 = main.board.cell_center_world(c)
		var best := 1e9
		for p in path_pts:
			var dd: float = w.distance_to(p)
			if dd < best:
				best = dd
		ranked.append({"c": c, "d": best})
	ranked.sort_custom(func(a, b): return a["d"] < b["d"])
	var placed_cells: Array = []
	for entry in ranked:
		if placed_cells.size() >= ids.size():
			break
		var c: Vector2i = entry["c"]
		if not main.board.is_buildable(c):
			continue
		# Skip spots adjacent to an already placed tower so they spread out.
		var too_close := false
		for pc in placed_cells:
			if HexUtils.axial_distance(c, pc) < 4:
				too_close = true
				break
		if too_close:
			continue
		main.placing_id = ids[placed_cells.size() % ids.size()]
		if main._try_place(c):
			placed_cells.append(c)
	main.placing_id = ""
	print("DRIVER: placed ", placed_cells.size(), " towers")

	var eids: Array = main.content.enemy_ids()
	var dist := 30.0
	for eid in eids:
		var ed = main.content.enemy(eid)
		if ed == null:
			continue
		for k in 2:
			var pl: Dictionary = main._forward_along(path_pts, dist)
			var e := Enemy3D.new()
			e.bounty.connect(main._on_enemy_bounty)
			e.reached_goal.connect(main._on_enemy_reached_goal)
			e.split.connect(main._on_enemy_split)
			e.setup(ed, path_pts)
			e.place_on_path(int(pl["index"]), pl["pos"])
			main.board.add_enemy(e)
			dist += 45.0

	if not placed_cells.is_empty():
		# Select the LEFTMOST tower: near the board edge (range clips the
		# boundary — the historical overlay-breaking case) AND on-camera (the
		# board's right side hides behind the UI pane).
		var pick: Vector2i = placed_cells[0]
		var pick_x := 1e9
		for pc2 in placed_cells:
			var w2: Vector2 = main.board.cell_center_world(pc2)
			if w2.x < pick_x:
				pick_x = w2.x
				pick = pc2
		var t = main.board.tower_at(pick)
		if t != null:
			main._select_tower(pick, t)
			# Mixed tier state (3/2/0) so the shot shows purchasable + both
			# locked flavors of the upgrade buttons.
			for s3 in [0, 0, 0, 1, 1]:
				main._on_upgrade_pressed(s3)

	# Let combat play out a moment so beams/projectiles are visible.
	for i in 50:
		await get_tree().process_frame
