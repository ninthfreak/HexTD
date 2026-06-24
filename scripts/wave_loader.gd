class_name WaveLoader
## Loads the wave schedule from data/waves.json.
##
## Each wave has an optional "name" (defaults to 1-based index) and a list of
## groups.  Each group has: type, count, gap, and an optional "start" (seconds
## from wave start, default 0).
##
## Timeline rules (backward-compat):
##   • If NO group in a wave specifies "start", groups chain end-to-end
##     (sequential, matching old behaviour).
##   • If ANY group specifies "start", every group uses its own start time
##     (absolute timeline — groups may overlap).
##
## build_timeline() returns a sorted Array of {time: float, type: String} for
## the spawn runner to consume.

const WAVES_PATH := "res://data/waves.json"
const DEFAULT_WAVES_JSON := """
{
  "spawn_interval_default": 0.7,
  "waves": [
    { "groups": [ { "type": "bit", "count": 12, "gap": 0.55 } ] },
    { "groups": [ { "type": "2bit", "count": 6, "gap": 0.8 }, { "type": "bit", "count": 8, "gap": 0.45 } ] },
    { "groups": [ { "type": "nybble", "count": 4, "gap": 1.1 }, { "type": "2bit", "count": 8, "gap": 0.6 } ] },
    { "groups": [ { "type": "byte", "count": 2, "gap": 1.6 }, { "type": "nybble", "count": 5, "gap": 0.9 }, { "type": "bit", "count": 14, "gap": 0.35 } ] }
  ]
}
"""

static func load_waves() -> Dictionary:
	var text := FileAccess.get_file_as_string(WAVES_PATH)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		data = JSON.parse_string(DEFAULT_WAVES_JSON)
	if typeof(data) != TYPE_DICTIONARY:
		return {"spawn_interval_default": 0.7, "waves": []}
	return data

## Return the display name for a wave dictionary. Falls back to the 1-based
## index formatted as a string.
static func wave_name(wave: Dictionary, index: int) -> String:
	var n = wave.get("name", "")
	if n is String and n != "":
		return n
	return str(index + 1)

## Build a sorted spawn timeline for one wave.
## Returns Array of { "time": float, "type": String }, sorted by time.
static func build_timeline(wave: Dictionary, default_gap: float) -> Array:
	var groups: Array = wave.get("groups", [])
	if groups.is_empty():
		return []

	var has_explicit_start := false
	for g in groups:
		if g.has("start"):
			has_explicit_start = true
			break

	var events: Array = []

	if has_explicit_start:
		for g in groups:
			var t := str(g.get("type", "bit"))
			var c: int = int(g.get("count", 1))
			var gap: float = float(g.get("gap", default_gap))
			var start: float = float(g.get("start", 0.0))
			for k in range(c):
				events.append({"time": start + float(k) * gap, "type": t})
	else:
		var cursor := 0.0
		for g in groups:
			var t := str(g.get("type", "bit"))
			var c: int = int(g.get("count", 1))
			var gap: float = float(g.get("gap", default_gap))
			for k in range(c):
				events.append({"time": cursor + float(k) * gap, "type": t})
			cursor += float(c) * gap

	events.sort_custom(func(a, b): return a["time"] < b["time"])
	return events
