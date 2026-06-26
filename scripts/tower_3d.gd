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
var _focus_cd := 0.0                 # post-kill blind/idle timer (focus_time)
var _hum: AudioStreamPlayer = null
var _hum_pb: AudioStreamGeneratorPlayback = null
var _hum_phase := 0.0
var _hum_freq := 40.0

# 3D scene
var _body: Node3D                    # container for the composite tower parts
var _beam: MeshInstance3D            # laser beam (null until first needed)
var _beam_cyl: CylinderMesh
var _beam_mat: StandardMaterial3D
var _beam_impact: MeshInstance3D     # bright dot at the target end

# --- ability badges (real world-space children of the tower) ---
# A row of billboarded hex "windows" hung off the (unscaled) tower root at a
# fixed local offset, fixed world scale. Each badge is a quad with a parallax
# shader: the hex frame is fixed, and the glyph inside reveals more/less of itself
# with camera distance, scaled around a per-icon focal point. The frame scales
# with the tower (perspective handles size); only the reveal scalars (zoom_t for
# window width, focal_t for focal travel) are pushed to the shader per frame.
@export var badge_world_scale: float = 1.0
@export var cam_dist_near: float = 500.0    # camera distance at/below which the glyph is fully in view (zoom_t = 1)
@export var cam_dist_far: float = 1500.0    # camera distance at minimum reveal (zoom_t = 0); 1000 lands ~68%+ in view
@export var focal_center_dist: float = 1000.0  # at/below this distance the focal is fully centered (focal_in)
var _badge_anchor: Node3D = null
var _badge_mats: Array = []          # ShaderMaterial per live badge (zoom_t updated per frame)
var _badge_info: Array = []          # {mi: MeshInstance3D, tip: String} per live badge (hover tooltips)
# Display order. `prop` is the TowerData flag; art is art/<file>_{glyph,backplate,rim}.png.
# focal/reveal_* drive the per-icon parallax window (see ABILITY_BADGE_PARALLAX_SPEC).
const ABILITY_BADGES := [
	{"prop": "bit_corruption", "file": "bit_corruption", "focal_out_x": 0.50, "focal_out_y": 0.50, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.55, "reveal_in": 1.25, "reveal_rate": 1.0, "tip": "Bit Corruption\nBypasses ECC damage resistance."},
	{"prop": "cipher", "file": "cipher", "focal_out_x": 0.48, "focal_out_y": 0.50, "focal_in_x": 0.48, "focal_in_y": 0.50, "reveal_out": 0.52, "reveal_in": 1.05, "reveal_rate": 1.0, "tip": "Cipher\nSees and targets Encrypted enemies."},
	{"prop": "buffer_overflow", "file": "buffer_overflow", "focal_out_x": 0.66, "focal_out_y": 0.34, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.50, "reveal_in": 1.40, "reveal_rate": 1.0, "tip": "Buffer Overflow\nSurplus damage spills into the target's decay children."},
	{"prop": "ignore_walls", "file": "tunneling", "focal_out_x": 0.84, "focal_out_y": 0.50, "focal_in_x": 0.60, "focal_in_y": 0.50, "reveal_out": 0.50, "reveal_in": 1.15, "reveal_rate": 1.0, "tip": "Tunneling\nAttacks through blocking tiles."},
	{"prop": "dos", "file": "dos", "focal_out_x": 0.72, "focal_out_y": 0.50, "focal_in_x": 0.50, "focal_in_y": 0.50, "reveal_out": 0.70, "reveal_in": 1.15, "reveal_rate": 1.0, "tip": "Denial of Service\nFreezes an enemy, then slows it."},
]
const BADGE_BASE_WORLD := 30.0       # frame edge length (world units) at scale 1.0; tune via badge_world_scale
static var _badge_tex := {}          # texture file base -> Texture2D (shared cache, caches misses)
static var _badge_shader_res: Shader = null
const _BADGE_SHADER := """
shader_type spatial;
// depth_test_disabled: badges are a HUD-like overlay — never occluded by the
// board, path, range highlight, towers or enemies. High render_priority (set on
// the material) keeps them sorted on top of other transparent geometry too.
render_mode unshaded, cull_disabled, depth_test_disabled;

uniform sampler2D glyph_tex : source_color;
uniform sampler2D backplate_tex : source_color;
uniform sampler2D rim_tex : source_color;
uniform vec2 focal_out = vec2(0.5, 0.5);
uniform vec2 focal_in = vec2(0.5, 0.5);
uniform float reveal_out = 0.5;
uniform float reveal_in = 1.0;
uniform float reveal_rate = 1.0;
uniform float zoom_t = 0.0;
uniform float focal_t = 0.0;

void vertex() {
	// Billboard the quad to face the camera while preserving its world scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0]),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1]),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2]),
		MODEL_MATRIX[3]);
}

void fragment() {
	float k = pow(clamp(zoom_t, 0.0, 1.0), reveal_rate);
	float kf = pow(clamp(focal_t, 0.0, 1.0), reveal_rate);
	float w = mix(reveal_out, reveal_in, k);          // window width fraction
	vec2 fcur = mix(focal_out, focal_in, kf);         // focal centers on its own (earlier) distance ramp
	vec2 guv = fcur + (UV - 0.5) * w;                 // sample window around the current focal
	vec4 glyph = texture(glyph_tex, guv);
	if (guv.x < 0.0 || guv.x > 1.0 || guv.y < 0.0 || guv.y > 1.0) {
		glyph.a = 0.0;
	}
	vec4 back = texture(backplate_tex, UV);
	vec4 rim = texture(rim_tex, UV);
	vec3 col = back.rgb;
	float gin = glyph.a * back.a;                     // clip glyph to hex interior
	col = mix(col, glyph.rgb, gin);
	col = mix(col, rim.rgb, rim.a);
	ALBEDO = col;
	ALPHA = max(max(back.a, gin), rim.a);
}
"""

const LASER_START_FRAC := 0.1
const BEAM_GLOW := 2.2
const HUM_BASE_HZ := 40.0
const HUM_PITCH_MAX := 25.0
const HUM_PITCH_CURVE := 0.6
const HUM_MIX_RATE := 44100.0
const HUM_TABLE := 2048
const HUM_VOL_DB := -3.0

const BODY_HEIGHT := 8.0             # nominal body height (world units)
const BEAM_ORIGIN_LIFT := 30.0       # beam fires from the tall laser cone tip
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
	position = Vector3(pp.x, GameBoard3D.BUS_TOP, pp.y)

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
	var labels := {"damage": "Damage", "range": "Range", "fire_rate": "Fire rate", "directions": "Projectiles", "ramp_time": "Ramp time", "focus_time": "Focus delay", "height": "Height", "width": "Width"}
	for key in ["damage", "range", "fire_rate", "directions", "ramp_time", "focus_time", "height", "width"]:
		if tier.has(key) and float(tier[key]) != 0.0:
			lines.append("%s %s" % [labels[key], _delta_str(key, float(tier[key]))])
	if str(tier.get("color", "")) != "":
		lines.append("Color change")
	var flag_labels := {"cipher": "Cipher", "bit_corruption": "Bit corruption", "ignore_walls": "Ignore walls", "buffer_overflow": "Buffer overflow", "dos": "Denial of service"}
	for key in ["cipher", "bit_corruption", "ignore_walls", "buffer_overflow", "dos"]:
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
		"ramp_time", "focus_time":
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
	if tier.has("focus_time"):
		data.focus_time = maxf(0.1, data.focus_time + float(tier["focus_time"]))
	data.height_scale = maxf(0.05, data.height_scale + float(tier.get("height", 0.0)))
	data.width_scale = maxf(0.05, data.width_scale + float(tier.get("width", 0.0)))
	var col := str(tier.get("color", ""))
	if col != "":
		data.color = Color(col)
	_apply_flag("cipher", tier)
	_apply_flag("bit_corruption", tier)
	_apply_flag("ignore_walls", tier)
	_apply_flag("buffer_overflow", tier)
	_apply_flag("dos", tier)

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
		"arc":
			_process_arc(delta)
		_:
			_process_targeted(delta)
	if _badge_anchor != null and not _badge_mats.is_empty():
		_update_badge_zoom()

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

# Arc: aim at the prioritised target and emit one expanding wave per shot.
func _process_arc(delta: float) -> void:
	_cooldown -= delta
	if _cooldown <= 0.0:
		var t = _find_target()
		if t != null:
			_fire_arc(t)
			_cooldown = 1.0 / data.fire_rate

func _fire_arc(t) -> void:
	var w := ArcWave3D.new()
	w.setup(pp, t.pp - pp, data.damage, data.projectile_speed,
			cell, board.tower_reach(data.range_tiles), data.color, board)
	w.pierces_ecc = data.bit_corruption
	w.applies_dos = data.dos
	w.can_see_encrypted = data.cipher
	board.add_projectile(w)

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
		p.applies_dos = data.dos
		board.add_projectile(p)

func _process_laser(delta: float) -> void:
	# focus_time: after a kill the beam is blind/idle for this long. This caps
	# kills/sec (swarm tax) while barely touching single-target DPS.
	if _focus_cd > 0.0:
		_focus_cd -= delta
		_laser_target = null
		_charge = 0.0
		_set_hum(false, 0.0)
		_update_beam(0.0, false)
		return
	if not _target_still_valid(_laser_target):
		_laser_target = null
		_charge = 0.0          # reset ramp when the target is lost (per-target ramp)
	if _laser_target == null:
		_laser_target = _acquire_target()
		_charge = 0.0          # fresh target starts at the weak end of the curve
	if _laser_target != null:
		_charge = minf(_charge + delta, data.ramp_time)
		var cr := 1.0 if data.ramp_time <= 0.0 else clampf(_charge / data.ramp_time, 0.0, 1.0)
		# Convex (quadratic ease-in) ramp: ~0 early, full at ramp_time.
		var factor := cr * cr
		var killed: bool = _laser_target.take_damage(data.damage * factor * delta, data.bit_corruption)
		if killed:
			_laser_target = null
			_charge = 0.0
			_focus_cd = data.focus_time
			_set_hum(false, 0.0)
			_update_beam(0.0, false)
			return
		_set_hum(true, cr)
		_update_beam(factor, true)
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
	# Tunneling (ignore_walls) lets the tower fire through blocking tiles, so LOS
	# is only required when the tower lacks it.
	return data.ignore_walls or board.has_los(pp, t.pp)

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
		if not data.ignore_walls and not board.has_los(pp, e.pp):
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
	p.setup(pp, t, data.damage, data.projectile_speed, data.color, data.bit_corruption, data.buffer_overflow, data.dos)
	board.add_projectile(p)

# ---------------------------------------------------------------- body (3D)
# One colour-coded, FLAT-SHADED low-poly primitive per fire mode (no base/caps):
#   single -> octagonal cylinder; radial -> stellated torus; laser -> cone;
#   arc -> flared horn / bell (the inverse of the laser cone — opens upward).
# Built by hand with per-face normals so they read as faceted low-poly (Godot's
# CylinderMesh/TorusMesh use smooth normals, which looked round / "high poly").
func _rebuild_body() -> void:
	if _body != null and is_instance_valid(_body):
		_body.queue_free()
		_body = null
	if data == null:
		return
	_body = Node3D.new()
	add_child(_body)
	var r: float = GameBoard3D.TOWER_RADIUS
	var mat := _core_mat()
	# Outer extent ~0.9 * TOWER_RADIUS: nearly fills the hex footprint with a
	# small margin so the body never reads as crossing into a neighbour cell.
	match data.fire_mode:
		"radial":
			# stellated torus: a polyhedral torus with a spike raised from every face,
			# bristling outward in all directions — echoing the all-directions burst.
			# Sized so the spike tips still sit inside the hex footprint.
			var inner := r * 0.30
			var outer := r * 0.72
			var tube := (outer - inner) * 0.5
			var spike := tube * 1.15
			_part(_low_poly_stellated_torus(inner, outer, 8, 6, spike), mat, tube + spike)
		"laser":
			_part(_low_poly_cone(r * 0.9, 60.0, 6), mat, 0.0)
		"arc":
			# Flared emitter: narrow base, concave flare to a wide open mouth on top.
			_part(_low_poly_horn(r * 0.26, r * 0.95, 52.0, 8, 6), mat, 0.0)
		_:
			_part(_low_poly_cylinder(r * 0.9, 40.0, 8), mat, 0.0)
	# Upgrades can reshape the body: scale width in the plane (X/Z) and height in Y.
	# Scaling the whole container keeps every fire mode (and its part offsets) correct.
	_body.scale = Vector3(maxf(0.05, data.width_scale), maxf(0.05, data.height_scale), maxf(0.05, data.width_scale))

func _part(mesh: Mesh, mat: Material, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position.y = y
	_body.add_child(mi)
	return mi

# Add a flat triangle with an outward normal (away from `ctr`).
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ctr: Vector3) -> void:
	var nrm := (b - a).cross(c - a)
	if nrm.length() < 0.000001:
		return
	nrm = nrm.normalized()
	if nrm.dot((a + b + c) / 3.0 - ctr) < 0.0:
		nrm = -nrm
	for v in [a, b, c]:
		st.set_normal(nrm); st.add_vertex(v)

# Flat-shaded N-gon prism (base at y=0, up to y=height).
func _low_poly_cylinder(rad: float, height: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, height * 0.5, 0)
	var topc := Vector3(0, height, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * rad, 0, sin(a0) * rad)
		var b1 := Vector3(cos(a1) * rad, 0, sin(a1) * rad)
		var t0 := b0 + Vector3(0, height, 0)
		var t1 := b1 + Vector3(0, height, 0)
		_tri(st, b0, b1, t1, ctr); _tri(st, b0, t1, t0, ctr)   # side quad
		_tri(st, topc, t0, t1, ctr)                            # top cap
		_tri(st, Vector3.ZERO, b1, b0, ctr)                    # bottom cap
	return st.commit()

# Flat-shaded N-gon cone / pyramid (base at y=0, apex at y=height).
func _low_poly_cone(base_r: float, height: float, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := Vector3(0, height, 0)
	var ctr := Vector3(0, height * 0.33, 0)
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
		var b1 := Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
		_tri(st, apex, b0, b1, ctr)              # side face
		_tri(st, Vector3.ZERO, b1, b0, ctr)      # base cap
	return st.commit()

# Flat-shaded flared horn / bell — a body of revolution opening upward. Rings of
# an N-gon are lofted from `base_r` at the bottom to `rim_r` at the top, with the
# radius following a concave curve (radius grows faster near the top, FLARE_POW),
# so the wall bows outward like a trumpet bell. The mouth is left open (no top
# cap); a small bottom cap closes the base where it meets the turret.
func _low_poly_horn(base_r: float, rim_r: float, height: float, sides: int, segs: int) -> ArrayMesh:
	const FLARE_POW := 2.4
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ctr := Vector3(0, height * 0.5, 0)
	for s in range(segs):
		var f0 := float(s) / float(segs)
		var f1 := float(s + 1) / float(segs)
		var y0 := height * f0
		var y1 := height * f1
		var r0: float = base_r + (rim_r - base_r) * pow(f0, FLARE_POW)
		var r1: float = base_r + (rim_r - base_r) * pow(f1, FLARE_POW)
		for i in range(sides):
			var a0 := TAU * float(i) / float(sides)
			var a1 := TAU * float(i + 1) / float(sides)
			var p00 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var p10 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var p01 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			var p11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			_tri(st, p00, p10, p11, ctr); _tri(st, p00, p11, p01, ctr)   # flared side quad
	# Bottom cap (small octagon) so the base reads solid where it mounts.
	for i in range(sides):
		var a0 := TAU * float(i) / float(sides)
		var a1 := TAU * float(i + 1) / float(sides)
		var b0 := Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
		var b1 := Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
		_tri(st, Vector3.ZERO, b1, b0, ctr)
	return st.commit()

# Flat-shaded polyhedral torus lying flat (major ring in XZ), centred at y=0.
# `rings` faces around the main ring, `tube_sides` quads around the tube.
func _low_poly_torus(inner_r: float, outer_r: float, rings: int, tube_sides: int) -> ArrayMesh:
	var rr := (inner_r + outer_r) * 0.5
	var tt := (outer_r - inner_r) * 0.5
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings):
		var u0 := TAU * float(i) / float(rings)
		var u1 := TAU * float(i + 1) / float(rings)
		for j in range(tube_sides):
			var v0 := TAU * float(j) / float(tube_sides)
			var v1 := TAU * float(j + 1) / float(tube_sides)
			var a := _torus_pt(rr, tt, u0, v0)
			var b := _torus_pt(rr, tt, u1, v0)
			var c := _torus_pt(rr, tt, u1, v1)
			var d := _torus_pt(rr, tt, u0, v1)
			var nrm := _torus_nrm((u0 + u1) * 0.5, (v0 + v1) * 0.5)
			for v in [a, b, c, a, c, d]:
				st.set_normal(nrm); st.add_vertex(v)
	return st.commit()

func _torus_pt(rr: float, tt: float, u: float, v: float) -> Vector3:
	return Vector3(cos(u), 0, sin(u)) * (rr + tt * cos(v)) + Vector3(0, tt * sin(v), 0)

func _torus_nrm(u: float, v: float) -> Vector3:
	return Vector3(cos(u) * cos(v), sin(v), sin(u) * cos(v)).normalized()

# Flat-shaded stellated torus: the same polyhedral torus, but every quad face is
# raised into a 4-sided pyramid whose apex is pushed out along the face normal by
# `spike`, so the body bristles with points in all directions. Each pyramid side is
# oriented outward from that spike's own axis (not the global centre), so spikes on
# the inner rim point inward correctly.
func _low_poly_stellated_torus(inner_r: float, outer_r: float, rings: int, tube_sides: int, spike: float) -> ArrayMesh:
	var rr := (inner_r + outer_r) * 0.5
	var tt := (outer_r - inner_r) * 0.5
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(rings):
		var u0 := TAU * float(i) / float(rings)
		var u1 := TAU * float(i + 1) / float(rings)
		for j in range(tube_sides):
			var v0 := TAU * float(j) / float(tube_sides)
			var v1 := TAU * float(j + 1) / float(tube_sides)
			var a := _torus_pt(rr, tt, u0, v0)
			var b := _torus_pt(rr, tt, u1, v0)
			var c := _torus_pt(rr, tt, u1, v1)
			var d := _torus_pt(rr, tt, u0, v1)
			var um := (u0 + u1) * 0.5
			var vm := (v0 + v1) * 0.5
			var base_c := _torus_pt(rr, tt, um, vm)
			var apex := base_c + _torus_nrm(um, vm) * spike
			var mid := (base_c + apex) * 0.5    # orient each side face away from the spike axis
			_tri(st, a, b, apex, mid)
			_tri(st, b, c, apex, mid)
			_tri(st, c, d, apex, mid)
			_tri(st, d, a, apex, mid)
	return st.commit()

# Colour-coded body material: the tower's own colour, lit + a soft self-glow.
# Low metallic so it reads as colour, not a dark mirror; two-sided so the hand-
# built meshes never cull inside-out.
func _core_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = data.color
	m.metallic = 0.25
	m.roughness = 0.35
	m.emission_enabled = true
	m.emission = data.color
	m.emission_energy_multiplier = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

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
	var from := Vector3(pp.x, GameBoard3D.BUS_TOP + BEAM_ORIGIN_LIFT, pp.y)
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

# ---------------------------------------------------------------- ability badges
# Show/hide the tower's ability badge row. Built as real world-space children so
# the camera moves and zooms them natively — no screen-space follow, no per-frame
# repositioning. Called by Main3D on (de)selection; safe to call repeatedly (it
# rebuilds, so it also refreshes after an upgrade changes the tower's flags).
func set_badges_visible(on: bool) -> void:
	_clear_badges()
	if on:
		_build_badges()

func _clear_badges() -> void:
	if _badge_anchor != null and is_instance_valid(_badge_anchor):
		_badge_anchor.queue_free()
	_badge_anchor = null
	_badge_mats.clear()
	_badge_info.clear()

func _build_badges() -> void:
	if data == null:
		return
	# One badge per ability flag that is true; skip any whose textures are missing
	# so the row stays gapless. Display order follows ABILITY_BADGES.
	var built: Array = []
	for entry in ABILITY_BADGES:
		var prop: String = entry["prop"]
		if not bool(data.get(prop)):
			continue
		var mat := _make_badge_material(entry)
		if mat != null:
			built.append({"mat": mat, "tip": str(entry.get("tip", "")), "file": str(entry["file"])})
	if built.is_empty():
		return
	# The anchor hangs off the tower ROOT (never scaled — only `_body` is), so it
	# never inherits the tower's height/width scale. Its world scale is fixed once;
	# the parallax shader only reads zoom_t each frame, so the badges never swim.
	_badge_anchor = Node3D.new()
	_badge_anchor.position = Vector3(0.0, 4.0, GameBoard3D.TOWER_RADIUS * 1.4)
	_badge_anchor.scale = Vector3.ONE * badge_world_scale
	add_child(_badge_anchor)
	var n := built.size()
	var spacing := BADGE_BASE_WORLD * 1.15
	var start_x := -spacing * float(n - 1) * 0.5
	for i in range(n):
		var b: Dictionary = built[i]
		var mat: ShaderMaterial = b["mat"]
		var mesh := QuadMesh.new()
		mesh.size = Vector2(BADGE_BASE_WORLD, BADGE_BASE_WORLD)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.position = Vector3(start_x + spacing * float(i), 0.0, 0.0)
		_badge_anchor.add_child(mi)
		_badge_mats.append(mat)
		_badge_info.append({"mi": mi, "tip": str(b["tip"]), "file": str(b["file"])})

# Build the parallax material for one icon (null if any of its 3 layers is absent).
func _make_badge_material(entry: Dictionary) -> ShaderMaterial:
	var base: String = entry["file"]
	var glyph := _badge_texture(base + "_glyph")
	var backplate := _badge_texture(base + "_backplate")
	var rim := _badge_texture(base + "_rim")
	if glyph == null or backplate == null or rim == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = _badge_shader()
	mat.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX   # draw on top of all other transparent geometry
	mat.set_shader_parameter("glyph_tex", glyph)
	mat.set_shader_parameter("backplate_tex", backplate)
	mat.set_shader_parameter("rim_tex", rim)
	mat.set_shader_parameter("focal_out", Vector2(float(entry["focal_out_x"]), float(entry["focal_out_y"])))
	mat.set_shader_parameter("focal_in", Vector2(float(entry["focal_in_x"]), float(entry["focal_in_y"])))
	mat.set_shader_parameter("reveal_out", float(entry["reveal_out"]))
	mat.set_shader_parameter("reveal_in", float(entry["reveal_in"]))
	mat.set_shader_parameter("reveal_rate", float(entry["reveal_rate"]))
	mat.set_shader_parameter("zoom_t", 0.0)
	mat.set_shader_parameter("focal_t", 0.0)
	return mat

# Drive the parallax: set zoom_t (0 far .. 1 near) on every live badge material.
# This is the only per-frame badge work and touches no transform, so nothing swims.
func _update_badge_zoom() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var d: float = cam.global_position.distance_to(_badge_anchor.global_position)
	var span: float = maxf(0.001, cam_dist_far - cam_dist_near)
	var t: float = clampf((cam_dist_far - d) / span, 0.0, 1.0)
	# Focal centers on a closer ramp (done by focal_center_dist) so it is settled
	# before the width finishes opening, per the reveal-distance targets.
	var fspan: float = maxf(0.001, cam_dist_far - focal_center_dist)
	var ft: float = clampf((cam_dist_far - d) / fspan, 0.0, 1.0)
	for m in _badge_mats:
		m.set_shader_parameter("zoom_t", t)
		m.set_shader_parameter("focal_t", ft)

# Which badge is under `screen_pos` (camera-projected): returns {tip, file} for the
# hovered badge, or {} if none. The badges are billboarded quads, so the world
# half-width along the camera's right axis projects to the on-screen hit radius.
func badge_tip_at(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	if _badge_anchor == null or camera == null:
		return {}
	var half: float = BADGE_BASE_WORLD * 0.5 * badge_world_scale
	var right: Vector3 = camera.global_transform.basis.x
	for info in _badge_info:
		var mi: MeshInstance3D = info["mi"]
		if not is_instance_valid(mi):
			continue
		var c: Vector3 = mi.global_position
		if camera.is_position_behind(c):
			continue
		var center: Vector2 = camera.unproject_position(c)
		var edge: Vector2 = camera.unproject_position(c + right * half)
		var r: float = maxf(8.0, center.distance_to(edge))
		if screen_pos.distance_to(center) <= r:
			return {"tip": str(info["tip"]), "file": str(info["file"])}
	return {}

# Shared parallax shader, compiled once.
static func _badge_shader() -> Shader:
	if _badge_shader_res != null:
		return _badge_shader_res
	var sh := Shader.new()
	sh.code = _BADGE_SHADER
	_badge_shader_res = sh
	return _badge_shader_res

# Cached texture lookup: art/<file>.png (then .webp). Misses (null) are cached too
# so a not-yet-added layer isn't re-probed.
static func _badge_texture(file: String) -> Texture2D:
	if _badge_tex.has(file):
		return _badge_tex[file]
	var tex: Texture2D = null
	for ext in [".png", ".webp"]:
		var path := "res://art/%s%s" % [file, ext]
		if ResourceLoader.exists(path):
			tex = load(path)
			break
	_badge_tex[file] = tex
	return tex
