extends Node
## Dev-only: selling a Firewall Daemon must take its rules with it, or
## place / deploy / sell / repeat would mint free coverage (selling refunds).
func _rules(main) -> int:
	var n := 0
	for c in main.board._entities.get_children():
		if c is FirewallRule3D and is_instance_valid(c):
			n += 1
	return n

func drive(main) -> void:
	main.money = 999999999
	var pts: PackedVector2Array = main.board.get_path_points()
	var spot := Vector2i.ZERO
	var best := 1e9
	for c in main.map.buildable:
		if main.board.is_buildable(c):
			var dd: float = main.board.cell_center_world(c).distance_to(pts[0])
			if dd < best:
				best = dd
				spot = c
	main.placing_id = "firewall"
	main._try_place(spot)
	main.placing_id = ""
	for i in 800:
		await get_tree().process_frame
	var before := _rules(main)
	main.selected_cell = spot
	main.has_selected = true
	main._on_sell_pressed()
	for i in 10:
		await get_tree().process_frame
	print("FWSELL: rules before sell=%d, after sell=%d (must be 0)" % [before, _rules(main)])
	print("FWSELL: done")
