-- ============================================================================
-- GrenadeHelper - Pure Lua JSON Utility (Sandbox Compatible, NO type() global)
-- ============================================================================

local Json = {}

local function safe_type(val)
    if val == nil then return "nil" end
    if val == true or val == false then return "boolean" end
    if type then return type(val) end
    if tonumber(val) ~= nil and val == tonumber(val) then return "number" end
    local strVal = tostring(val)
    if strVal:sub(1, 6) == "table:" then return "table" end
    return "string"
end

local function escape_str(s)
    local in_char  = {'\\', '"', '/', '\b', '\f', '\n', '\r', '\t'}
    local out_char = {'\\\\', '\\"', '\\/', '\\b', '\\f', '\\n', '\\r', '\\t'}
    for i, c in ipairs(in_char) do
        s = s:gsub(c, out_char[i])
    end
    return s
end

function Json.encode(val)
    local t = safe_type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return '"' .. escape_str(tostring(val)) .. '"'
    elseif t == "table" then
        local is_array = true
        local max_idx = 0
        for k, v in pairs(val) do
            local kt = safe_type(k)
            if kt ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_idx then max_idx = k end
        end

        if is_array then
            local parts = {}
            for i = 1, max_idx do
                table.insert(parts, Json.encode(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. escape_str(tostring(k)) .. '":' .. Json.encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function Json.decode(str)
    if not str or str == "" then return nil, "Empty string" end
    str = tostring(str)

    local pos = 1
    local len = #str

    local function skip_whitespace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1
        local start_pos = pos
        local result = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                table.insert(result, str:sub(start_pos, pos - 1))
                pos = pos + 1
                return table.concat(result)
            elseif c == '\\' then
                table.insert(result, str:sub(start_pos, pos - 1))
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == 'n' then table.insert(result, "\n")
                elseif esc == 'r' then table.insert(result, "\r")
                elseif esc == 't' then table.insert(result, "\t")
                elseif esc == '"' then table.insert(result, '"')
                elseif esc == '\\' then table.insert(result, '\\')
                elseif esc == '/' then table.insert(result, '/')
                else table.insert(result, esc) end
                pos = pos + 1
                start_pos = pos
            else
                pos = pos + 1
            end
        end
        return nil, "Unterminated string"
    end

    local function parse_number()
        local start_pos = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= len do
            local c = str:sub(pos, pos)
            if (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-' then
                pos = pos + 1
            else
                break
            end
        end
        local num_str = str:sub(start_pos, pos - 1)
        return tonumber(num_str)
    end

    local function parse_object()
        pos = pos + 1
        skip_whitespace()
        local obj = {}
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end

        while pos <= len do
            skip_whitespace()
            if str:sub(pos, pos) ~= '"' then return nil, "Expected string key at pos " .. tostring(pos) end
            local key, err = parse_string()
            if not key then return nil, err or "Invalid string key" end
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then return nil, "Expected ':' at pos " .. tostring(pos) end
            pos = pos + 1
            skip_whitespace()
            local val, err = parse_value()
            if err ~= nil then return nil, err end
            obj[key] = val
            skip_whitespace()
            local next_c = str:sub(pos, pos)
            if next_c == '}' then
                pos = pos + 1
                return obj
            elseif next_c == ',' then
                pos = pos + 1
            else
                return nil, "Expected ',' or '}' at pos " .. tostring(pos)
            end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1
        skip_whitespace()
        local arr = {}
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end

        while pos <= len do
            skip_whitespace()
            local val, err = parse_value()
            if err ~= nil then return nil, err end
            table.insert(arr, val)
            skip_whitespace()
            local next_c = str:sub(pos, pos)
            if next_c == ']' then
                pos = pos + 1
                return arr
            elseif next_c == ',' then
                pos = pos + 1
            else
                return nil, "Expected ',' or ']' at pos " .. tostring(pos)
            end
        end
        return arr
    end

    parse_value = function()
        skip_whitespace()
        if pos > len then return nil, "Unexpected end of input" end
        local c = str:sub(pos, pos)
        if c == '"' then
            return parse_string()
        elseif c == '{' then
            return parse_object()
        elseif c == '[' then
            return parse_array()
        elseif (c >= '0' and c <= '9') or c == '-' then
            return parse_number()
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        end
        return nil, "Unexpected character '" .. c .. "' at pos " .. tostring(pos)
    end

    local result, err = parse_value()
    return result, err
end

return Json
