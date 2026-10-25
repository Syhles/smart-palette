-- Lit-primitive normal+luminance generators. Each generator returns a grid
-- of luminance values [0,1] for a `size`x`size` canvas, with `nil` for
-- pixels outside the silhouette. Light direction is hardcoded here for
-- now (Phase 3 multi-light feature will parameterize this).
--
-- Pure math — no Aseprite dependency.

local M = {}

local AMBIENT = 0.15  -- floor so the shadow side never reads as pure black
local DIFFUSE = 0.85  -- 1 - AMBIENT

-- Named light directions (canvas coords: -y is up, +z toward camera).
M.LIGHT_DIRS = {
    ["upper-left"]   = { -0.4, -0.6,  0.7 },
    ["upper-right"]  = {  0.4, -0.6,  0.7 },
    ["lower-left"]   = { -0.4,  0.5,  0.7 },
    ["rim-back"]     = {    0,  0.3, -0.9 },
    ["top-down"]     = {    0,   -1,  0.1 },
}
M.LIGHT_DIR_KEYS  = { "upper-left", "upper-right", "lower-left", "rim-back", "top-down" }
M.LIGHT_DIR_LABEL = {
    ["upper-left"]  = "Upper-left",
    ["upper-right"] = "Upper-right",
    ["lower-left"]  = "Lower-left",
    ["rim-back"]    = "Rim (back)",
    ["top-down"]    = "Top-down",
}

local function normalizeDir(d)
    local len = math.sqrt(d[1]*d[1] + d[2]*d[2] + d[3]*d[3])
    if len == 0 then return 0, 0, 1 end
    return d[1]/len, d[2]/len, d[3]/len
end

-- Default lights = the single upper-left light, intensity 1.0. Used when
-- the caller doesn't pass a lights array (back-compat with the original
-- single-light sphere preview).
local DEFAULT_LIGHTS = { { dir = M.LIGHT_DIRS["upper-left"], intensity = 1.0 } }

-- Sum diffuse contributions from N lights, plus ambient floor, clamped to [0, 1].
local function shade(nx, ny, nz, lights)
    if not lights or #lights == 0 then lights = DEFAULT_LIGHTS end
    local sum = AMBIENT
    for _, l in ipairs(lights) do
        local lx, ly, lz = normalizeDir(l.dir or DEFAULT_LIGHTS[1].dir)
        local d = math.max(0, nx*lx + ny*ly + nz*lz)
        sum = sum + d * DIFFUSE * (l.intensity or 1.0)
    end
    if sum < 0 then sum = 0 end
    if sum > 1 then sum = 1 end
    return sum
end

M._shade = shade  -- exposed for tests

----------------------------------------------------------------------
-- Sphere — unchanged from the original sphere.lua implementation.
----------------------------------------------------------------------

function M.sphere(size, lights)
    local r = size / 2
    local map = {}
    for y = 0, size - 1 do
        map[y] = {}
        for x = 0, size - 1 do
            local nx = (x - r + 0.5) / r
            local ny = (y - r + 0.5) / r
            local d2 = nx*nx + ny*ny
            if d2 <= 1 then
                local nz = math.sqrt(1 - d2)
                map[y][x] = shade(nx, ny, nz, lights)
            end
        end
    end
    return map
end

----------------------------------------------------------------------
-- Cube — isometric, three faces visible (top + lower-left + lower-right).
-- Face normals are constant within each face, so each shows up as a flat
-- band of luminance — useful for testing how the ramp handles hard edges
-- between distinct values.
----------------------------------------------------------------------

local function inParallelogram(px, py, ax, ay, ux, uy, vx, vy)
    -- Solve (px-ax, py-ay) = a*(ux,uy) + b*(vx,vy). Returns a, b.
    local det = ux*vy - uy*vx
    if det == 0 then return nil end
    local a = ((px - ax) * vy - (py - ay) * vx) / det
    local b = ((py - ay) * ux - (px - ax) * uy) / det
    if a >= 0 and a <= 1 and b >= 0 and b <= 1 then return a, b end
    return nil
end

function M.cube(size, lights)
    local cx, cy = size / 2, size / 2
    local s = size / 3   -- half of cube edge in screen pixels (so cube fits comfortably)

    -- Vertices (canvas coords) for the visible iso silhouette:
    local TopA = { cx,     cy - s   } -- top vertex
    local TopB = { cx + s, cy - s/2 } -- right vertex
    local Mid  = { cx,     cy       } -- center vertex (front-top corner)
    local TopD = { cx - s, cy - s/2 } -- left vertex
    local BotL = { cx - s, cy + s/2 }
    local Bot  = { cx,     cy + s   }
    local BotR = { cx + s, cy + s/2 }

    -- Each face stored as { Acorner, Ucorner-Acorner, Vcorner-Acorner, normal }.
    local faces = {
        -- Top: A=TopD, U=TopA-TopD, V=Mid-TopD. Normal (0, -1, 0).
        {
            ax = TopD[1], ay = TopD[2],
            ux = TopA[1] - TopD[1], uy = TopA[2] - TopD[2],
            vx = Mid[1]  - TopD[1], vy = Mid[2]  - TopD[2],
            nx = 0, ny = -1, nz = 0,
        },
        -- Lower-left: A=TopD, U=Mid-TopD, V=BotL-TopD. Normal (0, 0, 1) (front-facing).
        {
            ax = TopD[1], ay = TopD[2],
            ux = Mid[1]  - TopD[1], uy = Mid[2]  - TopD[2],
            vx = BotL[1] - TopD[1], vy = BotL[2] - TopD[2],
            nx = 0, ny = 0, nz = 1,
        },
        -- Lower-right: A=Mid, U=TopB-Mid, V=Bot-Mid. Normal (1, 0, 0) (world-right).
        {
            ax = Mid[1], ay = Mid[2],
            ux = TopB[1] - Mid[1], uy = TopB[2] - Mid[2],
            vx = Bot[1]  - Mid[1], vy = Bot[2]  - Mid[2],
            nx = 1, ny = 0, nz = 0,
        },
    }

    local map = {}
    for y = 0, size - 1 do
        map[y] = {}
        for x = 0, size - 1 do
            for _, f in ipairs(faces) do
                local a = inParallelogram(x + 0.5, y + 0.5,
                    f.ax, f.ay, f.ux, f.uy, f.vx, f.vy)
                if a ~= nil then
                    map[y][x] = shade(f.nx, f.ny, f.nz, lights)
                    break
                end
            end
        end
    end
    return map
end

----------------------------------------------------------------------
-- Cylinder — vertical, no end caps. Side surface curves around the y-axis;
-- shading is constant along y, varies in x with the cosine of the angle.
-- Useful for testing the ramp on tube-like shapes (limbs, tree trunks).
----------------------------------------------------------------------

function M.cylinder(size, lights)
    local cx     = size / 2
    local r      = math.floor(size * 0.34)              -- horizontal radius
    local top    = math.floor(size * 0.10)
    local bottom = math.floor(size * 0.90) - 1

    local map = {}
    for y = 0, size - 1 do
        map[y] = {}
        if y >= top and y <= bottom then
            for x = 0, size - 1 do
                local nx = (x - cx + 0.5) / r
                if nx >= -1 and nx <= 1 then
                    local nz = math.sqrt(1 - nx*nx)
                    map[y][x] = shade(nx, 0, nz, lights)
                end
            end
        end
    end
    return map
end

----------------------------------------------------------------------
-- Hemisphere — top dome of a sphere (lower half is empty). Tests the ramp
-- on rounded objects without a full silhouette circle (helmets, hills).
----------------------------------------------------------------------

function M.hemisphere(size, lights)
    local cx, cy = size / 2, size * 0.62  -- center sits below midline so the dome reads as a hill
    local r      = size * 0.46

    local map = {}
    for y = 0, size - 1 do
        map[y] = {}
        if y < cy then
            for x = 0, size - 1 do
                local nx = (x - cx + 0.5) / r
                local ny = (y - cy + 0.5) / r
                local d2 = nx*nx + ny*ny
                if d2 <= 1 then
                    local nz = math.sqrt(1 - d2)
                    map[y][x] = shade(nx, ny, nz, lights)
                end
            end
        end
    end
    return map
end

----------------------------------------------------------------------
-- Registry
----------------------------------------------------------------------

M.GENERATORS = {
    sphere     = M.sphere,
    cube       = M.cube,
    cylinder   = M.cylinder,
    hemisphere = M.hemisphere,
}

M.KEYS  = { "sphere", "cube", "cylinder", "hemisphere" }
M.LABEL = {
    sphere     = "Sphere",
    cube       = "Cube",
    cylinder   = "Cylinder",
    hemisphere = "Hemisphere",
}

-- Build the luminance map for the named primitive. Falls back to sphere
-- if the name is unknown (e.g. stale prefs from an older version).
function M.build(name, size, lights)
    local fn = M.GENERATORS[name] or M.GENERATORS.sphere
    return fn(size, lights)
end

return M
