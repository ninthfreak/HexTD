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
	var n_ok := 0
	for c2 in main.map.buildable:
		if main.board.is_buildable(c2):
			n_ok += 1
	print("DRIVER: placed ", placed_cells.size(), "; is_buildable-ok=", n_ok, "/", main.map.buildable.size(), " bset=", main.board.buildable_set.size(), " occ=", main.board.occupied.size(), " money=", main.money)

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
		var t = main.board.tower_at(placed_cells[0])
		if t != null:
			main._select_tower(placed_cells[0], t)

	# Let combat play out a moment so beams/projectiles are visible.
	for i in 50:
		await get_tree().process_frame
