-- ============================================================================
-- GrenadeHelper by @Keqqyrr - Composition Root & Lifecycle Manager Class
-- ============================================================================

local LineupService = require("lineup_service")
local Recorder      = require("action_recorder")
local ModernMenu    = require("modern_menu")
local HUD           = require("hud")

local GrenadeHelper = {
    State = { Enabled = true },
    WasAltPressed = false,
    AlignAction = nil,
}

function GrenadeHelper:Init()
    if Storage then
        if Storage.GrenadeHelperEnabled ~= nil then
            self.State.Enabled = Storage.GrenadeHelperEnabled
        else
            self.State.Enabled = true
            Storage.GrenadeHelperEnabled = true
        end
        Storage.CurrentMapProfile = nil
    end

    HUD:Init()

    if InputActions then
        local recordAction = InputActions:FindAction("SaveLineup")
        if recordAction and recordAction.OnPerformed then
            recordAction:OnPerformed(function() GrenadeHelper:ToggleRecordingAction() end)
        end

        local deleteAction = InputActions:FindAction("DeleteLineup") or InputActions:FindAction("DeleteCurrentLineup")
        if deleteAction and deleteAction.OnPerformed then
            deleteAction:OnPerformed(function() GrenadeHelper:DeleteActiveLineupAction() end)
        end

        local renameAction = InputActions:FindAction("RenameLineup") or InputActions:FindAction("RenameCurrentLineup")
        if renameAction and renameAction.OnPerformed then
            renameAction:OnPerformed(function() GrenadeHelper:RenameActiveLineupAction() end)
        end

        local menuAction = InputActions:FindAction("ToggleGrenadeMenu")
        if menuAction and menuAction.OnPerformed then
            menuAction:OnPerformed(function() ModernMenu.Toggle() end)
        end

        self.AlignAction = InputActions:FindAction("AlignLineup")
    end
end

function GrenadeHelper:SetModuleEnabled(enabled)
    self.State.Enabled = enabled == true
    if Storage then
        Storage.GrenadeHelperEnabled = self.State.Enabled
    end
end

function GrenadeHelper:ToggleModule()
    self:SetModuleEnabled(not self.State.Enabled)
    print("[GrenadeHelper] Toggled: " .. (self.State.Enabled and "ENABLED" or "DISABLED"))
end

function GrenadeHelper:GetLocalAgent()
    return (Agents and Agents.GetLocalOrSpectatedAgent and Agents:GetLocalOrSpectatedAgent())
        or (Agents and Agents.GetLocalAgent and Agents:GetLocalAgent())
end

function GrenadeHelper:ToggleRecordingAction()
    local agent = self:GetLocalAgent()
    if not agent then return end

    if Recorder.Recording then
        Recorder:StopAndSave(agent)
    else
        if not self.State.Enabled then
            self:SetModuleEnabled(true)
            print("[GrenadeHelper] Enabled automatically for recording")
        end
        Recorder:Start(agent, LineupService:GetCurrentMapName())
    end

    if ModernMenu.IsOpen and ModernMenu.IsOpen() and ModernMenu.Refresh then
        ModernMenu.Refresh()
    end
end

function GrenadeHelper:DeleteActiveLineupAction()
    local agent = self:GetLocalAgent()
    if not agent then return end

    local activeMap = LineupService:GetCurrentMapName()
    local maxDist   = Config and Config.ActivationDistance or 2.5
    local lineup    = LineupService:FindActiveLineup(agent, maxDist, activeMap)
    if lineup then
        if lineup.id then
            LineupService:DeleteLineupById(lineup.id, activeMap)
        elseif lineup.storageIndex then
            LineupService:DeleteSavedLineup(lineup.storageIndex, activeMap)
        end
        local msg = "Deleted: " .. tostring(lineup.description) .. " [" .. activeMap .. "]"
        print("[GrenadeHelper] " .. msg)
        if NotificationController and NotificationController.ShowHint then
            NotificationController:ShowHint(msg, 2.5)
        end
        if ModernMenu.IsOpen and ModernMenu.IsOpen() then ModernMenu.Refresh() end
    end
end

function GrenadeHelper:RenameActiveLineupAction()
    local agent = self:GetLocalAgent()
    if not agent then return end

    local activeMap = LineupService:GetCurrentMapName()
    local maxDist   = Config and Config.ActivationDistance or 2.5
    local lineup    = LineupService:FindActiveLineup(agent, maxDist, activeMap)
    if lineup then
        if ModernMenu and ModernMenu.OpenRenameModalForLineup then
            ModernMenu.OpenRenameModalForLineup(lineup)
        end
        local msg = "Renaming: " .. tostring(lineup.description or "Lineup")
        print("[GrenadeHelper] " .. msg)
    else
        if NotificationController and NotificationController.ShowHint then
            NotificationController:ShowHint("Stand near a spot to rename it with F3", 2.5)
        end
    end
end

function GrenadeHelper:OnFrame()
    if ModernMenu and ModernMenu.Update then
        ModernMenu.Update()
    end

    if Storage and Storage.GrenadeHelperEnabled ~= nil then
        self.State.Enabled = Storage.GrenadeHelperEnabled == true
    end

    local agent = self:GetLocalAgent()

    if agent and Recorder and Recorder.Tick then
        Recorder:Tick(agent)
    end

    if not self.State.Enabled then
        HUD:Render(nil, false, nil)
        if self.WasAltPressed then
            LineupService:StopAlignment()
            self.WasAltPressed = false
        end
        return
    end

    if not agent then
        HUD:Render(nil, false, nil)
        if self.WasAltPressed then
            LineupService:StopAlignment()
            self.WasAltPressed = false
        end
        return
    end

    local maxDist = Config and Config.ActivationDistance or 2.5
    local nearestLineup = LineupService:FindActiveLineup(agent, maxDist)

    local isAltPressed = false
    if self.AlignAction and self.AlignAction.IsPressed and self.AlignAction:IsPressed() then
        isAltPressed = true
    end

    if isAltPressed and not self.WasAltPressed then
        LineupService:LockActiveLineup(agent, LineupService:GetCurrentMapName())
    end

    local isAligning = false
    local hudActiveLineup = nearestLineup

    if isAltPressed then
        isAligning = LineupService:UpdatePlayback(agent)
        local locked = LineupService:GetLockedLineup()
        if locked then hudActiveLineup = locked end
    elseif self.WasAltPressed then
        LineupService:StopAlignment()
    end

    self.WasAltPressed = isAltPressed

    HUD:Render(hudActiveLineup, isAligning, agent)
end

-- Initialize composition root
GrenadeHelper:Init()

if Scheduler and Scheduler.OnFrame then
    Scheduler:OnFrame(function() GrenadeHelper:OnFrame() end)
end

print("[GrenadeHelper] Advanced Grenade Helper (Client Module) initialized safely.")

return GrenadeHelper
