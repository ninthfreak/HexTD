extends Control
## Start menu: lists available maps and launches the chosen one.

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(380, 0)
	center.add_child(col)

	var title := Label.new()
	title.text = "HEX TOWER DEFENSE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	col.add_child(title)

	var sub := Label.new()
	sub.text = "Select a map"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.modulate = Color(1, 1, 1, 0.6)
	col.add_child(sub)

	col.add_child(HSeparator.new())

	for entry in Levels.map_entries():
		var b := Button.new()
		b.text = entry["name"]
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(_on_pick.bind(entry["path"]))
		col.add_child(b)

	var hint := Label.new()
	hint.text = "Add maps by dropping .json files from the editor into the maps/ folder."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.modulate = Color(1, 1, 1, 0.45)
	col.add_child(hint)

func _on_pick(path: String) -> void:
	GameState.selected_path = path
	get_tree().change_scene_to_file("res://scenes/main.tscn")
