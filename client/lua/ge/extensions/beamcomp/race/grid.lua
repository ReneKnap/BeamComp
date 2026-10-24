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
-- Longitudinal axis: the grid's forward direction (the way the field drives off the line) is ONE
-- answer, M.travel_axis (ADR-0023 amendment 2026-10-24): the start/finish gate normal callers pass (the
-- direction of travel through CP0), else -- a start line with no usable normal -- the start pose's own
-- rotation, read the way BeamNG reads it. The field is laid out behind that axis and every car faces
-- along it: each pose carries it as `forward`, so the placement orients the car with quatFromDir and the
-- measured slope whichever source answered. The headingDeg param rotates the whole grid (positions + car
-- headings) about vertical on top of that, layout and cars by the same angle in the same sense.
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
-- (race/grideditor.lua). A copy is precisely what broke: the editor's own KNOBS table named a constant no
-- file in this mod defines, its `max` therefore read nil, and the rows/columns knobs went unbounded.
--
-- The server mirrors it as grid_fit.AXIS_CAPACITY for the ADR-0051 slot reservation, which has to
-- reproduce this side's column count exactly. The two move together, or the reservation punches its
-- holes into a grid that nobody lays out.
--
-- 32 is a generous bound, not a physical one: at the default 4 m column gap a 32-wide grid is 124 m
-- across and the per-column stagger (row_gap / columns) shrinks to 0.25 m. That is absurd on most tracks
-- and it is still the admin's call -- the editor previews the field he asked for. The bound exists so an
-- absurd number cannot pass itself off as a reasonable one, not to decide what fits on a road.
local MAX_AXIS_PIN = 32
M.MAX_AXIS_PIN = MAX_AXIS_PIN

-- The rows a param set falls back to when it pins NEITHER axis. Deliberately a plain number and NOT
-- derived from MAX_AXIS_PIN: this is a DEFAULT, not a clamp, and for as long as it was spelled
-- ceil(CAPACITY / DEFAULT_COLUMNS) every move of the cap silently dragged the default along with it.
-- The value is unobservable today -- resolved_params leaves `columns` nil only when `rows` is explicitly
-- pinned, and that pinned number is the only p.rows compute_segment ever divides by -- so its one job is
-- to keep the resolved `rows` a usable number instead of nil.
local DEFAULT_ROWS = 4

-- The way a start rotation drives off, in that rotation's own frame: +Y. BeamNG puts a race car on a
-- start pose as quat(0,0,1,0) * rot (gameplay/race/startPosition.lua; vehicles.lua places our cars the
-- same way) and a car's nose is its local -Y, so the flip turns the nose onto +Y and `rot` carries that
-- out into the world. Authored start rotations follow it: their +Y lies along CP0's gate normal on 306 of
-- the 325 shipped races that have one, median 1.3 degrees (measured 2026-10-24, the engine's own maths).
local START_ROT_TRAVEL = {x = 0, y = 1, z = 0}

-- The axis of last resort, for a start line with no usable gate normal whose start rotation points its +Y
-- straight up or down: nothing names a horizontal direction, so the field lies along world X and its
-- cars face along it too. No shipped race comes near it; start.lua logs it as a W line.
local WORLD_X = {x = 1, y = 0, z = 0}

local EPSILON = 1e-6

-- Rotate a plain {x, y, z} vector by a plain {x, y, z, w} quaternion THE WAY THE ENGINE DOES. BeamNG's
-- `q * v` (lua/common/mathlib.lua, LuaQuat.__mul) applies the CONJUGATE of the textbook rotation:
--   t = 2 (q x v),  v' = v - w t + q x t        (the textbook rotation is v + w t + q x t)
-- i.e. it turns by the opposite angle. Transcribed term for term from LuaQuat.__mul, so it agrees with
-- `quat(...) * vec3(...)` to the last bit and this module stays engine-free (ADR-0023). Read the textbook
-- way, a start rotation comes out mirrored across world X -- heading h becomes -h -- which is what this
-- module's no-gate-normal fallback did until 2026-10-24: the field lay along the mirror image while the
-- cars, placed by the engine, faced the right way (bug utah-crawls-grid-helpers-and-heading).
local function engine_rotate(q, v)
    local tx = 2 * (q.y * v.z - q.z * v.y)
    local ty = 2 * (q.z * v.x - q.x * v.z)
    local tz = 2 * (q.x * v.y - q.y * v.x)
    return {
        x = v.x - q.w * tx + (q.y * tz - q.z * ty),
        y = v.y - q.w * ty + (q.z * tx - q.x * tz),
        z = v.z - q.w * tz + (q.x * ty - q.y * tx),
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

-- (public) The direction the grid is laid out along and its cars face, as a horizontal unit {x, y, z},
-- plus which source answered: "gate normal" or "start rotation". nil, nil when neither names a horizontal
-- direction. THE one answer to that question (ADR-0023 amendment 2026-10-24): make_frame lays every grid
-- out with it, so the race start and the grid editor's preview take the same direction, and race/start.lua
-- asks it again only to say in the log which source answered and to measure a reverse start's setback.
--
--   gate normal    -- CP0's normal, flattened, whenever it has a horizontal component: the direction of
--                     travel through the start line, the cleanest source there is.
--   start rotation -- `base_rot`'s +Y as the engine turns it (engine_rotate), flattened: where the
--                     engine points a car placed on that pose. Three shipped races need it, the Utah
--                     crawls 006-Leap, 007-Dried and 008-Around; their start headings lie 6 to 12 degrees
--                     off CP0 -> CP1. Its pitch and roll are dropped -- the placement measures the slope.
--
-- Plain tables in and out; `base_rot` may be nil when the caller has a gate normal.
function M.travel_axis(base_rot, gate_normal)
    local axis = gate_normal and horizontal_unit(gate_normal)
    if axis then
        return axis, "gate normal"
    end
    axis = base_rot and horizontal_unit(engine_rotate(base_rot, START_ROT_TRAVEL))
    if axis then
        return axis, "start rotation"
    end
    return nil, nil
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
-- segment to the next. `origin` is the segment's base point and the heading pivot; `forward` is the layout
-- axis and `facing` the way the cars face, BOTH M.travel_axis's answer (two equal tables, never shared, so
-- no pose can alias the other's); `rot` is the start quaternion, carried along on every pose and not read
-- for the orientation, since every pose has a `facing` now. The right axis is always forward's horizontal
-- perpendicular, so it is derived on demand rather than stored.
--
-- Until 2026-10-24 a start line without a gate normal left `facing` nil, and with it every pose's
-- `forward`: no slope was measured, no sample discs were drawn, and the car kept the start quaternion while
-- the layout took a mirrored copy of it. That case is now a gate normal like any other.
local function make_frame(base_pos, base_rot, gate_normal)
    local axis = M.travel_axis(base_rot, gate_normal) or WORLD_X
    return {
        origin = base_pos,
        forward = {x = axis.x, y = axis.y, z = axis.z},
        facing = {x = axis.x, y = axis.y, z = axis.z},
        rot = base_rot,
    }
end

-- Lay `count` cars out for one param set anchored on `frame`, and return (poses, next_frame, layout) -- the
-- frame the FOLLOWING segment starts from (a kinematic chain), and the frame this one was laid out in.
-- `poses` is a list of { pos, rot, forward, faceDir } in slot order.
-- Within the segment: its own headingDeg rotates the layout about the frame origin (the pivot);
-- each slot is placed as right * lateral + (-forward) * setback, so offsetForward is a gap along the frame
-- forward and offsetLateral a shift along the frame right; the column stagger (row_gap / columns) spreads the
-- columns across one row's depth; mirror negates only the column-derived lateral. `next_frame` advances the
-- origin to this segment's CONTINUATION point (the seamless Round-3 forward point) plus this segment's
-- offsetLateral shift, and rotates forward/facing/rot by this segment's headingDeg -- so a rotated or
-- laterally shifted segment carries the whole tail behind it and headings compose cumulatively down the
-- chain. `params`: the ADR-0023 param set (offsets/heading/gaps + a rows-or-columns width pin; nil -> default).
--
-- `layout` hands out what this function computes anyway and changes none of it (ADR-0023 amendment
-- 2026-10-16): the pivot `origin`, the `frame_forward` the segment received, its own heading-rotated
-- `forward` and `right`, and the resolved `columns`. The grid editor draws its part boundaries and its plan
-- from them; the poses and next_frame are exactly what they were. The tables are shared, so read-only.
local function compute_segment(frame, count, params)
    local p = resolved_params(params)
    local heading_rad = math.rad(p.heading_deg)

    -- Rotate the incoming frame axes by this segment's headingDeg about the origin (the pivot). `forward`
    -- is the layout/travel axis and `facing` the way the cars face: the same direction, turned by the same
    -- rotate_horizontal, so a turned grid turns its field and its cars by the same angle in the same sense.
    -- The rotation carries into next_frame (it chains).
    --
    -- `rot` is composed too, as z_quat * rot, and that is a TEXTBOOK composition: under the engine's
    -- convention (engine_rotate) it turns a car by -headingDeg, the opposite way. It is kept exactly as it
    -- always was so a pose's `rot` field stays bit-identical, and it is harmless only because nothing
    -- orients a car by it any more -- every pose carries `forward`. Do not start reading it again.
    local forward = frame.forward
    local facing = frame.facing
    local rot = frame.rot
    if p.heading_deg ~= 0 then
        forward = rotate_horizontal(forward, heading_rad)
        facing = rotate_horizontal(facing, heading_rad)
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
            -- The travel axis the car faces (M.travel_axis + the chained headings): vehicles.lua orients the
            -- car along it with quatFromDir and the measured slope, and placement.ground_all measures the
            -- slope only when it is there. Shared read-only across slots.
            forward = facing,
            -- The layout axis the slot was placed along -- draw-only, the editor's orientation line and the
            -- grid camera read it. Equal to `forward` by construction (both start as M.travel_axis and turn
            -- together); a separate table so a reader of one can never mutate the other.
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
    local layout = {
        origin = origin,
        frame_forward = frame.forward,
        forward = forward,
        right = right,
        columns = columns,
    }
    return poses, next_frame, layout
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
--
-- Returns (poses, layouts): `layouts` lists, in slot order, every segment that laid out at least one pose
-- as compute_segment's layout plus its `segment` index, `startSlot` and pose `count`. A segment that starts
-- at or past `count` has no poses and no entry.
local function stack_segments(base_pos, base_rot, count, segments, gate_normal)
    local list = normalize_segments(segments)
    -- The running frame: starts at segment 0's anchor and is threaded from each segment to the next, so
    -- every segment stacks relative to the previous segment's end (its rotation and lateral shift included).
    local frame = make_frame(base_pos, base_rot, gate_normal)

    local all_poses = {}
    local layouts = {}
    for index = 1, #list do
        local seg = list[index]
        local next_start = list[index + 1] and list[index + 1].startSlot or count
        local seg_count = math.min(next_start, count) - seg.startSlot
        if seg_count > 0 then
            local seg_poses, next_frame, layout = compute_segment(frame, seg_count, seg.params)
            for _, pose in ipairs(seg_poses) do
                pose.segment = index
                all_poses[#all_poses + 1] = pose
            end
            layout.segment = index
            layout.startSlot = seg.startSlot
            layout.count = seg_count
            layouts[#layouts + 1] = layout
            frame = next_frame
        end
    end
    return all_poses, layouts
end

-- The pose list alone, for the race start. Deliberately ONE return value: start.lua calls this in the last
-- argument position of placement.ground_all, where a second return would be passed on as an argument.
function M.poses_segmented(base_pos, base_rot, count, segments, gate_normal)
    local poses = stack_segments(base_pos, base_rot, count, segments, gate_normal)
    return poses
end

-- The same poses plus the frame every segment was laid out in (see stack_segments), for the grid editor's
-- part boundaries and plan (ADR-0023 amendment 2026-10-16). Same function underneath, so the editor can
-- never draw a line for a layout the spawn does not produce.
function M.poses_segmented_with_frames(base_pos, base_rot, count, segments, gate_normal)
    return stack_segments(base_pos, base_rot, count, segments, gate_normal)
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
