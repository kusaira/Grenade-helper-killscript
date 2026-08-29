-- ============================================================================
-- GrenadeHelper - Cyberpunk Tactical HUD Menu GUI Controller Class
-- ============================================================================

local LineupService = require("lineup_service")
local Recorder      = require("action_recorder")
local JsonUtility   = require("json_utility")
local ActionCodec   = require("action_codec")

local ModernMenu = {
    PANEL_WIDTH  = 920,
    PANEL_HEIGHT = 540,
    Root = nil,
    Panel = nil,
    IsOpenState = false,
    CurrentPage = "Lineups",
    DragHandle = nil,
    ClickAction = nil,
    Dragging = false,
    DragStartMouse = nil,
    DragStartX = 0,
    DragStartY = 0,
    OffsetX = tonumber(Storage and Storage.GrenadeHelperMenuX),
    OffsetY = tonumber(Storage and Storage.GrenadeHelperMenuY),
    CurrentRenameLineupId = nil,
    SearchQuery = "",
    TypeFilter = "ALL",
    Ui = {},
    Pages = {},
    Tabs = {},
    LineupRowPool = {},
}

function ModernMenu:Find(name)
    if not self.Root then return nil end
    if not self.ElementCache then self.ElementCache = {} end
    local cached = self.ElementCache[name]
    if cached then return cached end

    local child = self.Root:GetChild(name)
    if child then
        self.ElementCache[name] = child
    end
    return child
end

function ModernMenu:GetWindowScale()
    local scale = self.Panel and self.Panel.windowScale
    if not scale or scale <= 0 then return 1 end
    return scale
end

function ModernMenu:GetUiExtents()
    if UI and UI.ViewportToUiPoint and Vector3 and Vector3.new then
        local bottomLeft = UI:ViewportToUiPoint(Vector3.new(0.0, 0.0, 0.0))
        local topRight   = UI:ViewportToUiPoint(Vector3.new(1.0, 1.0, 0.0))
        if bottomLeft and topRight and bottomLeft.x and topRight.x then
            local scale = self:GetWindowScale()
            local width  = math.abs(topRight.x - bottomLeft.x) / scale
            local height = math.abs(topRight.y - bottomLeft.y) / scale
            if width > 1.0 and height > 1.0 then return width, height end
        end
    end
    return 1920.0, 1080.0
end

function ModernMenu:GetMouseUiPosition()
    if not UI or not UI.GetMousePosition or not Vector3 or not Vector3.new then return nil end
    local mouse = UI:GetMousePosition()
    local screenWidth = (Screen and Screen.Width) or 1920
    local screenHeight = (Screen and Screen.Height) or 1080
    if not mouse or screenWidth <= 0 or screenHeight <= 0 then
        return nil
    end
    local uiPoint = UI:ViewportToUiPoint(Vector3.new(mouse.x / screenWidth, mouse.y / screenHeight, 0))
    if not uiPoint then return nil end
    local scale = self:GetWindowScale()
    return { x = uiPoint.x / scale, y = uiPoint.y / scale }
end

function ModernMenu:ClampPosition(x, y)
    local width, height = self:GetUiExtents()
    local maxX = math.max(0, width - self.PANEL_WIDTH)
    local maxY = math.max(0, height - self.PANEL_HEIGHT)
    return math.max(0, math.min(maxX, x)), math.max(0, math.min(maxY, y))
end

function ModernMenu:ApplyPosition(save)
    if not self.Panel then return end

    local uiW, uiH = self:GetUiExtents()
    if not self.OffsetX or self.OffsetX <= 5 or self.OffsetX > (uiW - 50) then
        self.OffsetX = math.floor((uiW - self.PANEL_WIDTH) * 0.5)
    end
    if not self.OffsetY or self.OffsetY <= 5 or self.OffsetY > (uiH - 50) then
        self.OffsetY = math.floor((uiH - self.PANEL_HEIGHT) * 0.5)
    end

    self.OffsetX, self.OffsetY = self:ClampPosition(self.OffsetX, self.OffsetY)
    if self.Panel.style then
        self.Panel.style.left = self.OffsetX
        self.Panel.style.top  = self.OffsetY
    end

    if save and Storage then
        Storage.GrenadeHelperMenuX = self.OffsetX
        Storage.GrenadeHelperMenuY = self.OffsetY
    end
end

function ModernMenu:ShowPage(name)
    self.CurrentPage = name
    for pageName, page in pairs(self.Pages) do
        if page then
            local active = pageName == name
            page.visible = active
            if page.style and DisplayStyle then
                page.style.display = active and DisplayStyle.Flex or DisplayStyle.None
            end
            local tab = self.Tabs[pageName]
            if tab and tab.EnableInClassList then
                tab:EnableInClassList("is-active", active)
            end
        end
    end
end

function ModernMenu:FormatGrenadeType(typeName)
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

function ModernMenu:UpdateTagTypeClass(element, typeName)
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

function ModernMenu:OpenRenameModal(item)
    if not item then return end
    self.CurrentRenameLineupId = item.id

    local modal = self:Find("veM2RenameModal")
    local textInput = self:Find("txtM2RenameInput")

    if modal then
        modal.visible = true
        if modal.style and DisplayStyle then
            modal.style.display = DisplayStyle.Flex
        end
    end

    if textInput and item.description then
        textInput.value = tostring(item.description)
        if textInput.Focus then textInput:Focus() end
    end
end

function ModernMenu.OpenRenameModalForLineup(item)
    if not item then return end
    ModernMenu:Open()
    ModernMenu:OpenRenameModal(item)
end

function ModernMenu:CloseRenameModal()
    self.CurrentRenameLineupId = nil
    local modal = self:Find("veM2RenameModal")
    if modal then
        modal.visible = false
        if modal.style and DisplayStyle then
            modal.style.display = DisplayStyle.None
        end
    end
end

function ModernMenu:RefreshLineupsList()
    local container = self:Find("veM2LineupList")
    if not container then return end

    local activeMap = LineupService:GetCurrentMapName()
    local captionLabel = self:Find("lblM2CurrentMapCaption")
    if captionLabel then
        captionLabel.text = string.format("INDEX OF SAVED GRENADE TARGETS [MAP: %s]", string.upper(tostring(activeMap or "AUTO")))
    end

    local txtSearch = self:Find("txtM2SearchInput")
    if txtSearch then
        local rawText = txtSearch.value
        if rawText then
            self.SearchQuery = tostring(rawText)
        end
    end

    local emptyLabel = self:Find("lblM2EmptyLineups")
    local rawLineups = LineupService:GetAllLineups(activeMap)
    local lineups = {}
    local query = tostring(self.SearchQuery or ""):lower()
    local filter = tostring(self.TypeFilter or "ALL"):upper()

    if rawLineups then
        for _, item in ipairs(rawLineups) do
            local matchesText = true
            if query ~= "" then
                local desc = tostring(item.description or ""):lower()
                local gtype = tostring(item.grenadeType or ""):lower()
                matchesText = (desc:find(query, 1, true) ~= nil) or (gtype:find(query, 1, true) ~= nil)
            end

            local matchesCategory = true
            if filter ~= "ALL" then
                local gtype = tostring(item.grenadeType or ""):upper()
                if filter == "SONAR" then
                    matchesCategory = (gtype:find("SONAR") ~= nil)
                elseif filter == "EMP" then
                    matchesCategory = (gtype:find("EMP") ~= nil)
                elseif filter == "FRAG" then
                    matchesCategory = (gtype:find("FRAG") ~= nil or gtype:find("HE") ~= nil)
                elseif filter == "FIRE" then
                    matchesCategory = (gtype:find("INCENDIARY") ~= nil or gtype:find("MOLOTOV") ~= nil or gtype:find("FIRE") ~= nil)
                end
            end

            if matchesText and matchesCategory then
                table.insert(lineups, item)
            end
        end
    end

    if not lineups or #lineups == 0 then
        if emptyLabel then
            emptyLabel.visible = true
            if emptyLabel.style and DisplayStyle then
                emptyLabel.style.display = DisplayStyle.Flex
            end
        end
        for _, poolItem in ipairs(self.LineupRowPool) do
            if poolItem and poolItem.row then
                poolItem.row.visible = false
                if poolItem.row.style and DisplayStyle then
                    poolItem.row.style.display = DisplayStyle.None
                end
            end
        end
        return
    end

    if emptyLabel then
        emptyLabel.visible = false
        if emptyLabel.style and DisplayStyle then
            emptyLabel.style.display = DisplayStyle.None
        end
    end

    if not UI or not UI.CreateVisualElement or not UI.CreateLabel then
        return
    end

    for index, item in ipairs(lineups) do
        local poolItem = self.LineupRowPool[index]
        if not poolItem or not poolItem.indexLabel then
            local row = UI:CreateVisualElement()
            if not row then break end
            row:AddToClassList("cmd-lineup-item")

            local infoBox = UI:CreateVisualElement()
            infoBox:AddToClassList("cmd-lineup-info")

            local headerRow = UI:CreateVisualElement()
            headerRow:AddToClassList("cmd-lineup-header-row")

            local indexLabel = UI:CreateLabel()
            indexLabel:AddToClassList("cmd-lineup-index")

            local typeBadge = UI:CreateLabel()
            typeBadge:AddToClassList("cmd-lineup-type-badge")

            local titleLabel = UI:CreateLabel()
            titleLabel:AddToClassList("cmd-lineup-title")

            headerRow:Add(indexLabel)
            headerRow:Add(typeBadge)
            headerRow:Add(titleLabel)

            local detailLabel = UI:CreateLabel()
            detailLabel:AddToClassList("cmd-lineup-detail")

            infoBox:Add(headerRow)
            infoBox:Add(detailLabel)

            local actionBox = UI:CreateVisualElement()
            actionBox:AddToClassList("cmd-action-box")

            local rerecordBtn = UI:CreateLabel()
            rerecordBtn.text = "[ RE-RECORD ]"
            rerecordBtn:AddToClassList("cmd-btn-rerecord")
            if rerecordBtn.SetCursor then rerecordBtn:SetCursor("hand") end
            if rerecordBtn.EnableMouseEvents then rerecordBtn:EnableMouseEvents() end

            local renameBtn = UI:CreateLabel()
            renameBtn.text = "[ RENAME ]"
            renameBtn:AddToClassList("cmd-btn-rename")
            if renameBtn.SetCursor then renameBtn:SetCursor("hand") end
            if renameBtn.EnableMouseEvents then renameBtn:EnableMouseEvents() end

            local delBtn = UI:CreateLabel()
            delBtn.text = "[ DELETE ]"
            delBtn:AddToClassList("cmd-btn-delete")
            if delBtn.SetCursor then delBtn:SetCursor("hand") end
            if delBtn.EnableMouseEvents then delBtn:EnableMouseEvents() end

            actionBox:Add(rerecordBtn)
            actionBox:Add(renameBtn)
            actionBox:Add(delBtn)

            row:Add(infoBox)
            row:Add(actionBox)
            container:Add(row)

            poolItem = {
                row = row,
                indexLabel = indexLabel,
                typeBadge = typeBadge,
                titleLabel = titleLabel,
                detailLabel = detailLabel,
                renameBtn = renameBtn,
                delBtn = delBtn,
                rerecordBtn = rerecordBtn
            }
            self.LineupRowPool[index] = poolItem
        end

        if poolItem.indexLabel then
            poolItem.indexLabel.text = string.format("#%02d", index)
        end

        if poolItem.titleLabel then
            poolItem.titleLabel.text = string.upper(tostring(item.description or "TARGET"))
        end

        if poolItem.typeBadge then
            local gTypeStr = self:FormatGrenadeType(item.grenadeType)
            poolItem.typeBadge.text = gTypeStr
            self:UpdateTagTypeClass(poolItem.typeBadge, gTypeStr)
        end

        if poolItem.detailLabel then
            local posText
            local hasActions = (item.actionsData and item.actionsData ~= "") or (item.actions ~= nil)
            if hasActions then
                local sx = (item.standPosition and item.standPosition.x) or item.standX or 0
                local sy = (item.standPosition and item.standPosition.y) or item.standY or 0
                local sz = (item.standPosition and item.standPosition.z) or item.standZ or 0
                local durationTicks = (item.actions and item.actions.durationTicks)
                    or (ActionCodec and ActionCodec.GetDurationTicks and ActionCodec.GetDurationTicks(item.actionsData))
                    or 0
                posText = string.format("  STAND: (%.1f, %.1f, %.1f) | PITCH: %.1f deg  YAW: %.1f deg | REC: %d ticks",
                    sx, sy, sz,
                    item.pitch or 0, item.yaw or 0,
                    durationTicks)
            else
                posText = "  [LEGACY DATA - NOT SUPPORTED, DELETE OR RE-RECORD]"
            end
            poolItem.detailLabel.text = posText
        end

        local currentItem = item

        if poolItem.renameBtn and poolItem.renameBtn.OnClick then
            poolItem.renameBtn:OnClick(function()
                ModernMenu:OpenRenameModal(currentItem)
            end)
        end

        local lineupId = item.id
        local storageIdx = item.storageIndex

        if poolItem.delBtn and poolItem.delBtn.OnClick then
            poolItem.delBtn:OnClick(function()
                if lineupId then
                    LineupService:DeleteLineupById(lineupId, activeMap)
                elseif storageIdx then
                    LineupService:DeleteSavedLineup(storageIdx, activeMap)
                end
                ModernMenu:RefreshLineupsList()
            end)
        end

        if poolItem.rerecordBtn and poolItem.rerecordBtn.OnClick then
            poolItem.rerecordBtn:OnClick(function()
                if not lineupId then return end
                local ok, err = Recorder:StartRerecord(lineupId, activeMap)
                if ok then
                    ModernMenu:Close()
                elseif NotificationController and NotificationController.ShowHint then
                    NotificationController:ShowHint(tostring(err or "Could not start re-record"), 2.5)
                end
            end)
        end

        if poolItem.row then
            poolItem.row.visible = true
            if poolItem.row.style and DisplayStyle then
                poolItem.row.style.display = DisplayStyle.Flex
            end
        end
    end

    for i = #lineups + 1, #self.LineupRowPool do
        local poolItem = self.LineupRowPool[i]
        if poolItem and poolItem.row then
            poolItem.row.visible = false
            if poolItem.row.style and DisplayStyle then
                poolItem.row.style.display = DisplayStyle.None
            end
        end
    end
end

ModernMenu.FilterButtons = {
    { name = "btnM2FilterAll",   type = "ALL" },
    { name = "btnM2FilterSonar", type = "SONAR" },
    { name = "btnM2FilterEmp",   type = "EMP" },
    { name = "btnM2FilterFrag",  type = "FRAG" },
    { name = "btnM2FilterFire",  type = "FIRE" },
}

function ModernMenu:UpdateFilterButtons(selectedType)
    if selectedType then
        self.TypeFilter = selectedType
    end
    local currentFilter = self.TypeFilter or "ALL"
    for _, item in ipairs(self.FilterButtons) do
        local btn = self:Find(item.name)
        if btn then
            local isActive = (item.type == currentFilter)
            if btn.EnableInClassList then
                btn:EnableInClassList("is-active", isActive)
            end
        end
    end
end

function ModernMenu:UpdateToggleButton(buttonName, isEnabled)
    local btn = self:Find(buttonName)
    if not btn then return end

    if btn.EnableInClassList then
        btn:EnableInClassList("is-on", isEnabled)
    end
    btn.text = isEnabled and "[ ENABLED ]" or "[ DISABLED ]"
end

function ModernMenu.Refresh()
    if not ModernMenu.Root then return end
    ModernMenu:UpdateFilterButtons(ModernMenu.TypeFilter)
    ModernMenu:RefreshLineupsList()
    ModernMenu:UpdateToggleButton("btnM2Enabled", Storage and Storage.GrenadeHelperEnabled ~= false)

    local lblDist = ModernMenu:Find("lblM2MaxDistance")
    if lblDist then
        local currentDist = Config and Config.ActivationDistance or 2.5
        lblDist.text = string.format("%.1f M", currentDist)
    end

    local isAuto = not (Storage and Storage.CurrentMapProfile and Storage.CurrentMapProfile ~= "")
    local btnAuto = ModernMenu:Find("btnM2MapAuto")
    if btnAuto and btnAuto.EnableInClassList then
        btnAuto:EnableInClassList("is-active", isAuto)
    end
end

function ModernMenu:Close()
    self.IsOpenState = false
    self.Dragging = false
    self:CloseRenameModal()
    if self.Root and UI and UI.CloseWindow then
        UI:CloseWindow(self.Root, true)
    end
end

function ModernMenu:Open()
    self.IsOpenState = true
    if self.Root and UI and UI.OpenWindow then
        self:ApplyPosition(false)
        self:Refresh()
        UI:OpenWindow(self.Root, true, true, false, false)
    end
end

function ModernMenu.Toggle()
    if ModernMenu.IsOpenState then
        ModernMenu:Close()
    else
        ModernMenu:Open()
    end
end

function ModernMenu.IsOpen()
    return ModernMenu.IsOpenState == true
end

function ModernMenu:ShowToast(msg)
    local text = tostring(msg or "")
    print("[GrenadeHelper] " .. text)
    if NotificationController then
        if NotificationController.ShowHint then
            NotificationController:ShowHint(text, 3.0)
        elseif NotificationController.ShowNotification then
            NotificationController:ShowNotification(text, 3.0)
        end
    end
end

function ModernMenu:ExportConfigToJson()
    local currentMap = LineupService:GetCurrentMapName()

    local exportLineups = {}
    for _, item in ipairs(LineupService:GetAllLineups(currentMap)) do
        table.insert(exportLineups, {
            id          = item.id,
            description = item.description,
            grenadeType = item.grenadeType,
            mapName     = item.mapName,
            standX      = item.standPosition.x,
            standY      = item.standPosition.y,
            standZ      = item.standPosition.z,
            pitch       = item.pitch,
            yaw         = item.yaw,
            actionsData = item.actionsData
        })
    end

    local exportData = {
        version = "2.0",
        currentMap = currentMap,
        settings = {
            Enabled            = Storage and Storage.GrenadeHelperEnabled ~= false,
            ActivationDistance = Config and Config.ActivationDistance or 2.5,
            MarkerColor        = Config and Config.MarkerColor or "#00FF9D",
            ShowAllLineupsWithoutGrenade = Config and Config.ShowAllLineupsWithoutGrenade ~= false,
            ShowSkyTargetLabels = Config and Config.ShowSkyTargetLabels ~= false
        },
        lineupsByMap = Storage and Storage.LineupsByMap or {},
        lineups = exportLineups
    }

    local jsonStr = JsonUtility.encode(exportData)
    local hexData = ActionCodec.ToHex(jsonStr)

    if Clipboard and Clipboard.SetText then
        Clipboard:SetText(hexData)
        self:ShowToast("Config copied to clipboard!")
    else
        self:ShowToast("Clipboard API unavailable!")
    end
end

function ModernMenu:GetItemCoordsAndTicks(item)
    local x = item.standX or (item.standPosition and item.standPosition.x) or 0
    local y = item.standY or (item.standPosition and item.standPosition.y) or 0
    local z = item.standZ or (item.standPosition and item.standPosition.z) or 0
    local pitch = item.pitch or 0
    local yaw = item.yaw or 0
    local grenadeType = tostring(item.grenadeType or ""):lower()
    local actionsData = tostring(item.actionsData or "")
    return x, y, z, pitch, yaw, grenadeType, actionsData
end

function ModernMenu:CleanHexTrack(str)
    local s = tostring(str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s:sub(1, 3):upper() == "V2:" then s = s:sub(4) end
    return s:gsub("[^0-9a-fA-F]", "")
end

function ModernMenu:IsDuplicateLineup(newItem, existingList)
    if not existingList or #existingList == 0 then return false end
    local nx, ny, nz, npitch, nyaw, ngrenade, nactions = self:GetItemCoordsAndTicks(newItem)
    local cleanN = self:CleanHexTrack(nactions)

    for _, existing in ipairs(existingList) do
        if existing then
            local ex, ey, ez, epitch, eyaw, egrenade, eactions = self:GetItemCoordsAndTicks(existing)

            local dx = math.abs(nx - ex)
            local dy = math.abs(ny - ey)
            local dz = math.abs(nz - ez)
            local dpitch = math.abs(npitch - epitch)
            local dyaw = math.abs(nyaw - eyaw)

            local samePosAndAngle = (dx < 0.05 and dy < 0.05 and dz < 0.05 and dpitch < 0.5 and dyaw < 0.5)

            local sameActions = false
            local cleanE = self:CleanHexTrack(eactions)
            if cleanN ~= "" and cleanE ~= "" then
                sameActions = (cleanN == cleanE)
            else
                sameActions = true
            end

            if samePosAndAngle and sameActions then
                return true
            end
        end
    end
    return false
end

function ModernMenu:ProcessImportData(rawInput, isAppend)
    if not rawInput or rawInput == "" then
        self:ShowToast("Clipboard is empty!")
        return
    end

    local text = tostring(rawInput):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        self:ShowToast("Clipboard is empty!")
        return
    end

    if (text:sub(1, 1) == '"' and text:sub(-1) == '"') or (text:sub(1, 1) == "'" and text:sub(-1) == "'") then
        text = text:sub(2, -2):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local jsonStr = ""
    local firstChar = text:sub(1, 1)

    if firstChar == "{" or firstChar == "[" then
        jsonStr = text
    else
        local cleanHex = text:gsub("[^0-9a-fA-F]", "")
        if cleanHex == "" then
            self:ShowToast("Clipboard contains invalid config data!")
            return
        end
        jsonStr = ActionCodec.FromHex(cleanHex)
    end

    local data, err = JsonUtility.decode(jsonStr)
    if not data then
        self:ShowToast("Invalid config in clipboard: " .. tostring(err or "parse error"))
        return
    end

    if data.settings then
        if data.settings.Enabled ~= nil and Storage then
            Storage.GrenadeHelperEnabled = data.settings.Enabled
        end
        if data.settings.ActivationDistance ~= nil and Config then
            Config.ActivationDistance = tonumber(data.settings.ActivationDistance) or 2.5
        end
        if data.settings.MarkerColor ~= nil and Config then
            Config.MarkerColor = tostring(data.settings.MarkerColor)
        end
    end

    local currentMap = LineupService:GetCurrentMapName()
    if Storage then
        if not Storage.LineupsByMap then Storage.LineupsByMap = {} end

        if data.lineupsByMap then
            if isAppend then
                local totalAdded = 0
                local totalSkipped = 0
                for mapKey, list in pairs(data.lineupsByMap) do
                    if not Storage.LineupsByMap[mapKey] then Storage.LineupsByMap[mapKey] = {} end
                    for _, item in ipairs(list) do
                        if item then
                            if not self:IsDuplicateLineup(item, Storage.LineupsByMap[mapKey]) then
                                table.insert(Storage.LineupsByMap[mapKey], item)
                                totalAdded = totalAdded + 1
                            else
                                totalSkipped = totalSkipped + 1
                            end
                        end
                    end
                end
                Storage.LineupsByMap = Storage.LineupsByMap
                if ConfigManager and ConfigManager.Save then ConfigManager:Save() end
                LineupService:InvalidateCaches()
                ModernMenu.Refresh()
                if totalSkipped > 0 then
                    self:ShowToast("Appended " .. tostring(totalAdded) .. " lineups (" .. tostring(totalSkipped) .. " duplicates skipped)!")
                else
                    self:ShowToast("Appended " .. tostring(totalAdded) .. " lineups across maps!")
                end
            else
                Storage.LineupsByMap = data.lineupsByMap
                if ConfigManager and ConfigManager.Save then ConfigManager:Save() end
                LineupService:InvalidateCaches()
                ModernMenu.Refresh()
                self:ShowToast("Overwritten lineups from clipboard successfully!")
            end
        elseif data.lineups then
            local targetMap = data.currentMap or currentMap
            if not Storage.LineupsByMap[targetMap] then Storage.LineupsByMap[targetMap] = {} end

            if isAppend then
                local addedCount = 0
                local skippedCount = 0
                for _, item in ipairs(data.lineups) do
                    if item then
                        if not self:IsDuplicateLineup(item, Storage.LineupsByMap[targetMap]) then
                            local idx = #Storage.LineupsByMap[targetMap] + 1
                            local newItem = {
                                id          = "Lineup_" .. tostring(math.random(1000, 9999)) .. "_" .. tostring(idx),
                                description = item.description or ("Lineup #" .. tostring(idx)),
                                grenadeType = item.grenadeType or "Grenade",
                                mapName     = targetMap,
                                standX      = item.standX or (item.standPosition and item.standPosition.x) or 0,
                                standY      = item.standY or (item.standPosition and item.standPosition.y) or 0,
                                standZ      = item.standZ or (item.standPosition and item.standPosition.z) or 0,
                                aimX        = item.aimX or 0,
                                aimY        = item.aimY or 0,
                                aimZ        = item.aimZ or 0,
                                pitch       = item.pitch or 0,
                                yaw         = item.yaw or 0,
                                actionsData = item.actionsData
                            }
                            table.insert(Storage.LineupsByMap[targetMap], newItem)
                            addedCount = addedCount + 1
                        else
                            skippedCount = skippedCount + 1
                        end
                    end
                end
                Storage.LineupsByMap = Storage.LineupsByMap
                if ConfigManager and ConfigManager.Save then ConfigManager:Save() end
                LineupService:InvalidateCaches()
                ModernMenu.Refresh()
                if skippedCount > 0 then
                    self:ShowToast("Appended " .. tostring(addedCount) .. " lineups to " .. targetMap .. " (" .. tostring(skippedCount) .. " duplicates skipped)!")
                else
                    self:ShowToast("Appended " .. tostring(addedCount) .. " lineups to " .. targetMap .. "!")
                end
            else
                local mapItems = {}
                for _, item in ipairs(data.lineups) do
                    if item then
                        table.insert(mapItems, {
                            id          = item.id or ("Lineup_" .. tostring(math.random(1000, 9999))),
                            description = item.description or "Lineup",
                            grenadeType = item.grenadeType or "Grenade",
                            mapName     = targetMap,
                            standX      = item.standX or (item.standPosition and item.standPosition.x) or 0,
                            standY      = item.standY or (item.standPosition and item.standPosition.y) or 0,
                            standZ      = item.standZ or (item.standPosition and item.standPosition.z) or 0,
                            aimX        = item.aimX or 0,
                            aimY        = item.aimY or 0,
                            aimZ        = item.aimZ or 0,
                            pitch       = item.pitch or 0,
                            yaw         = item.yaw or 0,
                            actionsData = item.actionsData
                        })
                    end
                end
                Storage.LineupsByMap[targetMap] = mapItems
                Storage.LineupsByMap = Storage.LineupsByMap
                if ConfigManager and ConfigManager.Save then ConfigManager:Save() end
                LineupService:InvalidateCaches()
                ModernMenu.Refresh()
                self:ShowToast("Overwritten " .. targetMap .. " with " .. tostring(#mapItems) .. " lineups!")
            end
        end
    end
end

function ModernMenu:ImportConfigFromJson(isAppend)
    self:ShowToast("Reading clipboard...")
    if Clipboard and Clipboard.GetText then
        Clipboard:GetText(function(res)
            local clipboardText = res and res.Text
            ModernMenu:ProcessImportData(clipboardText, isAppend)
        end)
    else
        self:ShowToast("Clipboard API unavailable!")
    end
end

function ModernMenu.Init()
    if ModernMenu.Root then return true end
    if not UI or not UI.BuildFromUxmlInteractive then return false end

    ModernMenu.Root = UI:BuildFromUxmlInteractive("modern_menu.uxml")
    if not ModernMenu.Root then
        return false
    end
    ModernMenu.ElementCache = {}

    if ModernMenu.LineupRowPool then
        for _, poolItem in ipairs(ModernMenu.LineupRowPool) do
            if poolItem and poolItem.row then
                if poolItem.row.RemoveFromHierarchy then poolItem.row:RemoveFromHierarchy() end
                if poolItem.row.Delete then poolItem.row:Delete()
                elseif UI and UI.Delete then UI:Delete(poolItem.row) end
            end
        end
    end
    ModernMenu.LineupRowPool = {}

    ModernMenu.Panel = ModernMenu:Find("ModernMenuPanel") or ModernMenu:Find("pnlM2Container")
    ModernMenu.DragHandle = ModernMenu:Find("veM2DragHandle")

    ModernMenu.Pages.Lineups = ModernMenu:Find("pageM2Lineups") or ModernMenu:Find("veM2PageLineups")
    ModernMenu.Pages.Settings = ModernMenu:Find("pageM2Settings") or ModernMenu:Find("veM2PageSettings")

    ModernMenu.Tabs.Lineups = ModernMenu:Find("btnM2TabLineups")
    ModernMenu.Tabs.Settings = ModernMenu:Find("btnM2TabSettings")

    if ModernMenu.Tabs.Lineups then
        if ModernMenu.Tabs.Lineups.EnableMouseEvents then ModernMenu.Tabs.Lineups:EnableMouseEvents() end
        if ModernMenu.Tabs.Lineups.SetCursor then ModernMenu.Tabs.Lineups:SetCursor("hand") end
        if ModernMenu.Tabs.Lineups.OnClick then ModernMenu.Tabs.Lineups:OnClick(function() ModernMenu:ShowPage("Lineups") end) end
    end

    if ModernMenu.Tabs.Settings then
        if ModernMenu.Tabs.Settings.EnableMouseEvents then ModernMenu.Tabs.Settings:EnableMouseEvents() end
        if ModernMenu.Tabs.Settings.SetCursor then ModernMenu.Tabs.Settings:SetCursor("hand") end
        if ModernMenu.Tabs.Settings.OnClick then ModernMenu.Tabs.Settings:OnClick(function() ModernMenu:ShowPage("Settings") end) end
    end

    local btnAutoMap     = ModernMenu:Find("btnM2MapAuto")
    local btnCastle      = ModernMenu:Find("btnM2MapCastle")
    local btnUnderground = ModernMenu:Find("btnM2MapUnderground")
    local txtCustomMap   = ModernMenu:Find("txtM2CustomMap")
    local btnApplyMap    = ModernMenu:Find("btnM2SetCustomMap")

    if btnAutoMap then
        if btnAutoMap.EnableMouseEvents then btnAutoMap:EnableMouseEvents() end
        if btnAutoMap.SetCursor then btnAutoMap:SetCursor("hand") end
        if btnAutoMap.OnClick then
            btnAutoMap:OnClick(function()
                LineupService:SetCurrentMapName("AUTO")
                ModernMenu:ShowToast("Map set to Auto-Detect!")
                ModernMenu.Refresh()
            end)
        end
    end

    if btnCastle then
        if btnCastle.EnableMouseEvents then btnCastle:EnableMouseEvents() end
        if btnCastle.SetCursor then btnCastle:SetCursor("hand") end
        if btnCastle.OnClick then
            btnCastle:OnClick(function()
                LineupService:SetCurrentMapName("CASTLE")
                ModernMenu.Refresh()
            end)
        end
    end

    if btnUnderground then
        if btnUnderground.EnableMouseEvents then btnUnderground:EnableMouseEvents() end
        if btnUnderground.SetCursor then btnUnderground:SetCursor("hand") end
        if btnUnderground.OnClick then
            btnUnderground:OnClick(function()
                LineupService:SetCurrentMapName("UNDERGROUND")
                ModernMenu.Refresh()
            end)
        end
    end

    if btnApplyMap then
        if btnApplyMap.EnableMouseEvents then btnApplyMap:EnableMouseEvents() end
        if btnApplyMap.SetCursor then btnApplyMap:SetCursor("hand") end
        if btnApplyMap.OnClick then
            btnApplyMap:OnClick(function()
                if txtCustomMap and txtCustomMap.value and txtCustomMap.value ~= "" then
                    LineupService:SetCurrentMapName(txtCustomMap.value)
                    ModernMenu.Refresh()
                end
            end)
        end
    end

    local btnSave = ModernMenu:Find("btnM2SavePoint")
    if btnSave then
        if btnSave.EnableMouseEvents then btnSave:EnableMouseEvents() end
        if btnSave.SetCursor then btnSave:SetCursor("hand") end
        if btnSave.OnClick then
            btnSave:OnClick(function()
                local agent = (Agents and Agents.GetLocalOrSpectatedAgent and Agents:GetLocalOrSpectatedAgent()) or (Agents and Agents.GetLocalAgent and Agents:GetLocalAgent())
                if agent and not Recorder.Recording then
                    local ok, err = Recorder:Start(agent)
                    if ok then
                        ModernMenu:Close()
                    elseif NotificationController and NotificationController.ShowHint then
                        NotificationController:ShowHint(tostring(err or "Could not start recording"), 2.5)
                    end
                end
            end)
        end
    end

    local btnClose = ModernMenu:Find("btnM2Close")
    if btnClose then
        if btnClose.EnableMouseEvents then btnClose:EnableMouseEvents() end
        if btnClose.SetCursor then btnClose:SetCursor("hand") end
        if btnClose.OnClick then btnClose:OnClick(function() ModernMenu:Close() end) end
    end

    for _, item in ipairs(ModernMenu.FilterButtons) do
        local btn = ModernMenu:Find(item.name)
        if btn then
            if btn.EnableMouseEvents then btn:EnableMouseEvents() end
            if btn.SetCursor then btn:SetCursor("hand") end
            if btn.OnClick then
                local filterType = item.type
                btn:OnClick(function()
                    ModernMenu:UpdateFilterButtons(filterType)
                    ModernMenu:RefreshLineupsList()
                end)
            end
        end
    end

    local btnEnabled = ModernMenu:Find("btnM2Enabled")
    if btnEnabled then
        if btnEnabled.EnableMouseEvents then btnEnabled:EnableMouseEvents() end
        if btnEnabled.SetCursor then btnEnabled:SetCursor("hand") end
        if btnEnabled.OnClick then
            btnEnabled:OnClick(function()
                if Storage then
                    Storage.GrenadeHelperEnabled = not (Storage.GrenadeHelperEnabled ~= false)
                end
                ModernMenu.Refresh()
            end)
        end
    end

    local trkDistance = ModernMenu:Find("trkM2MaxDistance")
    if trkDistance then
        if trkDistance.EnableMouseEvents then trkDistance:EnableMouseEvents() end
        if trkDistance.SetCursor then trkDistance:SetCursor("hand") end
        if trkDistance.OnClick then
            trkDistance:OnClick(function()
                local current = Config and Config.ActivationDistance or 2.5
                local nextVal = current + 0.5
                if nextVal > 5.0 then nextVal = 0.5 end
                if Config then Config.ActivationDistance = nextVal end
                ModernMenu.Refresh()
            end)
        end
    end

    local btnExportJson = ModernMenu:Find("btnM2ExportJson")
    local btnImportJson = ModernMenu:Find("btnM2ImportJson")
    local btnAddJson    = ModernMenu:Find("btnM2AddJson")

    if btnExportJson then
        if btnExportJson.EnableMouseEvents then btnExportJson:EnableMouseEvents() end
        if btnExportJson.SetCursor then btnExportJson:SetCursor("hand") end
        if btnExportJson.OnClick then btnExportJson:OnClick(function() ModernMenu:ExportConfigToJson() end) end
    end

    if btnImportJson then
        if btnImportJson.EnableMouseEvents then btnImportJson:EnableMouseEvents() end
        if btnImportJson.SetCursor then btnImportJson:SetCursor("hand") end
        if btnImportJson.OnClick then btnImportJson:OnClick(function() ModernMenu:ImportConfigFromJson(false) end) end
    end

    if btnAddJson then
        if btnAddJson.EnableMouseEvents then btnAddJson:EnableMouseEvents() end
        if btnAddJson.SetCursor then btnAddJson:SetCursor("hand") end
        if btnAddJson.OnClick then btnAddJson:OnClick(function() ModernMenu:ImportConfigFromJson(true) end) end
    end

    local textInput = ModernMenu:Find("txtM2RenameInput")
    local btnRenameSave = ModernMenu:Find("btnM2RenameSave")
    local btnRenameCancel = ModernMenu:Find("btnM2RenameCancel")

    if btnRenameSave then
        if btnRenameSave.EnableMouseEvents then btnRenameSave:EnableMouseEvents() end
        if btnRenameSave.SetCursor then btnRenameSave:SetCursor("hand") end
        if btnRenameSave.OnClick then
            btnRenameSave:OnClick(function()
                if ModernMenu.CurrentRenameLineupId and textInput then
                    local newName = textInput.value
                    if newName and newName ~= "" then
                        local currentMap = LineupService:GetCurrentMapName()
                        LineupService:RenameLineupById(ModernMenu.CurrentRenameLineupId, newName, currentMap)
                    end
                end
                ModernMenu:CloseRenameModal()
                ModernMenu:Close()
            end)
        end
    end

    if btnRenameCancel then
        if btnRenameCancel.EnableMouseEvents then btnRenameCancel:EnableMouseEvents() end
        if btnRenameCancel.SetCursor then btnRenameCancel:SetCursor("hand") end
        if btnRenameCancel.OnClick then
            btnRenameCancel:OnClick(function()
                ModernMenu:CloseRenameModal()
                ModernMenu:Close()
            end)
        end
    end

    local presets = {
        btnM2PresetHeaven = "Heaven",
        btnM2PresetAMain  = "A Main",
        btnM2PresetBSite  = "B Site",
        btnM2PresetMid    = "Mid",
        btnM2PresetWindow = "Window"
    }

    for btnName, presetVal in pairs(presets) do
        local btn = ModernMenu:Find(btnName)
        if btn then
            if btn.EnableMouseEvents then btn:EnableMouseEvents() end
            if btn.SetCursor then btn:SetCursor("hand") end
            if btn.OnClick then
                btn:OnClick(function()
                    if textInput then textInput.value = presetVal end
                end)
            end
        end
    end

    if ModernMenu.DragHandle then
        if ModernMenu.DragHandle.EnableMouseEvents then ModernMenu.DragHandle:EnableMouseEvents() end
        if ModernMenu.DragHandle.SetCursor then ModernMenu.DragHandle:SetCursor("move") end
        if ModernMenu.DragHandle.OnPointerDown then
            ModernMenu.DragHandle:OnPointerDown(function()
                ModernMenu.Dragging = true
                ModernMenu.DragStartMouse = ModernMenu:GetMouseUiPosition()
                ModernMenu.DragStartX = ModernMenu.OffsetX
                ModernMenu.DragStartY = ModernMenu.OffsetY
            end)
        end
    end

    ModernMenu:ShowPage("Lineups")
    ModernMenu.Root.visible = false
    ModernMenu.Refresh()
    return true
end

function ModernMenu.Update()
    if not ModernMenu.Root then
        ModernMenu.Init()
    end

    if ModernMenu.IsOpenState then
        local txtSearch = ModernMenu:Find("txtM2SearchInput")
        if txtSearch and txtSearch.value ~= nil then
            local currentVal = tostring(txtSearch.value or "")
            if currentVal ~= ModernMenu.SearchQuery then
                ModernMenu.SearchQuery = currentVal
                ModernMenu:RefreshLineupsList()
            end
        end
    end

    if ModernMenu.ClickAction == nil and InputActions then
        ModernMenu.ClickAction = InputActions:FindAction("Click")
    end

    if ModernMenu.Dragging then
        local clickPressed = ModernMenu.ClickAction and ModernMenu.ClickAction.IsPressed and ModernMenu.ClickAction:IsPressed()
        if ModernMenu.ClickAction and not clickPressed then
            ModernMenu.Dragging = false
            ModernMenu:ApplyPosition(true)
        else
            local mouse = ModernMenu:GetMouseUiPosition()
            if mouse and ModernMenu.DragStartMouse then
                ModernMenu.OffsetX = ModernMenu.DragStartX + (mouse.x - ModernMenu.DragStartMouse.x)
                ModernMenu.OffsetY = ModernMenu.DragStartY + (mouse.y - ModernMenu.DragStartMouse.y)
                ModernMenu:ApplyPosition(false)
            end
        end
    end
end

return ModernMenu
