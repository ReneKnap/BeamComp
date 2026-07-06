-- BeamComp -- live race HUD push (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/hud.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless: the GE extension (init.lua) builds a snapshot of the local player's race
-- state each racing frame and pushes it here; this module just fires the GE->UI hook.
--
-- The render surface is the draggable AngularJS app at ui/modules/apps/BeamCompHud/ (ADR-0012). The
-- contract is the hook name BeamCompHudUpdate: the app receives it via scope.$on(...). guihooks is
-- bootstrap-immune (ADR-0008 Finding 4), so this works for a server-delivered mod; GE streams are
-- not an option (guihooks.sendStreams breaks on GE), hence a per-frame trigger.

local M = {}

local LOG_TAG = "beamcomp.race"

-- The GE->UI contract: the AngularJS app subscribes with scope.$on(HOOK, ...) (ADR-0012).
local HOOK = "BeamCompHudUpdate"

-- The app's key in BeamNG's apps registry: ui_apps uses app.json's "directive" as appName when no
-- "appName" field is given, and the registry is keyed by appName (ui/modules/apps/app-service.js).
local APP_NAME = "beamCompHud"

-- Fire the UI hook defensively: a bad payload or missing surface must never break the caller
-- (the per-frame onUpdate push). Mirrors race/countdown.lua's trigger_ui.
local function trigger_ui(name, payload)
    if not guihooks then
        return
    end
    local ok, err = pcall(guihooks.trigger, name, payload)
    if not ok then
        log("W", LOG_TAG, "HUD UI trigger '" .. name .. "' failed: " .. tostring(err))
    end
end

-- Push one HUD snapshot to the app; the caller (init.lua build_hud_snapshot) builds it from the
-- local player's state. The module stays render-only, race-blind of the payload.
function M.push(snapshot)
    trigger_ui(HOOK, snapshot)
end

-- Blank the HUD (between races / reload): an inactive snapshot the app hides on. Idempotent.
function M.clear()
    M.push({active = false})
end

-- Show the HUD app for the race: ask the apps container to add it if it isn't already on the layout
-- (ensureAppVisible dedups by appName, so a manual copy isn't duplicated). Transient: spawns into
-- the live container; the saved layout is untouched (app-container.js / app-service.js, ADR-0012).
function M.show()
    trigger_ui("appContainer:ensureAppVisible", jsonEncode({appName = APP_NAME}))
end

-- Hide the HUD app after the race: remove it from the live container by appName, reverting to the
-- player's normal (multiplayer) HUD. Transient like show() -- the saved layout is untouched.
function M.hide()
    trigger_ui("appContainer:removeApp", APP_NAME)
end

-- Last-resort recovery for the self-healing watchdog (init.lua): force a full UI reload. During the
-- race-start spawn churn an engine/BeamMP UI reload can knock out the whole UI, and our server-delivered
-- app (mounted after the UI bootstrap, ADR-0008) does not come back on its own; re-showing alone may not
-- recover it, so the watchdog escalates here. Existence-guarded + pcall-wrapped like trigger_ui so a
-- missing engine function never breaks the caller (the onUpdate watchdog tick).
function M.reload_ui()
    if not reloadUI then
        return
    end
    local ok, err = pcall(reloadUI)
    if not ok then
        log("W", LOG_TAG, "UI reload failed: " .. tostring(err))
    end
end

-- Force the stock, vehicle-bound UI apps (dashboard / tacho) to re-bind to the active race car after the
-- race-start seat churn (bug default-dashboard-ui-missing-at-race-start). Root cause: under spawn-churn
-- lag the stock dashboard's implicit rebind -- which rides the be:enterVehicle vehicle-switch -- can land
-- before the new car's VE streams are up, or onto a transient car that is then removed, so the gauge ends
-- up bound to nothing and stays blank for the race. init.lua re-asserts the seat once the re-seated VE is
-- ready (which re-points the UI stream source); this is the companion escalation for the case where that
-- re-seat is a no-op because the seat was ALREADY active -- it replays the engine's own vehicle-focus
-- dispatch (extensions.hook 'onVehicleSwitched', lua/ge/main.lua) so every core handler, including the
-- vehicle-apps refresh, re-runs against the now-ready car. old_id = -1 ("from no vehicle") forces a fresh
-- bind rather than a no-change early-out. Existence-guarded + pcall-wrapped like reload_ui, so a renamed
-- engine API degrades to "no rebind" rather than crashing; extensions.hook pcall-isolates each extension
-- internally, so one bad handler cannot break this caller. Distinct from reload_ui: this never reloads the
-- whole UI, so it does not disturb the BeamComp HUD (ADR-0012 watchdog).
function M.rebind_vehicle_apps(new_id)
    if new_id == nil then
        return
    end
    if type(extensions) ~= "table" or type(extensions.hook) ~= "function" then
        return
    end
    local ok, err = pcall(extensions.hook, "onVehicleSwitched", -1, new_id, 0)
    if not ok then
        log("W", LOG_TAG, "stock vehicle-apps rebind failed: " .. tostring(err))
    end
end

return M
