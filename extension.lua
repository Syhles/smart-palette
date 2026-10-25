-- Smart Palette — pixel-art color helper for Aseprite.
--
-- A non-modal panel with three tabs:
--   Main        — Shading, Lightness, Saturation, Hue ramps from the current
--                 foreground color, plus a sphere preview and tonal-value strip.
--   Harmonies   — Complementary, Analogous, Triadic, Split-complementary,
--                 Tetradic, Square swatch rows.
--   Settings    — Color space (HSL / OKHSL), light-source preset, color-blindness
--                 simulation, ramp tunables. All persisted via plugin.preferences.
--
-- Click any swatch to set fgColor; right-click to set bgColor. Shift+click
-- adds a single swatch to the active sprite's palette; the "+ Palette" button
-- on each row adds the whole row.

local color      = require("color")
local cvd        = require("cvd")
local ramp       = require("ramp")
local sphere     = require("sphere")
local primitives = require("primitives")
local presets    = require("presets")
local delta      = require("delta")
local lospec     = require("lospec")
local kmeans     = require("kmeans")
local export     = require("export")
local curves     = require("curves")

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local SWATCH       = 22    -- pixel size of each ramp swatch
local SWATCH_SM    = 24    -- harmony swatches (slightly bigger, fewer of them)
local PAD          = 4     -- canvas padding
local SPHERE_SIZE  = 96    -- sphere preview dimensions
local MAX_STEPS    = 11    -- canvas width is sized for the max-allowed step count
local DELTA_BAR_H  = 5     -- height of the ΔE diagnostic bar under ramps

----------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------

local dlg            = nil
local fgListenerKey  = nil
local lumMaps        = {}    -- cached per-primitive luminance grids, lazy-built
local sphereCache    = { key = nil, image = nil }  -- last-rendered preview
local lockedBase     = nil   -- nil = use app.fgColor; Color = use this
local hoverText      = nil   -- last-shown hover readout (drawn in info canvas)
local prefs          = nil   -- alias to plugin.preferences (set in init)
local cvdDlg         = nil   -- secondary CVD preview window (when open)
local cvdState       = nil   -- { spriteListenerKey, siteListenerKey, watchedSprite }

----------------------------------------------------------------------
-- Utility helpers (Aseprite-specific glue)
----------------------------------------------------------------------

local function getBase()
    return lockedBase or app.fgColor
end

local function applyCvdToColor(c, mode)
    return cvd.applyToColor(c, mode or prefs.cvdMode, Color)
end

local function colorToHex(c)
    return string.format("#%02x%02x%02x", c.red, c.green, c.blue)
end

local function setFgOrBg(c, button)
    if button == MouseButton.RIGHT then
        app.bgColor = c
    else
        app.fgColor = c
    end
end

-- Sample up to maxSamples opaque pixels from the active sprite's first
-- frame, return as an array of {r, g, b} triples. Skips fully transparent
-- pixels so they don't pull centroids toward black.
local function sampleSpritePixels(sprite, maxSamples)
    local frame = sprite.frames[1]
    local img = Image(sprite, frame)
    local total = img.width * img.height
    local stride = math.max(1, math.floor(total / maxSamples))
    local pc = app.pixelColor
    local out = {}
    local i = 0
    for y = 0, img.height - 1 do
        for x = 0, img.width - 1 do
            if i % stride == 0 then
                local px = img:getPixel(x, y)
                local a  = pc.rgbaA(px)
                if a > 128 then
                    table.insert(out, { pc.rgbaR(px), pc.rgbaG(px), pc.rgbaB(px) })
                end
            end
            i = i + 1
        end
    end
    return out
end

-- Run OkLab k-means on sprite samples and return an array of Color centroids
-- sorted shadow → highlight.
local function harmonizeSprite(k)
    local sprite = app.activeSprite
    if not sprite then
        app.alert("No active sprite. Open or create one first.")
        return nil
    end
    local rgb = sampleSpritePixels(sprite, 8000)
    if #rgb == 0 then
        app.alert("Sprite has no opaque pixels to sample.")
        return nil
    end
    local lab = {}
    for i, s in ipairs(rgb) do
        local L, a, b = color.rgbToOklab(s[1]/255, s[2]/255, s[3]/255)
        lab[i] = { L, a, b }
    end
    local centroids = kmeans.kmeans(lab, k or prefs.stepCount, { maxIter = 30 })
    kmeans.sortByL(centroids)
    local out = {}
    for i, c in ipairs(centroids) do
        local r, g, b = color.oklabToRgb(c[1], c[2], c[3])
        out[i] = Color{
            r = math.floor(r * 255 + 0.5),
            g = math.floor(g * 255 + 0.5),
            b = math.floor(b * 255 + 0.5),
            a = 255,
        }
    end
    return out
end

-- Append `colors` to the active sprite's palette inside an undo-able transaction.
-- Surfaces friendly errors for the no-active-sprite and indexed-overflow cases.
local function addColorsToPalette(colors, label)
    local sprite = app.activeSprite
    if not sprite then
        app.alert("No active sprite — open or create one to add colors to its palette.")
        return
    end
    local pal = sprite.palettes[1]
    local n = #pal
    if sprite.colorMode == ColorMode.INDEXED and (n + #colors) > 256 then
        app.alert("Palette is full (256 colors). Remove some entries to add more.")
        return
    end
    app.transaction(label or "Add Smart Palette colors", function()
        pal:resize(n + #colors)
        for i, c in ipairs(colors) do
            pal:setColor(n + i - 1, c)
        end
    end)
end

----------------------------------------------------------------------
-- Ramp / harmony helpers — bind the Color ctor and prefs into the pure builders
----------------------------------------------------------------------

local function buildRamp(stepFn, base)
    return ramp.buildRamp(stepFn, base, prefs, Color)
end

local function buildHarmony(base, offsets)
    return ramp.buildHarmony(base, offsets, prefs.colorSpace, Color)
end

----------------------------------------------------------------------
-- Sphere preview
----------------------------------------------------------------------

-- Decode prefs.lights (a JSON array) into a list of {dir = vec, intensity}
-- entries suitable for primitives.build. Returns nil if no lights are
-- enabled, which lets primitives fall back to its default (single
-- upper-left light).
local function activeLights()
    local raw = presets.decodeAll(prefs.lights or "[]")  -- reuses the json+normalize helper
    -- decodeAll returns either an array-shaped table or {} when malformed.
    -- Walk it and convert direction names to vectors.
    local out = {}
    for i = 1, 8 do  -- support up to 8 entries; UI exposes 3
        local entry = raw[i]
        if entry then
            local enabled = entry.enabled
            -- JSON booleans round-trip as Lua booleans via Aseprite's codec;
            -- treat missing / non-false as enabled for forward-compat.
            if enabled == nil then enabled = true end
            local intensity = tonumber(entry.intensity) or 0
            local dirName = entry.dir or "upper-left"
            local dirVec = primitives.LIGHT_DIRS[dirName]
            if enabled and intensity > 0 and dirVec then
                table.insert(out, { dir = dirVec, intensity = intensity })
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Cache lumMaps by both primitive AND lights signature so changing lights
-- invalidates the right map. Use prefs.lights as the lights component of
-- the key; it's already canonicalized by JSON encoding.
local function lumMapFor(prim)
    local key = prim .. "|" .. (prefs.lights or "")
    if not lumMaps[key] then
        lumMaps[key] = primitives.build(prim, SPHERE_SIZE, activeLights())
    end
    return lumMaps[key]
end

----------------------------------------------------------------------
-- CVD preview window — separate non-modal dialog showing the active
-- sprite re-rendered through the chosen CVD matrix. Non-destructive
-- (we never touch the sprite); refreshes on sprite/site change events.
----------------------------------------------------------------------

local CVD_PREVIEW_SIZE = 256  -- canvas dimension; sprite scales to fit

local function renderCvdPreviewImage()
    local sprite = app.activeSprite
    if not sprite then return nil end
    local frame = app.activeFrame or sprite.frames[1]
    local src = Image(sprite, frame)
    local pc = app.pixelColor
    local out = Image(src.width, src.height, ColorMode.RGB)
    out:clear(0)
    for y = 0, src.height - 1 do
        for x = 0, src.width - 1 do
            local px = src:getPixel(x, y)
            local a = pc.rgbaA(px)
            if a > 0 then
                local r, g, b = pc.rgbaR(px), pc.rgbaG(px), pc.rgbaB(px)
                if prefs.cvdMode ~= "none" then
                    r, g, b = cvd.apply(r, g, b, prefs.cvdMode)
                end
                out:drawPixel(x, y, pc.rgba(r, g, b, a))
            end
        end
    end
    return out
end

local function detachCvdListeners()
    if not cvdState then return end
    if cvdState.spriteListenerKey and cvdState.watchedSprite then
        pcall(function()
            cvdState.watchedSprite.events:off(cvdState.spriteListenerKey)
        end)
    end
    if cvdState.siteListenerKey then
        pcall(function() app.events:off(cvdState.siteListenerKey) end)
    end
    cvdState = nil
end

local function attachCvdListeners(repaintFn)
    detachCvdListeners()
    cvdState = { watchedSprite = app.activeSprite }
    if cvdState.watchedSprite then
        cvdState.spriteListenerKey =
            cvdState.watchedSprite.events:on("change", repaintFn)
    end
    cvdState.siteListenerKey = app.events:on("sitechange", function()
        -- Active sprite may have changed; reattach to the new one.
        if cvdState and app.activeSprite ~= cvdState.watchedSprite then
            if cvdState.spriteListenerKey and cvdState.watchedSprite then
                pcall(function()
                    cvdState.watchedSprite.events:off(cvdState.spriteListenerKey)
                end)
            end
            cvdState.watchedSprite = app.activeSprite
            if cvdState.watchedSprite then
                cvdState.spriteListenerKey =
                    cvdState.watchedSprite.events:on("change", repaintFn)
            end
        end
        repaintFn()
    end)
end

local function openCvdPreview()
    if cvdDlg then
        cvdDlg:show{ wait = false }
        return
    end
    cvdDlg = Dialog{
        title   = "CVD Preview",
        onclose = function()
            detachCvdListeners()
            cvdDlg = nil
        end,
    }
    cvdDlg:label{ id = "status", text = "Mode: " .. cvd.LABEL[prefs.cvdMode] }
    cvdDlg:newrow()
    cvdDlg:canvas{
        id     = "preview",
        width  = CVD_PREVIEW_SIZE,
        height = CVD_PREVIEW_SIZE,
        onpaint = function(ev)
            local gc = ev.context
            gc.color = Color{ r = 30, g = 30, b = 30, a = 255 }
            gc:fillRect(Rectangle(0, 0, CVD_PREVIEW_SIZE, CVD_PREVIEW_SIZE))
            local img = renderCvdPreviewImage()
            if not img then
                gc.color = Color{ r = 200, g = 200, b = 200, a = 255 }
                gc:fillText("(no active sprite)", 8, CVD_PREVIEW_SIZE / 2)
                return
            end
            -- Fit the rendered image into the canvas, preserving aspect.
            local scale = math.min(CVD_PREVIEW_SIZE / img.width,
                                   CVD_PREVIEW_SIZE / img.height)
            local dw = math.floor(img.width  * scale)
            local dh = math.floor(img.height * scale)
            local dx = math.floor((CVD_PREVIEW_SIZE - dw) / 2)
            local dy = math.floor((CVD_PREVIEW_SIZE - dh) / 2)
            -- gc:drawImage(image, srcRect, dstRect) scales the blit.
            gc:drawImage(img,
                Rectangle(0, 0, img.width, img.height),
                Rectangle(dx, dy, dw, dh))
        end,
    }
    attachCvdListeners(function()
        if cvdDlg then
            cvdDlg:modify{ id = "status", text = "Mode: " .. cvd.LABEL[prefs.cvdMode] }
            cvdDlg:repaint()
        end
    end)
    cvdDlg:show{ wait = false }
end

local function paintSphere(gc)
    local base = getBase()
    local key = sphere.cacheKey(base, prefs)
    if sphereCache.key ~= key then
        local prim = prefs.lightPrimitive or "sphere"
        sphereCache.image = sphere.render(SPHERE_SIZE, prefs, {
            Image           = Image,
            ColorMode       = ColorMode,
            pixelColor      = app.pixelColor,
            applyCvdToColor = applyCvdToColor,
            buildRamp       = function() return buildRamp(ramp.shadingStep, base) end,
            lumMap          = lumMapFor(prim),
        })
        sphereCache.key = key
    end
    gc:drawImage(sphereCache.image, 0, 0)
end

----------------------------------------------------------------------
-- Hover readout
----------------------------------------------------------------------

-- Set the hover-readout text. We use a fixed-size canvas (not dlg:label) so
-- the dialog never resizes when the readout's length changes — a label-based
-- approach left ghost artifacts of the previous frame's layout.
local function updateInfoLabel(c)
    local newText
    if c then
        local h, s, l = color.rgbToHsl(c.red, c.green, c.blue)
        newText = string.format("%s  RGB(%d, %d, %d)  HSL(%d°, %d%%, %d%%)",
            colorToHex(c), c.red, c.green, c.blue,
            math.floor(h + 0.5), math.floor(s * 100 + 0.5), math.floor(l * 100 + 0.5))
    end
    if newText == hoverText then return end
    hoverText = newText
    if dlg then dlg:repaint() end
end

----------------------------------------------------------------------
-- Generic swatch-row canvas: takes a function that builds a list of colors
-- and renders them in a horizontal strip with click/right-click/hover wired up.
----------------------------------------------------------------------

local function makeSwatchStrip(d, opts)
    -- opts: id, label, colorsFn (returns array of Color), swatchSize (px),
    --       maxCount (canvas width budget), centerIndex (or nil for none),
    --       enableDeltaE (bool — reserve room for ΔE bar even when off)
    local sw         = opts.swatchSize or SWATCH
    local maxCount   = opts.maxCount or MAX_STEPS
    local hasDelta   = opts.enableDeltaE == true
    local width      = maxCount * sw + PAD * 2
    local extraH     = hasDelta and (DELTA_BAR_H + 2) or 0
    local height     = sw + PAD * 2 + extraH

    if opts.label then
        d:label{ text = opts.label }
        d:newrow()
    end

    d:canvas{
        id     = opts.id,
        width  = width,
        height = height,

        onpaint = function(ev)
            local gc = ev.context
            local colors = opts.colorsFn()
            for i, c in ipairs(colors) do
                gc.color = applyCvdToColor(c)
                gc:fillRect(Rectangle(PAD + (i - 1) * sw, PAD, sw, sw))
            end
            if opts.centerIndex then
                local mid = opts.centerIndex(#colors)
                if mid then
                    gc.color = Color{ r = 255, g = 255, b = 255, a = 255 }
                    gc.strokeWidth = 2
                    gc:strokeRect(Rectangle(PAD + (mid - 1) * sw, PAD, sw, sw))
                    gc.color = Color{ r = 0, g = 0, b = 0, a = 255 }
                    gc.strokeWidth = 1
                    gc:strokeRect(Rectangle(PAD + (mid - 1) * sw + 1, PAD + 1, sw - 2, sw - 2))
                end
            end
            -- ΔE diagnostic bars: one per gap between adjacent swatches.
            -- Visible only when prefs.showDeltaE is on.
            if hasDelta and prefs.showDeltaE then
                local barY = PAD + sw + 2
                for i = 1, #colors - 1 do
                    local c1 = applyCvdToColor(colors[i])
                    local c2 = applyCvdToColor(colors[i + 1])
                    local de = delta.oklabDeltaE(c1.red, c1.green, c1.blue,
                                                 c2.red, c2.green, c2.blue)
                    local k = delta.classify(de, prefs.deltaIdealMin, prefs.deltaIdealMax)
                    local r, g, b = delta.classifyColor(k)
                    gc.color = Color{ r = r, g = g, b = b, a = 255 }
                    -- Bar centered on the boundary between swatches i and i+1.
                    local barX = PAD + (i - 1) * sw + math.floor(sw / 2)
                    gc:fillRect(Rectangle(barX, barY, sw, DELTA_BAR_H))
                end
            end
        end,

        onmousedown = function(ev)
            if ev.x < PAD or ev.y < PAD then return end
            local i = math.floor((ev.x - PAD) / sw) + 1
            local colors = opts.colorsFn()
            if i < 1 or i > #colors then return end
            local c = applyCvdToColor(colors[i])
            -- Shift+click adds the single swatch to the palette instead of setting fg/bg.
            if ev.shiftKey then
                addColorsToPalette({ c }, "Add swatch to palette")
            else
                setFgOrBg(c, ev.button)
            end
        end,

        onmousemove = function(ev)
            if ev.x < PAD or ev.y < PAD or ev.y > PAD + sw then
                updateInfoLabel(nil)
                return
            end
            local i = math.floor((ev.x - PAD) / sw) + 1
            local colors = opts.colorsFn()
            if i < 1 or i > #colors then
                updateInfoLabel(nil)
                return
            end
            updateInfoLabel(applyCvdToColor(colors[i]))
        end,
    }
end

----------------------------------------------------------------------
-- Main tab — info readout, lock, sphere preview, 4 ramps, value strip
----------------------------------------------------------------------

local function midOfRamp(n) return math.floor(n / 2) + 1 end

local function makeRamp(d, id, label, stepFn)
    makeSwatchStrip(d, {
        id           = id,
        label        = label,
        colorsFn     = function() return buildRamp(stepFn, getBase()) end,
        swatchSize   = SWATCH,
        maxCount     = MAX_STEPS,
        centerIndex  = midOfRamp,
        enableDeltaE = true,
    })
    d:button{
        id      = id .. "_add",
        text    = "+ Palette",
        onclick = function()
            local r = buildRamp(stepFn, getBase())
            local out = {}
            for i, c in ipairs(r) do out[i] = applyCvdToColor(c) end
            addColorsToPalette(out, "Add " .. label .. " ramp")
        end,
    }
    d:newrow()
end

-- Tonal-value strip: same shading ramp rendered as luminance grays, so the user
-- can verify that the shading has good value contrast independent of hue.
local function makeValueStrip(d)
    d:label{ text = "Tonal value" }
    d:newrow()
    d:canvas{
        id     = "valuestrip",
        width  = MAX_STEPS * SWATCH + PAD * 2,
        height = math.floor(SWATCH * 0.5) + PAD * 2,
        onpaint = function(ev)
            local gc = ev.context
            local r = buildRamp(ramp.shadingStep, getBase())
            local h = math.floor(SWATCH * 0.5)
            for i, c in ipairs(r) do
                local cc = applyCvdToColor(c)
                -- Luminance via Rec.709 weights
                local y = math.floor(0.2126 * cc.red + 0.7152 * cc.green + 0.0722 * cc.blue + 0.5)
                gc.color = Color{ r = y, g = y, b = y, a = 255 }
                gc:fillRect(Rectangle(PAD + (i - 1) * SWATCH, PAD, SWATCH, h))
            end
        end,
    }
    d:newrow()
end

local function buildMainTab(d)
    -- Hover readout: a fixed-size canvas drawing text via gc:fillText. Using a
    -- canvas (not dlg:label) keeps the dialog from resizing when the readout
    -- text changes length — a label-based version produced redraw artifacts.
    d:canvas{
        id     = "info",
        width  = MAX_STEPS * SWATCH + PAD * 2,
        height = 22,
        onpaint = function(ev)
            local gc = ev.context
            gc.color = Color{ r = 180, g = 180, b = 180, a = 255 }
            -- 22px canvas, baseline at y=15 leaves ~14px ascent and ~6px
            -- descent — comfortable for the Aseprite default UI font.
            gc:fillText(hoverText or "—", PAD, 15)
        end,
    }
    d:newrow()

    d:check{
        id       = "lock",
        text     = "Lock base color",
        selected = lockedBase ~= nil,
        onclick  = function()
            if lockedBase then
                lockedBase = nil
            else
                lockedBase = Color(app.fgColor)
            end
            d:repaint()
        end,
    }
    d:newrow()

    d:canvas{
        id     = "sphere",
        width  = SPHERE_SIZE,
        height = SPHERE_SIZE,
        onpaint = function(ev) paintSphere(ev.context) end,
    }
    d:newrow()

    makeRamp(d, "shading",    "Shading",    ramp.shadingStep)
    makeValueStrip(d)
    makeRamp(d, "lightness",  "Lightness",  ramp.lightnessStep)
    makeRamp(d, "saturation", "Saturation", ramp.saturationStep)
    makeRamp(d, "hue",        "Hue",        ramp.hueStep)
end

----------------------------------------------------------------------
-- Harmonies tab
----------------------------------------------------------------------

local function buildHarmoniesTab(d)
    for i, harmony in ipairs(ramp.HARMONIES) do
        makeSwatchStrip(d, {
            id         = "harm_" .. i,
            label      = harmony.name,
            colorsFn   = function() return buildHarmony(getBase(), harmony.offsets) end,
            swatchSize = SWATCH_SM,
            maxCount   = 4,
        })
        d:button{
            id      = "harm_" .. i .. "_add",
            text    = "+ Palette",
            onclick = function()
                local h = buildHarmony(getBase(), harmony.offsets)
                local out = {}
                for j, c in ipairs(h) do out[j] = applyCvdToColor(c) end
                addColorsToPalette(out, "Add " .. harmony.name .. " harmony")
            end,
        }
        d:newrow()
    end
end

----------------------------------------------------------------------
-- Settings tab
----------------------------------------------------------------------

local function presetOptions()
    local opts = {}
    for i, key in ipairs(ramp.LIGHT_PRESET_KEYS) do
        opts[i] = ramp.LIGHT_PRESETS[key].label
    end
    return opts
end

local function presetKeyFromLabel(label)
    for _, key in ipairs(ramp.LIGHT_PRESET_KEYS) do
        if ramp.LIGHT_PRESETS[key].label == label then return key end
    end
    return "sunny"
end

local function cvdOptions()
    local opts = {}
    for i, key in ipairs(cvd.KEYS) do opts[i] = cvd.LABEL[key] end
    return opts
end

local function cvdKeyFromLabel(label)
    for _, key in ipairs(cvd.KEYS) do
        if cvd.LABEL[key] == label then return key end
    end
    return "none"
end

local function primitiveOptions()
    local opts = {}
    for i, key in ipairs(primitives.KEYS) do opts[i] = primitives.LABEL[key] end
    return opts
end

local function primitiveKeyFromLabel(label)
    for _, key in ipairs(primitives.KEYS) do
        if primitives.LABEL[key] == label then return key end
    end
    return "sphere"
end

local function lightDirOptions()
    local opts = {}
    for i, key in ipairs(primitives.LIGHT_DIR_KEYS) do
        opts[i] = primitives.LIGHT_DIR_LABEL[key]
    end
    return opts
end

local function lightDirKeyFromLabel(label)
    for _, key in ipairs(primitives.LIGHT_DIR_KEYS) do
        if primitives.LIGHT_DIR_LABEL[key] == label then return key end
    end
    return "upper-left"
end

local function refreshAll()
    if dlg then dlg:repaint() end
end

-- Read the three light-slot widgets and re-encode prefs.lights from them.
local function syncLightsFromWidgets(d)
    local arr = {}
    for slot = 1, 3 do
        local pre = "light" .. slot
        arr[slot] = {
            enabled   = d.data[pre .. "_en"] and true or false,
            dir       = lightDirKeyFromLabel(d.data[pre .. "_dir"]),
            intensity = (d.data[pre .. "_int"] or 0) / 100,
        }
    end
    prefs.lights = presets.encodeAll(arr)
    refreshAll()
end

-- Load prefs.lights and pad to 3 entries (filling missing slots with disabled).
local function loadLightSlots()
    local raw = presets.decodeAll(prefs.lights or "[]")
    local out = {}
    for i = 1, 3 do
        local r = raw[i] or {}
        local enabled = r.enabled
        if enabled == nil then enabled = (i == 1) end  -- only slot 1 default-enabled
        out[i] = {
            enabled   = enabled and true or false,
            dir       = r.dir or (i == 1 and "upper-left" or "rim-back"),
            intensity = tonumber(r.intensity) or (i == 1 and 1.0 or 0.0),
        }
    end
    return out
end

-- Push the values currently in `prefs` into every Settings-tab widget.
-- Used by the Reset button and by Load Preset, so widget state stays in
-- sync with the underlying prefs after a bulk update.
local function syncSettingsWidgets(d)
    d:modify{ id = "colorSpace",     option = prefs.colorSpace == "okhsl" and "OKHSL (perceptual)" or "HSL (classic)" }
    d:modify{ id = "lightPrimitive", option = primitives.LABEL[prefs.lightPrimitive or "sphere"] }
    d:modify{ id = "lightPreset",    option = ramp.LIGHT_PRESETS[prefs.lightPreset].label }
    d:modify{ id = "customHl",       value = prefs.customHl, visible = prefs.lightPreset == "custom" }
    d:modify{ id = "customSh",       value = prefs.customSh, visible = prefs.lightPreset == "custom" }
    d:modify{ id = "cvdMode",        option = cvd.LABEL[prefs.cvdMode] }
    d:modify{ id = "showDeltaE",     selected = prefs.showDeltaE }
    d:modify{ id = "tonePreset",     option = curves.PRESET_LABEL[prefs.tonePreset or "identity"] }
    d:modify{ id = "absoluteMode",   selected = prefs.absoluteMode }
    d:modify{ id = "absShadowL",     value = math.floor(prefs.absShadowL * 100 + 0.5),
                                     visible = prefs.absoluteMode }
    d:modify{ id = "absHighlightL",  value = math.floor(prefs.absHighlightL * 100 + 0.5),
                                     visible = prefs.absoluteMode }
    d:modify{ id = "stepCount",      value = prefs.stepCount }
    d:modify{ id = "lightSpan",      value = math.floor(prefs.lightSpan * 100 + 0.5) }
    d:modify{ id = "satSpan",        value = math.floor(prefs.satSpan * 100 + 0.5) }
    d:modify{ id = "hueSpan",        value = prefs.hueSpan }
    d:modify{ id = "shadingFactor",   value = math.floor(prefs.shadingFactor * 100 + 0.5) }
    d:modify{ id = "shadingDesatHl",  value = math.floor(prefs.shadingDesatHl * 100 + 0.5) }
    d:modify{ id = "shadingDesatSh",  value = math.floor(prefs.shadingDesatSh * 100 + 0.5) }
    d:modify{ id = "shadingSatBoost", value = math.floor(prefs.shadingSatBoost * 100 + 0.5) }
    d:modify{ id = "lightGamma",      value = math.floor(prefs.lightGamma * 100 + 0.5) }
    -- Light slots: push the decoded lights back to the per-slot widgets.
    local slotData = loadLightSlots()
    for slot = 1, 3 do
        local pre = "light" .. slot
        local s = slotData[slot]
        d:modify{ id = pre .. "_en",  selected = s.enabled }
        d:modify{ id = pre .. "_dir", option   = primitives.LIGHT_DIR_LABEL[s.dir] }
        d:modify{ id = pre .. "_int", value    = math.floor(s.intensity * 100 + 0.5) }
    end
end

----------------------------------------------------------------------
-- Settings split across three tabs (Light / Ramp / Tools) so each
-- fits on screen — Aseprite's Dialog has no scroll container.
----------------------------------------------------------------------

local function buildLightTab(d)
    d:separator{ text = "Preview" }
    d:combobox{
        id       = "lightPrimitive",
        label    = "Shape",
        option   = primitives.LABEL[prefs.lightPrimitive or "sphere"],
        options  = primitiveOptions(),
        onchange = function()
            prefs.lightPrimitive = primitiveKeyFromLabel(d.data.lightPrimitive)
            refreshAll()
        end,
    }
    d:newrow()

    d:separator{ text = "Light source" }
    d:combobox{
        id       = "lightPreset",
        label    = "Preset",
        option   = ramp.LIGHT_PRESETS[prefs.lightPreset].label,
        options  = presetOptions(),
        onchange = function()
            prefs.lightPreset = presetKeyFromLabel(d.data.lightPreset)
            d:modify{ id = "customHl", visible = prefs.lightPreset == "custom" }
            d:modify{ id = "customSh", visible = prefs.lightPreset == "custom" }
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "customHl",
        label    = "Highlight hue",
        min      = 0,
        max      = 359,
        value    = prefs.customHl,
        visible  = prefs.lightPreset == "custom",
        onchange = function()
            prefs.customHl = d.data.customHl
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "customSh",
        label    = "Shadow hue",
        min      = 0,
        max      = 359,
        value    = prefs.customSh,
        visible  = prefs.lightPreset == "custom",
        onchange = function()
            prefs.customSh = d.data.customSh
            refreshAll()
        end,
    }
    d:newrow()

    d:separator{ text = "Lights (key / fill / rim)" }
    -- Three light slots. Slot 1 defaults on as the "key" light; 2 and 3
    -- start off and act as fill / rim. Each row has enabled + direction +
    -- intensity. Any change re-encodes prefs.lights and triggers a rerender.
    local slotData = loadLightSlots()
    for slot = 1, 3 do
        local pre = "light" .. slot
        local s = slotData[slot]
        d:check{
            id       = pre .. "_en",
            label    = "Light " .. slot,
            text     = "on",
            selected = s.enabled,
            onchange = function() syncLightsFromWidgets(d) end,
        }
        d:combobox{
            id       = pre .. "_dir",
            option   = primitives.LIGHT_DIR_LABEL[s.dir],
            options  = lightDirOptions(),
            onchange = function() syncLightsFromWidgets(d) end,
        }
        d:slider{
            id       = pre .. "_int",
            min      = 0,
            max      = 100,
            value    = math.floor(s.intensity * 100 + 0.5),
            onchange = function() syncLightsFromWidgets(d) end,
        }
        d:newrow()
    end
end

local function buildRampTab(d)
    d:separator{ text = "Color space" }
    d:combobox{
        id       = "colorSpace",
        label    = "Space",
        option   = prefs.colorSpace == "okhsl" and "OKHSL (perceptual)" or "HSL (classic)",
        options  = { "HSL (classic)", "OKHSL (perceptual)" },
        onchange = function()
            prefs.colorSpace = (d.data.colorSpace == "OKHSL (perceptual)") and "okhsl" or "hsl"
            refreshAll()
        end,
    }
    d:newrow()

    d:separator{ text = "Tunables" }
    d:slider{
        id       = "stepCount",
        label    = "Step count",
        min      = 5,
        max      = MAX_STEPS,
        value    = prefs.stepCount,
        onchange = function()
            -- Only odd counts make sense (so there's a center swatch).
            local v = d.data.stepCount
            if v % 2 == 0 then v = v + 1 end
            if v > MAX_STEPS then v = MAX_STEPS end
            prefs.stepCount = v
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "lightSpan",
        label    = "Lightness span (%)",
        min      = 10,
        max      = 60,
        value    = math.floor(prefs.lightSpan * 100 + 0.5),
        onchange = function()
            prefs.lightSpan = d.data.lightSpan / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "satSpan",
        label    = "Saturation span (%)",
        min      = 10,
        max      = 100,
        value    = math.floor(prefs.satSpan * 100 + 0.5),
        onchange = function()
            prefs.satSpan = d.data.satSpan / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "hueSpan",
        label    = "Hue span (°)",
        min      = 15,
        max      = 180,
        value    = prefs.hueSpan,
        onchange = function()
            prefs.hueSpan = d.data.hueSpan
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "shadingFactor",
        label    = "Shading hue strength (%)",
        min      = 0,
        max      = 100,
        value    = math.floor(prefs.shadingFactor * 100 + 0.5),
        onchange = function()
            prefs.shadingFactor = d.data.shadingFactor / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "shadingDesatHl",
        label    = "Highlight desat (%)",
        min      = 0,
        max      = 50,
        value    = math.floor(prefs.shadingDesatHl * 100 + 0.5),
        onchange = function()
            prefs.shadingDesatHl = d.data.shadingDesatHl / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "shadingDesatSh",
        label    = "Shadow desat (%)",
        min      = 0,
        max      = 50,
        value    = math.floor(prefs.shadingDesatSh * 100 + 0.5),
        onchange = function()
            prefs.shadingDesatSh = d.data.shadingDesatSh / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "shadingSatBoost",
        label    = "Midtone sat boost (%)",
        min      = 0,
        max      = 30,
        value    = math.floor(prefs.shadingSatBoost * 100 + 0.5),
        onchange = function()
            prefs.shadingSatBoost = d.data.shadingSatBoost / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "lightGamma",
        label    = "Value contrast (%)",
        min      = 100,
        max      = 200,
        value    = math.floor(prefs.lightGamma * 100 + 0.5),
        onchange = function()
            prefs.lightGamma = d.data.lightGamma / 100
            refreshAll()
        end,
    }
    d:newrow()

    d:separator{ text = "Tone curve" }
    do
        local labels, sel = {}, curves.PRESET_LABEL[prefs.tonePreset or "identity"]
        for i, k in ipairs(curves.PRESET_KEYS) do labels[i] = curves.PRESET_LABEL[k] end
        d:combobox{
            id      = "tonePreset",
            label   = "Curve",
            option  = sel,
            options = labels,
            onchange = function()
                local pickedLabel = d.data.tonePreset
                for _, k in ipairs(curves.PRESET_KEYS) do
                    if curves.PRESET_LABEL[k] == pickedLabel then
                        prefs.tonePreset = k
                        break
                    end
                end
                refreshAll()
            end,
        }
    end
    d:newrow()

    d:separator{ text = "Absolute lightness" }
    d:check{
        id       = "absoluteMode",
        label    = "Mode",
        text     = "lock shadow/highlight L to fixed values",
        selected = prefs.absoluteMode,
        onchange = function()
            prefs.absoluteMode = d.data.absoluteMode
            d:modify{ id = "absShadowL",    visible = prefs.absoluteMode }
            d:modify{ id = "absHighlightL", visible = prefs.absoluteMode }
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "absShadowL",
        label    = "Shadow L (%)",
        min      = 0,
        max      = 100,
        value    = math.floor(prefs.absShadowL * 100 + 0.5),
        visible  = prefs.absoluteMode,
        onchange = function()
            prefs.absShadowL = d.data.absShadowL / 100
            refreshAll()
        end,
    }
    d:newrow()
    d:slider{
        id       = "absHighlightL",
        label    = "Highlight L (%)",
        min      = 0,
        max      = 100,
        value    = math.floor(prefs.absHighlightL * 100 + 0.5),
        visible  = prefs.absoluteMode,
        onchange = function()
            prefs.absHighlightL = d.data.absHighlightL / 100
            refreshAll()
        end,
    }
    d:newrow()
end

local function buildToolsTab(d)
    -- Presets row sits up top so users can swap configurations without
    -- scrolling past every tunable.
    d:separator{ text = "Presets" }
    local presetMap  = presets.decodeAll(prefs.presets)
    local presetList = presets.list(presetMap)
    table.insert(presetList, 1, "")  -- empty entry = "no preset chosen"

    d:combobox{
        id      = "presetLoad",
        label   = "Load",
        option  = "",
        options = presetList,
        onchange = function()
            local name = d.data.presetLoad
            local map  = presets.decodeAll(prefs.presets)
            if name and name ~= "" and map[name] then
                presets.apply(prefs, map[name])
                syncSettingsWidgets(d)
                refreshAll()
            end
        end,
    }
    d:newrow()
    d:entry{
        id    = "presetName",
        label = "Name",
        text  = "",
    }
    d:newrow()
    d:button{
        id   = "presetSave",
        text = "Save current",
        onclick = function()
            local name = d.data.presetName
            if not name or name == "" then
                app.alert("Enter a preset name first.")
                return
            end
            local map = presets.decodeAll(prefs.presets)
            presets.save(map, name, prefs)
            prefs.presets = presets.encodeAll(map)
            local newList = presets.list(map)
            table.insert(newList, 1, "")
            d:modify{ id = "presetLoad", options = newList, option = name }
        end,
    }
    d:button{
        id   = "presetDelete",
        text = "Delete",
        onclick = function()
            local name = d.data.presetLoad
            if not name or name == "" then return end
            local map = presets.decodeAll(prefs.presets)
            presets.delete(map, name)
            prefs.presets = presets.encodeAll(map)
            local newList = presets.list(map)
            table.insert(newList, 1, "")
            d:modify{ id = "presetLoad", options = newList, option = "" }
        end,
    }
    d:newrow()

    d:separator{ text = "Export shading ramp" }
    local exportFormatLabels = {}
    for i, f in ipairs(export.FORMATS) do exportFormatLabels[i] = f.label end
    d:combobox{
        id      = "exportFormat",
        label   = "Format",
        option  = export.FORMATS[1].label,
        options = exportFormatLabels,
    }
    d:newrow()
    -- The file widget opens the system Save dialog when clicked. After the
    -- user picks a path, onchange fires and we write the ramp to disk.
    d:file{
        id       = "exportPath",
        label    = "Save to",
        save     = true,
        filename = "smart-palette-shading.gpl",
        onchange = function()
            local outPath = d.data.exportPath
            if not outPath or outPath == "" then return end
            local chosen
            for _, f in ipairs(export.FORMATS) do
                if f.label == d.data.exportFormat then chosen = f; break end
            end
            if not chosen then return end
            local cs = buildRamp(ramp.shadingStep, getBase())
            local out = {}
            for i, c in ipairs(cs) do out[i] = applyCvdToColor(c) end
            local body = chosen.fn(out, "Smart Palette shading")
            local fh, err = io.open(outPath, "w")
            if not fh then
                app.alert("Could not write file: " .. tostring(err))
                return
            end
            fh:write(body)
            fh:close()
        end,
    }
    d:newrow()

    d:separator{ text = "Sprite analysis" }
    d:button{
        id   = "harmonize",
        text = "Harmonize active sprite",
        onclick = function()
            local cs = harmonizeSprite(prefs.stepCount)
            if cs then
                addColorsToPalette(cs, "Harmonize sprite (k-means in OkLab)")
            end
        end,
    }
    d:newrow()

    d:separator{ text = "Lospec import" }
    d:entry{
        id    = "lospecName",
        label = "Palette",
        text  = "",
    }
    d:button{
        id   = "lospecImport",
        text = "Import",
        onclick = function()
            local name = d.data.lospecName
            if not name or name == "" then
                app.alert("Type a Lospec palette name first (e.g. 'endesga-32').")
                return
            end
            local slug = lospec.slugify(name)
            local body, err = lospec.fetch(slug)
            if not body then
                app.alert("Lospec import failed: " .. tostring(err) ..
                          "\n\nNote: Aseprite asks for permission the first time a script runs an external command (curl).")
                return
            end
            local hexes, perr = lospec.parsePalette(body)
            if not hexes then
                app.alert("Lospec parse failed: " .. tostring(perr))
                return
            end
            local cobjs = {}
            for i, hex in ipairs(hexes) do
                local r, g, b = lospec.hexToRgb(hex)
                if r then cobjs[i] = Color{ r = r, g = g, b = b, a = 255 } end
            end
            addColorsToPalette(cobjs, "Import Lospec: " .. slug)
        end,
    }
    d:newrow()

    d:separator{ text = "Color-blindness preview" }
    d:combobox{
        id       = "cvdMode",
        label    = "Simulate",
        option   = cvd.LABEL[prefs.cvdMode],
        options  = cvdOptions(),
        onchange = function()
            prefs.cvdMode = cvdKeyFromLabel(d.data.cvdMode)
            if cvdDlg then cvdDlg:repaint() end
            refreshAll()
        end,
    }
    d:newrow()
    d:button{
        id   = "openCvdPreview",
        text = "Open CVD preview window",
        onclick = openCvdPreview,
    }
    d:newrow()

    d:separator{ text = "Diagnostics" }
    d:check{
        id       = "showDeltaE",
        label    = "Ramp ΔE bars",
        text     = "show under each ramp",
        selected = prefs.showDeltaE,
        onchange = function()
            prefs.showDeltaE = d.data.showDeltaE
            refreshAll()
        end,
    }
    d:newrow()

    d:separator{}
    d:button{
        id      = "reset",
        text    = "Reset to defaults",
        onclick = function()
            -- Reset everything except the saved-preset map (the user's
            -- collection of named configurations should survive Reset).
            local savedPresets = prefs.presets
            for k, v in pairs(ramp.DEFAULTS) do prefs[k] = v end
            prefs.presets = savedPresets
            syncSettingsWidgets(d)
            refreshAll()
        end,
    }
end

----------------------------------------------------------------------
-- Dialog construction & lifecycle
----------------------------------------------------------------------

local function openDialog()
    if dlg then
        dlg:show{ wait = false }
        return
    end

    dlg = Dialog{
        title   = "Smart Palette",
        onclose = function()
            if fgListenerKey then
                app.events:off(fgListenerKey)
                fgListenerKey = nil
            end
            dlg = nil
        end,
    }

    dlg:tab{ id = "tab_main",      text = "Main"      }
    buildMainTab(dlg)
    dlg:tab{ id = "tab_harmonies", text = "Harmonies" }
    buildHarmoniesTab(dlg)
    dlg:tab{ id = "tab_light",     text = "Light"     }
    buildLightTab(dlg)
    dlg:tab{ id = "tab_ramp",      text = "Ramp"      }
    buildRampTab(dlg)
    dlg:tab{ id = "tab_tools",     text = "Tools"     }
    buildToolsTab(dlg)
    dlg:endtabs()

    -- Repaint when the foreground color changes elsewhere in Aseprite, but
    -- only when not locked (locked panels show a frozen base).
    fgListenerKey = app.events:on("fgcolorchange", function()
        if dlg and not lockedBase then dlg:repaint() end
    end)

    dlg:show{ wait = false }
end

----------------------------------------------------------------------
-- Plugin entry
----------------------------------------------------------------------

function init(plugin)
    -- Migrate the legacy symmetric `shadingDesat` pref into the new
    -- highlight-desat slot before seeding new keys, so users who tuned
    -- the old slider keep their custom value.
    local p = plugin.preferences
    if p.shadingDesatHl == nil and p.shadingDesat ~= nil then
        p.shadingDesatHl = p.shadingDesat
    end
    -- Seed any missing preferences with their defaults.
    for k, v in pairs(ramp.DEFAULTS) do
        if plugin.preferences[k] == nil then
            plugin.preferences[k] = v
        end
    end
    prefs = plugin.preferences

    plugin:newCommand{
        id      = "SmartPalette",
        title   = "Smart Palette",
        onclick = openDialog,
    }
end

function exit(plugin)
    if dlg then dlg:close() end
end
