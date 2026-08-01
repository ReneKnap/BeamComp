-- BeamComp -- race countdown surface (GE side).
--
-- Renders the start countdown (8-2-1-GO!), the staging-wait indicator, and the recover/repair assist
-- hold countdown on BeamComp's own centered HUD overlay (ADR-0021), pushed GE->UI via the
-- BeamCompCountdown guihooks hook and drawn by the BeamCompHud app (ui/modules/apps/BeamCompHud,
-- ADR-0012). This replaces the built-in ScenarioFlashMessage surface used before (ADR-0008): that
-- surface depended on a base-game UI app a player might not have on their layout, so a player could see
-- no countdown at all (live-test Finding #5). The overlay rides the same app BeamComp force-shows for
-- the race HUD, so it needs no separate per-player setup beyond that one app.
--
-- The counts are ticked GE-side in init.lua onUpdate (like the grace and assist countdowns already
-- are) and pushed here a beat at a time; this module is a thin render + audio shim. guihooks is
-- bootstrap-immune (ADR-0008 Finding 4), so the push works for a server-delivered mod.

local M = {}

local LOG_TAG = "beamcomp.race"

-- The GE->UI contract: the BeamCompHud app subscribes with scope.$on(HOOK, ...) (ADR-0012/0021).
local HOOK = "BeamCompCountdown"

-- Per-number countdown beep events (base-game AudioGui). The sound index is intentionally reversed
-- from the number: "3" plays Countdown1, "2" Countdown2, "1" Countdown3. Numbers above 3 (the longer
-- 8 s count) get no beep -- only the final three and GO! do.
local BEAT_SOUNDS = {
    [3] = "event:UI_Countdown1",
    [2] = "event:UI_Countdown2",
    [1] = "event:UI_Countdown3",
}
local GO_SOUND = "event:UI_CountdownGo"

-- Seconds between repaints of the staging-wait line (ADR-0021 amendment). The payload is constant for
-- the whole wait, so this is not a refresh but a recovery: the wait is open-ended now, and the HUD app
-- mounts best-effort (ADR-0012 section 3), so a UI reload or a late add minutes into staging would
-- otherwise leave that player with no overlay for the rest of it. Matches the rate the old per-second
-- count effectively ran at. Lives here rather than as a top-level local in init.lua, which sits near
-- LuaJIT's 200-local ceiling.
M.STAGING_REPAINT_INTERVAL = 1.0


-- Fire a UI hook defensively: a malformed payload or a missing surface must never break the phase
-- handler / onUpdate tick that calls us. Mirrors race/hud.lua's trigger_ui.
local function trigger_ui(payload)
    if not guihooks then
        return
    end
    local ok, err = pcall(guihooks.trigger, HOOK, payload)
    if not ok then
        log("W", LOG_TAG, "countdown UI trigger failed: " .. tostring(err))
    end
end

-- Play a UI sound defensively (the cue the flash surface used to run via its soundCmd). A missing
-- audio API must never break the countdown.
local function play_audio(event)
    if not event or not Engine or not Engine.Audio then
        return
    end
    local ok, err = pcall(Engine.Audio.playOnce, "AudioGui", event)
    if not ok then
        log("W", LOG_TAG, "countdown audio '" .. event .. "' failed: " .. tostring(err))
    end
end


-- Show one start-count beat (the whole-second number n). Ticked from init.lua onUpdate.
function M.show_start(value)
    trigger_ui({active = true, kind = "start", value = value})
end

-- Show the F1 start light tower (ADR-0043) with `lit` of the red lights on (0..count). Ticked from
-- init.lua onUpdate during an F1 light-start countdown; the all-off "lights out = GO" rides the same
-- M.show_go on the racing transition, so no separate extinguish frame is needed. `hint` is an optional
-- short pre-start line ("hold until lights out") the app shows above the lights early in the sequence.
function M.show_lights(lit, hint)
    trigger_ui({active = true, kind = "lights", lit = lit, hint = hint})
end

-- Show GO! -- driven by the server `racing` phase, so it lands on the movement-lock release. The app
-- self-hides it after a beat (the racing phase sends no clear).
function M.show_go()
    trigger_ui({active = true, kind = "go"})
end

-- Show the recover/repair assist hold countdown, e.g. "Recover 5" (ADR-0017). Ticked from step_assist.
function M.show_assist(label, value)
    trigger_ui({active = true, kind = "assist", label = label, value = value})
end

-- Show the staging-wait indicator (ADR-0021 amendment): staging has no clock any more -- it waits for
-- the host -- so this carries no number, just the standing "waiting" line the app renders. `hint` is an
-- optional pre-procedure note (e.g. the F1 light-start heads-up, ADR-0043) shown underneath; nil for a
-- normal staging wait. Re-pushed from init.lua onUpdate every STAGING_REPAINT_INTERVAL.
function M.show_staging(hint)
    trigger_ui({active = true, kind = "staging", hint = hint})
end

-- Hide the overlay (race end / reload / count finished). Idempotent.
function M.clear()
    trigger_ui({active = false})
end

-- Play the per-number beep for the final 3-2-1 beats (no-op for the silent 8..4 beats).
function M.play_beat(value)
    play_audio(BEAT_SOUNDS[value])
end

-- Play the GO! cue, coincident with M.show_go on the racing transition.
function M.play_go()
    play_audio(GO_SOUND)
end

return M
