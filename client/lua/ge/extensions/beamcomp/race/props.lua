-- BeamComp -- race props: the track's scenery prefabs (load + clear) AND the shared seat policy that
-- keeps the player out of every prop vehicle those prefabs bring along.
--
-- Lives at lua/ge/extensions/beamcomp/race/props.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller owns the list of spawned
-- object names and passes it back to M.clear. Target: client GE (LuaJIT 5.1).
--
-- This is also the one module that knows EVERY prop identity -- it already requires race/cones.lua
-- (knockable cones) and race/grinders.lua (powered grinders) -- which is why the reactive seat policy
-- lives here rather than in either of them (see the "race-prop seat policy" section at the bottom, and
-- bug race-prop-steals-player-seat).
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
local grinders = require("beamcomp/race/grinders")
local prefab = require("beamcomp/race/prefab")
local vehiclespecs = require("beamcomp/race/vehiclespecs")

local LOG_TAG = "beamcomp.props"
local PROP_NAME_PREFIX = "beamcomp_prop_"
-- The host's cones-only prefab containers get their own name prefix so they are tracked and cleared
-- alongside the statics, without colliding with the PROP_NAME_PREFIX names (ADR-0025).
local CONE_PROP_NAME_PREFIX = "beamcomp_cone_"

-- Where the filtered prefab copies are written (one per source prefab index). BeamNG temp vpaths,
-- overwritten each load -- no cleanup needed. statics-only for the non-host barriers, cones-only for
-- the host's quickrace cone source, cone-capped for the host's mission prefabs.
local STATICS_TMP_PREFIX = "/temp/beamcomp_statics_"
local CONES_TMP_PREFIX = "/temp/beamcomp_cones_"
local CAPPED_TMP_PREFIX = "/temp/beamcomp_capped_"

-- The host caps the number of cone prop-vehicles it instantiates from a mission prefab (ADR-0020
-- amendment). A cone-rich time-trial track (wcusa trackAttack_002/003: 72/81 cones vs 33 in the working
-- _001) otherwise spawns every cone as a real, BeamMP-propagated vehicle synchronously, and a burst of
-- 70+ hangs the BeamMP race start so handle_race_start never completes (no timer/countdown/AI). This is
-- NOT the MaxCars cap (reproduced at MaxCars=256) -- it is the act of spawning that many vehicles at
-- once, so a fixed conservative cap is the fix, not a count limit. 48 = first bet: 33 is proven to work,
-- 72 hangs; it also stays under a default MaxCars of 64. Kept as a single constant so it drops trivially
-- if 48 still hangs in the in-game test. Non-cone objects (statics/decals/SimGroup) are always kept;
-- only cones beyond the cap are dropped.
local MAX_CONE_VEHICLES = 48

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
-- `cone_files` is the host-only quickrace cone source (ADR-0025): a separate track prefab whose cone
-- vehicles the host spawns from a cones-only copy (so it does not re-spawn the track's statics/spheres);
-- empty for missions, whose cones ride inside `prefab_files`. Non-hosts never spawn it.
-- Returns the list of prefab names spawned (for prefab cleanup), the list of kept cone vehicle ids
-- (empty unless host; for cone cleanup), and the list of kept powered-prop vehicle ids (the grinders --
-- empty unless host, ADR-0020 amendment). One bad prefab warns and is skipped rather than aborting.
--
-- NOTE on the two id lists: BeamMP deletes and re-spawns a freshly spawned prop-vehicle under a NEW id a few
-- seconds later, as part of its ownership/sync round-trip, so both lists go stale (measured, bug
-- race-prop-steals-player-seat round 3). The grinder list is therefore only a SEED for the activation window,
-- which re-derives the live set from the scene, and grinder cleanup scans the scene instead
-- (grinders.clear_scene). The CONE list is still used as-is by cones.clear and so has the same latent flaw --
-- deliberately left alone in that item's scope and filed separately; the cone bounce and the cone nametag
-- suppression are unaffected because both are driven by live hooks rather than by these ids.
function M.load(prefab_files, keep_cones, cone_files)
    if type(spawnPrefab) ~= "function" or type(removePrefab) ~= "function" then
        log("W", LOG_TAG, "spawnPrefab/removePrefab unavailable -- cannot load props")
        return {}, {}, {}
    end
    if type(prefab_files) ~= "table" then
        return {}, {}, {}
    end

    local vehicles_before = current_vehicle_ids()

    local spawned = {}
    for i, file in ipairs(prefab_files) do
        local name = PROP_NAME_PREFIX .. i
        -- Clear the name first: addPrefab refuses an existing name, and this also reaps any
        -- orphan from a prior load whose tracked names were lost (e.g. a hard reload).
        pcall(removePrefab, name)
        -- Filter the JSONL mission prefabs (ADR-0020); a legacy .prefab (the cone-free quickrace
        -- barriers, ADR-0024) has no cone vehicles and is spawned full on every client -- routing its
        -- TorqueScript through the JSONL filter would corrupt it, so only .prefab.json files are filtered.
        --   * Non-hosts spawn a STATICS-ONLY copy so the cone vehicles are never created (ADR-0020).
        --   * The host spawns a CONE-CAPPED copy: statics + at most MAX_CONE_VEHICLES cones, the overflow
        --     dropped, so a cone-rich track's 70+ synchronous cone spawns can't hang the BeamMP race start
        --     (ADR-0020 amendment). Under the cap it is content-identical to the full prefab.
        -- Either filter degrades to the full prefab (logged) rather than leaving the client with no
        -- barriers / the host with no cones.
        local source = file
        if file:find("%.prefab%.json$") then
            if keep_cones then
                local capped_file = CAPPED_TMP_PREFIX .. i .. ".prefab.json"
                if prefab.write_capped(file, capped_file, MAX_CONE_VEHICLES) then
                    source = capped_file
                else
                    log("W", LOG_TAG, "cone-cap filter failed; loading full prefab '"
                        .. tostring(file) .. "'")
                end
            else
                local statics_file = STATICS_TMP_PREFIX .. i .. ".prefab.json"
                if prefab.write_statics_only(file, statics_file) then
                    source = statics_file
                else
                    log("W", LOG_TAG, "statics-only filter failed; loading full prefab '"
                        .. tostring(file) .. "'")
                end
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

    -- Host only: spawn a cones-only copy of each quickrace cone source so the cone vehicles exist once
    -- for BeamMP to sync, without re-spawning the statics/spheres/waypoints the source prefab also
    -- contains (ADR-0025). Non-hosts never reach here, so they never instantiate a quickrace cone.
    if keep_cones and type(cone_files) == "table" then
        for i, file in ipairs(cone_files) do
            local name = CONE_PROP_NAME_PREFIX .. i
            pcall(removePrefab, name)
            local dest_ext = file:find("%.prefab%.json$") and ".prefab.json" or ".prefab"
            local cones_file = CONES_TMP_PREFIX .. i .. dest_ext
            if prefab.write_cones_only(file, cones_file) then
                local ok, obj = pcall(spawnPrefab, name, cones_file, "0 0 0", "0 0 1", "1 1 1")
                if ok and obj then
                    spawned[#spawned + 1] = name
                else
                    log("W", LOG_TAG, "failed to load cone prefab '" .. tostring(cones_file) .. "': "
                        .. tostring(obj))
                end
            end
        end
    end

    -- Only the host instantiates the prefab's prop-vehicles, so only the host tracks their ids for
    -- cleanup; non-hosts never spawned any and have nothing to track (ADR-0020/0025). keep_new diffs
    -- every new cone vehicle in the scene, so it captures both a mission's full-prefab cones and the
    -- quickrace cones-only spawn above.
    local cone_ids = {}
    local grinder_ids = {}
    if keep_cones then
        cone_ids = cones.keep_new(vehicles_before)
        -- Powered props (the GridMap GrinderGrandPrix grinders, jbeam "large_spinner"): the NEW grinder
        -- prop-vehicles the full-prefab spawn created (ADR-0020 amendment). Just identify + return them;
        -- the caller (init.lua) drives their motor over a short readiness window after spawn -- the
        -- `spinner` controller only exists once the fresh VE's powertrain is up -- and clears them on race
        -- end / re-issue exactly like the cones. BeamMP syncs the resulting rotation to every client.
        grinder_ids = grinders.keep_new(vehicles_before)
    end

    -- Rebuild the static collision mesh so the freshly spawned barriers are solid (spawnPrefab
    -- only does this when the world editor is open). Same call core/dynamicProps uses.
    if #spawned > 0 and be then
        pcall(function() be:reloadCollision(false, true) end)
    end

    log("I", LOG_TAG, string.format("loaded %d prop prefab(s), %d shared cone(s), %d powered prop(s)",
        #spawned, #cone_ids, #grinder_ids))
    return spawned, cone_ids, grinder_ids
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


-- ===== race-prop seat policy ==============================================================
-- A race prefab's prop-vehicles are real, enterable vehicles: the cones carry autoEnterVehicle, and the
-- GridMap GrinderGrandPrix grinders auto-enter once their VE finishes loading -- AFTER the own car has
-- been placed, which is how the player ended up driving a rotating morning-star for a whole race (bug
-- race-prop-steals-player-seat). The guarantee is a REACTIVE bounce off any prop, in any phase; it
-- touches nothing on the prop itself, so a grinder keeps spinning (ADR-0020 amendment).

-- Whether a vehicle is one of the race's PROPS -- something the player must never sit in. Two layers:
--   * GUARANTEED, jbeam-keyed: a knockable cone (cones.is_cone) or a powered grinder
--     (grinders.is_grinder). Exact identities read straight off the vehicle, so the concrete reported
--     cases stay fixed even when model metadata is unreadable.
--   * WIDENED, metadata-keyed, only while a race is running (`race_active`): any model the engine
--     reports as a KNOWN non-car (Prop/Trailer via vehiclespecs.is_known_non_car -- the same test
--     race/vehicles.lua's is_owned_race_car already uses). This covers a FUTURE prefab prop whose jbeam
--     is neither "cones" nor "large_spinner". An unreadable Type counts as a car there, so the widening
--     can only ever ADD a known non-car, never drop a real one. It is race-gated because outside a race
--     a Trailer-type vehicle is a legitimate free-roam vehicle the player may own and switch into.
function M.is_race_prop(veh, race_active)
    if veh == nil then
        return false
    end
    if cones.is_cone(veh) or grinders.is_grinder(veh) then
        return true
    end
    return race_active == true and vehiclespecs.is_known_non_car(veh.JBeam)
end

-- The vehicle to bounce into for candidate `id`, or nil when the candidate is absent, is the prop the
-- player just landed in (`prop_id` -- bouncing a vehicle into itself is not a bounce), or no longer
-- resolves. Ids are compared as strings: tracked ids and getID() may differ in number/string type (the
-- same rule the AI bounce uses).
local function fallback_car(id, prop_id)
    if not be or id == nil or tostring(id) == tostring(prop_id) then
        return nil
    end
    return be:getObjectByID(id)
end

-- GUARANTEED non-enterable: when the player lands in a race prop -- by the engine's auto-enter after the
-- prefab spawn, via the Tab cycle, or from a BeamMP-synced spawn -- put them straight back into a real
-- car. Reactive (driven from init.lua's onVehicleSwitched) and internals-free, so it cannot fail to keep
-- the player out of a prop, owner-local or remote-synced, in any phase. Candidates are tried in order:
-- `preferred_id` (the assigned race car) first, then `alternate_id` (the last tracked seated car); a
-- candidate whose vehicle is gone is skipped, and NO resolvable candidate is a no-op -- the player is
-- never trapped, the rule every BeamComp bounce follows. Returns true if it bounced the player.
function M.enforce_non_enterable(new_id, preferred_id, alternate_id)
    local fallback = fallback_car(preferred_id, new_id) or fallback_car(alternate_id, new_id)
    if not fallback then
        return false
    end
    local ok, err = pcall(function() be:enterVehicle(0, fallback) end)
    if not ok then
        log("W", LOG_TAG, "could not bounce player off a race prop: " .. tostring(err))
        return false
    end
    log("I", LOG_TAG, "bounced player off a race prop back into their car")
    return true
end

return M
