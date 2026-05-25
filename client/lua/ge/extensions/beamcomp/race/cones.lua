-- BeamComp -- shared race cone-vehicle policy (the prefab's knockable jbeam "cones").
--
-- Lives at lua/ge/extensions/beamcomp/race/cones.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller (race/props.lua + init.lua)
-- owns the tracked cone ids and passes them back. Target: client GE (LuaJIT 5.1).
--
-- Race prefabs ship knockable physics prop-vehicles (jbeam "cones", each with autoEnterVehicle)
-- alongside the static scenery. They must be spawned ONCE for all players, not per-client: in a
-- BeamMP session every spawned vehicle is owned and propagated, so a per-client load made N x 14
-- duplicates. The fix (ADR-0009): exactly one client -- the /race issuer, flagged propOwner by the
-- server -- KEEPS the cones its prefab load creates (M.keep_new); BeamMP syncs them to everyone.
-- Every other client DELETES only its OWN newly-spawned cones (M.delete_owned_new), so the owner's
-- incoming synced cones (not owned locally) are left untouched. The owner clears its set on race
-- end (M.clear), and BeamMP removes them for all clients.
--
-- The cones must never be enterable or clutter the Tab vehicle cycle, on every client. Two layers:
--   * M.enforce_non_enterable -- GUARANTEED: bounce the player off a cone back to the race car.
--     Reactive (driven from init.lua's onVehicleSwitched) and internals-free, so it cannot fail to
--     keep the player out of a cone -- owner-local or remote-synced.
--   * M.exclude_from_cycle -- BEST-EFFORT: try to drop the cone from the Tab cycle entirely. The
--     field a BeamMP-synced remote vehicle honours for switching is unverified (ADR-0009), so this
--     is fully guarded; the bounce above is what actually enforces non-enterability.

local M = {}

local LOG_TAG = "beamcomp.cones"
local CONE_JBEAM = "cones"

-- Whether a vehicle object is one of the race prefab's knockable cone prop-vehicles. This is the
-- single source of cone identity (the spawn loader and the non-enterable policy both ask here).
function M.is_cone(veh)
    return veh ~= nil and veh.JBeam == CONE_JBEAM
end

-- The owned-vehicle id set (as a string-keyed lookup) for the current BeamMP session, or nil
-- outside a session. getOwnMap is BeamMP's MPVehicleGE global listing vehicles whose isLocal is
-- true; its keys and getID() may differ in number/string type, so keys are normalised to strings.
local function owned_id_set()
    if type(getOwnMap) ~= "function" then
        return nil
    end
    local own = getOwnMap()
    if type(own) ~= "table" then
        return nil
    end
    local ids = {}
    for game_vehicle_id in pairs(own) do
        ids[tostring(game_vehicle_id)] = true
    end
    return ids
end

-- The cone vehicles in the scene that did not exist before the load (diffed against
-- `existing_before`, a set of pre-load object ids). When `owned_only` is true the result is
-- restricted to vehicles this client owns. Returns a list of game vehicle ids.
local function new_cone_ids(existing_before, owned_only)
    local ids = {}
    if not be then
        return ids
    end
    local owned = owned_only and owned_id_set() or nil
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and M.is_cone(veh) then
            local id = veh:getID()
            local is_owned = (not owned_only) or (owned ~= nil and owned[tostring(id)])
            if not existing_before[id] and is_owned then
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- OWNER path: keep the cone vehicles this prefab load just created (do not delete them) and return
-- their ids so the caller can track them for cleanup. BeamMP propagates the spawns ('Os:') to every
-- other client, so the owner is the single source of the shared cone set.
function M.keep_new(existing_before)
    local ids = new_cone_ids(existing_before, false)
    log("I", LOG_TAG, string.format("kept %d shared cone(s)", #ids))
    return ids
end

-- NON-OWNER path: delete only the OWNED cones this prefab load just created, leaving the owner's
-- incoming synced cones (not owned here) in place. Returns the count removed.
function M.delete_owned_new(existing_before)
    local ids = new_cone_ids(existing_before, true)
    local removed = 0
    for _, id in ipairs(ids) do
        local veh = be:getObjectByID(id)
        if veh then
            local ok, err = pcall(function() veh:delete() end)
            if ok then
                removed = removed + 1
            else
                log("W", LOG_TAG, "failed to delete own cone " .. tostring(id) .. ": "
                    .. tostring(err))
            end
        end
    end
    log("I", LOG_TAG, string.format("removed %d own cone(s)", removed))
    return removed
end

-- OWNER cleanup: delete the tracked cone vehicles by id. Tolerant of ids whose vehicle is already
-- gone. BeamMP propagates the owned delete ('Od:'), removing them for all clients. Returns the
-- count processed.
function M.clear(ids)
    if type(ids) ~= "table" then
        return 0
    end
    local cleared = 0
    for _, id in ipairs(ids) do
        local veh = be and be:getObjectByID(id)
        if veh then
            pcall(function() veh:delete() end)
        end
        cleared = cleared + 1
    end
    log("I", LOG_TAG, string.format("cleared %d shared cone(s)", cleared))
    return cleared
end

-- GUARANTEED non-enterable: when the player switches into a cone, put them straight back into the
-- race car. Driven from init.lua's onVehicleSwitched, so it fires on every switch -- the player can
-- never stay seated in a cone, owner-local or remote-synced. No-op when the switched-into vehicle
-- is not a cone or no fallback car id is known. Returns true if it bounced the player.
function M.enforce_non_enterable(new_id, fallback_id)
    if not be or new_id == nil or fallback_id == nil then
        return false
    end
    if tostring(new_id) == tostring(fallback_id) then
        return false
    end
    if not M.is_cone(be:getObjectByID(new_id)) then
        return false
    end
    local fallback = be:getObjectByID(fallback_id)
    if not fallback then
        return false
    end
    local ok, err = pcall(function() be:enterVehicle(0, fallback) end)
    if not ok then
        log("W", LOG_TAG, "could not bounce player off cone: " .. tostring(err))
        return false
    end
    log("I", LOG_TAG, "bounced player off cone back to race car")
    return true
end

-- BEST-EFFORT exclusion from the Tab vehicle cycle. The flag a BeamMP-synced remote vehicle honours
-- for player switching is unverified (ADR-0009): this sets the field BeamNG marks non-player parked
-- vehicles with, fully pcall-guarded so a wrong/absent field warns once rather than throwing. The
-- guaranteed bounce above is what actually enforces non-enterability -- CONFIRM in-game whether this
-- keeps the cone out of the cycle, and refine the mechanism (or escalate to the ADR-0009 blocking
-- finding) from the 2-client test. No-op for non-cone vehicles. Returns true if the attempt ran.
function M.exclude_from_cycle(veh)
    if not M.is_cone(veh) then
        return false
    end
    local ok, err = pcall(function() veh:setField("isParkingVehicle", "", "true") end)
    if not ok then
        log("W", LOG_TAG, "exclude_from_cycle attempt failed (field unverified): " .. tostring(err))
        return false
    end
    return true
end

return M
