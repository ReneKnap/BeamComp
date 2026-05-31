-- BeamComp -- race prefab partition (split a race prefab's static scenery from its cone vehicles).
--
-- Lives at lua/ge/extensions/beamcomp/race/prefab.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state). Target: client GE (LuaJIT 5.1).
--
-- A race prefab is newline-delimited JSON: one scene object per line, plus a SimGroup container line
-- the objects parent to (references/time-trial-race-format.md s4). The file mixes two kinds of object:
--   * static scenery -- `class == "TSStatic"` (the plastic barriers/markers), client-local, NOT
--     BeamMP-propagated.
--   * knockable cone prop-vehicles -- `class == "BeamNGVehicle"` (jbeam "cones", autoEnterVehicle),
--     which spawn as real vehicles and ARE BeamMP-propagated.
--
-- ADR-0020: only the host instantiates the cones (BeamMP syncs them to everyone); non-hosts must
-- NEVER instantiate them -- spawning N cones on every client only to despawn them does not scale.
-- This module writes a STATICS-ONLY copy of a prefab (cone-vehicle lines dropped) that non-hosts
-- spawn instead of the full file, so no cone vehicle is ever created on a non-host.
--
-- The SimGroup container line is NOT necessarily the first line (in hirochi_raceway/004-mediumcourse
-- the cones precede it), so it is found by class, not position, and kept verbatim. Kept lines are
-- written back unchanged -- they are already valid prefab JSONL.

local M = {}

local LOG_TAG = "beamcomp.prefab"

-- The scene-object class of the prefab's knockable cone prop-vehicles. Confirmed against the real
-- hirochi_raceway/004-mediumcourse mainPrefab.prefab.json (14 cone lines, jbeam "cones").
local CONE_OBJECT_CLASS = "BeamNGVehicle"

-- Whether a decoded prefab object line is one of the cone prop-vehicles (the only thing non-hosts
-- must not spawn). Anything that is not a cone -- TSStatic scenery, the SimGroup, decals -- is kept.
local function is_cone_object(obj)
    return type(obj) == "table" and obj.class == CONE_OBJECT_CLASS
end

-- Write a statics-only copy of `prefab_file` to `dest_file`: every line except the cone prop-vehicle
-- lines, kept verbatim. Returns true on success, false (logged) if the file cannot be read/written or
-- has no static objects to keep. The caller spawns `dest_file` on non-hosts so cones never instantiate.
function M.write_statics_only(prefab_file, dest_file)
    if type(readFile) ~= "function" or type(writeFile) ~= "function" then
        log("W", LOG_TAG, "readFile/writeFile unavailable -- cannot filter prefab")
        return false
    end

    local raw = readFile(prefab_file)
    if not raw then
        log("W", LOG_TAG, "could not read prefab '" .. tostring(prefab_file) .. "'")
        return false
    end

    local kept = {}
    local dropped = 0
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("\r$", "")
        if trimmed ~= "" then
            -- Keep anything we cannot positively identify as a cone -- safer to keep an unexpected
            -- line than to drop scenery. jsonDecode returns nil on a bad line (pcall is the boundary).
            local ok, obj = pcall(jsonDecode, trimmed)
            if ok and is_cone_object(obj) then
                dropped = dropped + 1
            else
                kept[#kept + 1] = trimmed
            end
        end
    end

    if #kept == 0 then
        log("W", LOG_TAG, "prefab '" .. tostring(prefab_file) .. "' had no static objects to keep")
        return false
    end

    if not writeFile(dest_file, table.concat(kept, "\n")) then
        log("W", LOG_TAG, "could not write filtered prefab '" .. tostring(dest_file) .. "'")
        return false
    end

    log("I", LOG_TAG, string.format(
        "statics-only prefab: kept %d line(s), dropped %d cone(s) -> %s", #kept, dropped, dest_file))
    return true
end

return M
