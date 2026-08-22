class_name ImpactFlash3D
extends Node3D
## One-shot impact burst: a small unshaded low-poly octahedron in the hit
## colour that flares (scale up + emission spike) and dissolves in ~0.12s,
## then frees itself. Projectiles spawn it at the contact point as a sibling
## on the board so it outlives the shot that spawned it.

const LIFE := 0.12
const START_SCALE := 0.6
const END_SCALE := 2.4
const BURST_ENERGY := 3.0      # starting emission — well over bloom threshold for a free flash

static var _burst_mesh: ArrayMesh   # shared unit geometry (colour lives in the material)

# Shared material cache: the recipe below is deterministic per colour and never
# animated (the fade rides the per-instance `transparency` property), so every
# flash of a colour reuses one material.
static var _mat_cache := {}    # rgba32 -> StandardMaterial3D

var _mi: MeshInstance3D
var _t := 0.0
var _start_scale := START_SCALE
var _end_scale := END_SCALE

# Build, colour, parent and place a flash in one call. `size` scales the whole
# burst (1.0 for the standard hit; larger for e.g. the wall-blocked spark).
static func spawn(parent: Node, at: Vector3, color: Color, size := 1.0) -> void:
	var f := ImpactFlash3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = unit_octahedron()
	mi.material_override = _shared_mat(color)
	f._mi = mi
	f.add_child(mi)
	f._start_scale = START_SCALE * size
	f._end_scale = END_SCALE * size
	f.scale = Vector3.ONE * f._start_scale
	f.position = at
	parent.add_child(f)

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
	# The burst energy is baked in; the per-instance transparency fade carries
	# the whole dissolve (near-identical to the old parallel energy+alpha tween).
	mat.emission_energy_multiplier = BURST_ENERGY
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = mat
	return mat

func _ready() -> void:
	if _mi == null:             # only spawn() builds the mesh; bail if built by hand
		queue_free()

# Same envelope the old per-flash Tween ran (0.12s, cubic ease-out, scale up +
# fade out), as a tiny in-node _process — no Tween/material allocations per hit.
func _process(delta: float) -> void:
	if _mi == null:
		return
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	var u: float = _t / LIFE
	var k: float = 1.0 - pow(1.0 - u, 3.0)   # TRANS_CUBIC / EASE_OUT
	scale = Vector3.ONE * lerpf(_start_scale, _end_scale, k)
	_mi.transparency = k

# Shared unit octahedron (half-extent 1). Materials here are unshaded and
# cull-disabled, so winding is irrelevant and no normals are needed.
static func unit_octahedron() -> ArrayMesh:
	if _burst_mesh != null:
		return _burst_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var xp := Vector3.RIGHT; var xn := Vector3.LEFT
	var yp := Vector3.UP; var yn := Vector3.DOWN
	var zp := Vector3.BACK; var zn := Vector3.FORWARD
	for face in [[xp, yp, zp], [zp, yp, xn], [xn, yp, zn], [zn, yp, xp],
			[yn, zp, xp], [yn, xn, zp], [yn, zn, xn], [yn, xp, zn]]:
		for v in face:
			st.add_vertex(v)
	_burst_mesh = st.commit()
	return _burst_mesh
