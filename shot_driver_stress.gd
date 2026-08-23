extends Node
## Dev-only stress benchmark driver: floods the board with enemies + towers,
## runs combat for a fixed frame count, and prints frame-time statistics.
## Loaded by shotter.gd via SHOT_DRIVER. Env knobs:
##   STRESS_ENEMIES (default 400)   STRESS_FRAMES (default 240)

func drive(main) -> void:
	main.money = 9999999
	var n_enemies := int(OS.get_environment("STRESS_ENEMIES")) if OS.get_environment("STRESS_ENEMIES") != "" else 400
	var n_frames := int(OS.get_environment("STRESS_FRAMES")) if OS.get_environment("STRESS_FRAMES") != "" else 240
	var n_towers := int(OS.get_environment("STRESS_TOWERS")) if OS.get_environment("STRESS_TOWERS") != "" else 12

	# Towers: fill every legal spot near the path (same ranking as the populated
	# driver) so targeting/firing load is realistic.
	var ids: Array = main.content.tower_ids()
	var path_pts: PackedVector2Array = main.board.get_path_points()
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
	var placed := 0
	for entry in ranked:
		if placed >= n_towers:
			break
		var c2: Vector2i = entry["c"]
		if not main.board.is_buildable(c2):
			continue
		main.placing_id = ids[placed % ids.size()]
		if main._try_place(c2):
			placed += 1
	main.placing_id = ""

	# Enemies: every type, spread across the whole path so every tower engages.
	var eids: Array = main.content.enemy_ids()
	var total_len := 0.0
	for i in range(path_pts.size() - 1):
		total_len += path_pts[i].distance_to(path_pts[i + 1])
	for k in n_enemies:
		var ed = main.content.enemy(eids[k % eids.size()])
		if ed == null:
			continue
		var pl: Dictionary = main._forward_along(path_pts, fmod(float(k) * 37.7, total_len * 0.9) + 5.0)
		var e := Enemy3D.new()
		e.bounty.connect(main._on_enemy_bounty)
		e.reached_goal.connect(main._on_enemy_reached_goal)
		e.split.connect(main._on_enemy_split)
		e.setup(ed, path_pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)

	if OS.get_environment("ZOOM_DIST") != "":
		main.cam_distance = float(OS.get_environment("ZOOM_DIST"))
		main._target_distance = main.cam_distance
		main._update_camera_transform()
	print("STRESS: towers=", placed, " enemies=", main.board.enemies.size(), " frames=", n_frames)
	# Warm up (spawn pops, first shots) before measuring.
	for i in 30:
		await get_tree().process_frame
	var proc_ms: Array = []
	var frame_ms: Array = []
	var last := Time.get_ticks_usec()
	for i in n_frames:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append(float(now - last) / 1000.0)
		proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		last = now
	proc_ms.sort()
	frame_ms.sort()
	var mean := 0.0
	for v in proc_ms:
		mean += v
	mean /= proc_ms.size()
	print("STRESS: alive_end=", main.board.enemies.size(),
		" nodes=", Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		" orphans=", Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("STRESS: render objects=", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		" draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		" primitives=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	print("STRESS: process_ms mean=%.2f p50=%.2f p95=%.2f max=%.2f" % [
		mean, proc_ms[proc_ms.size() / 2], proc_ms[int(proc_ms.size() * 0.95)], proc_ms[proc_ms.size() - 1]])
	print("STRESS: frame_ms   p50=%.2f p95=%.2f (includes software-GL render; not GPU-representative)" % [
		frame_ms[frame_ms.size() / 2], frame_ms[int(frame_ms.size() * 0.95)]])
