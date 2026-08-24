extends Node
## Dev-only: confirms every ABILITY_BADGES entry resolves its three art layers
## and that a tower carrying the flag actually builds the badge.
func drive(main) -> void:
	for b in Tower3D.ABILITY_BADGES:
		var ok := []
		for layer in ["glyph", "backplate", "rim"]:
			var f: String = "%s_%s" % [b["file"], layer]
			var p: String = "res://art/%s%s.png" % [ArtPaths.dir(f), f]
			ok.append("%s=%s" % [layer, "ok" if ResourceLoader.exists(p) else "MISSING"])
		print("BADGE: %-18s prop=%-18s %s" % [b["file"], b["prop"], " ".join(ok)])
	# a real tower with the flag on: does the badge get built?
	main.money = 99999999
	var td = main.content.tower("quantum")
	if td == null:
		print("BADGE: no quantum tower in content")
		return
	print("BADGE: quantum base execute_no_decay=", td.execute_no_decay,
		" execute_threshold=", td.execute_threshold)
	var pts: PackedVector2Array = main.board.get_path_points()
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "quantum"
	main._try_place(spot)
	main.placing_id = ""
	var tw = main.board.tower_at(spot)
	# buy Amplitude (slot 0) up to tier 4, then read the T5 tooltip BEFORE buying it
	for i in 4:
		if tw.can_upgrade(0):
			tw.upgrade(0)
	print("BADGE: Amplitude T5 tooltip (what the player reads before buying):")
	for line in tw.tier_summary(0).split("\n"):
		print("BADGE:     ", line)
	if tw.can_upgrade(0):
		tw.upgrade(0)
	print("BADGE: after Amplitude T5 -> execute_threshold=", tw.data.execute_threshold,
		" execute_no_decay=", tw.data.execute_no_decay)
	tw.set_badges_visible(true)
	await get_tree().process_frame
	var tips := []
	for e in tw._badge_info:
		tips.append(str(e["tip"]).split("\n")[0])
	print("BADGE: live badges on tower = ", tips)
	print("BADGE: done")
