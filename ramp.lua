-- Ramp & harmony builders + step functions. The step functions take a
-- `prefs` table for everything they need to read; this keeps the module
-- pure (no hidden globals) and trivially unit-testable.

local util   = require("util")
local color  = require("color")
local curves = require("curves")

local M = {}

----------------------------------------------------------------------
-- Defaults (also acts as the schema for plugin.preferences)
----------------------------------------------------------------------

M.DEFAULTS = {
    colorSpace     = "hsl",
    lightPreset    = "sunny",
    lightPrimitive = "sphere",
    customHl       = 50,
    customSh       = 230,
    cvdMode        = "none",
    stepCount      = 7,
    lightSpan      = 0.50,
    satSpan        = 0.50,
    hueSpan        = 60,
    shadingFactor  = 0.85,
    shadingDesatHl = 0.25,  -- S_highlight = S_base * (1 - this) — 0.25 → 75%
    shadingDesatSh = 0.40,  -- S_shadow    = S_base * (1 - this) — 0.40 → 60% (muddy darks)
    shadingSatBoost = 0.15, -- BOOSTED: 15% midtone vividness above base
    lightGamma     = 1.20,  -- shading-ramp value curve. >1 spreads extremes
    presets        = "{}",  -- JSON map of {name -> preset table}
    showDeltaE     = false, -- show under-strip ΔE diagnostic bars
    deltaIdealMin  = 0.04,  -- ΔE below this is "too close"
    deltaIdealMax  = 0.15,  -- ΔE above this is "too far"
    absoluteMode   = false, -- when true, shading/lightness L hits fixed endpoints
    absShadowL     = 0.30,  -- L at t=-1 in absolute mode (only meaningful in OKHSL)
    absHighlightL  = 0.85,  -- L at t=+1 in absolute mode
    lights         = '[{"dir":"upper-left","intensity":1.0,"enabled":true}]',
    tonePreset     = "identity",  -- name from curves.PRESET_KEYS
}

----------------------------------------------------------------------
-- Light-source presets (highlight target hue, shadow target hue)
----------------------------------------------------------------------

M.LIGHT_PRESETS = {
    sunny      = { hl =  60, sh = 240, label = "Sunny / midday"        },
    overcast   = { hl =  45, sh = 220, label = "Overcast / cloudy"     },
    sunset     = { hl =  30, sh = 200, label = "Sunset / golden hour"  },
    moonlight  = { hl = 210, sh = 240, label = "Moonlight / night"     },
    underwater = { hl = 180, sh = 210, label = "Underwater"            },
    torch      = { hl =  20, sh = 260, label = "Dungeon torch / fire"  },
    neon       = { hl = 310, sh = 180, label = "Sci-fi / neon magenta" },
    candle     = { hl =  25, sh = 250, label = "Candlelight"           },
    custom     = { hl = nil, sh = nil, label = "Custom..."             },
}

M.LIGHT_PRESET_KEYS = {
    "sunny", "overcast", "sunset", "moonlight",
    "underwater", "torch", "neon", "candle", "custom"
}

----------------------------------------------------------------------
-- Color harmonies (hue offsets from base, in degrees)
----------------------------------------------------------------------

M.HARMONIES = {
    { name = "Complementary",        offsets = {0, 180}              },
    { name = "Analogous",            offsets = {-30, 0, 30}          },
    { name = "Triadic",              offsets = {0, 120, 240}         },
    { name = "Split-complementary",  offsets = {0, 150, 210}         },
    { name = "Tetradic",             offsets = {0, 60, 180, 240}     },
    { name = "Square",               offsets = {0, 90, 180, 270}     },
}

----------------------------------------------------------------------
-- Step functions: given base (h, s, l), t in [-1, +1], and prefs,
-- return the shifted (h, s, l).
----------------------------------------------------------------------

-- Compute the new L value given base L, t, and prefs. In absolute mode the
-- ramp's shadow / highlight ends sit at fixed L values; otherwise it uses
-- the symmetric span-around-base behavior. Absolute endpoints are clamped
-- so that an out-of-bounds base doesn't invert the ramp direction.
local function lightnessFor(l, t, prefs)
    if prefs.absoluteMode then
        local lo = math.min(prefs.absShadowL,    l)
        local hi = math.max(prefs.absHighlightL, l)
        return util.asym(l, t, lo, hi)
    end
    return util.asymBounded(l, t, 0.03, 0.97, prefs.lightSpan)
end

function M.shadingStep(h, s, l, t, prefs)
    local preset = M.LIGHT_PRESETS[prefs.lightPreset] or M.LIGHT_PRESETS.sunny
    local hl = preset.hl or prefs.customHl
    local sh = preset.sh or prefs.customSh
    local target = (t >= 0) and hl or sh

    local mu = math.abs(t)

    -- 1. Value Curve: Non-linear scaling (steeper drops in shadows, bright pops in highlights)
    local mu_v   = mu ^ prefs.lightGamma
    local t_v    = (t >= 0) and mu_v or -mu_v
    local nl     = lightnessFor(l, t_v, prefs)

    -- 2. Smart Hue Routing (The Universal Exceptions)
    local arc = util.shortestArc(h, target)

    -- Exception A: Force Yellow (40-80) shadows through warm Crimson/Rust instead of Green
    if t < 0 and h >= 40 and h <= 80 and target >= 200 and target <= 260 then
        arc = -math.abs(arc) -- Force a clockwise vector
    end
    -- Exception B: Force Blue (200-260) highlights through Mint/Cyan instead of Magenta
    if t > 0 and h >= 200 and h <= 260 and target >= 40 and target <= 80 then
        arc = -math.abs(arc) -- Force a clockwise vector
    end

    -- 3. Asymmetric Hue Velocity 
    -- Shadows aggressively curve into ambient blue; highlights shift steadier toward yellow
    local hue_mu = (t < 0) and (mu ^ 1.6) or (mu ^ 0.9)
    local nh = (h + arc * hue_mu * prefs.shadingFactor) % 360

    -- 4. Advanced Saturation Parabola
    local desatEnd = (t >= 0) and prefs.shadingDesatHl or prefs.shadingDesatSh
    local boost    = 4 * mu * (1 - mu) -- Peaks exactly at mid-lights/mid-shadows to keep vibrance
    local sweep    = mu ^ 1.8

    -- Force a steeper saturation drop in the deepest crevices (Ambient Occlusion)
    if t < -0.8 then 
        sweep = sweep * 1.15 
    end

    local ns = util.clamp(s * (1 - sweep * desatEnd) + prefs.shadingSatBoost * boost, 0, 1)

    -- 5. True Sun-Bleaching at the extreme highlight end
    if t > 0.8 and nl > 0.85 then
        ns = ns * util.clamp(1.0 - (nl - 0.85) * 2.5, 0, 1)
    end

    return nh, ns, util.clamp(nl, 0, 1)
end

function M.lightnessStep(h, s, l, t, prefs)
    return h, s, lightnessFor(l, t, prefs)
end

function M.saturationStep(h, s, l, t, prefs)
    return h, util.asymBounded(s, t, 0, 1, prefs.satSpan), l
end

function M.hueStep(h, s, l, t, prefs)
    return (h + t * prefs.hueSpan) % 360, s, l
end

----------------------------------------------------------------------
-- Builders
----------------------------------------------------------------------

-- Build a ramp of `prefs.stepCount` colors from `base` by walking
-- t ∈ [-1, +1] through `stepFn`. The middle swatch is always the base color.
-- ColorCtor is the constructor used to build the output entries (Aseprite's
-- `Color` in production, a stub in tests).
function M.buildRamp(stepFn, base, prefs, ColorCtor)
    local h, s, l = color.rgbToHs(base.red, base.green, base.blue, prefs.colorSpace)
    local steps = prefs.stepCount
    local mid = math.floor(steps / 2) + 1
    local out = {}
    -- Optional tone curve applied to output L. The middle swatch stays at
    -- the base color regardless of curve so the user's pick is preserved.
    local applyCurve = not curves.isIdentity(prefs.tonePreset)
    local curve = applyCurve and curves.byName(prefs.tonePreset) or nil
    for i = 1, steps do
        local t = (i - mid) / (mid - 1)
        local nh, ns, nl = stepFn(h, s, l, t, prefs)
        if curve and i ~= mid then
            nl = util.clamp(curves.eval(curve, util.clamp(nl, 0, 1)), 0, 1)
        end
        local r, g, b = color.hsToRgb(nh, ns, nl, prefs.colorSpace)
        out[i] = ColorCtor{ r = r, g = g, b = b, a = base.alpha or 255 }
    end
    return out
end

-- Build a smart harmony row: each entry is `base` rotated by one of `offsets` degrees,
-- applying professional pixel art weight (60-30-10 rule) and natural luminance shifting.
function M.buildHarmony(base, offsets, colorSpace, ColorCtor)
    local h, s, l = color.rgbToHs(base.red, base.green, base.blue, colorSpace)
    local out = {}
    
    for i, off in ipairs(offsets) do
        local nh = (h + off) % 360
        if nh < 0 then nh = nh + 360 end

        local ns = s
        local nl = l

        -- Only alter the color if it's NOT the base anchor (Offset 0 stays pure)
        if math.abs(off) > 0.1 then
            -- Calculate the shortest angular distance from the base
            local absOff = math.abs(off)
            if absOff > 180 then absOff = 360 - absOff end

            -- The Master's Warm/Cool Curve:
            -- A cosine wave peaking at Yellow (60°) and bottoming at Blue (240°).
            -- Returns 1.0 for pure yellow, -1.0 for pure blue.
            local warmth = math.cos(math.rad(nh - 60))

            if absOff >= 120 then
                -- THE 10% ACCENT (Complements, Triadic opposites)
                -- 1. Boost saturation slightly to make the accent pop.
                ns = util.clamp(s * 1.15, 0, 1)
                -- 2. Strong shift towards its natural luminance to create stark contrast.
                nl = util.clamp(l + warmth * 0.15, 0.05, 0.95)
            else
                -- THE 30% SECONDARY (Analogous / Split neighbors)
                -- 1. Desaturate slightly so it sits behind the base color (atmospheric recession).
                ns = util.clamp(s * 0.85, 0, 1)
                -- 2. Gentle shift towards natural luminance.
                nl = util.clamp(l + warmth * 0.05, 0.05, 0.95)

                -- 3. Value Contrast: Ensure it doesn't share the exact lightness of the base.
                if math.abs(nl - l) < 0.04 then
                    nl = (l > 0.5) and (nl - 0.05) or (nl + 0.05)
                end
            end
        end

        local r, g, b = color.hsToRgb(nh, ns, nl, colorSpace)
        out[i] = ColorCtor{ r = r, g = g, b = b, a = base.alpha or 255 }
    end
    return out
end

return M