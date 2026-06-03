-- BeamComp -- client VE (Vehicle-Engine) extension.
--
-- Lives at lua/vehicle/extensions/beamcomp/init.lua inside the client mod zip and loads under the
-- name `beamcomp_init` in the per-vehicle Lua VM. The VE VM owns per-vehicle physics, electrics, and
-- input -- a different VM from GE with no shared state. GE arms us via
-- veh:queueLuaCommand("beamcomp_init.<fn>()"); we forward to GE via obj:queueGameEngineLua(...).
--
-- Thin key forwarder for the opt-in in-race recover/repair assists (ADR-0017). Only the two
-- hold-capable recover keys are repurposed (they have both onDown and onUp, so GE can run a
-- hold-to-activate countdown that a release cancels):
--   recovery.startRecovering()      -- recover_vehicle      (Insert)      -> repair  (key down)
--   recovery.startRecovering(true)  -- recover_vehicle_alt  (Ctrl+Insert) -> recover (key down)
--   recovery.stopRecovering()       -- either key released  -> key up (cancels the countdown)
-- All the arming/countdown/stationary-gate/action logic lives GE-side; we only report down/up.
-- Originals are restored on disarm and on unload (hot-reload safe via sentinels on the recovery table).
--
-- Also owns the EV start-freeze hold (ADR-0017 amendment, countdown-lock-leaks Finding #3). The GE
-- freeze (controller.setFreeze) is a soft hold that an electric motor's instant 0-rpm torque can
-- creep through; combustion cars cannot (they have to rev up). So for EVs only, while the hold is
-- armed (staging + countdown), we clamp the throttle to 0 each frame. GE arms/disarms this over the
-- frozen phases (separate from the assist arm); combustion cars are left untouched so launch-revving
-- against the freeze still works.

local M = {}

-- Keys for stashing the genuine original recovery functions ON the recovery table (not in this
-- module), so a Lua reload of this extension never mistakes our own override for the original.
local ORIG_START_KEY = "beamcomp_orig_startRecovering"
local ORIG_STOP_KEY = "beamcomp_orig_stopRecovering"

-- EV start-freeze hold state. `freeze_hold` is whether GE has armed the clamp (the frozen phases);
-- `is_electric` is detected once per car (nil = not yet checked) and gates the clamp so only EVs are
-- held. Both reset on disarm/unload.
local freeze_hold = false
local is_electric = nil

-- Report an assist key event to GE, which owns the enable check, stationary gate, countdown, and
-- action. `call` is the GE entry point + args, e.g. "on_assist_key_down('recover')".
local function forward(call)
    obj:queueGameEngineLua("if beamcomp_init then beamcomp_init." .. call .. " end")
end

-- Key down: recover_vehicle (Insert) -> repair; recover_vehicle_alt (Ctrl+Insert) -> recover.
function M.on_recover_down(use_alt_mode)
    forward(use_alt_mode and "on_assist_key_down('recover')" or "on_assist_key_down('repair')")
end

-- Key up: cancel any in-progress hold (GE decides).
function M.on_recover_up()
    forward("on_assist_key_up()")
end

-- Install our forwarders, saving the genuine originals once (sentinel-guarded so a reload never
-- double-saves). Always re-points to this module's current functions so a reload rebinds cleanly.
local function arm()
    if type(recovery) ~= "table" then
        return
    end
    if recovery[ORIG_START_KEY] == nil and type(recovery.startRecovering) == "function" then
        recovery[ORIG_START_KEY] = recovery.startRecovering
    end
    if recovery[ORIG_STOP_KEY] == nil and type(recovery.stopRecovering) == "function" then
        recovery[ORIG_STOP_KEY] = recovery.stopRecovering
    end
    recovery.startRecovering = M.on_recover_down
    recovery.stopRecovering = M.on_recover_up
end

-- Restore the genuine recovery functions. No-op when not armed (originals absent).
local function disarm()
    if type(recovery) ~= "table" then
        return
    end
    if recovery[ORIG_START_KEY] ~= nil then
        recovery.startRecovering = recovery[ORIG_START_KEY]
        recovery[ORIG_START_KEY] = nil
    end
    if recovery[ORIG_STOP_KEY] ~= nil then
        recovery.stopRecovering = recovery[ORIG_STOP_KEY]
        recovery[ORIG_STOP_KEY] = nil
    end
end

-- GE arms the forwarders when the race starts and disarms them when it ends (ADR-0017).
function M.on_assist_arm()
    arm()
end

function M.on_assist_disarm()
    disarm()
end

-- Detect whether this car has an electric drivetrain, by scanning the powertrain for a device of type
-- "electricMotor". pcall-guarded: powertrain is engine-version-coupled, and a car still spawning may
-- not have it yet -- a miss returns false (no clamp) rather than erroring into the VE runtime. The
-- exact powertrain accessor (getDevices) is runtime-confirmed for BeamNG 0.38.5; verify in-game.
local function has_electric_motor()
    if type(powertrain) ~= "table" or type(powertrain.getDevices) ~= "function" then
        return false
    end
    local found = false
    local ok = pcall(function()
        for _, device in pairs(powertrain.getDevices()) do
            if type(device) == "table" and device.type == "electricMotor" then
                found = true
                return
            end
        end
    end)
    if not ok then
        return false
    end
    return found
end

-- GE arms the EV freeze hold over the frozen phases (staging + countdown). Detect the drivetrain once
-- (cached for the car's lifetime) so the per-frame clamp does no powertrain scan.
function M.on_freeze_hold_arm()
    if is_electric == nil then
        is_electric = has_electric_motor()
    end
    freeze_hold = true
end

-- GE disarms the hold on the racing transition (alongside the GE freeze release) and on teardown.
function M.on_freeze_hold_disarm()
    freeze_hold = false
end

-- Per-frame: while the hold is armed on an electric car, pin the throttle to 0 so instant motor torque
-- cannot creep through the soft GE freeze. No-op for combustion cars and when not armed. updateGFX is
-- the VE graphics-frame hook; whether it clamps fast enough versus a physics-step hook is to be
-- confirmed in-game (electrics.values.throttle is the lever either way).
function M.updateGFX(dt)
    if not freeze_hold or not is_electric then
        return
    end
    if type(electrics) == "table" and type(electrics.values) == "table" then
        electrics.values.throttle = 0
    end
end

-- Restore vanilla recovery and drop the freeze hold if the extension is unloaded mid-race (hot
-- reload), so the recover keys never stay hijacked and no throttle clamp survives on a dead override.
function M.onExtensionUnloaded()
    disarm()
    freeze_hold = false
    is_electric = nil
end

return M
