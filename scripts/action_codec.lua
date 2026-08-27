-- ============================================================================
-- GrenadeHelper - Compact Binary/Hex Codec for Recorded Action Tracks
-- ============================================================================
-- Packs {durationTicks, events={{t, fields={move,look,jump,crouch,fire}}}}
-- into a hex string: a 2-byte tick header, then per event a 1-byte field
-- bitmask (also carries jump/crouch/fire boolean values as bits - no extra
-- bytes needed for those), a 2-byte tick offset, and only the move/look
-- pairs that are actually present, each as two signed 16-bit fixed-point
-- values (move x10^3, look x10 - one decimal place is enough for degrees).
-- No string.pack dependency: pure string.char/byte + arithmetic, since bit
-- operators are not part of this sandbox's Lua dialect.

local ActionCodec = {}

local FLAG_MOVE             = 1
local FLAG_LOOK             = 2
local FLAG_JUMP_PRESENT     = 4
local FLAG_JUMP_VALUE       = 8
local FLAG_CROUCH_PRESENT   = 16
local FLAG_CROUCH_VALUE     = 32
local FLAG_FIRE_PRESENT     = 64
local FLAG_FIRE_VALUE       = 128
local FLAG_ALT_FIRE_PRESENT = 256
local FLAG_ALT_FIRE_VALUE   = 512

local MOVE_SCALE = 1000
local LOOK_SCALE = 10

local HEX_DIGITS = "0123456789abcdef"

local function HasFlag(byte, flag)
    return math.floor(byte / flag) % 2 == 1
end

local function Round(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return math.ceil(x - 0.5)
end

local function ClampU16(n)
    if n < 0 then return 0 end
    if n > 65535 then return 65535 end
    return n
end

local function ClampI16(n)
    if n < -32768 then return -32768 end
    if n > 32767 then return 32767 end
    return n
end

local function PackU8(n)
    return string.char(n % 256)
end

local function PackU16(n)
    n = math.floor(n) % 65536
    return string.char(math.floor(n / 256), n % 256)
end

local function PackI16(n)
    n = math.floor(n)
    if n < 0 then n = n + 65536 end
    return PackU16(n)
end

local function UnpackU8(bin, pos)
    return bin:byte(pos), pos + 1
end

local function UnpackU16(bin, pos)
    local hi, lo = bin:byte(pos, pos + 1)
    return (hi or 0) * 256 + (lo or 0), pos + 2
end

local function UnpackI16(bin, pos)
    local v, nextPos = UnpackU16(bin, pos)
    if v >= 32768 then v = v - 65536 end
    return v, nextPos
end

local function ToHex(bin)
    local out = {}
    for i = 1, #bin do
        local b = bin:byte(i)
        local hi = math.floor(b / 16)
        local lo = b % 16
        out[i] = HEX_DIGITS:sub(hi + 1, hi + 1) .. HEX_DIGITS:sub(lo + 1, lo + 1)
    end
    return table.concat(out)
end

local function FromHex(hexStr)
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
---@param track table
---@return string hex
function ActionCodec.Encode(track)
    local bin = { PackU16(ClampU16(track and track.durationTicks or 0)) }

    for _, ev in ipairs((track and track.events) or {}) do
        local fields = ev.fields or {}
        local flags = 0

        if fields.move then flags = flags + FLAG_MOVE end
        if fields.look then flags = flags + FLAG_LOOK end
        if fields.jump ~= nil then
            flags = flags + FLAG_JUMP_PRESENT
            if fields.jump then flags = flags + FLAG_JUMP_VALUE end
        end
        if fields.crouch ~= nil then
            flags = flags + FLAG_CROUCH_PRESENT
            if fields.crouch then flags = flags + FLAG_CROUCH_VALUE end
        end
        if fields.fire ~= nil then
            flags = flags + FLAG_FIRE_PRESENT
            if fields.fire then flags = flags + FLAG_FIRE_VALUE end
        end
        if fields.altFire ~= nil then
            flags = flags + FLAG_ALT_FIRE_PRESENT
            if fields.altFire then flags = flags + FLAG_ALT_FIRE_VALUE end
        end

        bin[#bin + 1] = PackU16(flags)
        bin[#bin + 1] = PackU16(ClampU16(ev.t or 0))

        if fields.move then
            bin[#bin + 1] = PackI16(ClampI16(Round((fields.move.x or 0) * MOVE_SCALE)))
            bin[#bin + 1] = PackI16(ClampI16(Round((fields.move.y or 0) * MOVE_SCALE)))
        end
        if fields.look then
            bin[#bin + 1] = PackI16(ClampI16(Round((fields.look.x or 0) * LOOK_SCALE)))
            bin[#bin + 1] = PackI16(ClampI16(Round((fields.look.y or 0) * LOOK_SCALE)))
        end
    end

    return "V2:" .. ToHex(table.concat(bin))
end

--- Decodes a hex string produced by Encode back into a {durationTicks, events} table.
---@param hexStr string|nil
---@return table track
function ActionCodec.Decode(hexStr)
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
    local bin = FromHex(cleanHex)
    local len = #bin
    local pos = 1

    local durationTicks
    durationTicks, pos = UnpackU16(bin, pos)

    local events = {}
    while pos <= len do
        local flags, tick
        if isV2 then
            flags, pos = UnpackU16(bin, pos)
        else
            flags, pos = UnpackU8(bin, pos)
        end
        tick, pos = UnpackU16(bin, pos)

        local fieldsOut = {}

        if HasFlag(flags, FLAG_MOVE) then
            local mx, my
            mx, pos = UnpackI16(bin, pos)
            my, pos = UnpackI16(bin, pos)
            fieldsOut.move = { x = mx / MOVE_SCALE, y = my / MOVE_SCALE }
        end
        if HasFlag(flags, FLAG_LOOK) then
            local px, py
            px, pos = UnpackI16(bin, pos)
            py, pos = UnpackI16(bin, pos)
            fieldsOut.look = { x = px / LOOK_SCALE, y = py / LOOK_SCALE }
        end
        if HasFlag(flags, FLAG_JUMP_PRESENT) then
            fieldsOut.jump = HasFlag(flags, FLAG_JUMP_VALUE)
        end
        if HasFlag(flags, FLAG_CROUCH_PRESENT) then
            fieldsOut.crouch = HasFlag(flags, FLAG_CROUCH_VALUE)
        end
        if HasFlag(flags, FLAG_FIRE_PRESENT) then
            fieldsOut.fire = HasFlag(flags, FLAG_FIRE_VALUE)
        end
        if isV2 and HasFlag(flags, FLAG_ALT_FIRE_PRESENT) then
            fieldsOut.altFire = HasFlag(flags, FLAG_ALT_FIRE_VALUE)
        end

        events[#events + 1] = { t = tick, fields = fieldsOut }
    end

    return { durationTicks = durationTicks, events = events }
end

--- Fast header lookup for track duration ticks without full event decoding.
---@param hexStr string|nil
---@return integer durationTicks
function ActionCodec.GetDurationTicks(hexStr)
    if not hexStr or hexStr == "" then return 0 end
    local bin = FromHex(hexStr)
    if #bin < 2 then return 0 end
    return UnpackU16(bin, 1)
end

-- Exposed generically so callers outside this file (e.g. the menu's
-- import/export box) can hex-wrap arbitrary text without duplicating this.
ActionCodec.ToHex = ToHex
ActionCodec.FromHex = FromHex

return ActionCodec
