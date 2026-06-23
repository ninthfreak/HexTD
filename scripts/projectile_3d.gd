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
var pp := Vector2.ZERO

const GLOW := 1.7              # over-bright factor that the env's bloom picks up
const FLY_HEIGHT := 4.0        # world-Y at which projectiles cruise above the board
const SPHERE_RADIUS := 1.4

func setup(start_plane: Vector2, t, dmg: float, spd: float, c: Color, pierce := false) -> void:
	pp = start_plane
	target = t
	damage = dmg
	speed = spd
	col = c
	pierces_ecc = pierce
	_build_mesh()
	_sync_transform()

func _build_mesh() -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = SPHERE_RADIUS
	sm.height = SPHERE_RADIUS * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	var bright: Color = col.lightened(0.3)
	mat.albedo_color = bright
	mat.emission_enabled = true
	mat.emission = bright
	# Push emission > 1 so the environment glow blooms the shot, matching the 2D look.
	mat.emission_energy_multiplier = GLOW
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)

func _sync_transform() -> void:
	position = Vector3(pp.x, FLY_HEIGHT, pp.y)

# Target.pp is the enemy's plane position; we move pp toward it and resync the
# 3D transform. On contact we deal damage and self-destruct.
func _process(delta: float) -> void:
	if not is_instance_valid(target):
		queue_free()
		return
	var to_target: Vector2 = target.pp - pp
	var dist := to_target.length()
	var step := speed * delta
	if step >= dist:
		target.take_damage(damage, pierces_ecc)
		var am = get_node_or_null("/root/AudioManager")
		if am:
			am.play_sfx("projectile_hit")
		queue_free()
	else:
		pp += to_target / dist * step
		_sync_transform()
