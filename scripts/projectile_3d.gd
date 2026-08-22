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
var pierces_ecc := false
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

# Shared material cache: the recipe below is deterministic per colour and never
# animated per instance, so every shot of a colour reuses one material.
static var _mat_cache := {}    # rgba32 -> StandardMaterial3D
static var _am_cached: Node = null  # AudioManager, resolved once (shared pattern)

var _mesh: MeshInstance3D
var _roll := 0.0

func setup(start_plane: Vector2, t, dmg: float, spd: float, c: Color, pierce := false, overflow := false, dos := false) -> void:
	pp = start_plane
	target = t
	damage = dmg
	speed = spd
	col = c
	pierces_ecc = pierce
	buffer_overflow = overflow
	applies_dos = dos
	_build_mesh()
	_sync_transform()

func _build_mesh() -> void:
	# a small faceted octahedron "bit", elongated along its travel axis — matches
	# the hand-built low-poly tower bodies instead of a smooth sphere
	_mesh = MeshInstance3D.new()
	_mesh.mesh = ImpactFlash3D.unit_octahedron()
	_mesh.material_override = _shared_mat(col)
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
		queue_free()
		return
	var to_target: Vector2 = target.pp - pp
	var dist := to_target.length()
	var step := speed * delta
	if step >= dist:
		var contact: Vector2 = target.pp
		target.take_damage(damage, pierces_ecc, buffer_overflow)
		if applies_dos and is_instance_valid(target):
			target.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)
		var parent := get_parent()
		if parent != null:
			ImpactFlash3D.spawn(parent, Vector3(contact.x, GameBoard3D.ENEMY_Y, contact.y), col)
		var am: Node = _audio()
		if am:
			am.play_sfx("projectile_hit")
		queue_free()
	else:
		pp += to_target / dist * step
		# roll the bit around its long axis and keep that axis pointed at the
		# target (plane +x -> 3D +x, plane +y -> 3D +z, so yaw = -plane angle)
		_roll += SPIN * delta
		_mesh.rotation = Vector3(_roll, -to_target.angle(), 0.0)
		_sync_transform()
