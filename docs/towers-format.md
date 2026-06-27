# HexTD Tower JSON Spec

`data/towers.json` is one JSON object. Keys are unique tower IDs; values are tower
definitions. Key order = build-bar order in-game.

```json
{
  "<id>": { "...fields..." },
  "<id>": { "...fields..." }
}
```

The tower format is **not** kept backward compatible — redefine towers freely.

> **Changelog (this revision):** added `targets`, `arc_angle`, and the per-tower DoS
> fields (`dos_freeze`, `dos_slow_time`, `dos_slow_factor`); added the **crosspathing**
> purchase rule; corrected the `dos` note (it now also applies on `arc`). See the
> engine spec (`docs/upgrade-engine-spec.md`) for the runtime behavior these require.

## Base fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | string | `"Tower"` | Display name. |
| `description` | string | `""` | Build-button tooltip body (the name is shown above it). Multi-line; `\n` for line breaks. |
| `color` | `"#rrggbb"` | `"#59b2ff"` | Body / projectile / beam color. |
| `range` | int | 3 | Attack radius in hex tiles (min 1). |
| `fire_rate` | number | 1.5 | Shots per second (`single`) / volleys per second (`radial`) / waves per second (`arc`). Ignored by `laser`. |
| `damage` | number | 10 | Damage per hit. For `laser`, max damage per second at full charge. For `arc`, 0 deals no damage (still applies ability effects). |
| `cost` | int | 40 | Build cost. |
| `projectile_speed` | number | 320 | Plane units/sec for `single`/`radial` shots and the `arc` wave front (1 hex ≈ 11.3). |
| `fire_mode` | enum | `"single"` | `"single"` \| `"radial"` \| `"laser"` \| `"arc"` (see below). |
| `targets` | int | 1 | **NEW.** `single` only: number of distinct enemies engaged per fire cycle (furthest-along first). >1 = multi-target / no-overkill spray. |
| `directions` | int | 6 | `radial` only: number of equally spaced spokes (min 1; 6 = hex flat sides). |
| `ramp_time` | number | 2.0 | `laser` only: seconds of sustained fire to reach full power (min 0.05). |
| `focus_time` | number | 0.0 | Seconds the tower is idle after **killing** a target (min 0). Taxes swarm clearing. |
| `arc_angle` | number | 70 | **NEW.** `arc` only: full angular width of the wedge, in degrees (min 1, max 360; 360 = omnidirectional). |
| `dos_freeze` | number | 0.5 | **NEW.** Seconds an enemy is fully stopped by a DoS hit (per-tower override of the former global `DOS_STOP`). |
| `dos_slow_time` | number | 2.0 | **NEW.** Seconds an enemy stays slowed after the freeze ends (override of `DOS_SLOW_TIME`). |
| `dos_slow_factor` | number | 0.5 | **NEW.** Speed multiplier while slowed (override of `DOS_SLOW_FACTOR`); lower = harsher. |
| `bit_corruption` | bool | false | Ignores enemy ECC 90% damage resist. |
| `ecc_pierce` | number | 0 | **NEW.** Fraction of an enemy's ECC resist this tower ignores *natively* (0 = full 90% resist applies; 0.5 = only ~45% resist; 1 = fully ignored). `bit_corruption` overrides to a full pierce. |
| `cipher` | bool | false | Can see and target Encrypted enemies. |
| `buffer_overflow` | bool | false | Single-hit surplus damage spills into the target's decay children. **Single-target only.** |
| `ignore_walls` | bool | false | "Tunneling": attack through blocking tiles (LOS ignored; `radial` spokes pass through walls). |
| `dos` | bool | false | "Denial of Service": a hit freezes the enemy briefly, then slows it. Applies on `single`, `radial`, and `arc` (laser ignores it). |
| `execute_threshold` | number | 0 | **NEW.** A hit instantly kills any enemy at/below this fraction of its max HP (0 = off). |
| `execute_no_decay` | bool | false | **NEW.** If set, an execute kill also suppresses the enemy's decay spawn — a clean delete of that body's whole sub-tree. |
| `height_scale` | number | 1.0 | Body height multiplier, 3D view (min 0.05). |
| `width_scale` | number | 1.0 | Body width / footprint multiplier (min 0.05; also scales the 2D body). |
| `upgrades` | array | `[]` | Exactly 3 upgrade paths of 5 tiers each — see Upgrades + Crosspathing. |

Omit any optional field to use its default. `target_priority` (first/last/strongest)
is a per-tower in-game toggle, not a JSON field.

## Fire modes

- **`single`** — homing shot(s) at the enemy(ies) furthest along the path within range
  and line of sight. With `targets > 1`, engages that many distinct enemies per cycle,
  one shot each (no overkill onto a single body). The only mode that uses
  `buffer_overflow`.
- **`radial`** — fires a volley of `directions` straight spokes whenever any enemy is in
  range. Spokes are stopped by blocking walls unless `ignore_walls`.
- **`laser`** — locks one target and ramps damage with a convex (quadratic ease-in)
  curve: `damage_per_sec = damage * (elapsed / ramp_time)²`, reaching full at
  `ramp_time`. The ramp resets to 0 whenever the target changes or is lost.
- **`arc`** — an aimed expanding wave spanning `arc_angle` degrees, centered on the
  prioritised target. Every enemy the front crosses within range and within the wedge is
  affected once (no pierce cap). Applies `damage` (default 0) and the tower's ability
  flags through the normal effect path, gated by Cipher for Encrypted enemies. At
  `arc_angle = 360` it is omnidirectional. `fire_rate` is waves/second. The arc wave is
  **not** blocked by walls, so `ignore_walls` is a no-op on `arc`.

## Upgrades + Crosspathing

`upgrades` is an array of **3 paths**; each path has **5 tiers** the player buys
level-by-level in-game. Tiers within a path are sequential.

```json
"upgrades": [
  { "name": "Caliber", "tiers": [ {…}, {…}, {…}, {…}, {…} ] },
  { "name": "Action",  "tiers": [ {…}, {…}, {…}, {…}, {…} ] },
  { "name": "Optics",  "tiers": [ {…}, {…}, {…}, {…}, {…} ] }
]
```

**Crosspathing purchase rule (BTD6-style, enforced by the engine, not the data):**

- A tower may upgrade **at most two** of its three paths; the third stays at tier 0.
- **Only one** path may be raised above tier 2 (i.e. into tiers 3, 4, 5).
- The second upgraded path is capped at **tier 2**.
- Tiers are bought in order within a path; illegal purchases are greyed out in-game.

So legal builds look like 5-2-0, 0-2-5, 2-4-0, etc. Tier 5 is "special" only by being
the deepest tier of the chosen main path — there is no capstone flag.

### Tier fields

A tier mutates the tower's effective stats when purchased. Numeric entries are
**additive deltas** (may be negative); flags are tri-state; absent keys mean "no change".

| Key | Type | Effect |
|---|---|---|
| `cost` | int | Price of this tier (not a delta). |
| `damage` | number | Add to `damage`. |
| `range` | number | Add to `range` (rounded). |
| `fire_rate` | number | Add to `fire_rate`. |
| `targets` | number | Add to `targets` (rounded, floored at 1). **NEW.** |
| `directions` | number | Add to `directions` (rounded). |
| `ramp_time` | number | Add to `ramp_time` (floored at 0.05). |
| `focus_time` | number | Add to `focus_time` (floored at 0). |
| `arc_angle` | number | Add to `arc_angle` (clamped 1–360). **NEW.** |
| `dos_freeze` | number | Add to `dos_freeze` (floored at 0). **NEW.** |
| `dos_slow_time` | number | Add to `dos_slow_time` (floored at 0). **NEW.** |
| `dos_slow_factor` | number | Add to `dos_slow_factor` (clamped 0.05–1.0). **NEW.** |
| `height` | number | Add to `height_scale` (floored at 0.05). |
| `width` | number | Add to `width_scale` (floored at 0.05). |
| `color` | `"#rrggbb"` | Replace `color` (omit / `""` = no change). |
| `cipher` | `"on"`\|`"off"` | Enable/disable Cipher. |
| `bit_corruption` | `"on"`\|`"off"` | Enable/disable Bit Corruption. |
| `ecc_pierce` | number | Add to `ecc_pierce` (clamped 0–1). **NEW.** |
| `ignore_walls` | `"on"`\|`"off"` | Enable/disable Tunneling. |
| `buffer_overflow` | `"on"`\|`"off"` | Enable/disable Buffer Overflow. |
| `dos` | `"on"`\|`"off"` | Enable/disable Denial of Service. |
| `execute_threshold` | number | Add to `execute_threshold` (clamped 0–1). **NEW.** |
| `execute_no_decay` | `"on"`\|`"off"` | Enable/disable decay suppression on execute kills. **NEW.** |

Flags resolve in path order — a later path's `"on"`/`"off"` overrides an earlier one.
