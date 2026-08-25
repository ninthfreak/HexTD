extends Node
## Dev-only: does the Firewall Daemon filter MOVING traffic?
##
## shot_driver_firewall.gd parks a body on a rule tile by assigning e.pp and
## e.cell directly, which proves the damage path but not the game. Real play
## walks bodies across the tile at speed, so this driver spawns ordinary
## traversing enemies and measures what the rules actually take off them.
##
## It also re-runs the parked case in the same session, so a pass-here /
## fail-there split points straight at the crossing, not at the damage code.

func _rules(main) -> Array:
	var out: Array = []
	for c in main.board._entities.get_children():
		if c is FirewallRule3D and is_instance_valid(c):
			out.append(c)
	return out

func _charges(rules: Array) -> int:
	var n := 0
	for r in rules:
		if is_instance_valid(r):
			n += r.charges
	return n

func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()

	# Firewall only: nothing else on the board may damage the test traffic.
	var spot := Vector2i.ZERO
	var best := 1.0e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "firewall"
	if not main._try_place(spot):
		print("FWLIVE: placement failed")
		return
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	print("FWLIVE: firewall at %s | range=%d damage=%.0f charges=%d max_rules=%d rate=%.2f/s"
		% [str(spot), tw.data.range_tiles, tw.data.damage, tw.data.rule_charges,
		   tw.data.max_rules, tw.data.fire_rate])

	# Let it lay down its full set of rules.
	for i in 900:
		await get_tree().process_frame
	var rs := _rules(main)
	if rs.is_empty():
		print("FWLIVE: NO RULES DEPLOYED — the tower never placed anything.")
		print("FWLIVE: done")
		return
	var cells := []
	for r in rs:
		cells.append(str(r.cell))
	print("FWLIVE: %d rules live on cells %s" % [rs.size(), ", ".join(cells)])
	var on_route := 0
	for r in rs:
		if r.cell in main.map.path:
			on_route += 1
	print("FWLIVE: %d of %d rules sit on a route tile" % [on_route, rs.size()])
	# Where the route enters those cells, as path indices — traffic must cross them.
	var idxs := []
	for r in rs:
		var i: int = main.map.path.find(r.cell)
		if i >= 0:
			idxs.append(str(i))
	print("FWLIVE: rule tiles are at path indices %s (route is %d tiles long)"
		% [", ".join(idxs), main.map.path.size()])

	# --- MOVING traffic -----------------------------------------------------
	var ch0: int = _charges(rs)
	var ed := EnemyData.new()
	ed.health = 1.0e9              # immortal: we are measuring damage, not kills
	ed.speed = 40.0
	ed.color = Color.WHITE
	ed.radius = 14.0
	var mobs: Array = []
	for i in 8:
		var e := Enemy3D.new()
		e.setup(ed, pts)
		e.place_on_path(0, pts[0])
		main.board.add_enemy(e)
		mobs.append(e)
		for j in 15:               # stagger them down the route
			await get_tree().process_frame
	var hp0 := 0.0
	for e in mobs:
		if is_instance_valid(e):
			hp0 += e.health
	# Long enough for the leaders to walk clear past the ruled tiles.
	for i in 1500:
		await get_tree().process_frame
	var hp1 := 0.0
	var reached := 0
	for e in mobs:
		if is_instance_valid(e):
			hp1 += e.health
			if e.cell in main.map.path:
				var pi: int = main.map.path.find(e.cell)
				var furthest := -1
				for r in rs:
					if is_instance_valid(r):
						var ri: int = main.map.path.find(r.cell)
						if ri > furthest:
							furthest = ri
				if pi > furthest:
					reached += 1
	var rs_after := _rules(main)
	print("FWLIVE: MOVING  -> damage dealt %.0f | charges spent %d | %d of 8 bodies walked past every rule tile"
		% [hp0 - hp1, ch0 - _charges(rs_after), reached])
	for e in mobs:
		if is_instance_valid(e):
			e.queue_free()
	await get_tree().process_frame

	# --- PARKED traffic (the control) ---------------------------------------
	var rs2 := _rules(main)
	if rs2.is_empty():
		print("FWLIVE: every rule was spent — no control run possible (that alone means the rules DO fire)")
		print("FWLIVE: done")
		return
	var r0 = rs2[0]
	var ed2 := EnemyData.new()
	ed2.health = 1.0e9
	ed2.speed = 0.0
	ed2.color = Color.WHITE
	ed2.radius = 14.0
	var p := Enemy3D.new()
	p.setup(ed2, pts)
	p.pp = main.board.cell_center_world(r0.cell)
	p.cell = r0.cell
	main.board.add_enemy(p)
	var ph0: float = p.health
	var pc0: int = r0.charges
	for i in 120:
		await get_tree().process_frame
	print("FWLIVE: PARKED  -> damage dealt %.0f | that rule's charges %d -> %d"
		% [ph0 - p.health, pc0, r0.charges if is_instance_valid(r0) else 0])
	p.queue_free()
	print("FWLIVE: done")
