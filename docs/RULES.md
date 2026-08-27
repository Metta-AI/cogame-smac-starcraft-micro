# Rules

Everything the sim does, in the order it does it. Every number here is a config
field, and every shipped variant leaves it at the value printed below.

## The board

The hand-tuned `arena` map: **1235 x 659** map pixels, fixed geometry, pinned
into the replay's config as `mapSpec`. No procedural terrain. The obstacles are
exactly the cover that makes line of sight matter, and the four spinning centre
diamonds are live geometry that movement, bullets and vision all resolve
against.

`TargetFps` = `ReplayFps` = **24**. One **battle** is `maxTicks` = **1440**
ticks = 60 s. One **episode** is `maxGames` = **3** battles. The map, the seed
and the connected seats are identical across the three; the sim RNG stream
simply continues, so each battle's spawn jitter differs and all three are
re-derivable from the one recorded seed.

Decision turns: `turnTicks` = **120** ticks = 5.0 s, i.e. **12 turns per
battle, 36 per episode**.

## Seats and units

`num_agents` = **5**. One seat = one unit. No seat commands more than one body
and no body is uncommanded.

Seat -> role comes from the variant's `roles` array (length 5, always). A unit's
anonymous in-game name is `<ROLE>-<identity>`, where the identity is ranked
among the seats that share the role: `RANGER-alpha`, `RANGER-beta`,
`BLADE-alpha`, `BLADE-beta`, `BLADE-gamma`.

All five seats are on the **Red** side. The enemy army is **Blue** and holds no
seats. An enemy's in-game name is `E<id>` with ids assigned 1..n in spawn order
and stable for that battle. Those ids are the whole point of the command
grammar: `"target_id": 3` is how a commander says *everybody shoot E3*.

## The units

Common to every unit: body 34 px drawn / 13 px footprint, one life, no respawn,
no healing, no regeneration, aim decoupled from movement at 5 brads/tick, and
the starter's acceleration / friction / slide-collision model unchanged.

| | `ranger` | `blade` | `swarm` (enemy only) |
|---|---|---|---|
| max hp | 60 | 120 | 30 |
| speed | 2.75 px/tick (66 px/s) | 3.16 px/tick (~76 px/s) | 3.57 px/tick (~86 px/s) |
| weapon | hitscan shot | arc swing | arc swing |
| range / reach | 380 px | 56 px, +-45 deg | 40 px, +-45 deg |
| damage | 4 | 10 | 6 |
| cooldown | 18 ticks (0.75 s) | 30 ticks (1.25 s) | 24 ticks (1.0 s) |
| windup | 5 ticks, aim locked at the trigger pull | swing lit 4 ticks at the aim it was thrown at | same |
| dps | 5.33 | 8.0 | 6.0 |
| line of sight | required | required | required |

The ranger's shot is a real hitscan weapon with a released-shot aim jitter
calibrated off its own range and a silhouette exposure test: a fully visible
body is hit about 80 % of the time at maximum range and about 99 % at half
range. Cover is partial, not binary — a corner-hugger can only be hit on the
sliver of body it actually shows.

The blade's swing damages every living unit of the OTHER side inside the
reach/half-angle wedge with a clear line, **at most once per activation**
across all four lit ticks.

**There is no friendly fire.** A shot passes through friendly bodies and a swing
ignores them.

**Time to kill.** Five of ours focus-firing one enemy blade (120 hp) kill it in
about 3.5 s; one enemy ranger (60 hp) in about 1.7 s. Five of ours each shooting
a different enemy kill nothing in the same window. A lone ranger needs 22.5 s of
uninterrupted fire to kill a blade while the blade needs 7.5 s of contact to
kill the ranger.

## Spawns

At the start of each battle:

1. Our five are placed in a column at `friendlySpawnX` = **380**, centred on
   `y = 329`, `spawnSpacingPx` = **44** px apart, in seat order.
2. The enemy army is placed the same way at `enemySpawnX` = **855**, in
   enemy-id order.
3. Every unit takes an integer jitter `(dx, dy)`, each drawn independently from
   the sim RNG in `[-24, +24]`, and is snapped to the nearest pixel at which the
   13 px footprint is clear floor (bounded to a 96 px ring; if nothing is clear
   the un-jittered point is used).

The two lines start **475 px** apart — just outside a ranger's 380 px range.

## The enemy army — the published script

The enemy is **inside the sim**, hashed, integer-only and deterministic. It runs
once per tick, in enemy-id order:

1. **Target selection.** Each living enemy keeps a current target. It keeps that
   target while the target is alive and within `leashPx` = **700 px**.
   Otherwise, and in any case every `retargetTicks` = **48** ticks, it picks the
   living friendly unit with the smallest integer squared distance that is
   within `aggroPx` = **600 px** and has a clear line; ties break to the lowest
   seat index. A retarget only replaces a LIVE current target if the candidate
   is at least 1.5x closer — hysteresis, so an enemy does not oscillate between
   two units standing side by side.
2. **Movement.** With a target: step directly toward it at the unit's speed,
   through the same wall-slide collision our units use. Without one: step toward
   the friendly spawn anchor.
3. **Stuck escape.** An enemy whose position is unchanged for `enemyStuckTicks`
   = **24** consecutive ticks rotates its step vector a quarter turn clockwise
   for the next 12 ticks.
4. **Attack.** If the target is inside range/reach and the aim error is inside
   24 brads with a clear line, it fires (ranger) or swings (blade/swarm) under
   the same weapon rules as ours, and its cooldown starts. Otherwise it turns
   toward the target at 5 brads/tick.

The composition is config, not code: `enemyRoles` is an array of 1..24 role
names, and the four shipped scenarios are four values of that one field. There
is **one difficulty level**.

## Tick order

1. Turn boundary: the directives collected for this turn become each seat's
   active directive and one `directive` record per seat is written to the
   replay. A directive is EXCLUDED from `gameHash` — nothing a commander says
   can move the hash chain, only the masks it produces.
2. The control layer compiles one `uint8` actuator mask per living friendly unit.
3. Those five masks go to `sim.step` and to the replay, indexed by unit. **This
   is the determinism boundary.**
4. The centre diamonds turn.
5. Roster-driven transitions.
6. Playing:
   1. Per unit: decrement cooldowns and windups, apply movement and aim, and
      start a windup (ranger) or queue a swing (blade) on a fresh A press.
   2. The scripted army decides, in enemy-id order, before any damage lands.
   3. Every shot that releases this tick resolves against ONE snapshot taken
      before any of them apply, so unit order confers no advantage.
   4. Every lit swing resolves.
   5. Damage applies; hp floors at 0; a unit at 0 hp is dead for the battle.
      **Damage credited to the scoreboard is clipped to the victim's remaining
      hp** — overkill is never banked.
   6. Both armies' totals and the per-enemy focus count are recomputed.
   7. The sim guard runs (below).
   8. The battle end conditions are evaluated **in this order**: our army wiped
      -> `wipe`; else enemy army wiped -> `victory`; else 1440 ticks ->
      `full_time`. A tick that annihilates both sides is a `wipe`.
   9. FX pruning and shout expiry.
7. One `gameHash` per tick is written to the replay.

## The sim guard

Every tick, before a battle can be ended on the numbers it checks: every living
unit's centre is inside the map box and on non-wall floor; the alive counts
equal full recounts; every unit's hp is in `[0, maxHp]` and a unit with 0 hp is
not alive; the per-unit damage ledgers sum to the battle totals; the battle
totals never exceed the starting pools; and the roster is exactly
`5 + len(enemyRoles)` units. A trip ends the episode `fault` / `sim_fault` and
the squad is scored from what it actually banked.

## Scoring

```
per battle b (only battles that actually started):
  dmgFrac_b  = damage our units applied to the enemy, overkill clipped
               / sum of the enemy army's max hp at spawn        -> [0, 1]
  lossFrac_b = damage the enemy applied to us, overkill clipped
               / sum of our max hp at spawn                     -> [0, 1]
  won_b      = 1 if every enemy died AND >= 1 of ours is alive, else 0
  battle_b   = 0.60*won_b + 0.30*dmgFrac_b + 0.10*(1 - lossFrac_b)

teamScore = (sum over battles played of battle_b) / 3           -> [0, 1]
credit[s] = 0.0004 * dmgDealt[s] / max(1, sum of dmgDealt)
scores[s] = teamScore + credit[s]
win[s]    = (teamScore >= 0.5)          -- the same boolean for all five seats
```

Higher is better and no term is ever negative. A victory always scores at least
0.90 for that battle (because `dmgFrac == 1` follows from it) and a wipe always
scores at most 0.30. `teamScore` is **identical for all five seats** — that is
the cooperative pin, stated as an equation.

## End conditions

`results.reason` is a closed enum of exactly three values; `results.endRule`
carries the detail of the LAST battle played and is a closed enum of exactly
six.

| `reason` | `endRule` | when |
|---|---|---|
| `complete` | `victory` | the last battle ended with every enemy dead and at least one of ours alive |
| `complete` | `wipe` | the last battle ended with all five of ours dead (this covers mutual annihilation) |
| `complete` | `full_time` | the last battle ran its 1440 ticks with both sides standing |
| `deadline` | `wall_clock` | the 690 s engine budget elapsed; battles already finished keep their value, the battle in progress banks its damage with `won = 0`, battles never started score 0 |
| `fault` | `sim_fault` | the sim guard tripped |
| `fault` | `host_error` | an unexpected server-side exception |

A seat that never connects does **not** end the episode: after 2400 lobby ticks
the no-show is reported to the platform, its unit is driven by the `focusfire`
baseline for the whole episode, and all three battles play out.

## The two published scripted baselines

**`focusfire`** — the certification player, the per-turn LLM fallback, the
driver of a no-show seat, and the default for a seat that registers with
neither `PLAYER_PROMPT` nor `PLAYER_SCRIPTED`. Every governed unit derives the
**same** kill order from state alone, so the seats that can concentrate fire —
the **rangers** — converge on one target without communicating, each from its
own standoff post:

1. Rank the living enemies by, in order: (a) inside 420 px of any living
   friendly unit before everything else; (b) current hp ascending; (c) integer
   squared distance to our squad centroid ascending; (d) enemy id ascending.
2. A living **ranger** issues `focus` on the kill order — unless a living melee
   enemy is within `panicPx` = **150 px** of it, in which case it issues `kite`
   with that enemy as `target_id`. Its standoff post is one probe step per seat
   around the target's standoff circle, so five rangers shooting one target
   stand on five different posts instead of walking into the same point.
3. A living **blade** issues `screen` when at least one friendly ranger is alive
   and some melee enemy is within 260 px of that ranger; otherwise `focus` — on
   the **kill order** while our squad is not outnumbered (`enemyRoles` no longer
   than `roles`), and on the living enemy nearest **itself** when it is. A melee
   unit cannot concentrate damage from where it stands, only walk: against a few
   tough enemies, arriving together and killing the focused one is worth it;
   against a bigger, thinner army, three arcs into one dying body is wasted
   damage while everything the pile is not facing keeps swinging.
4. With no living enemy: everyone `regroup`.

**`charge`** — the second filler, weaker BY CONSTRUCTION and different in
SHAPE: unit *k* issues `attack_move` at the **(*k* + turn)-th deepest** living
enemy in the formation, measured from our squad centre — ranked by squared
distance descending, with the enemy id as the tie-break, wrapped when fewer
enemies are standing. Nobody kites, nobody screens. Three weaknesses in one
rule: the squad pushes to the **far side** of the enemy army and fights it from
the inside (our damage is capped by the weapon cooldown, the number of enemies
in contact with us is not); the seat-indexed rank splits the damage five ways
instead of killing anything; and the rotating rank abandons a half-killed enemy
every turn.

## What is NOT modelled

No friendly fire, no respawns, no healing, no hit-point regeneration, no more
than one life. No stim, blink, medivacs, cloaking, splash damage, air units or
upgrades. No production, resources or bases — this is micro at tick rate. No fog
of war: the board is fully observable. No enemy difficulty ladder. No procedural
terrain.
