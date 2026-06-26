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
const SPEED_MULT := 2.5         # global travel-speed multiplier applied to data.speed (JSON values stay as authored)
# Denial of Service (DoS) debuff: a hit fully stops the enemy for DOS_STOP seconds,
# then drops it to DOS_SLOW_FACTOR of its speed for DOS_SLOW_TIME seconds.
const DOS_STOP := 0.5
const DOS_SLOW_TIME := 2.0
const DOS_SLOW_FACTOR := 0.5
const DOS_FROST := Color(0.5, 0.85, 1.0)   # icy tint while frozen/slowed
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
	"stella_octangula", "cube_octahedron", "dodeca_icosahedron",
	"great_dodecahedron", "great_stellated_dodecahedron", "great_icosahedron"]
# Kepler–Poinsot star polyhedra. The flat-shaded renderer can't draw their true
# self-intersecting faces, so each is built as a recognisable surface model: a
# base solid with a pyramidal spike (k>1) or inward dimple (k<1) erected on every
# face. core = which base solid, k = apex distance as a fraction of the face
# centroid distance. (Validated offline; see scratchpad/stars.py.)
const STAR_SOLIDS := {
	"great_dodecahedron": {"core": "icosahedron", "k": 0.45},          # dimpled icosa (concave, 12 points)
	"great_stellated_dodecahedron": {"core": "dodecahedron", "k": 1.95}, # 12 pentagonal spikes
	"great_icosahedron": {"core": "icosahedron", "k": 2.0},            # 20 triangular spikes
}
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
const BAR_HEIGHT_PAD := 3.0     # bar sits above the body's top by this many units

var data: EnemyData
var path_points: PackedVector2Array
var health: float
var heading := 0.0             # radians; 0 = facing +X in plane space
var pp := Vector2.ZERO
var _index := 0
var _alive := true

# DoS debuff state
var _freeze_time := 0.0
var _slow_time := 0.0
var _slow_factor := 1.0         # active slow multiplier (set per-tower by apply_dos)
var _tint_mats: Array = []      # {mat, alb, emi, emi_on} for body materials we can frost-tint
var _dos_vis_k := -1.0          # last-applied tint strength (avoid per-frame churn)
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
	# Draw the bar on top of everything (body, walls) so it reads as a HUD element
	# regardless of camera angle, the way the 2D bar always sat above the sprite.
	_bar.no_depth_test = true
	_bar.render_priority = 8
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
	# ECC scan band sweeps the body's full height, so tune it once the height is known.
	_tune_scan(_body)
	_collect_tint_mats()

func _place_bar() -> void:
	if _bar != null:
		# Size the bar to roughly the enemy's width so it's clearly readable
		# (a fixed tiny bar got lost against the larger 3D bodies). pixel_size is
		# chosen so the 40-texel-wide texture spans ~2.4 * the body radius.
		var bar_w: float = maxf(9.0, _radius_estimate() * 2.4)
		_bar.pixel_size = bar_w / float(BAR_PIX_W)
		_bar.position = Vector3(0, _body_top + BAR_HEIGHT_PAD, 0)

# A true 3D platonic solid (or dual compound) as the body. Each member is
# normalised to a circumradius of 1, scaled by data.radius, and shifted so the
# body's lowest point rests on the board (y=0). Faces are flat-shaded metallic
# (form from the key light) + a modest self-glow; edges are bright emissive
# lines that bloom — the "faceted + edge glow" style.
func _build_solid_body() -> void:
	var r: float = maxf(2.0, data.radius)
	# Gather geometry in unit (circumradius ~1) coords as flat triangles + edges,
	# then scale by r, lift so the lowest point rests on the board, and emit.
	var faces: Array = []        # each: PackedVector3Array of 3 verts
	var edges: Array = []        # each: [Vector3, Vector3]
	_collect_solid_geometry(data.shape, faces, edges)
	var min_y := INF
	var max_y := -INF
	var sfaces: Array = []
	for f in faces:
		var sf := PackedVector3Array()
		for v in f:
			var p: Vector3 = v * r
			sf.append(p)
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
		sfaces.append(sf)
	var sedges: Array = []
	for e in edges:
		var a: Vector3 = e[0] * r
		var b: Vector3 = e[1] * r
		min_y = minf(min_y, minf(a.y, b.y))
		max_y = maxf(max_y, maxf(a.y, b.y))
		sedges.append([a, b])
	var lift := -min_y
	var up := Vector3(0, lift, 0)
	# Faces: flat-shaded, one explicit normal per triangle pointing away from the
	# (origin-centred, pre-lift) body — robust for convex hulls and spikes alike.
	var face_st := SurfaceTool.new()
	face_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sf in sfaces:
		var a: Vector3 = sf[0]
		var b: Vector3 = sf[1]
		var c: Vector3 = sf[2]
		var nrm := (b - a).cross(c - a)
		if nrm.length() < 0.000001:
			continue
		nrm = nrm.normalized()
		if nrm.dot((a + b + c) / 3.0) < 0.0:
			nrm = -nrm
		face_st.set_normal(nrm); face_st.add_vertex(a + up)
		face_st.set_normal(nrm); face_st.add_vertex(b + up)
		face_st.set_normal(nrm); face_st.add_vertex(c + up)
	var faces_mi := MeshInstance3D.new()
	faces_mi.mesh = face_st.commit()
	faces_mi.material_override = _faces_material()
	_body_root.add_child(faces_mi)
	_body = faces_mi
	var edge_st := SurfaceTool.new()
	edge_st.begin(Mesh.PRIMITIVE_LINES)
	for se in sedges:
		edge_st.add_vertex(se[0] + up)
		edge_st.add_vertex(se[1] + up)
	var edges_mi := MeshInstance3D.new()
	edges_mi.mesh = edge_st.commit()
	edges_mi.material_override = _edge_material()
	_body_root.add_child(edges_mi)
	_body_top = max_y + lift

# Fill `faces` (triangles) and `edges` (segments) in unit coords for the shape.
# Convex solids & compounds come from per-member hull triangulation + min edges;
# the Kepler–Poinsot stars get explicit spike/dimple geometry.
func _collect_solid_geometry(shape: String, faces: Array, edges: Array) -> void:
	if STAR_SOLIDS.has(shape):
		_collect_star_geometry(shape, faces, edges)
		return
	for verts in _solid_members(shape):
		for tri in _hull_triangles(verts):
			faces.append(PackedVector3Array([verts[tri[0]], verts[tri[1]], verts[tri[2]]]))
		for e in _min_edges(verts):
			edges.append([verts[e[0]], verts[e[1]]])

# A star polyhedron's surface model: erect an apex over every face of the base
# solid (apex = face_centroid * k) and fan-triangulate the face to it. k>1 makes
# outward spikes; k<1 makes inward dimples (concave). Edges = the base-face edges
# (outer ridges) plus each apex ridge, so the faceted form glows crisply.
func _collect_star_geometry(shape: String, faces: Array, edges: Array) -> void:
	var spec: Dictionary = STAR_SOLIDS[shape]
	var core := _normalize(_verts(str(spec["core"])))
	var k := float(spec["k"])
	for f in _faces_of(core):
		var ctr := Vector3.ZERO
		for idx in f:
			ctr += core[idx]
		ctr /= float(f.size())
		var apex: Vector3 = ctr * k
		var m: int = f.size()
		for t in range(m):
			var a: Vector3 = core[f[t]]
			var b: Vector3 = core[f[(t + 1) % m]]
			faces.append(PackedVector3Array([a, b, apex]))
			edges.append([a, b])       # outer ridge (base-face edge)
			edges.append([a, apex])    # ridge from this vertex up/in to the apex

# Detect a convex solid's flat faces: group hull triangles by their (outward)
# plane normal, then order each face's vertices CCW around the face centroid so
# the caller can fan-triangulate or erect a spike on a clean polygon.
func _faces_of(verts: PackedVector3Array) -> Array:
	var groups := {}
	for tri in _hull_triangles(verts):
		var a: Vector3 = verts[tri[0]]
		var b: Vector3 = verts[tri[1]]
		var c: Vector3 = verts[tri[2]]
		var nrm := (b - a).cross(c - a)
		if nrm.length() < 0.000001:
			continue
		nrm = nrm.normalized()
		if nrm.dot(a) < 0.0:
			nrm = -nrm
		var key := "%d,%d,%d" % [roundi(nrm.x * 1000.0), roundi(nrm.y * 1000.0), roundi(nrm.z * 1000.0)]
		var arr: Array = groups.get(key, [])
		for idx in tri:
			if not (idx in arr):
				arr.append(idx)
		groups[key] = arr
	var faces := []
	for key in groups:
		var idx: Array = groups[key]
		var ctr := Vector3.ZERO
		for i in idx:
			ctr += verts[i]
		ctr /= float(idx.size())
		var n := ctr.normalized()
		var u := (verts[idx[0]] - ctr).normalized()
		var w := n.cross(u)
		var pairs := []
		for i in idx:
			var d: Vector3 = verts[i] - ctr
			pairs.append([atan2(d.dot(w), d.dot(u)), i])
		pairs.sort_custom(func(x, y): return x[0] < y[0])
		var ordered := []
		for p in pairs:
			ordered.append(p[1])
		faces.append(ordered)
	return faces

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
# reads on the dark board without washing out the edge outline. Enemies carrying
# a special property (ECC / Encrypted / both = "TLS") get a ShaderMaterial that
# adds the property visuals instead; plain enemies keep the cheap StandardMaterial.
func _faces_material() -> Material:
	if data.ecc or data.encrypted:
		return _property_material()
	var mat := StandardMaterial3D.new()
	var fill: Color = data.color
	mat.albedo_color = fill
	mat.metallic = 0.2
	mat.roughness = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if data.glow > 0.0:
		mat.emission_enabled = true
		mat.emission = fill
		mat.emission_energy_multiplier = 0.3 + data.glow * 0.25
	return mat

# Shader for the special-property body. Replicates the plain look (lit metallic +
# self-glow) and adds, per uniform flags:
#  - ECC: a thick horizontal emission band sweeping up/down the body height.
#  - Encrypted: partial face transparency, so the opaque wireframe edges show
#    through as a "revealed wireframe".
#  - both (TLS): both — and the scan band is forced opaque so the sweeping line
#    is never see-through.
const _PROPERTY_SHADER := """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 body_color : source_color = vec4(1.0);
uniform float emission_energy = 0.4;
uniform float base_alpha = 1.0;
uniform float scan_enabled = 0.0;
uniform float scan_center = 0.0;
uniform float scan_amp = 1.0;
uniform float scan_half_width = 1.0;
uniform float scan_speed = 1.6;
uniform float scan_boost = 2.4;
uniform float scan_phase = 0.0;

varying float v_y;

void vertex() {
	v_y = VERTEX.y;
}

void fragment() {
	ALBEDO = body_color.rgb;
	METALLIC = 0.2;
	ROUGHNESS = 0.5;
	vec3 emis = body_color.rgb * emission_energy;
	float alpha = base_alpha;
	if (scan_enabled > 0.5) {
		float pos = scan_center + scan_amp * sin(TIME * scan_speed + scan_phase);
		float band = 1.0 - smoothstep(scan_half_width * 0.55, scan_half_width, abs(v_y - pos));
		emis += body_color.rgb * band * scan_boost;
		alpha = max(alpha, band);   // scan band stays opaque (TLS: never transparent)
	}
	EMISSION = emis;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
"""

static var _property_shader: Shader

func _property_material() -> ShaderMaterial:
	if _property_shader == null:
		_property_shader = Shader.new()
		_property_shader.code = _PROPERTY_SHADER
	var m := ShaderMaterial.new()
	m.shader = _property_shader
	var fill: Color = data.color
	var energy := 0.0
	if data.glow > 0.0:
		energy = 0.3 + data.glow * 0.25
	m.set_shader_parameter("body_color", fill)
	m.set_shader_parameter("emission_energy", energy)
	# Encrypted: ghost the faces (the opaque edge wireframe then reads through them).
	m.set_shader_parameter("base_alpha", 0.4 if data.encrypted else 1.0)
	# ECC: enable the sweeping band (extents are set in _tune_scan once the height is known).
	m.set_shader_parameter("scan_enabled", 1.0 if data.ecc else 0.0)
	m.set_shader_parameter("scan_phase", randf() * TAU)   # de-sync the sweep across enemies
	return m

# Set the ECC scan band's vertical extents from the finished body height. The
# band sweeps the full [0, _body_top] span and is kept thick (~0.44 * height).
func _tune_scan(mi: MeshInstance3D) -> void:
	if mi == null:
		return
	var m = mi.material_override
	if m is ShaderMaterial:
		var top: float = maxf(_body_top, 0.001)
		m.set_shader_parameter("scan_center", top * 0.5)
		m.set_shader_parameter("scan_amp", top * 0.5)
		m.set_shader_parameter("scan_half_width", top * 0.22)

# Edges: unshaded emission for a crisp glowing outline. Kept modest — too bright
# and the bloom swallows the body into a formless blob.
func _edge_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var fill: Color = data.color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = fill.lightened(0.3)
	mat.emission_enabled = true
	mat.emission = fill.lightened(0.3)
	mat.emission_energy_multiplier = 1.2 + data.glow * 0.4
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
	_tick_dos(delta)
	var step := data.speed * SPEED_MULT * delta
	if _freeze_time > 0.0:
		step = 0.0
	elif _slow_time > 0.0:
		step *= _slow_factor
	if step >= dist:
		pp = target
		_index += 1
	else:
		pp += to_target / dist * step
	_sync_transform()

# --------------------------------------------------------------- Denial of Service
# Apply (or refresh) the freeze-then-slow debuff. Re-hits take the longer remaining
# of each phase rather than stacking. The slow timer only counts down once the
# freeze has elapsed, so the full slow window always follows the stop.
func apply_dos(freeze := DOS_STOP, slow_time := DOS_SLOW_TIME, slow_factor := DOS_SLOW_FACTOR) -> void:
	if not _alive:
		return
	# Re-application takes the stronger of each: longer freeze/slow, and the lower
	# (stronger) slow factor. A fresh hit on an un-debuffed enemy takes its factor.
	var active := _freeze_time > 0.0 or _slow_time > 0.0
	_freeze_time = maxf(_freeze_time, freeze)
	_slow_time = maxf(_slow_time, slow_time)
	_slow_factor = slow_factor if not active else minf(_slow_factor, slow_factor)

func _tick_dos(delta: float) -> void:
	if _freeze_time > 0.0:
		_freeze_time -= delta
	elif _slow_time > 0.0:
		_slow_time -= delta
	_apply_dos_visual()

# Snapshot the body materials we can frost-tint (StandardMaterial3D only; the ECC
# scan shader is left alone). Rebuilt whenever the body is (re)built.
func _collect_tint_mats() -> void:
	_tint_mats.clear()
	_dos_vis_k = -1.0
	if _body_root != null:
		_gather_tint_mats(_body_root)

func _gather_tint_mats(n: Node) -> void:
	if n is MeshInstance3D:
		var m: Material = (n as MeshInstance3D).material_override
		if m is StandardMaterial3D:
			var sm := m as StandardMaterial3D
			_tint_mats.append({"mat": sm, "alb": sm.albedo_color, "emi": sm.emission, "emi_on": sm.emission_enabled})
	for c in n.get_children():
		_gather_tint_mats(c)

# Lerp the body toward an icy colour while frozen (strong) or slowed (mild), and
# restore the originals when the debuff lapses. Only writes on a change in strength.
func _apply_dos_visual() -> void:
	var k := 0.0
	if _freeze_time > 0.0:
		k = 0.85
	elif _slow_time > 0.0:
		k = 0.5
	if is_equal_approx(k, _dos_vis_k):
		return
	_dos_vis_k = k
	for t in _tint_mats:
		var sm: StandardMaterial3D = t["mat"]
		sm.albedo_color = (t["alb"] as Color).lerp(DOS_FROST, k)
		if t["emi_on"]:
			sm.emission = (t["emi"] as Color).lerp(DOS_FROST, k)

# --------------------------------------------------------------- damage / reduction
func take_damage(amount: float, pierces_ecc := false, buffer_overflow := false) -> bool:
	# Returns true if this hit depleted the current form (a "kill"), so the laser
	# can trigger its focus_time delay.
	if not _alive:
		return false
	if data.ecc and not pierces_ecc:
		amount *= (1.0 - ECC_RESIST)
	# Buffer Overflow: remember surplus past the target's remaining HP (post-resist).
	var carry := 0.0
	if buffer_overflow and amount > health:
		carry = amount - health
	health -= amount
	if health <= 0.0:
		_on_depleted(carry, pierces_ecc)
		return true
	_refresh_bar_texture(health / data.health)
	return false

func _on_depleted(carry := 0.0, pierces_ecc := false) -> void:
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
	# Buffer Overflow: split the carried surplus evenly across the decay children
	# (floor; remainder discarded). per_child == 0 when there is no overflow.
	var per_child := 0.0
	if carry > 0.0:
		per_child = floor(carry / float(count))
	var parent_index := _index
	var parent_pos := pp
	# morph this node into the lesser form (it is the first decay child)
	data = lesser
	health = data.health
	_build_body()
	_place_bar()
	_refresh_bar_texture(1.0)
	# the rest spawn along the path behind us, evenly spaced, each carrying overflow
	if count > 1:
		var spacing: float = _radius_estimate() * 2.0 + 6.0
		var placements := []
		for k in range(1, count):
			var res := _walk_back(parent_index, parent_pos, spacing * float(k))
			placements.append({"index": int(res.x), "pos": Vector2(res.y, res.z), "carry": per_child, "pierce": pierces_ecc})
		split.emit(lesser, placements)
	# Spill into this first child too. One-hop: the carried hit does not itself
	# overflow (buffer_overflow arg left false), but a child it kills decays normally.
	if per_child > 0.0:
		take_damage(per_child, pierces_ecc)

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
