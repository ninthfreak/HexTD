class_name ArcWave3D
extends Node3D
## An aimed, expanding wave front — the "arc" fire mode's delivery mechanism.
##
## Emitted from the tower toward its current target, the front sweeps outward at
## `speed` and dissipates at the tower's range edge. Every enemy the front crosses
## within range (and within the aimed wedge) is affected exactly once — there is no
## pierce cap; breadth is governed by range. The wave carries the tower's effects
## (damage + ability flags) through the normal effect path and knows nothing about
## any specific ability: it just applies whatever it was handed. Encrypted enemies
## are gated by `can_see_encrypted`, the same as targeting and radial spokes.
##
## Deliberately NOT pooled, unlike Projectile3D / RadialProjectile3D: the hit
## test depends on _half/_segs/_dirs, which _ready() derives from arc_angle and
## damage — and _ready() does not re-run when a pooled node re-enters the tree,
## so a reused wave would carry the previous wave's wedge. Pooling this needs
## that derivation moved to an explicit post-setup call on the caller's side.

var board                       # GameBoard3D (untyped)
var origin := Vector2.ZERO      # PLANE position the wave radiates from (the tower)
var aim := 0.0                  # centre direction, radians
var speed := 320.0
var damage := 0.0               # may be 0 — a pure-effect wave then deals no damage
var origin_cell := Vector2i.ZERO
var range_tiles := 3            # axial reach (already tower_reach-expanded by the caller)
var col := Color(1, 1, 1)
# Effects carried through, identical to what the radial spoke passes.
var pierces_ecc := false        # Bit Corruption
var execute_threshold := 0.0    # kill outright at/below this fraction of the target's max HP
var execute_no_decay := false   # an execute kill also suppresses the decay spawn
var applies_dos := false        # Denial of Service
var dos_freeze := 0.5           # per-tower DoS timing (used when applies_dos)
var dos_slow_time := 2.0
var dos_slow_factor := 0.5
var can_see_encrypted := false  # Cipher
var arc_angle := 70.0           # aimed wedge width in degrees (>=360 -> no angular gate)

const GLOW := 2.0               # shared ordnance glow (the laser beam stays brightest at 2.2)
const BAND := 6.0               # visual front thickness (world units)
const CREST_H := 4.0            # height of the vertical crest wall at the wavefront
const FROST := Color(0.5, 0.85, 1.0)   # matches enemy_3d.gd's DOS_FROST freeze cue
const HIT_PAD := 8.0            # slack added to the enemy radius when the front "crosses" it
# Conservative upper bound on any enemy's hit_radius, for the coarse band gate.
# The largest shape in data/enemies.json (great_icosahedron) has radius 40, so
# 48 leaves generous headroom; the exact per-enemy test below stays authoritative.
const MAX_R := 48.0

var _radius := 0.0
var _range_world := 0.0
var _hit := {}                  # enemy -> true (one application per enemy)
var _im: ImmediateMesh
var _mat: StandardMaterial3D
var _segs := 12                 # segments proportional to arc angle (set in _ready)
var _dashed := false            # zero-damage waves render dashed (set in _ready)
var _half := 0.0                # wedge half-angle, radians (set in _ready)
var _dirs := PackedVector2Array()   # unit direction per segment boundary (set in _ready)

func setup(origin_plane: Vector2, aim_dir: Vector2, dmg: float, spd: float,
		origin_cellv: Vector2i, tiles: int, c: Color, b) -> void:
	origin = origin_plane
	aim = aim_dir.angle()
	damage = dmg
	speed = spd
	origin_cell = origin_cellv
	range_tiles = tiles
	col = c
	board = b
	# World radius that comfortably covers every in-range cell; the per-enemy axial
	# check is the authoritative range gate, so a slightly generous radius is fine.
	_range_world = float(tiles) * b.HEX_SIZE * 2.0
	_build_visual()
	position = Vector3(origin_plane.x, GameBoard3D.ENEMY_Y, origin_plane.y)

# arc_angle / damage / applies_dos are assigned by the tower AFTER setup(), so
# every style choice that depends on them waits until the node enters the tree.
func _ready() -> void:
	# segments proportional to angular coverage: full rings get 64 (smooth
	# silhouette), narrow wedges drop to 8 rather than burning verts
	_segs = clampi(int(round(minf(arc_angle, 360.0) / 360.0 * 64.0)), 8, 64)
	# a pure-control wave (no damage) renders dashed — a field, not a blade
	_dashed = damage == 0.0
	# half = pi at 360° (clamped), so the angular gate then admits every
	# direction and the band closes into a full ring
	_half = deg_to_rad(minf(arc_angle, 360.0) * 0.5)
	# per-segment unit direction table: aim/_half/_segs are all fixed from here
	# on, so the cos/sin happen once instead of per segment per frame
	_dirs.resize(_segs + 1)
	for i in range(_segs + 1):
		var a: float = aim - _half + (2.0 * _half) * float(i) / float(_segs)
		_dirs[i] = Vector2(cos(a), sin(a))
	if applies_dos and _mat != null:
		# frost tint: share a hue with the enemies' DoS freeze cue so the
		# cause (this wave) and the effect (frozen enemy) read as one thing
		var frosted: Color = col.lightened(0.3).lerp(FROST, 0.5)
		_mat.albedo_color = frosted
		_mat.emission = frosted

func _build_visual() -> void:
	# per-instance material (never shared/cached): alpha + emission animate every frame
	_mat = StandardMaterial3D.new()
	var bright: Color = col.lightened(0.3)
	_mat.albedo_color = bright
	_mat.emission_enabled = true
	_mat.emission = bright
	_mat.emission_energy_multiplier = GLOW
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.vertex_color_use_as_albedo = true   # per-vertex alpha shapes the soft band edges
	_im = ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _im
	mi.material_override = _mat
	add_child(mi)

func _process(delta: float) -> void:
	_radius += speed * delta
	_check_hits()
	_update_visual()
	if _radius >= _range_world:
		queue_free()

# Apply the wave to any enemy the front has just reached this frame, within the
# aimed wedge and the tower's range, respecting the Cipher visibility gate.
func _check_hits() -> void:
	if board == null:
		return
	# worst-case reach this frame: front radius + pad + the largest enemy radius
	var band: float = _radius + HIT_PAD + MAX_R
	var band2: float = band * band
	# Deferred compaction makes board.enemies safe to iterate without a
	# duplicate(); capping at the pre-loop size keeps the old snapshot
	# semantics (split children appended mid-loop are not visited this frame).
	var count: int = board.enemies.size()
	for i in range(count):
		var e = board.enemies[i]   # untyped on purpose (Variant from array indexing)
		if not is_instance_valid(e) or _hit.has(e):
			continue
		var to_e: Vector2 = e.pp - origin
		# cheap gates first: squared-distance band, then the wedge; the exact
		# radius and the authoritative axial gate run only for the survivors
		if to_e.length_squared() > band2:
			continue
		if e.data.encrypted and not can_see_encrypted:
			continue
		var dist := to_e.length()
		if dist < 0.001:
			continue
		if absf(angle_difference(aim, to_e.angle())) > _half:
			continue
		var reach: float = _radius + HIT_PAD + e.hit_radius
		if dist > reach:
			continue
		# authoritative range gate: exact world_cell (e.cell can be a frame
		# stale), kept last so it only runs for confirmed candidates
		if HexUtils.axial_distance(origin_cell, board.world_cell(e.pp)) > range_tiles:
			continue
		_hit[e] = true
		e.take_damage(damage, pierces_ecc, false, execute_threshold, execute_no_decay)
		if applies_dos:
			e.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)

# Redraw the front as a curved band at the current radius, fading as it expands.
# Vertex alpha ramps inner (0) -> crest (1) -> outer (0) so the band has a soft
# leading/trailing falloff with a bright crest, and a short vertical wall rises
# from the crest so the front stays readable at shallow camera angles.
func _update_visual() -> void:
	if _im == null:
		return
	_im.clear_surfaces()
	var inner: float = maxf(0.0, _radius - BAND)
	var outer: float = _radius + BAND
	var lift := Vector3(0.0, CREST_H, 0.0)
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(_segs):
		if _dashed and i % 3 == 2:   # dashed: skip every 3rd segment
			continue
		# unit directions from the _ready table — only the radii change per frame
		var d0: Vector2 = _dirs[i]
		var d1: Vector2 = _dirs[i + 1]
		var c0 := Vector3(d0.x * _radius, 0.0, d0.y * _radius)   # crest
		var c1 := Vector3(d1.x * _radius, 0.0, d1.y * _radius)
		# flat band, two strips: inner (alpha 0) -> crest (1) -> outer (0)
		_emit_quad(Vector3(d0.x * inner, 0.0, d0.y * inner),
				Vector3(d1.x * inner, 0.0, d1.y * inner), c1, c0, 0.0, 0.0, 1.0, 1.0)
		_emit_quad(c0, c1, Vector3(d1.x * outer, 0.0, d1.y * outer),
				Vector3(d0.x * outer, 0.0, d0.y * outer), 1.0, 1.0, 0.0, 0.0)
		# vertical crest wall at the wavefront, fading to nothing at the top
		_emit_quad(c0, c1, c1 + lift, c0 + lift, 1.0, 1.0, 0.0, 0.0)
	_im.surface_end()
	var t: float = clampf(_radius / maxf(_range_world, 0.001), 0.0, 1.0)
	# eased fade: the front stays readable through most of its travel (~35%
	# opacity at t = 0.9 instead of 10% linear), then dies quickly at the edge
	var fade: float = pow(1.0 - t, 0.45)
	_mat.emission_energy_multiplier = GLOW * fade
	_mat.albedo_color.a = fade

# Quad as two triangles with per-vertex alpha (winding irrelevant: CULL_DISABLED).
func _emit_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		a0: float, a1: float, a2: float, a3: float) -> void:
	_emit_v(p0, a0); _emit_v(p1, a1); _emit_v(p2, a2)
	_emit_v(p0, a0); _emit_v(p2, a2); _emit_v(p3, a3)

func _emit_v(p: Vector3, alpha: float) -> void:
	_im.surface_set_color(Color(1, 1, 1, alpha))
	_im.surface_add_vertex(p)
