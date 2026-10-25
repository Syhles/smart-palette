-- Named ramp presets. Each preset captures every value in ramp.DEFAULTS
-- (color space, light preset, primitive, ramp tunables, ...) so loading
-- one fully restores a configuration the user liked.
--
-- Stored in plugin.preferences as a JSON string (single key) rather than
-- a nested Lua table, because nested-table support in plugin.preferences
-- is undocumented and we'd rather not bet the user's data on it.

local ramp = require("ramp")

local M = {}

-- Reference to the json codec. Aseprite exposes one as a global; tests
-- inject a stub via M.setJson(). Don't capture at load time — the global
-- isn't necessarily defined when this module is required.
local function jsonCodec()
    return _G.json or M._json
end

function M.setJson(codec)
    M._json = codec
end

-- Aseprite's json.decode returns a `userdata` proxy. It indexes and iterates
-- like a table but isn't writable. Quirk: for JSON *arrays* the userdata's
-- `pairs` is empty — only `ipairs` walks them. For JSON *objects* it's the
-- opposite: `pairs` works, `ipairs` is empty. We run both loops to handle
-- either shape.
local function normalize(v)
    if type(v) == "userdata" or type(v) == "table" then
        local out = {}
        for i, vv in ipairs(v) do out[i] = normalize(vv) end
        for k, vv in pairs(v) do
            if out[k] == nil then out[k] = normalize(vv) end
        end
        return out
    end
    return v
end

----------------------------------------------------------------------
-- Serialization helpers
----------------------------------------------------------------------

-- Serialize a flat prefs table to a JSON string. Keys not in ramp.DEFAULTS
-- are dropped (we don't want stale or unknown keys polluting saved presets).
function M.encodeOne(prefsTbl)
    local pruned = {}
    for k, _ in pairs(ramp.DEFAULTS) do
        if prefsTbl[k] ~= nil then pruned[k] = prefsTbl[k] end
    end
    return jsonCodec().encode(pruned)
end

function M.decodeOne(s)
    if type(s) ~= "string" or s == "" then return {} end
    local ok, t = pcall(jsonCodec().decode, s)
    if not ok or (type(t) ~= "table" and type(t) ~= "userdata") then
        return {}
    end
    return normalize(t)
end

-- Encode the whole preset map (name -> preset table) to a single JSON
-- string suitable for storing in plugin.preferences.presets.
function M.encodeAll(presets)
    return jsonCodec().encode(presets or {})
end

function M.decodeAll(s)
    if type(s) ~= "string" or s == "" then return {} end
    local ok, t = pcall(jsonCodec().decode, s)
    if not ok or (type(t) ~= "table" and type(t) ~= "userdata") then
        return {}
    end
    return normalize(t)
end

----------------------------------------------------------------------
-- High-level operations on the preset map
----------------------------------------------------------------------

function M.list(presetMap)
    local names = {}
    for name in pairs(presetMap or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function M.save(presetMap, name, prefsTbl)
    if not name or name == "" then return presetMap end
    presetMap[name] = {}
    for k, _ in pairs(ramp.DEFAULTS) do
        if prefsTbl[k] ~= nil then presetMap[name][k] = prefsTbl[k] end
    end
    return presetMap
end

function M.delete(presetMap, name)
    presetMap[name] = nil
    return presetMap
end

-- Apply a preset onto a live prefs table. Only keys that exist in the
-- preset are touched; missing keys keep their current values (so a preset
-- saved against an older schema doesn't reset newly-added prefs).
function M.apply(prefsTbl, preset)
    if not preset then return prefsTbl end
    for k, v in pairs(preset) do
        if ramp.DEFAULTS[k] ~= nil then
            prefsTbl[k] = v
        end
    end
    return prefsTbl
end

return M
