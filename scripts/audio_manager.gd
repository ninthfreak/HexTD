extends Node
## Central SFX manager (autoload as "AudioManager").
##
## - Builds an "SFX" audio bus with a limiter at runtime (no .tres needed).
## - Plays one-shots from a pool of players with per-name burst-coalescing, so a
##   radial volley or a multi-enemy decay can't stack into dozens of voices.
## - Streams are looked up by name; unknown names are loaded from res://audio/<name>.wav
##   on demand, so data-driven per-enemy death sounds "just work" once the file exists.
## - Exposes the looping laser hum for towers to drive continuously.
##
## Nodes call it defensively via get_node_or_null("/root/AudioManager"), so if the
## autoload is ever missing the game stays silent instead of crashing.

const SFX_BUS := "SFX"
const SFX_VOLUME_DB := -8.0        # global SFX level - lower this if everything's too loud
const AUDIO_DIR := "res://audio/"
const POOL_SIZE := 24
const PER_NAME_PER_FRAME := 3      # max copies of one sound started in a single frame
const PER_NAME_VOICES := 4         # max copies of one sound sounding at once (mass-kill guard)
const MIN_GAP_MS := 45             # per-name floor between (non-stacked) restarts
const DEFAULT_DEATH := "enemy_death"

var _pool: Array[AudioStreamPlayer] = []
var _streams := {}                 # name -> AudioStream (cache)
var _frame_counts := {}            # name -> count started this frame
var _last_start_ms := {}           # name -> tick of the last start (rate floor)
var _laser_stream: AudioStream = null

## Every sound the game can play. Preloaded at boot so a failed import or a
## missing file is reported ONCE, loudly, at startup instead of degrading into
## silence that looks like a code bug.
const SOUND_NAMES := [
	"tower_fire", "radial_fire", "arc_fire", "dos_wave", "projectile_hit",
	"enemy_death", "enemy_split", "enemy_leak", "build_place", "sell",
	"upgrade", "cheat_money", "wave_start", "wave_clear", "victory", "defeat",
	"ui_click",
]

func _ready() -> void:
	_setup_bus()
	var loaded := 0
	for n in SOUND_NAMES:
		if _stream_for(n) != null:
			loaded += 1
	_laser_stream = _load_wav("laser_hum")
	if _laser_stream is AudioStreamWAV:
		# loop in code so you don't have to toggle Loop on import
		var w := _laser_stream as AudioStreamWAV
		var bpf := 1 if w.format == AudioStreamWAV.FORMAT_8_BITS else 2
		if w.stereo:
			bpf *= 2
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = w.data.size() / bpf   # end of stream, in frames (0 would disable the loop)
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_pool.append(p)
	# One-line audible-state report in the Output panel. If the game is ever
	# silent, this line says whether the cause is missing audio files or a muted
	# / turned-down bus, without needing a debugger.
	var idx := AudioServer.get_bus_index(SFX_BUS)
	print("AudioManager: %d/%d sounds loaded | SFX bus #%d vol %.1f dB muted=%s | master vol %.1f dB muted=%s" % [
		loaded, SOUND_NAMES.size(), idx,
		AudioServer.get_bus_volume_db(idx), str(AudioServer.is_bus_mute(idx)),
		AudioServer.get_bus_volume_db(0), str(AudioServer.is_bus_mute(0))])
	if loaded < SOUND_NAMES.size():
		push_warning("AudioManager: %d sound(s) missing from %s — re-import the project (Project > Tools > Reimport) if they exist on disk." % [
			SOUND_NAMES.size() - loaded, AUDIO_DIR])

func _process(_delta: float) -> void:
	if not _frame_counts.is_empty():
		_frame_counts.clear()

## Build the SFX bus, or take ownership of one that already exists.
##
## The bus is this script's to own, so its audible state is ENFORCED on every
## boot rather than assumed. A project that has ever had its Audio panel touched
## carries a `default_bus_layout.tres`; if that layout holds an "SFX" bus that is
## muted, turned down, bypassed, or not routed to Master, simply skipping setup
## (as this used to do when the bus already existed) silences the entire game
## with nothing in the logs to explain it.
func _setup_bus() -> void:
	var idx := AudioServer.get_bus_index(SFX_BUS)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, SFX_BUS)
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, SFX_VOLUME_DB)
	AudioServer.set_bus_mute(idx, false)
	AudioServer.set_bus_bypass_effects(idx, false)
	# Master carries every sound and the game exposes no control for it, so a
	# muted Master can only be a stale layout — restore it rather than ship mute.
	if AudioServer.is_bus_mute(0):
		AudioServer.set_bus_mute(0, false)
		push_warning("AudioManager: the Master bus was muted (stale bus layout?) — unmuted it.")
	# a limiter tames peaks when many sounds stack (only add ours once)
	for i in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectLimiter:
			return
	var lim := AudioEffectLimiter.new()
	lim.ceiling_db = -1.0
	lim.threshold_db = -6.0
	AudioServer.add_bus_effect(idx, lim)

## Play a one-shot by name (with a little pitch variation so repeats don't sound robotic).
## Bursts of the same sound in one frame are capped to keep the mix clean.
func play_sfx(sound_name: String, pitch_var := 0.06) -> void:
	var key := sound_name if sound_name != "" else DEFAULT_DEATH
	var stream := _stream_for(key)
	if stream == null:
		return
	var c: int = int(_frame_counts.get(key, 0))
	if c >= PER_NAME_PER_FRAME:
		return
	# Rate floor: simultaneous bursts (same frame) may stack up to the cap
	# above, but sequential restarts of one name are spaced out — many towers
	# firing the same sound become a texture instead of a machine gun.
	var now := Time.get_ticks_msec()
	if c == 0 and now - int(_last_start_ms.get(key, -1000)) < MIN_GAP_MS:
		return
	# One pass over the pool finds a free voice AND counts how many copies of this
	# sound are already sounding. A mass wipe would otherwise start a death sound
	# per kill: they arrive within milliseconds of each other, so the extra copies
	# only add clipping and mixer load while starving every other sound out of the
	# 24-voice pool.
	var free_p: AudioStreamPlayer = null
	var same := 0
	for p in _pool:
		if p.playing:
			if str(p.get_meta("sfx", "")) == key:
				same += 1
		elif free_p == null:
			free_p = p
	if same >= PER_NAME_VOICES:
		return
	if free_p == null:
		return   # all voices busy -> drop this one (global polyphony cap)
	_frame_counts[key] = c + 1
	_last_start_ms[key] = now
	free_p.set_meta("sfx", key)
	free_p.stream = stream
	free_p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	free_p.play()

## The looping hum stream for laser towers (already set to loop). May be null
## if the file is missing.
func laser_stream() -> AudioStream:
	return _laser_stream

## Mute/unmute all SFX (used by the sandbox sound toggle). The laser hum is on the
## same bus, so this silences it too.
func set_muted(muted: bool) -> void:
	var idx := AudioServer.get_bus_index(SFX_BUS)
	if idx != -1:
		AudioServer.set_bus_mute(idx, muted)

func _free_player() -> AudioStreamPlayer:
	for p in _pool:
		if not p.playing:
			return p
	return null

func _stream_for(sound_name: String) -> AudioStream:
	if _streams.has(sound_name):
		return _streams[sound_name]
	var s := _load_wav(sound_name)
	_streams[sound_name] = s   # cache even nulls so we don't retry-load every hit
	return s

func _load_wav(sound_name: String) -> AudioStream:
	var path := AUDIO_DIR + sound_name + ".wav"
	if not ResourceLoader.exists(path):
		push_warning("AudioManager: missing sound '%s' (%s)" % [sound_name, path])
		return null
	return load(path)
