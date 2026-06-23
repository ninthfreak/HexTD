# Project history & decisions log

> **Draft for review.** A scannable record of what was decided in the project's
> conversations, so it isn't stranded in chat transcripts. Complements the other
> docs: `PROJECT_CONTEXT.md` (architecture handoff of the original build),
> `REFACTOR_3D.md` (the active 3D port), and `CLAUDE.md` (conventions).
>
> **Scope note:** only two conversations live in this project — "Game development
> scope in Godot" (2026-06-21) and "Continuing development" (2026-06-23). The
> original build (ECC/encrypted mechanics, laser mode, multiply-decay, the
> enemy-balance page, the editor) happened in conversations **outside** this
> project and isn't reachable from here; `PROJECT_CONTEXT.md` is the summary of
> that earlier work. Move those chats into the project if you want them on record
> here too.

---

## Session 2026-06-21 — "Game development scope in Godot"

Two threads:

**Project setup.** Worked out how Claude projects actually store context: an
*Instructions* box (got the conventions block) and a separate *files / Add content*
area (got `PROJECT_CONTEXT.md`). Key takeaway recorded then: a chat being *in* the
project doesn't auto-load its content — only the instructions and the files area
persist across chats. (This is the same limitation that later made the chat→Claude
Code handoff need written docs.)

**Radial firing mode (built).** Added a third `fire_mode`, `radial`, alongside
`single` and `laser`:
- A radial tower idles until any enemy is within range, then every `1/fire_rate`
  seconds emits one volley of `directions` shots, equally spaced starting at 0°
  (6 = the hex's flat-side centers). Each shot flies straight, pierces (damages
  each enemy once per volley), and dies at the range edge.
- Reused stats: `range` = activation distance + spoke length; `fire_rate` =
  volleys/sec; `damage` = per shot per enemy; `projectile_speed` = spoke speed.
- New file `radial_projectile.gd`; touched `tower.gd`, `tower_data.gd`,
  `game_content.gd`. `towers.json` left untouched.
- `fire_mode` defaults to `"single"` when absent, so existing towers are unchanged.
- **Decisions:** the editor must understand the new firing method (radial controls
  added + fields preserved); **walls stop spokes** (a spoke is truncated by a
  `blocking` cell unless `ignore_walls`).

---

## Session 2026-06-23 — "Continuing development"

### Part 1 — 2D PCB visual flair (built, later superseded by the 3D pivot)

The session reskinned the board toward a printed-circuit-board look:

- **Terminology:** display labels renamed grass → **solder mask**, path/road →
  **trace**. Only the *labels* changed; internal data keys (`'path'`, `'grass'`)
  were left alone, and saved map JSON doesn't store those strings, so map data and
  format stayed backward compatible.
- **Colors:** trace = copper `Color(0.72, 0.45, 0.20)` (≈ `#B87333`); solder mask =
  green `Color(0.24, 0.40, 0.28)`; wall = `Color(0.16, 0.17, 0.22)`.
- **In-game hex lines removed** so the board reads as one solid PCB surface. Hex
  lines were deliberately **kept** in the editor and on the tower-view overlay.
- **Tile shader (2D):** a `canvas_item` shader keyed off each tile's fill color —
  copper tiles got a brushed-metal look (anisotropic streaks along the trace +
  specular band + glint), everything else got glossy clearcoat solder mask. Anchored
  in board space so the pattern stayed locked to tiles on pan/zoom; children
  (towers/enemies) unaffected. Later iterated toward "flat mirror copper + clearcoat
  mask" with a board-wide directional sheen instead of per-hex hotspots.
- **Copper-corner shave (`CHAMFER_T = 0.5`):** a runtime pass that cuts the
  protruding (convex) corners of the copper region with a straight chord, so a hex
  staircase reads as a flat trace edge. Concave notches and interior edges are left
  untouched, so contiguous copper stays seamless and no hex grid reappears. (This
  replaced an earlier "material-step height boundary" attempt.)
- **Glow layer (`glow_layer.gd`):** one batched additive `Node2D` pass drawing a
  soft glow blob per enemy in its own color, scaled by a per-enemy `glow`
  multiplier; sits above tiles, below entities.

**Why this matters going forward:** the recurring frustration here was that 2D can
only *fake* lighting, reflections, and depth, and every fix hit that ceiling. That's
what motivated the 3D decision. The reusable conclusions that carry into 3D are the
**terminology, the copper/mask/wall colors, the no-in-game-hex-lines rule, and the
editor relabeling**. The 2D shader, the corner-shave, and the glow layer are
*fakes that 3D replaces* with real materials and lighting — keep them only as a
record of what was tried.

### Part 2 — The pivot to 3D

The deliberation that followed (renderer choice → Forward+/Vulkan, the
rendering-layer-not-game rewrite framing, the plane-coordinate architecture) and the
refactor that was started are recorded in **`REFACTOR_3D.md`**. See that file for the
live decisions, status, and open assumptions.

---

## Carried forward vs. superseded (quick reference)

| Decision | Status in 3D |
|---|---|
| solder mask / trace terminology | **carried forward** |
| copper / mask / wall colors | carried forward (as material albedo) |
| no in-game hex lines; hex lines in editor + overlay | carried forward |
| editor relabeling (Trace / Solder Mask) | carried forward |
| radial fire mode + walls stop spokes | carried forward (logic, unchanged) |
| 2D tile shader (brushed metal / clearcoat) | **superseded** by real 3D materials |
| copper-corner shave (`CHAMFER_T`) | **superseded** (clipped prism polygons instead) |
| 2D glow layer | **superseded** by engine lighting/emission |
