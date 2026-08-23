extends Node
## Dev-only regression fingerprint for TOWER TARGETING.
##
## Runs a fixed scenario — seeded RNG, deterministic tower placement covering
## every fire mode and all four target priorities, deterministic enemy spawns —
## and prints a fingerprint of the combat outcome. Any change to which enemy a
## tower picks, or when damage lands, moves these numbers. Visual-only work must
## leave them byte-identical.

func drive(main) -> void:
	seed(1234567)
	main.money = 9999999
	var ids: Array = main.content.tower_ids()
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var prios := ["first", "last", "strongest", "weakest"]

	# Towers: nearest-to-path buildable cells, cycling fire modes and priorities.
	var ranked: Array = []
	for c in main.map.buildable:
		var w: Vector2 = main.board.cell_center_world(c)
		var best := 1e9
		for p in path_pts:
			var dd: float = w.distance_to(p)
			if dd < best:
				best = dd
		ranked.append({"c": c, "d": best})
	ranked.sort_custom(func(a, b): return a["d"] < b["d"] if a["d"] != b["d"] else a["c"].x < b["c"].x)
	var placed := 0
	for entry in ranked:
		if placed >= 12:
			break
		var c2: Vector2i = entry["c"]
		if not main.board.is_buildable(c2):
			continue
		main.placing_id = ids[placed % ids.size()]
		if main._try_place(c2):
			var t = main.board.tower_at(c2)
			# Drive the priority to the wanted one through the public API.
			var want: String = prios[placed % prios.size()]
			for i in 8:
				if t.target_priority == want:
					break
				t.cycle_target_priority()
			placed += 1
	main.placing_id = ""

	# Enemies: every type, evenly spread, deterministic.
	var eids: Array = main.content.enemy_ids()
	var total_len := 0.0
	for i in range(path_pts.size() - 1):
		total_len += path_pts[i].distance_to(path_pts[i + 1])
	for k in 240:
		var ed = main.content.enemy(eids[k % eids.size()])
		if ed == null:
			continue
		var pl: Dictionary = main._forward_along(path_pts, fmod(float(k) * 29.3, total_len * 0.85) + 8.0)
		var e := Enemy3D.new()
		e.bounty.connect(main._on_enemy_bounty)
		e.reached_goal.connect(main._on_enemy_reached_goal)
		e.split.connect(main._on_enemy_split)
		e.setup(ed, path_pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)

	for i in 400:
		await get_tree().process_frame

	# Fingerprint: outcome of the fight, insensitive to draw order but sensitive
	# to which enemies were shot and when.
	var alive := 0
	var hp_sum := 0.0
	var prog_sum := 0
	for e in main.board.enemies:
		if not is_instance_valid(e):
			continue
		alive += 1
		hp_sum += e.health
		prog_sum += e.progress()
	print("TARGET: towers=%d alive=%d hp_sum=%.3f prog_sum=%d money=%d lives=%d" % [
		placed, alive, hp_sum, prog_sum, main.money, main.lives])
