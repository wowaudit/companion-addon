RaidExport = LibStub("AceAddon-3.0"):NewAddon("WowauditRaidExport", "AceEvent-3.0")
local addon = RaidExport

local EXPORT_ICON_PATH = "Interface\\AddOns\\WowauditCompanion\\Media\\logo"
local EXPORT_POPUP_MESSAGE = "Copy and paste this into your raid plan on the wowaudit website to generate assignment and cooldown reminders for your group"

local exportButton
local exportPopupFrame
local exportPopupEditBox
local raidHooksInstalled = false
local raidSubFrameActive = false

local function normalizeRealm(realm)
  if not realm or realm == "" then
    return (GetNormalizedRealmName() or ""):gsub("%s+", "")
  end

  return realm:gsub("%s+", "")
end

function addon:GetUnitFullName(unit)
  local name, realm = UnitFullName(unit)
  if not name then
    return nil
  end

  return name .. "-" .. normalizeRealm(realm)
end

function addon:GetUnitSpecID(unit)
  if not UnitExists(unit) then
    return 0
  end

  if UnitIsUnit(unit, "player") and GetSpecialization and GetSpecializationInfo then
    local currentSpec = GetSpecialization()
    if currentSpec then
      local playerSpecID = GetSpecializationInfo(currentSpec)
      if type(playerSpecID) == "number" and playerSpecID > 0 then
        return playerSpecID
      end
    end

    return 0
  end

  if GetInspectSpecialization then
    local inspectSpecID = GetInspectSpecialization(unit)
    if type(inspectSpecID) == "number" and inspectSpecID > 0 then
      return inspectSpecID
    end
  end

  return 0
end

function addon:GetUnitClassID(unit)
  if not UnitExists(unit) then
    return 0
  end

  local _, _, classID = UnitClass(unit)
  if type(classID) == "number" and classID > 0 then
    return classID
  end

  return 0
end

function addon:BuildRaidExportPayload()
  local entries = {}
  local seenNames = {}

  local function addUnitEntry(unit)
    if not UnitExists(unit) then
      return
    end

    local fullName = addon:GetUnitFullName(unit)
    if not fullName or seenNames[fullName] then
      return
    end

    seenNames[fullName] = true
    table.insert(entries, string.format("%s|%d|%d", fullName, addon:GetUnitSpecID(unit), addon:GetUnitClassID(unit)))
  end

  local inHomeRaid = IsInRaid and IsInRaid(LE_PARTY_CATEGORY_HOME)
  local inInstanceRaid = IsInRaid and IsInRaid(LE_PARTY_CATEGORY_INSTANCE)
  local inHomeGroup = IsInGroup and IsInGroup(LE_PARTY_CATEGORY_HOME)
  local inInstanceGroup = IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)

  if inHomeRaid or inInstanceRaid then
    local groupSize = GetNumGroupMembers() or 0
    for i = 1, groupSize do
      addUnitEntry("raid" .. i)
    end
  elseif inHomeGroup or inInstanceGroup then
    addUnitEntry("player")
    local subgroupSize = GetNumSubgroupMembers() or math.max((GetNumGroupMembers() or 1) - 1, 0)
    for i = 1, subgroupSize do
      addUnitEntry("party" .. i)
    end
  end

  return "raidlist:" .. table.concat(entries, " ") .. ";"
end

function addon:EnsureExportPopupFrame()
  if exportPopupFrame then
    return
  end

  exportPopupFrame = CreateFrame("Frame", "WowauditRaidExportPopupFrame", UIParent, "BasicFrameTemplateWithInset")
  exportPopupFrame:SetSize(360, 120)
  exportPopupFrame:SetPoint("CENTER")
  exportPopupFrame:SetFrameStrata("DIALOG")
  exportPopupFrame:SetMovable(true)
  exportPopupFrame:EnableMouse(true)
  exportPopupFrame:RegisterForDrag("LeftButton")
  exportPopupFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  exportPopupFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  exportPopupFrame:Hide()

  if exportPopupFrame.TitleText then
    exportPopupFrame.TitleText:SetText("Export raid setup")
  end

  local instruction = exportPopupFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  instruction:SetPoint("TOPLEFT", exportPopupFrame, "TOPLEFT", 16, -30)
  instruction:SetPoint("TOPRIGHT", exportPopupFrame, "TOPRIGHT", -16, -30)
  instruction:SetJustifyH("LEFT")
  instruction:SetTextColor(1, 1, 1, 1)
  instruction:SetText(EXPORT_POPUP_MESSAGE)

  local inputContainer = CreateFrame("Frame", nil, exportPopupFrame, "BackdropTemplate")
  inputContainer:SetPoint("TOPLEFT", exportPopupFrame, "TOPLEFT", 16, -62)
  inputContainer:SetPoint("TOPRIGHT", exportPopupFrame, "TOPRIGHT", -16, -62)
  inputContainer:SetHeight(34)
  inputContainer:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  inputContainer:SetBackdropColor(0, 0, 0, 0.9)

  exportPopupEditBox = CreateFrame("EditBox", nil, inputContainer)
  exportPopupEditBox:SetPoint("TOPLEFT", inputContainer, "TOPLEFT", 10, -7)
  exportPopupEditBox:SetPoint("BOTTOMRIGHT", inputContainer, "BOTTOMRIGHT", -10, 7)
  exportPopupEditBox:SetMultiLine(false)
  exportPopupEditBox:SetAutoFocus(false)
  exportPopupEditBox:SetFontObject(GameFontHighlightSmall)
  exportPopupEditBox:SetTextColor(1, 1, 1, 1)
  exportPopupEditBox:SetTextInsets(2, 2, 2, 2)
  exportPopupEditBox:SetMaxLetters(0)
  exportPopupEditBox:SetScript("OnEscapePressed", function()
    if exportPopupFrame then
      exportPopupFrame:Hide()
    end
  end)
end

function addon:ShowExportPopup()
  local payload = addon:BuildRaidExportPayload()
  addon:EnsureExportPopupFrame()
  if not exportPopupFrame or not exportPopupEditBox then
    return
  end

  exportPopupFrame:Show()
  exportPopupEditBox:SetText(payload or "")
  exportPopupEditBox:SetFocus()
  exportPopupEditBox:HighlightText()
end

function addon:RefreshExportPopupIfVisible()
  if not exportPopupFrame or not exportPopupEditBox or not exportPopupFrame:IsShown() then
    return
  end

  local payload = addon:BuildRaidExportPayload()
  exportPopupEditBox:SetText(payload or "")
  exportPopupEditBox:SetFocus()
  exportPopupEditBox:HighlightText()
end

function addon:CreateExportButton()
  if exportButton or not RaidFrame then
    return
  end

  local raidInfoButton = _G.RaidFrameRaidInfoButton
  local headerParent = _G.FriendsFrame or RaidFrame
  exportButton = CreateFrame("Button", "WowauditRaidExportButton", headerParent, "UIPanelButtonTemplate")
  if raidInfoButton then
    exportButton:SetSize(math.floor(raidInfoButton:GetWidth() * 0.9), math.floor(raidInfoButton:GetHeight() * 0.9))
  else
    exportButton:SetSize(72, 20)
  end

  exportButton:SetFrameStrata("HIGH")
  exportButton:SetFrameLevel((headerParent:GetFrameLevel() or 1) + 8)
  exportButton:SetText("Export")
  exportButton:SetNormalFontObject(GameFontHighlightSmall)
  exportButton:SetHighlightFontObject(GameFontHighlightSmall)
  exportButton:SetDisabledFontObject(GameFontDisableSmall)
  exportButton:SetScript("OnClick", function()
    addon:ShowExportPopup()
  end)

  local icon = exportButton:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(EXPORT_ICON_PATH)
  icon:SetSize(12, 12)
  icon:SetPoint("LEFT", exportButton, "LEFT", 8, 0)

  local label = exportButton:GetFontString()
  if label then
    label:ClearAllPoints()
    label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    label:SetPoint("RIGHT", exportButton, "RIGHT", -8, 0)
  end
end

function addon:UpdateExportButton()
  if not RaidFrame then
    return
  end

  addon:CreateExportButton()
  if not exportButton then
    return
  end

  exportButton:ClearAllPoints()
  local closeButton = _G.FriendsFrameCloseButton or _G.RaidFrameCloseButton
  local titleText = _G.FriendsFrameTitleText or _G.RaidFrameTitleText
  if closeButton then
    exportButton:SetPoint("RIGHT", closeButton, "LEFT", -8, 0)
  elseif titleText then
    exportButton:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
  else
    exportButton:SetPoint("TOPRIGHT", RaidFrame, "TOPRIGHT", -42, 18)
  end

  if raidSubFrameActive and FriendsFrame and FriendsFrame:IsShown() then
    exportButton:Show()
  else
    exportButton:Hide()
  end
end

function addon:HookRaidUI()
  if not RaidFrame then
    return
  end

  if not raidHooksInstalled then
    RaidFrame:HookScript("OnShow", function()
      raidSubFrameActive = true
      addon:UpdateExportButton()
    end)
    RaidFrame:HookScript("OnHide", function()
      raidSubFrameActive = false
      if exportButton then
        exportButton:Hide()
      end
    end)

    if FriendsFrame_ShowSubFrame then
      hooksecurefunc("FriendsFrame_ShowSubFrame", function(frameName)
        raidSubFrameActive = (frameName == "RaidFrame")
        addon:UpdateExportButton()
      end)
    end

    raidHooksInstalled = true
  end

  raidSubFrameActive = RaidFrame:IsShown()
  addon:UpdateExportButton()
end

function addon:OnAddonLoaded(_, addonName)
  if addonName == "Blizzard_RaidUI" then
    addon:HookRaidUI()
  end
end

function addon:OnEnable()
  addon:RegisterEvent("ADDON_LOADED", "OnAddonLoaded")
  addon:RegisterEvent("GROUP_ROSTER_UPDATE", "RefreshExportPopupIfVisible")
  addon:HookRaidUI()
end
