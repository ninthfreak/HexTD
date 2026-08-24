extends Node
## THROWAWAY audit driver (delete after use). Drives the real 3D UI: places one
## tower of every id, SELECTS it, and reads the strings the upgrade/sell buttons
## and the info line actually render. Then sells it.

func drive(main) -> void:
	var cells: Array = []
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			cells.append(c)
	var next := 0
	for id in main.content.tower_ids():
		while next < cells.size() and not main.board.is_buildable(cells[next]):
			next += 1
		if next >= cells.size():
			print("UI: out of cells")
			return
		var spot = cells[next]
		next += 1
		main.money = 999999999
		main.placing_id = id
		var ok: bool = main._try_place(spot)
		main.placing_id = ""
		var t = main.board.tower_at(spot)
		if not ok or t == null:
			print("UI: place FAILED ", id)
			continue
		main._select_tower(spot, t)
		main._update_tower_buttons(t)
		main._update_tower_control_row(t)
		main._update_target_button(t)
		await get_tree().process_frame
		print("UI: id=%-9s info=%s" % [id, main.info_label.text])
		for s in range(t.slot_count()):
			var cl = main.btn_cl(main.upgrade_buttons[s])
			print("UI:   btn[%d] = %s | tooltip = %s" % [
				s, cl._prefix + ("¤" + cl._value + cl._suffix if cl._value != "" else ""),
				main.upgrade_buttons[s].tooltip_text.replace("\n", " / ")])
		var scl = main.btn_cl(main.sell_button)
		print("UI:   sell = %s%s%s  tooltip=%s" % [scl._prefix, scl._value, scl._suffix, main.sell_button.tooltip_text])
		# buy one tier on path 0, re-read, then sell
		main._on_upgrade_pressed(0)
		await get_tree().process_frame
		print("UI:   after upgrade info=%s" % (main.info_label.text))
		main._on_sell_pressed()
		await get_tree().process_frame
		print("UI:   sold -> tower_at=%s" % str(main.board.tower_at(spot)))
	print("UI: done")
