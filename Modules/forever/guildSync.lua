if WowauditGameVersion ~= "classic_forever" then return end

ForeverSync = LibStub("AceAddon-3.0"):NewAddon("WowauditForeverSync", "AceEvent-3.0", "AceTimer-3.0", "AceComm-3.0", "AceSerializer-3.0")
local AceDB = LibStub("AceDB-3.0")

local ROSTER_SYNC_DELAY = 2
local ENTER_WORLD_SYNC_DELAY = 10

local defaults = {
  profile = {
    guild = {},
  },
}

-- GetNumClasses() on classic clients is lower than the highest class id, so
-- looping GetClassInfo over it misses Druid (11).
local CLASS_IDS = {
  WARRIOR = 1,
  PALADIN = 2,
  HUNTER = 3,
  ROGUE = 4,
  PRIEST = 5,
  DEATHKNIGHT = 6,
  SHAMAN = 7,
  MAGE = 8,
  WARLOCK = 9,
  MONK = 10,
  DRUID = 11,
  DEMONHUNTER = 12,
  EVOKER = 13,
}

local REGION_NAMES = { "US", "KR", "EU", "TW", "CN" }

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function nonEmpty(value)
  if value == nil or value == "" then return nil end
  return value
end

local function isEventValid(event)
  if C_EventUtils and C_EventUtils.IsEventValid then
    return C_EventUtils.IsEventValid(event)
  end
  return true
end

local function requestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  elseif GuildRoster then
    GuildRoster()
  end
end

local function currentRegion()
  return nonEmpty(safeCall(GetCurrentRegionName))
    or REGION_NAMES[safeCall(GetCurrentRegion) or 0]
    or "Unknown"
end

local function isOwnRealm(value)
  local normalized = value:gsub("[%s%-]", "")
  return normalized == (nonEmpty(safeCall(GetNormalizedRealmName)) or "")
    or normalized == (nonEmpty(safeCall(GetRealmName)) or ""):gsub("[%s%-]", "")
end

-- Camelot has no realm in character names. Depending on the build the roster
-- returns "Name Surname" or "Name-Surname"; a trailing realm is stripped.
local function splitName(fullName)
  fullName = fullName:match("^%s*(.-)%s*$")
  local base, suffix = fullName:match("^([^%-]+)%-(.+)$")
  if base then
    if isOwnRealm(suffix) then
      fullName = base:match("^%s*(.-)%s*$")
    else
      return base:match("^%s*(.-)%s*$"), suffix
    end
  end
  local name, surname = fullName:match("^(%S+)%s+(.+)$")
  if name then
    return name, surname
  end
  return fullName, nil
end

ForeverSync.isOwnRealm = isOwnRealm

local function raceForGuid(guid)
  if not guid or not GetPlayerInfoByGUID then return nil end
  local ok, _, _, race, raceFile = pcall(GetPlayerInfoByGUID, guid)
  if ok then return nonEmpty(race), nonEmpty(raceFile) end
  return nil
end

ForeverSync.CLASS_IDS = CLASS_IDS
ForeverSync.currentRegion = currentRegion
ForeverSync.splitName = splitName

function ForeverSync:OnInitialize()
  self.db = AceDB:New("WowauditForeverSyncDB", defaults, true)
  self.db.global.gameVersion = "classic_forever"
  -- Everything stored last session was uploaded by the desktop client when the
  -- game wrote the file, so only this session's characters are kept.
  self.db.global.characters = {}

  local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  self.db.global.addonVersion = safeCall(getMetadata, "WowauditCompanion", "Version")
end

function ForeverSync:OnEnable()
  self:SafeRegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
  self:SafeRegisterEvent("PLAYER_GUILD_UPDATE", "OnPlayerGuildUpdate")
  self:SafeRegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
  self:SafeRegisterEvent("GUILD_MOTD", "OnGuildMOTD")
  self:RegisterGearSyncEvents()
end

function ForeverSync:SafeRegisterEvent(event, method)
  if not isEventValid(event) then return end
  pcall(self.RegisterEvent, self, event, method)
end

function ForeverSync:OnPlayerEnteringWorld()
  requestRoster()
  self:ScheduleGuildDataSync(ENTER_WORLD_SYNC_DELAY)
  self:ScheduleGearCapture()
end

function ForeverSync:OnPlayerGuildUpdate()
  requestRoster()
  self:ScheduleGuildDataSync()
end

function ForeverSync:OnGuildRosterUpdate()
  self:ScheduleGuildDataSync()
end

function ForeverSync:OnGuildMOTD(_, motd)
  self.latestGuildMOTD = motd
  self:ScheduleGuildDataSync()
end

-- Coalesces instead of debouncing: busy guilds fire GUILD_ROSTER_UPDATE often
-- enough that a resetting timer would never run. A sooner request still wins,
-- so the roster arriving cuts the enter-world fallback short.
function ForeverSync:ScheduleGuildDataSync(delay)
  delay = delay or ROSTER_SYNC_DELAY
  if self.syncTimer then
    if self:TimeLeft(self.syncTimer) <= delay then return end
    self:CancelTimer(self.syncTimer)
  end

  self.syncTimer = self:ScheduleTimer(function()
    self.syncTimer = nil
    self:SyncGuildData()
  end, delay)
end

function ForeverSync:SetGuildProfile()
  local guildName, _, _, guildRealm = GetGuildInfo("player")
  if not guildName then return nil end

  local realm = guildRealm or GetNormalizedRealmName() or "Unknown"
  local region = currentRegion()
  local profileName = guildName .. "-" .. realm .. "-" .. region

  if self.db:GetCurrentProfile() ~= profileName then
    self.db:SetProfile(profileName)
  end

  return guildName, realm, region
end

function ForeverSync:SyncGuildData()
  if not IsInGuild() then return false end

  local guildName, realm, region = self:SetGuildProfile()
  if not guildName then return false end

  local guild = self.db.profile.guild
  guild.name = guildName
  guild.realm = realm
  guild.region = region
  guild.faction = UnitFactionGroup("player")
  guild.info = nonEmpty(safeCall(GetGuildInfoText))

  self:SyncGuildMOTD(guild)
  self:SyncGuildRanks(guild)
  self:SyncGuildMembers(guild)

  self.db.profile.lastSyncTime = GetServerTime()
  return true
end

function ForeverSync:SyncGuildMOTD(guild)
  local motd = self.latestGuildMOTD
  if motd == nil then
    motd = safeCall(GetGuildRosterMOTD)
  end
  guild.motd = nonEmpty(motd)
end

function ForeverSync:SyncGuildRanks(guild)
  local numRanks = safeCall(GuildControlGetNumRanks)
  if not numRanks or numRanks <= 0 then return end

  local ranks = {}
  for i = 1, numRanks do
    ranks[i] = {
      index = i,
      name = GuildControlGetRankName(i),
    }
  end
  guild.ranks = ranks
end

-- rankIndex is GetGuildRosterInfo's 0-based value; ranks[].index is 1-based.
function ForeverSync:SyncGuildMembers(guild)
  local numMembers = GetNumGuildMembers()
  if not numMembers or numMembers <= 0 then return end

  local previousByGuid = {}
  for _, member in ipairs(guild.members or {}) do
    if member.guid then
      previousByGuid[member.guid] = member
    end
  end

  local members = {}
  for i = 1, numMembers do
    local fullName, rankName, rankIndex, level, _, _, publicNote, officerNote, _, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
    if fullName then
      local name, surname = splitName(fullName)
      local race, raceFile = raceForGuid(guid)
      local previous = guid and previousByGuid[guid]
      if not race and previous then
        race, raceFile = previous.race, previous.raceFile
      end

      members[#members + 1] = {
        name = name,
        surname = surname,
        classId = classFile and CLASS_IDS[classFile],
        classFile = classFile,
        race = race,
        raceFile = raceFile,
        level = level,
        rankIndex = rankIndex,
        rankName = rankName,
        publicNote = publicNote,
        officerNote = officerNote,
        guid = guid,
      }
    end
  end

  if #members > 0 then
    guild.members = members
  end
end

function ForeverSync:ManualSync()
  requestRoster()
  self:CaptureGear()
  if not self:SyncGuildData() then
    print("You are not in a guild, did not sync guild data.")
    return
  end

  print("Synced guild data.")
  print("Close the game or /reload to send your data to the wowaudit website.")
end
