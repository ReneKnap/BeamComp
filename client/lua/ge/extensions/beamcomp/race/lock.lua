-- BeamComp -- in-race vehicle-action lock (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/lock.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless module: the caller (init.lua) installs the lock when the race countdown
-- starts and removes it when the race returns to lobby (ADR-0017).
--
-- During countdown + racing the player must stay in their one race car. Two layers prevent leaving
-- it or swapping it (ADR-0017):
--   1. core_input_actionFilter -- BeamNG's own input-action blocker (the mechanism scenarios use).
--      We block the switch / vehicle-selector / parts-selector / reload keys (no car swap or extra
--      spawn) and the teleport/reset family (no alternative recover/repair route). recover_vehicle /
--      recover_vehicle_alt are deliberately NOT blocked here: the VE recovery override owns them so
--      the opt-in recover/repair assists can use those keys.
--   2. A guard on core_vehicles.spawnNewVehicle / replaceVehicle. The action filter only blocks key
--      bindings; the vehicle selector is also reachable from the Esc/UI menu, which is not an input
--      action. Guarding the spawn/replace functions themselves closes that route too. BeamComp's own
--      race-start spawn runs in the spawning phase, before this lock arms at countdown, so it is not
--      affected (and handle_race_start removes the lock up front as a belt-and-braces guard).

local M = {}

local LOG_TAG = "beamcomp.lock"

-- Shared input filter id. BeamNG convention (scenarios.lua, career.lua, ...): every subsystem toggles
-- its own named group on filter 0, so we only ever flip our group on/off and never clear(0).
local FILTER_ID = 0
local ACTION_GROUP = "beamcomp_race_lock"

-- Input actions hard-blocked for the duration of the race. Only the two hold-capable recover keys
-- are REPURPOSED into the assists (recover_vehicle = Insert, recover_vehicle_alt = Ctrl+Insert) via
-- the VE override and so are intentionally absent here; every other switch / spawn / reset / recover
-- route is blocked, including the onDown-only reset keys (reset_physics, reset_all_physics, loadHome)
-- which cannot support a hold (ADR-0017).
local BLOCKED_ACTIONS = {
    "switch_next_vehicle",
    "switch_previous_vehicle",
    "switch_next_vehicle_multiseat",
    "vehicle_selector",
    "parts_selector",
    "vehicledebugMenu",
    "reload_vehicle",
    "reload_all_vehicles",
    "recover_to_last_road",
    "reset_physics",
    "reset_all_physics",
    "loadHome",
    "saveHome",
    "dropPlayerAtCamera",
    "dropPlayerAtCameraNoReset",
}

-- Keys for stashing the original core_vehicles functions. Stored ON the core_vehicles table (not in
-- this module) so a Lua reload mid-race never double-wraps: a present original means we are already
-- guarding, regardless of this module's freshly-reset state.
local ORIG_SPAWN_KEY = "beamcomp_orig_spawnNewVehicle"
local ORIG_REPLACE_KEY = "beamcomp_orig_replaceVehicle"

-- Min seconds between "locked" toasts on a refused spawn/replace, so mashing the selector shows one
-- toast, not a flood. os.clock() is monotonic CPU seconds -- precise enough to gate a toast.
local SPAWN_BLOCK_TOAST_THROTTLE = 2.0
local last_spawn_block_toast_at = 0

local function notify_spawn_blocked()
    local now = os.clock()
    if now - last_spawn_block_toast_at >= SPAWN_BLOCK_TOAST_THROTTLE then
        last_spawn_block_toast_at = now
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = "Switching or spawning vehicles is locked during the race",
        })
    end
    log("I", LOG_TAG, "blocked a vehicle spawn/replace during the race")
end

-- Block or unblock the input-action group. setGroup defines the action list; addAction toggles it on
-- our shared filter. Wrapped in pcall: the input API is engine-version-coupled, so a mismatch warns
-- once rather than breaking the phase handler.
local function set_action_filter(blocked)
    if type(core_input_actionFilter) ~= "table" then
        return
    end
    local ok, err = pcall(function()
        if blocked then
            core_input_actionFilter.setGroup(ACTION_GROUP, BLOCKED_ACTIONS)
        end
        core_input_actionFilter.addAction(FILTER_ID, ACTION_GROUP, blocked)
    end)
    if not ok then
        log("W", LOG_TAG, "action filter update failed: " .. tostring(err))
    end
end

-- Replace spawnNewVehicle / replaceVehicle with refusing stubs, stashing the originals. Idempotent:
-- a stashed original means we are already guarding, so re-installing is a no-op.
local function guard_core_vehicles()
    if type(core_vehicles) ~= "table" then
        return
    end
    if core_vehicles[ORIG_SPAWN_KEY] == nil and type(core_vehicles.spawnNewVehicle) == "function" then
        core_vehicles[ORIG_SPAWN_KEY] = core_vehicles.spawnNewVehicle
        core_vehicles.spawnNewVehicle = function()
            notify_spawn_blocked()
            return nil
        end
    end
    if core_vehicles[ORIG_REPLACE_KEY] == nil and type(core_vehicles.replaceVehicle) == "function" then
        core_vehicles[ORIG_REPLACE_KEY] = core_vehicles.replaceVehicle
        core_vehicles.replaceVehicle = function()
            notify_spawn_blocked()
            return nil
        end
    end
end

-- Restore the original spawnNewVehicle / replaceVehicle. No-op when not guarding (originals absent).
local function unguard_core_vehicles()
    if type(core_vehicles) ~= "table" then
        return
    end
    if core_vehicles[ORIG_SPAWN_KEY] ~= nil then
        core_vehicles.spawnNewVehicle = core_vehicles[ORIG_SPAWN_KEY]
        core_vehicles[ORIG_SPAWN_KEY] = nil
    end
    if core_vehicles[ORIG_REPLACE_KEY] ~= nil then
        core_vehicles.replaceVehicle = core_vehicles[ORIG_REPLACE_KEY]
        core_vehicles[ORIG_REPLACE_KEY] = nil
    end
end

-- Arm the lock: block the input actions and guard the spawn/replace functions. Idempotent.
function M.install()
    set_action_filter(true)
    guard_core_vehicles()
    log("I", LOG_TAG, "in-race vehicle-action lock installed")
end

-- Lift the lock: unblock the input actions and restore the spawn/replace functions. Idempotent, so
-- it is safe to call on lobby, on a fresh race start, and on extension unload.
function M.remove()
    set_action_filter(false)
    unguard_core_vehicles()
    log("I", LOG_TAG, "in-race vehicle-action lock removed")
end

return M
