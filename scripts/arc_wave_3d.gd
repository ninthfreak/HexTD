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
var applies_dos := false        # Denial of Service
var dos_freeze := 0.5           # per-tower DoS timing (used when applies_dos)
var dos_slow_time := 2.0
var dos_slow_factor := 0.5
var can_see_encrypted := false  # Cipher
var arc_angle := 70.0           # aimed wedge width in degrees (>=360 -> no angular gate)

const GLOW := 1.6
const BAND := 6.0               # visual front thickness (world units)
const HIT_PAD := 8.0            # slack added to the enemy radius when the front "crosses" it

var _radius := 0.0
var _range_world := 0.0
var _hit := {}                  # enemy -> true (one application per enemy)
var _im: ImmediateMesh
var _mat: StandardMaterial3D

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

func _build_visual() -> void:
	_mat = StandardMaterial3D.new()
	var bright: Color = col.lightened(0.3)
	_mat.albedo_color = bright
	_mat.emission_enabled = true
	_mat.emission = bright
	_mat.emission_energy_multiplier = GLOW
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
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
	for e in board.enemies.duplicate():
		if not is_instance_valid(e) or _hit.has(e):
			continue
		if e.data.encrypted and not can_see_encrypted:
			continue
		var to_e: Vector2 = e.pp - origin
		var dist := to_e.length()
		if dist < 0.001:
			continue
		# half = pi at 360° (clamped), so the gate then admits every direction.
		var half := deg_to_rad(minf(arc_angle, 360.0) * 0.5)
		if absf(angle_difference(aim, to_e.angle())) > half:
			continue
		if HexUtils.axial_distance(origin_cell, board.world_cell(e.pp)) > range_tiles:
			continue
		var reach := _radius + HIT_PAD
		if e.has_method("_radius_estimate"):
			reach += e._radius_estimate()
		if dist > reach:
			continue
		_hit[e] = true
		e.take_damage(damage, pierces_ecc)
		if applies_dos:
			e.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)

# Redraw the front as a curved band at the current radius, fading as it expands.
func _update_visual() -> void:
	if _im == null:
		return
	_im.clear_surfaces()
	var inner: float = maxf(0.0, _radius - BAND)
	var outer: float = _radius + BAND
	var half := deg_to_rad(minf(arc_angle, 360.0) * 0.5)   # pi at 360° -> a full ring
	var segs := 28
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in range(segs + 1):
		var a: float = aim - half + (2.0 * half) * float(i) / float(segs)
		var d := Vector2(cos(a), sin(a))
		_im.surface_add_vertex(Vector3(d.x * inner, 0.0, d.y * inner))
		_im.surface_add_vertex(Vector3(d.x * outer, 0.0, d.y * outer))
	_im.surface_end()
	var t: float = clampf(_radius / maxf(_range_world, 0.001), 0.0, 1.0)
	_mat.emission_energy_multiplier = GLOW * (1.0 - t)
	_mat.albedo_color.a = 1.0 - t
