## The scripted enemy army — SMAC's "built-in AI", implemented INSIDE the sim.
##
## It is not a player pod, not a control-layer client and never a recorded
## mask: the wasm viewer re-derives every enemy decision from the seed and the
## recorded friendly masks, so the army costs zero replay bytes and a hash
## mismatch stays a real integrity signal.
##
## INTEGER ONLY (see units.nim). Every distance here is an integer squared
## distance, the retarget hysteresis is an integer cross-multiply and the
## stuck escape is an integer quarter turn — no new floating-point value
## enters the hashed path.
##
## `include`d into sim.nim because it needs the combat core's line-of-sight
## test and the same actuator vocabulary our units use: an enemy produces an
## `InputState`, exactly like the control layer does for a seat, and the
## starter's `applyInput` walks it with the same wall-slide collision.

proc microEnemyRetarget*(sim: var SimServer, cogIndex: int) =
  ## Step 1 of the enemy script. Keeps the current target while it lives and
  ## stays inside `leashPx`; otherwise, and in any case every `retargetTicks`,
  ## picks the living friendly unit with the smallest integer squared distance
  ## inside `aggroPx` that has a clear line. Ties break to the lowest cog
  ## index. A retarget only replaces a LIVE current target when the candidate
  ## is at least 1.5x closer (9 * dNew <= 4 * dCur) — hysteresis, so an enemy
  ## does not oscillate between two units standing side by side.
  let
    friendly = sim.config.friendlyCount()
    px = sim.players[cogIndex].x + CollisionW div 2
    py = sim.players[cogIndex].y + CollisionH div 2
    leashSq = sim.config.leashPx * sim.config.leashPx
    aggroSq = sim.config.aggroPx * sim.config.aggroPx
  var current = sim.players[cogIndex].targetSeat
  if current >= 0 and current < friendly:
    let held = sim.players[current]
    if not held.alive or
        distSq(px, py, held.x + CollisionW div 2,
               held.y + CollisionH div 2) > leashSq:
      current = -1
  else:
    current = -1
  if sim.players[cogIndex].retargetCounter > 0:
    dec sim.players[cogIndex].retargetCounter
    if current >= 0:
      sim.players[cogIndex].targetSeat = current
      return
  sim.players[cogIndex].retargetCounter = max(1, sim.config.retargetTicks)
  var
    bestIndex = -1
    bestDist = high(int)
  for j in 0 ..< friendly:
    if not sim.players[j].alive:
      continue
    let
      tx = sim.players[j].x + CollisionW div 2
      ty = sim.players[j].y + CollisionH div 2
      d = distSq(px, py, tx, ty)
    if d > aggroSq:
      continue
    if not sim.paintPathClear(px, py, tx, ty):
      continue
    if d < bestDist:
      bestDist = d
      bestIndex = j
  if bestIndex < 0:
    sim.players[cogIndex].targetSeat = current
    return
  if current < 0:
    sim.players[cogIndex].targetSeat = bestIndex
    return
  if bestIndex == current:
    sim.players[cogIndex].targetSeat = current
    return
  let held = sim.players[current]
  let currentDist = distSq(
    px, py, held.x + CollisionW div 2, held.y + CollisionH div 2)
  # 1.5x closer, as an integer cross-multiply: (dNew / dCur) <= (2/3)^2 = 4/9.
  if 9 * bestDist <= 4 * currentDist:
    sim.players[cogIndex].targetSeat = bestIndex
  else:
    sim.players[cogIndex].targetSeat = current

proc microEnemyInput*(sim: var SimServer, cogIndex: int): InputState =
  ## One enemy's actuator state for this tick: steer at its target through the
  ## wall-slide collision, deflect a quarter turn clockwise when wedged, turn
  ## the aim toward the target, and pull the trigger when the shot will land.
  result = InputState()
  if not sim.players[cogIndex].alive:
    return
  sim.microEnemyRetarget(cogIndex)
  let
    px = sim.players[cogIndex].x + CollisionW div 2
    py = sim.players[cogIndex].y + CollisionH div 2
    target = sim.players[cogIndex].targetSeat
  var
    goalX = sim.config.friendlySpawnX
    goalY = MapHeight div 2
  if target >= 0 and target < sim.players.len:
    goalX = sim.players[target].x + CollisionW div 2
    goalY = sim.players[target].y + CollisionH div 2

  # --- stuck escape: the same wall follower control.nim uses on wedged cogs.
  if sim.players[cogIndex].x == sim.players[cogIndex].lastPosX and
      sim.players[cogIndex].y == sim.players[cogIndex].lastPosY:
    inc sim.players[cogIndex].stuckCount
  else:
    sim.players[cogIndex].stuckCount = 0
  sim.players[cogIndex].lastPosX = sim.players[cogIndex].x
  sim.players[cogIndex].lastPosY = sim.players[cogIndex].y
  if sim.players[cogIndex].stuckRotTicks > 0:
    dec sim.players[cogIndex].stuckRotTicks
  elif sim.players[cogIndex].stuckCount >= max(1, sim.config.enemyStuckTicks):
    sim.players[cogIndex].stuckRotTicks = DefaultEnemyStuckRotTicks
    sim.players[cogIndex].stuckCount = 0

  var
    stepX = goalX - px
    stepY = goalY - py
  if sim.players[cogIndex].stuckRotTicks > 0:
    let rotX = -stepY
    stepY = stepX
    stepX = rotX

  # --- d-pad: the octant of the step vector. Up+Down and Left+Right can never
  # both be set, because each pair comes from ONE sign.
  let
    ax = abs(stepX)
    ay = abs(stepY)
    major = max(ax, ay)
  if major > 0 and distSq(px, py, goalX, goalY) > MicroArriveRadiusSq:
    if ax * 5 >= major * 2:
      if stepX > 0: result.right = true else: result.left = true
    if ay * 5 >= major * 2:
      if stepY > 0: result.down = true else: result.up = true

  # --- aim: turn toward the target at AimTurnRate.
  if target < 0 or target >= sim.players.len:
    return
  let
    tx = sim.players[target].x + CollisionW div 2
    ty = sim.players[target].y + CollisionH div 2
    desired = bradsOfVector(tx - px, ty - py)
  var err = (desired - sim.players[cogIndex].aimBrads) mod AimBradsTurn
  if err < -(AimBradsTurn div 2): err += AimBradsTurn
  if err > AimBradsTurn div 2: err -= AimBradsTurn
  if err > MicroAimDeadBrads:
    result.b = true
  elif err < -MicroAimDeadBrads:
    result.select = true

  # --- trigger: inside range/reach, aim error inside FireAimBrads, clear line.
  if abs(err) > MicroAimBrads:
    return
  if sim.players[cogIndex].fireCooldown > 0 or
      sim.players[cogIndex].fireWindup > 0 or
      sim.players[cogIndex].arcTicksLeft > 0:
    return
  let reach = sim.config.roleReach(sim.players[cogIndex].role)
  if distSq(px, py, tx, ty) > reach * reach:
    return
  if not sim.paintPathClear(px, py, tx, ty):
    return
  result.attack = true

proc stepEnemyAi*(sim: var SimServer, inputs: var seq[InputState]) =
  ## Runs the whole army once per tick, in ENEMY-ID order, and writes each
  ## enemy's actuator state into the step's input array. Enemy movement, aim
  ## and trigger therefore resolve through exactly the same `applyInput` and
  ## weapon paths our units use — one combat core, no second implementation.
  ##
  ## The step body fires on a FRESH A press, and the enemy's previous mask is
  ## never in the step's `prevInputs` (nothing records it), so the edge is
  ## computed here against the hashed `heldAttack` flag instead. Without it an
  ## enemy would fire exactly once and then hold the trigger down forever.
  if not sim.config.microMode():
    return
  while inputs.len < sim.players.len:
    inputs.add(InputState())
  for cogIndex in sim.config.friendlyCount() ..< sim.players.len:
    var state = sim.microEnemyInput(cogIndex)
    let fresh = state.attack and not sim.players[cogIndex].heldAttack
    sim.players[cogIndex].heldAttack = state.attack
    state.attack = fresh
    inputs[cogIndex] = state
