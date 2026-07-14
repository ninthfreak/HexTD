extends Control
## Start menu. Two steps: first pick a mode (Play Game / Sandbox), then pick a map.
## The chosen mode is stashed in GameState and read by Main3D to decide which
## controls to expose. Styled entirely in code (no assets) to match the in-game
## neon-on-dark look: cyan-bordered dark buttons, a faint drifting hex grid, and
## short fade transitions between steps.

const BUS_COLOR := Color(0.15, 0.85, 1.00)   # neon cyan — same as the board's bus edge

var col: VBoxContainer
var _fade: ColorRect          # fullscreen black overlay for the exit transition
var _step_tween: Tween

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = _build_theme()

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Faint hex grid + vignette over the flat base color, drawn by a tiny
	# canvas shader — ties the menu to the glowing hex board behind it.
	var grid := ColorRect.new()
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.material = _grid_material()
	add_child(grid)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	col = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(380, 0)
	center.add_child(col)

	# Exit fade sits above everything; transparent + click-through until a map
	# is picked.
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)

	_show_mode_choice()

# ---- theming (all code-built, no assets) ----

func _build_theme() -> Theme:
	var t := Theme.new()
	var normal := _button_box(Color(0.10, 0.13, 0.18), Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.30))
	var hover := _button_box(Color(0.13, 0.18, 0.25), Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.85))
	var pressed := _button_box(Color(0.07, 0.10, 0.14), Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.85))
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", hover)   # keyboard nav reads like hover
	t.set_color("font_color", "Button", Color(0.85, 0.92, 1.0))
	t.set_color("font_hover_color", "Button", Color(1, 1, 1))
	t.set_color("font_pressed_color", "Button", Color(1, 1, 1))
	t.set_color("font_focus_color", "Button", Color(1, 1, 1))
	t.set_color("font_disabled_color", "Button", Color(0.85, 0.92, 1.0, 0.4))
	return t

func _button_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

# Secondary buttons (Back): border only, no panel fill.
func _style_secondary(b: Button) -> void:
	var normal := _button_box(Color(0, 0, 0, 0), Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.30))
	var hover := _button_box(Color(0, 0, 0, 0), Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.85))
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", hover)

# Faint hex-line grid with a slow drift, plus a radial vignette that darkens
# the edges so the menu column stays the focus.
func _grid_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;

const vec3 LINE_COLOR = vec3(0.15, 0.85, 1.0);
const vec3 EDGE_COLOR = vec3(0.03, 0.045, 0.06);
const float CELL_PX = 64.0;

// Hex distance: 0 at a cell center, 0.5 on the cell edge.
float hex_dist(vec2 p) {
	p = abs(p);
	return max(dot(p, vec2(0.5, 0.8660254)), p.x);
}

void fragment() {
	// Two staggered rectangular lattices make the hex cells; TIME gives a
	// slow diagonal drift.
	vec2 p = FRAGCOORD.xy / CELL_PX + TIME * 0.008 * vec2(0.6, 1.0);
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(p, r) - h;
	vec2 b = mod(p - h, r) - h;
	vec2 gv = (dot(a, a) < dot(b, b)) ? a : b;
	float line = smoothstep(0.46, 0.5, hex_dist(gv));
	float a_line = line * 0.045;
	float a_vig = smoothstep(0.4, 0.72, length(UV - vec2(0.5))) * 0.35;
	// Composite the two translucent layers (grid under vignette) into one output.
	float a_out = a_line + a_vig * (1.0 - a_line);
	vec3 rgb = a_out > 0.0001 ? (LINE_COLOR * a_line * (1.0 - a_vig) + EDGE_COLOR * a_vig) / a_out : EDGE_COLOR;
	COLOR = vec4(rgb, a_out);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

# ---- step plumbing ----

# Replace the column's contents (used when stepping between the two screens).
func _clear() -> void:
	for c in col.get_children():
		col.remove_child(c)
		c.queue_free()

# Fade/slide the rebuilt column in. Waits a frame so the CenterContainer has
# laid the new content out before we nudge it off its resting spot.
func _animate_step_in() -> void:
	if _step_tween != null and _step_tween.is_valid():
		_step_tween.kill()
	col.modulate.a = 0.0
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var base_y := col.position.y
	col.position.y = base_y + 8.0
	_step_tween = create_tween().set_parallel()
	_step_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_step_tween.tween_property(col, "modulate:a", 1.0, 0.15)
	_step_tween.tween_property(col, "position:y", base_y, 0.15)

func _header(subtext: String) -> void:
	var title := Label.new()
	title.text = "HEX TOWER DEFENSE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Synthesised bold + soft black outline, same trick as the in-game banner.
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.variation_embolden = 0.6
	title.add_theme_font_override("font", fv)
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", BUS_COLOR)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	title.add_theme_constant_override("outline_size", 8)
	col.add_child(title)

	# Binary flavor line — "Hex" in ASCII, barely there.
	var flavor := Label.new()
	flavor.text = "01001000 01100101 01111000"
	flavor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flavor.add_theme_font_size_override("font_size", 13)
	flavor.add_theme_color_override("font_color", Color(BUS_COLOR.r, BUS_COLOR.g, BUS_COLOR.b, 0.25))
	col.add_child(flavor)

	var sub := Label.new()
	sub.text = subtext
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.6)
	col.add_child(sub)

	col.add_child(HSeparator.new())

# ---- step 1: mode ----
func _show_mode_choice() -> void:
	_clear()
	_header("Choose a mode")

	var tutorial := Button.new()
	tutorial.text = "How to Play"
	tutorial.custom_minimum_size = Vector2(0, 46)
	tutorial.pressed.connect(_on_mode.bind("tutorial"))
	col.add_child(tutorial)

	var play := Button.new()
	play.text = "Play Game"
	play.custom_minimum_size = Vector2(0, 46)
	play.pressed.connect(_on_mode.bind("game"))
	col.add_child(play)

	var sandbox := Button.new()
	sandbox.text = "Sandbox"
	sandbox.custom_minimum_size = Vector2(0, 46)
	sandbox.pressed.connect(_on_mode.bind("sandbox"))
	col.add_child(sandbox)

	var hint := Label.new()
	hint.text = "How to Play walks you through the basics. Play Game runs the waves in order. Sandbox gives you cheats and free spawning."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.modulate = Color(1, 1, 1, 0.45)
	col.add_child(hint)

	_animate_step_in()

func _play_click() -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am:
		am.play_sfx("ui_click")

func _on_mode(mode: String) -> void:
	_play_click()
	GameState.mode = mode
	_show_map_list()

# ---- step 2: map ----
func _show_map_list() -> void:
	_clear()
	_header("Select a map")

	for entry in Levels.map_entries():
		col.add_child(_map_button(entry))

	var back := Button.new()
	back.text = "← Back"
	back.custom_minimum_size = Vector2(0, 36)
	back.pressed.connect(func() -> void:
		_play_click()
		_show_mode_choice())
	_style_secondary(back)
	col.add_child(back)

	var hint := Label.new()
	hint.text = "Add maps by dropping .json files from the editor into the maps/ folder."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.modulate = Color(1, 1, 1, 0.45)
	col.add_child(hint)

	_animate_step_in()

# One map entry: the name on the left, a dim size/route summary on the right.
func _map_button(entry: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 46)
	b.pressed.connect(_on_pick.bind(entry["path"]))

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14        # match the button stylebox content margins
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)

	var name_l := Label.new()
	name_l.text = str(entry["name"])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)

	var tiles: int = entry.get("tiles", 0)
	var path_len: int = entry.get("path_len", 0)
	if tiles > 0:
		var meta_l := Label.new()
		meta_l.text = "%d tiles · path %d" % [tiles, path_len]
		meta_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		meta_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		meta_l.add_theme_font_size_override("font_size", 12)
		meta_l.modulate = Color(1, 1, 1, 0.5)
		meta_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(meta_l)

	return b

func _on_pick(path: String) -> void:
	_play_click()
	GameState.selected_path = path
	# Fade to black, then swap scenes from the tween callback.
	_fade.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks during the fade
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", 1.0, 0.2)
	tw.tween_callback(func() -> void:
		get_tree().change_scene_to_file("res://scenes/main_3d.tscn"))
