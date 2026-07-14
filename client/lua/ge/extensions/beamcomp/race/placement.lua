-- BeamComp -- placement grounding (ground-cast, plus wall displacement for the recover assist).
--
-- Lives at lua/ge/extensions/beamcomp/race/placement.lua inside the client mod zip. Reload-safe (no
-- M.state, no file-scope engine handles) -- the only file-scope state is a one-shot probe flag whose
-- reset on a Lua reload is intended (it re-proves the reloaded zip; see probe_height_apis). Target: client
-- GE (LuaJIT 5.1). Unlike race/grid (pure pose math, engine-independent), THIS module is the engine
-- boundary: it reads world collision geometry, which only the client owns (ADR-0005), so it must never
-- move server-side.
--
-- Why it exists (ADR-0034): grid.poses lays the field out flat at the start-line Z, and the recover
-- assist teleports to a checkpoint's authored centre Z. Neither samples the real surface below the pose,
-- so on undulating tracks rear-row cars bury / float and a recover drops into the ground. This module
-- drops a pose onto the surface (a downward ray) before anything is placed on it.
--
-- Division of labor (ADR-0034 amendment 2026-07-14): the GRID spawn path (start.prepare -> ground_all)
-- grounds HEIGHT-ONLY -- no wall displacement -- so cars spawn at exactly the authored X/Y the editor
-- preview shows. The wall test misfired on steep slopes (its horizontal ray hits the rising ground
-- itself and shoved a slot down-track, in the observed case onto the staged-quali ramp). Only the
-- RECOVER assist (init.recover_target -> resolve) keeps the full ground + wall-nudge pass: a
-- checkpoint's authored centre can genuinely sit inside geometry, a grid slot is ground an admin chose.
--
-- Degrade-don't-crash (like ADR-0017's engine wrappers): every engine read is pcall/type-guarded, and a
-- missing/unhappy cast API leaves the pose UNCHANGED -- never worse than the pre-ADR-0034 behaviour. The
-- degrade is silent (no per-pose log spam: this runs once per grid slot); only the rare wall give-up logs.
--
-- ENGINE-API NOTE: castRayStatic(origin, dir, maxDist) -> distance-to-nearest-static-hit and
-- core_terrain.getTerrainHeight(vec3) are used against BeamNG 0.38.5 and are UNVERIFIED under BeamMP
-- here -- confirm the signature/return in-game (a miss is assumed to return >= maxDist).

local M = {}

local LOG_TAG = "beamcomp.spawn"

-- Vertical cast bounds. The ray starts UP_MARGIN above the pose's own Z so it begins ABOVE the surface
-- even when the authored Z is slightly underground (a checkpoint centre), then drops up to MAX_DROP.
-- GROUND_CLEARANCE lifts the car a hair off the surface so it settles rather than clips.
local UP_MARGIN = 10.0
local MAX_DROP = 200.0
local GROUND_CLEARANCE = 0.2

-- Nominal car footprint for the horizontal wall test (no real vehicle exists when a grid is computed or
-- previewed). Half-length/half-width of a typical car plus a clearance margin; the rays fire from
-- WALL_RAY_HEIGHT above the grounded Z (roughly axle height) so they meet a wall, not the ground.
local HALF_LENGTH = 2.5
local HALF_WIDTH = 1.1
local WALL_MARGIN = 0.5
local WALL_RAY_HEIGHT = 0.5

-- Wall displacement (recover assist only): step the pose this far along +forward per try, up to this
-- many tries, re-grounding each step.
local NUDGE_STEP = 1.0
local MAX_NUDGES = 8

-- Cast start lifts (metres above the hint) for probe_ground_z's wide editor window: each cast covers
-- [lift + UP_MARGIN - MAX_DROP, lift + UP_MARGIN] around the hint, so together they search contiguously
-- from MAX_DROP below up to ~200 m ABOVE the chain z (the grid-split seed's motivating case), trying
-- the window nearest the hint first.
local PROBE_HINT_LIFTS = {0, 40, 90, 190}

local EPSILON = 1e-6


-- A {x, y, z} vector flattened to the horizontal plane and unit-normalized, or nil when it has no
-- horizontal component (a straight up/down vector gives no usable direction).
local function horizontal_unit(v)
    if type(v) ~= "table" then
        return nil
    end
    local len = math.sqrt(v.x * v.x + v.y * v.y)
    if len < EPSILON then
        return nil
    end
    return {x = v.x / len, y = v.y / len, z = 0}
end

-- Downward ray to the nearest static surface (terrain AND static meshes/roads) below (x, y), or nil. The
-- ray starts UP_MARGIN above `hint_z` and a miss is taken as dist >= MAX_DROP (see ENGINE-API NOTE).
local function cast_ground_z(x, y, hint_z)
    if type(castRayStatic) ~= "function" or type(vec3) ~= "function" then
        return nil
    end
    local start_z = (hint_z or 0) + UP_MARGIN
    local ok, dist = pcall(castRayStatic, vec3(x, y, start_z), vec3(0, 0, -1), MAX_DROP)
    if ok and type(dist) == "number" and dist >= 0 and dist < MAX_DROP then
        return start_z - dist
    end
    return nil
end

-- Terrain-height fallback for when castRayStatic is unavailable -- terrain only (misses meshes/roads on
-- stilts), but better than the flat authored Z. Returns the height or nil.
local function terrain_ground_z(x, y)
    if type(core_terrain) ~= "table" or type(core_terrain.getTerrainHeight) ~= "function"
            or type(vec3) ~= "function" then
        return nil
    end
    local ok, height = pcall(core_terrain.getTerrainHeight, vec3(x, y, 0))
    if ok and type(height) == "number" then
        return height
    end
    return nil
end

-- True when a static obstacle sits within the car footprint around (x, y, z) facing `forward` (a
-- horizontal unit vector). Fires four short rays from ~axle height along +/-forward and +/-right; a hit
-- closer than the footprint reach means the pose is inside/against geometry. False (not blocked) when
-- there is no forward axis or the cast API is missing -- the ground drop already happened either way.
local function is_blocked(x, y, z, forward)
    if not forward or type(castRayStatic) ~= "function" or type(vec3) ~= "function" then
        return false
    end
    local right = {x = forward.y, y = -forward.x}
    local origin = vec3(x, y, z + WALL_RAY_HEIGHT)
    local longitudinal = HALF_LENGTH + WALL_MARGIN
    local lateral = HALF_WIDTH + WALL_MARGIN

    local function hits(dir_x, dir_y, reach)
        local ok, dist = pcall(castRayStatic, origin, vec3(dir_x, dir_y, 0), reach)
        return ok and type(dist) == "number" and dist >= 0 and dist < reach
    end

    return hits(forward.x, forward.y, longitudinal)
        or hits(-forward.x, -forward.y, longitudinal)
        or hits(right.x, right.y, lateral)
        or hits(-right.x, -right.y, lateral)
end


-- One-shot BeamMP height-API verification probe. placement.lua does the codebase's ONLY ground casts
-- (ADR-0034), and castRayStatic / core_terrain.getTerrainHeight are UNVERIFIED under BeamMP -- a miss
-- degrades silently to nil (flat). Fired once, this reports whether each API answered with a real value
-- in-game vs degraded, so a handover can confirm the grounding is actually live AND that the fresh client
-- zip (not a stale cache) is the one running. Re-runs the two reads for the queried point rather than
-- reusing ground_z's short-circuited result, so both APIs are reported independently. pcall-guarded so a
-- bad read never breaks the grounding it precedes; one line per load, no per-pose spam.
local probe_fired = false

local function probe_height_apis(x, y, hint_z)
    if probe_fired then
        return
    end
    probe_fired = true
    pcall(function()
        local cast_z = cast_ground_z(x, y, hint_z)
        local terrain_z = terrain_ground_z(x, y)
        log("I", LOG_TAG, string.format(
            "placement height-API probe (BeamMP verify, ADR-0034): castRayStatic=%s, "
            .. "core_terrain.getTerrainHeight=%s",
            cast_z and string.format("%.2f", cast_z) or "nil (degraded)",
            terrain_z and string.format("%.2f", terrain_z) or "nil (degraded)"))
    end)
end

-- The surface Z below (x, y): a downward static-geometry cast, falling back to terrain height, or nil
-- when neither API answers. `hint_z` seeds the ray's start height (see cast_ground_z).
function M.ground_z(x, y, hint_z)
    probe_height_apis(x, y, hint_z)
    local z = cast_ground_z(x, y, hint_z)
    if z then
        return z
    end
    return terrain_ground_z(x, y)
end

-- Wide-window surface probe for the EDITOR's grid-split height seed (ADR-0023 amendment). Unlike
-- ground_z -- whose fixed UP_MARGIN window is a spawn-side contract (the cast must start UNDER a tunnel
-- ceiling, ADR-0034) -- this also searches far ABOVE the hint, for the exact case the seed exists for:
-- terrain that climbed more than UP_MARGIN over the chain z, where the normal cast starts inside the
-- hill and misses. Casts at escalating start heights (nearest window first, so a surface close to the
-- hint wins over a high overpass), then falls back to terrain height (z-independent), refined by one
-- more cast seeded there (catches a road deck just above the terrain). Returns the surface z, or nil
-- when no API answers (the caller degrades to a 0 seed). Editor-only; the spawn path never calls this.
function M.probe_ground_z(x, y, hint_z)
    local base = hint_z or 0
    for _, lift in ipairs(PROBE_HINT_LIFTS) do
        local z = cast_ground_z(x, y, base + lift)
        if z then
            return z
        end
    end
    local terrain = terrain_ground_z(x, y)
    if not terrain then
        return nil
    end
    return cast_ground_z(x, y, terrain) or terrain
end

-- A copy of `pose` dropped onto the surface: z = ground + GROUND_CLEARANCE, or the original z when no
-- surface is found (degrade-don't-crash). Never mutates the input: grid.poses shares one read-only
-- `forward` table across slots and reuses `rot`, so those pass through by reference while a NEW pos
-- table is built.
function M.ground_pose(pose)
    local pos = pose.pos
    local ground = M.ground_z(pos.x, pos.y, pos.z)
    local z = ground and (ground + GROUND_CLEARANCE) or pos.z
    return {
        pos = {x = pos.x, y = pos.y, z = z},
        rot = pose.rot,
        forward = pose.forward,
    }
end

-- Ground a list of poses HEIGHT-ONLY, in place-order -- the grid spawn pass (ADR-0034 amendment): each
-- pose drops to the surface with NO wall displacement, so the spawned field keeps the authored X/Y of
-- every slot, exactly what the editor preview shows. Entries that are not {pos = {...}} tables pass
-- through unchanged (defensive at the call boundary, like resolve). Returns a new list; the input list
-- and its pose tables are not mutated.
function M.ground_all(poses)
    if type(poses) ~= "table" then
        return poses
    end
    local grounded = {}
    for index = 1, #poses do
        local pose = poses[index]
        if type(pose) == "table" and type(pose.pos) == "table" then
            grounded[index] = M.ground_pose(pose)
        else
            grounded[index] = pose
        end
    end
    return grounded
end

-- A copy of `pose` grounded and, if it sits in a wall, nudged along +forward (down-track) until clear --
-- re-grounding each step, up to MAX_NUDGES. Gives up gracefully (logged) on the last position rather
-- than looping forever. Recover-only since the grid spawn went height-only (ADR-0034 amendment): a
-- checkpoint's authored centre can sit inside geometry, so the nudge earns its keep there. `forward` is
-- read from pose.forward (the recover seam passes the facing dir as `forward`).
function M.clear_pose(pose)
    local grounded = M.ground_pose(pose)
    local forward = horizontal_unit(pose.forward)
    if not forward then
        return grounded
    end

    local pos = grounded.pos
    if not is_blocked(pos.x, pos.y, pos.z, forward) then
        return grounded
    end

    local x, y, z = pos.x, pos.y, pos.z
    for _ = 1, MAX_NUDGES do
        x = x + forward.x * NUDGE_STEP
        y = y + forward.y * NUDGE_STEP
        local ground = M.ground_z(x, y, z)
        z = ground and (ground + GROUND_CLEARANCE) or z
        if not is_blocked(x, y, z, forward) then
            return {pos = {x = x, y = y, z = z}, rot = pose.rot, forward = pose.forward}
        end
    end

    log("W", LOG_TAG, "placement: could not nudge the recover target clear of geometry -- "
        .. "using the last tried position")
    return {pos = {x = x, y = y, z = z}, rot = pose.rot, forward = pose.forward}
end

-- Resolve a single pose to its final spawnable form: grounded, then cleared of walls (the recover-assist
-- pass; the grid spawn uses ground_all instead). Returns the input unchanged when it is not a
-- {pos = {...}} table (defensive at the call boundary). clear_pose grounds internally, so there is no
-- double cast.
function M.resolve(pose)
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return pose
    end
    return M.clear_pose(pose)
end

-- Resolve a list of poses in place-order through the full ground + wall-nudge pass. The grid spawn no
-- longer uses this (it grounds height-only via ground_all, ADR-0034 amendment); kept as the list form
-- of resolve for recover-style placement. Returns a new list; the input list and its pose tables are
-- not mutated.
function M.resolve_all(poses)
    if type(poses) ~= "table" then
        return poses
    end
    local resolved = {}
    for index = 1, #poses do
        resolved[index] = M.resolve(poses[index])
    end
    return resolved
end

return M
