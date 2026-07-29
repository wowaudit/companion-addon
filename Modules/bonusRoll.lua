BonusRoll = LibStub("AceAddon-3.0"):NewAddon("WowauditBonusRoll", "AceComm-3.0", "AceSerializer-3.0", "AceEvent-3.0", "AceTimer-3.0")
local addon = BonusRoll
local AceGUI = LibStub("AceGUI-3.0")
local ScrollingTable = LibStub("ScrollingTable")

local CURRENCY_ID = 3418
local COMM_PREFIX = "WowauditCoins"
local REQUEST_DEBOUNCE = 5
local AUTO_REFRESH_DELAY = 19

local COL_LEFT = 4
local DATA_COLSPAN = 4 -- Left + Earned + Cap + Updated at

local frame
local frameShown
local coinsTable
local coinsTableHost
local lastRequestAt = 0

local GREY = { r = 0.60, g = 0.60, b = 0.60, a = 1.0 }
local WHITE = { r = 0.90, g = 0.90, b = 0.90, a = 1.0 }
local GREEN = { r = 0.45, g = 0.90, b = 0.45, a = 1.0 }
local YELLOW = { r = 1.00, g = 0.82, b = 0.20, a = 1.0 }
local RED = { r = 1.00, g = 0.45, b = 0.45, a = 1.0 }

local function leftColor(left)
  if left >= 2 then
    return GREEN
  elseif left == 1 then
    return YELLOW
  end
  return RED
end

local function earnedColor(earned, cap)
  if cap and earned >= cap then
    return GREEN
  elseif earned > 0 then
    return YELLOW
  end
  return RED
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

local function maxPlayerLevel()
  if GetMaxLevelForPlayerExpansion then
    return GetMaxLevelForPlayerExpansion()
  end
  if GetMaxPlayerLevel then
    return GetMaxPlayerLevel()
  end
  return UnitLevel("player") or 80
end

local function formatUpdatedAt(updatedAt)
  if type(updatedAt) ~= "number" or updatedAt <= 0 then
    return "-"
  end
  return date("%m/%d %H:%M", updatedAt)
end

local function classFileFromId(classId)
  if type(classId) ~= "number" or classId <= 0 then
    return nil
  end
  local _, classFile = GetClassInfo(classId)
  return classFile
end

local function classIdFromFile(classFileName)
  if not classFileName or not GetNumClasses then
    return nil
  end
  for i = 1, GetNumClasses() do
    local _, file, id = GetClassInfo(i)
    if file == classFileName then
      return id
    end
  end
  return nil
end

local function getClassColor(classFileName)
  local color = classFileName and RAID_CLASS_COLORS[classFileName]
  if color then
    return { r = color.r, g = color.g, b = color.b, a = 1.0 }
  end
  return WHITE
end

local function SetCellClassIcon(_, cellFrame, data, _, _, realrow, column, fShow)
  if not fShow then
    cellFrame:SetNormalTexture(nil)
    if cellFrame.text then
      cellFrame.text:SetText("")
    end
    return
  end

  local celldata = data[realrow] and data[realrow].cols and data[realrow].cols[column]
  local classFile = celldata and celldata.args and celldata.args[1]
  if classFile and CLASS_ICON_TCOORDS[classFile] then
    cellFrame:SetNormalTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    cellFrame:GetNormalTexture():SetTexCoord(unpack(CLASS_ICON_TCOORDS[classFile]))
  else
    cellFrame:SetNormalTexture(nil)
  end
  if cellFrame.text then
    cellFrame.text:SetText("")
  end
end

-- lib-st has no colspan; widen Left and collapse the following data columns instead.
local function SetCellLeft(_, cellFrame, data, cols, _, realrow, column, fShow)
  if not fShow then
    cellFrame.text:SetText("")
    cellFrame:SetWidth(cols[column].width)
    return
  end

  local celldata = data[realrow] and data[realrow].cols and data[realrow].cols[column]
  local colspan = celldata and celldata.colspan or 1
  local width = cols[column].width
  if colspan > 1 then
    width = 0
    for i = column, math.min(column + colspan - 1, #cols) do
      width = width + (cols[i].width or 0)
    end
  end

  cellFrame:SetWidth(width)
  cellFrame.text:SetWidth(math.max(width - 8, 1))
  if colspan > 1 then
    cellFrame.text:SetText("Addon not installed")
  else
    local value = celldata and celldata.value
    cellFrame.text:SetText(value ~= nil and tostring(value) or "")
  end
  local color = (celldata and celldata.color) or WHITE
  cellFrame.text:SetTextColor(color.r, color.g, color.b, color.a)
end

local function SetCellData(_, cellFrame, data, cols, _, realrow, column, fShow)
  if not fShow then
    cellFrame.text:SetText("")
    cellFrame:SetWidth(cols[column].width)
    return
  end

  local leftCell = data[realrow] and data[realrow].cols and data[realrow].cols[COL_LEFT]
  if leftCell and leftCell.colspan and leftCell.colspan > 1 then
    cellFrame:SetWidth(0.001)
    cellFrame.text:SetWidth(0.001)
    cellFrame.text:SetText("")
    return
  end

  local celldata = data[realrow] and data[realrow].cols and data[realrow].cols[column]
  cellFrame:SetWidth(cols[column].width)
  cellFrame.text:SetWidth(cols[column].width - 8)
  cellFrame.text:SetText(celldata and celldata.value or "")
  local color = (celldata and celldata.color) or WHITE
  cellFrame.text:SetTextColor(color.r, color.g, color.b, color.a)
end

local function recordsTable()
  if DataSync and DataSync.db then
    local g = DataSync.db.global
    g.bonusRolls = g.bonusRolls or {}
    return g.bonusRolls
  end
  return nil
end

function addon:StoreRecord(name, record)
  if not name or not record then
    return
  end
  local records = recordsTable()
  if not records then
    return
  end
  local existing = records[name] or {}
  records[name] = {
    left = record.left,
    earned = record.earned,
    cap = record.cap,
    updatedAt = record.updatedAt,
    classId = record.classId or existing.classId,
  }
end

function addon:StoreClassId(name, classId)
  if not name or type(classId) ~= "number" or classId <= 0 then
    return
  end
  local records = recordsTable()
  if not records then
    return
  end
  local existing = records[name]
  if existing then
    existing.classId = classId
  else
    records[name] = { classId = classId }
  end
end

function addon:GetRecord(name)
  local records = recordsTable()
  if not records then
    return nil
  end
  return records[name]
end

function addon:GetLocalRecord()
  local info = C_CurrencyInfo.GetCurrencyInfo(CURRENCY_ID)
  if not info then
    return nil
  end

  local _, _, classId = UnitClass("player")
  local record = {
    left = info.quantity or 0,
    earned = info.totalEarned or 0,
    cap = info.maxQuantity or 0,
    updatedAt = time(),
    classId = classId,
  }

  local name = playerFullName()
  if name then
    addon:StoreRecord(name, record)
  end

  return record
end

function addon:GetGroupChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  elseif IsInRaid() then
    return "RAID"
  elseif IsInGroup() then
    return "PARTY"
  end
  return nil
end

function addon:SerializePayload(payload)
  return self:Serialize(payload)
end

function addon:DeserializePayload(msg)
  local ok, payload = self:Deserialize(msg)
  if not ok or type(payload) ~= "table" then
    return nil
  end
  return payload
end

function addon:SendPayload(distribution, target, payload)
  local serialized = addon:SerializePayload(payload)
  if not serialized then
    return
  end
  self:SendCommMessage(COMM_PREFIX, serialized, distribution, target)
end

function addon:RequestData(force)
  local now = GetTime()
  if not force and (now - lastRequestAt) < REQUEST_DEBOUNCE then
    return
  end
  lastRequestAt = now

  addon:GetLocalRecord()

  local payload = { cmd = "REQ" }

  if IsInGuild() then
    addon:SendPayload("GUILD", nil, payload)
  end

  local groupChannel = addon:GetGroupChannel()
  if groupChannel then
    addon:SendPayload(groupChannel, nil, payload)
  end
end

function addon:ReplyWithLocalRecord(sender)
  if not sender or sender == "" then
    return
  end

  local selfName = playerFullName()
  local senderName = fullName(sender)
  if selfName and senderName and selfName == senderName then
    return
  end

  local record = addon:GetLocalRecord()
  if not record then
    return
  end

  addon:SendPayload("WHISPER", sender, {
    cmd = "RESP",
    left = record.left,
    earned = record.earned,
    cap = record.cap,
    updatedAt = record.updatedAt,
    classId = record.classId,
  })
end

function addon:OnCommReceived(_, msg, _, sender)
  local payload = addon:DeserializePayload(msg)
  if not payload or not payload.cmd then
    return
  end

  if payload.cmd == "REQ" then
    addon:ReplyWithLocalRecord(sender)
  elseif payload.cmd == "RESP" then
    local name = fullName(sender)
    if not name then
      return
    end

    addon:StoreRecord(name, {
      left = tonumber(payload.left) or 0,
      earned = tonumber(payload.earned) or 0,
      cap = tonumber(payload.cap) or 0,
      updatedAt = tonumber(payload.updatedAt) or time(),
      classId = tonumber(payload.classId),
    })

    if frameShown then
      addon:RefreshTable()
    end
  end
end

function addon:CollectCandidates()
  local candidates = {}
  local selfName = playerFullName()
  local selfRealm = GetNormalizedRealmName()

  local function addCandidate(name, online, level, classFileName, source)
    local normalized = fullName(name, selfRealm)
    if not normalized then
      return
    end

    local classId = classIdFromFile(classFileName)
    if classId then
      addon:StoreClassId(normalized, classId)
    end

    local existing = candidates[normalized]
    if existing then
      existing.online = existing.online or online
      existing.level = existing.level or level
      existing.classFileName = existing.classFileName or classFileName
      existing.classId = existing.classId or classId
      -- Prefer Group over Guild when someone appears in both
      if source == "Group" then
        existing.source = "Group"
      end
      return
    end

    candidates[normalized] = {
      name = normalized,
      online = online and true or false,
      level = level,
      classFileName = classFileName,
      classId = classId,
      source = source or "Guild",
    }
  end

  if selfName then
    local _, classFileName = UnitClass("player")
    addCandidate(selfName, true, UnitLevel("player"), classFileName, "Group")
  end

  local groupSize = GetNumGroupMembers() or 0
  if groupSize > 0 then
    local inRaid = IsInRaid()
    if inRaid then
      for i = 1, groupSize do
        local name, _, _, level, _, classFileName, _, online = GetRaidRosterInfo(i)
        if name then
          addCandidate(name, online ~= false, level, classFileName, "Group")
        end
      end
    else
      for i = 1, GetNumSubgroupMembers() do
        local unit = "party" .. i
        if UnitExists(unit) then
          local name, realm = UnitFullName(unit)
          local _, partyClassFile = UnitClass(unit)
          addCandidate(fullName(name, realm), UnitIsConnected(unit), UnitLevel(unit), partyClassFile, "Group")
        end
      end
    end
  end

  local maxLevel = maxPlayerLevel()
  local numGuildMembers = GetNumGuildMembers() or 0
  for i = 1, numGuildMembers do
    local name, _, _, level, _, _, _, _, isOnline, _, classFileName = GetGuildRosterInfo(i)
    if name and level and level >= maxLevel then
      local record = addon:GetRecord(fullName(name))
      local hasCoinData = record and record.left ~= nil
      if isOnline or hasCoinData then
        addCandidate(name, isOnline, level, classFileName, "Guild")
      end
    end
  end

  return candidates
end

function addon:BuildRows()
  local candidates = addon:CollectCandidates()
  local rows = {}

  for _, candidate in pairs(candidates) do
    local record = addon:GetRecord(candidate.name)
    local hasCoinData = record and record.left ~= nil
    local classId = (record and record.classId) or candidate.classId
    local classFile = candidate.classFileName or classFileFromId(classId)
    local nameColor = getClassColor(classFile)
    local displayName = Ambiguate(candidate.name, "guild")
    local source = candidate.source or "Guild"
    local row

    if hasCoinData then
      row = {
        name = candidate.name,
        cols = {
          { value = classFile or "", DoCellUpdate = SetCellClassIcon, args = { classFile } },
          { value = displayName, color = nameColor },
          { value = source, color = WHITE },
          { value = record.left, color = leftColor(record.left) },
          { value = tostring(record.earned), color = earnedColor(record.earned, record.cap) },
          { value = tostring(record.cap), color = WHITE },
          { value = formatUpdatedAt(record.updatedAt), color = WHITE },
        },
      }
    elseif candidate.online then
      row = {
        name = candidate.name,
        cols = {
          { value = classFile or "", DoCellUpdate = SetCellClassIcon, args = { classFile } },
          { value = displayName, color = nameColor },
          { value = source, color = WHITE },
          { value = -1, color = GREY, colspan = DATA_COLSPAN },
          { value = "" },
          { value = "" },
          { value = "" },
        },
      }
    else
      row = nil
    end

    if row then
      table.insert(rows, row)
    end
  end

  return rows
end

function addon:RefreshTable()
  if not coinsTable then
    return
  end

  local rows = addon:BuildRows()
  coinsTable:SetData(rows)

  if frame then
    frame:SetStatusText(string.format("%d player(s)", #rows))
  end
end

function addon:CreateCoinsTable()
  if coinsTable or not coinsTableHost then
    return
  end

  local columns = {
    { name = "", width = 20, DoCellUpdate = SetCellClassIcon },
    { name = "Name", width = 140 },
    { name = "Source", width = 60, align = "CENTER", sort = ScrollingTable.SORT_ASC, sortnext = 4 },
    { name = "Left", width = 50, align = "CENTER", DoCellUpdate = SetCellLeft, defaultsort = ScrollingTable.SORT_DSC },
    { name = "Earned", width = 50, align = "CENTER", DoCellUpdate = SetCellData },
    { name = "Cap", width = 50, align = "CENTER", DoCellUpdate = SetCellData },
    { name = "Updated at", width = 100, align = "CENTER", DoCellUpdate = SetCellData },
  }

  coinsTable = ScrollingTable:CreateST(columns, 17, 18, nil, coinsTableHost.frame)
  coinsTable:SetDefaultHighlight(0.20, 0.45, 0.75, 0.22)
  coinsTable:SetDefaultHighlightBlank(0.0, 0.0, 0.0, 0.0)
  coinsTable.frame:SetPoint("TOPLEFT", coinsTableHost.frame, "TOPLEFT", 0, -22)
  coinsTable:EnableSelection(false)
  coinsTable:SetData({})
end

function addon:ShowWindow()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  end

  addon:GetLocalRecord()

  if frame then
    frameShown = true
    addon:RefreshTable()
    addon:RequestData(false)
    frame:Show()
    frame.frame:Raise()
    return
  end

  frame = AceGUI:Create("Frame")
  frame:SetTitle("Wowaudit Bonus Rolls")
  frame:SetLayout("List")
  frame:SetWidth(540)
  frame:SetHeight(420)
  frame:EnableResize(false)
  frame.frame:SetFrameStrata("MEDIUM")
  frame.frame:Raise()
  frame.content:SetFrameStrata("MEDIUM")
  frame.content:Raise()
  frameShown = true

  local closeButton = nil
  for _, child in ipairs({ frame.frame:GetChildren() }) do
    if child.GetText and child:GetText() == CLOSE then
      closeButton = child
      break
    end
  end

  local refreshButton = CreateFrame("Button", nil, frame.frame, "UIPanelButtonTemplate")
  refreshButton:SetText("Refresh")
  refreshButton:SetSize(80, 20)
  if closeButton then
    refreshButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
  else
    refreshButton:SetPoint("BOTTOMRIGHT", frame.frame, "BOTTOMRIGHT", -132, 17)
  end
  refreshButton:SetScript("OnClick", function()
    addon:GetLocalRecord()
    addon:RefreshTable()
    addon:RequestData(true)
  end)

  local statusBar = frame.statustext and frame.statustext:GetParent()
  if statusBar then
    statusBar:ClearAllPoints()
    statusBar:SetPoint("BOTTOMLEFT", 15, 15)
    statusBar:SetPoint("RIGHT", refreshButton, "LEFT", -6, 0)
  end

  coinsTableHost = AceGUI:Create("SimpleGroup")
  coinsTableHost:SetFullWidth(true)
  coinsTableHost:SetHeight(338)
  coinsTableHost:SetLayout("Fill")
  if coinsTableHost.frame.SetClipsChildren then
    coinsTableHost.frame:SetClipsChildren(true)
  end
  frame:AddChild(coinsTableHost)

  addon:CreateCoinsTable()
  addon:RefreshTable()
  addon:RequestData(true)

  frame:SetCallback("OnClose", function()
    if coinsTable then
      coinsTable:SetData({})
    end
    frameShown = false
  end)
end

function addon:OnZoneChanged()
  if not WowauditCompanionAdmin then
    return
  end
  if self.autoRefreshTimer then
    self:CancelTimer(self.autoRefreshTimer)
  end
  self.autoRefreshTimer = self:ScheduleTimer("AutoRefresh", AUTO_REFRESH_DELAY)
end

function addon:AutoRefresh()
  self.autoRefreshTimer = nil
  addon:RequestData(true)
end

function addon:OnInitialize()
  self:RegisterComm(COMM_PREFIX)
end

function addon:OnEnable()
  addon:GetLocalRecord()
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneChanged")
  self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneChanged")
end
