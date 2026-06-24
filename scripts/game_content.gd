class_name GameContent
## Registry of towers and enemies, both loaded from data/*.json with built-in
## fallbacks so the game always runs. Edit the JSON (or use the editor) to change
## or add content.

const TOWERS_PATH := "res://data/towers.json"
const ENEMIES_PATH := "res://data/enemies.json"

const DEFAULT_TOWERS_JSON := """
{
  "basic": { "name": "Basic Tower", "color": "#59b2ff", "range": 150, "fire_rate": 1.6, "damage": 9, "cost": 40, "projectile_speed": 340 }
}
"""

const DEFAULT_ENEMIES_JSON := """
{
  "bit":    { "name": "bit",    "shape": "square",  "side": 14,              "color": "#6ad36a", "health": 12,  "speed": 100, "reward": 2,  "reduces_to": "" },
  "2bit":   { "name": "2-bit",  "shape": "rect",    "length": 28, "width": 14, "color": "#4dd0c0", "health": 24,  "speed": 88,  "reward": 3,  "reduces_to": "bit" },
  "nybble": { "name": "nybble", "shape": "square",  "side": 28,              "color": "#4d9be8", "health": 52,  "speed": 74,  "reward": 7,  "reduces_to": "2bit" },
  "byte":   { "name": "byte",   "shape": "octagon", "radius": 22,            "color": "#b06ae8", "health": 116, "speed": 60,  "reward": 16, "reduces_to": "nybble" }
}
"""

var _towers := {}
var _tower_order: Array = []
var _enemies := {}

func _init() -> void:
	_load_towers()
	_load_enemies()

# ---------------------------------------------------------------- towers
func _load_towers() -> void:
	var data = _read_json(TOWERS_PATH, DEFAULT_TOWERS_JSON)
	if typeof(data) != TYPE_DICTIONARY:
		return
	for id in data.keys():
		_towers[str(id)] = _tower_from_dict(data[id])
		_tower_order.append(str(id))

func _tower_from_dict(d: Dictionary) -> TowerData:
	var t := TowerData.new()
	t.display_name = str(d.get("name", "Tower"))
	t.color = _color(str(d.get("color", "#59b2ff")))
	t.range_tiles = maxi(1, int(d.get("range", 3)))
	t.fire_rate = float(d.get("fire_rate", 1.5))
	t.damage = float(d.get("damage", 10))
	t.cost = int(d.get("cost", 40))
	t.projectile_speed = float(d.get("projectile_speed", 320))
	t.fire_mode = str(d.get("fire_mode", "single"))
	t.directions = maxi(1, int(d.get("directions", 6)))
	t.ignore_walls = bool(d.get("ignore_walls", false))
	t.ramp_time = maxf(0.05, float(d.get("ramp_time", 2.0)))
	t.bit_corruption = bool(d.get("bit_corruption", false))
	t.cipher = bool(d.get("cipher", false))
	t.buffer_overflow = bool(d.get("buffer_overflow", false))
	t.height_scale = maxf(0.05, float(d.get("height_scale", 1.0)))
	t.width_scale = maxf(0.05, float(d.get("width_scale", 1.0)))
	t.upgrades = _parse_upgrades(d.get("upgrades", []))
	return t

## Normalize the optional upgrade slots (max 3 slots, max 5 tiers each). Numeric stats
## are additive deltas; flags are "on"/"off"; absent keys mean "no change". Tolerates the
## older flat tier list by wrapping it as a single slot.
func _parse_upgrades(arr) -> Array:
	var out := []
	if typeof(arr) != TYPE_ARRAY:
		return out
	for slot_raw in arr:
		var name := "Slot %d" % (out.size() + 1)
		var tiers_raw = slot_raw
		if typeof(slot_raw) == TYPE_DICTIONARY and slot_raw.has("tiers"):
			name = str(slot_raw.get("name", name))
			tiers_raw = slot_raw["tiers"]
		var tiers := []
		if typeof(tiers_raw) == TYPE_ARRAY:
			for u in tiers_raw:
				if typeof(u) != TYPE_DICTIONARY:
					continue
				var tier := {"cost": int(u.get("cost", 0))}
				for stat in ["damage", "range", "fire_rate", "directions", "ramp_time", "height", "width"]:
					if u.has(stat):
						tier[stat] = float(u[stat])
				for flag in ["cipher", "bit_corruption", "ignore_walls", "buffer_overflow"]:
					if u.has(flag):
						tier[flag] = str(u[flag])
				if u.has("color") and str(u["color"]) != "":
					tier["color"] = str(u["color"])
				tiers.append(tier)
				if tiers.size() >= 5:
					break
		out.append({"name": name, "tiers": tiers})
		if out.size() >= 3:
			break
	return out

func tower(id: String) -> TowerData:
	return _towers[id]

func tower_ids() -> Array:
	return _tower_order

# ---------------------------------------------------------------- enemies
func _load_enemies() -> void:
	var data = _read_json(ENEMIES_PATH, DEFAULT_ENEMIES_JSON)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var rank := 0
	for id in data.keys():
		var e := _enemy_from_dict(str(id), data[id])
		e.rank = rank   # JSON key order = editor order; top of the list = rank 0
		_enemies[str(id)] = e
		rank += 1
	for id in _enemies.keys():
		var e: EnemyData = _enemies[id]
		if e.reduces_to_id != "" and _enemies.has(e.reduces_to_id):
			e.reduces_to = _enemies[e.reduces_to_id]

func _enemy_from_dict(id: String, d: Dictionary) -> EnemyData:
	var e := EnemyData.new()
	e.id = id
	e.display_name = str(d.get("name", id))
	e.shape = str(d.get("shape", "square"))
	e.color = _color(str(d.get("color", "#dd5555")))
	e.health = float(d.get("health", 20))
	e.speed = float(d.get("speed", 90))
	e.reward = int(d.get("reward", 3))
	e.glow = float(d.get("glow", 1.0))
	e.side = float(d.get("side", 16))
	e.length = float(d.get("length", 32))
	e.width = float(d.get("width", 16))
	e.radius = float(d.get("radius", 16))
	e.sides = int(d.get("sides", 8))
	var rt = d.get("reduces_to", "")
	e.reduces_to_id = "" if rt == null else str(rt)
	e.reduce_count = maxi(1, int(d.get("reduce_count", 1)))
	e.ecc = bool(d.get("ecc", false))
	e.encrypted = bool(d.get("encrypted", false))
	e.death_sound = str(d.get("death_sound", ""))
	return e

func enemy(id: String) -> EnemyData:
	return _enemies.get(id, null)

func enemy_ids() -> Array:
	return _enemies.keys()

# ---------------------------------------------------------------- helpers
func _read_json(path: String, fallback: String):
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		data = JSON.parse_string(fallback)
	return data

func _color(s: String) -> Color:
	return Color.html(s)
