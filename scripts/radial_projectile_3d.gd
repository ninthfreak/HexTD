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

static var _spoke_mesh: ArrayMesh   # shared unit geometry (colour lives in the material)

var _safety := 0.0
var _safety_start := 0.0       # initial _safety, for the range-edge fade
var _hit := {}                 # enemy -> true (one hit per enemy)
var _mat: StandardMaterial3D

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
	_build_mesh()
	_sync_transform()

func _build_mesh() -> void:
	# elongated hexagonal diamond aligned with the travel direction — the shape
	# makes the pierce line legible, unlike the old featureless sphere
	var mi := MeshInstance3D.new()
	mi.mesh = _diamond_mesh()
	# per-instance material (never the shared cache): the range-edge fade
	# animates this spoke's alpha
	_mat = StandardMaterial3D.new()
	var bright: Color = col.lightened(0.3)
	_mat.albedo_color = bright
	_mat.emission_enabled = true
	_mat.emission = bright
	_mat.emission_energy_multiplier = GLOW
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = _mat
	# long axis along travel (plane +x -> 3D +x, plane +y -> 3D +z, so yaw =
	# -plane angle); dir never changes, so this is set once
	mi.rotation.y = -dir.angle()
	mi.scale = Vector3(STRETCH, 1.0, 1.0)   # velocity stretch
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
		var here: Vector2i = board.world_cell(pp)
		if not ignore_walls and board.blocking_set.has(here):
			# a wall absorbed the shot — spark in cool white so the rule
			# (walls stop spokes) is actually visible
			var parent := get_parent()
			if parent != null:
				ImpactFlash3D.spawn(parent, Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y), WALL_SPARK, 1.25)
			queue_free()
			return
		if HexUtils.axial_distance(origin_cell, here) > range_tiles \
				or not board.has_cell(here):
			queue_free()
			return
	_check_hits()
	if _safety <= 0.0:
		queue_free()
	else:
		# range-edge death fades instead of popping: dissolve the last 15% of flight
		_mat.albedo_color.a = clampf(_safety / maxf(_safety_start * FADE_FRAC, 0.001), 0.0, 1.0)
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
			var contact: Vector2 = e.pp
			e.take_damage(damage, pierces_ecc)
			if applies_dos:
				e.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)
			var parent := get_parent()
			if parent != null:
				ImpactFlash3D.spawn(parent, Vector3(contact.x, GameBoard3D.ENEMY_Y, contact.y), col)
			if am:
				am.play_sfx("projectile_hit")
