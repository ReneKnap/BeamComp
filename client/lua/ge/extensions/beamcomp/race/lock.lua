-- BeamComp -- in-race vehicle-action lock (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/lock.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Near-stateless (one transient replace_seen flag, see below): the caller (init.lua)
-- installs the lock when the race countdown starts and removes it when the race returns to lobby
-- (ADR-0017).
--
-- During countdown + racing the player must stay in their one race car. Two layers prevent leaving
-- it or swapping it (ADR-0017):
--   1. core_input_actionFilter -- BeamNG's own input-action blocker (the mechanism scenarios use).
--      We block the switch / vehicle-selector / parts-selector / reload keys (no car swap or extra
--      spawn) and the teleport/reset family (no alternative recover/repair route). recover_vehicle /
--      recover_vehicle_alt are deliberately NOT in this group: the VE recovery override owns them so
--      the opt-in recover/repair assists can use those keys. (They ARE blocked by the separate hold
--      lock below, but only while a qualifying driver is being held put.)
--   2. A guard on core_vehicles.spawnNewVehicle / replaceVehicle. The action filter only blocks key
--      bindings; the vehicle selector is also reachable from the Esc/UI menu, which is not an input
--      action. Guarding the spawn/replace functions themselves closes that route too. BeamComp's own
--      race-start spawn runs in the spawning phase, before this lock arms at countdown, so it is not
--      affected (and handle_race_start removes the lock up front as a belt-and-braces guard).
--
-- The lock has two modes (ADR-0021/0017 amendments, staging-allow-vehicle-swap):
--   * swap-allowed -- installed for the staging wait so the player may still change car (replace the
--     model/config via the vehicle/parts selector). replaceVehicle is left unguarded and the two
--     selector actions are left unfiltered; spawnNewVehicle (extra car) and every other switch / reset
--     / recover / grabber route stays blocked. A staging swap is re-staged by init.lua (re-freeze,
--     bounce target, VE re-arm).
--   * full -- the original fixed-car lock. install() with no opts, or re-installed at countdown to
--     upgrade the staging lock: setGroup redefines the action group and the replace guard is added.
--
-- On top of those, an independent HOLD LOCK (ADR-0017 amendment, quali-hold-reset-and-repaint-leak)
-- blocks the two recover keys for the span of a qualifying hold -- see set_recover_blocked below. It is
-- a separate action group with its own toggle, so it composes with either mode above without touching it.

local M = {}

local LOG_TAG = "beamcomp.lock"

-- Set true by the swap-allowed replaceVehicle pass-through when the player replaces their car during
-- staging, consumed by init.lua (consume_replace) to re-stage the new car. A replace keeps the same
-- vehicle id, so this event flag is the only reliable signal that a swap happened.
M.replace_seen = false

-- Shared input filter id. BeamNG convention (scenarios.lua, career.lua, ...): every subsystem toggles
-- its own named group on filter 0, so we only ever flip our group on/off and never clear(0).
local FILTER_ID = 0
local ACTION_GROUP = "beamcomp_race_lock"

-- Second action group on the SAME filter, toggled independently of the race lock (set_recover_blocked).
-- BeamNG keys blocked groups per filter and re-applies every flagged one on each update
-- (core/input/actionFilter.lua), so the two groups never interfere.
local HOLD_ACTION_GROUP = "beamcomp_race_hold_lock"

-- Input actions hard-blocked for the duration of the race. Only the two hold-capable recover keys
-- are REPURPOSED into the assists (recover_vehicle = Insert, recover_vehicle_alt = Ctrl+Insert) via
-- the VE override and so are intentionally absent here; every other switch / spawn / reset / recover
-- route is blocked, including the onDown-only reset keys (reset_physics, reset_all_physics, loadHome)
-- which cannot support a hold (ADR-0017). The two car-selector actions live in SELECTOR_ACTIONS below
-- so the swap-allowed mode can leave them open; everything here is blocked in both modes.
local BLOCKED_ACTIONS = {
    "switch_next_vehicle",
    "switch_previous_vehicle",
    "switch_next_vehicle_multiseat",
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
    -- Node grabber (Ctrl + drag): applies an external force the soft start-freeze does not resist, so
    -- it could drag the car off its grid slot during the lock (countdown-lock-leaks Finding #4). Its
    -- render/activation action is blocked here. NOTE: the exact action name(s) for BeamNG 0.38.5 are to
    -- be confirmed in-game (dump core_input_actionFilter / the inputmaps) -- a wrong name silently
    -- no-ops the filter rather than erroring. If the grabber is not a filterable input action, disable
    -- the GE-side grabber for the lock span instead.
    "nodegrabRender",
    "nodegrabStrength",
    "nodegrabFixedFrame",
}

-- The car-selector input actions. Blocked in the full lock (no swap during countdown/racing), but left
-- open in the swap-allowed staging mode so the player can replace the model/config (ADR-0021 amendment).
-- spawnNewVehicle is still refused by the core_vehicles guard, so an open selector can replace but not
-- spawn an extra car.
local SELECTOR_ACTIONS = {
    "vehicle_selector",
    "parts_selector",
}

-- The two recover keys, blocked only for the span of a qualifying hold (set_recover_blocked). Absent from
-- BLOCKED_ACTIONS because the assists own them for every other phase; blocking them here -- at the engine's
-- input filter rather than only GE-side -- is what also closes the window right after a vehicle-config
-- respawn, where the VE recovery override has been reloaded away and the keys are momentarily vanilla.
-- Both names are taken verbatim from the engine's own `vehicleTeleporting` action template.
local HOLD_ACTIONS = {
    "recover_vehicle",
    "recover_vehicle_alt",
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

-- Build the blocked-action list for the requested mode: always BLOCKED_ACTIONS, plus the two selector
-- actions unless replace is allowed (swap-allowed staging mode leaves the selector open).
local function blocked_actions_for(allow_replace)
    if allow_replace then
        return BLOCKED_ACTIONS
    end
    local actions = {}
    for _, action in ipairs(BLOCKED_ACTIONS) do
        actions[#actions + 1] = action
    end
    for _, action in ipairs(SELECTOR_ACTIONS) do
        actions[#actions + 1] = action
    end
    return actions
end

-- Block or unblock the input-action group. setGroup defines the action list; addAction toggles it on
-- our shared filter. Re-calling setGroup redefines the group, so upgrading the swap-allowed mode to the
-- full lock (countdown) just re-blocks with the selector actions added. Wrapped in pcall: the input API
-- is engine-version-coupled, so a mismatch warns once rather than breaking the phase handler.
local function set_action_filter(blocked, allow_replace)
    if type(core_input_actionFilter) ~= "table" then
        return
    end
    local ok, err = pcall(function()
        if blocked then
            core_input_actionFilter.setGroup(ACTION_GROUP, blocked_actions_for(allow_replace))
        end
        core_input_actionFilter.addAction(FILTER_ID, ACTION_GROUP, blocked)
    end)
    if not ok then
        log("W", LOG_TAG, "action filter update failed: " .. tostring(err))
    end
end

-- Block or unblock the two recover keys, independently of the race lock's own group. Same pcall guard as
-- set_action_filter: the input API is engine-version-coupled, and a wrong action name no-ops silently, so
-- the caller keeps a GE-side guard as a second layer.
local function set_hold_filter(blocked)
    if type(core_input_actionFilter) ~= "table" then
        return
    end
    local ok, err = pcall(function()
        if blocked then
            core_input_actionFilter.setGroup(HOLD_ACTION_GROUP, HOLD_ACTIONS)
        end
        core_input_actionFilter.addAction(FILTER_ID, HOLD_ACTION_GROUP, blocked)
    end)
    if not ok then
        log("W", LOG_TAG, "hold filter update failed: " .. tostring(err))
    end
end

-- Guard spawnNewVehicle (always refused) and replaceVehicle (refused in the full lock; in swap-allowed
-- mode wrapped with a pass-through that runs the original and flags replace_seen so init.lua can re-stage
-- the new car). The originals are stashed once on core_vehicles; the wrapper itself is (re)assigned on
-- each install, so the staging->countdown upgrade flips replaceVehicle from pass-through to refusing stub
-- without re-stashing (which would capture our own wrapper as the "original").
local function guard_core_vehicles(allow_replace)
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
    end
    if core_vehicles[ORIG_REPLACE_KEY] ~= nil then
        if allow_replace then
            core_vehicles.replaceVehicle = function(...)
                M.replace_seen = true
                return core_vehicles[ORIG_REPLACE_KEY](...)
            end
        else
            core_vehicles.replaceVehicle = function()
                notify_spawn_blocked()
                return nil
            end
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

-- Arm the lock: block the input actions and guard the spawn/replace functions. Idempotent. With
-- opts.allow_replace the swap-allowed staging mode is installed (replace + the car selector stay open,
-- extra spawn + everything else blocked); with no opts (or false) the full fixed-car lock. Calling it
-- again without allow_replace upgrades a swap-allowed lock to full (ADR-0021/0017 amendments).
function M.install(opts)
    local allow_replace = opts ~= nil and opts.allow_replace == true
    set_action_filter(true, allow_replace)
    guard_core_vehicles(allow_replace)
    log("I", LOG_TAG, "in-race vehicle-action lock installed ("
        .. (allow_replace and "swap-allowed" or "full") .. ")")
end

-- Block or unblock the two recover keys for a qualifying hold (ADR-0017 amendment): while a driver waits in
-- the queue, sits staged at the ramp, or is done for the session, the hold must actually hold -- and a
-- frozen car satisfies the assists' stationary gate, so an unblocked recover key would happily free it.
-- A separate group from the race lock, so the in-run recover-requeue (ADR-0044) and the in-race assists
-- keep both keys in every state that is NOT held.
--
-- Deliberately unconditional (no internal "already applied" flag): a Lua reload resets this module's state
-- while the engine's filter state survives (actionFilter serializes it), so an internal flag could desync
-- and strand the keys blocked. The caller owns the change detection against its own reload-surviving state.
function M.set_recover_blocked(blocked)
    set_hold_filter(blocked == true)
    log("I", LOG_TAG, "recover keys " .. (blocked and "blocked (quali hold)" or "released"))
end

-- Lift the lock: unblock the input actions and restore the spawn/replace functions. Idempotent, so
-- it is safe to call on lobby, on a fresh race start, and on extension unload. Clears the hold group too --
-- without that, a race ending while a driver is held would leave the recover keys dead in the finished
-- free-roam window and the lobby.
function M.remove()
    set_action_filter(false)
    set_hold_filter(false)
    unguard_core_vehicles()
    M.replace_seen = false
    log("I", LOG_TAG, "in-race vehicle-action lock removed")
end

-- The KEYBOARD control currently bound to `action`, or nil. Reads BeamNG's own binding table
-- (core_input_bindings.bindings: one entry per device, each with contents.devicetype and
-- contents.bindings = {{action, control}, ...}; controls are normalized to lower case by the engine).
--
-- Keyboard only, on purpose. The engine's own core_input_bindings.getControlForAction returns whichever
-- device it happens to reach first, so with a gamepad attached it answers things like "button31" -- true,
-- but useless to read in a tooltip and worse than showing no key at all. `unused` marks a binding the
-- engine has disabled for the seated vehicle, so those are skipped too.
--
-- Guarded like every other engine-version-coupled touchpoint in this file (ADR-0017): a renamed or
-- restructured binding table degrades to "no key known", never to an error.
local function keyboard_control_for(action)
    local bindings = core_input_bindings and core_input_bindings.bindings
    if type(bindings) ~= "table" then
        return nil
    end
    for _, device in ipairs(bindings) do
        local contents = type(device) == "table" and device.contents or nil
        if type(contents) == "table" and contents.devicetype == "keyboard"
            and type(contents.bindings) == "table" then
            for _, binding in ipairs(contents.bindings) do
                if type(binding) == "table" and binding.action == action
                    and not binding.unused and binding.active ~= false
                    and type(binding.control) == "string" and binding.control ~= "" then
                    return binding.control
                end
            end
        end
    end
    return nil
end

-- The keys the two in-race assists actually sit on, for the race-setup panel's hover help (ADR-0049
-- amendment). Returns {repair = <control>?, recover = <control>?} -- either field absent when the action
-- carries no keyboard binding, so the panel can name the command without inventing a key.
--
-- The mapping is INVERTED and that is not a typo: the plain recover key is the repair assist, the
-- alternate one is the recover assist (ADR-0017 decision 3, and the VE forwarder that implements it).
function M.assist_controls()
    local ok, controls = pcall(function()
        return {
            repair = keyboard_control_for("recover_vehicle"),
            recover = keyboard_control_for("recover_vehicle_alt"),
        }
    end)
    if not ok then
        log("W", LOG_TAG, "could not read input bindings: " .. tostring(controls))
        return {}
    end
    return controls
end

-- True (once) if the player replaced their car since the last call: the swap-allowed pass-through sets
-- replace_seen, this consumes it. init.lua polls it each staging frame to re-stage the swapped car.
function M.consume_replace()
    if M.replace_seen then
        M.replace_seen = false
        return true
    end
    return false
end

return M
