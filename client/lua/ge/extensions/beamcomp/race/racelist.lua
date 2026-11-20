-- BeamComp -- GE-side race lists: the /races chat lines and the race options of both setup panels.
--
-- Lives at lua/ge/extensions/beamcomp/race/racelist.lua inside the client mod zip. Target: client GE (LuaJIT 5.1).
-- One piece of module state: the facts of the races on the loaded map (mode, laps, checkpoints, route length),
-- read once and remembered until the map changes (M.forget, called on the level change in init.lua
-- M.onClientEndMission). A GE Lua reload drops it with everything else (ADR-0052); the next read rebuilds it.
--
-- Composes discovery (which races exist) + parser (what each one is) into ready-to-post chat lines for the player
-- who ran /races and into the option list both panels pick a race from. The server is race-blind (ADR-0005), so the
-- client owns this: it builds the display lines and ships them back for the server to post verbatim (ADR-0011).
-- Only the current map's races are parsed; races on other maps are counted, not parsed.

local M = {}

local discovery = require("beamcomp/race/discovery")
local parser = require("beamcomp/race/parser")
local maps = require("beamcomp/race/maps")
local optsort = require("beamcomp/race/optsort")
local race_start = require("beamcomp/race/start")

local LOG_TAG = "beamcomp.race"

-- Between the parts of a race's facts line: " · ", U+00B7 written as its UTF-8 bytes, so the string does not
-- depend on how this file is saved.
-- BeamNG's jsonEncode escapes only control characters, quotes and backslashes, so UTF-8 reaches the UI untouched,
-- the way the game sends its own square-kilometre sign (ui/gameplaySelector/tileGenerators/levelTiles.lua).
local FACTS_SEPARATOR = " \194\183 "

-- A distance reads in the large unit from these on: km from 1000 m, miles from a tenth of a mile.
local METERS_PER_KM = 1000
local SMALLEST_MILES = 0.1
local FEET_PER_MILE = 5280

-- The user-facing word for a race's source (ADR-0024/0035): the freeroam timeTrial set is "map", the
-- aiRace set is "ai", the rallyStage set is "rally", the crawl set is "crawl", the level quickrace set is
-- "menu" -- matching the "map:"/"ai:"/"rally:"/"crawl:"/"menu:" prefix /race accepts to pick same-named
-- variants. rallyStage/crawl are Sprint-normalized in the parser, so the mode column reads "sprint";
-- this source tag only names which mission type the track came from. A drag strip (ADR-0067) carries none:
-- it is listed under its own title, which already says what it is.
local function source_label(source)
    if source == "quickrace" then
        return "menu"
    end
    if source == "aiRace" then
        return "ai"
    end
    if source == "rallyStage" then
        return "rally"
    end
    if source == "crawl" then
        return "crawl"
    end
    return "map"
end

-- The name a race is listed under: "<slug> [<short>] (<source>)", the bracket dropped when the shortname IS
-- the slug. A drag strip (ADR-0067) is listed under its title with the name /race takes in the bracket, which
-- then always shows (the title has spaces and is not what anybody types), and without a source tag.
local function list_label(locator, shortname)
    if locator.title then
        return locator.title .. " [" .. (shortname or locator.displayName) .. "]"
    end
    local label = locator.displayName
    if shortname and shortname ~= locator.displayName then
        label = label .. " [" .. shortname .. "]"
    end
    return label .. " (" .. source_label(locator.source) .. ")"
end

-- Every race on `loaded_map` as locators, deprecated included.
local function races_on(loaded_map)
    local here = {}
    for _, locator in ipairs(discovery.list()) do
        if locator.map and maps.matches(loaded_map, locator.map) then
            here[#here + 1] = locator
        end
    end
    return here
end

-- ===== the facts of one race ====================================================================================

-- What the race lists say about one race, read off its parse. {supported = false} when it cannot be parsed (a
-- branching race, a missing file), else:
--   mode        -- "drag" on a drag strip (ADR-0067), "circuit" on a closed loop, else "sprint": the mode the
--                  setup panel preselects for it;
--   closed, strip -- the two flags the panel's mode logic reads (M.meta_for);
--   defaultLaps -- the track's OWN lap count, raw, from the parse (never the race.race.json, ADR-0035), nil when it
--                  names none. Resolved by the reader: the panel's way (race_start.resolve_laps) or /races' way;
--   checkpoints -- the checkpoint count, lanes -- a strip's lane count (nil elsewhere);
--   length      -- one pass of the race's own route in metres (race_start.route_length).
local function read_facts(locator)
    local race = parser.parse(locator)
    if not race or not race.meta then
        return {supported = false}
    end
    local strip = race.meta.strip
    local closed = race.meta.closed and true or false
    return {
        supported = true,
        mode = (strip and "drag") or (closed and "circuit") or "sprint",
        closed = closed,
        strip = strip ~= nil,
        defaultLaps = tonumber(race.meta.defaultLaps),
        checkpoints = #race.checkpoints,
        lanes = strip and #strip.lanes or nil,
        length = race_start.route_length(race),
    }
end

-- read_facts behind a pcall: a race that throws costs only itself and reads as not supported.
local function facts_of(locator)
    local ok, facts = pcall(read_facts, locator)
    if ok then
        return facts
    end
    log("W", LOG_TAG, "race facts for '" .. tostring(locator.id) .. "' could not be read: " .. tostring(facts))
    return {supported = false}
end

-- ===== the facts of one map, read once ==========================================================================

-- The facts of the races on one map: by locator id, for the level `map` names.
local known = {map = nil, by_id = {}}

local function now_ms()
    return (os.clockhp or os.clock)() * 1000
end

-- Whether reading a race puts objects into the live scene. The legacy quickrace format is read by the engine's
-- path:fromTrack, which spawns the track's prefab and deletes it again (ADR-0024): statics on 63 of the 108 shipped
-- quickrace tracks, 59 cone vehicles on 6 of them, in a session BeamMP syncs vehicles in. Such a race is read only
-- when somebody asks for that one race (it is picked, /races all), as before; the list never reads it.
local function read_spawns_into_scene(locator)
    return locator.format == "quickrace"
end

-- Read the facts of every race in `locators` not known yet, and measure the batch in one line.
local function read_missing(loaded_map, locators)
    local started = now_ms()
    local read, unsupported = 0, 0
    for _, locator in ipairs(locators) do
        if not known.by_id[locator.id] then
            local facts = facts_of(locator)
            known.by_id[locator.id] = facts
            read = read + 1
            if not facts.supported then
                unsupported = unsupported + 1
            end
        end
    end
    if read > 0 then
        log("I", LOG_TAG, string.format("race facts for '%s': %d races (%d not supported) in %.0f ms",
            loaded_map, read, unsupported, now_ms() - started))
    end
end

-- The facts known for `loaded_map`, by locator id. The first read on a map parses every race on it that can be
-- read without touching the scene, the deprecated ones included so the panel's "incl. deprecated" toggle needs no
-- second pass. That is the one hitch, accepted by the owner (2026-11-20: read at the first panel open, remembered
-- until the map changes), and the log line measures it. Every later read parses only a race it has not seen yet:
-- discovery forgets an empty scan, so a map whose first read found nothing fills itself in on the next one. A
-- different map starts over. A race read on its own (facts_for) is kept here too.
local function facts_for_map(loaded_map)
    if known.map ~= loaded_map then
        known.map, known.by_id = loaded_map, {}
    end
    local readable = {}
    for _, locator in ipairs(races_on(loaded_map)) do
        if not read_spawns_into_scene(locator) then
            readable[#readable + 1] = locator
        end
    end
    read_missing(loaded_map, readable)
    return known.by_id
end

-- The facts of one race on `loaded_map`, read now if the map's read left it out.
local function facts_for(loaded_map, locator)
    local by_id = facts_for_map(loaded_map)
    if not by_id[locator.id] then
        read_missing(loaded_map, {locator})
    end
    return by_id[locator.id]
end

-- Forget the facts, so the next read parses the map again. Called on a level change (init.lua
-- M.onClientEndMission) beside discovery.invalidate: the same map entered again can carry another mod set.
-- Silent when nothing is remembered, so the common case adds no line to a log that goes blind after 15k of them.
function M.forget()
    if known.map then
        known.map, known.by_id = nil, {}
        log("I", LOG_TAG, "race facts forgotten; the next read parses the map again")
    end
end

-- ===== the facts line ===========================================================================================

-- The unit answer last logged, so its source is named once per change and not once per race.
local units_said = nil

local function note_units(answer, level)
    if answer ~= units_said then
        units_said = answer
        log(level, LOG_TAG, "race list distances: " .. answer)
    end
end

-- `meters` in the large unit of the game's own unit system, as the game converts it: translateDistance
-- (lua/ge/ge_utils.lua) reads the player's length setting (uiUnitLength) and answers km or mi. Probed like any
-- engine touchpoint (ADR-0017): value and unit, or nil, nil and the reason when it is missing, throws or answers
-- anything else.
local function game_distance(meters)
    if type(translateDistance) ~= "function" then
        return nil, nil, "the game has no translateDistance"
    end
    local ok, value, unit = pcall(translateDistance, meters, true)
    if not ok then
        return nil, nil, "translateDistance failed: " .. tostring(value)
    end
    if type(value) ~= "number" or (unit ~= "km" and unit ~= "mi") then
        return nil, nil, "translateDistance answered " .. tostring(value) .. " " .. tostring(unit)
    end
    return value, unit
end

local function metric_text(meters)
    local whole_meters = math.floor(meters + 0.5)
    if whole_meters < METERS_PER_KM then
        return string.format("%d m", whole_meters)
    end
    return string.format("%.1f km", meters / METERS_PER_KM)
end

local function imperial_text(miles)
    if miles < SMALLEST_MILES then
        return string.format("%d ft", math.floor(miles * FEET_PER_MILE + 0.5))
    end
    return string.format(miles < 1 and "%.2f mi" or "%.1f mi", miles)
end

-- A distance in the unit system the game shows, metric as the fallback. Metric: whole metres below 1 km, else km
-- with one decimal. Imperial: whole feet below a tenth of a mile, two decimals below a mile (a strip's quarter mile
-- reads 0.25 mi), else one. The game's own "auto" switches to miles only at a mile, which would print a 0.8 mi
-- sprint in feet; the thresholds are ours, the setting and the conversion are the game's.
local function distance_text(meters)
    local value, unit, failure = game_distance(meters)
    if unit == "mi" then
        note_units("imperial, from the game's unit setting", "I")
        return imperial_text(value)
    end
    if unit == "km" then
        note_units("metric, from the game's unit setting", "I")
    else
        note_units("metric, the fallback (" .. failure .. ")", "W")
    end
    return metric_text(meters)
end

local function counted(count, singular, plural)
    return string.format("%d %s", count, count == 1 and singular or plural)
end

-- The gray line under a race's name in both panels' race lists: "circuit · 3 laps · 12 cp · 4.2 km/lap",
-- "sprint · 8 cp · 2.7 km", "drag · 2 lanes · 402 m", or "not supported". A circuit's laps are the number the Laps
-- placeholder states (init.lua M.request_race_meta): race_start.resolve_laps with no request, over the same record
-- M.meta_for answers from, so the two cannot disagree. A route too short to measure prints no distance.
local function facts_line(facts)
    if not facts.supported then
        return "not supported"
    end
    local parts = {facts.mode}
    if facts.mode == "circuit" then
        parts[#parts + 1] = counted(race_start.resolve_laps(nil, facts.defaultLaps), "lap", "laps")
    end
    parts[#parts + 1] = facts.lanes and counted(facts.lanes, "lane", "lanes")
        or string.format("%d cp", facts.checkpoints)
    if facts.length > 0 then
        local distance = distance_text(facts.length)
        parts[#parts + 1] = facts.mode == "circuit" and distance .. "/lap" or distance
    end
    return table.concat(parts, FACTS_SEPARATOR)
end

-- The facts line of every option in option order, false for a race whose facts are not known: one the list does
-- not read (read_spawns_into_scene) until somebody has read it on its own. Composed on every read rather than
-- remembered, so a change of the game's units shows at the next panel open without a second parse.
local function facts_lines(options, loaded_map)
    local facts = facts_for_map(loaded_map)
    local lines = {}
    for index, option in ipairs(options) do
        local race_facts = facts[option.id]
        lines[index] = race_facts and facts_line(race_facts) or false
    end
    return lines
end

-- Put each option's facts line on it as `detail`. All or nothing: when anything here throws, the options go out
-- without a single line, and the panels then show the names alone rather than a guess.
local function attach_facts(options, loaded_map)
    local ok, lines = pcall(facts_lines, options, loaded_map)
    if not ok then
        log("W", LOG_TAG, "race list for '" .. tostring(loaded_map) .. "' goes out without its facts: "
            .. tostring(lines))
        return
    end
    for index, option in ipairs(options) do
        option.detail = lines[index] or nil
    end
end

-- ===== /races ===================================================================================================

-- One chat line describing a race: "  <slug> [<short>] (menu) - circuit, 6 cp, 2 laps" (laps only for
-- a closed-loop circuit), "  <title> [<slug>] - drag strip, 2 lanes", or
-- "  <slug> [<short>] (menu) - (unsupported)" when it can't be parsed (e.g. a branching race). <short> is
-- the tippable shortname for /race. The (map)/(menu) tag names the source so two same-named variants are
-- distinguishable via the prefix. Deprecated (quickrace) entries, only shown with "all", carry a
-- "(deprecated)" marker (ADR-0026). Reads the same facts as the panels' list; its lap count keeps its own rule
-- (no upper clamp), so the chat lines stay what they were.
local function describe(locator, shortname, deprecated, facts)
    local label = list_label(locator, shortname)
    if deprecated then
        label = label .. " (deprecated)"
    end

    if not facts.supported then
        return "  " .. label .. " - (unsupported)"
    end
    if facts.strip then
        return string.format("  %s - drag strip, %d lanes", label, facts.lanes)
    end

    local line = string.format("  %s - %s, %d cp", label, facts.mode, facts.checkpoints)
    if facts.mode == "circuit" then
        local laps = math.max(1, math.floor(facts.defaultLaps or 1))
        line = line .. string.format(", %d laps", laps)
    end
    return line
end

-- Build the /races chat lines, given the loaded level id (or nil if undetectable). Returns an array
-- of strings the server posts verbatim. Current-map races are listed with parsed detail; races on
-- other maps are only counted (a race starts only on its own map). With no map context, every race is
-- listed by id without parsing (a parse-all would be heavy and the map filter is unavailable).
--
-- The deprecated quickrace source (ADR-0026) is hidden unless include_deprecated ("all") is set: shown
-- entries then carry a "(deprecated)" marker, and a hidden one on this map is replaced by a count hint
-- so the player learns "all" reveals more. Off-map deprecated races stay out of the count unless "all".
function M.build(loaded_map, include_deprecated)
    local races = discovery.list()

    if not loaded_map then
        local visible, hidden = {}, 0
        for _, locator in ipairs(races) do
            if include_deprecated or not discovery.is_deprecated(locator) then
                visible[#visible + 1] = locator
            else
                hidden = hidden + 1
            end
        end
        local lines = {string.format("BeamComp: %d race(s) installed (map unknown - can't filter):",
            #visible)}
        for _, locator in ipairs(visible) do
            lines[#lines + 1] = "  " .. locator.id
        end
        if hidden > 0 then
            lines[#lines + 1] = string.format("(%d deprecated - /races all to show)", hidden)
        end
        return lines
    end

    -- Split this map's startable races from the rest; within this map separate the deprecated ones
    -- (hidden unless "all") so they can be hinted at. Off-map deprecated races are out of default scope
    -- exactly like on-map ones, so they only count toward "elsewhere" with "all".
    local here, hidden_here, elsewhere = {}, 0, 0
    for _, locator in ipairs(races) do
        local on_map = locator.map and maps.matches(loaded_map, locator.map)
        local shown = include_deprecated or not discovery.is_deprecated(locator)
        if on_map then
            if shown then
                here[#here + 1] = locator
            else
                hidden_here = hidden_here + 1
            end
        elseif shown then
            elsewhere = elsewhere + 1
        end
    end

    -- Shortnames over the visible on-map set: that's the set /race resolves against here, so the shown
    -- form is the shortest that stays unambiguous among the startable races (ADR-0026 keeps the
    -- deprecated source out of both unless "all", so the two stay consistent).
    local shortnames = discovery.shortnames(here)

    local lines = {}
    if #here == 0 then
        lines[#lines + 1] = "BeamComp: no races on this map (" .. loaded_map .. ")"
    else
        local facts = facts_for_map(loaded_map)
        -- The listed races the map's read leaves out (read_spawns_into_scene) are read here, as /races all always
        -- read them.
        read_missing(loaded_map, here)
        lines[#lines + 1] = string.format("BeamComp races on %s (%d):", loaded_map, #here)
        for _, locator in ipairs(here) do
            lines[#lines + 1] = describe(locator, shortnames[locator.id],
                discovery.is_deprecated(locator), facts[locator.id])
        end
    end

    if hidden_here > 0 then
        lines[#lines + 1] = string.format("(%d deprecated on this map - /races all to show)",
            hidden_here)
    end

    if elsewhere > 0 then
        lines[#lines + 1] = string.format("(%d more on other maps - switch map to start them)",
            elsewhere)
    end

    return lines
end

-- ===== the panels ===============================================================================================

-- Structured race options for the settings UI (ADR-0037): the startable on-map races as {id, label, strip, detail}
-- for a dropdown. `id` is the canonical locator id discovery.resolve matches and the panel submits as the race
-- name. Mirrors build()'s on-map filter but returns data, not chat lines. Deprecated races (ADR-0026) are excluded
-- unless include_deprecated is set (the panel's "include deprecated" toggle), in which case they are listed with a
-- "(deprecated)" marker.
--
-- `detail` is the race's facts line (facts_line), the gray line under its name in the open list. The facts are read
-- for the whole map on the first read and remembered (facts_for_map): this list is rebuilt on every panel open,
-- refresh and form restore, and only the first of them on a map parses anything (ADR-0037 amendment 2026-11-20,
-- which overturns the old rule that this list parses no geometry). An option without `detail` (a legacy quickrace
-- track nobody has read on its own, read_spawns_into_scene, or facts that could not be attached) shows no line,
-- never a guess.
--
-- Ordered by the DISPLAYED label (optsort.by_display), not by the locator id discovery.list sorts on --
-- the dropdown shows the display name, so that is what it is ordered by, and the whole label counts
-- including its "[short]", source and "(deprecated)" suffixes. The sort runs on the finished option array,
-- so neither discovery.list's id order (which /races and every resolve read) nor the shortname pass above
-- it can be affected. This one list feeds BOTH panels -- the race-setup dropdown and the grid editor's
-- race list (init.lua push_setup_data / push_grid_data) -- so both are ordered, and described, from here.
function M.options(loaded_map, include_deprecated)
    if not loaded_map then
        return {}
    end
    local here = {}
    for _, locator in ipairs(races_on(loaded_map)) do
        if include_deprecated or not discovery.is_deprecated(locator) then
            here[#here + 1] = locator
        end
    end
    local shortnames = discovery.shortnames(here)
    local options = {}
    for _, locator in ipairs(here) do
        local label = list_label(locator, shortnames[locator.id])
        if discovery.is_deprecated(locator) then
            label = label .. " (deprecated)"
        end
        -- A drag strip (ADR-0067): the panel recommends and preselects Drag on it. Read off the source, so the
        -- recommendation holds even when the strip cannot be parsed.
        options[#options + 1] = {id = locator.id, label = label,
            strip = locator.source == "strip" or nil}
    end
    attach_facts(options, loaded_map)
    return optsort.by_display(options, "label", "id")
end

-- The track metadata the race-setup panel needs for ONE race (ADR-0037/0013): `closed`, the flag that
-- decides whether a race is a lap race or a point-to-point run, `defaultLaps`, the lap count THIS TRACK itself
-- brings (nil when it names none), and `strip`. Returns nil when the race cannot be resolved or cannot be parsed
-- (a branching track, a missing file) -- the panel then keeps its "track type unknown" state rather than being
-- told something false.
--
-- Answered from the same facts record as the race list's gray line (facts_for_map), so the Laps placeholder and
-- the list's laps come from one record, and picking a race parses nothing. defaultLaps is the PARSED number
-- (parser.build_meta), never the race.race.json's: that file's own defaultLaps is an editor value the mission's
-- info.json contradicts on about a third of the stock races, and the info field is named per mission type
-- ("defaultLaps" for timeTrial/rallyStage, "lapCount" for aiRace -- ADR-0024/0035).
--
-- The number is the track's own, NOT the one a start would end up using: the single-lap fallback and
-- the upper clamp belong to race/start.lua and are applied by the caller (init.lua request_race_meta)
-- through race_start.resolve_laps, so nothing here re-invents them.
--
-- Deprecated races are included: the panel can select one (with its "incl. deprecated" toggle), so
-- refusing to describe it would leave that selection stuck on the unknown fallback.
function M.meta_for(loaded_map, race_id)
    if type(race_id) ~= "string" or race_id == "" then
        return nil
    end
    local locator = discovery.resolve(race_id, loaded_map, true)
    if not locator then
        return nil
    end
    local facts = loaded_map and facts_for(loaded_map, locator) or facts_of(locator)
    if not facts.supported then
        return nil
    end
    return {
        closed = facts.closed,
        defaultLaps = facts.defaultLaps,
        strip = facts.strip or nil,
    }
end

return M
