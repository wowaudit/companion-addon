Wit = LibStub("AceAddon-3.0"):NewAddon("Wowaudit Invite Tool", "AceTimer-3.0")
local addon = Wit
local AceGUI = LibStub("AceGUI-3.0")
local ScrollingTable = LibStub("ScrollingTable")
local notInSetup
local frame
local frameShown
local editbox
local strategyButtons = {}
local encounterTable
local encounterTableHost
local rawInputText
local encounters
local inviteToolDefaults = {
  pastedText = "",
}
local inviteStrategies = {
  { key = "invite_only", label = "Invite only" },
  { key = "replace", label = "Invite & remove" },
  { key = "rearrange", label = "Invite & rearrange" },
}
local selectedStrategyIndex = 1

local function updateInviteActionCellStyle(cellFrame, isHovered)
  if not cellFrame then
    return
  end

  if not cellFrame.inviteActionButton then
    local actionButton = CreateFrame("Button", nil, cellFrame, "UIPanelButtonTemplate")
    actionButton:SetPoint("CENTER", cellFrame, "CENTER", 0, 0)
    actionButton:SetSize(70, 16)
    actionButton:SetText("Invite")
    actionButton:EnableMouse(false)
    actionButton:SetFrameLevel(cellFrame:GetFrameLevel() + 1)
    cellFrame.inviteActionButton = actionButton
  end

  local actionButton = cellFrame.inviteActionButton
  if isHovered then
    actionButton:LockHighlight()
  else
    actionButton:UnlockHighlight()
  end
end

local function inviteActionCellUpdate(_, cellFrame, data, _, _, realrow, column, fShow, tableRef)
  if not fShow then
    if cellFrame and cellFrame.inviteActionButton then
      cellFrame.inviteActionButton:Hide()
    end
    if cellFrame and cellFrame.text then
      cellFrame.text:SetText("")
    end
    return
  end

  cellFrame.text:SetText("")
  cellFrame.inviteActionHovered = false
  updateInviteActionCellStyle(cellFrame, false)
  cellFrame.inviteActionButton:Show()
end

local function trim(text)
  if not text then
    return ""
  end

  return text:match("^%s*(.-)%s*$")
end

function addon:NormalizeInviteList(invitelistText)
  local cleanedText = trim((invitelistText or ""):gsub("|", " "))
  cleanedText = cleanedText:gsub("%s+", " ")

  if cleanedText == "" then
    return ""
  end

  return cleanedText:gsub(" ", "\n")
end

function addon:EnsureInviteToolDB()
  if type(WowauditInviteToolDB) ~= "table" then
    WowauditInviteToolDB = {}
  end

  if type(WowauditInviteToolDB.pastedText) ~= "string" then
    WowauditInviteToolDB.pastedText = inviteToolDefaults.pastedText
  end

  return WowauditInviteToolDB
end

function addon:GetPersistedInviteText()
  local db = addon:EnsureInviteToolDB()
  return db.pastedText
end

function addon:SetPersistedInviteText(text)
  local db = addon:EnsureInviteToolDB()
  db.pastedText = text or ""
end

function addon:ApplyInviteInputText(text)
  rawInputText = text or ""
  encounters = addon:ParseEncounterPayload(rawInputText)
  addon:RefreshEncounterTable()

  if frame then
    if rawInputText == "" then
      frame:SetStatusText("")
    else
      frame:SetStatusText(string.format("Found %d encounter(s)", #encounters))
    end
  end
end

function addon:RestorePersistedInviteText()
  local persistedText = addon:GetPersistedInviteText()

  if editbox then
    editbox:SetText(persistedText)
  end

  addon:ApplyInviteInputText(persistedText)
end

function addon:GetRosterSnapshot()
  local rosterLookup = {}
  local groupSize = GetNumGroupMembers() or 0
  local selfName, selfRealm = UnitFullName("player")
  local playerFullName = nil
  if selfName and selfRealm then
    playerFullName = selfName .. "-" .. selfRealm
  end

  for i = 1, groupSize do
    local name = GetRaidRosterInfo(i)
    if name and not string.find(name, "-") and selfRealm then
      name = name .. "-" .. selfRealm
    end
    if name then
      rosterLookup[name] = true
    end
  end

  return rosterLookup, selfRealm, playerFullName
end

function addon:GetEncounterDeltaCounts(inviteString, rosterLookup, fallbackRealm, playerFullName)
  local inviteLookup = {}
  local toInvite = 0
  local toRemove = 0

  for inviteTarget in string.gmatch(inviteString or "", "([^\n]+)") do
    local normalizedInviteTarget = trim(inviteTarget)
    if normalizedInviteTarget ~= "" and not string.find(normalizedInviteTarget, "-") and fallbackRealm then
      normalizedInviteTarget = normalizedInviteTarget .. "-" .. fallbackRealm
    end

    if normalizedInviteTarget ~= "" and not inviteLookup[normalizedInviteTarget] then
      inviteLookup[normalizedInviteTarget] = true
      if normalizedInviteTarget ~= playerFullName and not rosterLookup[normalizedInviteTarget] then
        toInvite = toInvite + 1
      end
    end
  end

  for rosterName, _ in pairs(rosterLookup) do
    if rosterName ~= playerFullName and not inviteLookup[rosterName] then
      toRemove = toRemove + 1
    end
  end

  return toInvite, toRemove
end

function addon:GetEncounterLabel(encounter)
  return encounter.name or "Unknown Encounter"
end

function addon:GetDifficultyShortLabel(encounter)
  local difficultyText = trim(encounter.difficulty or "")
  if difficultyText == "" then
    return "?"
  end
  return difficultyText
end

function addon:ParseEncounterPayload(payloadText)
  local parsedEncounters = {}
  local currentEncounter = nil
  local normalizedPayload = (payloadText or ""):gsub("\r\n", "\n")

  for rawLine in string.gmatch(normalizedPayload, "([^\n]+)") do
    local line = trim(rawLine)

    if line ~= "" then
      local _, difficulty, encounterName = line:match("^EncounterID:([^;]+);Difficulty:([^;]+);Name:(.+)$")
      if difficulty and encounterName then
        currentEncounter = {
          name = trim(encounterName),
          difficulty = trim(difficulty),
          inviteString = "",
          hasInviteList = false,
          label = "",
        }
        table.insert(parsedEncounters, currentEncounter)
      else
        local inviteListText = line:match("^invitelist:(.*);$")
        if inviteListText and currentEncounter and not currentEncounter.hasInviteList then
          currentEncounter.inviteString = addon:NormalizeInviteList(inviteListText)
          currentEncounter.hasInviteList = true
          currentEncounter.label = addon:GetEncounterLabel(currentEncounter)
        end
      end
    end
  end

  for _, encounter in ipairs(parsedEncounters) do
    if encounter.label == "" then
      encounter.label = addon:GetEncounterLabel(encounter)
    end
  end

  return parsedEncounters
end

function addon:RefreshEncounterTable()
  if not encounterTable then
    return
  end

  local rosterLookup, fallbackRealm, playerFullName = addon:GetRosterSnapshot()
  local tableData = {}
  for _, encounter in ipairs(encounters or {}) do
    local toInvite, toRemove = addon:GetEncounterDeltaCounts(encounter.inviteString, rosterLookup, fallbackRealm, playerFullName)
    table.insert(tableData, {
      encounterName = encounter.label,
      inviteString = encounter.inviteString,
      cols = {
        encounter.label,
        addon:GetDifficultyShortLabel(encounter),
        {
          value = tostring(toInvite),
          color = toInvite > 0 and { r = 0.45, g = 0.90, b = 0.45, a = 1.0 } or { r = 0.78, g = 0.78, b = 0.78, a = 1.0 },
        },
        {
          value = tostring(toRemove),
          color = toRemove > 0 and { r = 1.00, g = 0.45, b = 0.45, a = 1.0 } or { r = 0.78, g = 0.78, b = 0.78, a = 1.0 },
        },
        {
          value = "Invite",
          color = { r = 0.2, g = 0.8, b = 1.0, a = 1.0 },
        },
      },
    })
  end

  encounterTable:SetData(tableData)
end

function addon:UpdateStrategyButtonText()
  for index, strategy in ipairs(inviteStrategies) do
    local button = strategyButtons[index]
    if button then
      local isActive = index == selectedStrategyIndex
      button:SetText(strategy.label)
      if button.text then
        button.text:SetTextColor(1, 1, 1, 1)
      end

      if button.frame then
        if isActive then
          button.frame:LockHighlight()
        else
          button.frame:UnlockHighlight()
        end

        local tint = isActive and 1.0 or 0.62
        for _, region in ipairs({ button.frame:GetRegions() }) do
          if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            if region.SetDesaturated then
              region:SetDesaturated(not isActive)
            end
            region:SetVertexColor(tint, tint, tint)
          end
        end
      end
    end
  end
end

function addon:SetStrategy(index)
  selectedStrategyIndex = index
  addon:UpdateStrategyButtonText()
end

function addon:RunStrategyForEncounter(inviteString)
  local strategy = inviteStrategies[selectedStrategyIndex]
  if strategy.key == "replace" then
    addon:Replace(inviteString)
  elseif strategy.key == "rearrange" then
    addon:InviteAndRearrange(inviteString)
  else
    addon:InviteOnly(inviteString)
  end
end

function addon:CreateEncounterTable()
  if encounterTable or not encounterTableHost then
    return
  end

  local columns = {
    { name = "Encounter", width = 162 },
    { name = "Difficulty", width = 64, align = "CENTER" },
    { name = "To invite", width = 58, align = "CENTER" },
    { name = "To remove", width = 58, align = "CENTER" },
    { name = "Action", width = 74, align = "CENTER", DoCellUpdate = inviteActionCellUpdate },
  }

  encounterTable = ScrollingTable:CreateST(columns, 10, 18, nil, encounterTableHost.frame)
  encounterTable:SetDefaultHighlight(0.20, 0.45, 0.75, 0.22)
  encounterTable:SetDefaultHighlightBlank(0.0, 0.0, 0.0, 0.0)
  -- ScrollingTable draws header labels above its frame; reserve space so they do not overlap controls above.
  encounterTable.frame:SetPoint("TOPLEFT", encounterTableHost.frame, "TOPLEFT", 0, -22)
  encounterTable.frame:SetPoint("BOTTOMRIGHT", encounterTableHost.frame, "BOTTOMRIGHT", 0, 0)
  encounterTable:RegisterEvents({
    ["OnEnter"] = function(rowFrame, cellFrame, _, _, row, realrow, column, tableRef)
      if row and realrow then
        tableRef:SetHighLightColor(rowFrame, tableRef:GetDefaultHighlight())
      end

      if row and column == 5 then
        cellFrame.inviteActionHovered = true
        updateInviteActionCellStyle(cellFrame, true)
      end

      return true
    end,
    ["OnLeave"] = function(rowFrame, cellFrame, _, _, row, realrow, column, tableRef)
      if row and realrow then
        tableRef:SetHighLightColor(rowFrame, tableRef:GetDefaultHighlightBlank())
      end

      if row and column == 5 then
        cellFrame.inviteActionHovered = false
        updateInviteActionCellStyle(cellFrame, false)
      end

      return true
    end,
    ["OnClick"] = function(_, _, data, _, row, realrow, column, _, button)
      if row and realrow and column == 5 and button == "LeftButton" then
        local rowData = data[realrow]
        if rowData then
          addon:RunStrategyForEncounter(rowData.inviteString)
        end

        return true
      end

      return false
    end,
  }, true)
  encounterTable:EnableSelection(false)
  encounterTable:SetData({})
end

function addon:ResetInput()
  rawInputText = ""
  encounters = {}
  addon:SetPersistedInviteText("")

  if editbox then
    editbox:SetText("")
  end

  addon:RefreshEncounterTable()

  if frame then
    frame:SetStatusText("")
  end
end

function addon:CreateFrame()
  if frame then
    frameShown = true
    addon:RestorePersistedInviteText()
    frame:Show()
    frame.frame:Raise()
    return
  else
    frame = AceGUI:Create("Frame")
    frame:SetTitle("Wowaudit Invite Tool")
    frame:SetLayout("List")
    frame:SetWidth(480)
    frame:SetHeight(440)
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

    local resetButton = CreateFrame("Button", nil, frame.frame, "UIPanelButtonTemplate")
    resetButton:SetText("Reset")
    resetButton:SetSize(70, 20)
    if closeButton then
      resetButton:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
    else
      resetButton:SetPoint("BOTTOMRIGHT", frame.frame, "BOTTOMRIGHT", -132, 17)
    end
    resetButton:SetScript("OnClick", function() addon:ResetInput() end)

    local statusBar = frame.statustext and frame.statustext:GetParent()
    if statusBar then
      statusBar:ClearAllPoints()
      statusBar:SetPoint("BOTTOMLEFT", 15, 15)
      statusBar:SetPoint("RIGHT", resetButton, "LEFT", -6, 0)
    end

    local horizontalGroup = AceGUI:Create("SimpleGroup")
    horizontalGroup:SetFullWidth(true)
    horizontalGroup:SetLayout("Flow")

    local editBoxGroup = AceGUI:Create("SimpleGroup")
    editBoxGroup:SetWidth(460)
    editBoxGroup:SetLayout("Fill")

    editbox = AceGUI:Create("MultiLineEditBox")
    editbox:SetLabel("Paste event note or invite string here:")
    editbox:SetFullWidth(true)
    editbox:SetNumLines(7)
    editbox:SetCallback("OnTextChanged", function(_, _, text)
      local latestText = text or ""
      addon:ApplyInviteInputText(latestText)
      addon:SetPersistedInviteText(latestText)
    end)
    editbox:DisableButton(true)
    editBoxGroup:AddChild(editbox)


    horizontalGroup:AddChild(editBoxGroup)

    frame:AddChild(horizontalGroup)

    local strategyLabelGroup = AceGUI:Create("SimpleGroup")
    strategyLabelGroup:SetFullWidth(true)
    strategyLabelGroup:SetHeight(18)
    strategyLabelGroup:SetLayout("Fill")
    frame:AddChild(strategyLabelGroup)

    local strategyLabel = strategyLabelGroup.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    strategyLabel:SetFontObject(GameFontHighlightSmall)
    strategyLabel:SetPoint("CENTER", strategyLabelGroup.frame, "CENTER", 0, 0)
    strategyLabel:SetTextColor(1, 1, 1, 1)
    strategyLabel:SetText("Choose invite mode")

    local strategyGroup = AceGUI:Create("SimpleGroup")
    strategyGroup:SetFullWidth(true)
    strategyGroup:SetHeight(30)
    strategyGroup:SetLayout("Flow")
    frame:AddChild(strategyGroup)

    strategyButtons = {}
    for index, strategy in ipairs(inviteStrategies) do
      local button = AceGUI:Create("Button")
      button:SetText(strategy.label)
      button:SetWidth(146)
      button:SetCallback("OnClick", function() addon:SetStrategy(index) end)
      strategyGroup:AddChild(button)
      strategyButtons[index] = button
    end

    encounterTableHost = AceGUI:Create("SimpleGroup")
    encounterTableHost:SetFullWidth(true)
    encounterTableHost:SetHeight(225)
    encounterTableHost:SetLayout("Fill")
    frame:AddChild(encounterTableHost)

    rawInputText = ""
    encounters = {}
    notInSetup = ""
    selectedStrategyIndex = 1
    addon:UpdateStrategyButtonText()
    addon:CreateEncounterTable()
    addon:RestorePersistedInviteText()

    frame:SetCallback("OnClose", function(widget)
      if encounterTable then
        encounterTable:SetData({})
      end

      frameShown = false
    end)
  end
end

function addon:Replace(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  addon:Uninvite(false, selectedInviteString)
  addon:Invite(selectedInviteString)
end

function addon:InviteAndRearrange(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  addon:Uninvite(true, selectedInviteString)
  addon:InviteOnly(selectedInviteString)
end

function addon:InviteOnly(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  notInSetup = ""
  addon:Invite(selectedInviteString)

  if (string.len(notInSetup) > 0) then
    print("These players are not in the setup but haven't been removed: "..notInSetup:sub(1, -3))
  end
end

function addon:Uninvite(moveOnly, selectedInviteString)
  local moveToEnd = {}
  local playersInGroup = {}
  local currentInviteString = selectedInviteString or ""
  if not (string.len(currentInviteString) > 0) then
    return
  end

  -- Uninvite raid members not in the string
  local rosterSize = GetNumGroupMembers() or 0
	local myName, myRealm = UnitFullName("player")
	for j=rosterSize,1,-1 do
		local nown = GetNumGroupMembers() or 0
		if nown > 0 then
      local name, rank, subgroup = GetRaidRosterInfo(j)
      if name and not string.find(name, "-") then
        name = name.."-"..myRealm
      end

      local playerInfo = {}

      -- Store raid group status
      if name then
        playerInfo['name'] = name
        playerInfo['subgroup'] = subgroup
        playerInfo['index'] = j
        playersInGroup[subgroup] = (playersInGroup[subgroup] or {})
        table.insert(playersInGroup[subgroup], playerInfo)
      end

			if name then
        local shouldRemain = false
        for inviteTarget in string.gmatch(currentInviteString, "([^\n]+)") do
          if inviteTarget == name then
            shouldRemain = true
          end
        end

        if moveOnly and not shouldRemain then
          table.insert(moveToEnd, playerInfo)
        end

        if not shouldRemain then
          if moveOnly then
            notInSetup = notInSetup..name..", "
          elseif name ~= myName then
            local nameWithoutRealm, playerRealm = unpack(split(name, "-"))

            if playerRealm == myRealm then
              UninviteUnit(nameWithoutRealm)
            else
              UninviteUnit(name)
            end
          end
        end
			end
		end
	end

  if moveOnly then
    -- First move unbenched players to the start
    for group=8,1,-1 do
      if playersInGroup[group] then
        for k, player in pairs(playersInGroup[group]) do
          local currentTargetGroup = 1
          local searching = true

          while searching do
            if currentTargetGroup >= player.subgroup then
              searching = false
            elseif playersInGroup[currentTargetGroup] and (addon:Tablelength(playersInGroup[currentTargetGroup]) > 4) then
              currentTargetGroup = currentTargetGroup + 1
            else
              local onBench = false
              for _,p in pairs(moveToEnd) do
                if p.name == player.name then
                  onBench = true
                  searching = false
                  break
                end
              end

              if not onBench then
                SetRaidSubgroup(player.index, currentTargetGroup)
                player.subgroup = currentTargetGroup
                playersInGroup[group][k] = nil
                playersInGroup[currentTargetGroup] = (playersInGroup[currentTargetGroup] or {})
                table.insert(playersInGroup[currentTargetGroup], player)
                searching = false
              end
            end
          end
        end
      end
    end

    -- Then move benched players to the end
    for k, player in pairs(moveToEnd) do
      local searching = true
      local currentTargetGroup = 8

      while searching do
        if playersInGroup[currentTargetGroup] and (addon:Tablelength(playersInGroup[currentTargetGroup]) > 4) then
          currentTargetGroup = currentTargetGroup - 1
        else
          SetRaidSubgroup(player.index, currentTargetGroup)
          playersInGroup[currentTargetGroup] = (playersInGroup[currentTargetGroup] or {})
          table.insert(playersInGroup[currentTargetGroup], player)
          searching = false
        end
      end
    end
  end
end

function addon:Tablelength(T)
  local count = 0
  for _ in pairs(T) do count = count + 1 end
  return count
end

function addon:Invite(selectedInviteString)
  local groupSize = GetNumGroupMembers()
  local alreadyInGroup = {}
  local currentInviteString = selectedInviteString or ""
  if groupSize ~= 0 then
    for i=1,groupSize do
      local name = GetRaidRosterInfo(i)
      table.insert(alreadyInGroup, name)
    end
  end

  local selfName, selfRealm = UnitFullName("player")
  -- Invite raid members in the string
  for inviteTarget in string.gmatch(currentInviteString, "([^\n]+)") do
    if not tableContains(alreadyInGroup, inviteTarget) then
      if inviteTarget ~= selfName .. "-" .. selfRealm then
        C_PartyInfo.InviteUnit(inviteTarget)
      end
    end
  end
end

function split(input, separator)
  if separator == nil then
    separator = "%s"
  end
  local t={}
  for str in string.gmatch(input, "([^"..separator.."]+)") do
    table.insert(t, str)
  end
  return t
end


function tableContains(testTable, value)
  for i = 1,#testTable do
    if (testTable[i] == value) then
      return true
    end
  end
  return false
end
