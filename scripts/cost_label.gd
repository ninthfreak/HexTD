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

func set_cost(prefix: String, value: int, suffix: String, dim: bool) -> void:
	_prefix = prefix
	_value = str(value)
	_suffix = suffix
	_dim = dim
	queue_redraw()

func set_plain(text: String, dim: bool) -> void:
	_prefix = text
	_value = ""
	_suffix = ""
	_dim = dim
	queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	var base_fs := get_theme_default_font_size()
	var sym_fs := int(base_fs * 1.5)
	var col := Color(1, 1, 1, 0.5 if _dim else 1.0)
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
		draw_string(font, Vector2(x, sym_y), "¤", HORIZONTAL_ALIGNMENT_LEFT, -1, sym_fs, col)
		x += sym_w
		draw_string(font, Vector2(x, base_y), _value, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs, col)
		x += val_w
		draw_string(font, Vector2(x, base_y), _suffix, HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs, col)
