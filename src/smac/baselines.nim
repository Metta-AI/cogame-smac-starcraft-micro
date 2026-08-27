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

proc nthDeepestEnemy(sim: SimServer, x, y, rank: int): int =
  ## The `rank`-th FARTHEST living enemy from a map point (0 = farthest),
  ## ranked by integer squared distance with the enemy id as the tie-break so
  ## the order is total and machine-independent. The rank wraps when fewer
  ## enemies are standing than it asks for, so a five-unit squad always has a
  ## target. -1 when the enemy army is gone.
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
  ranked[ranked.high - (rank mod ranked.len)][2]

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int]
): SquadDirective =
  ## The directive one baseline issues for the units it governs this turn.
  ##
  ## `focusfire` — every RANGED unit derives the SAME kill order from state
  ## alone and shoots it from a per-seat standoff post. A ranger `focus`es it
  ## unless a melee enemy is inside `panicPx`, in which case it `kite`s that
  ## enemy — it is worth more alive at 300 px than dead at 50. A blade
  ## `screen`s while a friendly ranger is alive and a melee enemy is closing on
  ## it; otherwise it `focus`es the enemy nearest ITSELF, because a melee unit
  ## cannot concentrate fire from where it stands — it can only walk, and five
  ## blades walking at one enemy are a pile, not a focus.
  ##
  ## `charge` — weaker BY CONSTRUCTION and different in SHAPE, so the ladder
  ## gets a spread rather than two versions of one bot: unit k `attack_move`s at
  ## the (k + turn)-th DEEPEST living enemy in the formation as seen from our
  ## squad centre, and nobody kites or screens. Three weaknesses in one rule —
  ## the squad pushes to the far side of the enemy army and fights it from the
  ## inside (our damage is cooldown-capped, the number of enemies in contact is
  ## not), the damage splits five ways instead of killing anything, and the
  ## rotating rank abandons a half-killed enemy every turn.
  ## tests/test_control.nim pins `focus > charge` on all four shipped
  ## compositions.
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
      ## OVER-COMMIT, AND NEVER COMMIT. Three deliberate weaknesses in one
      ## integer rule, and every one of them is a real bad habit:
      ##   * the target is measured from OUR SQUAD CENTRE, deepest first, so
      ##     the whole squad pushes to the FAR side of the enemy formation and
      ##     ends up fighting it from the inside — our damage is capped by the
      ##     weapon cooldown, the number of enemies in contact with us is not;
      ##   * the rank is seat-indexed, so five units pick five different enemies
      ##     and the damage splits instead of killing anything;
      ##   * the rank also rotates with the TURN, so a half-killed enemy is
      ##     abandoned every turn. Nobody kites, nobody screens, nobody
      ##     finishes.
      ## Still a pure function of the state (turn = gameTicksElapsed div
      ## turnTicks), so it is as re-derivable as the rest of the baseline.
      let
        centre = microCentre(sim)
        turn = sim.gameTicksElapsed() div max(1, sim.config.turnTicks)
        near = sim.nthDeepestEnemy(centre.x, centre.y, cogIndex + turn)
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
      ## MELEE, and this is where focus fire stops being a RANGED idea. A blade
      ## cannot trade at range: it walks to its target, and five blades sent at
      ## ONE enemy converge into a pile that swings at a single low-hp unit
      ## while the rest of the army chews on them. It engages the enemy nearest
      ## ITSELF instead — hit what you can reach — and the squad's shared kill
      ## order is left to the rangers, who can actually concentrate fire from
      ## where they stand. MEASURED at the pinned seed: five blades chasing one
      ## kill order through a twenty-unit swarm scored 0.327, and 0.925 with the
      ## half-distance version of this rule, against `charge`'s 0.942.
      let near = sim.livingEnemyNearest(px, py)
      if near >= 0:
        order.targetId = sim.config.enemyIdOf(near)
        order.targetX = sim.players[near].x + CollisionW div 2
        order.targetY = sim.players[near].y + CollisionH div 2
        order.say = sim.cogAlias(near)
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
