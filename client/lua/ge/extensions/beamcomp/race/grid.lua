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
--
-- Segmented grids (ADR-0023 amendment): a direction's grid can be an ordered list of stacked parametric
-- segments -- segment 0 is the base param set (today's block) and each further segment starts at a
-- breakpoint slot with its own full param set, laid out BEHIND the previous one. M.poses_segmented runs the
-- stacking as a KINEMATIC FRAME CHAIN: each segment lays out in a running frame and passes the next segment
-- the frame at its own end, so a segment's forward continuation (seamless at offsetForward 0), its lateral
-- offset, its height anchor (anchorHeight -- retired, see resolved_params) and its heading rotation all
-- carry into the whole tail behind it (headings compose cumulatively).
--
-- Distinct from the chaining anchor, four per-segment params say how a slot MEETS THE GROUND. They do not
-- chain and this module never acts on them -- it states them on each pose and the ground pass
-- (race/placement.lua) is what reads them, which is how grid.lua stays engine-independent while the knobs
-- still reach the cast: offsetHeight -> `lift` (the post-grounding lift, added after the surface snap),
-- castHeight -> `castLift` (how much higher the ground SEARCH starts -- window only), noDowncast (no drop
-- at all) and noSlope (no measured tilt).
-- A single-segment list reproduces M.poses (today's layout) bit-for-bit. block_to_segments /
-- segments_to_block convert between the stored block and the segment list.

local M = {}

-- Layout defaults. The default grid pins two columns and lets the rows grow with the field: a 2-wide grid
-- 4 m across (DEFAULT_COL_GAP), each row 8 m further back (DEFAULT_ROW_GAP), the whole field 15 m behind the
-- line (the old GRID_START_SETBACK, ADR-0022). The per-column stagger is not a fixed value: each column is
-- set back by row_gap / columns, so the columns spread evenly across one row's depth (with two columns,
-- column 2 sits at half the row gap -- 4 m for the 8 m default).
local DEFAULT_COLUMNS = 2
local DEFAULT_OFFSET_FORWARD = 15.0  -- metres the whole grid trails behind the line (ADR-0022)
local DEFAULT_OFFSET_LATERAL = 0.0   -- metres the whole grid shifts along the right axis
local DEFAULT_ANCHOR_HEIGHT = 0.0    -- metres the segment base lifts above the inherited chain z (chains)
local DEFAULT_OFFSET_HEIGHT = 0.0    -- metres each pose lifts above the grounded surface (no chaining)
local DEFAULT_CAST_HEIGHT = 0.0      -- metres the ground search starts higher (window only, no chaining)
local DEFAULT_NO_DOWNCAST = false    -- skip the ground drop for this segment
local DEFAULT_NO_SLOPE = false       -- skip the measured surface tilt for this segment
local DEFAULT_HEADING_DEG = 0.0      -- extra rotation about vertical applied to layout + headings
local DEFAULT_ROW_GAP = 8.0          -- longitudinal gap between rows (metres)
local DEFAULT_COL_GAP = 4.0          -- lateral gap between adjacent columns (metres)
local DEFAULT_MIRROR = false         -- lateral side flip: off reproduces the historical pole-left layout

-- The upper bound of an explicit WIDTH PIN. rows and columns are the two ways to pin a grid's width and
-- resolved_params clamps whichever one is given to [1, MAX_AXIS_PIN], so this single number decides how
-- wide -- or, pinned the other way round, how deep -- a grid may be authored.
--
-- Exported because the editor's knob constraint has to READ this number instead of keeping a copy of it
-- (race/grideditor.lua): the hand-written copy is what broke -- it named a constant no file in this mod
-- defines, so it reads nil and leaves rows and columns with no upper clamp at all.
--
-- The server mirrors it as grid_fit.AXIS_CAPACITY for the ADR-0051 slot reservation, which has to
-- reproduce this side's column count exactly. The two move together, or the reservation punches its
-- holes into a grid that nobody lays out.
local MAX_AXIS_PIN = 8
M.MAX_AXIS_PIN = MAX_AXIS_PIN

-- The rows a param set falls back to when it pins NEITHER axis. Deliberately a plain number and NOT
-- derived from MAX_AXIS_PIN: this is a DEFAULT, not a clamp, and for as long as it was spelled
-- ceil(CAPACITY / DEFAULT_COLUMNS) every move of the cap silently dragged the default along with it.
-- The value is unobservable today -- resolved_params leaves `columns` nil only when `rows` is explicitly
-- pinned, and that pinned number is the only p.rows compute_segment ever divides by -- so its one job is
-- to keep the resolved `rows` a usable number instead of nil.
local DEFAULT_ROWS = 4

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
-- Both pins clamp to [1, MAX_AXIS_PIN]; rows always gets a value (used only when columns is nil/derived).
-- `mirror` is a boolean (not a number): only a genuine `true` enables the lateral flip, so an absent or
-- false flag reproduces today's pole-left layout bit-for-bit (0/1 would misfire -- 0 is truthy in Lua).
-- A shallow copy of a table (nil-tolerant), so a stored grid block / param set can be re-based into the
-- editor's segment model or serialized back without ever aliasing (and thus mutating) the source table.
local function shallow_copy(t)
    local copy = {}
    if type(t) == "table" then
        for key, value in pairs(t) do
            copy[key] = value
        end
    end
    return copy
end

local function resolved_params(params)
    params = params or {}

    local has_columns = type(params.columns) == "number" and params.columns >= 1
    local has_rows = type(params.rows) == "number" and params.rows >= 1

    local columns
    if has_columns then
        columns = math.max(1, math.min(MAX_AXIS_PIN, math.floor(params.columns)))
    elseif not has_rows then
        columns = DEFAULT_COLUMNS
    else
        columns = nil
    end

    local rows = params.rows
    if type(rows) ~= "number" or rows < 1 then
        rows = DEFAULT_ROWS
    end
    rows = math.max(1, math.min(MAX_AXIS_PIN, math.floor(rows)))

    return {
        offset_forward = params.offsetForward or DEFAULT_OFFSET_FORWARD,
        offset_lateral = params.offsetLateral or DEFAULT_OFFSET_LATERAL,
        -- Internal pre-grounding height ANCHOR (ADR-0023 amendment): metres the segment base lifts
        -- above the inherited chain z, chaining into the following segments. RETIRED as of the
        -- 2026-09-01 amendment -- nothing writes it any more (the editor's auto-seed is gone) and
        -- block_to_segments strips it from every loaded grid, because the height chain re-centres the
        -- ground-cast window per slot, which is the whole job this anchor was seeded for. Kept because
        -- the segment frame still carries a z and this is where it would be lifted; at its 0 default the
        -- base is exactly the inherited chain z.
        anchor_height = params.anchorHeight or DEFAULT_ANCHOR_HEIGHT,
        -- The height KNOB (ADR-0023 amendment): a POST-grounding lift, metres above the surface. Pure
        -- math here only writes it onto each pose as `lift`; the ground passes (spawn ground_all,
        -- editor preview) add it AFTER their surface snap. Does NOT chain, never moves the cast window.
        offset_height = params.offsetHeight or DEFAULT_OFFSET_HEIGHT,
        -- The three placement options of the ADR-0023 amendment 2026-09-01, all per segment and all pure
        -- pass-through: this module only writes them onto each pose, the ground pass (placement.lua) is
        -- what acts on them. None of the three chains -- they describe how ONE slot meets the ground.
        cast_height = params.castHeight or DEFAULT_CAST_HEIGHT,
        no_downcast = params.noDowncast == true,
        no_slope = params.noSlope == true,
        heading_deg = params.headingDeg or DEFAULT_HEADING_DEG,
        row_gap = params.rowGap or DEFAULT_ROW_GAP,
        col_gap = params.colGap or DEFAULT_COL_GAP,
        rows = rows,
        columns = columns,
        mirror = params.mirror == true,
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
        offsetHeight = DEFAULT_OFFSET_HEIGHT,
        castHeight = DEFAULT_CAST_HEIGHT,
        headingDeg = DEFAULT_HEADING_DEG,
        rowGap = DEFAULT_ROW_GAP,
        colGap = DEFAULT_COL_GAP,
        columns = DEFAULT_COLUMNS,
        mirror = DEFAULT_MIRROR,
        noDowncast = DEFAULT_NO_DOWNCAST,
        noSlope = DEFAULT_NO_SLOPE,
    }
end

-- The forward setback of a single grid slot at `local_index` for a resolved param set. Shared by the pose
-- loop (placed slots 0..count-1) and the segment continuation point (the un-placed slot at index = count),
-- so both use the exact same ramp. Because setback = local_index * (row_gap / columns) + offset_forward is
-- LINEAR in local_index, laying the same param set out as stacked segments (each continuing at the previous
-- segment's next slot) reproduces one continuous grid slot-for-slot along the travel axis.
local function slot_setback(local_index, p, columns, column_setback)
    local column = local_index % columns
    local row = math.floor(local_index / columns)
    return row * p.row_gap + column * column_setback + p.offset_forward
end

-- The starting frame for a grid (segment 0): the moving reference the segmented stacker threads from one
-- segment to the next. `origin` is the segment's base point and the heading pivot; `forward` is the travel
-- axis (the gate normal, else derived from base_rot); `facing` is the gate-normal-based car heading (nil
-- without a gate normal, so placement keeps the authored start quaternion); `rot` is the base quaternion for
-- that no-gate fallback. The right axis is always forward's horizontal perpendicular, so it is derived on
-- demand rather than stored.
local function make_frame(base_pos, base_rot, gate_normal)
    return {
        origin = base_pos,
        forward = resolve_forward(base_rot, gate_normal),
        facing = gate_normal and horizontal_unit(gate_normal) or nil,
        rot = base_rot,
    }
end

-- Lay `count` cars out for one param set anchored on `frame`, and return (poses, next_frame) -- the frame the
-- FOLLOWING segment starts from (a kinematic chain). `poses` is a list of { pos, rot, forward, faceDir } in
-- slot order. Within the segment: its own headingDeg rotates the layout about the frame origin (the pivot);
-- each slot is placed as right * lateral + (-forward) * setback, so offsetForward is a gap along the frame
-- forward and offsetLateral a shift along the frame right; the column stagger (row_gap / columns) spreads the
-- columns across one row's depth; mirror negates only the column-derived lateral. `next_frame` advances the
-- origin to this segment's CONTINUATION point (the seamless Round-3 forward point) plus this segment's
-- offsetLateral shift, and rotates forward/facing/rot by this segment's headingDeg -- so a rotated or
-- laterally shifted segment carries the whole tail behind it and headings compose cumulatively down the
-- chain. `params`: the ADR-0023 param set (offsets/heading/gaps + a rows-or-columns width pin; nil -> default).
local function compute_segment(frame, count, params)
    local p = resolved_params(params)
    local heading_rad = math.rad(p.heading_deg)

    -- Rotate the incoming frame axes by this segment's headingDeg about the origin (the pivot). `forward`
    -- is the layout/travel axis, `facing` the gate-normal car heading (nil without a gate normal, so
    -- placement keeps the start quaternion), `rot` the no-gate fallback quaternion -- all rotate together so
    -- the layout and the car headings stay consistent, and the rotation carries into next_frame (it chains).
    local forward = frame.forward
    local facing = frame.facing
    local rot = frame.rot
    if p.heading_deg ~= 0 then
        forward = rotate_horizontal(forward, heading_rad)
        if facing then
            facing = rotate_horizontal(facing, heading_rad)
        end
        rot = quat_mul(z_quat(heading_rad), rot)
    end
    -- Right-hand horizontal perpendicular to forward. Which column is left vs right is arbitrary.
    local right = {x = forward.y, y = -forward.x, z = 0}

    -- Columns: an explicit count (p.columns) pins the width so the grid never grows wider than asked;
    -- otherwise (rows pinned) derive the columns from the ACTUAL field size. max(count, 1) only guards the
    -- column_setback division for an empty field (the slot loop then runs zero times).
    local columns = p.columns or math.ceil(math.max(count, 1) / p.rows)
    local centre_column = (columns - 1) / 2
    -- Per-column stagger: spread the columns evenly across one row's depth (a smooth diagonal).
    local column_setback = p.row_gap / columns

    local origin = frame.origin
    -- The segment's base height: the inherited chain z lifted by this segment's anchorHeight. Applied to
    -- every pose AND to next_frame below, so the anchor carries the whole tail with it -- the same
    -- chain the lateral offset and heading rotation ride (ADR-0023 amendment). The anchor is retired
    -- (resolved_params) and therefore always 0, so this is origin.z: the pure-math z the ground pass
    -- then uses as the CHAIN SEED for the first slot and as the fallback if nothing ever grounds.
    local base_z = origin.z + p.anchor_height
    local poses = {}
    for slot = 0, count - 1 do
        local column = slot % columns
        -- Column-derived lateral spread about the centre; mirror negates it so the field swaps sides.
        -- offset_lateral is added after the flip so it stays an absolute shift along the frame right.
        local column_lateral = (column - centre_column) * p.col_gap
        if p.mirror then
            column_lateral = -column_lateral
        end
        local lateral = column_lateral + p.offset_lateral
        local setback = slot_setback(slot, p, columns, column_setback)
        poses[#poses + 1] = {
            pos = {
                x = origin.x + right.x * lateral - forward.x * setback,
                y = origin.y + right.y * lateral - forward.y * setback,
                z = base_z,
            },
            rot = {x = rot.x, y = rot.y, z = rot.z, w = rot.w},
            -- The travel axis the car should face, from the gate normal (+ chained headings); nil when no
            -- gate normal, so the placement falls back to `rot`. Shared read-only across slots.
            forward = facing,
            -- The always-present heading unit vector (the car's true facing in both the gate-normal and
            -- the fallback case) -- draw-only, used by the editor's orientation line. Distinct from
            -- `forward` above, which stays nil without a gate normal to preserve placement semantics.
            faceDir = forward,
            -- The segment's POST-grounding height lift (the offsetHeight knob, ADR-0023 amendment).
            -- Deliberately NOT part of pos.z: the frame chain and the ground-cast hint must not see it.
            -- The ground passes (spawn ground_all, editor preview) add it AFTER their surface snap, so
            -- +1 m hovers the car/pillar exactly 1 m above where it would otherwise sit.
            lift = p.offset_height,
            -- How this slot meets the ground (ADR-0023 amendment 2026-09-01), riding along exactly like
            -- `lift`: this module states them, placement.ground_all acts on them, and grid.lua stays
            -- engine-independent (ADR-0023) -- it still never casts and never learns what a surface is.
            --   castLift  -- metres the ground SEARCH starts higher. Only the window: neither the
            --               surface found nor the height handed to the next slot moves with it.
            --   noDowncast -- no drop at all; the slot keeps the inherited chain height plus `lift`.
            --   noSlope    -- no measured tilt; the slot stays flat (world up).
            castLift = p.cast_height,
            noDowncast = p.no_downcast,
            noSlope = p.no_slope,
        }
    end

    -- The continuation setback: the forward setback this segment WOULD give its next slot (local index =
    -- count). The next segment starts here, so its offsetForward = 0 continues this one seamlessly and a
    -- positive offsetForward is a pure extra gap (the Round-3 forward semantics, kept exactly). Because the
    -- ramp is linear, a same-params all-offsets-0 chain reproduces one continuous grid slot-for-slot.
    local continuation = slot_setback(count, p, columns, column_setback)
    -- Advance the frame to that continuation point for the next segment: forward by the continuation and
    -- laterally by this segment's offsetLateral (so lateral chains to the tail), carrying the heading-rotated
    -- forward/facing/rot (so heading chains cumulatively). z carries the anchorHeight-lifted base, so the
    -- anchor chains into the tail too (the post-grounding `lift` does not -- it stays per segment);
    -- per-pose grounding still happens downstream.
    local next_frame = {
        origin = {
            x = origin.x + right.x * p.offset_lateral - forward.x * continuation,
            y = origin.y + right.y * p.offset_lateral - forward.y * continuation,
            z = base_z,
        },
        forward = forward,
        facing = facing,
        rot = rot,
    }
    return poses, next_frame
end

-- Grid poses for `count` players behind base_pos/base_rot for a single param set (ADR-0023). Thin wrapper
-- over compute_segment on a one-shot start frame, kept for callers that lay out one uniform block; the
-- segmented path threads the frame across segments. Returns just the pose list (drops the next frame).
function M.poses(base_pos, base_rot, count, params, gate_normal)
    local poses = compute_segment(make_frame(base_pos, base_rot, gate_normal), count, params)
    return poses
end

-- Normalize an ordered segment list to a clean, sorted copy: nil/empty becomes a single default segment,
-- malformed entries are dropped, entries are sorted ascending by startSlot, and the base segment's
-- startSlot is forced to 0. Never mutates the input.
local function normalize_segments(segments)
    if type(segments) ~= "table" or #segments == 0 then
        return {{startSlot = 0, params = nil}}
    end
    local list = {}
    for _, seg in ipairs(segments) do
        if type(seg) == "table" then
            list[#list + 1] = {startSlot = seg.startSlot or 0, params = seg.params}
        end
    end
    if #list == 0 then
        return {{startSlot = 0, params = nil}}
    end
    table.sort(list, function(a, b)
        return a.startSlot < b.startSlot
    end)
    list[1].startSlot = 0
    return list
end

-- Grid poses for `count` players from an ORDERED SEGMENT LIST (ADR-0023 amendment): stacked parametric
-- segments laid out one behind the other as a KINEMATIC FRAME CHAIN. `segments` is `{{startSlot, params},
-- ...}` (index 1 = segment 0, its startSlot forced to 0); slots [startSlot_i, startSlot_{i+1}) use segment
-- i's params. Each segment is laid out in a running frame and hands the NEXT segment the frame at its own
-- end (compute_segment): the frame advances forward by the continuation setback (so at offsetForward = 0 a
-- segment continues the previous one seamlessly -- a same-params all-offsets-0 chain equals one continuous
-- grid slot-for-slot along the travel axis, and a positive offsetForward is a pure extra gap), shifts
-- laterally by the segment's offsetLateral (so a lateral offset carries the whole tail with it), and rotates
-- by the segment's headingDeg about its origin (so a rotated segment turns the whole tail behind it and
-- headings compose cumulatively down the chain). Per-segment mirror flips a segment's own lateral; a
-- breakpoint off a column boundary restarts that segment's columns (its lateral pattern begins fresh at
-- column 0). Every pose is tagged with its 1-based `segment` index (for the editor's active highlight). A
-- single-segment list reproduces M.poses (today's layout) bit-for-bit.
function M.poses_segmented(base_pos, base_rot, count, segments, gate_normal)
    local list = normalize_segments(segments)
    -- The running frame: starts at segment 0's anchor and is threaded from each segment to the next, so
    -- every segment stacks relative to the previous segment's end (its rotation and lateral shift included).
    local frame = make_frame(base_pos, base_rot, gate_normal)

    local all_poses = {}
    for index = 1, #list do
        local seg = list[index]
        local next_start = list[index + 1] and list[index + 1].startSlot or count
        local seg_count = math.min(next_start, count) - seg.startSlot
        if seg_count > 0 then
            local seg_poses, next_frame = compute_segment(frame, seg_count, seg.params)
            for _, pose in ipairs(seg_poses) do
                pose.segment = index
                all_poses[#all_poses + 1] = pose
            end
            frame = next_frame
        end
    end
    return all_poses
end

-- Drop the retired height anchor from a param set as it is loaded (ADR-0023 amendment 2026-09-01). Every
-- stored anchorHeight was auto-seeded against the OLD base -- one height per segment, measured to
-- re-centre a grounding window that started at the flat start-line z. The height chain
-- (placement.ground_all) now puts that window on the real surface for every slot, so the base is already
-- right and the old delta would be a second, visible offset on top of it. Idempotent by construction:
-- the field is REMOVED, so a block that has already been through here (or was saved after the
-- migration) passes through untouched. It runs in the LOAD path -- the funnel both the editor and the
-- race start pass through -- so a grid that only ever lives on the server is migrated too.
local function drop_retired_anchor(params)
    params.anchorHeight = nil
    return params
end

-- Convert a STORED per-direction block into the ordered segment list the stacker consumes. Segment 0 is
-- the block's own params (a shallow copy minus the nested `segments` array, so segment 0 carries no nested
-- list and the stored block is never mutated); the optional `block.segments` array supplies segments 1..n,
-- each `{startSlot >= 1, params}`. A nil block yields a single default segment. Backward-compatible: a
-- block with no `segments` yields exactly one segment, reproducing today's layout.
function M.block_to_segments(block)
    if type(block) ~= "table" then
        return {{startSlot = 0, params = {}}}
    end
    local base_params = drop_retired_anchor(shallow_copy(block))
    base_params.segments = nil
    local list = {{startSlot = 0, params = base_params}}
    if type(block.segments) == "table" then
        for _, seg in ipairs(block.segments) do
            if type(seg) == "table" and type(seg.params) == "table" then
                local start_slot = tonumber(seg.startSlot)
                if start_slot and start_slot >= 1 then
                    list[#list + 1] = {
                        startSlot = math.floor(start_slot),
                        params = drop_retired_anchor(shallow_copy(seg.params)),
                    }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        return a.startSlot < b.startSlot
    end)
    return list
end

-- Convert an ordered segment list back into a STORABLE per-direction block (the inverse of
-- block_to_segments), for the editor's save snapshot. Segment 0's params become the block; segments 1..n
-- become the optional `segments` array. A single-segment list yields exactly today's block (no `segments`
-- key) -- so saving a grid with no breakpoints is byte-compatible with a pre-feature save.
function M.segments_to_block(segments)
    if type(segments) ~= "table" or #segments == 0 then
        return {}
    end
    local block = shallow_copy(segments[1].params)
    block.segments = nil
    if #segments > 1 then
        local extra = {}
        for index = 2, #segments do
            extra[#extra + 1] = {
                startSlot = segments[index].startSlot,
                params = shallow_copy(segments[index].params),
            }
        end
        block.segments = extra
    end
    return block
end

return M
