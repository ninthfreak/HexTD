extends Node
## Dev-only: does ECC blunt the Jammer? Runs an ECC enemy and an identical
## non-ECC enemy down the same path, with and without a Jammer in range.
var _pts: PackedVector2Array

func _along(e) -> float:
	var d := 0.0
	for i in range(mini(e._index, _pts.size() - 1)):
		d += _pts[i].distance_to(_pts[i + 1])
	if e._index < _pts.size():
		d += _pts[e._index].distance_to(e.pp)
	return d

func _mk(ecc: bool, enc := false) -> EnemyData:
	var d := EnemyData.new()
	d.health = 1e9            # immortal: isolates movement from damage
	d.speed = 60.0
	d.color = Color.WHITE
	d.radius = 16.0
	d.ecc = ecc
	d.encrypted = enc
	return d

func drive(main) -> void:
	main.money = 999999999
	_pts = main.board.get_path_points()
	var results := {}
	for phase in ["no jammer", "with jammer", "jammer + Cipher"]:
		for e in main.board.enemies.duplicate():
			if is_instance_valid(e):
				e.queue_free()
		await get_tree().process_frame
		if phase != "no jammer":
			var spot := Vector2i.ZERO
			var best := 1e9
			for c in main.map.buildable:
				if main.board.is_buildable(c):
					var dd: float = main.board.cell_center_world(c).distance_to(_pts[0])
					if dd < best:
						best = dd
						spot = c
			main.placing_id = "jammer"
			if not main._try_place(spot):
				print("ECC: jammer placement failed")
				return
			main.placing_id = ""
			var jt = main.board.tower_at(spot)
			jt.data.range_tiles = 14
			if phase == "jammer + Cipher":
				# Signal T1 then T2 — T2 is where Cipher lives
				jt.upgrade(1)
				jt.upgrade(1)
			print("ECC: [%s] jammer dos=%s cipher=%s" % [phase, str(jt.data.dos), str(jt.data.cipher)])
		var made := {}
		for spec in [["plain", false, false], ["ecc", true, false], ["encrypted", false, true], ["tls", true, true]]:
			var e := Enemy3D.new()
			e.setup(_mk(bool(spec[1]), bool(spec[2])), _pts)
			e.place_on_path(0, _pts[0])
			main.board.add_enemy(e)
			made[spec[0]] = e
		for i in 300:
			await get_tree().process_frame
		var row := {}
		for label in made:
			row[label] = _along(made[label])
			made[label].queue_free()
		results[phase] = row
	print("ECC: distance along path after 5 s (lower = more jammed)")
	print("ECC:  %-10s %10s %12s %8s %12s %8s" % ["enemy", "unjammed", "jammed", "slow%", "+Cipher", "slow%"])
	for label in ["plain", "ecc", "encrypted", "tls"]:
		var a: float = results["no jammer"][label]
		var b: float = results["with jammer"][label]
		var c: float = results["jammer + Cipher"][label]
		print("ECC:  %-10s %10.1f %12.1f %7.1f%% %12.1f %7.1f%%"
			% [label, a, b, (1.0 - b / maxf(a, 0.001)) * 100.0, c, (1.0 - c / maxf(a, 0.001)) * 100.0])
	print("ECC: done")
