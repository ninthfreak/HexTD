class_name GameBoard3D
extends Node3D
## 3D version of the board. All hex math, footprint/LOS/range, and the copper
## clip-tile selection are ported UNCHANGED from the 2D GameBoard — they operate
## on PLANE coordinates (Vector2). The plane maps to 3D as (x, y) -> (x, 0, y),
## so world y is height/up. Rendering is generated prism meshes instead of 2D
## draw calls; materials are real metallic copper + clearcoat solder mask so the
## finish reflects the environment dynamically.
##
## Entities (towers/enemies/projectiles) are Node3D and keep a 2D `pp` (plane
## position) for all logic, syncing their 3D transform for display.

const HEX_SIZE := 11.34
## Dark neon / digital-grid theme. The board is a near-black glossy reflective
## substrate; the path "trace", spawn and goal are emissive neon so the HDR glow
## blooms them and the dark floor mirrors them (SSR).
const TRACE_COLOR := Color(0.15, 0.85, 1.00)   # neon cyan path edge (emissive)
const MASK_COLOR := Color(0.42, 0.16, 0.40)    # purple-pink build plateau (dim glow)
const SPAWN_COLOR := Color(0.20, 1.00, 0.45)   # neon green
const GOAL_COLOR := Color(1.00, 0.35, 0.30)    # neon red
const WALL_COLOR := Color(0.09, 0.10, 0.15)    # dark obstacle (faint red rim)

# Heights (world units). The build area is a raised plateau at COPPER_TOP (the
# shared placement plane — towers, ray-picking and overlays all anchor here, so
# that constant is unchanged); the PATH is carved BELOW it, a sunken glossy
# channel whose side walls (rising from PATH_TOP up to the plateau rim) carry the
# neon edge glow. Enemies travel along the sunken floor. Blocking walls stand
# above the plateau.
const MASK_TOP := 0.0
const MASK_THICK := 6.0
const COPPER_TOP := 1.2         # build plateau top = placement plane (towers/picking/overlays)
const PATH_TOP := -2.0          # sunken path floor (glossy black); enemies travel here
const WALL_TOP := 4.2           # blocking walls stand above the plateau
const ENEMY_Y := COPPER_TOP + 5.5   # enemies hover this high (above the plateau; shadow sells the gap)
const RIM_WIDTH := 1.8          # width of the flat neon border strip along the path rim

## Copper clip tiles — identical rule to the 2D board (see that file for the full
## explanation). 0=NE,1=SE,2=S,3=SW,4=NW,5=N.
const TILE_OMIT := {
	"CORNER_N": [5], "CORNER_S": [2], "CORNER_NE": [0], "CORNER_SE": [1], "CORNER_SW": [3], "CORNER_NW": [4],
	"HALF_E": [0, 1], "HALF_W": [3, 4], "HALF_NE": [0, 5], "HALF_SW": [2, 3],
	"HALF_NW": [4, 5], "HALF_SE": [1, 2],
}
const EDGE_NB := [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]
const HALF_TILE := {0: "HALF_E", 1: "HALF_SE", 2: "HALF_SW", 3: "HALF_W", 4: "HALF_NW", 5: "HALF_NE"}
const POINT_TILE := {5: "CORNER_N", 0: "CORNER_NE", 1: "CORNER_SE", 2: "CORNER_S", 3: "CORNER_SW", 4: "CORNER_NW"}
const FOOTPRINT_DIRS := [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1),
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]
const FOOTPRINT_RADIUS := 1
const TOWER_RADIUS := HEX_SIZE * 1.7320508075688772

var origin := Vector2(0, 0)
var map: HexMapData
var path_pixels := PackedVector2Array()   # smoothed path, PLANE coords
var occupied := {}
var blocking_set := {}
var trace_set := {}
var buildable_set := {}
var enemies: Array = []
var _bounds := Rect2()
var _entities: Node3D

var _mat_copper: StandardMaterial3D
var _mat_copper_edge: StandardMaterial3D
var _mat_mask: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_spawn: StandardMaterial3D
var _mat_goal: StandardMaterial3D
var _mesh_root: Node3D

func _ready() -> void:
	_build_materials()
	_entities = Node3D.new()
	add_child(_entities)

func _build_materials() -> void:
	# Dark neon theme. Back-face culling disabled on every board material (flat
	# board viewed from above — removes any winding fragility).
	#
	# The path is a sunken channel of glossy polished-black floor AND walls (so the
	# whole trench is one dark mirror that reflects the enemies/neon via SSR). The
	# neon border is a separate FLAT emissive strip laid along the top rim (see
	# _add_path_walls): a flat strip reads consistently from above on every edge,
	# unlike the vertical walls (which only showed glow where they faced the
	# camera). Floor+walls = _mat_copper (glossy black); rim strip = _mat_copper_edge.
	_mat_copper = StandardMaterial3D.new()
	_mat_copper.albedo_color = Color(0.01, 0.012, 0.015)
	_mat_copper.metallic = 0.95
	_mat_copper.roughness = 0.04            # sharp mirror reflections
	_mat_copper.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Trench side walls: the neon edge that outlines the sunken path.
	_mat_copper_edge = StandardMaterial3D.new()
	_mat_copper_edge.albedo_color = TRACE_COLOR.darkened(0.7)
	_mat_copper_edge.emission_enabled = true
	_mat_copper_edge.emission = TRACE_COLOR
	_mat_copper_edge.emission_energy_multiplier = 2.2
	_mat_copper_edge.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Build plateau: purple-pink with a VERY DIM self-glow (emission < 1 so it
	# reads as faintly lit but does not bloom), lightly glossy so it still catches
	# the key light and a little reflection.
	_mat_mask = StandardMaterial3D.new()
	_mat_mask.albedo_color = MASK_COLOR
	_mat_mask.metallic = 0.3
	_mat_mask.roughness = 0.42
	_mat_mask.emission_enabled = true
	_mat_mask.emission = Color(0.85, 0.35, 0.75)
	_mat_mask.emission_energy_multiplier = 0.18
	_mat_mask.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Walls: dark obstacles with a faint red rim glow (a hazard cue), not bloomed.
	_mat_wall = StandardMaterial3D.new()
	_mat_wall.albedo_color = WALL_COLOR
	_mat_wall.metallic = 0.4
	_mat_wall.roughness = 0.4
	_mat_wall.emission_enabled = true
	_mat_wall.emission = Color(0.9, 0.15, 0.25)
	_mat_wall.emission_energy_multiplier = 0.45
	_mat_wall.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_spawn = _emissive_mat(SPAWN_COLOR)
	_mat_goal = _emissive_mat(GOAL_COLOR)

# A bright emissive marker material (spawn / goal), bloomed by the HDR glow.
func _emissive_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.darkened(0.5)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func setup(m: HexMapData) -> void:
	map = m
	blocking_set = {}
	for cell in m.blocking:
		blocking_set[cell] = true
	trace_set = {}
	for cell in m.trace:
		trace_set[cell] = true
	buildable_set = {}
	for cell in m.buildable:
		buildable_set[cell] = true
	var raw := PackedVector2Array()
	for cell in m.path:
		raw.append(_cell_to_pixel(cell))
	path_pixels = _smooth_path(raw)
	_compute_bounds()
	_build_board_meshes()

# ---------------------------------------------------------------- 3D meshes
func _build_board_meshes() -> void:
	if _mesh_root != null and is_instance_valid(_mesh_root):
		_mesh_root.queue_free()
	_mesh_root = Node3D.new()
	add_child(_mesh_root)

	# Two levels. The BUILD PLATEAU (every non-path cell) is a FULL-HEX cap at
	# COPPER_TOP — full hexes so buildable cells stay unambiguous. The PATH is a
	# sunken, SMOOTH ribbon: each path cell's floor is the clipped polygon (the
	# 2D copper clip rule, smoothing the trace silhouette) dropped to PATH_TOP,
	# and the corners clipped OFF each path cell are filled back in at COPPER_TOP
	# as plateau slivers — so the plateau reads as one continuous surface with a
	# smooth inner edge along the path, without rounding the build hexes. Trench
	# walls (clipped boundary, PATH_TOP up to the rim) carry the neon glow.
	# Flat shading (smooth group -1) + generate_normals gives each face its own
	# normal without averaging.
	var plateau_st := SurfaceTool.new(); plateau_st.begin(Mesh.PRIMITIVE_TRIANGLES); plateau_st.set_smooth_group(-1)
	var spawn_st := SurfaceTool.new(); spawn_st.begin(Mesh.PRIMITIVE_TRIANGLES); spawn_st.set_smooth_group(-1)
	var goal_st := SurfaceTool.new(); goal_st.begin(Mesh.PRIMITIVE_TRIANGLES); goal_st.set_smooth_group(-1)
	var wall_st := SurfaceTool.new(); wall_st.begin(Mesh.PRIMITIVE_TRIANGLES); wall_st.set_smooth_group(-1)
	var path_st := SurfaceTool.new(); path_st.begin(Mesh.PRIMITIVE_TRIANGLES); path_st.set_smooth_group(-1)
	var edge_st := SurfaceTool.new(); edge_st.begin(Mesh.PRIMITIVE_TRIANGLES); edge_st.set_smooth_group(-1)
	var have_spawn := false
	var have_goal := false
	var have_wall := false
	var have_path := false

	for cell in map.cells:
		var c := _cell_to_pixel(cell)
		var hex := _hex_plane_polygon(c)
		if _is_path_cell(cell):
			# smooth sunken ribbon floor (clip the TRACE region, as in 2D)
			var poly := _clipped_plane_polygon(cell, c, trace_set)
			if poly.size() >= 3:
				if cell == map.spawn:
					_add_cap(spawn_st, poly, PATH_TOP + 0.05); have_spawn = true
				elif cell == map.goal:
					_add_cap(goal_st, poly, PATH_TOP + 0.05); have_goal = true
				else:
					_add_cap(path_st, poly, PATH_TOP)
				_add_path_walls(path_st, edge_st, c, poly)
				have_path = true
			# fill the clipped-off corner(s) at plateau level so the plateau stays
			# continuous (and full-hex everywhere except this smooth path edge)
			var omit: Array = TILE_OMIT.get(_clip_tile(cell, trace_set), [])
			if not omit.is_empty():
				_add_clip_slivers(plateau_st, hex, omit, COPPER_TOP)
		elif blocking_set.has(cell):
			_add_prism(wall_st, hex, WALL_TOP, PATH_TOP); have_wall = true
		else:
			_add_cap(plateau_st, hex, COPPER_TOP)   # full-hex build plateau
			_add_plateau_skirt(plateau_st, c, hex)  # solid sides at the board's outer rim

	_commit(plateau_st, _mat_mask)
	if have_spawn: _commit(spawn_st, _mat_spawn)
	if have_goal: _commit(goal_st, _mat_goal)
	if have_wall: _commit(wall_st, _mat_wall, true)   # walls cast shadows (depth)
	if have_path:
		_commit(path_st, _mat_copper, true)              # glossy black floor + trench walls
		_commit(edge_st, _mat_copper_edge)               # flat neon rim border

func _is_path_cell(cell: Vector2i) -> bool:
	return trace_set.has(cell) or cell == map.spawn or cell == map.goal

# For each clipped-floor edge of a path cell that borders a non-path cell, add a
# glossy-black trench WALL (into `black_st`, PATH_TOP up to the plateau rim) and a
# flat emissive RIM strip (into `rim_st`, on the plateau just above COPPER_TOP,
# extending RIM_WIDTH outward from the edge). The rim is the neon border — flat,
# so it reads consistently from above on every edge. Boundary detection probes
# just outside the edge midpoint: a path neighbour means an internal edge (no wall
# or rim, channel stays continuous); otherwise it gets both.
func _add_path_walls(black_st: SurfaceTool, rim_st: SurfaceTool, center: Vector2, poly: PackedVector2Array) -> void:
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var mid: Vector2 = (a + b) * 0.5
		var outward: Vector2 = mid - center
		if outward.length() < 0.0001:
			continue
		var probe: Vector2 = mid + outward.normalized() * (HEX_SIZE * 0.5)
		if _is_path_cell(world_cell(probe)):
			continue   # internal edge shared with a path neighbour
		# glossy-black trench wall (rim down to floor)
		var at := Vector3(a.x, COPPER_TOP, a.y)
		var bt := Vector3(b.x, COPPER_TOP, b.y)
		var ab := Vector3(a.x, PATH_TOP, a.y)
		var bb := Vector3(b.x, PATH_TOP, b.y)
		black_st.add_vertex(at); black_st.add_vertex(bb); black_st.add_vertex(ab)
		black_st.add_vertex(at); black_st.add_vertex(bt); black_st.add_vertex(bb)
		# flat neon rim strip on the plateau, just proud of the cap to avoid z-fight.
		# Endpoints are extended along the edge by RIM_WIDTH so neighbouring strips
		# OVERLAP at the corners (closing the wedge gaps that made the border look
		# dashed). Overlapping coplanar same-colour quads show no artifact.
		var dir: Vector2 = b - a
		if dir.length() < 0.0001:
			continue
		dir = dir.normalized()
		var nrm := Vector2(-dir.y, dir.x)
		if nrm.dot(outward) < 0.0:
			nrm = -nrm
		var a2: Vector2 = a - dir * RIM_WIDTH
		var b2: Vector2 = b + dir * RIM_WIDTH
		var ao: Vector2 = a2 + nrm * RIM_WIDTH
		var bo: Vector2 = b2 + nrm * RIM_WIDTH
		var ry := COPPER_TOP + 0.05
		rim_st.add_vertex(Vector3(a2.x, ry, a2.y)); rim_st.add_vertex(Vector3(b2.x, ry, b2.y)); rim_st.add_vertex(Vector3(bo.x, ry, bo.y))
		rim_st.add_vertex(Vector3(a2.x, ry, a2.y)); rim_st.add_vertex(Vector3(bo.x, ry, bo.y)); rim_st.add_vertex(Vector3(ao.x, ry, ao.y))

# Fill the corner(s) clipped off a path cell, capped at `y` (plateau level), so
# the plateau stays continuous up to the smooth clip edge. `omit` is a single
# consecutive run of hex-vertex indices (per TILE_OMIT); the filled sliver is the
# small polygon [kept-before, omitted..., kept-after].
func _add_clip_slivers(st: SurfaceTool, hex: PackedVector2Array, omit: Array, y: float) -> void:
	var run := _omit_run(omit)
	if run.is_empty():
		return
	var before: int = (int(run[0]) - 1 + 6) % 6
	var after: int = (int(run[run.size() - 1]) + 1) % 6
	var poly := PackedVector2Array()
	poly.append(hex[before])
	for r in run:
		poly.append(hex[int(r)])
	poly.append(hex[after])
	_add_cap(st, poly, y)

# Order a consecutive (mod 6) set of omitted vertex indices into a run, starting
# at the index whose predecessor is NOT omitted (handles the wrap case, e.g. [0,5]).
func _omit_run(omit: Array) -> Array:
	var present := {}
	for o in omit:
		present[int(o)] = true
	var start := int(omit[0])
	for o in omit:
		if not present.has((int(o) - 1 + 6) % 6):
			start = int(o)
			break
	var run: Array = []
	var x := start
	while present.has(x) and run.size() < 6:
		run.append(x)
		x = (x + 1) % 6
	return run

# Plateau skirt: a vertical wall dropping from the plateau rim to the path floor
# on edges that border OFF-MAP (no neighbour cell) — so the board reads as a
# solid slab at its perimeter. Interior edges (plateau/plateau, plateau/path)
# get no skirt: plateau/plateau stays continuous, plateau/path is covered by the
# glowing trench wall. Probes outside the edge midpoint like the trench logic.
func _add_plateau_skirt(st: SurfaceTool, center: Vector2, poly: PackedVector2Array) -> void:
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var mid: Vector2 = (a + b) * 0.5
		var outward: Vector2 = mid - center
		if outward.length() < 0.0001:
			continue
		var probe: Vector2 = mid + outward.normalized() * (HEX_SIZE * 0.5)
		if has_cell(world_cell(probe)):
			continue   # interior edge — no perimeter skirt
		var at := Vector3(a.x, COPPER_TOP, a.y)
		var bt := Vector3(b.x, COPPER_TOP, b.y)
		var ab := Vector3(a.x, PATH_TOP, a.y)
		var bb := Vector3(b.x, PATH_TOP, b.y)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(ab)
		st.add_vertex(at); st.add_vertex(bt); st.add_vertex(bb)

# generate_normals respects the flat smooth group set by the callers, so each
# face gets its own normal (no averaging) — caps up, walls out. Flat ground
# (mask/spawn/goal) does not cast shadows: two-sided (cull-disabled) ground
# self-shadowing would darken it. Raised copper and walls DO cast, for depth.
func _commit(st: SurfaceTool, mat: Material, cast_shadows := false) -> void:
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_root.add_child(mi)

# Top cap (single face) at height y for a plane polygon, as a triangle fan.
# Winding note: the plane polygon is CCW in plane space, but the (x,y)->(x,0,y)
# mapping flips handedness, so a (center, a, b) fan would face DOWN. We emit
# (center, b, a) so generate_normals computes a +Y up normal.
func _add_cap(st: SurfaceTool, poly: PackedVector2Array, y: float) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var c3 := Vector3(center.x, y, center.y)
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		st.add_vertex(c3)
		st.add_vertex(Vector3(b.x, y, b.y))
		st.add_vertex(Vector3(a.x, y, a.y))

# A prism: top cap at `top`, vertical sides down to `bottom`. Side triangles are
# wound to face OUTWARD under the same handedness flip.
func _add_prism(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float) -> void:
	_add_cap(st, poly, top)
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		# two triangles per side quad (outward winding)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(ab)
		st.add_vertex(at); st.add_vertex(bt); st.add_vertex(bb)

func _hex_plane_polygon(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var ang := deg_to_rad(60.0 * i - 30.0)
		pts.append(center + Vector2(cos(ang), sin(ang)) * HEX_SIZE)
	return pts

# Clipped top polygon = full hex minus the clipped vertices (straight edges),
# computed against `region` (the set of cells forming the raised area whose
# silhouette is being smoothed — the build plateau here, the trace in 2D).
func _clipped_plane_polygon(cell: Vector2i, center: Vector2, region: Dictionary) -> PackedVector2Array:
	var hp := _hex_plane_polygon(center)
	var tile := _clip_tile(cell, region)
	var omit: Array = TILE_OMIT.get(tile, [])
	if omit.is_empty():
		return hp
	var poly := PackedVector2Array()
	for i in range(hp.size()):
		if not (i in omit):
			poly.append(hp[i])
	return poly

# ---------------------------------------------------------------- clip rule (ported)
# Smooths the boundary of `region` by cutting a cell's protruding corners. Ported
# verbatim from the 2D copper rule, generalised from the fixed trace set to any
# region set (so it can smooth the build plateau's silhouette along the path).
func _clip_tile(cell: Vector2i, region: Dictionary) -> String:
	var copper: Array = []
	var offmap: Array = []
	for i in range(6):
		var n: Vector2i = cell + EDGE_NB[i]
		copper.append(region.has(n))
		offmap.append(not has_cell(n))
	var on_lr: bool = offmap[0] or offmap[3]
	var on_tb: bool = offmap[1] or offmap[2] or offmap[4] or offmap[5]
	if on_lr or on_tb:
		if on_lr:
			if not copper[4] and not copper[5]:
				return "CORNER_N"
			if not copper[1] and not copper[2]:
				return "CORNER_S"
			return ""
		if not copper[3]:
			return "HALF_W"
		if not copper[0]:
			return "HALF_E"
		return ""
	var exposed: Array = []
	for i in range(6):
		if not copper[i]:
			exposed.append(i)
	if exposed.is_empty():
		return ""
	var runs := _edge_runs(exposed)
	if runs.size() != 1:
		return ""
	var run: Array = runs[0]
	match run.size():
		2:
			return String(POINT_TILE[run[1]])
		3:
			return String(HALF_TILE[run[1]])
		_:
			return ""

func _edge_runs(exposed: Array) -> Array:
	var present := {}
	for e in exposed:
		present[e] = true
	var seen := {}
	var out: Array = []
	for e in exposed:
		if seen.has(e):
			continue
		var start: int = e
		while present.has((start - 1 + 6) % 6):
			start = (start - 1 + 6) % 6
			if start == e:
				break
		if seen.has(start):
			continue
		var run: Array = []
		var x: int = start
		while present.has(x) and not seen.has(x):
			run.append(x)
			seen[x] = true
			x = (x + 1) % 6
		out.append(run)
	return out

# ---------------------------------------------------------------- plane <-> 3D
func plane_to_world3(p: Vector2, h := COPPER_TOP) -> Vector3:
	return Vector3(p.x, h, p.y)

func world3_to_plane(w: Vector3) -> Vector2:
	return Vector2(w.x, w.z)

# ---------------------------------------------------------------- path smoothing (ported, 2D plane)
const PATH_SMOOTH_ITERATIONS := 6
const PATH_CENTER_STRENGTH := 0.6
const PATH_TAUBIN_LAMBDA := 0.5
const PATH_TAUBIN_MU := -0.53

func _smooth_path(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var pts := points
	var spacing := _mean_spacing(pts)
	var step := spacing * 0.4
	var reach := spacing * 8.0
	for _it in PATH_SMOOTH_ITERATIONS:
		pts = _center_pass(pts, step, reach)
		pts = _laplacian_pass(pts, PATH_TAUBIN_LAMBDA)
		pts = _laplacian_pass(pts, PATH_TAUBIN_MU)
	return pts

func _mean_spacing(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return maxf(1.0, total / float(maxi(1, pts.size() - 1)))

func _center_pass(pts: PackedVector2Array, step: float, reach: float) -> PackedVector2Array:
	var out := pts.duplicate()
	for i in range(1, pts.size() - 1):
		var dir: Vector2 = pts[i + 1] - pts[i - 1]
		if dir.length() < 0.0001:
			continue
		dir = dir.normalized()
		var n := Vector2(-dir.y, dir.x)
		var a := _march(pts[i], n, step, reach)
		var b := _march(pts[i], -n, step, reach)
		out[i] = pts[i] + n * ((a - b) * 0.5 * PATH_CENTER_STRENGTH)
	return out

func _march(p: Vector2, dir: Vector2, step: float, reach: float) -> float:
	var d := 0.0
	while d < reach:
		if not _in_trace(p + dir * (d + step)):
			break
		d += step
	return d

func _laplacian_pass(pts: PackedVector2Array, factor: float) -> PackedVector2Array:
	var out := pts.duplicate()
	for i in range(1, pts.size() - 1):
		var avg: Vector2 = (pts[i - 1] + pts[i + 1]) * 0.5
		out[i] = pts[i].lerp(avg, factor)
	return out

func _in_trace(p: Vector2) -> bool:
	return trace_set.has(world_cell(p))

# ---------------------------------------------------------------- logic API (ported, plane coords)
func get_path_points() -> PackedVector2Array:
	return path_pixels

func get_bounds() -> Rect2:
	return _bounds

func has_cell(cell: Vector2i) -> bool:
	return map != null and map.cells.has(cell)

func is_buildable(cell: Vector2i) -> bool:
	if map == null:
		return false
	for c in footprint(cell):
		if not buildable_set.has(c) or occupied.has(c):
			return false
	return true

func cell_free(cell: Vector2i) -> bool:
	return buildable_set.has(cell) and not occupied.has(cell)

func footprint(center: Vector2i) -> Array:
	var out := []
	for d in FOOTPRINT_DIRS:
		out.append(center + d)
	return out

func tower_reach(range_tiles: int) -> int:
	return range_tiles + FOOTPRINT_RADIUS

func tower_at(cell: Vector2i):
	return occupied.get(cell, null)

func world_cell(world_pos: Vector2) -> Vector2i:
	var frac := HexUtils.pixel_to_axial(world_pos - origin, HEX_SIZE)
	return HexUtils.axial_round(frac.x, frac.y)

func cell_center_world(cell: Vector2i) -> Vector2:
	return _cell_to_pixel(cell)

func hex_polygon(center: Vector2) -> PackedVector2Array:
	return _hex_plane_polygon(center)

func hexes_in_range(center: Vector2i, n: int) -> Dictionary:
	var visible: Array[Vector2i] = []
	var shadowed: Array[Vector2i] = []
	var blocked: Array[Vector2i] = []
	var c0 := cell_center_world(center)
	for dq in range(-n, n + 1):
		var lo: int = maxi(-n, -n - dq)
		var hi: int = mini(n, n - dq)
		for dr in range(lo, hi + 1):
			var cell := center + Vector2i(dq, dr)
			if not has_cell(cell):
				continue
			if blocking_set.has(cell):
				blocked.append(cell)
				continue
			if has_los(c0, cell_center_world(cell)):
				visible.append(cell)
			else:
				shadowed.append(cell)
	return {"visible": visible, "shadowed": shadowed, "blocked": blocked}

func has_los(a: Vector2, b: Vector2) -> bool:
	if blocking_set.is_empty():
		return true
	var d := b - a
	var dist := d.length()
	var steps := int(ceil(dist / (HEX_SIZE * 0.45)))
	if steps <= 1:
		return true
	for i in range(1, steps):
		var p := a + d * (float(i) / float(steps))
		if blocking_set.has(world_cell(p)):
			return false
	return true

func place_tower(cell: Vector2i, tower) -> void:
	for c in footprint(cell):
		occupied[c] = tower
	_entities.add_child(tower)

func remove_tower(cell: Vector2i) -> void:
	var t = occupied.get(cell, null)
	if t == null:
		return
	for c in footprint(cell):
		if occupied.get(c, null) == t:
			occupied.erase(c)
	if is_instance_valid(t):
		t.queue_free()

func add_enemy(e) -> void:
	enemies.append(e)
	_entities.add_child(e)
	e.tree_exited.connect(func(): enemies.erase(e))

func add_projectile(p) -> void:
	_entities.add_child(p)

func _cell_to_pixel(axial: Vector2i) -> Vector2:
	return HexUtils.axial_to_pixel(axial, HEX_SIZE) + origin

func _compute_bounds() -> void:
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for cell in map.cells:
		var p := _cell_to_pixel(cell)
		minx = minf(minx, p.x)
		miny = minf(miny, p.y)
		maxx = maxf(maxx, p.x)
		maxy = maxf(maxy, p.y)
	_bounds = Rect2(minx, miny, maxx - minx, maxy - miny)
