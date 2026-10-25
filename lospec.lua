-- Lospec palette import. The pure parts (slugify, URL builder, JSON
-- parser, hex parser) are isolated so they can be unit-tested without
-- network access. The fetch itself shells out to curl via os.execute,
-- which Aseprite gates behind a one-time permissions prompt.
--
-- Lospec endpoint: https://lospec.com/palette-list/<slug>.json
-- Response shape: { "name", "author", "colors": ["be4a2f", "d77643", ...] }

local M = {}

----------------------------------------------------------------------
-- Pure helpers
----------------------------------------------------------------------

local function jsonCodec()
    return _G.json or M._json
end

function M.setJson(codec)
    M._json = codec
end

-- Convert "Endesga 32" → "endesga-32", trimming and folding whitespace,
-- stripping anything that's not a letter, digit, or hyphen.
function M.slugify(name)
    if type(name) ~= "string" then return "" end
    local s = name:lower()
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s+", "-")
    s = s:gsub("[^%a%d%-]", "")
    -- Collapse runs of hyphens and trim leading/trailing.
    s = s:gsub("%-+", "-")
    s = s:gsub("^%-", ""):gsub("%-$", "")
    return s
end

function M.urlFor(slug)
    return "https://lospec.com/palette-list/" .. slug .. ".json"
end

-- Parse a 6-digit hex color (with optional leading #) to (r, g, b) bytes.
-- Returns nil on malformed input.
function M.hexToRgb(hex)
    if type(hex) ~= "string" then return nil end
    if hex:sub(1, 1) == "#" then hex = hex:sub(2) end
    if #hex ~= 6 then return nil end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if not (r and g and b) then return nil end
    return r, g, b
end

-- Parse a Lospec JSON response. Returns (colors, name) on success,
-- (nil, error) on failure. `colors` is an array of hex strings.
function M.parsePalette(body)
    if type(body) ~= "string" or body == "" then
        return nil, "empty response"
    end
    local codec = jsonCodec()
    if not codec then return nil, "no JSON codec available" end
    local ok, parsed = pcall(codec.decode, body)
    if not ok or (type(parsed) ~= "table" and type(parsed) ~= "userdata") then
        return nil, "malformed JSON"
    end
    local colors = parsed.colors
    if not colors then return nil, "no 'colors' field in response" end
    -- Normalize from userdata → table for predictable iteration.
    local out = {}
    local i = 1
    while colors[i] do
        out[i] = colors[i]
        i = i + 1
    end
    if #out == 0 then return nil, "palette has no colors" end
    return out, parsed.name
end

----------------------------------------------------------------------
-- Impure: fetch + import. Pulls all I/O dependencies in via `deps`.
----------------------------------------------------------------------

-- Default deps for production use. Tests inject their own.
local function defaultDeps()
    local tmpdir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
    local sep = package.config:sub(1, 1)
    return {
        execute = os.execute,
        readFile = function(path)
            local f = io.open(path, "r")
            if not f then return nil end
            local body = f:read("*a")
            f:close()
            return body
        end,
        removeFile = os.remove,
        tmpPath = tmpdir .. sep .. "smart-palette-lospec.json",
    }
end

-- Fetch a Lospec palette JSON. Returns (body, name) on success or (nil, err).
-- `deps` is optional — if omitted, real OS facilities are used.
function M.fetch(slug, deps)
    deps = deps or defaultDeps()
    local url = M.urlFor(slug)
    local cmd = string.format('curl -sf "%s" -o "%s"', url, deps.tmpPath)
    local ok, _, code = deps.execute(cmd)
    -- Lua 5.3 os.execute: true on success, nil/false on failure.
    -- Some builds return just an integer (5.1 style) — accept both.
    local success = (ok == true) or (ok == 0) or (ok == nil and code == 0)
    if not success then
        return nil, "curl failed (exit " .. tostring(code or "?") ..
                    "). Make sure curl is on PATH and the palette exists."
    end
    local body = deps.readFile(deps.tmpPath)
    deps.removeFile(deps.tmpPath)
    if not body or body == "" then
        return nil, "empty response (palette not found?)"
    end
    return body
end

return M
