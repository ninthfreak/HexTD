extends Node
## Dev-only BALANCE probe: measures real throughput of every tower against a
## standing target, using the game's own combat code (targeting, fire modes,
## projectile travel, LOS, abilities) rather than a formula.
##
## Method: park one tower next to a stationary high-HP dummy inside its range,
## run a fixed number of frames, and read the HP removed. That isolates damage
## output from placement and pathing. Trials are sequential in ONE process, so
## project load is paid once.

const SECONDS := 6.0
const DUMMY_HP := 1.0e9

func drive(main) -> void:
	seed(99)
	main.money = 999999999
	var frames := int(SECONDS * 60.0)
	print("BAL: tower                cost   dps      dps/100c  notes")
	for id in main.content.tower_ids():
		var td = main.content.tower(str(id))
		if td == null:
			continue
		var res: Array = await _trial(main, str(id), td, frames)
		var dps: float = res[0]
		var note: String = res[1]
		print("BAL: %-20s %5d  %7.1f  %8.2f  %s" % [
			td.display_name, td.cost, dps, dps / maxf(1.0, float(td.cost)) * 100.0, note])

## One tower vs one standing dummy. Returns [dps, note].
func _trial(main, id: String, td, frames: int) -> Array:
	# Clear the board of anything the previous trial left.
	for e in main.board.enemies.duplicate():
		if is_instance_valid(e):
			e.queue_free()
	main.board.enemies.clear()
	for c in main.board.occupied.keys():
		main.board.remove_tower(c)
	await get_tree().process_frame

	# Place the tower on the buildable cell closest to the path.
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var best_cell := Vector2i.ZERO
	var best_d := 1e9
	for c in main.map.buildable:
		if not main.board.is_buildable(c):
			continue
		var w: Vector2 = main.board.cell_center_world(c)
		for p in path_pts:
			var dd: float = w.distance_to(p)
			if dd < best_d:
				best_d = dd
				best_cell = c
	main.placing_id = id
	if not main._try_place(best_cell):
		return [0.0, "could not place"]
	main.placing_id = ""

	# A stationary dummy on the path nearest the tower, so every fire mode can
	# reach it: huge HP so nothing dies and the decay chain never muddies the read.
	var dummy := EnemyData.new()
	dummy.id = "balance_dummy"
	dummy.display_name = "Dummy"
	dummy.shape = "icosahedron"
	dummy.radius = 16.0
	dummy.health = DUMMY_HP
	dummy.speed = 0.0
	dummy.reward = 0
	var tower_pp: Vector2 = main.board.cell_center_world(best_cell)
	var near_i := 0
	var near_d := 1e9
	for i in range(path_pts.size()):
		var dd2: float = tower_pp.distance_to(path_pts[i])
		if dd2 < near_d:
			near_d = dd2
			near_i = i
	var e := Enemy3D.new()
	e.setup(dummy, path_pts)
	e.place_on_path(near_i, path_pts[near_i])
	main.board.add_enemy(e)
	await get_tree().process_frame

	for i in frames:
		await get_tree().process_frame
	var dealt: float = DUMMY_HP - e.health
	var note := ""
	if dealt <= 0.0:
		note = "NO DAMAGE (out of range/LOS?)"
	return [dealt / SECONDS, note]
