class_name Enemy3D
extends Node3D
## 3D enemy. All path / damage / split logic is ported verbatim from the 2D
## Enemy, operating on `pp` (plane position, Vector2). The 3D transform is
## synced from `pp` for display only. Body is an extruded prism rotated to face
## travel; the health bar above it is a billboarded Sprite3D so it always
## reads upright regardless of body yaw or camera tilt.

signal bounty(amount: int)
signal reached_goal()
signal split(lesser, placements)

const TURN_RATE := 9.0
const ECC_RESIST := 0.9
const GLOW_HDR_BOOST := 0.9
const BODY_HEIGHT := 4.0

# Platonic solids + their dual compounds, used as true-3D enemy bodies (the
# "faceted + edge glow" look). Sizes are driven by EnemyData.radius (the body's
# circumradius). Vertex tables below are unit-ish; geometry is normalised to a
# circumradius of 1 then scaled by radius. Faces/edges are derived at runtime
# (brute-force convex hull + min-distance edges) so no per-solid face table is
# hand-maintained — and it extends to the compounds member-by-member.
const PHI := 1.618033988749895
const SOLIDS := ["tetrahedron", "cube", "octahedron", "dodecahedron", "icosahedron",
	"stella_octangula", "cube_octahedron", "dodeca_icosahedron"]
const SOLID_VERTS := {
	"tetrahedron": [Vector3(1,1,1), Vector3(1,-1,-1), Vector3(-1,1,-1), Vector3(-1,-1,1)],
	"cube": [Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,1,-1), Vector3(-1,1,-1),
		Vector3(-1,-1,1), Vector3(1,-1,1), Vector3(1,1,1), Vector3(-1,1,1)],
	"octahedron": [Vector3(1,0,0), Vector3(-1,0,0), Vector3(0,1,0), Vector3(0,-1,0),
		Vector3(0,0,1), Vector3(0,0,-1)],
	"dodecahedron": [
		Vector3(-1,-1,-1), Vector3(-1,-1,1), Vector3(-1,1,-1), Vector3(-1,1,1),
		Vector3(1,-1,-1), Vector3(1,-1,1), Vector3(1,1,-1), Vector3(1,1,1),
		Vector3(0,-1.0/PHI,-PHI), Vector3(0,-1.0/PHI,PHI), Vector3(0,1.0/PHI,-PHI), Vector3(0,1.0/PHI,PHI),
		Vector3(-1.0/PHI,-PHI,0), Vector3(-1.0/PHI,PHI,0), Vector3(1.0/PHI,-PHI,0), Vector3(1.0/PHI,PHI,0),
		Vector3(-PHI,0,-1.0/PHI), Vector3(-PHI,0,1.0/PHI), Vector3(PHI,0,-1.0/PHI), Vector3(PHI,0,1.0/PHI)],
	"icosahedron": [
		Vector3(0,-1,-PHI), Vector3(0,-1,PHI), Vector3(0,1,-PHI), Vector3(0,1,PHI),
		Vector3(-1,-PHI,0), Vector3(-1,PHI,0), Vector3(1,-PHI,0), Vector3(1,PHI,0),
		Vector3(-PHI,0,-1), Vector3(-PHI,0,1), Vector3(PHI,0,-1), Vector3(PHI,0,1)],
}
const BAR_PIX_W := 40
const BAR_PIX_H := 6
const BAR_PIXEL_SIZE := 0.18    # world units per bar texel
const BAR_HEIGHT_PAD := 3.0     # bar sits above the body's top by this many units

var data: EnemyData
var path_points: PackedVector2Array
var health: float
var heading := 0.0             # radians; 0 = facing +X in plane space
var pp := Vector2.ZERO
var _index := 0
var _alive := true
var _body_root: Node3D         # rotates with heading (body only — bar stays upright)
var _body: MeshInstance3D      # the body faces (prism for legacy shapes, hull faces for solids)
var _body_top := BODY_HEIGHT   # world height of the body's top (drives the health bar)
var _bar: Sprite3D
var _bar_tex: ImageTexture

func setup(d: EnemyData, points: PackedVector2Array) -> void:
	data = d
	path_points = points
	health = d.health
	pp = points[0]
	if points.size() > 1:
		heading = (points[1] - points[0]).angle()
	_build_visuals()
	_sync_transform()
	_refresh_bar_texture(1.0)

func silhouette() -> PackedVector2Array:
	return _shape_points()

func progress() -> int:
	return _index

# --------------------------------------------------------------- mesh
func _build_visuals() -> void:
	_body_root = Node3D.new()
	add_child(_body_root)
	_build_body()
	_bar = Sprite3D.new()
	_bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bar.shaded = false
	_bar.pixel_size = BAR_PIXEL_SIZE / float(BAR_PIX_H)
	add_child(_bar)
	_place_bar()

# (Re)build the body under _body_root. Solids get a faceted shaded body PLUS a
# glowing neon edge outline (two child meshes); the legacy extruded prism shapes
# get the single extruded body. Callers clear _body_root first (morph rebuilds).
func _build_body() -> void:
	for c in _body_root.get_children():
		c.queue_free()
	if data.shape in SOLIDS:
		_build_solid_body()
	else:
		_body = MeshInstance3D.new()
		_body.mesh = _build_prism_mesh()
		_body.material_override = _faces_material()
		_body_root.add_child(_body)
		_body_top = BODY_HEIGHT

func _place_bar() -> void:
	if _bar != null:
		_bar.position = Vector3(0, _body_top + BAR_HEIGHT_PAD, 0)

# A true 3D platonic solid (or dual compound) as the body. Each member is
# normalised to a circumradius of 1, scaled by data.radius, and shifted so the
# body's lowest point rests on the board (y=0). Faces are flat-shaded metallic
# (form from the key light) + a modest self-glow; edges are bright emissive
# lines that bloom — the "faceted + edge glow" style.
func _build_solid_body() -> void:
	var members := _solid_members(data.shape)
	var r: float = maxf(2.0, data.radius)
	# Scale each member to circumradius r into FRESH arrays (packed arrays are
	# copy-on-write, so mutating the members in place wouldn't persist) and find
	# the lowest point so the body can be lifted to rest on the board.
	var scaled: Array = []
	var min_y := INF
	var max_y := -INF
	for verts in members:
		var sv := PackedVector3Array()
		for v in verts:
			var p: Vector3 = v * r
			sv.append(p)
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
		scaled.append(sv)
	var lift := -min_y
	var face_st := SurfaceTool.new()
	face_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	face_st.set_smooth_group(-1)            # flat facets
	var edge_st := SurfaceTool.new()
	edge_st.begin(Mesh.PRIMITIVE_LINES)
	for verts in scaled:
		var lifted := PackedVector3Array()
		for v in verts:
			lifted.append(v + Vector3(0, lift, 0))
		for tri in _hull_triangles(lifted):
			face_st.add_vertex(lifted[tri[0]])
			face_st.add_vertex(lifted[tri[1]])
			face_st.add_vertex(lifted[tri[2]])
		for e in _min_edges(lifted):
			edge_st.add_vertex(lifted[e[0]])
			edge_st.add_vertex(lifted[e[1]])
	face_st.generate_normals()
	var faces := MeshInstance3D.new()
	faces.mesh = face_st.commit()
	faces.material_override = _faces_material()
	_body_root.add_child(faces)
	_body = faces
	var edges := MeshInstance3D.new()
	edges.mesh = edge_st.commit()
	edges.material_override = _edge_material()
	_body_root.add_child(edges)
	_body_top = max_y + lift

# The members of a solid/compound, as arrays of vertices normalised so the
# largest member has a circumradius of 1. A compound is two interpenetrating
# solids built independently (dual pairs) — so each keeps its own faces/edges.
func _solid_members(shape: String) -> Array:
	match shape:
		"stella_octangula":
			var t := _verts("tetrahedron")
			var t2 := PackedVector3Array()
			for v in t:
				t2.append(-v)
			return [_normalize(t), _normalize(t2)]
		"cube_octahedron":
			return [_normalize(_verts("cube")), _scaled(_normalize(_verts("octahedron")), 1.18)]
		"dodeca_icosahedron":
			return [_normalize(_verts("dodecahedron")), _scaled(_normalize(_verts("icosahedron")), 1.12)]
		_:
			return [_normalize(_verts(shape))]

func _verts(name: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	for v in SOLID_VERTS[name]:
		out.append(v)
	return out

func _normalize(verts: PackedVector3Array) -> PackedVector3Array:
	var maxr := 0.0
	for v in verts:
		maxr = maxf(maxr, v.length())
	if maxr < 0.0001:
		return verts
	var out := PackedVector3Array()
	for v in verts:
		out.append(v / maxr)
	return out

func _scaled(verts: PackedVector3Array, s: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	for v in verts:
		out.append(v * s)
	return out

# Brute-force convex-hull triangulation (n <= 20, so O(n^3) is trivial): a triple
# is a hull face when every other vertex lies on one side of its plane. Wound so
# the normal points outward (away from the origin-centred solid). Coplanar faces
# emit several overlapping triangles with the same normal — harmless for shading
# (we never draw the triangle diagonals; the crisp outline comes from _min_edges).
func _hull_triangles(verts: PackedVector3Array) -> Array:
	var n := verts.size()
	var tris := []
	for i in range(n):
		for j in range(i + 1, n):
			for k in range(j + 1, n):
				var a := verts[i]
				var b := verts[j]
				var c := verts[k]
				var nrm := (b - a).cross(c - a)
				if nrm.length() < 0.000001:
					continue
				nrm = nrm.normalized()
				var d := nrm.dot(a)
				var pos := false
				var neg := false
				for m in range(n):
					if m == i or m == j or m == k:
						continue
					var s := nrm.dot(verts[m]) - d
					if s > 0.0001:
						pos = true
					elif s < -0.0001:
						neg = true
				if pos and neg:
					continue   # vertices straddle the plane -> not a hull face
				# orient outward: a face vertex of an origin-centred solid has
				# outward-normal . vertex > 0
				if d >= 0.0:
					tris.append([i, j, k])
				else:
					tris.append([i, k, j])
	return tris

# Polyhedron edges = vertex pairs at the minimum pairwise distance (true for all
# platonic solids). Computed per member so a compound's two solids keep their
# own edge lengths rather than picking up spurious cross-member pairs.
func _min_edges(verts: PackedVector3Array) -> Array:
	var n := verts.size()
	var mind := INF
	for i in range(n):
		for j in range(i + 1, n):
			mind = minf(mind, verts[i].distance_to(verts[j]))
	var out := []
	for i in range(n):
		for j in range(i + 1, n):
			if absf(verts[i].distance_to(verts[j]) - mind) < mind * 0.05:
				out.append([i, j])
	return out

# Faces: lit metallic (form from the key light) + a modest self-glow so the body
# reads on the dark board without washing out the edge outline.
func _faces_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var fill: Color = data.color
	mat.albedo_color = fill
	mat.metallic = 0.6
	mat.roughness = 0.3
	# Two-sided: the hull winding yields outward normals (so front faces light
	# correctly), but for convex solids the back faces are occluded anyway, and
	# disabling culling removes any winding-convention risk (no inside-out body).
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if data.glow > 0.0:
		mat.emission_enabled = true
		mat.emission = fill
		mat.emission_energy_multiplier = 0.25 + data.glow * 0.3
	return mat

# Edges: unshaded bright emission so the outline blooms in the HDR glow — the
# "pop" of the faceted-plus-edge-glow look.
func _edge_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var fill: Color = data.color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = fill.lightened(0.3)
	mat.emission_enabled = true
	mat.emission = fill.lightened(0.3)
	mat.emission_energy_multiplier = 2.5 + data.glow * GLOW_HDR_BOOST
	return mat

# Extrude the 2D silhouette into a prism (legacy non-solid shapes). Winding
# mirrors GameBoard3D._add_prism (top cap + outward side walls).
func _build_prism_mesh() -> ArrayMesh:
	var pts := _local_shape_points()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)   # flat facets, so the body's edges stay crisp
	_emit_prism(st, pts, BODY_HEIGHT, 0.0)
	st.generate_normals()
	return st.commit()

func _emit_prism(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		# top cap (fan from center). (center, b, a) so the cap faces +Y up under
		# the (x,y)->(x,0,y) handedness flip; see GameBoard3D._add_cap.
		st.add_vertex(Vector3(center.x, top, center.y))
		st.add_vertex(Vector3(b.x, top, b.y))
		st.add_vertex(Vector3(a.x, top, a.y))
		# side walls (two tris per quad), wound to face outward
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(ab)
		st.add_vertex(at); st.add_vertex(bt); st.add_vertex(bb)

# Local (un-rotated) shape, in plane coords. Heading is applied via _body_root yaw.
func _local_shape_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	if data.shape in SOLIDS:
		# Footprint approximation for projectile pierce / overlays: an octagon at
		# the body's circumradius. (The actual 3D shape is built elsewhere.)
		var r: float = maxf(2.0, data.radius)
		for i in range(8):
			var a := deg_to_rad(22.5 + 45.0 * i)
			pts.append(Vector2(cos(a), sin(a)) * r)
		return pts
	match data.shape:
		"rect":
			var l := data.length * 0.5
			var w := data.width * 0.5
			pts = PackedVector2Array([Vector2(l, -w), Vector2(l, w), Vector2(-l, w), Vector2(-l, -w)])
		"octagon":
			for i in range(8):
				var a := deg_to_rad(22.5 + 45.0 * i)
				pts.append(Vector2(cos(a), sin(a)) * data.radius)
		"polygon":
			var n: int = maxi(3, data.sides)
			for i in range(n):
				var a := TAU * float(i) / float(n)
				pts.append(Vector2(cos(a), sin(a)) * data.radius)
		_:
			var h := data.side * 0.5
			pts = PackedVector2Array([Vector2(h, -h), Vector2(h, h), Vector2(-h, h), Vector2(-h, -h)])
	return pts

# Heading-baked points (kept so radial_projectile_3d / overlays can ask for a
# rotated silhouette the same way the 2D enemy exposed it).
func _shape_points() -> PackedVector2Array:
	var local := _local_shape_points()
	var out := PackedVector2Array()
	for p in local:
		out.append(p.rotated(heading))
	return out

func _radius_estimate() -> float:
	if data.shape in SOLIDS:
		return maxf(2.0, data.radius)
	match data.shape:
		"rect":
			return maxf(data.length, data.width) * 0.5
		"octagon", "polygon":
			return data.radius
		_:
			return data.side * 0.5

# --------------------------------------------------------------- transform sync
# Plane heading: 0 = facing +X. World rotation around Y: world basis maps plane
# +X -> world +X, plane +Y -> world +Z. A 2D rotation by `heading` corresponds
# to a world rotation around Y by `-heading` (handedness flips because Y is up).
func _sync_transform() -> void:
	# Enemies hover above the board (over the sunken path), not resting on it.
	position = Vector3(pp.x, GameBoard3D.ENEMY_Y, pp.y)
	_body_root.rotation = Vector3(0.0, -heading, 0.0)

# --------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if not _alive:
		return
	if _index >= path_points.size() - 1:
		_reach_goal()
		return
	var target := path_points[_index + 1]
	var to_target := target - pp
	var dist := to_target.length()
	if dist > 0.001:
		heading = lerp_angle(heading, to_target.angle(), clampf(TURN_RATE * delta, 0.0, 1.0))
	var step := data.speed * delta
	if step >= dist:
		pp = target
		_index += 1
	else:
		pp += to_target / dist * step
	_sync_transform()

# --------------------------------------------------------------- damage / reduction
func take_damage(amount: float, pierces_ecc := false) -> void:
	if not _alive:
		return
	if data.ecc and not pierces_ecc:
		amount *= (1.0 - ECC_RESIST)
	health -= amount
	if health <= 0.0:
		_on_depleted()
	else:
		_refresh_bar_texture(health / data.health)

func _on_depleted() -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx(data.death_sound)
	bounty.emit(data.reward)
	var lesser: EnemyData = data.reduces_to
	if lesser == null:
		_alive = false
		queue_free()
		return
	var count: int = maxi(1, data.reduce_count)
	var parent_index := _index
	var parent_pos := pp
	# morph this node into the lesser form
	data = lesser
	health = data.health
	_build_body()
	_place_bar()
	_refresh_bar_texture(1.0)
	if count <= 1:
		return
	# the rest spawn along the path behind us, evenly spaced
	var spacing: float = _radius_estimate() * 2.0 + 6.0
	var placements := []
	for k in range(1, count):
		var res := _walk_back(parent_index, parent_pos, spacing * float(k))
		placements.append({"index": int(res.x), "pos": Vector2(res.y, res.z)})
	split.emit(lesser, placements)

func _walk_back(seg: int, p: Vector2, back: float) -> Vector3:
	while back > 0.0:
		var behind := path_points[seg]
		var v := behind - p
		var d := v.length()
		if d >= back:
			var np := p + v / maxf(d, 0.0001) * back
			return Vector3(float(seg), np.x, np.y)
		back -= d
		p = behind
		if seg == 0:
			return Vector3(0.0, path_points[0].x, path_points[0].y)
		seg -= 1
	return Vector3(float(seg), p.x, p.y)

func place_on_path(seg: int, pos: Vector2) -> void:
	_index = seg
	pp = pos
	if seg + 1 < path_points.size():
		heading = (path_points[seg + 1] - pos).angle()
	_sync_transform()

func _reach_goal() -> void:
	_alive = false
	reached_goal.emit()
	queue_free()

# --------------------------------------------------------------- health bar
# A tiny billboarded sprite. Cheap to redraw — only happens when health changes
# (or on setup/morph), not every frame.
func _refresh_bar_texture(frac: float) -> void:
	var img := Image.create(BAR_PIX_W, BAR_PIX_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0.6))
	var fill: int = maxi(0, int(round(float(BAR_PIX_W) * clampf(frac, 0.0, 1.0))))
	if fill > 0:
		img.fill_rect(Rect2i(0, 0, fill, BAR_PIX_H), Color(0.2, 0.9, 0.3))
	if _bar_tex == null:
		_bar_tex = ImageTexture.create_from_image(img)
		_bar.texture = _bar_tex
	else:
		_bar_tex.update(img)
