extends Node
## Dev-only: after a big body decays, how many of its children spend their first
## frames at FULL detail? Without prime_lod they wait out the staggered test.
func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	# Towers so _refresh_buckets() runs (it is driven by tower targeting queries).
	var ranked := []
	for c in main.map.buildable:
		var w: Vector2 = main.board.cell_center_world(c)
		var best := 1e9
		for p in pts:
			var dd: float = w.distance_to(p)
			if dd < best:
				best = dd
		ranked.append({"c": c, "d": best})
	ranked.sort_custom(func(a, b): return a["d"] < b["d"])
	var ids: Array = main.content.tower_ids()
	var placed := 0
	for entry in ranked:
		if placed >= 8:
			break
		main.placing_id = ids[placed % ids.size()]
		if main._try_place(entry["c"]):
			placed += 1
	main.placing_id = ""
	var ed = main.content.enemy("kibibyte")
	if ed == null:
		print("PRIME: no kibibyte")
		return
	var total_len := 0.0
	for i in range(pts.size() - 1):
		total_len += pts[i].distance_to(pts[i + 1])
	for k in 6:
		var pl: Dictionary = main._forward_along(pts, fmod(float(k) * 197.0, total_len * 0.7) + 5.0)
		var e := Enemy3D.new()
		e.bounty.connect(main._on_enemy_bounty)
		e.reached_goal.connect(main._on_enemy_reached_goal)
		e.split.connect(main._on_enemy_split)
		e.setup(ed, pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
	for i in 30:
		await get_tree().process_frame
	print("PRIME: detonating — sampling the FIRST frame after each split round")
	print("PRIME: %-6s %7s %8s %8s %10s %9s" % ["round", "alive", "f1", "f2", "settled", "gap f1"])
	var worst := 0
	for round_i in 8:
		for e in main.board.enemies.duplicate():
			if is_instance_valid(e) and e._alive:
				e.take_damage(1e12)
		await get_tree().process_frame          # the very next frame after the split
		var a1 := 0
		var f1 := 0
		for e in main.board.enemies:
			if not is_instance_valid(e) or not e._alive:
				continue
			a1 += 1
			if not e._lod_reduced:
				f1 += 1
		if a1 == 0:
			break
		await get_tree().process_frame
		var a15 := 0
		var f15 := 0
		for e in main.board.enemies:
			if not is_instance_valid(e) or not e._alive:
				continue
			a15 += 1
			if not e._lod_reduced:
				f15 += 1
		# Ten frames later every enemy has had its staggered test at least once,
		# so this is the tier the board SETTLES on. If priming works, frame 1
		# already matches it; if it does not, frame 1 is inflated and the gap is
		# the transient.
		for i in 10:
			await get_tree().process_frame
		var a2 := 0
		var f2 := 0
		for e in main.board.enemies:
			if not is_instance_valid(e) or not e._alive:
				continue
			a2 += 1
			if not e._lod_reduced:
				f2 += 1
		var p1: int = int(100.0 * float(f1) / float(maxi(a1, 1)))
		var p2: int = int(100.0 * float(f2) / float(maxi(a2, 1)))
		worst = maxi(worst, p1 - p2)
		print("PRIME: %-6d %7d %8d%% %8d%% %10d%% %9d" % [round_i + 1, a1, p1,
			int(100.0 * float(f15) / float(maxi(a15, 1))), p2, p1 - p2])
	print("PRIME: worst frame-1 excess over settled tier = %d points (0 = no transient)" % worst)
	print("PRIME: done")
