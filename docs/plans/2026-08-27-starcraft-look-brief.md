# smac-starcraft-micro — StarCraft look-and-feel brief (ux.replay Phase 0)

Goal: the replay (and live broadcast) should read as a **dark sci-fi RTS micro battle**
— the SMAC/StarCraft register — not a paintball arena. No Blizzard assets, names, or
sprites (repo policy, docs/SCENARIOS.md): original art in the genre's visual language.

## Replay Brief (engine-derived)

1. **Standing axis** — `teamScore ∈ [0,1]` = 0.60·wins + 0.30·damage + 0.10·survival,
   mean of 3 battles, identical for all five seats. Broadcast axis = the two ARMY HP
   pools + battles won + running score. (Already on screen: army bars + momentum graph.)
2. **Dramatic beats** (from beat kinds + SC micro fandom): battle start (armies 475 px
   apart, just out of ranger range), FIRST BLOOD, each focused kill (the 5-on-1 volley —
   the focus ring ×N is the signature shape), a loss (BLADE-gamma IS DOWN), last cog,
   battle over (victory/wipe/full_time), end card. The commander `note`/`say` lines are
   the LLM story (already in the feed).
3. **Board** — fixed 1235×659 arena; walls/obstacles = cover; four spinning centre
   diamonds; two spawn columns L/R. Fully observable, no fog.
4. **Entities** — 5 friendly (RANGER-α/β = ranged hitscan, BLADE-α/β/γ = melee arc) vs
   enemy army E1..En (ranger/blade/swarm). SMAC 2s3z lineage: ranger≈stalker,
   blade≈zealot, swarm≈zergling.
5. **You** — all five seats are the submitted policies; names shown only in DOM
   scorebug/endcard (identity-privacy test).

## What's wrong today (fidelity-to-REGISTER audit)

The sim, HUD and choreography are right; the ART is the fork's paintball inheritance:
- Floor: gray concrete + grid seams. Walls/obstacles: plywood/cardboard crates.
- Units: paintball soldiers with paintguns; hits leave red/blue PAINT SPLATS.
- Loading screen: paintball locker room. Speech bubbles: pink chat pills.
A first-time viewer reads "paintball", not "sci-fi micro".

## Art-direction LOCK (Phase 0c)

**One sentence:** *A night-time orbital battle-deck seen from an esports observer
booth — dark alloy platform etched with faint cyan panel lines, original
stalker/zealot-register units picked out by team glow, plasma tracers and energy
slashes as the only bright things on the field.*

- **Palette (tokens):** deck near-black `#0d1117`-family biased blue-steel (never pure
  #000); panel-line teal `#2b4a52`; friendly identity **cyan/azure** `#57c7ff`; enemy
  identity **crimson** `#ff5252`; plasma bolt white-hot core + team-tinted halo;
  warning amber `#f0a821` (keep — clock/beats already use it); ink outline = warm-dark
  steel `#1a222c`, not black.
- **Framing:** full-bleed fixed arena (unchanged); subtle corner vignette (starter's
  `#lightpool` already does this — keep); the board stays the hero.
- **Type:** keep the starter's display face for chrome; numerals mono (already).
- **HUD semantics:** OURS = cyan (currently white), THEIRS = crimson (already red);
  focus ring = amber; hp bars green→amber→red like an RTS.

## Depth target (PD1 — written, graded against in Phase 4)

The render loop is a real-time re-simulated sim (motion/choreography come free, like
the 3D-reuse path). The art batch is the work:

- **Arena bake:** deck-plate floor texture, panel-line grid, spawn pads (2), obstacle
  sprites for every wall class (thin pillars, crates→tech barricades, chevrons,
  circles→holo-emitters), centre diamonds → rotating energy pylons; baked spawn lines.
- **Units (rig sprites):** ranger + blade bodies × friendly/enemy palettes (+ swarm
  small variant) on the existing rig anchors; held weapon = plasma rifle silhouette /
  energy blade (procedural, rig_art).
- **FX:** hitscan tracer, muzzle flash, impact flash + scorch decal (replaces paint
  splat), blade arc glow, death burst, KO marker.
- **DOM:** lockerroom → briefing/hangar loading screen (bg + 5 unit portraits),
  endcard backdrop, speech pill restyle (comms chip, not pink bubble).
Target ≈ 25–35 authored/rebaked pieces. Ambient life: pylon rotation (exists),
panel-line shimmer, spawn pad pulse.

## Hard NO-TOUCH

- Sim/hash: `paint.nim` grid state, masks, `gameHash`, `GameVersion` (art is
  broadcast-only per rig_art/map_art contracts — keep it that way).
- `client/chrome_common.js` (sha-pinned), `broadcast_core.js` (one-identifier rule),
  starter ids/structure of `replay_broadcast.html` (appended block only).
- Determinism smoke (`tools/wasm_replay_smoke.cjs`) must stay green; live game frames
  byte-identical where hashed.
