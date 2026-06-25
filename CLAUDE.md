# HexTowerDefense — Claude Code project guide

Godot 4 hex-grid tower-defense game (binary/computing theme) plus a companion
content editor. Claude Code reads this file automatically at the start of every
session. It carries the project conventions and points to the active work.

**Current task: porting the renderer to 3D. See `REFACTOR_3D.md` for the full
decision record, status, and open assumptions — start there.**

---

## Environment & testing

- Do not assume Godot is runnable in every environment. If a `godot` binary is
  present, use it headless to catch compile/parse errors before handing work back
  (e.g. a `--headless` project-load / script-check pass). If it is **not** present
  (e.g. a restricted cloud sandbox), then GDScript is written and reasoned through
  but **NOT runtime-tested** — say so explicitly when delivering changes.
- `node` and `python` are available for offline testing. Unit-test editor logic,
  hex math, the bus clip-tile rule, and path smoothing that way rather than
  guessing — these are pure functions and don't need Godot.

## GDScript rules

- **Tab indentation only.** No leading spaces.
- **The `:=` inference trap.** `var x := something.method()` fails to compile when
  the right-hand side is untyped or a Variant — e.g. assigning from an untyped
  reference, from `Dictionary.get(...)`, or from array indexing. Give those an
  explicit type (`var x: Vector2 = ...`) or use a plain `=`. Known untyped refs
  include `board` and `_laser_target`.

## Data files are mine — do not edit their values

- **Never modify the CONTENT** of `data/enemies.json`, `data/towers.json`,
  `data/waves.json`, or `maps/*.json`. I customize these locally. You may add
  optional fields to the model/parser, but flag any format change and let me set
  the values. Since everything is under version control now, surface any JSON or
  format change clearly in the diff rather than burying it — nothing of mine gets
  overwritten without my seeing it.
- Keep **map/enemy JSON parsing backward compatible.** Tower format need not be
  backward compatible (I'll redefine my few towers).
- **Keep the schema docs current.** `docs/maps-format.md`, `docs/enemies-format.md`,
  `docs/towers-format.md`, and `docs/waves-format.md` describe the JSON formats. When
  a change touches a data format (new field, default, or parsing rule), update the
  matching schema doc in the same commit.

## Workflow

- The **repository is the source of truth** for the current code — read it
  directly. (There is no bundle to upload; that was a chat-era workaround and no
  longer applies.)
- Make changes on a branch and let me review them as a diff / pull request before
  they land.
- **Ask before pivoting on approach** rather than unilaterally switching.

---

## Architecture orientation (2D — the shipping game), scripts/

The logic layer is coordinate-and-data work on 2D plane coordinates (`Vector2`)
and is what the 3D port reuses unchanged.

- **hex_utils.gd** (HexUtils) — pointy-top odd-r ↔ axial math; pixel↔axial;
  `axial_distance`.
- **hex_map_data.gd / map_loader.gd** — map model + JSON loader; parses optional
  `blocking[]` (LOS walls); buildable = cells off the path and not blocking.
- **enemy_data.gd / enemy.gd** — enemy stats + traversal; multiply-decay on death;
  `ECC_RESIST` (90% damage resist) and `take_damage(amount, pierces_ecc)`.
- **tower_data.gd / tower.gd** — tower stats + three fire modes (single | radial |
  laser); `target_priority`; `_can_see(e)` gates targeting for encrypted enemies;
  ability flags (`bit_corruption`, `cipher`) read at moment of use.
- **projectile.gd / radial_projectile.gd** — homing single shot; straight pierce
  spoke.
- **game_board.gd** (GameBoard) — grid render, `world_cell`, `cell_center_world`,
  `hex_polygon`, `has_los`, `blocking_set`, enemy list, `hexes_in_range`
  (visible vs wall-shadowed split). The 3D port mirrors this API.
- **board_overlay.gd** — tower view as hex-tile region (visible tinted, shadowed
  hatched).
- **game_content.gd / wave_loader.gd** — load towers/enemies/waves from JSON with
  embedded defaults.
- **main.gd** (Main) — right pane (money/lives, wave picker, speed, towers),
  drag/click placement, range overlay.

### Editor (editor/)
- **editor_app.py** — pywebview desktop app exposing get_state/save via a JS bridge.
- **editor.html** — tabbed editor (Maps / Enemies / Waves / Towers) with the map
  tile painter, wall brush + auto-route, ability-flag fields, and per-row up/down
  reordering (order is saved into JSON key order; tower order drives the in-game
  build-bar order).
