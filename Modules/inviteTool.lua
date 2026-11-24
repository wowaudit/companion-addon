Wit = LibStub("AceAddon-3.0"):NewAddon("Wowaudit Invite Tool", "AceTimer-3.0")
local addon = Wit
local AceGUI = LibStub("AceGUI-3.0")
local ScrollingTable = LibStub("ScrollingTable")
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

local INVITE_COLUMN = 5
local ARRANGE_COLUMN = 6

local function updateActionCellStyle(cellFrame, isHovered)
  if not cellFrame or not cellFrame.actionButton then
    return
  end

  local actionButton = cellFrame.actionButton
  if isHovered and actionButton:IsEnabled() then
    actionButton:LockHighlight()
  else
    actionButton:UnlockHighlight()
  end
end

local function actionCellUpdate(label, isEnabled)
  return function(_, cellFrame, data, _, _, realrow, column, fShow, tableRef)
    if not fShow then
      if cellFrame and cellFrame.actionButton then
        cellFrame.actionButton:Hide()
      end
      if cellFrame and cellFrame.text then
        cellFrame.text:SetText("")
      end
      return
    end

    if not cellFrame.actionButton then
      local actionButton = CreateFrame("Button", nil, cellFrame, "UIPanelButtonTemplate")
      actionButton:SetPoint("CENTER", cellFrame, "CENTER", 0, 0)
      actionButton:SetSize(70, 16)
      actionButton:EnableMouse(false)
      actionButton:SetFrameLevel(cellFrame:GetFrameLevel() + 1)
      cellFrame.actionButton = actionButton
    end

    local rowData = data and realrow and data[realrow]
    cellFrame.text:SetText("")
    cellFrame.actionButton:SetText(label)
    cellFrame.actionButton:SetEnabled(not isEnabled or (rowData and isEnabled(rowData)) or false)
    updateActionCellStyle(cellFrame, false)
    cellFrame.actionButton:Show()
  end
end

local function hasPositionalSlots(rowData)
  return rowData.slots ~= nil
end

local function trim(text)
  if not text then
    return ""
  end

  return text:match("^%s*(.-)%s*$")
end

-- Matches the NSRT format: a list containing "," or ";" is positional (5 fields
-- per group, empty fields keep a position free), otherwise names are separated
-- by whitespace. Older wowaudit notes ended a whitespace list with a single ";".
function addon:ParseInviteList(invitelistText)
  local text = trim(invitelistText or "")
  local legacyText = text:gsub(";$", "")
  local isPositional = text:find(",", 1, true) or legacyText:find(";", 1, true)
  local names = {}

  if not isPositional then
    for name in legacyText:gmatch("([^%s]+)") do
      table.insert(names, name)
    end
    return names, nil
  end

  local slots = {}
  for field in (text:gsub(";", ",") .. ","):gmatch("(.-),") do
    local name = trim(field)
    table.insert(slots, name)
    if name ~= "" then
      table.insert(names, name)
    end
  end
  return names, slots
end

local function parseEncounterHeader(line)
  if not line:match("^EncounterID:") then
    return nil
  end

  local difficulty = line:match(";Difficulty:([^;]+)")
  local encounterName = line:match(";Name:(.-);%a+:") or line:match(";Name:(.+)$")
  if not difficulty or not encounterName then
    return nil
  end
  return trim(difficulty), trim(encounterName)
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
      local difficulty, encounterName = parseEncounterHeader(line)
      if difficulty and encounterName then
        currentEncounter = {
          name = encounterName,
          difficulty = difficulty,
          inviteString = "",
          inviteNames = {},
          slots = nil,
          hasInviteList = false,
          label = "",
        }
        table.insert(parsedEncounters, currentEncounter)
      else
        local inviteListText = line:match("^invitelist:%s*(.*)$")
        if inviteListText and not currentEncounter then
          currentEncounter = {
            name = "Invite list",
            difficulty = "",
            inviteString = "",
            inviteNames = {},
            slots = nil,
            hasInviteList = false,
            label = "",
          }
          table.insert(parsedEncounters, currentEncounter)
        end
        if inviteListText and not currentEncounter.hasInviteList then
          local names, slots = addon:ParseInviteList(inviteListText)
          currentEncounter.inviteNames = names
          currentEncounter.inviteString = table.concat(names, "\n")
          currentEncounter.slots = slots
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
      inviteNames = encounter.inviteNames,
      slots = encounter.slots,
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
        {
          value = "Arrange",
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

function addon:RunStrategyForEncounter(rowData)
  local strategy = inviteStrategies[selectedStrategyIndex]
  if strategy.key == "replace" then
    addon:Replace(rowData.inviteString)
  elseif strategy.key == "rearrange" then
    addon:InviteAndRearrange(rowData.inviteString, rowData.slots or rowData.inviteNames, hasPositionalSlots(rowData))
  else
    addon:InviteOnly(rowData.inviteString)
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
    { name = "Action", width = 74, align = "CENTER", DoCellUpdate = actionCellUpdate("Invite") },
    { name = "Arrange", width = 74, align = "CENTER", DoCellUpdate = actionCellUpdate("Arrange", hasPositionalSlots) },
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

      if row and (column == INVITE_COLUMN or column == ARRANGE_COLUMN) then
        updateActionCellStyle(cellFrame, true)
      end

      return true
    end,
    ["OnLeave"] = function(rowFrame, cellFrame, _, _, row, realrow, column, tableRef)
      if row and realrow then
        tableRef:SetHighLightColor(rowFrame, tableRef:GetDefaultHighlightBlank())
      end

      if row and (column == INVITE_COLUMN or column == ARRANGE_COLUMN) then
        updateActionCellStyle(cellFrame, false)
      end

      return true
    end,
    ["OnClick"] = function(_, _, data, _, row, realrow, column, _, button)
      if row and realrow and column == INVITE_COLUMN and button == "LeftButton" then
        local rowData = data[realrow]
        if rowData then
          addon:RunStrategyForEncounter(rowData)
        end

        return true
      end

      if row and realrow and column == ARRANGE_COLUMN and button == "LeftButton" then
        local rowData = data[realrow]
        if rowData and hasPositionalSlots(rowData) then
          WowauditGroupArranger:Start(rowData.slots)
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
    frame:SetWidth(560)
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
    editBoxGroup:SetWidth(540)
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
      button:SetWidth(174)
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
  addon:Uninvite(selectedInviteString)
  addon:Invite(selectedInviteString)
end

function addon:InviteAndRearrange(selectedInviteString, slots, exactPositions)
  C_PartyInfo.ConvertToRaid()
  addon:Invite(selectedInviteString)
  addon:PrintNotInSetup(selectedInviteString)
  WowauditGroupArranger:Start(slots, { watch = true, exactPositions = exactPositions })
end

function addon:InviteOnly(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  addon:Invite(selectedInviteString)
  addon:PrintNotInSetup(selectedInviteString)
end

function addon:GetInviteLookup(selectedInviteString, fallbackRealm)
  local inviteLookup = {}
  for inviteTarget in string.gmatch(selectedInviteString or "", "([^\n]+)") do
    local name = trim(inviteTarget)
    if name ~= "" and not string.find(name, "-", 1, true) and fallbackRealm then
      name = name .. "-" .. fallbackRealm
    end
    if name ~= "" then
      inviteLookup[name] = true
    end
  end
  return inviteLookup
end

function addon:PrintNotInSetup(selectedInviteString)
  local rosterLookup, fallbackRealm, playerFullName = addon:GetRosterSnapshot()
  local inviteLookup = addon:GetInviteLookup(selectedInviteString, fallbackRealm)

  local notListed = {}
  for rosterName, _ in pairs(rosterLookup) do
    if rosterName ~= playerFullName and not inviteLookup[rosterName] then
      table.insert(notListed, rosterName)
    end
  end
  if #notListed > 0 then
    print("These players are not in the setup but haven't been removed: " .. table.concat(notListed, ", "))
  end
end

function addon:Uninvite(selectedInviteString)
  if (selectedInviteString or "") == "" then
    return
  end

  local rosterLookup, myRealm, playerFullName = addon:GetRosterSnapshot()
  local inviteLookup = addon:GetInviteLookup(selectedInviteString, myRealm)
  for name, _ in pairs(rosterLookup) do
    if name ~= playerFullName and not inviteLookup[name] then
      local nameWithoutRealm, playerRealm = strsplit("-", name, 2)
      if playerRealm == myRealm then
        UninviteUnit(nameWithoutRealm)
      else
        UninviteUnit(name)
      end
    end
  end
end

function addon:Invite(selectedInviteString)
  local rosterLookup, selfRealm, playerFullName = addon:GetRosterSnapshot()
  for inviteTarget in string.gmatch(selectedInviteString or "", "([^\n]+)") do
    local name = trim(inviteTarget)
    local normalizedName = name
    if not string.find(name, "-", 1, true) and selfRealm then
      normalizedName = name .. "-" .. selfRealm
    end
    if name ~= "" and normalizedName ~= playerFullName and not rosterLookup[normalizedName] then
      C_PartyInfo.InviteUnit(name)
    end
  end
end
