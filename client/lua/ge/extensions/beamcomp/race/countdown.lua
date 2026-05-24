-- BeamComp -- race start countdown (GE side).
--
-- Renders the synchronized 3-2-1-GO! start countdown on BeamNG's built-in centered flash-message
-- surface (the same one the base game's race countdowns use; scenarios.lua:1584-1597). Driven from
-- the client GE handler (init.lua handle_race_phase) off the server-authoritative race phases
-- (ADR-0006): the `countdown` phase (carrying a `duration`) starts the count, the `racing` phase
-- shows GO! (coincident with the movement-lock release), and `lobby`/reload clears it.
--
-- A custom, colorable BeamComp countdown overlay is deferred to the Phase-4 HUD (ADR-0008): a
-- server-delivered mod mounts after BeamNG's one-time UI-module bootstrap, so a custom UI module
-- never loads. The built-in flash surface is the reliable choice and needs no per-player setup.

local M = {}

local LOG_TAG = "beamcomp.race"

-- Built-in centered flash-message surface (base-game race countdown; scenarios.lua:1584-1597).
local FLASH_HOOK = "ScenarioFlashMessage"
local FLASH_RESET_HOOK = "ScenarioFlashMessageReset"

local DEFAULT_COUNTDOWN_SECONDS = 3
local GO_MESSAGE = "GO!"

-- Per-number countdown beep events (base-game AudioGui). The sound index is intentionally
-- reversed from the number: "3" plays Countdown1, "2" Countdown2, "1" Countdown3. Numbers
-- above 3 (longer countdowns) get no beep -- only the final three and GO! do.
local BEAT_SOUNDS = {
    [3] = "event:UI_Countdown1",
    [2] = "event:UI_Countdown2",
    [1] = "event:UI_Countdown3",
}
local GO_SOUND = "event:UI_CountdownGo"


local function play_sound_cmd(event)
    if not event then
        return ""
    end
    return "Engine.Audio.playOnce('AudioGui', '" .. event .. "')"
end

-- Fire a UI hook defensively: a malformed payload or a missing surface must never break the
-- phase handler that calls us.
local function trigger_ui(name, payload)
    if not guihooks then
        return
    end
    local ok, err = pcall(guihooks.trigger, name, payload)
    if not ok then
        log("W", LOG_TAG, "countdown UI trigger '" .. name .. "' failed: " .. tostring(err))
    end
end

-- Round the server-issued duration to whole seconds, clamped to at least one; fall back to the
-- default if the payload is missing or invalid.
local function resolve_seconds(duration)
    if type(duration) ~= "number" or duration <= 0 then
        return DEFAULT_COUNTDOWN_SECONDS
    end
    return math.max(1, math.floor(duration + 0.5))
end

-- Build the flash-message beat list the UI auto-sequences: one {message, seconds, sound, big}
-- tuple per second, counting down from `seconds` to 1.
local function build_beats(seconds)
    local beats = {}
    for n = seconds, 1, -1 do
        beats[#beats + 1] = {n, 1, play_sound_cmd(BEAT_SOUNDS[n]), true}
    end
    return beats
end

local function flash(message_list)
    trigger_ui(FLASH_RESET_HOOK)
    trigger_ui(FLASH_HOOK, message_list)
end


-- Start the synced 3-2-1 count off the server-issued duration.
function M.show_countdown(duration)
    flash(build_beats(resolve_seconds(duration)))
end

-- Show GO! -- driven by the server `racing` phase, so it lands on the movement-lock release.
function M.show_go()
    flash({{GO_MESSAGE, 1, play_sound_cmd(GO_SOUND), true}})
end

-- Clear any countdown message (race end / reload). Idempotent.
function M.clear()
    trigger_ui(FLASH_RESET_HOOK)
end

return M
