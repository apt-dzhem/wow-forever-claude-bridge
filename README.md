# wow-forever-claude-bridge

Let Claude (or any MCP client) read your **World of Warcraft: Forever** character: quest log, completed quests, turn-in history, location, talents, gear, bags, spells, professions, reputations and installed addons.

Two parts:

| Part | What it does |
|------|--------------|
| `ClaudeBridge/` | In-game addon (Interface 16001). Snapshots your character into `ClaudeBridgeDB` every 30 s and on relevant events, and logs each quest turn-in with time, XP and money. |
| `wow-mcp/` | Local MCP server (Python, stdio). Reads the addon's SavedVariables and, if installed, the [ForeverQuest](https://www.curseforge.com/wow/addons/foreverquest) quest database to name quests and find quest givers. |

## How it works

WoW addons cannot open files or sockets. They can only write SavedVariables, and the game flushes those to disk on `/reload`, logout or exit. So the data on disk is as fresh as your last save:

- `/cb` prints a status line in chat.
- `/cb sync` takes a snapshot and reloads the UI, so the file on disk is current.

## Install

### Addon

Copy `ClaudeBridge/` into `World of Warcraft/_forever_/Interface/AddOns/`, then **fully restart the game**. A `/reload` does not pick up new addon folders.

### MCP server

Needs [uv](https://docs.astral.sh/uv/). Dependencies are declared inline in `server.py`.

```sh
claude mcp add wow-forever -s user -- uv run --quiet --script /path/to/wow-mcp/server.py
```

The server looks for the game at `~/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_` (a Lutris/Wine Battle.net prefix). Set `WOW_DIR` to point elsewhere:

```sh
claude mcp add wow-forever -s user -e WOW_DIR="/path/to/_forever_" -- uv run --quiet --script /path/to/wow-mcp/server.py
```

## Tools

| Tool | Returns |
|------|---------|
| `wow_status` | Snapshot age, stored characters, which game APIs answered |
| `wow_character` | Level, XP, rested XP, gold, location, hearth, stats, buffs, group |
| `wow_quest_log` | Quest log with objectives, plus turn-in NPC and coordinates when known |
| `wow_completed_quests` | Completed quest IDs resolved to names, optional zone filter |
| `wow_recent_turnins` | Turn-in history, newest first |
| `wow_available_quests` | Quests you can pick up in a zone, with giver name and x/y |
| `wow_quest_lookup` | Search the quest database by ID or name |
| `wow_section` | Raw section: talents, equipment, bags, spells, reputations, skills, stats, buffs, group, location, addons |

## Limits

- The quest database is ForeverQuest's Questie-derived data, so it only covers Classic quests. New Forever quests get names once they have passed through your quest log.
- Completion order is not available from the game; only turn-ins recorded by the addon have timestamps.
- Your SavedVariables contain your character and guild names. They stay on your machine; this repo contains no game data.
