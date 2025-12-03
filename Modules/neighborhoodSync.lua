local NeighborhoodSync = LibStub("AceAddon-3.0"):NewAddon("WowauditNeighborhoodSync", "AceEvent-3.0")
local AceDB = LibStub("AceDB-3.0")

local defaults = {
  profile = {
    neighborhood = {
      mapData = nil,
      cornerstoneInfo = nil,
      name = nil,
    },
  },
}

function NeighborhoodSync:OnInitialize()
  self.db = AceDB:New("WowauditNeighborhoodSyncDB", defaults, true)
end

function NeighborhoodSync:OnEnable()
  -- Register neighborhood events
  self:RegisterEvent("NEIGHBORHOOD_MAP_DATA_UPDATED", "OnMapDataUpdated")
  self:RegisterEvent("NEIGHBORHOOD_INFO_UPDATED", "OnInfoUpdated")
  self:RegisterEvent("NEIGHBORHOOD_NAME_UPDATED", "OnNameUpdated")

  -- Register zone change event to detect entering neighborhood zone
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
  self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneChanged")
end

function NeighborhoodSync:OnMapDataUpdated()
  local mapData = C_HousingNeighborhood.GetNeighborhoodMapData()
  if mapData then
    self.db.profile.neighborhood.mapData = mapData
    print("[NeighborhoodSync] Map data updated and saved")
  else
    print("[NeighborhoodSync] Map data update called but no data returned")
  end
end

function NeighborhoodSync:OnInfoUpdated()
  local cornerstoneInfo = C_HousingNeighborhood.GetCornerstoneNeighborhoodInfo()
  if cornerstoneInfo then
    self.db.profile.neighborhood.cornerstoneInfo = cornerstoneInfo
    print("[NeighborhoodSync] Cornerstone info updated and saved")
  else
    print("[NeighborhoodSync] Cornerstone info update called but no data returned")
  end
end

function NeighborhoodSync:OnNameUpdated()
  local name = C_HousingNeighborhood.GetNeighborhoodName()
  if name then
    self.db.profile.neighborhood.name = name
    print("[NeighborhoodSync] Neighborhood name updated: " .. tostring(name))
  else
    print("[NeighborhoodSync] Neighborhood name update called but no name returned")
  end
end

function NeighborhoodSync:OnZoneChanged()
  -- Check if we're in a neighborhood zone
  -- C_HousingNeighborhood functions should be safe to call even if not in neighborhood
  -- but we'll call all three functions as requested
  print("[NeighborhoodSync] Zone changed, updating all neighborhood data...")
  self:OnMapDataUpdated()
  self:OnInfoUpdated()
  self:OnNameUpdated()
end
