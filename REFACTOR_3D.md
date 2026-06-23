# 3D Refactor — design decisions & status

> **Draft for review.** Extracted from the "Continuing development" chat, the
> recovered `game_board_3d.gd`, and the planning of the response that failed
> mid-stream. Skim it, correct anything wrong or stale, and add anything I missed —
> my read of the chat came in pieces, so a small decision may not have made it in.
> Once you're happy, this is the record Claude Code works from.

## Goal

Port the game's **rendering** to 3D while keeping it as close to the current game
as possible — same logic, same behavior, just opening up real lighting, materials,
reflections, and resolution independence. Explicitly NOT a from-scratch rewrite.

## Why 3D (the reasoning that led here)

The 2D raster pipeline is structurally incapable of the things being chased:
dynamic lighting, material/specular reflections (the copper "mirror" look), real
depth, and crisp scaling at every zoom. In 2D those are faked, plugin-bound, or
impossible. In 3D they're the medium's defaults — a mesh renders at display
resolution, so it's sharp at any zoom for free, and materials reflect the
environment with no hand-faked bands.

## Renderer

- **Forward+ (Vulkan).** Already switched (done earlier, one-and-done). The
  material reflections and lighting niceties live here, not in the Compatibility
  (OpenGL) renderer. This also unlocked 2D glow/bloom as a side benefit.

## Core architecture decision

It's a **rendering-layer rewrite, not a game rewrite.** The logic — hex math,
pathing, waves, targeting, upgrades, economy, and the copper clip-tile selection
rule — is coordinate-and-data work and **ports unchanged**, still operating on 2D
plane coordinates (`Vector2`).

- **Coordinate mapping:** plane `(x, y)` → world `(x, 0, y)`. World **y is height/up**.
- **`HEX_SIZE` stays 11.34** so all existing hex math ports directly with no rescale.
- **Entities are `Node3D`** but keep a 2D plane-position field (the recovered board
  uses the name `pp` / `plane_pos`) for ALL logic. Their 3D transform is synced from
  that for display only. So targeting, pathing, and range checks stay in 2D plane
  math; tower/enemy/projectile get a mechanical change to use the plane field
  internally instead of `position`.
- **`GameBoard3D` preserves the 2D `GameBoard` API** (`world_cell`,
  `cell_center_world`, `hexes_in_range`, `has_los`, `is_buildable`, `footprint`,
  `place_tower`, `add_enemy`, …) so existing entity code talks to it with minimal
  change. This is the whole reason the port is feasible.

## Visual / mesh approach

- **Board** = layered generated meshes (SurfaceTool / ArrayMesh): a mask substrate
  prism under every cell (the green board), copper traces raised slightly proud on
  top using the existing clipped-polygon logic (preserves the edge-smoothing of the
  2D clip rule), walls as tall prisms, spawn/goal as colored caps.
- **Materials:** copper = metallic `StandardMaterial3D`, near-mirror
  (roughness ≈ 0.18); solder mask = green with **clearcoat** (glossy clear epoxy
  over matte green); walls / spawn / goal are flat.
- **Towers:** extrude the existing 2D tower shapes into 3D prisms with materials.
- **Enemies:** extruded 3D shapes moving along the path, with **billboarded health
  bars** above them.
- **Projectiles:** small 3D spheres.
- **Camera / lighting / input:** tilted 3D camera + directional light + sky
  environment; click handling via a **raycast from the camera through the cursor to
  the ground plane** → cell.

## Overlays (the tricky part — simplified, by decision)

- Range → highlighted hex tiles.
- Footprint → colored region.
- Ghost (placement preview) tower → translucent.
- **Badges and tooltips: DEFERRED** to future work, not part of this pass.

## File strategy (reversible by design)

- Create **new `_3d`-suffixed files** and leave all 2D files intact as a safety net,
  so the move is reversible: `game_board_3d.gd`, `tower_3d`, `enemy_3d`,
  `projectile_3d`, `main_3d.tscn` + `main_3d.gd`.
- `main_3d` builds camera/lighting/environment/board/UI in code in `_ready`,
  mirroring how the original `main.gd` built everything programmatically.
- Update `menu.gd` to launch the 3D scene.

## Status

- **`game_board_3d.gd` — written (foundation).** Reasoned, **not runtime-tested**.
  Tab indentation verified; `:=` discipline verified by reading (explicit types /
  plain `=` used wherever the RHS is a Variant).
- **Not yet built:** `tower_3d`, `enemy_3d`, `projectile_3d`; `main_3d` scene +
  script (camera/lighting/input); the `menu.gd` switch. Roughly the foundation
  only — the rest of the port remains.

## Open items to verify (needs a running Godot / a visual check)

- Mesh **normals / winding** on the prism caps vs. sides (could light from the
  wrong side until seen).
- Whether the **clipped-copper corners** read the same as the 2D board's look.
- Whether `hexes_in_range` returning `{visible, shadowed, blocked}` matches what the
  overlay consumers expect (the 2D version split visible vs shadowed).

## Assumptions made (the "best guesses" to confirm or override)

These were chosen to keep moving without blocking on questions — flag any you'd
decide differently:

1. Plane→world mapping `(x, y) → (x, 0, y)` with y as up.
2. `HEX_SIZE` retained at 11.34 (no rescale).
3. New `_3d` files rather than replacing the 2D ones (reversible).
4. Overlay simplified as above; badges/tooltips deferred.
5. Specific material values (copper roughness ≈ 0.18, mask clearcoat) — starting
   points, tune to taste.
