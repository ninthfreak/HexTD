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
		if _hover:
			m *= 1.3
		draw_texture_rect(pic, Rect2(0, 0, d, d), false, m)
	else:
		# Placeholder hex until the art exists: dark base + a wash of the tower colour.
		draw_colored_polygon(_verts, Color(0.09, 0.11, 0.15, 0.96))
		var tint := base_color
		tint.a = 0.32 if _hover else 0.20
		draw_colored_polygon(_verts, tint)
		var outline := PackedVector2Array(_verts)
		outline.append(_verts[0])
		draw_polyline(outline, base_color.lightened(0.25) if _hover else base_color, 2.5, true)
	# Price along the bottom (drawn over the art's dark base).
	var pcol := Color(1, 1, 1) if affordable else Color(1, 0.42, 0.42)
	draw_string(get_theme_default_font(), Vector2(0, d * 0.87), "$%d" % cost,
		HORIZONTAL_ALIGNMENT_CENTER, d, int(d * 0.17), pcol)
