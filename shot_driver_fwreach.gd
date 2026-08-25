extends Node
## Dev-only: what the deploy range gate changed. For every legal Firewall
## placement, counts the route tiles reachable by the OLD raw-range_tiles gate
## versus the NEW footprint-aware tower_reach() gate — and, crucially, whether
## any placement went from "can never deploy" to "can".

func drive(main) -> void:
	main.money = 999999999
	var rng := 3
	# explicit type: main.board is untyped, so := cannot infer here (CLAUDE.md)
	var reach: int = main.board.tower_reach(rng)
	print("REACH: range_tiles=%d -> old gate %d, new gate %d (FOOTPRINT_RADIUS=%d)"
		% [rng, rng, reach, reach - rng])

	var legal := 0
	var dead_old := 0
	var dead_new := 0
	var gained := 0
	var sum_old := 0
	var sum_new := 0
	var cap_old := 0     # placements that could reach at least max_rules tiles
	var cap_new := 0
	var max_rules := 5
	for c in main.map.buildable:
		if not main.board.is_buildable(c):
			continue
		legal += 1
		var n_old := 0
		var n_new := 0
		for p in main.map.path:
			var d: int = HexUtils.axial_distance(c, p)
			if d <= rng:
				n_old += 1
			if d <= reach:
				n_new += 1
		sum_old += n_old
		sum_new += n_new
		if n_old == 0:
			dead_old += 1
		if n_new == 0:
			dead_new += 1
		if n_old == 0 and n_new > 0:
			gained += 1
		if n_old >= max_rules:
			cap_old += 1
		if n_new >= max_rules:
			cap_new += 1
	print("REACH: %d legal placements" % legal)
	print("REACH: route tiles reachable, mean  old %.2f -> new %.2f  (+%.2f)"
		% [float(sum_old) / float(maxi(legal, 1)), float(sum_new) / float(maxi(legal, 1)),
		   float(sum_new - sum_old) / float(maxi(legal, 1))])
	print("REACH: placements that can deploy NOTHING  old %d -> new %d  (%d rescued)"
		% [dead_old, dead_new, gained])
	print("REACH: placements that can actually reach max_rules(%d)  old %d -> new %d"
		% [max_rules, cap_old, cap_new])
	print("REACH: done")
