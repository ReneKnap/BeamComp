-- BeamComp -- parametric start-grid pose math.
--
-- Lives at lua/ge/extensions/beamcomp/race/grid.lua inside the client mod zip. Stateless
-- and engine-independent: plain {x, y, z} / {x, y, z, w} tables in and out, no engine
-- handles, so it is trivially reload-safe. Target: client GE (LuaJIT 5.1).
--
-- Lays N players out in a grid behind a single base start pose. The shape is driven by a parameter
-- set (ADR-0023) -- offsets, spacings, an extra heading rotation, and a row count -- rather than fixed
-- constants. When no params are given the defaults reproduce the historical staggered two-column
-- layout (offset 15 m back, ADR-0022), so a race with no custom grid looks exactly as before. A custom
-- grid (server-stored, named, relayed in raceStart) just supplies a different param set.
--
-- Longitudinal axis: the grid's forward direction (the way the field drives off the line) comes
-- from real world geometry, NOT from a guessed quaternion axis. Callers pass the start/finish gate
-- normal (the direction of travel through CP0); the grid lays the field out behind it. When no gate
-- normal exists the grid derives forward from the start pose itself (see forward_from_base_rot).
-- The headingDeg param rotates the whole grid (positions + car headings) about vertical on top of that.

local M = {}

-- Layout defaults. Reproduce the historical staggered two-column grid when a param is absent:
-- two columns 4 m apart (2 * the old HALF_WIDTH), rows 6 m apart, and the whole field 15 m behind the
-- line (the old GRID_START_SETBACK, ADR-0022). The per-column stagger is no longer a fixed value: each
-- column is set back by row_gap / columns, so the columns spread evenly across one row's depth (with two
-- columns, column 2 sits at half the row gap). For the default (6 m rows, 2 columns) that is 3 m -- the
-- same as the old fixed STAGGER, so the default grid is unchanged.
local DEFAULT_COLUMNS = 2
local DEFAULT_OFFSET_FORWARD = 15.0  -- metres the whole grid trails behind the line (ADR-0022)
local DEFAULT_OFFSET_LATERAL = 0.0   -- metres the whole grid shifts along the right axis
local DEFAULT_HEADING_DEG = 0.0      -- extra rotation about vertical applied to layout + headings
local DEFAULT_ROW_GAP = 6.0          -- longitudinal gap between rows (metres)
local DEFAULT_COL_GAP = 4.0          -- lateral gap between adjacent columns (metres)

-- Fixed field size the grid is laid out (and centred) for, so a given slot's pose is INDEPENDENT of how
-- many players are actually present: P0..P7 sit in the same places whether 1 or 8 cars spawn, and the
-- editor's 8-car preview matches the real spawn. Only the first `count` slots get a pose. A field larger
-- than this still works (the layout grows), it just is not the centred-for-8 arrangement.
local GRID_CAPACITY = 8
M.LAYOUT_CAPACITY = GRID_CAPACITY

-- BeamNG vehicle-forward axis in object space, used only by the no-gate-normal fallback: the grid
-- lays cars out along this once it is rotated into the world by the placement rotation. +Y is the
-- documented default; if a race whose start line has NO gate normal lays its grid out sideways or in
-- front of the line, flip/rotate this. Races with a gate normal (the common case, e.g. closed
-- circuits) never touch this.
local VEHICLE_FORWARD_LOCAL = {x = 0, y = 1, z = 0}

-- 180-degree rotation about Z (vertical) -- the exact flip vehicles.lua applies when it actually
-- places the car (quat(0,0,1,0) * base_rot). We replicate it here so the FALLBACK forward axis
-- matches the heading the car ends up at, not the raw authored start quaternion.
local Z_FLIP = {x = 0, y = 0, z = 1, w = 0}

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

-- The unit quaternion for a rotation of `angle_rad` about world vertical (Z).
local function z_quat(angle_rad)
    local half = angle_rad * 0.5
    return {x = 0, y = 0, z = math.sin(half), w = math.cos(half)}
end

-- Rotate a horizontal {x, y, z} vector about vertical by `angle_rad` (z is forced flat).
local function rotate_horizontal(v, angle_rad)
    local cos_a = math.cos(angle_rad)
    local sin_a = math.sin(angle_rad)
    return {x = v.x * cos_a - v.y * sin_a, y = v.x * sin_a + v.y * cos_a, z = 0}
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

-- Fill a (possibly partial, possibly nil) grid param set with defaults. Param keys are camelCase to
-- match the wire format (ADR-0023); 0 is a valid value for the numeric offsets/gaps, so `or` defaulting
-- is safe (0 is truthy in Lua). Rows default to GRID_CAPACITY / DEFAULT_COLUMNS (the historical two
-- columns) and are clamped to [1, GRID_CAPACITY] -- independent of the live player count, so a slot's
-- pose is stable across field sizes.
local function resolved_params(params)
    params = params or {}
    local rows = params.rows
    if type(rows) ~= "number" or rows < 1 then
        rows = math.ceil(GRID_CAPACITY / DEFAULT_COLUMNS)
    end
    rows = math.max(1, math.min(GRID_CAPACITY, math.floor(rows)))
    return {
        offset_forward = params.offsetForward or DEFAULT_OFFSET_FORWARD,
        offset_lateral = params.offsetLateral or DEFAULT_OFFSET_LATERAL,
        heading_deg = params.headingDeg or DEFAULT_HEADING_DEG,
        row_gap = params.rowGap or DEFAULT_ROW_GAP,
        col_gap = params.colGap or DEFAULT_COL_GAP,
        rows = rows,
    }
end

-- A fresh default param set (camelCase, as stored and edited). The grid editor (race/grideditor) seeds
-- its starting values from this so it shows real numbers to tune; a race start that relays no custom
-- grid gets the same values implicitly via resolved_params.
function M.default_params()
    return {
        offsetForward = DEFAULT_OFFSET_FORWARD,
        offsetLateral = DEFAULT_OFFSET_LATERAL,
        headingDeg = DEFAULT_HEADING_DEG,
        rowGap = DEFAULT_ROW_GAP,
        colGap = DEFAULT_COL_GAP,
        rows = math.ceil(GRID_CAPACITY / DEFAULT_COLUMNS),
    }
end

-- Grid poses for `count` players behind base_pos/base_rot. Returns a list of
-- { pos = {x, y, z}, rot = {x, y, z, w} } in slot order.
--   params      -- optional grid param set (ADR-0023): offsetForward/offsetLateral (metres, along the
--                  travel/right axes), headingDeg (extra rotation of the whole grid about vertical),
--                  rowGap/colGap (metres), rows (columns are derived as ceil(capacity / rows), where
--                  capacity is a fixed field size, so a slot's pose does not shift with the live count).
--                  Nil or missing fields fall back to the historical layout.
--   gate_normal -- optional {x, y, z} start/finish gate normal (CP0's direction of travel). When given
--                  the grid lays out behind it; when absent it derives forward from base_rot.
-- Each slot is placed as right * lateral + (-forward) * setback: lateral spreads the columns about the
-- centre, setback trails the field back along the travel axis. Within a row the columns are staggered by
-- row_gap / columns each, so they spread evenly across one row's depth (two columns -> column 2 at half
-- the row gap). headingDeg pivots both the layout axes and every car heading. z is taken from base_pos.
function M.poses(base_pos, base_rot, count, params, gate_normal)
    local p = resolved_params(params)
    local heading_rad = math.rad(p.heading_deg)

    local forward = resolve_forward(base_rot, gate_normal)
    if p.heading_deg ~= 0 then
        forward = rotate_horizontal(forward, heading_rad)
    end
    -- Right-hand horizontal perpendicular to forward (forward x up). Which column is left vs right is
    -- arbitrary -- the columns are symmetric -- so any consistent perpendicular is fine.
    local right = {x = forward.y, y = -forward.x, z = 0}

    local rot = base_rot
    if p.heading_deg ~= 0 then
        rot = quat_mul(z_quat(heading_rad), base_rot)
    end

    -- Columns from the FIXED capacity (not the live count), so slot k sits in the same place whether 1
    -- or capacity cars spawn -- the editor preview then matches the real grid. A field above capacity
    -- grows the columns to fit.
    local columns = math.ceil(math.max(count, GRID_CAPACITY) / p.rows)
    local centre_column = (columns - 1) / 2
    -- Per-column stagger: spread the columns evenly across one row's depth so the grid forms a smooth
    -- diagonal (two columns -> column 2 at half the row gap), continuing into the next rows.
    local column_setback = p.row_gap / columns

    local poses = {}
    for slot = 0, count - 1 do
        local column = slot % columns
        local row = math.floor(slot / columns)
        local lateral = (column - centre_column) * p.col_gap + p.offset_lateral
        local setback = row * p.row_gap + column * column_setback + p.offset_forward
        poses[#poses + 1] = {
            pos = {
                x = base_pos.x + right.x * lateral - forward.x * setback,
                y = base_pos.y + right.y * lateral - forward.y * setback,
                z = base_pos.z,
            },
            rot = {x = rot.x, y = rot.y, z = rot.z, w = rot.w},
        }
    end
    return poses
end

return M
