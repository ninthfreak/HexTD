# HexTD UI / tower art

Art lives in `art/`. PNG is what the engine wires up; SVG (where present) is a
scalable source for the same image.

## Ability badges (5) — parallax three-layer composites

Each tower-ability badge is rendered in 3D as a parallax stack of **three** layers
(see `ABILITY_BADGES` in `tower_3d.gd`). For an ability whose art base is `<base>`,
the engine loads:

| layer | file | role |
|---|---|---|
| backplate | `<base>_backplate.png` | dark recessed tile (#161B22) |
| glyph | `<base>_glyph.png` | the icon itself |
| rim | `<base>_rim.png` | coloured hex rim / frame |

A badge renders only if all three layers exist (otherwise it's skipped silently). It
shows on a selected tower whenever the matching flag is true, and its `_glyph` is
reused in the hover tooltip.

| ability flag | art base | accent |
|---|---|---|
| `bit_corruption` | `bit_corruption` | red (defeats ECC) |
| `cipher` | `cipher` | blue (reveals encrypted) |
| `buffer_overflow` | `buffer_overflow` | amber (spills excess to spawns) |
| `ignore_walls` (Tunneling) | `tunneling` | violet (shoots through walls) |
| `dos` (Denial of Service) | `dos` | cyan (freeze-then-slow wave) |

The art base equals the flag key — except **Tunneling**, whose flag is `ignore_walls`
but whose files are `tunneling_*`. Per-badge focal/parallax tuning (focal_out/in,
reveal_out/in, reveal_rate) lives in the `ABILITY_BADGES` entry.

The standalone `<base>.png` / `<base>.svg` (e.g. `cipher.svg`, `dos.svg`) are flat
single-image sources, not used by the parallax badge path.

## Tower selection buttons

`tower_<id>.png` — one per tower id in `towers.json` (`tower_basic`, `tower_machinegun`,
`tower_slow`, `tower_radial`, `tower_laser`, `tower_jammer`). Each is a full 512×512
**hex face** (dark tile + coloured rim baked in, transparent outside the hex). Wired
in `main_3d.gd` via `_load_art("tower_" + id)`; a colored-hex placeholder shows until
the file exists. Rename a tower key → rename its file.

## Sandbox / UI buttons

Graphic-only hex buttons (PNG wired, SVG source alongside):

| file(s) | button |
|---|---|
| `sound_on.png` / `sound_off.png` | sound toggle (two-state) |
| `spawn_enemy.png` / `spawn_enemies.png` | spawn button (singular at count 1, plural above) |
| `cheat_money.png` | sandbox cheat (+funds) |

These are full hex faces too, so they're set as flat, icon-only buttons (no button
chrome) to avoid double-framing the baked-in hex.

## Format notes
- **PNG (512×512)** is the wired asset — guaranteed to render in Godot.
- **SVG** sources are pure shapes; Godot's importer (thorvg) renders them but does
  **not** render `<text>`, so any digit-based glyph stays PNG (or its digits must be
  converted to vector paths).
- The badge `_backplate` supplies the dark tile (#161B22) the glyphs rely on for
  contrast. For glyphs on a lighter surface, request transparent versions with
  adjusted colours.

## Godot import
PNG imports as a texture with no special setup. For crisp small icons, leave mipmaps
and filtering on.
