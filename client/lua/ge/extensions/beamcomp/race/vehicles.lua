-- BeamComp -- race vehicle lifecycle (despawn now; spawn lands with item 4).
--
-- Lives at lua/ge/extensions/beamcomp/race/vehicles.lua inside the client mod zip. Stateless
-- and reload-safe (no M.state, no file-scope mutable state). Target: client GE (LuaJIT 5.1).
--
-- Despawns exactly the vehicles this client owns when a race starts, so item 4 can later
-- spawn one fresh vehicle per player at its grid pose. Owned-only is deliberate: getOwnMap()
-- (BeamMP's MPVehicleGE) lists vehicles whose isLocal == true, and deleting an owned vehicle
-- fires BeamNG's onVehicleDestroyed, which BeamMP turns into an 'Od:' message that removes
-- the vehicle on every client. Deleting a non-owned (synced) vehicle would desync, so we
-- never touch other players' cars (hence no core_vehicles.removeAll).

local M = {}

local LOG_TAG = "beamcomp.spawn"

-- Remove every vehicle this client owns in the current multiplayer session. Returns the
-- number deleted (0 is valid), or nil plus a reason when there is no MP session to act in.
function M.despawn_own()
    -- getOwnMap is a BeamMP GE global that exists only inside a multiplayer session.
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end

    local own = getOwnMap()
    if type(own) ~= "table" then
        return nil, "owned-vehicle list unavailable"
    end

    local removed = 0
    for game_vehicle_id in pairs(own) do
        local veh = be:getObjectByID(game_vehicle_id)
        if veh then
            local ok, err = pcall(function() veh:delete() end)
            if ok then
                removed = removed + 1
            else
                log("W", LOG_TAG, "failed to delete vehicle " .. tostring(game_vehicle_id)
                    .. ": " .. tostring(err))
            end
        end
    end

    -- Our camera may be left on a now-deleted vehicle; drop to free-cam when we removed our
    -- car and none of ours remains (item 4 will spawn a fresh one to enter).
    if removed > 0 and type(getPlayerVehicle) == "function" and not getPlayerVehicle(0)
            and commands and commands.setFreeCamera then
        pcall(commands.setFreeCamera)
    end

    log("I", LOG_TAG, string.format("despawned %d own vehicle(s)", removed))
    return removed
end

return M
