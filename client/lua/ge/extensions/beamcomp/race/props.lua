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
--   1. They bundle physics "prop vehicles" (jbeam "cones", each with autoEnterVehicle) alongside
--      the static meshes. spawnPrefab loads the whole file, so those spawn as real vehicles -- and
--      every vehicle a client spawns in a BeamMP session is owned and propagated. ADR-0020: only the
--      host (`keep_cones`) spawns the full prefab, keeping the cones its load creates for BeamMP to
--      sync to everyone; non-hosts spawn a STATICS-ONLY copy (race/prefab.lua) so they never
--      instantiate a cone vehicle at all -- prevention, not spawn-then-delete. We snapshot vehicle
--      ids before the host load and hand the snapshot to cones.lua to diff against, returning the
--      kept cone ids for the caller to track (host only; non-hosts have none).
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

local cones = require("beamcomp/race/cones")
local prefab = require("beamcomp/race/prefab")

local LOG_TAG = "beamcomp.props"
local PROP_NAME_PREFIX = "beamcomp_prop_"

-- Where the statics-only prefab copies non-hosts spawn are written (one per source prefab index).
-- A BeamNG temp vpath, overwritten each load -- no cleanup needed.
local STATICS_TMP_PREFIX = "/temp/beamcomp_statics_"

-- The set of vehicle object IDs currently in the scene, so the cone prop-vehicles a subsequent
-- prefab load creates can be told apart from pre-existing (player/synced) vehicles.
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

-- Load each prefab file as a scene object under a deterministic name and rebuild static collision.
-- `keep_cones` is true only on the host (ADR-0020): the host spawns the FULL prefab and keeps the
-- knockable cones its load creates for BeamMP to sync; every other client spawns a STATICS-ONLY copy
-- (race/prefab.lua) so it never instantiates a cone vehicle -- prevention, not spawn-then-delete.
-- Returns the list of prefab names spawned (for prefab cleanup) and the list of kept cone vehicle ids
-- (empty unless host; for cone cleanup). One bad prefab warns and is skipped rather than aborting.
function M.load(prefab_files, keep_cones)
    if type(spawnPrefab) ~= "function" or type(removePrefab) ~= "function" then
        log("W", LOG_TAG, "spawnPrefab/removePrefab unavailable -- cannot load props")
        return {}, {}
    end
    if type(prefab_files) ~= "table" then
        return {}, {}
    end

    local vehicles_before = current_vehicle_ids()

    local spawned = {}
    for i, file in ipairs(prefab_files) do
        local name = PROP_NAME_PREFIX .. i
        -- Clear the name first: addPrefab refuses an existing name, and this also reaps any
        -- orphan from a prior load whose tracked names were lost (e.g. a hard reload).
        pcall(removePrefab, name)
        -- Non-hosts spawn a statics-only copy so the cone vehicles are never created (ADR-0020). The
        -- host spawns the full file as-is. If the filter fails, degrade to the full prefab rather
        -- than leave the client with no barriers (logged).
        local source = file
        if not keep_cones then
            local statics_file = STATICS_TMP_PREFIX .. i .. ".prefab.json"
            if prefab.write_statics_only(file, statics_file) then
                source = statics_file
            else
                log("W", LOG_TAG, "statics-only filter failed; loading full prefab '"
                    .. tostring(file) .. "'")
            end
        end
        -- Identity pos/rot/scale: prefab object coords are absolute world-space, so the
        -- container transform is identity (mirrors gameplay/race/path.lua's own spawnPrefab call).
        local ok, obj = pcall(spawnPrefab, name, source, "0 0 0", "0 0 1", "1 1 1")
        if ok and obj then
            spawned[#spawned + 1] = name
        else
            log("W", LOG_TAG, "failed to load prop prefab '" .. tostring(source) .. "': "
                .. tostring(obj))
        end
    end

    -- Only the host instantiates cones, so only the host tracks their ids for cleanup; non-hosts
    -- never spawned any and have nothing to track (ADR-0020).
    local cone_ids = {}
    if keep_cones then
        cone_ids = cones.keep_new(vehicles_before)
    end

    -- Rebuild the static collision mesh so the freshly spawned barriers are solid (spawnPrefab
    -- only does this when the world editor is open). Same call core/dynamicProps uses.
    if #spawned > 0 and be then
        pcall(function() be:reloadCollision(false, true) end)
    end

    log("I", LOG_TAG, string.format("loaded %d prop prefab(s), %d shared cone(s)",
        #spawned, #cone_ids))
    return spawned, cone_ids
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

    -- Rebuild the static collision mesh: removePrefab drops the visual meshes but leaves stale
    -- collision behind, so despawned barriers stay solid otherwise (mirror of the load path).
    if cleared > 0 and be then
        pcall(function() be:reloadCollision(false, true) end)
    end

    log("I", LOG_TAG, string.format("cleared %d prop prefab(s)", cleared))
    return cleared
end

return M
