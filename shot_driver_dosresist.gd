extends Node
## Dev-only: does dos_resist actually stop the Jammer? Runs one body of each
## resist level past a maxed Jammer and measures how far it gets.
var _pts: PackedVector2Array

func _along(e) -> float:
	var d := 0.0
	for i in range(mini(e._index, _pts.size() - 1)):
		d += _pts[i].distance_to(_pts[i + 1])
	if e._index < _pts.size():
		d += _pts[e._index].distance_to(e.pp)
	return d

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
	main.placing_id = "jammer"
	main._try_place(spot)
	main.placing_id = ""
	var jt = main.board.tower_at(spot)
	jt.data.range_tiles = 14
	# max the Signal path — the strongest jam in the game
	for i in 5:
		if jt.can_upgrade(1):
			jt.upgrade(1)
	print("DOSR: maxed Jammer — freeze=%.2fs slow_time=%.1fs slow_factor=%.2f"
		% [jt.data.dos_freeze, jt.data.dos_slow_time, jt.data.dos_slow_factor])

	# CONTROL first: measure an unjammed body rather than assuming speed * time.
	var control := 0.0
	for phase in ["control", "jammed"]:
		if phase == "control":
			jt.data.dos = false          # jammer present but toothless
		else:
			jt.data.dos = true
		for lvl in ([0.0] if phase == "control" else [0.0, 0.5, 1.0]):
			for e in main.board.enemies.duplicate():
				if is_instance_valid(e):
					e.queue_free()
			await get_tree().process_frame
			var ed := EnemyData.new()
			ed.health = 1e12          # immortal: isolates movement from damage
			ed.speed = 8.0            # a tebibyte's speed
			ed.color = Color.WHITE
			ed.radius = 20.0
			ed.dos_resist = lvl
			var e2 := Enemy3D.new()
			e2.setup(ed, _pts)
			e2.place_on_path(0, _pts[0])
			main.board.add_enemy(e2)
			for i in 600:            # 10 s
				await get_tree().process_frame
			var moved: float = _along(e2)
			if phase == "control":
				control = moved
				print("DOSR: CONTROL (no DoS at all) -> travelled %6.1f units in 10 s" % moved)
			else:
				print("DOSR: dos_resist=%.2f -> travelled %6.1f units = %5.1f%% of unjammed"
					% [lvl, moved, 100.0 * moved / maxf(control, 0.001)])
			e2.queue_free()
	print("DOSR: done")
