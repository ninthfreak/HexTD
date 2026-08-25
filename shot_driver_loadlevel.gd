extends Node
## Dev-only: proves the count-driven load level steps and un-steps with
## hysteresis, and that the LOD thresholds it drives actually move.
func drive(main) -> void:
	print("LOAD: enter=", Enemy3D.LOAD_ENTER, " leave=", Enemy3D.LOAD_LEAVE)
	print("LOAD: %8s %6s   %s" % ["alive", "level", "(rising then falling)"])
	var seq := [0, 200, 399, 400, 700, 799, 800, 1200, 800, 750, 700, 699, 400, 345, 340, 339, 100, 0]
	var out := []
	for n in seq:
		Enemy3D.update_load_level(n)
		out.append("%d->L%d" % [n, Enemy3D.load_level])
	print("LOAD:  ", " ".join(out))
	# thresholds each level produces
	print("LOAD: level  drop_px  restore_px  lead exempt while crowd <")
	for lv in 3:
		print("LOAD:   L%d   %6.0f   %9.0f   %s" % [lv,
			Enemy3D.LOD_DROP_PX + Enemy3D.LOAD_DROP_BONUS[lv],
			Enemy3D.LOD_RESTORE_PX + Enemy3D.LOAD_DROP_BONUS[lv],
			"always" if Enemy3D.LOAD_LEAD_MAX[lv] > 1000 else str(Enemy3D.LOAD_LEAD_MAX[lv])])
	# hysteresis must hold: no oscillation when the count sits on a boundary
	Enemy3D.update_load_level(0)
	var flips := 0
	var prev := Enemy3D.load_level
	for i in 40:
		Enemy3D.update_load_level(400 if (i % 2) == 0 else 399)
		if Enemy3D.load_level != prev:
			flips += 1
			prev = Enemy3D.load_level
	print("LOAD: count flapping 399<->400 for 40 ticks caused %d level changes (1 = entered and stayed)" % flips)
	Enemy3D.update_load_level(0)
	print("LOAD: done")
