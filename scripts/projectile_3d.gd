class_name Projectile3D
extends Node3D
## 3D homing shot. The flight + hit logic mirrors the 2D Projectile exactly,
## just on the (x, y) plane stored in `pp` (the entity's plane position) so it
## stays compatible with the board's hex math. The 3D transform is synced from
## `pp` each frame for display only.

var target                # Enemy3D (untyped to keep dependency edges loose)
var speed: float
var damage: float
var col: Color
var board = null               # GameBoard3D, for hop target lookup (untyped: loose dependency edge)
var hops := 0                  # remaining forwards after the current hit
var hop_range := 2             # how far, in tiles, to look for the next hop
var hop_falloff := 0.6         # damage multiplier applied at each hop
var can_see_encrypted := false # Cipher: a hop must not pick a target the tower cannot see
var _hit := {}                 # enemies this shot already struck, so it cannot forward back onto one
var pierces_ecc := false
var ecc_pierce := 0.0          # partial native ECC pierce (bit_corruption is the full one)
var execute_threshold := 0.0   # kill outright at/below this fraction of the target's max HP
var execute_no_decay := false  # an execute kill also suppresses the decay spawn
var buffer_overflow := false   # tower had Buffer Overflow: surplus spills into decay children
var applies_dos := false       # tower had Denial of Service: freeze-then-slow the enemy on hit
var dos_freeze := 0.5          # per-tower DoS timing (used when applies_dos)
var dos_slow_time := 2.0
var dos_slow_factor := 0.5
var pp := Vector2.ZERO

const GLOW := 2.0              # shared ordnance glow (the laser beam stays brightest at 2.2)
const BIT_HALF := 1.6          # octahedron "bit" half-extent
const STRETCH := 2.8           # velocity stretch along the travel axis
const SPIN := 8.0              # roll speed around the travel axis, rad/s
const POOL_KEY := &"projectile3d"   # private to this class: a take can only return a Projectile3D

# Shared material cache: the recipe below is deterministic per colour and never
# animated per instance, so every shot of a colour reuses one material.
static var _mat_cache := {}    # rgba32 -> StandardMaterial3D
static var _am_cached: Node = null  # AudioManager, resolved once (shared pattern)

var _mesh: MeshInstance3D
var _roll := 0.0
# Board that handed this instance out (untyped: pool_take/pool_put are not Node
# methods, so a typed reference would not compile). Only obtain() sets it; an
# instance built with new() keeps the plain queue_free lifetime.
var _pool_board
var _dead := false             # released already — makes a double release impossible

# Pooled construction: a parked shot or a fresh one, out of the tree, with every
# per-life field reset. The caller then runs setup() and board.add_projectile().
static func obtain(b) -> Projectile3D:
	var p: Projectile3D = null
	if b != null:
		var n: Node = b.pool_take(POOL_KEY)
		if n is Projectile3D:
			p = n
		elif n != null:
			n.queue_free()   # wrong class under our key: drop it rather than orphan it
	if p == null:
		p = Projectile3D.new()
	p._pool_board = b
	p._reset()
	return p

# Full per-life reset. EVERY field a shot writes belongs here — a pooled instance
# carries its predecessor's state otherwise, and a stale target or damage is a
# gameplay bug, not a cosmetic one. Add new fields to this list when adding them
# above. Covered: target, speed, damage, col, board, hops, hop_range,
# hop_falloff, can_see_encrypted, _hit, pierces_ecc, ecc_pierce,
# execute_threshold, execute_no_decay, buffer_overflow,
# applies_dos, dos_freeze, dos_slow_time, dos_slow_factor, pp, _roll, _dead,
# node transform / visibility / processing, mesh rotation / scale / transparency /
# visibility. `_mesh.material_override` is (re)assigned from `col` by setup().
func _reset() -> void:
	target = null
	speed = 0.0
	damage = 0.0
	col = Color(1, 1, 1)
	board = null
	hops = 0
	hop_range = 2
	hop_falloff = 0.6
	can_see_encrypted = false
	# _hit is the dangerous one: a stale set makes a reused shot silently refuse to
	# forward onto enemies it never actually touched.
	_hit.clear()
	pierces_ecc = false
	ecc_pierce = 0.0
	execute_threshold = 0.0
	execute_no_decay = false
	buffer_overflow = false
	applies_dos = false
	dos_freeze = 0.5
	dos_slow_time = 2.0
	dos_slow_factor = 0.5
	pp = Vector2.ZERO
	_roll = 0.0
	_dead = false
	transform = Transform3D.IDENTITY
	visible = true
	set_process(true)
	_ensure_mesh()
	_mesh.rotation = Vector3.ZERO
	_mesh.scale = Vector3(BIT_HALF * STRETCH, BIT_HALF, BIT_HALF)   # velocity stretch on x
	_mesh.transparency = 0.0
	_mesh.visible = true

func setup(start_plane: Vector2, t, dmg: float, spd: float, c: Color, pierce := false, overflow := false, dos := false) -> void:
	pp = start_plane
	target = t
	damage = dmg
	speed = spd
	col = c
	pierces_ecc = pierce
	buffer_overflow = overflow
	applies_dos = dos
	if t != null:
		_hit[t] = true
	_ensure_mesh()
	_mesh.material_override = _shared_mat(col)
	# Aim on the spawn frame: _process would otherwise be the first thing to set
	# the yaw, so a reused instance could render one frame at its last shot's angle.
	if t != null and is_instance_valid(t):
		var to_t: Vector2 = t.pp - pp
		if to_t.length_squared() > 0.0:
			_mesh.rotation = Vector3(_roll, -to_t.angle(), 0.0)
	_sync_transform()

## Forward this shot to its next target. Returns false when it has no hops left,
## no board to search, or nothing eligible nearby — the caller then releases it.
## The search is a cell-set lookup on the board's existing per-frame enemy index,
## not a scan of every enemy, so a shot with many hops stays cheap.
func _forward_from(contact: Vector2) -> bool:
	if hops <= 0 or board == null:
		return false
	var origin: Vector2i = board.world_cell(contact)
	var cands: Array = board.enemies_in_cell_set(board.range_cell_set(origin, hop_range))
	var best = null
	var best_d := INF
	for e in cands:
		if not is_instance_valid(e) or not e._alive:
			continue
		if _hit.has(e):
			continue
		# A hop picks its own target, so it has to honour Cipher itself — the
		# tower's acquisition gate never sees this choice.
		if e.data.encrypted and not can_see_encrypted:
			continue
		var d: float = contact.distance_squared_to(e.pp)
		if d < best_d:
			best_d = d
			best = e
	if best == null:
		return false
	target = best
	_hit[best] = true
	damage *= hop_falloff
	hops -= 1
	return true

# One-time mesh child: a pooled instance keeps the one it built on its first
# life. Per-shot mesh state belongs in _reset() / setup(), not here.
func _ensure_mesh() -> void:
	if _mesh != null and is_instance_valid(_mesh):
		return
	# a small faceted octahedron "bit", elongated along its travel axis — matches
	# the hand-built low-poly tower bodies instead of a smooth sphere
	_mesh = MeshInstance3D.new()
	_mesh.mesh = ImpactFlash3D.unit_octahedron()
	_mesh.scale = Vector3(BIT_HALF * STRETCH, BIT_HALF, BIT_HALF)   # velocity stretch on x
	add_child(_mesh)

static func _shared_mat(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	var cached: StandardMaterial3D = _mat_cache.get(key)
	if cached != null:
		return cached
	var mat := StandardMaterial3D.new()
	var bright: Color = c.lightened(0.3)
	mat.albedo_color = bright
	mat.emission_enabled = true
	mat.emission = bright
	# Push emission > 1 so the environment glow blooms the shot, matching the 2D look.
	mat.emission_energy_multiplier = GLOW
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = mat
	return mat

func _sync_transform() -> void:
	# cruise at the enemies' hover height so shots meet them
	position = Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y)

func _audio() -> Node:
	if _am_cached == null or not is_instance_valid(_am_cached):
		_am_cached = get_node_or_null("/root/AudioManager")
	return _am_cached

# Target.pp is the enemy's plane position; we move pp toward it and resync the
# 3D transform. On contact we deal damage, flash at the contact point, and
# self-destruct.
func _process(delta: float) -> void:
	if not is_instance_valid(target):
		_release()
		return
	var to_target: Vector2 = target.pp - pp
	var dist := to_target.length()
	var step := speed * delta
	if step >= dist:
		var contact: Vector2 = target.pp
		target.take_damage(damage, pierces_ecc, buffer_overflow, ecc_pierce, execute_threshold, execute_no_decay)
		if applies_dos and is_instance_valid(target):
			target.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)
		var parent := get_parent()
		if parent != null:
			ImpactFlash3D.spawn(parent, Vector3(contact.x, GameBoard3D.ENEMY_Y, contact.y), col)
		var am: Node = _audio()
		if am:
			am.play_sfx("projectile_hit")
		if not _forward_from(contact):
			_release()
	else:
		pp += to_target / dist * step
		# roll the bit around its long axis and keep that axis pointed at the
		# target (plane +x -> 3D +x, plane +y -> 3D +z, so yaw = -plane angle)
		_roll += SPIN * delta
		_mesh.rotation = Vector3(_roll, -to_target.angle(), 0.0)
		_sync_transform()

# Death path. Parking instead of freeing is only safe because nothing outlives a
# shot that references it: the firing tower drops its reference on the frame it
# fires, the board keeps no projectile list (add_projectile is a bare add_child),
# and no signal is ever connected to a shot. `target` is dropped here so a parked
# shot cannot pin a dead enemy. After pool_put the node is out of the tree and
# not processing — callers must return immediately.
func _release() -> void:
	if _dead:
		return
	_dead = true
	target = null
	var b = _pool_board
	_pool_board = null
	if b != null and is_instance_valid(b):
		b.pool_put(POOL_KEY, self)
	else:
		queue_free()
