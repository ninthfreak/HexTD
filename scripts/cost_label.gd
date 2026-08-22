class_name CostLabel
extends Control
## A one-line, centred label that can draw a cost with the ¤ currency glyph
## enlarged AND vertically aligned with the digits — something neither a plain
## Button nor a RichTextLabel can do (RTL aligns mixed sizes by baseline, so a
## bigger ¤ floats high). Used as a mouse-ignoring overlay on the upgrade/sell
## buttons; the Button underneath still handles clicks, disabled and hover.

var _prefix := ""
var _value := ""      # number drawn after the ¤ ("" = no cost segment)
var _suffix := ""
var _dim := false
var _value_col := Color(1, 1, 1)   # ¤ + digits tint (economy color coding)
var _text_col := Color(1, 1, 1)    # prefix/suffix tint

func set_cost(prefix: String, value: int, suffix: String, dim: bool, value_col := Color(1, 1, 1)) -> void:
	# Callers push state every frame; only an actual change warrants a redraw.
	var v := str(value)
	if _prefix == prefix and _value == v and _suffix == suffix and _dim == dim \
			and _value_col == value_col and _text_col == Color(1, 1, 1):
		return
	_prefix = prefix
	_value = v
	_suffix = suffix
	_dim = dim
	_value_col = value_col
	_text_col = Color(1, 1, 1)
	queue_redraw()

func set_plain(text: String, dim: bool, col := Color(1, 1, 1)) -> void:
	if _prefix == text and _value == "" and _suffix == "" and _dim == dim and _text_col == col:
		return
	_prefix = text
	_value = ""
	_suffix = ""
	_dim = dim
	_text_col = col
	queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	var base_fs := get_theme_default_font_size()
	var sym_fs := int(base_fs * 1.5)
	# Dim washes the descriptive text; the ¤ amount keeps its own full-strength
	# color so "too expensive" (red) still pops on a greyed button.
	var col := Color(_text_col.r, _text_col.g, _text_col.b, _text_col.a * (0.5 if _dim else 1.0))
	var vcol := _value_col
	var pre_w := font.get_string_size(_prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs).x
	var sym_w := 0.0
	var val_w := 0.0
	var suf_w := 0.0
	if _value != "":
		sym_w = font.get_string_size("¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs).x
		val_w = font.get_string_size(_value, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs).x
		suf_w = font.get_string_size(_suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs).x
	var total := pre_w + sym_w + val_w + suf_w
	# Centre the whole line; align each piece's font cell on the vertical mid-line.
	var cy := size.y * 0.5
	var base_y := cy + (font.get_ascent(base_fs) - font.get_descent(base_fs)) * 0.5
	var sym_y := cy + (font.get_ascent(sym_fs) - font.get_descent(sym_fs)) * 0.5
	var x := (size.x - total) * 0.5
	draw_string(font, Vector2(x, base_y), _prefix, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs, col)
	x += pre_w
	if _value != "":
		draw_string(font, Vector2(x, sym_y), "¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs, vcol)
		x += sym_w
		draw_string(font, Vector2(x, base_y), _value, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs, vcol)
		x += val_w
		draw_string(font, Vector2(x, base_y), _suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs, col)
