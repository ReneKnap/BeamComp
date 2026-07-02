-- BeamComp -- shared race POWERED prop-vehicle policy (the prefab's self-driven props, e.g. the
-- GridMap v2 GrinderGrandPrix rotating morning-star/flail obstacles).
--
-- Lives at lua/ge/extensions/beamcomp/race/grinders.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller (race/props.lua + init.lua) owns
-- the tracked grinder ids and passes them back. Target: client GE (LuaJIT 5.1).
--
-- ADR-0020 amendment (2026-07-02): a race prefab's `class == "BeamNGVehicle"` lines are not always
-- knockable cones -- an aiRace mission (ADR-0035) can ship rotating obstacle props that carry their OWN
-- powertrain. BeamComp's pipeline only SPAWNS the prefab (race/props.lua); nothing starts a spawned
-- prop-vehicle's motor, so on the host the grinders spawn but hang motionless, and -- being a different
-- jbeam than "cones" -- they are captured by neither cones.keep_new nor reliably the prefab container,
-- so they leak after the race. On non-hosts prefab.filter_statics drops every BeamNGVehicle line, so the
-- grinders (like the cones) arrive only by BeamMP sync from the host. This module is the powered-prop
-- sibling of race/cones.lua (and mirrors ADR-0036's AI cars -- "a cone that drives itself"):
--
--   * M.keep_new  -- HOST identity by diff, no new jbeam needed: after the full-prefab spawn, every NEW
--     vehicle that is NOT a cone is a powered prop. The snapshot is taken before spawnPrefab, so the only
--     new vehicles are the prefab's; minus the cones, the rest are the grinders. (Even if this caught some
--     other non-cone prefab prop-vehicle, tracking it for cleanup is still correct -- it prevents ANY
--     prefab prop-vehicle from leaking -- and activation no-ops on a motor-less one.)
--   * M.activate / M.sustain -- HOST-side motor start (SPIKE): queue a fully-guarded VE command that turns
--     ignition on and applies full throttle, then re-assert the throttle each frame (an unmanned vehicle's
--     input system drives throttle back to 0 otherwise). BeamMP syncs the resulting node motion to clients,
--     so a host-side spin is also the client fix. The EXACT powertrain start for the stock grinder jbeam is
--     unverified without the running game -- flagged for the 2-client handover test, exactly like ADR-0036's
--     M.drive/M.server_id_of spikes. A wrong call no-ops (each candidate is pcall-wrapped), so grinders
--     simply stay static -- no worse than today, no crash, no per-frame log spam.
--   * M.clear -- HOST cleanup by id (veh:delete()), the same proven ADR-0009/0020-fallback path cones.clear
--     uses. BeamMP propagates the owned delete ('Od:'), removing them for all clients. This fixes the leak
--     regardless of whether activation succeeds.
--
-- The cone correctness guarantees are untouched: cones.is_cone / enforce_non_enterable / exclude_from_cycle
-- stay jbeam-"cones"-keyed, so a grinder is never parked/frozen (it must spin).

local M = {}

local cones = require("beamcomp/race/cones")

local LOG_TAG = "beamcomp.grinders"

-- The VE-side Lua that starts one grinder's motor (SPIKE, ADR-0020 amendment). Each candidate mechanism
-- is pcall-wrapped so a jbeam without that field/API no-ops instead of throwing -- pcall(fn) is safe even
-- when the wrapped call hits a nil global. Deliberately NO explicit starter crank: it would re-crank every
-- frame on the sustain re-assert. An electric-motor prop spins on ignition + throttle alone; a combustion
-- prop auto-starts on ignition in recent BeamNG. Queued to the grinder VE, so it applies even while the
-- freshly spawned vehicle's VE is still coming up (mirrors vehicles.set_vehicle_frozen). Trivial + cannot
-- throw. If a grinder stays static in the handover test, its jbeam's electrics/powertrain is the input to
-- confirm (a starter crank or a different field may be needed).
local SPIN_COMMAND = table.concat({
    "pcall(function() electrics.values.ignitionLevel = 2 end)",
    "pcall(function() if controller and controller.mainController "
        .. "and controller.mainController.setEngineIgnition then "
        .. "controller.mainController.setEngineIgnition(true) end end)",
    "pcall(function() electrics.values.throttle = 1 end)",
}, "; ")

-- The non-cone vehicles in the scene that did not exist before the load (diffed against `existing_before`,
-- a set of pre-load object ids). Returns a list of game vehicle ids. Scene presence is synchronous after
-- spawnPrefab (unlike BeamMP ownership), so the host's diff is reliable here. Mirrors cones.new_cone_ids,
-- inverted: the cones are removed via cones.is_cone, so the remainder are the powered props.
local function new_grinder_ids(existing_before)
    local ids = {}
    if not be then
        return ids
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and not cones.is_cone(veh) then
            local id = veh:getID()
            if not existing_before[id] then
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- HOST path: identify the powered prop-vehicles this prefab load just created (the new non-cone vehicles)
-- and return their ids so the caller can activate + track them for cleanup. Host-only, called from
-- race/props.lua exactly where cones.keep_new is (same pre-spawn snapshot). BeamMP propagates the spawns
-- ('Os:') to every other client, so the host is the single source of the shared grinder set.
function M.keep_new(existing_before)
    local ids = new_grinder_ids(existing_before)
    log("I", LOG_TAG, string.format("kept %d powered prop(s)", #ids))
    return ids
end

-- Queue the spin command to one grinder VE. pcall-guarded (the queue call is the engine boundary).
-- Returns true, or false plus the error.
local function queue_spin(veh)
    local ok, err = pcall(function() veh:queueLuaCommand(SPIN_COMMAND) end)
    if not ok then
        return false, err
    end
    return true
end

-- HOST: start each grinder's motor once at spawn (SPIKE). Best-effort + guarded; a grinder whose vehicle
-- is gone is skipped, a queue failure warns once (not per frame). Returns the count activated. BeamMP syncs
-- the resulting rotation to clients.
function M.activate(ids)
    if type(ids) ~= "table" then
        return 0
    end
    local activated = 0
    for _, id in ipairs(ids) do
        local veh = be and be:getObjectByID(id)
        if veh then
            local ok, err = queue_spin(veh)
            if ok then
                activated = activated + 1
            else
                log("W", LOG_TAG, "could not activate grinder " .. tostring(id) .. ": " .. tostring(err))
            end
        end
    end
    log("I", LOG_TAG, string.format("activated %d powered prop(s)", activated))
    return activated
end

-- HOST: re-assert the spin every frame while the grinders are live (called from init.lua's onUpdate). An
-- unmanned vehicle's input system drives throttle back to 0 each frame, so a one-shot set would not hold;
-- the ignition/engine-ignition in SPIN_COMMAND are idempotent, so re-asserting never re-cranks a starter.
-- Silent by design -- this runs per frame and must not spam the log; a gone vehicle is simply skipped.
function M.sustain(ids)
    if type(ids) ~= "table" or not be then
        return
    end
    for _, id in ipairs(ids) do
        local veh = be:getObjectByID(id)
        if veh then
            queue_spin(veh)
        end
    end
end

-- HOST cleanup: delete the tracked grinder vehicles by id. Tolerant of ids whose vehicle is already gone.
-- BeamMP propagates the owned delete ('Od:'), removing them for all clients. Returns the count processed.
-- Mirrors cones.clear -- the proven ADR-0009/0020-fallback cleanup path.
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
    log("I", LOG_TAG, string.format("cleared %d powered prop(s)", cleared))
    return cleared
end

return M
