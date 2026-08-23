extends Node
## Standalone audio self-test. Open `scenes/audio_check.tscn` and press F6.
##
## Diagnoses "Godot makes no sound" without involving the game at all. It
## synthesises a tone in memory, so it does not touch the audio files, the WAV
## importer, the import cache, or the game's AudioManager — if this is silent,
## nothing in the project can be the cause.
##
## It then plays that tone through EVERY output device Godot can see, one at a
## time, announcing each. Godot picking a device that is not your speakers (an
## HDMI output, a disconnected headset, a virtual/monitor device) is the usual
## reason the editor and the game are silent while every other application on
## the machine is fine.

const TONE_SECONDS := 1.5
const TONE_HZ := 440.0

var _player: AudioStreamPlayer
var _pb: AudioStreamGeneratorPlayback
var _phase := 0.0
var _cap: AudioEffectCapture

func _ready() -> void:
	print("\n==================== HexTD audio self-test ====================")
	print("OS               : ", OS.get_name())
	print("Godot            : ", Engine.get_version_info().string)
	print("Audio driver     : ", ProjectSettings.get_setting("audio/driver/driver", "(default)"))
	print("Mix rate         : ", AudioServer.get_mix_rate(), " Hz")
	print("Output latency   : ", "%.1f ms" % (AudioServer.get_output_latency() * 1000.0))
	print("Master           : vol ", AudioServer.get_bus_volume_db(0), " dB, muted=", AudioServer.is_bus_mute(0))

	_cap = AudioEffectCapture.new()
	_cap.buffer_length = 2.0
	AudioServer.add_bus_effect(0, _cap)

	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.25
	_player.stream = gen
	add_child(_player)

	var devices: PackedStringArray = AudioServer.get_output_device_list()
	print("\nGodot sees ", devices.size(), " output device(s). Playing a ",
		int(TONE_HZ), " Hz tone through each — LISTEN for which one you hear.\n")
	var original: String = AudioServer.output_device
	for d in devices:
		AudioServer.output_device = d
		await get_tree().process_frame
		var pk := await _tone()
		var mark := "  <-- signal produced" if pk > 0.001 else "  <-- ENGINE PRODUCED SILENCE"
		print("  device %-42s measured peak %.4f%s" % ['"' + d + '"', pk, mark])
	AudioServer.output_device = original
	print("\nCurrent device restored to: ", AudioServer.output_device)

	# A real backend reports a non-zero output latency and names the machine's
	# actual sinks. Zero latency plus a lone "Default" is what the DUMMY driver
	# looks like: the mixer keeps running (so every measurement above still shows
	# signal) while nothing is ever handed to the hardware.
	var looks_dummy: bool = AudioServer.get_output_latency() <= 0.0 and devices.size() <= 1
	if looks_dummy:
		print("\n*** No real audio backend is open (latency 0.0 ms, only \"Default\"). ***")
		print("    Godot fell back to its dummy driver — it is mixing into nothing.")
		print("    This is why nothing plays even though every level above measures fine,")
		print("    and it is outside the project: no game-side change can restore sound.")

	# The game's own path, for completeness: files -> importer -> SFX bus.
	# Untyped on purpose: play_sfx is AudioManager's, not Node's, so a typed
	# reference makes this a hard error on newer engine versions.
	var am = get_node_or_null("/root/AudioManager")
	if am != null:
		_cap.clear_buffer()
		am.play_sfx("defeat")
		var pk2 := 0.0
		var t := 0.0
		while t < 1.5:
			var got: int = _cap.get_frames_available()
			if got > 0:
				for f in _cap.get_buffer(got):
					pk2 = maxf(pk2, maxf(absf(f.x), absf(f.y)))
			t += get_process_delta_time()
			await get_tree().process_frame
		print("Game sound via SFX bus    : measured peak %.4f" % pk2)

	print("\nHow to read this:")
	print("  * You HEARD a tone on some device -> that is your working device.")
	print("    Set it in Project Settings > Audio > Driver > Output Device (enable")
	print("    Advanced Settings to see it), or fix the OS default, and the game")
	print("    will use it too.")
	print("  * Peaks > 0 but you heard NOTHING, and the dummy-driver notice above")
	print("    appeared -> Godot cannot open your sound server. Check, in order:")
	print("      1. the editor's startup log for \"All audio drivers failed,")
	print("         falling back to the dummy driver\";")
	print("      2. how Godot is installed. A sandboxed build is the usual cause:")
	print("           flatpak override --user --socket=pulseaudio org.godotengine.Godot")
	print("           snap connect godot:audio-playback")
	print("      3. launching the editor with an explicit backend:")
	print("           godot --audio-driver PulseAudio     (or ALSA)")
	print("      4. that pipewire-pulse / pulseaudio is actually running for your")
	print("         user session (pactl info should answer).")
	print("  * A peak of 0.0000 everywhere -> the engine itself is producing no")
	print("    signal; send me this output.")
	print("===============================================================\n")
	get_tree().quit()

## Push one tone through the generator and return the peak seen on Master.
func _tone() -> float:
	if not _player.playing:
		_player.play()
	_pb = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	_cap.clear_buffer()
	var peak := 0.0
	var elapsed := 0.0
	var rate: float = AudioServer.get_mix_rate()
	while elapsed < TONE_SECONDS:
		if _pb != null:
			for i in _pb.get_frames_available():
				var s: float = sin(_phase * TAU) * 0.5
				_pb.push_frame(Vector2(s, s))
				_phase = fmod(_phase + TONE_HZ / rate, 1.0)
		var got: int = _cap.get_frames_available()
		if got > 0:
			for f in _cap.get_buffer(got):
				peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
		elapsed += get_process_delta_time()
		await get_tree().process_frame
	return peak
