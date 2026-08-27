## The two published scripted baselines.
##
## Both emit the SAME directive object an LLM does, on the same 5.0 s cadence,
## so their output is legal by construction and directly comparable. Both are
## pure functions of the world state, which is what makes the bounded-orders
## test in tests/test_control.nim meaningful.
##
## `focusfire` is load-bearing in four places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, the driver of a
## unit whose seat never connected, and the default for a seat that registers
## with neither PLAYER_PROMPT nor PLAYER_SCRIPTED. It is documented in
## docs/RULES.md precisely so "cooperating with a partner you did not write"
## here means "a partner whose published rules you know".

import
  std/[algorithm, strutils],
  sim, control, directives

type
  Baseline* = enum
    blFocusFire = "focusfire"
    blCharge = "charge"

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `focusfire`: a seat that
  ## says nothing useful still plays the published default rather than sitting
  ## out.
  case text.strip().toLowerAscii()
  of "charge": blCharge
  else: blFocusFire

proc killOrder*(sim: SimServer): int =
  ## The ONE target every `focusfire` unit derives from state alone, so five
  ## independent seats converge on it without communicating. Living enemies are
  ## ranked by, in order:
  ##   (a) inside 420 px of ANY living friendly unit, before everything else;
  ##   (b) current hp ascending — the one closest to dying;
  ##   (c) integer squared distance to our squad centroid ascending;
  ##   (d) enemy id ascending.
  ## -1 when the enemy army is gone.
  result = -1
  let
    centre = microCentre(sim)
    engageSq = AimRangeRanged * AimRangeRanged
  var
    bestEngaged = false
    bestHp = 0
    bestDist = 0
  for j in sim.config.friendlyCount() ..< sim.players.len:
    if not sim.players[j].alive:
      continue
    let
      ex = sim.players[j].x + CollisionW div 2
      ey = sim.players[j].y + CollisionH div 2
    var engaged = false
    for i in 0 ..< min(sim.config.friendlyCount(), sim.players.len):
      if not sim.players[i].alive:
        continue
      if distSq(sim.players[i].x + CollisionW div 2,
                sim.players[i].y + CollisionH div 2, ex, ey) <= engageSq:
        engaged = true
        break
    let dist = distSq(centre.x, centre.y, ex, ey)
    if result < 0:
      result = j
      bestEngaged = engaged
      bestHp = sim.players[j].hp
      bestDist = dist
      continue
    var better = false
    if engaged != bestEngaged:
      better = engaged
    elif sim.players[j].hp != bestHp:
      better = sim.players[j].hp < bestHp
    elif dist != bestDist:
      better = dist < bestDist
    if better:
      result = j
      bestEngaged = engaged
      bestHp = sim.players[j].hp
      bestDist = dist

proc nearestMeleeEnemy(sim: SimServer, cogIndex: int): int =
  ## The living enemy BLADE or SWARM unit nearest one of our units, or -1.
  result = -1
  var best = high(int)
  let
    px = sim.players[cogIndex].x + CollisionW div 2
    py = sim.players[cogIndex].y + CollisionH div 2
  for j in sim.config.friendlyCount() ..< sim.players.len:
    if not sim.players[j].alive or not sim.players[j].role.isMelee():
      continue
    let d = distSq(px, py, sim.players[j].x + CollisionW div 2,
                   sim.players[j].y + CollisionH div 2)
    if d < best:
      best = d
      result = j

proc nthNearestEnemy(sim: SimServer, x, y, rank: int): int =
  ## The `rank`-th nearest living enemy to a map point (0 = nearest), ranked by
  ## integer squared distance with the enemy id as the tie-break so the order is
  ## total and machine-independent. The rank wraps when fewer enemies are
  ## standing than the rank asks for, so a five-unit squad always has a target.
  ## -1 when the enemy army is gone.
  var ranked: seq[(int, int, int)] = @[]   # (distSq, enemy id, cog index)
  for j in sim.config.friendlyCount() ..< sim.players.len:
    if not sim.players[j].alive:
      continue
    ranked.add((
      distSq(x, y, sim.players[j].x + CollisionW div 2,
             sim.players[j].y + CollisionH div 2),
      sim.config.enemyIdOf(j),
      j))
  if ranked.len == 0:
    return -1
  ranked.sort()
  ranked[rank mod ranked.len][2]

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int]
): SquadDirective =
  ## The directive one baseline issues for the units it governs this turn.
  ##
  ## `focusfire` — every governed unit derives the SAME kill order from state
  ## alone. A ranger `focus`es it unless a melee enemy is inside `panicPx`, in
  ## which case it `kite`s that enemy — it is worth more alive at 300 px than
  ## dead at 50. A blade `screen`s while a friendly ranger is alive and a melee
  ## enemy is closing on it, otherwise `focus`es the kill order.
  ##
  ## `charge` — weaker BY CONSTRUCTION and different in SHAPE, so the ladder
  ## gets a spread rather than two versions of one bot: unit k `attack_move`s at
  ## the k-th nearest living enemy to ITSELF, every turn. Nobody kites, nobody
  ## screens, and the seat-indexed rank means the five units pick five
  ## DIFFERENT enemies whenever the army is that big — so the squad splits its
  ## damage, every enemy lives longer, and every extra tick an enemy lives is
  ## another swing at us. That is the arithmetic (focused damage kills faster
  ## than spread damage, so it takes less in return) which makes `focusfire`
  ## beat `charge` on every shipped composition rather than only on the ones
  ## where "nearest me" happens to differ from the squad's kill order.
  ## tests/test_control.nim pins the inequality on all four.
  result.source = dsScripted
  result.note = (if kind == blCharge: "charge" else: "focus fire")
  if governed.len == 0:
    return
  let
    order0 = killOrder(sim)
    panicSq = max(1, sim.config.panicPx) * max(1, sim.config.panicPx)
    screenPx = 260
  for cogIndex in governed:
    if cogIndex < 0 or cogIndex >= sim.players.len:
      continue
    var order = CogOrder(
      cogIndex: cogIndex,
      id: sim.cogAlias(cogIndex),
      intent: intFocus,
      targetId: -1,
      targetX: sim.players[cogIndex].x + CollisionW div 2,
      targetY: sim.players[cogIndex].y + CollisionH div 2
    )
    let
      px = sim.players[cogIndex].x + CollisionW div 2
      py = sim.players[cogIndex].y + CollisionH div 2
    if order0 < 0:
      ## No enemy left standing: everyone regroups on the squad centre.
      let centre = microCentre(sim)
      order.intent = intRegroup
      order.targetX = centre.x
      order.targetY = centre.y
      order.say = "clear"
      result.orders.add(order)
      continue
    if kind == blCharge:
      ## Seat-indexed spreading: seat 0 takes the enemy nearest it, seat 1 the
      ## second nearest to IT, and so on. Pure function of the state, so it is
      ## as re-derivable as the rest of the baseline.
      let near = sim.nthNearestEnemy(px, py, cogIndex)
      let pick = (if near >= 0: near else: order0)
      order.intent = intAttackMove
      order.targetId = sim.config.enemyIdOf(pick)
      order.targetX = sim.players[pick].x + CollisionW div 2
      order.targetY = sim.players[pick].y + CollisionH div 2
      order.say = "go"
      result.orders.add(order)
      continue
    order.targetId = sim.config.enemyIdOf(order0)
    order.targetX = sim.players[order0].x + CollisionW div 2
    order.targetY = sim.players[order0].y + CollisionH div 2
    order.say = sim.cogAlias(order0)
    if sim.players[cogIndex].role == urRanger:
      let threat = nearestMeleeEnemy(sim, cogIndex)
      if threat >= 0 and
          distSq(px, py, sim.players[threat].x + CollisionW div 2,
                 sim.players[threat].y + CollisionH div 2) <= panicSq:
        order.intent = intKite
        order.targetId = sim.config.enemyIdOf(threat)
        order.targetX = sim.players[threat].x + CollisionW div 2
        order.targetY = sim.players[threat].y + CollisionH div 2
        order.say = "kite"
    else:
      let ranger = weakestRanger(sim)
      if ranger >= 0:
        let threat = nearestMeleeEnemy(sim, ranger)
        if threat >= 0 and
            distSq(sim.players[ranger].x + CollisionW div 2,
                   sim.players[ranger].y + CollisionH div 2,
                   sim.players[threat].x + CollisionW div 2,
                   sim.players[threat].y + CollisionH div 2) <=
              screenPx * screenPx:
          order.intent = intScreen
          order.say = "screen"
    result.orders.add(order)
