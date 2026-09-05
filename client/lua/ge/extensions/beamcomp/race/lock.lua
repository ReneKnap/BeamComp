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

-- Optional callback the swap-allowed replaceVehicle pass-through invokes with (modelName, opt) right
-- before the engine replaces the car, so the caller can act on the car that is ABOUT to exist. Set by
-- init.lua for the staging swap (ADR-0051 round 2); nil means the pass-through behaves exactly as before.
M.on_before_replace = nil

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
-- so the swap-allowed mode can leave them open, and the node-grabber actions are resolved from the engine
-- at install time (nodegrabber_actions below); everything here is blocked in both modes.
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
}

-- The node grabber (Ctrl + drag) applies an external force the soft start-freeze does not resist, so it can
-- drag the car off its grid slot for as long as the lock is meant to be holding it (ADR-0017,
-- countdown-lock-leaks Finding #4). It IS a filterable input action -- the game's own career mode blocks it
-- through the same setGroup/addAction path this file already uses (career.lua updateNodegrabberBlocking),
-- so it needs no second, GE-side mechanism.
--
-- The names are read from the ENGINE's action template at install time rather than written out here (bug
-- nodegrabber-action-names-wrong). This list started life as three invented names -- "nodegrabRender",
-- "nodegrabStrength", "nodegrabFixedFrame" -- that no engine version has ever known, and an unknown name is
-- a silent no-op in ActionMap.addToFilter: no error, no warning, no log. The block therefore did nothing at
-- all from the day it was added until someone read the engine source. Taking the names from the engine is
-- what survives the next rename; the list below is only the fallback for an engine that no longer offers
-- the template, and falling back to it is warned about (report_nodegrabber_block).
local NODEGRABBER_TEMPLATE = "nodegrabber"

-- Verbatim from the engine's actionTemplates.nodegrabber (core/input/actionFilter.lua, BeamNG.drive 0.39):
-- six actions, the last two gamepad variants.
local NODEGRABBER_ACTIONS = {
    "nodegrabberAction",
    "nodegrabberGrab",
    "nodegrabberRender",
    "nodegrabberStrength",
    "nodegrabberPadGrab",
    "nodegrabberPadMode",
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

-- The node-grabber actions to block, preferring the engine's own template over the built-in list.
-- Returns (actions, is_from_template).
--
-- getActionTemplates hands back the RAW actionTemplates table, not a copy (core/input/actionFilter.lua), so
-- this only ever reads it and copies the names out -- inserting into or reordering that table would change
-- what every other subsystem blocks.
--
-- Every step degrades instead of throwing: a missing API, a missing template, or a template of an
-- unexpected shape all fall back to NODEGRABBER_ACTIONS, because losing the grabber names must not also
-- lose the thirteen other actions that share the group. The fallback is not silent -- see
-- report_nodegrabber_block.
local function nodegrabber_actions()
    local from_template
    pcall(function()
        if type(core_input_actionFilter.getActionTemplates) ~= "function" then
            return
        end
        local templates = core_input_actionFilter.getActionTemplates()
        if type(templates) ~= "table" or type(templates[NODEGRABBER_TEMPLATE]) ~= "table" then
            return
        end
        local names = {}
        for _, action in ipairs(templates[NODEGRABBER_TEMPLATE]) do
            if type(action) == "string" and action ~= "" then
                names[#names + 1] = action
            end
        end
        if #names > 0 then
            from_template = names
        end
    end)
    if from_template then
        return from_template, true
    end
    return NODEGRABBER_ACTIONS, false
end

-- Build the blocked-action list for the requested mode: always BLOCKED_ACTIONS plus the node-grabber
-- actions, plus the two selector actions unless replace is allowed (the swap-allowed staging mode leaves
-- the selector open -- there the player may change car, but still must not drag it off its slot, ADR-0021).
--
-- Always a fresh array, in both modes: setGroup stores the array BY REFERENCE (actionGroups[name] =
-- arrayValues) and serializes it across Lua reloads, so the engine must never be handed one of this
-- module's own constant tables to hold on to.
local function blocked_actions_for(allow_replace, grabber_actions)
    local actions = {}
    for _, action in ipairs(BLOCKED_ACTIONS) do
        actions[#actions + 1] = action
    end
    for _, action in ipairs(grabber_actions) do
        actions[#actions + 1] = action
    end
    if not allow_replace then
        for _, action in ipairs(SELECTOR_ACTIONS) do
            actions[#actions + 1] = action
        end
    end
    return actions
end

-- One line per lock install (ADR-0017 amendment, nodegrabber-action-names-wrong) reporting how much of the
-- node-grabber block the engine says is live. Deliberately once per install and never per frame: the client
-- log goes blind after ~15k entries and BeamMP fills it on its own, so a per-frame line would destroy the
-- very evidence it exists to provide.
--
-- Read the count for exactly what it is. isActionBlocked answers from blockedActions[filter][name], which
-- addToFilter writes for EVERY name it is handed, real or not. So "6 of 6" proves that our group reached
-- the filter and that nobody cleared filter 0 out from under us -- it does NOT prove the six names exist.
-- Name validity is what reading them from the engine template buys, which is why a fallback to the
-- built-in list is the warning worth reacting to.
local function report_nodegrabber_block(grabber_actions, is_from_template, allow_replace)
    if not is_from_template then
        log("W", LOG_TAG, "node grabber block: engine action template '" .. NODEGRABBER_TEMPLATE
            .. "' unavailable, using the built-in name list -- re-check it against the engine's"
            .. " core/input/actionFilter.lua")
    end
    if type(core_input_actionFilter.isActionBlocked) ~= "function" then
        return
    end
    local ok, filtered, unfiltered = pcall(function()
        local count, gaps = 0, {}
        for _, action in ipairs(grabber_actions) do
            if core_input_actionFilter.isActionBlocked(action) then
                count = count + 1
            else
                gaps[#gaps + 1] = action
            end
        end
        return count, gaps
    end)
    if not ok then
        log("W", LOG_TAG, "node grabber block: could not read the filter state: " .. tostring(filtered))
        return
    end
    local summary = string.format(
        "node grabber block: %d of %d actions filtered (%s lock, names from %s)",
        filtered, #grabber_actions, allow_replace and "swap-allowed" or "full",
        is_from_template and "the engine template" or "the built-in fallback")
    if #unfiltered == 0 then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; not filtered: " .. table.concat(unfiltered, ", "))
    end
end

-- Block or unblock the input-action group. setGroup defines the action list; addAction toggles it on
-- our shared filter. Re-calling setGroup redefines the group, so upgrading the swap-allowed mode to the
-- full lock (countdown) just re-blocks with the selector actions added. Wrapped in pcall: the input API
-- is engine-version-coupled, so a mismatch warns once rather than breaking the phase handler -- and the
-- node-grabber template read rides inside that same guard.
local function set_action_filter(blocked, allow_replace)
    if type(core_input_actionFilter) ~= "table" then
        return
    end
    local grabber_actions, is_from_template
    local ok, err = pcall(function()
        if blocked then
            grabber_actions, is_from_template = nodegrabber_actions()
            core_input_actionFilter.setGroup(ACTION_GROUP,
                blocked_actions_for(allow_replace, grabber_actions))
        end
        core_input_actionFilter.addAction(FILTER_ID, ACTION_GROUP, blocked)
    end)
    if not ok then
        log("W", LOG_TAG, "action filter update failed: " .. tostring(err))
        return
    end
    -- Only after addAction: it is addAction -> updateFilters that actually applies the group, so what
    -- this reads back is the filter state the lock just produced.
    if blocked then
        report_nodegrabber_block(grabber_actions, is_from_template, allow_replace)
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
            core_vehicles.replaceVehicle = function(model_name, opt, ...)
                M.replace_seen = true
                -- The caller's chance to act on the NEW car before the engine touches anything (ADR-0051
                -- round 2). _replaceVehicle takes the replacement's spawn position from the OUTGOING car
                -- (`localOptions.pos = veh:getPosition()`), so a swap into a differently sized car lands
                -- offset and has to be nudged afterwards -- a visible jump. Knowing model_name and
                -- opt.config here is what lets init.lua pre-position the outgoing car instead, which is
                -- free: it is deleted in this same call and never rendered where it was moved to.
                --
                -- Kept deliberately thin: this is lock infrastructure on an engine function, so the hook
                -- is optional, pcall-guarded, and its outcome is ignored. Anything that goes wrong in it
                -- must leave the replace itself exactly as it was.
                if type(M.on_before_replace) == "function" then
                    pcall(M.on_before_replace, model_name, opt)
                end
                -- Turn OFF the engine's spawn-avoidance nudge for this one replace.
                --
                -- safeSpawn defaults to ON (spawn.lua: `options.safeSpawn == true or == nil`), and it
                -- pushes the freshly placed car around until it intersects no other vehicle
                -- (setSafePosition -> placeVehicle). That is the right instinct for a car being spawned
                -- SOMEWHERE; it is exactly wrong for one we are deliberately putting on its own reserved
                -- grid slot, where the neighbours it is "rescued" from are the cars it is supposed to
                -- line up with. It is also what made the swap asymmetric: a smaller replacement
                -- intersected nobody and stayed put, a bigger one got shoved off the slot we had just
                -- anchored and then had to be visibly corrected back.
                --
                -- Safe here for two reasons: the field is frozen through staging, so nothing can move
                -- into the slot; and the flag survives the option chain -- replaceVehicle deepcopies opt
                -- AFTER this line, and sanitizeVehicleSpawnOptions returns the same table it was given
                -- (fillVehicleSpawnOptionDefaults mutates and returns opt), so `false` reaches
                -- replaceOtherVehicle's `if options.safeSpawn == nil` guard as a real false.
                --
                -- Scoped to this wrapper alone, which only exists under the swap-allowed staging lock --
                -- never global, and never for the race spawn (see race/vehicles.lua spawn_vehicle_at).
                --
                -- Forwarded as a COPY rather than set on the caller's table: the options belong to
                -- whoever called replaceVehicle (the vehicle/parts selector, our own compliance revert),
                -- and a table they might reuse must not silently keep our flag. A shallow copy is enough
                -- -- we only add a boolean, and replaceVehicle deep-copies before anything mutates it.
                local forwarded = opt
                pcall(function()
                    if type(opt) == "table" then
                        local copy = {}
                        for key, value in pairs(opt) do
                            copy[key] = value
                        end
                        copy.safeSpawn = false
                        forwarded = copy
                    end
                end)
                return core_vehicles[ORIG_REPLACE_KEY](model_name, forwarded, ...)
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
