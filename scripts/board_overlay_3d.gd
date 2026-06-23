class_name BoardOverlay3D
extends Node3D
## Simplified 3D placement overlay. Per REFACTOR_3D.md it's the minimum useful
## set: range tiles (visible / shadowed / blocked), footprint, and a
## translucent ghost of the tower being placed. Badges and tooltips are
## deferred. Main3D pushes state in and calls refresh().

var board                          # GameBoard3D (untyped)

const HOVER_LIFT := 0.6            # how far above the copper to float overlay tiles

const RANGE_FILL := Color(0.20, 0.55, 1.00, 0.28)
const RANGE_LINE := Color(0.20, 0.55, 1.00, 0.85)
const HIDDEN_FILL := Color(0.97, 0.55, 0.25, 0.32)
const GHOST_COLOR := Color(0.62, 0.64, 0.67, 0.55)

var preview_active := false
var preview_cell := Vector2i.ZERO
var preview_range := 0
var preview_valid := true
var preview_color := Color(0.4, 0.7, 1.0)
var preview_mode := "single"
var preview_dirs := 6

var selected_active := false
var selected_cell := Vector2i.ZERO
var selected_range := 0
var selected_color := Color(0.45, 0.75, 1.0)

var _scene_root: Node3D            # all generated meshes hang off here

func _ready() -> void:
	_scene_root = Node3D.new()
	add_child(_scene_root)

func refresh() -> void:
	if board == null:
		return
	# Wipe the previous frame's meshes and rebuild from current state. The set
	# of overlay tiles is small (range hex disk for a single tower) so this
	# trivially fits a per-input-event redraw.
	for c in _scene_root.get_children():
		c.queue_free()
	if selected_active:
		_draw_region(selected_cell, selected_range)
		_draw_footprint(selected_cell, selected_color, false)
	if preview_active:
		_draw_region(preview_cell, preview_range)
		_draw_footprint(preview_cell, preview_color, true)
		var center: Vector2 = board.cell_center_world(preview_cell)
		_draw_tower_ghost(center, preview_mode, preview_dirs)
		if not preview_valid and board.is_buildable(preview_cell):
			_draw_invalid_mark(center)

# Range disk, split by line-of-sight (visible / shadowed / blocked-by-wall).
func _draw_region(cell: Vector2i, n: int) -> void:
	var res: Dictionary = board.hexes_in_range(cell, n)
	var fp := {}
	for c in board.footprint(cell):
		fp[c] = true
	for c in res["visible"]:
		if fp.has(c):
			continue
		_draw_tile(c, RANGE_FILL)
	for c in res["shadowed"]:
		if fp.has(c):
			continue
		_draw_tile(c, HIDDEN_FILL)
	for c in res["blocked"]:
		if fp.has(c):
			continue
		_draw_tile(c, HIDDEN_FILL)

func _draw_footprint(cell: Vector2i, base: Color, validate: bool) -> void:
	var fill := Color(base.r, base.g, base.b, 0.35)
	for c in board.footprint(cell):
		_draw_tile(c, fill)
		if validate and not board.cell_free(c):
			_draw_invalid_mark(board.cell_center_world(c))

# A single flat hex tile floating just above the copper, as an unshaded
# transparent polygon. Used for all three overlay categories.
func _draw_tile(cell: Vector2i, col: Color) -> void:
	var center: Vector2 = board.cell_center_world(cell)
	var poly: PackedVector2Array = board.hex_polygon(center)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y: float = GameBoard3D.COPPER_TOP + HOVER_LIFT
	var c3 := Vector3(center.x, y, center.y)
	var m := poly.size()
	for i in range(m):
		var a := poly[i]
		var b := poly[(i + 1) % m]
		st.add_vertex(c3)
		st.add_vertex(Vector3(a.x, y, a.y))
		st.add_vertex(Vector3(b.x, y, b.y))
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _flat_translucent_mat(col)
	_scene_root.add_child(mi)

# A red X marker, drawn as two flat strips above the cell.
func _draw_invalid_mark(center: Vector2) -> void:
	var y: float = GameBoard3D.COPPER_TOP + HOVER_LIFT * 1.5
	var r: float = GameBoard3D.HEX_SIZE * 0.55
	var w: float = 0.6
	var col := Color(0.06, 0.08, 0.12, 0.95)
	_add_strip(Vector3(center.x - r, y, center.y - r), Vector3(center.x + r, y, center.y + r), w, col)
	_add_strip(Vector3(center.x - r, y, center.y + r), Vector3(center.x + r, y, center.y - r), w, col)

func _add_strip(a: Vector3, b: Vector3, w: float, col: Color) -> void:
	# Two-triangle ribbon between `a` and `b` of width `w`, perpendicular to the
	# segment in the XZ plane. Used for the invalid-cell X.
	var d := b - a
	if d.length() < 0.0001:
		return
	var n3 := Vector3(-d.z, 0, d.x).normalized() * (w * 0.5)
	var a1 := a + n3
	var a2 := a - n3
	var b1 := b + n3
	var b2 := b - n3
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_vertex(a1); st.add_vertex(a2); st.add_vertex(b2)
	st.add_vertex(a1); st.add_vertex(b2); st.add_vertex(b1)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _flat_translucent_mat(col)
	_scene_root.add_child(mi)

# Translucent silhouette of the tower being placed, sitting at the preview cell.
# Mirrors Tower3D's body shapes per fire mode.
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
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_emit_prism_fan(st, world_poly, GameBoard3D.COPPER_TOP + 7.0, GameBoard3D.COPPER_TOP + HOVER_LIFT)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _flat_translucent_mat(GHOST_COLOR)
	_scene_root.add_child(mi)

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

func _emit_prism_fan(st: SurfaceTool, poly: PackedVector2Array, top: float, bottom: float) -> void:
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	var n := poly.size()
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		st.add_vertex(Vector3(center.x, top, center.y))
		st.add_vertex(Vector3(a.x, top, a.y))
		st.add_vertex(Vector3(b.x, top, b.y))
		var at := Vector3(a.x, top, a.y)
		var bt := Vector3(b.x, top, b.y)
		var ab := Vector3(a.x, bottom, a.y)
		var bb := Vector3(b.x, bottom, b.y)
		st.add_vertex(at); st.add_vertex(ab); st.add_vertex(bb)
		st.add_vertex(at); st.add_vertex(bb); st.add_vertex(bt)

func _flat_translucent_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
