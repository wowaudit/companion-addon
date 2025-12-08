DataSync = LibStub("AceAddon-3.0"):NewAddon("WowauditDataSync", "AceEvent-3.0", "AceTimer-3.0")
local AceDB = LibStub("AceDB-3.0")

local defaults = {
  profile = {
    neighborhoods = {},
    guild = {
      motd = nil,
      ranks = nil,
      members = nil,
    },
  },
}

function DataSync:OnInitialize()
  self.db = AceDB:New("WowauditDataSyncDB", defaults, true)
end

function DataSync:OnEnable()
  self:RegisterGuildSyncEvents()
  self:RegisterNeighborhoodSyncEvents()
  self:RegisterSharedSyncEvents()
end

function DataSync:RegisterSharedSyncEvents()
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
  self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
end

function DataSync:OnZoneChanged()
  self:ScheduleGuildDataSync()
  self:RequestNeighborhoodDataSync()
end

function DataSync:OnPlayerEnteringWorld()
  self:ScheduleGuildDataSync()
  self:RequestNeighborhoodDataSync()
end

function DataSync:SetGuildProfile()
  local guildName, _, _, guildRealm = GetGuildInfo("player")
  if not guildName then return nil end

  -- guildRealm may be nil if on the same realm, use player's realm as fallback
  local realm = guildRealm or GetNormalizedRealmName()
  local region = GetCurrentRegionName() or "Unknown"

  local profileName =  guildName .. "-" .. realm .. "-" .. region

  if profileName and self.db:GetCurrentProfile() ~= profileName then
    self.db:SetProfile(profileName)
  end
end

function DataSync:ManualSync()
  C_GuildInfo.GuildRoster()
  DataSync:SyncGuildData()
  print("Synced guild data.")

  local neighborhoodSyncResult = DataSync:SyncNeighborhoodData()
  print(neighborhoodSyncResult or "Synced neighborhood data.")
  print("Close the game or /reload to send your data to the wowaudit website.")
end
