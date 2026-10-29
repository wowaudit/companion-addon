if WowauditGameVersion ~= "classic_forever" then return end

local COMM_PREFIX = "WowauditGear"
local PAYLOAD_VERSION = 1
local CAPTURE_DELAY = 5
local RESEND_AFTER = 30 * 60
local REPLY_MIN_DELAY = 2
local REPLY_MAX_DELAY = 15
local REPLY_THROTTLE = 5 * 60

local MAX_GEAR_LENGTH = 2000
local MAX_ITEM_LENGTH = 200
local MAX_PROFESSIONS = 2
local MAX_SKILL = 1000

-- Shirt (4) and tabard (19) are cosmetic.
local GEAR_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

local function isAdmin()
  return WowauditCompanionAdmin == true
end

local function characterKey(name, surname)
  return name .. " " .. surname
end

-- Mirrors the website's MANUAL_NAME_FORMAT (2 to 12 letters). Lua patterns are
-- byte based, so letters are counted as UTF-8 characters and anything that is
-- clearly not a letter is rejected.
local function isValidNamePart(value)
  if type(value) ~= "string" or value:find("[%s%p%d%c]") then return false end
  local length = select(2, value:gsub("[^\128-\191]", ""))
  return length >= 2 and length <= 12
end

local function isWholeNumber(value, min, max)
  return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
end

local function itemString(link)
  local value = link and link:match("|Hitem:([^|]+)|h")
  return value and value:gsub(":+$", "")
end

-- Gear is keyed by slot id as a string: a table with integer keys 1..n would be
-- exported by the desktop client as an array and lose its slot ids. The second
-- value is false when an equipped item has no link yet because it isn't cached.
local function collectGear(unit)
  local gear, complete = {}, true
  for _, slot in ipairs(GEAR_SLOTS) do
    local value = itemString(GetInventoryItemLink(unit, slot))
    if value and value ~= "" then
      gear[tostring(slot)] = value
    elseif GetInventoryItemID(unit, slot) then
      complete = false
    end
  end
  return gear, complete
end

local function collectProfessions()
  local professions = {}
  if not GetProfessions then return professions end

  local indices = { GetProfessions() }
  for i = 1, MAX_PROFESSIONS do
    local index = indices[i]
    if index then
      local name, _, skillLevel, maxSkillLevel, _, _, skillLine = GetProfessionInfo(index)
      if skillLine then
        professions[#professions + 1] = {
          skillLine = skillLine,
          name = name,
          rank = skillLevel or 0,
          maxRank = maxSkillLevel or 0,
        }
      end
    end
  end
  return professions
end

ForeverSync.collectProfessions = collectProfessions

-- Newer builds return the surname as UnitName's second value, older ones as
-- "Name Surname"; the guild roster entry for the unit's GUID is the last fallback.
local function unitNameParts(unit)
  local unitName, second = UnitName(unit)
  if unitName and second and second ~= "" and not ForeverSync.isOwnRealm(second) then
    return unitName, second
  end
  local name, surname = ForeverSync.splitName(unitName or "")
  if surname then return name, surname end

  local guid = UnitGUID(unit)
  for i = 1, (GetNumGuildMembers() or 0) do
    local fullName, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, memberGuid = GetGuildRosterInfo(i)
    if fullName and memberGuid == guid then
      return ForeverSync.splitName(fullName)
    end
  end
  return name, nil
end

local function encodeGear(gear)
  local parts = {}
  for slot = 1, 19 do
    local value = gear[tostring(slot)]
    if value then
      parts[#parts + 1] = slot .. "=" .. value
    end
  end
  return table.concat(parts, ";")
end

local function encodeProfessions(professions)
  local parts = {}
  for _, profession in ipairs(professions) do
    parts[#parts + 1] = profession.skillLine .. "=" .. profession.rank .. "/" .. profession.maxRank
  end
  return table.concat(parts, ";")
end

local function decodeGear(value)
  if type(value) ~= "string" or #value > MAX_GEAR_LENGTH then return nil end

  local gear = {}
  for part in value:gmatch("[^;]+") do
    local slot, item = part:match("^(%d+)=([%d:%-]+)$")
    slot = tonumber(slot)
    if not slot or slot < 1 or slot > 19 or #item > MAX_ITEM_LENGTH then return nil end
    gear[tostring(slot)] = item
  end
  return gear
end

local function decodeProfessions(value)
  if type(value) ~= "string" then return nil end

  local professions = {}
  for part in value:gmatch("[^;]+") do
    local skillLine, rank, maxRank = part:match("^(%d+)=(%d+)/(%d+)$")
    skillLine, rank, maxRank = tonumber(skillLine), tonumber(rank), tonumber(maxRank)
    if not skillLine or rank > MAX_SKILL or maxRank > MAX_SKILL then return nil end
    if #professions >= MAX_PROFESSIONS then return nil end
    professions[#professions + 1] = { skillLine = skillLine, rank = rank, maxRank = maxRank }
  end
  return professions
end

function ForeverSync:RegisterGearSyncEvents()
  self:RegisterComm(COMM_PREFIX, "OnGearCommReceived")
  self:SafeRegisterEvent("ZONE_CHANGED_NEW_AREA", "ScheduleGearCapture")
  self:SafeRegisterEvent("INSPECT_READY", "OnInspectReady")
  self:RegisterRecipeSyncEvents()
  self:RegisterPvpSyncEvents()
end

function ForeverSync:ScheduleGearCapture()
  if self.gearTimer then return end

  self.gearTimer = self:ScheduleTimer(function()
    self.gearTimer = nil
    self:CaptureGear()
  end, CAPTURE_DELAY)
end

-- "" means not in a guild. Right after login IsInGuild() can be true before the
-- guild name is known; nil leaves the website's guild link untouched.
local function ownGuildName()
  if not IsInGuild() then return "" end
  local guildName = GetGuildInfo("player")
  if guildName and guildName ~= "" then return guildName end
  return nil
end

function ForeverSync:BuildRecord(unit, gear, guild)
  local name, surname = unitNameParts(unit)
  if not isValidNamePart(name) or not isValidNamePart(surname) then return nil end

  local _, classFile, classId = UnitClass(unit)
  local _, raceFile = UnitRace(unit)
  local level = UnitLevel(unit)

  return {
    name = name,
    surname = surname,
    realm = GetNormalizedRealmName(),
    region = self.currentRegion(),
    classId = classId or (classFile and self.CLASS_IDS[classFile]),
    raceFile = raceFile,
    faction = UnitFactionGroup(unit),
    guild = guild,
    level = level and level > 0 and level or nil,
    updatedAt = GetServerTime(),
    gear = gear,
  }
end

function ForeverSync:BuildOwnRecord()
  local record = self:BuildRecord("player", (collectGear("player")), ownGuildName())
  if record then
    record.professions = collectProfessions()
    record.recipes, record.recipesUpdatedAt = self:OwnRecipes(record.professions)
    record.pvp = self.collectOwnPvp()
  end
  return record
end

local INSPECT_RETRY_DELAY = 0.5
local INSPECT_MAX_ATTEMPTS = 5
local INSPECT_UNITS = { "target", "focus", "mouseover" }

local function unitForGuid(guid)
  for _, unit in ipairs(INSPECT_UNITS) do
    if UnitGUID(unit) == guid then return unit end
  end

  local prefix, count = "party", GetNumSubgroupMembers()
  if IsInRaid() then
    prefix, count = "raid", GetNumGroupMembers()
  end
  for i = 1, count do
    if UnitGUID(prefix .. i) == guid then return prefix .. i end
  end
  return nil
end

function ForeverSync:OnInspectReady(_, guid)
  self:CaptureInspect(guid, 1)
end

-- Inspected records have no professions or recipes (the API doesn't expose them) and no PvP
-- rank, and only carry a guild when the game shows one, so a missing guild isn't read as "left".
function ForeverSync:CaptureInspect(guid, attempt)
  local unit = guid and unitForGuid(guid)
  if not unit or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end

  local gear, complete = collectGear(unit)
  if not complete then
    if attempt < INSPECT_MAX_ATTEMPTS then
      self:ScheduleTimer(function() self:CaptureInspect(guid, attempt + 1) end, INSPECT_RETRY_DELAY)
    end
    return
  end
  -- An empty result usually means the inspect data was already cleared.
  if next(gear) == nil then return end

  local guild = GetGuildInfo(unit)
  local record = self:BuildRecord(unit, gear, guild ~= "" and guild or nil)
  if record then
    self:StoreCharacter(record)
  end
end

function ForeverSync:StoreCharacter(record)
  local characters = self.db.global.characters
  local key = characterKey(record.name, record.surname)
  local existing = characters[key]
  if existing and (existing.updatedAt or 0) >= record.updatedAt then return end

  if existing then
    if record.professions == nil then
      record.professions = existing.professions
    end
    if record.recipes == nil then
      record.recipes, record.recipesUpdatedAt = existing.recipes, existing.recipesUpdatedAt
    end
    if record.pvp == nil then
      record.pvp = existing.pvp
    end
  end
  characters[key] = record
end

function ForeverSync:CaptureGear()
  local record = self:BuildOwnRecord()
  if not record then return end

  self:StoreCharacter(record)

  if isAdmin() then
    self:RequestGuildGear()
  else
    self:BroadcastGear(record)
  end
end

function ForeverSync:BroadcastGear(record, force)
  if not IsInGuild() then return end

  local gear = encodeGear(record.gear)
  local professions = encodeProfessions(record.professions)
  local recipes = self.encodeRecipes(record.recipes)
  local pvp = self.encodePvp(record.pvp)
  local fingerprint = gear .. "|" .. professions .. "|" .. (recipes or "") .. "|" .. (pvp or "")
  local recentlySent = self.lastGearSentAt and (GetTime() - self.lastGearSentAt) < RESEND_AFTER
  if not force and fingerprint == self.lastGearFingerprint and recentlySent then return end

  self.lastGearFingerprint = fingerprint
  self.lastGearSentAt = GetTime()

  -- Recipes and PvP data are trailing fields, so admins on older versions ignore them.
  local message = self:Serialize("GEAR", PAYLOAD_VERSION, record.name, record.surname, record.realm or "",
    record.classId, record.level, record.updatedAt, gear, professions, record.raceFile, record.faction,
    recipes, recipes and record.recipesUpdatedAt or nil, pvp, pvp and record.pvp.updatedAt or nil)
  self:SendCommMessage(COMM_PREFIX, message, "GUILD")
end

-- Members only send while someone is listening, so an admin logging in asks
-- once per session for everyone's current gear.
function ForeverSync:RequestGuildGear()
  if self.gearRequested or not IsInGuild() then return end

  self.gearRequested = true
  self:SendCommMessage(COMM_PREFIX, self:Serialize("REQ"), "GUILD")
end

-- Replies are spread out so a request doesn't make the whole guild answer at once.
function ForeverSync:ScheduleGearReply()
  if self.gearReplyTimer then return end
  if self.lastGearReplyAt and (GetTime() - self.lastGearReplyAt) < REPLY_THROTTLE then return end

  self.gearReplyTimer = self:ScheduleTimer(function()
    self.gearReplyTimer = nil
    self.lastGearReplyAt = GetTime()

    local record = self:BuildOwnRecord()
    if record then
      self:StoreCharacter(record)
      self:BroadcastGear(record, true)
    end
  end, math.random(REPLY_MIN_DELAY, REPLY_MAX_DELAY))
end

-- Payloads come from other players' clients, so every field is validated before
-- it ends up in SavedVariables and on the website.
function ForeverSync:OnGearCommReceived(prefix, message, distribution)
  if prefix ~= COMM_PREFIX or distribution ~= "GUILD" then return end

  local ok, command, version, name, surname, realm, classId, level, updatedAt, gear, professions, raceFile, faction, recipes, recipesUpdatedAt, pvp, pvpUpdatedAt = self:Deserialize(message)
  if not ok then return end

  if command == "REQ" then
    if not isAdmin() then
      self:ScheduleGearReply()
    end
    return
  end

  if command ~= "GEAR" or version ~= PAYLOAD_VERSION or not isAdmin() then return end
  if not isValidNamePart(name) or not isValidNamePart(surname) then return end
  if type(realm) ~= "string" or realm == "" or #realm > 64 or realm:find("%c") then return end
  if not isWholeNumber(classId, 1, 13) or not isWholeNumber(level, 1, 100) then return end
  if not isWholeNumber(updatedAt, 1, math.huge) then return end

  local decodedGear = decodeGear(gear)
  local decodedProfessions = decodeProfessions(professions)
  if not decodedGear or not decodedProfessions then return end
  if raceFile ~= nil and (type(raceFile) ~= "string" or #raceFile > 32 or not raceFile:match("^%a+$")) then return end
  if faction ~= nil and faction ~= "Alliance" and faction ~= "Horde" then return end

  -- Senders on older versions don't send recipes or PvP data; an invalid field is dropped without
  -- rejecting the gear, and StoreCharacter then keeps what we already had.
  local decodedRecipes = self.isValidRecipeTimestamp(recipesUpdatedAt) and self.decodeRecipes(recipes) or nil
  local decodedPvp = self.decodePvp(pvp, pvpUpdatedAt)

  -- The message arrived on the guild channel, so the sender shares our guild.
  self:StoreCharacter({
    name = name,
    surname = surname,
    realm = realm,
    region = self.currentRegion(),
    classId = classId,
    raceFile = raceFile,
    faction = faction,
    guild = ownGuildName(),
    level = level,
    updatedAt = updatedAt,
    gear = decodedGear,
    professions = decodedProfessions,
    recipes = decodedRecipes,
    recipesUpdatedAt = decodedRecipes and recipesUpdatedAt or nil,
    pvp = decodedPvp,
  })
end
