function DataSync:RegisterGuildSyncEvents()
  self:RegisterEvent("GUILD_MOTD", "SyncGuildData")
end

function DataSync:ScheduleGuildDataSync()
  self:ScheduleTimer("SyncGuildData", 10)
end

function DataSync:SyncGuildData()
  self:SetGuildProfile()
  self:SyncGuildMOTD(guildProfile)
  self:SyncGuildRanks(guildProfile)
  self:SyncGuildMembers(guildProfile)
  self.db.profile.lastSyncTime = C_DateAndTime.GetServerTimeLocal()
end

function DataSync:SyncGuildMOTD()
  local motd = GetGuildRosterMOTD()
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
