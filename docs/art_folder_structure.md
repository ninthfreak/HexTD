# art/ folder reorganization — execution spec

**Goal:** declutter the flat `art/` folder (46 files) into four function-based
subfolders, and update the GDScript art-path loaders so every existing call site
keeps working unchanged.

**In scope:** the file moves + the code changes described in §2–§4.
**Out of scope** (do NOT do these unless I confirm separately): the optional
follow-ups in §7.

**Hard constraints (read first):**
- This repo's GDScript uses **tab indentation only**. All code below is tabbed.
- Watch the `:=` inference rule: never infer a type from an untyped value. The
  snippets below already use explicit types where needed.
- **Do not modify the contents of** `data/*.json` or `maps/*.json`.
- Godot can't be run in the authoring sandbox; reason through the GDScript, don't
  assume it was runtime-tested. It must be verified by opening the project in Godot
  (see §5).
- Preserve git history: use `git mv`, not delete+add.
- Keep the `tower_` filename prefix (it mirrors the `data/towers.json` keys, and the
  resolver relies on it).

---

## 1. Target structure

```
art/
├── badges/      # ability-flag badges: flat icon + 3-layer parallax set
│   ├── bit_corruption.svg .png _backplate.png _glyph.png _rim.png
│   ├── buffer_overflow.png _backplate.png _glyph.png _rim.png
│   ├── cipher.svg .png _backplate.png _glyph.png _rim.png
│   ├── dos.svg _backplate.png _glyph.png _rim.png
│   └── tunneling.svg .png _backplate.png _glyph.png _rim.png
├── towers/      # tower selection buttons (filenames keep the tower_ prefix)
│   └── tower_basic.png tower_jammer.png tower_laser.png
│       tower_machinegun.png tower_radial.png tower_slow.png
├── ui/          # sandbox / transport control buttons
│   ├── pause.svg play.svg
│   ├── speed_1x.svg speed_2x.svg speed_3x.svg
│   ├── wave_start.svg wave_inprogress.svg
│   ├── sound_on.svg/.png sound_off.svg/.png
│   ├── spawn_enemy.svg/.png spawn_enemies.svg/.png
│   └── cheat_money.svg/.png
└── hud/         # frameless status readouts
    ├── lives.png
    └── money.png
```

No `.import` sidecars or `.godot/` are tracked in this repo (both gitignored), so
there are no import files to move and none to commit — only the raw assets move.
Godot regenerates imports on next open (§5).

---

## 2. File moves

Run from the repo root. The globs map 1:1 onto the four folders.

```bash
cd art
mkdir -p badges towers ui hud

# badges (23 files)
git mv bit_corruption* buffer_overflow* cipher* dos* tunneling* badges/

# towers (6 files)
git mv tower_* towers/

# ui (17 files)
git mv pause* play* speed_* wave_* sound_* spawn_* cheat_money* ui/

cd ..
git status        # confirm 46 renames, nothing left loose in art/ root
```

After moving, `art/` root should contain only the four subfolders. `lives.png` and
`money.png` are new (not currently in the repo) — they're added directly into
`art/hud/` in §3, not moved.

---

## 3. New / updated assets

These PNGs are uploaded alongside this spec (authored this session). Place them at:

- `art/hud/money.png`   — new wireframe currency HUD icon
- `art/hud/lives.png`   — accepted wireframe heart HUD icon (not previously committed)
- `art/ui/cheat_money.png` — rebuilt cheat button (overwrites the moved one)

`art/ui/cheat_money.svg` still holds the **old** `$`-coin glyph and no longer matches
`cheat_money.png`. Leave it for now (its disposition is an §7 follow-up).

---

## 4. Code changes

**Design intent:** one routing rule lives in a new shared helper; the five art
loaders each insert that subfolder into the path they already build. **Do not**
rewrite the ~15 call sites (e.g. `_load_icon("pause")`) to carry subpaths — call
sites stay exactly as they are.

### 4a. New file — `scripts/art_paths.gd`

```gdscript
class_name ArtPaths
extends RefCounted

# Folder routing for everything under res://art/. Centralized here so the loaders
# in main_3d.gd / tower_3d.gd / board_overlay.gd keep their call sites unchanged —
# only the path each builds is run through dir().

const _BADGES := ["bit_corruption", "buffer_overflow", "cipher", "dos", "tunneling"]
const _LAYER_SUFFIXES := ["_glyph", "_backplate", "_rim"]
const _HUD := ["lives", "money"]

# Bare asset name (no extension) -> art subfolder, with trailing slash.
# e.g. "pause" -> "ui/", "dos_glyph" -> "badges/", "tower_basic" -> "towers/",
#      "money" -> "hud/".
static func dir(asset: String) -> String:
	if asset.begins_with("tower_"):
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
```

Note: `dir()` is `static`, so it's callable from `tower_3d.gd`'s static
`_badge_texture` as well as the instance loaders.

### 4b. `scripts/main_3d.gd`

Three single-line path edits. Function bodies and caches are otherwise unchanged.

In `_load_icon(file)`:
```gdscript
# before
	var path := "res://art/%s.svg" % file
# after
	var path := "res://art/%s%s.svg" % [ArtPaths.dir(file), file]
```

In `_load_art(file)`:
```gdscript
# before
	var path := "res://art/%s.png" % file
# after
	var path := "res://art/%s%s.png" % [ArtPaths.dir(file), file]
```

In `_load_tower_pic(id)` (towers-only, so hardcode the subfolder):
```gdscript
# before
	var path := "res://art/tower_%s.png" % id
# after
	var path := "res://art/towers/tower_%s.png" % id
```

`_load_art` intentionally routes both UI assets (`sound_on`, `spawn_enemy`, …) and
badge glyphs (it's called as `_load_art(file + "_glyph")` in `_update_badge_tooltip`);
the resolver handles both. No change needed at those call sites.

### 4c. `scripts/tower_3d.gd`

In the static `_badge_texture(file)` (`file` is e.g. `"dos_glyph"`; `ext` includes the dot):
```gdscript
# before
		var path := "res://art/%s%s" % [file, ext]
# after
		var path := "res://art/%s%s%s" % [ArtPaths.dir(file), file, ext]
```

### 4d. `scripts/board_overlay.gd`

In `_icon_texture(name)` (`name` is an ability/flag name; `ext` includes the dot):
```gdscript
# before
		var path := "res://art/%s%s" % [name, ext]
# after
		var path := "res://art/%s%s%s" % [ArtPaths.dir(name), name, ext]
```

Also update the nearby comment that says "Drop a file named `<ability>` into
`res://art/`" to point at `res://art/badges/`.

---

## 5. Verification

1. **No stray flat-folder paths remain.** This should return nothing:
   ```bash
   grep -rn 'res://art/%s' scripts/ | grep -v 'art/%s%s' | grep -v 'towers/tower_'
   ```
   (The tower line `res://art/towers/tower_%s.png` and the resolver-prefixed
   `art/%s%s…` lines are the only allowed forms.)
2. **Confirm the tree** matches §1; `art/` root holds only the four subfolders.
3. **Re-import in Godot.** Open the project once so Godot re-imports all moved
   assets into their new paths (regenerates the gitignored `.import`/`.godot` cache).
   `ResourceLoader.exists(...)` returns false until this happens, so do it before
   smoke-testing.
4. **Smoke test** the sandbox scene: tower build-bar icons, the transport/UI
   buttons (pause/play/speed/wave/sound/spawn/cheat), ability-badge tooltips and
   the board overlay ability icons, and the lives/money HUD readouts all load.

---

## 6. Commit

Suggested split for reviewability:
1. moves only (`git mv …`) + the new `art/hud/*` and updated `art/ui/cheat_money.png`,
2. the code changes (`scripts/art_paths.gd` + the four edited scripts).

---

## 7. Optional follow-ups — do NOT do unless I confirm

- **Wire the HUD icons.** There is currently no `_load_art("money")` / `_load_art("lives")`
  anywhere; the money/lives readouts aren't pulling these textures yet. Wiring them
  is a separate change.
- **Standardize badge sets.** `buffer_overflow` is missing its flat `.svg` and `dos`
  is missing its flat `.png`, while the other three badges have both. Decide whether
  to fill the gaps or drop the flat variants entirely.
- **Remove the stale `art/ui/cheat_money.svg`** (old `$`-coin glyph) once the PNG is
  confirmed as the authoritative cheat-button asset.
- **Update `docs/ICONS_README.md`** to reflect the new subfolder paths (it's already
  noted as stale in the visual-design handoff; `CLAUDE.md` asks for it to be updated
  when icon work lands).
