class_name FirewallRule3D
extends Node3D
## One deployed firewall rule: a filter sitting on a single route tile that
## damages traffic crossing it until its charges run out.
##
## A rule is CELL-KEYED, not a collider. Each frame it reads the board's existing
## per-frame enemy bucket for its own cell — the same index tower targeting and
## projectile hops already rebuild — so a rule costs one dictionary lookup per
## frame regardless of how many enemies are on the board.
##
## Charges are spent PER BODY, not per frame: `_hit` remembers what this rule has
## already filtered, so an enemy standing still on the tile is charged once, and
## a rule with 4 charges stops 4 distinct bodies.

var board = null                 # GameBoard3D (untyped: keeps the dependency edge loose)
var cell := Vector2i.ZERO
var damage := 30.0
var charges := 4
var pierces_ecc := false         # Bit Corruption, inherited from the deploying tower
var ecc_pierce := 0.0
var can_see_encrypted := false   # Cipher: a rule cannot filter what the tower cannot see
var applies_dos := false
var dos_freeze := 0.5
var dos_slow_time := 2.0
var dos_slow_factor := 0.5
var col := Color(0.45, 0.85, 1.0)

var _hit := {}                   # bodies this rule has already charged for
var _cell_set := {}              # {cell: true}, built once — avoids a per-frame allocation
var _max_charges := 4
var _mi: MeshInstance3D = null

const PLATE_Y := GameBoard3D.BUS_TOP + 0.35   # sits on the bus, under the enemies
const PLATE_H := 0.7

static var _mesh_cache: Mesh = null
static var _mat_cache := {}

func setup(b, c: Vector2i, dmg: float, ch: int, colour: Color) -> void:
	board = b
	cell = c
	damage = dmg
	charges = maxi(1, ch)
	_max_charges = charges
	col = colour
	_cell_set = {cell: true}
	position = Vector3(0.0, PLATE_Y, 0.0)
	_build_body()
	_refresh_fade()

func _build_body() -> void:
	if _mesh_cache == null:
		# A flat hexagonal plate, matching the tile it filters.
		var cyl := CylinderMesh.new()
		cyl.radial_segments = 6
		cyl.rings = 1
		cyl.top_radius = GameBoard3D.HEX_SIZE * 0.82
		cyl.bottom_radius = GameBoard3D.HEX_SIZE * 0.82
		cyl.height = PLATE_H
		_mesh_cache = cyl
	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh_cache
	_mi.rotation = Vector3(0.0, deg_to_rad(30.0), 0.0)   # align flats to the pointy-top grid
	add_child(_mi)

func _shared_mat(c: Color) -> StandardMaterial3D:
	var key := c.to_rgba32()
	var cached: StandardMaterial3D = _mat_cache.get(key)
	if cached != null:
		return cached
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c.r, c.g, c.b, 0.55)
	m.emission_enabled = true
	m.emission = c.lightened(0.25)
	m.emission_energy_multiplier = 1.6
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = m
	return m

# Spent charges read as a dimmer, thinner plate, so a nearly exhausted rule is
# visible as one before it vanishes.
func _refresh_fade() -> void:
	if _mi == null:
		return
	var k: float = float(charges) / float(maxi(_max_charges, 1))
	_mi.material_override = _shared_mat(col)
	_mi.transparency = clampf(1.0 - k, 0.0, 0.75)
	_mi.scale = Vector3(1.0, maxf(0.25, k), 1.0)

func _process(_delta: float) -> void:
	if board == null or charges <= 0:
		return
	for e in board.enemies_in_cell_set(_cell_set):
		if charges <= 0:
			break
		if not is_instance_valid(e) or not e._alive:
			continue
		if _hit.has(e):
			continue
		# A rule filters traffic it can see: Encrypted bodies pass untouched
		# unless the deploying tower had Cipher.
		if e.data.encrypted and not can_see_encrypted:
			continue
		_hit[e] = true
		charges -= 1
		e.take_damage(damage, pierces_ecc, false, ecc_pierce)
		if applies_dos and is_instance_valid(e) and e._alive:
			e.apply_dos(dos_freeze, dos_slow_time, dos_slow_factor)
		_refresh_fade()
	if charges <= 0:
		queue_free()
