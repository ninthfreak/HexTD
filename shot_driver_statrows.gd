extends Node
## Dev-only: exercises Tower3D.stat_rows() and the selection panel it feeds, for
## every tower and every fire mode. Placing + selecting each tower is what proves
## the panel rebuild path, not just the formatter.

func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	var used := {}
	for id in main.content.tower_ids():
		# a free buildable cell, nearest the route so range overlays are realistic
		var spot := Vector2i.ZERO
		var best := 1.0e9
		for c in main.map.buildable:
			if used.has(c) or not main.board.is_buildable(c):
				continue
			var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
			if dd < best:
				best = dd
				spot = c
		main.placing_id = id
		if not main._try_place(spot):
			print("ROWS: %-10s placement FAILED" % id)
			main.placing_id = ""
			continue
		main.placing_id = ""
		used[spot] = true
		var tw = main.board.tower_at(spot)
		var rows: Array = tw.stat_rows()
		print("ROWS: --- %s (%s) : %d rows ---" % [tw.data.display_name, id, rows.size()])
		for r in rows:
			print("ROWS:      %-17s %s" % [str(r[0]), str(r[1])])
		# drive the real panel rebuild for this tower
		main.selected_cell = spot
		main.has_selected = true
		main._update_tower_buttons(tw)
		var n: int = main.attr_grid.get_child_count()
		# +2 rows: the live "Damage dealt" / "Destroyed" tally is appended under the
		# fixed attributes, so the grid carries (attributes + 2) name/value pairs.
		print("ROWS:   panel grid children=%d (expect %d) header=%s tally=[%s / %s]"
			% [n, (rows.size() + 2) * 2, str(main.attr_header.visible),
			   main.tally_dmg_value.text, main.tally_kill_value.text])
		await get_tree().process_frame

	# fully upgrade one path on Flood so the resolved (not base) values are shown
	for c in used:
		var t = main.board.tower_at(c)
		if t != null and t.data.display_name == "Flood":
			for i in 5:
				if t.can_upgrade(0):
					t.upgrade(0)
			print("ROWS: --- Flood after Magnitude x%d ---" % t.slot_level(0))
			for r in t.stat_rows():
				print("ROWS:      %-17s %s" % [str(r[0]), str(r[1])])
			break

	# deselecting must hide the block rather than leave stale rows
	main.has_selected = false
	main._update_tower_buttons(null)
	print("ROWS: after deselect -> grid children=%d visible=%s header=%s"
		% [main.attr_grid.get_child_count(), str(main.attr_grid.visible), str(main.attr_header.visible)])
	print("ROWS: done")
