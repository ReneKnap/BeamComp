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
-- The headingDeg param rotates the whole grid (positions + car headings) about vertical on top of
-- that. Each pose carries the grid's `forward` travel axis (the direction the car should face) when
-- it comes from a gate normal -- the reliable source -- so the placement can orient the car to the
-- grid instead of the authored start quaternion; `forward` is nil when there is no gate normal, in
-- which case the placement keeps the start pose's own heading.

local M = {}

-- Layout defaults. The default grid pins two columns and lets the rows grow with the field: a 2-wide grid
-- 4 m across (DEFAULT_COL_GAP), each row 8 m further back (DEFAULT_ROW_GAP), the whole field 15 m behind the
-- line (the old GRID_START_SETBACK, ADR-0022). The per-column stagger is not a fixed value: each column is
-- set back by row_gap / columns, so the columns spread evenly across one row's depth (with two columns,
-- column 2 sits at half the row gap -- 4 m for the 8 m default).
local DEFAULT_COLUMNS = 2
local DEFAULT_OFFSET_FORWARD = 15.0  -- metres the whole grid trails behind the line (ADR-0022)
local DEFAULT_OFFSET_LATERAL = 0.0   -- metres the whole grid shifts along the right axis
local DEFAULT_HEADING_DEG = 0.0      -- extra rotation about vertical applied to layout + headings
local DEFAULT_ROW_GAP = 8.0          -- longitudinal gap between rows (metres)
local DEFAULT_COL_GAP = 4.0          -- lateral gap between adjacent columns (metres)

-- The editor's default preview field size and the rows clamp/fallback. With the columns-pinned default a
-- slot's pose is count-independent (slot k -> a fixed row/column from k alone), so the editor's 8-car
-- preview matches the real spawn. NOTE: this is no longer a layout floor -- when rows are pinned instead,
-- the columns derive from the ACTUAL field size (grid.poses), so that layout grows/shrinks with the count.
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
-- is safe (0 is truthy in Lua). rows and columns are two ways to express the same width and are mutually
-- exclusive: an explicit `columns` PINS the column count (poses uses it verbatim, the rows grow with the
-- field); an explicit `rows` pins the row count (poses derives the columns from the live field size). When
-- NEITHER is given -- the bare fallback / no-custom-grid case -- the default pins DEFAULT_COLUMNS columns.
-- Both pins clamp to [1, GRID_CAPACITY]; rows always gets a value (used only when columns is nil/derived).
local function resolved_params(params)
    params = params or {}

    local has_columns = type(params.columns) == "number" and params.columns >= 1
    local has_rows = type(params.rows) == "number" and params.rows >= 1

    local columns
    if has_columns then
        columns = math.max(1, math.min(GRID_CAPACITY, math.floor(params.columns)))
    elseif not has_rows then
        columns = DEFAULT_COLUMNS
    else
        columns = nil
    end

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
        columns = columns,
    }
end

-- A fresh default param set (camelCase, as stored and edited). The grid editor (race/grideditor) seeds
-- its starting values from this so it shows real numbers to tune; a race start that relays no custom
-- grid gets the same defaults implicitly via resolved_params. Pins DEFAULT_COLUMNS columns; rows is the
-- dynamic axis, left unset so the editor shows it as derived ("auto") and it grows with the field.
function M.default_params()
    return {
        offsetForward = DEFAULT_OFFSET_FORWARD,
        offsetLateral = DEFAULT_OFFSET_LATERAL,
        headingDeg = DEFAULT_HEADING_DEG,
        rowGap = DEFAULT_ROW_GAP,
        colGap = DEFAULT_COL_GAP,
        columns = DEFAULT_COLUMNS,
    }
end

-- Grid poses for `count` players behind base_pos/base_rot. Returns a list of
-- { pos = {x, y, z}, rot = {x, y, z, w} } in slot order.
--   params      -- optional grid param set (ADR-0023): offsetForward/offsetLateral (metres, along the
--                  travel/right axes), headingDeg (extra rotation of the whole grid about vertical),
--                  rowGap/colGap (metres), and a width pin -- either rows (columns are derived as
--                  ceil(count / rows) from the live field, so the columns grow/shrink with the driver
--                  count) or columns (an explicit column count that pins the width and lets the rows grow).
--                  Nil or missing fields fall back to the default layout (pinned DEFAULT_COLUMNS columns).
--   gate_normal -- optional {x, y, z} start/finish gate normal (CP0's direction of travel). When given
--                  the grid lays out behind it; when absent it derives forward from base_rot.
-- Each slot is placed as right * lateral + (-forward) * setback: lateral spreads the columns about the
-- centre, setback trails the field back along the travel axis. Within a row the columns are staggered by
-- row_gap / columns each, so they spread evenly across one row's depth (two columns -> column 2 at half
-- the row gap). headingDeg pivots both the layout axes and every car heading. z is taken from base_pos.
function M.poses(base_pos, base_rot, count, params, gate_normal)
    local p = resolved_params(params)
    local heading_rad = math.rad(p.heading_deg)

    -- The grid's forward axis (direction of travel off the line), preferring the gate normal. The
    -- gate normal is the only reliable heading source; when it is present and horizontal that axis is
    -- handed to the placement as `facing` so the car is oriented to the grid (the layout) rather than
    -- the authored start quaternion. With no usable gate normal `facing` stays nil and the placement
    -- keeps the start pose's heading (rot), so races with no gate normal are unchanged.
    local facing = gate_normal and horizontal_unit(gate_normal) or nil
    local forward = resolve_forward(base_rot, gate_normal)

    -- headingDeg rotates the whole grid -- layout axes and car headings alike -- on top of that.
    if p.heading_deg ~= 0 then
        forward = rotate_horizontal(forward, heading_rad)
        if facing then
            facing = rotate_horizontal(facing, heading_rad)
        end
    end
    -- Right-hand horizontal perpendicular to forward (forward x up). Which column is left vs right is
    -- arbitrary -- the columns are symmetric -- so any consistent perpendicular is fine.
    local right = {x = forward.y, y = -forward.x, z = 0}

    -- Fallback heading when there is no gate normal: the authored start pose, turned about vertical by
    -- headingDeg (the historical behaviour). The placement uses this only when `facing` is nil.
    local rot = base_rot
    if p.heading_deg ~= 0 then
        rot = quat_mul(z_quat(heading_rad), base_rot)
    end

    -- Columns: an explicit count (p.columns) pins them so the grid never grows wider than asked, and the
    -- rows grow with the field. Otherwise (rows pinned) derive the columns from the ACTUAL field size, so a
    -- pinned 2-row grid is 2 cars wide for 4 cars and grows wider as the field grows. max(count, 1) only
    -- guards the column_setback division below for an empty field (the slot loop then runs zero times).
    local columns = p.columns or math.ceil(math.max(count, 1) / p.rows)
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
            -- The travel axis the car should face, from the gate normal (+ headingDeg); nil when no
            -- gate normal, so the placement falls back to `rot`. Shared read-only across slots.
            forward = facing,
        }
    end
    return poses
end

return M
