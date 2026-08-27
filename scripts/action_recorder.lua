-- ============================================================================
-- GrenadeHelper - Tick-Based Input Recorder (Capture & Compress)
-- ============================================================================

local LineupService = require("lineup_service")

local Recorder = {
    Recording        = false,
    StartTick        = nil,
    LastSampledTick  = nil,
    RawBuffer        = {},
    Baseline         = nil,
    RerecordTargetId = nil,
    TargetMapName    = nil,
}

local function SafeGetCurrentItem(agent)
    if not agent or not agent.Inventory then return nil end
    return agent.Inventory.CurrentItem
end

local function GetThrowState(item)
    local throwable = item and item.AsThrowableItem
    if not throwable then return nil end
    return throwable.ThrowState
end

local function CopyVec2(v)
    if not v then return { x = 0, y = 0 } end
    return { x = v.x or 0, y = v.y or 0 }
end

-- Below this horizontal speed, the player counts as "not moving" for the
-- purpose of trimming idle stretches (see IsMeaningfulSample).
local IDLE_SPEED_THRESHOLD = 0.05

--- A tick is worth keeping if the player was actually doing something -
--- moving, holding a direction, jumping, crouching, or throwing. Camera
--- drift alone (aim changing while standing still) is not meaningful: it's
--- just the player looking around before/after the real action, not part
--- of the lineup itself.
local function IsMeaningfulSample(sample)
    if sample.move.x ~= 0 or sample.move.y ~= 0 then return true end
    if sample.jump or sample.crouch or sample.fire or sample.altFire then return true end
    if (sample.speed or 0) > IDLE_SPEED_THRESHOLD then return true end
    return false
end

--- Collapses a raw per-sampled-tick buffer into a sparse list of change-point
--- events: the first sample is always emitted in full (baseline), and every
--- later sample only contributes the fields that actually differ from the
--- previously known value of that field.
---@param rawBuffer table[]
---@return table[] events
local function CompressBuffer(rawBuffer)
    local events = {}
    local prev = nil

    for _, sample in ipairs(rawBuffer) do
        local changed = {}

        if not prev then
            changed.move    = sample.move
            changed.look    = sample.look
            changed.jump    = sample.jump
            changed.crouch  = sample.crouch
            changed.fire    = sample.fire
            changed.altFire = sample.altFire
        else
            if sample.move.x ~= prev.move.x or sample.move.y ~= prev.move.y then
                changed.move = sample.move
            end
            if sample.look.x ~= prev.look.x or sample.look.y ~= prev.look.y then
                changed.look = sample.look
            end
            if sample.jump    ~= prev.jump    then changed.jump    = sample.jump    end
            if sample.crouch  ~= prev.crouch  then changed.crouch  = sample.crouch  end
            if sample.fire    ~= prev.fire    then changed.fire    = sample.fire    end
            if sample.altFire ~= prev.altFire then changed.altFire = sample.altFire end
        end

        -- Defensive: a genuine press should already show up via the diff
        -- above; this only guards against the very first sampled tick after
        -- a jump was already mid-air (no prior "false" to diff against).
        if sample.jumpPressed and changed.jump == nil and (not prev or prev.jump == false) then
            changed.jump = true
        end

        local hasChange = changed.move ~= nil or changed.look ~= nil
            or changed.jump ~= nil or changed.crouch ~= nil or changed.fire ~= nil or changed.altFire ~= nil

        if hasChange then
            table.insert(events, { t = sample.tickOffset, fields = changed })
        end

        prev = sample
    end

    return events
end

--- Starts recording. Requires a throwable/bridge-charge item to be equipped
--- (same rule the old one-shot save used) so the baseline grenade type is
--- always known.
---@param agent Agent
---@param mapName string|nil
function Recorder:Start(agent, mapName)
    if self.Recording then return false, "Already recording" end

    local baseline, err = LineupService:CaptureBaseline(agent)
    if not baseline then
        if NotificationController and NotificationController.ShowHint then
            NotificationController:ShowHint(tostring(err), 2.5)
        end
        self.RerecordTargetId = nil
        return false, err
    end

    self.Recording       = true
    self.StartTick       = (Time and Time.Tick) or 0
    self.LastSampledTick = nil
    self.RawBuffer       = {}
    self.Baseline        = baseline
    self.TargetMapName   = mapName or LineupService:GetCurrentMapName()

    print("[GrenadeHelper] Recording started at tick " .. tostring(self.StartTick))
    if NotificationController and NotificationController.ShowHint then
        NotificationController:ShowHint("[GrenadeHelper] Recording... throw the grenade or press F1 again to stop", 2.5)
    end

    return true
end

--- Same as Start, but marks the recording to overwrite an existing lineup
--- (by id) instead of inserting a new one once it stops.
function Recorder:StartRerecord(lineupId, mapName)
    if self.Recording then return false, "Already recording" end
    if not lineupId then return false, "Missing lineup id" end

    local agent = (Agents and Agents.GetLocalOrSpectatedAgent and Agents:GetLocalOrSpectatedAgent())
               or (Agents and Agents.GetLocalAgent and Agents:GetLocalAgent())
    if not agent then return false, "Agent is unavailable" end

    self.RerecordTargetId = lineupId
    local ok, err = self:Start(agent, mapName)
    if not ok then
        self.RerecordTargetId = nil
    end
    return ok, err
end

--- Called every client frame while recording. Samples at most once per real
--- simulation tick (Time.Tick), since Scheduler:OnTick is server-only and
--- unavailable to this client module.
---@param agent Agent
function Recorder:Tick(agent)
    if not self.Recording then return end
    if not Time or Time.Tick == nil then return end

    local currentTick = Time.Tick
    if currentTick == self.LastSampledTick then return end
    self.LastSampledTick = currentTick

    local move = AgentInput and AgentInput.GetMoveDirection and AgentInput:GetMoveDirection()
    local look = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()

    local jumpDown    = EInputButton and AgentInput and AgentInput.IsButtonDown and AgentInput:IsButtonDown(EInputButton.Jump) == true
    local jumpPressed = EInputButton and AgentInput and AgentInput.IsJustPressed and AgentInput:IsJustPressed(EInputButton.Jump) == true
    local crouchDown  = EInputButton and AgentInput and AgentInput.IsButtonDown and AgentInput:IsButtonDown(EInputButton.Crouch) == true
    local fireDown    = EInputButton and AgentInput and AgentInput.IsButtonDown and AgentInput:IsButtonDown(EInputButton.Fire) == true
    local altFireDown = EInputButton and AgentInput and AgentInput.IsButtonDown and AgentInput:IsButtonDown(EInputButton.AlternateFire) == true

    -- Position and speed are only used transiently, to trim idle lead-in/
    -- trail-off in StopAndSave and to re-anchor the baseline if the start
    -- gets trimmed away - neither ends up in the saved action track.
    local truePos = agent.Movement and agent.Movement.Position
    local vel = agent.Movement and agent.Movement.Velocity
    local speed = vel and math.sqrt((vel.x or 0) ^ 2 + (vel.z or 0) ^ 2) or 0

    table.insert(self.RawBuffer, {
        tickOffset  = currentTick - self.StartTick,
        move        = CopyVec2(move),
        look        = CopyVec2(look),
        jump        = jumpDown,
        jumpPressed = jumpPressed,
        crouch      = crouchDown,
        fire        = fireDown,
        altFire     = altFireDown,
        pos         = truePos and { x = truePos.x, y = truePos.y, z = truePos.z } or nil,
        speed       = speed,
    })

    local item = SafeGetCurrentItem(agent)
    local throwState = GetThrowState(item)
    if EThrowState and (throwState == EThrowState.Throwing or throwState == EThrowState.ThrowingAlternate) then
        local lastSample = self.RawBuffer[#self.RawBuffer]
        if lastSample then
            if throwState == EThrowState.ThrowingAlternate then
                lastSample.altFire = true
            else
                lastSample.fire = true
            end
        end
        self:StopAndSave(agent)
    end
end

--- Stops recording (if active), compresses the buffer, and saves it as a new
--- or overwritten (re-record) lineup.
---@param agent Agent
function Recorder:StopAndSave(agent)
    if not self.Recording then return false, "Not recording" end
    self.Recording = false

    if #self.RawBuffer == 0 then
        self.RerecordTargetId = nil
        self.Baseline = nil
        if NotificationController and NotificationController.ShowHint then
            NotificationController:ShowHint("[GrenadeHelper] Recording too short - nothing saved", 2.5)
        end
        return false, "Empty recording"
    end

    -- Trim idle lead-in/trail-off: stretches where only the camera drifted
    -- but nothing actually happened (no velocity, no move input, no buttons)
    -- are the player standing around deciding what to do, not the lineup
    -- itself. Keep only the span between the first and last meaningful tick.
    -- If nothing was ever meaningful, leave the buffer untouched rather than
    -- discarding the whole recording.
    local firstIdx, lastIdx = nil, nil
    for i, sample in ipairs(self.RawBuffer) do
        if IsMeaningfulSample(sample) then
            if not firstIdx then firstIdx = i end
            lastIdx = i
        end
    end

    if firstIdx and (firstIdx > 1 or lastIdx < #self.RawBuffer) then
        local firstSample = self.RawBuffer[firstIdx]
        local baseTick = firstSample.tickOffset

        -- Re-anchor the baseline to where the useful recording now starts,
        -- not where F1 was originally pressed, so pre-roll walks/aims the
        -- player to the right spot before tick playback begins.
        if firstSample.pos then
            self.Baseline.pos = { x = firstSample.pos.x, y = firstSample.pos.y, z = firstSample.pos.z }
        end
        self.Baseline.pitch = firstSample.look.x
        self.Baseline.yaw   = firstSample.look.y

        local trimmed = {}
        for i = firstIdx, lastIdx do
            local s = self.RawBuffer[i]
            trimmed[#trimmed + 1] = {
                tickOffset  = s.tickOffset - baseTick,
                move        = s.move,
                look        = s.look,
                jump        = s.jump,
                jumpPressed = s.jumpPressed,
                crouch      = s.crouch,
                fire        = s.fire,
                altFire     = s.altFire,
            }
        end
        self.RawBuffer = trimmed
    end

    -- Force a closing sample so a still-held jump/crouch/fire at the moment
    -- of stop doesn't leave a dangling "pressed" state on replay.
    local last = self.RawBuffer[#self.RawBuffer]
    if last.jump or last.crouch or last.fire or last.altFire then
        table.insert(self.RawBuffer, {
            tickOffset  = last.tickOffset + 1,
            move        = last.move,
            look        = last.look,
            jump        = false,
            crouch      = false,
            fire        = false,
            altFire     = false,
            jumpPressed = false,
        })
    end

    local events = CompressBuffer(self.RawBuffer)
    local durationTicks = self.RawBuffer[#self.RawBuffer].tickOffset

    local actionsTrack = { durationTicks = durationTicks, events = events }
    local saved, err = LineupService:SaveRecordedLineup(self.Baseline, actionsTrack, self.TargetMapName, self.RerecordTargetId)

    self.RerecordTargetId = nil
    self.Baseline = nil
    self.RawBuffer = {}

    if not saved then
        if NotificationController and NotificationController.ShowHint then
            NotificationController:ShowHint(tostring(err or "Failed to save recording"), 3.0)
        end
        return false, err
    end

    local msg = "[GrenadeHelper] Saved: " .. tostring(saved.description) .. " (" .. tostring(saved.grenadeType) .. ") - "
        .. tostring(#events) .. " events / " .. tostring(durationTicks) .. " ticks"
    print(msg)
    if NotificationController and NotificationController.ShowHint then
        NotificationController:ShowHint(msg, 3.0)
    end

    return true
end

return Recorder
