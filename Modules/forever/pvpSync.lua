if WowauditGameVersion ~= "classic_forever" then return end

-- The seasonal PvP rank (Private/Scout up to Grand Marshal/High Warlord) is a renown faction.
local PVP_RANK_FACTION_ID = 2800
local MAX_RANK = 14
local MAX_POINTS = 10000000
local MAX_KILLS = 10000000

local function isWholeNumber(value, min, max)
  return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
end

local function wholeNumber(value)
  return type(value) == "number" and math.floor(value) or nil
end

-- PvP data is { rank, progress, threshold, kills, updatedAt }, where progress and threshold are the
-- rank points earned toward the next rank. Kills are lifetime honorable kills and may be missing.
local function buildPvp(rank, progress, threshold, kills, updatedAt)
  rank, progress, threshold, kills = wholeNumber(rank), wholeNumber(progress) or 0, wholeNumber(threshold) or 0, wholeNumber(kills)
  if not isWholeNumber(rank, 0, MAX_RANK) then return nil end
  if not isWholeNumber(progress, 0, MAX_POINTS) or not isWholeNumber(threshold, 0, MAX_POINTS) then return nil end
  if kills ~= nil and not isWholeNumber(kills, 0, MAX_KILLS) then kills = nil end

  return { rank = rank, progress = progress, threshold = threshold, kills = kills, updatedAt = updatedAt }
end

-- On the guild channel PvP data travels as "rank:progress:threshold:kills", kills being optional.
local function encodePvp(pvp)
  if not pvp then return nil end
  return table.concat({ pvp.rank, pvp.progress, pvp.threshold, pvp.kills or "" }, ":")
end

local function decodePvp(value, updatedAt)
  if type(value) ~= "string" or not isWholeNumber(updatedAt, 1, math.huge) then return nil end

  local rank, progress, threshold, kills = value:match("^(%d+):(%d+):(%d+):(%d*)$")
  if not rank then return nil end
  return buildPvp(tonumber(rank), tonumber(progress), tonumber(threshold), tonumber(kills), updatedAt)
end

ForeverSync.encodePvp = encodePvp
ForeverSync.decodePvp = decodePvp

local function ownHonorableKills()
  if not GetPVPLifetimeStats then return nil end
  local ok, kills = pcall(GetPVPLifetimeStats)
  return ok and kills or nil
end

function ForeverSync.collectOwnPvp()
  local api = C_MajorFactions
  if not api or not api.GetMajorFactionProgressionInfo then return nil end

  local info = api.GetMajorFactionProgressionInfo(PVP_RANK_FACTION_ID)
  if not info then return nil end
  return buildPvp(info.renownLevel, info.renownReputationEarned, info.renownLevelThreshold, ownHonorableKills(), GetServerTime())
end

function ForeverSync:RegisterPvpSyncEvents()
  self:SafeRegisterEvent("PLAYER_PVP_RANK_CHANGED", "ScheduleGearCapture")
end
