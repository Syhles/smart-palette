-- Color-space conversions: HSL (classic) and OKHSL (perceptual, via OkLab).
-- Pure math — no Aseprite types touched, so this file runs under stock Lua.
--
-- The OKHSL implementation is OkLab in cylindrical coordinates with chroma
-- normalized to [0,1] against OKLAB_CMAX so the same step functions in
-- ramp.lua can drive both spaces.

local util = require("util")

local M = {}

local OKLAB_CMAX = 0.32   -- typical max sRGB chroma; chroma > this clips to gamut
M.OKLAB_CMAX = OKLAB_CMAX

----------------------------------------------------------------------
-- sRGB gamma compansion
----------------------------------------------------------------------

function M.srgbDecompand(c)
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

function M.srgbCompand(c)
    if c <= 0.0031308 then return 12.92 * c end
    return 1.055 * (c ^ (1/2.4)) - 0.055
end

----------------------------------------------------------------------
-- HSL (classic) — fallback color space
----------------------------------------------------------------------

function M.rgbToHsl(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local h, s, l = 0, 0, (mx + mn) / 2
    if mx ~= mn then
        local d = mx - mn
        s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
        if mx == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif mx == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h * 60
    end
    return h, s, l
end

local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
end

function M.hslToRgb(h, s, l)
    local r, g, b
    if s == 0 then
        r, g, b = l, l, l
    else
        local q = l < 0.5 and l * (1 + s) or l + s - l * s
        local p = 2 * l - q
        local hn = (h % 360) / 360
        if hn < 0 then hn = hn + 1 end
        r = hue2rgb(p, q, hn + 1/3)
        g = hue2rgb(p, q, hn)
        b = hue2rgb(p, q, hn - 1/3)
    end
    return math.floor(r * 255 + 0.5),
           math.floor(g * 255 + 0.5),
           math.floor(b * 255 + 0.5)
end

----------------------------------------------------------------------
-- OkLab / OkLCh (cylindrical OkLab). Bjorn Ottosson's matrices.
----------------------------------------------------------------------

function M.rgbToOklab(r, g, b)
    -- r, g, b in [0, 1] sRGB
    r = M.srgbDecompand(r)
    g = M.srgbDecompand(g)
    b = M.srgbDecompand(b)

    local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

    l, m, s = util.cbrt(l), util.cbrt(m), util.cbrt(s)

    return  0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

function M.oklabToRgb(L, a, b)
    local l_ = L + 0.3963377774 * a + 0.2158037573 * b
    local m_ = L - 0.1055613458 * a - 0.0638541728 * b
    local s_ = L - 0.0894841775 * a - 1.2914855480 * b

    local l = l_ * l_ * l_
    local m = m_ * m_ * m_
    local s = s_ * s_ * s_

    local r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    local bl= -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    r  = util.clamp(M.srgbCompand(util.clamp(r,  0, 1)), 0, 1)
    g  = util.clamp(M.srgbCompand(util.clamp(g,  0, 1)), 0, 1)
    bl = util.clamp(M.srgbCompand(util.clamp(bl, 0, 1)), 0, 1)
    return r, g, bl
end

function M.rgbToOkhsl(r, g, b)
    local L, a, B = M.rgbToOklab(r/255, g/255, b/255)
    local C = math.sqrt(a*a + B*B)
    local h = math.deg(math.atan(B, a))
    if h < 0 then h = h + 360 end
    return h, math.min(1, C / OKLAB_CMAX), L
end

function M.okhslToRgb(h, s, l)
    local C   = s * OKLAB_CMAX
    local rad = math.rad(h)
    local a   = C * math.cos(rad)
    local B   = C * math.sin(rad)
    local r, g, bl = M.oklabToRgb(l, a, B)
    return math.floor(r * 255 + 0.5),
           math.floor(g * 255 + 0.5),
           math.floor(bl * 255 + 0.5)
end

----------------------------------------------------------------------
-- Color-space dispatch — pick HSL or OKHSL based on the `space` argument
----------------------------------------------------------------------

function M.rgbToHs(r, g, b, space)
    if space == "okhsl" then return M.rgbToOkhsl(r, g, b) end
    return M.rgbToHsl(r, g, b)
end

function M.hsToRgb(h, s, l, space)
    if space == "okhsl" then return M.okhslToRgb(h, s, l) end
    return M.hslToRgb(h, s, l)
end

return M
