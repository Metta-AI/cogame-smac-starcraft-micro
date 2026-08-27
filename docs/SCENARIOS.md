# Scenarios and their SMAC lineage

## No OpenBW, no Blizzard assets, no parity claim

This coworld implements SMAC-style micro combat **natively on the coworld-ctf
engine**. To be explicit, because the source idea framed the game as a mod of an
OpenBW wrapper:

* There is **no OpenBW**, no StarCraft: Brood War binary, no BWAPI, no Blizzard
  data files, no Blizzard art, no `.rep` replays and no OpenBW rendering
  anywhere in this repository or in the image it builds.
* There is **no dependency on `Metta-AI/coworld-bw`**, on PySC2, on the SMAC
  package or on JaxMARL/SMAX. The idea itself sanctions the dependency-free
  route.
* **No bit-exact parity with SMAC, SMACv2 or SMAX is claimed or tested.** No
  numerical, action-space or reward-curve parity. The unit classes (`ranger`,
  `blade`, `swarm`) are this repo's own and the numbers are tuned here.
* The replay is rendered by our own static WebAssembly viewer, never by OpenBW.

What IS carried over is the *shape* of the scenarios: a small fixed squad
against a scripted enemy army of fixed composition, ranged units that kite,
melee units that body-block, focus fire as the decisive skill, and a shared win
reward with damage shaping.

## The four shipped scenarios

A scenario is a value of two config fields — `roles` (always five entries) and
`enemyRoles` (1..24 entries). Nothing else changes: the map, the seat count, the
clock, the weapons and the scoring are identical, and every damage term divides
by that scenario's own starting pool, so a harder scenario is genuinely harder
to score on rather than differently scaled.

### `default` — Micro — two and three

`roles` = 2 x ranger, 3 x blade. `enemyRoles` = the same five. Enemy pool 480 hp
against our 480.

**Lineage: SMAC 2s3z.** The smallest squad in which focus fire, kiting and
body-blocking are all live decisions at once — two ranged units that must be
protected and three melee units that can do the protecting. This is the variant
the league ranks.

Full-contact squad dps is 34.6 against 480 enemy hp, i.e. about 14 s of perfect
contact, which in practice lands battles at 25-45 s inside the 60 s clock.

### `outnumbered` — Micro — five against six

`roles` = 5 x ranger. `enemyRoles` = 6 x ranger. Enemy pool 360 hp against our
300.

**Lineage: SMAC 5m_vs_6m.** Nobody can body-block, because nobody has the health
to. The only way to win the trade is to kill faster than you are killed: one
target at a time, and back off while the weapon cools. Every unit out-ranges
nothing, so positioning is entirely about who is inside whose 380 px.

### `corridor` — Micro — the corridor

`roles` = 5 x blade. `enemyRoles` = 20 x swarm. Enemy pool 600 hp against our
600.

**Lineage: SMAC corridor.** Twenty-five bodies on the board. The swarm units are
fast (86 px/s) and fragile (30 hp), and they pick the closest thing they can see
and walk at it. A blade that steps out of the line is surrounded by four of them
and dies; five blades holding a line in a doorway kill them one at a time. This
is the scenario that tests whether a commander can make its unit STOP.

### `heavy` — Micro — outgunned

`roles` = 2 x ranger, 3 x blade. `enemyRoles` = 3 x ranger, 4 x blade. Enemy
pool 660 hp against our 480.

**Lineage: SMAC 3s5z_vs_3s6z.** Outgunned by 38 %. A victory here needs perfect
focus fire from the opening volley; a full-time draw with 70 % damage banked is
a real result and scores like one (0.30 x 0.70 + 0.10 x survival). The variant
exists to make the damage-shaping term matter on its own, rather than only as a
consolation for a lost battle.

## Adding a scenario

Add a variant to `coworld_manifest_template.json` with a new `scenario` id and a
new `enemyRoles` array. That is the whole change: no code, no new art, no new
tests beyond `tests/test_manifest.nim`, which already builds and steps EVERY
variant's `game_config` (the collab-cooking scar — testing only the certification
fixture is how a 25-unit roster ships broken).

The seat-count pin bounds every scenario at five units on our side, and
`enemyRoles` is bounded at 24 entries by `config_schema`, so no variant can
schedule an unbounded army.

## Out of scope for v1

SMACv2's randomised unit *types* per episode and its free-form start positions
are v0.2 — `roles` and `enemyRoles` are already the right shape for a generator
to write into, and the seeded +-24 px spawn jitter is the whole of the
randomisation today. The other twenty-odd SMAC scenarios are `enemyRoles` values
away and cost nothing but variants. SMAC's built-in-AI difficulty ladder is not
modelled: this ships one script, and it is published in `docs/RULES.md` so a
prompt can be written against it.
