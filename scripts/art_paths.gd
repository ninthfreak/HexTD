class_name ArtPaths
extends RefCounted

# Folder routing for everything under res://art/. Centralized here so the loaders
# in main_3d.gd / tower_3d.gd / board_overlay.gd keep their call sites unchanged —
# only the path each builds is run through dir().

const _BADGES := ["bit_corruption", "buffer_overflow", "cipher", "dos", "tunneling"]
const _LAYER_SUFFIXES := ["_glyph", "_backplate", "_rim"]
const _HUD := ["lives", "money"]
const _TOWER_PREFIXES := ["tower_", "focus_", "rotate_"]

# Bare asset name (no extension) -> art subfolder, with trailing slash.
# e.g. "pause" -> "ui/", "dos_glyph" -> "badges/", "tower_basic" -> "towers/",
#      "money" -> "hud/".
static func dir(asset: String) -> String:
	for prefix in _TOWER_PREFIXES:
		if asset.begins_with(prefix):
			return "towers/"
	var base: String = asset
	for suffix in _LAYER_SUFFIXES:
		if base.ends_with(suffix):
			base = base.substr(0, base.length() - suffix.length())
			break
	if base in _BADGES:
		return "badges/"
	if asset in _HUD:
		return "hud/"
	return "ui/"
