-- ============================================================================
-- GrenadeHelper by @Keqqyrr - Composition Root & Lifecycle Manager (Client Module)
-- ============================================================================

local LineupService = require("lineup_service")
local Recorder       = require("action_recorder")
local ModernMenu    = require("modern_menu")
local HUD           = require("hud")

local State = { Enabled = true }

if Storage then
    if Storage.GrenadeHelperEnabled ~= nil then
        State.Enabled = Storage.GrenadeHelperEnabled
    else
        State.Enabled = true
        Storage.GrenadeHelperEnabled = true
    end
    -- Always default to Auto-Detect map on startup
    Storage.CurrentMapProfile = nil
end

HUD:Init()

local WasAltPressed = false

---@param enabled boolean
local function SetModuleEnabled(enabled)
    State.Enabled = enabled == true
    if Storage then
        Storage.GrenadeHelperEnabled = State.Enabled
    end
end

local function ToggleModule()
    SetModuleEnabled(not State.Enabled)
    print("[GrenadeHelper] Toggled: " .. (State.Enabled and "ENABLED" or "DISABLED"))
end

local function GetLocalAgent()
    return (Agents and Agents.GetLocalOrSpectatedAgent and Agents:GetLocalOrSpectatedAgent())
        or (Agents and Agents.GetLocalAgent and Agents:GetLocalAgent())
end

--- F1: starts a new tick-by-tick recording, or stops and saves the one in
--- progress. Recording auto-stops on an actual grenade throw (see
--- action_recorder.lua); this is only the manual start/stop path.
local function ToggleRecordingAction()
    local agent = GetLocalAgent()
    if not agent then return end

    if Recorder.Recording then
        Recorder:StopAndSave(agent)
    else
        -- Recording used to remain available while the helper was disabled,
        -- but the saved lineup was then hidden and Alt playback was skipped.
        -- Starting an explicit recording also enables the runtime so the
        -- result is immediately visible and playable after it is saved.
        if not State.Enabled then
            SetModuleEnabled(true)
            print("[GrenadeHelper] Enabled automatically for recording")
        end
        Recorder:Start(agent, LineupService:GetCurrentMapName())
    end

    if ModernMenu.IsOpen and ModernMenu.IsOpen() and ModernMenu.Refresh then
        ModernMenu.Refresh()
    end
end

local function DeleteActiveLineupAction()
    local agent = GetLocalAgent()
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

local function RenameActiveLineupAction()
    local agent = GetLocalAgent()
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

-- Key bindings initialization
if InputActions then

    local recordAction = InputActions:FindAction("SaveLineup")
    if recordAction and recordAction.OnPerformed then recordAction:OnPerformed(ToggleRecordingAction) end

    local deleteAction = InputActions:FindAction("DeleteLineup") or InputActions:FindAction("DeleteCurrentLineup")
    if deleteAction and deleteAction.OnPerformed then deleteAction:OnPerformed(DeleteActiveLineupAction) end

    local renameAction = InputActions:FindAction("RenameLineup") or InputActions:FindAction("RenameCurrentLineup")
    if renameAction and renameAction.OnPerformed then renameAction:OnPerformed(RenameActiveLineupAction) end

    local menuAction = InputActions:FindAction("ToggleGrenadeMenu")
    if menuAction and menuAction.OnPerformed then menuAction:OnPerformed(function() ModernMenu.Toggle() end) end
end

local alignAction = InputActions and InputActions.FindAction and InputActions:FindAction("AlignLineup")

-- ============================================================================
-- OnFrame Loop
-- ============================================================================
local function OnFrame()
    if ModernMenu and ModernMenu.Update then
        ModernMenu.Update()
    end

    -- The menu edits the persisted setting directly. Keep the runtime state
    -- synchronized so its ENABLED toggle takes effect without a hot reload.
    if Storage and Storage.GrenadeHelperEnabled ~= nil then
        State.Enabled = Storage.GrenadeHelperEnabled == true
    end

    local agent = GetLocalAgent()

    -- Recording runs independently of the Enabled toggle and of alignment,
    -- exactly like the old F1/F2 bindings did.
    if agent and Recorder and Recorder.Tick then
        Recorder:Tick(agent)
    end

    if not State.Enabled then
        HUD:Render(nil, false, nil)
        if WasAltPressed then
            LineupService:StopAlignment()
            WasAltPressed = false
        end
        return
    end

    if not agent then
        HUD:Render(nil, false, nil)
        if WasAltPressed then
            LineupService:StopAlignment()
            WasAltPressed = false
        end
        return
    end

    local maxDist = Config and Config.ActivationDistance or 2.5
    local nearestLineup = LineupService:FindActiveLineup(agent, maxDist)

    local isAltPressed = false
    if alignAction and alignAction.IsPressed and alignAction:IsPressed() then
        isAltPressed = true
    end

    if isAltPressed and not WasAltPressed then
        LineupService:LockActiveLineup(agent, LineupService:GetCurrentMapName())
    end

    local isAligning = false
    local hudActiveLineup = nearestLineup

    if isAltPressed then
        isAligning = LineupService:UpdatePlayback(agent)
        local locked = LineupService:GetLockedLineup()
        if locked then hudActiveLineup = locked end
    elseif WasAltPressed then
        LineupService:StopAlignment()
    end

    WasAltPressed = isAltPressed

    HUD:Render(hudActiveLineup, isAligning, agent)
end

if Scheduler and Scheduler.OnFrame then
    Scheduler:OnFrame(OnFrame)
end

print("[GrenadeHelper] Advanced Grenade Helper (Client Module) initialized safely.")
