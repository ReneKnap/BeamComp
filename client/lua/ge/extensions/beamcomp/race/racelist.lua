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

-- One chat line describing a race: "  <slug> [<short>] - circuit, 6 cp, 2 laps" (laps only for a
-- closed-loop circuit), or "  <slug> [<short>] - (unsupported)" when it can't be parsed (e.g. a
-- branching race). <short> is the tippable shortname for /race; it equals the slug when no shorter
-- unique form exists, in which case the bracket is dropped to avoid a redundant "[<slug>]".
local function describe(locator, shortname)
    local label = locator.displayName
    if shortname and shortname ~= locator.displayName then
        label = label .. " [" .. shortname .. "]"
    end

    local race = parser.parse(locator.raceFile)
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
function M.build(loaded_map)
    local races = discovery.list()

    if not loaded_map then
        local lines = {string.format("BeamComp: %d race(s) installed (map unknown - can't filter):",
            #races)}
        for _, locator in ipairs(races) do
            lines[#lines + 1] = "  " .. locator.id
        end
        return lines
    end

    local here, elsewhere = {}, 0
    for _, locator in ipairs(races) do
        if locator.map and maps.matches(loaded_map, locator.map) then
            here[#here + 1] = locator
        else
            elsewhere = elsewhere + 1
        end
    end

    -- Shortnames over this map's races only: that's the set /race resolves against here, so the
    -- shown form is the shortest that stays unambiguous among the startable races.
    local shortnames = discovery.shortnames(here)

    local lines = {}
    if #here == 0 then
        lines[#lines + 1] = "BeamComp: no races on this map (" .. loaded_map .. ")"
    else
        lines[#lines + 1] = string.format("BeamComp races on %s (%d):", loaded_map, #here)
        for _, locator in ipairs(here) do
            lines[#lines + 1] = describe(locator, shortnames[locator.id])
        end
    end

    if elsewhere > 0 then
        lines[#lines + 1] = string.format("(%d more on other maps - switch map to start them)",
            elsewhere)
    end

    return lines
end

return M
