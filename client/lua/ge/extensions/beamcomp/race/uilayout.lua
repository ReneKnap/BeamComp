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
-- duplicated, a user-authored placement never disturbed, ADR-0012 par.3); remove takes every
-- instance of the name (also sweeps duplicates a crash may have left) and is a no-op when absent.
-- New with 0.39: an added entry lives in the user's current layout file between show and remove --
-- acceptable, and every close path sweeps the entry back out.
--
-- The pair is deliberately ASYMMETRIC (bug ui-glitches-after-ingame-menu-resize): ensure_visible adds
-- to the current layout only, remove sweeps EVERY layout on disk. "The current layout" is resolved
-- independently at each call and can change in between -- opening the radial menu switches it for as
-- long as the menu is up (core/quickAccess.lua show() -> setGameState(nil,'radial') -> GameStateUpdate
-- -> the Vue store's useLayout -> ui_appLayouts.setUsedLayout), and the HUD-apps layout browser
-- switches it on a preview. A show landing in one layout and the matching hide sweeping another leaves
-- the entry behind forever; that is how a beamCompHud entry ended up parked in the user's
-- radial.uilayout.json. Sweeping all layouts on the way out is the stateless fix -- a record of where
-- we added would go stale on a GE Lua reload and could not clean an entry that is already on disk.
-- The add is NOT widened to match: one direction closes the loop (a stray add is found by the next
-- remove), while a widened add would start deleting entries out of layouts the user is not even in.
--
-- Placement (round 2): 0.39 renders every layout-hosted app from its placement through a px
-- resolver (ui/ui-vue/src/modules/apps/placementResolve.js) that parses ONLY number/px/%/em/rem
-- values -- CSS functions (min/clamp/calc) and vw/vh yield null, the dimension collapses to 0 and
-- is clamped up to the app's min-width/min-height, a quarter-size box. The app.json css is NOT
-- applied to layout entries. ensure_visible therefore guarantees an explicit, parseable placement:
-- derived from the app's own app.json css (function expressions evaluated to px against a
-- 1920x1080 reference viewport -- the render-time clamp bounds it into the real frame, and a user
-- drag/resize rewrites it wholesale). An entry already on the layout gets its placement repaired
-- when it is missing (a stale round-1 add) or still carries css functions (the editor's own manual
-- add passes the css through verbatim); any other plain-value placement counts as user-authored and
-- is never touched (ADR-0012 par. 3).
--
-- What the editor actually writes (corrected 2026-09-08, bug ui-glitches-after-ingame-menu-resize --
-- this paragraph used to claim "pure px", which is false): placementResolve.js writes **em** for all
-- sizes and non-centre positions and "50%" for a centred axis (its own file header line 13;
-- rectPxToPlacement -> pxToEm / encodeAxis). The CLASSIFICATION is unaffected either way --
-- is_parseable_value accepts em, so such an entry reads as "custom" and we leave it alone -- only the
-- stated reason was wrong. Plain px in a layout file is still a supported LEGACY form: the overlay
-- detects it (usesOverlayUnitsOnly) and converts it at render time against a fixed 16 px base
-- (legacyPxToEm), which is why our px-derived placements render at their design size.
--
-- Consequence worth knowing but NOT ours to fix: the render-time clamp reads min-/max-width from the
-- CATALOGUE app, not from the layout entry -- readSizeConstraint(app, key, ...) with app = item.app,
-- whose lookup order is app[key] / app.placement[key] / app.css[key], and a catalogue entry has no
-- placement. So the clamp floor always comes from app.json css in px while the width it clamps came
-- through em, for every app in the game. The min-width/min-height derive_placement writes into the
-- entry are read by nothing at all (no consumer in ui/ui-vue/src/modules/apps/); they are kept
-- because they cost nothing and make an entry recognisably ours.
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

-- ===== placement derivation (round 2, see the header) ====================================

-- Reference viewport for evaluating vw/vh/%-of-viewport in css expressions. Oversize on smaller
-- screens is harmless: the 0.39 overlay clamps every rect into the real frame at render time.
local REF_VIEWPORT_W = 1920
local REF_VIEWPORT_H = 1080
local FONT_SIZE_PX = 16

-- Every placement key the px resolver reads, mapped to whether it measures the horizontal axis
-- (for %/viewport-relative evaluation).
local AXIS_BY_KEY = {
    left = true, right = true, width = true, ["min-width"] = true, ["max-width"] = true,
    top = false, bottom = false, height = false, ["min-height"] = false, ["max-height"] = false,
}

-- Whether a raw css value already survives 0.39's placement parser (number, or a plain
-- px/%/em/rem/bare-number string -- placementResolve.js parsePlacementValue).
local function is_parseable_value(raw)
    if type(raw) == "number" then
        return true
    end
    if type(raw) ~= "string" then
        return false
    end
    return raw:lower():match("^%s*-?%d*%.?%d+%s*(px)%s*$") ~= nil
        or raw:lower():match("^%s*-?%d*%.?%d+%s*(%%)%s*$") ~= nil
        or raw:lower():match("^%s*-?%d*%.?%d+%s*(r?em)%s*$") ~= nil
        or raw:match("^%s*-?%d*%.?%d+%s*$") ~= nil
end

local eval_css_length -- recursive: terms reference nested function expressions

-- One css length term to px: "660px" | "92vw" | "50%" | "1.5em" | bare number (= px).
local function term_to_px(term, axis_px)
    local number_str = term:match("^(-?%d*%.?%d+)")
    local value = number_str and tonumber(number_str)
    if not value then
        return nil
    end
    local unit = term:sub(#number_str + 1):lower():match("^%s*(.-)%s*$")
    if unit == "" or unit == "px" then
        return value
    end
    if unit == "vw" then
        return value * REF_VIEWPORT_W / 100
    end
    if unit == "vh" then
        return value * REF_VIEWPORT_H / 100
    end
    if unit == "%" then
        return value * axis_px / 100
    end
    if unit == "em" or unit == "rem" then
        return value * FONT_SIZE_PX
    end
    return nil
end

-- Split a function argument list at top-level commas (nested parentheses kept intact).
local function split_args(inner)
    local args = {}
    local depth = 0
    local start = 1
    for i = 1, #inner do
        local char = inner:sub(i, i)
        if char == "(" then
            depth = depth + 1
        elseif char == ")" then
            depth = depth - 1
        elseif char == "," and depth == 0 then
            args[#args + 1] = inner:sub(start, i - 1)
            start = i + 1
        end
    end
    args[#args + 1] = inner:sub(start)
    return args
end

-- Left-to-right top-level " + " / " - " arithmetic (css calc requires the spaces around the
-- operator, which disambiguates from negative numbers). * and / are unsupported -> nil.
local function eval_arith(expr, axis_px)
    local parts = {}
    local ops = {}
    local depth = 0
    local start = 1
    local i = 1
    while i <= #expr do
        local char = expr:sub(i, i)
        if char == "(" then
            depth = depth + 1
        elseif char == ")" then
            depth = depth - 1
        elseif depth == 0 and (char == "+" or char == "-")
            and expr:sub(i - 1, i - 1) == " " and expr:sub(i + 1, i + 1) == " " then
            parts[#parts + 1] = expr:sub(start, i - 2)
            ops[#ops + 1] = char
            start = i + 2
        end
        i = i + 1
    end
    parts[#parts + 1] = expr:sub(start)

    local total = eval_css_length(parts[1], axis_px)
    for k = 2, #parts do
        if total == nil then
            return nil
        end
        local value = eval_css_length(parts[k], axis_px)
        if value == nil then
            return nil
        end
        total = (ops[k - 1] == "+") and (total + value) or (total - value)
    end
    return total
end

-- A css length expression to px: nested min()/max()/clamp()/calc(), " + "/" - " arithmetic, and
-- the unit terms above. nil for anything else (the caller keeps the raw value).
eval_css_length = function(expr, axis_px)
    expr = expr:match("^%s*(.-)%s*$")
    local fname, inner = expr:match("^(%a+)%s*%((.*)%)$")
    if not fname then
        return term_to_px(expr, axis_px)
    end
    fname = fname:lower()
    if fname == "calc" then
        return eval_arith(inner, axis_px)
    end
    local values = {}
    for _, arg in ipairs(split_args(inner)) do
        local value = eval_arith(arg, axis_px)
        if value == nil then
            return nil
        end
        values[#values + 1] = value
    end
    if fname == "min" and #values > 0 then
        return math.min(unpack(values))
    end
    if fname == "max" and #values > 0 then
        return math.max(unpack(values))
    end
    if fname == "clamp" and #values == 3 then
        return math.max(values[1], math.min(values[2], values[3]))
    end
    return nil
end

-- Parser-compatible form of one css value: parseable values pass through verbatim, function
-- expressions are evaluated to whole px. nil when unresolvable.
local function normalize_css_value(raw, is_horizontal)
    if is_parseable_value(raw) then
        return raw
    end
    if type(raw) ~= "string" then
        return nil
    end
    local px = eval_css_length(raw, is_horizontal and REF_VIEWPORT_W or REF_VIEWPORT_H)
    if px == nil then
        return nil
    end
    return string.format("%dpx", math.floor(px + 0.5))
end

-- The app's own app.json css block -- the single geometry source, read at call time so mod-side
-- geometry updates keep flowing into fresh adds/repairs. Folder convention: appName
-- "beamCompSetup" -> /ui/modules/apps/BeamCompSetup/app.json (all BeamComp apps follow it).
local function read_app_css(app_name)
    local file = "/ui/modules/apps/" .. app_name:sub(1, 1):upper() .. app_name:sub(2) .. "/app.json"
    local app_json = jsonReadFile(file)
    if type(app_json) ~= "table" or type(app_json.css) ~= "table" then
        return nil, file
    end
    return app_json.css, file
end

-- Build the explicit placement for an add: the app.json css, normalized to values the 0.39 px
-- resolver understands. nil (add without placement, round-1 behavior) only when the css is
-- unreadable; an individual unresolvable value stays raw -- never worse than the css fallback.
local function derive_placement(app_name)
    local css, source = read_app_css(app_name)
    if not css then
        log("W", LOG_TAG, "no app.json css for '" .. app_name .. "' (" .. source
            .. "); adding without placement")
        return nil
    end
    local placement = {position = type(css.position) == "string" and css.position or "absolute"}
    for key, is_horizontal in pairs(AXIS_BY_KEY) do
        if css[key] ~= nil then
            local value = normalize_css_value(css[key], is_horizontal)
            if value == nil then
                log("W", LOG_TAG, "unresolvable css " .. key .. " for '" .. app_name .. "': "
                    .. tostring(css[key]))
                value = css[key]
            end
            placement[key] = value
        end
    end
    return placement
end

-- Classify an existing entry's placement:
--   "missing" -- absent/empty (a stale round-1 add)      -> repair with a derived placement
--   "legacy"  -- carries css-function values ("(")       -> repair by normalizing in place
--   "custom"  -- any other parseable form: em/50% from   -> never touched
--                a drag/resize, px from us or a legacy
--                layout (see the header)
local function placement_state(placement)
    if type(placement) ~= "table" or next(placement) == nil then
        return "missing"
    end
    for key in pairs(AXIS_BY_KEY) do
        local value = placement[key]
        if type(value) == "string" and value:find("(", 1, true) then
            return "legacy"
        end
    end
    return "custom"
end

-- Normalized copy of a legacy css-function placement: only the offending values are evaluated,
-- every other value stays byte-identical (it may be user-authored).
local function normalized_placement_copy(placement)
    local copy = {}
    for key, value in pairs(placement) do
        copy[key] = value
    end
    for key, is_horizontal in pairs(AXIS_BY_KEY) do
        local value = copy[key]
        if type(value) == "string" and value:find("(", 1, true) then
            copy[key] = normalize_css_value(value, is_horizontal) or value
        end
    end
    return copy
end

-- Repair the placement of the already-on-layout instances that need it (see placement_state);
-- returns whether anything was written. Never touches a "custom" placement.
local function repair_placements(api, layout, app_name, indices)
    if type(api.applyPlacementPatch) ~= "function" then
        return false
    end
    local patched = false
    for _, idx in ipairs(indices) do
        local entry = layout.apps[idx]
        local state = placement_state(entry.placement)
        local replacement = nil
        if state == "missing" then
            replacement = derive_placement(app_name)
        elseif state == "legacy" then
            replacement = normalized_placement_copy(entry.placement)
        end
        -- the patch API expects 0-based indices, like removeApp
        if replacement
            and api.applyPlacementPatch(layout.filename, idx - 1, replacement) == true then
            patched = true
            log("I", LOG_TAG, "repaired " .. state .. " placement of '" .. app_name
                .. "' in " .. tostring(layout.filename))
        end
    end
    return patched
end

-- ===== show / remove =====================================================================

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
    local indices = app_indices(layout, app_name)
    if #indices > 0 then
        -- Already on the layout (manual add or an earlier show): repair a missing/legacy
        -- placement so the panel renders full-size, leave a user-authored one untouched.
        if repair_placements(api, layout, app_name, indices) then
            notify_layouts_changed()
        end
        return true
    end
    if api.addApp(layout.filename, app_name, derive_placement(app_name)) ~= true then
        log("W", LOG_TAG, "addApp refused '" .. app_name .. "' for " .. tostring(layout.filename))
        return false
    end
    notify_layouts_changed()
    log("I", LOG_TAG, "added '" .. app_name .. "' to layout " .. tostring(layout.filename))
    return true
end

-- Every layout on disk that currently carries app_name. Writable ones only: a layout with no
-- filename cannot be addressed by the removeApp API.
local function layouts_carrying(api, app_name)
    local carrying = {}
    for _, layout in ipairs(api.getAvailableLayouts() or {}) do
        if type(layout.filename) == "string" and #app_indices(layout, app_name) > 0 then
            carrying[#carrying + 1] = layout
        end
    end
    return carrying
end

-- Take every instance of app_name out of ONE layout. Back-to-front, so the earlier positions stay
-- valid across the successive writes (each removeApp re-reads the file from disk). The API expects
-- 0-based indices, hence the -1. Returns whether anything was written.
local function remove_from_layout(api, layout, app_name)
    local removed = false
    local indices = app_indices(layout, app_name)
    for i = #indices, 1, -1 do
        if api.removeApp(layout.filename, indices[i] - 1) == true then
            removed = true
        end
    end
    return removed
end

-- The appContainer:removeApp replacement: take every instance of app_name out of EVERY layout on
-- disk, not just the current one (see the asymmetry note in the header). True when the app is (or
-- already was) gone. Layouts that do not carry the app are never written, so an original-only layout
-- -- which getAvailableLayouts reports under its not-yet-existing user path -- is not materialised.
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
    local carrying = layouts_carrying(api, app_name)
    if #carrying == 0 then
        return true
    end
    local cleaned = {}
    for _, layout in ipairs(carrying) do
        if remove_from_layout(api, layout, app_name) then
            cleaned[#cleaned + 1] = tostring(layout.filename)
        end
    end
    if #cleaned == 0 then
        log("W", LOG_TAG, "removeApp refused every instance of '" .. app_name .. "'")
        return false
    end
    notify_layouts_changed()
    log("I", LOG_TAG, "removed '" .. app_name .. "' from " .. #cleaned .. " layout(s): "
        .. table.concat(cleaned, ", "))
    return #cleaned == #carrying
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
