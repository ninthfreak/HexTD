extends Control
## Start menu. Two steps: first pick a mode (Play Game / Sandbox), then pick a map.
## The chosen mode is stashed in GameState and read by Main3D to decide which
## controls to expose.

var col: VBoxContainer

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	col = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(380, 0)
	center.add_child(col)

	_show_mode_choice()

# Replace the column's contents (used when stepping between the two screens).
func _clear() -> void:
	for c in col.get_children():
		col.remove_child(c)
		c.queue_free()

func _header(subtext: String) -> void:
	var title := Label.new()
	title.text = "HEX TOWER DEFENSE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	col.add_child(title)

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

func _on_mode(mode: String) -> void:
	GameState.mode = mode
	_show_map_list()

# ---- step 2: map ----
func _show_map_list() -> void:
	_clear()
	_header("Select a map")

	for entry in Levels.map_entries():
		var b := Button.new()
		b.text = entry["name"]
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(_on_pick.bind(entry["path"]))
		col.add_child(b)

	var back := Button.new()
	back.text = "← Back"
	back.custom_minimum_size = Vector2(0, 36)
	back.pressed.connect(_show_mode_choice)
	col.add_child(back)

	var hint := Label.new()
	hint.text = "Add maps by dropping .json files from the editor into the maps/ folder."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.modulate = Color(1, 1, 1, 0.45)
	col.add_child(hint)

func _on_pick(path: String) -> void:
	GameState.selected_path = path
	get_tree().change_scene_to_file("res://scenes/main_3d.tscn")
