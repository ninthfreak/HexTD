extends Node
## Standalone audio self-test. Open `scenes/audio_check.tscn` and press F6.
##
## The game's own logging can only prove that a voice STARTED. This goes further:
## it taps the Master bus with an AudioEffectCapture and measures the mixed
## output, which separates the two failure modes that look identical from inside
## the game:
##   * the engine is producing signal and you still hear nothing
##       -> the fault is the output device or the OS mixer, not the game;
##   * the engine is producing silence
##       -> the fault is in the project (bus, files, volumes) and I can fix it.
## It also lists the output devices Godot can see, since a default device with no
## speakers attached (HDMI, a disconnected headset) presents exactly as silence.

const TEST_SECONDS := 1.2

func _ready() -> void:
	print("\n==================== HexTD audio self-test ====================")
	print("Godot            : ", Engine.get_version_info().string)
	print("Mix rate         : ", AudioServer.get_mix_rate(), " Hz")
	print("Output latency   : ", "%.1f ms" % (AudioServer.get_output_latency() * 1000.0))
	print("Current device   : ", AudioServer.output_device)
	print("Devices available: ", AudioServer.get_output_device_list())
	print("Master           : vol ", AudioServer.get_bus_volume_db(0), " dB, muted=", AudioServer.is_bus_mute(0))
	var sfx := AudioServer.get_bus_index("SFX")
	if sfx != -1:
		print("SFX bus          : vol ", AudioServer.get_bus_volume_db(sfx), " dB, muted=",
			AudioServer.is_bus_mute(sfx), ", sends to ", AudioServer.get_bus_send(sfx))
	else:
		print("SFX bus          : (absent — AudioManager creates it at runtime)")

	# Tap the mixed output.
	var cap := AudioEffectCapture.new()
	cap.buffer_length = 2.0
	AudioServer.add_bus_effect(0, cap)
	await get_tree().process_frame
	cap.clear_buffer()

	# A plain loud tone straight to Master: this bypasses the game entirely, so
	# it is the cleanest test of "can this machine make a sound at all".
	var player := AudioStreamPlayer.new()
	player.bus = "Master"
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 44100.0
	gen.buffer_length = 0.25
	player.stream = gen
	add_child(player)
	player.play()
	var pb := player.get_stream_playback() as AudioStreamGeneratorPlayback
	var phase := 0.0
	var elapsed := 0.0
	var peak := 0.0
	while elapsed < TEST_SECONDS:
		var avail: int = pb.get_frames_available()
		for i in avail:
			var s: float = sin(phase * TAU) * 0.5      # 440 Hz at half scale
			pb.push_frame(Vector2(s, s))
			phase = fmod(phase + 440.0 / 44100.0, 1.0)
		var got: int = cap.get_frames_available()
		if got > 0:
			for f in cap.get_buffer(got):
				peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
		elapsed += get_process_delta_time()
		await get_tree().process_frame
	player.stop()
	print("\nTone (direct to Master)  : measured peak %.4f  <- you should have HEARD a 440 Hz beep" % peak)

	# Now the game's own path, through AudioManager and the SFX bus.
	var am := get_node_or_null("/root/AudioManager")
	if am == null:
		print("AudioManager             : MISSING (autoload not loaded)")
	else:
		cap.clear_buffer()
		am.play_sfx("defeat")
		var peak2 := 0.0
		var t := 0.0
		while t < TEST_SECONDS:
			var got2: int = cap.get_frames_available()
			if got2 > 0:
				for f2 in cap.get_buffer(got2):
					peak2 = maxf(peak2, maxf(absf(f2.x), absf(f2.y)))
			t += get_process_delta_time()
			await get_tree().process_frame
		print("Game sfx (via SFX bus)   : measured peak %.4f  <- you should have HEARD the defeat sting" % peak2)

	print("\nHow to read this:")
	print("  both peaks > 0 but you heard nothing -> the engine IS producing audio;")
	print("     the fault is the output device or the OS mixer (check the device list")
	print("     above, and your OS per-application volume for Godot).")
	print("  a peak of 0 -> the engine is producing silence; send me this output.")
	print("===============================================================\n")
	get_tree().quit()
