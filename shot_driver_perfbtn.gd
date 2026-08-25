extends Node
## Dev-only: the perf toggle must exist in sandbox, be absent in game mode,
## and drive both the overlay and its own dim state.
func drive(main) -> void:
	print("PERF: mode=%s  is_game=%s" % [GameState.mode, str(main.is_game)])
	print("PERF: art resolves -> %s" % str(ResourceLoader.exists("res://art/%sperf_stats.png" % ArtPaths.dir("perf_stats"))))
	if main.perf_button == null:
		print("PERF: no perf_button on this build (expected in game mode)")
	else:
		print("PERF: button present, texture=%s tooltip=%s"
			% [str(main.perf_button.texture_normal != null), main.perf_button.tooltip_text.split("\n")[0]])
		print("PERF: start hidden=%s dim=%.2f" % [str(not main.perf_label.visible), main.perf_button.self_modulate.r])
		main._toggle_perf()
		await get_tree().process_frame
		print("PERF: after 1st press visible=%s dim=%.2f" % [str(main.perf_label.visible), main.perf_button.self_modulate.r])
		# The refresh gate is 0.2 s of WALL time, so wait for real text rather than
		# a fixed frame count (headless runs far faster than 60fps).
		var waited := 0
		while main.perf_label.text == "" and waited < 60000:
			await get_tree().process_frame
			waited += 1
			if waited % 20000 == 0:
				print("PERF:   ...%d frames, accum=%.4f s (gate 0.20)" % [waited, main._perf_accum])
		print("PERF: text appeared after %d frames (accum gate is 0.2 s WALL time)" % waited)
		print("PERF: readout text ->")
		for line in main.perf_label.text.split("\n"):
			print("PERF:    ", line)
		main._toggle_perf()
		await get_tree().process_frame
		print("PERF: after 2nd press visible=%s dim=%.2f" % [str(main.perf_label.visible), main.perf_button.self_modulate.r])
	print("PERF: done")
