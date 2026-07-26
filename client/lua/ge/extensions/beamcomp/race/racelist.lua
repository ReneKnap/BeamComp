-- BeamComp -- GE-side race-list builder for the /races command.
--
-- Lives at lua/ge/extensions/beamcomp/race/racelist.lua inside the client mod zip. Stateless: require
-- it and call M.build(loaded_map). Target: client GE (LuaJIT 5.1).
--
-- Composes discovery (which races exist) + parser (their mode/checkpoints/laps) into ready-to-post
-- chat lines for the player who ran /races. The server is race-blind (ADR-0005), so the client owns
-- this: it builds the display lines and ships them back for the server to post verbatim (ADR-0011).
-- Only the current-map races are parsed (a small set); races on other maps are counted, not parsed.

local M = {}

local discovery = require("beamcomp/race/discovery")
local parser = require("beamcomp/race/parser")
local maps = require("beamcomp/race/maps")
local optsort = require("beamcomp/race/optsort")

-- The user-facing word for a race's source (ADR-0024/0035): the freeroam timeTrial set is "map", the
-- aiRace set is "ai", the rallyStage set is "rally", the crawl set is "crawl", the level quickrace set is
-- "menu" -- matching the "map:"/"ai:"/"rally:"/"crawl:"/"menu:" prefix /race accepts to pick same-named
-- variants. rallyStage/crawl are Sprint-normalized in the parser, so the mode column reads "sprint";
-- this source tag only names which mission type the track came from.
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

-- One chat line describing a race: "  <slug> [<short>] (menu) - circuit, 6 cp, 2 laps" (laps only for
-- a closed-loop circuit), or "  <slug> [<short>] (menu) - (unsupported)" when it can't be parsed (e.g.
-- a branching race). <short> is the tippable shortname for /race; it equals the slug when no shorter
-- unique form exists, in which case the bracket is dropped to avoid a redundant "[<slug>]". The (map)/
-- (menu) tag names the source so two same-named variants are distinguishable via the prefix. Deprecated
-- (quickrace) entries, only shown with "all", carry a "(deprecated)" marker (ADR-0026).
local function describe(locator, shortname, deprecated)
    local label = locator.displayName
    if shortname and shortname ~= locator.displayName then
        label = label .. " [" .. shortname .. "]"
    end
    label = label .. " (" .. source_label(locator.source) .. ")"
    if deprecated then
        label = label .. " (deprecated)"
    end

    local race = parser.parse(locator)
    if not race then
        return "  " .. label .. " - (unsupported)"
    end

    local mode = (race.meta and race.meta.closed) and "circuit" or "sprint"
    local line = string.format("  %s - %s, %d cp", label, mode, #race.checkpoints)
    if mode == "circuit" then
        local laps = math.max(1, math.floor(tonumber(race.meta.defaultLaps) or 1))
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
        lines[#lines + 1] = string.format("BeamComp races on %s (%d):", loaded_map, #here)
        for _, locator in ipairs(here) do
            lines[#lines + 1] = describe(locator, shortnames[locator.id],
                discovery.is_deprecated(locator))
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

-- Structured race options for the settings UI (ADR-0037): the startable on-map races as {id, label}
-- pairs for a dropdown. `id` is the canonical locator id discovery.resolve matches and the panel submits
-- as the race name. Mirrors build()'s on-map filter but returns data, not chat lines, and parses no
-- geometry -- the panel needs only a pick list; the issuer client validates the choice on start. Deprecated
-- races (ADR-0026) are excluded unless include_deprecated is set (the panel's "include deprecated" toggle),
-- in which case they are listed with a "(deprecated)" marker.
--
-- Ordered by the DISPLAYED label (optsort.by_display), not by the locator id discovery.list sorts on --
-- the dropdown shows the display name, so that is what it is ordered by, and the whole label counts
-- including its "[short]", source and "(deprecated)" suffixes. The sort runs on the finished option array,
-- so neither discovery.list's id order (which /races and every resolve read) nor the shortname pass above
-- it can be affected. This one list feeds BOTH panels -- the race-setup dropdown and the grid editor's
-- race list (init.lua push_setup_data / push_grid_data) -- so both are ordered from here.
function M.options(loaded_map, include_deprecated)
    if not loaded_map then
        return {}
    end
    local here = {}
    for _, locator in ipairs(discovery.list()) do
        if locator.map and maps.matches(loaded_map, locator.map)
            and (include_deprecated or not discovery.is_deprecated(locator)) then
            here[#here + 1] = locator
        end
    end
    local shortnames = discovery.shortnames(here)
    local options = {}
    for _, locator in ipairs(here) do
        local short = shortnames[locator.id]
        local label = locator.displayName
        if short and short ~= locator.displayName then
            label = label .. " [" .. short .. "]"
        end
        label = label .. " (" .. source_label(locator.source) .. ")"
        if discovery.is_deprecated(locator) then
            label = label .. " (deprecated)"
        end
        options[#options + 1] = {id = locator.id, label = label}
    end
    return optsort.by_display(options, "label", "id")
end

return M
