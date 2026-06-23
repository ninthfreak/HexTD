class_name WaveLoader
## Loads the wave schedule from data/waves.json (see that file for the format),
## falling back to a built-in default so the game always runs.

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
