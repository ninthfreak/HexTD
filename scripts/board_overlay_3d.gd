class_name BoardOverlay3D
extends Node3D
## Simplified 3D placement overlay. Per REFACTOR_3D.md it's the minimum useful
## set: range tiles (visible / shadowed / blocked), footprint, and a
## translucent ghost of the tower being placed. Ability badges + their tooltip
## are drawn separately by Main3D as screen-space UI. Main3D pushes state in and
## calls refresh().

var board                          # GameBoard3D (untyped)

const HOVER_LIFT := 0.6            # how far above the bus to float overlay tiles
const LINE_LIFT := 0.08            # outline strokes float above the fills so they win the depth tie

const RANGE_FILL := Color(0.20, 0.55, 1.00, 0.16)
const RANGE_LINE := Color(0.20, 0.55, 1.00, 0.85)
const HIDDEN_FILL := Color(0.97, 0.55, 0.25, 0.20)
const HIDDEN_LINE := Color(0.97, 0.55, 0.25, 0.85)
const BLOCKED_FILL := Color(0.30, 0.16, 0.10, 0.40)   # wall cells: a dead dark stain, no outline
const GHOST_INVALID := Color(0.9, 0.25, 0.2, 0.4)

const RANGE_LINE_ENERGY := 2.0     # base emission energies; _process pulses around these
const HIDDEN_LINE_ENERGY := 1.4

var preview_active := false
var preview_cell := Vector2i.ZERO
var preview_range := 0
var preview_valid := true
var preview_color := Color(0.4, 0.7, 1.0)
var preview_mode := "single"
var preview_dirs := 6
var preview_ignore_walls := false   # Tunneling: wall-shadowed tiles are still reachable
var preview_rotated := false        # 30° rotated hex range (taller than wide)

var selected_active := false
var selected_cell := Vector2i.ZERO
var selected_range := 0
var selected_color := Color(0.45, 0.75, 1.0)
var selected_ignore_walls := false
var selected_rotated := false

var _scene_root: Node3D            # all generated meshes hang off here

# Materials are built once and reused across refreshes. refresh() rebuilds the
# meshes per input event, so allocating materials there would churn — and the
# _process pulse needs stable objects to animate.
var _mat_range_fill: StandardMaterial3D
var _mat_hidden_fill: StandardMaterial3D
var _mat_blocked_fill: StandardMaterial3D
var _mat_range_line: StandardMaterial3D
var _mat_hidden_line: StandardMaterial3D
var _mat_x_red: StandardMaterial3D
var _mat_x_under: StandardMaterial3D
var _mat_ghost: StandardMaterial3D
var _fill_cache: Dictionary = {}   # tower-tinted footprint fills, keyed by col.to_rgba32()
var _ring_cache: Dictionary = {}   # tower-tinted footprint edge rings, keyed by col.to_rgba32()

func _ready() -> void:
	_scene_root = Node3D.new()
	add_child(_scene_root)
	_mat_range_fill = _make_fill_mat(RANGE_FILL)
	_mat_hidden_fill = _make_fill_mat(HIDDEN_FILL)
	_mat_blocked_fill = _make_fill_mat(BLOCKED_FILL)
	_mat_range_line = _make_line_mat(RANGE_LINE, Color(0.20, 0.55, 1.00), RANGE_LINE_ENERGY)
	_mat_hidden_line = _make_line_mat(HIDDEN_LINE, Color(0.97, 0.55, 0.25), HIDDEN_LINE_ENERGY)
	# The invalid X: emissive red on top of a dark underlay strip for contrast.
	_mat_x_red = _make_line_mat(Color(1.0, 0.22, 0.16, 0.95), Color(1.0, 0.15, 0.10), 2.5)
	_mat_x_under = _make_line_mat(Color(0.06, 0.08, 0.12, 0.95), Color(), 0.0)
	# Ghost: vertex colors carry the tint (top cap bright, side walls darker) so
	# one material fakes top-lit shading; emission is retinted per refresh.
	_mat_ghost = StandardMaterial3D.new()
	_mat_ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_ghost.cull_mode = BaseMaterial3D.CULL_BACK
	_mat_ghost.vertex_color_use_as_albedo = true
	_mat_ghost.render_priority = 3   # over the region fills/strokes

# Breathe the region fills/outlines while a placement or selection is live.
# Only cached material properties change here — never the meshes — so the
# per-input-event rebuild in refresh() stays the only geometry cost.
func _process(_delta: float) -> void:
	if not preview_active and not selected_active:
		return
	var k: float = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * TAU * 0.8)
	var fill_scale: float = lerpf(0.79, 1.21, k)    # fill alpha swings ~±21% around its base
	var energy_scale: float = lerpf(0.75, 1.3, k)   # range line: 1.5 .. 2.6
	_mat_range_fill.albedo_color = Color(RANGE_FILL.r, RANGE_FILL.g, RANGE_FILL.b, RANGE_FILL.a * fill_scale)
	_mat_hidden_fill.albedo_color = Color(HIDDEN_FILL.r, HIDDEN_FILL.g, HIDDEN_FILL.b, HIDDEN_FILL.a * fill_scale)
	_mat_range_line.emission_energy_multiplier = RANGE_LINE_ENERGY * energy_scale
	_mat_hidden_line.emission_energy_multiplier = HIDDEN_LINE_ENERGY * energy_scale

func refresh() -> void:
	if board == null:
		return
	# Wipe the previous frame's meshes and rebuild from current state. The set
	# of overlay tiles is small (range hex disk for a single tower) so this
	# trivially fits a per-input-event redraw.
	for c in _scene_root.get_children():
		c.queue_free()
	if selected_active:
		_draw_region(selected_cell, selected_range, selected_ignore_walls, selected_rotated)
		_draw_footprint(selected_cell, selected_color, false)
	if preview_active:
		_draw_region(preview_cell, preview_range, preview_ignore_walls, preview_rotated)
		_draw_footprint(preview_cell, preview_color, true)
		var center: Vector2 = board.cell_center_world(preview_cell)
		_draw_tower_ghost(center, preview_mode, preview_dirs)
		if not preview_valid and board.is_buildable(preview_cell):
			_draw_invalid_mark(center)

# Range disk, split by line-of-sight (visible / shadowed / blocked-by-wall).
# Tunneling towers (ignore_walls) reach the wall-shadowed tiles too, so those are
# drawn as in-range rather than hidden. Wall cells themselves are never reachable
# and get a separate deader stain with no outline.
func _draw_region(cell: Vector2i, n: int, ignore_walls := false, rotated := false) -> void:
	var res: Dictionary = board.hexes_in_range(cell, n, rotated)
	var fp := {}
	for c in board.footprint(cell):
		fp[c] = true
	var range_set := {}
	var hidden_set := {}
	var blocked_set := {}
	for c in res["visible"]:
		if not fp.has(c):
			range_set[c] = true
	for c in res["shadowed"]:
		if fp.has(c):
			continue
		if ignore_walls:
			range_set[c] = true
		else:
			hidden_set[c] = true
	for c in res["blocked"]:
		if not fp.has(c):
			blocked_set[c] = true
	if not range_set.is_empty():
		_draw_cells_fill(range_set, _mat_range_fill)
		for poly in board.cell_set_outline(range_set, 2):
			_draw_poly_outline(poly, GameBoard3D.BUS_TOP + HOVER_LIFT + LINE_LIFT, 1.4, _mat_range_line)
	if not hidden_set.is_empty():
		_draw_cells_fill(hidden_set, _mat_hidden_fill)
		for poly in board.cell_set_outline(hidden_set, 2):
			_draw_poly_outline(poly, GameBoard3D.BUS_TOP + HOVER_LIFT + LINE_LIFT, 1.4, _mat_hidden_line)
	if not blocked_set.is_empty():
		_draw_cells_fill(blocked_set, _mat_blocked_fill)

func _draw_footprint(cell: Vector2i, base: Color, validate: bool) -> void:
	# Footprint floats slightly above the region fills so it reads as "the tower
	# goes HERE"; a bright hex-edge ring in the tower's own color anchors it.
	var fill_y: float = GameBoard3D.BUS_TOP + HOVER_LIFT + 0.05
	var fill_mat: StandardMaterial3D = _fill_mat_for(Color(base.r, base.g, base.b, 0.35))
	for c in board.footprint(cell):
		_draw_tile(c, fill_y, fill_mat)
		if validate and not board.cell_free(c):
			_draw_invalid_mark(board.cell_center_world(c))
	var center: Vector2 = board.cell_center_world(cell)
	_draw_poly_outline(board.hex_polygon(center), fill_y + 0.04, 1.0, _ring_mat_for(base))

# Region fill as one batched mesh of per-cell hex fans. Filling cells directly
# (instead of triangulating the region's outline polygons) is immune to the
# outline degeneracies a region can hit at the board edge, and to the outer
# loop of an annular region spanning its hole.
func _draw_cells_fill(cells: Dictionary, mat: StandardMaterial3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y: float = GameBoard3D.BUS_TOP + HOVER_LIFT
	for cell in cells:
		var hp: PackedVector2Array = board.hex_polygon(board.cell_center_world(cell))
		for i in range(1, 5):
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(hp[0].x, y, hp[0].y))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(hp[i].x, y, hp[i].y))
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(hp[i + 1].x, y, hp[i + 1].y))
	_add_overlay_mesh(st.commit(), mat)

# A single flat hex tile floating just above the bus, as an unshaded
# transparent polygon. Used for the footprint tiles.
func _draw_tile(cell: Vector2i, y: float, mat: StandardMaterial3D) -> void:
	var center: Vector2 = board.cell_center_world(cell)
	var poly: PackedVector2Array = board.hex_polygon(center)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c3 := Vector3(center.x, y, center.y)
	var m := poly.size()
	for i in range(m):
		var a := poly[i]
		var b := poly[(i + 1) % m]
		st.add_vertex(c3)
		st.add_vertex(Vector3(a.x, y, a.y))
		st.add_vertex(Vector3(b.x, y, b.y))
	st.generate_normals()
	_add_overlay_mesh(st.commit(), mat)

# Ribbon-quad stroke along a closed poly at height `y` — one mesh per poly.
func _draw_poly_outline(poly: PackedVector2Array, y: float, w: float, mat: StandardMaterial3D) -> void:
	var n := poly.size()
	if n < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		_emit_strip(st, Vector3(a.x, y, a.y), Vector3(b.x, y, b.y), w)
	st.generate_normals()
	_add_overlay_mesh(st.commit(), mat)

# A red X marker, drawn as two flat strips above the cell, over a wide dark
# underlay so the emissive red pops on any cell.
func _draw_invalid_mark(center: Vector2) -> void:
	var y: float = GameBoard3D.BUS_TOP + HOVER_LIFT * 1.5
	var r: float = GameBoard3D.HEX_SIZE * 0.45
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_strip(st, Vector3(center.x - r, y - 0.05, center.y - r), Vector3(center.x + r, y - 0.05, center.y + r), 3.0)
	_emit_strip(st, Vector3(center.x - r, y - 0.05, center.y + r), Vector3(center.x + r, y - 0.05, center.y - r), 3.0)
	st.generate_normals()
	_add_overlay_mesh(st.commit(), _mat_x_under)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_strip(st, Vector3(center.x - r, y, center.y - r), Vector3(center.x + r, y, center.y + r), 1.8)
	_emit_strip(st, Vector3(center.x - r, y, center.y + r), Vector3(center.x + r, y, center.y - r), 1.8)
	st.generate_normals()
	_add_overlay_mesh(st.commit(), _mat_x_red)

func _emit_strip(st: SurfaceTool, a: Vector3, b: Vector3, w: float) -> void:
	# Two-triangle ribbon between `a` and `b` of width `w`, perpendicular to the
	# segment in the XZ plane. Used for outline strokes and the invalid-cell X.
	var d := b - a
	if d.length() < 0.0001:
		return
	var n3 := Vector3(-d.z, 0, d.x).normalized() * (w * 0.5)
	var a1 := a + n3
	var a2 := a - n3
	var b1 := b + n3
	var b2 := b - n3
	st.add_vertex(a1); st.add_vertex(a2); st.add_vertex(b2)
	st.add_vertex(a1); st.add_vertex(b2); st.add_vertex(b1)

# Translucent silhouette of the tower being placed, sitting at the preview cell.
# Mirrors Tower3D's body shapes per fire mode. Tinted with the tower's own color
# (red when the placement is invalid); vertex colors fake top-lit shading.
func _draw_tower_ghost(center: Vector2, mode: String, dirs: int) -> void:
	var pts: PackedVector2Array
	match mode:
		"radial":
			pts = _star_points(dirs)
		"laser":
			pts = _circle_points(28)
		_:
			pts = _diamond_points()
	# Translate the local shape into world plane coords.
	var world_poly := PackedVector2Array()
	for p in pts:
		world_poly.append(p + center)
	var tint: Color
	if preview_valid:
		tint = Color(preview_color.r, preview_color.g, preview_color.b, 0.45)
		_mat_ghost.emission_enabled = true
		_mat_ghost.emission = preview_color * 0.6
		_mat_ghost.emission_energy_multiplier = 0.8
	else:
		tint = GHOST_INVALID
		_mat_ghost.emission_enabled = false
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_prism_fan(st, world_poly, GameBoard3D.BUS_TOP + 7.0, GameBoard3D.BUS_TOP + HOVER_LIFT, tint, tint.darkened(0.35))
	st.generate_normals()
	_add_overlay_mesh(st.commit(), _mat_ghost)

func _diamond_points() -> PackedVector2Array:
	var s: float = GameBoard3D.TOWER_RADIUS
	return PackedVector2Array([
		Vector2(0, -s), Vector2(s, 0), Vector2(0, s), Vector2(-s, 0)
	])

func _star_points(dirs: int) -> PackedVector2Array:
	var n: int = maxi(3, int(round(sqrt(3.0 * float(maxi(1, dirs))))))
	var outer: float = GameBoard3D.TOWER_RADIUS
	var inner := outer * 0.46
	var perim := PackedVector2Array()
	for i in range(2 * n):
		var ang := TAU * float(i) / float(2 * n)
		var rad: float = outer if i % 2 == 0 else inner
		perim.append(Vector2(cos(ang), sin(ang)) * rad)
	return perim

func _circle_points(n: int) -> PackedVector2Array:
	var r: float = GameBoard3D.TOWER_RADIUS
	var pts := PackedVector2Array()
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		pts.append(Vector2(cos(ang), sin(ang)) * r)
	return pts

func _emit_prism_fan(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float, top_col: Color, side_col: Color) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		st.set_color(top_col)
		st.add_vertex(Vector3(center.x, top, center.y))
		st.add_vertex(Vector3(a.x, top, a.y))
		st.add_vertex(Vector3(b.x, top, b.y))
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		st.set_color(side_col)
		st.add_vertex(at); st.add_vertex(ab); st.add_vertex(bb)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(bt)

# Shared mesh spawner. Overlay geometry never casts shadows — alpha-transparent
# materials would still stamp fully opaque shadow copies onto the board.
func _add_overlay_mesh(mesh: Mesh, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_scene_root.add_child(mi)

# Overlay layers order themselves EXPLICITLY above the board's transparent
# frost slab (priority 0): distance-sorting transparents is unreliable once the
# fill is one big batched mesh whose sort point can land behind the slab's.
# Fills at 1, strokes at 2 so the outline always wins the fill.
func _make_fill_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = 1
	return m

func _make_line_mat(col: Color, emit: Color, energy: float) -> StandardMaterial3D:
	var m := _make_fill_mat(col)
	m.render_priority = 2
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emit
		m.emission_energy_multiplier = energy
	return m

# Tower-tinted materials, cached per color so refresh() (which runs per input
# event) never allocates materials.
func _fill_mat_for(col: Color) -> StandardMaterial3D:
	var key: int = col.to_rgba32()
	if not _fill_cache.has(key):
		_fill_cache[key] = _make_fill_mat(col)
	var m: StandardMaterial3D = _fill_cache[key]
	return m

func _ring_mat_for(base: Color) -> StandardMaterial3D:
	var key: int = base.to_rgba32()
	if not _ring_cache.has(key):
		_ring_cache[key] = _make_line_mat(Color(base.r, base.g, base.b, 0.9), Color(base.r, base.g, base.b), 1.8)
	var m: StandardMaterial3D = _ring_cache[key]
	return m
