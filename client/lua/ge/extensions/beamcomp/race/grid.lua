-- BeamComp -- staggered start-grid pose math.
--
-- Lives at lua/ge/extensions/beamcomp/race/grid.lua inside the client mod zip. Stateless
-- and engine-independent: plain {x, y, z} / {x, y, z, w} tables in and out, no engine
-- handles, so it is trivially reload-safe. Target: client GE (LuaJIT 5.1).
--
-- Lays N players out in a two-column staggered grid behind a single base start pose
-- (the race-start-sequence feature). All cars keep the base heading; only position varies.
--
-- Longitudinal axis: the grid's forward direction (the way the field drives off the line) comes
-- from real world geometry, NOT from a guessed quaternion axis. Callers pass the start/finish gate
-- normal (the direction of travel through CP0); the grid lays the field out behind it. When no gate
-- normal exists the grid derives forward from the start pose itself (see forward_from_base_rot).
-- This replaces the old "+Y = forward" guess (LONGITUDINAL_SIGN), which put the field ~90 deg off
-- and drifted the whole grid sideways once the start-setback grew (ADR-0022 wanted the backward
-- sign taken from the checkpoint geometry; this is that).

local M = {}

local COLUMNS = 2
local HALF_WIDTH = 2.0   -- lateral offset of each column from centre (metres)
local ROW_GAP = 6.0      -- longitudinal gap between rows (metres)
local STAGGER = 3.0      -- extra setback applied to the right column (metres)

-- 180-degree rotation about Z (vertical) -- the exact flip vehicles.lua applies when it actually
-- places the car (quat(0,0,1,0) * base_rot). We replicate it here so the FALLBACK forward axis
-- matches the heading the car ends up at, not the raw authored start quaternion.
local Z_FLIP = {x = 0, y = 0, z = 1, w = 0}

-- BeamNG vehicle-forward axis in object space, used only by the no-gate-normal fallback: the grid
-- lays cars out along this once it is rotated into the world by the placement rotation. +Y is the
-- documented default; if a race whose start line has NO gate normal lays its grid out sideways or in
-- front of the line, flip/rotate this -- it is the in-game-tunable knob the old LONGITUDINAL_SIGN was.
-- Races with a gate normal (the common case, e.g. closed circuits) never touch this.
local VEHICLE_FORWARD_LOCAL = {x = 0, y = 1, z = 0}

local EPSILON = 1e-6

-- Rotate a plain {x, y, z} vector by a plain {x, y, z, w} quaternion:
--   v' = v + 2w(q x v) + 2 q x (q x v)
local function rotate_vector(q, v)
    local first = {
        x = q.y * v.z - q.z * v.y,
        y = q.z * v.x - q.x * v.z,
        z = q.x * v.y - q.y * v.x,
    }
    local second = {
        x = q.y * first.z - q.z * first.y,
        y = q.z * first.x - q.x * first.z,
        z = q.x * first.y - q.y * first.x,
    }
    return {
        x = v.x + 2 * (q.w * first.x + second.x),
        y = v.y + 2 * (q.w * first.y + second.y),
        z = v.z + 2 * (q.w * first.z + second.z),
    }
end

-- Hamilton product a (x) b of two plain {x, y, z, w} quaternions.
local function quat_mul(a, b)
    return {
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
end

-- A {x, y, z} vector flattened to the horizontal plane and unit-normalized, or nil when it has no
-- horizontal component (degenerate -- the grid axis can't be derived from a straight-up/down vector).
local function horizontal_unit(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y)
    if len < EPSILON then
        return nil
    end
    return {x = v.x / len, y = v.y / len, z = 0}
end

-- The grid's forward direction (direction of travel off the line) derived from the start pose, for
-- races whose start line has no gate normal. Uses the same placement rotation the car gets
-- (Z_FLIP * base_rot, see vehicles.lua), so the layout can't disagree with the heading. Returns a
-- horizontal unit {x, y, z} or nil if it degenerates.
local function forward_from_base_rot(base_rot)
    local placed = quat_mul(Z_FLIP, base_rot)
    return horizontal_unit(rotate_vector(placed, VEHICLE_FORWARD_LOCAL))
end

-- The forward (travel) unit vector for the grid: prefer the gate normal (direction of travel through
-- CP0, the cleanest source), else derive from the start pose, with a final raw-base_rot last resort so
-- a pose always comes back. Always horizontal so the grid stays level.
local function resolve_forward(base_rot, gate_normal)
    if gate_normal then
        local f = horizontal_unit(gate_normal)
        if f then
            return f
        end
    end
    return forward_from_base_rot(base_rot)
        or horizontal_unit(rotate_vector(base_rot, {x = 0, y = 1, z = 0}))
        or {x = 1, y = 0, z = 0}
end

-- Grid poses for `count` players behind base_pos/base_rot. Returns a list of
-- { pos = {x, y, z}, rot = {x, y, z, w} } in slot order; every pose keeps the base heading.
--   start_setback -- optional metres to push the WHOLE grid further behind the line (default 0).
--   gate_normal   -- optional {x, y, z} start/finish gate normal (CP0's direction of travel). When
--                    given the grid lays out behind it; when absent it derives forward from base_rot.
-- Each slot is placed in the world frame as right * lateral + (-forward) * setback: lateral spreads
-- the two columns, setback (rows + stagger + start_setback) trails the field straight back along the
-- travel axis. z is taken from base_pos -- the grid stays level.
function M.poses(base_pos, base_rot, count, start_setback, gate_normal)
    local forward = resolve_forward(base_rot, gate_normal)
    -- Right-hand horizontal perpendicular to forward (forward x up). Which column is left vs right is
    -- arbitrary -- the two columns are symmetric -- so any consistent perpendicular is fine.
    local right = {x = forward.y, y = -forward.x, z = 0}

    local poses = {}
    for slot = 0, count - 1 do
        local column = slot % COLUMNS
        local row = math.floor(slot / COLUMNS)
        local lateral = (column == 0) and -HALF_WIDTH or HALF_WIDTH
        local setback = row * ROW_GAP + ((column == 1) and STAGGER or 0) + (start_setback or 0)
        poses[#poses + 1] = {
            pos = {
                x = base_pos.x + right.x * lateral - forward.x * setback,
                y = base_pos.y + right.y * lateral - forward.y * setback,
                z = base_pos.z,
            },
            rot = {x = base_rot.x, y = base_rot.y, z = base_rot.z, w = base_rot.w},
        }
    end
    return poses
end

return M
