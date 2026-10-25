-- Lit-primitive preview: holds the cached luminance map(s) for the active
-- primitive plus the renderer that maps luminance → ramp swatch. The map
-- math lives in primitives.lua; this module is the integration layer
-- (cache, render-to-Image, Aseprite-side glue contract).

local primitives = require("primitives")

local M = {}

-- Back-compat alias — older callers (and tests) still call buildSphereMap;
-- it now produces the sphere primitive specifically with default lighting.
function M.buildSphereMap(size)
    return primitives.build("sphere", size, nil)
end

-- Build the luminance map for the chosen primitive name with given lights.
function M.buildMap(name, size, lights)
    return primitives.build(name, size, lights)
end

-- Build a fingerprint of every input that affects the rendered preview.
-- When this matches the cached one we skip the re-render. Includes the
-- primitive name so switching primitives invalidates the cache.
function M.cacheKey(base, prefs)
    return string.format("%d,%d,%d,%d|%s|%s|%s|%s|%d,%d|%d|%.3f,%.3f,%.3f,%.3f,%.3f,%.3f|%s|%s|%s|%.3f,%.3f|%s",
        base.red, base.green, base.blue, base.alpha or 255,
        prefs.lightPrimitive or "sphere",
        prefs.colorSpace, prefs.lightPreset, prefs.cvdMode,
        prefs.customHl, prefs.customSh,
        prefs.stepCount,
        prefs.shadingFactor, prefs.shadingDesatHl, prefs.shadingDesatSh,
        prefs.shadingSatBoost, prefs.lightGamma, prefs.lightSpan,
        prefs.lights or "",
        prefs.tonePreset or "identity",
        tostring(prefs.absoluteMode),
        prefs.absShadowL or 0, prefs.absHighlightL or 0,
        tostring(prefs.showDeltaE))
end

-- Render the sphere preview into a fresh Image. Aseprite-specific globals
-- (Image, ColorMode, app.pixelColor, applyCvdToColor) are passed via `deps`
-- so this function can be called from tests with stubs if needed.
--
-- deps must contain:
--   Image, ColorMode  -- Aseprite constructors
--   pixelColor        -- app.pixelColor
--   applyCvdToColor   -- function(Color, mode) -> Color
--   buildRamp         -- function() -> array of Color (already configured for shading)
--   lumMap            -- the precomputed luminance grid (any primitive)
function M.render(size, prefs, deps)
    local ramp = deps.buildRamp()
    local steps = prefs.stepCount

    local img = deps.Image(size, size, deps.ColorMode.RGB)
    img:clear(0)

    local map = deps.lumMap or deps.sphereMap  -- accept either name for back-compat
    for y = 0, size - 1 do
        local row = map[y]
        if row then
            for x = 0, size - 1 do
                local lum = row[x]
                if lum then
                    local idx = math.floor(lum * (steps - 1) + 0.5) + 1
                    if idx < 1 then idx = 1 end
                    if idx > steps then idx = steps end
                    local c = deps.applyCvdToColor(ramp[idx], prefs.cvdMode)
                    img:drawPixel(x, y, deps.pixelColor.rgba(c.red, c.green, c.blue, 255))
                end
            end
        end
    end
    return img
end

return M
