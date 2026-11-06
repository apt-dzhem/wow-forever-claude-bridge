# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.2,<2"]
# ///
"""wow-forever MCP server: reads the ClaudeBridge addon's SavedVariables and
ForeverQuest's quest database (Questie-derived) from the local WoW install."""
import glob
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luasv  # noqa: E402
from mcp.server.fastmcp import FastMCP  # noqa: E402

WOW = os.environ.get("WOW_DIR", os.path.expanduser(
    "~/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_"))
QUEST_DB = os.path.join(WOW, "Interface/AddOns/ForeverQuest/DatabaseData.lua")

# Classic uiMapIDs used by the quest database; the addon's own map list overrides these.
MAP_NAMES = {
    1411: "Durotar", 1412: "Mulgore", 1413: "The Barrens", 1416: "Alterac Mountains", 1417: "Arathi Highlands",
    1418: "Badlands", 1419: "Blasted Lands", 1420: "Tirisfal Glades", 1421: "Silverpine Forest",
    1422: "Western Plaguelands", 1423: "Eastern Plaguelands", 1424: "Hillsbrad Foothills", 1425: "The Hinterlands",
    1426: "Dun Morogh", 1427: "Searing Gorge", 1428: "Burning Steppes", 1429: "Elwynn Forest", 1430: "Deadwind Pass",
    1431: "Duskwood", 1432: "Loch Modan", 1433: "Redridge Mountains", 1434: "Stranglethorn Vale",
    1435: "Swamp of Sorrows", 1436: "Westfall", 1437: "Wetlands", 1438: "Teldrassil", 1439: "Darkshore",
    1440: "Ashenvale", 1441: "Thousand Needles", 1442: "Stonetalon Mountains", 1443: "Desolace", 1444: "Feralas",
    1445: "Dustwallow Marsh", 1446: "Tanaris", 1447: "Azshara", 1448: "Felwood", 1449: "Un'Goro Crater",
    1450: "Moonglade", 1451: "Silithus", 1452: "Winterspring", 1453: "Stormwind City", 1454: "Orgrimmar",
    1455: "Ironforge", 1456: "Thunder Bluff", 1457: "Darnassus", 1458: "Undercity",
}

mcp = FastMCP("wow-forever")
_cache = {}


def _load(path):
    mtime = os.path.getmtime(path)
    hit = _cache.get(path)
    if hit and hit[0] == mtime:
        return hit[1]
    data = luasv.load_assignments(path)
    _cache[path] = (mtime, data)
    return data


def _sv_path():
    paths = glob.glob(os.path.join(WOW, "WTF/Account/*/SavedVariables/ClaudeBridge.lua"))
    if not paths:
        raise RuntimeError("No ClaudeBridge.lua SavedVariables yet. Log in with the addon enabled, then /reload or /cb sync.")
    return max(paths, key=os.path.getmtime)


def _bridge():
    return _load(_sv_path()).get("ClaudeBridgeDB") or {}


def _char(name=None):
    db = _bridge()
    chars = db.get("characters") or {}
    key = name or db.get("lastCharacter")
    if key not in chars:
        match = [k for k in chars if name and k.lower().startswith(name.lower())]
        if not match:
            raise RuntimeError(f"Character {key!r} not found. Known: {list(chars)}")
        key = match[0]
    return key, chars[key]


def _qdb():
    return _load(QUEST_DB)["F.locationDB"]


def _map_names():
    names = dict(MAP_NAMES)
    try:
        for k, v in (_bridge().get("mapNames") or {}).items():
            names[int(k)] = v
    except RuntimeError:
        pass
    return names


def _resolve_map(zone):
    names = _map_names()
    if isinstance(zone, int) or (isinstance(zone, str) and zone.isdigit()):
        return int(zone)
    z = zone.lower()
    for mid, n in names.items():
        if n.lower() == z:
            return mid
    for mid, n in names.items():
        if z in n.lower():
            return mid
    raise RuntimeError(f"Unknown zone {zone!r}")


def _target(key, map_id=None):
    t = _qdb()["targets"].get(key)
    if not t:
        return {"id": key}
    names = _map_names()
    locs = []
    for mid, pts in (t.get("maps") or {}).items():
        if map_id and mid != map_id:
            continue
        x, y = pts[0]
        locs.append({"zone": names.get(mid, mid), "x": round(x * 100, 1), "y": round(y * 100, 1), "spawns": len(pts)})
    kind = {"n": "npc", "o": "object", "i": "item"}.get(key[0], key[0])
    return {"name": t.get("name"), "type": kind, "locations": locs}


def _bit(mask, n):
    return mask == 0 or (n and 1 <= n <= 32 and (mask >> (n - 1)) & 1 == 1)


def _age(ts):
    s = int(time.time() - ts)
    return f"{s}s" if s < 120 else f"{s // 60}m" if s < 7200 else f"{s // 3600}h"


@mcp.tool()
def wow_status() -> dict:
    """Snapshot freshness, which characters are stored, and data sources. Call first; tell the user to /cb sync in game if stale."""
    path = _sv_path()
    db = _bridge()
    chars = {k: {"level": v.get("character", {}).get("level"), "savedAt": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(v.get("savedAt", 0))),
                 "age": _age(v.get("savedAt", 0)), "reason": v.get("reason"), "completedQuestsApi": v.get("completedQuestsApi"),
                 "talentApi": (v.get("talents") or {}).get("api")} for k, v in (db.get("characters") or {}).items()}
    return {"file": path, "fileWritten": _age(os.path.getmtime(path)) + " ago", "lastCharacter": db.get("lastCharacter"),
            "characters": chars, "questDatabase": QUEST_DB if os.path.exists(QUEST_DB) else "missing",
            "note": "Data is only as fresh as the last /reload, /cb sync or logout."}


@mcp.tool()
def wow_character(character: str | None = None) -> dict:
    """Character overview: level/XP/rested, gold, location (zone, subzone, x/y), hearth, stats, professions, buffs, party."""
    key, c = _char(character)
    ch = dict(c.get("character") or {})
    if "money" in ch:
        m = ch["money"]
        ch["gold"] = f"{m // 10000}g {m // 100 % 100}s {m % 100}c"
    if ch.get("xpMax"):
        ch["xpPercent"] = round(100 * ch["xp"] / ch["xpMax"], 1)
    return {"key": key, "savedAgo": _age(c.get("savedAt", 0)), "character": ch, "location": c.get("location"),
            "stats": c.get("stats"), "skills": c.get("skills"), "buffs": c.get("buffs"), "group": c.get("group")}


@mcp.tool()
def wow_quest_log(character: str | None = None) -> list:
    """Current quest log with objectives and progress, enriched with turn-in NPC and location from the quest database when known."""
    _, c = _char(character)
    quests = (_qdb())["quests"]
    out = []
    for q in c.get("questLog") or []:
        r = quests.get(q.get("id"))
        if r:
            q = dict(q, turnIn=[_target(k) for k in r.get("ends") or []], startedBy=[_target(k) for k in r.get("starts") or []][:1])
        out.append(q)
    return out


@mcp.tool()
def wow_completed_quests(character: str | None = None, zone: str | None = None) -> dict:
    """Completed quest IDs resolved to names/levels where the database knows them. Optional zone filters to quests started in that zone."""
    _, c = _char(character)
    quests = _qdb()["quests"]
    ids = c.get("completedQuests") or []
    zone_ids = set(_qdb()["starts"].get(_resolve_map(zone), [])) if zone else None
    seen = {int(k): v for k, v in (_bridge().get("questNames") or {}).items()}
    known, unknown = [], []
    for i in ids:
        if zone_ids is not None and i not in zone_ids:
            continue
        r = quests.get(i)
        if r:
            known.append({"id": i, "name": r["name"], "level": r["level"]})
        elif i in seen:
            known.append({"id": i, "name": seen[i], "level": None, "forever": True})
        else:
            unknown.append(i)
    return {"total": len(ids), "api": c.get("completedQuestsApi"), "shown": len(known) + len(unknown),
            "quests": sorted(known, key=lambda q: q["level"] if q["level"] is not None else 999),
            "unknownIds": unknown if zone_ids is None else [],
            "note": "Unknown IDs are mostly new Forever quests not in the Questie-derived database."}


def _eligible(qid, r, level, race, cls, done, inlog):
    taken = lambda q: q in inlog or q in done  # noqa: E731
    if r.get("blocked") or taken(qid) or level < r["min"] or (r["max"] > 0 and level > r["max"]):
        return False
    if not _bit(r["races"], race) or not _bit(r["classes"], cls):
        return False
    if any(q not in done for q in r["all"]):
        return False
    if r["any"] and not any(q in done for q in r["any"]):
        return False
    if any(q <= 0 or taken(q) for q in r["exclusive"]):
        return False
    if r["next"] > 0 and taken(r["next"]):
        return False
    if r["parent"] > 0 and r["parent"] not in inlog:
        return False
    if r["untilQuest"] > 0 and r["untilQuest"] in done:
        return False
    if r["starting"] > 0 and not taken(r["starting"]):
        return False
    if r["disabled"] > 0 and r["disabled"] in inlog:
        return False
    if r["breadcrumb"] > 0 and taken(r["breadcrumb"]):
        return False
    return True


@mcp.tool()
def wow_available_quests(zone: str | None = None, character: str | None = None, max_above: int = 3, min_below: int = 7) -> dict:
    """Quests the character can pick up now in a zone (default: current zone), with quest-giver name and x/y.
    Uses ForeverQuest's Questie-derived database: classic quests only, new Forever quests are not listed.
    max_above / min_below bound quest level relative to the character's level."""
    _, c = _char(character)
    ch = c.get("character") or {}
    level, race, cls = ch.get("level", 1), ch.get("raceID"), ch.get("classID")
    db = _qdb()
    map_id = _resolve_map(zone) if zone else (c.get("location") or {}).get("mapID")
    if map_id not in db["starts"]:
        parent = (c.get("location") or {}).get("parentMapID")
        if not zone and parent in db["starts"]:
            map_id = parent
    done = set(c.get("completedQuests") or [])
    inlog = {q["id"] for q in c.get("questLog") or []}
    out = []
    for qid in db["starts"].get(map_id, []):
        r = db["quests"].get(qid)
        if not r or not (level - min_below <= r["level"] <= level + max_above):
            continue
        if _eligible(qid, r, level, race, cls, done, inlog):
            out.append({"id": qid, "name": r["name"], "level": r["level"], "minLevel": r["min"],
                        "giver": [_target(k, map_id) for k in r.get("starts") or []][:2]})
    out.sort(key=lambda q: (q["level"], q["name"]))
    return {"zone": _map_names().get(map_id, map_id), "mapID": map_id, "characterLevel": level, "count": len(out), "quests": out}


@mcp.tool()
def wow_quest_lookup(query: str, character: str | None = None) -> list:
    """Find quests in the database by ID or name fragment: level, start/end NPCs with coordinates, objectives, and whether this character completed it."""
    db = _qdb()
    try:
        _, c = _char(character)
        done = set(c.get("completedQuests") or [])
        inlog = {q["id"] for q in c.get("questLog") or []}
    except RuntimeError:
        done, inlog = set(), set()
    if query.isdigit():
        hits = [int(query)] if int(query) in db["quests"] else []
    else:
        ql = query.lower()
        hits = [i for i, r in db["quests"].items() if ql in r["name"].lower()][:15]
    out = []
    for i in hits:
        r = db["quests"][i]
        out.append({"id": i, "name": r["name"], "level": r["level"], "minLevel": r["min"],
                    "status": "completed" if i in done else "in log" if i in inlog else "not done",
                    "start": [_target(k) for k in r["starts"]], "end": [_target(k) for k in r["ends"]],
                    "objectives": [{"text": o.get("label"), "where": _target(o["target"]) if o.get("target") else None} for o in r["objectives"]],
                    "requires": r["all"] + r["any"], "next": r["next"] or None})
    return out


@mcp.tool()
def wow_recent_turnins(limit: int = 20, character: str | None = None) -> list:
    """Most recent quest turn-ins (newest first) with time, XP and money gained. Recorded by the addon since v0.1.1."""
    db = _bridge()
    who = (character or db.get("lastCharacter") or "").split("-")[0]
    out = []
    for t in db.get("turnIns") or []:
        if who and t.get("character") and t["character"] != who:
            continue
        out.append(dict(t, when=time.strftime("%Y-%m-%d %H:%M", time.localtime(t.get("at", 0))), ago=_age(t.get("at", 0))))
        if len(out) >= limit:
            break
    return out


SECTIONS = ["talents", "equipment", "bags", "spells", "reputations", "skills", "stats", "buffs", "group", "location", "addons"]


@mcp.tool()
def wow_section(section: str, character: str | None = None):
    """Raw snapshot section. One of: talents, equipment, bags, spells, reputations, skills, stats, buffs, group, location, addons."""
    if section not in SECTIONS:
        raise RuntimeError(f"section must be one of {SECTIONS}")
    if section == "addons":
        return _bridge().get("addons")
    _, c = _char(character)
    return c.get(section)


if __name__ == "__main__":
    mcp.run()
