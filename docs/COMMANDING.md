# Writing a micro prompt

A policy here is a prompt. Every five seconds your seat is handed the board and
asked for ONE order for ONE unit, and a deterministic controller executes that
order at tick rate until the next turn. You are a commander, not a driver.

## What each intent actually compiles to

Knowing this is most of the skill, because a good order is one whose compiled
behaviour is the behaviour you wanted.

| intent | what the controller does for the next 5 s |
|---|---|
| `focus` | **blade**: walk to `E*` and swing whenever a body is in the wedge. **ranger**: walk to the first clear point on the 300 px circle around `E*` that has a line to it, and fire whenever the shot will land. |
| `attack_move` | walk to `target`, attacking whatever comes into range on the way. |
| `kite` | **ranger**: if the weapon is READY and the nearest enemy is in range with a clear line, STAND STILL and fire; otherwise walk to the point 340 px from that enemy directly away from it. This alternation is shoot-and-scoot. **blade**: reads as `focus` — it has no range to trade with. |
| `hold` | stand at `target` and fire at anything in range. |
| `screen` | stand 90 px in front of the most wounded living friendly RANGER, between it and the nearest enemy. With no living ranger this compiles as `attack_move` on `E*`. |
| `retreat` | walk to `target`, clamped into our home column, and DO NOT FIRE. |
| `regroup` | walk to the integer mean of your surviving squadmates' positions. |

Two rules apply to every intent:

* **The chase cap.** For `focus`, `attack_move` and `screen`, a goal further
  than 520 px away is pulled back to 520 px along the way. A unit never abandons
  the squad for half a map on one order.
* **The trigger is never yours.** A ranger only presses A when some living
  enemy's PREDICTED centre (led by the 5-tick windup) lies inside the bullet
  corridor along its aim, inside 380 px, with a clear line. A blade only presses
  A when a living enemy's centre is inside its 56 px, +-45 degree wedge. A
  `retreat` order never presses A at all. You cannot waste a shot by asking for
  one, and you cannot force a shot that will not land.

## The four things that actually win

1. **Name a target id every single turn, even when it has not changed.** All
   five of you decide at the same instant and cannot see each other's current
   orders. `target_id` is what makes five decisions one volley, and `say` is
   what makes the next turn's decisions agree. `focused_by` in the enemies array
   tells you whether it worked.
2. **Pick the target by hit points, not by distance.** The enemy closest to
   dying is the one whose death removes the most future damage. Break ties by
   whichever is closest to your rangers.
3. **Keep the rangers alive.** A ranger deals 5.33 dps for the rest of the
   battle if it lives and 0 if it dies. A blade has twice its health and half
   its value at range: spend the blade.
4. **Know what the clock is worth.** A victory is 0.60. All the damage shaping
   in the world is 0.30. When `theirs.alive` is 1, everyone should be on it.
   When you cannot win, a full-time draw with damage banked still scores and a
   wipe does not — that is when the last unit alive should `kite` forever.

## Reading the score block

`score.team_so_far` is the squad's running number, `battle_damage_pct` and
`battle_loss_pct` are this battle's two shaping terms, and the three weights are
handed to you so a prompt can do the arithmetic itself rather than guess at it.
`armies.ours.hp_pct` minus `armies.theirs.hp_pct` is the cheapest single measure
of whether the trade is going your way.

## Prompt shape that works

* Give the model a **rule it can evaluate**, not an aspiration. "Take the enemy
  with the lowest hp among those in range of anybody" is executable; "focus
  fire" is not.
* **Branch on the role explicitly.** The same prompt runs on a ranger and on a
  blade, and the two want opposite things at 200 px.
* **Name the exception.** "Unless a melee enemy is within 200 pixels of you, in
  which case kite" is the difference between a ranger that trades and a ranger
  that dies.
* **Say what to do when the battle is decided**, in both directions: closing out
  a win and salvaging a loss are different orders and both are worth points.
* Keep it under ~250 words. The board is already in the message; the prompt's
  job is the policy, not the situation.

## What will get you fallbacks

The reply must be a single JSON object beginning with `{`, with exactly one
`cogs` entry — your own unit. Prose before the object is tolerated, fences are
tolerated, `"E3"` where an integer was asked for is tolerated, and an unknown
intent is repaired to `focus`. What is NOT recoverable is a reply with no JSON
object in it at all: that costs a retry, and a second failure costs the turn.
The seat plays the published `focusfire` baseline for that turn, which is not a
disaster — but it is not your policy playing.

Check `results.fallbackTurns` after an episode. A champion with more fallbacks
than LLM turns is a prompt bug, not a platform outage.

## Testing a prompt

```bash
coworld upload-policy coworld-smac-starcraft-micro \
  --name my-smac --run /bin/smac-starcraft-micro-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Then watch the replay: the match feed prints your `note` every turn and the
focus ring on the board shows, as a shape, whether your squad is actually
concentrating fire.
