-- Pure text generators for ramp / palette exports. The actual file writing
-- happens at the call site via io.open (desktop Aseprite supports writes
-- via standard io); these functions just produce strings.
--
-- `colors` is always an array of objects with .red/.green/.blue/.alpha
-- (Aseprite Color or the test stub).

local M = {}

local function hex(c)
    return string.format("%02x%02x%02x", c.red, c.green, c.blue)
end

----------------------------------------------------------------------
-- GIMP Palette (.gpl) — readable by GIMP, Krita, and Aseprite itself.
----------------------------------------------------------------------

function M.toGpl(colors, name)
    name = name or "Smart Palette"
    local lines = {
        "GIMP Palette",
        "Name: " .. name,
        "Columns: 0",
        "#",
    }
    for i, c in ipairs(colors) do
        table.insert(lines, string.format("%3d %3d %3d\t%s %d",
            c.red, c.green, c.blue, name, i))
    end
    return table.concat(lines, "\n") .. "\n"
end

----------------------------------------------------------------------
-- Plain hex list, one #rrggbb per line — easy to paste into anything.
----------------------------------------------------------------------

function M.toHexList(colors)
    local lines = {}
    for i, c in ipairs(colors) do
        lines[i] = "#" .. hex(c)
    end
    return table.concat(lines, "\n") .. "\n"
end

----------------------------------------------------------------------
-- CSS custom properties — drop the ramp into a stylesheet as :root vars.
----------------------------------------------------------------------

function M.toCss(colors, prefix)
    prefix = prefix or "ramp"
    local lines = { ":root {" }
    for i, c in ipairs(colors) do
        table.insert(lines, string.format("  --%s-%d: #%s;", prefix, i, hex(c)))
    end
    table.insert(lines, "}")
    return table.concat(lines, "\n") .. "\n"
end

----------------------------------------------------------------------
-- GIMP gradient (.ggr) — for cross-tool gradient reuse. One segment
-- between each consecutive pair of swatches, linear blending.
----------------------------------------------------------------------

function M.toGgr(colors, name)
    name = name or "Smart Palette"
    local n = #colors
    if n < 2 then
        -- A degenerate gradient is just one constant block.
        return string.format("GIMP Gradient\nName: %s\n0\n", name)
    end
    local segments = n - 1
    local lines = {
        "GIMP Gradient",
        "Name: " .. name,
        tostring(segments),
    }
    for i = 1, segments do
        local left  = (i - 1) / segments
        local right = i / segments
        local mid   = (left + right) / 2
        local cl, cr = colors[i], colors[i + 1]
        -- Format: left mid right L_R L_G L_B L_A R_R R_G R_B R_A blend coloring
        -- blend=0 (linear), coloring=0 (RGB)
        table.insert(lines, string.format(
            "%.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f 0 0",
            left, mid, right,
            cl.red/255, cl.green/255, cl.blue/255, (cl.alpha or 255)/255,
            cr.red/255, cr.green/255, cr.blue/255, (cr.alpha or 255)/255))
    end
    return table.concat(lines, "\n") .. "\n"
end

----------------------------------------------------------------------
-- Format registry
----------------------------------------------------------------------

M.FORMATS = {
    { key = "gpl",  label = "GIMP palette (.gpl)",   ext = "gpl",  fn = M.toGpl  },
    { key = "hex",  label = "Hex list (.txt)",       ext = "txt",  fn = M.toHexList },
    { key = "css",  label = "CSS variables (.css)",  ext = "css",  fn = M.toCss  },
    { key = "ggr",  label = "GIMP gradient (.ggr)",  ext = "ggr",  fn = M.toGgr  },
}

function M.byKey(key)
    for _, f in ipairs(M.FORMATS) do
        if f.key == key then return f end
    end
    return nil
end

return M
