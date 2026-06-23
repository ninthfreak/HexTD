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
const DEFAULT_DEATH := "enemy_death"

var _pool: Array[AudioStreamPlayer] = []
var _streams := {}                 # name -> AudioStream (cache)
var _frame_counts := {}            # name -> count started this frame
var _laser_stream: AudioStream = null

func _ready() -> void:
	_setup_bus()
	# preload the known set; missing files are tolerated (logged, then skipped)
	for n in ["projectile_hit", "enemy_death"]:
		_stream_for(n)
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

func _process(_delta: float) -> void:
	if not _frame_counts.is_empty():
		_frame_counts.clear()

func _setup_bus() -> void:
	if AudioServer.get_bus_index(SFX_BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, SFX_BUS)
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, SFX_VOLUME_DB)
	# a limiter tames peaks when many sounds stack
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
	_frame_counts[key] = c + 1
	var p := _free_player()
	if p == null:
		return   # all voices busy -> drop this one (global polyphony cap)
	p.stream = stream
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.play()

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
