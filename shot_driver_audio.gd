extends Node
## Dev-only audio diagnostic: verifies the whole SFX pipeline end to end, then
## watches real combat to confirm gameplay actually starts voices.

var _am
var _started := {}     # sound name -> times a voice actually started

func drive(main) -> void:
	_am = get_node_or_null("/root/AudioManager")
	print("AUDIO: autoload=", _am)
	if _am == null:
		return
	var idx := AudioServer.get_bus_index("SFX")
	print("AUDIO: sfx_bus=", idx, " muted=", AudioServer.is_bus_mute(idx),
		" vol_db=", AudioServer.get_bus_volume_db(idx), " master_muted=", AudioServer.is_bus_mute(0))

	# 1. A long sound must register as playing IMMEDIATELY (no frame boundary).
	_am.play_sfx("defeat")
	var n_now := _playing()
	print("AUDIO: play_sfx(defeat) -> playing_immediately=", n_now)

	# 2. Repeated distinct sounds in one frame.
	for s in ["tower_fire", "enemy_death", "wave_start", "upgrade"]:
		_am.play_sfx(s)
	print("AUDIO: after 4 distinct sounds -> playing=", _playing())

	# 3. The rate floor must not permanently wedge a name.
	for i in 5:
		_am.play_sfx("ui_click")
	await get_tree().create_timer(0.3).timeout
	_am.play_sfx("ui_click")
	print("AUDIO: ui_click after 300ms gap -> playing=", _playing())

	# 4. Real combat: wrap play_sfx accounting by polling free players.
	var ids: Array = main.content.tower_ids()
	var path_pts: PackedVector2Array = main.board.get_path_points()
	var ranked: Array = []
	for c in main.map.buildable:
		var w: Vector2 = main.board.cell_center_world(c)
		var best := 1e9
		for p in path_pts:
			var dd: float = w.distance_to(p)
			if dd < best:
				best = dd
		ranked.append({"c": c, "d": best})
	ranked.sort_custom(func(a, b): return a["d"] < b["d"])
	var placed := 0
	for entry in ranked:
		if placed >= 6:
			break
		var c2: Vector2i = entry["c"]
		if not main.board.is_buildable(c2):
			continue
		main.placing_id = ids[placed % ids.size()]
		if main._try_place(c2):
			placed += 1
	main.placing_id = ""
	var eids: Array = main.content.enemy_ids()
	for k in 40:
		var ed = main.content.enemy(eids[k % eids.size()])
		if ed == null:
			continue
		var pl: Dictionary = main._forward_along(path_pts, 20.0 + float(k) * 25.0)
		var e := Enemy3D.new()
		e.bounty.connect(main._on_enemy_bounty)
		e.reached_goal.connect(main._on_enemy_reached_goal)
		e.split.connect(main._on_enemy_split)
		e.setup(ed, path_pts)
		e.place_on_path(int(pl["index"]), pl["pos"])
		main.board.add_enemy(e)
	print("AUDIO: combat start towers=", placed, " enemies=", main.board.enemies.size())
	var peak := 0
	for i in 300:
		await get_tree().process_frame
		peak = maxi(peak, _playing())
	print("AUDIO: during 300 combat frames -> peak_simultaneous_voices=", peak)

func _playing() -> int:
	var n := 0
	for c in _am.get_children():
		if c is AudioStreamPlayer and c.playing:
			n += 1
	return n
