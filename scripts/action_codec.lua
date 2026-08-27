-- ============================================================================
-- GrenadeHelper - Compact Binary/Hex Codec Class for Action Tracks
-- ============================================================================

local ActionCodec = {
    FLAG_MOVE             = 1,
    FLAG_LOOK             = 2,
    FLAG_JUMP_PRESENT     = 4,
    FLAG_JUMP_VALUE       = 8,
    FLAG_CROUCH_PRESENT   = 16,
    FLAG_CROUCH_VALUE     = 32,
    FLAG_FIRE_PRESENT     = 64,
    FLAG_FIRE_VALUE       = 128,
    FLAG_ALT_FIRE_PRESENT = 256,
    FLAG_ALT_FIRE_VALUE   = 512,

    MOVE_SCALE            = 1000,
    LOOK_SCALE            = 10,
    HEX_DIGITS            = "0123456789abcdef",
}

function ActionCodec:HasFlag(byte, flag)
    return math.floor(byte / flag) % 2 == 1
end

function ActionCodec:Round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return math.ceil(x - 0.5)
end

function ActionCodec:ClampU16(n)
    if n < 0 then return 0 end
    if n > 65535 then return 65535 end
    return n
end

function ActionCodec:ClampI16(n)
    if n < -32768 then return -32768 end
    if n > 32767 then return 32767 end
    return n
end

function ActionCodec:PackU8(n)
    return string.char(n % 256)
end

function ActionCodec:PackU16(n)
    n = math.floor(n) % 65536
    return string.char(math.floor(n / 256), n % 256)
end

function ActionCodec:PackI16(n)
    n = math.floor(n)
    if n < 0 then n = n + 65536 end
    return self:PackU16(n)
end

function ActionCodec:UnpackU8(bin, pos)
    return bin:byte(pos), pos + 1
end

function ActionCodec:UnpackU16(bin, pos)
    local hi, lo = bin:byte(pos, pos + 1)
    return (hi or 0) * 256 + (lo or 0), pos + 2
end

function ActionCodec:UnpackI16(bin, pos)
    local v, nextPos = self:UnpackU16(bin, pos)
    if v >= 32768 then v = v - 65536 end
    return v, nextPos
end

function ActionCodec.ToHex(bin)
    local self = ActionCodec
    local out = {}
    for i = 1, #bin do
        local b = bin:byte(i)
        local hi = math.floor(b / 16)
        local lo = b % 16
        out[i] = self.HEX_DIGITS:sub(hi + 1, hi + 1) .. self.HEX_DIGITS:sub(lo + 1, lo + 1)
    end
    return table.concat(out)
end

function ActionCodec.FromHex(hexStr)
    hexStr = tostring(hexStr or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if hexStr:sub(1, 3):upper() == "V2:" then
        hexStr = hexStr:sub(4)
    end
    local out = {}
    local len = #hexStr
    local i = 1
    while i <= len do
        if i + 1 <= len then
            local byteHex = hexStr:sub(i, i + 1)
            if byteHex:find("^[0-9a-fA-F][0-9a-fA-F]$") then
                local val = tonumber(byteHex, 16)
                if val ~= nil then
                    out[#out + 1] = string.char(val)
                    i = i + 2
                else
                    out[#out + 1] = hexStr:sub(i, i)
                    i = i + 1
                end
            else
                out[#out + 1] = hexStr:sub(i, i)
                i = i + 1
            end
        else
            out[#out + 1] = hexStr:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

--- Encodes a {durationTicks, events} action track into a compact hex string with V2: header.
function ActionCodec.Encode(track)
    local self = ActionCodec
    local bin = { self:PackU16(self:ClampU16(track and track.durationTicks or 0)) }

    for _, ev in ipairs((track and track.events) or {}) do
        local fields = ev.fields or {}
        local flags = 0

        if fields.move then flags = flags + self.FLAG_MOVE end
        if fields.look then flags = flags + self.FLAG_LOOK end
        if fields.jump ~= nil then
            flags = flags + self.FLAG_JUMP_PRESENT
            if fields.jump then flags = flags + self.FLAG_JUMP_VALUE end
        end
        if fields.crouch ~= nil then
            flags = flags + self.FLAG_CROUCH_PRESENT
            if fields.crouch then flags = flags + self.FLAG_CROUCH_VALUE end
        end
        if fields.fire ~= nil then
            flags = flags + self.FLAG_FIRE_PRESENT
            if fields.fire then flags = flags + self.FLAG_FIRE_VALUE end
        end
        if fields.altFire ~= nil then
            flags = flags + self.FLAG_ALT_FIRE_PRESENT
            if fields.altFire then flags = flags + self.FLAG_ALT_FIRE_VALUE end
        end

        bin[#bin + 1] = self:PackU16(flags)
        bin[#bin + 1] = self:PackU16(self:ClampU16(ev.t or 0))

        if fields.move then
            bin[#bin + 1] = self:PackI16(self:ClampI16(self:Round((fields.move.x or 0) * self.MOVE_SCALE)))
            bin[#bin + 1] = self:PackI16(self:ClampI16(self:Round((fields.move.y or 0) * self.MOVE_SCALE)))
        end
        if fields.look then
            bin[#bin + 1] = self:PackI16(self:ClampI16(self:Round((fields.look.x or 0) * self.LOOK_SCALE)))
            bin[#bin + 1] = self:PackI16(self:ClampI16(self:Round((fields.look.y or 0) * self.LOOK_SCALE)))
        end
    end

    return "V2:" .. self.ToHex(table.concat(bin))
end

--- Decodes a hex string produced by Encode back into a {durationTicks, events} table.
function ActionCodec.Decode(hexStr)
    local self = ActionCodec
    if not hexStr or hexStr == "" then
        return { durationTicks = 0, events = {} }
    end

    hexStr = tostring(hexStr):gsub("^%s+", ""):gsub("%s+$", "")
    local isV2 = false
    if hexStr:sub(1, 3):upper() == "V2:" then
        isV2 = true
        hexStr = hexStr:sub(4)
    end
    local cleanHex = hexStr:gsub("[^0-9a-fA-F]", "")
    local bin = self.FromHex(cleanHex)
    local len = #bin
    local pos = 1

    local durationTicks
    durationTicks, pos = self:UnpackU16(bin, pos)

    local events = {}
    while pos <= len do
        local flags, tick
        if isV2 then
            flags, pos = self:UnpackU16(bin, pos)
        else
            flags, pos = self:UnpackU8(bin, pos)
        end
        tick, pos = self:UnpackU16(bin, pos)

        local fieldsOut = {}

        if self:HasFlag(flags, self.FLAG_MOVE) then
            local mx, my
            mx, pos = self:UnpackI16(bin, pos)
            my, pos = self:UnpackI16(bin, pos)
            fieldsOut.move = { x = mx / self.MOVE_SCALE, y = my / self.MOVE_SCALE }
        end
        if self:HasFlag(flags, self.FLAG_LOOK) then
            local px, py
            px, pos = self:UnpackI16(bin, pos)
            py, pos = self:UnpackI16(bin, pos)
            fieldsOut.look = { x = px / self.LOOK_SCALE, y = py / self.LOOK_SCALE }
        end
        if self:HasFlag(flags, self.FLAG_JUMP_PRESENT) then
            fieldsOut.jump = self:HasFlag(flags, self.FLAG_JUMP_VALUE)
        end
        if self:HasFlag(flags, self.FLAG_CROUCH_PRESENT) then
            fieldsOut.crouch = self:HasFlag(flags, self.FLAG_CROUCH_VALUE)
        end
        if self:HasFlag(flags, self.FLAG_FIRE_PRESENT) then
            fieldsOut.fire = self:HasFlag(flags, self.FLAG_FIRE_VALUE)
        end
        if isV2 and self:HasFlag(flags, self.FLAG_ALT_FIRE_PRESENT) then
            fieldsOut.altFire = self:HasFlag(flags, self.FLAG_ALT_FIRE_VALUE)
        end

        events[#events + 1] = { t = tick, fields = fieldsOut }
    end

    return { durationTicks = durationTicks, events = events }
end

--- Fast header lookup for track duration ticks without full event decoding.
function ActionCodec.GetDurationTicks(hexStr)
    if not hexStr or hexStr == "" then return 0 end
    local bin = ActionCodec.FromHex(hexStr)
    if #bin < 2 then return 0 end
    return ActionCodec:UnpackU16(bin, 1)
end

return ActionCodec
