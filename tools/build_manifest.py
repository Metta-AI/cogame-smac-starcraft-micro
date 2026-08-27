#!/usr/bin/env python3
"""Regenerates coworld_manifest_template.json from this repo's docs.

The manifest's `game.docs` and `game.protocols` are TEXT (never URIs), so the
README and the four doc pages are inlined here rather than hand-copied — the
one place they can drift.  Run it after editing docs/ or README.md:

    python3 tools/build_manifest.py

`tests/test_manifest.nim` asserts every invariant this file encodes.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SLUG = "smac-starcraft-micro"
IMAGE = "{{SMAC_STARCRAFT_MICRO_IMAGE}}"
SOURCE = "https://github.com/Metta-AI/cogame-smac-starcraft-micro/tree/main"


def text(path):
    body = (ROOT / path).read_text(encoding="utf-8")
    assert body.strip(), f"{path} is empty"
    return {"type": "text", "value": body}


ROLES = ["ranger", "ranger", "blade", "blade", "blade"]
PLAYERS = [{"name": n} for n in ("Unit A", "Unit B", "Unit C", "Unit D", "Unit E")]
SLOTS = [{"team": "red"} for _ in range(5)]

# Every tuning knob, at its published default.  A variant that omits one plays
# the rules docs/RULES.md documents.
TUNING = {
    "maxTicks": 1440,
    "maxGames": 3,
    "turnTicks": 120,
    "turnBudgetMs": 10000,
    "attempt1Ms": 6000,
    "retryMs": 3000,
    "turnSpacingMs": 12000,
    "wallClockBudgetSeconds": 690,
    "lobbyJoinTimeoutTicks": 2400,
    "startWaitTicks": 120,
    "gameOverTicks": 72,
    "friendlySpawnX": 380,
    "enemySpawnX": 855,
    "spawnSpacingPx": 44,
    "spawnJitterPx": 24,
    "rangerHp": 60,
    "rangerRange": 380,
    "rangerDamage": 4,
    "rangerCooldown": 18,
    "bladeHp": 120,
    "bladeSpeedPct": 115,
    "bladeReach": 56,
    "bladeArcBrads": 32,
    "bladeDamage": 10,
    "bladeCooldown": 30,
    "swingTicks": 4,
    "swarmHp": 30,
    "swarmSpeedPct": 130,
    "swarmReach": 40,
    "swarmDamage": 6,
    "swarmCooldown": 24,
    "aggroPx": 600,
    "leashPx": 700,
    "retargetTicks": 48,
    "enemyStuckTicks": 24,
    "rangerStandoff": 300,
    "kiteStandoff": 340,
    "screenStandoff": 90,
    "chaseCapPx": 520,
    "panicPx": 150,
    "winWeightPermille": 600,
    "dmgWeightPermille": 300,
    "survWeightPermille": 100,
    "creditEpsilonPerMyriad": 4,
    "maxOutputTokens": 900,
}

SCALARS = {
    "seed": {"type": "integer", "default": 679961},
    "num_agents": {"type": "integer", "minimum": 5, "maximum": 5, "default": 5},
    "minPlayers": {"type": "integer", "minimum": 5, "maximum": 5, "default": 5},
    "scenario": {"type": "string", "default": "default"},
    "loadout": {"type": "string", "default": "micro"},
    "mapPath": {"type": "string", "default": "plains"},
    "fogOfWar": {"type": "boolean", "default": False},
    "fastMode": {"type": "boolean", "default": True},
    "showPlayerLabels": {"type": "boolean", "default": False},
    "model": {"type": "string", "default": ""},
}
for key, value in TUNING.items():
    SCALARS[key] = {"type": "integer", "minimum": 0, "default": value}

CONFIG_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        # The runner INJECTS tokens; no game_config below may carry a literal
        # array (cogame-knights-archers 0.1.0), but the schema still requires
        # them, and tests/test_manifest.nim asserts both halves.
        "tokens": {
            "type": "array", "minItems": 5, "maxItems": 5,
            "items": {"type": "string"},
        },
        "players": {
            "type": "array", "minItems": 5, "maxItems": 5,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"name": {"type": "string"}},
            },
        },
        "slots": {
            "type": "array", "minItems": 5, "maxItems": 5,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {"team": {"type": "string", "enum": ["red", "blue"]}},
            },
        },
        "roles": {
            "type": "array", "minItems": 5, "maxItems": 5,
            "items": {"type": "string", "enum": ["ranger", "blade"]},
        },
        "enemyRoles": {
            "type": "array", "minItems": 1, "maxItems": 24,
            "items": {"type": "string", "enum": ["ranger", "blade", "swarm"]},
        },
        **SCALARS,
    },
}

SEAT_ARRAYS = {
    "names": "string", "scores": "number", "win": "boolean", "role": "string",
    "alias": "string", "damageDealt": "integer", "damageTaken": "integer",
    "kills": "integer", "deaths": "integer", "shots": "integer",
    "llmTurns": "integer", "fallbackTurns": "integer",
}
BATTLE_ARRAYS = {
    "battleResults": "string", "battleTicks": "integer",
    "battleDamagePct": "integer", "battleLossPct": "integer",
}

RESULTS_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["names", "scores", "win", "role", "reason", "endRule"],
    "properties": {
        **{
            k: {"type": "array", "minItems": 5, "maxItems": 5,
                "items": {"type": v}}
            for k, v in SEAT_ARRAYS.items()
        },
        **{
            k: {"type": "array", "minItems": 1, "maxItems": 6,
                "items": {"type": v}}
            for k, v in BATTLE_ARRAYS.items()
        },
        "teamScore": {"type": "number"},
        "battlesWon": {"type": "integer"},
        "enemyKilled": {"type": "integer"},
        "enemyTotal": {"type": "integer"},
        "scenario": {"type": "string"},
        "reason": {"type": "string", "enum": ["complete", "deadline", "fault"]},
        "endRule": {
            "type": "string",
            "enum": ["victory", "wipe", "full_time", "wall_clock",
                     "sim_fault", "host_error"],
        },
        "games": {"type": "integer"},
        "finalTick": {"type": "integer"},
        "seed": {"type": "integer"},
    },
}


def game_config(scenario, roles, enemy_roles, map_path):
    config = {
        "players": PLAYERS,
        "slots": SLOTS,
        "num_agents": 5,
        "minPlayers": 5,
        "loadout": "micro",
        "scenario": scenario,
        "roles": roles,
        "enemyRoles": enemy_roles,
        "seed": 679961,
        "mapPath": map_path,
        "fogOfWar": False,
        "fastMode": True,
        "showPlayerLabels": False,
    }
    config.update(TUNING)
    return config


VARIANTS = [
    ("default", "Micro — two and three",
     "Two rangers and three blades against a mirror army of the same five "
     "units, 480 hit points a side. The league default: the SMAC 2s3z shape, "
     "where focus fire, kiting and body-blocking are all live decisions at "
     "once. Fought on the open plains: 475 px of flat deck and nothing to hide "
     "behind. Three 60-second battles; the squad's score is one number and "
     "every seat gets it.",
     ROLES, ROLES, "plains"),
    ("outnumbered", "Micro — five against six",
     "Five rangers against six. Nobody can body-block, so the only way to win "
     "the trade is to kill faster than you are killed: one target at a time, "
     "and back off while the weapon cools. Fought on the open plains. Adapted "
     "from the SMAC 5m_vs_6m shape.",
     ["ranger"] * 5, ["ranger"] * 6, "plains"),
    ("corridor", "Micro — the corridor",
     "Five blades against twenty fast, fragile swarm units. Twenty-five bodies "
     "on the board, and the field pinches to one 104 px doorway: the squad has "
     "to hold the corridor rather than chase, because a blade that steps "
     "through is surrounded. Adapted from the SMAC corridor shape.",
     ["blade"] * 5, ["swarm"] * 20, "corridor"),
    ("heavy", "Micro — outgunned",
     "The default squad against seven: three enemy rangers and four enemy "
     "blades, 660 hit points against our 480. A victory here needs perfect "
     "focus fire; a full-time draw with damage banked is a real result. Fought "
     "on the open plains. Adapted from the SMAC 3s5z_vs_3s6z shape.",
     ROLES, ["ranger"] * 3 + ["blade"] * 4, "plains"),
]

CERT_CONFIG = {
    "players": PLAYERS,
    "slots": SLOTS,
    "roles": ROLES,
    "enemyRoles": ROLES,
    "num_agents": 5,
    "minPlayers": 5,
    "loadout": "micro",
    "scenario": "default",
    "seed": 679961,
    "mapPath": "plains",
    "fogOfWar": False,
    "maxTicks": 480,
    "maxGames": 3,
    "turnTicks": 120,
    "turnBudgetMs": 10000,
    "turnSpacingMs": 0,
    "wallClockBudgetSeconds": 180,
    "lobbyJoinTimeoutTicks": 1440,
    "startWaitTicks": 0,
    "gameOverTicks": 24,
    "friendlySpawnX": 470,
    "enemySpawnX": 760,
    "fastMode": True,
    "showPlayerLabels": False,
}

manifest = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/metta/main/packages/"
               "coworld/src/coworld/coworld_manifest_schema.json",
    "tags": ["micro", "cooperative", "smac", "rts", "combat", "llm", "starcraft"],
    "episode_timeout_minutes": 20,
    "game": {
        "name": SLUG,
        "owner": "daveey",
        "description":
            "Five cogs, one unit each, fight a scripted enemy army three times "
            "on a fixed arena. The whole squad shares ONE score: how much of "
            "the army you destroy, whether you wipe it out, and how much of "
            "your own health survives. Focus fire is the whole game.",
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/smac-starcraft-micro"],
            "env": {
                # Without this the hosted game container never sees the coworld
                # secret and every league episode silently plays scripted
                # (the hive scar, 2026-08-23). The namespace must equal
                # game.name EXACTLY (cooperative-hunting, 2026-08-25).
                "ANTHROPIC_API_KEY_URI":
                    "secret://coworld/smac-starcraft-micro/anthropic_api_key",
            },
            "source_url": SOURCE,
        },
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "protocols": {
            "player": text("docs/PROTOCOL.md"),
            "global": text("docs/PROTOCOL.md"),
        },
        "docs": {
            "readme": text("README.md"),
            "pages": [
                {"id": "rules", "title": "Rules", "content": text("docs/RULES.md")},
                {"id": "scenarios",
                 "title": "Scenarios and their SMAC lineage",
                 "content": text("docs/SCENARIOS.md")},
                {"id": "protocol", "title": "Wire protocol",
                 "content": text("docs/PROTOCOL.md")},
                {"id": "commanding", "title": "Writing a micro prompt",
                 "content": text("docs/COMMANDING.md")},
            ],
        },
    },
    "player": [{
        "id": "baseline",
        "type": "player",
        "name": "Focus Fire Baseline",
        "description":
            "Scripted unit: the whole squad derives one kill order from state, "
            "rangers kite when a melee enemy closes, blades screen the rangers.",
        "image": IMAGE,
        "run": ["/bin/smac-starcraft-micro-player"],
        "env": {"PLAYER_SCRIPTED": "focusfire"},
        "source_url": SOURCE,
        # The bundled player CPU limit minimum is "1" (pistonball 0.1.1).
        "resources": {
            "requests": {"cpu": "100m", "memory": "64Mi"},
            "limits": {"cpu": "1"},
        },
    }],
    "variants": [
        {
            "id": vid,
            "name": name,
            "description": description,
            "game_config": game_config(vid, roles, enemy_roles, map_path),
        }
        for vid, name, description, roles, enemy_roles, map_path in VARIANTS
    ],
    "certification": {
        "players": [{"player_id": "baseline"} for _ in range(5)],
        "game_config": CERT_CONFIG,
    },
}

out = ROOT / "coworld_manifest_template.json"
out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"wrote {out} ({out.stat().st_size} bytes)")
