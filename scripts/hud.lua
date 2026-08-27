-- ============================================================================
-- GrenadeHelper - Cyberpunk Tactical ESP & World Visuals Component (Nil-Safe)
-- ============================================================================

local LineupService = require("lineup_service")
local Recorder      = require("action_recorder")
local MathUtils     = require("math_utils")

local CreateVector3    = MathUtils.CreateVector3
local AngleDiffDegrees = MathUtils.AngleDiffDegrees

local HUD = {}

local HudRoot          = nil
local HudRootContainer = nil
local OverlayPool      = {}
local TagPool          = {}
local AimMarkerPool    = {}

local function CreateColor(r, g, b, a)
    if Color and Color.new then
        return Color.new(r or 1, g or 1, b or 1, a or 1)
    end
    return Color(r or 1, g or 1, b or 1, a or 1)
end

local function ParseRGB(hexStr)
    if not hexStr or tostring(hexStr) == "" then
        return 0.0, 1.0, 0.61
    end
    local cleanHex = tostring(hexStr):gsub("#", "")
    local r = tonumber(cleanHex:sub(1, 2), 16) or 0
    local g = tonumber(cleanHex:sub(3, 4), 16) or 255
    local b = tonumber(cleanHex:sub(5, 6), 16) or 157
    return r / 255, g / 255, b / 255
end

local function ComputeAimPoint(standPos, pitch, yaw, distance)
    local yawRad   = math.rad(yaw or 0)
    local pitchRad = math.rad(pitch or 0)
    local cosPitch = math.cos(pitchRad)
    local forwardX = math.sin(yawRad) * cosPitch
    local forwardY = -math.sin(pitchRad)
    local forwardZ = math.cos(yawRad) * cosPitch

    local sx = standPos and standPos.x or 0
    local sy = standPos and standPos.y or 0
    local sz = standPos and standPos.z or 0

    return CreateVector3(
        sx + forwardX * distance,
        sy + 1.6 + forwardY * distance,
        sz + forwardZ * distance
    )
end

local function FindChild(parent, name)
    if not parent then return nil end
    if parent.GetChild then
        return parent:GetChild(name)
    end
    return nil
end

local function FormatGrenadeType(typeName)
    if not typeName or typeName == "" then return "GRENADE" end
    local lowerStr = tostring(typeName):lower()

    if lowerStr:find("power") or lowerStr:find("powershell") then
        return "POWERSHIELD"
    elseif lowerStr:find("shield") or lowerStr:find("barrier") or lowerStr:find("bridge") or lowerStr:find("charge") then
        return "SHIELD"
    elseif lowerStr:find("frag") or lowerStr:find("he") or lowerStr:find("fragment") then
        return "FRAG"
    elseif lowerStr:find("incendiary") or lowerStr:find("molotov") or lowerStr:find("fire") or lowerStr:find("thermite") then
        return "INCENDIARY"
    elseif lowerStr:find("sonar") then
        return "SONAR"
    elseif lowerStr:find("emp") then
        return "EMP"
    end

    return string.upper(tostring(typeName))
end

local function UpdateTagTypeClass(element, typeName)
    if not element or not element.EnableInClassList then return end
    local lower = tostring(typeName):lower()

    element:EnableInClassList("gh-type-frag", lower:find("frag") ~= nil or lower:find("he") ~= nil)
    element:EnableInClassList("gh-type-shield", lower:find("shield") ~= nil or lower:find("power") ~= nil or lower:find("barrier") ~= nil)
    element:EnableInClassList("gh-type-incendiary", lower:find("incendiary") ~= nil or lower:find("molotov") ~= nil or lower:find("fire") ~= nil)
    element:EnableInClassList("gh-type-sonar", lower:find("sonar") ~= nil)
    element:EnableInClassList("gh-type-emp", lower:find("emp") ~= nil)

    local isCustom = (lower:find("frag") or lower:find("he") or lower:find("shield") or lower:find("power") or lower:find("barrier") or lower:find("incendiary") or lower:find("molotov") or lower:find("fire") or lower:find("sonar") or lower:find("emp")) ~= nil
    element:EnableInClassList("gh-type-default", not isCustom)
end

function HUD:Init()
    if UI and UI.BuildFromUxmlAbsolute and not HudRoot then
        HudRoot = UI:BuildFromUxmlAbsolute("hud_root.uxml")
        if HudRoot then
            HudRootContainer = FindChild(HudRoot, "HudRoot") or HudRoot
        end
    end
end

local function GetOrCreateOverlay(index)
    local overlay = OverlayPool[index]
    if not overlay and WorldVisuals and WorldVisuals.CreateSurfaceOverlay then
        overlay = WorldVisuals:CreateSurfaceOverlay()
        if overlay then
            local radius = 0.65
            local diameter = radius * 2.0
            if overlay.SetSize then overlay:SetSize(CreateVector3(diameter, diameter, diameter)) end
            if overlay.SetFillBase then overlay:SetFillBase(1.0) end
            if overlay.SetOcclusionEnabled then overlay:SetOcclusionEnabled(false) end
            if overlay.SetVisible then overlay:SetVisible(false) end
            OverlayPool[index] = overlay
        end
    end
    return overlay
end

local function GetOrCreateTag(index)
    local tag = TagPool[index]
    if not tag and HudRootContainer and UI and UI.CreateVisualElement and UI.CreateLabel then
        local container = UI:CreateVisualElement()
        if container then
            container:AddToClassList("gh-world-tag")

            local typeLabel = UI:CreateLabel()
            typeLabel:AddToClassList("gh-tag-type")

            local titleLabel = UI:CreateLabel()
            titleLabel:AddToClassList("gh-tag-title")

            local subLabel = UI:CreateLabel()
            subLabel:AddToClassList("gh-tag-sub")

            container:Add(typeLabel)
            container:Add(titleLabel)
            container:Add(subLabel)

            HudRootContainer:Add(container)

            tag = {
                container  = container,
                typeLabel  = typeLabel,
                titleLabel = titleLabel,
                subLabel   = subLabel
            }
            TagPool[index] = tag
        end
    end
    return tag
end

local function GetOrCreateAimMarker(index)
    local marker = AimMarkerPool[index]
    if not marker and HudRootContainer and UI and UI.CreateVisualElement then
        local dot = UI:CreateVisualElement()
        if dot then
            dot:AddToClassList("gh-aim-marker")
            dot:AddToClassList("gh-aim-marker-unaligned")

            local innerDot = UI:CreateVisualElement()
            innerDot:AddToClassList("gh-aim-dot-inner")
            innerDot:AddToClassList("gh-aim-dot-unaligned")
            dot:Add(innerDot)

            local label = UI:CreateLabel()
            label:AddToClassList("gh-aim-label")
            dot:Add(label)

            HudRootContainer:Add(dot)
            marker = { dot = dot, innerDot = innerDot, label = label }
            AimMarkerPool[index] = marker
        end
    end
    return marker
end

function HUD:Render(activeLineup, isAligning, agent)
    if not HudRoot then
        self:Init()
    end

    local isRecording = Recorder and Recorder.Recording == true

    -- Render UXML Recording Banner notification
    if HudRootContainer then
        local recBanner = FindChild(HudRootContainer, "RecordingBanner")
        if recBanner then
            recBanner.visible = isRecording
            if recBanner.style and DisplayStyle then
                recBanner.style.display = isRecording and DisplayStyle.Flex or DisplayStyle.None
            end
            if recBanner.EnableInClassList then
                recBanner:EnableInClassList("gh-hidden", not isRecording)
            end
        end
    end

    -- Render ImGui Recording Banner notification
    if isRecording and ImGui and ImGui.Begin and Screen then
        local sw = (Screen and Screen.Width) or 1920
        if ImGui.SetNextWindowPos then
            ImGui.SetNextWindowPos(sw * 0.5 - 200, 35)
        end
        if ImGui.SetNextWindowSize then
            ImGui.SetNextWindowSize(400, 45)
        end
        local flags = (ImGuiWindowFlags and (ImGuiWindowFlags.NoDecoration + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoInputs)) or 0
        if ImGui.Begin("GH_Rec_Banner", nil, flags) then
            if ImGui.TextColored then
                ImGui.TextColored(1.0, 0.25, 0.25, 1.0, "REC - RECORDING IN PROGRESS")
                ImGui.TextColored(0.8, 0.8, 0.8, 1.0, "Throw grenade or press F1 to save")
            end
            ImGui.End()
        end
    end

    local lineups = LineupService:GetAllLineups()
    if not lineups then lineups = {} end

    local agentPos = agent and agent.Movement and agent.Movement.Position
    local camera   = Cameras and Cameras.Main

    local lookRot = AgentInput and AgentInput.GetLookRotation and AgentInput:GetLookRotation()
    local currentYaw = lookRot and lookRot.y

    local currentKey, isThrowable = LineupService:GetCurrentGrenadeKey(agent)
    local r, g, b = ParseRGB(Config and Config.MarkerColor or "#00FF9D")

    local fadeStartDist = 18.0
    local fadeFullDist  = 4.0

    local isAlwaysShowEnabled = (Storage and Storage.ShowAllLineupsWithoutGrenade == true) or (Config and Config.ShowAllLineupsWithoutGrenade == true)
    local isAltHeld = false
    if InputActions and InputActions.FindAction then
        local alignAct = InputActions:FindAction("AlignLineup")
        if alignAct and alignAct.IsPressed and alignAct:IsPressed() then
            isAltHeld = true
        end
    end
    local allowAllLineups = isAlwaysShowEnabled or isAltHeld

    local visibleTagCount = 0
    local visibleMarkerCount = 0
    local visibleOverlayCount = 0

    -- Phase 1: Cluster nearby standing positions for ground tags & 3D overlays
    local clusters = {}
    for _, lineup in ipairs(lineups) do
        if lineup and lineup.standPosition and lineup.standPosition.x then
            local matchesGrenade = LineupService:MatchesGrenadeKey(currentKey, isThrowable, lineup.grenadeType)
            local hasGrenade = isThrowable and matchesGrenade or (allowAllLineups or matchesGrenade)
            local sp = lineup.standPosition

            local distToPlayer = 999.0
            if agentPos and agentPos.x then
                local dx = sp.x - agentPos.x
                local dy = (sp.y or 0) - (agentPos.y or 0)
                local dz = sp.z - agentPos.z
                distToPlayer = math.sqrt(dx * dx + dy * dy + dz * dz)
            end

            local opacity = 0.0
            if hasGrenade then
                if distToPlayer <= fadeFullDist then
                    opacity = 1.0
                elseif distToPlayer <= fadeStartDist then
                    opacity = (fadeStartDist - distToPlayer) / (fadeStartDist - fadeFullDist)
                end
            end

            if opacity > 0.01 then
                local foundCluster = nil
                for _, cl in ipairs(clusters) do
                    local cx = cl.center.x - sp.x
                    local cy = (cl.center.y or 0) - (sp.y or 0)
                    local cz = cl.center.z - sp.z
                    local distBetween = math.sqrt(cx * cx + cy * cy + cz * cz)
                    if distBetween <= 1.0 then
                        foundCluster = cl
                        break
                    end
                end

                if not foundCluster then
                    foundCluster = {
                        center = sp,
                        minDist = distToPlayer,
                        maxOpacity = opacity,
                        items = {},
                        typeCounts = {},
                        hasActive = false
                    }
                    table.insert(clusters, foundCluster)
                end

                table.insert(foundCluster.items, lineup)
                if distToPlayer < foundCluster.minDist then
                    foundCluster.minDist = distToPlayer
                end
                if opacity > foundCluster.maxOpacity then
                    foundCluster.maxOpacity = opacity
                end

                if activeLineup and activeLineup.id == lineup.id then
                    foundCluster.hasActive = true
                end

                local gType = FormatGrenadeType(lineup.grenadeType)
                foundCluster.typeCounts[gType] = (foundCluster.typeCounts[gType] or 0) + 1
            end
        end
    end

    local function FormatClusterSummary(typeCounts)
        local parts = {}
        local order = { "SONAR", "EMP", "INCENDIARY", "FRAG", "SHIELD", "POWERSHIELD", "GRENADE" }
        local seen = {}
        for _, t in ipairs(order) do
            local count = typeCounts[t]
            if count and count > 0 then
                table.insert(parts, t .. " - " .. tostring(count))
                seen[t] = true
            end
        end
        for t, count in pairs(typeCounts) do
            if not seen[t] and count > 0 then
                table.insert(parts, tostring(t) .. " - " .. tostring(count))
            end
        end
        return table.concat(parts, "  ")
    end

    -- Render Ground Tags & 3D Surface Overlays for Clusters
    for _, cl in ipairs(clusters) do
        local sp = cl.center
        local opacity = cl.maxOpacity

        visibleOverlayCount = visibleOverlayCount + 1
        local overlay = GetOrCreateOverlay(visibleOverlayCount)
        if overlay and overlay.SetPosition and overlay.SetColor and overlay.SetVisible then
            overlay:SetPosition(CreateVector3(sp.x, (sp.y or 0) + 0.05, sp.z))
            local circleAlpha = (cl.hasActive and isAligning) and (0.80 * opacity) or (0.50 * opacity)
            overlay:SetColor(CreateColor(r, g, b, circleAlpha))
            overlay:SetVisible(true)
        end

        if camera and camera.WorldToViewportPoint and UI and UI.ViewportToUiPoint then
            visibleTagCount = visibleTagCount + 1
            local tag = GetOrCreateTag(visibleTagCount)
            if tag then
                local worldPos = CreateVector3(sp.x, (sp.y or 0) + 1.25, sp.z)
                local viewport = camera:WorldToViewportPoint(worldPos)

                if viewport and viewport.z and viewport.z > 0 then
                    local uiPoint = UI:ViewportToUiPoint(viewport)
                    if uiPoint and uiPoint.x and tag.container and tag.container.style then
                        tag.container.style.left = uiPoint.x
                        tag.container.style.top  = uiPoint.y
                        tag.container.style.opacity = opacity

                        if #cl.items == 1 then
                            local lineup = cl.items[1]
                            local formattedType = FormatGrenadeType(lineup.grenadeType)
                            if tag.typeLabel then
                                tag.typeLabel.text = formattedType
                                UpdateTagTypeClass(tag.typeLabel, formattedType)
                            end
                            if tag.titleLabel then
                                tag.titleLabel.text = string.upper(tostring(lineup.description or "LINEUP"))
                            end
                        else
                            if tag.typeLabel then
                                tag.typeLabel.text = "POS (" .. tostring(#cl.items) .. ")"
                                UpdateTagTypeClass(tag.typeLabel, "default")
                            end
                            if tag.titleLabel then
                                tag.titleLabel.text = FormatClusterSummary(cl.typeCounts)
                            end
                        end

                        if tag.subLabel then
                            if cl.hasActive and isAligning then
                                tag.subLabel.text = "[ ALIGNING ]"
                                if tag.subLabel.EnableInClassList then tag.subLabel:EnableInClassList("is-aligning", true) end
                            else
                                tag.subLabel.text = string.format("[ %.1fm ]", cl.minDist)
                                if tag.subLabel.EnableInClassList then tag.subLabel:EnableInClassList("is-aligning", false) end
                            end
                        end

                        tag.container.visible = true
                        if DisplayStyle then tag.container.style.display = DisplayStyle.Flex end
                    elseif tag.container then
                        tag.container.visible = false
                        if tag.container.style and DisplayStyle then tag.container.style.display = DisplayStyle.None end
                    end
                elseif tag.container then
                    tag.container.visible = false
                    if tag.container.style and DisplayStyle then tag.container.style.display = DisplayStyle.None end
                end
            end
        end
    end

    -- Phase 2: Render Sky Aim Markers for nearby lineups
    local matchRadius = (Config and Config.ActivationDistance) or 2.5
    local showSkyLabels = (Config and Config.ShowSkyTargetLabels ~= false)

    for _, lineup in ipairs(lineups) do
        if lineup and lineup.standPosition and lineup.standPosition.x then
            local matchesGrenade = LineupService:MatchesGrenadeKey(currentKey, isThrowable, lineup.grenadeType)
            local hasGrenade = isThrowable and matchesGrenade or (allowAllLineups or matchesGrenade)
            local sp = lineup.standPosition
            local distToPlayer = 999.0
            if agentPos and sp and agentPos.x and sp.x then
                local dx = sp.x - agentPos.x
                local dy = (sp.y or 0) - (agentPos.y or 0)
                local dz = sp.z - agentPos.z
                distToPlayer = math.sqrt(dx * dx + dy * dy + dz * dz)
            end

            local showMarker = (lineup.actionsData or lineup.actions) and hasGrenade and sp and sp.x
                and distToPlayer <= matchRadius
                and camera and camera.WorldToViewportPoint and UI and UI.ViewportToUiPoint

            if showMarker then
                local aimPoint = ComputeAimPoint(sp, lineup.pitch, lineup.yaw, 5.0)
                local viewport = camera:WorldToViewportPoint(aimPoint)

                if viewport and viewport.z and viewport.z > 0 then
                    local uiPoint = UI:ViewportToUiPoint(viewport)
                    if uiPoint and uiPoint.x then
                        visibleMarkerCount = visibleMarkerCount + 1
                        local marker = GetOrCreateAimMarker(visibleMarkerCount)
                        if marker and marker.dot and marker.dot.style then
                            marker.dot.style.left = uiPoint.x
                            marker.dot.style.top  = uiPoint.y

                            if marker.label then
                                if showSkyLabels then
                                    local desc = string.upper(tostring(lineup.description or "AIM POINT"))
                                    local gType = FormatGrenadeType(lineup.grenadeType)
                                    marker.label.text = desc .. " [" .. gType .. "]"
                                    if DisplayStyle then marker.label.style.display = DisplayStyle.Flex end
                                else
                                    if DisplayStyle then marker.label.style.display = DisplayStyle.None end
                                end
                            end

                            -- ONLY the single active lineup selected by FindActiveLineup turns green!
                            local isSelected = (activeLineup and activeLineup.id == lineup.id)
                            local aligned = isSelected and currentYaw and (AngleDiffDegrees(currentYaw, lineup.yaw or 0) <= 20)
                            if marker.dot.EnableInClassList then
                                marker.dot:EnableInClassList("gh-aim-marker-aligned", aligned == true)
                                marker.dot:EnableInClassList("gh-aim-marker-unaligned", aligned == false)
                            end
                            if marker.innerDot and marker.innerDot.EnableInClassList then
                                marker.innerDot:EnableInClassList("gh-aim-dot-aligned", aligned == true)
                                marker.innerDot:EnableInClassList("gh-aim-dot-unaligned", aligned == false)
                            end

                            marker.dot.visible = true
                            if marker.dot.style and DisplayStyle then
                                marker.dot.style.display = DisplayStyle.Flex
                            end
                        end
                    end
                end
            end
        end
    end

    -- Safely trim excess 3D surface overlays and release spawner slots back to WorldVisuals
    for i = #OverlayPool, visibleOverlayCount + 1, -1 do
        local overlay = OverlayPool[i]
        if overlay then
            if overlay.SetVisible then overlay:SetVisible(false) end
            if WorldVisuals and WorldVisuals.RemoveObject then
                WorldVisuals:RemoveObject(overlay)
            end
        end
        OverlayPool[i] = nil
    end

    -- Trim excess tags beyond visible count to keep element count minimal
    for i = #TagPool, visibleTagCount + 1, -1 do
        local tag = TagPool[i]
        if tag and tag.container then
            if tag.container.RemoveFromHierarchy then tag.container:RemoveFromHierarchy() end
            if tag.container.Delete then tag.container:Delete()
            elseif UI and UI.Delete then UI:Delete(tag.container) end
        end
        TagPool[i] = nil
    end

    -- Trim excess reticle markers beyond visible count
    for i = #AimMarkerPool, visibleMarkerCount + 1, -1 do
        local marker = AimMarkerPool[i]
        if marker and marker.dot then
            if marker.dot.RemoveFromHierarchy then marker.dot:RemoveFromHierarchy() end
            if marker.dot.Delete then marker.dot:Delete()
            elseif UI and UI.Delete then UI:Delete(marker.dot) end
        end
        AimMarkerPool[i] = nil
    end
end

return HUD
