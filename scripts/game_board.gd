class_name GameBoard
extends Node2D
## Renders the hex grid and owns all towers, enemies and projectiles.
## Provides world<->hex helpers. Input is handled by Main.

const HEX_SIZE := 11.34   # = 30 / sqrt(7): a tower's 7-hex footprint ≈ one old hex
## Tile fill colors. Bus = bus; the tile shader keys the metal look off this.
const BUS_COLOR := Color(0.72, 0.45, 0.20)   # bus
const SUBSTRATE_COLOR := Color(0.24, 0.40, 0.28)    # substrate (green)

## Runtime-only bus rendering via predefined clip tiles. Each bus cell is drawn
## as the full hex MINUS some vertices, so a hex staircase reads as straight, hard-
## cornered bus edges. The tile is chosen per cell from its 6 edge-neighbours (bus
## vs not). The editor draws plain cells but previews the same clips.
##
## _hex_polygon vertex order: 0=NE, 1=SE, 2=S, 3=SW, 4=NW, 5=N.
## Tiles are named for the slice clipped away (which becomes substrate):
## CORNER_<dir> drops one vertex (a triangular nip at that corner); HALF_<dir> drops
## two (cutting the hex in half along an axis). The chord between the dropped vertices'
## neighbours is the straight clipped edge.
const TILE_OMIT := {
	"CORNER_N": [5], "CORNER_S": [2], "CORNER_NE": [0], "CORNER_SE": [1], "CORNER_SW": [3], "CORNER_NW": [4],
	"HALF_E": [0, 1], "HALF_W": [3, 4], "HALF_NE": [0, 5], "HALF_SW": [2, 3],
	"HALF_NW": [4, 5], "HALF_SE": [1, 2],
}
## Edge neighbour offsets, indexed e0..e5 (must match the hex edge order):
## e0=E, e1=lower-right, e2=lower-left, e3=W, e4=upper-left, e5=upper-right.
const EDGE_NB := [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]
## One exposed edge (or the middle of a 3-edge run) -> the half-cut facing that edge.
const HALF_TILE := {0: "HALF_E", 1: "HALF_SE", 2: "HALF_SW", 3: "HALF_W", 4: "HALF_NW", 5: "HALF_NE"}
## Two adjacent exposed edges -> the point clip of the vertex they share (vertex index).
const POINT_TILE := {5: "CORNER_N", 0: "CORNER_NE", 1: "CORNER_SE", 2: "CORNER_S", 3: "CORNER_SW", 4: "CORNER_NW"}
## A tower's footprint: the center cell plus its 6 axial neighbors (a rosette).
const FOOTPRINT_DIRS := [
	Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1),
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]
## The footprint is a radius-1 hex disk, so range measured from the footprint
## outline equals range-from-center + 1 (hex Minkowski identity).
const FOOTPRINT_RADIUS := 1
## Radius tower bodies are drawn at, so their outline reaches the centres of the
## 6 footprint neighbour hexes. Adjacent hex centres are HEX_SIZE * sqrt(3) apart.
const TOWER_RADIUS := HEX_SIZE * 1.7320508075688772
var origin := Vector2(0, 0)

var _tile_material: ShaderMaterial

var map: HexMapData
var path_pixels := PackedVector2Array()
var occupied := {}          # Vector2i -> Tower (every footprint cell maps to its tower)
var blocking_set := {}      # Vector2i -> true (line-of-sight walls)
var bus_set := {}         # Vector2i -> true (bus region, for rendering)
var buildable_set := {}     # Vector2i -> true (fast buildable lookup)
var enemies: Array = []
var _bounds := Rect2()
var _entities: Node2D

func _ready() -> void:
	_build_tile_material()
	_entities = Node2D.new()
	add_child(_entities)

## One canvas_item shader skins every tile from a single board-space lighting
## environment, so the two materials read as real surfaces under the same light:
##   * bus cells  -> flat, smooth, high-contrast MIRROR with a crisp light
##                      streak (warm metallic).
##   * everything else-> flat, smooth substrate under a CLEAR COAT (low
##                      contrast green + a soft broad gloss for depth).
## No per-hex math and no noise, so adjacent bus hexes are seamless.
## The board's children (glow/towers/enemies) are unaffected — a CanvasItem's
## material does not propagate to children unless they opt in.
func _build_tile_material() -> void:
	var sh := Shader.new()
	sh.code = TILE_SHADER
	_tile_material = ShaderMaterial.new()
	_tile_material.shader = sh
	_tile_material.set_shader_parameter("bus_color", Vector3(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b))
	_tile_material.set_shader_parameter("bus_tol", 0.12)
	# Sheen is the ONLY brightness variation now, and it only ADDS light — the
	# flat tile color is the floor everywhere, so nothing reads as a dark patch.
	# Defaults are deliberately faint (basically flat). Raise to revisit shine.
	_tile_material.set_shader_parameter("light_dir", Vector2(0.50, -0.86))
	_tile_material.set_shader_parameter("sheen_pos", 0.0)     # where the faint highlight sits (-1..1)
	_tile_material.set_shader_parameter("sheen_width", 0.22)
	_tile_material.set_shader_parameter("bus_sheen", 0.10) # 0 = perfectly flat bus
	_tile_material.set_shader_parameter("substrate_sheen", 0.05)   # 0 = perfectly flat mask
	material = _tile_material

func setup(m: HexMapData) -> void:
	map = m
	blocking_set = {}
	for cell in m.blocking:
		blocking_set[cell] = true
	bus_set = {}
	for cell in m.bus:
		bus_set[cell] = true
	buildable_set = {}
	for cell in m.buildable:
		buildable_set[cell] = true
	var raw := PackedVector2Array()
	for cell in m.path:
		raw.append(_cell_to_pixel(cell))
	path_pixels = _smooth_path(raw)
	_compute_bounds()
	_update_shader_bounds()
	queue_redraw()

## Normalize the shader's sheen gradient to the current board extent so the
## highlight reads the same on any map size.
func _update_shader_bounds() -> void:
	if _tile_material == null:
		return
	var c := _bounds.position + _bounds.size * 0.5
	var radius: float = maxf(1.0, _bounds.size.length() * 0.5)
	_tile_material.set_shader_parameter("board_center", c)
	_tile_material.set_shader_parameter("board_radius", radius)

func get_path_points() -> PackedVector2Array:
	return path_pixels

# Hex grids have no straight column, so a centerline route through cell centers
# staggers left/right every row. Smoothing fixes that in two parts each pass:
#  1) a band-aware centering step pulls each point to the midpoint of the bus's
#     cross-section (perpendicular to travel), so it tracks the true center even
#     through turns instead of cutting them;
#  2) Taubin smoothing (a positive lambda pass + a negative mu pass) removes
#     residual jitter WITHOUT the shrinkage that plain Laplacian causes, so corners
#     only round off slightly rather than getting cut.
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

# Move each interior point toward the midpoint of the bus band measured
# perpendicular to its direction of travel (endpoints stay pinned).
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

# Distance from p to the edge of the bus in direction dir (how far the band extends).
func _march(p: Vector2, dir: Vector2, step: float, reach: float) -> float:
	var d := 0.0
	while d < reach:
		if not _in_bus(p + dir * (d + step)):
			break
		d += step
	return d

func _laplacian_pass(pts: PackedVector2Array, factor: float) -> PackedVector2Array:
	var out := pts.duplicate()
	for i in range(1, pts.size() - 1):
		var avg: Vector2 = (pts[i - 1] + pts[i + 1]) * 0.5
		out[i] = pts[i].lerp(avg, factor)   # factor < 0 extrapolates (Taubin anti-shrink)
	return out

func _in_bus(p: Vector2) -> bool:
	return bus_set.has(world_cell(p))

func get_bounds() -> Rect2:
	return _bounds

func has_cell(cell: Vector2i) -> bool:
	return map != null and map.cells.has(cell)

## A tower occupies its center cell + the 6 around it. Buildable only if every
## one of those 7 cells exists, is buildable, and is unoccupied.
func is_buildable(cell: Vector2i) -> bool:
	if map == null:
		return false
	for c in footprint(cell):
		if not buildable_set.has(c) or occupied.has(c):
			return false
	return true

## True if a single cell is paintable terrain and not already taken.
## Used to colour individual footprint cells during placement.
func cell_free(cell: Vector2i) -> bool:
	return buildable_set.has(cell) and not occupied.has(cell)

## The 7 cells a tower placed on `center` would cover.
func footprint(center: Vector2i) -> Array:
	var out := []
	for d in FOOTPRINT_DIRS:
		out.append(center + d)
	return out

## Effective targeting reach in tiles, measured from the footprint outline
## rather than the center hex. A range_tiles value of N reaches N tiles beyond
## the tower's footprint.
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
	return _hex_polygon(center)

## All board cells within `n` tiles of `center`, split by line of sight.
## Returns {"visible": Array[Vector2i], "shadowed": Array[Vector2i]} where
## shadowed cells are in range but hidden behind a blocking wall.
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

## True if nothing blocks the straight line between two world points.
## Samples along the segment and fails if any sample falls on a blocking hex.
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

func _draw() -> void:
	if map == null:
		return
	for cell in map.cells:
		var center := _cell_to_pixel(cell)
		var pts := _hex_polygon(center)
		var fill: Color
		if cell == map.spawn:
			fill = Color(0.30, 0.55, 0.32)
		elif cell == map.goal:
			fill = Color(0.66, 0.28, 0.28)
		elif blocking_set.has(cell):
			fill = Color(0.16, 0.17, 0.22)   # wall (blocks line of sight)
		elif bus_set.has(cell):
			fill = SUBSTRATE_COLOR                # bus drawn as hybrid tiles below; mask shows through clips
		else:
			fill = SUBSTRATE_COLOR                # substrate
		draw_colored_polygon(pts, fill)
	# No per-cell hex outline in-game: the board reads as a solid PCB surface.
	# (Hex grid lines still appear in the editor and on the tower view overlay.)
	_draw_bus()

## Draws each bus cell as its hybrid tile (full hex minus clipped vertices), chosen
## from the cell's bus/non-bus neighbours. The clipped-away part shows the mask
## underfill from _draw(). Resolution-independent: rebuilt from the live cell centre and
## HEX_SIZE every redraw, so the straight clip edges stay crisp at any zoom.
func _draw_bus() -> void:
	for cell in bus_set.keys():
		var center := _cell_to_pixel(cell)
		var hp := _hex_polygon(center)
		var tile := _bus_tile(cell)
		var omit: Array = TILE_OMIT.get(tile, [])
		if omit.is_empty():
			draw_colored_polygon(hp, BUS_COLOR)   # full hex (interior cell, or out-of-scope cap)
			continue
		var poly := PackedVector2Array()
		for i in range(hp.size()):
			if not (i in omit):
				poly.append(hp[i])
		draw_colored_polygon(poly, BUS_COLOR)

## Picks the hybrid tile for a bus cell from its exposed (non-bus) edges.
## 0 or 1 exposed -> full hex: a lone exposed edge is already straight, so clipping it
## is wrong (that over-clip is what dovetailed the verticals and inside corners).
## 2 adjacent -> point-clip the shared vertex. 3 contiguous -> half-cut facing the
## middle edge. 4+ contiguous (a bus cap) and split exposure (a junction) only occur
## at map edges, handled separately; those fall through to a full hex too.
func _bus_tile(cell: Vector2i) -> String:
	var bus: Array = []
	var offmap: Array = []
	for i in range(6):
		var n: Vector2i = cell + EDGE_NB[i]
		bus.append(bus_set.has(n))
		offmap.append(not has_cell(n))
	# --- Map-edge rule: a bus cell on the map boundary clips toward its in-map mask
	# side so the bus runs cleanly off the edge (the "start/end at the edge" case).
	# Fires only on the boundary; interior cells fall through to the normal rule.
	# (Diagonal/corner exits — both an L/R and a T/B edge at once — aren't specially
	# handled yet; they take the L/R branch. No such map exists currently.)
	var on_lr: bool = offmap[0] or offmap[3]
	var on_tb: bool = offmap[1] or offmap[2] or offmap[4] or offmap[5]
	if on_lr or on_tb:
		if on_lr:
			if not bus[4] and not bus[5]:
				return "CORNER_N"
			if not bus[1] and not bus[2]:
				return "CORNER_S"
			return ""
		if not bus[3]:
			return "HALF_W"
		if not bus[0]:
			return "HALF_E"
		return ""
	# --- Normal interior rule ---
	var exposed: Array = []
	for i in range(6):
		if not bus[i]:
			exposed.append(i)
	if exposed.is_empty():
		return ""
	var runs := _edge_runs(exposed)
	if runs.size() != 1:
		return ""   # split exposure (junction) — out of scope
	var run: Array = runs[0]
	match run.size():
		2:
			return String(POINT_TILE[run[1]])   # run is [a, a+1]; shared vertex = a+1
		3:
			return String(HALF_TILE[run[1]])    # full side exposed -> half-cut facing middle edge
		_:
			return ""   # 1 = already-straight single edge; 4+ = cap; both stay a full hex

## Splits a set of exposed edge indices (0..5) into maximal contiguous cyclic runs,
## each ordered ascending from its start (e.g. [5,0,1] for a run wrapping past 0).
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
				break   # full ring of 6
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

func _hex_polygon(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var ang := deg_to_rad(60.0 * i - 30.0)
		pts.append(center + Vector2(cos(ang), sin(ang)) * HEX_SIZE)
	return pts

# --- Tile surface shader (canvas_item) -------------------------------------
# Reads each polygon's flat fill color and adds material shading:
#   * cells matching bus_color -> brushed-metal bus (anisotropic streaks
#     along the bus + a tight specular band and sharp glint)
#   * all other cells -> glossy plastic substrate (broad soft highlight +
#     faint clearcoat sparkle)
# The pattern is anchored in board space (VERTEX), so it stays locked to the
# tiles when the camera pans or zooms. Everything is tweakable up top.
const TILE_SHADER := """

shader_type canvas_item;

uniform vec3 bus_color = vec3(0.72, 0.45, 0.20);
uniform float bus_tol = 0.12;

// Even lighting: the flat tile color is the floor everywhere (no across-board
// darkening), plus a single faint additive sheen. No region is ever darker
// than its base color, so there are no dark patches and no blown highlights.
uniform vec2 light_dir = vec2(0.50, -0.86);
uniform vec2 board_center = vec2(0.0, 0.0);
uniform float board_radius = 600.0;
uniform float sheen_pos = 0.0;
uniform float sheen_width = 0.22;
uniform float bus_sheen = 0.10;
uniform float substrate_sheen = 0.05;

varying vec2 vpos;

void vertex() {
	vpos = VERTEX;
}

void fragment() {
	vec3 base = COLOR.rgb;
	float is_bus = step(distance(base, bus_color), bus_tol);

	vec2 nl = normalize(light_dir);
	float g = dot((vpos - board_center) / board_radius, nl);
	float streak = exp(-pow((g - sheen_pos) / sheen_width, 2.0));

	float sheen = mix(substrate_sheen, bus_sheen, is_bus);
	vec3 tint = mix(vec3(0.85, 0.95, 1.0), vec3(1.0, 0.93, 0.82), is_bus);

	vec3 col = base + tint * streak * sheen;   // only ever ADDS light
	col = min(col, vec3(1.0));
	COLOR = vec4(col, COLOR.a);
}

"""
