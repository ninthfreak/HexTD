class_name Tower
extends Node2D
## Sits on a hex, auto-targets the enemy furthest along the path within range,
## and fires projectiles at its fire rate. Drawn as a diamond.

var data: TowerData              # effective (per-instance) stats, reflecting upgrades
var base_data: TowerData         # the shared registry stats this tower was built from
var slot_levels: Array = []      # current tier reached in each upgrade slot (0 = base)
var invested := 0                # total money spent (base + upgrades), for sell refund
var board                 # GameBoard (untyped to keep dependencies simple)
var cell: Vector2i
var target_priority := "first"   # "first" | "last" | "strongest" — toggled in-game
var _cooldown := 0.0
var _laser_target = null
var _charge := 0.0               # laser ramp progress in seconds
var _hum: AudioStreamPlayer = null
var _hum_pb: AudioStreamGeneratorPlayback = null
var _hum_phase := 0.0
var _hum_freq := 40.0

const LASER_START_FRAC := 0.1    # laser begins at 10% power, climbs to full
const BEAM_GLOW := 2.2           # laser beam/impact over-bright factor (alpha-blended, so higher than projectiles)
const HUM_BASE_HZ := 40.0        # hum fundamental at zero charge
const HUM_PITCH_MAX := 25.0      # ~40 Hz hum rises to ~1 kHz at full charge
const HUM_PITCH_CURVE := 0.6     # <1 = rises rapidly early in the charge
const HUM_MIX_RATE := 44100.0
const HUM_TABLE := 2048
const HUM_VOL_DB := -3.0

# One cycle of the hum buzz (harmonics with a 1/k^1.2 rolloff), built once and shared.
static var _hum_table: PackedFloat32Array

static func _hum_wavetable() -> PackedFloat32Array:
	if not _hum_table.is_empty():
		return _hum_table
	var tbl := PackedFloat32Array()
	tbl.resize(HUM_TABLE)
	var mx := 0.0
	for i in HUM_TABLE:
		var ph := TAU * float(i) / float(HUM_TABLE)
		var s := 0.0
		for k in range(1, 13):
			s += (1.0 / pow(float(k), 1.2)) * sin(ph * float(k))
		tbl[i] = s
		mx = maxf(mx, absf(s))
	if mx > 0.0:
		for i in HUM_TABLE:
			tbl[i] = tbl[i] / mx
	_hum_table = tbl
	return _hum_table

func setup(d: TowerData, b, pos: Vector2) -> void:
	base_data = d
	board = b
	position = pos
	cell = b.world_cell(pos)
	invested = d.cost
	slot_levels = []
	for _i in range(slot_count()):
		slot_levels.append(0)
	_apply_levels()   # data = a private copy of the base stats
	queue_redraw()

# ---------------------------------------------------------------- upgrades
const SELL_REFUND := 0.75        # fraction of total spend returned when selling

func slot_count() -> int:
	return mini(3, base_data.upgrades.size())

func slot_name(s: int) -> String:
	return str(base_data.upgrades[s].get("name", "Slot %d" % (s + 1)))

func slot_max(s: int) -> int:
	var tiers = base_data.upgrades[s].get("tiers", [])
	return mini(5, tiers.size())

func slot_level(s: int) -> int:
	return slot_levels[s]

func can_upgrade(s: int) -> bool:
	return s >= 0 and s < slot_count() and slot_levels[s] < slot_max(s)

## Cost of the next tier in slot s, or -1 if maxed / invalid.
func next_cost(s: int) -> int:
	if not can_upgrade(s):
		return -1
	return int(base_data.upgrades[s]["tiers"][slot_levels[s]].get("cost", 0))

func upgrade(s: int) -> void:
	if not can_upgrade(s):
		return
	invested += next_cost(s)
	slot_levels[s] += 1
	_apply_levels()

func sell_value() -> int:
	return int(floor(invested * SELL_REFUND))

func refund_percent() -> int:
	return int(round(SELL_REFUND * 100.0))

## Human-readable summary of the next tier in slot s (for the in-game tooltip).
func tier_summary(s: int) -> String:
	if not can_upgrade(s):
		return ""
	var tier: Dictionary = base_data.upgrades[s]["tiers"][slot_levels[s]]
	var lines := []
	var labels := {"damage": "Damage", "range": "Range", "fire_rate": "Fire rate", "directions": "Projectiles", "ramp_time": "Ramp time"}
	for key in ["damage", "range", "fire_rate", "directions", "ramp_time"]:
		if tier.has(key) and float(tier[key]) != 0.0:
			lines.append("%s %s" % [labels[key], _delta_str(key, float(tier[key]))])
	var flag_labels := {"cipher": "Cipher", "bit_corruption": "Bit corruption", "ignore_walls": "Ignore walls"}
	for key in ["cipher", "bit_corruption", "ignore_walls"]:
		var fv := str(tier.get(key, ""))
		if fv == "on":
			lines.append("%s: enabled" % flag_labels[key])
		elif fv == "off":
			lines.append("%s: removed" % flag_labels[key])
	if lines.is_empty():
		return "No stat change"
	return "\n".join(lines)

func _delta_str(key: String, v: float) -> String:
	var sgn := "+" if v > 0.0 else ""
	match key:
		"range", "directions":
			return "%s%d" % [sgn, int(round(v))]
		"fire_rate":
			return "%s%s/s" % [sgn, _trim(v)]
		"ramp_time":
			return "%s%ss" % [sgn, _trim(v)]
		_:
			return "%s%s" % [sgn, _trim(v)]

func _trim(v: float) -> String:
	var s := "%.2f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s

# Rebuild the effective stats from base, then apply every purchased tier, slot by slot.
# (Flags resolve in slot order, so a later slot's "on"/"off" overrides an earlier one.)
func _apply_levels() -> void:
	data = base_data.duplicate() as TowerData
	for s in range(slot_count()):
		var tiers = base_data.upgrades[s].get("tiers", [])
		for i in range(slot_levels[s]):
			_apply_tier(tiers[i])
	queue_redraw()

func _apply_tier(tier: Dictionary) -> void:
	data.damage += float(tier.get("damage", 0.0))
	data.range_tiles += int(round(float(tier.get("range", 0.0))))
	data.fire_rate += float(tier.get("fire_rate", 0.0))
	data.directions += int(round(float(tier.get("directions", 0.0))))
	data.ramp_time = maxf(0.0, data.ramp_time + float(tier.get("ramp_time", 0.0)))
	_apply_flag("cipher", tier)
	_apply_flag("bit_corruption", tier)
	_apply_flag("ignore_walls", tier)

func _apply_flag(key: String, tier: Dictionary) -> void:
	var v := str(tier.get(key, ""))
	if v == "on":
		data.set(key, true)
	elif v == "off":
		data.set(key, false)

func _process(delta: float) -> void:
	if data == null:
		return
	# One fire mode per tower. Add a case here to introduce a new mode.
	match data.fire_mode:
		"radial":
			_process_radial(delta)
		"laser":
			_process_laser(delta)
		_:
			_process_targeted(delta)

# Targeted: homing shot at the enemy furthest along the path, within range and clear line of sight.
func _process_targeted(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0:
		var t = _find_target()
		if t != null:
			_shoot(t)
			_cooldown = 1.0 / data.fire_rate

# Radial: idle until any enemy is in range, then emit a volley of fixed-direction
# shots every 1/fire_rate seconds. Shots fly straight out and die at range edge.
func _process_radial(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0:
		if _any_enemy_in_range():
			_fire_volley()
			_cooldown = 1.0 / data.fire_rate
		else:
			_cooldown = 0.0   # stay primed so it fires the instant one enters

func _any_enemy_in_range() -> bool:
	for e in board.enemies:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if HexUtils.axial_distance(cell, board.world_cell(e.position)) <= board.tower_reach(data.range_tiles):
			return true
	return false

func _fire_volley() -> void:
	var n: int = maxi(1, data.directions)
	for i in range(n):
		var ang := TAU * float(i) / float(n)   # i=0 -> 0 deg; for n=6 these are the hex flat sides
		var p := RadialProjectile.new()
		p.setup(position, Vector2(cos(ang), sin(ang)), data.damage, data.projectile_speed, cell, board.tower_reach(data.range_tiles), data.color, board)
		p.ignore_walls = data.ignore_walls
		p.pierces_ecc = data.bit_corruption
		p.can_see_encrypted = data.cipher
		board.add_projectile(p)

# Laser: lock one target, ramp damage from low to full while it stays locked,
# and deal continuous damage until the target dies or leaves range/sight.
func _process_laser(delta: float) -> void:
	if not _target_still_valid(_laser_target):
		_laser_target = null
		_charge = 0.0
	if _laser_target == null:
		_laser_target = _acquire_target()
		_charge = 0.0
	if _laser_target != null:
		_charge = minf(_charge + delta, data.ramp_time)
		var cr := 1.0 if data.ramp_time <= 0.0 else clampf(_charge / data.ramp_time, 0.0, 1.0)
		var frac := lerpf(LASER_START_FRAC, 1.0, cr)
		_laser_target.take_damage(data.damage * frac * delta, data.bit_corruption)
		_set_hum(true, cr)
	else:
		_set_hum(false, 0.0)
	queue_redraw()   # redraw every frame so the beam follows the target

## Continuous laser hum, synthesized live so there's no loop seam/click and the
## pitch can sweep smoothly. Frequency rises rapidly with charge toward ~1 kHz.
func _set_hum(active: bool, charge_ratio: float) -> void:
	if active:
		if _hum == null:
			var gen := AudioStreamGenerator.new()
			gen.mix_rate = HUM_MIX_RATE
			gen.buffer_length = 0.1
			_hum = AudioStreamPlayer.new()
			_hum.stream = gen
			var am = get_node_or_null("/root/AudioManager")
			_hum.bus = am.SFX_BUS if am else "Master"
			_hum.volume_db = HUM_VOL_DB
			add_child(_hum)
		if not _hum.playing:
			_hum.play()
			_hum_pb = _hum.get_stream_playback() as AudioStreamGeneratorPlayback
			_hum_phase = 0.0
		_hum_freq = HUM_BASE_HZ * lerpf(1.0, HUM_PITCH_MAX, pow(charge_ratio, HUM_PITCH_CURVE))
		_fill_hum()
	elif _hum != null and _hum.playing:
		_hum.stop()
		_hum_pb = null

func _fill_hum() -> void:
	if _hum_pb == null:
		return
	var tbl := _hum_wavetable()
	var n := tbl.size()
	var inc: float = _hum_freq / HUM_MIX_RATE * float(n)
	var avail := _hum_pb.get_frames_available()
	for i in avail:
		var i0 := int(_hum_phase) % n
		var i1 := (i0 + 1) % n
		var frac: float = _hum_phase - floor(_hum_phase)
		var s: float = lerpf(tbl[i0], tbl[i1], frac)
		_hum_pb.push_frame(Vector2(s, s))
		_hum_phase += inc
		if _hum_phase >= float(n):
			_hum_phase -= float(n)

func _target_still_valid(t) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	if HexUtils.axial_distance(cell, board.world_cell(t.position)) > board.tower_reach(data.range_tiles):
		return false
	return board.has_los(position, t.position)

func _find_target():
	return _acquire_target()

# Can this tower see/hit the given enemy? Encrypted enemies need Cipher.
func _can_see(e) -> bool:
	return data.cipher or not e.data.encrypted

# Choose a target among in-range, visible enemies according to target_priority.
func _acquire_target():
	var best = null
	var best_key := 0
	var best_tie := 0
	var first := true
	for e in board.enemies:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if HexUtils.axial_distance(cell, board.world_cell(e.position)) > board.tower_reach(data.range_tiles):
			continue
		if not board.has_los(position, e.position):
			continue
		var key: int
		var tie := 0                       # tiebreak: furthest along the path wins
		match target_priority:
			"last":
				key = -e.progress()        # least far along the path
			"strongest":
				key = e.data.rank          # lowest in the editor list (highest rank) wins
				tie = e.progress()         # among equal rank, prefer the frontmost
			_:
				key = e.progress()         # "first": furthest along the path
		if first or key > best_key or (key == best_key and tie > best_tie):
			first = false
			best_key = key
			best_tie = tie
			best = e
	return best

func cycle_target_priority() -> String:
	match target_priority:
		"first":
			target_priority = "last"
		"last":
			target_priority = "strongest"
		_:
			target_priority = "first"
	_laser_target = null   # re-acquire under the new rule
	_charge = 0.0
	return target_priority

func _shoot(t) -> void:
	var p := Projectile.new()
	p.setup(position, t, data.damage, data.projectile_speed, data.color, data.bit_corruption)
	board.add_projectile(p)

func _draw() -> void:
	if data == null:
		return
	match data.fire_mode:
		"radial":
			_draw_star()
		"laser":
			_draw_laser()
		_:
			_draw_diamond()

# Laser: unique circle body, plus a beam to the locked target whose
# thickness/brightness grows with charge.
func _draw_laser() -> void:
	if _laser_target != null and is_instance_valid(_laser_target):
		var cr := 1.0 if data.ramp_time <= 0.0 else clampf(_charge / data.ramp_time, 0.0, 1.0)
		var frac := lerpf(LASER_START_FRAC, 1.0, cr)
		var to: Vector2 = _laser_target.position - position
		# over-bright the beam + impact so the HDR glow blooms them (it's light, after all)
		var bc := data.color
		var beam := Color(bc.r * BEAM_GLOW, bc.g * BEAM_GLOW, bc.b * BEAM_GLOW, lerpf(0.35, 0.9, frac))
		draw_line(Vector2.ZERO, to, beam, lerpf(4.0, 12.0, frac))
		draw_circle(to, lerpf(4.0, 10.0, frac), Color(BEAM_GLOW, BEAM_GLOW, BEAM_GLOW, 0.8))
	var r: float = GameBoard.TOWER_RADIUS
	draw_circle(Vector2.ZERO, r, data.color)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(0, 0, 0, 0.5), 2.0, true)
	draw_circle(Vector2.ZERO, r * 0.4, Color(1, 1, 1, 0.85))

func _draw_diamond() -> void:
	var s: float = GameBoard.TOWER_RADIUS
	var pts := PackedVector2Array([
		Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0)
	])
	draw_colored_polygon(pts, data.color)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Color(0, 0, 0, 0.5), 2.0)

# Star with one point per firing direction, aligned to the spokes (point at 0 deg).
func _draw_star() -> void:
	# Point count grows sub-linearly with the projectile count so dense radial towers
	# don't become unreadable spiky blobs: round(sqrt(3 * dirs)), e.g. 3->3, 12->6, 24->8.
	var dirs: int = maxi(1, data.directions)
	var n: int = maxi(3, int(round(sqrt(3.0 * float(dirs)))))
	var outer: float = GameBoard.TOWER_RADIUS
	var inner := outer * 0.46
	var perim := PackedVector2Array()
	for i in range(2 * n):
		var ang := TAU * float(i) / float(2 * n)
		var rad: float = outer if i % 2 == 0 else inner
		perim.append(Vector2(cos(ang), sin(ang)) * rad)
	# fill as a fan of triangles from the center (robust for a concave star)
	for i in range(perim.size()):
		draw_colored_polygon(
			PackedVector2Array([Vector2.ZERO, perim[i], perim[(i + 1) % perim.size()]]),
			data.color)
	var outline := perim.duplicate()
	outline.append(perim[0])
	draw_polyline(outline, Color(0, 0, 0, 0.5), 2.0)
