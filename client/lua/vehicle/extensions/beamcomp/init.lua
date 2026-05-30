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

local M = {}

-- Keys for stashing the genuine original recovery functions ON the recovery table (not in this
-- module), so a Lua reload of this extension never mistakes our own override for the original.
local ORIG_START_KEY = "beamcomp_orig_startRecovering"
local ORIG_STOP_KEY = "beamcomp_orig_stopRecovering"

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

-- Restore vanilla recovery if the extension is unloaded mid-race (hot reload), so the recover keys
-- never stay hijacked by a dead override.
function M.onExtensionUnloaded()
    disarm()
end

return M
