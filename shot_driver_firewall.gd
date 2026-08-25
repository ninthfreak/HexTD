extends Node
## Dev-only: verifies the Firewall Daemon against the real combat code —
## rules deploy onto route tiles in range, one per tile, capped at max_rules;
## a crossing body spends exactly one charge; a rule expires when spent;
## Encrypted traffic passes untouched without Cipher.
var _pts: PackedVector2Array

func _rules(main) -> Array:
	var out: Array = []
	for c in main.board._entities.get_children():
		if c is FirewallRule3D and is_instance_valid(c):
			out.append(c)
	return out

func drive(main) -> void:
	main.money = 999999999
	_pts = main.board.get_path_points()
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(_pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "firewall"
	if not main._try_place(spot):
		print("FW: placement failed")
		return
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	print("FW: %s at %s | range=%d rate=%.2f/s damage=%.0f charges=%d max_rules=%d"
		% [tw.data.display_name, str(spot), tw.data.range_tiles, tw.data.fire_rate,
		   tw.data.damage, tw.data.rule_charges, tw.data.max_rules])

	# --- deploy: rules should fill up to the cap, one per tile, then stop ---
	for i in 900:
		await get_tree().process_frame
	var rs := _rules(main)
	var cells := {}
	for r in rs:
		cells[r.cell] = true
	var on_route := 0
	for r in rs:
		if r.cell in main.map.path:
			on_route += 1
	print("FW: after 15 s -> %d live rules (cap %d), %d distinct tiles, %d of them on the route"
		% [rs.size(), tw.data.max_rules, cells.size(), on_route])
	print("FW: one rule per tile: %s | never exceeds cap: %s"
		% [str(cells.size() == rs.size()), str(rs.size() <= tw.data.max_rules)])

	# --- a body crossing a ruled tile spends exactly one charge ------------
	if rs.is_empty():
		print("FW: no rules deployed — cannot test filtering")
		return
	var r0 = rs[0]
	var before_ch: int = r0.charges
	var ed := EnemyData.new()
	ed.health = 1e9
	ed.speed = 0.0
	ed.color = Color.WHITE
	ed.radius = 16.0
	var e := Enemy3D.new()
	e.setup(ed, _pts)
	var w: Vector2 = main.board.cell_center_world(r0.cell)
	e.pp = w
	e.cell = r0.cell
	main.board.add_enemy(e)
	var hp0: float = e.health
	for i in 120:                      # two seconds parked on the rule
		await get_tree().process_frame
	print("FW: body parked on a rule for 2 s -> damage=%.0f (expect %.0f, ONE charge not per-frame), charges %d -> %d"
		% [hp0 - e.health, tw.data.damage, before_ch, r0.charges if is_instance_valid(r0) else 0])
	e.queue_free()
	await get_tree().process_frame

	# --- Encrypted traffic passes untouched without Cipher ----------------
	var rs2 := _rules(main)
	if rs2.is_empty():
		print("FW: no rules left for the Cipher test")
		print("FW: done")
		return
	var r1 = rs2[0]
	for label in ["no Cipher", "Cipher"]:
		r1.can_see_encrypted = (label == "Cipher")
		var ed2 := EnemyData.new()
		ed2.health = 1e9
		ed2.speed = 0.0
		ed2.color = Color.WHITE
		ed2.radius = 16.0
		ed2.encrypted = true
		var e2 := Enemy3D.new()
		e2.setup(ed2, _pts)
		e2.pp = main.board.cell_center_world(r1.cell)
		e2.cell = r1.cell
		main.board.add_enemy(e2)
		var h0: float = e2.health
		for i in 60:
			await get_tree().process_frame
		print("FW: %-10s -> Encrypted body took %.0f damage" % [label, h0 - e2.health])
		e2.queue_free()
		await get_tree().process_frame
	print("FW: done")
