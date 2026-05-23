-- BeamComp -- race vehicle lifecycle (despawn + own-car respawn on a race start).
--
-- Lives at lua/ge/extensions/beamcomp/race/vehicles.lua inside the client mod zip. Stateless
-- and reload-safe (no M.state, no file-scope mutable state). Target: client GE (LuaJIT 5.1).
--
-- On a race start each client clears the vehicles it owns and spawns one fresh copy of its own
-- car at the grid pose the server assigned it (M.respawn_own_at). Owned-only is deliberate:
-- getOwnMap() (BeamMP's MPVehicleGE) lists vehicles whose isLocal == true, and both deleting
-- and spawning an owned vehicle are propagated to every client by BeamMP -- a delete fires
-- BeamNG's onVehicleDestroyed -> 'Od:', a spawn fires onVehicleSpawned -> 'Os:'. Touching a
-- non-owned (synced) vehicle would desync, so we never do (hence no core_vehicles.removeAll);
-- each client clears and spawns only its own car and the full grid fills in as all do the same.

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

-- Snapshot the player's active vehicle so it can be respawned fresh after the despawn deletes
-- it: model + part config + all three paint layers (mirrors core_vehicles.cloneCurrent).
-- Returns the spec table, or nil when the player has no active vehicle to copy.
local function capture_own_spec()
    if type(getPlayerVehicle) ~= "function" then
        return nil
    end
    local veh = getPlayerVehicle(0)
    if not veh then
        return nil
    end

    local ok, spec = pcall(function()
        local paints = veh:getMetallicPaintData()
        return {
            model = veh.JBeam,
            config = veh.partConfig,
            paint = createVehiclePaint(veh.color, paints[1]),
            paint2 = createVehiclePaint(veh.colorPalette0, paints[2]),
            paint3 = createVehiclePaint(veh.colorPalette1, paints[3]),
        }
    end)
    if not ok then
        log("W", LOG_TAG, "could not read own vehicle spec: " .. tostring(spec))
        return nil
    end
    return spec
end

-- Spawn one vehicle at a grid pose (plain {pos = {x,y,z}, rot = {x,y,z,w}} tables). Uses the
-- captured spec when present, else the engine's default model. Returns the new vehicle, or nil
-- plus a reason.
local function spawn_vehicle_at(pose, spec)
    if type(core_vehicles) ~= "table" or type(core_vehicles.spawnNewVehicle) ~= "function" then
        return nil, "core_vehicles.spawnNewVehicle unavailable"
    end
    local model = (spec and spec.model) or core_vehicles.defaultVehicleModel
    if not model then
        return nil, "no vehicle model to spawn"
    end

    -- spawnNewVehicle wants vec3/quat userdata, not the plain tables myPose carries. Heading
    -- caveat: spawn.setVehicleObject applies a built-in 180-degree Z flip (rot = quat(0,0,1,0)
    -- * rot). We pass the pose rotation straight through; if spawned cars face opposite the
    -- start direction, pre-multiply rot by quat(0,0,1,0) here -- the spawn analogue of
    -- grid.lua's LONGITUDINAL_SIGN, only verifiable in-game.
    local opt = {
        pos = vec3(pose.pos.x, pose.pos.y, pose.pos.z),
        rot = quat(pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w),
    }
    if spec then
        opt.config = spec.config
        opt.paint = spec.paint
        opt.paint2 = spec.paint2
        opt.paint3 = spec.paint3
    end

    -- In an MP session core_vehicles.spawnNewVehicle is BeamMP's spawnRequest, which forwards
    -- this options table unchanged to the original; the spawn then fires onVehicleSpawned,
    -- which BeamMP sends to all clients ('Os:'). No extra call is needed to propagate.
    local ok, veh = pcall(core_vehicles.spawnNewVehicle, model, opt)
    if not ok then
        return nil, "spawn failed: " .. tostring(veh)
    end
    if not veh then
        return nil, "spawn returned no vehicle"
    end
    return veh
end

-- Clear this client's owned vehicles and spawn a fresh copy of its own car at `pose` (the grid
-- start the server assigned). Capturing before the despawn is required, since the despawn
-- deletes the car we copy. Returns the spawned vehicle, or nil plus a reason. BeamMP propagates
-- both the despawn ('Od:') and the spawn ('Os:') to every client. _spawnNewVehicle auto-enters
-- the player, so the despawn's free-cam is superseded.
function M.respawn_own_at(pose)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" or type(pose.rot) ~= "table" then
        return nil, "invalid grid pose"
    end

    local spec = capture_own_spec()
    M.despawn_own()

    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "respawn failed: " .. tostring(reason))
        return nil, reason
    end

    local model_name = (spec and spec.model) or "default"
    log("I", LOG_TAG, string.format("respawned own '%s' at grid (%.1f, %.1f, %.1f)",
        tostring(model_name), pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

return M
