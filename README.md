# Hex Tower Defense (Godot 4)

A small but real tower-defense starter on a large **hexagonal grid**, with a
right-hand tower pane, drag-and-drop or select-then-click placement, and live
range previews. Everything is drawn with basic shapes in code — no image assets.

## Run it

1. Open **Godot 4** (4.6 or newer).
2. Import this folder (select it / its `project.godot`).
3. Press **Play** (F5). You start on the **map menu** — pick a map. The window
   opens at 1920x1080 and is resizable.

## Sandbox mode

The game scene is a **sandbox** for now (it may stay this way): there is no
winning or losing screen. You pick a map, then in the right pane you can:

- **Start wave** — choose any wave from the dropdown and launch it; you can
  start more waves at any time (they stack), and the dropdown auto-advances.
- **Speed** — one button toggles 1x / 2x / 3x game speed.
- **Cheat: +funds** — adds money for testing (amount is `cheat_amount` in main.gd).
- **Exit to map select** — returns to the menu.

Enemies that reach the goal still cost a life (it bottoms out at 0, no game over).


## Controls

- **Build a tower** — either *drag* a tower from the right pane onto a green hex,
  or *click* a tower in the pane and then *click* a green hex (you stay armed to
  place several; right-click or **Esc** to stop).
- **See range** — shown while placing (follows the cursor; green = OK, red =
  blocked/too expensive), and when you click a tower that's already placed.
- **Start Wave** — sends enemies from the green spawn hex to the red goal.
- **Pan** — middle-mouse drag, or **WASD** / arrow keys.
- **Zoom** — mouse scroll wheel.
- **Cancel / deselect** — right-click or **Esc**.

Kill enemies to earn money; enemies that reach the goal cost a life. Clear all
waves to win.

## Project structure

```
project.godot            Config; main scene + window size
scenes/menu.tscn         Start menu (entry scene)
scenes/main.tscn         The game scene
data/enemies.json        Enemy definitions  (edit me)
data/waves.json          Wave schedule      (edit me)
data/towers.json         Tower definitions  (edit me)
scripts/
  hex_utils.gd           Hex math: offset<->axial, axial->pixel, rounding
  hex_map_data.gd        Resource: cells, path, buildable, spawn, goal
  levels.gd              Builds level data (serpentine path generator)
  tower_data.gd          Resource: one tower's stats
  enemy_data.gd          One enemy type (shape, stats, reduction)
  game_content.gd        Loads towers + enemies from data/*.json
  wave_loader.gd         Loads the wave schedule from data/waves.json
  menu.gd                Start menu: lists maps and launches one
  game_state.gd          Carries the chosen map from menu into the game
  map_loader.gd          Loads .json maps from the editor into HexMapData
  game_board.gd          Draws the grid, world<->hex helpers, holds entities
  board_overlay.gd       Draws range circles and the placement ghost
  tower.gd               Tower entity (targets + shoots)
  enemy.gd               Enemy entity (walks the path)
  projectile.gd          Homing shot
  main.gd                Game state, camera, UI pane, placement, waves
```

## Maps & the editor

All content — maps, enemies, waves, towers — is edited in the included **editor**
(in the `editor/` folder). It runs as a tiny local helper so it can open and save
your real game files directly:

```
cd <your game folder>
python editor.py            # or: python editor/editor.py
```

It opens in your browser, **auto-loads** `data/enemies.json`, `data/waves.json`,
`data/towers.json` and every map in `maps/`, and each tab has a **Save** button
that writes straight back to disk (with a confirmation). Closing the page warns
you if anything is unsaved. No more import/export. (Requires Python 3; the editor
files live in `editor/`.)

The **Maps** tab paints a hex grid with these tile types: **path** (the enemy
lane), **grass** (buildable), **spawn**/**goal** (route endpoints), and **block**
— a wall that towers cannot see or shoot through. It auto-solves the enemy route
and saves the map file.

**Blocking tiles & line of sight:** a tower only fires at an enemy it has a clear
straight line to. A `block` tile between a tower and an enemy hides that enemy
from it. Block tiles aren't buildable and aren't part of the route.

To use a map: drop the exported `.json` into this project's `maps/` folder. The
game loads every `.json` in there (sorted by filename); `maps/level.json` is a
ready-made example. If the folder is empty, a generated demo map is used so the
project still runs.

No code or coordinates required — the map you paint is the map you play.

## How to extend

**Make a map** — Use the Hex Map Editor (see above); no code needed.

**Generated fallback** — In `levels.gd`, `get_level()` calls
`_build(cols, rows, _serpentine(cols, first_row, last_row, band), name)`.
Change the numbers: `band` controls how much open space sits between path rows.
For a fully hand-drawn path, pass your own ordered list of `(col, row)` cells
(each step one hex left/right/up/down) instead of `_serpentine(...)`.

**Add a map** — Add a branch in `get_level()` (`match index`) returning a
different `_build(...)`, then load it from `main.gd` with `Levels.get_level(1)`.

**Add a tower** — In `game_content.gd._init()`, add another
`_add_tower("id", _make_tower(name, color, range, fire_rate, damage, cost,
projectile_speed))`. It automatically appears as a button in the pane.

**Edit or add an enemy** — Open `data/enemies.json`. Each entry is
`"id": { ...fields }`:

| field | meaning |
|-------|---------|
| `name` | label shown in-game |
| `shape` | `square`, `rect`, `octagon`, or `polygon` |
| `color` | hex string, e.g. `"#4dd0c0"` |
| `health` | hit points for this form |
| `speed` | pixels per second |
| `reward` | money granted when this form is destroyed |
| `side` | square edge length |
| `length` / `width` | rect size along / across the path (a `rect` leads with a short side) |
| `radius` / `sides` | octagon / polygon size (and side count for `polygon`) |
| `reduces_to` | id of the smaller enemy this becomes when killed; `""` = it dies |

Only the size fields for the chosen shape matter. To add an enemy, copy an entry,
give it a new id, and set its fields — then use that id in a wave. Enemies turn to
face their direction of travel, so a `rect` moves end-on and rotates through corners.

The **reduction chain** is just `reduces_to` links: `byte → nybble → 2bit → bit → gone`.
Depleting a form's health turns it into a full instance of the next one down (and
pays out that form's `reward`).

**Edit or add a tower** — Use the editor's **Towers** tab, or edit
`data/towers.json` directly. Each entry is `"id": { name, color, range, fire_rate,
damage, cost, projectile_speed }`. Towers appear as buttons in the game's right
pane in file order. Keep at least one tower defined.

**Define waves** — Open `data/waves.json` (or the editor's **Waves** tab):

```json
{
  "spawn_interval_default": 0.7,
  "waves": [
    { "groups": [ { "type": "bit", "count": 12, "gap": 0.55 } ] },
    { "groups": [ { "type": "byte", "count": 2, "gap": 1.6 },
                  { "type": "bit",  "count": 10, "gap": 0.4 } ] }
  ]
}
```

`waves` is an ordered list. Each wave has `groups`; each group spawns `count` of an
enemy `type` (an id from `enemies.json`), `gap` seconds apart. Groups play in order,
so the second example sends two bytes, then ten bits. Add a wave by adding another
entry — the Start-Wave counter updates automatically.

Both files are read when the game launches (relaunch to see edits). If a file is
missing or malformed, a built-in default is used so the game still runs.

**Tune difficulty** — `money` and `lives` at the top of `main.gd`; everything
else (enemy stats, wave makeup) lives in the `data/` files above. Camera limits: `min_zoom`, `max_zoom`, `pan_speed`,
`pane_width`. Hex size: `HEX_SIZE` in `game_board.gd`.

**Swap shapes for art later** — Each entity draws itself in `_draw()`; replace
those calls with a `Sprite2D` when you want real artwork.

## Note

I wrote the files directly but couldn't launch the Godot editor to play-test in
my environment. The logic and Godot 4 file formats are written carefully, but if
anything errors on first launch, paste the message — it's almost always a quick
one-line fix.
