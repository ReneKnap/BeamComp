-- BeamComp -- in-game start-grid editor (preview + param tuning).
--
-- Lives at lua/ge/extensions/beamcomp/race/grideditor.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Reload-safe: holds only plain tables in M.state, no engine handles, and previews with
-- immediate-mode draws (init.lua redraws each frame), so a Lua reload just drops the edit session with
-- nothing to clean up.
--
-- Authoring side of named parametric grids (ADR-0023). The admin enters edit mode against a race on the
-- current map; the editor anchors a PREVIEW_COUNT-car grid to that race's real start line (via
-- race/start.anchor) and recomputes the preview poses with race/grid as the knobs are tuned over the GE
-- console or the panel. Separate forward/reverse blocks are accumulated; reverse is only authored if the
-- admin switches to it. M.snapshot() hands the blocks -- plus the authored preview count, part of the grid
-- since the ADR-0023 amendment 2026-08-02 -- to init.lua, which ships them to the server (gridSave).
--
-- Segmented grids (ADR-0023 amendment): each direction is modelled as an ORDERED SEGMENT LIST -- segment 0
-- is the base param set, and a breakpoint at a chosen slot adds a further segment (seeded from the covering
-- segment's params) that lays out behind the previous one (grid.poses_segmented). M.state.segment is the
-- active segment the knobs edit; the breakpoint selector (M.select_segment / M.remove_segment) chooses it.
-- A fresh breakpoint auto-seeds its internal anchorHeight from the real surface at its first slot
-- (seed_segment_anchor), so splitting alone re-anchors the grounding window on climbing terrain; the
-- anchor is deliberately NOT a knob -- re-creating the breakpoint re-seeds it. The offsetHeight knob is
-- a separate POST-grounding lift applied after the preview/spawn ground snap (see recompute).
-- A grid with only segment 0 is exactly today's single-block behaviour.

local M = {}

local grid = require("beamcomp/race/grid")
-- Grounds each preview pose to terrain HEIGHT (see recompute) so the pillars follow the surface the way
-- spawned cars do. Height-only is now the REAL spawn semantics too (placement.ground_all, ADR-0034
-- amendment) -- what the admin dials in here is exactly what spawns, X/Y untouched on both sides.
local placement = require("beamcomp/race/placement")
local start = require("beamcomp/race/start")
local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.grid"

-- How big a field this grid was AUTHORED for (ADR-0023 amendment 2026-08-02). It is saved with the grid
-- and restored when the grid is opened, and it has exactly two jobs: it is the slot count the editor
-- previews, and it is the threshold above which the race start warns the admin who started the race.
-- It is NOT an input to the layout -- the layout stays count-independent (grid.poses grows the field
-- above grid.LAYOUT_CAPACITY to fill whatever count arrives), so this number never moves a spawned pose.
-- A brand-new grid starts at 16 so a large grid reads clearly while tuning, even with no players present;
-- the count is tunable (M.set_preview_count, clamped to [MIN_PREVIEW_COUNT, MAX_PREVIEW_COUNT]).
local DEFAULT_PREVIEW_COUNT = 16
local MIN_PREVIEW_COUNT = 1
local MAX_PREVIEW_COUNT = 32

-- Upper bound for a breakpoint start slot (a breakpoint beyond the previewed/spawned field just yields an
-- empty segment, so this only guards against absurd values). Segment 0 always starts at slot 0.
local MAX_BREAKPOINT_SLOT = MAX_PREVIEW_COUNT

-- Tunable knobs (camelCase, matching the stored/wire param keys) and their constraints. Offsets and
-- heading are unrestricted; gaps are non-negative; rows and columns are positive integers. rows and
-- columns are two ways to express the same width and are mutually exclusive (see M.set): pinning one axis
-- drops the other, which then becomes the dynamic axis derived from the field at spawn (grid.poses).
-- offsetHeight is the POST-grounding lift (added after the ground snap at spawn and preview). The
-- internal anchorHeight (the auto-seeded split anchor) is deliberately absent here: it has no editing
-- surface, so M.set rejects it -- re-create the breakpoint to re-seed it.
local KNOBS = {
    offsetForward = {},
    offsetLateral = {},
    offsetHeight = {},
    headingDeg = {},
    rowGap = {min = 0},
    colGap = {min = 0},
    rows = {min = 1, max = PREVIEW_COUNT, integer = true},
    columns = {min = 1, max = PREVIEW_COUNT, integer = true},
}

-- Coerce a knob value to a boolean for the `mirror` toggle (the one non-numeric knob). Accepts a real
-- boolean, a number (non-zero is on), or a string ("true"/"1"/"on" -> on) so the UI, the GE console, and
-- a hand-edited param file all settle on a genuine boolean in the stored block.
local function coerce_bool(value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        local lowered = value:lower()
        return lowered == "true" or lowered == "1" or lowered == "on"
    end
    return false
end

-- A shallow copy of a param set, so a new segment seeded from another never aliases (and thus mutates)
-- the segment it was copied from. Param values are flat (numbers + the mirror boolean), so shallow is enough.
local function copy_params(params)
    local copy = {}
    if type(params) == "table" then
        for key, value in pairs(params) do
            copy[key] = value
        end
    end
    return copy
end

-- Coerce a preview count to a usable slot count: tonumber -> floor -> clamp to [MIN, MAX], falling back
-- to DEFAULT_PREVIEW_COUNT when it is absent or unusable. THE single coercion, shared by the editing
-- surface (M.set_preview_count) and by the stored count a saved grid brings back (enter), so a
-- hand-edited grids file is exactly as safe as a typed number and the two paths cannot drift apart.
local function coerce_preview_count(count)
    local number = tonumber(count)
    -- NaN survives tonumber and every comparison below, so it has to be rejected on its own.
    if not number or number ~= number then
        return DEFAULT_PREVIEW_COUNT
    end
    return math.max(MIN_PREVIEW_COUNT, math.min(MAX_PREVIEW_COUNT, math.floor(number)))
end

-- Styling of the ground-sample blobs the preview draws on each pose's four slope-measuring points
-- (ADR-0034 amendment 2026-08-30): a flat disc, drawn as a very short cylinder because drawCylinder is
-- the draw API this project has actually proven. init.lua renders them; they live HERE, as table fields,
-- because init.lua's main chunk sits just under LuaJIT's 200-top-level-local ceiling (CLAUDE.md) and a
-- field costs none -- and because the preview these belong to is this module's.
M.SAMPLE_BLOB_RADIUS = 0.16
M.SAMPLE_BLOB_HEIGHT = 0.03

-- Editor session. active = false when not editing; everything else is meaningful only while active.
M.state = {
    active = false,
    race = nil,        -- canonical id of the race being edited; saving OWNS the grid to it (ADR-0023)
    map = nil,         -- the map it lives on (grids are keyed grids[map][race][name], ADR-0023)
    direction = "forward",  -- which direction's segment list the knobs currently edit
    blocks = nil,      -- {forward = <segment_list>, reverse = <segment_list>?}; each is {{startSlot, params}, ...}
    segment = 1,       -- 1-based index of the active segment (the one the knobs edit) in the active direction
    anchors = nil,     -- cached {forward = {base_pose, gate_normal}, reverse = ...} per direction
    poses = nil,       -- current preview poses for the active direction (drawn by init.lua)
    preview_count = DEFAULT_PREVIEW_COUNT,  -- the authored field size: previewed slots + warn threshold
}

-- The active direction's ordered segment list, or nil when not editing.
local function active_segments()
    if not M.state.active or not M.state.blocks then
        return nil
    end
    return M.state.blocks[M.state.direction]
end

-- Recompute the preview poses for the active direction from its segment list + cached anchor.
local function recompute()
    local anchor = M.state.anchors[M.state.direction]
    local segments = M.state.blocks[M.state.direction]
    -- poses_segmented stacks the segments (ADR-0023 amendment) and tags each pose with its segment index
    -- and faceDir, which init.lua reads to highlight the active segment and draw the orientation line.
    local poses = grid.poses_segmented(anchor.base_pose.pos, anchor.base_pose.rot,
        M.state.preview_count, segments, anchor.gate_normal)
    -- Ground each pose to the surface HEIGHT ONLY (placement.ground_pose): Z follows the terrain so the
    -- preview matches where cars land, with NO lateral wall-nudge -- and since the grid spawn grounds
    -- height-only too (placement.ground_all, ADR-0034 amendment), preview and spawn are the same pass.
    -- The pose's `lift` (the offsetHeight knob's POST-grounding lift) is added after the snap in the
    -- same order as the spawn pass, so a +1 m knob shows pillars hovering exactly 1 m. Copy back only
    -- what the preview needs: ground_pose returns a fresh {pos, rot, forward} table that would drop the
    -- segment tag and faceDir. These pose tables are freshly built here, so mutating them is safe.
    --
    -- `up` and `samples` come from the same call (ADR-0034 amendment 2026-08-30): the pillars lean with
    -- the measured slope, and a blob is drawn on each of the four points it was measured at. The slope is
    -- taken unclamped by design, so a corner landing on a kerb really does tip a slot hard -- the blobs
    -- are what makes that readable, and fixable by moving the slot, instead of mysterious.
    for _, pose in ipairs(poses) do
        local grounded = placement.ground_pose(pose)
        pose.pos.z = grounded.pos.z + (tonumber(pose.lift) or 0)
        pose.up = grounded.up
        pose.samples = grounded.samples
    end
    M.state.poses = poses
end

-- Auto-seed a NEW breakpoint segment's internal anchorHeight from the real surface at its first slot
-- (ADR-0023 amendment): measure the ground under the pose the pure chain puts there and set the delta
-- that lifts the segment base onto it -- the split point becomes the segment's new height zero. This is
-- what makes SPLITTING a grid re-anchor the grounding window on climbing terrain by itself. The anchor
-- is pre-grounding and internal (no knob; re-creating the breakpoint is the way to re-seed it) --
-- distinct from the offsetHeight knob's post-grounding lift. Uses the wide editor probe
-- (placement.probe_ground_z) because the motivating case is ground far above the inherited chain z,
-- outside the spawn window. Editor-only; the spawn side stays pure param application. Must be called
-- AFTER the segment (anchorHeight 0) is inserted, so the chain pose reflects the inherited height.
-- Degrade-don't-crash: any failure (no ground, engine API missing) leaves the anchor at 0, logged, and
-- never surfaces an error into the editor flow.
local function seed_segment_anchor(new_segment)
    local seeded_delta = nil
    pcall(function()
        local anchor = M.state.anchors[M.state.direction]
        -- Lay the chain out PURE (grid.poses_segmented, not the preview -- recompute overwrites z with
        -- the grounded height) far enough to include the new segment's first slot, and read the
        -- un-grounded chain pose there.
        local count = math.max(M.state.preview_count, new_segment.startSlot + 1)
        local poses = grid.poses_segmented(anchor.base_pose.pos, anchor.base_pose.rot, count,
            active_segments(), anchor.gate_normal)
        local first_pose = poses[new_segment.startSlot + 1]
        if not first_pose then
            return
        end
        local chain_z = first_pose.pos.z
        local ground = placement.probe_ground_z(first_pose.pos.x, first_pose.pos.y, chain_z)
        if not ground then
            return
        end
        -- Centimetre rounding keeps the stored value clean; the grounding window this anchor exists
        -- to re-center is metres wide, so the lost precision is irrelevant.
        seeded_delta = math.floor((ground - chain_z) * 100 + 0.5) / 100
    end)
    if seeded_delta then
        new_segment.params.anchorHeight = seeded_delta
        log("I", LOG_TAG, string.format("breakpoint at slot %d: height anchor auto-seeded to %+.2f m",
            new_segment.startSlot, seeded_delta))
    else
        log("W", LOG_TAG, string.format("breakpoint at slot %d: no ground found for the height anchor"
            .. " -- anchor stays 0 (re-create the breakpoint to retry)", new_segment.startSlot))
    end
end

-- Anchor the forward grid for `race_name_or_id` on the current map, install the given STORED blocks
-- (each is expanded into its ordered segment list) and the grid's STORED preview count, and preview. The
-- stored race is always the canonical id (start.anchor resolves it), so a later assign is keyed the same
-- way the server resolves it at race start (ADR-0023). `preview_count` is the saved authored field size
-- (ADR-0023 amendment 2026-08-02); nil -- a brand-new grid, or a record from before the field existed --
-- coerces to DEFAULT_PREVIEW_COUNT. Returns true + the canonical id, or nil + a reason. Replaces any
-- prior session.
local function enter(race_name_or_id, blocks, preview_count)
    local map = maps.current()
    if not map then
        return nil, "no map loaded"
    end

    local anchor, reason = start.anchor(race_name_or_id, "forward")
    if not anchor then
        return nil, reason
    end

    -- Expand each stored block into its segment list (block_to_segments copies the params, so editing a
    -- segment never mutates the wire payload). A block with no `segments` yields a single segment.
    local segment_blocks = {forward = grid.block_to_segments(blocks.forward)}
    if type(blocks.reverse) == "table" then
        segment_blocks.reverse = grid.block_to_segments(blocks.reverse)
    end

    M.state.active = true
    M.state.race = anchor.raceId
    M.state.map = map
    M.state.direction = "forward"
    M.state.blocks = segment_blocks
    M.state.segment = 1
    M.state.anchors = {forward = anchor}
    M.state.preview_count = coerce_preview_count(preview_count)
    recompute()
    return true, anchor.raceId
end

-- Start a fresh grid from the track's generated default layout (beamcomp_grid_new).
function M.start_fresh(race_name)
    if type(race_name) ~= "string" or race_name == "" then
        return nil, "usage: beamcomp_grid_new(\"<race>\")"
    end
    local ok, race_id = enter(race_name, {forward = grid.default_params()})
    if ok then
        log("I", LOG_TAG, "editing new grid for '" .. race_id .. "'")
    end
    return ok, race_id
end

-- Open a saved grid for further editing (beamcomp_grid_edit, once the server returns its data). A grid's
-- params are RELATIVE to a start line (ADR-0023), so `anchor_race` re-targets them onto a chosen race's
-- start line -- loading a grid authored for race A onto race B previews B's start as the new origin. Absent
-- an override, falls back to the race the grid was authored against (record.race). A loaded reverse block
-- is preserved (set_direction won't overwrite it). The record's authored preview count is restored too
-- (ADR-0023 amendment 2026-08-02) -- coerced, so a hand-edited or missing one degrades to the default
-- rather than breaking the session. Returns true + the canonical id, or nil + a reason.
function M.open(record, anchor_race)
    if type(record) ~= "table" or type(record.forward) ~= "table" or type(record.race) ~= "string" then
        return nil, "saved grid is missing its race or params"
    end
    local blocks = {forward = record.forward}
    if type(record.reverse) == "table" then
        blocks.reverse = record.reverse
    end
    local target = (type(anchor_race) == "string" and anchor_race ~= "") and anchor_race or record.race
    local ok, race_id = enter(target, blocks, record.previewCount)
    if ok then
        log("I", LOG_TAG, "editing saved grid for '" .. race_id .. "'")
    end
    return ok, race_id
end

-- Switch the knobs to the forward or reverse block. Reverse anchors to the reversed start line lazily;
-- it seeds a default reverse block only if one was not already loaded/edited, so an opened grid's saved
-- reverse params survive the switch. A race with no reverse geometry returns nil + a reason.
function M.set_direction(direction)
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
    end
    if direction ~= "forward" and direction ~= "reverse" then
        return nil, "direction must be 'forward' or 'reverse'"
    end

    if direction == "reverse" and not M.state.anchors.reverse then
        local anchor, reason = start.anchor(M.state.race, "reverse")
        if not anchor then
            return nil, reason
        end
        M.state.anchors.reverse = anchor
    end
    if direction == "reverse" and not M.state.blocks.reverse then
        M.state.blocks.reverse = grid.block_to_segments(grid.default_params())
    end

    M.state.direction = direction
    -- The two directions can have different segment counts; keep the active index in range for the one
    -- we just switched to (falling back to the base segment).
    M.state.segment = math.max(1, math.min(M.state.segment, #M.state.blocks[direction]))
    recompute()
    return true
end

-- Set one knob on the ACTIVE SEGMENT's params and re-preview. `knob` is a camelCase param name. The
-- numeric knobs coerce `value` to a number, clamped per the knob's constraints; the boolean `mirror`
-- knob is special-cased (stored as a genuine true/false). Returns true + the applied value, or nil + a
-- reason (not editing, unknown knob, non-numeric value).
function M.set(knob, value)
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
    end
    -- The knobs edit the ACTIVE segment's params (segment 0 by default; a breakpoint selection makes a
    -- later segment active). This is the same block shape as before -- just per segment now.
    local block = active_segments()[M.state.segment].params
    -- Mirror is the one boolean toggle, not a clamped number: coerce and store it before the numeric path.
    if knob == "mirror" then
        local on = coerce_bool(value)
        block.mirror = on
        recompute()
        return true, on
    end
    local constraint = KNOBS[knob]
    if not constraint then
        return nil, "unknown knob '" .. tostring(knob) .. "'"
    end
    local number = tonumber(value)
    if not number then
        return nil, "value must be a number"
    end

    if constraint.integer then
        number = math.floor(number)
    end
    if constraint.min and number < constraint.min then
        number = constraint.min
    end
    if constraint.max and number > constraint.max then
        number = constraint.max
    end

    block[knob] = number
    -- rows and columns are mutually exclusive width pins (last set wins): pinning one axis drops the other
    -- so it becomes the dynamic axis (grid.poses derives it from the field). Symmetric in both directions.
    if knob == "rows" then
        block.columns = nil
    elseif knob == "columns" then
        block.rows = nil
    end
    recompute()
    return true, number
end

-- Select (or create) the segment that starts at `start_slot`, making it the active one the knobs edit
-- (ADR-0023 amendment). Slot 0 (or below) is always the base segment. If a segment already starts at the
-- slot it is activated; otherwise a new segment is created, SEEDED from the params of the segment that
-- currently covers the slot (a copy you then tune, with every CHAINING field zeroed -- see the seed
-- block below), inserted in slot order, and its internal anchorHeight auto-seeded from the ground at
-- its first slot (seed_segment_anchor -- creation only, a re-select never re-seeds). Returns true +
-- the applied start slot, or nil + a reason.
function M.select_segment(start_slot)
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
    end
    local number = tonumber(start_slot)
    if not number then
        return nil, "value must be a number"
    end
    number = math.floor(number)

    local segments = active_segments()
    if number <= 0 then
        M.state.segment = 1
        recompute()
        return true, 0
    end
    number = math.min(number, MAX_BREAKPOINT_SLOT)

    -- Already a breakpoint here? Just make it active.
    for index, seg in ipairs(segments) do
        if seg.startSlot == number then
            M.state.segment = index
            recompute()
            return true, number
        end
    end

    -- Otherwise insert a new segment after the one covering the slot (the last with a smaller startSlot).
    local prev_index = 1
    for index, seg in ipairs(segments) do
        if seg.startSlot < number then
            prev_index = index
        end
    end
    -- Seed a fresh breakpoint from the covering segment, then zero every field that CHAINS. That one
    -- rule decides this whole block. A chaining value is ALREADY baked into the frame this segment
    -- starts from -- compute_segment hands the next segment its shifted, rotated and lifted frame
    -- (grid.lua) -- so copying it would apply it a SECOND time.
    --   Zeroed, because they chain:
    --     * offsetForward / offsetLateral, so the segment CONTINUES the previous one seamlessly out of
    --       the box: offsetForward is then a pure additional gap the admin dials in (0 = seamless).
    --     * headingDeg, so the tail keeps the direction it already points in. Inheriting it turned the
    --       whole tail by the covering segment's angle a second time, with the knob reading a value the
    --       admin never dialled in (bug grideditor-breakpoint-label-and-heading-reset).
    --     * the internal anchorHeight, which is then auto-seeded from the real surface below.
    --   Inherited, because they do NOT chain: columns/rows/rowGap/colGap/mirror, so a split never
    --   reshapes the field, and the offsetHeight LIFT, so it never visibly moves it either.
    -- Only breakpoint segments are zeroed here; segment 0 keeps its own offsetForward (the setback from
    -- the line) and its own heading.
    local seeded = copy_params(segments[prev_index].params)
    seeded.offsetForward = 0
    seeded.offsetLateral = 0
    seeded.headingDeg = 0
    seeded.anchorHeight = 0
    local new_segment = {startSlot = number, params = seeded}
    table.insert(segments, prev_index + 1, new_segment)
    M.state.segment = prev_index + 1
    seed_segment_anchor(new_segment)
    recompute()
    return true, number
end

-- Remove the active breakpoint, merging its slots back into the previous segment (ADR-0023 amendment).
-- The base segment (index 1, slot 0) cannot be removed. On success the previous segment becomes active.
-- Returns true, or nil + a reason.
function M.remove_segment()
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
    end
    if M.state.segment <= 1 then
        return nil, "cannot remove the base segment"
    end
    local segments = active_segments()
    table.remove(segments, M.state.segment)
    M.state.segment = M.state.segment - 1
    recompute()
    return true
end

-- The active segment's 1-based index (for init.lua's preview highlight). 1 when not editing.
function M.active_segment()
    return M.state.segment
end

-- The active segment's param set (the block the knobs edit), or nil when not editing. Lets init.lua
-- reflect the authoritative knob values without reaching into the segment-list shape.
function M.active_params()
    local segments = active_segments()
    local seg = segments and segments[M.state.segment]
    return seg and seg.params or nil
end

-- The layout defaults a knob falls back to when its param is absent, for the panel's placeholder hint:
-- an empty knob field then reads "0 (default)" instead of a bare "-". A stored block only omits a knob
-- when it predates that knob (offsetHeight on an older saved grid) or when a breakpoint inherited such a
-- block -- grid.resolved_params fills exactly these values at spawn, so this is the number that actually
-- applies. Straight from race/grid so the panel carries no second copy of the constants. `rows` is
-- deliberately absent (it is the derived axis and reads "auto"), `mirror` has no number field.
function M.knob_defaults()
    return grid.default_params()
end

-- The active direction's segment boundaries as a light list {{startSlot = N}, ...} (for the panel's
-- breakpoint read-out). Empty when not editing; never leaks the internal param tables.
function M.segment_bounds()
    local segments = active_segments()
    if not segments then
        return {}
    end
    local bounds = {}
    for _, seg in ipairs(segments) do
        bounds[#bounds + 1] = {startSlot = seg.startSlot}
    end
    return bounds
end

-- Set the authored field size: how many grid slots the preview shows, and (once saved) the size above
-- which the race start warns the issuer. It never feeds the layout -- that stays count-independent
-- (ADR-0023). `count` is coerced to an integer and clamped to [MIN, MAX]. Returns true + the applied
-- value, or nil + a reason when not editing / non-numeric.
function M.set_preview_count(count)
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
    end
    -- A non-numeric value is REJECTED here rather than defaulted: this is the typed surface (the GE
    -- console and the panel), where the caller wants to hear about a typo. Only the stored path defaults.
    if not tonumber(count) then
        return nil, "value must be a number"
    end
    local number = coerce_preview_count(count)
    M.state.preview_count = number
    recompute()
    return true, number
end

-- The current authored field size (previewed slots + the start's warn threshold).
function M.preview_count()
    return M.state.preview_count
end

-- The reference scene for the active direction, for the caller (init.lua) to spawn/draw alongside the
-- preview: {prefabFiles = {...}, checkpoint = {pos, normal, radius}|nil}. The anchor for each direction
-- already carries these (start.anchor), so switching direction switches the scene too. Nil when not editing.
function M.current_scene()
    if not M.state.active then
        return nil
    end
    local anchor = M.state.anchors[M.state.direction]
    if not anchor then
        return nil
    end
    return {prefabFiles = anchor.prefabFiles, checkpoint = anchor.checkpoint}
end

-- The current edit as a save payload: the map, the anchored race (which OWNS the saved grid -- re-anchoring
-- a loaded grid and saving it moves it to that race, ADR-0023 amendment 2026-07-27), the authored blocks
-- (reverse only if it was edited) and the authored field size. `name` is supplied by the caller (the save
-- command). Nil when not editing.
function M.snapshot(name)
    if not M.state.active then
        return nil
    end
    -- Collapse each direction's segment list back into a storable block (segments_to_block emits no
    -- `segments` key for a single-segment grid, so a no-breakpoint grid saves exactly as it did before).
    return {
        map = M.state.map,
        name = name,
        race = M.state.race,
        forward = grid.segments_to_block(M.state.blocks.forward),
        reverse = M.state.blocks.reverse and grid.segments_to_block(M.state.blocks.reverse) or nil,
        -- ONE number per grid, at the record's TOP LEVEL -- deliberately not inside forward/reverse
        -- (ADR-0023 amendment 2026-08-02). Those are param sets: they flow through block_to_segments
        -- into M.set, which rejects unknown knobs, so a previewCount in there would be a layout param,
        -- which is exactly what this must never become. The editor's count is session-level (switching
        -- direction keeps it), and one number per record is the faithful mirror of that.
        previewCount = M.state.preview_count,
    }
end

-- Leave edit mode. Immediate-mode preview stops as soon as active is false -- nothing to despawn.
function M.clear()
    M.state.active = false
    M.state.race = nil
    M.state.map = nil
    M.state.direction = "forward"
    M.state.blocks = nil
    M.state.segment = 1
    M.state.anchors = nil
    M.state.poses = nil
    M.state.preview_count = DEFAULT_PREVIEW_COUNT
end

return M
