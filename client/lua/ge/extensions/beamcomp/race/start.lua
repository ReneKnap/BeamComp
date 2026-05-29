-- BeamComp -- race-start resolution.
--
-- Lives at lua/ge/extensions/beamcomp/race/start.lua inside the client mod zip. Stateless:
-- require it and call M.prepare(payload). Target: client GE (LuaJIT 5.1).
--
-- Given a raceStart payload from the server, resolves the race name locally (ADR-0005: the
-- server passes the name through, the client resolves), parses it, picks the default start
-- pose, and lays the grid out via race/grid for `count` players. Returns a plain race-start
-- state table the GE extension stores and renders, or nil plus a human-readable reason.

local M = {}

local discovery = require("beamcomp/race/discovery")
local parser = require("beamcomp/race/parser")
local grid = require("beamcomp/race/grid")
local checkpoints = require("beamcomp/race/checkpoints")
local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.race"

-- Upper bound on circuit laps, so a typo'd /race lap count can't build a runaway traversal plan.
local MAX_LAPS = 1000

-- The pose the grid anchors on: the race's `default` start selector, else the first listed
-- start position. Returns {pos, rot} (plain tables) or nil plus a reason.
local function default_start_pose(race)
    local start_positions = race.startPositions
    local default_id = start_positions.selectors.default
    if default_id then
        for _, sp in ipairs(start_positions.list) do
            if sp.id == default_id then
                return {pos = sp.pos, rot = sp.rot}
            end
        end
    end

    local first = start_positions.list[1]
    if first then
        return {pos = first.pos, rot = first.rot}
    end
    return nil, "race has no start position"
end

local REVERSE_PREFAB = "reversePrefab.prefab.json"

-- The prefab files to load for a forward race: every shipped prefab except the reverse one
-- (i.e. main + forward, given the parser's fixed {main, forward, reverse} set). Reverse-
-- direction support is a deferred feature, so its prefab is excluded here.
local function forward_prefabs(prefab_files)
    local forward = {}
    for _, file in ipairs(prefab_files or {}) do
        if file:sub(-#REVERSE_PREFAB) ~= REVERSE_PREFAB then
            forward[#forward + 1] = file
        end
    end
    return forward
end

-- Resolve the effective race mode + lap count for this start (ADR-0013). The server relays the
-- admin's /race tokens but cannot validate them against geometry (race-blind, ADR-0005), so the
-- check lands here:
--   mode -- the payload override ("sprint"/"circuit") if given, else auto from meta.closed.
--   laps -- circuit only: the payload override else meta.defaultLaps, clamped >= 1; sprint is always
--           a single pass (laps = 1).
-- A circuit forced on a non-closed race cannot run as a loop, so it falls back to sprint and returns
-- a warning the caller surfaces (the client cannot reply in chat). Returns mode, laps, warning (nil).
local function resolve_mode(race, payload)
    local closed = race.meta and race.meta.closed
    local requested = payload.mode

    local mode
    if requested == "sprint" or requested == "circuit" then
        mode = requested
    else
        mode = closed and "circuit" or "sprint"
    end

    local warning
    if mode == "circuit" and not closed then
        warning = "circuit requested on a non-loop race -- running as sprint"
        mode = "sprint"
    end

    local laps = 1
    if mode == "circuit" then
        local requested_laps = tonumber(payload.laps) or (race.meta and race.meta.defaultLaps) or 1
        laps = math.max(1, math.min(MAX_LAPS, math.floor(requested_laps)))
    end

    return mode, laps, warning
end

-- Build the race-start state for a raceStart payload, or return nil plus a reason.
function M.prepare(payload)
    if type(payload) ~= "table" or type(payload.race) ~= "string" then
        return nil, "malformed raceStart payload"
    end

    -- Resolve against this map's races only (ADR-0005: only the client knows a race's map, and a
    -- race only starts on its own map). Skip the map filter if the level is undetectable.
    local loaded = maps.current()
    local locator, miss = discovery.resolve(payload.race, loaded)
    if not locator then
        if miss and miss.code == "ambiguous" then
            return nil, "ambiguous race name '" .. payload.race .. "'"
        end
        -- Not on this map: if the name does pick out a race elsewhere, say so -- more helpful
        -- than a bare "not found" on a multi-map server.
        if loaded then
            local elsewhere = discovery.resolve(payload.race)
            if elsewhere and elsewhere.map and not maps.matches(loaded, elsewhere.map) then
                return nil, "race is on map '" .. elsewhere.map .. "' -- you are on '"
                    .. loaded .. "'"
            end
        end
        return nil, "race not found: '" .. payload.race .. "'"
    end

    log("I", LOG_TAG, "race map '" .. tostring(locator.map) .. "', loaded map '"
        .. tostring(loaded) .. "'")

    local race, parse_err = parser.parse(locator.raceFile)
    if not race then
        return nil, "could not parse race: " .. tostring(parse_err)
    end

    local base_pose, pose_err = default_start_pose(race)
    if not base_pose then
        return nil, pose_err
    end

    local roster = payload.grid or {}
    local my_slot = payload.slot or 0
    -- Cover my own slot even if the roster is shorter than expected (server inconsistency).
    local count = #roster
    if my_slot + 1 > count then
        count = my_slot + 1
    end

    local poses = grid.poses(base_pose.pos, base_pose.rot, count)
    local my_pose = poses[my_slot + 1]
    if not my_pose then
        return nil, "invalid slot " .. tostring(my_slot)
    end

    local mode, laps, mode_warning = resolve_mode(race, payload)
    local plan = checkpoints.plan(race.checkpoints, mode, laps)
    if mode_warning then
        log("W", LOG_TAG, "raceStart: " .. mode_warning)
    end

    log("I", LOG_TAG, string.format(
        "race '%s' ready: slot %d of %d, mode=%s laps=%d (%d crossings) at (%.1f, %.1f, %.1f)",
        race.meta.name, my_slot, count, mode, laps, plan.count,
        my_pose.pos.x, my_pose.pos.y, my_pose.pos.z))

    return {
        name = race.meta.name,
        raceId = locator.id,
        mySlot = my_slot,
        myPose = my_pose,
        gridPoses = poses,
        roster = roster,
        prefabFiles = forward_prefabs(race.props.prefabFiles),
        -- Ordered, visible-only checkpoints with a stable 0-based index (ADR-0005); consumed by
        -- the racing-phase checkpoint detector (race/checkpoints.lua).
        checkpoints = race.checkpoints,
        -- Resolved race mode + lap count and the detector's traversal plan (ADR-0013).
        mode = mode,
        laps = laps,
        plan = plan,
        modeWarning = mode_warning,
    }
end

return M
