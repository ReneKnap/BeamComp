-- BeamComp -- GE-side map identity helpers.
--
-- Lives at lua/ge/extensions/beamcomp/race/maps.lua inside the client mod zip. Stateless: require it
-- and call M.current() / M.matches(...). Target: client GE (LuaJIT 5.1).
--
-- Small shared helpers for reasoning about the loaded level vs a race's map: a race only starts on
-- its own map (race/start) and /races lists the current map's races (race/racelist).

local M = {}

-- The loaded level's identifier (e.g. "hirochi_raceway"), or nil if it can't be read.
-- getCurrentLevelIdentifier is a GE global; guarded so a missing API degrades to nil.
function M.current()
    if type(getCurrentLevelIdentifier) ~= "function" then
        return nil
    end
    local ok, level = pcall(getCurrentLevelIdentifier)
    if ok and type(level) == "string" and level ~= "" then
        return level
    end
    return nil
end

-- Whether the loaded level matches a race's map. Substring-tolerant so a path-form identifier
-- ("/levels/<map>/info.json") still matches a bare map name.
function M.matches(loaded, race_map)
    local a, b = loaded:lower(), race_map:lower()
    return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

return M
