-- BeamComp -- race vehicle lifecycle (despawn + own-car respawn on a race start).
--
-- Lives at lua/ge/extensions/beamcomp/race/vehicles.lua inside the client mod zip. Stateless
-- and reload-safe (no M.state, no file-scope mutable state). Target: client GE (LuaJIT 5.1).
--
-- On a race start each client places its own car at the grid pose the server assigned it
-- (M.respawn_own_at, ADR-0007). Primary path: if the player is already in a real owned car, keep
-- it -- repair + teleport it in place and despawn only the OTHER owned cars -- so its runtime state
-- (ESC / drive-mode, customization) survives. Fallback (no real own car): despawn all and spawn a
-- fresh one. Owned-only is deliberate: getOwnMap() (BeamMP's MPVehicleGE) lists vehicles whose
-- isLocal == true, and deleting / spawning / teleporting an owned vehicle is propagated to every
-- client by BeamMP (delete -> 'Od:', spawn -> 'Os:', teleport via normal position sync). Touching a
-- non-owned (synced) vehicle would desync, so we never do; each client handles only its own car and
-- the full grid fills in as all do the same.

local M = {}

local LOG_TAG = "beamcomp.spawn"

-- Delete every owned vehicle except `keep_id` (pass nil to delete all). Returns the count deleted
-- (0 is valid), or nil plus a reason when there is no MP session to act in. Shared by despawn_own
-- and despawn_owned_except. getOwnMap is a BeamMP GE global that exists only inside an MP session;
-- the delete is propagated to all clients by BeamMP (onVehicleDestroyed -> 'Od:').
local function delete_owned_except(keep_id)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end

    local own = getOwnMap()
    if type(own) ~= "table" then
        return nil, "owned-vehicle list unavailable"
    end

    local removed = 0
    for game_vehicle_id in pairs(own) do
        -- Compare as strings: own-map keys and getId() may differ in number/string type.
        if tostring(game_vehicle_id) ~= tostring(keep_id) then
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
    end

    return removed
end

-- Remove every vehicle this client owns in the current multiplayer session. Returns the
-- number deleted (0 is valid), or nil plus a reason when there is no MP session to act in.
function M.despawn_own()
    local removed, reason = delete_owned_except(nil)
    if not removed then
        return nil, reason
    end

    -- Our camera may be left on a now-deleted vehicle; drop to free-cam when we removed our
    -- car and none of ours remains (the fresh-spawn fallback will spawn one to enter).
    if removed > 0 and type(getPlayerVehicle) == "function" and not getPlayerVehicle(0)
            and commands and commands.setFreeCamera then
        pcall(commands.setFreeCamera)
    end

    log("I", LOG_TAG, string.format("despawned %d own vehicle(s)", removed))
    return removed
end

-- Remove every owned vehicle EXCEPT `keep_id` -- used by the keep+repair+teleport path to clear the
-- player's other cars while leaving the one they sit in untouched (no free-cam drop: the seated car
-- stays). Returns the count deleted, or nil plus a reason.
function M.despawn_owned_except(keep_id)
    local removed, reason = delete_owned_except(keep_id)
    if not removed then
        return nil, reason
    end

    log("I", LOG_TAG, string.format("despawned %d other own vehicle(s)", removed))
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

-- Return the car the player is currently in, iff it is a real owned car worth keeping for the race
-- (in the owned-vehicle map and not the walking unicycle); else nil (which selects the fresh-spawn
-- fallback). Owned membership is what makes it BeamMP-safe to touch.
--
-- `preferred_id` is the vehicle the player last switched into, tracked GE-side via onVehicleSwitched
-- (see init.lua). This is REQUIRED in BeamMP: the polling APIs (getPlayerVehicle(0) /
-- be:getPlayerVehicle(0)) stick to the FIRST owned car and do not follow later spawns/switches, so
-- without the tracked id the race start keeps the wrong car when several are spawned (confirmed
-- in-game: only the tracked-id version works). Falls back to be:getPlayerVehicle(0) when no tracked
-- id is owned/valid (single car, or right after load).
function M.resolve_own_car(preferred_id)
    if not be or type(getOwnMap) ~= "function" then
        return nil
    end
    local own = getOwnMap()
    if type(own) ~= "table" then
        return nil
    end

    -- The owned, non-unicycle vehicle object for `id`, or nil.
    local function owned_car(id)
        if id == nil then
            return nil
        end
        for game_vehicle_id in pairs(own) do
            if tostring(game_vehicle_id) == tostring(id) then
                local veh = be:getObjectByID(game_vehicle_id)
                if veh and veh.JBeam ~= "unicycle" then
                    return veh
                end
                return nil
            end
        end
        return nil
    end

    local seated = owned_car(preferred_id)
    if seated then
        return seated
    end
    local pv = be:getPlayerVehicle(0)
    return owned_car(pv and pv:getId())
end

-- Repair + teleport a vehicle to a grid pose. veh:setPositionRotation resets the vehicle to its
-- undamaged rest state at the new pose -- BeamNG's own race-start repair path
-- (gameplay/race/startPosition.lua). The 180-degree Z flip (quat(0,0,1,0) * rot) matches the flip
-- the spawn path applies internally and the engine's repair branch applies explicitly; verified
-- in-game at handover.
local function repair_and_place(veh, pose)
    local rot = quat(0, 0, 1, 0) * quat(pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w)
    veh:setPositionRotation(pose.pos.x, pose.pos.y, pose.pos.z, rot.x, rot.y, rot.z, rot.w)
end

-- Place this client's own car at `pose` (the grid start the server assigned). Two paths (ADR-0007):
-- if `own_car` is the player's seated owned car (resolved by the caller via M.resolve_own_car with
-- the onVehicleSwitched-tracked id), keep it -- despawn only the OTHER owned cars, then repair +
-- teleport the kept car in place (preserving ESC/drive-mode and customization); otherwise fall back
-- to a fresh spawn (despawn all, spawn a new car). Returns the resolved race car (the caller enters
-- + freezes it), or nil plus a reason. BeamMP propagates the despawn ('Od:'), spawn ('Os:'), and the
-- kept car's teleport (via normal owned-vehicle position sync).
function M.respawn_own_at(pose, own_car)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" or type(pose.rot) ~= "table" then
        return nil, "invalid grid pose"
    end

    if own_car then
        M.despawn_owned_except(own_car:getId())
        local ok, err = pcall(repair_and_place, own_car, pose)
        if not ok then
            log("W", LOG_TAG, "repair+teleport failed: " .. tostring(err))
            return nil, "repair+teleport failed: " .. tostring(err)
        end
        log("I", LOG_TAG, string.format("kept + placed own car id=%s at grid (%.1f, %.1f, %.1f)",
            tostring(own_car:getId()), pose.pos.x, pose.pos.y, pose.pos.z))
        return own_car
    end

    -- Fallback: no real own car (free-cam / walking / none) -- spawn a fresh one. Capturing before
    -- the despawn is required, since the despawn deletes the car we copy.
    local spec = capture_own_spec()
    M.despawn_own()

    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "respawn failed: " .. tostring(reason))
        return nil, reason
    end

    local model_name = (spec and spec.model) or "default"
    log("I", LOG_TAG, string.format("spawned fresh own '%s' at grid (%.1f, %.1f, %.1f)",
        tostring(model_name), pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

-- Freeze or release a vehicle in place using BeamNG's built-in controller.setFreeze -- the same
-- lock the base game's quickrace / scenario countdowns use (e.g. scenario/quickRace.lua,
-- gameplay/race/race.lua). It holds the car put while still letting the player rev and steer. The
-- command is queued to the vehicle's VE VM, so it applies even when the car was just spawned and
-- its VE is still coming up. Owned-only by construction: the caller passes its own vehicle (the
-- freshly spawned handle, or getPlayerVehicle(0)), so no remote car is ever touched. Returns true,
-- or nil plus a reason.
function M.set_vehicle_frozen(veh, frozen)
    if not veh then
        return nil, "no vehicle"
    end
    local mode = frozen and 1 or 0
    local ok, err = pcall(function()
        veh:queueLuaCommand("controller.setFreeze(" .. mode .. ")")
    end)
    if not ok then
        return nil, "setFreeze failed: " .. tostring(err)
    end
    return true
end

return M
