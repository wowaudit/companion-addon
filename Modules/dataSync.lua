local DataSync = LibStub("AceAddon-3.0"):NewAddon("WowauditDataSync", "AceEvent-3.0", "AceTimer-3.0")
local AceDB = LibStub("AceDB-3.0")

local NEIGHBORHOOD_BUFF_SPELL_ID = 1227147

local function HasNeighborhoodBuff()
  local auraData = C_UnitAuras.GetPlayerAuraBySpellID(NEIGHBORHOOD_BUFF_SPELL_ID)
  return auraData ~= nil
end

local function IsGuildNeighborhood()
  local metadata = C_HousingNeighborhood.GetCornerstoneNeighborhoodInfo()
  return metadata and metadata.neighborhoodOwnerType == 1
end

local function GetGuildProfileName()
  local guildName, _, _, guildRealm = GetGuildInfo("player")
  if not guildName then return nil end

  -- guildRealm may be nil if on the same realm, use player's realm as fallback
  local realm = guildRealm or GetNormalizedRealmName()
  local region = GetCurrentRegionName() or "Unknown"

  return guildName .. "-" .. realm .. "-" .. region
end

local defaults = {
  profile = {
    neighborhood = {
      plots = nil,
      metadata = nil,
      currentRealm = nil,
      mapId = nil,
    },
    guild = {
      motd = nil,
      ranks = nil,
      members = nil,
    },
  },
}

function DataSync:OnInitialize()
  self.db = AceDB:New("WowauditDataSyncDB", defaults, true)

  -- Register slash command
  SLASH_WOWAUDIT1 = "/wowaudit"
  SlashCmdList["WOWAUDIT"] = function(msg)
    if msg == "sync" then
      DataSync:ManualSync()
    elseif msg == "invite" then
      -- Open invite tool window
      if Wit and Wit.CreateFrame then
        Wit:CreateFrame()
      else
        print("[Wowaudit] Invite tool not loaded")
      end
    else
      print("Usage: /wowaudit [sync|invite]")
    end
  end
end

function DataSync:OnEnable()
  -- Register neighborhood events
  self:RegisterEvent("NEIGHBORHOOD_MAP_DATA_UPDATED", "OnMapDataUpdated")
  self:RegisterEvent("NEIGHBORHOOD_INFO_UPDATED", "OnInfoUpdated")
  self:RegisterEvent("NEIGHBORHOOD_NAME_UPDATED", "OnInfoUpdated")

  -- Register zone change event to detect entering neighborhood zone
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
  self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneChanged")

  -- Register guild events
  self:RegisterEvent("GUILD_MOTD", "OnGuildMOTD")
end

function DataSync:OnMapDataUpdated()
  if not HasNeighborhoodBuff() then return end
  if not IsGuildNeighborhood() then return end

  local mapData = C_HousingNeighborhood.GetNeighborhoodMapData()
  if mapData then
    local plots = {}
    for i, record in ipairs(mapData) do
      plots[i] = {
        ownerName = record.ownerName,
        plotID = record.plotID,
      }
    end
    self.db.profile.neighborhood.plots = plots
  end
end

function DataSync:OnInfoUpdated()
  if not HasNeighborhoodBuff() then return end
  if not IsGuildNeighborhood() then return end

  local metadata = C_HousingNeighborhood.GetCornerstoneNeighborhoodInfo()
  if metadata then
    self.db.profile.neighborhood.metadata = metadata
  end
end

function DataSync:SyncGuildMOTD()
  self:SetGuildProfile()
  local motd = GetGuildRosterMOTD()
  if motd and motd ~= "" then
    self.db.profile.guild.motd = motd
  else
    self.db.profile.guild.motd = nil
  end
end

function DataSync:SyncGuildRanks()
  self:SetGuildProfile()
  local numRanks = GuildControlGetNumRanks()
  if numRanks and numRanks > 0 then
    local ranks = {}
    for i = 1, numRanks do
      ranks[i] = {
        index = i,
        name = GuildControlGetRankName(i),
      }
    end
    self.db.profile.guild.ranks = ranks
  end
end

function DataSync:SyncGuildMembers()
  self:SetGuildProfile()
  local numMembers = GetNumGuildMembers()
  if numMembers and numMembers > 0 then
    local members = {}
    for i = 1, numMembers do
      local name, _, _, _, _, _, publicNote = GetGuildRosterInfo(i)
      if name then
        members[i] = {
          name = name,
          publicNote = publicNote,
          officerNote = officerNote,
          guid = guid,
        }
      end
    end
    self.db.profile.guild.members = members
  end
end

function DataSync:OnGuildMOTD(event, motd)
  -- motd is passed as the second argument to the event handler
  if motd and motd ~= "" then
    self:SetGuildProfile()
    self.db.profile.guild.motd = motd
  end
end

function DataSync:SetGuildProfile()
  local profileName = GetGuildProfileName()
  if profileName and self.db:GetCurrentProfile() ~= profileName then
    self.db:SetProfile(profileName)
  end
end

function DataSync:ManualSync()
  C_HousingNeighborhood.RequestNeighborhoodRoster()
  C_HousingNeighborhood.RequestNeighborhoodInfo()
  C_GuildInfo.GuildRoster() -- Request fresh guild roster data

  -- Sync guild data immediately
  self:SyncGuildMOTD()
  self:SyncGuildRanks()
  self:SyncGuildMembers()
  print("Synced guild data. Close the game or /reload to send it to the wowaudit website.")

  -- Check requirements
  if not HasNeighborhoodBuff() then
    print("You are not in your own neighborhood, did not sync neighborhood data")
    return
  end

  if not IsGuildNeighborhood() then
    print("Your neighborhood is not owned by your guild, did not sync neighborhood data")
    return
  end

  self:OnMapDataUpdated()
  self:OnInfoUpdated()

  self.db.profile.neighborhood.currentRealm = GetRealmName()
  self.db.profile.neighborhood.mapId = C_Map.GetBestMapForUnit("player")

  print("Synced neighborhood data. Close the game or /reload to send it to the wowaudit website.")
end

function DataSync:OnZoneChanged(event)
  C_HousingNeighborhood.RequestNeighborhoodRoster()
  C_HousingNeighborhood.RequestNeighborhoodInfo()

  -- Only sync neighborhood data when we have the neighborhood buff and it's a guild neighborhood
  if HasNeighborhoodBuff() and IsGuildNeighborhood() then
    -- Set profile based on guild before syncing
    self:SetGuildProfile()

    self:OnMapDataUpdated()
    self:OnInfoUpdated()

    self.db.profile.neighborhood.currentRealm = GetRealmName()
    self.db.profile.neighborhood.mapId = C_Map.GetBestMapForUnit("player")

    -- Sync guild data with 10 second delay to ensure data is available
    self:ScheduleTimer("SyncGuildMOTD", 10)
    self:ScheduleTimer("SyncGuildRanks", 11)
    self:ScheduleTimer("SyncGuildMembers", 12)
  end
end
