# Tower attribute icons

Four attribute badges, filenames match the tower-data flag keys so wiring is direct:

| file | attribute flag | accent |
|---|---|---|
| bit_corruption.png | bit_corruption | red (defeats ECC) |
| cipher.png / .svg  | cipher          | blue (reveals encrypted) |
| buffer_overflow.png | buffer_overflow | amber (spills excess to spawns) |
| tunneling.png / .svg | tunneling (ignore_walls) | violet (shoots through walls) |

## Format
- **PNG (512x512)** for all four — guaranteed to render in Godot.
- **SVG** also provided for cipher + tunneling only. They are pure shapes, so
  Godot's importer renders them fine and they stay resolution-independent.
- bit_corruption and buffer_overflow are built from 1/0/2 digits. Godot's SVG
  importer (thorvg) does NOT render `<text>`, so those two are PNG only. If a
  scalable version is needed later, their digits must be converted to vector paths.

## Each badge includes its dark rounded tile (#161B22)
The glyphs rely on the dark background for contrast (dark fills inside the eye and
beaker, dim structural strokes). If they need to sit on the UI's own surfaces as
transparent glyphs instead, request transparent-background versions — the colours
will need adjusting so they read on whatever sits behind them.

## Godot import
PNG imports as a texture with no special setup. For crisp small badges, leave
mipmaps on and filter on. Reference each where the tower's attribute flags are shown
(build bar / upgrade tier / tower info), keyed by the flag name above.
