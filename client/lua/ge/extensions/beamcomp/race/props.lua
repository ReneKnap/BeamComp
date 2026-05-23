-- BeamComp -- race prop lifecycle (load + clear the track's scenery prefabs on a race start).
--
-- Lives at lua/ge/extensions/beamcomp/race/props.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller owns the list of spawned
-- object names and passes it back to M.clear. Target: client GE (LuaJIT 5.1).
--
-- On a race start each client loads the race's static-scenery prefab(s) -- the plastic barriers,
-- sign posts and direction arrows the singleplayer time-trial places -- into the scene. This is
-- client-local and deterministic, NOT BeamMP-propagated: BeamMP syncs vehicles, not arbitrary
-- scene objects, and prefab object coordinates are absolute world-space (gameplay/race/path.lua
-- loads them the same way), so the same prefab file produces identical placement on every
-- client with no message exchanged (ADR-0005: the client owns its geometry).
--
-- Two runtime quirks of these mission prefabs, discovered in-game, are handled here:
--   1. They bundle physics "prop vehicles" (jbeam objects like cones, each with
--      autoEnterVehicle) alongside the static meshes. spawnPrefab loads the whole file, so those
--      spawn as real vehicles that hijack the player and clutter the vehicle list -- we delete
--      the ones each load creates (matched by jbeam, snapshot-diffed so pre-existing vehicles are
--      untouched), keeping only the static scenery.
--   2. Statics spawned at runtime have no collision until the static collision mesh is rebuilt
--      (spawnPrefab only rebuilds it when the world editor is open), so we call be:reloadCollision
--      once after loading -- mirroring core/dynamicProps.
--
-- Prefabs are persistent SceneTree objects, so unlike the immediate-mode grid markers they must
-- be cleared on a new load and on extension unload. We spawn each under a deterministic name
-- (beamcomp_prop_<i>) and clean up by that name: spawnPrefab returns a Prefab object via the
-- mission-prefab path (ge_utils.lua:741), removePrefab(name) unloads+deletes it (:804, a no-op
-- when absent). addPrefab rejects a name that already exists, so every load clears its name
-- first -- which also reaps a stale orphan left by a state-losing reload.

local M = {}

local LOG_TAG = "beamcomp.props"
local PROP_NAME_PREFIX = "beamcomp_prop_"

-- Jbeam objects that race prefabs ship as physics "prop vehicles". They carry autoEnterVehicle
-- and would otherwise seat the player and show up in the Tab vehicle cycle, so they are removed
-- right after the prefab loads, leaving only the static scenery.
local PROP_VEHICLE_JBEAMS = {
    cones = true,
}

-- The set of vehicle object IDs currently in the scene, so prop vehicles a subsequent prefab
-- load creates can be told apart from pre-existing (player/synced) vehicles.
local function current_vehicle_ids()
    local ids = {}
    if not be then
        return ids
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh then
            ids[veh:getID()] = true
        end
    end
    return ids
end

-- Delete vehicles that did not exist before the load and are a known prop jbeam. Iterates in
-- reverse because deleting shifts the object list. Returns the count removed.
local function remove_new_prop_vehicles(existing_before)
    if not be then
        return 0
    end
    local removed = 0
    for i = be:getObjectCount() - 1, 0, -1 do
        local veh = be:getObject(i)
        if veh and not existing_before[veh:getID()] and PROP_VEHICLE_JBEAMS[veh.JBeam] then
            local ok, err = pcall(function() veh:delete() end)
            if ok then
                removed = removed + 1
            else
                log("W", LOG_TAG, "failed to delete prop vehicle: " .. tostring(err))
            end
        end
    end
    return removed
end

-- Load each prefab file as a scene object under a deterministic name, drop the prop vehicles the
-- load created, and rebuild static collision. Returns the list of prefab names actually spawned
-- (possibly empty) so the caller can track them for cleanup. One bad prefab warns and is skipped
-- rather than aborting the rest.
function M.load(prefab_files)
    if type(spawnPrefab) ~= "function" or type(removePrefab) ~= "function" then
        log("W", LOG_TAG, "spawnPrefab/removePrefab unavailable -- cannot load props")
        return {}
    end
    if type(prefab_files) ~= "table" then
        return {}
    end

    local vehicles_before = current_vehicle_ids()

    local spawned = {}
    for i, file in ipairs(prefab_files) do
        local name = PROP_NAME_PREFIX .. i
        -- Clear the name first: addPrefab refuses an existing name, and this also reaps any
        -- orphan from a prior load whose tracked names were lost (e.g. a hard reload).
        pcall(removePrefab, name)
        -- Identity pos/rot/scale: prefab object coords are absolute world-space, so the
        -- container transform is identity (mirrors gameplay/race/path.lua's own spawnPrefab call).
        local ok, obj = pcall(spawnPrefab, name, file, "0 0 0", "0 0 1", "1 1 1")
        if ok and obj then
            spawned[#spawned + 1] = name
        else
            log("W", LOG_TAG, "failed to load prop prefab '" .. tostring(file) .. "': "
                .. tostring(obj))
        end
    end

    local removed = remove_new_prop_vehicles(vehicles_before)

    -- Rebuild the static collision mesh so the freshly spawned barriers are solid (spawnPrefab
    -- only does this when the world editor is open). Same call core/dynamicProps uses.
    if #spawned > 0 and be then
        pcall(function() be:reloadCollision(false, true) end)
    end

    log("I", LOG_TAG, string.format("loaded %d prop prefab(s), removed %d prop vehicle(s)",
        #spawned, removed))
    return spawned
end

-- Remove every prop prefab previously spawned, by name. Tolerant of names whose object is
-- already gone (removePrefab no-ops). Returns the number of names processed.
function M.clear(names)
    if type(names) ~= "table" then
        return 0
    end

    local cleared = 0
    for _, name in ipairs(names) do
        pcall(removePrefab, name)
        cleared = cleared + 1
    end

    log("I", LOG_TAG, string.format("cleared %d prop prefab(s)", cleared))
    return cleared
end

return M
