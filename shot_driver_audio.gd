extends Node
## Dev-only audio diagnostic. Taps the Master bus with an AudioEffectCapture so
## the ACTUAL mixed output can be measured, not just "did a voice start".

func drive(main) -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am == null:
		print("AUDIO: no AudioManager")
		return
	var cap := AudioEffectCapture.new()
	cap.buffer_length = 2.0
	AudioServer.add_bus_effect(0, cap)          # Master
	print("AUDIO: capture attached; bus0 effects=", AudioServer.get_bus_effect_count(0))
	await get_tree().process_frame
	cap.clear_buffer()
	am.play_sfx("defeat")
	print("AUDIO: played defeat")
	var peak := 0.0
	var total := 0
	for i in 120:
		await get_tree().process_frame
		var avail := cap.get_frames_available()
		if avail > 0:
			var buf := cap.get_buffer(avail)
			total += buf.size()
			for f in buf:
				peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
	print("AUDIO: MASTER OUTPUT frames=", total, " peak=", peak)
	# Second probe: play everything at once and measure again.
	cap.clear_buffer()
	for s in ["tower_fire", "enemy_death", "wave_start", "upgrade", "ui_click"]:
		am.play_sfx(s)
	var peak2 := 0.0
	var total2 := 0
	for i in 120:
		await get_tree().process_frame
		var avail2 := cap.get_frames_available()
		if avail2 > 0:
			var buf2 := cap.get_buffer(avail2)
			total2 += buf2.size()
			for f2 in buf2:
				peak2 = maxf(peak2, maxf(absf(f2.x), absf(f2.y)))
	print("AUDIO: MASTER OUTPUT (5 sounds) frames=", total2, " peak=", peak2)
