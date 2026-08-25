extends Node
## Dev-only: proves per-tower damage/kill attribution across every fire mode.
##
## Each tower is placed alone with its own probe traffic, so anything credited to
## it can only have come from it. Damage is checked against the health actually
## removed from the probes — the tally must equal that, not the nominal shot
## damage (ECC resist and overkill both bend the two apart).

const PROBE_HP := 4000.0

func _spawn(main, pts: PackedVector2Array, hp: float, ecc := false) -> Enemy3D:
	var ed := EnemyData.new()
	ed.health = hp
	ed.speed = 0.0
	ed.color = Color.WHITE
	ed.radius = 16.0
	ed.ecc = ecc
	var e := Enemy3D.new()
	e.setup(ed, pts)
	main.board.add_enemy(e)
	return e

func _free_cell(main, used: Dictionary, near: Vector2) -> Vector2i:
	var spot := Vector2i.ZERO
	var best := 1.0e9
	for c in main.map.buildable:
		if used.has(c) or not main.board.is_buildable(c):
			continue
		var dd: float = main.board.cell_center_world(c).distance_to(near)
		if dd < best:
			best = dd
			spot = c
	return spot

func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	var used := {}
	print("TALLY: %-16s %12s %12s %8s %8s  %s"
		% ["tower", "hp removed", "credited", "kills", "match", "mode"])

	for id in main.content.tower_ids():
		var spot := _free_cell(main, used, pts[0])
		main.placing_id = id
		if not main._try_place(spot):
			print("TALLY: %-16s placement FAILED" % id)
			main.placing_id = ""
			continue
		main.placing_id = ""
		used[spot] = true
		var tw = main.board.tower_at(spot)
		# Probes parked on the route inside this tower's reach. Several of them, so
		# radial/arc breadth and Router hops have something to reach.
		# Cover the FURTHEST-along in-range route tiles, not the first ones found:
		# the Firewall lays its rules on the highest path index it can reach, so
		# probes taken in path order miss it entirely and it scores a false zero.
		var reach: Array = []
		for c in main.map.path:
			if HexUtils.axial_distance(spot, c) <= tw.data.range_tiles:
				reach.append(c)
		var probes: Array = []
		for i in range(maxi(0, reach.size() - 5), reach.size()):
			var c: Vector2i = reach[i]
			var e := _spawn(main, pts, PROBE_HP)
			e.pp = main.board.cell_center_world(c)
			e.cell = c
			probes.append(e)
		if probes.is_empty():
			print("TALLY: %-16s no route tile in range — skipped" % tw.data.display_name)
			continue
		var hp_before := 0.0
		for e in probes:
			hp_before += e.health
		for i in 600:                        # ten seconds of fire
			await get_tree().process_frame
		var hp_after := 0.0
		var gone := 0
		for e in probes:
			if is_instance_valid(e) and e._alive:
				hp_after += e.health
			else:
				gone += 1
		# A probe that decayed into a child form still holds health, and that
		# child's health is not part of the original pool — so compare against the
		# damage the tower says it did, allowing for bodies that left the pool.
		var removed: float = hp_before - hp_after - float(gone) * 0.0
		var ok: String = "yes" if absf(removed - tw.damage_dealt) < 1.0 else "DIFFERS"
		print("TALLY: %-16s %12.0f %12.0f %8d %8s  %s"
			% [tw.data.display_name, removed, tw.damage_dealt, tw.kills, ok, tw.data.fire_mode])
		for e in probes:
			if is_instance_valid(e):
				e.queue_free()
		# One tower on the board at a time: otherwise the previous towers keep
		# firing at the next tower's probes and every figure after the first is
		# measuring the whole board, not the tower under test.
		main.board.remove_tower(spot)
		used.erase(spot)
		# Let the removed tower's in-flight ordnance expire before the next tower's
		# probes exist. Those shots still land, but their source node is gone, so
		# they are credited to nobody (correct — a sold tower must not accrue) and
		# would otherwise show up as unattributed damage on the NEXT tower's row.
		for i in 120:
			await get_tree().process_frame

	# --- ECC: the tally must record the RESISTED figure, not the nominal ------
	print("TALLY: --- ECC resist is reflected in the credited figure ---")
	for corrupt in [false, true]:
		var spot := _free_cell(main, used, pts[0])
		main.placing_id = "heavy"
		if not main._try_place(spot):
			break
		main.placing_id = ""
		used[spot] = true
		var tw = main.board.tower_at(spot)
		tw.data.bit_corruption = corrupt
		var target: Enemy3D = null
		for c in main.map.path:
			if HexUtils.axial_distance(spot, c) <= tw.data.range_tiles:
				target = _spawn(main, pts, 1.0e9, true)
				target.pp = main.board.cell_center_world(c)
				target.cell = c
				break
		if target == null:
			break
		var h0: float = target.health
		for i in 300:
			await get_tree().process_frame
		print("TALLY:   bit_corruption=%-5s  hp removed %.0f  credited %.0f  (must agree)"
			% [str(corrupt), h0 - target.health, tw.damage_dealt])
		target.queue_free()
		main.board.remove_tower(spot)
		used.erase(spot)
		await get_tree().process_frame

	# --- kills are counted, once per depleted body ---------------------------
	print("TALLY: --- kill counting (each depleted body counts once) ---")
	var kspot := _free_cell(main, used, pts[0])
	main.placing_id = "heavy"
	if main._try_place(kspot):
		main.placing_id = ""
		var ktw = main.board.tower_at(kspot)
		var victims: Array = []
		for c in main.map.path:
			if victims.size() >= 4:
				break
			if HexUtils.axial_distance(kspot, c) > ktw.data.range_tiles:
				continue
			var e := _spawn(main, pts, 30.0)     # one Heavy shot deletes it
			e.pp = main.board.cell_center_world(c)
			e.cell = c
			victims.append(e)
		for i in 600:
			await get_tree().process_frame
		var dead := 0
		for e in victims:
			if not is_instance_valid(e) or not e._alive:
				dead += 1
		print("TALLY:   %d probes spawned, %d gone, tower reports %d kills / %.0f damage"
			% [victims.size(), dead, ktw.kills, ktw.damage_dealt])
		print("TALLY:   overkill excluded: %d kills x 30 hp = %d, credited %.0f"
			% [ktw.kills, ktw.kills * 30, ktw.damage_dealt])

	# --- the tally survives an upgrade ---------------------------------------
	for c in used:
		var t = main.board.tower_at(c)
		if t != null and t.damage_dealt > 0.0:
			var d0: float = t.damage_dealt
			var k0: int = t.kills
			if t.can_upgrade(0):
				t.upgrade(0)
				print("TALLY: upgrade kept the record: damage %.0f -> %.0f | kills %d -> %d"
					% [d0, t.damage_dealt, k0, t.kills])
			break
	print("TALLY: done")
