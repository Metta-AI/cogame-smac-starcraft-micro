## Shared fixtures for the smac-starcraft-micro suite.
##
## Every test builds its sim through `newMicroSim`, so ONE place owns the
## "what a micro config looks like" knowledge and a config field that grows a
## validation rule breaks one line rather than fourteen files.
##
## Tests run from the repo root, but sim construction lazily loads `data/`
## relative to the cwd, so the builders here pin the cwd for the duration of
## the call.

import
  std/[json, os, strutils],
  bitworld/spriteprotocol,
  smac/[sim, control, directives, baselines, llm, decide, broadcast]

export sim, control, directives, baselines, llm, decide, broadcast,
  spriteprotocol, json, strutils

const GameDir* = currentSourcePath.parentDir.parentDir

proc microConfigJson*(
  maxTicks = 480,
  maxGames = 1,
  scenario = "default",
  roles: seq[string] = @["ranger", "ranger", "blade", "blade", "blade"],
  enemyRoles: seq[string] = @["ranger", "ranger", "blade", "blade", "blade"],
  seed = 679961,
  friendlySpawnX = 470,
  enemySpawnX = 760
): string =
  ## The config every fixture starts from: five seats, one unit each, the micro
  ## loadout, on the hand-tuned arena, with the LLM rate floor off.
  var
    roleArray = newJArray()
    enemyArray = newJArray()
    tokens = newJArray()
    players = newJArray()
    slots = newJArray()
  for role in roles:
    roleArray.add(%role)
  for role in enemyRoles:
    enemyArray.add(%role)
  for i in 0 ..< roles.len:
    tokens.add(%("t" & $i))
    players.add(%*{"name": "unit" & $i})
    slots.add(%*{"team": "red"})
  $(%*{
    "seed": seed,
    "loadout": "micro",
    "scenario": scenario,
    "num_agents": roles.len,
    "minPlayers": roles.len,
    "roles": roleArray,
    "enemyRoles": enemyArray,
    "maxTicks": maxTicks,
    "maxGames": maxGames,
    "mapPath": "arena",
    "fogOfWar": false,
    "turnTicks": 120,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 4,
    "lobbyJoinTimeoutTicks": 0,
    "friendlySpawnX": friendlySpawnX,
    "enemySpawnX": enemySpawnX,
    "fastMode": true,
    "showPlayerLabels": false,
    "tokens": tokens,
    "players": players,
    "slots": slots
  })

proc microConfig*(json: string): GameConfig =
  result = defaultGameConfig()
  result.update(json)

proc initForTest*(config: GameConfig): SimServer =
  let previous = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previous)

proc newMicroSim*(configJson = microConfigJson()): SimServer =
  ## A STARTED micro battle: five seats seated, the enemy army built, both
  ## lines spawned.
  let config = microConfig(configJson)
  result = initForTest(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< config.numAgents:
    let name =
      if seat < config.slots.len and config.slots[seat].name.len > 0:
        config.slots[seat].name
      else:
        "policy" & $seat
    discard result.addPlayer(name, seat, "t" & $seat)
    result.seatNames[seat] = name
  for order in config.numAgents ..< config.microUnitCount():
    discard result.addPlayer(result.aliasOfCog(order), order, "", trusted = true)
  result.startGame()

proc idle*(sim: SimServer): seq[InputState] =
  ## An all-idle input frame sized to the roster.
  newSeq[InputState](sim.players.len)

proc stepIdle*(sim: var SimServer, ticks: int) =
  var prev = sim.idle()
  for _ in 0 ..< ticks:
    let now = sim.idle()
    sim.step(now, prev)
    prev = now

proc enemyIndex*(sim: SimServer, enemyId: int): int =
  sim.config.cogOfEnemyId(enemyId)

proc killUnit*(sim: var SimServer, index: int) =
  ## Removes one unit from play through the sim's own damage path, so every
  ## ledger and counter moves exactly as it would in a real battle. The killer
  ## is always a unit of the OTHER side, so the damage ledgers the sim guard
  ## checks stay exactly consistent.
  let killer =
    if index < sim.config.friendlyCount(): sim.config.friendlyCount()
    else: 0
  while sim.players[index].alive and sim.players[index].hp > 0:
    discard sim.absorbDamage(index, sim.players[index].hp, killer, "gun")
    if sim.players[index].hp <= 0:
      sim.killPlayer(index, killer)
  sim.updateArmiesNow()
