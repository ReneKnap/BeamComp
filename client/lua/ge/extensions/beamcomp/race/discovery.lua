-- BeamComp -- GE-side time-trial race discovery and name resolution.
--
-- Lives at lua/ge/extensions/beamcomp/race/discovery.lua inside the client mod zip.
-- Stateless: require it and call M.list() / M.resolve(name).
--
-- Discovers installed time-trial races by scanning the BeamNG virtual filesystem, from two sources
-- (ADR-0024): the freeroam mission markers (race.race.json under a /timeTrial/ path, ADR-0005) and the
-- Time Trial menu's level quickrace tracks (/levels/<map>/quickrace/). The scan is robust against the
-- missions subsystem not being initialized in a multiplayer session. Each locator carries a source
-- ("mission"/"quickrace") and format ("racePath"/"quickrace"), and a map-qualified id ("<map>/<slug>"
-- for missions, "<map>/quickrace/<slug>" for quickrace) so names never collide. M.resolve maps a
-- requested name (optionally "map:"/"menu:"-prefixed to pick a source) to a single locator, or reports
-- a miss / ambiguity.

local M = {}

local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.race"

local MISSIONS_ROOT = "/gameplay/missions/"
local LEVELS_ROOT = "/levels/"
local RACE_FILENAME = "race.race.json"
-- The map is the path segment right before /timeTrial/, the slug the one after:
-- ".../<map>/timeTrial/<slug>/race.race.json". Left unanchored so it matches whether
-- FS:findFiles returns absolute or root-relative paths, and so vendored/mod races
-- mounted under the same convention are picked up too (ADR-0005).
local TIME_TRIAL_PATTERN = "([^/]+)/timeTrial/([^/]+)/race%.race%.json$"
-- The map is the segment before /quickrace/, the file the one after (flat folder):
-- ".../<map>/quickrace/<file>". Unanchored for the same reason as the time-trial pattern (ADR-0024).
local QUICKRACE_PATTERN = "([^/]+)/quickrace/([^/]+)$"

-- Build a locator from a missions race.race.json VFS path, or nil if it is not a time-trial race.
-- source = "mission" (the freeroam map markers), format = "racePath" (path:onDeserialized loadable).
local function locator_from_race_file(race_file)
    local map, slug = race_file:match(TIME_TRIAL_PATTERN)
    if not map then
        return nil
    end
    return {
        id = map .. "/" .. slug,
        displayName = slug,
        map = map,
        source = "mission",
        format = "racePath",
        folder = race_file:match("^(.*/)[^/]*$"),
        raceFile = race_file,
    }
end

-- Build a locator from a level quickrace file VFS path, or nil if it is not a track definition
-- (ADR-0024). source = "quickrace" (the Time Trial menu set). A "<name>.race.json" is the new path
-- format (loaded like a mission); a plain "<name>.json" is the legacy quickrace format (loaded via
-- race/quickrace). Prefab files that also end in .json (e.g. "arrowFlags.prefab.json") are skipped.
local function locator_from_quickrace_file(race_file)
    local map, filename = race_file:match(QUICKRACE_PATTERN)
    if not map or filename:find("%.prefab%.json$") then
        return nil
    end

    local track_name, format
    local race_slug = filename:match("^(.+)%.race%.json$")
    if race_slug then
        track_name, format = race_slug, "racePath"
    else
        track_name = filename:match("^(.+)%.json$")
        format = "quickrace"
    end
    if not track_name then
        return nil
    end

    return {
        id = map .. "/quickrace/" .. track_name,
        displayName = track_name,
        map = map,
        source = "quickrace",
        format = format,
        folder = race_file:match("^(.*/)[^/]*$"),
        trackName = track_name,
        raceFile = race_file,
    }
end

-- The level folder names that hold content (each may carry a /quickrace/ set). Mirrors
-- quickRaceLoader.getLevelList: scan one level deep for info.json.
local function level_names()
    local names = {}
    local seen = {}
    for _, info_file in ipairs(FS:findFiles(LEVELS_ROOT, "info.json", 1, true, false)) do
        local map = info_file:match("levels/([^/]+)/")
        if map and not seen[map] then
            seen[map] = true
            names[#names + 1] = map
        end
    end
    return names
end

-- Every installed time-trial race across both sources, as locators, sorted by id (ADR-0024): the
-- missions set (freeroam map markers) and the level quickrace set (the Time Trial menu).
function M.list()
    local locators = {}

    for _, race_file in ipairs(FS:findFiles(MISSIONS_ROOT, RACE_FILENAME, -1, false, true)) do
        local locator = locator_from_race_file(race_file)
        if locator then
            locators[#locators + 1] = locator
        end
    end

    for _, map in ipairs(level_names()) do
        local quickrace_dir = LEVELS_ROOT .. map .. "/quickrace/"
        for _, race_file in ipairs(FS:findFiles(quickrace_dir, "*.json", -1, true, false)) do
            local locator = locator_from_quickrace_file(race_file)
            if locator then
                locators[#locators + 1] = locator
            end
        end
    end

    table.sort(locators, function(a, b) return a.id < b.id end)
    log("I", LOG_TAG, "discovered " .. #locators .. " time-trial race(s)")
    return locators
end

-- Collapse a list of matched locators into a resolve result: the single race if exactly one
-- matched, else the {code = "ambiguous", candidates = {ids}} reason table. Shared by the slug
-- and substring tiers so both report ambiguity identically.
local function single_or_ambiguous(name, matches)
    if #matches == 1 then
        log("I", LOG_TAG, "resolved '" .. name .. "' to " .. matches[1].id)
        return matches[1]
    end

    local ids = {}
    for _, race in ipairs(matches) do
        ids[#ids + 1] = race.id
    end
    log("W", LOG_TAG, "ambiguous race name '" .. name .. "': " .. table.concat(ids, ", "))
    return nil, {code = "ambiguous", candidates = ids}
end

-- An optional source prefix on a /race name (ADR-0024): "map:" restricts the match to the freeroam
-- mission set, "menu:" to the level quickrace set -- so same-named variants across the two sources can
-- be picked deterministically. Returns the source ("mission"/"quickrace") or nil, plus the name with
-- the prefix stripped. Case-insensitive on the prefix.
local function split_source_prefix(name)
    local rest = name:match("^[Mm][Aa][Pp]:(.*)$")
    if rest then
        return "mission", rest
    end
    rest = name:match("^[Mm][Ee][Nn][Uu]:(.*)$")
    if rest then
        return "quickrace", rest
    end
    return nil, name
end

-- Resolve a requested race name to a single locator. An optional "map:"/"menu:" prefix first restricts
-- to that source (ADR-0024). Tiers, exact-first: map-qualified id ("<map>/<slug>",
-- "<map>/quickrace/<slug>"), then bare slug ("<slug>"), then a unique case-insensitive substring of a
-- slug ("med" -> "004-mediumcourse") -- all case-insensitive. An exact name can never be diverted to a
-- different race by the substring tier, since the exact tiers run first.
--
-- When loaded_map is given the match set is restricted to races startable on that map (a race
-- only starts on its own map anyway), which keeps the set small so shorter substrings stay
-- unambiguous; with no map context every installed race is considered. On failure returns nil
-- plus a reason table: {code = "ambiguous", candidates = {...}} or {code = "not_found"}.
function M.resolve(name, loaded_map)
    if not name or name == "" then
        return nil, {code = "not_found"}
    end

    local source, bare = split_source_prefix(name)
    if bare == "" then
        return nil, {code = "not_found"}
    end
    local wanted = bare:lower()
    local candidates = M.list()

    if loaded_map then
        local on_map = {}
        for _, race in ipairs(candidates) do
            if race.map and maps.matches(loaded_map, race.map) then
                on_map[#on_map + 1] = race
            end
        end
        candidates = on_map
    end

    if source then
        local in_source = {}
        for _, race in ipairs(candidates) do
            if race.source == source then
                in_source[#in_source + 1] = race
            end
        end
        candidates = in_source
    end

    for _, race in ipairs(candidates) do
        if race.id:lower() == wanted then
            log("I", LOG_TAG, "resolved '" .. name .. "' to " .. race.id)
            return race
        end
    end

    local exact = {}
    for _, race in ipairs(candidates) do
        if race.displayName:lower() == wanted then
            exact[#exact + 1] = race
        end
    end
    if #exact > 0 then
        return single_or_ambiguous(name, exact)
    end

    -- Substring fallback (match against the slug only, not the map-qualified id, so a stray
    -- map-name fragment can't pull in an off-map race). Plain find -- the input is literal text.
    local partial = {}
    for _, race in ipairs(candidates) do
        if race.displayName:lower():find(wanted, 1, true) then
            partial[#partial + 1] = race
        end
    end
    if #partial > 0 then
        return single_or_ambiguous(name, partial)
    end

    log("W", LOG_TAG, "no race matches '" .. name .. "'")
    return nil, {code = "not_found"}
end

-- Shortname candidates for a slug, shortest first: prefixes of each alphanumeric token, so the
-- forms stay readable ("004", "med") rather than arbitrary fragments. "004-mediumcourse" yields
-- "0","00","004","m","me","med",... -- then sorted by length, ties keeping token order so the
-- leading number is preferred at equal length.
local function shortname_candidates(slug)
    local candidates = {}
    local order = 0
    for token in slug:lower():gmatch("[%w]+") do
        order = order + 1
        for len = 1, #token do
            candidates[#candidates + 1] = {text = token:sub(1, len), order = order, len = len}
        end
    end
    table.sort(candidates, function(a, b)
        if a.len ~= b.len then
            return a.len < b.len
        end
        return a.order < b.order
    end)
    return candidates
end

-- The shortest readable shortname for each locator that still resolves uniquely to it: the
-- shortest token-prefix candidate contained in exactly one slug across the whole set (that one
-- slug is necessarily its own, so M.resolve(shortname) lands here). Falls back to the full slug
-- when nothing shorter is unique. Returns a map id -> shortname. Uniqueness is checked against
-- the full given set, so a displayed shortname always resolves to what it labels.
function M.shortnames(locators)
    local slugs = {}
    for _, race in ipairs(locators) do
        slugs[#slugs + 1] = race.displayName:lower()
    end

    local function unique_to_one(candidate)
        local hits = 0
        for _, slug in ipairs(slugs) do
            if slug:find(candidate, 1, true) then
                hits = hits + 1
                if hits > 1 then
                    return false
                end
            end
        end
        return hits == 1
    end

    local result = {}
    for _, race in ipairs(locators) do
        local short = race.displayName
        for _, candidate in ipairs(shortname_candidates(race.displayName)) do
            if unique_to_one(candidate.text) then
                short = candidate.text
                break
            end
        end
        result[race.id] = short
    end
    return result
end

return M
