class_name MapLoader
## Loads maps exported from the graphical editor (.json) into HexMapData.
## Expected JSON shape (coordinates are offset [col, row]):
##   { "name", "cols", "rows", "spawn":[c,r], "goal":[c,r],
##     "path":[[c,r],...ordered...], "cells":[[c,r],...] }

static func load_file(path: String) -> HexMapData:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	return from_json(text)

static func from_json(text: String) -> HexMapData:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("MapLoader: could not parse map JSON.")
		return null
	if not (data.has("path") and data.has("spawn") and data.has("goal")):
		push_warning("MapLoader: map JSON missing required fields.")
		return null

	var m := HexMapData.new()
	m.display_name = data.get("name", "Map")

	var path: Array[Vector2i] = []
	for c in data["path"]:
		path.append(HexUtils.offset_to_axial(int(c[0]), int(c[1])))
	m.path = path

	var on_path := {}
	for c in path:
		on_path[c] = true

	# Bus = the route surface region (any width). A map with no "bus" field — an
	# old "trace"-keyed map not yet re-saved from the editor, or one that never had
	# the field — falls back to the path so it still loads.
	var bus: Array[Vector2i] = []
	var bus_set := {}
	if data.has("bus") and data["bus"] is Array and not data["bus"].is_empty():
		for c in data["bus"]:
			var t := HexUtils.offset_to_axial(int(c[0]), int(c[1]))
			bus.append(t)
			bus_set[t] = true
	else:
		bus = path.duplicate()
		bus_set = on_path.duplicate()
	m.bus = bus

	var blocking: Array[Vector2i] = []
	var block_set := {}
	if data.has("blocking"):
		for c in data["blocking"]:
			var b := HexUtils.offset_to_axial(int(c[0]), int(c[1]))
			blocking.append(b)
			block_set[b] = true
	m.blocking = blocking

	var cells: Array[Vector2i] = []
	if data.has("cells"):
		for c in data["cells"]:
			cells.append(HexUtils.offset_to_axial(int(c[0]), int(c[1])))
	else:
		cells = path.duplicate()
	m.cells = cells

	var buildable: Array[Vector2i] = []
	for c in cells:
		if not bus_set.has(c) and not block_set.has(c):
			buildable.append(c)
	m.buildable = buildable

	m.spawn = HexUtils.offset_to_axial(int(data["spawn"][0]), int(data["spawn"][1]))
	m.goal = HexUtils.offset_to_axial(int(data["goal"][0]), int(data["goal"][1]))

	# Optional per-map build-area tint ("#rrggbb"); absent -> the model's default.
	if data.has("build_color") and data["build_color"] is String and data["build_color"] != "":
		m.build_color = Color(str(data["build_color"]))
	return m
