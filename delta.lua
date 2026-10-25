-- OkLab perceptual color distance (ΔE) and severity classification.
-- ΔE is just Euclidean distance in OkLab space; values are unitless and
-- typically fall in [0, ~1] for sRGB color pairs.
--
-- Used to flag adjacent swatches in a ramp that are perceptually too close
-- (banding risk) or too far apart (visible jumps).

local color = require("color")

local M = {}

-- Distance in OkLab between two sRGB triples (each component in [0, 255]).
function M.oklabDeltaE(r1, g1, b1, r2, g2, b2)
    local L1, a1, b1ok = color.rgbToOklab(r1/255, g1/255, b1/255)
    local L2, a2, b2ok = color.rgbToOklab(r2/255, g2/255, b2/255)
    local dL = L1 - L2
    local da = a1 - a2
    local db = b1ok - b2ok
    return math.sqrt(dL*dL + da*da + db*db)
end

-- Classify a ΔE value relative to an ideal range.
-- Returns one of: "too_close", "close", "ideal", "far", "too_far".
function M.classify(de, idealMin, idealMax)
    idealMin = idealMin or 0.04
    idealMax = idealMax or 0.15
    local lowMargin  = idealMin * 0.5
    local highMargin = idealMax * 1.5
    if de < lowMargin then return "too_close" end
    if de < idealMin then return "close" end
    if de <= idealMax then return "ideal" end
    if de <= highMargin then return "far" end
    return "too_far"
end

-- Map a classification to an indicator color (sRGB 0-255 triple).
-- Used by the UI to draw the under-strip diagnostic bars.
function M.classifyColor(klass)
    if klass == "ideal"     then return  90, 200,  90 end  -- green
    if klass == "close"     then return 220, 200,  90 end  -- yellow
    if klass == "far"       then return 220, 200,  90 end
    if klass == "too_close" then return 220, 100, 100 end  -- red-ish
    if klass == "too_far"   then return 220, 100, 100 end
    return 150, 150, 150  -- fallback grey
end

return M
