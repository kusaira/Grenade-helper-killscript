-- ============================================================================
-- GrenadeHelper - Lineup Storage & Tick-Based Macro Playback Engine Class
-- ============================================================================

local ActionCodec = require("action_codec")
local MathUtils   = require("math_utils")

local LineupService = {
    PREROLL_MAX_SPEED = 0.15,
    PREROLL_STABLE_TICKS_REQUIRED = 2,
    SETTLE_DELAY_TICKS = 12,
    ActionsDecodeCache = {},
    LineupsSummaryCache = {},
    LastEquipTryTime = 0,
    PendingEquipButton = nil,
    PlaybackState = {
        Lineup               = nil,
        PreRollDone          = false,
        StartTick            = nil,
        LockTick             = nil,
        StableTicks          = 0,
        PostAlignSettleTicks = 0,
        NextEventIndex       = 1,
        Current              = { move = { x = 0, y = 0 }, look = { x = 0, y = 0 }, jump = false, crouch = false, fire = false, altFire = false },
    }
}

function LineupService:GetDecodedActions(id, item)
    if not item.actionsData or item.actionsData == "" then return nil end
    local cached = self.ActionsDecodeCache[id]
    if cached then return cached end
    local decoded = ActionCodec.Decode(item.actionsData)
    self.ActionsDecodeCache[id] = decoded
    return decoded
end

function LineupService:GetInitialLineupCrouch(lineup)
    if not lineup or not lineup.actions or not lineup.actions.events then return false end
    for _, ev in ipairs(lineup.actions.events) do
        if ev and ev.t and ev.t > 10 then break end
        if ev and ev.fields and ev.fields.crouch ~= nil then
            return ev.fields.crouch == true
        end
    end
    return false
end

function LineupService:InvalidateCaches(mapName)
    if mapName then
        self.LineupsSummaryCache[mapName] = nil
    else
        for k in pairs(self.LineupsSummaryCache) do self.LineupsSummaryCache[k] = nil end
        for k in pairs(self.ActionsDecodeCache) do self.ActionsDecodeCache[k] = nil end
    end

    if Storage then
        Storage.GrenadeHelperLineupsRevision =
            (tonumber(Storage.GrenadeHelperLineupsRevision) or 0) + 1
    end
end

function LineupService:SafeGetCurrentItem(agent)
    if not agent or not agent.Inventory then return nil end
    return agent.Inventory.CurrentItem
end

function LineupService:SafeIsSwitching(agent)
    if not agent or not agent.Inventory then return false end
    return agent.Inventory.IsSwitching == true
end

function LineupService:SafeGetItemName(item)
    if not item then return "" end
    return item.Name or ""
end

function LineupService:SafeIsThrowable(item)
    if not item then return false end
    return (item.IsThrowable == true or item.IsBridgeCharge == true)
end

function LineupService:StandardizeGrenadeKey(str)
    if not str or str == "" then return "" end
    local lower = tostring(str):lower()
    if lower:find("power") or lower:find("powershell") then return "powershell" end
    if lower:find("shield") or lower:find("barrier") or lower:find("bridge") or lower:find("charge") then return "shield" end
    if lower:find("frag") or lower:find("he") or lower:find("fragment") or lower == "grenade" then return "frag" end
    if lower:find("incendiary") or lower:find("molotov") or lower:find("fire") or lower:find("thermite") then return "incendiary" end
    if lower:find("sonar") then return "sonar" end
    if lower:find("emp") then return "emp" end
    return lower
end

function LineupService:GetExactGrenadeKey(item)
    if not item then return "" end

    local name = self:SafeGetItemName(item):lower()

    if item.IsBridgeCharge then return "shield" end
    if name:find("power") or name:find("powershell") then return "powershell" end
    if name:find("shield") or name:find("barrier") or name:find("bridge") or name:find("charge") then return "shield" end
    if name:find("incendiary") or name:find("molotov") or name:find("fire") or name:find("thermite") then return "incendiary" end
    if name:find("sonar") then return "sonar" end
    if name:find("emp") then return "emp" end
    if name:find("frag") or name:find("he") or name:find("fragment") then return "frag" end

    if item.IsThrowable then return "frag" end
    return name
end

function LineupService:IsAllowedGrenade(itemName, item)
    if item and (item.IsBridgeCharge or item.IsThrowable) then
        return true
    end
    if not itemName or itemName == "" then return false end
    local name = tostring(itemName):lower()
    return name:find("grenade") ~= nil or name:find("molotov") ~= nil
        or name:find("incendiary") ~= nil or name:find("powershell") ~= nil
        or name:find("shield") ~= nil or name:find("bridge") ~= nil
        or name:find("sonar") ~= nil or name:find("emp") ~= nil
        or name:find("thermite") ~= nil or name:find("smoke") ~= nil
end

function LineupService:GetCurrentMapName(agent)
    if MapInfo then
        local rawName = MapInfo.MapName
        if not rawName and MapInfo.GetMapName then
            rawName = MapInfo:GetMapName()
        end
        if rawName and tostring(rawName) ~= "" then
            return tostring(rawName):upper()
        end
    end

    local targetAgent = agent
    if not targetAgent and Agents then
        targetAgent = (Agents.GetLocalOrSpectatedAgent and Agents:GetLocalOrSpectatedAgent())
            or (Agents.GetLocalAgent and Agents:GetLocalAgent())
    end

    if targetAgent and targetAgent.Movement then
        local zones = nil
        if targetAgent.Movement.GetZones then
            zones = targetAgent.Movement:GetZones()
        elseif MapInfo and MapInfo.GetZones and targetAgent.Movement.Position then
            zones = MapInfo:GetZones(targetAgent.Movement.Position)
        end

        if zones then
            for _, zone in ipairs(zones) do
                local zLower = tostring(zone):lower()
                if zLower:find("castle") then
                    return "CASTLE"
                elseif zLower:find("underground") or zLower:find("metro") or zLower:find("subway") then
                    return "UNDERGROUND"
                end
            end
        end
    end

    if Storage and Storage.CurrentMapProfile and tostring(Storage.CurrentMapProfile) ~= "" then
        return tostring(Storage.CurrentMapProfile):upper()
    end

    return "CASTLE"
end

function LineupService:SetCurrentMapName(mapName)
    if Storage then
        if not mapName or tostring(mapName) == "" or mapName == "AUTO" then
            Storage.CurrentMapProfile = nil
        else
            Storage.CurrentMapProfile = tostring(mapName):upper()
        end
    end
    self:InvalidateCaches()
end

function LineupService:EnsureStorageStructure()
    if not Storage then return end
    local modified = false
    if not Storage.LineupsByMap then
        Storage.LineupsByMap = {}
        modified = true
    end
    if Storage.Lineups and #Storage.Lineups > 0 then
        local targetMap = "CASTLE"
        if not Storage.LineupsByMap[targetMap] then
            Storage.LineupsByMap[targetMap] = {}
        end
        for _, item in ipairs(Storage.Lineups) do
            if item then
                item.mapName = item.mapName or targetMap
                table.insert(Storage.LineupsByMap[targetMap], item)
            end
        end
        Storage.Lineups = nil
        modified = true
    end
    if Storage.LineupsByMap["DefaultMap"] and #Storage.LineupsByMap["DefaultMap"] > 0 then
        if not Storage.LineupsByMap["CASTLE"] then
            Storage.LineupsByMap["CASTLE"] = {}
        end
        for _, item in ipairs(Storage.LineupsByMap["DefaultMap"]) do
            if item then
                item.mapName = "CASTLE"
                table.insert(Storage.LineupsByMap["CASTLE"], item)
            end
        end
        Storage.LineupsByMap["DefaultMap"] = nil
        modified = true
    end
    if modified then
        Storage.LineupsByMap = Storage.LineupsByMap
        if ConfigManager and ConfigManager.Save then ConfigManager:Save() end
    end
end

function LineupService:CommitLineupsForMap(mapName, lineups)
    if not Storage then return end
    local lineupsByMap = Storage.LineupsByMap or {}
    lineupsByMap[mapName] = lineups
    Storage.LineupsByMap = lineupsByMap
end

function LineupService:GetAllLineups(mapName)
    local targetMap = mapName or self:GetCurrentMapName()
    local storageRevision = tonumber(Storage and Storage.GrenadeHelperLineupsRevision) or 0

    local cached = self.LineupsSummaryCache[targetMap]
    if cached and cached.revision == storageRevision then
        return cached.items
    end

    self:EnsureStorageStructure()
    local saved = (Storage and Storage.LineupsByMap and Storage.LineupsByMap[targetMap]) or {}
    local result = {}
    for idx, item in ipairs(saved) do
        if item then
            local idVal = item.id or ("Lineup_" .. tostring(idx))
            table.insert(result, {
                id            = idVal,
                storageIndex  = idx,
                description   = item.description or ("Lineup " .. tostring(idx)),
                grenadeType   = item.grenadeType or "Grenade",
                mapName       = item.mapName or targetMap,
                standPosition = MathUtils:CreateVector3(item.standX or 0, item.standY or 0, item.standZ or 0),
                pitch         = item.pitch or 0,
                yaw           = item.yaw or 0,
                actionsData   = item.actionsData,
                actions       = nil
            })
        end
    end

    self.LineupsSummaryCache[targetMap] = {
        revision = storageRevision,
        items = result,
    }
    return result
end

function LineupService:CaptureBaseline(agent)
    if not agent then return nil, "Agent is unavailable" end
    if not agent.Movement or not agent.Movement.Position then
        return nil, "Agent position is unavailable"
    end

    local currentItem = self:SafeGetCurrentItem(agent)
    local currentKey = self:GetExactGrenadeKey(currentItem)
    local currentName = self:SafeGetItemName(currentItem)

    if currentKey == "powershell" then currentName = "PowerShell Grenade"
    elseif currentKey == "shield" then currentName = "Shield Grenade"
    elseif currentKey == "frag" then currentName = "Frag Grenade"
    elseif currentKey == "incendiary" then currentName = "Incendiary Grenade"
    elseif currentKey == "sonar" then currentName = "Sonar Grenade"
    elseif currentKey == "emp" then currentName = "EMP Grenade" end

    if not currentItem or not self:IsAllowedGrenade(currentName, currentItem) then
        return nil, "Please equip a grenade before recording a lineup!"
    end

    local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
    if not lookRot then return nil, "Look rotation is unavailable" end

    local pos = agent.Movement.Position

    return {
        pos         = MathUtils:CreateVector3(pos.x, pos.y, pos.z),
        pitch       = lookRot.x or 0,
        yaw         = lookRot.y or 0,
        grenadeName = currentName,
    }, nil
end

function LineupService:SaveRecordedLineup(baseline, actionsTrack, mapName, rerecordId)
    if not baseline then return nil, "Missing baseline" end
    self:EnsureStorageStructure()
    local targetMap = mapName or self:GetCurrentMapName()

    if not Storage then return nil, "Storage is unavailable" end
    if not Storage.LineupsByMap[targetMap] then Storage.LineupsByMap[targetMap] = {} end
    local list = Storage.LineupsByMap[targetMap]

    if rerecordId then
        local targetIdStr = tostring(rerecordId)
        for idx, item in ipairs(list) do
            local itemIdStr = item.id and tostring(item.id) or ("Lineup_" .. tostring(idx))
            if itemIdStr == targetIdStr then
                item.standX, item.standY, item.standZ = baseline.pos.x, baseline.pos.y, baseline.pos.z
                item.pitch, item.yaw = baseline.pitch, baseline.yaw
                item.grenadeType = baseline.grenadeName
                item.actionsData = ActionCodec.Encode(actionsTrack)
                self:CommitLineupsForMap(targetMap, list)
                self.ActionsDecodeCache[item.id] = actionsTrack
                self:InvalidateCaches(targetMap)
                return { id = item.id, description = item.description, grenadeType = item.grenadeType, mapName = targetMap }, nil
            end
        end
    end

    local newIndex = #list + 1
    local timestamp = (Time and Time.Seconds and math.floor(Time.Seconds * 1000)) or math.random(100000, 999999)
    local uniqueId = "Lineup_" .. tostring(timestamp) .. "_" .. tostring(newIndex)
    local defaultDesc = "Lineup #" .. tostring(newIndex)

    local newItem = {
        id          = uniqueId,
        description = defaultDesc,
        grenadeType = baseline.grenadeName,
        mapName     = targetMap,
        standX      = baseline.pos.x,
        standY      = baseline.pos.y,
        standZ      = baseline.pos.z,
        aimX        = baseline.pos.x,
        aimY        = baseline.pos.y,
        aimZ        = baseline.pos.z,
        pitch       = baseline.pitch,
        yaw         = baseline.yaw,
        actionsData = ActionCodec.Encode(actionsTrack),
    }

    table.insert(list, newItem)
    self:CommitLineupsForMap(targetMap, list)
    self.ActionsDecodeCache[uniqueId] = actionsTrack
    self:InvalidateCaches(targetMap)

    return { id = uniqueId, description = defaultDesc, grenadeType = newItem.grenadeType, mapName = targetMap }, nil
end

function LineupService:DeleteSavedLineup(index, mapName)
    self:EnsureStorageStructure()
    local targetMap = mapName or self:GetCurrentMapName()
    local currentLineups = Storage and Storage.LineupsByMap and Storage.LineupsByMap[targetMap] or {}
    if index and currentLineups[index] then
        table.remove(currentLineups, index)
        self:CommitLineupsForMap(targetMap, currentLineups)
        self:InvalidateCaches(targetMap)
        return true
    end
    return false
end

function LineupService:DeleteLineupById(id, mapName)
    self:EnsureStorageStructure()
    local targetMap = mapName or self:GetCurrentMapName()
    local currentLineups = Storage and Storage.LineupsByMap and Storage.LineupsByMap[targetMap] or {}
    local targetIdStr = tostring(id)
    for idx, item in ipairs(currentLineups) do
        local itemIdStr = item.id and tostring(item.id) or ("Lineup_" .. tostring(idx))
        if itemIdStr == targetIdStr or tostring(idx) == targetIdStr then
            table.remove(currentLineups, idx)
            self:CommitLineupsForMap(targetMap, currentLineups)
            self:InvalidateCaches(targetMap)
            return true
        end
    end
    return false
end

function LineupService:RenameLineupById(id, newName, mapName)
    self:EnsureStorageStructure()
    local targetMap = mapName or self:GetCurrentMapName()
    local currentLineups = Storage and Storage.LineupsByMap and Storage.LineupsByMap[targetMap] or {}
    local targetIdStr = tostring(id)
    for idx, item in ipairs(currentLineups) do
        local itemIdStr = item.id and tostring(item.id) or ("Lineup_" .. tostring(idx))
        if itemIdStr == targetIdStr or tostring(idx) == targetIdStr then
            item.description = newName
            self:CommitLineupsForMap(targetMap, currentLineups)
            self:InvalidateCaches(targetMap)
            return true
        end
    end
    return false
end

LineupService.DeleteLineup = LineupService.DeleteSavedLineup

function LineupService:GetCurrentGrenadeKey(agent)
    local currentItem = self:SafeGetCurrentItem(agent)
    if not currentItem or not self:SafeIsThrowable(currentItem) then
        return "", false
    end
    return self:GetExactGrenadeKey(currentItem), true
end

function LineupService:MatchesGrenadeKey(currentKey, isThrowable, grenadeType)
    if not grenadeType or grenadeType == "" then return true end
    if not isThrowable then return false end

    local targetKey = self:StandardizeGrenadeKey(grenadeType)
    return (currentKey ~= "" and targetKey ~= "" and currentKey == targetKey)
end

function LineupService:HasGrenadeInInventory(agent, grenadeType)
    if not agent then return true end
    local currentKey, isThrowable = self:GetCurrentGrenadeKey(agent)
    return self:MatchesGrenadeKey(currentKey, isThrowable, grenadeType)
end

function LineupService:ComputeAimPoint(standPos, pitch, yaw, distance)
    local distVal  = distance or 5.0
    local yawRad   = math.rad(yaw or 0)
    local pitchRad = math.rad(pitch or 0)
    local cosPitch = math.cos(pitchRad)
    local forwardX = math.sin(yawRad) * cosPitch
    local forwardY = -math.sin(pitchRad)
    local forwardZ = math.cos(yawRad) * cosPitch

    local sx = standPos and standPos.x or 0
    local sy = standPos and standPos.y or 0
    local sz = standPos and standPos.z or 0

    return MathUtils:CreateVector3(
        sx + forwardX * distVal,
        sy + 1.6 + forwardY * distVal,
        sz + forwardZ * distVal
    )
end

function LineupService:GetCursorTargetScore(agent, lineup, currentPos, currentPitch, currentYaw)
    if not lineup or not lineup.standPosition then return 999999.0 end

    local dist = MathUtils:CalculateDistance(currentPos, lineup.standPosition)

    local camera = Cameras and Cameras.Main
    if camera and camera.WorldToViewportPoint then
        local aimPoint = self:ComputeAimPoint(lineup.standPosition, lineup.pitch or 0, lineup.yaw or 0, 5.0)
        local viewport = camera:WorldToViewportPoint(aimPoint)

        if viewport and viewport.z and viewport.z > 0 then
            local dx = (viewport.x or 0.5) - 0.5
            local dy = (viewport.y or 0.5) - 0.5
            local screenDist = math.sqrt(dx * dx + dy * dy)
            return (screenDist * 1000.0) + (dist * 0.01)
        end
    end

    local yawDiff   = MathUtils:AngleDiffDegrees(currentYaw, lineup.yaw or 0)
    local pitchDiff = math.abs(currentPitch - (lineup.pitch or 0))
    local angleDiff = math.sqrt(yawDiff * yawDiff + pitchDiff * pitchDiff)
    return (angleDiff * 100.0) + (dist * 0.01)
end

function LineupService:FindActiveLineup(agent, maxDistance, mapName)
    if not agent or not agent.Movement or not agent.Movement.Position then return nil, 999999.0, true end

    local currentPos = agent.Movement.Position
    local targetMap  = mapName or self:GetCurrentMapName()
    local mapLineups = self:GetAllLineups(targetMap)

    local currentItem = self:SafeGetCurrentItem(agent)
    local isGrenadeEquipped = true
    if currentItem then
        isGrenadeEquipped = self:IsAllowedGrenade(self:SafeGetItemName(currentItem), currentItem)
    end

    local currentKey, isThrowable = self:GetCurrentGrenadeKey(agent)

    local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
    local currentPitch = (lookRot and lookRot.x) or 0
    local currentYaw   = (lookRot and lookRot.y) or 0

    local closestLineup = nil
    local bestScore     = 999999.0
    local minDistance   = 999999.0
    local maxDistLimit  = maxDistance or (Config and Config.ActivationDistance) or 2.5

    for _, lineup in ipairs(mapLineups) do
        local hasActions = (lineup.actionsData and lineup.actionsData ~= "") or (lineup.actions ~= nil)
        if hasActions and self:MatchesGrenadeKey(currentKey, isThrowable, lineup.grenadeType) then
            local dist = MathUtils:CalculateDistance(currentPos, lineup.standPosition)
            if dist <= maxDistLimit then
                local score = self:GetCursorTargetScore(agent, lineup, currentPos, currentPitch, currentYaw)

                if score < bestScore then
                    bestScore     = score
                    minDistance   = dist
                    closestLineup = lineup
                end
            end
        end
    end

    if closestLineup and not closestLineup.actions and closestLineup.actionsData then
        closestLineup.actions = self:GetDecodedActions(closestLineup.id, closestLineup)
    end

    return closestLineup, minDistance, isGrenadeEquipped
end

function LineupService:AlignAimToTarget(agent, lineup)
    if not lineup then return end

    local pitchVal = lineup.pitch or 0
    local yawVal   = lineup.yaw   or 0

    local rotVec = MathUtils:CreateVector2(pitchVal, yawVal)
    if AgentInput and AgentInput.SetLookRotation then
        AgentInput:SetLookRotation(rotVec)
    end
end

function LineupService:AlignPositionToTarget(agent, lineup)
    if not lineup or not lineup.standPosition then return false end
    if not agent or not agent.Movement or not agent.Movement.Position then return false end

    local currentPos = agent.Movement.Position
    local targetPos = lineup.standPosition

    local dx = targetPos.x - currentPos.x
    local dz = targetPos.z - currentPos.z
    local distance = math.sqrt(dx * dx + dz * dz)

    local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
    if not lookRot then return false end

    local yawRad   = math.rad(lookRot.y or 0)
    local forwardX = math.sin(yawRad)
    local forwardZ = math.cos(yawRad)
    local rightX   = math.cos(yawRad)
    local rightZ   = -math.sin(yawRad)

    if distance <= 0.02 then
        local vel = agent.Movement.Velocity
        local velX, velZ = (vel and vel.x or 0), (vel and vel.z or 0)
        local speed = math.sqrt(velX * velX + velZ * velZ)

        if speed <= self.PREROLL_MAX_SPEED then
            self:StopPositionAlign()
            return true
        end

        local brakeX = -(velX * rightX + velZ * rightZ) / speed
        local brakeY = -(velX * forwardX + velZ * forwardZ) / speed
        if AgentInput and AgentInput.SetMoveDirection then
            AgentInput:SetMoveDirection(MathUtils:CreateVector2(brakeX, brakeY))
        end
        return false
    end

    local inv = 1.0 / distance
    local moveX = (dx * rightX + dz * rightZ) * inv
    local moveY = (dx * forwardX + dz * forwardZ) * inv

    if AgentInput and AgentInput.SetMoveDirection then
        AgentInput:SetMoveDirection(MathUtils:CreateVector2(moveX, moveY))
    end
    return false
end

function LineupService:StopPositionAlign()
    if AgentInput and AgentInput.SetMoveDirection then
        AgentInput:SetMoveDirection(MathUtils:CreateVector2(0, 0))
    end
end

function LineupService:SafeGetEnum(enumTbl, name)
    if not enumTbl or not name then return nil end
    return enumTbl[name]
end

function LineupService:GetInputButtonForGrenade(grenadeType)
    if not grenadeType or not EInputButton then return nil end
    local lowerStr = tostring(grenadeType):lower()

    if lowerStr:find("frag") or lowerStr:find("he") or lowerStr:find("fragment") then
        return self:SafeGetEnum(EInputButton, "FragGrenade")
    elseif lowerStr:find("bridge") or lowerStr:find("charge") or lowerStr:find("shield") or lowerStr:find("barrier") then
        return self:SafeGetEnum(EInputButton, "BridgeCharge") or self:SafeGetEnum(EInputButton, "PowerShell")
    elseif lowerStr:find("power") or lowerStr:find("powershell") then
        return self:SafeGetEnum(EInputButton, "PowerShell") or self:SafeGetEnum(EInputButton, "BridgeCharge")
    elseif lowerStr:find("incendiary") or lowerStr:find("molotov") or lowerStr:find("fire") or lowerStr:find("thermite") then
        return self:SafeGetEnum(EInputButton, "Incendiary")
    elseif lowerStr:find("sonar") then
        return self:SafeGetEnum(EInputButton, "Sonar")
    elseif lowerStr:find("emp") then
        return self:SafeGetEnum(EInputButton, "EmpGrenade")
    end

    return self:SafeGetEnum(EInputButton, "CycleGrenade")
end

function LineupService:EquipGrenadeForLineup(agent, lineup)
    if not agent or not lineup then return end
    if not AgentInput or not AgentInput.SetButtonState then return end

    if self.PendingEquipButton then
        AgentInput:SetButtonState(self.PendingEquipButton, false)
        self.PendingEquipButton = nil
    end

    if self:SafeIsSwitching(agent) then return end

    local lineupType = tostring(lineup.grenadeType or ""):lower()
    local currentItem = self:SafeGetCurrentItem(agent)
    local currentName = self:SafeGetItemName(currentItem)

    if currentName ~= "" then
        local lowerName = currentName:lower()
        if lineupType ~= "" and (lowerName:find(lineupType) or lineupType:find(lowerName)) then
            return
        end
    end

    local now = (Time and Time.Seconds) or 0
    if now - self.LastEquipTryTime < 0.20 then return end
    self.LastEquipTryTime = now

    local btn = self:GetInputButtonForGrenade(lineup.grenadeType)
    if btn then
        AgentInput:SetButtonState(btn, true)
        self.PendingEquipButton = btn
    end
end

function LineupService:LockActiveLineup(agent, mapName)
    local ps = self.PlaybackState
    ps.Lineup               = nil
    ps.PreRollDone          = false
    ps.StartTick            = nil
    ps.NextEventIndex       = 1
    ps.LockTick             = (Time and Time.Tick) or 0
    ps.StableTicks          = 0
    ps.PostAlignSettleTicks = 0

    if not agent or not agent.Movement or not agent.Movement.Position then return nil end

    local currentPos = agent.Movement.Position
    local targetMap  = mapName or self:GetCurrentMapName()
    local mapLineups = self:GetAllLineups(targetMap)

    local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
    local currentPitch = (lookRot and lookRot.x) or 0
    local currentYaw   = (lookRot and lookRot.y) or 0

    local activationRadius = (Config and Config.ActivationDistance) or 2.5
    local searchRadius = activationRadius

    local currentKey, isThrowable = self:GetCurrentGrenadeKey(agent)

    local best, bestScore = nil, nil
    for _, candidate in ipairs(mapLineups) do
        local hasActions = (candidate.actionsData and candidate.actionsData ~= "") or (candidate.actions ~= nil)
        if hasActions and self:MatchesGrenadeKey(currentKey, isThrowable, candidate.grenadeType) then
            local dist = MathUtils:CalculateDistance(currentPos, candidate.standPosition)
            if dist <= searchRadius then
                local score = self:GetCursorTargetScore(agent, candidate, currentPos, currentPitch, currentYaw)
                if not bestScore or score < bestScore then
                    bestScore = score
                    best = candidate
                end
            end
        end
    end

    if best and not best.actions and best.actionsData then
        best.actions = self:GetDecodedActions(best.id, best)
    end

    ps.Lineup = best
    return best
end

function LineupService:GetLockedLineup()
    return self.PlaybackState.Lineup
end

function LineupService:ResolveStateAtTick(track, elapsed)
    local ps = self.PlaybackState
    local cur = ps.Current
    local events = track.events
    local idx = ps.NextEventIndex

    while events[idx] and events[idx].t <= elapsed do
        local fields = events[idx].fields
        if fields.move    then cur.move    = fields.move    end
        if fields.look    then cur.look    = fields.look    end
        if fields.jump    ~= nil then cur.jump    = fields.jump    end
        if fields.crouch  ~= nil then cur.crouch  = fields.crouch  end
        if fields.fire    ~= nil then cur.fire    = fields.fire    end
        if fields.altFire ~= nil then cur.altFire = fields.altFire end
        idx = idx + 1
    end

    ps.NextEventIndex = idx
    return cur
end

function LineupService:StopAlignment()
    self:StopPositionAlign()

    if AgentInput and AgentInput.SetButtonState and EInputButton then
        if EInputButton.Jump then AgentInput:SetButtonState(EInputButton.Jump, false) end
        if EInputButton.Crouch then AgentInput:SetButtonState(EInputButton.Crouch, false) end
        if EInputButton.Fire then AgentInput:SetButtonState(EInputButton.Fire, false) end
        if EInputButton.AlternateFire then AgentInput:SetButtonState(EInputButton.AlternateFire, false) end
    end

    if self.PendingEquipButton and AgentInput and AgentInput.SetButtonState then
        AgentInput:SetButtonState(self.PendingEquipButton, false)
        self.PendingEquipButton = nil
    end

    local ps = self.PlaybackState
    ps.Lineup               = nil
    ps.PreRollDone          = false
    ps.StartTick            = nil
    ps.LockTick             = nil
    ps.StableTicks          = 0
    ps.PostAlignSettleTicks = 0
    ps.NextEventIndex       = 1
    ps.Current              = { move = { x = 0, y = 0 }, look = { x = 0, y = 0 }, jump = false, crouch = false, fire = false, altFire = false }
end

function LineupService:HasThrowEvent(track)
    if not track or not track.events then return false end
    for _, ev in ipairs(track.events) do
        if ev and ev.fields then
            if ev.fields.fire == true or ev.fields.altFire == true then
                return true
            end
        end
    end
    return false
end

function LineupService:UpdatePlayback(agent)
    local ps = self.PlaybackState
    local lineup = ps.Lineup
    if not lineup or not lineup.actions then return false end

    self:EquipGrenadeForLineup(agent, lineup)

    local currentItem = self:SafeGetCurrentItem(agent)
    local isSwitching = self:SafeIsSwitching(agent)
    local currentKey, isThrowable = self:GetCurrentGrenadeKey(agent)
    local grenadeReady = isThrowable and not isSwitching and self:MatchesGrenadeKey(currentKey, isThrowable, lineup.grenadeType)

    if not ps.PreRollDone then
        local preRollTicks = ((Time and Time.Tick) or 0) - (ps.LockTick or 0)
        local forced = preRollTicks > 120

        local targetCrouch = self:GetInitialLineupCrouch(lineup)

        if ps.PostAlignSettleTicks > 0 then
            if EInputButton and EInputButton.Crouch and AgentInput and AgentInput.SetButtonState then
                AgentInput:SetButtonState(EInputButton.Crouch, targetCrouch)
            end

            self:StopPositionAlign()
            self:AlignAimToTarget(agent, lineup)

            ps.PostAlignSettleTicks = ps.PostAlignSettleTicks + 1

            local requiredSettle = targetCrouch and 1 or self.SETTLE_DELAY_TICKS

            if (ps.PostAlignSettleTicks >= requiredSettle and grenadeReady) or forced then
                ps.PreRollDone    = true
                ps.StartTick      = (Time and Time.Tick) or 0
                ps.NextEventIndex = 1
                ps.Current = {
                    move = { x = 0, y = 0 }, look = { x = lineup.pitch or 0, y = lineup.yaw or 0 },
                    jump = false, crouch = targetCrouch, fire = false, altFire = false,
                }
            end
            return true
        end

        local currentPos = agent and agent.Movement and agent.Movement.Position
        local targetPos  = lineup and lineup.standPosition
        local distToTarget = 99.0
        if currentPos and targetPos and currentPos.x and targetPos.x then
            local dx = targetPos.x - currentPos.x
            local dz = targetPos.z - currentPos.z
            distToTarget = math.sqrt(dx * dx + dz * dz)
        end

        local shouldCrouch = (distToTarget <= 0.25)
        if EInputButton and EInputButton.Crouch and AgentInput and AgentInput.SetButtonState then
            AgentInput:SetButtonState(EInputButton.Crouch, shouldCrouch)
        end

        local reachedPos = self:AlignPositionToTarget(agent, lineup)
        self:AlignAimToTarget(agent, lineup)

        local reachedAim = true
        local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
        if lookRot then
            local pitchDiff = math.abs((lookRot.x or 0) - (lineup.pitch or 0))
            local yawDiff = MathUtils:AngleDiffDegrees(lookRot.y or 0, lineup.yaw or 0)
            reachedAim = pitchDiff <= 0.25 and yawDiff <= 0.25
        end

        if forced then
            reachedPos, reachedAim = true, true
        end

        if reachedPos and reachedAim and (grenadeReady or forced) then
            ps.StableTicks = ps.StableTicks + 1
        else
            ps.StableTicks = 0
        end

        if ps.StableTicks >= self.PREROLL_STABLE_TICKS_REQUIRED or forced then
            self:StopPositionAlign()
            ps.PostAlignSettleTicks = 1
        end

        return true
    end

    local elapsed = ((Time and Time.Tick) or 0) - ps.StartTick
    local duration = (lineup.actions and lineup.actions.durationTicks) or 0
    if duration <= 1 then duration = 6 end

    if elapsed >= duration then
        self:StopAlignment()
        return false
    end

    local state = self:ResolveStateAtTick(lineup.actions, elapsed)
    local fallbackThrow = not self:HasThrowEvent(lineup.actions) and (elapsed >= 0 and elapsed <= 5)

    if AgentInput and AgentInput.SetMoveDirection then
        AgentInput:SetMoveDirection(MathUtils:CreateVector2(state.move.x, state.move.y))
    end
    if AgentInput and AgentInput.SetButtonState and EInputButton then
        if EInputButton.Jump then AgentInput:SetButtonState(EInputButton.Jump, state.jump == true) end
        if EInputButton.Crouch then AgentInput:SetButtonState(EInputButton.Crouch, state.crouch == true) end

        local doFire = (state.fire == true) or fallbackThrow
        local doAltFire = (state.altFire == true)

        if EInputButton.Fire then AgentInput:SetButtonState(EInputButton.Fire, doFire) end
        if EInputButton.AlternateFire then AgentInput:SetButtonState(EInputButton.AlternateFire, doAltFire) end
    end
    if AgentInput and AgentInput.SetLookRotation then
        AgentInput:SetLookRotation(MathUtils:CreateVector2(state.look.x, state.look.y))
    end

    return true
end

return LineupService
