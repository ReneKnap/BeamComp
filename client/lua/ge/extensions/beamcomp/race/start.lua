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

local LOG_TAG = "beamcomp.race"

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

-- The loaded level's identifier (e.g. "hirochi_raceway"), or nil if it can't be read.
-- getCurrentLevelIdentifier is a GE global; guarded so a missing API degrades to "unknown".
local function current_map()
    if type(getCurrentLevelIdentifier) ~= "function" then
        return nil
    end
    local ok, level = pcall(getCurrentLevelIdentifier)
    if ok and type(level) == "string" and level ~= "" then
        return level
    end
    return nil
end

-- Whether the loaded level matches the race's map. Substring-tolerant so a path-form
-- identifier ("/levels/<map>/info.json") still matches a bare map name.
local function maps_match(loaded, race_map)
    local a, b = loaded:lower(), race_map:lower()
    return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- Build the race-start state for a raceStart payload, or return nil plus a reason.
function M.prepare(payload)
    if type(payload) ~= "table" or type(payload.race) ~= "string" then
        return nil, "malformed raceStart payload"
    end

    local locator, miss = discovery.resolve(payload.race)
    if not locator then
        if miss and miss.code == "ambiguous" then
            return nil, "ambiguous race name '" .. payload.race .. "'"
        end
        return nil, "race not found: '" .. payload.race .. "'"
    end

    -- Markers/poses are in the race's own world coordinates, so refuse a race that isn't on
    -- the loaded map (ADR-0005: only the client knows the race's map). Skip if undetectable.
    local loaded = current_map()
    log("I", LOG_TAG, "race map '" .. tostring(locator.map) .. "', loaded map '"
        .. tostring(loaded) .. "'")
    if loaded and locator.map and not maps_match(loaded, locator.map) then
        return nil, "race is on map '" .. locator.map .. "' -- you are on '" .. loaded .. "'"
    end

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

    log("I", LOG_TAG, string.format("race '%s' ready: slot %d of %d at (%.1f, %.1f, %.1f)",
        race.meta.name, my_slot, count, my_pose.pos.x, my_pose.pos.y, my_pose.pos.z))

    return {
        name = race.meta.name,
        raceId = locator.id,
        mySlot = my_slot,
        myPose = my_pose,
        gridPoses = poses,
        roster = roster,
    }
end

return M
