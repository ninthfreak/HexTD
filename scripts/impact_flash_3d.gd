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

var _mat: StandardMaterial3D
var _end_scale := END_SCALE

# Build, colour, parent and place a flash in one call. `size` scales the whole
# burst (1.0 for the standard hit; larger for e.g. the wall-blocked spark).
static func spawn(parent: Node, at: Vector3, color: Color, size := 1.0) -> void:
	var f := ImpactFlash3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = unit_octahedron()
	# per-instance material (never shared/cached): the tween animates it
	f._mat = StandardMaterial3D.new()
	var bright: Color = color.lightened(0.3)
	f._mat.albedo_color = bright
	f._mat.emission_enabled = true
	f._mat.emission = bright
	f._mat.emission_energy_multiplier = BURST_ENERGY
	f._mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	f._mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	f._mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = f._mat
	f.add_child(mi)
	f.scale = Vector3.ONE * (START_SCALE * size)
	f.position = at
	f._end_scale = END_SCALE * size
	parent.add_child(f)

func _ready() -> void:
	if _mat == null:            # only spawn() sets the material; bail if built by hand
		queue_free()
		return
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "scale", Vector3.ONE * _end_scale, LIFE)
	tw.tween_property(_mat, "emission_energy_multiplier", 0.0, LIFE)
	tw.tween_property(_mat, "albedo_color:a", 0.0, LIFE)
	tw.finished.connect(queue_free)

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
