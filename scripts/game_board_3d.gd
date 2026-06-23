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
const TRACE_COLOR := Color(0.72, 0.45, 0.20)   # copper
const MASK_COLOR := Color(0.24, 0.40, 0.28)    # solder mask (green)
const SPAWN_COLOR := Color(0.30, 0.55, 0.32)
const GOAL_COLOR := Color(0.66, 0.28, 0.28)
const WALL_COLOR := Color(0.16, 0.17, 0.22)

# Heights (world units). Copper sits proud of the mask; walls stand tall.
const MASK_TOP := 0.0
const MASK_THICK := 6.0
const COPPER_TOP := 1.6        # copper raised slightly above the mask surface
const WALL_TOP := 10.0

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
	_mat_copper = StandardMaterial3D.new()
	_mat_copper.albedo_color = TRACE_COLOR
	_mat_copper.metallic = 1.0
	_mat_copper.metallic_specular = 0.9
	_mat_copper.roughness = 0.18          # near-mirror; raise for a satin look
	_mat_mask = StandardMaterial3D.new()
	_mat_mask.albedo_color = MASK_COLOR
	_mat_mask.metallic = 0.0
	_mat_mask.roughness = 0.35
	_mat_mask.clearcoat_enabled = true
	_mat_mask.clearcoat = 1.0
	_mat_mask.clearcoat_roughness = 0.08   # glossy clear epoxy over the green
	_mat_wall = _flat_mat(WALL_COLOR, 0.6)
	_mat_spawn = _flat_mat(SPAWN_COLOR, 0.5)
	_mat_goal = _flat_mat(GOAL_COLOR, 0.5)

func _flat_mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
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

	# substrate: every cell as a mask-topped prism (the green board)
	var mask_st := SurfaceTool.new()
	mask_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var spawn_st := SurfaceTool.new(); spawn_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var goal_st := SurfaceTool.new(); goal_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_st := SurfaceTool.new(); wall_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var copper_st := SurfaceTool.new(); copper_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var have_spawn := false
	var have_goal := false
	var have_wall := false
	var have_copper := false

	for cell in map.cells:
		var c := _cell_to_pixel(cell)
		var hex := _hex_plane_polygon(c)
		# substrate prism for every cell (mask). Spawn/goal/wall get a coloured cap on top.
		_add_prism(mask_st, hex, MASK_TOP, MASK_TOP - MASK_THICK)
		if cell == map.spawn:
			_add_cap(spawn_st, hex, MASK_TOP + 0.05); have_spawn = true
		elif cell == map.goal:
			_add_cap(goal_st, hex, MASK_TOP + 0.05); have_goal = true
		elif blocking_set.has(cell):
			_add_prism(wall_st, hex, WALL_TOP, MASK_TOP); have_wall = true

	# copper traces: clipped top polygon, raised, as its own prism
	for cell in trace_set.keys():
		var c := _cell_to_pixel(cell)
		var poly := _clipped_plane_polygon(cell, c)
		if poly.size() >= 3:
			_add_prism(copper_st, poly, COPPER_TOP, MASK_TOP)
			have_copper = true

	_commit(mask_st, _mat_mask)
	if have_spawn: _commit(spawn_st, _mat_spawn)
	if have_goal: _commit(goal_st, _mat_goal)
	if have_wall: _commit(wall_st, _mat_wall)
	if have_copper: _commit(copper_st, _mat_copper)

func _commit(st: SurfaceTool, mat: Material) -> void:
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	_mesh_root.add_child(mi)

# Top cap (single face) at height y for a plane polygon, as a triangle fan.
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
		st.add_vertex(Vector3(a.x, y, a.y))
		st.add_vertex(Vector3(b.x, y, b.y))

# A prism: top cap at `top`, vertical sides down to `bottom`.
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
		st.add_vertex(at); st.add_vertex(ab); st.add_vertex(bb)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(bt)

func _hex_plane_polygon(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var ang := deg_to_rad(60.0 * i - 30.0)
		pts.append(center + Vector2(cos(ang), sin(ang)) * HEX_SIZE)
	return pts

# Copper cell's top polygon = full hex minus the clipped vertices (straight edges).
func _clipped_plane_polygon(cell: Vector2i, center: Vector2) -> PackedVector2Array:
	var hp := _hex_plane_polygon(center)
	var tile := _copper_tile(cell)
	var omit: Array = TILE_OMIT.get(tile, [])
	if omit.is_empty():
		return hp
	var poly := PackedVector2Array()
	for i in range(hp.size()):
		if not (i in omit):
			poly.append(hp[i])
	return poly

# ---------------------------------------------------------------- copper clip rule (ported)
func _copper_tile(cell: Vector2i) -> String:
	var copper: Array = []
	var offmap: Array = []
	for i in range(6):
		var n: Vector2i = cell + EDGE_NB[i]
		copper.append(trace_set.has(n))
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
