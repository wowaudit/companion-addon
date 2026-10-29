if WowauditGameVersion ~= "live" then return end

SimcExport = LibStub("AceAddon-3.0"):NewAddon("WowauditSimcExport", "AceComm-3.0", "AceSerializer-3.0", "AceEvent-3.0", "AceTimer-3.0")
local addon = SimcExport

-- The admin collects SimC exports (from the Simulationcraft addon) from their group into
-- WowauditDataSyncDB, which the desktop client uploads. Members answer requests either with
-- this module or with RCLootCouncil_wowaudit, which speaks the same protocol and takes
-- precedence when both are installed.

local COMM_PREFIX = "WowauditSimc"
local PAYLOAD_VERSION = 1
local MAX_REPLY_DELAY = 10
local ROSTER_DEBOUNCE = 5
-- Equipping a gear set changes every slot at once, so the own export waits until changes settle.
local OWN_EXPORT_DEBOUNCE = 10
local PRUNE_AFTER = 30 * 24 * 60 * 60
local MAX_EXPORT_LENGTH = 60000

local requestedMembers = {}
local replyTimers = {}
local deferredReplies = {}

local function isAdmin()
  return WowauditCompanionAdmin == true
end

local function otherResponderActive()
  return WowauditSimcResponder == "RCLootCouncil_wowaudit"
end

local function normalizeRealm(realm)
  if not realm or realm == "" then
    return (GetNormalizedRealmName() or ""):gsub("%s+", "")
  end
  return realm:gsub("%s+", "")
end

local function fullName(name, realm)
  if not name or name == "" then
    return nil
  end
  if string.find(name, "-", 1, true) then
    return name
  end
  return name .. "-" .. normalizeRealm(realm)
end

local function playerFullName()
  local name, realm = UnitFullName("player")
  return fullName(name, realm)
end

-- Only the lines SimC simulates on count, so the export's timestamp header and
-- currency comments don't make every export look new. Must match RCLootCouncil_wowaudit.
local function exportHash(text)
  local hash = 5381
  for line in text:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= "#" then
      for i = 1, #line do
        hash = (hash * 33 + line:byte(i)) % 4294967296
      end
    end
  end
  return format("%08x", hash)
end

local function currentSpecId()
  local index = GetSpecialization and GetSpecialization()
  if not index then
    return nil
  end
  return GetSpecializationInfo(index)
end

local function generateExport()
  local simc = LibStub("AceAddon-3.0"):GetAddon("Simulationcraft", true)
  if not simc or type(simc.GetSimcProfile) ~= "function" then
    return nil
  end

  local ok, profile, printError = pcall(simc.GetSimcProfile, simc, false, false, false, false)
  if not ok or type(profile) ~= "string" or profile == "" or printError then
    return nil
  end

  -- Pipes are doubled for display in the addon's edit box.
  profile = profile:gsub("||", "|")
  if #profile > MAX_EXPORT_LENGTH then
    return nil
  end
  return profile
end

local function exportsTable()
  if DataSync and DataSync.db then
    local g = DataSync.db.global
    g.simcExports = g.simcExports or {}
    return g.simcExports
  end
  return nil
end

local function groupChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
    return "INSTANCE_CHAT"
  end
  return IsInRaid() and "RAID" or "PARTY"
end

local function onlineGroupMembers()
  local names = {}
  local prefix = IsInRaid() and "raid" or "party"
  local count = IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
  for i = 1, count do
    local unit = prefix .. i
    if UnitExists(unit) and UnitIsConnected(unit) and not UnitIsUnit(unit, "player") then
      local name, realm = UnitName(unit)
      local key = fullName(name, realm)
      if key and name ~= UNKNOWNOBJECT then
        names[#names + 1] = key
      end
    end
  end
  return names
end

-- Collecting (admin only)

function addon:StoreExport(name, specId, text, generatedAt, hash)
  local exports = exportsTable()
  if not exports or not name or not specId or type(text) ~= "string" or #text > MAX_EXPORT_LENGTH then
    return
  end

  exports[name] = exports[name] or {}
  local existing = exports[name][specId]
  if existing and (existing.generatedAt or 0) > generatedAt then
    return
  end

  exports[name][specId] = {
    text = text,
    generatedAt = generatedAt,
    hash = hash or exportHash(text),
  }
end

function addon:KnownHashes(name)
  local exports = exportsTable()
  local entries = exports and exports[name]
  if type(entries) ~= "table" then
    return nil
  end

  local hashes = {}
  for specId, entry in pairs(entries) do
    if type(entry) == "table" and entry.hash then
      hashes[specId] = entry.hash
    end
  end
  return hashes
end

function addon:ScheduleOwnExport()
  if not isAdmin() then
    return
  end
  if self.ownExportTimer then
    self:CancelTimer(self.ownExportTimer)
  end

  self.ownExportTimer = self:ScheduleTimer(function()
    addon.ownExportTimer = nil
    addon:StoreOwnExport()
  end, OWN_EXPORT_DEBOUNCE)
end

function addon:StoreOwnExport()
  if InCombatLockdown() then
    self.ownExportDeferred = true
    return
  end
  self.ownExportDeferred = false

  local name, specId, text = playerFullName(), currentSpecId(), generateExport()
  if not specId or not text then
    return
  end

  local hash = exportHash(text)
  local known = self:KnownHashes(name)
  if known and known[specId] == hash then
    return
  end
  self:StoreExport(name, specId, text, time(), hash)
end

-- The whole group is asked in a single message. Members answer by whisper, and only when
-- their export differs from the one we already have.
function addon:RequestFromGroup()
  if not isAdmin() or not IsInGroup() then
    return
  end

  local known = {}
  for _, name in ipairs(onlineGroupMembers()) do
    requestedMembers[name] = true
    known[name] = self:KnownHashes(name)
  end

  self:SendCommMessage(COMM_PREFIX, self:Serialize("REQ", known), groupChannel())
end

-- Players are asked once per session, when they join the group or when the admin joins theirs.
function addon:RequestFromNewMembers()
  for _, name in ipairs(onlineGroupMembers()) do
    if not requestedMembers[name] then
      self:RequestFromGroup()
      return
    end
  end
end

function addon:OnExportReceived(sender, version, specId, generatedAt, hash, text)
  if not isAdmin() or version ~= PAYLOAD_VERSION then
    return
  end

  specId = tonumber(specId)
  if not specId or type(text) ~= "string" or (hash ~= nil and type(hash) ~= "string") then
    return
  end

  generatedAt = math.min(tonumber(generatedAt) or time(), time())
  self:StoreExport(fullName(sender), specId, text, generatedAt, hash)
end

function addon:Prune()
  local exports = exportsTable()
  if not exports then
    return
  end

  local cutoff = time() - PRUNE_AFTER
  for name, entries in pairs(exports) do
    if type(entries) == "table" then
      for specId, entry in pairs(entries) do
        if type(entry) ~= "table" or (entry.generatedAt or 0) < cutoff then
          entries[specId] = nil
        end
      end
    end
    if type(entries) ~= "table" or next(entries) == nil then
      exports[name] = nil
    end
  end
end

-- RCLootCouncil's master looter ends a session once loot is handed out, a good moment
-- to pick up the gear that was just awarded.
function addon:SubscribeToLootCouncil()
  if self.lootCouncilSubscribed then
    return
  end

  local lootCouncil = LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
  if not lootCouncil or type(lootCouncil.Require) ~= "function" or not lootCouncil.PREFIXES then
    return
  end

  local ok, comms = pcall(lootCouncil.Require, "Services.Comms")
  if not ok or not comms or type(comms.Subscribe) ~= "function" then
    return
  end

  self.lootCouncilSubscribed = true
  comms:Subscribe(lootCouncil.PREFIXES.MAIN, "session_end", function()
    addon:ScheduleTimer(function()
      addon:RequestFromGroup()
    end, MAX_REPLY_DELAY)
  end)
end

-- Answering (members)

function addon:OnRequestReceived(sender, known)
  if otherResponderActive() or fullName(sender) == playerFullName() then
    return
  end

  local myName = playerFullName()
  local knownForMe = type(known) == "table" and myName and known[myName] or nil
  self:ScheduleReply(sender, knownForMe)
end

-- Spread replies so a raid answering one request doesn't all whisper at once.
function addon:ScheduleReply(sender, knownForMe)
  if replyTimers[sender] then
    self:CancelTimer(replyTimers[sender])
  end
  replyTimers[sender] = self:ScheduleTimer(function()
    replyTimers[sender] = nil
    addon:SendExport(sender, knownForMe)
  end, math.random() * MAX_REPLY_DELAY)
end

function addon:SendExport(sender, knownForMe)
  if InCombatLockdown() then
    deferredReplies[sender] = knownForMe or false
    return
  end

  local specId = currentSpecId()
  local text = generateExport()
  if not specId or not text then
    return
  end

  local hash = exportHash(text)
  if type(knownForMe) == "table" and knownForMe[specId] == hash then
    return
  end

  self:SendCommMessage(COMM_PREFIX, self:Serialize("SIMC", PAYLOAD_VERSION, specId, time(), hash, text), "WHISPER", sender, "BULK")
end

-- Events

function addon:OnCommReceived(prefix, message, distribution, sender)
  if prefix ~= COMM_PREFIX then
    return
  end

  local ok, command, a, b, c, d, e = self:Deserialize(message)
  if not ok then
    return
  end

  if command == "REQ" then
    self:OnRequestReceived(sender, a)
  elseif command == "SIMC" and distribution == "WHISPER" then
    self:OnExportReceived(sender, a, b, c, d, e)
  end
end

function addon:OnRosterChanged()
  if not isAdmin() then
    return
  end
  if not IsInGroup() then
    wipe(requestedMembers)
    return
  end
  if self.rosterTimer then
    self:CancelTimer(self.rosterTimer)
  end

  self.rosterTimer = self:ScheduleTimer(function()
    addon.rosterTimer = nil
    addon:RequestFromNewMembers()
  end, ROSTER_DEBOUNCE)
end

function addon:PLAYER_ENTERING_WORLD()
  self:OnRosterChanged()
  self:ScheduleOwnExport()
end

function addon:PLAYER_SPECIALIZATION_CHANGED(_, unit)
  if unit == "player" then
    self:ScheduleOwnExport()
  end
end

function addon:PLAYER_REGEN_ENABLED()
  local replies = deferredReplies
  deferredReplies = {}
  for sender, knownForMe in pairs(replies) do
    self:ScheduleReply(sender, knownForMe or nil)
  end

  if self.ownExportDeferred then
    self:ScheduleOwnExport()
  end
end

function addon:OnInitialize()
  self:RegisterComm(COMM_PREFIX)
end

function addon:OnEnable()
  self:Prune()
  self:SubscribeToLootCouncil()
  self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterChanged")
  self:RegisterEvent("PLAYER_ENTERING_WORLD")
  self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "ScheduleOwnExport")
  self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  self:RegisterEvent("TRAIT_CONFIG_UPDATED", "ScheduleOwnExport")
  self:RegisterEvent("PLAYER_REGEN_ENABLED")
end
