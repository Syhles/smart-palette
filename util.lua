-- Pure math helpers shared across the rest of the modules. No Aseprite
-- dependencies, so this file is fully exercisable under stock Lua for tests.

local M = {}

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- t in [-1,+1] maps to [lo, base, hi] so both extremes always reach the
-- boundary without two adjacent positions collapsing to the same value.
function M.asym(v, t, lo, hi)
    if t < 0 then
        return v + t * (v - lo)
    else
        return v + t * (hi - v)
    end
end

-- Same as asym but caps each side at ±cap from base.
function M.asymBounded(v, t, lo, hi, cap)
    return M.asym(v, t, math.max(lo, v - cap), math.min(hi, v + cap))
end

-- Shortest-arc hue distance from `from` to `to`, in [-180, +180].
function M.shortestArc(from, to)
    return ((to - from + 540) % 360) - 180
end

-- Sign-preserving cube root (Lua's math.pow rejects negative bases for
-- non-integer exponents, but OkLab matrix outputs can be negative).
function M.cbrt(x)
    if x < 0 then return -((-x) ^ (1/3)) end
    return x ^ (1/3)
end

-- Lerp from a to b at t in [0,1] (no clamp).
function M.lerp(a, b, t)
    return a + (b - a) * t
end

return M
