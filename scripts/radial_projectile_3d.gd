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
var applies_dos := false        # tower had Denial of Service: freeze-then-slow each enemy hit
var can_see_encrypted := false  # tower had Cipher
var pp := Vector2.ZERO

const GLOW := 1.7
const SPHERE_RADIUS := 2.4
const HIT_PAD := 8.0           # projectile-radius slack added to enemy radius

var _safety := 0.0
var _hit := {}                 # enemy -> true (one hit per enemy)

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
	mat.emission_energy_multiplier = GLOW
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)

func _sync_transform() -> void:
	# cruise at the enemies' hover height so shots meet them
	position = Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y)

func _process(delta: float) -> void:
	var step := speed * delta
	pp += dir * step
	_safety -= step
	if board != null:
		var here: Vector2i = board.world_cell(pp)
		if HexUtils.axial_distance(origin_cell, here) > range_tiles \
				or not board.has_cell(here) \
				or (not ignore_walls and board.blocking_set.has(here)):
			queue_free()
			return
	_check_hits()
	if _safety <= 0.0:
		queue_free()
	else:
		_sync_transform()

func _check_hits() -> void:
	if board == null:
		return
	var am = get_node_or_null("/root/AudioManager")
	for e in board.enemies.duplicate():
		if not is_instance_valid(e) or _hit.has(e):
			continue
		if e.data.encrypted and not can_see_encrypted:
			continue
		var r := HIT_PAD
		if e.has_method("_radius_estimate"):
			r += e._radius_estimate()
		if pp.distance_to(e.pp) <= r:
			_hit[e] = true
			e.take_damage(damage, pierces_ecc)
			if applies_dos:
				e.apply_dos()
			if am:
				am.play_sfx("projectile_hit")
