class_name HexTowerButton
extends Control
## A hex-shaped tower build button: the tower's picture, its price along the bottom,
## and the name + description in the hover tooltip. Pressing it starts placement
## (the same drag model as the old text buttons). The clickable area is the hex
## itself (via `_has_point`) so honeycomb-packed neighbours never steal each other's
## clicks where their bounding boxes overlap.

signal tower_pressed(id: String)

# Unit hex (flat top/bottom, points left/right) matching the SVG hex art, so these
# buttons tessellate with the same offsets the honeycomb layout uses.
const HEX_N := [
	Vector2(0.96667, 0.5), Vector2(0.73333, 0.90417), Vector2(0.26667, 0.90417),
	Vector2(0.03333, 0.5), Vector2(0.26667, 0.09583), Vector2(0.73333, 0.09583),
]

var id := ""
var cost := 0
var base_color := Color.WHITE
var pic: Texture2D = null
var affordable := true
var _verts := PackedVector2Array()
var _hover := false
var _hover_amt := 0.0     # eased 0..1 hover brightness (lerped in _process)
var _hover_ms := 0        # wall-clock stamp — _process delta is 0 while paused

func _process(_delta: float) -> void:
	# Ease the hover brighten instead of snapping; only redraw while moving.
	# Wall-clock time so the ease still runs at time_scale 0 (paused).
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _hover_ms) / 1000.0, 0.0, 0.1)
	_hover_ms = now
	var target := 1.0 if _hover else 0.0
	if absf(_hover_amt - target) < 0.01:
		return
	_hover_amt = lerpf(_hover_amt, target, minf(1.0, 12.0 * dt))
	if absf(_hover_amt - target) < 0.01:
		_hover_amt = target
	queue_redraw()

func setup(tower_id: String, td: TowerData, picture: Texture2D, d: float) -> void:
	id = tower_id
	cost = td.cost
	base_color = td.color
	pic = picture
	custom_minimum_size = Vector2(d, d)
	size = Vector2(d, d)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var desc := td.description.strip_edges()
	tooltip_text = td.display_name if desc == "" else "%s\n\n%s" % [td.display_name, desc]
	_verts = PackedVector2Array()
	for v in HEX_N:
		_verts.append(v * d)

func _has_point(point: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(point, _verts)

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hover = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hover = false
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		tower_pressed.emit(id)

func set_affordable(v: bool) -> void:
	if v != affordable:
		affordable = v
		queue_redraw()

func _draw() -> void:
	var d := size.x
	if pic != null:
		# The art is a full hex face (dark tile + coloured rim baked in, transparent
		# outside the hex), so draw it across the whole cell — no extra hex frame, or
		# it would double-frame. Modulate handles hover-brighten / unaffordable-dim.
		# Unaffordable dims; hover brightens — and the two compose, so an unaffordable
		# tower (e.g. a pricey one you can't yet buy) still lights up on hover.
		var m := Color(0.5, 0.5, 0.5) if not affordable else Color(1, 1, 1)
		m *= lerpf(1.0, 1.3, _hover_amt)
		draw_texture_rect(pic, Rect2(0, 0, d, d), false, m)
	else:
		# Placeholder hex until the art exists: dark base + a wash of the tower colour.
		draw_colored_polygon(_verts, Color(0.09, 0.11, 0.15, 0.96))
		var tint := base_color
		tint.a = lerpf(0.20, 0.32, _hover_amt)
		draw_colored_polygon(_verts, tint)
		var outline := PackedVector2Array(_verts)
		outline.append(_verts[0])
		draw_polyline(outline, base_color.lightened(0.25 * _hover_amt), 2.5, true)
	# Price along the bottom. The ¤ currency glyph is small in the default font, so
	# draw it larger than the digits and centre the two as a pair — vertically
	# aligned by centring each glyph's font cell on a common line so they sit level.
	# Gold = affordable, red = not (same economy coding as the money stat and the
	# upgrade buttons), with a black outline so the price reads on any face.
	var pcol := Color(1.0, 0.82, 0.25) if affordable else Color(1, 0.42, 0.42)
	var font := get_theme_default_font()
	var num := str(cost)
	var num_fs := int(d * 0.18)
	var sym_fs := int(d * 0.30)
	var sym_w := font.get_string_size("¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs).x
	var num_w := font.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1, num_fs).x
	var gap := d * 0.02
	var x0 := (d - (sym_w + gap + num_w)) * 0.5
	var cy := d * 0.80
	var sym_y := cy + (font.get_ascent(sym_fs) - font.get_descent(sym_fs)) * 0.5
	var num_y := cy + (font.get_ascent(num_fs) - font.get_descent(num_fs)) * 0.5
	var ow := maxi(1, int(d * 0.03))
	draw_string_outline(font, Vector2(x0, sym_y), "¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs, ow, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2(x0, sym_y), "¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs, pcol)
	draw_string_outline(font, Vector2(x0 + sym_w + gap, num_y), num, HORIZONTAL_ALIGNMENT_LEFT, -1, num_fs, ow, Color(0, 0, 0, 0.8))
	draw_string(font, Vector2(x0 + sym_w + gap, num_y), num, HORIZONTAL_ALIGNMENT_LEFT, -1, num_fs, pcol)
