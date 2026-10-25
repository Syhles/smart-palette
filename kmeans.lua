-- K-means clustering in 3D space (OkLab) for the "harmonize active sprite"
-- feature. The clustering itself is generic — it operates on arrays of
-- 3-tuples and doesn't know about color. Sampling and color conversion
-- happen at the call site.

local M = {}

-- Run k-means on a list of samples (each {x, y, z}). Returns an array of
-- k centroids in the same coordinate space.
--
-- opts:
--   maxIter: hard cap on iterations (default 30)
--   tol:     stop when the largest centroid move is below this (default 1e-4)
function M.kmeans(samples, k, opts)
    opts = opts or {}
    local maxIter = opts.maxIter or 30
    local tol     = opts.tol or 1e-4
    local n = #samples
    if n == 0 then return {} end
    if k > n then k = n end
    if k <= 0 then return {} end

    -- Init: pick k samples evenly spaced through the input. Deterministic.
    local centroids = {}
    for i = 1, k do
        local idx = math.floor((i - 1) * n / k) + 1
        local s = samples[idx]
        centroids[i] = { s[1], s[2], s[3] }
    end

    for _ = 1, maxIter do
        -- Assignment + accumulation in one pass to avoid an O(n*k) extra loop.
        local sums   = {}
        local counts = {}
        for j = 1, k do sums[j] = {0, 0, 0}; counts[j] = 0 end

        for _, s in ipairs(samples) do
            local best, bestD = 1, math.huge
            for j = 1, k do
                local c = centroids[j]
                local d1 = s[1] - c[1]
                local d2 = s[2] - c[2]
                local d3 = s[3] - c[3]
                local d  = d1*d1 + d2*d2 + d3*d3
                if d < bestD then bestD = d; best = j end
            end
            sums[best][1] = sums[best][1] + s[1]
            sums[best][2] = sums[best][2] + s[2]
            sums[best][3] = sums[best][3] + s[3]
            counts[best] = counts[best] + 1
        end

        local maxMove = 0
        for j = 1, k do
            if counts[j] > 0 then
                local nx = sums[j][1] / counts[j]
                local ny = sums[j][2] / counts[j]
                local nz = sums[j][3] / counts[j]
                local ox, oy, oz = centroids[j][1], centroids[j][2], centroids[j][3]
                local dx, dy, dz = nx - ox, ny - oy, nz - oz
                local move = math.sqrt(dx*dx + dy*dy + dz*dz)
                if move > maxMove then maxMove = move end
                centroids[j] = { nx, ny, nz }
            end
        end
        if maxMove < tol then break end
    end

    return centroids
end

-- Sort centroids by lightness (first coordinate, ascending). Useful so the
-- output palette is ordered shadow → highlight.
function M.sortByL(centroids)
    table.sort(centroids, function(a, b) return a[1] < b[1] end)
    return centroids
end

return M
