-- BeamComp -- shared race POWERED prop-vehicle policy (the prefab's self-driven props, e.g. the
-- GridMap v2 GrinderGrandPrix rotating morning-star/flail obstacles, jbeam "large_spinner").
--
-- Lives at lua/ge/extensions/beamcomp/race/grinders.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller (race/props.lua + init.lua) owns
-- the tracked grinder ids AND the activation-window timing, and passes the ids back. Target: client
-- GE (LuaJIT 5.1).
--
-- ADR-0020 amendment (2026-07-02, refined R2 2026-07-03): a race prefab's `class == "BeamNGVehicle"`
-- lines are not always knockable cones -- an aiRace mission (ADR-0035) can ship rotating obstacle props
-- that carry their OWN powertrain. BeamComp's pipeline only SPAWNS the prefab (race/props.lua); nothing
-- starts a spawned prop-vehicle's motor, so on the host the grinders spawn but hang motionless, and --
-- being a different jbeam than "cones" -- they are captured by neither cones.keep_new nor reliably the
-- prefab container, so they leak after the race. On non-hosts prefab.filter_statics drops every
-- BeamNGVehicle line, so the grinders (like the cones) arrive only by BeamMP sync from the host. This
-- module is the powered-prop sibling of race/cones.lua (and mirrors ADR-0036's AI cars -- "a cone that
-- drives itself"):
--
--   * M.is_grinder / M.keep_new -- HOST identity by jbeam name (exactly like cones.is_cone), verified
--     from the stock jbeam: the GrinderGrandPrix props are "large_spinner". After the full-prefab spawn
--     M.keep_new returns every NEW "large_spinner" vehicle (diffed against a pre-spawn snapshot) so the
--     caller can activate + track them. Precise identity => precise leak tracking.
--   * M.activate -- HOST-side motor start via the vehicle's `spinner` main-controller (verified from
--     vehicles/large_spinner/lua/controller/spinner.lua). The controller owns an e-motor + wheel-rotator
--     and regulates the throttle itself (PID in updateGFX); it is driven by a target RPM ratio [-1..1],
--     reachable ONLY through onGameplayEvent("controller:spinner", {"setTargetRPMRatio", <ratio>, <lock>}).
--     So activation = ignition to level 2 (jbeam allows only level 2) + engine ignition + target RPM ratio
--     1 (locked = set immediately, no ramp). All queued to the grinder VE, fully pcall-guarded: a jbeam
--     without the controller/API no-ops instead of throwing. Called each frame over a short readiness
--     window (init.lua), because the controller only exists after the freshly spawned VE's powertrain init
--     (getControllerSafe returns nil before that). Once set, the locked target ratio holds on its own --
--     the controller keeps the throttle, so NO per-frame re-assert is needed past the window (writing
--     throttle from outside would fight the controller). BeamMP syncs the resulting node motion to clients,
--     so a host-side spin is also the client fix. A wrong call no-ops -- grinders stay static, no worse
--     than today, no crash, no per-frame log spam.
--   * M.clear -- HOST cleanup by id (veh:delete()), the same proven ADR-0009/0020-fallback path cones.clear
--     uses. BeamMP propagates the owned delete ('Od:'), removing them for all clients. This fixes the leak
--     regardless of whether activation succeeds.
--
-- The cone correctness guarantees are untouched: cones.is_cone / enforce_non_enterable / exclude_from_cycle
-- stay jbeam-"cones"-keyed, so a grinder is never parked/frozen (it must spin).

local M = {}

local LOG_TAG = "beamcomp.grinders"

-- The jbeam of the GridMap v2 GrinderGrandPrix rotating grinders (verified from the stock content zip
-- vehicles/large_spinner). Single source of grinder identity, exactly like cones.CONE_JBEAM.
local GRINDER_JBEAM = "large_spinner"

-- The VE-side Lua that starts one grinder's motor (verified from the stock `spinner` main-controller,
-- ADR-0020 amendment R2). The rotation is NOT motor throttle we can poke directly: the controller owns
-- the throttle (PID) and is driven by a target RPM ratio reachable only via onGameplayEvent. Every call
-- is pcall-guarded and existence-checked, so a jbeam/build without that controller or API no-ops instead
-- of throwing. Idempotent, so re-issuing it each frame over the spawn readiness window (init.lua) never
-- mis-behaves: the controller only appears after the fresh VE's powertrain init, so a single shot at spawn
-- would usually land before getControllerSafe("spinner") is non-nil. Ratio 1 (full) with locked = true
-- sets the target immediately without a ramp; direction/speed are tunable in the 2-client handover test.
local SPIN_COMMAND = [[
local c = controller and controller.getControllerSafe and controller.getControllerSafe("spinner")
if c then
  pcall(function() if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(2) end end)
  pcall(function() if c.setEngineIgnition then c.setEngineIgnition(true) end end)
  pcall(function() c.onGameplayEvent("controller:spinner", {"setTargetRPMRatio", 1, true}) end)
end
]]

-- Whether a vehicle object is one of the race prefab's powered grinder prop-vehicles. This is the
-- single source of grinder identity (the spawn loader and the activation both ask here), mirroring
-- cones.is_cone.
function M.is_grinder(veh)
    return veh ~= nil and veh.JBeam == GRINDER_JBEAM
end

-- The grinder vehicles in the scene that did not exist before the load (diffed against `existing_before`,
-- a set of pre-load object ids). Returns a list of game vehicle ids. Scene presence is synchronous after
-- spawnPrefab (unlike BeamMP ownership), so the host's diff is reliable here. Mirrors cones.new_cone_ids.
local function new_grinder_ids(existing_before)
    local ids = {}
    if not be then
        return ids
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and M.is_grinder(veh) then
            local id = veh:getID()
            if not existing_before[id] then
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- HOST path: identify the powered grinder prop-vehicles this prefab load just created and return their
-- ids so the caller can activate + track them for cleanup. Host-only, called from race/props.lua exactly
-- where cones.keep_new is (same pre-spawn snapshot). BeamMP propagates the spawns ('Os:') to every other
-- client, so the host is the single source of the shared grinder set.
function M.keep_new(existing_before)
    local ids = new_grinder_ids(existing_before)
    log("I", LOG_TAG, string.format("kept %d powered prop(s)", #ids))
    return ids
end

-- Queue the spin command to one grinder VE. pcall-guarded (the queue call is the engine boundary); the
-- first return is the ok flag.
local function queue_spin(veh)
    return pcall(function() veh:queueLuaCommand(SPIN_COMMAND) end)
end

-- HOST: (re-)issue the activation command to each live grinder VE. Called each frame over the short
-- readiness window (init.lua) because the `spinner` main-controller only comes up after the freshly
-- spawned grinder VE's powertrain init -- getControllerSafe returns nil before that, so the queued command
-- no-ops until the controller exists. Idempotent + fully guarded, so re-issuing is harmless; the locked
-- target ratio holds on its own once set, so activation stops when the window closes (no per-frame
-- re-assert -- the controller owns the throttle). Silent by design (runs per frame in the window; must not
-- spam the log); a grinder whose vehicle is gone is skipped. Returns the count re-issued to.
function M.activate(ids)
    if type(ids) ~= "table" or not be then
        return 0
    end
    local issued = 0
    for _, id in ipairs(ids) do
        local veh = be:getObjectByID(id)
        if veh and queue_spin(veh) then
            issued = issued + 1
        end
    end
    return issued
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
