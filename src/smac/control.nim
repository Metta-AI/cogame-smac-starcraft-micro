## The control layer: the ONE deterministic function that turns a directive
## into per-tick Sprite v1 actuator masks.
##
## Both LLM directives and scripted directives are compiled by this same code,
## so the two policy kinds are strictly comparable and a scripted baseline is
## legal by construction. It is a pure function of
## `(sim state, directive, cogIndex) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback, which is why this
## module may use ordinary floating-point navigation maths where the hashed
## paint grid may not.

import
  std/[math, tables],
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px.
                              ## Sized to the ARENA, not to the paint grid: the
                              ## arena's corridors are ~26 px wide for a 13 px
                              ## footprint, so a cell the size of a paint tile
                              ## (34 px) has no open cell anywhere inside a gap
                              ## between two obstacles and the flow field
                              ## reports the whole far side of every obstacle
                              ## column UNREACHABLE. Measured on that grid, a
                              ## sweeping squad fell back to the straight line,
                              ## walked into the first wall and pressed the same
                              ## d-pad direction for two thousand ticks. At
                              ## 12 px every 26 px corridor contains a cell
                              ## centre with the full footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
                              ## A field is one int per cell, so an unbounded
                              ## cache on a fine grid is an unbounded leak over
                              ## a long episode; eight cogs never need more.
  ArriveRadius* = 20          ## px: a cog this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  FireAimBrads* = 24          ## widest aim error that still pulls the trigger.
  HuntMemoryTicks* = 72       ## how long a seen enemy stays "known".
  HuntRangePx* = 300          ## aim priority radius for a known enemy.
  AimRangeRanged* = 420       ## px: a RANGER turns to face an enemy this far
                              ## off — a little past its 380 px weapon range,
                              ## so it is already lined up when the target
                              ## walks in.
  AimRangeMelee* = 120        ## px: a BLADE turns to face an enemy this far
                              ## off; twice its 56 px reach.
  StuckTicks* = 8             ## ticks of zero displacement after which a cog
                              ## steers along the obstacle instead of into it.
                              ## The flow field is built once, over the wall
                              ## mask alone: it cannot know about the spinning
                              ## diamonds' later frames, and it cannot know
                              ## about the other seven COGS at all — four cogs
                              ## sharing one goal in a 26 px corridor jam each
                              ## other. Degrade-never-hang applies to a cog as
                              ## much as to a network call.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastSeenX*, lastSeenY*: seq[int]   ## per cog: last known enemy position
    lastSeenTick*: seq[int]
    lastSeenIndex*: seq[int]
    lastX*, lastY*: seq[int]           ## per cog: position at the last observe
    stuckTicks*: seq[int]              ## per cog: consecutive motionless ticks

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL wall mask (not an
  ## observation stream): a cell is open when a cog footprint fits at its
  ## centre. Built once per episode, against the mask as it stands at build
  ## time — a spinning diamond that later rotates into a cell this grid calls
  ## open is handled by the stuck deflection in `compileMask`, not by rebuilding
  ## a five-thousand-cell grid every tick.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks. Cheap enough that eight cogs chasing eight distinct
  ## goals still costs a handful of BFS passes per second.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) < FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one cog: straight at the goal when the line of
  ## sight is clear (so a cog does not stair-step around an open floor), else
  ## down the flow field toward the neighbouring cell nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a cog, so
      # clipping the corner of an obstacle wedges the cog against it and it
      # presses the same direction forever.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastSeenX = newSeq[int](MaxPlayers)
  result.lastSeenY = newSeq[int](MaxPlayers)
  result.lastSeenTick = newSeq[int](MaxPlayers)
  result.lastSeenIndex = newSeq[int](MaxPlayers)
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastSeenTick[i] = low(int) div 2
    result.lastSeenIndex[i] = -1
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2

proc observeEnemies*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: each cog's memory of the
  ## nearest enemy it can currently see, and whether it is making progress.
  ## Vision is the sim's own fog rule, so the control layer never knows more
  ## than the cog does.
  ##
  ## Both are updated here rather than in `compileMask` so that compiling a
  ## mask stays a pure read of this state: the same (state, directive) pair
  ## yields the same byte however many times it is asked.
  while ctl.lastSeenX.len < sim.players.len:
    ctl.lastSeenX.add(0)
    ctl.lastSeenY.add(0)
    ctl.lastSeenTick.add(low(int) div 2)
    ctl.lastSeenIndex.add(-1)
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  for i in 0 ..< sim.players.len:
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    var
      bestDist = high(int)
      bestIndex = -1
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive:
        continue
      if sim.players[j].team == sim.players[i].team:
        continue
      ## MICRO: the board is fully observable (fogOfWar false in every shipped
      ## variant), so "seen" is a clear LINE, not a fog cone.
      if sim.config.microMode():
        if not sim.paintPathClear(
            sim.players[i].x + CollisionW div 2,
            sim.players[i].y + CollisionH div 2,
            sim.players[j].x + CollisionW div 2,
            sim.players[j].y + CollisionH div 2):
          continue
      elif not sim.playerVisibleTo(i, j):
        continue
      let d = distSq(sim.players[i].x, sim.players[i].y,
                     sim.players[j].x, sim.players[j].y)
      if d < bestDist:
        bestDist = d
        bestIndex = j
    if bestIndex >= 0:
      ctl.lastSeenX[i] = sim.players[bestIndex].x
      ctl.lastSeenY[i] = sim.players[bestIndex].y
      ctl.lastSeenTick[i] = sim.tickCount
      ctl.lastSeenIndex[i] = bestIndex

proc knownEnemy*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[known: bool, x, y, index, ticksAgo: int] =
  ## The nearest enemy this cog knows about — seen now, or seen within
  ## HuntMemoryTicks. That memory is intel a commander legitimately has.
  if cogIndex >= ctl.lastSeenTick.len:
    return (false, 0, 0, -1, 0)
  let age = sim.tickCount - ctl.lastSeenTick[cogIndex]
  if age > HuntMemoryTicks or ctl.lastSeenIndex[cogIndex] < 0:
    return (false, 0, 0, -1, 0)
  (true, ctl.lastSeenX[cogIndex], ctl.lastSeenY[cogIndex],
   ctl.lastSeenIndex[cogIndex], age)

proc microCentre*(sim: SimServer): tuple[x, y: int] =
  ## The integer mean of our LIVING units' centres — the squad's centre of
  ## mass, which `regroup` walks to and which ranks the kill order.
  var
    sx = 0
    sy = 0
    n = 0
  for i in 0 ..< min(sim.config.friendlyCount(), sim.players.len):
    if not sim.players[i].alive:
      continue
    sx += sim.players[i].x + CollisionW div 2
    sy += sim.players[i].y + CollisionH div 2
    inc n
  if n == 0:
    return (x: MapWidth div 2, y: MapHeight div 2)
  (x: sx div n, y: sy div n)

proc livingEnemyNearest*(
  sim: SimServer, x, y: int
): int =
  ## The living enemy unit whose centre is nearest a map point, or -1.
  result = -1
  var best = high(int)
  for j in sim.config.friendlyCount() ..< sim.players.len:
    if not sim.players[j].alive:
      continue
    let d = distSq(
      x, y, sim.players[j].x + CollisionW div 2,
      sim.players[j].y + CollisionH div 2)
    if d < best:
      best = d
      result = j

proc resolveOrderEnemy*(
  sim: SimServer, order: CogOrder, cogIndex: int
): int =
  ## The enemy `E*` an order names: `target_id` when it names a LIVING enemy,
  ## else the living enemy nearest the order's clamped `target`, else the
  ## living enemy nearest the unit, else -1.
  if order.targetId > 0:
    let cog = sim.config.cogOfEnemyId(order.targetId)
    if cog >= 0 and cog < sim.players.len and sim.players[cog].alive:
      return cog
  result = sim.livingEnemyNearest(order.targetX, order.targetY)
  if result >= 0:
    return
  if cogIndex >= 0 and cogIndex < sim.players.len:
    result = sim.livingEnemyNearest(
      sim.players[cogIndex].x + CollisionW div 2,
      sim.players[cogIndex].y + CollisionH div 2)

proc weakestRanger*(sim: SimServer): int =
  ## The living friendly RANGER with the lowest hp; ties break to the lowest
  ## seat index. -1 when no ranger is alive.
  result = -1
  var best = high(int)
  for i in 0 ..< min(sim.config.friendlyCount(), sim.players.len):
    if not sim.players[i].alive or sim.players[i].role != urRanger:
      continue
    if sim.players[i].hp < best:
      best = sim.players[i].hp
      result = i

proc standoffPoint*(
  sim: SimServer, targetX, targetY, awayX, awayY, standoff: int
): tuple[x, y: int] =
  ## A point `standoff` px from (targetX, targetY) along the direction toward
  ## (awayX, awayY), clamped into the map box and snapped to walkable ground.
  let
    dx = awayX - targetX
    dy = awayY - targetY
    span = max(1, abs(dx) + abs(dy))
  let
    px = clamp(targetX + dx * standoff div span, 0, MapWidth - 1)
    py = clamp(targetY + dy * standoff div span, 0, MapHeight - 1)
  sim.nearestWalkable(px, py)

proc rangerPost*(
  sim: SimServer, enemyIndex, cogIndex: int
): tuple[x, y: int] =
  ## Where a ranger stands to shoot one enemy: the first clear point found by
  ## probing 16 evenly spaced points on the circle of `rangerStandoff` around
  ## it, starting from the direction "enemy -> our squad centre" and
  ## alternating outward. Nothing clear -> the enemy's own position, which is
  ## an advance rather than a stall.
  let
    ex = sim.players[enemyIndex].x + CollisionW div 2
    ey = sim.players[enemyIndex].y + CollisionH div 2
    centre = microCentre(sim)
    standoff = max(1, sim.config.rangerStandoff)
    base = bradsOfVector(centre.x - ex, centre.y - ey)
  for step in 0 ..< 16:
    let
      offset = ((step + 1) div 2) * 16 * (if step mod 2 == 0: 1 else: -1)
      brads = ((base + offset) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
      (ux, uy) = aimVector(brads)
      px = clamp(ex + int(ux * float(standoff)), 0, MapWidth - 1)
      py = clamp(ey + int(uy * float(standoff)), 0, MapHeight - 1)
    if sim.canOccupy(px, py) and sim.paintPathClear(px, py, ex, ey):
      return (x: px, y: py)
  (x: ex, y: ey)

proc predictedCentre*(sim: SimServer, index, ticks: int): tuple[x, y: int] =
  ## Where a unit's centre will be `ticks` from now at its current velocity —
  ## integer lead, so a ranger's 5-tick windup is aimed where the target is
  ## going rather than where it was.
  let p = sim.players[index]
  (x: p.x + CollisionW div 2 + p.velX * ticks div MotionScale,
   y: p.y + CollisionH div 2 + p.velY * ticks div MotionScale)

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to for one unit. Every branch has a
  ## defined answer, so a unit is never left without somewhere to be, and the
  ## CHASE CAP below means it never abandons the squad for half a map on one
  ## order.
  let
    unit = sim.players[cogIndex]
    px = unit.x + CollisionW div 2
    py = unit.y + CollisionH div 2
    target: tuple[x, y: int] = (clamp(order.targetX, 0, MapWidth - 1),
                                clamp(order.targetY, 0, MapHeight - 1))
    enemy = sim.resolveOrderEnemy(order, cogIndex)
  var
    goal: tuple[x, y: int] = target
    capped = false
  case order.intent
  of intFocus:
    if enemy < 0:
      goal = target
    elif unit.role == urRanger:
      goal = sim.rangerPost(enemy, cogIndex)
      capped = true
    else:
      goal = (x: sim.players[enemy].x + CollisionW div 2,
              y: sim.players[enemy].y + CollisionH div 2)
      capped = true
  of intAttackMove:
    goal = target
    capped = true
  of intKite:
    if unit.role != urRanger:
      ## A blade reads `kite` as `focus`: it has no range to trade with.
      if enemy >= 0:
        goal = (x: sim.players[enemy].x + CollisionW div 2,
                y: sim.players[enemy].y + CollisionH div 2)
        capped = true
      else:
        goal = target
    else:
      let nearest = sim.livingEnemyNearest(px, py)
      if nearest < 0:
        goal = target
      else:
        let
          nx = sim.players[nearest].x + CollisionW div 2
          ny = sim.players[nearest].y + CollisionH div 2
        if unit.fireCooldown == 0 and unit.fireWindup == 0 and
            distSq(px, py, nx, ny) <=
              sim.config.rangerRange * sim.config.rangerRange and
            sim.paintPathClear(px, py, nx, ny):
          ## SHOOT AND SCOOT: the weapon is ready and the shot will land, so
          ## the unit stands still and fires. This is the ONE place in the
          ## design where a goal depends on the weapon's cooldown.
          goal = (x: px, y: py)
        else:
          goal = sim.standoffPoint(
            nx, ny, px, py, max(1, sim.config.kiteStandoff))
  of intHold:
    goal = target
  of intScreen:
    let ranger = weakestRanger(sim)
    if ranger < 0:
      if enemy >= 0:
        goal = (x: sim.players[enemy].x + CollisionW div 2,
                y: sim.players[enemy].y + CollisionH div 2)
        capped = true
      else:
        goal = target
    else:
      let
        rx = sim.players[ranger].x + CollisionW div 2
        ry = sim.players[ranger].y + CollisionH div 2
        threat = sim.livingEnemyNearest(rx, ry)
      if threat < 0:
        goal = target
      else:
        goal = sim.standoffPoint(
          rx, ry,
          sim.players[threat].x + CollisionW div 2,
          sim.players[threat].y + CollisionH div 2,
          max(1, sim.config.screenStandoff))
        capped = true
  of intRetreat:
    let zone = sim.captureZone(sim.players[cogIndex].team)
    goal = (x: clamp(target.x, zone.xLo, zone.xHi),
            y: clamp(target.y, zone.yLo, zone.yHi))
  of intRegroup:
    var
      sx = 0
      sy = 0
      n = 0
    for i in 0 ..< min(sim.config.friendlyCount(), sim.players.len):
      if i == cogIndex or not sim.players[i].alive:
        continue
      sx += sim.players[i].x + CollisionW div 2
      sy += sim.players[i].y + CollisionH div 2
      inc n
    goal = (if n == 0: target else: (x: sx div n, y: sy div n))
  if capped:
    let cap = max(1, sim.config.chaseCapPx)
    let d = distSq(px, py, goal.x, goal.y)
    if d > cap * cap:
      let span = max(1, abs(goal.x - px) + abs(goal.y - py))
      goal = (x: clamp(px + (goal.x - px) * cap div span, 0, MapWidth - 1),
              y: clamp(py + (goal.y - py) * cap div span, 0, MapHeight - 1))
  goal

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: CogOrder,
  cogIndex: int
): uint8 =
  ## One unit's Sprite v1 actuator mask for this tick.
  ##
  ## Legality is STRUCTURAL, not checked afterwards: Up and Down are chosen
  ## from one sign so they can never both be set (same for Left/Right), B and
  ## Select come from one signed error, and C is never touched, because this
  ## loadout places nothing C could throw.
  result = 0
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let unit = sim.players[cogIndex]
  if not unit.alive:
    return
  let
    px = unit.x + CollisionW div 2
    py = unit.y + CollisionH div 2
    ranged = unit.role == urRanger
    reach = sim.config.roleReach(unit.role)
    aimRange = (if ranged: AimRangeRanged else: AimRangeMelee)
    goal = ctl.goalFor(sim, order, cogIndex)
    enemy = sim.resolveOrderEnemy(order, cogIndex)

  # --- d-pad: the octant of the steering vector, unless we have arrived ---
  if distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if cogIndex < ctl.stuckTicks.len and ctl.stuckTicks[cogIndex] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the unit
      # ALONG whatever it is pressed against. One consistent rotation makes
      # this a wall follower, so a convex obstacle is escaped rather than
      # oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      # Diagonals only when the minor axis is at least 40% of the major one,
      # so a straight run does not chatter between two octants.
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- aim, in priority order ------------------------------------------------
  var
    aimX = goal.x
    aimY = goal.y
    aimed = -1
  if enemy >= 0 and sim.players[enemy].alive and
      distSq(px, py, sim.players[enemy].x + CollisionW div 2,
             sim.players[enemy].y + CollisionH div 2) <= aimRange * aimRange and
      sim.paintPathClear(px, py, sim.players[enemy].x + CollisionW div 2,
                         sim.players[enemy].y + CollisionH div 2):
    aimed = enemy
  else:
    let nearest = sim.livingEnemyNearest(px, py)
    if nearest >= 0 and
        distSq(px, py, sim.players[nearest].x + CollisionW div 2,
               sim.players[nearest].y + CollisionH div 2) <=
          aimRange * aimRange:
      aimed = nearest
  if aimed >= 0:
    ## A ranger leads its target: the shot is instantaneous but the windup is
    ## FireWindupTicks long, so it aims where the body will be.
    let lead =
      if ranged: sim.predictedCentre(aimed, sim.config.fireWindupTicks)
      else: (sim.players[aimed].x + CollisionW div 2,
             sim.players[aimed].y + CollisionH div 2)
    aimX = lead.x
    aimY = lead.y
  elif order.hasFace:
    aimX = order.faceX
    aimY = order.faceY
  elif distSq(px, py, goal.x, goal.y) <= AimMinRangeSq:
    ## Standing on the goal gives a vector of length ~0, which reads as due
    ## east. Face east deliberately instead — that is where the army comes
    ## from.
    aimX = px + 64
    aimY = py
  let
    desired = bradsOfVector(aimX - px, aimY - py)
    err = bradsErr(desired, unit.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise

  # --- trigger ---------------------------------------------------------------
  if order.intent == intRetreat:
    return                              ## a retreating unit never fires.
  if unit.fireCooldown > 0 or unit.fireWindup > 0 or unit.arcTicksLeft > 0:
    return
  if abs(err) > FireAimBrads:
    return
  let (ux, uy) = aimVector(unit.aimBrads)
  var worthIt = false
  for j in sim.config.friendlyCount() ..< sim.players.len:
    if not sim.players[j].alive:
      continue
    let
      tx = sim.players[j].x + CollisionW div 2
      ty = sim.players[j].y + CollisionH div 2
    if distSq(px, py, tx, ty) > reach * reach:
      continue
    if not sim.paintPathClear(px, py, tx, ty):
      continue
    if ranged:
      ## A ranger only spends a shot it expects to land: the target's
      ## PREDICTED centre must lie inside the bullet corridor along the aim
      ## ray, which is exactly the acceptance window `selectFireTarget` uses.
      let
        lead = sim.predictedCentre(j, sim.config.fireWindupTicks)
        vx = float(lead.x - px)
        vy = float(lead.y - py)
        forward = vx * ux + vy * uy
      if forward <= 0.0:
        continue
      if abs(vx * uy - vy * ux) > BulletHalfWidth + float(PlayerHalf):
        continue
      worthIt = true
      break
    else:
      ## A blade swings only with a body inside the reach/half-angle wedge.
      var wrapped = bradsErr(bradsOfVector(tx - px, ty - py), unit.aimBrads)
      if abs(wrapped) <= sim.config.bladeArcBrads:
        worthIt = true
        break
  if worthIt:
    result = result or ButtonA
