-- BeamComp -- BeamNG 0.39 UI-app layout compatibility (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/uilayout.lua inside the client mod zip. Target: client
-- GE (LuaJIT 5.1). BeamNG 0.39 made Vue the primary UI framework and rebuilt HUD-apps management;
-- the Angular appContainer guihooks (ensureAppVisible / removeApp) that every BeamComp show/close
-- path fired have NO listener any more, so each was a silent no-op (bug beamng-039-breakage). This
-- module is the single replacement seam: all programmatic app visibility goes through
-- ensure_visible / remove below. The data path is untouched -- BeamComp* guihooks and toastrMsg
-- still reach the hosted Angular apps (the 0.39 bridge broadcasts every hook to the Angular
-- rootScope AND the Vue event bus, ui/ui-vue/src/bridge/libs/StreamHooks.js).
--
-- How the 0.39 layout system works (verified against the local 0.39 install):
--   * The rendered HUD IS the current-layout document (a .uilayout.json under
--     /settings/ui_apps/layouts/). There is no transient container add any more: showing an app
--     means putting an entry into that document, closing means taking it out. Even the store's
--     legacy appContainer:spawn hook persists through the same ui_appLayouts.addApp, so a transient
--     path does not exist to prefer -- see 2-architecture.md for the full evaluation.
--   * ui_appLayouts.addApp/removeApp resolve the layout FRESH FROM DISK by filename and write the
--     file silently (no UI notification). The in-memory getCurrentLayout() copy goes stale against
--     those writes, so it is only trusted for the *filename*; dedup and index mapping run against
--     getAvailableLayouts() (a fresh file read, synchronous in this VM -- race-free against our own
--     watchdog re-shows, unlike the async spawn hook).
--   * The Vue store re-reads + re-renders on the UiAppLayoutsChanged guihook
--     (ui_apps.notifyLayoutsChanged), which is how a silent write becomes visible on screen.
--   * removeApp is INDEX-based and expects 0-based indices (JS convention: Lua-side does +1).
--
-- Semantics preserved from the old hooks: ensure_visible dedups by appName (a manual copy is never
-- duplicated, an existing placement never disturbed, ADR-0012 par.3); remove takes every instance
-- of the name (also sweeps duplicates a crash may have left) and is a no-op when absent. New with
-- 0.39: an added entry lives in the user's current layout file between show and remove --
-- acceptable, the add stores NO placement, so the app.json css keeps governing geometry, and every
-- close path sweeps the entry back out.
--
-- Defensive posture: both entry points are reached from onUpdate watchdog ticks, so every engine
-- call is pcall-wrapped (mirrors race/hud.lua's trigger_ui) -- a missing API or failed file write
-- logs and returns false, never breaks the caller's frame.

local M = {}

local LOG_TAG = "beamcomp.ui"

-- Resolve the 0.39 layout authority. `extensions` auto-loads an extension on first index access
-- (lua/common/extensions.lua MT.__index -> load), so this returns nil only on a build that
-- genuinely lacks ui_appLayouts (pre-0.39); the pcall also absorbs a throwing loader.
local function layout_api()
    if type(extensions) ~= "table" then
        return nil
    end
    local ok, api = pcall(function()
        return extensions.ui_appLayouts
    end)
    if not ok or type(api) ~= "table" or type(api.getAvailableLayouts) ~= "function" then
        return nil
    end
    return api
end

-- True while the user is inside the HUD-apps layout editor. The editor works on an unpersisted
-- draft (the Vue store skips the Lua write during an edit session), so a programmatic file write +
-- refresh in that window would clobber the draft or get lost on save -- callers skip and retry.
local function is_user_editing(api)
    return type(api.isEditing) == "function" and api.isEditing() == true
end

-- The current layout as freshly read from disk: filename from the (possibly stale) in-memory
-- current layout, content re-resolved via getAvailableLayouts. Returns the layout table, or
-- nil + reason. No current layout happens briefly after a UI boot, before the Vue store has
-- pushed the gamestate layout down to ui_appLayouts.
local function current_layout_from_disk(api)
    local current = type(api.getCurrentLayout) == "function" and api.getCurrentLayout() or nil
    local filename = type(current) == "table" and current.filename or nil
    if type(filename) ~= "string" or filename == "" then
        return nil, "no current layout selected yet"
    end
    for _, layout in ipairs(api.getAvailableLayouts() or {}) do
        if layout.filename == filename then
            return layout
        end
    end
    return nil, "current layout not on disk: " .. filename
end

-- All 1-based positions of app_name in the layout's app list (multiple when duplicated).
local function app_indices(layout, app_name)
    local indices = {}
    if type(layout.apps) == "table" then
        for i, app in ipairs(layout.apps) do
            if type(app) == "table" and app.appName == app_name then
                indices[#indices + 1] = i
            end
        end
    end
    return indices
end

-- addApp/removeApp write the layout file silently; this poke makes the Vue store re-read and
-- re-render. ui_apps.notifyLayoutsChanged is exactly that trigger (lua/ge/extensions/ui/apps.lua);
-- fall back to the raw guihook it wraps if ui_apps is somehow absent.
local function notify_layouts_changed()
    local ok, ui_apps = pcall(function()
        return extensions.ui_apps
    end)
    if ok and type(ui_apps) == "table" and type(ui_apps.notifyLayoutsChanged) == "function" then
        ui_apps.notifyLayoutsChanged()
        return
    end
    if guihooks then
        guihooks.trigger("UiAppLayoutsChanged")
    end
end

-- The appContainer:ensureAppVisible replacement: add app_name to the current layout unless it is
-- already there. True when the app is (now) on the layout.
local function do_ensure_visible(app_name)
    local api = layout_api()
    if not api then
        log("W", LOG_TAG, "cannot show '" .. app_name .. "': ui_appLayouts unavailable")
        return false
    end
    if is_user_editing(api) then
        log("I", LOG_TAG, "not adding '" .. app_name .. "': HUD layout editor is open")
        return false
    end
    local layout, reason = current_layout_from_disk(api)
    if not layout then
        log("W", LOG_TAG, "cannot show '" .. app_name .. "': " .. reason)
        return false
    end
    if #app_indices(layout, app_name) > 0 then
        -- Already on the layout (manual add or an earlier show): nothing to write, and the
        -- existing placement stays untouched.
        return true
    end
    -- nil placement on purpose: the renderer then falls back to the app.json css, so mod-side
    -- geometry updates keep applying instead of freezing in the user's layout file.
    if api.addApp(layout.filename, app_name, nil) ~= true then
        log("W", LOG_TAG, "addApp refused '" .. app_name .. "' for " .. tostring(layout.filename))
        return false
    end
    notify_layouts_changed()
    log("I", LOG_TAG, "added '" .. app_name .. "' to layout " .. tostring(layout.filename))
    return true
end

-- The appContainer:removeApp replacement: take every instance of app_name out of the current
-- layout. True when the app is (or already was) gone.
local function do_remove(app_name)
    local api = layout_api()
    if not api then
        log("W", LOG_TAG, "cannot remove '" .. app_name .. "': ui_appLayouts unavailable")
        return false
    end
    if is_user_editing(api) then
        log("I", LOG_TAG, "not removing '" .. app_name .. "': HUD layout editor is open")
        return false
    end
    local layout, reason = current_layout_from_disk(api)
    if not layout then
        log("W", LOG_TAG, "cannot remove '" .. app_name .. "': " .. reason)
        return false
    end
    local indices = app_indices(layout, app_name)
    if #indices == 0 then
        return true
    end
    -- Back-to-front, so the earlier positions stay valid across the successive writes (each
    -- removeApp re-reads the file). The API expects 0-based indices, hence the -1.
    local removed = false
    for i = #indices, 1, -1 do
        if api.removeApp(layout.filename, indices[i] - 1) == true then
            removed = true
        end
    end
    if removed then
        notify_layouts_changed()
        log("I", LOG_TAG, "removed '" .. app_name .. "' from layout " .. tostring(layout.filename))
    end
    return removed
end

-- Public, crash-proof entry points (see the defensive-posture note in the header).

function M.ensure_visible(app_name)
    if type(app_name) ~= "string" or app_name == "" then
        return false
    end
    local ok, shown = pcall(do_ensure_visible, app_name)
    if not ok then
        log("W", LOG_TAG, "ensure_visible('" .. app_name .. "') failed: " .. tostring(shown))
        return false
    end
    return shown == true
end

function M.remove(app_name)
    if type(app_name) ~= "string" or app_name == "" then
        return false
    end
    local ok, removed = pcall(do_remove, app_name)
    if not ok then
        log("W", LOG_TAG, "remove('" .. app_name .. "') failed: " .. tostring(removed))
        return false
    end
    return removed == true
end

return M
