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

-- The car spawned when the player starts a race without a real own car to copy (on foot, free-cam, or
-- nothing). Stock config -- model only. Without this the fresh-spawn fallback would copy whatever
-- getPlayerVehicle(0) is (the walking unicycle, or a prop), so the player landed in a non-car.
local DEFAULT_VEHICLE_MODEL = "etk800"

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

-- True when `veh` is a real, race-eligible owned car: present in this client's owned-vehicle map
-- (so BeamMP-safe to touch) and not the walking unicycle. The single definition of "a real own car",
-- shared by resolve_own_car (which car to keep) and capture_own_spec (which spec is worth copying) --
-- it also keeps the shared prop cones out, since they are not owned (ADR-0009).
local function is_owned_race_car(veh)
    if not veh or type(getOwnMap) ~= "function" or not be then
        return false
    end
    if veh.JBeam == "unicycle" then
        return false
    end
    local own = getOwnMap()
    if type(own) ~= "table" then
        return false
    end
    local veh_id = veh:getId()
    for game_vehicle_id in pairs(own) do
        -- Compare as strings: own-map keys and getId() may differ in number/string type.
        if tostring(game_vehicle_id) == tostring(veh_id) then
            return true
        end
    end
    return false
end

-- Snapshot the player's active vehicle so it can be respawned fresh after the despawn deletes
-- it: model + part config + all three paint layers (mirrors core_vehicles.cloneCurrent).
-- Returns the spec table, or nil when the player is not in a real own car worth copying (on foot,
-- free-cam, a prop, or nothing) -- the caller then spawns DEFAULT_VEHICLE_MODEL instead.
local function capture_own_spec()
    if type(getPlayerVehicle) ~= "function" then
        return nil
    end
    local veh = getPlayerVehicle(0)
    if not is_owned_race_car(veh) then
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

-- The orientation quaternion for a grid pose, BEFORE the 180-degree Z flip each placement path
-- applies. Prefer the grid's `forward` travel axis -- face the car down the grid via quatFromDir,
-- the recipe verified in recover_to -- so the car is oriented to the grid, not the authored start
-- quaternion. Fall back to the start rotation (`rot`) when the pose carries no forward (no gate
-- normal). quatFromDir/vec3/quat are engine globals, kept here rather than in the pure grid module.
local function pose_orientation(pose)
    if pose.forward then
        return quatFromDir(vec3(pose.forward.x, pose.forward.y, pose.forward.z), vec3(0, 0, 1))
    end
    return quat(pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w)
end

-- The world position to place the reference point at so the car's FRONT-centre lands on the grid
-- pose, instead of the reference point BeamNG puts there (which sits mid-car, ~on the seats).
--
-- The spawn bounding box is measured from the car's CURRENT, pre-teleport transform -- a
-- getSpawnWorldOOBB read right after setPositionRotation still reflects the old transform, so we must
-- measure before moving. We learn the reference->front-centre offset there (decomposed along the
-- car's current forward/right via the OOBB centre and its forward half-length, getHalfExtents().y),
-- then re-apply it along the grid's target forward/right. This needs no vehicle-local axis or
-- quaternion-flip assumption -- it reads the real geometry and re-projects it. Returns the grid pose
-- unchanged when there is no forward axis or the bbox API is unavailable (keeps the centre anchor).
local function front_anchored_target(veh, pose)
    local base = vec3(pose.pos.x, pose.pos.y, pose.pos.z)
    if not pose.forward then
        return base
    end
    local ok, target = pcall(function()
        local bb = veh:getSpawnWorldOOBB()
        local fwd = veh:getDirectionVector()
        fwd = vec3(fwd.x, fwd.y, 0)
        fwd:normalize()
        local right = vec3(fwd.y, -fwd.x, 0)
        local to_centre = bb:getCenter() - veh:getPosition()
        -- reference -> front-centre, split into the car's own forward (+ half-length) and lateral.
        local forward_dist = to_centre:dot(fwd) + bb:getHalfExtents().y
        local lateral_dist = to_centre:dot(right)
        local target_fwd = vec3(pose.forward.x, pose.forward.y, 0)
        target_fwd:normalize()
        local target_right = vec3(target_fwd.y, -target_fwd.x, 0)
        return base - (target_fwd * forward_dist + target_right * lateral_dist)
    end)
    if ok and target then
        return target
    end
    log("W", LOG_TAG, "front-anchor unavailable; centre-anchoring: " .. tostring(target))
    return base
end

-- Spawn one vehicle at a grid pose (plain {pos, rot, forward?} tables). Uses the captured spec when
-- present, else the engine's default model. Returns the new vehicle, or nil plus a reason.
local function spawn_vehicle_at(pose, spec)
    if type(core_vehicles) ~= "table" or type(core_vehicles.spawnNewVehicle) ~= "function" then
        return nil, "core_vehicles.spawnNewVehicle unavailable"
    end
    local model = (spec and spec.model) or DEFAULT_VEHICLE_MODEL
    if not model then
        return nil, "no vehicle model to spawn"
    end

    -- spawnNewVehicle wants vec3/quat userdata, not the plain tables myPose carries. Heading caveat:
    -- spawn.setVehicleObject applies a built-in 180-degree Z flip (rot = quat(0,0,1,0) * rot), so we
    -- pass pose_orientation straight through -- the internal flip then turns a forward-derived
    -- quatFromDir into a car facing down the grid, matching repair_and_place's explicit flip.
    local opt = {
        pos = vec3(pose.pos.x, pose.pos.y, pose.pos.z),
        rot = pose_orientation(pose),
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

    -- The owned, non-unicycle vehicle object for `id`, or nil.
    local function owned_car(id)
        if id == nil then
            return nil
        end
        local veh = be:getObjectByID(tonumber(id) or id)
        if is_owned_race_car(veh) then
            return veh
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
    local rot = quat(0, 0, 1, 0) * pose_orientation(pose)
    -- Front-anchor the car: measure the target from its current transform BEFORE teleporting (the
    -- world bbox is stale right after setPositionRotation), then place once.
    local pos = front_anchored_target(veh, pose)
    veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
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
    if not spec then
        log("I", LOG_TAG, "no own car to copy; spawning default vehicle '" .. DEFAULT_VEHICLE_MODEL
            .. "' at grid")
    end
    M.despawn_own()

    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "respawn failed: " .. tostring(reason))
        return nil, reason
    end

    local model_name = (spec and spec.model) or DEFAULT_VEHICLE_MODEL
    log("I", LOG_TAG, string.format("spawned fresh own '%s' at grid (%.1f, %.1f, %.1f)",
        tostring(model_name), pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

-- Teleport + repair a vehicle to a recover pose: `pos` ({x,y,z}) facing along `dir` ({x,y,z}, world
-- up). Like repair_and_place, veh:setPositionRotation resets the car to its undamaged rest state at
-- the pose, and the same 180-degree Z-flip (quat(0,0,1,0) * ...) matches the engine's repair branch
-- (verified in-game for grid placement). A nil/degenerate dir keeps the car's current heading. Used
-- by the recover-to-last-checkpoint assist (ADR-0017). Returns true, or nil plus a reason.
function M.recover_to(veh, pos, dir)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pos) ~= "table" then
        return nil, "invalid recover pose"
    end
    local ok, err = pcall(function()
        if dir then
            local base = quatFromDir(vec3(dir.x, dir.y, dir.z), vec3(0, 0, 1))
            local rot = quat(0, 0, 1, 0) * base
            veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        else
            local rot = quat(veh:getRotation())
            veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        end
    end)
    if not ok then
        return nil, "recover_to failed: " .. tostring(err)
    end
    return true
end

-- Best-effort "has this car been modified from stock parts" check for the records vehicle field
-- (ADR-0027). Reads veh.partConfig (the same field capture_own_spec copies, so it is known to work
-- under BeamMP): a string is a named preset config (.pc file) -> stock/preset, a table is an inline,
-- customized parts blob -> modified. Returns nil (unknown) when the field is absent or any other type,
-- so the server stores "unknown" rather than a guess. Heuristic -- confirm the string/table split
-- in-game at handover.
local function detect_modified(veh)
    local ok, part_config = pcall(function() return veh.partConfig end)
    if not ok or part_config == nil then
        return nil
    end
    if type(part_config) == "string" then
        return false
    end
    if type(part_config) == "table" then
        return true
    end
    return nil
end

-- Collect this client's vehicle metadata for the server's best-times records (ADR-0027). `veh` is the
-- resolved race car (the caller already holds it). Every engine read is pcall-guarded and degrades to
-- nil: the BeamNG globals for vehicle details are UNVERIFIED under BeamMP, so any gap yields a nil field
-- rather than an error -- the server stores nil vehicle fields. Player identity is no longer collected
-- here -- it is reported separately on connect (ADR-0031). Returns {vehicle = {model, type, variant,
-- modified}}.
function M.collect_client_info(veh)
    local info = {vehicle = {model = nil, type = nil, variant = nil, modified = nil}}
    if not veh then
        return info
    end

    -- Vehicle model: the JBeam name (e.g. "etk800"), read straight off the handle like elsewhere here.
    local ok_model, model = pcall(function() return veh.JBeam end)
    if ok_model and type(model) == "string" and model ~= "" then
        info.vehicle.model = model
    end

    -- Vehicle type/class: the model's body style / type from its details, keyed by the vehicle id.
    local ok_type, vtype = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleDetails) == "function" then
            local details = core_vehicles.getVehicleDetails(veh:getId())
            local model_info = details and details.model
            if type(model_info) == "table" then
                return model_info.Type or model_info["Body Style"]
            end
        end
        return nil
    end)
    if ok_type and type(vtype) == "string" and vtype ~= "" then
        info.vehicle.type = vtype
    end

    -- Vehicle variant: the named partConfig preset (e.g. "etk800_300d") when the car is a stock/preset
    -- config (partConfig is a string); nil for an inline-customized parts blob, which buckets under the
    -- model alone for records (ADR-0029). Same field detect_modified reads, so it is known to work here.
    local ok_variant, part_config = pcall(function() return veh.partConfig end)
    if ok_variant and type(part_config) == "string" and part_config ~= "" then
        info.vehicle.variant = part_config
    end

    info.vehicle.modified = detect_modified(veh)

    return info
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
