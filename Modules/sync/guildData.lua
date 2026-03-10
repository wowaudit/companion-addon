function DataSync:RegisterGuildSyncEvents()
  self:RegisterEvent("GUILD_MOTD", "OnGuildMOTD")
end

function DataSync:ScheduleGuildDataSync()
  self:ScheduleTimer("SyncGuildData", 10)
end

function DataSync:OnGuildMOTD(_, motd)
  self.latestGuildMOTD = motd
  self:SyncGuildData()
end

function DataSync:SyncGuildData()
  self:SetGuildProfile()
  self:SyncGuildMOTD()
  self:SyncGuildRanks()
  self:SyncGuildMembers()
  self.db.profile.lastSyncTime = C_DateAndTime.GetServerTimeLocal()
end

function DataSync:SyncGuildMOTD()
  local motd = self.latestGuildMOTD
  if motd == nil then
    local ok, value = pcall(GetGuildRosterMOTD)
    if ok then
      motd = value
    end
  end

  if motd and motd ~= "" then
    self.db.profile.guild.motd = motd
  else
    self.db.profile.guild.motd = nil
  end
end

function DataSync:SyncGuildRanks()
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
  local numMembers = GetNumGuildMembers()
  local members = {}

  if numMembers and numMembers > 0 then
    for i = 1, numMembers do
      local name, _, _, _, _, _, publicNote, officerNote, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
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

  return members
end
