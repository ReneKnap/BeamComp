-- BeamComp -- time-windowed mute for BeamMP's vehicle-spawn notifications during a race start.
--
-- Lives at lua/ge/extensions/beamcomp/race/spawn_mute.lua inside the client mod zip. Target: client
-- GE (LuaJIT 5.1).
--
-- The host spawns the race's knockable cones as ~14 BeamMP-synced vehicles (ADR-0020). Each synced
-- spawn makes BeamMP show a top-left notification on every OTHER client -- "Spawn received and queued
-- for <host>" (MPVehicleGE.lua -> UI.showNotification, gated on the client's enableSpawnQueue setting).
-- With 14 cones that floods the notification list. Unlike the floating world nametag (suppressed
-- per-vehicle via hideNametag), these notifications carry no per-vehicle marker, so the only lever is
-- to mute UI.showNotification for the few seconds the cone-spawn burst lasts (finding #2b). Accepted
-- edge case: a real player spawning inside that window is muted too.
--
-- `UI` is a global GE extension shared with BeamMP, so wrapping UI.showNotification affects BeamMP's
-- calls. State is stashed ON the UI table (not module upvalues) so a BeamComp hot-reload re-uses the
-- saved original and shared deadline instead of double-wrapping (re-binding upvalues across a reload
-- is the documented trap). Restored on extension unload.

local M = {}

local ORIG_FIELD = "_beamcomp_orig_showNotification"
local UNTIL_FIELD = "_beamcomp_mute_until"

-- Whether the BeamMP UI module with a wrappable showNotification is present.
local function ui_available()
    return type(UI) == "table" and type(UI.showNotification) == "function"
end

-- Install the showNotification wrapper once, stashing the original + the (zeroed) deadline on the UI
-- table. Idempotent and reload-safe: if the wrapper is already in place (this or a prior load), the
-- saved original is left untouched. Returns true if a wrappable UI is present.
local function ensure_installed()
    if not ui_available() then
        return false
    end
    if UI[ORIG_FIELD] then
        return true
    end
    UI[ORIG_FIELD] = UI.showNotification
    UI[UNTIL_FIELD] = 0
    UI.showNotification = function(...)
        if os.clock() < (UI[UNTIL_FIELD] or 0) then
            return
        end
        return UI[ORIG_FIELD](...)
    end
    return true
end

-- Mute BeamMP's spawn notifications for the next `seconds` (the cone-spawn burst window). No-op when
-- no wrappable UI is present.
function M.mute_for(seconds)
    if not ensure_installed() then
        return
    end
    UI[UNTIL_FIELD] = os.clock() + seconds
end

-- Restore the original showNotification and clear the stashed state (extension unload).
function M.restore()
    if type(UI) == "table" and UI[ORIG_FIELD] then
        UI.showNotification = UI[ORIG_FIELD]
        UI[ORIG_FIELD] = nil
        UI[UNTIL_FIELD] = nil
    end
end

return M
