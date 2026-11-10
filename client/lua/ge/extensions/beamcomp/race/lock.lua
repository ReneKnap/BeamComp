-- BeamComp -- in-race vehicle-action lock (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/lock.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Near-stateless (a few transient flags, see below): the caller (init.lua) installs the
-- lock when the race countdown starts and removes it when the race returns to lobby (ADR-0017), and
-- calls M.step once per frame for the selector bar and the pause menu's vehicle tab.
--
-- During countdown + racing the player must stay in their one race car. Four layers prevent leaving
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
--      affected (and handle_race_start removes the lock up front as a belt-and-braces guard). The
--      selector's own buttons reach the car without either of the two, so four more core_vehicles
--      functions are refused in every mode (VEHICLE_BUTTONS, ADR-0017 amendment 2026-11-05).
--   3. The vehicle selector's management bar is hidden for the whole lock through the engine's own switch,
--      the one career and challenges use. That also takes Reset all and Remove all away, which have no
--      core_vehicles field to guard. The pick itself (spawn / replace) stays, so the staging swap works.
--   4. The pause menu's vehicle tab decides whether its car buttons are enabled only when it builds them, so
--      one built before the install keeps them working. Its single public entry is wrapped for the lock and
--      refuses Remove, Reset, Repair here, Remove all other vehicles and Switch to vehicle, and an open tab
--      is asked to rebuild so they grey out (ADR-0017 amendment 2026-11-10). The same amendment adds
--      toggleAITraffic to layer 1: the tab and the radial menu ask it before they hand a car to the AI.
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
-- A race that FORCES this player's car (ADR-0064) narrows both modes: the replace is refused from staging
-- on, and a guard on core_vehicle_partmgmt refuses every parts change before its respawn, while tuning
-- and paint go through untouched. Whether the race forces the car is asked of M.car_is_forced on every
-- install, never passed in. A race with a vehicle limit (Mode 3) arms the same guard in the full lock only
-- (ADR-0064 amendment 2026-11-04): in staging a parts change is allowed and measured afterwards, from the
-- countdown on it is refused. Asked of M.race_has_caps the same way.
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

-- Whether the running race forces this player's car: car=<model[:config]>, car=random, car=host, or a
-- class-drop class with a car (ADR-0064). init.lua installs the real predicate in onExtensionLoaded, the
-- same shape as M.notify below. install() asks it on EVERY call rather than taking an option, so the quali
-- re-grid's remove/install pair re-arms the parts lock without knowing it exists. This default answers
-- false: a seam nobody installed keeps the lock exactly as it was before forced cars locked their parts.
function M.car_is_forced()
    return false
end

-- Whether the running race has a vehicle limit (maxhp / maxpwr / minkg / maxkg, ADR-0032). Installed by
-- init.lua beside car_is_forced and asked by every install the same way. Under a limit the parts are locked
-- from the countdown on (the full lock): a change there would land on a car that is already about to race,
-- and only tuning is left to measure and revert (init.lua M.caps). This default answers false.
function M.race_has_caps()
    return false
end

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

-- Handing the player's own race car to the AI (ADR-0017 amendment 2026-11-10). The pause menu's vehicle tab
-- offers its AI modes only while this action is not blocked and asks again at click time
-- (ui/pause/providers/vehicleTabInteractions.lua canUseVehicleAiModes), the radial menu builds its whole AI
-- page only then (core/quickAccess.lua), and the action's own key runs ai.toggleTrafficMode on the seated
-- car. So the filter alone closes all three, in both lock modes. BeamComp's AI opponents never pass through
-- it: race/ai.lua sets their modes with queueLuaCommand on their own VE, which no input filter reaches.
--
-- The name is checked against the engine's template rather than taken on trust, for the node-grabber reason
-- (an unknown name is a silent no-op). The template also holds toggleTraffic, which spawns ambient traffic
-- and never touches a car's AI mode, so it stays open and the template is read, not adopted whole.
local AI_MODE_TEMPLATE = "aiControls"
local AI_MODE_ACTION = "toggleAITraffic"

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

-- The core_vehicles functions behind the vehicle selector's own buttons, which change the car without
-- passing spawnNewVehicle / replaceVehicle (bug vehicle-selector-load-default-bypasses-race-lock):
--   spawnDefault  -- "Load default". In MP the field is BeamMP's spawnDefaultRequest, which calls BeamMP's
--                    own stashed replaceVehicle; in SP the engine calls its file-local one.
--   cloneCurrent  -- "Clone current" (also the radial menu and the pause tab): the engine's file-local
--                    spawnNewVehicle, behind BeamMP's protected-config wrapper.
--   removeCurrent -- "Remove current": veh:delete(), nothing else.
--   removeAll     -- the dev build's Debug tab.
-- Refused in every lock mode, staging included even when the race forces no car: a staging swap goes
-- through the selector's normal pick, never through these.
local VEHICLE_BUTTONS = {"spawnDefault", "cloneCurrent", "removeCurrent", "removeAll"}

-- Prefix of their stash keys on core_vehicles, the same shape as the two keys above.
local VEHICLE_BUTTON_ORIG_PREFIX = "beamcomp_orig_"

-- The engine module that builds the vehicle selector's management bar (Set as default, Load default, Save
-- current config, Clone current, Select random, Reset all, Remove all / current / others). It is read with
-- rawget and never through `extensions.<name>`, which would LOAD it (common/extensions.lua __index): the lock
-- acts only on a module the game has loaded itself, and catches a later one in M.step.
local SELECTOR_OPS_MODULE = "ui_vehicleSelector_vehicleOperations"
local SELECTOR_NOT_LOADED = SELECTOR_OPS_MODULE .. " is not loaded yet"

-- Stash key of the original getManagementDetails, on the module table: a reloaded module is a fresh table
-- without it, which is how M.step tells a module it still has to hide the bar on.
local ORIG_MANAGEMENT_KEY = "beamcomp_orig_getManagementDetails"

-- The selector's own redraw event and backend name. The engine fires exactly this after it switches the bar
-- (ui/vehicleSelector/general.lua, openVehicleSelectorForChallenge); only a mounted selector listens.
local SELECTOR_REDRAW_EVENT = "gridSelectorRefreshAll"
local SELECTOR_BACKEND = "vehicleSelector"

-- The bar's bookkeeping. Module state a GE reload forgets together with the wrapper itself (the teardown
-- runs M.remove first), like parts_lock_reason.
--   wanted    -- the lock is installed, so the bar is to be hidden
--   announced -- the bar state an open selector was last asked to redraw for (true = hidden)
--   outcome   -- why the bar could not be hidden at the last attempt (nil = hidden), so M.step never logs
--                the same failure twice
--   warned    -- the "engine ignored the switch" tripwire already fired for this hide
local selector_bar = {wanted = false, announced = false, outcome = nil, warned = false}

-- The engine module behind the pause menu's vehicle tab. Every click in every view of the tab (the vehicle
-- list, a vehicle's details, the pause home's nearby vehicles) reaches it through one public entry the Vue UI
-- calls by name, executeVehicleTabInteractionAction(buttonId, payload), and that entry is what the lock
-- wraps. The button's enabled state comes from canModifyVehicles() when the tab builds it, and the click
-- handlers never ask again (bug pause-tab-open-across-race-start-keeps-car-actions). Read with rawget, like
-- the selector module.
local TAB_MODULE = "ui_pause_providers_vehicleTabInteractions"
local TAB_ENTRY = "executeVehicleTabInteractionAction"
local TAB_NOT_LOADED = TAB_MODULE .. " is not loaded yet"

-- Stash key of the original entry, on the provider table: a reloaded provider is a fresh table without it.
local ORIG_TAB_KEY = "beamcomp_orig_" .. TAB_ENTRY

-- Where a button's action is written down: the provider's file local `buttonInstance`
-- (gridSelectorUtils/buttonModule.lua), an upvalue of the entry, looked up by NAME and never by index.
-- getButtonInfo(buttonId).meta.action is the action the tab registered the button under.
local TAB_BUTTONS_UPVALUE = "buttonInstance"

-- The tab actions the lock refuses. Clone needs no entry (core_vehicles.cloneCurrent refuses it,
-- VEHICLE_BUTTONS), the AI modes need none (the engine refuses them itself once AI_MODE_ACTION is blocked),
-- and Open details and Exit vehicle stay free.
local TAB_REFUSED_ACTIONS = {
    deleteVehicle = true,
    resetVehicle = true,
    repairVehicleHere = true,
    removeAllOtherVehicles = true,
    switchToVehicle = true,
}

-- Switch to vehicle once per local player when several sit at one machine: switchToVehicle_p0, _p1, ...
local TAB_SEAT_SWITCH_PATTERN = "^switchToVehicle_p%d+$"

-- The tab's own refresh event. The provider fires it after every vehicle spawn (onVehicleSpawned), and an
-- open vehicle list answers it by fetching its whole payload again, built with the lock's current answer.
local TAB_REBUILD_EVENT = "VehicleTabSpawnFinished"

-- The tab's bookkeeping, the same shape as selector_bar and forgotten by a GE reload the same way:
--   wanted    -- the lock is installed, so the entry is to be guarded and an open tab is to show it
--   announced -- the lock state an open tab was last asked to rebuild for
--   outcome   -- why the entry could not be guarded at the last attempt (nil = guarded), so M.step never logs
--                the same failure twice
local pause_tab = {wanted = false, announced = false, outcome = nil}

-- Min seconds between "locked" toasts on a refused spawn/replace, so mashing the selector shows one
-- toast, not a flood. os.clock() is monotonic CPU seconds -- precise enough to gate a toast.
local SPAWN_BLOCK_TOAST_THROTTLE = 2.0
local last_spawn_block_toast_at = 0

-- What a refused parts change tells the player, throttled like the spawn refusal but on its own clock, so
-- a refused car pick right before it does not swallow it.
local PARTS_LOCKED_NOTICE = "Parts are locked for this race"
local last_parts_block_notice_at = 0

-- Why the parts guard is armed by the current install ("forced car" or "vehicle limit"), for the refusal's
-- log line; nil while it is not armed. Module state a GE reload forgets together with the guard itself
-- (remove() runs from the teardown first).
local parts_lock_reason = nil

-- What a refusal's log line says the lock is for, per reason.
local PARTS_LOCK_WHY = {
    ["forced car"] = "this race forces the car",
    ["vehicle limit"] = "parts are locked under the vehicle limit from the countdown on",
}

-- Prefix of the per-function stash keys on core_vehicle_partmgmt. On the engine table for the same reason
-- as ORIG_SPAWN_KEY: a present original means we are already guarding, whatever this module's state says.
local PARTS_ORIG_PREFIX = "beamcomp_orig_"

-- The config keys a tuning or paint change carries (partmgmt setConfigVars / setConfigPaints). licenseName
-- is the plate, not a part.
local TUNING_KEYS = {vars = true, paints = true, licenseName = true}

-- Where a player-facing refusal from this module goes. init.lua installs its phase-routing chokepoint
-- here (notice.say) in onExtensionLoaded: during a race the message belongs in the screen centre, outside
-- it in the top-left toast (feature race-toast-cleanup-and-checkpoint-readout). This module cannot reach
-- that chokepoint itself -- init.lua requires it, not the other way round -- so it is handed in, the same
-- shape as on_before_replace above.
--
-- The built-in default is the OLD toast on purpose: a seam nobody installed then degrades to the surface
-- this message had before, never to silence. Re-installed after a GE Lua reload with everything else in
-- onExtensionLoaded (ADR-0052).
function M.notify(msg, kind)
    if not guihooks then
        return
    end
    guihooks.trigger("toastrMsg", {type = kind or "warning", title = "BeamComp", msg = msg})
end

-- The lock's notice for every refused car route: the selector, its buttons and the pause tab. One text and
-- one clock, so a refused clone and the tab click right after it show one notice, not two of the same.
local function show_vehicle_lock_notice()
    local now = os.clock()
    if now - last_spawn_block_toast_at >= SPAWN_BLOCK_TOAST_THROTTLE then
        last_spawn_block_toast_at = now
        M.notify("Switching or spawning vehicles is locked during the race", "warning")
    end
end

-- `route` names the refused core_vehicles function in the log line; the two original guards pass none.
local function notify_spawn_blocked(route)
    show_vehicle_lock_notice()
    log("I", LOG_TAG, "blocked a vehicle spawn/replace during the race"
        .. (route and " (core_vehicles." .. route .. ")" or ""))
end

-- The action names of one engine action template, copied out, or nil when the engine offers no such template.
--
-- getActionTemplates hands back the RAW actionTemplates table, not a copy (core/input/actionFilter.lua), so
-- this only ever reads it and copies the names out -- inserting into or reordering that table would change
-- what every other subsystem blocks.
--
-- Every step degrades instead of throwing: a missing API, a missing template, or a template of an unexpected
-- shape all answer nil, and each caller falls back to its built-in names with a warning.
local function template_actions(template)
    local found
    pcall(function()
        if type(core_input_actionFilter.getActionTemplates) ~= "function" then
            return
        end
        local templates = core_input_actionFilter.getActionTemplates()
        if type(templates) ~= "table" or type(templates[template]) ~= "table" then
            return
        end
        local names = {}
        for _, action in ipairs(templates[template]) do
            if type(action) == "string" and action ~= "" then
                names[#names + 1] = action
            end
        end
        if #names > 0 then
            found = names
        end
    end)
    return found
end

-- The node-grabber actions to block, preferring the engine's own template over the built-in list. Returns
-- (actions, is_from_template). The fallback keeps the grabber names from taking the other actions that share
-- the group down with them, and it is not silent -- see report_nodegrabber_block.
local function nodegrabber_actions()
    local from_template = template_actions(NODEGRABBER_TEMPLATE)
    if from_template then
        return from_template, true
    end
    return NODEGRABBER_ACTIONS, false
end

-- Build the blocked-action list for the requested mode: always BLOCKED_ACTIONS, the node-grabber actions and
-- the AI-mode action, plus the two selector actions unless replace is allowed (the swap-allowed staging mode
-- leaves the selector open -- there the player may change car, but still must not drag it off its slot or
-- hand it to the AI, ADR-0021).
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
    actions[#actions + 1] = AI_MODE_ACTION
    if not allow_replace then
        for _, action in ipairs(SELECTOR_ACTIONS) do
            actions[#actions + 1] = action
        end
    end
    return actions
end

-- The actions of `actions` the filter does not report as blocked. nil plus the reason when the filter state
-- cannot be read at all.
local function unfiltered_actions(actions)
    if type(core_input_actionFilter.isActionBlocked) ~= "function" then
        return nil, "core_input_actionFilter has no isActionBlocked"
    end
    local ok, gaps = pcall(function()
        local found = {}
        for _, action in ipairs(actions) do
            if not core_input_actionFilter.isActionBlocked(action) then
                found[#found + 1] = action
            end
        end
        return found
    end)
    if not ok then
        return nil, tostring(gaps)
    end
    return gaps
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
    local unfiltered, err = unfiltered_actions(grabber_actions)
    if unfiltered == nil then
        log("W", LOG_TAG, "node grabber block: could not read the filter state: " .. tostring(err))
        return
    end
    local summary = string.format(
        "node grabber block: %d of %d actions filtered (%s lock, names from %s)",
        #grabber_actions - #unfiltered, #grabber_actions, allow_replace and "swap-allowed" or "full",
        is_from_template and "the engine template" or "the built-in fallback")
    if #unfiltered == 0 then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; not filtered: " .. table.concat(unfiltered, ", "))
    end
end

-- Where the AI-mode name stands against the engine's template, for the install line: the clause and whether
-- it is the expected answer.
local function ai_mode_name_source()
    local template = template_actions(AI_MODE_TEMPLATE)
    if template == nil then
        return "engine template '" .. AI_MODE_TEMPLATE .. "' unavailable, built-in name", false
    end
    for _, action in ipairs(template) do
        if action == AI_MODE_ACTION then
            return "name in the engine template '" .. AI_MODE_TEMPLATE .. "'", true
        end
    end
    return "name NOT in the engine template '" .. AI_MODE_TEMPLATE .. "' ("
        .. table.concat(template, ", ") .. ")", false
end

-- One line per lock install for the AI-mode block, read the same way as the node-grabber line: the filter
-- answer proves the group reached the filter, and the template clause is what proves the name is one the
-- engine knows. Either one off is a W.
local function report_ai_mode_block(allow_replace)
    local source, is_known = ai_mode_name_source()
    local unfiltered, err = unfiltered_actions({AI_MODE_ACTION})
    local state = "filtered"
    if unfiltered == nil then
        state = "filter state unreadable (" .. tostring(err) .. ")"
    elseif #unfiltered > 0 then
        state = "NOT filtered"
    end
    local summary = string.format("AI modes: %s %s (%s lock, %s)", AI_MODE_ACTION, state,
        allow_replace and "swap-allowed" or "full", source)
    if is_known and state == "filtered" then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; the own car can be handed to the AI, re-check the engine's"
            .. " core/input/actionFilter.lua")
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
        report_ai_mode_block(allow_replace)
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

-- The stand-in for one VEHICLE_BUTTONS function: the vehicle notice and nil, never an error. The selector
-- calls these from a fade callback after `app:waiting true`, so a throw would leave its spinner standing.
-- Every caller already reads nil as "nothing happened" (a refused clone logs its own failure and clears
-- the spinner).
local function refuse_vehicle_button(name)
    return function()
        local ok, err = pcall(notify_spawn_blocked, name)
        if not ok then
            log("W", LOG_TAG, "refused " .. name .. ", but answering it failed: " .. tostring(err))
        end
        return nil
    end
end

-- Wrap every VEHICLE_BUTTONS function present on core_vehicles. Same shape as guard_partmgmt: the original
-- is stashed once on the engine table, the stand-in is (re)assigned on every install, so a second install
-- never captures our own stand-in as the "original". Returns the wrapped and the missing names, or nil when
-- core_vehicles is not loaded.
local function guard_vehicle_buttons()
    if type(core_vehicles) ~= "table" then
        return nil
    end
    local wrapped, missing = {}, {}
    for _, name in ipairs(VEHICLE_BUTTONS) do
        local stash_key = VEHICLE_BUTTON_ORIG_PREFIX .. name
        if core_vehicles[stash_key] == nil and type(core_vehicles[name]) == "function" then
            core_vehicles[stash_key] = core_vehicles[name]
        end
        if core_vehicles[stash_key] ~= nil then
            core_vehicles[name] = refuse_vehicle_button(name)
            wrapped[#wrapped + 1] = name
        else
            missing[#missing + 1] = name
        end
    end
    return wrapped, missing
end

-- Put back every stashed VEHICLE_BUTTONS original. No-op when not guarding.
local function unguard_vehicle_buttons()
    if type(core_vehicles) ~= "table" then
        return
    end
    for _, name in ipairs(VEHICLE_BUTTONS) do
        local stash_key = VEHICLE_BUTTON_ORIG_PREFIX .. name
        if core_vehicles[stash_key] ~= nil then
            core_vehicles[name] = core_vehicles[stash_key]
            core_vehicles[stash_key] = nil
        end
    end
end

-- One line per install naming what is wrapped. A function missing after a game update is an open route,
-- so it is named at W, like report_parts_guard.
local function report_vehicle_buttons(wrapped, missing)
    if wrapped == nil then
        log("W", LOG_TAG, "vehicle buttons: core_vehicles is not loaded, Load default / Clone / Remove"
            .. " are NOT locked")
        return
    end
    local summary = string.format("vehicle buttons: wrapped %d of %d core_vehicles functions (%s)",
        #wrapped, #VEHICLE_BUTTONS, table.concat(wrapped, ", "))
    if #missing == 0 then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; not found: " .. table.concat(missing, ", ")
            .. "; re-check the engine's core/vehicles.lua")
    end
end

-- The selector module the game has loaded right now, or nil. Never loads it (see SELECTOR_OPS_MODULE).
local function selector_ops()
    local ops = rawget(_G, SELECTOR_OPS_MODULE)
    if type(ops) ~= "table" then
        return nil
    end
    return ops
end

local function is_selector_bar_hidden()
    local ops = selector_ops()
    return ops ~= nil and ops[ORIG_MANAGEMENT_KEY] ~= nil
end

-- The tripwire behind the switch: with managementButtonsEnabled off the engine builds no button at all, so a
-- button in the answer means it reads another switch now and the bar is back. Once per hide, never per call.
local function check_bar_hidden(details)
    if selector_bar.warned or type(details) ~= "table" or type(details.buttonInfo) ~= "table" then
        return
    end
    if next(details.buttonInfo) ~= nil then
        selector_bar.warned = true
        log("W", LOG_TAG, string.format("vehicle selector bar: the engine built %d buttons although"
            .. " managementButtonsEnabled was off, the bar is NOT hidden; re-check the engine's"
            .. " ui/vehicleSelector/vehicleOperations.lua", #details.buttonInfo))
    end
end

-- Put the engine's switch back, then hand on what the original answered, or its error unchanged.
local function finish_management_call(ops, enabled, ok, ...)
    ops.managementButtonsEnabled = enabled
    if not ok then
        error((...), 0)
    end
    check_bar_hidden((...))
    return ...
end

-- The wrapper for getManagementDetails. It turns the engine's switch off for the length of the call only
-- and puts the engine's own value back right after, so the lock never owns the switch: the selector may
-- set it on every open, and whatever it set last is what stands once the lock is lifted (a career false
-- stays false). Off is the engine's own career / challenge path: no management button, the current car's
-- name and thumbnail still built. Once the stash is gone (the lock was lifted) a kept copy is a plain
-- pass-through.
local function bar_guard_for(ops, original)
    return function(...)
        if ops[ORIG_MANAGEMENT_KEY] == nil then
            return original(...)
        end
        local enabled = ops.managementButtonsEnabled
        ops.managementButtonsEnabled = false
        return finish_management_call(ops, enabled, pcall(original, ...))
    end
end

-- Hide the bar on the loaded module. Returns nil when it is hidden (now or already), else why not.
-- Whether the engine still reads managementButtonsEnabled is not probed here: the field may legitimately
-- hold nil, and a renamed switch shows up as buttons in the first answer (check_bar_hidden), which is the
-- evidence a probe could only guess at.
local function hide_selector_bar()
    local ops = selector_ops()
    if ops == nil then
        return SELECTOR_NOT_LOADED
    end
    if ops[ORIG_MANAGEMENT_KEY] ~= nil then
        return nil
    end
    if type(ops.getManagementDetails) ~= "function" then
        return SELECTOR_OPS_MODULE .. " has no getManagementDetails"
    end
    local original = ops.getManagementDetails
    ops[ORIG_MANAGEMENT_KEY] = original
    ops.getManagementDetails = bar_guard_for(ops, original)
    selector_bar.warned = false
    return nil
end

-- Give the bar back. Only the function goes back; the switch was never ours. Returns whether anything did.
local function show_selector_bar()
    local ops = selector_ops()
    if ops == nil or ops[ORIG_MANAGEMENT_KEY] == nil then
        return false
    end
    ops.getManagementDetails = ops[ORIG_MANAGEMENT_KEY]
    ops[ORIG_MANAGEMENT_KEY] = nil
    return true
end

-- One line per outcome of a hide. A module that is not loaded yet is expected and is caught by M.step; a
-- missing function is the tripwire after a game update. `context` says which hide it was.
local function report_selector_bar(reason, context)
    selector_bar.outcome = reason
    if reason == nil then
        log("I", LOG_TAG, "vehicle selector bar: hidden " .. context)
    elseif reason == SELECTOR_NOT_LOADED then
        log("I", LOG_TAG, "vehicle selector bar: " .. reason .. ", hidden as soon as the game loads it")
    else
        log("W", LOG_TAG, "vehicle selector bar NOT hidden: " .. reason
            .. "; re-check the engine's ui/vehicleSelector/vehicleOperations.lua")
    end
end

-- Ask an open vehicle selector to fetch its bar again. A selector fetches it only when it opens or its
-- selection clears, so one that stayed open across the install would otherwise keep Reset all and Remove all
-- for the whole staging. A closed selector has no listener, so this costs nothing then.
local function redraw_open_selector(is_hidden)
    if type(guihooks) ~= "table" then
        return
    end
    local ok, err = pcall(guihooks.trigger, SELECTOR_REDRAW_EVENT, SELECTOR_BACKEND)
    if not ok then
        log("W", LOG_TAG, "vehicle selector redraw failed: " .. tostring(err))
        return
    end
    log("I", LOG_TAG, "vehicle selector bar " .. (is_hidden and "hidden" or "back")
        .. ": asked an open selector to redraw (" .. SELECTOR_REDRAW_EVENT .. ")")
end

-- The tab provider the game has loaded right now, or nil. Never loads it (see TAB_MODULE).
local function tab_provider()
    local tab = rawget(_G, TAB_MODULE)
    if type(tab) ~= "table" then
        return nil
    end
    return tab
end

local function is_tab_guarded()
    local tab = tab_provider()
    return tab ~= nil and tab[ORIG_TAB_KEY] ~= nil
end

-- The provider's button map, found among the upvalues of its original entry by name. nil plus why not when
-- the debug library is missing, the walk fails, or no upvalue of that name carries a getButtonInfo.
local function tab_buttons(entry)
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then
        return nil, "the debug library is not available"
    end
    local ok, buttons = pcall(function()
        local index = 1
        while true do
            local name, value = debug.getupvalue(entry, index)
            if name == nil then
                return nil
            end
            if name == TAB_BUTTONS_UPVALUE then
                return value
            end
            index = index + 1
        end
    end)
    if not ok then
        return nil, "reading its upvalues failed: " .. tostring(buttons)
    end
    if type(buttons) ~= "table" or type(buttons.getButtonInfo) ~= "function" then
        return nil, "the entry has no upvalue '" .. TAB_BUTTONS_UPVALUE .. "' with a getButtonInfo"
    end
    return buttons
end

-- The action a tab button was registered under, or nil when it cannot be read.
local function tab_button_action(buttons, button_id)
    local info = buttons.getButtonInfo(button_id)
    local meta = type(info) == "table" and info.meta or nil
    local action = type(meta) == "table" and meta.action or nil
    if type(action) ~= "string" then
        return nil
    end
    return action
end

local function is_refused_tab_action(action)
    return TAB_REFUSED_ACTIONS[action] == true or action:find(TAB_SEAT_SWITCH_PATTERN) ~= nil
end

-- Whether the lock refuses this click. Returns (refuse, label, why): the label names the action, or the
-- button when its action is unknown, and `why` is set when the refusal is a fail-closed one, which the log
-- then says. Fail-closed in both unknown cases: without the button map every click is refused, and so is a
-- button whose action cannot be read -- a button that refuses Open details costs a notice, one that lets
-- Reset through costs the race.
local function tab_verdict(buttons, button_id)
    local label = "button " .. tostring(button_id)
    if buttons == nil then
        return true, label, "the button map is unreadable"
    end
    local ok, action = pcall(tab_button_action, buttons, button_id)
    if not ok then
        return true, label, "reading its action failed: " .. tostring(action)
    end
    if action == nil then
        return true, label, "its action cannot be read"
    end
    return is_refused_tab_action(action), action, nil
end

-- One refused tab click: a log line every time (a click, never a frame), then the lock's notice. The line
-- first, so a throwing notice cannot swallow it.
local function refuse_tab_action(label, why)
    if why then
        log("W", LOG_TAG, "refused a pause-menu vehicle tab action (" .. label .. ", fail-closed: "
            .. why .. ")")
    else
        log("I", LOG_TAG, "refused a pause-menu vehicle tab action (" .. label .. ")")
    end
    show_vehicle_lock_notice()
end

-- The wrapper for the tab's entry. A refused click answers nil, never false and never an error. The vehicle
-- list and a vehicle's details fetch their payload again after a click whatever it answered (the details not
-- after a delete), the pause home's nearby vehicles only after one that did not answer false, so nil is what
-- lets a view the rebuild event does not reach grey out after the refused click. Once the stash is gone (the
-- lock was lifted) a kept copy is a plain pass-through.
local function tab_guard_for(tab, original, buttons)
    return function(button_id, ...)
        if tab[ORIG_TAB_KEY] == nil then
            return original(button_id, ...)
        end
        local refuse, label, why = tab_verdict(buttons, button_id)
        if not refuse then
            return original(button_id, ...)
        end
        local ok, err = pcall(refuse_tab_action, label, why)
        if not ok then
            log("W", LOG_TAG, "refused a pause-menu vehicle tab action, but answering it failed: "
                .. tostring(err))
        end
        return nil
    end
end

-- Wrap the entry on the loaded provider. Returns (failure, unreadable): failure is nil when the entry is
-- guarded (now or already) and says why not otherwise; unreadable says why the button map could not be read,
-- in which case the guard refuses every click. Same stash shape as guard_partmgmt: the original once, the
-- wrapper (re)assigned on every call, so a second install never captures our own wrapper as the "original".
local function guard_pause_tab()
    local tab = tab_provider()
    if tab == nil then
        return TAB_NOT_LOADED
    end
    if tab[ORIG_TAB_KEY] == nil then
        if type(tab[TAB_ENTRY]) ~= "function" then
            return TAB_MODULE .. " has no " .. TAB_ENTRY
        end
        tab[ORIG_TAB_KEY] = tab[TAB_ENTRY]
    end
    local original = tab[ORIG_TAB_KEY]
    local buttons, unreadable = tab_buttons(original)
    tab[TAB_ENTRY] = tab_guard_for(tab, original, buttons)
    return nil, unreadable
end

-- Give the original entry back. Returns whether anything was guarded.
local function unguard_pause_tab()
    local tab = tab_provider()
    if tab == nil or tab[ORIG_TAB_KEY] == nil then
        return false
    end
    tab[TAB_ENTRY] = tab[ORIG_TAB_KEY]
    tab[ORIG_TAB_KEY] = nil
    return true
end

-- One line per outcome of a guard. A provider that is not loaded yet is expected and is caught by M.step; a
-- missing entry and a fail-closed guard are the tripwires after a game update, and the suffix of the guarded
-- line names where the actions come from. `context` says which guard it was.
local function report_pause_tab(context, failure, unreadable)
    pause_tab.outcome = failure
    if failure == TAB_NOT_LOADED then
        log("I", LOG_TAG, "pause-menu vehicle tab: " .. failure .. ", guarded as soon as the game loads it")
    elseif failure then
        log("W", LOG_TAG, "pause-menu vehicle tab NOT guarded: " .. failure
            .. "; re-check the engine's ui/pause/providers/vehicleTabInteractions.lua")
    elseif unreadable then
        log("W", LOG_TAG, "pause-menu vehicle tab: guarded " .. context .. ", FAIL-CLOSED (" .. unreadable
            .. "), every tab action is refused; re-check the engine's"
            .. " ui/pause/providers/vehicleTabInteractions.lua")
    else
        log("I", LOG_TAG, "pause-menu vehicle tab: guarded " .. context
            .. " (actions from the provider's button map)")
    end
end

-- Ask an open tab to rebuild, so its buttons follow the lock. The vehicle list fetches its payload again on
-- this event; a vehicle's details view and the pause home's nearby vehicles do not, and grey out after their
-- first click, which the guard refuses. Nothing to ask while the provider is not loaded: no tab is built.
local function rebuild_open_tab(is_locked)
    if tab_provider() == nil or type(guihooks) ~= "table" then
        return
    end
    local ok, err = pcall(guihooks.trigger, TAB_REBUILD_EVENT)
    if not ok then
        log("W", LOG_TAG, "pause-menu vehicle tab rebuild failed: " .. tostring(err))
        return
    end
    log("I", LOG_TAG, "pause-menu vehicle tab " .. (is_locked and "locked" or "unlocked")
        .. ": asked an open tab to rebuild (" .. TAB_REBUILD_EVENT .. ")")
end

-- Whether a mergeConfig payload changes more than tuning and paint. A whitelist on purpose: partsTree and
-- parts are the obvious keys, but a mainPartName or model would be another car altogether, and an unknown
-- key refused costs a notice where one let through costs the race its forced car. Anything that is not a
-- table goes to the original, which rejects it with its own warning.
local function carries_parts(config)
    if type(config) ~= "table" then
        return false
    end
    for key in pairs(config) do
        if not TUNING_KEYS[key] then
            return true
        end
    end
    return false
end

-- Whether `veh` is the vehicle the player sits in -- the car every other partmgmt entry acts on. A handle
-- whose id cannot be read is not provably the player's; it goes to the original, which fails on it exactly
-- as it always did.
local function is_player_vehicle(veh)
    local ok, is_player = pcall(function()
        return veh:getID() == be:getPlayerVehicleID(0)
    end)
    return ok and is_player == true
end

local function always()
    return true
end

-- Every core_vehicle_partmgmt entry that can change the player's parts (ADR-0064), in log order, each with
-- the question that decides whether THIS call does. The engine routes its own calls between these through
-- file locals, so wrapping the fields never reaches setConfigVars / setConfigPaints: tuning and paint stay
-- free without being named here. loadLocal and resetAllToLoadedConfig end in replaceVehicle, which the
-- forced-car lock refuses anyway; catching them here answers with the parts notice and the menu resync.
local PARTS_ENTRIES = {
    {name = "setPartsTreeConfig", changes_parts = always},
    {name = "setPartsConfig", changes_parts = always},
    {name = "loadLocal", changes_parts = always},
    {name = "resetAllToLoadedConfig", changes_parts = always},
    {name = "resetPartsToLoadedConfig", changes_parts = always},
    {name = "resetConfig", changes_parts = always},
    {name = "setConfig", changes_parts = carries_parts},
    {name = "setConfigOfVehicle", changes_parts = function(veh, config)
        return carries_parts(config) and is_player_vehicle(veh)
    end},
}

-- Hand the parts menu the car as it really is. Not cosmetic: on Apply the menu disables itself and waits
-- for VehicleConfigChange (Parts.vue write -> waitForData), so a refusal that only said no would leave it
-- greyed out for good. sendDataToUI pushes the car's real parts tree, and the menu rebuilds from it showing
-- the old part again.
local function resync_parts_menu(partmgmt)
    local ok, err = pcall(partmgmt.sendDataToUI)
    if not ok then
        log("W", LOG_TAG, "parts menu resync failed: " .. tostring(err))
    end
end

-- One refused parts change: a log line every time (a click, never a frame), the menu resync, and the
-- notice at most every SPAWN_BLOCK_TOAST_THROTTLE seconds. The resync goes first: it is the part the menu
-- cannot do without.
local function refuse_parts_change(partmgmt, name)
    log("I", LOG_TAG, "refused a parts change (" .. name .. "): "
        .. (PARTS_LOCK_WHY[parts_lock_reason] or "the parts are locked"))
    resync_parts_menu(partmgmt)
    local now = os.clock()
    if now - last_parts_block_notice_at >= SPAWN_BLOCK_TOAST_THROTTLE then
        last_parts_block_notice_at = now
        M.notify(PARTS_LOCKED_NOTICE, "warning")
    end
end

-- The wrapper for one PARTS_ENTRIES function. It refuses a call that changes parts -- or one it cannot
-- read, fail-closed -- and hands every other call to the original with all its arguments. Once the stash
-- is gone (the lock was removed) it is a plain pass-through, so a copy of it that somebody kept outlives
-- nothing.
local function parts_guard_for(partmgmt, entry, stash_key)
    local original = partmgmt[stash_key]
    return function(...)
        if partmgmt[stash_key] == nil then
            return original(...)
        end
        local ok, changes = pcall(entry.changes_parts, ...)
        if not ok then
            log("W", LOG_TAG, "could not read a " .. entry.name .. " call, refusing it: "
                .. tostring(changes))
        elseif not changes then
            return original(...)
        end
        local refused, err = pcall(refuse_parts_change, partmgmt, entry.name)
        if not refused then
            log("W", LOG_TAG, "parts change refused, but answering it failed: " .. tostring(err))
        end
        return nil
    end
end

-- Wrap every PARTS_ENTRIES function present on core_vehicle_partmgmt. Same shape as guard_core_vehicles:
-- the original is stashed once on the engine table, the wrapper is (re)assigned on every install, so a
-- second install never captures our own wrapper as the "original". Returns the wrapped and the missing
-- names, or nil when the module is not loaded at all.
--
-- The plain global is the right table: the UI's call string resolves extensions.core_vehicle_partmgmt,
-- and lua/common/extensions.lua registers that and _G.core_vehicle_partmgmt as the same module table, read
-- by name when the string runs -- so replacing the field is what catches the menu's Apply.
local function guard_partmgmt()
    local partmgmt = core_vehicle_partmgmt
    if type(partmgmt) ~= "table" then
        return nil
    end
    local wrapped, missing = {}, {}
    for _, entry in ipairs(PARTS_ENTRIES) do
        local stash_key = PARTS_ORIG_PREFIX .. entry.name
        if partmgmt[stash_key] == nil and type(partmgmt[entry.name]) == "function" then
            partmgmt[stash_key] = partmgmt[entry.name]
        end
        if partmgmt[stash_key] ~= nil then
            partmgmt[entry.name] = parts_guard_for(partmgmt, entry, stash_key)
            wrapped[#wrapped + 1] = entry.name
        else
            missing[#missing + 1] = entry.name
        end
    end
    return wrapped, missing
end

-- Put back every stashed partmgmt original. Returns how many were restored (0 when nothing was guarded).
local function unguard_partmgmt()
    local partmgmt = core_vehicle_partmgmt
    if type(partmgmt) ~= "table" then
        return 0
    end
    local restored = 0
    for _, entry in ipairs(PARTS_ENTRIES) do
        local stash_key = PARTS_ORIG_PREFIX .. entry.name
        if partmgmt[stash_key] ~= nil then
            partmgmt[entry.name] = partmgmt[stash_key]
            partmgmt[stash_key] = nil
            restored = restored + 1
        end
    end
    return restored
end

-- One line per guarded install naming what is wrapped and why ("forced car" / "vehicle limit"). A function
-- missing after a game update is the tripwire, so it is named at W; the count alone would read as success
-- with one route open.
local function report_parts_guard(wrapped, missing, reason)
    if wrapped == nil then
        log("W", LOG_TAG, "parts lock (" .. reason
            .. "): core_vehicle_partmgmt is not loaded, parts are NOT locked")
        return
    end
    local summary = string.format("parts lock (%s): wrapped %d of %d (%s)",
        reason, #wrapped, #PARTS_ENTRIES, table.concat(wrapped, ", "))
    if #missing == 0 then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; not found: " .. table.concat(missing, ", ")
            .. "; re-check the engine's core/vehicle/partmgmt.lua")
    end
end

-- The answer of an installed policy seam (M.car_is_forced / M.race_has_caps). A predicate that throws
-- reads as false -- the same answer as no predicate at all, i.e. the lock as it was before that seam -- and
-- says so.
local function ask_policy(predicate, what)
    local ok, answer = pcall(predicate)
    if not ok then
        log("W", LOG_TAG, "could not read " .. what .. ", parts stay unlocked: " .. tostring(answer))
        return false
    end
    return answer == true
end

-- Why this install locks the parts, or nil: a forced car locks them in every mode (ADR-0064), a vehicle limit
-- in the full lock only (ADR-0064 amendment 2026-11-04) -- the staging lock leaves them open there, and the
-- change is measured after its respawn instead.
local function parts_lock_reason_for(is_forced, allow_replace)
    if is_forced then
        return "forced car"
    end
    if not allow_replace and ask_policy(M.race_has_caps, "the race's vehicle limit") then
        return "vehicle limit"
    end
    return nil
end

-- Arm the lock: block the input actions, guard the spawn/replace functions, the selector's own car buttons
-- and the pause tab's entry, and hide the selector's management bar. Idempotent. With opts.allow_replace the
-- swap-allowed staging mode is installed (replace + the car selector stay open, extra spawn + everything else
-- blocked); with no opts (or false) the full fixed-car lock. Calling it again without allow_replace upgrades
-- a swap-allowed lock to full (ADR-0021/0017 amendments). The car buttons, the bar, the pause tab and the AI
-- modes are the same in both modes.
--
-- A race that forces the car (M.car_is_forced, ADR-0064) overrides allow_replace for the replace only:
-- the replace is refused from staging on, while the selector keys stay open -- the parts-selector key is
-- the way into the tuning menu, and the vehicle selector answers a pick with the vehicle notice. The parts
-- guard follows the same answer on every install, so it is armed or put back declaratively. A vehicle limit
-- (M.race_has_caps) arms the parts guard in the full lock and changes nothing else: the staging swap stays
-- open, because the limit measures the swapped car instead.
function M.install(opts)
    local allow_replace = opts ~= nil and opts.allow_replace == true
    local is_forced = ask_policy(M.car_is_forced, "the race's car policy")
    local reason = parts_lock_reason_for(is_forced, allow_replace)
    set_action_filter(true, allow_replace)
    guard_core_vehicles(allow_replace and not is_forced)
    report_vehicle_buttons(guard_vehicle_buttons())
    selector_bar.wanted = true
    report_selector_bar(hide_selector_bar(), "for the lock")
    pause_tab.wanted = true
    report_pause_tab("for the lock", guard_pause_tab())
    parts_lock_reason = reason
    if reason then
        local wrapped, missing = guard_partmgmt()
        report_parts_guard(wrapped, missing, reason)
    else
        unguard_partmgmt()
    end
    local mode = allow_replace and "swap-allowed" or "full"
    if is_forced then
        mode = (allow_replace and "staging" or "full") .. ", forced car"
    elseif reason then
        mode = mode .. ", " .. reason
    end
    log("I", LOG_TAG, "in-race vehicle-action lock installed (" .. mode .. ")")
end

-- Block or unblock the two recover keys for a qualifying hold (ADR-0017 amendment): while a driver waits in
-- the queue, sits staged at the ramp, or is done for the session, the hold must actually hold -- and a
-- frozen car satisfies the assists' stationary gate, so an unblocked recover key would happily free it.
-- A separate group from the race lock, so the in-run recover-requeue (ADR-0044) and the in-race assists
-- keep both keys in every state that is NOT held.
--
-- Deliberately unconditional (no internal "already applied" flag): a GE Lua reload resets this module's
-- state while the engine's filter state survives -- core/input/actionFilter.lua really does define
-- onSerialize/onDeserialized and carries its action groups over -- so an internal flag could desync and
-- strand the keys blocked.
--
-- The caller owns the change detection, in M.state.quali_hold_locked. That flag is NOT reload-surviving
-- either (an earlier version of this comment claimed it was): a reload rebuilds M.state from its literal.
-- What keeps the two sides in step is that the same reload runs init.lua's onExtensionUnloaded ->
-- teardown_race_world -> M.remove(), which releases this group before the flag resets, and that
-- onExtensionLoaded re-asserts the released state instead of trusting the fresh flag. Keep both ends: a
-- cache of an engine state that outlives the reload has to be re-established at load, never guessed.
function M.set_recover_blocked(blocked)
    set_hold_filter(blocked == true)
    log("I", LOG_TAG, "recover keys " .. (blocked and "blocked (quali hold)" or "released"))
end

-- Lift the lock: unblock the input actions and restore the spawn/replace functions, the car buttons, the
-- selector's bar, the pause tab's entry and the parts guard. Idempotent, so it is safe to call on lobby, on a
-- fresh race start, and on extension unload. Clears the hold group too -- without that, a race ending while a
-- driver is held would leave the recover keys dead in the finished free-roam window and the lobby.
function M.remove()
    set_action_filter(false)
    set_hold_filter(false)
    unguard_core_vehicles()
    unguard_vehicle_buttons()
    selector_bar.wanted = false
    selector_bar.outcome = nil
    if show_selector_bar() then
        log("I", LOG_TAG, "vehicle selector bar: given back")
    end
    pause_tab.wanted = false
    pause_tab.outcome = nil
    if unguard_pause_tab() then
        log("I", LOG_TAG, "pause-menu vehicle tab: given back")
    end
    if unguard_partmgmt() > 0 then
        log("I", LOG_TAG, "parts lock lifted")
    end
    parts_lock_reason = nil
    M.replace_seen = false
    log("I", LOG_TAG, "in-race vehicle-action lock removed")
end

-- The selector's half of M.step:
--   1. While the lock stands, hide the bar on a selector module the game loaded, or reloaded, after the
--      install. Install alone would only work when the module happened to be there first.
--   2. When the bar's state differs from what an open selector was last asked to draw, ask it to redraw.
--      Here and not in install/remove, so the quali re-grid's remove/install pair in one frame asks nothing.
local function step_selector_bar()
    if not selector_bar.wanted and not selector_bar.announced then
        return
    end
    if selector_bar.wanted and not is_selector_bar_hidden() then
        local reason = hide_selector_bar()
        if reason == nil or reason ~= selector_bar.outcome then
            report_selector_bar(reason, "(the selector module was loaded after the install)")
        end
    end
    local is_hidden = is_selector_bar_hidden()
    if is_hidden ~= selector_bar.announced then
        selector_bar.announced = is_hidden
        redraw_open_selector(is_hidden)
    end
end

-- The pause tab's half of M.step, the same two jobs:
--   1. While the lock stands, guard the entry on a provider the game loaded, or reloaded, after the install.
--   2. When the lock state differs from what an open tab was last asked to show, ask it to rebuild. The lock
--      state, not the guard: the buttons grey out on the action filter, which needs no provider.
local function step_pause_tab()
    if not pause_tab.wanted and not pause_tab.announced then
        return
    end
    if pause_tab.wanted and not is_tab_guarded() then
        local failure, unreadable = guard_pause_tab()
        if failure == nil or failure ~= pause_tab.outcome then
            report_pause_tab("(the provider was loaded after the install)", failure, unreadable)
        end
    end
    if pause_tab.wanted ~= pause_tab.announced then
        pause_tab.announced = pause_tab.wanted
        rebuild_open_tab(pause_tab.wanted)
    end
end

-- Once per frame from init.lua's onUpdate, in every phase: the selector's bar and the pause tab, four boolean
-- reads when there is no lock and nothing to tell.
function M.step()
    step_selector_bar()
    step_pause_tab()
end

-- Whether BeamNG's binding table can be read at all right now. core_input_bindings.bindings starts life
-- as an EMPTY list and is filled in that module's onFirstUpdate, so "not a single device" means "not
-- populated yet", never "this machine has no keyboard". The difference is load-bearing for the join hint:
-- reading the empty table as an answer would conclude that nothing is bound and say so out loud.
local function bindings_readable()
    local bindings = core_input_bindings and core_input_bindings.bindings
    return type(bindings) == "table" and #bindings > 0
end

-- Where `action` is bound. Returns TWO values: the control of its KEYBOARD binding (or nil), and the
-- devicetype of the first non-keyboard device carrying it (or nil). Reads BeamNG's own binding table
-- (core_input_bindings.bindings: one entry per device, each with contents.devicetype and
-- contents.bindings = {{action, control}, ...}; controls are normalized to lower case by the engine).
--
-- The split into two return values is what lets the panel's tooltips and the join hint share ONE reader
-- while the tooltips never see a foreign device: keyboard_control_for takes the first value only, so "the
-- panel sees keyboard bindings and nothing else" is a property of the code instead of a claim about its
-- callers. The engine's own core_input_bindings.getControlForAction serves neither -- it returns whichever
-- device it reaches first, so with a wheel attached it answers things like "button31": true, and
-- unreadable. `unused` marks a binding the engine has disabled for the seated vehicle, skipped on every
-- device.
--
-- Guarded like every other engine-version-coupled touchpoint in this file (ADR-0017): a renamed or
-- restructured binding table degrades to "no key known", never to an error.
local function binding_for(action)
    local bindings = core_input_bindings and core_input_bindings.bindings
    if type(bindings) ~= "table" then
        return nil, nil
    end
    local other_device = nil
    for _, device in ipairs(bindings) do
        local contents = type(device) == "table" and device.contents or nil
        if type(contents) == "table" and type(contents.bindings) == "table" then
            local is_keyboard = contents.devicetype == "keyboard"
            for _, binding in ipairs(contents.bindings) do
                if type(binding) == "table" and binding.action == action
                    and not binding.unused and binding.active ~= false
                    and type(binding.control) == "string" and binding.control ~= "" then
                    if is_keyboard then
                        return binding.control, nil
                    end
                    other_device = other_device or contents.devicetype or "unknown"
                    break
                end
            end
        end
    end
    return nil, other_device
end

-- The KEYBOARD control currently bound to `action`, or nil. Deliberately drops binding_for's second
-- return value: every caller of this one puts its answer in front of a player as a key he can press, and
-- a wheel's "button31" is worse there than naming no key at all (ADR-0049).
local function keyboard_control_for(action)
    local control = binding_for(action)
    return control
end

-- A BeamNG control as a person would write it: the engine stores bindings lower-cased and
-- space-separated ("insert", "ctrl insert"), which reads as a key on a keyboard once capitalised and
-- joined with "+". nil for anything unusable, and every caller must treat that as "name no key at all".
--
-- The Lua half of a pair -- BeamCompSetup/app.js keyLabel() is the JS half and has to stay in step with
-- this one. Two halves because the two surfaces are fed from different sides: the panel formats a control
-- the GE push handed it, this formats one before it leaves the client, so that the server never handles a
-- raw BeamNG control string and needs no formatting rule of its own.
local function key_label(control)
    if type(control) ~= "string" then
        return nil
    end
    local parts = {}
    for part in control:gmatch("%S+") do
        parts[#parts + 1] = part:sub(1, 1):upper() .. part:sub(2)
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "+")
end

-- How ONE assist is bound, as the join hint needs it: {state = "key", key = "Insert"} for a keyboard
-- binding, {state = "device"} for one that sits on a wheel/gamepad/mouse, {state = "none"} for an action
-- with no binding anywhere. nil when the control cannot be turned into a label -- the server then says
-- nothing at all about that assist, which is the safe direction.
--
-- Three states rather than two, and each assist is asked on its own: a driver can have Repair on the
-- keyboard and Recover on his wheel, and a single "everything is bound" branch would be wrong for him.
-- The device is never NAMED, only its absence from the keyboard: the engine's devicetype is a raw
-- "xinput"/"joystick"/"wheel" (bindings.lua getBindings), and it notes itself that some force-feedback
-- wheels report as "joystick" -- so a friendly device name would be a guess, while "another device" cannot
-- be wrong.
local function assist_state(action)
    local control, other_device = binding_for(action)
    if control then
        local label = key_label(control)
        if not label then
            return nil
        end
        return {state = "key", key = label}
    end
    if other_device then
        return {state = "device"}
    end
    return {state = "none"}
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

-- How this machine binds the two in-race assists, for the chat lines the server writes when a player joins
-- (ADR-0058). Returns {repair = <state>, recover = <state>} in the shape assist_state describes, or nil
-- when nothing can be said at all.
--
-- The mapping is INVERTED here exactly as it is in M.assist_controls, and for the same reason: BeamComp's
-- REPAIR sits on the game's plain `recover_vehicle`, BeamComp's RECOVER on `recover_vehicle_alt` (ADR-0017
-- decision 3; the crossing is implemented in the VE forwarder, lua/vehicle/extensions/beamcomp/init.lua
-- on_recover_down). Pairing `recover` with `recover_vehicle` because it reads more sensibly sends every
-- player on the server the WRONG key.
--
-- nil rather than two "nothing is bound" states while the binding table is unpopulated: this runs at
-- extension load, and reporting an unread table would tell a correctly bound player to go and bind his
-- keys. A wrong key is worse than no key, and so is a wrong "you have none".
function M.assist_key_report()
    if not bindings_readable() then
        log("W", LOG_TAG, "input bindings not readable yet; reporting no assist keys")
        return nil
    end
    local ok, report = pcall(function()
        return {
            repair = assist_state("recover_vehicle"),
            recover = assist_state("recover_vehicle_alt"),
        }
    end)
    if not ok then
        log("W", LOG_TAG, "could not read input bindings: " .. tostring(report))
        return nil
    end
    return report
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
