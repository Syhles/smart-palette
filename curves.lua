-- Tone curves applied to ramp output L. A curve is an array of {x, y}
-- control points (sorted by x); evaluation is piecewise linear with
-- endpoint clamping. v1 ships preset curves only; a future revision can
-- add an interactive editor canvas without changing this module's API.

local M = {}

-- Evaluate a curve at x ∈ [0,1]. Returns the y-coordinate via linear
-- interpolation between adjacent control points.
function M.eval(curve, x)
    if not curve or #curve == 0 then return x end
    if x <= curve[1][1] then return curve[1][2] end
    for i = 1, #curve - 1 do
        local p1 = curve[i]
        local p2 = curve[i + 1]
        if x <= p2[1] then
            local span = p2[1] - p1[1]
            if span <= 0 then return p2[2] end
            local t = (x - p1[1]) / span
            return p1[2] + t * (p2[2] - p1[2])
        end
    end
    return curve[#curve][2]
end

----------------------------------------------------------------------
-- Preset curves
----------------------------------------------------------------------

M.PRESETS = {
    identity     = { {0, 0},    {1, 1} },
    lift_shadows = { {0, 0.10}, {0.5, 0.55}, {1, 1.00} },
    compress_hl  = { {0, 0.00}, {0.5, 0.45}, {1, 0.90} },
    punchy       = { {0, 0.00}, {0.25, 0.12}, {0.75, 0.88}, {1, 1.00} },
    flatten      = { {0, 0.20}, {0.5, 0.50}, {1, 0.80} },
}

M.PRESET_KEYS  = { "identity", "lift_shadows", "compress_hl", "punchy", "flatten" }
M.PRESET_LABEL = {
    identity     = "Off (identity)",
    lift_shadows = "Lift shadows",
    compress_hl  = "Compress highlights",
    punchy       = "Punchy (S-curve)",
    flatten      = "Flatten (low contrast)",
}

function M.byName(name)
    return M.PRESETS[name or "identity"] or M.PRESETS.identity
end

function M.isIdentity(name)
    return name == nil or name == "identity"
end

return M
