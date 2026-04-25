Wit = LibStub("AceAddon-3.0"):NewAddon("Wowaudit Invite Tool", "AceTimer-3.0")
local addon = Wit
local AceGUI = LibStub("AceGUI-3.0")
local ScrollingTable = LibStub("ScrollingTable")
local invitingPreview
local uninvitingPreview
local notInSetup
local frame
local frameShown
local editbox
local strategyButton
local encounterTable
local encounterTableHost
local rawInputText
local encounters
local inviteStrategies = {
  { key = "invite_only", label = "Invite only" },
  { key = "replace", label = "Invite and remove" },
  { key = "rearrange", label = "Invite and rearrange" },
}
local selectedStrategyIndex = 1

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

function addon:GetInviteCount(inviteString)
  local count = 0

  for _ in string.gmatch(inviteString or "", "([^\n]+)") do
    count = count + 1
  end

  return count
end

function addon:GetEncounterLabel(encounter)
  local difficultyInitial = string.sub(encounter.difficulty or "", 1, 1)
  if difficultyInitial == "" then
    difficultyInitial = "?"
  end

  return string.format("%s (%s)", encounter.name or "Unknown Encounter", difficultyInitial)
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
          inviteCount = 0,
          label = "",
        }
        table.insert(parsedEncounters, currentEncounter)
      else
        local inviteListText = line:match("^invitelist:(.*);$")
        if inviteListText and currentEncounter and not currentEncounter.hasInviteList then
          currentEncounter.inviteString = addon:NormalizeInviteList(inviteListText)
          currentEncounter.hasInviteList = true
          currentEncounter.inviteCount = addon:GetInviteCount(currentEncounter.inviteString)
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

  local tableData = {}
  for _, encounter in ipairs(encounters or {}) do
    table.insert(tableData, {
      encounterName = encounter.label,
      inviteString = encounter.inviteString,
      cols = {
        encounter.label,
        tostring(encounter.inviteCount),
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
  if strategyButton then
    strategyButton:SetText("Mode: " .. inviteStrategies[selectedStrategyIndex].label)
  end
end

function addon:CycleStrategy()
  selectedStrategyIndex = selectedStrategyIndex + 1
  if selectedStrategyIndex > #inviteStrategies then
    selectedStrategyIndex = 1
  end

  addon:UpdateStrategyButtonText()
end

function addon:RunStrategyForEncounter(inviteString)
  local strategy = inviteStrategies[selectedStrategyIndex]
  if strategy.key == "replace" then
    addon:Replace(false, inviteString)
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
    { name = "Encounter", width = 238 },
    { name = "Players", width = 56, align = "CENTER" },
    { name = "Action", width = 90, align = "CENTER" },
  }

  encounterTable = ScrollingTable:CreateST(columns, 10, 18, nil, encounterTableHost.frame)
  encounterTable.frame:SetPoint("TOPLEFT", encounterTableHost.frame, "TOPLEFT", 0, -4)
  encounterTable.frame:SetPoint("BOTTOMRIGHT", encounterTableHost.frame, "BOTTOMRIGHT", 0, 0)
  encounterTable:RegisterEvents({
    ["OnClick"] = function(_, _, data, _, row, realrow, column, _, button)
      if row and realrow and column == 3 and button == "LeftButton" then
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

  if editbox then
    editbox:SetText("")
  end

  addon:RefreshEncounterTable()

  if frame then
    frame:SetStatusText("")
  end
end

function addon:CreateFrame()
  if frameShown then
    return
  else
    frame = AceGUI:Create("Frame")
    frame:SetTitle("Wowaudit Invite Tool")
    frame:SetLayout("List")
    frame:SetWidth(430)
    frame:SetHeight(400)
    frame:EnableResize(false)
    frame.frame:SetFrameStrata("MEDIUM")
    frame.frame:Raise()
    frame.content:SetFrameStrata("MEDIUM")
    frame.content:Raise()
    frameShown = true

    local horizontalGroup = AceGUI:Create("SimpleGroup")
    horizontalGroup:SetFullWidth(true)
    horizontalGroup:SetLayout("Flow")

    local editBoxGroup = AceGUI:Create("SimpleGroup")
    editBoxGroup:SetWidth(250)
    editBoxGroup:SetLayout("Fill")

    editbox = AceGUI:Create("MultiLineEditBox")
    editbox:SetLabel("Paste invite string here:")
    editbox:SetFullWidth(true)
    editbox:SetNumLines(7)
    editbox:SetCallback("OnTextChanged", function(_, _, text)
      rawInputText = text or ""
      encounters = addon:ParseEncounterPayload(rawInputText)
      addon:RefreshEncounterTable()

      if frame then
        frame:SetStatusText(string.format("Parsed %d encounter(s)", #encounters))
      end
    end)
    editbox:DisableButton(true)
    editBoxGroup:AddChild(editbox)


    local buttonGroup = AceGUI:Create("SimpleGroup")
    buttonGroup:SetWidth(160)
    buttonGroup:SetLayout("List")

    strategyButton = AceGUI:Create("Button")
    strategyButton:SetWidth(150)
    strategyButton:SetCallback("OnClick", function() addon:CycleStrategy() end)
    buttonGroup:AddChild(strategyButton)

    local resetButton = AceGUI:Create("Button")
    resetButton:SetText("Reset")
    resetButton:SetWidth(150)
    resetButton:SetCallback("OnClick", function() addon:ResetInput() end)
    buttonGroup:AddChild(resetButton)

    horizontalGroup:AddChild(editBoxGroup)
    horizontalGroup:AddChild(buttonGroup)

    frame:AddChild(horizontalGroup)

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

    frame:SetCallback("OnClose", function(widget)
      AceGUI:Release(widget)
      frameShown = false
      frame = nil
      editbox = nil
      strategyButton = nil
      encounterTable = nil
      encounterTableHost = nil
      rawInputText = ""
      encounters = {}
    end)
  end
end

function addon:Replace(preview, selectedInviteString)
  if not preview then
    C_PartyInfo.ConvertToRaid()
  end

  addon:Uninvite(preview, false, selectedInviteString)
  addon:Invite(preview, selectedInviteString)
end

function addon:InviteAndRearrange(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  addon:Uninvite(false, true, selectedInviteString)
  addon:InviteOnly(selectedInviteString)
end

function addon:InviteOnly(selectedInviteString)
  C_PartyInfo.ConvertToRaid()
  notInSetup = ""
  addon:Invite(false, selectedInviteString)

  if (string.len(notInSetup) > 0) then
    print("These players are not in the setup but haven't been removed: "..notInSetup:sub(1, -3))
  end
end

function addon:Uninvite(preview, moveOnly, selectedInviteString)
  invitingPreview = 0
  uninvitingPreview = 0
  local moveToEnd = {}
  local playersInGroup = {}
  local currentInviteString = selectedInviteString or ""
  if not (string.len(currentInviteString) > 0) then
    if frame then
      frame:SetStatusText("Removing "..uninvitingPreview.." | Inviting "..invitingPreview)
    end
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
            if preview then
              invitingPreview = invitingPreview - 1
            end
            shouldRemain = true
          end
        end

        if moveOnly and not shouldRemain then
          table.insert(moveToEnd, playerInfo)
        end

        if not shouldRemain then
          if preview or moveOnly then
            notInSetup = notInSetup..name..", "
            uninvitingPreview = uninvitingPreview + 1
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

  if moveOnly and not preview then
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

function addon:Invite(preview, selectedInviteString)
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
    if preview then
      invitingPreview = invitingPreview + 1
    else
      if not tableContains(alreadyInGroup, inviteTarget) then
        if inviteTarget ~= selfName .. "-" .. selfRealm then
          C_PartyInfo.InviteUnit(inviteTarget)
        end
      end
    end
  end

  if preview then
    if frame then
      frame:SetStatusText("Removing "..uninvitingPreview.." | Inviting "..invitingPreview)
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
