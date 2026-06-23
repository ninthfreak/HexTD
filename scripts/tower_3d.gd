class_name Tower3D
extends Node3D
## 3D tower. Targeting, upgrades, fire modes and the audible laser hum are
## ported unchanged from the 2D Tower; all logic still operates on plane
## (Vector2) coordinates via the entity's `pp` field and `cell`. The body is
## an extruded prism (diamond / star / cylinder by fire mode), and the laser
## beam is a thin metallic cylinder reoriented each frame to point at the
## locked target.

var data: TowerData
var base_data: TowerData
var slot_levels: Array = []
var invested := 0
var board                            # GameBoard3D (untyped)
var cell: Vector2i
var pp := Vector2.ZERO               # plane position (the tower's center)
var target_priority := "first"
var _cooldown := 0.0
var _laser_target = null
var _charge := 0.0
var _hum: AudioStreamPlayer = null
var _hum_pb: AudioStreamGeneratorPlayback = null
var _hum_phase := 0.0
var _hum_freq := 40.0

# 3D scene
var _body: MeshInstance3D
var _beam: MeshInstance3D            # laser beam (null until first needed)
var _beam_cyl: CylinderMesh
var _beam_mat: StandardMaterial3D
var _beam_impact: MeshInstance3D     # bright dot at the target end

const LASER_START_FRAC := 0.1
const BEAM_GLOW := 2.2
const HUM_BASE_HZ := 40.0
const HUM_PITCH_MAX := 25.0
const HUM_PITCH_CURVE := 0.6
const HUM_MIX_RATE := 44100.0
const HUM_TABLE := 2048
const HUM_VOL_DB := -3.0

const BODY_HEIGHT := 8.0             # extruded body height (world units)
const BEAM_ORIGIN_LIFT := 8.0        # beam fires from the top of the body
const BEAM_TARGET_LIFT := 2.0        # mid-height of an enemy body (Enemy3D.BODY_HEIGHT * 0.5)
const BEAM_BASE_THICK := 0.6
const BEAM_FULL_THICK := 1.6

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

# `pos_plane` is the cell's plane center (Vector2); board.cell_center_world
# returns that on GameBoard3D as well, matching the 2D API.
func setup(d: TowerData, b, pos_plane: Vector2) -> void:
	base_data = d
	board = b
	pp = pos_plane
	cell = b.world_cell(pos_plane)
	invested = d.cost
	slot_levels = []
	for _i in range(slot_count()):
		slot_levels.append(0)
	_apply_levels()
	_sync_transform()
	_rebuild_body()

func _sync_transform() -> void:
	position = Vector3(pp.x, GameBoard3D.COPPER_TOP, pp.y)

# ---------------------------------------------------------------- upgrades (ported)
const SELL_REFUND := 0.75

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
	_rebuild_body()

func sell_value() -> int:
	return int(floor(invested * SELL_REFUND))

func refund_percent() -> int:
	return int(round(SELL_REFUND * 100.0))

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

func _apply_levels() -> void:
	data = base_data.duplicate() as TowerData
	for s in range(slot_count()):
		var tiers = base_data.upgrades[s].get("tiers", [])
		for i in range(slot_levels[s]):
			_apply_tier(tiers[i])

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

# ---------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if data == null:
		return
	match data.fire_mode:
		"radial":
			_process_radial(delta)
		"laser":
			_process_laser(delta)
		_:
			_process_targeted(delta)

func _process_targeted(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0:
		var t = _find_target()
		if t != null:
			_shoot(t)
			_cooldown = 1.0 / data.fire_rate

func _process_radial(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0:
		if _any_enemy_in_range():
			_fire_volley()
			_cooldown = 1.0 / data.fire_rate
		else:
			_cooldown = 0.0

func _any_enemy_in_range() -> bool:
	for e in board.enemies:
		if not is_instance_valid(e):
			continue
		if not _can_see(e):
			continue
		if HexUtils.axial_distance(cell, board.world_cell(e.pp)) <= board.tower_reach(data.range_tiles):
			return true
	return false

func _fire_volley() -> void:
	var n: int = maxi(1, data.directions)
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		var p := RadialProjectile3D.new()
		p.setup(pp, Vector2(cos(ang), sin(ang)), data.damage, data.projectile_speed,
				cell, board.tower_reach(data.range_tiles), data.color, board)
		p.ignore_walls = data.ignore_walls
		p.pierces_ecc = data.bit_corruption
		p.can_see_encrypted = data.cipher
		board.add_projectile(p)

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
		_update_beam(frac, true)
	else:
		_set_hum(false, 0.0)
		_update_beam(0.0, false)

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
	if HexUtils.axial_distance(cell, board.world_cell(t.pp)) > board.tower_reach(data.range_tiles):
		return false
	return board.has_los(pp, t.pp)

func _find_target():
	return _acquire_target()

func _can_see(e) -> bool:
	return data.cipher or not e.data.encrypted

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
		if HexUtils.axial_distance(cell, board.world_cell(e.pp)) > board.tower_reach(data.range_tiles):
			continue
		if not board.has_los(pp, e.pp):
			continue
		var key: int
		var tie := 0
		match target_priority:
			"last":
				key = -e.progress()
			"strongest":
				key = e.data.rank
				tie = e.progress()
			_:
				key = e.progress()
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
	_laser_target = null
	_charge = 0.0
	return target_priority

func _shoot(t) -> void:
	var p := Projectile3D.new()
	p.setup(pp, t, data.damage, data.projectile_speed, data.color, data.bit_corruption)
	board.add_projectile(p)

# ---------------------------------------------------------------- body mesh
# Rebuilt on upgrade because radial star geometry depends on `directions`.
func _rebuild_body() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
		_body = null
	if data == null:
		return
	_body = MeshInstance3D.new()
	_body.mesh = _build_body_mesh()
	_body.material_override = _body_material()
	add_child(_body)

func _body_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = data.color
	mat.metallic = 0.6
	mat.roughness = 0.25
	# A modest emissive accent in the tower's own colour so it reads as a glowing
	# tech construct on the dark board (and the floor reflects it) without
	# blooming as hard as the path/enemies.
	mat.emission_enabled = true
	mat.emission = data.color
	mat.emission_energy_multiplier = 0.5
	return mat

func _build_body_mesh() -> ArrayMesh:
	var pts: PackedVector2Array
	match data.fire_mode:
		"radial":
			pts = _star_points()
		"laser":
			pts = _circle_points(28)
		_:
			pts = _diamond_points()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)   # flat facets, so the body's edges stay crisp
	_emit_prism_fan(st, pts, BODY_HEIGHT, 0.0)
	st.generate_normals()
	return st.commit()

func _diamond_points() -> PackedVector2Array:
	var s: float = GameBoard3D.TOWER_RADIUS
	return PackedVector2Array([
		Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0)
	])

# Star with one point per firing direction (matches the 2D rule).
func _star_points() -> PackedVector2Array:
	var dirs: int = maxi(1, data.directions)
	var n: int = maxi(3, int(round(sqrt(3.0 * float(dirs)))))
	var outer: float = GameBoard3D.TOWER_RADIUS
	var inner := outer * 0.46
	var perim := PackedVector2Array()
	for i in range(2 * n):
		var ang := TAU * float(i) / float(2 * n)
		var rad: float = outer if i % 2 == 0 else inner
		perim.append(Vector2(cos(ang), sin(ang)) * rad)
	return perim

func _circle_points(n: int) -> PackedVector2Array:
	var r: float = GameBoard3D.TOWER_RADIUS
	var pts := PackedVector2Array()
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	return pts

# Fan-from-center prism: top cap + side walls. Mirrors GameBoard3D._add_prism.
func _emit_prism_fan(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		# (center, b, a): cap faces +Y up under the (x,y)->(x,0,y) handedness
		# flip; sides wound outward. See GameBoard3D._add_cap / _add_prism.
		st.add_vertex(Vector3(center.x, top, center.y))
		st.add_vertex(Vector3(b.x, top, b.y))
		st.add_vertex(Vector3(a.x, top, a.y))
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(ab)
		st.add_vertex(at); st.add_vertex(bt); st.add_vertex(bb)

# ---------------------------------------------------------------- laser beam
# Built lazily so non-laser towers stay cheap. Each frame the cylinder is
# stretched and oriented from tower top to the locked target.
func _ensure_beam() -> void:
	if _beam != null and is_instance_valid(_beam):
		return
	_beam_cyl = CylinderMesh.new()
	_beam_cyl.top_radius = BEAM_BASE_THICK
	_beam_cyl.bottom_radius = BEAM_BASE_THICK
	_beam_cyl.height = 1.0
	_beam_cyl.radial_segments = 10
	_beam_cyl.rings = 1
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.albedo_color = data.color
	_beam_mat.emission_enabled = true
	_beam_mat.emission = data.color
	_beam_mat.emission_energy_multiplier = BEAM_GLOW
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam = MeshInstance3D.new()
	_beam.mesh = _beam_cyl
	_beam.material_override = _beam_mat
	# Beam lives at world scope on the board entities root so its global
	# transform isn't twisted by future tower-local transforms.
	board._entities.add_child(_beam)
	_beam_impact = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BEAM_FULL_THICK * 1.8
	sm.height = sm.radius * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	_beam_impact.mesh = sm
	var im := StandardMaterial3D.new()
	im.albedo_color = Color(1, 1, 1, 1)
	im.emission_enabled = true
	im.emission = Color(1, 1, 1)
	im.emission_energy_multiplier = BEAM_GLOW
	im.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_impact.material_override = im
	board._entities.add_child(_beam_impact)

func _update_beam(frac: float, on: bool) -> void:
	if not on:
		if _beam != null and is_instance_valid(_beam):
			_beam.visible = false
			_beam_impact.visible = false
		return
	_ensure_beam()
	_beam.visible = true
	_beam_impact.visible = true
	var thick := lerpf(BEAM_BASE_THICK, BEAM_FULL_THICK, frac)
	var alpha := lerpf(0.35, 0.9, frac)
	_beam_cyl.top_radius = thick
	_beam_cyl.bottom_radius = thick
	_beam_mat.albedo_color = Color(data.color.r, data.color.g, data.color.b, alpha)
	# Endpoints in world coords. Pull the target's plane pos through an
	# explicit Vector2 first so the Vector3 constructor sees typed floats
	# rather than Variant member accesses on an untyped reference.
	var tpp: Vector2 = _laser_target.pp
	var from := Vector3(pp.x, GameBoard3D.COPPER_TOP + BEAM_ORIGIN_LIFT, pp.y)
	# enemies hover at ENEMY_Y, so aim there (+ a little for body mid-height)
	var to := Vector3(tpp.x, GameBoard3D.ENEMY_Y + BEAM_TARGET_LIFT, tpp.y)
	var dir := to - from
	var dlen := dir.length()
	if dlen < 0.001:
		_beam.visible = false
		_beam_impact.visible = false
		return
	_beam_cyl.height = dlen
	# Orient the cylinder's Y axis along `dir`. Build an explicit basis to avoid
	# look_at edge-cases (target directly above the source).
	var y_axis := dir / dlen
	var ref := Vector3.RIGHT if absf(y_axis.y) > 0.99 else Vector3.UP
	var x_axis := y_axis.cross(ref).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	var mid := from + dir * 0.5
	_beam.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), mid)
	_beam_impact.global_transform = Transform3D(Basis(), to)
	var impact_scale: float = lerpf(0.6, 1.4, frac)
	_beam_impact.scale = Vector3(impact_scale, impact_scale, impact_scale)

# Clean up the externally-parented beam nodes when the tower is removed.
func _exit_tree() -> void:
	_set_hum(false, 0.0)
	if _beam != null and is_instance_valid(_beam):
		_beam.queue_free()
	if _beam_impact != null and is_instance_valid(_beam_impact):
		_beam_impact.queue_free()
