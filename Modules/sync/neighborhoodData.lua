function DataSync:IsOwnGuildNeighborhood(metadata)
  local isGuildNeighborhood = metadata and metadata.neighborhoodOwnerType == 1

  local auraData = C_UnitAuras.GetPlayerAuraBySpellID(1227147)
  local isOwnNeighborhood = auraData ~= nil

  local isOtherSubdivision = false
  if self.db.profile.neighborhoods then
    for _, neighborhood in pairs(self.db.profile.neighborhoods) do
      if neighborhood.metadata and neighborhood.metadata.ownerGUID == metadata.ownerGUID then
        isOtherSubdivision = true
      end
    end
  end

  return isGuildNeighborhood and (isOwnNeighborhood or isOtherSubdivision)
end

function DataSync:RegisterNeighborhoodSyncEvents()
  self:RegisterEvent("NEIGHBORHOOD_MAP_DATA_UPDATED", "RequestNeighborhoodDataSync")
  self:RegisterEvent("UPDATE_BULLETIN_BOARD_ROSTER", "OnBulletinBoardOpened")
end

function DataSync:RequestNeighborhoodDataSync()
  C_HousingNeighborhood.RequestNeighborhoodRoster()
  C_HousingNeighborhood.RequestNeighborhoodInfo()
  self:SyncNeighborhoodData()
end

function DataSync:SyncNeighborhoodData()
  self:SetGuildProfile()

  local neighborhoodGUID = C_Housing.GetCurrentNeighborhoodGUID()
  if not neighborhoodGUID then return "You are not in a neighborhood, did not sync neighborhood data." end

  local metadata = C_HousingNeighborhood.GetCornerstoneNeighborhoodInfo()
  if not self:IsOwnGuildNeighborhood(metadata) then
    return "You are not in your guild's neighborhood, did not sync neighborhood data. If you are in a different subdivision, please sync your own subdivision first."
  end

  self:UpdatePlotData(neighborhoodGUID)
  self:UpdateMetadata(neighborhoodGUID, metadata)

  self.db.profile.lastSyncTime = C_DateAndTime.GetServerTimeLocal()
end

function DataSync:OnBulletinBoardOpened(event, neighborhoodInfo, rosterList)
  self:SyncNeighborhoodData()

  local members = DataSync:SyncGuildMembers()

  -- Build a lookup table from playerGUID to member name
  local guidToName = {}
  for _, member in pairs(members) do
    if member.guid then
      guidToName[member.guid] = member.name
    end
  end

  -- For each neighborhood, count subdivision matches and assign the best one
  if self.db.profile.neighborhoods then
    for neighborhoodGUID, neighborhood in pairs(self.db.profile.neighborhoods) do
      if neighborhood.plots then
        local subdivisionCounts = {}

        for _, rosterEntry in pairs(rosterList) do
          local playerName = guidToName[rosterEntry.playerGUID]
          if playerName then
            for _, plot in pairs(neighborhood.plots) do
              if plot.ownerName == playerName and plot.plotID == rosterEntry.plotID then
                local subdivision = rosterEntry.subdivision
                subdivisionCounts[subdivision] = (subdivisionCounts[subdivision] or 0) + 1
                break
              end
            end
          end
        end

        local maxCount = 0
        local bestSubdivision = nil
        for subdivision, count in pairs(subdivisionCounts) do
          if count > maxCount then
            maxCount = count
            bestSubdivision = subdivision
          end
        end

        if bestSubdivision then
          neighborhood.subdivision = bestSubdivision

          neighborhood.plots = {}
          for _, rosterEntry in pairs(rosterList) do
            if rosterEntry.subdivision == bestSubdivision then
              table.insert(neighborhood.plots, {
                ownerName = guidToName[rosterEntry.playerGUID],
                plotID = rosterEntry.plotID,
              })
            end
          end
        end
      end
    end
  end
end

function DataSync:UpdatePlotData(neighborhoodGUID)
  local mapData = C_HousingNeighborhood.GetNeighborhoodMapData()
  if mapData then
    local plots = {}
    for i, record in ipairs(mapData) do
      plots[i] = {
        ownerName = record.ownerName,
        plotID = record.plotID,
      }
    end

    if not self.db.profile.neighborhoods[neighborhoodGUID] then
      self.db.profile.neighborhoods[neighborhoodGUID] = {}
    end

    self.db.profile.neighborhoods[neighborhoodGUID].plots = plots
  end
end

function DataSync:UpdateMetadata(neighborhoodGUID, metadata)
  self.db.profile.neighborhoods[neighborhoodGUID].metadata = metadata
  self.db.profile.neighborhoods[neighborhoodGUID].currentRealm = GetNormalizedRealmName()
  self.db.profile.neighborhoods[neighborhoodGUID].mapId = C_Map.GetBestMapForUnit("player")
end
