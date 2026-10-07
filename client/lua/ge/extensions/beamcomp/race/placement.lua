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
-- It also measures the surface's SLOPE (ADR-0034 amendment 2026-08-30): four more casts, at the corners
-- of a nominal car footprint, span the plane the car will stand on, and that plane's normal rides along
-- on the pose as `up`. race/vehicles.lua turns it into the spawn orientation, the front anchor and (since
-- the 2026-09-01 recover-follows-surface-slope amendment) the recover orientation -- and since 2026-10-07
-- the recover's box anchor too -- and the grid editor draws it. Without a normal every consumer keeps its
-- pre-slope, world-up behaviour.
--
-- WHERE that footprint sits depends on what the pose means, and the two paths here disagree: a GRID pose
-- is the car's front edge, so the footprint is set back half a car to land under the body; a RECOVER
-- target is the car's middle, so it is not set back at all. Every caller of the measurement states its
-- convention -- see NORMAL_SET_BACK.
--
-- Division of labor (ADR-0034 amendment 2026-07-14): the GRID spawn path (start.prepare -> ground_all)
-- grounds HEIGHT-ONLY -- no wall displacement -- so cars spawn at exactly the authored X/Y the editor
-- preview shows. The wall test misfired on steep slopes (its horizontal ray hits the rising ground
-- itself and shoved a slot down-track, in the observed case onto the staged-quali ramp). Only the
-- RECOVER assist (init.recover_target -> resolve) keeps the full ground + wall-nudge pass: a
-- checkpoint's authored centre can genuinely sit inside geometry, a grid slot is ground an admin chose.
--
-- The grid pass is a CHAIN (ADR-0034 amendment 2026-09-01): ground_all walks the slots in order and each
-- one starts its search at the surface the slot BEFORE it found, not at its own authored z. The search
-- window therefore travels with the terrain and can be small (CHAIN_UP_MARGIN, 3 m) instead of the fixed
-- 10 m a per-slot search needed -- small enough that a bridge deck overhead is no longer the first thing
-- a ray meets, and still enough to climb a hill. The recover assist's CENTRE drop keeps the wide window:
-- it has no chain to inherit from. Its four SLOPE casts do not (ADR-0034 amendment 2026-10-07,
-- recover-anchors-the-box): they start from a surface already measured, exactly like the grid's, and take
-- the same narrow window -- see SLOPE_UP_MARGIN.
--
-- Degrade-don't-crash (like ADR-0017's engine wrappers): every engine read is pcall/type-guarded, and a
-- missing/unhappy cast API leaves the pose UNCHANGED -- never worse than the pre-ADR-0034 behaviour. The
-- degrade is silent (no per-pose log spam: this runs once per grid slot); only the rare wall give-up logs.
--
-- ENGINE-API NOTE: castRayStatic(origin, dir, maxDist) -> distance-to-nearest-static-hit and
-- core_terrain.getTerrainHeight(vec3) are used against BeamNG 0.38.5 and are UNVERIFIED under BeamMP
-- here -- confirm the signature/return in-game (a miss is assumed to return >= maxDist). The slope
-- measurement adds no new engine API: it is the same castRayStatic, four more times.

local M = {}

local LOG_TAG = "beamcomp.spawn"

-- Vertical cast bounds. The ray starts UP_MARGIN above the hint height so it begins ABOVE the surface
-- even when the hint is slightly underground (a checkpoint centre), then drops up to MAX_DROP.
-- GROUND_CLEARANCE lifts the car a hair off the surface so it settles rather than clips.
--
-- UP_MARGIN is the RECOVER assist's window for its CENTRE drop: its hint is a checkpoint's authored
-- centre, a single point with nothing before it to inherit from, so it keeps the wide 10 m it has always
-- had. Its slope corners do NOT use it (see SLOPE_UP_MARGIN).
local UP_MARGIN = 10.0
local MAX_DROP = 200.0
local GROUND_CLEARANCE = 0.2

-- The GRID chain's window (ADR-0034 amendment 2026-09-01): metres above the height the PREVIOUS slot
-- found. 3 m, because that is what the chain makes sufficient -- a slot only has to see over the rise
-- since its neighbour, and 3 m between two grid positions is already a very steep hill. Small on
-- purpose: the 10 m a per-slot search needed is exactly what made a ray under a bridge meet the deck
-- above it first and spawn the field on the bridge. A segment whose FIRST slot genuinely starts far
-- below its ground has the per-segment castHeight knob to lift its own window.
local CHAIN_UP_MARGIN = 3.0

-- The window of the four SLOPE corner casts, for the grid AND the recover assist alike (ADR-0034
-- amendment 2026-10-07, recover-anchors-the-box): metres above the surface already found under the pose.
--
-- The corners are seeded at a height that was just MEASURED, so the window does not have to find the
-- ground -- it only has to see over the rise across half a footprint. What a wider window adds is
-- STRUCTURE: everything static between the road and the top of the window counts as the ground under
-- that wheel. The recover used to take UP_MARGIN (10 m) here, so an arch, a banner, a sign gantry, a
-- bridge deck or a canopy 3..10 m above ONE corner was sampled as the road there -- a strong roll (and
-- pitch) on perfectly flat ground. The grid had already been cured of exactly that ("the bridge defect
-- one level down", amendment 2026-09-01); the recover never got the same cure.
--
-- Derived from the chain window rather than restated, so the grid's in-game-verified slope is measured
-- with the same number as before and the two windows can never drift apart. What it cannot do: an object
-- LOWER than 3 m above a corner -- a barrier, a kerb stone, a parked prop -- is still sampled, because
-- inside the window it is indistinguishable from a step in the road. The log line vehicles.recover_to
-- writes names the four corner heights so such a case shows as a number.
local SLOPE_UP_MARGIN = CHAIN_UP_MARGIN

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

-- Half the footprint the ground NORMAL is sampled over (ADR-0034 amendment 2026-08-30): a nominal car's
-- wheelbase (~2.7 m) and track (~1.6 m), halved. The four corners are where a car's wheels would touch,
-- so the plane through them is the plane the car ends up in.
--
-- Deliberately a fixed nominal car and NOT the real vehicle's box, even though vehiclespecs.config_anchor
-- publishes one: every client computes the pose of EVERY slot before it knows who drives what
-- (race/start.layout_for), and the grid editor previews the same poses with no cars in the world at all.
-- A size-dependent footprint would give two clients two different normals for one slot and would break
-- ADR-0023's preview-matches-spawn invariant.
local NORMAL_HALF_LENGTH = 1.35
local NORMAL_HALF_WIDTH = 0.8

-- How far BEHIND the pose that footprint's centre sits. There are TWO answers, because this module
-- grounds two kinds of pose (ADR-0034 amendment 2026-09-01, recover-follows-surface-slope):
--
--   a GRID pose is the car's FRONT EDGE   -- race/vehicles.lua places the reference point so the front
--                                            centre lands exactly on it -> set the footprint back by
--                                            half a nominal car (NORMAL_SET_BACK).
--   a RECOVER target is the car's MIDDLE  -- a checkpoint's authored centre, and vehicles.recover_to
--                                            puts the car's BOX CENTRE there (its bottom face on the
--                                            surface) -> no set-back at all.
--
-- Which of the two a pose follows is stated at every call site and never defaulted: a forgotten caller
-- must fail loudly rather than quietly measure the grid 2.2 m off (see cast_normal_samples). The vehicle
-- side mirrors this split one-to-one: vehicles.lua's ANCHOR_FRONT / ANCHOR_MIDDLE say which point of the
-- car's box lands on the pose, so the footprint measured here and the box placed there are the same car.
--
-- The grid's set-back (ADR-0034 amendment 2026-09-01, slope-samples-on-the-car): a footprint centred ON
-- a front-edge pose sampled 1.35 m of ground IN FRONT OF the bumper and only the first 1.35 m of the
-- ~4.4 m the car actually covers, so on a crest or a slope edge the measured tilt came mostly from
-- ground the car never touches. Set back by half a nominal car, the four samples span 0.85 m .. 3.55 m
-- behind the front edge: entirely under the car, in the stretch between its axles.
--
-- Written as the wall test's HALF_LENGTH minus the clearance margin baked into it (0.3 m) so both
-- nominal measurements describe ONE car and cannot drift apart: 2.2 m of half-length, i.e. a 4.4 m car,
-- the size class of BeamNG's default vehicles. A fixed nominal for the same determinism reason as the
-- footprint itself (above): it must not depend on who ends up driving the slot.
--
-- Only the centre moves. The footprint is deliberately NOT stretched to the whole car: a wider span
-- reaches further into kerbs and potholes at the edges, and the slope is taken unclamped.
local NORMAL_SET_BACK = HALF_LENGTH - 0.3
local NORMAL_NO_SET_BACK = 0

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
-- ray starts `up_margin` (default UP_MARGIN) above `hint_z` and a miss is taken as dist >= MAX_DROP
-- (see ENGINE-API NOTE). The grid chain passes CHAIN_UP_MARGIN, every slope corner SLOPE_UP_MARGIN; only
-- the recover assist's centre drop takes the default.
local function cast_ground_z(x, y, hint_z, up_margin)
    if type(castRayStatic) ~= "function" or type(vec3) ~= "function" then
        return nil
    end
    local start_z = (hint_z or 0) + (up_margin or UP_MARGIN)
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

-- The four footprint corner points on the surface under the car standing at (x, y), in the order
-- front-left, front-right, rear-left, rear-right, or nil. `axis` is the pose's facing; the rectangle is
-- laid out along it so its long sides read as the car's pitch and its short ones as its roll, and its
-- centre sits `set_back` behind (x, y) along that same axis -- how far depends on whether the pose marks
-- the car's front edge or its middle, which only the caller knows (see NORMAL_SET_BACK). The set-back
-- therefore turns with the pose exactly like the corners do; it is never an offset along world Y. Each
-- corner reuses cast_ground_z -- this module's single cast path -- seeded at `surface_z`, the height
-- already found under the pose itself.
--
-- `set_back` has NO default on purpose. Both call sites state their pose convention explicitly, and a
-- caller that forgot to raises here instead of silently measuring the grid on the wrong 2.2 m of ground:
-- a wrong number is invisible in-game, a missing one is not.
--
-- ALL FOUR must hit: spanning a plane from fewer points needs an invented one, and the contract is to
-- degrade to flat rather than guess. Terrain height is deliberately not a fallback here either -- it
-- knows nothing about the bridge or road deck the cast found.
--
-- `up_margin` is passed through to the corner casts, and both callers hand down the narrow
-- SLOPE_UP_MARGIN on purpose: with the wide default, a deck 4 m above a corner would still be sampled and
-- tilt the car towards a surface it will never stand on -- the bridge defect one level down. The recover
-- assist took the wide window until 2026-10-07, the prime suspect for its cars rolled on flat ground.
--
-- The set-back is what a corner has to reach across from that seed (up to 3.55 m behind a grid pose), so
-- on ground falling away steeply enough behind the pose -- roughly 40 degrees over the chain's 3 m window
-- -- a rear corner starts below its surface, finds nothing and the slot degrades to flat. That is the
-- intended answer here: no measurement beats an invented one.
local function cast_normal_samples(x, y, surface_z, axis, up_margin, set_back)
    local forward = horizontal_unit(axis)
    if not forward then
        return nil
    end
    local right_x, right_y = forward.y, -forward.x
    local centre_x = x - forward.x * set_back
    local centre_y = y - forward.y * set_back

    local function corner(along, across)
        local corner_x = centre_x + forward.x * along + right_x * across
        local corner_y = centre_y + forward.y * along + right_y * across
        local corner_z = cast_ground_z(corner_x, corner_y, surface_z, up_margin)
        if not corner_z then
            return nil
        end
        return {x = corner_x, y = corner_y, z = corner_z}
    end

    local front_left = corner(NORMAL_HALF_LENGTH, -NORMAL_HALF_WIDTH)
    local front_right = corner(NORMAL_HALF_LENGTH, NORMAL_HALF_WIDTH)
    local rear_left = corner(-NORMAL_HALF_LENGTH, -NORMAL_HALF_WIDTH)
    local rear_right = corner(-NORMAL_HALF_LENGTH, NORMAL_HALF_WIDTH)
    if not (front_left and front_right and rear_left and rear_right) then
        return nil
    end
    return {front_left, front_right, rear_left, rear_right}
end

-- The unit normal of the plane through those four samples: the cross product of the two DIAGONALS,
-- (front-right - rear-left) x (front-left - rear-right). That is the exact normal of a planar quad and
-- the evenly weighted fit of a warped one, and it needs no point ordering beyond the two diagonals.
--
-- It always points UP, with no sign fix-up and no "is this upside down" guess: the cross product's z
-- component works out to 8 * NORMAL_HALF_LENGTH * NORMAL_HALF_WIDTH for ANY heading, because it depends
-- only on the corners' horizontal layout -- and each sample sits directly below its own corner, so no
-- ground shape can invert it.
local function plane_normal(samples)
    local front_left, front_right, rear_left, rear_right = samples[1], samples[2], samples[3], samples[4]
    local ax = front_right.x - rear_left.x
    local ay = front_right.y - rear_left.y
    local az = front_right.z - rear_left.z
    local bx = front_left.x - rear_right.x
    local by = front_left.y - rear_right.y
    local bz = front_left.z - rear_right.z
    local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    local len = math.sqrt(nx * nx + ny * ny + nz * nz)
    if len < EPSILON then
        return nil
    end
    return {x = nx / len, y = ny / len, z = nz / len}
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
-- when neither API answers. `hint_z` seeds the ray's start height and `up_margin` how far above it the
-- ray starts (see cast_ground_z). The terrain fallback is height-independent, so it answers whatever the
-- window was -- which is why a chain slot that overshot its window still lands on the terrain under it.
function M.ground_z(x, y, hint_z, up_margin)
    probe_height_apis(x, y, hint_z)
    local z = cast_ground_z(x, y, hint_z, up_margin)
    if z then
        return z
    end
    return terrain_ground_z(x, y)
end

-- The unit surface normal under the car placed at (x, y) -- `set_back` says how far behind that point
-- the sampled footprint sits, i.e. whether (x, y) is the car's front edge or its middle, see
-- cast_normal_samples -- plus the four points it was measured at, or nil when the footprint could not be
-- fully sampled. `surface_z` is the height already found under (x, y) (it seeds the corner casts),
-- `axis` the pose's facing, `up_margin` the corner casts' window.
--
-- The ONE slope measurement in the codebase: the grid spawn, the grid editor's preview and the recover
-- assist all reach it through attach_slope, so there is deliberately no second approximation of the
-- slope anywhere. Public as the named step of that chain rather than for an outside caller -- it has
-- none today (the editor preview goes through ground_all since the chain amendment).
function M.ground_normal(x, y, surface_z, axis, up_margin, set_back)
    local samples = cast_normal_samples(x, y, surface_z, axis, up_margin, set_back)
    if not samples then
        return nil
    end
    local normal = plane_normal(samples)
    if not normal then
        return nil
    end
    return normal, samples
end

-- The unit direction that LIES in the surface with normal `up` and keeps the COMPASS HEADING of `axis`
-- (whose own z is ignored -- it is read as a heading). Geometrically the intersection of the surface with
-- the vertical plane through that heading: driving off in `axis`, following the ground. Returns nil when
-- either argument is missing or the surface is vertical (no direction on it has that heading).
--
-- This is the ONE recipe in the codebase for putting a travel axis onto a slope, and it exists because
-- of how quatFromDir works: setFromDir (lua/common/mathlib.lua:1059) keeps `dir` VERBATIM and only
-- orthogonalises `up` against it, so handing it a HORIZONTAL axis plus a surface normal yields roll and
-- exactly ZERO pitch. The axis has to arrive already lying in the surface. BeamNG's own surface-aligned
-- placement passes an already-tilted dir for the same reason (lua/ge/spawn.lua:759, :774).
--
-- Deliberately NOT the orthogonal projection of the axis onto the plane. That also lands in the surface,
-- but on a slope with a sideways component it rotates the heading (0.8 degrees on a 15-degree slope with
-- a 5% cross-fall) -- it would let the terrain feed yaw back into an authored grid heading, when the
-- whole premise here is that a surface normal carries NO yaw information and the two are orthogonal.
function M.plane_axis(axis, up)
    if type(axis) ~= "table" or type(up) ~= "table" then
        return nil
    end
    local heading_len = math.sqrt(axis.x * axis.x + axis.y * axis.y)
    if heading_len < EPSILON or math.abs(up.z) < EPSILON then
        return nil
    end
    local x, y = axis.x / heading_len, axis.y / heading_len
    -- On the plane through the origin with this normal, z = -(up.x * x + up.y * y) / up.z.
    local z = -(up.x * x + up.y * y) / up.z
    local len = math.sqrt(1 + z * z)
    return {x = x / len, y = y / len, z = z / len}
end

-- Put the surface's SLOPE at (x, y) on an already-dropped pose, so the car follows the ground instead
-- of standing flat in it (ADR-0034 amendment 2026-08-30). `seed_z` is the height the corner casts start
-- from -- the surface just found under the pose -- `up_margin` their window, and `set_back` the pose's
-- convention (front edge or middle, see NORMAL_SET_BACK). Absent `up` means every consumer keeps
-- world-up, i.e. exactly the behaviour before that amendment.
--
-- Two conditions, and both are load-bearing: without a `seed_z` there is no measured height to hang the
-- corner casts on, and without `forward` the car cannot be placed in a tilted frame at all --
-- vehicles.pose_frame needs exactly that field, and a pose without it keeps the authored start
-- quaternion and spawns flat. Measuring a normal that could never be used would only make the grid
-- editor lean pillars over cars that will not lean (ADR-0023: the preview IS the spawn).
--
-- `samples` (the four measured points) rides along the same way grid.lua's `faceDir` does: it is
-- draw-only, and the grid editor needs it to show WHERE the slope was measured -- the slope is taken
-- unclamped, so a corner landing on a kerb is a real result an admin has to be able to see.
local function attach_slope(grounded, x, y, seed_z, forward, up_margin, set_back)
    if not seed_z or not forward then
        return
    end
    grounded.up, grounded.samples = M.ground_normal(x, y, seed_z, forward, up_margin, set_back)
end

-- A copy of `pose` dropped onto the surface: z = ground + GROUND_CLEARANCE, or the original z when no
-- surface is found (degrade-don't-crash). The single-pose, UN-CHAINED form -- the recover assist's pass
-- (via clear_pose), whose centre drop searches from the pose's own authored z through the wide UP_MARGIN
-- window. The grid goes through ground_all instead, which chains. Never mutates the input: grid.poses
-- shares one read-only `forward` table across slots and reuses `rot`, so those pass through by reference
-- while a NEW pos table is built.
--
-- The slope is sampled with NO set-back: this pose is the car's MIDDLE (recover_to puts the box centre
-- on it), not the front edge a grid slot describes -- see NORMAL_SET_BACK. Its corners take the grid's
-- narrow SLOPE_UP_MARGIN, not the centre drop's 10 m (ADR-0034 amendment 2026-10-07).
--
-- `surface` is the raw height the centre drop found (nil when nothing answered), published so the
-- recover's log line can state the corner samples relative to it -- a corner standing on a barrier then
-- reads as "+1.00 m" instead of hiding inside a normal vector.
function M.ground_pose(pose)
    local pos = pose.pos
    local ground = M.ground_z(pos.x, pos.y, pos.z)
    local grounded = {
        pos = {x = pos.x, y = pos.y, z = ground and (ground + GROUND_CLEARANCE) or pos.z},
        rot = pose.rot,
        forward = pose.forward,
        surface = ground,
    }
    attach_slope(grounded, pos.x, pos.y, ground, pose.forward, SLOPE_UP_MARGIN, NORMAL_NO_SET_BACK)
    return grounded
end

-- Ground ONE slot of the grid chain and report the surface it found (nil when nothing answered).
--
-- `hint_z` is where the search starts: the surface the PREVIOUS slot found, or -- until anything has
-- grounded -- the slot's own authored z. That inherited height is also what the slot falls back to when
-- its own cast finds nothing, and that is the point of the chain rather than a detail of it: a gap in
-- the geometry must not drop one car back to the flat start-line height the rest of the field has
-- already climbed away from.
--
-- The pose's own three placement options ride along from grid.lua (ADR-0023 amendment 2026-09-01) and
-- are read HERE, so the editor preview and the spawn honour them through the same code.
local function ground_chained(pose, hint_z)
    local pos = pose.pos
    local lift = tonumber(pose.lift) or 0
    -- `castLift` moves ONLY where the ray starts. The height this slot falls back to and the height it
    -- hands on both stay measured from the un-shifted chain, so lifting one segment's window to see over
    -- a rise can never drag the field up with it.
    local surface = nil
    if not pose.noDowncast then
        surface = M.ground_z(pos.x, pos.y, hint_z + (tonumber(pose.castLift) or 0), CHAIN_UP_MARGIN)
    end
    local grounded = {
        pos = {
            x = pos.x,
            y = pos.y,
            z = (surface and (surface + GROUND_CLEARANCE) or hint_z) + lift,
        },
        rot = pose.rot,
        forward = pose.forward,
    }
    -- The tilt is measured from the surface the drop found -- or, when the drop is switched OFF, from
    -- the chain height, so that "no ground drop" and "no slope" stay two independent switches. A drop
    -- that FAILED still yields no seed and therefore no tilt, exactly as before: a slot whose own cast
    -- found nothing must not lean on a guess.
    if not pose.noSlope then
        local seed = surface
        if not seed and pose.noDowncast then
            seed = hint_z
        end
        attach_slope(grounded, pos.x, pos.y, seed, pose.forward, SLOPE_UP_MARGIN, NORMAL_SET_BACK)
    end
    return grounded, surface
end

-- Ground a list of poses HEIGHT-ONLY, in slot order -- the grid spawn pass (ADR-0034 amendment): each
-- pose drops to the surface with NO wall displacement, so the spawned field keeps the authored X/Y of
-- every slot, exactly what the editor preview shows.
--
-- The drops form a CHAIN (ADR-0034 amendment 2026-09-01): each slot searches from the height the slot
-- BEFORE it found, so the search window travels with the terrain instead of hanging off one authored
-- start-line z for the whole field. What is handed on is the RAW SURFACE -- never the pose z -- so
-- clearance and lift can never accumulate down the field. Slot order is spatial order here (staggered
-- columns, `column = slot % columns` in grid.lua), so the chain really does walk the ground.
--
-- A pose's `lift` (the offsetHeight knob's POST-grounding lift, ADR-0023 amendment) is added on top --
-- equally on the degrade path when no surface answers -- so +1 m spawns the car exactly 1 m above where
-- it would otherwise sit. Grid poses carry `lift`, `castLift`, `noDowncast` and `noSlope` (ADR-0023
-- amendment 2026-09-01, read in ground_chained); recover targets carry none of them. A slot that finds
-- nothing leaves the chain height untouched for the next slot: the last surface actually measured stays
-- the reference. Entries that are not {pos = {...}} tables pass through unchanged (defensive at the call
-- boundary, like resolve). Returns a new list; the input list and its pose tables are not mutated.
function M.ground_all(poses)
    if type(poses) ~= "table" then
        return poses
    end
    local grounded = {}
    local chain_z = nil
    for index = 1, #poses do
        local pose = poses[index]
        if type(pose) == "table" and type(pose.pos) == "table" then
            local dropped, surface = ground_chained(pose, chain_z or pose.pos.z)
            if surface then
                chain_z = surface
            end
            grounded[index] = dropped
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
--
-- A nudged pose gets its slope RE-MEASURED where it ends up (ADR-0034 amendment 2026-09-01,
-- recover-follows-surface-slope): the car stands metres from the checkpoint centre by then, so the
-- normal measured there would be the slope of a patch of ground it never touches -- and since
-- vehicles.recover_to orients into that normal now, a stale one would tilt the car wrongly rather than
-- go unread. Both exits re-measure, the nudged-clear one and the gave-up one, with the same narrow
-- SLOPE_UP_MARGIN as ground_pose, and both publish the `surface` they measured from.
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
    local surface = nil

    -- The pose the nudge settled on, with the slope measured at THAT spot. `surface` is the height the
    -- last step's own cast found -- the same seed ground_pose uses -- so a step whose cast found nothing
    -- leaves the pose without a normal and the car flat, rather than tilted by a guess.
    local function nudged_pose()
        local moved = {
            pos = {x = x, y = y, z = z},
            rot = pose.rot,
            forward = pose.forward,
            surface = surface,
        }
        attach_slope(moved, x, y, surface, forward, SLOPE_UP_MARGIN, NORMAL_NO_SET_BACK)
        return moved
    end

    for _ = 1, MAX_NUDGES do
        x = x + forward.x * NUDGE_STEP
        y = y + forward.y * NUDGE_STEP
        surface = M.ground_z(x, y, z)
        z = surface and (surface + GROUND_CLEARANCE) or z
        if not is_blocked(x, y, z, forward) then
            return nudged_pose()
        end
    end

    log("W", LOG_TAG, "placement: could not nudge the recover target clear of geometry -- "
        .. "using the last tried position")
    return nudged_pose()
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
