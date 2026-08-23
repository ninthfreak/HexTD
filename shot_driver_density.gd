extends Node
## Dev-only: how clumped are enemies in a big wave? Reports the per-hex-cell
## occupancy distribution, which is what a crowd-aware LOD would key on.

func drive(main) -> void:
	var n := int(OS.get_environment("STRESS_ENEMIES")) if OS.get_environment("STRESS_ENEMIES") != "" else 400
	var eids: Array = main.content.enemy_ids()
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var total_len := 0.0
	for i in range(path_pts.size() - 1):
		total_len += path_pts[i].distance_to(path_pts[i + 1])
	for k in n:
		var ed = main.content.enemy(eids[k % eids.size()])
		if ed == null:
			continue
		var pl: Dictionary = main._forward_along(path_pts, fmod(float(k) * 37.7, total_len * 0.9) + 5.0)
		var e := Enemy3D.new()
		e.setup(ed, path_pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
	for i in 40:
		await get_tree().process_frame
	# Occupancy per hex cell.
	var per_cell := {}
	var alive := 0
	for e in main.board.enemies:
		if not is_instance_valid(e):
			continue
		alive += 1
		per_cell[e.cell] = int(per_cell.get(e.cell, 0)) + 1
	var buckets := {1: 0, 2: 0, 3: 0, 5: 0, 8: 0}
	var shared := 0
	var maxocc := 0
	for c in per_cell:
		var occ: int = per_cell[c]
		maxocc = maxi(maxocc, occ)
		if occ > 1:
			shared += occ
		for t in buckets:
			if occ >= t:
				buckets[t] = int(buckets[t]) + occ
	print("DENSITY: alive=", alive, " occupied_cells=", per_cell.size(),
		" mean_per_cell=%.2f" % (float(alive) / maxf(1.0, float(per_cell.size()))), " max_in_a_cell=", maxocc)
	print("DENSITY: sharing a cell with anyone: ", shared, " (", int(round(100.0 * shared / maxf(1, alive))), "%)")
	for t in [2, 3, 5, 8]:
		print("DENSITY:   in cells holding >=%d: %d (%d%%)" % [t, buckets[t], int(round(100.0 * float(buckets[t]) / maxf(1.0, float(alive))))])
