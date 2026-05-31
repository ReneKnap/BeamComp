-- BeamComp -- shared race cone-vehicle policy (the prefab's knockable jbeam "cones").
--
-- Lives at lua/ge/extensions/beamcomp/race/cones.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller (race/props.lua + init.lua)
-- owns the tracked cone ids and passes them back. Target: client GE (LuaJIT 5.1).
--
-- Race prefabs ship knockable physics prop-vehicles (jbeam "cones", each with autoEnterVehicle)
-- alongside the static scenery. They must exist ONCE for all players, not per-client: in a BeamMP
-- session every spawned vehicle is owned and propagated, so a per-client load made N x 14 duplicates.
-- The fix (ADR-0020, superseding ADR-0009): non-hosts spawn a statics-only prefab (race/prefab.lua)
-- and never instantiate a cone at all; only the host -- the /race issuer, flagged propOwner by the
-- server -- spawns the full prefab and KEEPS the cones its load creates (M.keep_new), which BeamMP
-- syncs to everyone. The host clears its set on race end (M.clear), and BeamMP removes them for all.
-- (The earlier non-host "delete your own cones" path is gone: it relied on BeamMP's getOwnMap()
-- ownership, which a freshly-spawned cone is not yet in synchronously, so it deleted nothing.)
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

-- The cone vehicles in the scene that did not exist before the load (diffed against
-- `existing_before`, a set of pre-load object ids). Returns a list of game vehicle ids. Scene
-- presence is synchronous after spawnPrefab (unlike BeamMP ownership), so the host's diff is
-- reliable here.
local function new_cone_ids(existing_before)
    local ids = {}
    if not be then
        return ids
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and M.is_cone(veh) then
            local id = veh:getID()
            if not existing_before[id] then
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- HOST path: keep the cone vehicles this prefab load just created (do not delete them) and return
-- their ids so the caller can track them for cleanup. BeamMP propagates the spawns ('Os:') to every
-- other client, so the host is the single source of the shared cone set (ADR-0020).
function M.keep_new(existing_before)
    local ids = new_cone_ids(existing_before)
    log("I", LOG_TAG, string.format("kept %d shared cone(s)", #ids))
    return ids
end

-- HOST cleanup: delete the tracked cone vehicles by id. Tolerant of ids whose vehicle is already
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

-- Suppress BeamMP's floating player-nametag + "spawned a vehicle" label on a synced cone (ADR-0020,
-- finding #2). BeamMP's nametag draw loop skips a vehicle whose MPVehicleGE Vehicle entry has
-- `hideNametag` set; BeamMP never sets the field itself, so it is the sanctioned per-vehicle opt-out.
-- Best-effort, fully guarded: a freshly synced cone may not be registered in MPVehicleGE yet at spawn
-- time, in which case this no-ops (the accepted fallback is that the tag stays). No-op for non-cones
-- or outside a BeamMP session. Returns true if the tag was hidden.
function M.hide_nametag(veh)
    if not M.is_cone(veh) then
        return false
    end
    if type(MPVehicleGE) ~= "table" or type(MPVehicleGE.getVehicleByGameID) ~= "function" then
        return false
    end
    local ok, hidden = pcall(function()
        local entry = MPVehicleGE.getVehicleByGameID(veh:getID())
        if type(entry) == "table" then
            entry.hideNametag = true
            return true
        end
        return false
    end)
    if not ok then
        log("W", LOG_TAG, "hide_nametag attempt failed: " .. tostring(hidden))
        return false
    end
    return hidden
end

return M
