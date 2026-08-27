## The decision layer: the per-turn loop that asks both commanders what their
## squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (120 ticks = 5.0 s of sim time), 12
## turns per battle, 36 per episode. At each turn the server builds ALL FIVE
## seats' request bodies and issues them as ONE parallel batch
## (`curly.makeRequests`) — this is a simultaneous-decision game, so querying
## seats one after another would quintuple the wall clock for nothing. One
## call per seat per turn; at most 5 in flight; at most 180 calls an episode.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `focusfire` scripted directive for that turn and a `fallback`
## record names the cause. No failure mode leaves a cog unactuated: the
## control layer always has a directive — this turn's, else last turn's, else
## `focusfire`'s.

import
  std/[json, math, monotimes, os, strutils, times],
  curly,
  sim, control, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `focusfire`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer
    ## Snapshots taken at the END of each turn, so "last turn" in the view is
    ## a real delta rather than a running total.
    lastSeatDamage*: seq[int]
    lastSeatShots*: seq[int]
    lastTeamDamage*: int
    lastEnemyDead*: int
    lastOurDead*: int

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  result.lastSeatDamage = newSeq[int](sim.seatCount())
  result.lastSeatShots = newSeq[int](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blFocusFire
    result.seats[i].label = "focusfire"

proc intSqrt*(value: int): int =
  ## Integer square root by Newton's method — the ONE place the seat view
  ## converts a squared distance into a readable number of pixels, and it does
  ## it without a float so the same number appears in the replay's directive
  ## record and on the board.
  if value <= 0:
    return 0
  result = value
  var guess = (value + 1) div 2
  while guess < result:
    result = guess
    guess = (guess + value div guess) div 2

proc snapshotTurn*(engine: var DecisionEngine, sim: SimServer) =
  ## Records the counters the NEXT turn's `last_turn` block diffs against.
  while engine.lastSeatDamage.len < sim.config.friendlyCount():
    engine.lastSeatDamage.add(0)
    engine.lastSeatShots.add(0)
  for i in 0 ..< min(engine.lastSeatDamage.len, sim.players.len):
    engine.lastSeatDamage[i] = sim.players[i].microDealt
    engine.lastSeatShots[i] = sim.players[i].shotsFired
  engine.lastTeamDamage = sim.battleDmgDealt
  engine.lastEnemyDead = sim.config.enemyCount() - sim.theirAlive
  engine.lastOurDead = sim.config.friendlyCount() - sim.ourAlive

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerBattle: int
): string =
  ## Everything this seat may legitimately know, in MAP PIXELS, rounded to
  ## integers. The board is fully observable (design §Per-seat observation), so
  ## every living unit on both sides is here with its hit points — but the
  ## other seats' directives FOR THE TURN BEING DECIDED are not, and neither is
  ## the seed, the RNG state, any future jitter, the enemy AI's internal
  ## counters, any seat's PLAYER_PROMPT or any real policy name. Units are
  ## RANGER-*/BLADE-*/E<n> and nothing else.
  let
    friendly = sim.config.friendlyCount()
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)
    px = (if seat < sim.players.len: sim.players[seat].x + CollisionW div 2
          else: 0)
    py = (if seat < sim.players.len: sim.players[seat].y + CollisionH div 2
          else: 0)

  var you = newJObject()
  if seat < sim.players.len:
    let p = sim.players[seat]
    you = %*{
      "id": sim.cogAlias(seat),
      "role": roleText(p.role),
      "alive": p.alive,
      "pos": [px, py],
      "aim": p.aimBrads,
      "hp": max(0, p.hp),
      "hp_max": p.maxHp,
      "range_px": sim.config.roleReach(p.role),
      "cooldown_ticks": max(0, p.fireCooldown),
      "ready": p.alive and p.fireCooldown <= 0 and p.fireWindup <= 0 and
        p.arcTicksLeft <= 0,
      "damage_dealt": p.microDealt,
      "kills": p.kills,
      "speed_px_s": sim.config.maxSpeed * sim.config.roleSpeedPct(p.role) div
        100 * TargetFps div MotionScale div 100 * 100
    }

  ## Every living enemy, NEAREST TO YOU FIRST, capped at MaxEnemyViewEntries.
  var ranked: seq[tuple[dist, index: int]] = @[]
  for j in friendly ..< sim.players.len:
    if not sim.players[j].alive:
      continue
    ranked.add((distSq(px, py, sim.players[j].x + CollisionW div 2,
                       sim.players[j].y + CollisionH div 2), j))
  for a in 1 ..< ranked.len:
    let key = ranked[a]
    var b = a - 1
    while b >= 0 and (ranked[b].dist > key.dist or
        (ranked[b].dist == key.dist and ranked[b].index > key.index)):
      ranked[b + 1] = ranked[b]
      dec b
    ranked[b + 1] = key
  var enemies = newJArray()
  for entry in ranked:
    if enemies.len >= MaxEnemyViewEntries:
      break
    let
      j = entry.index
      e = sim.players[j]
      ex = e.x + CollisionW div 2
      ey = e.y + CollisionH div 2
    var attacking = newJNull()
    if e.targetSeat >= 0 and e.targetSeat < friendly:
      attacking = %sim.cogAlias(e.targetSeat)
    enemies.add(%*{
      "id": sim.config.enemyIdOf(j),
      "name": sim.cogAlias(j),
      "role": roleText(e.role),
      "pos": [ex, ey],
      "hp": max(0, e.hp),
      "hp_max": e.maxHp,
      "dist_px": intSqrt(entry.dist),
      "in_your_range": (
        seat < sim.players.len and
        entry.dist <= sim.config.roleReach(sim.players[seat].role) *
          sim.config.roleReach(sim.players[seat].role)),
      "attacking": attacking,
      "focused_by": (if j < sim.focusCount.len: sim.focusCount[j] else: 0),
      "reach_px": sim.config.roleReach(e.role),
      "speed_px_s": sim.config.maxSpeed * sim.config.roleSpeedPct(e.role) div
        100 * TargetFps div MotionScale div 100 * 100
    })

  ## The squad channel: the OTHER four seats, with LAST turn's note, say and
  ## intent. Never this turn's — all five decide at the same moment.
  var squad = newJArray()
  for i in 0 ..< min(friendly, sim.players.len):
    if i == seat:
      continue
    let m = sim.players[i]
    var
      lastIntent = newJNull()
      lastNote = newJNull()
      lastSay = newJNull()
      attacking = newJNull()
    if i < engine.haveDirective.len and engine.haveDirective[i]:
      lastNote = %engine.directives[i].note
      for order in engine.directives[i].orders:
        if order.cogIndex == i:
          lastIntent = %($order.intent)
          lastSay = %order.say
    let target = sim.microAttackTarget(i)
    if target >= 0:
      attacking = %sim.cogAlias(target)
    squad.add(%*{
      "id": sim.cogAlias(i),
      "role": roleText(m.role),
      "pos": [m.x + CollisionW div 2, m.y + CollisionH div 2],
      "alive": m.alive,
      "hp": max(0, m.hp),
      "hp_max": m.maxHp,
      "damage_dealt": m.microDealt,
      "attacking": attacking,
      "last_intent": lastIntent,
      "last_note": lastNote,
      "last_say": lastSay
    })

  let
    ourMax = max(1, sim.ourStartHp)
    theirMax = max(1, sim.enemyStartHp)
  var node = %*{
    "battle": sim.gameIndex + 1,
    "of": max(1, sim.config.maxGames),
    "scenario": sim.config.scenario,
    "turn": turnIndex,
    "turns": turnsPerBattle,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "you": you,
    "armies": {
      "ours": {
        "alive": sim.ourAlive, "hp": sim.ourHp, "hp_max": ourMax,
        "hp_pct": 100 * sim.ourHp div ourMax
      },
      "theirs": {
        "alive": sim.theirAlive, "hp": sim.theirHp, "hp_max": theirMax,
        "hp_pct": 100 * sim.theirHp div theirMax
      }
    },
    "enemies": enemies,
    "squad": squad,
    "last_turn": {
      "your_damage": (if seat < engine.lastSeatDamage.len:
                        max(0, (if seat < sim.players.len:
                                  sim.players[seat].microDealt else: 0) -
                            engine.lastSeatDamage[seat])
                      else: 0),
      "your_shots": (if seat < engine.lastSeatShots.len:
                       max(0, (if seat < sim.players.len:
                                 sim.players[seat].shotsFired else: 0) -
                           engine.lastSeatShots[seat])
                     else: 0),
      "team_damage": max(0, sim.battleDmgDealt - engine.lastTeamDamage),
      "enemy_kills": max(0, (sim.config.enemyCount() - sim.theirAlive) -
        engine.lastEnemyDead),
      "our_losses": max(0, (friendly - sim.ourAlive) - engine.lastOurDead)
    },
    "score": {
      "team_so_far": microTeamScorePermille(sim).float / 1000.0,
      "battles_won": sim.battlesWon,
      "battle_damage_pct": 100 * sim.battleDmgDealt div theirMax,
      "battle_loss_pct": 100 * sim.battleDmgTaken div ourMax,
      "win_weight": sim.config.winWeightPermille.float / 1000.0,
      "dmg_weight": sim.config.dmgWeightPermille.float / 1000.0,
      "surv_weight": sim.config.survWeightPermille.float / 1000.0
    }
  }
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    node["your_last_directive"] = %engine.directives[seat].note
  else:
    node["your_last_directive"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  battle, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "battle": battle,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, alias, role, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "role": role,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

proc stopRecord*(tick: int): string =
  ## The `stop` control record: the engine's wall-clock stop, written once into
  ## the replay chat stream and re-applied at playback by the SAME proc
  ## (`sim.applyStop`) that applied it live.
  $(%*{
    "k": "stop", "tick": tick,
    "reason": ReasonDeadline, "endRule": EndRuleWallClock
  })

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(engine.ctl, sim, kind, sim.commandedCogs(seat))

proc focusfireFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int]
): SquadDirective =
  ## The published `focusfire` directive for an arbitrary unit set — the
  ## per-turn fallback and the driver of a seat that never connected.
  scriptedDirective(engine.ctl, sim, blFocusFire, cogs)

proc repairMissingOrders*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  directive: var SquadDirective
) =
  ## Design §Reply schema, the `cogs` row: "extra entries dropped; a missing
  ## unit keeps LAST turn's directive, else `focusfire`'s". The parser fills an
  ## unnamed unit with `focus` so no unit is ever left unactuated; that default
  ## is a floor, not the rule — a commander whose reply did not name this seat
  ## meant it to carry on, not to abandon its post.
  var previous: seq[CogOrder]
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    previous = engine.directives[seat].orders
  var
    fallbackDirective: SquadDirective
    builtFallback = false
  for order in directive.orders.mitems:
    if order.fromReply:
      continue
    var repaired = false
    for old in previous:
      if old.cogIndex == order.cogIndex:
        order = old                  ## last turn's directive for this cog
        repaired = true
        break
    if repaired:
      continue
    if not builtFallback:
      fallbackDirective = engine.focusfireFor(sim, sim.commandedCogs(seat))
      builtFallback = true
    for fallback in fallbackDirective.orders:
      if fallback.cogIndex == order.cogIndex:
        order = fallback             ## else focusfire's
        break

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerBattle: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal directive.
  let
    battle = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing
  ## about turn k+1 (the sidecar's window may have rolled), so the flag is
  ## cleared here and only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch the LLM off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "smac: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens (`no_credentials`, `budget_guard`). Recording it is
      # what makes the two countable: without this an LLM seat with no key
      # reported llmTurns 0 AND fallbackTurns 0, and replay_summary.py's
      # `fallbacks` was 0 for an episode in which nothing but fallbacks
      # happened. A seat that registered as SCRIPTED is not a fallback and
      # gets no record (which is why certification's two baseline seats write
      # none).
      var directive = engine.focusfireFor(sim, sim.commandedCogs(seat))
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(battle, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing focusfire"))
      echo "smac llm: seat ", seat, " falling back to focusfire (", cause,
        ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and two seats at
  # a fast turn sit right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 24 req/min. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          battle, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = engine.seatViewJson(sim, seat, turnIndex, turnsPerBattle)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with exactly " &
          "one \"cogs\" entry — your own unit.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — and a config that is not a whole
    # number of seconds is therefore not the deadline it claims to be. 0.1.2
    # shipped `attempt1Ms: 4500` and really ran with 4 s against a sidecar
    # whose median call measured 4618 ms; every successful LLM directive in
    # that release reported a latency of 3999–4001 ms, i.e. it was the
    # deadline answering, not the model. sim_config now REJECTS a sub-second
    # value, so the floor below is an identity: 6000 -> 6 s, 3000 -> 3 s,
    # worst case 9 s inside the 10 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        let commanded = sim.commandedCogs(seat)
        var ids: seq[string]
        for cogIndex in commanded:
          ids.add(sim.cogAlias(cogIndex))
        ## The default target when the reply gives none: the enemy army's
        ## centroid, which is always somewhere worth walking.
        var
          cx = 0
          cy = 0
          n = 0
        for j in sim.config.friendlyCount() ..< sim.players.len:
          if not sim.players[j].alive:
            continue
          cx += sim.players[j].x + CollisionW div 2
          cy += sim.players[j].y + CollisionH div 2
          inc n
        if n == 0:
          cx = MapWidth div 2
          cy = MapHeight div 2
        else:
          cx = cx div n
          cy = cy div n
        var directive = parseSquadDirective(
          extractJsonObject(text), ids, commanded,
          cx, cy, MapWidth - 1, MapHeight - 1)
        directive.source = dsLlm
        directive.latencyMs = latency
        ## Design §Reply schema, the `cogs` row: a reply whose entries name no
        ## commanded cog is REPAIRED — last turn's directive, else `focusfire`'s
        ## — and stays an LLM turn carrying the model's own note. It is not a
        ## parse failure: no retry is burned, no `fallback` record is written,
        ## and the line below deliberately avoids the phrase "falling back",
        ## which phase 60 greps the game log for and which must mean a seat
        ## really did degrade to the scripted layer for a turn.
        var namedCog = false
        for order in directive.orders:
          if order.fromReply:
            namedCog = true
            break
        let hadPrevious = seat < engine.haveDirective.len and
          engine.haveDirective[seat]
        engine.repairMissingOrders(sim, seat, directive)
        engine.directives[seat] = directive
        engine.haveDirective[seat] = true
        if not namedCog:
          echo "smac llm: seat ", seat,
            " repaired: reply named no commanded cog; kept ",
            (if hadPrevious: "last turn's directive"
             else: "focusfire's directive"), " on turn ", turnIndex
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made the hosted log unreadable: 205
          ## "falling back (parse_error)" lines for an episode whose only
          ## fault was a daily-token cap.
          cause = "throttled"
        result.add(fallbackRecord(
          battle, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "smac llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land. Bounded, and recorded as
      # a `fallback` with cause `throttled` by the block below.
      echo "smac llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays focusfire for this turn --------------------
  for seat in open:
    var directive = engine.focusfireFor(sim, sim.commandedCogs(seat))
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(battle, turnIndex, seat, 2, cause,
      "seat fell back to the focusfire directive"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "smac llm: seat ", seat, " falling back to focusfire (", cause,
      ") on turn ", turnIndex
