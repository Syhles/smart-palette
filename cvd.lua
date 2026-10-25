-- Color-blindness simulation matrices (Brettel/Viénot 1999, sRGB-direct).
-- Preview-grade accuracy; sufficient for an artist's CVD check.

local util  = require("util")
local color = require("color")

local M = {}

M.MATRICES = {
    protanopia = {
        { 0.567, 0.433, 0.000 },
        { 0.558, 0.442, 0.000 },
        { 0.000, 0.242, 0.758 },
    },
    deuteranopia = {
        { 0.625, 0.375, 0.000 },
        { 0.700, 0.300, 0.000 },
        { 0.000, 0.300, 0.700 },
    },
    tritanopia = {
        { 0.950, 0.050, 0.000 },
        { 0.000, 0.433, 0.567 },
        { 0.000, 0.475, 0.525 },
    },
}

M.KEYS  = { "none", "protanopia", "deuteranopia", "tritanopia" }
M.LABEL = {
    none         = "Off",
    protanopia   = "Protanopia",
    deuteranopia = "Deuteranopia",
    tritanopia   = "Tritanopia",
}

-- Apply the chosen CVD matrix to an sRGB triple in [0,255]. Mode "none" or
-- any unknown mode returns the input unchanged.
function M.apply(r, g, b, mode)
    local m = M.MATRICES[mode]
    if not m then return r, g, b end

    local lr = color.srgbDecompand(r / 255)
    local lg = color.srgbDecompand(g / 255)
    local lb = color.srgbDecompand(b / 255)

    local nr = m[1][1] * lr + m[1][2] * lg + m[1][3] * lb
    local ng = m[2][1] * lr + m[2][2] * lg + m[2][3] * lb
    local nb = m[3][1] * lr + m[3][2] * lg + m[3][3] * lb

    nr = util.clamp(color.srgbCompand(util.clamp(nr, 0, 1)), 0, 1)
    ng = util.clamp(color.srgbCompand(util.clamp(ng, 0, 1)), 0, 1)
    nb = util.clamp(color.srgbCompand(util.clamp(nb, 0, 1)), 0, 1)
    return math.floor(nr * 255 + 0.5),
           math.floor(ng * 255 + 0.5),
           math.floor(nb * 255 + 0.5)
end

-- Convenience for applying the matrix to an Aseprite Color (or any object
-- exposing red/green/blue/alpha). Returns a fresh Color via the injected
-- constructor (Aseprite's `Color` global, or a stub in tests).
function M.applyToColor(c, mode, ColorCtor)
    if mode == "none" or mode == nil then return c end
    local r, g, b = M.apply(c.red, c.green, c.blue, mode)
    return ColorCtor{ r = r, g = g, b = b, a = c.alpha or 255 }
end

return M
