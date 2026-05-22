-- BeamComp -- GE-side time-trial race discovery and name resolution.
--
-- Lives at lua/ge/extensions/beamcomp/race/discovery.lua inside the client mod zip.
-- Stateless: require it and call M.list() / M.resolve(name).
--
-- Discovers installed time-trial races by scanning the BeamNG virtual filesystem for
-- race.race.json files under a /timeTrial/ path (ADR-0005) -- robust against the
-- missions subsystem not being initialized in a multiplayer session, and mirroring how
-- the engine's own missions.lua discovers content. Each race gets a map-qualified id
-- "<map>/<slug>" so names never collide across maps. M.resolve maps a requested name to
-- a single locator, or reports a miss / ambiguity.

local M = {}

local LOG_TAG = "beamcomp.race"

local MISSIONS_ROOT = "/gameplay/missions/"
local RACE_FILENAME = "race.race.json"
-- The map is the path segment right before /timeTrial/, the slug the one after:
-- ".../<map>/timeTrial/<slug>/race.race.json". Left unanchored so it matches whether
-- FS:findFiles returns absolute or root-relative paths, and so vendored/mod races
-- mounted under the same convention are picked up too (ADR-0005).
local TIME_TRIAL_PATTERN = "([^/]+)/timeTrial/([^/]+)/race%.race%.json$"

-- Build a locator from a race.race.json VFS path, or nil if it is not a time-trial race.
local function locator_from_race_file(race_file)
    local map, slug = race_file:match(TIME_TRIAL_PATTERN)
    if not map then
        return nil
    end
    return {
        id = map .. "/" .. slug,
        displayName = slug,
        map = map,
        folder = race_file:match("^(.*/)[^/]*$"),
        raceFile = race_file,
    }
end

-- Every installed time-trial race, as locators, sorted by id.
function M.list()
    local locators = {}
    local files = FS:findFiles(MISSIONS_ROOT, RACE_FILENAME, -1, false, true)
    for _, race_file in ipairs(files) do
        local locator = locator_from_race_file(race_file)
        if locator then
            locators[#locators + 1] = locator
        end
    end
    table.sort(locators, function(a, b) return a.id < b.id end)
    log("I", LOG_TAG, "discovered " .. #locators .. " time-trial race(s)")
    return locators
end

-- Resolve a requested race name to a single locator. Accepts a map-qualified id
-- ("<map>/<slug>") or a bare slug ("<slug>"), case-insensitive. On failure returns nil
-- plus a reason table: {code = "ambiguous", candidates = {...}} or {code = "not_found"}.
function M.resolve(name)
    if not name or name == "" then
        return nil, {code = "not_found"}
    end

    local wanted = name:lower()
    local races = M.list()

    for _, race in ipairs(races) do
        if race.id:lower() == wanted then
            log("I", LOG_TAG, "resolved '" .. name .. "' to " .. race.id)
            return race
        end
    end

    local matches = {}
    for _, race in ipairs(races) do
        if race.displayName:lower() == wanted then
            matches[#matches + 1] = race
        end
    end

    if #matches == 1 then
        log("I", LOG_TAG, "resolved '" .. name .. "' to " .. matches[1].id)
        return matches[1]
    end

    if #matches > 1 then
        local ids = {}
        for _, race in ipairs(matches) do
            ids[#ids + 1] = race.id
        end
        log("W", LOG_TAG, "ambiguous race name '" .. name .. "': " .. table.concat(ids, ", "))
        return nil, {code = "ambiguous", candidates = ids}
    end

    log("W", LOG_TAG, "no race matches '" .. name .. "'")
    return nil, {code = "not_found"}
end

return M
