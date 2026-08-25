extends Node
## Dev-only: verifies the ECC resist / Bit Corruption rule, execute_threshold /
## execute_no_decay and the fire-rate cadence fix against the real combat code.
## Not part of the game.

func drive(main) -> void:
	var pts: PackedVector2Array = main.board.get_path_points()

	# --- ECC resist vs Bit Corruption ----------------------------------------
	var ep := EnemyData.new()
	ep.health = 1000000.0
	ep.speed = 0.0
	ep.color = Color.WHITE
	ep.radius = 16.0
	ep.ecc = true
	var got := {}
	for label in ["resisted", "bit_corruption"]:
		var e := Enemy3D.new()
		e.setup(ep, pts)
		main.board.add_enemy(e)
		var b: float = e.health
		e.take_damage(1000.0, label == "bit_corruption")
		got[label] = b - e.health
		e.queue_free()
	print("MECH: ECC  resisted=%.0f bit_corruption=%.0f   (expect 100 / 1000)"
		% [got["resisted"], got["bit_corruption"]])

	# --- execute_threshold / execute_no_decay ---------------------------------
	var lesser := EnemyData.new()
	lesser.health = 200.0
	lesser.color = Color.RED
	lesser.radius = 10.0
	for dmg in [900.0, 700.0]:
		for decay in [false, true]:
			var pd := EnemyData.new()
			pd.health = 1000.0
			pd.color = Color.RED
			pd.radius = 10.0
			pd.reduce_count = 2
			pd.reduces_to = lesser if decay else null
			var e := Enemy3D.new()
			e.setup(pd, pts)
			main.board.add_enemy(e)
			var killed: bool = e.take_damage(dmg, false, false, 0.15, true)
			var form := "gone" if (not is_instance_valid(e)) or (not e._alive) else ("decayed" if e.data == lesser else "alive")
			print("MECH: execute dmg=%d leaves %d%% decay_chain=%-5s -> killed=%-5s form=%s"
				% [int(dmg), int((1000.0 - dmg) / 10.0), str(decay), str(killed), form])
			if is_instance_valid(e):
				e.queue_free()

	# --- fire-rate cadence: ONE tower + ONE immortal probe, rate varied --------
	main.money = 99999999
	var probe := EnemyData.new()
	probe.health = 1e15
	probe.speed = 0.0
	probe.color = Color.WHITE
	probe.radius = 20.0
	var target := Enemy3D.new()
	target.setup(probe, pts)
	target.place_on_path(0, pts[0])
	main.board.add_enemy(target)
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if not main.board.is_buildable(c):
			continue
		var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
		if dd < best:
			best = dd
			spot = c
	main.placing_id = main.content.tower_ids()[0]
	if not main._try_place(spot):
		print("MECH: could not place tower")
		return
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	tw.data.damage = 1.0
	tw.data.range_tiles = 12
	tw.data.targets = 1
	print("MECH: --- shots/sec measured over 4s (one tower, immortal probe) ---")
	print("MECH: %9s %10s %10s" % ["fire_rate", "measured", "old-model"])
	for rate in [8.0, 12.0, 18.0, 24.0, 30.0, 36.0, 45.0, 90.0]:
		tw.data.fire_rate = rate
		for i in 30:
			await get_tree().process_frame        # settle
		var h0: float = target.health
		for i in 240:
			await get_tree().process_frame
		var shots: float = (h0 - target.health) / 4.0
		var old: float = 60.0 / ceil(60.0 / rate)
		print("MECH: %9.1f %10.2f %10.2f" % [rate, shots, old])
	print("MECH: done")
