-- BeamComp -- in-game start-grid editor (preview + param tuning).
--
-- Lives at lua/ge/extensions/beamcomp/race/grideditor.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Reload-safe: holds only plain tables in M.state, no engine handles, and previews with
-- immediate-mode draws (init.lua redraws each frame), so a Lua reload just drops the edit session with
-- nothing to clean up.
--
-- Authoring side of named parametric grids (ADR-0023). The admin enters edit mode against a race on the
-- current map; the editor anchors a PREVIEW_COUNT-car grid to that race's real start line (via
-- race/start.anchor) and recomputes the preview poses with race/grid as the six knobs are tuned over the
-- GE console. Separate forward/reverse blocks are accumulated; reverse is only authored if the admin
-- switches to it. M.snapshot() hands the blocks to init.lua, which ships them to the server (gridSave).

local M = {}

local grid = require("beamcomp/race/grid")
local start = require("beamcomp/race/start")
local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.grid"

-- The editor previews the grid's full fixed-capacity field so the layout reads clearly while tuning,
-- even with fewer (or no) players present -- and so the preview matches where cars actually spawn (the
-- layout is count-independent, grid.LAYOUT_CAPACITY).
local PREVIEW_COUNT = grid.LAYOUT_CAPACITY

-- Tunable knobs (camelCase, matching the stored/wire param keys) and their constraints. Offsets and
-- heading are unrestricted; gaps are non-negative; rows is a positive integer (the per-column stagger is
-- derived from rowGap / columns, not a knob).
local KNOBS = {
    offsetForward = {},
    offsetLateral = {},
    headingDeg = {},
    rowGap = {min = 0},
    colGap = {min = 0},
    rows = {min = 1, max = PREVIEW_COUNT, integer = true},
}

-- Editor session. active = false when not editing; everything else is meaningful only while active.
M.state = {
    active = false,
    race = nil,        -- canonical id of the race being edited (the default-grid key, ADR-0023)
    map = nil,         -- the map it lives on (grids are keyed by map, ADR-0023)
    direction = "forward",  -- which block the knobs currently edit
    blocks = nil,      -- {forward = <params>, reverse = <params>?} accumulated for the save
    anchors = nil,     -- cached {forward = {base_pose, gate_normal}, reverse = ...} per direction
    poses = nil,       -- current preview poses for the active direction (drawn by init.lua)
}

-- Recompute the preview poses for the active direction from its block + cached anchor.
local function recompute()
    local anchor = M.state.anchors[M.state.direction]
    local block = M.state.blocks[M.state.direction]
    M.state.poses = grid.poses(anchor.base_pose.pos, anchor.base_pose.rot, PREVIEW_COUNT, block,
        anchor.gate_normal)
end

-- Anchor the forward grid for `race_name_or_id` on the current map, install the given param blocks, and
-- preview. The stored race is always the canonical id (start.anchor resolves it), so a later assign is
-- keyed the same way the server resolves it at race start (ADR-0023). Returns true + the canonical id,
-- or nil + a reason. Replaces any prior session.
local function enter(race_name_or_id, blocks)
    local map = maps.current()
    if not map then
        return nil, "no map loaded"
    end

    local anchor, reason = start.anchor(race_name_or_id, "forward")
    if not anchor then
        return nil, reason
    end

    M.state.active = true
    M.state.race = anchor.raceId
    M.state.map = map
    M.state.direction = "forward"
    M.state.blocks = blocks
    M.state.anchors = {forward = anchor}
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

-- Open a saved grid for further editing (beamcomp_grid_edit, once the server returns its data). The
-- record carries the race it was authored against, so we re-anchor to that race; a loaded reverse block
-- is preserved (set_direction won't overwrite it). Returns true + the canonical id, or nil + a reason.
function M.open(record)
    if type(record) ~= "table" or type(record.forward) ~= "table" or type(record.race) ~= "string" then
        return nil, "saved grid is missing its race or params"
    end
    local blocks = {forward = record.forward}
    if type(record.reverse) == "table" then
        blocks.reverse = record.reverse
    end
    local ok, race_id = enter(record.race, blocks)
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
        M.state.blocks.reverse = grid.default_params()
    end

    M.state.direction = direction
    recompute()
    return true
end

-- Set one knob on the active direction's block and re-preview. `knob` is a camelCase param name;
-- `value` is coerced to a number, clamped per the knob's constraints. Returns true + the applied value,
-- or nil + a reason (not editing, unknown knob, non-numeric value).
function M.set(knob, value)
    if not M.state.active then
        return nil, "not editing -- beamcomp_grid_new(\"<race>\") first"
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

    M.state.blocks[M.state.direction][knob] = number
    recompute()
    return true, number
end

-- The current edit as a save payload: the map and the authored blocks (reverse only if it was edited).
-- `name` is supplied by the caller (the save command). Returns nil when not editing.
function M.snapshot(name)
    if not M.state.active then
        return nil
    end
    return {
        map = M.state.map,
        name = name,
        race = M.state.race,
        forward = M.state.blocks.forward,
        reverse = M.state.blocks.reverse,
    }
end

-- Leave edit mode. Immediate-mode preview stops as soon as active is false -- nothing to despawn.
function M.clear()
    M.state.active = false
    M.state.race = nil
    M.state.map = nil
    M.state.direction = "forward"
    M.state.blocks = nil
    M.state.anchors = nil
    M.state.poses = nil
end

return M
