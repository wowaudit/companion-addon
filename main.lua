Wit = LibStub("AceAddon-3.0"):NewAddon("Wowaudit Invite Tool", "AceTimer-3.0")
local addon = Wit
local AceGUI = LibStub("AceGUI-3.0")
local inviteString
local invitingPreview
local uninvitingPreview
local notInSetup
local frame
local frameShown

SLASH_WOWAUDITINVITETOOL1, SLASH_WOWAUDITINVITETOOL2 = '/wit', '/wowaudit';

function SlashCmdList.WOWAUDITINVITETOOL(msg, editBox)
  addon:CreateFrame()
end

function addon:CreateFrame()
  if frameShown then
    return
  else
    frame = AceGUI:Create("Frame")
    frame:SetTitle("Wowaudit Invite Tool")
    frame:SetLayout("Flow")
    frame:SetWidth(455)
    frame:SetHeight(180)
    frame:EnableResize(false)
    frame.frame:SetFrameStrata("MEDIUM")
    frame.frame:Raise()
    frame.content:SetFrameStrata("MEDIUM")
    frame.content:Raise()

    local horizontalGroup = AceGUI:Create("SimpleGroup")
    horizontalGroup:SetFullWidth(true)
    horizontalGroup:SetLayout("Flow")

    local editBoxGroup = AceGUI:Create("SimpleGroup")
    editBoxGroup:SetWidth(240)
    editBoxGroup:SetLayout("Fill")

    local editbox = AceGUI:Create("MultiLineEditBox")
    editbox:SetLabel("Paste invite string here:")
    editbox:SetFullWidth(true)
    editbox:SetNumLines(15)
    editbox:SetCallback("OnTextChanged", function(widget, event, text) inviteString = text:gsub("|", ";"); inviteString = inviteString:gsub("[;]+", "\n"); editbox:SetText(inviteString) end)
    editbox:DisableButton(true)
    editBoxGroup:AddChild(editbox)


    local buttonGroup = AceGUI:Create("SimpleGroup")
    buttonGroup:SetWidth(180)
    buttonGroup:SetLayout("List")

    local replaceButton = AceGUI:Create("Button")
    replaceButton:SetText("Invite and remove")
    replaceButton:SetWidth(180)
    replaceButton:SetCallback("OnClick", function() addon:Replace(false) end)
    buttonGroup:AddChild(replaceButton)

    local rearrangeButton = AceGUI:Create("Button")
    rearrangeButton:SetText("Invite and rearrange")
    rearrangeButton:SetWidth(180)
    rearrangeButton:SetCallback("OnClick", function() addon:InviteAndRearrange() end)
    buttonGroup:AddChild(rearrangeButton)

    local inviteButton = AceGUI:Create("Button")
    inviteButton:SetText("Invite only")
    inviteButton:SetWidth(180)
    inviteButton:SetCallback("OnClick", function() addon:InviteOnly() end)
    buttonGroup:AddChild(inviteButton)

    horizontalGroup:AddChild(editBoxGroup)
    horizontalGroup:AddChild(buttonGroup)

    frame:AddChild(horizontalGroup)


    inviteString = ""
    notInSetup = ""
    self.previewer = self:ScheduleRepeatingTimer("UpdatePreview", 0.1)

    frame:SetCallback("OnClose", function(widget)
      AceGUI:Release(widget)
      frameShown = false
      self:CancelTimer(self.previewer)
    end)
  end
end

function addon:UpdatePreview()
  addon:Replace(true)
  notInSetup = ""
end

function addon:Replace(preview)
  if not preview then
    C_PartyInfo.ConvertToRaid()
  end

  addon:Uninvite(preview, false)
  addon:Invite(preview)
end

function addon:InviteAndRearrange()
  C_PartyInfo.ConvertToRaid()
  addon:Uninvite(false, true)
  addon:InviteOnly()
end

function addon:InviteOnly()
  C_PartyInfo.ConvertToRaid()
  notInSetup = ""
  addon:Invite(false)

  if (string.len(notInSetup) > 0) then
    print("These players are not in the setup but haven't been removed: "..notInSetup:sub(1, -3))
  end
end

function addon:Uninvite(preview, moveOnly)
  invitingPreview = 0
  uninvitingPreview = 0
  local moveToEnd = {}
  local playersInGroup = {}
  if not (string.len(inviteString) > 0) then
    frame:SetStatusText("Removing "..uninvitingPreview.." | Inviting "..invitingPreview)
    return
  end

  -- Uninvite raid members not in the string
  local rosterSize = GetNumGroupMembers() or 0
	local myName, myRealm = UnitFullName("player")
	for j=rosterSize,1,-1 do
		local nown = GetNumGroupMembers() or 0
		if nown > 0 then
      local name, rank, subgroup = GetRaidRosterInfo(j)
      if not string.find(name, "-") then
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
        for inviteTarget in string.gmatch(inviteString, "([^\n]+)") do
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

function addon:Invite(preview)
  local groupSize = GetNumGroupMembers()
  local alreadyInGroup = {}
  if groupSize ~= 0 then
    for i=1,groupSize do
      local name = GetRaidRosterInfo(i)
      table.insert(alreadyInGroup, name)
    end
  end

  local selfName, selfRealm = UnitFullName("player")
  -- Invite raid members in the string
  for inviteTarget in string.gmatch(inviteString, "([^\n]+)") do
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
    frame:SetStatusText("Removing "..uninvitingPreview.." | Inviting "..invitingPreview)
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
