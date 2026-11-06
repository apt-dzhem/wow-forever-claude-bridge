-- ClaudeBridge: writes a snapshot of the current character into ClaudeBridgeDB.
-- WoW only flushes SavedVariables to disk on /reload, logout or exit, so
-- "/cb sync" (a ReloadUI) is how the file on disk gets refreshed.
local ADDON = ...
local VERSION = "0.1.1"

local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g, h, i, j, k, l, m, n end
    return nil
end

local function round(v, places)
    if type(v) ~= "number" then return v end
    local m = 10 ^ (places or 4)
    return math.floor(v * m + 0.5) / m
end

local snap = {}

function snap.character()
    local name, realm = UnitFullName("player")
    local raceName, raceFile, raceID = UnitRace("player")
    local className, classFile, classID = UnitClass("player")
    local restXP = GetXPExhaustion and GetXPExhaustion() or 0
    return {
        name = name, realm = realm or GetRealmName(),
        race = raceName, raceFile = raceFile, raceID = raceID,
        class = className, classFile = classFile, classID = classID,
        sex = UnitSex("player"), faction = UnitFactionGroup("player"),
        level = UnitLevel("player"),
        xp = UnitXP("player"), xpMax = UnitXPMax("player"), restedXP = restXP or 0,
        isResting = IsResting(),
        money = GetMoney(),
        health = UnitHealthMax("player"), power = UnitPowerMax("player"),
        guild = try(GetGuildInfo, "player"),
        hearth = try(GetBindLocation),
    }
end

function snap.location()
    local loc = {
        zone = GetRealZoneText(), subzone = GetSubZoneText(), minimapZone = GetMinimapZoneText(),
    }
    local mapID = try(C_Map.GetBestMapForUnit, "player")
    loc.mapID = mapID
    if mapID then
        local info = try(C_Map.GetMapInfo, mapID)
        loc.mapName = info and info.name
        loc.parentMapID = info and info.parentMapID
        local pos = try(C_Map.GetPlayerMapPosition, mapID, "player")
        if pos then
            local x, y = pos:GetXY()
            loc.x, loc.y = round(x * 100, 2), round(y * 100, 2)
        end
    end
    local inInstance, instanceType = IsInInstance()
    loc.inInstance, loc.instanceType = inInstance, instanceType
    if inInstance then loc.instanceName = try(GetInstanceInfo) end
    return loc
end

function snap.questLog()
    local out = {}
    local Q = C_QuestLog
    if not (Q and Q.GetNumQuestLogEntries) then return out end
    local n = Q.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = try(Q.GetInfo, i)
        if info and not info.isHeader and info.questID and info.questID > 0 then
            local q = {
                id = info.questID, title = info.title, level = info.level,
                suggestedGroup = info.suggestedGroup, frequency = info.frequency,
                complete = try(Q.IsComplete, info.questID) or false,
                failed = try(Q.IsFailed, info.questID) or false,
                objectives = {},
            }
            for _, o in ipairs(try(Q.GetQuestObjectives, info.questID) or {}) do
                q.objectives[#q.objectives + 1] = {
                    text = o.text, type = o.type, done = o.finished,
                    have = o.numFulfilled, need = o.numRequired,
                }
            end
            out[#out + 1] = q
            ClaudeBridgeDB.questNames = ClaudeBridgeDB.questNames or {}
            ClaudeBridgeDB.questNames[info.questID] = info.title
        end
    end
    return out
end

function snap.completedQuests()
    local ids = try(C_QuestLog.GetAllCompletedQuestIDs)
    if type(ids) == "table" and #ids > 0 then
        table.sort(ids)
        return ids, "C_QuestLog.GetAllCompletedQuestIDs"
    end
    local map = try(GetQuestsCompleted)
    if type(map) == "table" then
        local list = {}
        for id, done in pairs(map) do if done then list[#list + 1] = id end end
        table.sort(list)
        return list, "GetQuestsCompleted"
    end
    return {}, "none"
end

-- Forever's talent API is not documented; try the modern trait API, then the
-- classic tab API, and record which one answered.
function snap.talents()
    local t = { api = "none", unspent = nil, trees = {} }
    t.unspent = try(UnitCharacterPoints, "player") or try(GetUnspentTalentPoints)

    local configID = try(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
    if configID and C_Traits and C_Traits.GetConfigInfo then
        local config = try(C_Traits.GetConfigInfo, configID)
        local picked = {}
        for _, treeID in ipairs(config and config.treeIDs or {}) do
            for _, nodeID in ipairs(try(C_Traits.GetTreeNodes, treeID) or {}) do
                local node = try(C_Traits.GetNodeInfo, configID, nodeID)
                if node and (node.currentRank or 0) > 0 then
                    local entryID = node.activeEntry and node.activeEntry.entryID or (node.entryIDs and node.entryIDs[1])
                    local entry = entryID and try(C_Traits.GetEntryInfo, configID, entryID)
                    local def = entry and entry.definitionID and try(C_Traits.GetDefinitionInfo, entry.definitionID)
                    local spellID = def and def.spellID
                    picked[#picked + 1] = {
                        nodeID = nodeID, rank = node.currentRank, maxRank = node.maxRanks,
                        spellID = spellID,
                        name = (def and def.overrideName) or (spellID and try(C_Spell.GetSpellName, spellID)),
                    }
                end
            end
        end
        if #picked > 0 then
            t.api = "C_Traits"
            t.trees = { { name = "active config", talents = picked } }
            return t
        end
    end

    local tabs = try(GetNumTalentTabs)
    if tabs and tabs > 0 then
        t.api = "GetTalentInfo"
        for tab = 1, tabs do
            local a, b, c, d = try(GetTalentTabInfo, tab)
            -- classic returns (name, icon, pointsSpent, fileName); newer returns (id, name, desc, icon, pointsSpent, ...)
            local tree = { name = type(a) == "string" and a or b, talents = {} }
            for i = 1, (try(GetNumTalents, tab) or 0) do
                local name, _, tier, column, rank, maxRank = try(GetTalentInfo, tab, i)
                if type(name) == "table" then -- table-returning variant
                    local info = name
                    name, tier, column, rank, maxRank = info.name, info.tier, info.column, info.rank, info.maxRank
                end
                if name then
                    tree.talents[#tree.talents + 1] = { name = name, tier = tier, column = column, rank = rank, maxRank = maxRank }
                end
            end
            t.trees[#t.trees + 1] = tree
        end
    end
    return t
end

local SLOTS = { "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
    "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
    "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot" }

function snap.equipment()
    local out = {}
    for _, slot in ipairs(SLOTS) do
        local id = GetInventorySlotInfo(slot)
        local itemID = GetInventoryItemID("player", id)
        if itemID then
            local link = GetInventoryItemLink("player", id)
            local name, _, quality, ilvl, reqLevel, _, subType = try(C_Item.GetItemInfo, itemID)
            local cur, max = GetInventoryItemDurability(id)
            out[slot] = { itemID = itemID, name = name or (link and link:match("%[(.-)%]")), quality = quality,
                itemLevel = ilvl, reqLevel = reqLevel, subType = subType,
                durability = cur and max and max > 0 and math.floor(cur / max * 100) or nil }
        end
    end
    return out
end

function snap.bags()
    local out, free = {}, 0
    local C = C_Container
    if not C then return out end
    for bag = 0, 4 do
        free = free + (try(C.GetContainerNumFreeSlots, bag) or 0)
        for slot = 1, (try(C.GetContainerNumSlots, bag) or 0) do
            local info = try(C.GetContainerItemInfo, bag, slot)
            if info and info.itemID then
                local key = info.itemID
                local e = out[key] or { itemID = info.itemID, name = info.itemName or (info.hyperlink and info.hyperlink:match("%[(.-)%]")), quality = info.quality, count = 0 }
                e.count = e.count + (info.stackCount or 1)
                out[key] = e
            end
        end
    end
    local list = {}
    for _, e in pairs(out) do list[#list + 1] = e end
    table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    return { freeSlots = free, items = list }
end

function snap.skills()
    local out = {}
    for i = 1, (try(GetNumSkillLines) or 0) do
        local name, isHeader, _, rank, _, _, maxRank = try(GetSkillLineInfo, i)
        if name and not isHeader then out[#out + 1] = { name = name, rank = rank, max = maxRank } end
    end
    return out
end

function snap.reputations()
    local out = {}
    for i = 1, (try(GetNumFactions) or 0) do
        local name, _, standingID, barMin, barMax, barValue, _, _, isHeader = try(GetFactionInfo, i)
        if name and not isHeader then
            out[#out + 1] = { name = name, standing = _G["FACTION_STANDING_LABEL" .. (standingID or 4)], value = barValue and barMin and (barValue - barMin), max = barMax and barMin and (barMax - barMin) }
        end
    end
    return out
end

function snap.spells()
    local out = {}
    local SB = C_SpellBook
    if SB and SB.GetNumSpellBookSkillLines then
        for line = 1, SB.GetNumSpellBookSkillLines() do
            local li = try(SB.GetSpellBookSkillLineInfo, line)
            if li then
                for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                    local it = try(SB.GetSpellBookItemInfo, i, Enum.SpellBookSpellBank.Player)
                    if it and it.name and not it.isPassive then
                        out[#out + 1] = { tab = li.name, name = it.name, subName = it.subName, spellID = it.spellID or it.actionID }
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local tabName, _, offset, num = GetSpellTabInfo(tab)
            for i = offset + 1, offset + num do
                local name, rank = GetSpellBookItemName(i, BOOKTYPE_SPELL)
                if name then out[#out + 1] = { tab = tabName, name = name, subName = rank } end
            end
        end
    end
    return out
end

function snap.stats()
    local s = {}
    for i, key in ipairs({ "str", "agi", "sta", "int", "spi" }) do s[key] = select(2, UnitStat("player", i)) end
    s.armor = select(2, UnitArmor("player"))
    s.meleeCrit = try(GetCritChance)
    s.spellCrit = try(GetSpellCritChance, 2)
    s.dodge, s.parry, s.block = try(GetDodgeChance), try(GetParryChance), try(GetBlockChance)
    s.attackPower = (function() local b, p, n = UnitAttackPower("player"); return b and (b + p + n) end)()
    s.spellPower = try(GetSpellBonusDamage, 2)
    s.healing = try(GetSpellBonusHealing)
    s.speed = round(try(GetUnitSpeed, "player"), 2)
    return s
end

function snap.buffs()
    local out = {}
    for i = 1, 40 do
        local a = try(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not a then break end
        out[#out + 1] = { name = a.name, spellID = a.spellId, remaining = a.expirationTime and a.expirationTime > 0 and math.floor(a.expirationTime - GetTime()) or nil }
    end
    return out
end

function snap.group()
    local out = {}
    local n = GetNumGroupMembers() or 0
    if n == 0 then return out end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, (IsInRaid() and n or n - 1) do
        local u = prefix .. i
        if UnitExists(u) then
            local _, cls = UnitClass(u)
            out[#out + 1] = { name = GetUnitName(u, true), level = UnitLevel(u), class = cls, online = UnitIsConnected(u) }
        end
    end
    return out
end

function snap.addons()
    local A = C_AddOns or {}
    local out = {}
    local num = (A.GetNumAddOns or GetNumAddOns)()
    for i = 1, num do
        local name, title, _, loadable, reason = (A.GetAddOnInfo or GetAddOnInfo)(i)
        local loaded = (A.IsAddOnLoaded or IsAddOnLoaded)(i)
        out[#out + 1] = { name = name, title = title and title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""),
            loaded = loaded and true or false, loadable = loadable and true or false, reason = reason,
            version = try(A.GetAddOnMetadata or GetAddOnMetadata, i, "Version") }
    end
    return out
end

-- Zone names for the uiMapIDs the server-side quest database uses.
function snap.mapNames()
    local out = {}
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    for _, root in ipairs({ 1414, 1415 }) do -- Kalimdor, Eastern Kingdoms
        for _, m in ipairs(try(C_Map.GetMapChildrenInfo, root, zoneType, true) or {}) do
            out[m.mapID] = m.name
        end
    end
    return out
end

local function takeSnapshot(reason)
    ClaudeBridgeDB = ClaudeBridgeDB or {}
    ClaudeBridgeDB.characters = ClaudeBridgeDB.characters or {}
    local c = snap.character()
    local key = (c.name or "?") .. "-" .. (c.realm or "?")
    -- During logout and loading screens unit data reads as zero; keep the last good snapshot.
    if (c.xpMax or 0) == 0 and (c.health or 0) == 0 then
        return ClaudeBridgeDB.characters[key]
    end
    local previous = ClaudeBridgeDB.characters[key]
    local data = { addonVersion = VERSION, savedAt = time(), reason = reason, gameVersion = (GetBuildInfo()) }
    for _, part in ipairs({ "character", "location", "questLog", "talents", "equipment", "bags", "skills",
        "reputations", "spells", "stats", "buffs", "group" }) do
        local ok, v = pcall(snap[part])
        data[part] = ok and v or { error = tostring(v) }
    end
    local ok, ids, api = pcall(snap.completedQuests)
    data.completedQuests = ok and ids or {}
    data.completedQuestsApi = ok and api or ("error: " .. tostring(ids))
    if #data.completedQuests == 0 and previous and previous.completedQuests and #previous.completedQuests > 0 then
        data.completedQuests, data.completedQuestsApi = previous.completedQuests, previous.completedQuestsApi .. " (kept)"
    end
    ClaudeBridgeDB.characters[key] = data
    ClaudeBridgeDB.lastCharacter = key
    local okA, addons = pcall(snap.addons)
    ClaudeBridgeDB.addons = okA and addons or { error = tostring(addons) }
    local okM, maps = pcall(snap.mapNames)
    if okM and next(maps) then ClaudeBridgeDB.mapNames = maps end
    return data
end

local f = CreateFrame("Frame")
local pending
local function schedule(reason)
    if pending then return end
    pending = true
    C_Timer.After(1, function() pending = nil; takeSnapshot(reason) end)
end

f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("CHARACTER_POINTS_CHANGED")
f:RegisterEvent("TRAIT_CONFIG_UPDATED")
local function recordTurnIn(questID, xp, money)
    ClaudeBridgeDB = ClaudeBridgeDB or {}
    local names = ClaudeBridgeDB.questNames or {}
    local title = names[questID] or try(C_QuestLog.GetTitleForQuestID, questID)
    local h = ClaudeBridgeDB.turnIns or {}
    table.insert(h, 1, { id = questID, title = title, at = time(), xp = xp, money = money,
        level = UnitLevel("player"), zone = GetRealZoneText(), character = UnitName("player") })
    while #h > 300 do table.remove(h) end
    ClaudeBridgeDB.turnIns = h
end

f:SetScript("OnEvent", function(_, event, ...)
    if event == "QUEST_TURNED_IN" then pcall(recordTurnIn, ...) end
    if event == "PLAYER_LOGOUT" then
        pcall(takeSnapshot, "logout") -- skipped automatically if unit data is already gone
    else
        schedule(event)
    end
end)

-- Keep the in-memory snapshot fresh so any save (reload, logout, crash-free exit) has current data.
C_Timer.NewTicker(30, function() pcall(takeSnapshot, "timer") end)

SLASH_CLAUDEBRIDGE1 = "/cb"
SLASH_CLAUDEBRIDGE2 = "/claudebridge"
SlashCmdList.CLAUDEBRIDGE = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "sync" then
        takeSnapshot("sync")
        ReloadUI()
        return
    end
    local d = takeSnapshot("status")
    if not d then print("|cff7fbf5fClaudeBridge|r: character data not ready yet, try again in a moment.") return end
    print(("|cff7fbf5fClaudeBridge|r %s: %s %s lvl %d, %d quests in log, %d completed (%s), talents via %s. Type |cffffd100/cb sync|r to write it to disk.")
        :format(VERSION, d.character.name or "?", d.character.class or "?", d.character.level or 0,
        #d.questLog, #d.completedQuests, d.completedQuestsApi, d.talents.api or "?"))
end
