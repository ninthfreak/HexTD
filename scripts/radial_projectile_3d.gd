class_name RadialProjectile3D
extends Node3D
## 3D version of the straight pierce spoke fired by radial towers. Identical
## plane logic to the 2D RadialProjectile (one hit per enemy, dies at range
## edge / off-board / on a wall unless ignore_walls), with `pp` as the plane
## position and the 3D transform synced for display.

var board                       # GameBoard3D (untyped)
var dir := Vector2.RIGHT        # PLANE direction
var speed := 320.0
var damage := 10.0
var origin_cell := Vector2i.ZERO
var range_tiles := 3
var col := Color(1, 1, 1)
var ignore_walls := false       # false: walls stop the shot
var pierces_ecc := false        # tower had Bit Corruption
var ecc_pierce := 0.0           # partial native ECC pierce (bit_corruption is the full one)
var execute_threshold := 0.0    # kill outright at/below this fraction of the target's max HP
var execute_no_decay := false   # an execute kill also suppresses the decay spawn
var applies_dos := false        # tower had Denial of Service: freeze-then-slow each enemy hit
var dos_freeze := 0.5           # per-tower DoS timing (used when applies_dos)
var dos_slow_time := 2.0
var dos_slow_factor := 0.5
var can_see_encrypted := false  # tower had Cipher
var pp := Vector2.ZERO

const GLOW := 2.0              # shared ordnance glow (the laser beam stays brightest at 2.2)
const LENGTH := 7.0            # diamond length along the travel axis
const RADIUS := 2.2            # hex cross-section radius
const STRETCH := 2.8           # velocity stretch along the travel axis
const HIT_PAD := 8.0           # projectile-radius slack added to enemy radius
const WALL_SPARK := Color(0.75, 0.85, 1.0)   # cool-white "blocked by a wall" flash
const FADE_FRAC := 0.15        # dissolve over the last 15% of flight
# Conservative upper bound on any enemy's hit_radius, for the coarse hit gate.
# The largest shape in data/enemies.json (great_icosahedron) has radius 40, so
# 48 leaves generous headroom; the exact per-enemy test below stays authoritative.
const MAX_R := 48.0
const COARSE_R2 := (HIT_PAD + MAX_R) * (HIT_PAD + MAX_R)
const POOL_KEY := &"radial_spoke3d"   # private to this class: a take can only return a RadialProjectile3D

static var _spoke_mesh: ArrayMesh   # shared unit geometry (colour lives in the material)
static var _am_cached: Node = null  # AudioManager, resolved once (shared pattern)

var _safety := 0.0
var _safety_start := 0.0       # initial _safety, for the range-edge fade
var _hit := {}                 # enemy -> true (one hit per enemy)
var _mi: MeshInstance3D
var _cell := Vector2i.ZERO     # cached world_cell(pp) — wall/range checks re-run on change
var _cell_known := false
# Board that handed this instance out (untyped: pool_take/pool_put are not Node
# methods, so a typed reference would not compile). Only obtain() sets it; an
# instance built with new() keeps the plain queue_free lifetime.
var _pool_board
var _dead := false             # released already — makes a double release impossible

# Pooled construction: a parked spoke or a fresh one, out of the tree, with every
# per-life field reset. The caller then runs setup() and board.add_projectile().
static func obtain(b) -> RadialProjectile3D:
	var p: RadialProjectile3D = null
	if b != null:
		var n: Node = b.pool_take(POOL_KEY)
		if n is RadialProjectile3D:
			p = n
		elif n != null:
			n.queue_free()   # wrong class under our key: drop it rather than orphan it
	if p == null:
		p = RadialProjectile3D.new()
	p._pool_board = b
	p._reset()
	return p

# Full per-life reset. EVERY field a spoke writes belongs here — a pooled instance
# carries its predecessor's state otherwise. `_hit` is the dangerous one: a stale
# hit set makes a reused spoke silently refuse to damage those enemies. Add new
# fields to this list when adding them above. Covered: board, dir, speed, damage,
# origin_cell, range_tiles, col, ignore_walls, pierces_ecc, ecc_pierce,
# execute_threshold, execute_no_decay, applies_dos,
# dos_freeze, dos_slow_time, dos_slow_factor, can_see_encrypted, pp, _safety,
# _safety_start, _hit, _cell, _cell_known, _dead, node transform / visibility /
# processing, mesh rotation / scale / transparency / visibility.
# `_mi.material_override` is (re)assigned from `col` by setup().
func _reset() -> void:
	board = null
	dir = Vector2.RIGHT
	speed = 320.0
	damage = 10.0
	origin_cell = Vector2i.ZERO
	range_tiles = 3
	col = Color(1, 1, 1)
	ignore_walls = false
	pierces_ecc = false
	ecc_pierce = 0.0
	execute_threshold = 0.0
	execute_no_decay = false
	applies_dos = false
	dos_freeze = 0.5
	dos_slow_time = 2.0
	dos_slow_factor = 0.5
	can_see_encrypted = false
	pp = Vector2.ZERO
	_safety = 0.0
	_safety_start = 0.0
	_hit.clear()
	_cell = Vector2i.ZERO
	_cell_known = false
	_dead = false
	transform = Transform3D.IDENTITY
	visible = true
	set_process(true)
	_ensure_mesh()
	_mi.rotation = Vector3.ZERO
	_mi.scale = Vector3(STRETCH, 1.0, 1.0)   # velocity stretch
	_mi.transparency = 0.0
	_mi.visible = true

func setup(start_plane: Vector2, direction: Vector2, dmg: float, spd: float,
		origin: Vector2i, tiles: int, c: Color, b) -> void:
	pp = start_plane
	dir = direction.normalized()
	damage = dmg
	speed = spd
	origin_cell = origin
	range_tiles = tiles
	col = c
	board = b
	_safety = float(tiles + 1) * 2.0 * b.HEX_SIZE
	_safety_start = _safety
	_ensure_mesh()
	# shared per-colour material (Projectile3D's cache — identical recipe); the
	# range-edge fade is driven per-instance via `_mi.transparency`, so nothing
	# here is ever animated on the material itself
	_mi.material_override = Projectile3D._shared_mat(col)
	# long axis along travel (plane +x -> 3D +x, plane +y -> 3D +z, so yaw =
	# -plane angle); dir never changes, so this is set once per shot
	_mi.rotation.y = -dir.angle()
	_mi.transparency = 0.0
	_sync_transform()

# One-time mesh child: a pooled instance keeps the one it built on its first
# life. Per-shot mesh state belongs in _reset() / setup(), not here.
func _ensure_mesh() -> void:
	if _mi != null and is_instance_valid(_mi):
		return
	# elongated hexagonal diamond aligned with the travel direction — the shape
	# makes the pierce line legible, unlike the old featureless sphere
	var mi := MeshInstance3D.new()
	mi.mesh = _diamond_mesh()
	mi.scale = Vector3(STRETCH, 1.0, 1.0)   # velocity stretch
	_mi = mi
	add_child(mi)

# Shared unit geometry: a faceted hexagonal bipyramid — nose/tail apexes on ±x,
# hex ring at x = 0. Materials here are unshaded and cull-disabled, so winding
# is irrelevant and no normals are needed.
static func _diamond_mesh() -> ArrayMesh:
	if _spoke_mesh != null:
		return _spoke_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nose := Vector3(LENGTH * 0.5, 0, 0)
	var tail := Vector3(-LENGTH * 0.5, 0, 0)
	for i in range(6):
		var a0 := TAU * float(i) / 6.0
		var a1 := TAU * float(i + 1) / 6.0
		var r0 := Vector3(0, cos(a0) * RADIUS, sin(a0) * RADIUS)
		var r1 := Vector3(0, cos(a1) * RADIUS, sin(a1) * RADIUS)
		st.add_vertex(nose); st.add_vertex(r0); st.add_vertex(r1)
		st.add_vertex(tail); st.add_vertex(r1); st.add_vertex(r0)
	_spoke_mesh = st.commit()
	return _spoke_mesh

func _sync_transform() -> void:
	# cruise at the enemies' hover height so shots meet them
	position = Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y)

func _process(delta: float) -> void:
	var step := speed * delta
	pp += dir * step
	_safety -= step
	if board != null:
		# one world_cell per frame; the wall / off-board / range checks depend
		# only on the cell, so they re-run only when the cell changes (a cell
		# that survived them last frame survives them now — walls and the map
		# are static, origin_cell/range_tiles fixed)
		var here: Vector2i = board.world_cell(pp)
		if not _cell_known or here != _cell:
			_cell = here
			_cell_known = true
			if not ignore_walls and board.blocking_set.has(here):
				# a wall absorbed the shot — spark in cool white so the rule
				# (walls stop spokes) is actually visible
				var parent := get_parent()
				if parent != null:
					ImpactFlash3D.spawn(parent, Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y), WALL_SPARK, 1.25)
				_release()
				return
			if HexUtils.axial_distance(origin_cell, here) > range_tiles \
					or not board.has_cell(here):
				_release()
				return
	_check_hits()
	if _safety <= 0.0:
		_release()
	else:
		# range-edge death fades instead of popping: dissolve the last 15% of
		# flight (per-instance transparency; the material stays shared, and the
		# write only happens once inside the fade window)
		var alpha := clampf(_safety / maxf(_safety_start * FADE_FRAC, 0.001), 0.0, 1.0)
		if alpha < 1.0:
			_mi.transparency = 1.0 - alpha
		_sync_transform()

func _audio() -> Node:
	if _am_cached == null or not is_instance_valid(_am_cached):
		_am_cached = get_node_or_null("/root/AudioManager")
	return _am_cached

func _check_hits() -> void:
	if board == null:
		return
	# Deferred compaction makes board.enemies safe to iterate without a
	# duplicate(); capping at the pre-loop size keeps the old snapshot
	# semantics (split children appended mid-loop are not visited this frame).
	var count: int = board.enemies.size()
	var played := false
	for i in range(count):
		var e = board.enemies[i]   # untyped on purpose (Variant from array indexing)
		if not is_instance_valid(e) or _hit.has(e):
			continue
		# cheap coarse gate first: squared distance against the worst-case hit
		# radius rejects almost every enemy without touching its data
		if pp.distance_squared_to(e.pp) > COARSE_R2:
			continue
		if e.data.encrypted and not can_see_encrypted:
			continue
		var r: float = HIT_PAD + e.hit_radius
		if pp.distance_to(e.pp) <= r:
			_hit[e] = true
			var contact: Vector2 = e.pp
			e.take_damage(damage, pierces_ecc, false, ecc_pierce, execute_threshold, execute_no_decay)
			if applies_dos:
				e.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)
			var parent := get_parent()
			if parent != null:
				ImpactFlash3D.spawn(parent, Vector3(contact.x, GameBoard3D.ENEMY_Y, contact.y), col)
			# at most one hit sfx per spoke per frame — a burst through a pack
			# stacked N identical samples into one loud click
			if not played:
				played = true
				var am: Node = _audio()
				if am:
					am.play_sfx("projectile_hit")

# Death path. Parking instead of freeing is only safe because nothing outlives a
# spoke that references it: the firing tower drops its reference on the frame it
# fires, the board keeps no projectile list (add_projectile is a bare add_child),
# and no signal is ever connected to a spoke. `_hit` is cleared here as well as in
# _reset() so a parked spoke pins none of the enemies it hit. After pool_put the
# node is out of the tree and not processing — callers must return immediately.
func _release() -> void:
	if _dead:
		return
	_dead = true
	_hit.clear()
	board = null
	var b = _pool_board
	_pool_board = null
	if b != null and is_instance_valid(b):
		b.pool_put(POOL_KEY, self)
	else:
		queue_free()
