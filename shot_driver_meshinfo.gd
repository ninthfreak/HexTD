extends Node
## Dev-only: per-enemy-type triangle counts, split faces vs edge outline.

func drive(main) -> void:
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var seen := {}
	var tot_f := 0
	var tot_e := 0
	var n := 0
	for id in main.content.enemy_ids():
		var ed = main.content.enemy(id)
		if ed == null or seen.has(ed.shape):
			continue
		seen[ed.shape] = true
		var e := Enemy3D.new()
		e.setup(ed, path_pts)
		main.board.add_enemy(e)
		await get_tree().process_frame
		var m: ArrayMesh = e._body.mesh
		var f := 0
		var g := 0
		if m.get_surface_count() > 0:
			f = m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3
		if m.get_surface_count() > 1:
			g = m.surface_get_arrays(1)[Mesh.ARRAY_VERTEX].size() / 3
		tot_f += f
		tot_e += g
		n += 1
		print("MESH: %-30s r=%2d  faces=%4d tris  edges=%4d tris  edge share=%3d%%" % [
			ed.shape, int(ed.radius), f, g, int(round(100.0 * float(g) / maxf(1.0, float(f + g))))])
	print("MESH: TOTAL over %d shapes: faces=%d edges=%d -> edges are %d%% of enemy geometry" % [
		n, tot_f, tot_e, int(round(100.0 * float(tot_e) / maxf(1.0, float(tot_f + tot_e))))])
