extends Node
## Dev-only: verifies the Router's hop forwarding against the real combat code —
## chain order, damage falloff, hop cap, no double-hits, Cipher gating on hops,
## and that the pooled projectile's `damage *= falloff` never leaks between shots.
var _pts: PackedVector2Array

func _probe(enc := false) -> EnemyData:
	var d := EnemyData.new()
	d.health = 1e12          # immortal: every hop lands and can be measured
	d.speed = 0.0
	d.color = Color.WHITE
	d.radius = 16.0
	d.encrypted = enc
	return d

func drive(main) -> void:
	main.money = 999999999
	_pts = main.board.get_path_points()
	# tower on the buildable cell nearest the route start
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(_pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "router"
	if not main._try_place(spot):
		print("ROUTER: placement failed")
		return
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	tw.data.range_tiles = 12
	# Park the autonomous cooldown so ONLY the manual _shoot() calls below fire.
	# _shoot() never touches _cooldown (only _rearm() does, from _process), so one
	# assignment holds for the whole run.
	tw._cooldown = 1.0e9
	print("ROUTER: base damage=%.0f hops=%d hop_range=%d falloff=%.2f cipher=%s"
		% [tw.data.damage, tw.data.hops, tw.data.hop_range, tw.data.hop_falloff, str(tw.data.cipher)])

	var step: float = float(main.board.tower_reach(1)) * 0.8   # ~1 tile apart
	var chain: Array = []
	for k in 6:
		var pl: Dictionary = main._forward_along(_pts, 40.0 + step * float(k))
		var e := Enemy3D.new()
		e.setup(_probe(), _pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
		chain.append(e)
	for i in 8:
		await get_tree().process_frame

	# --- one shot, fired through the tower's own code path -------------------
	var before: Array = []
	for e in chain:
		before.append(e.health)
	tw._shoot(chain[0])
	for i in 90:
		await get_tree().process_frame
	print("ROUTER: --- one shot at the head of a 6-enemy line ---")
	var total := 0.0
	var expect: float = tw.data.damage
	for i in chain.size():
		var dealt: float = before[i] - chain[i].health
		total += dealt
		var mark := ""
		if dealt > 0.0:
			mark = "  (expected %.1f)" % expect
			expect *= tw.data.hop_falloff
		print("ROUTER:   enemy %d  dealt %8.2f%s" % [i, dealt, mark])
	print("ROUTER:   total %.2f across %d bodies (hops=%d means at most %d bodies)"
		% [total, chain.filter(func(e): return true).size(), tw.data.hops, tw.data.hops + 1])

	# --- pooling: repeated shots must each deal the SAME total --------------
	print("ROUTER: --- 5 consecutive shots (pooled projectile reuse) ---")
	for s in 5:
		var b2: Array = []
		for e in chain:
			b2.append(e.health)
		tw._shoot(chain[0])
		for i in 90:
			await get_tree().process_frame
		var t2 := 0.0
		for i in chain.size():
			t2 += b2[i] - chain[i].health
		print("ROUTER:   shot %d total %.2f" % [s + 1, t2])

	# --- Cipher gating: a hop must skip Encrypted when the tower lacks it ---
	for e in chain:
		e.queue_free()
	await get_tree().process_frame
	var mixed: Array = []
	for k in 5:
		var pl2: Dictionary = main._forward_along(_pts, 40.0 + step * float(k))
		var e2 := Enemy3D.new()
		e2.setup(_probe(k % 2 == 1), _pts)     # every other one Encrypted
		e2.place_on_path(int(pl2["index"]), pl2["pos"])
		main.board.add_enemy(e2)
		mixed.append(e2)
	for i in 8:
		await get_tree().process_frame
	for label in ["no Cipher", "Cipher"]:
		tw.data.cipher = (label == "Cipher")
		var b3: Array = []
		for e in mixed:
			b3.append(e.health)
		tw._shoot(mixed[0])
		for i in 90:
			await get_tree().process_frame
		var hitline := ""
		for i in mixed.size():
			var d3: float = b3[i] - mixed[i].health
			hitline += ("%s%s " % ["ENC" if mixed[i].data.encrypted else "plain", "=HIT" if d3 > 0.0 else "=--"])
		print("ROUTER: %-10s -> %s" % [label, hitline])
	print("ROUTER: done")
