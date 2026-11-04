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
--
-- And it measures the car for the vehicle limit (ADR-0032 amendment 2026-11-04): GE asks for the live
-- power and weight with a token, we compute them the way the engine computed the shipped metadata and
-- answer with the token. The metadata describes the preset a car was spawned from, never the car after a
-- parts or tuning change, so this is the only reading the limit can trust.

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

-- The shipped metadata rounds the curb weight UP to this many kg (dynamicVehicleData.lua weightRoundValue).
local WEIGHT_ROUND_KG = 5

local function is_finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function add_reason(reading, reason)
    reading.reason = reading.reason and (reading.reason .. "; " .. reason) or reason
end

-- One engine device's torque data, or nil plus why not. Called as a method like the engine does
-- (engines[1]:getTorqueData()), pcall-guarded: the powertrain is engine-version-coupled.
local function torque_data(engine)
    if type(engine) ~= "table" or type(engine.getTorqueData) ~= "function" then
        return nil, "engine device has no getTorqueData"
    end
    local ok, data = pcall(engine.getTorqueData, engine)
    if not ok then
        return nil, "getTorqueData failed: " .. tostring(data)
    end
    if type(data) ~= "table" then
        return nil, "getTorqueData returned no table"
    end
    return data
end

-- Peak power over several engines: their final power curves summed rpm by rpm, then the highest point.
-- That is how the engine rates a multi-engine car (getVehiclePerformanceData), not the sum of the peaks.
local function summed_peak_power(engines)
    local curve = {}
    for _, engine in ipairs(engines) do
        local data, err = torque_data(engine)
        if not data then
            return nil, err
        end
        local final = type(data.curves) == "table" and data.curves[data.finalCurveName] or nil
        if type(final) ~= "table" or type(final.power) ~= "table" then
            return nil, "an engine has no final power curve"
        end
        for rpm, power in pairs(final.power) do
            curve[rpm] = (curve[rpm] or 0) + power
        end
    end
    local peak = -1
    for _, power in pairs(curve) do
        if power > peak then
            peak = power
        end
    end
    return peak
end

local function read_weight(reading)
    local ok, stats = pcall(function() return obj:calcBeamStats() end)
    if not ok then
        add_reason(reading, "obj:calcBeamStats unavailable: " .. tostring(stats))
    elseif type(stats) ~= "table" or not is_finite(stats.total_weight) then
        add_reason(reading, "calcBeamStats gave no total_weight")
    else
        reading.weight = math.ceil(stats.total_weight / WEIGHT_ROUND_KG) * WEIGHT_ROUND_KG
    end
end

local function read_power(reading)
    if type(powertrain) ~= "table" or type(powertrain.getDevicesByCategory) ~= "function" then
        add_reason(reading, "powertrain.getDevicesByCategory unavailable")
        return
    end
    local ok, engines = pcall(powertrain.getDevicesByCategory, "engine")
    if not ok or type(engines) ~= "table" then
        add_reason(reading, "getDevicesByCategory failed: " .. tostring(engines))
        return
    end
    reading.engines = #engines
    if #engines == 0 then
        add_reason(reading, "no engine device")
        return
    end
    local peak, err
    if #engines == 1 then
        local data
        data, err = torque_data(engines[1])
        peak = data and data.maxPower
    else
        peak, err = summed_peak_power(engines)
    end
    if err then
        add_reason(reading, err)
    elseif is_finite(peak) and peak > 0 then
        reading.power = math.floor(peak)
    else
        add_reason(reading, "no positive power on the torque curve")
    end
end

-- The car's live engine power (hp) and curb weight (kg) as {power, weight, engines, reason}: exactly what
-- lua/vehicle/extensions/dynamicVehicleData.lua getVehiclePerformanceData computes, reduced to the two
-- numbers the vehicle limit compares -- and that function generated the shipped Power/Weight metadata, so
-- units and rounding match the caps: weight ceil(total_weight / 5) * 5, power the peak of the final
-- torque curve (turbo, supercharger and nitrous applied, i.e. tuning included) floored, mechanical hp.
-- A value that cannot be read stays nil and `reason` names why (ADR-0017: every touchpoint probed).
-- getTorqueData subtracts friction scaled by damage, so a damaged car reads lower; GE measures after a
-- respawn or the race-start repair, where the car is fresh.
function M.read_live_spec()
    local reading = {engines = 0}
    read_weight(reading)
    read_power(reading)
    return reading
end

local function lua_number(value)
    return is_finite(value) and string.format("%.17g", value) or "nil"
end

local function lua_string(value)
    return type(value) == "string" and string.format("%q", value) or "nil"
end

-- GE asks (vehicles.request_live_spec); answer with the token it handed us, so a late answer for a request
-- GE has given up on is recognised and dropped there. The read never throws into the VE runtime.
function M.measure_spec(token)
    local ok, reading = pcall(M.read_live_spec)
    if not ok then
        reading = {engines = 0, reason = "measurement failed: " .. tostring(reading)}
    end
    forward(string.format("on_live_spec(%s, %s, %s, %s, %s, %s)",
        lua_number(obj:getId()), lua_number(token), lua_number(reading.power), lua_number(reading.weight),
        lua_number(reading.engines), lua_string(reading.reason)))
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
