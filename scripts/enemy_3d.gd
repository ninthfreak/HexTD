class_name Enemy3D
extends Node3D
## 3D enemy. All path / damage / split logic is ported verbatim from the 2D
## Enemy, operating on `pp` (plane position, Vector2). The 3D transform is
## synced from `pp` for display only. Body is an extruded prism rotated to face
## travel; the health bar above it is one instance in the board-wide
## HealthBarField, billboarded there so it reads upright regardless of body yaw
## or camera tilt.
##
## Two nodes per enemy: this root (pp) and _body (one MeshInstance3D carrying the
## merged faces+edges mesh plus heading yaw, idle spin, hover bob and the pop
## scale). Materials are SHARED per enemy type — every per-enemy visual
## (hit flash, DoS frost, ECC scan phase) rides instance shader uniforms on
## _body, so combat never writes a material property. That is the fast path and
## needs a RenderingDevice renderer; on the Compatibility renderer the shared
## material is a TEMPLATE that is duplicated per enemy instead (see
## _instance_uniforms_ok). Both paths draw the same image, and every per-enemy
## write goes through the one _set_inst_param helper.
##
## In the reduced LOD tier the body is not drawn by this node at all: _body is
## hidden and the shape becomes ONE instance in its enemy type's EnemyCrowdField
## (a single MultiMesh draw call for every reduced body of that type). Purely a
## change of renderer — pp, cell, health, hit_radius, the spatial buckets and
## every other targeting input are untouched by it.

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
const HIT_FLASH_RATE := 8.0     # hit flash decays at ~8/s so each hit reads as a distinct blink
const BOB_AMPLITUDE := 0.45     # hover bob on _body — display only, pp/hit logic untouched
const BOB_RATE := 2.2
const SPIN_RATE := 0.5          # idle spin (rad/s) for platonic solids only

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
const BAR_HEIGHT_PAD := 3.0     # bar sits above the body's top by this many units
# Mass-kill cap: at most this many shard FX may START in one frame (death shatter
# and goal-leak share the budget). Past it the enemy still dies normally and
# silently — an accepted visual trade-off, since nobody counts shards in a wipe.
# Distance LOD. The neon edge outline is 89% of enemy geometry, and its prisms
# are capped at 0.24 world units wide — under a pixel past ~500 units of camera
# distance, where they alias instead of reading as lines. Below LOD_DROP_PX of
# apparent DIAMETER an enemy therefore switches to a faces-only mesh; it comes
# back above LOD_RESTORE_PX. Keying on apparent size rather than camera distance
# keeps big shapes detailed at every zoom while tiny ones shed geometry early.
# A/B renders showed no compensation is wanted: lighting the body to replace the
# lost edge bloom flattens the facet shading and blows out pale enemies.
const LOD_DROP_PX := 40.0
const LOD_RESTORE_PX := 48.0        # gap = hysteresis, so scrolling cannot flicker
# Camera-derived half of the size test, refreshed once per frame by Main3D:
# apparent diameter in px == hit_radius * lod_k / distance_to_camera.
static var lod_k := 0.0
static var lod_cam_pos := Vector3.ZERO
# Frame counter fed by the same Main3D tick. Zoom changes are gradual and the
# hysteresis band above absorbs the lag, so each enemy only re-tests every 8th
# frame on its own stagger — at 400 enemies the test itself would otherwise cost
# more than the tier saves at close zoom, where nothing is reduced.
static var lod_frame := 0
const LOD_TEST_MASK := 7
# Crowd rule: in a cell holding this many enemies, everything except the largest
# one is buried in the pile and drops to the reduced tier whatever its apparent
# size. Restoring needs the cell to thin out to LOD_CROWD_CLEAR, which is the
# hysteresis for the same reason the pixel thresholds have a gap.
const LOD_CROWD_MIN := 3
const LOD_CROWD_CLEAR := 2

const DEATH_FX_PER_FRAME := 12
# Whether enemy bodies cast into the shadow map. Measured at 400 enemies: casting
# costs ~585 objects, ~585 draw calls and ~178k primitives — 43% of ALL draw calls
# in the frame — because every enemy is a shadow caster on top of its own draw.
# Enemies hover one unit over a near-black board lit by a dim (0.55) key light, so
# their shadows are not discernible in a side-by-side render; towers, walls and the
# board keep casting normally, which is where the grounding actually reads. Flip
# this to true to get them back (that also puts the merged edge outline in the
# shadow pass, which the pre-merge code excluded).
const ENEMY_CASTS_SHADOW := false
const FX_POOL_KEY := &"enemy_shard_fx"

var data: EnemyData
var path_points: PackedVector2Array
var health: float
var heading := 0.0             # radians; 0 = facing +X in plane space
var pp := Vector2.ZERO
# Cached grid cell of pp (refreshed each movement step) — read by
# towers/projectiles and the board's spatial buckets.
var cell := Vector2i.ZERO
var hit_radius := 0.0          # cached _radius_estimate(), kept fresh across setup/morph
var _grid_origin := Vector2.ZERO   # board plane origin (set by GameBoard3D.add_enemy)
var _index := 0
var _alive := true

# DoS debuff state
var _freeze_time := 0.0
var _slow_time := 0.0
var _slow_factor := 1.0         # active slow multiplier (set per-tower by apply_dos)
var _dos_vis_k := -1.0          # last-applied tint strength (avoid per-frame churn)
var _flash := 0.0               # hit-flash strength; set on damage, decayed in _process
var _flash_vis := -1.0          # last-applied flash strength (churn guard, like _dos_vis_k)
var _bob_time := 0.0
var _bob_phase := 0.0           # per-enemy random phase so hover bobs de-sync across the wave
# The one body node: merged faces (surface 0) + edge outline (surface 1), and the
# carrier of heading yaw + idle spin + hover bob + pop scale (bar stays upright).
var _body: MeshInstance3D
var _edges_mesh: ArrayMesh     # edges-only copy of surface 1; the shard FX draws this
# Fallback renderer ONLY (see _instance_uniforms_ok): this node's own duplicated
# materials, which carry the per-enemy values that cannot ride the instance there.
# Body enemies hold two (faces + edges); an FX carrier holds one. Always EMPTY on
# the capable path, where those same values are written to the instance instead.
var _own_mats: Array[ShaderMaterial] = []
var _lod_reduced := false      # true = wearing the faces-only mesh
var _lod_phase := 0            # de-syncs the staggered LOD test across the wave
# Written by GameBoard3D._refresh_buckets: how many enemies share this cell, and
# whether this is the largest of them (the one actually visible in the pile).
var crowd := 1
var crowd_lead := true
var _mat_body: ShaderMaterial  # surface 0 material, kept for tier swaps
var _mat_edge: ShaderMaterial  # surface 1 material (null while reduced)
var _spins := false            # platonic solids only — prisms never gain idle spin
var _spin_angle := 0.0         # idle spin, folded into the body yaw
var _pop_tween: Tween
var _pending_pop := 0.0        # spawn-pop duration deferred to _ready (setup runs pre-add_child)
var _body_top := BODY_HEIGHT   # world height of the body's top (drives the health bar)
# Health bar: an instance in the shared HealthBarField, held only while damaged.
var _bar_slot := -1            # instance index in that field; -1 = no bar
var _bar_field: HealthBarField
var _bar_width := 0.0          # bar's world width (scales with the body)
var _bar_y := 0.0              # bar height above this root, in local units
# Crowd rendering: while reduced, the body is one instance in this enemy type's
# EnemyCrowdField and _body is hidden. -1 = not registered (full tier, or between
# a morph's release and re-acquire).
var _crowd_slot := -1
var _crowd_field: EnemyCrowdField
# Mirrors of the three per-enemy shader values, recorded on the one write path
# (_set_inst_param) because the crowd instance carries them as custom data
# instead of reading them off _body's instance uniforms.
var _flash_inst := 0.0
var _frost_inst := 0.0
var _scan_inst := 0.0

# Shard-FX mode. A released FX carrier is a MeshInstance3D wearing THIS script
# (see _spawn_shard_fx); _is_fx keeps it out of every enemy code path for good.
var _is_fx := false
var _fx_mi: MeshInstance3D     # == self in FX mode, re-typed so the mesh API is reachable
var _fx_board = null           # board that owns the FX free list (untyped: GameBoard3D API)
var _fx_t := 0.0
var _fx_duration := 0.0
var _fx_start_scale := Vector3.ONE
var _fx_end_scale := Vector3.ONE

func setup(d: EnemyData, points: PackedVector2Array) -> void:
	data = d
	path_points = points
	health = d.health
	pp = points[0]
	cell = HexUtils.pixel_to_cell(pp - _grid_origin, GameBoard3D.HEX_SIZE)
	if points.size() > 1:
		heading = (points[1] - points[0]).angle()
	_bob_phase = randf() * TAU
	_lod_phase = randi() & LOD_TEST_MASK
	_build_visuals()
	_sync_transform()
	_refresh_bar(1.0)
	# Spawn-in pop: the same helper covers wave spawns and split children (both
	# arrive through setup()), so nothing materialises at full size in one frame.
	_pop_body(0.05, 0.25)

func silhouette() -> PackedVector2Array:
	return _shape_points()

func progress() -> int:
	return _index

# --------------------------------------------------------------- mesh
func _build_visuals() -> void:
	_body = MeshInstance3D.new()
	add_child(_body)
	_build_body()
	_place_bar()

# (Re)build the body on _body. Solids get a faceted shaded body PLUS a glowing
# neon edge outline; the legacy extruded prism shapes get the same pair from the
# extruded silhouette. Both live in ONE mesh (surface 0 = faces, surface 1 =
# edges) with a per-surface material, so an enemy needs a single MeshInstance3D.
# Meshes AND materials are STATIC and shared by reference (per shape+size via
# _mesh_cache, per enemy type via _body_mats/_edge_mats); nothing per-enemy lives
# in either, so a morph is just a re-point of both. On the fallback renderer the
# two materials are per-enemy duplicates of those same shared ones instead
# (_per_enemy_material) — a morph then re-duplicates from the new type's pair,
# which is still a re-point of everything that is actually built once.
func _build_body() -> void:
	# A morph changes the type key, and a crowd field is per type: drop the old
	# field's instance before the new form is taken, and re-register at the end.
	_release_crowd()
	var entry: Dictionary = _shared_meshes()
	# ECC scan band sweeps the body's full height, so the height must be known
	# before the (height-tuned) shared material is asked for.
	_body_top = float(entry["top"])
	_edges_mesh = entry["edges"]
	var m: ArrayMesh = entry["faces"] if _lod_reduced else entry["mesh"]
	_body.mesh = m
	# Drop any materials a previous form owned (fallback path only — no-op on the
	# capable path, where this list is always empty) before the new pair is taken.
	_own_mats.clear()
	_mat_body = null
	_mat_edge = null
	if m.get_surface_count() > 0:
		_mat_body = _per_enemy_material(_body_material())
		_body.set_surface_override_material(0, _mat_body)
	if m.get_surface_count() > 1:
		_mat_edge = _per_enemy_material(_edge_material())
		_body.set_surface_override_material(1, _mat_edge)
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if ENEMY_CASTS_SHADOW \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Solids spin; prisms must not. A morph restarts the spin from zero, as the
	# rebuilt spin wrapper used to.
	_spins = data.shape in SOLIDS
	_spin_angle = 0.0
	hit_radius = _radius_estimate()
	# Per-enemy shader state. scan_phase de-syncs the ECC sweep across enemies;
	# flash/frost start clean so a morph shows the new form at rest for one frame
	# exactly as the freshly built materials used to.
	_set_inst_param(&"scan_phase", randf())
	_set_inst_param(&"flash", 0.0)
	_set_inst_param(&"frost", 0.0)
	_dos_vis_k = -1.0
	_flash_vis = -1.0
	# Re-seat the yaw now that the spin was zeroed, so a morph snaps in the same
	# frame the rebuilt spin wrapper used to.
	_sync_transform()
	# A morph that happened while reduced stays reduced — in the NEW type's field.
	if _lod_reduced:
		_acquire_crowd()
		_body.visible = _crowd_slot < 0

# Merged body mesh + an edges-only copy (the shard FX draws it alone) + body-top
# height for the current shape and size, built once per distinct key and shared
# across enemies. The key carries every size input the geometry reads
# (_local_shape_points, _radius_estimate and the solid builder), so equal keys
# always mean identical meshes.
static var _mesh_cache: Dictionary = {}

func _shared_meshes() -> Dictionary:
	var key := "%s|%.3f|%.3f|%.3f|%.3f|%d" % [data.shape, data.radius, data.length, data.width, data.side, data.sides]
	var entry: Dictionary = _mesh_cache.get(key, {})
	if entry.is_empty():
		if data.shape in SOLIDS:
			entry = _build_solid_meshes()
		else:
			# Prisms get the same neon edge outline as the solids: silhouette
			# loops at top and bottom plus the vertical corner edges.
			var mesh := ArrayMesh.new()
			var face_only := _build_prism_surface()
			face_only.commit(mesh)
			var edge_st := _edge_outline_surface(_prism_edge_segments())
			edge_st.commit(mesh)
			entry = {"mesh": mesh, "faces": face_only.commit(), "edges": edge_st.commit(),
				"top": BODY_HEIGHT}
		_mesh_cache[key] = entry
	return entry

func _prism_edge_segments() -> Array:
	var pts := _local_shape_points()
	var segs: Array = []
	var n := pts.size()
	for i in range(n):
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var at := Vector3(a.x, BODY_HEIGHT, a.y)
		var bt := Vector3(b.x, BODY_HEIGHT, b.y)
		var ab := Vector3(a.x, 0.0, a.y)
		var bb := Vector3(b.x, 0.0, b.y)
		segs.append([at, bt])
		segs.append([ab, bb])
		segs.append([at, ab])
	return segs

# Size + anchor of this enemy's health bar. The bar itself is an instance in the
# shared HealthBarField, so this only recomputes what that field reads and pushes
# the change through when a bar is already live (a decay morph resizes the body
# under an enemy that is by definition already damaged).
func _place_bar() -> void:
	# Size the bar to roughly the enemy's width so it's clearly readable
	# (a fixed tiny bar got lost against the larger 3D bodies): the 40-texel-wide
	# bar spans ~2.4 * the body radius.
	_bar_width = maxf(9.0, _radius_estimate() * 2.4)
	_bar_y = _body_top + BAR_HEIGHT_PAD
	if _bar_slot >= 0:
		_bar_field.set_metrics(_bar_slot, _bar_width, _bar_y)

# A true 3D platonic solid (or dual compound) as the body meshes. Each member is
# normalised to a circumradius of 1, scaled by data.radius, and shifted so the
# body's lowest point rests on the board (y=0). Faces are flat-shaded metallic
# (form from the key light) + a modest self-glow; edges are bright emissive
# lines that bloom — the "faceted + edge glow" style. Returns a _mesh_cache
# entry ({mesh, edges, top}); node/material assembly happens in _build_body.
func _build_solid_meshes() -> Dictionary:
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
	var lifted: Array = []
	for se in sedges:
		lifted.append([se[0] + up, se[1] + up])
	var mesh := ArrayMesh.new()
	face_st.commit(mesh)
	var edge_st := _edge_outline_surface(lifted)
	edge_st.commit(mesh)
	return {
		"mesh": mesh,
		"faces": face_st.commit(),      # LOD tier B: the same faces, no outline
		"edges": edge_st.commit(),
		"top": max_y + lift,
	}

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

# --------------------------------------------------------------- materials
# Every body material is SHARED per enemy type and never written to during play.
# The three shaders below carry the per-enemy state (hit flash, DoS frost, ECC
# scan phase, shard-FX envelope) as `instance uniform`s, which live in the
# instance's own data rather than the material (Forward+/Mobile only; the project
# is forward_plus). On the Compatibility renderer, which has no instance uniforms,
# the same shaders compile with plain uniforms and each enemy duplicates the
# shared material — see _instance_uniforms_ok / _per_enemy_material / _set_inst_param.
#
# RENDERER CAPABILITY. `instance uniform` is not merely slower elsewhere, it is a
# HARD COMPILE ERROR on the Compatibility (OpenGL) renderer:
#     SHADER ERROR: Uniform instances are not supported in gl_compatibility shaders.
# All three shaders below fail to compile there, so every enemy renders broken —
# which also breaks any future web / low-end export. So each per-instance
# declaration is written with the _INST token and expanded at Shader build time:
# "instance uniform float flash;" where instance uniforms exist, "uniform float
# flash;" where they do not. There is ONE source string per shader and only the
# qualifier differs, so the two renderers cannot drift visually.
#
# DETECTION. RenderingServer.get_rendering_device() is non-null on Forward+ and
# Mobile (both are RenderingDevice backends) and null on Compatibility. Headless
# also reports null, but headless compiles no shaders at all and
# set_instance_shader_parameter is a harmless no-op there — so headless is treated
# as CAPABLE, keeping a headless profiling run on the same path (shared materials,
# no duplicates) as the shipping game. Measured in-engine:
#     headless          -> RD null,     DisplayServer "headless"
#     gl_compatibility  -> RD null,     DisplayServer "X11"
#     Forward+          -> RD non-null
# Probed ONCE and cached: the renderer cannot change while the process runs.
#
# COLOUR SPACE. What these replace lerped an sRGB Color on the CPU (frost/flash
# tints on albedo_color and emission, and the shard's colour tween) and let Godot
# convert the RESULT to linear. So the colour uniforms here are passed RAW — no
# `source_color` hint — and every mix happens before srgb_to_lin() below. Doing
# it the other way round is a visible shift, not a rounding difference.
#
# INSTANCE-UNIFORM SLOTS. Instance uniforms are addressed by slot index, assigned
# in declaration order per shader, and the body's two surfaces sit on ONE
# MeshInstance3D — so the body and edge shaders must declare `flash` then `frost`
# first and in that order, or a write to one would land in the other's slot.
# (The fallback path addresses plain uniforms by name, so order is free there —
# but the declarations are shared source, so the rule still governs them.)
#
# CROWD VARIANT. The body shader is compiled a SECOND time for EnemyCrowdField,
# where the same three values arrive as MultiMesh per-instance custom data rather
# than per-node instance uniforms (INSTANCE_CUSTOM works on both renderer
# families, so that path needs no capability branch). It is the SAME source
# string with the same two tokens expanded differently: the declarations become
# flat varyings and _INST_V fills in the vertex() assignments that feed them.
# Every line of fragment() is therefore character-identical across all three
# expansions and the variants cannot drift visually.
const _INST := "@INST@"     # expands to "instance uniform", "uniform", or "varying flat"
const _INST_V := "@INSTV@"  # empty, or the crowd variant's INSTANCE_CUSTOM unpack
# Order matches the declaration order above it, which is also the instance-uniform
# slot order — one mapping to keep in step, not two.
const _INST_V_BODY := """flash = INSTANCE_CUSTOM.x;
	frost = INSTANCE_CUSTOM.y;
	scan_phase = INSTANCE_CUSTOM.z;"""

static var _inst_uniform_support := -1   # -1 = not probed, 0 = fallback, 1 = capable

static func _instance_uniforms_ok() -> bool:
	if _inst_uniform_support < 0:
		var headless := DisplayServer.get_name() == "headless"
		_inst_uniform_support = 1 if (headless or RenderingServer.get_rendering_device() != null) else 0
	return _inst_uniform_support == 1

const _SRGB_FN := """
vec3 srgb_to_lin(vec3 c) {
	// Matches Color::srgb_to_linear() (what a source_color uniform gets on upload).
	vec3 hi = pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4));
	vec3 lo = c * (1.0 / 12.92);
	return mix(lo, hi, step(vec3(0.04045), c));
}
"""

# One shader for every enemy body.
#
# standard_mode = 1 reproduces the plain enemy's StandardMaterial3D term for term
# (albedo, metallic 0.2, roughness 0.5, emission colour x energy gated on
# emission_enabled, and the built-in rim light at rim 0.6 / rim_tint 0.2), frost
# and flash included — those lerped the material's own albedo/emission, so they
# are reproduced in sRGB.
#
# standard_mode = 0 is the special-property body (ECC / Encrypted / both = "TLS"),
# which trades the built-in rim for an emissive Fresnel rim and adds:
#  - ECC: a horizontal emission band scanning bottom-to-top at constant speed
#    (wrapping ramp with a brief off-time between passes, not a sine slosh).
#  - Encrypted: a 2px screen-space checkerboard discard — stays in the opaque
#    pipeline (no transparency-sorting shimmer) and the opaque wireframe edges
#    show through the discarded pixels as a "revealed wireframe".
#  - both (TLS): both — the scan band is kept solid, never dithered away.
const _BODY_SHADER := """
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 body_color = vec4(1.0);
uniform float standard_mode = 1.0;
uniform float emi_on = 0.0;           // standard: emission_enabled
uniform float base_energy = 1.0;      // standard: emission_energy_multiplier
uniform float emission_energy = 0.0;  // property: baked glow energy
uniform float base_alpha = 1.0;
uniform float scan_enabled = 0.0;
uniform float scan_top = 1.0;
uniform float scan_half_width = 1.0;
uniform float scan_speed = 0.45;
uniform float scan_boost = 2.4;

@INST@ float flash;
@INST@ float frost;
@INST@ float scan_phase;

varying float v_y;
%s
void vertex() {
	v_y = VERTEX.y;
	@INSTV@
}

void fragment() {
	vec3 frost_c = vec3(0.5, 0.85, 1.0);
	float band = 0.0;
	if (scan_enabled > 0.5) {
		// Wrapping linear ramp: constant-speed sweep past both ends of the body,
		// so the band briefly disappears before the next pass — a scanline.
		float t = fract(TIME * scan_speed + scan_phase);
		float pos = mix(-scan_half_width, scan_top + scan_half_width, t);
		band = 1.0 - smoothstep(scan_half_width * 0.55, scan_half_width, abs(v_y - pos));
	}
	// Encrypted: checkerboard discard (2px cells) instead of smooth alpha.
	if (base_alpha < 0.999 && band < 0.5) {
		vec2 cell = floor(FRAGCOORD.xy / 2.0);
		if (mod(cell.x + cell.y, 2.0) < 0.5) {
			discard;
		}
	}
	METALLIC = 0.2;
	ROUGHNESS = 0.5;
	// Rim term so grazing faces pick up a halo — silhouettes separate from the
	// dark board instead of flattening into color blobs. The property body puts
	// its rim in EMISSION instead, so it takes rim 0 (no contribution).
	RIM = 0.6 * standard_mode;
	RIM_TINT = 0.2;
	if (standard_mode > 0.5) {
		ALBEDO = srgb_to_lin(mix(body_color.rgb, frost_c, frost));
		vec3 emi = mix(body_color.rgb * emi_on, frost_c, frost);
		if (flash > 0.0) {
			EMISSION = srgb_to_lin(mix(emi, vec3(1.0), flash * 0.7)) * (base_energy + flash * 2.0);
		} else {
			EMISSION = srgb_to_lin(emi) * base_energy * emi_on;
		}
	} else {
		vec3 lin = srgb_to_lin(body_color.rgb);
		ALBEDO = mix(lin, frost_c, frost);
		vec3 emis = lin * emission_energy;
		emis += lin * band * scan_boost;
		// Fresnel rim: grazing faces emit a halo that lifts the silhouette off the board.
		float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
		emis += lin * rim * 0.5;
		// Frost after the band so a frozen ECC enemy's scan frosts too; flash last so
		// a hit always reads white even through frost.
		emis = mix(emis, frost_c * emission_energy, frost);
		emis += vec3(1.0) * flash * 2.0;
		EMISSION = emis;
	}
}
"""

# Edges: unshaded emission for a crisp glowing outline. Kept modest — too bright
# and the bloom swallows the body into a formless blob. Frost/flash drive it the
# same way they drove the StandardMaterial3D this replaces.
const _EDGE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform vec4 edge_color = vec4(1.0);
uniform float base_energy = 1.2;

@INST@ float flash;
@INST@ float frost;
%s
void fragment() {
	vec3 frost_c = vec3(0.5, 0.85, 1.0);
	vec3 c = mix(edge_color.rgb, frost_c, frost);
	ALBEDO = srgb_to_lin(c);
	if (flash > 0.0) {
		EMISSION = srgb_to_lin(mix(c, vec3(1.0), flash * 0.7)) * (base_energy + flash * 2.0);
	} else {
		EMISSION = srgb_to_lin(c) * base_energy;
	}
}
"""

# Shard FX: the edge wireframe blowing outward as the enemy dies. fx_u is the
# 0..1 envelope position driven by _tick_fx, replacing the colour/energy tweens
# (the scale half stays on the node). The energy spike still peaks at a quarter
# of the way through and rides down to zero over the rest.
const _FX_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

uniform vec4 start_color = vec4(1.0);
uniform vec4 end_color = vec4(1.0);
uniform float base_energy = 1.2;
uniform float spike = 6.0;

@INST@ float fx_u;
%s
void fragment() {
	vec4 c = mix(start_color, end_color, fx_u);
	vec3 lin = srgb_to_lin(c.rgb);
	ALBEDO = lin;
	ALPHA = c.a;
	float e = fx_u < 0.25
		? mix(base_energy, spike, fx_u / 0.25)
		: mix(spike, 0.0, (fx_u - 0.25) / 0.75);
	EMISSION = lin * e;
}
"""

static var _body_shader: Shader
static var _body_crowd_shader: Shader
static var _edge_shader: Shader
static var _fx_shader: Shader
static var _body_mats: Dictionary = {}
static var _crowd_mats: Dictionary = {}
static var _edge_mats: Dictionary = {}
static var _fx_mats: Dictionary = {}

# Compile one shader from its single source string, expanding _INST to the
# qualifier this renderer accepts. Only the qualifier changes — the shader body is
# character-identical on both paths, so both renderers produce the same image.
static func _shader_of(cached: Shader, src: String) -> Shader:
	if cached != null:
		return cached
	var s := Shader.new()
	var qualifier := "instance uniform" if _instance_uniforms_ok() else "uniform"
	s.code = (src % _SRGB_FN).replace(_INST, qualifier).replace(_INST_V, "")
	return s

# The crowd expansion of that same source: per-enemy values become flat varyings
# fed from the MultiMesh instance's custom data. Only the two tokens differ, so
# this variant draws exactly what a per-node body draws.
static func _crowd_shader_of(cached: Shader, src: String, unpack: String) -> Shader:
	if cached != null:
		return cached
	var s := Shader.new()
	s.code = (src % _SRGB_FN).replace(_INST, "varying flat").replace(_INST_V, unpack)
	return s

# The material this node actually wears for one shared per-type material.
# Capable path: the shared material itself, untouched — one material per enemy
# type for the whole wave, and per-enemy state rides the instance. Fallback path:
# the shared material is only a TEMPLATE (so the Shader object and every
# type-constant uniform are still built exactly once, and the duplicate keeps the
# shader by reference), and this node gets its own copy to write per-enemy values
# into. Recorded in _own_mats, which is what _set_inst_param writes through.
func _per_enemy_material(shared: ShaderMaterial) -> ShaderMaterial:
	if _instance_uniforms_ok():
		return shared
	var own := shared.duplicate() as ShaderMaterial
	if own == null:
		return shared
	_own_mats.append(own)
	return own

# THE one write path for every per-enemy shader value (flash, frost, scan_phase,
# fx_u). Capable: a single instance-uniform write on this node's visual, materials
# never touched. Fallback: the same value by name on each material this node owns
# — both body surfaces for an enemy (the edge shader declares flash/frost too, so
# edges follow faces exactly as they do through the shared instance slots), the
# single shard material for an FX carrier. Names not present in a given shader are
# ignored by the renderer, exactly as an unused instance slot is.
# The colour uniforms are plain `vec4` (no `source_color` hint — these shaders
# do their own sRGB conversion, and the hint would convert twice). A Color
# assigned to one of those survives the immediate readback but is dropped back
# to the uniform's default once the material is resolved against the shader,
# which rendered every enemy white. Vector4 is the type-exact match and sticks.
static func _v4(c: Color) -> Vector4:
	return Vector4(c.r, c.g, c.b, c.a)

func _set_inst_param(pname: StringName, value: Variant) -> void:
	# Mirror the three body values here, on the one write path, so the crowd tier
	# can hand the SAME numbers to its instance data — it cannot read them back off
	# _body. An FX carrier only ever writes fx_u, which falls through.
	match pname:
		&"flash":
			_flash_inst = float(value)
		&"frost":
			_frost_inst = float(value)
		&"scan_phase":
			_scan_inst = float(value)
	if _instance_uniforms_ok():
		var gi: GeometryInstance3D = _fx_mi if _is_fx else _body
		if gi != null:
			gi.set_instance_shader_parameter(pname, value)
		return
	for m in _own_mats:
		m.set_shader_parameter(pname, value)

# Everything the body/edge materials read that is constant for an enemy type:
# geometry (the scan band is tuned to the body height), colour, glow and the
# property flags. Equal keys therefore always mean an identical material.
func _type_key() -> String:
	return "%s|%.3f|%.3f|%.3f|%.3f|%d|%d|%.3f|%d|%d" % [data.shape, data.radius,
		data.length, data.width, data.side, data.sides, data.color.to_rgba32(),
		data.glow, int(data.ecc), int(data.encrypted)]

func _body_material() -> ShaderMaterial:
	var key := _type_key()
	var cached: ShaderMaterial = _body_mats.get(key)
	if cached != null:
		return cached
	_body_shader = _shader_of(_body_shader, _BODY_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _body_shader
	_body_uniforms(m)
	_body_mats[key] = m
	return m

# The crowd field's material for this enemy type: the SAME type-constant uniforms
# on the crowd expansion of the same shader, so a body that drops into the tier
# only changes which draw call carries it. One per type key, like the body one.
func _crowd_material() -> ShaderMaterial:
	var key := _type_key()
	var cached: ShaderMaterial = _crowd_mats.get(key)
	if cached != null:
		return cached
	_body_crowd_shader = _crowd_shader_of(_body_crowd_shader, _BODY_SHADER, _INST_V_BODY)
	var m := ShaderMaterial.new()
	m.shader = _body_crowd_shader
	_body_uniforms(m)
	_crowd_mats[key] = m
	return m

# Everything constant for an enemy type, written to either expansion of the body
# shader from ONE place — the two materials cannot fall out of step.
func _body_uniforms(m: ShaderMaterial) -> void:
	var glowing := data.glow > 0.0
	var energy := 0.0
	if glowing:
		energy = 0.3 + data.glow * 0.25
	m.set_shader_parameter("body_color", _v4(data.color))
	m.set_shader_parameter("standard_mode", 0.0 if (data.ecc or data.encrypted) else 1.0)
	# emission_enabled / emission_energy_multiplier of the StandardMaterial3D this
	# stands in for: with no glow the material had emission off and the untouched
	# default multiplier of 1.0, which the flash path still reads.
	m.set_shader_parameter("emi_on", 1.0 if glowing else 0.0)
	m.set_shader_parameter("base_energy", energy if glowing else 1.0)
	m.set_shader_parameter("emission_energy", energy)
	# Encrypted: base_alpha < 1 gates the checkerboard discard (the opaque edge
	# wireframe then reads through the discarded pixels).
	m.set_shader_parameter("base_alpha", 0.4 if data.encrypted else 1.0)
	m.set_shader_parameter("scan_enabled", 1.0 if data.ecc else 0.0)
	# ECC scan band ramps across the full [0, _body_top] span; half-width
	# 0.15 * height keeps it a line even on short bodies.
	var top: float = maxf(_body_top, 0.001)
	m.set_shader_parameter("scan_top", top)
	m.set_shader_parameter("scan_half_width", top * 0.15)

func _edge_material() -> ShaderMaterial:
	var bright: Color = data.color.lightened(0.3)
	var energy: float = 1.2 + data.glow * 0.4
	var key := "%d|%.3f" % [bright.to_rgba32(), energy]
	var cached: ShaderMaterial = _edge_mats.get(key)
	if cached != null:
		return cached
	_edge_shader = _shader_of(_edge_shader, _EDGE_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _edge_shader
	m.set_shader_parameter("edge_color", _v4(bright))
	m.set_shader_parameter("base_energy", energy)
	_edge_mats[key] = m
	return m

# Shard material for one (tint, spike) variation of the edge look. Deterministic
# per colour pair, so death shatters and goal leaks each collapse to one material
# per enemy type.
func _shard_material(tint: Color, spike: float) -> ShaderMaterial:
	var bright: Color = data.color.lightened(0.3)
	var energy: float = 1.2 + data.glow * 0.4
	var fade := Color(tint.r, tint.g, tint.b, 0.0)
	var key := "%d|%d|%.3f|%.3f" % [bright.to_rgba32(), fade.to_rgba32(), energy, spike]
	var cached: ShaderMaterial = _fx_mats.get(key)
	if cached != null:
		return cached
	_fx_shader = _shader_of(_fx_shader, _FX_SHADER)
	var m := ShaderMaterial.new()
	m.shader = _fx_shader
	m.set_shader_parameter("start_color", _v4(bright))
	m.set_shader_parameter("end_color", _v4(fade))
	m.set_shader_parameter("base_energy", energy)
	m.set_shader_parameter("spike", spike)
	_fx_mats[key] = m
	return m

# Edge outline as slim 4-sided prisms instead of 1px hardware lines: edge weight
# scales with enemy size (half-width from the body radius), anti-aliases as real
# geometry, and gives the bloom actual coverage. ~8 tris per edge — worst case
# (dodeca_icosahedron, ~90 edges) is still trivial, built once per _mesh_cache
# key and shared from then on. Returns the SurfaceTool so the caller can commit
# it twice: once as surface 1 of the merged body mesh, once as the standalone
# edges mesh the shard FX draws.
func _edge_outline_surface(segs: Array) -> SurfaceTool:
	var hw := clampf(_radius_estimate() * 0.03, 0.05, 0.12)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for se in segs:
		_emit_edge_prism(st, se[0], se[1], hw)
	return st

func _emit_edge_prism(st: SurfaceTool, a: Vector3, b: Vector3, hw: float) -> void:
	var axis := b - a
	if axis.length() < 0.0001:
		return
	var dir := axis.normalized()
	var ref := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var u := dir.cross(ref).normalized() * hw
	var w := dir.cross(u).normalized() * hw
	var offs := [u + w, u - w, -u - w, -u + w]
	for i in range(4):
		var o1: Vector3 = offs[i]
		var o2: Vector3 = offs[(i + 1) % 4]
		st.add_vertex(a + o1); st.add_vertex(a + o2); st.add_vertex(b + o2)
		st.add_vertex(a + o1); st.add_vertex(b + o2); st.add_vertex(b + o1)

# Extrude the 2D silhouette into a prism (legacy non-solid shapes). Winding
# mirrors GameBoard3D._add_prism (top cap + outward side walls).
func _build_prism_surface() -> SurfaceTool:
	var pts := _local_shape_points()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)   # flat facets, so the body's edges stay crisp
	_emit_prism(st, pts, BODY_HEIGHT, 0.0)
	st.generate_normals()
	return st

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

# Local (un-rotated) shape, in plane coords. Heading is applied via the _body yaw.
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
	# While the crowd field is drawing this enemy, _body is hidden and its
	# transform reaches nothing — the yaw goes into the instance buffer instead.
	# Writing it anyway would do the same work twice per enemy per frame.
	if _crowd_slot >= 0:
		return
	# Both terms are rotations about Y, so summing them is exactly what the old
	# heading node + spin child composed to.
	_body.rotation = Vector3(0.0, -heading + _spin_angle, 0.0)

# --------------------------------------------------------------- per-frame
func _process(delta: float) -> void:
	if _is_fx:
		_tick_fx(delta)
		return
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
	cell = HexUtils.pixel_to_cell(pp - _grid_origin, GameBoard3D.HEX_SIZE)
	if ((lod_frame + _lod_phase) & LOD_TEST_MASK) == 0:
		_update_lod()
	# Display-only motion: hover bob and a slow idle spin for the platonic solids,
	# both on _body (pp and the bar are untouched). The spin is advanced before the
	# yaw is written, since the two now share one rotation. Both are skipped in the
	# reduced tier, where the bob travels well under a pixel and the spin cannot be
	# read off a shape that small.
	if _spins and not _lod_reduced:
		_spin_angle += delta * SPIN_RATE
	_sync_transform()
	if not _lod_reduced:
		_bob_time += delta
		_body.position.y = sin(_bob_time * BOB_RATE + _bob_phase) * BOB_AMPLITUDE
	elif _crowd_slot >= 0:
		_push_crowd()

# Pick the detail tier from this enemy's APPARENT SIZE. lod_k folds the camera's
# FOV and the viewport height together (set once per frame by Main3D), so the test
# is one distance and one multiply per enemy; the swap itself only happens on a
# threshold crossing.
func _update_lod() -> void:
	if lod_k <= 0.0 or _body == null:
		return
	# Distance from `pp` rather than global_position: the world position is
	# derived from pp anyway, and reading global_position forces a transform sync.
	var dx: float = lod_cam_pos.x - pp.x
	var dy: float = lod_cam_pos.y - GameBoard3D.ENEMY_Y
	var dz: float = lod_cam_pos.z - pp.y
	var d: float = maxf(1.0, sqrt(dx * dx + dy * dy + dz * dz))
	var px: float = hit_radius * lod_k / d
	# Buried in a pile counts the same as being tiny: the detail cannot be seen.
	var buried := not crowd_lead and crowd >= LOD_CROWD_MIN
	if _lod_reduced:
		if px > LOD_RESTORE_PX and (crowd_lead or crowd <= LOD_CROWD_CLEAR):
			_apply_lod(false)
	elif px < LOD_DROP_PX or buried:
		_apply_lod(true)

# Swap between the shared full and faces-only meshes. Both come from the same
# cache entry and the materials are re-pointed rather than rebuilt, so a crossing
# costs a mesh assignment and at most one material lookup — never a body rebuild.
func _apply_lod(reduced: bool) -> void:
	if reduced == _lod_reduced or _body == null:
		return
	_lod_reduced = reduced
	var entry: Dictionary = _shared_meshes()
	var m: ArrayMesh = entry["faces"] if reduced else entry["mesh"]
	_body.mesh = m
	if reduced:
		# Freeze the hover at rest so the shape cannot sit at an odd height while
		# the bob is not being advanced.
		_body.position.y = 0.0
	if m.get_surface_count() > 0 and _mat_body != null:
		_body.set_surface_override_material(0, _mat_body)
	if m.get_surface_count() > 1:
		# A morph that happened while reduced never took an edge material.
		if _mat_edge == null:
			_mat_edge = _per_enemy_material(_edge_material())
		_body.set_surface_override_material(1, _mat_edge)
	# The reduced body is drawn as one instance in its type's EnemyCrowdField, so
	# this node must stop drawing or the shape renders twice. _body keeps its mesh
	# and materials either way, so coming back is still a re-point of nothing.
	# Hidden only once a slot is actually held: a field that could not be reached
	# leaves the node drawing itself rather than leaving an invisible enemy.
	if reduced:
		_acquire_crowd()
	else:
		_release_crowd()
	_body.visible = _crowd_slot < 0

# --------------------------------------------------------------- crowd rendering
# The reduced tier as MultiMesh instances: every reduced body of one enemy type
# shares that type's faces-only mesh and one crowd material, so the whole crowd
# collapses to about one draw call per type. VISUAL ONLY — this holds a slot and
# pushes a transform, and touches nothing the towers read.
func _acquire_crowd() -> void:
	if _crowd_slot >= 0 or _body == null:
		return
	# _apply_lod only runs from _process and a morph only from a live hit, so the
	# enemy is in-tree here; a spawn (which builds at full tier) never reaches this.
	var parent := get_parent()
	if parent == null:
		return
	var entry: Dictionary = _shared_meshes()
	var faces: ArrayMesh = entry["faces"]
	_crowd_field = EnemyCrowdField.for_type(parent, _type_key(), faces, _crowd_material())
	if _crowd_field == null:
		return
	_crowd_slot = _crowd_field.acquire(self, _crowd_xform(), _flash_inst, _frost_inst, _scan_inst)

func _release_crowd() -> void:
	if _crowd_slot < 0:
		return
	if _crowd_field != null and is_instance_valid(_crowd_field):
		_crowd_field.release(_crowd_slot)
	_crowd_slot = -1
	_crowd_field = null

func _push_crowd() -> void:
	if _crowd_field == null or not is_instance_valid(_crowd_field):
		return
	_crowd_field.set_instance(_crowd_slot, _crowd_xform(), _flash_inst, _frost_inst, _scan_inst)

# What _body would have rendered, composed rather than read back: reading
# global_transform forces a transform sync per enemy, and every part is already
# here. The root carries nothing but the pp position (no rotation, no scale) and
# the field is a sibling of the enemies, so this is exactly _body's own local
# offset, yaw and pop scale over that position. In this tier the bob is frozen at
# 0 and the spin is not advanced, so the only mover left is pp. The pop scale is
# uniform (Vector3.ONE * k), which is why scaled() stands in for the local-space
# scale Node3D would apply.
func _crowd_xform() -> Transform3D:
	# Built term by term rather than via Basis(axis, angle) + scaled(): the
	# rotation is about Y only, so it is two trig calls and a uniform scale, and
	# this runs per crowd enemy per frame.
	var a: float = -heading + _spin_angle
	var k: float = _body.scale.x
	var c: float = cos(a) * k
	var sn: float = sin(a) * k
	var b := Basis(Vector3(c, 0.0, -sn), Vector3(0.0, k, 0.0), Vector3(sn, 0.0, c))
	return Transform3D(b, Vector3(pp.x, GameBoard3D.ENEMY_Y + _body.position.y, pp.y))

# Called by EnemyCrowdField when a swap-remove moves this enemy's instance.
func set_crowd_slot(i: int) -> void:
	_crowd_slot = i

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
	# Early-out for the common idle case: no freeze/slow/flash pending AND the
	# visuals already restored. The churn guards sit at exactly 0.0 only after
	# _apply_status_visual wrote the restored baseline (they start at -1.0 on
	# every body rebuild), so this check can never skip a needed restore.
	if _freeze_time <= 0.0 and _slow_time <= 0.0 and _flash == 0.0 \
			and _dos_vis_k == 0.0 and _flash_vis == 0.0:
		return
	if _freeze_time > 0.0:
		_freeze_time -= delta
	elif _slow_time > 0.0:
		_slow_time -= delta
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * HIT_FLASH_RATE)
	_apply_status_visual()

# Frost (icy lerp while frozen/slowed) + hit flash (toward white with an energy
# boost past the bloom threshold), restored when both lapse. Two per-enemy writes
# through _set_inst_param — instance uniforms on the body where they exist (the
# shared per-type materials are never touched), this enemy's own duplicated
# materials otherwise — and churn-guarded: nothing is written while both strengths
# are unchanged. Surfaces 0 and 1 both read flash/frost, so edges follow faces.
func _apply_status_visual() -> void:
	var k := 0.0
	if _freeze_time > 0.0:
		k = 0.85
	elif _slow_time > 0.0:
		k = 0.5
	if is_equal_approx(k, _dos_vis_k) and is_equal_approx(_flash, _flash_vis):
		return
	_dos_vis_k = k
	_flash_vis = _flash
	if _body == null:
		return
	_set_inst_param(&"frost", k)
	_set_inst_param(&"flash", _flash)

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
	_flash = 1.0
	_refresh_bar(health / data.health)
	return false

# AudioManager autoload, resolved once and shared (the per-death absolute-path
# lookup showed up in profiles); re-resolved only if the cached node was freed.
static var _am_cached: Node = null

func _on_depleted(carry := 0.0, pierces_ecc := false) -> void:
	if _am_cached == null or not is_instance_valid(_am_cached):
		_am_cached = get_node_or_null("/root/AudioManager")
	var am := _am_cached
	if am:
		# A decay stage degrades rather than dies: it gets the split blip, so a
		# 3-stage chain doesn't replay the same death sound three times. The
		# (data-driven) death sound is saved for the final kill.
		am.play_sfx("enemy_split" if data.reduces_to != null else data.death_sound)
	bounty.emit(data.reward)
	var lesser: EnemyData = data.reduces_to
	if lesser == null:
		_alive = false
		_release_bar()
		_release_crowd()
		# Shatter: the edge wireframe blows outward and blooms, then fades.
		_spawn_shard_fx(Vector3.ONE * 1.6, 0.3, data.color.lightened(0.3), 6.0)
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
	_refresh_bar(1.0)
	# Punch the morphed body in + a white flash so the decay reads as a split,
	# not a glitch. Split children pop in via setup()'s spawn animation.
	_flash = 1.0
	_pop_body(1.45, 0.2)
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
	cell = HexUtils.pixel_to_cell(pp - _grid_origin, GameBoard3D.HEX_SIZE)
	if seg + 1 < path_points.size():
		heading = (path_points[seg + 1] - pos).angle()
	_sync_transform()

func _reach_goal() -> void:
	_alive = false
	_release_bar()
	_release_crowd()
	# Life loss is immediate — only the visual lingers behind the free below.
	reached_goal.emit()
	# Sucked-into-the-port: vertical stretch, tinted toward the goal marker's red.
	_spawn_shard_fx(Vector3(0.05, 1.4, 0.05), 0.25, GameBoard3D.GOAL_COLOR, 3.0)
	queue_free()

# Punch-in on _body (display only — pp-based hit logic and the billboarded bar
# are untouched). Shared by spawn-in, split children, and the decay morph.
# Spawners call setup() before add_child, so outside the tree the tween is
# deferred to _ready (the body just starts at from_scale until then).
func _pop_body(from_scale: float, duration: float) -> void:
	if _body == null:
		return
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_body.scale = Vector3.ONE * from_scale
	if not is_inside_tree():
		_pending_pop = duration
		return
	_pending_pop = 0.0
	_start_pop_tween(duration)

func _ready() -> void:
	if _pending_pop > 0.0:
		_start_pop_tween(_pending_pop)
		_pending_pop = 0.0

func _start_pop_tween(duration: float) -> void:
	_pop_tween = create_tween()
	_pop_tween.tween_property(_body, "scale", Vector3.ONE, duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

# --------------------------------------------------------------- shard FX
# One-shot detached copy of the edge wireframe, animated in the parent and
# released. The death shatter (scale out, emission spike) and the goal-leak
# suck-in (vertical stretch, goal-red tint) are parameter variations of this;
# the enemy node itself can free immediately.
#
# The carrier is a POOLED MeshInstance3D wearing this script, which is the only
# way it can run its own envelope: with the enemy gone there is nobody left to
# tick it, and a per-FX Tween is exactly what this replaces. _is_fx is set before
# it ever enters the tree and never cleared, so such a node can never fall into
# an enemy code path.
static var _fx_frame := -1
static var _fx_spawned := 0

func _spawn_shard_fx(target_scale: Vector3, duration: float, tint: Color, spike: float) -> void:
	if _body == null or _edges_mesh == null or not is_inside_tree():
		return
	var parent := get_parent()
	if parent == null:
		return
	# GameBoard3D.add_enemy parents enemies under the board's entity holder, so the
	# board (which owns the free list) is one hop above this node's parent.
	var bd = parent.get_parent()
	if bd == null or not bd.has_method("pool_take"):
		return
	var frame: int = Engine.get_process_frames()
	if frame != _fx_frame:
		_fx_frame = frame
		_fx_spawned = 0
	if _fx_spawned >= DEATH_FX_PER_FRAME:
		return   # mass wipe: this death is silent, everything else about it is normal
	_fx_spawned += 1
	var shard = bd.pool_take(FX_POOL_KEY)   # untyped: a MeshInstance3D wearing this script
	if shard == null:
		var mi := MeshInstance3D.new()
		mi.set_script(get_script())
		shard = mi
	shard._fx_begin(parent, _body.global_transform, _edges_mesh,
		_shard_material(tint, spike), target_scale, duration, bd)

# Arm this node as a shard FX and put it on screen. Everything the previous life
# left behind is overwritten here — the pool guarantees nothing else.
func _fx_begin(parent: Node, at: Transform3D, mesh_ref: ArrayMesh, mat: Material,
		target_scale: Vector3, duration: float, bd) -> void:
	_is_fx = true
	_fx_mi = _as_mesh_instance()
	if _fx_mi == null:
		return
	_fx_t = 0.0
	_fx_duration = maxf(duration, 0.0001)
	_fx_board = bd
	_fx_mi.mesh = mesh_ref
	# The shard material is shared per (tint, spike) exactly like the body ones, so
	# on the fallback path this carrier needs its own copy to hold fx_u. Whatever a
	# previous life left in _own_mats is dropped here — the pool guarantees nothing.
	_own_mats.clear()
	var use_mat: Material = mat
	if not _instance_uniforms_ok() and mat is ShaderMaterial:
		var own := mat.duplicate() as ShaderMaterial
		if own != null:
			_own_mats.append(own)
			use_mat = own
	_fx_mi.material_override = use_mat
	# One-shot glow FX — like the outline it copies, it never casts a shadow.
	_fx_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_set_inst_param(&"fx_u", 0.0)
	_fx_mi.visible = true
	parent.add_child(_fx_mi)
	_fx_mi.global_transform = at
	_fx_start_scale = _fx_mi.scale
	_fx_end_scale = _fx_start_scale * target_scale
	_fx_mi.set_process(true)

# The FX carrier is a MeshInstance3D even though this script extends Node3D, so
# `self` has to be re-typed through Node to expose the mesh API. Null on an enemy.
func _as_mesh_instance() -> MeshInstance3D:
	var me: Node = self
	return me as MeshInstance3D

# The envelope the two per-FX Tweens used to run: cubic ease-out on the scale,
# linear on the colour/energy ramp (that half rides fx_u, via _set_inst_param).
# Driven by the process delta, so it still tracks Engine.time_scale exactly.
func _tick_fx(delta: float) -> void:
	if _fx_duration <= 0.0 or _fx_mi == null:
		return
	_fx_t += delta
	var u: float = clampf(_fx_t / _fx_duration, 0.0, 1.0)
	_fx_mi.scale = _fx_start_scale.lerp(_fx_end_scale, 1.0 - pow(1.0 - u, 3.0))
	_set_inst_param(&"fx_u", u)
	if _fx_t >= _fx_duration:
		_release_fx()

func _release_fx() -> void:
	_fx_duration = 0.0
	_fx_t = 0.0
	var bd = _fx_board
	_fx_board = null
	if _fx_mi != null:
		# Drop the shared mesh/material so a parked carrier holds nothing and draws
		# nothing; _fx_begin re-points both on the next life. The envelope is reset
		# before the material goes, so the instance slot (capable path) is left clean
		# for the next life exactly as it was.
		_set_inst_param(&"fx_u", 0.0)
		_fx_mi.mesh = null
		_fx_mi.material_override = null
		_own_mats.clear()
	if bd != null and is_instance_valid(bd):
		bd.pool_put(FX_POOL_KEY, self)
	else:
		queue_free()

# --------------------------------------------------------------- health bar
# The bar is ONE instance in the board-wide HealthBarField (a single MultiMesh
# draw call for the whole wave) instead of a per-enemy billboarded Sprite3D. Only
# DAMAGED enemies hold an instance: at full health the slot is released, so a
# wave nobody has hit yet costs nothing and stays clutter-free — the same read
# the hidden sprite gave. The frame / track / fill ramp all live in the field's
# shader now; this side owns nothing but the fraction, size and anchor.
#
# The field is looked up from this enemy's own parent (the board's entity holder)
# and so is freed with the board — there is nothing to leak across a scene change.
func _refresh_bar(frac: float) -> void:
	var f := clampf(frac, 0.0, 1.0)
	if f >= 0.999:
		_release_bar()
		return
	if _bar_slot < 0:
		_acquire_bar(f)
		return
	_bar_field.set_fraction(_bar_slot, f)

func _acquire_bar(f: float) -> void:
	# setup() runs before add_child, so a spawn has no parent yet — but it also
	# spawns at full health, and the first damage always lands in-tree.
	var parent := get_parent()
	if parent == null:
		return
	_bar_field = HealthBarField.for_parent(parent)
	if _bar_field == null:
		return
	_bar_slot = _bar_field.acquire(self, _bar_width, _bar_y, f)

func _release_bar() -> void:
	if _bar_slot < 0:
		return
	if _bar_field != null and is_instance_valid(_bar_field):
		_bar_field.release(_bar_slot)
	_bar_slot = -1

# Called by HealthBarField when a swap-remove moves this enemy's instance.
func set_bar_slot(i: int) -> void:
	_bar_slot = i
