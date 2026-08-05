local WowauditCompanion = LibStub("AceAddon-3.0"):NewAddon("WowauditCompanion", "AceEvent-3.0", "AceTimer-3.0")

SLASH_WOWAUDIT1 = "/wowaudit"
SLASH_WOWAUDITINVITETOOL1 = "/wit"

local function HandleInvite()
    if Wit and Wit.CreateFrame then
        Wit:CreateFrame()
    else
        print("[Wowaudit Companion] Invite tool not loaded")
    end
end

local function HandleSync()
    if DataSync and DataSync.ManualSync then
        DataSync:ManualSync()
    else
        print("[Wowaudit Companion] DataSync module not available")
    end
end

local function HandleExportSetup()
    if RaidExport and RaidExport.ShowExportPopup then
        RaidExport:ShowExportPopup()
    else
        print("[Wowaudit Companion] RaidExport module not available")
    end
end

local function HandleBonusRolls()
    if BonusRoll and BonusRoll.ShowWindow then
        BonusRoll:ShowWindow()
    else
        print("[Wowaudit Companion] BonusRoll module not available")
    end
end

local function HandleWowauditCommand(msg)
    msg = (msg or ""):trim():lower()

    if msg == "sync" then
        HandleSync()

    elseif msg == "invite" then
        HandleInvite()

    elseif msg == "export-setup" then
        HandleExportSetup()

    elseif msg == "bonusrolls" or msg == "coins" then
        HandleBonusRolls()

    else
        print("Usage: /wowaudit [sync|invite|export-setup|bonusrolls]")
    end
end

function WowauditCompanion:OnInitialize()
    SlashCmdList["WOWAUDIT"] = HandleWowauditCommand
    SlashCmdList["WOWAUDITINVITETOOL"] = HandleInvite
end
