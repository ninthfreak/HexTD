class_name Levels
## Provides levels to the game.
##
## It loads map files (made in the graphical editor) from res://maps/*.json,
## sorted by filename. If none are found, it falls back to a generated demo map
## so the project always runs.
##
## Drop a .json exported from the map editor into the project's `maps/` folder
## and it appears here automatically.

const MAPS_DIR := "res://maps"

static func map_paths() -> Array:
	var paths: Array = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.to_lower().ends_with(".json"):
				paths.append(MAPS_DIR + "/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	paths.sort()
	return paths

static func count() -> int:
	var n := map_paths().size()
	return n if n > 0 else 1

## Menu entries: one {name, path} per map file, plus a generated demo fallback.
static func map_entries() -> Array:
	var entries: Array = []
	for p in map_paths():
		entries.append({"name": _name_of(p), "path": p})
	if entries.is_empty():
		entries.append({"name": "Generated Demo", "path": ""})
	return entries

static func _name_of(path: String) -> String:
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY and data.has("name"):
		return str(data["name"])
	return path.get_file()

## Load a specific map file, or the generated demo when the path is empty/invalid.
static func get_by_path(path: String) -> HexMapData:
	if path != "":
		var m := MapLoader.load_file(path)
		if m != null:
			return m
	return _generated_demo()

static func get_level(index: int) -> HexMapData:
	var paths := map_paths()
	if paths.size() > 0:
		var i: int = clampi(index, 0, paths.size() - 1)
		var m := MapLoader.load_file(paths[i])
		if m != null:
			return m
	return _generated_demo()

## Fallback: a serpentine path on a large grid (used only if maps/ is empty).
static func _generated_demo() -> HexMapData:
	var path := _serpentine(24, 1, 13, 3)
	return _build(24, 16, path, "Generated Demo")

static func _serpentine(cols: int, first_row: int, last_row: int, band: int) -> Array:
	var path: Array = []
	var r := first_row
	var going_right := true
	while true:
		if going_right:
			for c in range(cols):
				_push(path, Vector2i(c, r))
		else:
			for c in range(cols - 1, -1, -1):
				_push(path, Vector2i(c, r))
		var next_r := r + band
		if next_r > last_row:
			break
		var end_col := cols - 1 if going_right else 0
		for rr in range(r + 1, next_r + 1):
			_push(path, Vector2i(end_col, rr))
		r = next_r
		going_right = not going_right
	return path

static func _push(path: Array, cell: Vector2i) -> void:
	if path.is_empty() or path[path.size() - 1] != cell:
		path.append(cell)

static func _build(cols: int, rows: int, path_offset: Array, name: String) -> HexMapData:
	var m := HexMapData.new()
	m.display_name = name
	var all_cells: Array[Vector2i] = []
	for row in range(rows):
		for col in range(cols):
			all_cells.append(HexUtils.offset_to_axial(col, row))
	m.cells = all_cells
	var path: Array[Vector2i] = []
	for o in path_offset:
		path.append(HexUtils.offset_to_axial(o.x, o.y))
	m.path = path
	var on_path := {}
	for c in path:
		on_path[c] = true
	var buildable: Array[Vector2i] = []
	for c in all_cells:
		if not on_path.has(c):
			buildable.append(c)
	m.buildable = buildable
	m.spawn = path[0]
	m.goal = path[path.size() - 1]
	return m
