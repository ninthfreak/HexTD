extends Node
## Dev-only: two Router risks static reading cannot settle —
##   1. does a forwarding shot ALWAYS get released (pool leak)?
##   2. when a hop target decays, is the morphed parent correctly excluded while
##      its freshly spawned children stay eligible?
var _pts: PackedVector2Array

func _live_projectiles(main) -> int:
	var n := 0
	for c in main.board._entities.get_children():
		if c is Projectile3D and c.visible and c.is_processing():
			n += 1
	return n

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
	main.placing_id = "router"
	main._try_place(spot)
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	tw.data.range_tiles = 12
	tw._cooldown = 1.0e9
	tw.data.hops = 9            # TTL-max: the longest chain the tower can make
	tw.data.hop_range = 3

	# ---- 1. leak: 40 long-chain shots, then let the board settle -----------
	var step: float = float(main.board.tower_reach(1)) * 0.8
	var mob: Array = []
	for k in 12:
		var pl: Dictionary = main._forward_along(_pts, 40.0 + step * float(k))
		var ed := EnemyData.new()
		ed.health = 1e12
		ed.speed = 0.0
		ed.color = Color.WHITE
		ed.radius = 16.0
		var e := Enemy3D.new()
		e.setup(ed, _pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
		mob.append(e)
	for i in 8:
		await get_tree().process_frame
	var peak := 0
	for s in 40:
		tw._shoot(mob[0])
		await get_tree().process_frame
		peak = maxi(peak, _live_projectiles(main))
	for i in 400:
		await get_tree().process_frame
	print("LEAK: 40 nine-hop shots -> peak live projectiles=%d, settled=%d (settled must be 0)"
		% [peak, _live_projectiles(main)])
	for e in mob:
		if is_instance_valid(e):
			e.queue_free()
	await get_tree().process_frame

	# ---- 2. decay: does the chain continue into the spawned children? ------
	var lesser := EnemyData.new()
	lesser.health = 1e12          # children immortal so their hits are measurable
	lesser.speed = 0.0
	lesser.color = Color.RED
	lesser.radius = 12.0
	var parent_d := EnemyData.new()
	parent_d.health = 10.0        # dies to the first hit, then decays
	parent_d.speed = 0.0
	parent_d.color = Color.WHITE
	parent_d.radius = 16.0
	parent_d.reduce_count = 3
	parent_d.reduces_to = lesser
	var pl2: Dictionary = main._forward_along(_pts, 60.0)
	var p := Enemy3D.new()
	p.bounty.connect(main._on_enemy_bounty)
	p.reached_goal.connect(main._on_enemy_reached_goal)
	p.split.connect(main._on_enemy_split)
	p.setup(parent_d, _pts)
	p.place_on_path(int(pl2["index"]), pl2["pos"])
	main.board.add_enemy(p)
	for i in 6:
		await get_tree().process_frame
	tw.data.hops = 3
	tw._shoot(p)
	for i in 150:
		await get_tree().process_frame
	var morphed := 0
	var children := 0
	var hurt := 0
	for e in main.board.enemies:
		if not is_instance_valid(e) or not e._alive:
			continue
		if e == p:
			morphed += 1
			print("DECAY:   morphed parent  hp=%.1f of %.1f  %s" % [e.health, e.data.health,
				"UNTOUCHED after decay" if e.health >= e.data.health else "took a further hit"])
		else:
			children += 1
			if e.health < 1e12:
				hurt += 1
	print("DECAY: parent decayed into %d bodies; %d spawned children took chain damage"
		% [morphed + children, hurt])
	print("DECAY: (parent excluded by the per-shot hit set; children are new nodes, so eligible)")
	print("RR: done")
