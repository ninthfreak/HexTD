extends Node
## Dev-only: verifies the Beam's reworked paths (incl. Prefocus), Basic's Optics
## reshuffle and Quantum's new base cost / capped arc, against the real code.
func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	var used := {}
	var stand = func():
		var spot := Vector2i.ZERO
		var best := 1e9
		for c in main.map.buildable:
			if main.board.is_buildable(c) and not used.has(c):
				var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
				if dd < best:
					best = dd
					spot = c
		used[spot] = true
		return spot

	# --- Beam: buy Lens level by level, reporting the stats a player would see ---
	var spot = stand.call()
	main.placing_id = "beam"
	main._try_place(spot)
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	print("BEAM: Lens path — ramp / range / focus_time / Prefocus")
	print("BEAM:   base      ramp=%.2fs range=%d focus=%.2fs prefocus=%d%%"
		% [tw.data.ramp_time, tw.data.range_tiles, tw.data.focus_time, int(tw.data.charge_retain * 100)])
	for lv in 5:
		if not tw.can_upgrade(1):
			break
		tw.upgrade(1)
		print("BEAM:   Lens T%d   ramp=%.2fs range=%d focus=%.2fs prefocus=%d%%"
			% [lv + 1, tw.data.ramp_time, tw.data.range_tiles, tw.data.focus_time, int(tw.data.charge_retain * 100)])

	# --- Beam: Decrypt now graduates ECC pierce instead of stacking damage ---
	var s2 = stand.call()
	main.placing_id = "beam"
	main._try_place(s2)
	main.placing_id = ""
	var tw2 = main.board.tower_at(s2)
	print("BEAM: Decrypt path — cipher / bit_corruption / walls / damage")
	print("BEAM:   base      cipher=%s bitcorr=%s walls=%s dmg=%.0f"
		% [str(tw2.data.cipher), str(tw2.data.bit_corruption), str(tw2.data.ignore_walls), tw2.data.damage])
	for lv in 5:
		if not tw2.can_upgrade(2):
			break
		tw2.upgrade(2)
		print("BEAM:   Decrypt T%d cipher=%s bitcorr=%s walls=%s dmg=%.0f"
			% [lv + 1, str(tw2.data.cipher), str(tw2.data.bit_corruption), str(tw2.data.ignore_walls), tw2.data.damage])

	# --- Basic: cipher must now arrive at Optics T2 ---
	var s3 = stand.call()
	main.placing_id = "basic"
	main._try_place(s3)
	main.placing_id = ""
	var tw3 = main.board.tower_at(s3)
	var spent := 0
	for lv in 5:
		if not tw3.can_upgrade(2):
			break
		spent += tw3.next_cost(2)
		tw3.upgrade(2)
		if tw3.data.cipher:
			print("BASIC: Cipher acquired at Optics T%d for %d credits total (range now %d)"
				% [lv + 1, spent, tw3.data.range_tiles])
			break

	# --- Quantum: base cost up, arc must never reach a full surround ---
	var qd = main.content.tower("quantum")
	print("QUANTUM: base cost=%d  arc=%.0f deg" % [qd.cost, qd.arc_angle])
	var s4 = stand.call()
	main.placing_id = "quantum"
	main._try_place(s4)
	main.placing_id = ""
	var tw4 = main.board.tower_at(s4)
	for lv in 5:
		if not tw4.can_upgrade(1):
			break
		tw4.upgrade(1)
	print("QUANTUM: Field maxed -> arc=%.0f deg range=%d  (360 = fully surrounded)"
		% [tw4.data.arc_angle, tw4.data.range_tiles])
	print("BEAM: done")
