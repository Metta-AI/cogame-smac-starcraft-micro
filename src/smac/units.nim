## The unit table: what a `ranger`, a `blade` and a `swarm` unit ARE, which
## cog index is whose, and the damage ledger every score term is derived from.
##
## INTEGER ONLY. Nothing in this module — nor in `scenario.nim` or
## `enemy_ai.nim` — may use a floating-point value: all three feed the hashed
## path, `int` is 32-bit under `--cpu:wasm32`, and the wasm viewer re-derives
## every tick from the recorded masks. `tests/test_enemy_ai.nim` greps the
## three files for a floating-point token and fails on a hit.
##
## The per-role numbers themselves live on `GameConfig` (so a variant is a
## composition change, never a code change) and are read through the small
## accessors in `sim_types.nim` (`roleHp`, `roleDamage`, `roleCooldown`,
## `roleReach`, `roleSpeedPct`).

import sim_types

proc microMode*(config: GameConfig): bool {.inline.} =
  ## True while the micro loadout is engaged: two armies, no pickups, no
  ## hearts, no respawn, one seat per unit.
  config.loadout == LoadoutMicro

proc friendlyCount*(config: GameConfig): int {.inline.} =
  ## Our units. One seat commands exactly one, so this is `num_agents`.
  max(0, config.numAgents)

proc enemyCount*(config: GameConfig): int {.inline.} =
  ## The scripted army's unit count for this scenario.
  config.enemyRoles.len

proc microUnitCount*(config: GameConfig): int {.inline.} =
  ## Every body on the board: our five plus the enemy army.
  config.friendlyCount() + config.enemyCount()

proc isEnemyCog*(config: GameConfig, cogIndex: int): bool {.inline.} =
  ## Cog indices are laid out ours-first: 0 .. num_agents-1 are the seats'
  ## units, everything above is the enemy army in enemy-id order.
  config.microMode() and cogIndex >= config.friendlyCount()

proc enemyIdOf*(config: GameConfig, cogIndex: int): int {.inline.} =
  ## The enemy's 1-based in-battle id (`E3`), or 0 for one of ours.
  if config.isEnemyCog(cogIndex): cogIndex - config.friendlyCount() + 1
  else: 0

proc cogOfEnemyId*(config: GameConfig, enemyId: int): int {.inline.} =
  ## The cog index behind an `E<n>` id, or -1 when no such enemy exists.
  if enemyId < 1 or enemyId > config.enemyCount(): -1
  else: config.friendlyCount() + enemyId - 1

proc microFriendly*(config: GameConfig, cogIndex: int): bool {.inline.} =
  ## One of ours: a seat's unit.
  cogIndex >= 0 and cogIndex < config.friendlyCount()

proc microOpposed*(config: GameConfig, a, b: int): bool {.inline.} =
  ## True when two cogs are on opposite sides. Under the micro loadout there
  ## is no friendly fire, so this is the victim filter for both weapons.
  config.microFriendly(a) != config.microFriendly(b)

proc roleOfCog*(config: GameConfig, cogIndex: int): UnitRole =
  ## The role the config deals to one cog index. Out-of-range indices read as
  ## `urRanger` so no caller can fault on a stale index.
  if cogIndex < 0:
    return urRanger
  if config.isEnemyCog(cogIndex):
    let e = cogIndex - config.friendlyCount()
    if e < config.enemyRoles.len: config.enemyRoles[e] else: urRanger
  elif cogIndex < config.roles.len:
    config.roles[cogIndex]
  else:
    urRanger

proc roleRank*(config: GameConfig, cogIndex: int): int =
  ## One of our units' rank among the seats that share its role — the index
  ## into `IdentityNames` that turns `ranger` into `RANGER-beta`.
  if config.isEnemyCog(cogIndex) or cogIndex < 0:
    return 0
  let mine = config.roleOfCog(cogIndex)
  for i in 0 ..< min(cogIndex, config.friendlyCount()):
    if config.roleOfCog(i) == mine:
      inc result

proc armyStartHp*(config: GameConfig, roles: seq[UnitRole]): int =
  ## The sum of maximum hit points over one army at spawn — the denominator
  ## of that side's damage fraction.
  for role in roles:
    result += config.roleHp(role)

proc clipDamage*(remainingHp, amount: int): int {.inline.} =
  ## The share of one hit that the scoreboard banks: overkill is never
  ## credited, which is what makes `dmgFrac == 1` mean exactly "the enemy
  ## army is dead".
  max(0, min(max(0, remainingHp), max(0, amount)))

proc battleScorePermille*(
  config: GameConfig, won: bool, dmgDealt, enemyStartHp, dmgTaken, ourStartHp: int
): int =
  ## One battle's term on the [0, 1] league scale, in permille and integer
  ## only:  win*winWeight + dmgFrac*dmgWeight + (1 - lossFrac)*survWeight.
  ## Every input is clipped, so no term can leave [0, 1000].
  let
    enemyPool = max(1, enemyStartHp)
    ourPool = max(1, ourStartHp)
    dealt = clamp(dmgDealt, 0, enemyPool)
    taken = clamp(dmgTaken, 0, ourPool)
  result = (if won: config.winWeightPermille else: 0)
  result += config.dmgWeightPermille * dealt div enemyPool
  result += config.survWeightPermille * (ourPool - taken) div ourPool
  result = clamp(result, 0, 1000)

proc bradsOfVectorInt*(dx, dy: int): int =
  ## The heading of a map-space vector, in brads, computed with INTEGERS.
  ##
  ## `bradsOfVector` (sim_types) is `arctan2` plus `round`, and libm is not
  ## bit-identical between glibc and wasm: one ULP either side of a rounding
  ## boundary picks a different heading, which on the HASHED path (the enemy
  ## army's aim) is a native <-> wasm replay divergence. This picks the entry of
  ## the engine's own 1024-scaled unit-vector table whose dot product with the
  ## vector is largest, breaking ties to the lower index, so it is a total
  ## order over 256 headings and identical on every target.
  ##
  ## The table is `AimUnitX[b] = round(1024*cos(b))` and
  ## `AimUnitY[b] = round(-1024*sin(b))`, i.e. exactly `aimVector`'s screen-space
  ## convention, so this agrees with `bradsOfVector` everywhere but the
  ## boundaries it exists to make deterministic.
  if dx == 0 and dy == 0:
    return 0
  var best = low(int)
  for b in 0 ..< AimBradsTurn:
    let dot = dx * AimUnitX[b] + dy * AimUnitY[b]
    if dot > best:
      best = dot
      result = b
