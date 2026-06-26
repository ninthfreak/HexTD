class_name BoardOverlay
extends Node2D
## Draws the tower view area as a hex-tile region (not a circle) plus the
## placement ghost. Cells in range but hidden behind a wall are shown in a
## distinct "shadowed" style. Main pushes values in and calls queue_redraw().

var board                                   # GameBoard

# DARK is the crisp outline colour used throughout. The range now reads as bright
# blue (outline + a mostly-transparent blue fill); the footprint shows the tower's
# own colour. GHOST_COL is the neutral grey placement ghost.
const DARK := Color(0.04, 0.06, 0.09)
const RANGE_LINE := Color(0.20, 0.55, 1.00)  # bright blue range outline
const RANGE_FILL := Color(0.20, 0.55, 1.00)  # mostly-transparent blue fill
const GHOST_COL := Color(0.62, 0.64, 0.67)   # grey tower ghost

var preview_active := false
var preview_cell := Vector2i.ZERO
var preview_range := 0                       # tiles
var preview_valid := true
var preview_color := Color(0.4, 0.7, 1.0)
var preview_mode := "single"                 # fire_mode, for the ghost shape
var preview_dirs := 6                        # star points (radial towers)

var selected_active := false
var selected_cell := Vector2i.ZERO
var selected_range := 0                      # tiles
var selected_color := Color(0.45, 0.75, 1.0)
var badge_icons: Array = []                  # ability icons for the selected tower
var _icon_tex := {}                          # cache: ability name -> Texture2D

const BADGE_R := 13.0                        # ability badge circle radius (world px)
const BADGE_GAP := 6.0                       # gap between badges

func _ready() -> void:
	# smooth scaling for the rasterised SVG badge icons (reduces shimmer when zooming)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

func _draw() -> void:
	if board == null:
		return
	if selected_active:
		_draw_region(selected_cell, selected_range)
		_draw_footprint(selected_cell, selected_color, false)
	if preview_active:
		_draw_region(preview_cell, preview_range)
		_draw_footprint(preview_cell, preview_color, true)
		var center: Vector2 = board.cell_center_world(preview_cell)
		# terrain is fine but unaffordable: mark the centre so it still reads invalid
		if not preview_valid and board.is_buildable(preview_cell):
			_cross(center, Color(DARK.r, DARK.g, DARK.b, 0.9))
		# a grey ghost of the tower itself, on the cell you're aiming with
		_draw_tower_ghost(center, preview_mode, preview_dirs)
	# ability badges sit on top, just below the selected tower
	if selected_active and not badge_icons.is_empty():
		for b in badge_layout():
			_draw_badge(b["center"], str(b["icon"]))

## Draws the tower's 7-cell footprint as one translucent region in the tower's own
## colour, outlined only on the outer perimeter (no internal hex edges). When validate
## is true, any cell that can't be built on is marked with a dark X.
func _draw_footprint(cell: Vector2i, base: Color, validate: bool) -> void:
	var fill := Color(base.r, base.g, base.b, 0.25)
	var edges := {}                              # perimeter detection: edge key -> {count, a, b}
	for c in board.footprint(cell):
		var wc: Vector2 = board.cell_center_world(c)
		var poly: PackedVector2Array = board.hex_polygon(wc)
		draw_colored_polygon(poly, fill)
		var m := poly.size()
		for i in range(m):
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % m]
			var ka := _vkey(a)
			var kb := _vkey(b)
			var key := ka + "|" + kb if ka < kb else kb + "|" + ka
			if edges.has(key):
				edges[key]["count"] += 1
			else:
				edges[key] = {"count": 1, "a": a, "b": b}
		if validate and not board.cell_free(c):
			_cross(wc, Color(DARK.r, DARK.g, DARK.b, 0.9))
	# only edges that belong to a single hex are on the outer perimeter
	var line := Color(DARK.r, DARK.g, DARK.b, 0.85)
	for e in edges.values():
		if e["count"] == 1:
			draw_line(e["a"], e["b"], line, 2.5)

## Rounded vertex key (0.1px) so shared edges between adjacent hexes match exactly.
func _vkey(v: Vector2) -> String:
	return "%d,%d" % [roundi(v.x * 10.0), roundi(v.y * 10.0)]

## Dark X marking a blocked cell — a shape cue independent of colour.
func _cross(center: Vector2, col: Color) -> void:
	var r: float = board.HEX_SIZE * 0.55
	draw_line(center + Vector2(-r, -r), center + Vector2(r, r), col, 2.5)
	draw_line(center + Vector2(-r, r), center + Vector2(r, -r), col, 2.5)

## Translucent grey silhouette of the tower being placed, matching tower.gd's
## shapes (diamond / star / laser circle) so you see what you're about to build.
func _draw_tower_ghost(center: Vector2, mode: String, dirs: int) -> void:
	var body := Color(GHOST_COL.r, GHOST_COL.g, GHOST_COL.b, 0.45)
	var line := Color(DARK.r, DARK.g, DARK.b, 0.90)
	var radius: float = GameBoard.TOWER_RADIUS
	match mode:
		"radial":
			var n: int = maxi(3, dirs)
			var outer := radius
			var inner := outer * 0.46
			var perim := PackedVector2Array()
			for i in range(2 * n):
				var ang := TAU * float(i) / float(2 * n)
				var rad: float = outer if i % 2 == 0 else inner
				perim.append(Vector2(cos(ang), sin(ang)) * rad + center)
			for i in range(perim.size()):
				draw_colored_polygon(
					PackedVector2Array([center, perim[i], perim[(i + 1) % perim.size()]]), body)
			var ring := perim.duplicate()
			ring.append(perim[0])
			draw_polyline(ring, line, 2.0)
		"laser":
			draw_circle(center, radius, body)
			draw_arc(center, radius, 0.0, TAU, 32, line, 2.0, true)
			draw_circle(center, radius * 0.4, Color(1, 1, 1, 0.70))
		_:
			var s := radius
			var pts := PackedVector2Array([
				Vector2(0, -s) + center, Vector2(s, 0) + center,
				Vector2(0, s) + center, Vector2(-s, 0) + center])
			draw_colored_polygon(pts, body)
			var ol := pts.duplicate()
			ol.append(pts[0])
			draw_polyline(ol, line, 2.0)

func _draw_region(cell: Vector2i, n: int) -> void:
	var res: Dictionary = board.hexes_in_range(cell, n)
	# the footprint draws its own highlight on these cells, so don't also draw the
	# range grid under it (that grid showing through was the "internal lines")
	var fp := {}
	for c in board.footprint(cell):
		fp[c] = true
	# out of view (hidden behind a wall) OR a blocking tile itself: warm overlay + X
	var hidden := Color(0.97, 0.55, 0.25)
	for c in res["shadowed"]:
		if not fp.has(c):
			_draw_hidden_cell(c, hidden)
	for c in res["blocked"]:
		if not fp.has(c):
			_draw_hidden_cell(c, hidden)
	# visible (clear line of sight): bright blue, mostly-transparent fill
	for c in res["visible"]:
		if fp.has(c):
			continue
		var poly: PackedVector2Array = board.hex_polygon(board.cell_center_world(c))
		draw_colored_polygon(poly, Color(RANGE_FILL.r, RANGE_FILL.g, RANGE_FILL.b, 0.14))
		_outline(poly, Color(RANGE_LINE.r, RANGE_LINE.g, RANGE_LINE.b, 0.85), 1.8)

func _draw_hidden_cell(c: Vector2i, hidden: Color) -> void:
	var wc: Vector2 = board.cell_center_world(c)
	var poly: PackedVector2Array = board.hex_polygon(wc)
	draw_colored_polygon(poly, Color(hidden.r, hidden.g, hidden.b, 0.16))
	_outline(poly, Color(hidden.r, hidden.g, hidden.b, 0.55), 1.5)
	_hatch(wc, Color(hidden.r, hidden.g, hidden.b, 0.6))

func _outline(poly: PackedVector2Array, col: Color, w: float) -> void:
	var ring := poly.duplicate()
	ring.append(poly[0])
	draw_polyline(ring, col, w)

func _hatch(center: Vector2, col: Color) -> void:
	# a couple of short diagonal strokes to read as "out of view"
	var r: float = board.HEX_SIZE * 0.5
	draw_line(center + Vector2(-r, -r) * 0.6, center + Vector2(r, r) * 0.6, col, 1.5)
	draw_line(center + Vector2(-r, r) * 0.6, center + Vector2(r, -r) * 0.6, col, 1.5)

# ---------------------------------------------------------------- ability badges
# A horizontal row of circular ability badges, centred just below the tower.
func badge_layout() -> Array:
	var out := []
	if not selected_active or badge_icons.is_empty():
		return out
	var center: Vector2 = board.cell_center_world(selected_cell)
	var n := badge_icons.size()
	var step := BADGE_R * 2.0 + BADGE_GAP
	var start_x := center.x - step * float(n - 1) * 0.5
	var y := center.y + GameBoard.TOWER_RADIUS + BADGE_R * 1.5 + 8.0
	for i in range(n):
		out.append({"icon": str(badge_icons[i]), "center": Vector2(start_x + step * float(i), y)})
	return out

func _draw_badge(center: Vector2, icon: String) -> void:
	var ring_w := BADGE_R * 0.025      # dark rim: 2.5% of the radius
	var halo_w := BADGE_R * 0.01       # thin white halo just outside, so the badge pops
	var dark := Color(0.04, 0.06, 0.09)
	draw_circle(center, BADGE_R, Color(0.93, 0.95, 0.97, 0.93))   # light disc
	draw_arc(center, BADGE_R, 0.0, TAU, 32, Color(dark.r, dark.g, dark.b, 0.97), ring_w, true)
	draw_arc(center, BADGE_R + ring_w * 0.5 + halo_w * 0.5, 0.0, TAU, 32, Color(1, 1, 1, 0.9), halo_w, true)
	var d := BADGE_R * 1.7              # icon draw size (square), centred in the badge
	var tex := _icon_texture(icon)
	if tex != null:
		draw_texture_rect(tex, Rect2(center - Vector2(d, d) * 0.5, Vector2(d, d)), false, Color(1, 1, 1, 1))

# Cached lookup of an ability's icon. Drop a file named <ability> into res://art/badges/
# in any of these formats (PNG wins, so it can override an SVG). No code changes needed to swap art.
func _icon_texture(name: String) -> Texture2D:
	if _icon_tex.has(name):
		return _icon_tex[name]
	var tex: Texture2D = null
	for ext in [".png", ".webp", ".svg"]:
		var path := "res://art/%s%s%s" % [ArtPaths.dir(name), name, ext]
		if ResourceLoader.exists(path):
			tex = load(path)
			break
	if tex != null:
		_icon_tex[name] = tex   # only cache successful loads, so a late import still resolves
	return tex
