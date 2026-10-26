-- BeamComp -- in-game start-grid editor (preview + param tuning).
--
-- Lives at lua/ge/extensions/beamcomp/race/grideditor.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Reload-safe: holds only plain tables in M.state, no engine handles, and previews with
-- immediate-mode draws (init.lua redraws each frame), so a Lua reload just drops the edit session with
-- nothing to clean up. The camera that follows a session is NOT kept here: it is the one part of an edit
-- that does have something to put back, so it lives in race/gridcam.lua (ADR-0063). That module reads
-- M.state (the session counter, the direction, slot 1) and never writes it.
--
-- Authoring side of named parametric grids (ADR-0023). The admin enters edit mode against a race on the
-- current map; the editor anchors a preview-count-sized grid to that race's real start line (via
-- race/start.anchor) and recomputes the preview poses with race/grid as the knobs are tuned over the GE
-- console or the panel. Separate forward/reverse blocks are accumulated; reverse is only authored once the
-- session switches to it -- the admin's Reverse, or a panel session start that follows the direction the
-- race setup carried (init.lua setup.apply_carried_direction). M.snapshot() hands the blocks -- plus the
-- authored preview count, part of the grid since the ADR-0023 amendment 2026-08-02 -- to init.lua, which
-- ships them to the server (gridSave).
--
-- Segmented grids (ADR-0023 amendment): each direction is modelled as an ORDERED SEGMENT LIST -- segment 0
-- is the base param set, and a breakpoint at a chosen slot adds a further segment (seeded from the covering
-- segment's params) that lays out behind the previous one (grid.poses_segmented). M.state.segment is the
-- active segment the knobs edit; the breakpoint selector (M.select_segment / M.remove_segment) chooses it.
-- A fresh breakpoint starts at 0 and changes nothing until the admin dials something in: the height anchor
-- it used to auto-seed existed only to re-centre the grounding window at a segment boundary, and the
-- height CHAIN (placement.ground_all, ADR-0034 amendment 2026-09-01) now does that continuously, per slot.
-- A grid with only segment 0 is exactly today's single-block behaviour.
--
-- The admin reads segments as PARTS (ADR-0023 amendment 2026-10-16): every part has its own color, a line
-- across the field marks where each begins, and the panel draws the field as a plan. All three come out
-- of recompute() (see project) and M.plan(), from the very layout grid.lua hands the spawn, so the panel
-- never re-derives a pose and the plan and the 3D preview cannot disagree.

local M = {}

local grid = require("beamcomp/race/grid")
-- Grounds the preview poses through placement.ground_all (see recompute) -- literally the call the real
-- spawn makes, chain and all -- so what the admin dials in here is exactly what spawns, X/Y untouched
-- on both sides.
local placement = require("beamcomp/race/placement")
local start = require("beamcomp/race/start")
local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.grid"

-- How big a field this grid was AUTHORED for (ADR-0023 amendment 2026-08-02). It is saved with the grid
-- and restored when the grid is opened, and it has exactly two jobs: it is the slot count the editor
-- previews, and it is the threshold above which the race start warns the admin who started the race.
-- It is NOT an input to the layout -- the layout stays count-independent (grid.poses lays out whatever
-- count arrives, however far past the previewed field that is), so this number never moves a spawned pose.
-- A brand-new grid starts at 16 so a large grid reads clearly while tuning, even with no players present;
-- the count is tunable (M.set_preview_count, clamped to [MIN_PREVIEW_COUNT, MAX_PREVIEW_COUNT]).
local DEFAULT_PREVIEW_COUNT = 16
local MIN_PREVIEW_COUNT = 1
local MAX_PREVIEW_COUNT = 32

-- Upper bound for a breakpoint start slot (a breakpoint beyond the previewed/spawned field just yields an
-- empty segment, so this only guards against absurd values). Segment 0 always starts at slot 0.
local MAX_BREAKPOINT_SLOT = MAX_PREVIEW_COUNT

-- Upper bound for the rows/columns knobs, READ from the spawn maths rather than written down again here:
-- race/grid.lua clamps a stored pin to the same number, and an editor bound that disagrees with it is a
-- field that lies about what will spawn. The previous copy was written down here, as `max = PREVIEW_COUNT`
-- -- a name no file in this mod defines. It read nil, M.set's `if constraint.max` branch never fired, and
-- rows/columns took whatever an admin typed (bug grideditor-knobs-missing-upper-clamp). Nothing about that
-- is visible from the panel, so the one way this can break again is called out loud instead.
local MAX_AXIS_PIN = grid.MAX_AXIS_PIN
if type(MAX_AXIS_PIN) ~= "number" then
    -- No second copy of the number as a fallback: a bound the spawn does not share is the same lie in a
    -- different place. What was missing the first time round was the noise, so that is what is added.
    log("E", LOG_TAG, "grid.MAX_AXIS_PIN is missing -- the rows/columns knobs have no upper clamp")
end

-- Tunable knobs (camelCase, matching the stored/wire param keys) and their constraints. Offsets and
-- heading are unrestricted; gaps are non-negative; rows and columns are integers in [1, MAX_AXIS_PIN].
-- rows and columns are two ways to express the same width and are mutually exclusive (see M.set): pinning
-- one axis drops the other, which then becomes the dynamic axis derived from the field at spawn
-- (grid.poses). offsetHeight is the POST-grounding lift and castHeight the pre-grounding SEARCH-WINDOW
-- shift (ADR-0023 amendment 2026-09-01), both unrestricted. The internal anchorHeight is deliberately
-- absent here: it has no editing surface and no writer left (see M.select_segment), so M.set rejects it.
local KNOBS = {
    offsetForward = {},
    offsetLateral = {},
    offsetHeight = {},
    castHeight = {},
    headingDeg = {},
    rowGap = {min = 0},
    colGap = {min = 0},
    rows = {min = 1, max = MAX_AXIS_PIN, integer = true},
    columns = {min = 1, max = MAX_AXIS_PIN, integer = true},
}

-- The knobs that are switches, not numbers: the lateral flip and the two placement switches of the
-- ADR-0023 amendment 2026-09-01. They take the coerce_bool path in M.set instead of the clamped numeric
-- one, so what lands in the stored block is a genuine true/false (grid.lua reads all three as `== true`,
-- where a 0 would misfire -- 0 is truthy in Lua).
local BOOLEAN_KNOBS = {
    mirror = true,
    noDowncast = true,
    noSlope = true,
}

-- Coerce a knob value to a boolean for the switch knobs. Accepts a real boolean, a number (non-zero is
-- on), or a string ("true"/"1"/"on" -> on) so the UI, the GE console, and a hand-edited param file all
-- settle on a genuine boolean in the stored block.
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

-- The preview's route: every checkpoint after CP1 is drawn grey (CP0 keeps the red start-line style, CP1
-- the yellow look-ahead the race itself uses, both in init.lua). The area fill is dimmed well below the
-- other two, because a long route stacks dozens of these columns over the grid being edited. A field
-- here for the same reason as the blobs above: init.lua sits at the 200-local ceiling.
M.ROUTE_CHECKPOINT_STYLE = {
    area = {r = 0.6, g = 0.62, b = 0.66, a = 0.04},
    post = {r = 0.62, g = 0.64, b = 0.68, a = 0.7},
}

-- The gate-line angle init.lua's draw_checkpoint_marker takes for one checkpoint of the preview's route,
-- or nil. The colour of CP0 (red) and CP1 (yellow) is in their two POSTS, and without a line angle a
-- marker draws its posts from its gate normal -- so a checkpoint with no normal showed only the pale
-- column, the same tint for every role (bug utah-crawls-grid-helpers-and-heading). Such a checkpoint
-- carries the route's `tangent` (start.anchor), and this turns it into the angle that stands the posts
-- square to the route: the same convention as init.lua's gate_line_angle, atan2(-x, y) of the direction
-- the gate faces, so the posts land exactly where gate_edges would put them for a normal along the route.
-- nil for a checkpoint with a normal (it draws from that, unchanged) or without a tangent (no posts, as
-- before). A field here, not a helper in init.lua, because init.lua sits at the 200-local ceiling.
function M.route_post_angle(checkpoint)
    local tangent = checkpoint.tangent
    if not tangent then
        return nil
    end
    return math.atan2(-tangent.x, tangent.y)
end

-- ---- Parts: their colors, the line where each begins, and the panel's plan ---------------------------
-- (ADR-0023 amendment 2026-10-16.) init.lua draws the pillars and the lines with these, and the panel gets
-- the colors it draws with from M.plan(), so the plan and the 3D preview cannot disagree on a color.
--
-- Every part has its own color, wrapping after the last entry; neighbouring parts never share one. Part 1
-- keeps the cyan the preview has always had. Picked against tarmac, grass, sand and dirt for both the
-- bright and the muted rule below (a CIEDE2000 estimate, feature grid-editor-breakpoint-lines).
M.PART_PALETTE = {
    {r = 0.35, g = 0.95, b = 1.0},  -- cyan
    {r = 0.6, g = 1.0, b = 0.3},    -- lime
    {r = 0.3, g = 0.45, b = 1.0},   -- blue
}

-- The part being edited is drawn bright, every other part muted, each in its own color.
M.PART_BRIGHT = {scale = 1.0, alpha = 0.95}
M.PART_MUTED = {scale = 0.65, alpha = 0.7}

-- The line across the field where a part begins: one color for every such line, magenta because it must
-- read against the cyan pillars, the red orientation lines and the yellow sample blobs alike (red, the
-- color of the owner's sketch, would be taken for an orientation line). Carried on every boundary of the
-- plan too, so the panel draws a boundary in the color GE gives it.
M.BOUNDARY_COLOR = {r = 1.0, g = 0.2, b = 0.9, a = 0.95}
M.BOUNDARY_LINE_RADIUS = 0.08
-- How far above the line's end its "Part <n> from P<m>" label floats (m).
M.BOUNDARY_LABEL_HEIGHT = 0.6

-- How far the line reaches past the outermost car on either side (m): half a car's width plus room.
local BOUNDARY_SIDE_MARGIN = 1.5
-- The line is grounded at a point every BOUNDARY_SAMPLE_STEP metres (in at most BOUNDARY_MAX_SAMPLES
-- pieces), so it follows a crowned road or a kerb instead of cutting through it.
local BOUNDARY_SAMPLE_STEP = 1.0
local BOUNDARY_MAX_SAMPLES = 24
-- How far above the measured surface the line lies (m): on the ground, never in it.
local BOUNDARY_LINE_LIFT = 0.1

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
    -- The preview projected for the panel ({poses, boundaries, start}, plan metres) and the grounded 3D
    -- lines where each part begins ({points, label, label_pos} each, drawn by init.lua). Both rebuilt by
    -- every recompute, so neither needs its own previous value (ADR-0052).
    plan = nil,
    boundary_lines = nil,
    preview_count = DEFAULT_PREVIEW_COUNT,  -- the authored field size: previewed slots + warn threshold
    -- Bumped by every session start (enter, under both start_fresh and open) and never reset, not even
    -- by clear: race/gridcam.lua watches it to jump the camera on EVERY session start, whoever started it.
    session = 0,
}

-- The active direction's ordered segment list, or nil when not editing.
local function active_segments()
    if not M.state.active or not M.state.blocks then
        return nil
    end
    return M.state.blocks[M.state.direction]
end

-- The color part `part` is drawn in, {r, g, b, a}: its palette entry, wrapping, under the bright or the
-- muted rule. The one place that rule is applied.
function M.part_color(part, is_bright)
    local index = math.max(1, math.floor(tonumber(part) or 1))
    local base = M.PART_PALETTE[(index - 1) % #M.PART_PALETTE + 1]
    local rule = is_bright and M.PART_BRIGHT or M.PART_MUTED
    return {r = base.r * rule.scale, g = base.g * rule.scale, b = base.b * rule.scale, a = rule.alpha}
end

-- `value` rounded to 1 / `per_unit`. The plan is rounded to the centimetre and its facings to a
-- thousandth: plenty for a drawing, and it keeps the push small.
local function rounded(value, per_unit)
    return math.floor(value * per_unit + 0.5) / per_unit
end

-- The plan's frame: the one part 1 is laid out in, AFTER its own Rotate grid (ADR-0023 amendment
-- 2026-10-23) -- origin on the start pose (part 1's pivot), axes part 1's own. So part 1's rows are always
-- level, P1 on the left and its cars facing left, and only a later part that turns against part 1 shows
-- as a bend. Part 1's shift and mirror act on the positions inside this frame as they do in the world;
-- they do not move or flip the frame, which would turn the top view into a mirror image.
--
-- Round 1 used the frame BEFORE part 1's heading, the start line's own. A grid turned 196 degrees to fit
-- its track then lay diagonally across the strip and ran off both its edges.
local function plan_frame(first_layout)
    return {origin = first_layout.origin, forward = first_layout.forward, right = first_layout.right}
end

-- A world point in plan metres: x behind the start line, y to the right of the direction of travel.
local function to_plan(frame, point)
    local dx, dy = point.x - frame.origin.x, point.y - frame.origin.y
    return {
        x = rounded(-(dx * frame.forward.x + dy * frame.forward.y), 100),
        y = rounded(dx * frame.right.x + dy * frame.right.y, 100),
    }
end

-- A world direction in plan axes, rounded to a thousandth: (-1, 0) points at the start line.
local function plan_direction(frame, v)
    return rounded(-(v.x * frame.forward.x + v.y * frame.forward.y), 1000),
        rounded(v.x * frame.right.x + v.y * frame.right.y, 1000)
end

-- Which way the start line runs in the plan, {dx, dy}. It passes through the plan's origin (the start
-- pose) square to its own normal, the frame part 1 received, so it slants by part 1's heading: upright at
-- 0 degrees, 16 degrees off at 196. Turned to dy >= 0: a line has no direction, and one answer keeps the
-- push stable.
local function start_line_direction(frame, first_layout)
    local normal = first_layout.frame_forward
    local dx, dy = plan_direction(frame, {x = normal.y, y = -normal.x})
    if dy < 0 or (dy == 0 and dx < 0) then
        dx, dy = -dx, -dy
    end
    -- 0 rather than -0: the number crosses into JSON.
    return {dx = dx + 0, dy = dy + 0}
end

-- A world point in a part's own laid-out axes: metres along its forward and across to its right, from
-- its pivot.
local function part_coords(layout, point)
    local dx, dy = point.x - layout.origin.x, point.y - layout.origin.y
    return dx * layout.forward.x + dy * layout.forward.y, dx * layout.right.x + dy * layout.right.y
end

-- The first and last slot of a part's LAST row and of its FIRST row. Each part begins its own row 0
-- (grid.lua), so a part split off mid-row has a short last row, and both come from the part's own columns.
local function last_row(layout)
    local last = layout.count - 1
    return layout.startSlot + math.floor(last / layout.columns) * layout.columns, layout.startSlot + last
end

local function first_row(layout)
    return layout.startSlot, layout.startSlot + math.min(layout.columns, layout.count) - 1
end

-- How far the slots first..last reach along and across `layout`'s axes.
local function extent_in(layout, poses, first, last)
    local reach = {
        along_min = math.huge,
        along_max = -math.huge,
        across_min = math.huge,
        across_max = -math.huge,
    }
    for slot = first, last do
        local along, across = part_coords(layout, poses[slot + 1].pos)
        reach.along_min = math.min(reach.along_min, along)
        reach.along_max = math.max(reach.along_max, along)
        reach.across_min = math.min(reach.across_min, across)
        reach.across_max = math.max(reach.across_max, across)
    end
    return reach
end

-- The two end points ({x, y}) of the line where `layout`'s part begins. Measured in that part's own axes,
-- so the line turns with the part: halfway between the rearmost car of the previous part's last row and
-- the frontmost car of this part's first row -- between the two rows, never through a pillar -- and as
-- wide as both rows plus BOUNDARY_SIDE_MARGIN on each side.
local function boundary_ends(poses, previous, layout)
    local before = extent_in(layout, poses, last_row(previous))
    local after = extent_in(layout, poses, first_row(layout))
    local along = (before.along_min + after.along_max) / 2
    local function at(across)
        return {
            x = layout.origin.x + layout.forward.x * along + layout.right.x * across,
            y = layout.origin.y + layout.forward.y * along + layout.right.y * across,
        }
    end
    return at(math.min(before.across_min, after.across_min) - BOUNDARY_SIDE_MARGIN),
        at(math.max(before.across_max, after.across_max) + BOUNDARY_SIDE_MARGIN)
end

-- The line from `a` to `b` as points on the ground, one every BOUNDARY_SAMPLE_STEP metres. Grounded
-- through the grid's own chain (placement.ground_heights), seeded at `seed_z`.
local function grounded_line(a, b, seed_z)
    local length = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    local steps = math.max(1, math.min(BOUNDARY_MAX_SAMPLES, math.ceil(length / BOUNDARY_SAMPLE_STEP)))
    local points = {}
    for step = 0, steps do
        local t = step / steps
        points[#points + 1] = {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
    end
    local heights = placement.ground_heights(points, seed_z)
    for index, point in ipairs(points) do
        point.z = heights[index] + BOUNDARY_LINE_LIFT
    end
    return points
end

-- Project the grounded preview for its two readers: the panel's plan ({poses, boundaries, start}, plan
-- metres) and the 3D lines init.lua draws. A boundary exists for every part that has a pose, from the
-- second laid-out part on; a part starting past the preview has neither poses nor a line. `layouts` is
-- grid.poses_segmented_with_frames' second return, so every number here comes from the layout the spawn
-- uses -- the panel re-derives nothing.
local function project(poses, layouts)
    if not layouts[1] then
        return nil, nil
    end
    local frame = plan_frame(layouts[1])
    local plan_poses = {}
    for index, pose in ipairs(poses) do
        local at = to_plan(frame, pose.pos)
        -- The way the car faces, in plan axes: (-1, 0) for every car of part 1.
        local fx, fy = plan_direction(frame, pose.faceDir)
        plan_poses[index] = {
            slot = index - 1,
            part = pose.segment,
            x = at.x,
            y = at.y,
            fx = fx,
            fy = fy,
        }
    end

    local plan_boundaries, lines = {}, {}
    for index = 2, #layouts do
        local layout = layouts[index]
        local a, b = boundary_ends(poses, layouts[index - 1], layout)
        plan_boundaries[#plan_boundaries + 1] = {
            part = layout.segment,
            startSlot = layout.startSlot,
            a = to_plan(frame, a),
            b = to_plan(frame, b),
            color = M.BOUNDARY_COLOR,
        }
        -- Seeded at the surface under the part's first car (its grounded height without its lift).
        local first = poses[layout.startSlot + 1]
        local points = grounded_line(a, b, first.pos.z - (tonumber(first.lift) or 0))
        local label_at = points[#points]
        lines[#lines + 1] = {
            points = points,
            -- Display space, like the pillars' P labels: slot 0 is P1.
            label = "Part " .. layout.segment .. " from P" .. (layout.startSlot + 1),
            label_pos = {x = label_at.x, y = label_at.y, z = label_at.z + M.BOUNDARY_LABEL_HEIGHT},
        }
    end
    local plan = {
        poses = plan_poses,
        boundaries = plan_boundaries,
        start = start_line_direction(frame, layouts[1]),
    }
    return plan, lines
end

-- Recompute the preview poses for the active direction from its segment list + cached anchor.
local function recompute()
    local anchor = M.state.anchors[M.state.direction]
    local segments = M.state.blocks[M.state.direction]
    -- poses_segmented stacks the segments (ADR-0023 amendment) and tags each pose with its segment index
    -- and faceDir, which init.lua reads to highlight the active segment and draw the orientation line. The
    -- _with_frames form is the same layout plus the frame each segment was laid out in, for project().
    local poses, layouts = grid.poses_segmented_with_frames(anchor.base_pose.pos, anchor.base_pose.rot,
        M.state.preview_count, segments, anchor.gate_normal)
    -- Ground the preview through the very function the spawn grounds with (placement.ground_all): the
    -- height-only drop, the height CHAIN across the slots (ADR-0034 amendment 2026-09-01) and the
    -- post-grounding `lift` are then one implementation, not two that have to be kept in step. Two
    -- approximations of the same terrain are exactly the defect the chain exists to remove.
    --
    -- Copy back only what the preview needs: ground_all returns fresh {pos, rot, forward} tables that
    -- would drop the segment tag and faceDir. These pose tables are freshly built above, so mutating
    -- them is safe.
    --
    -- `up` and `samples` come from the same pass (ADR-0034 amendment 2026-08-30): the pillars lean with
    -- the measured slope, and a blob is drawn on each of the four points it was measured at. The slope is
    -- taken unclamped by design, so a corner landing on a kerb really does tip a slot hard -- the blobs
    -- are what makes that readable, and fixable by moving the slot, instead of mysterious.
    local grounded = placement.ground_all(poses)
    for index, pose in ipairs(poses) do
        pose.pos.z = grounded[index].pos.z
        pose.up = grounded[index].up
        pose.samples = grounded[index].samples
    end
    M.state.poses = poses
    -- After the grounding: the boundary lines seed their own ground search at the grounded height.
    M.state.plan, M.state.boundary_lines = project(poses, layouts)
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
    -- Only now: a session counts as started once its preview poses exist, which is what the camera flies to.
    M.state.session = M.state.session + 1
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
-- reverse params survive the switch. Returns nil + a reason only when start.anchor cannot anchor the race
-- at all (it does not resolve or parse, or has no start position). A race WITHOUT its own reverse route
-- is not refused, whatever this comment used to say: start.anchor gives it the anchor a forced reverse
-- race lines up on -- the forward start line turned around on a circuit, behind the forward finish on an
-- open route (ADR-0019 and its amendment 2026-10-11) -- so a reverse block authored there is the one that
-- race starts on.
function M.set_direction(direction)
    if not M.state.active then
        return nil, "not editing, run beamcomp_grid_new(\"<race>\") first"
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
-- numeric knobs coerce `value` to a number, clamped per the knob's constraints; the switch knobs
-- (BOOLEAN_KNOBS) are stored as a genuine true/false. Returns true + the applied value, or nil + a
-- reason (not editing, unknown knob, non-numeric value).
function M.set(knob, value)
    if not M.state.active then
        return nil, "not editing, run beamcomp_grid_new(\"<race>\") first"
    end
    -- The knobs edit the ACTIVE segment's params (segment 0 by default; a breakpoint selection makes a
    -- later segment active). This is the same block shape as before -- just per segment now.
    local block = active_segments()[M.state.segment].params
    -- The switches are toggles, not clamped numbers: coerce and store before the numeric path.
    if BOOLEAN_KNOBS[knob] then
        local on = coerce_bool(value)
        block[knob] = on
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
-- block below) and inserted in slot order. A fresh segment changes NOTHING until the admin dials
-- something in. Returns true + the applied start slot, or nil + a reason.
function M.select_segment(start_slot)
    if not M.state.active then
        return nil, "not editing, run beamcomp_grid_new(\"<race>\") first"
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
    --   Inherited, because they do NOT chain: columns/rows/rowGap/colGap/mirror, so a split never
    --   reshapes the field; the offsetHeight LIFT, so it never visibly moves it either; and the three
    --   placement options (castHeight, noDowncast, noSlope, ADR-0023 amendment 2026-09-01), which
    --   describe how ONE slot meets the ground and so are simply carried on by the new segment.
    -- Only breakpoint segments are zeroed here; segment 0 keeps its own offsetForward (the setback from
    -- the line) and its own heading.
    local seeded = copy_params(segments[prev_index].params)
    seeded.offsetForward = 0
    seeded.offsetLateral = 0
    seeded.headingDeg = 0
    table.insert(segments, prev_index + 1, {startSlot = number, params = seeded})
    M.state.segment = prev_index + 1
    recompute()
    return true, number
end

-- Remove the active breakpoint, merging its slots back into the previous segment (ADR-0023 amendment).
-- The base segment (index 1, slot 0) cannot be removed. On success the previous segment becomes active.
-- Returns true, or nil + a reason.
function M.remove_segment()
    if not M.state.active then
        return nil, "not editing, run beamcomp_grid_new(\"<race>\") first"
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

-- The last previewed slot of part `part`, or nil when the part starts past the preview.
local function last_previewed_slot(plan_poses, part)
    local last = nil
    for _, entry in ipairs(plan_poses) do
        if entry.part == part then
            last = entry.slot
        end
    end
    return last
end

-- The plan the panel draws (ADR-0023 amendment 2026-10-16), or nil when not editing. `poses` and
-- `boundaries` are the last recompute's projection, in plan metres (x behind the start line, y to the
-- right, in part 1's frame -- see plan_frame), and `start` the start line's direction through the plan's
-- origin. `parts` lists every part of the active direction, one starting past the preview included, with
-- its start slot, its last previewed slot (absent when it has none) and the color it is drawn in right
-- now -- bright for the edited part, muted for the rest, exactly as init.lua draws the pillars. Every slot
-- in here is a GE slot (0-based).
function M.plan()
    if not M.state.active or not M.state.plan then
        return nil
    end
    local parts = {}
    for index, seg in ipairs(active_segments()) do
        parts[index] = {
            part = index,
            startSlot = seg.startSlot,
            lastSlot = last_previewed_slot(M.state.plan.poses, index),
            color = M.part_color(index, index == M.state.segment),
        }
    end
    return {
        poses = M.state.plan.poses,
        boundaries = M.state.plan.boundaries,
        start = M.state.plan.start,
        parts = parts,
    }
end

-- Set the authored field size: how many grid slots the preview shows, and (once saved) the size above
-- which the race start warns the issuer. It never feeds the layout -- that stays count-independent
-- (ADR-0023). `count` is coerced to an integer and clamped to [MIN, MAX]. Returns true + the applied
-- value, or nil + a reason when not editing / non-numeric.
function M.set_preview_count(count)
    if not M.state.active then
        return nil, "not editing, run beamcomp_grid_new(\"<race>\") first"
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
-- preview: {prefabFiles = {...}, checkpoints = {...}} -- every checkpoint in this direction's order, CP0
-- first. The anchor for each direction already carries these (start.anchor), so switching direction
-- switches the scene too, red and yellow included. Nil when not editing.
function M.current_scene()
    if not M.state.active then
        return nil
    end
    local anchor = M.state.anchors[M.state.direction]
    if not anchor then
        return nil
    end
    return {prefabFiles = anchor.prefabFiles, checkpoints = anchor.checkpoints}
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
    M.state.plan = nil
    M.state.boundary_lines = nil
    M.state.preview_count = DEFAULT_PREVIEW_COUNT
end

return M
