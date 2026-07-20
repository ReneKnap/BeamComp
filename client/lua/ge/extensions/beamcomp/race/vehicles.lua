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

local vehiclespecs = require("beamcomp/race/vehiclespecs")

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
-- (so BeamMP-safe to touch), not the walking unicycle, and not a known non-car prop/trailer. The single
-- definition of "a real own car", shared by resolve_own_car (which car to keep) and capture_own_spec (which
-- spec is worth copying) -- it also keeps the shared prop cones out, since they are not owned (ADR-0009).
-- The non-car guard (ADR-0032 amendment) closes the prop/"Stange" leak: a player focused on an OWNED prop
-- (a barrier/trailer they spawned) must not have it copied and re-spawned as their race car -- they fall
-- through to a fresh default car instead. An unreadable Type still counts as a car (is_known_non_car drops
-- only a KNOWN non-car), so a car with missing metadata is never wrongly rejected.
local function is_owned_race_car(veh)
    if not veh or type(getOwnMap) ~= "function" or not be then
        return false
    end
    if veh.JBeam == "unicycle" then
        return false
    end
    if vehiclespecs.is_known_non_car(veh.JBeam) then
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

-- (public) Snapshot a spawned car as a spec table -- model + part config + all three paint layers (mirrors
-- core_vehicles.cloneCurrent) -- the shape spawn_vehicle_at and replace_spec consume. Returns the spec, or
-- nil when the read fails. pcall-guarded (the paint/handle reads are engine-boundary). Used by the staging
-- compliance gate (init.lua) to remember the last compliant car to revert an over-cap swap back to;
-- capture_own_spec wraps it with the owned-car guard.
function M.capture_spec(veh)
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
        log("W", LOG_TAG, "could not read vehicle spec: " .. tostring(spec))
        return nil
    end
    return spec
end

-- (public) Snapshot a spawned car's model + part config as the {model, config} the "same as host" AI mode
-- inherits (aicar=host, ADR-0036). Unlike capture_spec this skips paint: the AI spawn seam (M.spawn_at)
-- takes only model+config -- stock paint, like every other AI car -- so a paint-read failure must never
-- block the inherit. `config` may be a string (a named .pc preset, e.g. "846_340_A") or an inline parts
-- table (a tuned car); either rides straight into spawn_at. pcall-guarded (the field reads are the
-- engine-boundary reads capture_spec uses). Returns the spec, or nil when there is no vehicle or the model
-- is unreadable -- the caller then falls through the normal AI-car chain so the AI still races.
function M.host_car_spec(veh)
    if not veh then
        return nil
    end
    local ok, spec = pcall(function()
        return {model = veh.JBeam, config = veh.partConfig}
    end)
    if not ok or type(spec.model) ~= "string" or spec.model == "" then
        return nil
    end
    return spec
end

-- Snapshot the player's active vehicle so it can be respawned fresh after the despawn deletes it.
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
    return M.capture_spec(veh)
end

-- (public) Replace a SPAWNED car in place with a captured spec (same vehicle id) -- restoring model +
-- config + paint -- via core_vehicles.replaceVehicle. Unlike respawn_own_at this touches NO other owned
-- vehicle (respawn_own_at -> keep_own despawns the player's other cars, which on the host include the AI
-- field), so it is the safe primitive for reverting an over-cap staging swap (ADR-0032). During staging the
-- replaceVehicle it calls is the lock's swap-allowed pass-through, so the normal restage re-freezes +
-- re-places the reverted car. pcall-guarded (replaceVehicle is engine-version-coupled). Returns true, or
-- nil plus a reason.
function M.replace_spec(veh, spec)
    if not veh then
        return nil, "no vehicle"
    end
    if type(spec) ~= "table" or not spec.model then
        return nil, "no spec to apply"
    end
    if type(core_vehicles) ~= "table" or type(core_vehicles.replaceVehicle) ~= "function" then
        return nil, "core_vehicles.replaceVehicle unavailable"
    end
    local opt = {
        config = spec.config,
        paint = spec.paint,
        paint2 = spec.paint2,
        paint3 = spec.paint3,
    }
    local ok, err = pcall(core_vehicles.replaceVehicle, spec.model, opt)
    if not ok then
        return nil, "replaceVehicle failed: " .. tostring(err)
    end
    return true
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
-- pose (horizontally) and its wheels sit ON the surface (vertically), instead of the reference point
-- BeamNG puts there (which sits mid-car, ~on the seats -- above the wheels).
--
-- The spawn bounding box is measured from the car's CURRENT, pre-teleport transform -- a
-- getSpawnWorldOOBB read right after setPositionRotation still reflects the old transform, so we must
-- measure before moving. We learn the reference->front-centre offset there (decomposed along the
-- car's current forward/right via the OOBB centre and its forward half-length, getHalfExtents().y),
-- then re-apply it along the grid's target forward/right. This needs no vehicle-local axis or
-- quaternion-flip assumption -- it reads the real geometry and re-projects it.
--
-- The SAME OOBB read also anchors the Z axis: the grid pose Z is the grounded surface (placement.lua,
-- ADR-0034) with the reference point placed there, but the reference sits above the wheels, so a
-- taller car buried its wheels below the surface. We instead place the bounding-box BOTTOM at the
-- grounded Z, so wheels of any size car meet the surface. Returns the grid pose unchanged when there
-- is no forward axis or the bbox API is unavailable (keeps the centre anchor -- today's behaviour).
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
        local horizontal = base - (target_fwd * forward_dist + target_right * lateral_dist)
        -- Vertical anchor: horizontal.z is still base.z (the grounded grid Z, already lifted by
        -- placement.GROUND_CLEARANCE). bottom_offset is the reference -> bbox-bottom Z; subtracting it
        -- lifts the reference so the bbox bottom -- not the mid-car reference -- lands on the surface.
        local bottom_offset = to_centre.z - bb:getHalfExtents().z
        return vec3(horizontal.x, horizontal.y, horizontal.z - bottom_offset)
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

-- Build a PRIMARY vehicle paint layer from an opaque roster colour token (ADR-0047, round 3): a hex
-- string "rrggbb" (optionally #-prefixed) -> createVehiclePaint({x = r, y = g, z = b, w = 1}). Only the
-- primary layer is built; the caller leaves paint2/paint3 nil so those stay stock. Returns the paint
-- object, or nil for a nil/blank/invalid colour or when the paint API is unavailable -- the spawn then
-- uses stock paint. Fully guarded: a paint failure must never block an AI spawn (degrade to stock + log).
-- A bad hex is logged; a simply-absent createVehiclePaint API degrades silently (nothing to paint with).
--
-- The colour MUST be field-addressable ({x, y, z, w}), NOT an array {r, g, b, 1}: engine createVehiclePaint
-- (ge_utils.lua) reads color.x/.y/.z/.w and silently falls back to WHITE when color.x is nil, so an array
-- token would paint every AI white. This mirrors the proven player-paint path, which passes veh.color (a
-- field-addressable engine colour) into the same createVehiclePaint.
local function paint_from_color(color)
    if type(color) ~= "string" or color == "" then
        return nil
    end
    local hex = color:gsub("^#", "")
    if not hex:match("^%x%x%x%x%x%x$") then
        log("W", LOG_TAG, "invalid roster colour '" .. color .. "'; spawning stock paint")
        return nil
    end
    if type(createVehiclePaint) ~= "function" then
        return nil
    end
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    local ok, paint = pcall(createVehiclePaint, {x = r, y = g, z = b, w = 1})
    if not ok or not paint then
        log("W", LOG_TAG, "createVehiclePaint failed for '" .. color .. "'; spawning stock paint")
        return nil
    end
    return paint
end

-- Spawn one vehicle at a grid pose with a chosen model[:config], returning the new vehicle (or nil +
-- reason). The public seam over the internal spawn_vehicle_at so the AI module (race/ai, ADR-0036) spawns
-- host-owned AI cars through the exact front-anchored / grid-oriented path a player car uses, and BeamMP
-- propagates them the same way ('Os:'). Owned by the spawning client. `color` (ADR-0047) is an optional
-- opaque roster colour applied as the PRIMARY paint layer only (paint2/paint3 stay stock); nil = stock
-- paint, byte-identical to the pre-colour behaviour.
function M.spawn_at(pose, model, config, color)
    return spawn_vehicle_at(pose, {model = model, config = config, paint = paint_from_color(color)})
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

-- Front-anchored, grounded placement of ANY vehicle at a grid pose -- the same repair+teleport
-- (front-anchor, ADR-0034) the player's restage uses, but WITHOUT touching other owned cars (unlike
-- respawn_own_at, which despawns the player's other vehicles). The AI module (race/ai, ADR-0036)
-- re-places each host-owned AI car here once its jbeam has loaded, so the AI cars sit on the grid exactly
-- like the players' cars instead of the center-anchored spawn pose. Returns true, or nil plus a reason.
function M.place_at_grid(veh, pose)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return nil, "invalid grid pose"
    end
    local ok, err = pcall(repair_and_place, veh, pose)
    if not ok then
        return nil, "place_at_grid failed: " .. tostring(err)
    end
    return true
end

-- (public) Read a vehicle's current license-plate text, so the race-start path can capture the player's
-- plate BEFORE a forced/substitute spawn despawns their car, then re-apply it to the new car once its
-- jbeam has loaded (M.apply_plate). pcall-guarded -- core_vehicles.getVehicleLicenseText is unverified
-- under BeamMP (the same read collect_player_name uses in init.lua). Returns a non-empty string, or nil
-- when there is no vehicle, no plate set, or the read fails (nil -> keep the generated plate).
function M.read_plate(veh)
    if not veh then
        return nil
    end
    local ok, plate = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleLicenseText) == "function" then
            return core_vehicles.getVehicleLicenseText(veh)
        end
        return nil
    end)
    if ok and type(plate) == "string" and plate ~= "" then
        return plate
    end
    return nil
end

-- (public) Render a license-plate text onto an already-spawned vehicle via BeamNG's setPlateText. This
-- is the ONLY reliable way to set a forced car's plate: spawnNewVehicle ignores a spawn-time licenseText
-- (BeamNG's own techCore notes "licenseText not respected in spawnNewVehicle"), and the jbeam's
-- licenseplate init (licenseplatesSkins.lua) regenerates the plate from config.licenseName -- absent on a
-- forced spawn, so it generates a fresh random one. The jbeam init runs AFTER the GE spawn, so the plate
-- must be applied on the deferred restage (once the jbeam has loaded) or the regeneration overrides it.
-- No-op for an empty/nil plate (keeps the generated one). pcall-guarded (setPlateText is unverified under
-- BeamMP). Returns true, or nil plus a reason.
function M.apply_plate(veh, plate)
    if not veh then
        return nil, "no vehicle"
    end
    if type(plate) ~= "string" or plate == "" then
        return nil, "no plate to apply"
    end
    if type(core_vehicles) ~= "table" or type(core_vehicles.setPlateText) ~= "function" then
        return nil, "setPlateText unavailable"
    end
    local ok, err = pcall(core_vehicles.setPlateText, plate, veh:getId())
    if not ok then
        return nil, "setPlateText failed: " .. tostring(err)
    end
    return true
end

-- Split a car= token "model" or "model:config" into (model, config); config is nil when absent. Returns
-- nil when there is no model part. Shared by the Mode-2 fixed car and the Mode-3 substitute (ADR-0032).
local function parse_car_token(token)
    if type(token) ~= "string" or token == "" then
        return nil
    end
    local colon = token:find(":", 1, true)
    if not colon then
        return token, nil
    end
    local model = token:sub(1, colon - 1)
    if model == "" then
        return nil
    end
    local config = token:sub(colon + 1)
    if config == "" then
        config = nil
    end
    return model, config
end

-- Keep the player's seated owned car: despawn their other cars, then repair + teleport it onto the grid
-- (ADR-0007 primary path). Returns the kept car, or nil plus a reason.
local function keep_own(pose, own_car)
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

-- Despawn the player's cars and fresh-spawn a chosen {model, config} at the grid pose. Stock paint by
-- default; when `paint_from` (a captured spec) is given, its three paint layers ride onto the new car --
-- the Mode-2 "you already own this model in your own colours" case (spawn the forced trim, keep the
-- player's paint). Shared by Mode 2 (fixed car) and the Mode-3 substitute (ADR-0032). A fresh spawn
-- either way, so the caller's deferred restage + plate re-apply (keyed on the new vehicle id) still run.
-- Returns the new car, or nil + reason.
local function spawn_fixed(pose, model, config, paint_from)
    M.despawn_own()
    local spec = {model = model, config = config}
    if paint_from then
        spec.paint = paint_from.paint
        spec.paint2 = paint_from.paint2
        spec.paint3 = paint_from.paint3
    end
    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "policy spawn failed: " .. tostring(reason))
        return nil, reason
    end
    log("I", LOG_TAG, string.format("policy spawned '%s%s'%s at grid (%.1f, %.1f, %.1f)",
        tostring(model), config and (":" .. config) or "",
        paint_from and " in own paint" or "", pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

-- Mode 2 (ADR-0032): resolve the forced model[:config] against what the player already drives. The base
-- behaviour is a stock forced car for everyone (spawn_fixed). But when the player ALREADY owns the forced
-- MODEL, don't throw away their look:
--   * exact match -- forced config absent (model-only), or equal to their current config -> keep the
--     seated car untouched via keep_own: colours, licence plate and tuning preserved, no respawn (their
--     car already IS the forced car).
--   * model matches but the forced config differs -> fresh-spawn the DEMANDED config carrying the
--     player's own paint layers (the forced trim in their colours).
-- Any gap -- no own car, a different model, or an unreadable own spec -> stock forced car, exactly as
-- before (degrade, don't crash). The config compare is deliberately conservative: only an equal (string
-- ==) or absent forced config keeps the car, so a config the admin explicitly asked for is never skipped;
-- an inline-customized own config (a table, never == a config string) falls to the config-differs branch,
-- which still yields the correct forced config in the player's colours. capture_spec is pcall-guarded and
-- returns nil on any read failure, which selects the stock fall-through. Returns the race car, or nil +
-- reason.
local function spawn_forced(pose, model, config, own_car)
    if own_car then
        local own_spec = M.capture_spec(own_car)
        if own_spec and own_spec.model == model then
            if config == nil or config == own_spec.config then
                return keep_own(pose, own_car)
            end
            return spawn_fixed(pose, model, config, own_spec)
        end
    end
    return spawn_fixed(pose, model, config)
end

-- Fallback for Mode 1 when there is no real own car (free-cam / walking / none): copy the current car's
-- spec if any, else the default model, and fresh-spawn it (ADR-0007 §2). Returns the new car, or nil +
-- reason. Capturing before the despawn is required, since the despawn deletes the car we copy.
local function fresh_spawn_own(pose)
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

-- Spawn the fixed default car and flag it as a "no suitable car" degrade (ADR-0032 amendment): the shared
-- best-effort fallback for the paths where no cap-compliant / random-pool car was available (the Mode-3 cap
-- with no compliant car, and car=random with an empty cap-composed pool). Always a real car (never a prop),
-- even if it violates the active cap. Returns (car, nil, true) so the caller raises the no-suitable-car
-- warning and STILL races, or (nil, reason) on a spawn failure. Distinct from fresh_spawn_own, whose default
-- spawn (on-foot Mode 1) is NOT a no-suitable-car case and stays silent.
local function spawn_default_degraded(pose)
    local veh, reason = spawn_fixed(pose, DEFAULT_VEHICLE_MODEL, nil)
    if not veh then
        return nil, reason
    end
    return veh, nil, true
end

-- (public) Live Mode-3 compliance check for a SPAWNED car (ADR-0032): read the car's live power/weight --
-- reliable, unlike pre-spawn config metadata (see the POWER-READ RISK note) -- and apply is_compliant,
-- returning (compliant, power, weight) so a caller can both gate and build a warning from the readings. A
-- nil cap is "no limit on that axis"; an unreadable input under a set cap is non-compliant (cannot verify
-- => blocked). maxkg/minkg (kg) are the STRICT player weight range, exclude-on-unreadable like the power
-- caps (distinct from the AI's lenient big-car nicety). Shared by the race-start cap resolve
-- (respawn_for_cap) and the staging swap gate (init.lua).
function M.car_compliant(veh, maxhp, maxpwr, minkg, maxkg)
    local power = vehiclespecs.vehicle_power(veh)
    local weight = vehiclespecs.vehicle_weight(veh)
    local range = vehiclespecs.weight_range(minkg, maxkg)
    return vehiclespecs.is_compliant(power, weight, maxhp, maxpwr, nil, range), power, weight
end

-- Mode 3 (ADR-0032, §5 superseded by the 2026-07-07 amendment): keep the own car when it meets the power /
-- power-to-weight / weight-range cap, else substitute the first compliant car (own model's strongest legal
-- trim first, then other models -- find_compliant), else -- when NO installed car meets the cap -- spawn the
-- fixed default car (even though it violates the cap) so the player still races (best-effort cap), instead of
-- the old abort. Own-car power + weight are read from the spawned vehicle (reliable); candidates from config
-- metadata. Returns the kept/spawned car, (nil, reason) on a spawn failure, or (car, nil, true) where the
-- third value flags "degraded to the default because no suitable car" so the caller warns, then races.
local function respawn_for_cap(pose, own_car, policy)
    local own_model = own_car and own_car.JBeam or nil
    local compliant, own_power, own_weight = false, nil, nil
    if own_car then
        compliant, own_power, own_weight =
            M.car_compliant(own_car, policy.maxhp, policy.maxpwr, policy.minkg, policy.maxkg)
    end

    if compliant then
        log("I", LOG_TAG, string.format("own car '%s' meets the cap (power=%s, weight=%s) -- kept",
            tostring(own_model), tostring(own_power), tostring(own_weight)))
        return keep_own(pose, own_car)
    end

    local range = vehiclespecs.weight_range(policy.minkg, policy.maxkg)
    local pick = vehiclespecs.find_compliant(own_model, policy.maxhp, policy.maxpwr, nil, range)
    if pick then
        log("I", LOG_TAG, string.format("own car over the cap -- substituting '%s:%s'",
            tostring(pick.model), tostring(pick.config)))
        return spawn_fixed(pose, pick.model, pick.config)
    end

    -- No installed car meets the cap: best-effort default (ADR-0032 §5 superseded) -- spawn etk800 even
    -- over the cap and signal the caller to warn; the player races rather than sitting out.
    log("W", LOG_TAG, "no car meets the cap -- spawning default '" .. DEFAULT_VEHICLE_MODEL .. "'")
    return spawn_default_degraded(pose)
end

-- car=random (ADR-0032 amendment): roll a per-player random car locally at race start, composing with the
-- active caps (the deliberate exception to the car-wins precedence -- unlike a FIXED car=, the caps still
-- apply here). The pool pick is the SHARED composition vehiclespecs.random_vehicle, identical to the AI
-- random path (random_ai_vehicle), so the two never drift. Two composable axes, defaults ON when the field
-- is nil (a typed /race car=random; the panel sends explicit booleans): randomTrim (a random compliant trim
-- vs. the stock/default trim) and noBigCars (the BIG_CAR_MAX_WEIGHT curb-weight ceiling). An empty
-- cap-composed pool degrades to the fixed default car (never a prop) and signals the caller to warn; the
-- player still races. Returns the spawned car, (nil, reason) on a spawn failure, or (car, nil, true) when it
-- degraded to the default because no suitable car was available.
local function respawn_random(pose, policy)
    local pick = vehiclespecs.random_vehicle(vehiclespecs.random_spec_from_policy(policy))
    if pick then
        log("I", LOG_TAG, string.format("car=random -> '%s%s'",
            tostring(pick.model), pick.config and (":" .. pick.config) or ""))
        return spawn_fixed(pose, pick.model, pick.config)
    end

    -- Empty compliant pool (impossible cap, or no installed car): best-effort default + warn, never a prop.
    log("W", LOG_TAG, "car=random: no compliant car -- spawning default '" .. DEFAULT_VEHICLE_MODEL .. "'")
    return spawn_default_degraded(pose)
end

-- Place this client's own car at `pose` (the grid start the server assigned), per the relayed vehicle
-- policy (ADR-0032; `policy` = {car, maxhp, maxpwr, maxkg, minkg, randomTrim, noBigCars}, all nil = Mode 1).
-- Modes:
--   * Mode 1 (no policy) -- ADR-0007: keep the seated owned car (repair + teleport), else fresh-spawn one.
--   * car=random -- a per-player random car composing with the active caps (ADR-0032 amendment); the two
--     random axes ride randomTrim/noBigCars. Branched BEFORE parse_car_token so "random" is not treated as
--     a model name.
--   * Mode 2 (car=<model>) -- fixed model[:config] for everyone; but keep the own car when it already IS the
--     forced car (colours/plate/tuning preserved), or spawn the forced config in the player's paint when
--     only the config differs.
--   * Mode 3 (maxhp/maxpwr/maxkg/minkg) -- keep the own car if compliant, else substitute, else the
--     best-effort default car (ADR-0032 §5 superseded -- no more abort).
-- Returns the resolved race car (the caller enters + freezes it), (nil, reason) on a failure, or
-- (car, nil, true) where the third value flags "degraded to the default because no suitable car was
-- available" (car=random empty pool, or the Mode-3 no-compliant-car case) so the caller warns then races.
-- BeamMP propagates the despawn ('Od:'), spawn ('Os:'), and a kept car's teleport (owned-vehicle sync).
function M.respawn_own_at(pose, own_car, policy)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" or type(pose.rot) ~= "table" then
        return nil, "invalid grid pose"
    end
    policy = policy or {}

    if policy.car == "random" then
        return respawn_random(pose, policy)
    end

    if policy.car then
        local model, config = parse_car_token(policy.car)
        if not model then
            return nil, "invalid car= '" .. tostring(policy.car) .. "'"
        end
        return spawn_forced(pose, model, config, own_car)
    end

    if policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg then
        return respawn_for_cap(pose, own_car, policy)
    end

    if own_car then
        return keep_own(pose, own_car)
    end
    return fresh_spawn_own(pose)
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

    -- Power-to-weight (hp/kg) of the race car, for the start-order pwr mode (ADR-0033). Read client-side
    -- here so the server stays vehicle-blind (ADR-0005); nil when power or weight is unreadable, in which
    -- case the player sorts to the back of a pwr grid.
    local power = vehiclespecs.vehicle_power(veh)
    local weight = vehiclespecs.vehicle_weight(veh)
    if type(power) == "number" and type(weight) == "number" and weight > 0 then
        info.pwr = power / weight
    end

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
