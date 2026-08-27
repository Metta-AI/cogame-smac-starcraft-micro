## The scenario layer: where both armies stand at the start of a battle, what
## the army bookkeeping says while it runs, the sim guard that refuses to end
## a battle on numbers that do not add up, and the end conditions.
##
## INTEGER ONLY (see units.nim): this file is `include`d into sim.nim because
## it needs the combat core's line-of-sight test, and everything it computes
## is inside `gameHash` and re-derived by the wasm viewer.

const
  MicroAimBrads* = 24
    ## Widest aim error that still counts as "attacking" a unit — the same
    ## window `control.nim`'s trigger uses, so the focus ring on the board and
    ## the trigger that produces it agree.
  MicroAimDeadBrads* = 4
    ## No turn button inside this aim error — the control layer's own dead
    ## band, shared so our units and the enemy army steer identically.
  MicroArriveRadiusSq* = 20 * 20
    ## px^2: a unit this close to its goal stops walking.
  MicroPlaceRing* = 96
    ## px: how far the spawn search may walk from a jittered point before it
    ## gives up and uses the un-jittered one.

proc microPlace(sim: var SimServer, cogIndex, wantX, wantY: int) =
  ## Snaps one spawn point to the nearest pixel at which the 13 px footprint
  ## is clear floor, searching outward in integer rings and bounded at
  ## MicroPlaceRing px. With nothing clear inside the ring the un-jittered
  ## point is used, exactly as the design note says.
  let
    x0 = clamp(wantX, PlayerHalf, MapWidth - 1 - PlayerHalf)
    y0 = clamp(wantY, PlayerHalf, MapHeight - 1 - PlayerHalf)
  if sim.canOccupy(x0, y0):
    sim.placePlayer(cogIndex, x0, y0)
    return
  for r in 1 .. MicroPlaceRing:
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x0 + dx
          ny = y0 + dy
        if nx < PlayerHalf or ny < PlayerHalf or
            nx > MapWidth - 1 - PlayerHalf or ny > MapHeight - 1 - PlayerHalf:
          continue
        if sim.canOccupy(nx, ny):
          sim.placePlayer(cogIndex, nx, ny)
          return
  sim.placePlayer(cogIndex, x0, y0)

proc microAttackTarget*(sim: SimServer, cogIndex: int): int =
  ## The enemy this unit is CURRENTLY attacking: the living unit of the other
  ## side inside its weapon's reach, with a clear line, that its aim is
  ## already pointed at (inside MicroAimBrads); ties break to the nearest.
  ## Derived from state alone, so the wasm viewer computes exactly the same
  ## number without a single recorded byte — which is why `focusCount` is
  ## derived rather than hashed.
  result = -1
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let unit = sim.players[cogIndex]
  if not unit.alive:
    return
  let
    reach = sim.config.roleReach(unit.role)
    px = unit.x + CollisionW div 2
    py = unit.y + CollisionH div 2
  var best = high(int)
  for j in 0 ..< sim.players.len:
    if j == cogIndex or not sim.players[j].alive:
      continue
    if not sim.config.microOpposed(cogIndex, j):
      continue
    let
      tx = sim.players[j].x + CollisionW div 2
      ty = sim.players[j].y + CollisionH div 2
      d = distSq(px, py, tx, ty)
    if d > reach * reach:
      continue
    let err = bradsOfVector(tx - px, ty - py) - unit.aimBrads
    var wrapped = ((err mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
    if wrapped > AimBradsTurn div 2:
      wrapped -= AimBradsTurn
    if abs(wrapped) > MicroAimBrads:
      continue
    if not sim.paintPathClear(px, py, tx, ty):
      continue
    if d < best:
      best = d
      result = j

proc updateArmiesNow*(sim: var SimServer) =
  ## Recomputes both armies' live totals and the per-enemy focus count. Called
  ## every tick from `step` after damage has been applied, and once at spawn.
  let friendly = sim.config.friendlyCount()
  sim.ourHp = 0
  sim.theirHp = 0
  sim.ourAlive = 0
  sim.theirAlive = 0
  while sim.focusCount.len < sim.players.len:
    sim.focusCount.add(0)
  while sim.lastFocusTick.len < sim.players.len:
    sim.lastFocusTick.add(low(int) div 4)
  for i in 0 ..< sim.focusCount.len:
    sim.focusCount[i] = 0
  for i in 0 ..< sim.players.len:
    let hp = max(0, sim.players[i].hp)
    if i < friendly:
      sim.ourHp += hp
      if sim.players[i].alive: inc sim.ourAlive
    else:
      sim.theirHp += hp
      if sim.players[i].alive: inc sim.theirAlive
  for i in 0 ..< friendly:
    let target = sim.microAttackTarget(i)
    if target >= 0 and target < sim.focusCount.len:
      inc sim.focusCount[target]

proc microSpawnBattle*(sim: var SimServer) =
  ## Places both armies for one battle and resets every per-battle counter.
  ##
  ## Our five stand in a column at `friendlySpawnX`, centred on the map's
  ## vertical middle and `spawnSpacingPx` apart in SEAT order; the enemy army
  ## does the same at `enemySpawnX` in ENEMY-ID order. Every unit then takes an
  ## integer jitter drawn from the sim RNG — the seed is in the config, the
  ## config is in the replay, so a replay re-derives every spawn.
  if not sim.config.microMode():
    return
  let
    friendly = sim.config.friendlyCount()
    enemies = sim.config.enemyCount()
    midY = MapHeight div 2
    jitter = max(0, sim.config.spawnJitterPx)
  sim.focusCount = newSeq[int](sim.players.len)
  sim.lastFocusTick = newSeq[int](sim.players.len)
  for i in 0 ..< sim.lastFocusTick.len:
    sim.lastFocusTick[i] = low(int) div 4
  for cogIndex in 0 ..< sim.players.len:
    let
      role = sim.config.roleOfCog(cogIndex)
      mine = cogIndex < friendly
      rank = if mine: cogIndex else: cogIndex - friendly
      count = if mine: friendly else: enemies
      baseX = if mine: sim.config.friendlySpawnX else: sim.config.enemySpawnX
      baseY = midY + (2 * rank - (count - 1)) * sim.config.spawnSpacingPx div 2
    var
      dx = 0
      dy = 0
    if jitter > 0:
      dx = sim.rng.rand(2 * jitter) - jitter
      dy = sim.rng.rand(2 * jitter) - jitter
    sim.microPlace(cogIndex, baseX + dx, baseY + dy)
    sim.players[cogIndex].homeX = sim.players[cogIndex].x
    sim.players[cogIndex].homeY = sim.players[cogIndex].y
    sim.players[cogIndex].role = role
    sim.players[cogIndex].maxHp = sim.config.roleHp(role)
    sim.players[cogIndex].hp = sim.config.roleHp(role)
    sim.players[cogIndex].speedPct = sim.config.roleSpeedPct(role)
    sim.players[cogIndex].enemyId = (if mine: 0 else: rank + 1)
    sim.players[cogIndex].alive = true
    sim.players[cogIndex].lives = 1
    sim.players[cogIndex].deathTick = -1
    sim.players[cogIndex].microDealt = 0
    sim.players[cogIndex].microTaken = 0
    sim.players[cogIndex].targetSeat = -1
    sim.players[cogIndex].retargetCounter = 0
    sim.players[cogIndex].stuckCount = 0
    sim.players[cogIndex].stuckRotTicks = 0
    sim.players[cogIndex].fireCooldown = 0
    sim.players[cogIndex].fireWindup = 0
    sim.players[cogIndex].windupBrads = -1
    sim.players[cogIndex].arcTicksLeft = 0
    sim.players[cogIndex].arcAimBrads = -1
    sim.players[cogIndex].arcHitMask = 0
    sim.players[cogIndex].kills = 0
    sim.players[cogIndex].deaths = 0
    sim.players[cogIndex].shotsFired = 0
    sim.players[cogIndex].respawnTimer = 0
    # A melee unit carries the arc weapon; a ranger carries the hitscan gun.
    # These are the starter's own two weapon gates, so no new branch is needed
    # anywhere in the resolution path.
    sim.players[cogIndex].hasSprayPaint = role.isMelee()
    # Both lines face each other across the 475 px gap.
    sim.players[cogIndex].aimBrads = (if mine: 0 else: 128)
    sim.players[cogIndex].flipH = not mine
  sim.ourStartHp = 0
  sim.enemyStartHp = 0
  for cogIndex in 0 ..< sim.players.len:
    if cogIndex < friendly: sim.ourStartHp += sim.players[cogIndex].maxHp
    else: sim.enemyStartHp += sim.players[cogIndex].maxHp
  sim.battleDmgDealt = 0
  sim.battleDmgTaken = 0
  sim.updateArmiesNow()

proc checkMicroInvariants*(sim: SimServer) =
  ## The sim guard (design §Sim module), evaluated every tick BEFORE a battle
  ## can be ended on the numbers it checks. A trip raises SimGuardError, which
  ## the server's tick loop turns into `fault` / `sim_fault`.
  if not sim.config.microMode():
    return
  let friendly = sim.config.friendlyCount()
  if sim.players.len != friendly + sim.config.enemyCount():
    raise newException(
      SimGuardError,
      "micro roster is " & $sim.players.len & " units, expected " &
        $(friendly + sim.config.enemyCount()))
  var
    ours = 0
    theirs = 0
    dealt = 0
    taken = 0
  for i in 0 ..< sim.players.len:
    let unit = sim.players[i]
    if unit.alive:
      let
        cx = unit.x + CollisionW div 2
        cy = unit.y + CollisionH div 2
      if cx < 0 or cy < 0 or cx >= MapWidth or cy >= MapHeight:
        raise newException(
          SimGuardError, "unit " & $i & " left the map box at tick " &
            $sim.tickCount)
      if sim.isWall(cx, cy):
        raise newException(
          SimGuardError, "unit " & $i & " stands inside a wall at tick " &
            $sim.tickCount)
    if unit.hp < 0 or unit.hp > unit.maxHp:
      raise newException(
        SimGuardError, "unit " & $i & " hp " & $unit.hp & " out of [0, " &
          $unit.maxHp & "]")
    if unit.hp == 0 and unit.alive:
      raise newException(SimGuardError, "unit " & $i & " is alive at 0 hp")
    if i < friendly:
      if unit.alive: inc ours
      dealt += unit.microDealt
      taken += unit.microTaken
    else:
      if unit.alive: inc theirs
  if ours != sim.ourAlive or theirs != sim.theirAlive:
    raise newException(
      SimGuardError,
      "alive counts disagree with a full recount (" & $sim.ourAlive & "/" &
        $sim.theirAlive & " vs " & $ours & "/" & $theirs & ")")
  if dealt != sim.battleDmgDealt:
    raise newException(
      SimGuardError,
      "our damage ledger " & $dealt & " != battleDmgDealt " &
        $sim.battleDmgDealt)
  if taken != sim.battleDmgTaken:
    raise newException(
      SimGuardError,
      "our damage taken " & $taken & " != battleDmgTaken " &
        $sim.battleDmgTaken)
  if sim.battleDmgDealt > sim.enemyStartHp:
    raise newException(
      SimGuardError, "banked damage exceeds the enemy starting pool")
  if sim.battleDmgTaken > sim.ourStartHp:
    raise newException(
      SimGuardError, "banked losses exceed our starting pool")

proc finishBattle(sim: var SimServer, endRule: string) =
  ## Ends the battle in play with the named rule. The winner argument only
  ## drives the inherited log line and the reward accounts; the micro score is
  ## derived from `battleLog` in `microResultsJson`.
  sim.endRule = endRule
  if sim.endReason.len == 0:
    sim.endReason = ReasonComplete
  case endRule
  of EndRuleVictory: sim.finishGame(Red)
  of EndRuleWipe: sim.finishGame(Blue)
  else: sim.finishGame(Red, isDraw = true, timeLimitReached = true)

proc checkBattleEnd*(sim: var SimServer) =
  ## Replaces checkKothEnd / checkWinCondition / checkMaxTicks under the micro
  ## loadout, evaluated in EXACTLY this order — so a tick that annihilates both
  ## sides is a `wipe`, never a victory.
  if sim.phase != Playing:
    return
  if sim.ourAlive == 0:
    sim.finishBattle(EndRuleWipe)
  elif sim.theirAlive == 0:
    inc sim.battlesWon
    sim.finishBattle(EndRuleVictory)
  elif sim.config.maxTicks > 0 and sim.gameTicksElapsed() >= sim.config.maxTicks:
    sim.finishBattle(EndRuleFullTime)

proc archiveBattle*(sim: var SimServer) =
  ## Banks the battle in play into `battleLog`. Called by the server when the
  ## phase turns GameOver and by the wall-clock stop, so an episode cut short
  ## keeps the value of every battle that actually ran.
  if not sim.config.microMode():
    return
  var
    kills = 0
    losses = 0
  let seats = max(1, sim.config.numAgents)
  while sim.seatDamage.len < seats: sim.seatDamage.add(0)
  while sim.seatTaken.len < seats: sim.seatTaken.add(0)
  while sim.seatKills.len < seats: sim.seatKills.add(0)
  while sim.seatDeaths.len < seats: sim.seatDeaths.add(0)
  while sim.seatShots.len < seats: sim.seatShots.add(0)
  for i in 0 ..< sim.players.len:
    if i < sim.config.friendlyCount():
      kills += sim.players[i].kills
      if not sim.players[i].alive: inc losses
      ## The per-seat counters reset at every battle spawn, so the EPISODE
      ## totals the results document reports are banked here, once per battle.
      if i < seats:
        sim.seatDamage[i] += sim.players[i].microDealt
        sim.seatTaken[i] += sim.players[i].microTaken
        sim.seatKills[i] += sim.players[i].kills
        sim.seatShots[i] += sim.players[i].shotsFired
        if not sim.players[i].alive: inc sim.seatDeaths[i]
  sim.battleLog.add BattleRecord(
    ticks: sim.gameTicksElapsed(),
    endRule: (if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime),
    dmgDealt: sim.battleDmgDealt,
    dmgTaken: sim.battleDmgTaken,
    enemyStartHp: max(1, sim.enemyStartHp),
    ourStartHp: max(1, sim.ourStartHp),
    kills: kills,
    losses: losses,
    won: sim.endRule == EndRuleVictory
  )

proc applyStop*(sim: var SimServer, tick: int) =
  ## THE LOAD-BEARING WALL-CLOCK STOP. The engine's 690 s budget is a wall-clock
  ## fact and cannot be re-derived from sim state, so it is recorded as ONE
  ## `stop` chat record and applied by THIS proc on record AND on playback
  ## (particle-worlds 13c66d7, 2026-08-26). Doing it any other way is what
  ## makes every deadline-ended replay show a hash warning at the stop tick.
  ##
  ## The battle in progress banks its damage with `won = 0`; battles already
  ## finished keep their value; battles never started score 0 because
  ## `microTeamScorePermille` always divides by `maxGames`.
  if not sim.config.microMode():
    return
  if sim.endReason == ReasonDeadline and sim.phase == GameOver:
    return
  sim.endReason = ReasonDeadline
  sim.endRule = EndRuleWallClock
  if sim.phase == Playing:
    sim.archiveBattle()
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
  sim.endReason = ReasonDeadline
  sim.endRule = EndRuleWallClock
  discard tick

proc microTeamScorePermille*(sim: SimServer): int =
  ## The squad's score on the [0, 1] league scale, in permille: the mean of
  ## every battle's term over `maxGames`, so battles a deadline never started
  ## score exactly 0.
  let games = max(1, sim.config.maxGames)
  var total = 0
  for battle in sim.battleLog:
    total += sim.config.battleScorePermille(
      battle.won, battle.dmgDealt, battle.enemyStartHp,
      battle.dmgTaken, battle.ourStartHp)
  clamp(total div games, 0, 1000)
