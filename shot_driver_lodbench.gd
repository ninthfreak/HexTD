extends Node
## Dev-only LOD benchmark. Runs a realistic post-cascade population with towers
## present (so the bucket/crowd index actually rebuilds) and reports, per LOD
## mode, the script CPU cost and the draw submission cost. Env:
##   LODB_ENEMIES (600)  LODB_TOWERS (12)  LODB_FRAMES (150)  ZOOM_DIST
##
## NOTE: under software GL the FRAME time is not GPU-representative. Script
## process time and draw-call / primitive counts are.

var _pts: PackedVector2Array

func _stats(main) -> Dictionary:
	var alive := 0
	var reduced := 0
	var by_size := 0
	var by_crowd := 0
	var crowd_sum := 0
	var vh: float = maxf(get_viewport().get_visible_rect().size.y, 1.0)
	for e in main.board.enemies:
		if not is_instance_valid(e) or not e._alive:
			continue
		alive += 1
		crowd_sum += e.crowd
		if e._lod_reduced:
			reduced += 1
		var dx: float = Enemy3D.lod_cam_pos.x - e.pp.x
		var dy: float = Enemy3D.lod_cam_pos.y - GameBoard3D.ENEMY_Y
		var dz: float = Enemy3D.lod_cam_pos.z - e.pp.y
		var d: float = maxf(1.0, sqrt(dx * dx + dy * dy + dz * dz))
		if e.hit_radius * Enemy3D.lod_k / d < Enemy3D.LOD_DROP_PX:
			by_size += 1
		if not e.crowd_lead and e.crowd >= Enemy3D.LOD_CROWD_MIN:
			by_crowd += 1
	return {"alive": alive, "reduced": reduced, "by_size": by_size,
		"by_crowd": by_crowd, "crowd_avg": float(crowd_sum) / float(maxi(alive, 1)),
		"viewport_h": vh}

func _populate(main, n: int) -> void:
	for e in main.board.enemies.duplicate():
		if is_instance_valid(e):
			e.queue_free()
	await get_tree().process_frame
	# Post-cascade population: the small decay forms a big enemy breaks into,
	# spread along the route the way _walk_back actually spaces them.
	var forms: Array = []
	for id in ["bit", "crumb", "nybble", "byte", "doublet"]:
		var ed = main.content.enemy(id)
		if ed != null:
			forms.append(ed)
	if forms.is_empty():
		forms.append(main.content.enemy(main.content.enemy_ids()[0]))
	var total_len := 0.0
	for i in range(_pts.size() - 1):
		total_len += _pts[i].distance_to(_pts[i + 1])
	for k in n:
		var ed = forms[k % forms.size()]
		var pl: Dictionary = main._forward_along(_pts, fmod(float(k) * 13.7, total_len * 0.9) + 5.0)
		var e := Enemy3D.new()
		e.bounty.connect(main._on_enemy_bounty)
		e.reached_goal.connect(main._on_enemy_reached_goal)
		e.split.connect(main._on_enemy_split)
		e.setup(ed, _pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		e.data = ed
		main.board.add_enemy(e)

func drive(main) -> void:
	main.money = 999999999
	_pts = main.board.get_path_points()
	var n_enemies := 600
	if OS.get_environment("LODB_ENEMIES") != "":
		n_enemies = int(OS.get_environment("LODB_ENEMIES"))
	var n_towers := 12
	if OS.get_environment("LODB_TOWERS") != "":
		n_towers = int(OS.get_environment("LODB_TOWERS"))
	var n_frames := 150
	if OS.get_environment("LODB_FRAMES") != "":
		n_frames = int(OS.get_environment("LODB_FRAMES"))
	if OS.get_environment("ZOOM_DIST") != "":
		main.cam_distance = float(OS.get_environment("ZOOM_DIST"))
		main._target_distance = main.cam_distance
		main._update_camera_transform()

	# Towers: needed so _refresh_buckets() actually runs (it is driven by tower
	# targeting queries, not by a per-frame tick).
	var ids: Array = main.content.tower_ids()
	var ranked: Array = []
	for c in main.map.buildable:
		var w: Vector2 = main.board.cell_center_world(c)
		var best := 1e9
		for p in _pts:
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

	print("LODB: renderer=%s  viewport=%s  towers=%d  enemies=%d  cam=%.0f"
		% [DisplayServer.get_name(), str(get_viewport().get_visible_rect().size),
		   placed, n_enemies, main.cam_distance])

	for mode in ["LOD on", "LOD off"]:
		await _populate(main, n_enemies)
		for i in 40:
			await get_tree().process_frame
			if mode == "LOD off":
				for e in main.board.enemies:
					if is_instance_valid(e) and e._alive:
						e._apply_lod(false)
		var proc: Array = []
		var frame_ms: Array = []
		var draws := 0.0
		var prims := 0.0
		var objs := 0.0
		var last := Time.get_ticks_usec()
		var samples := 0
		for i in n_frames:
			await get_tree().process_frame
			if mode == "LOD off":
				for e in main.board.enemies:
					if is_instance_valid(e) and e._alive:
						e._apply_lod(false)
			var now := Time.get_ticks_usec()
			frame_ms.append(float(now - last) / 1000.0)
			last = now
			proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
			draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			objs += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
			samples += 1
		proc.sort()
		frame_ms.sort()
		var st: Dictionary = _stats(main)
		print("LODB: --- %s ---" % mode)
		print("LODB:   alive=%d  reduced=%d%%  (would-drop by_size=%d%% by_crowd=%d%%)  avg enemies/cell=%.1f"
			% [st["alive"], int(100.0 * float(st["reduced"]) / float(maxi(st["alive"], 1))),
			   int(100.0 * float(st["by_size"]) / float(maxi(st["alive"], 1))),
			   int(100.0 * float(st["by_crowd"]) / float(maxi(st["alive"], 1))), st["crowd_avg"]])
		print("LODB:   script_ms p50=%.2f p95=%.2f | frame_ms p50=%.2f (software GL — not GPU-representative)"
			% [proc[proc.size() / 2], proc[int(proc.size() * 0.95)], frame_ms[frame_ms.size() / 2]])
		print("LODB:   draw_calls=%d  primitives=%d  objects=%d  (per-frame avg)"
			% [int(draws / samples), int(prims / samples), int(objs / samples)])
	print("LODB: done")
