-- ============================================================================
-- GrenadeHelper - Shared Vector/Angle Helpers
-- ============================================================================
-- Small pure-math helpers used by both lineup_service.lua and hud.lua; kept
-- in one place instead of duplicated per file.

local MathUtils = {}

function MathUtils.CreateVector3(x, y, z)
    if Vector3 and Vector3.new then
        return Vector3.new(x or 0, y or 0, z or 0)
    end
    return Vector3(x or 0, y or 0, z or 0)
end

function MathUtils.CreateVector2(x, y)
    if Vector2 and Vector2.new then
        return Vector2.new(x or 0, y or 0)
    end
    return Vector2(x or 0, y or 0)
end

function MathUtils.CalculateDistance(v1, v2)
    if not v1 or not v2 or not v1.x or not v2.x then return 999999.0 end
    local dx = v1.x - v2.x
    local dy = (v1.y or 0) - (v2.y or 0)
    local dz = v1.z - v2.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Shortest signed difference between two degree angles, wrapped to -180..180.
function MathUtils.AngleDiffDegrees(a, b)
    return math.abs(((a - b) + 180) % 360 - 180)
end

return MathUtils
