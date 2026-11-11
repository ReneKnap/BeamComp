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
-- And it measures the car for the vehicle limit (ADR-0032 amendments 2026-11-04 and 2026-11-08): GE asks for
-- the live power and weight with a token, we answer with the token. Power is computed the way the engine
-- computed the shipped metadata; the weight is the car with every fuel tank full and nobody on board, the
-- quantity the shipped "Weight" states for a stock preset. The metadata describes the preset a car was
-- spawned from, never the car after a parts or tuning change, so this is the only reading the limit can
-- trust. The pwr start order sorts by the same reading (ADR-0033 amendment 2026-11-11); GE routes each answer
-- to its consumer by the token.

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

local function count_entries(entries)
    local count = 0
    for _ in pairs(entries) do
        count = count + 1
    end
    return count
end

-- The jbeam's own node masses, summed: the car as built, every seat empty and every tank dry. A parts or
-- tuning change rebuilds the jbeam, so it counts here; what rides in the car (the fuel, the seated player,
-- cargo) is put on the nodes at run time with obj:setNodeMass and does not.
local function static_mass()
    local nodes = type(v) == "table" and type(v.data) == "table" and v.data.nodes or nil
    if type(nodes) ~= "table" then
        return nil, "v.data.nodes unavailable"
    end
    local total = 0
    for _, node in pairs(nodes) do
        if type(node) == "table" and is_finite(node.nodeWeight) then
            total = total + node.nodeWeight
        end
    end
    if total <= 0 then
        return nil, "the jbeam nodes carry no weight"
    end
    return total
end

-- The fuel on the tanks' nodes now and with every tank full, put there the way
-- lua/vehicle/energyStorage/fuelTank.lua does: energy * fuelNodeMassCoef on each fuel node. A tank without
-- fuel nodes carries no fuel mass, full or not. Other storages carry none on a stock car (no N2O bottle has
-- mass nodes, air tanks measured 0 kg) and are left out.
local function fuel_masses()
    if type(energyStorage) ~= "table" or type(energyStorage.getStorages) ~= "function" then
        return nil, nil, "energyStorage.getStorages unavailable"
    end
    local ok, storages = pcall(energyStorage.getStorages)
    if not ok or type(storages) ~= "table" then
        return nil, nil, "energyStorage.getStorages failed: " .. tostring(storages)
    end
    local now, full = 0, 0
    for name, storage in pairs(storages) do
        if type(storage) == "table" and storage.type == "fuelTank" then
            local coefficient, nodes = storage.fuelNodeMassCoef, storage.fuelNodes
            if not is_finite(coefficient) or type(nodes) ~= "table" or not is_finite(storage.storedEnergy)
                    or not is_finite(storage.energyCapacity) then
                return nil, nil, "fuel tank '" .. tostring(name) .. "' has no readable fuel mass"
            end
            local per_energy = coefficient * count_entries(nodes)
            now = now + storage.storedEnergy * per_energy
            full = full + storage.energyCapacity * per_energy
        end
    end
    return now, full
end

-- The vehicle limit's weight (ADR-0032 amendment 2026-11-08): the car with every fuel tank full and nobody on
-- board, so neither the fill level nor the seated player counts. Measured on 17 stock presets (BeamNG
-- 0.40.5): total_weight = static mass + fuel + 84 kg for the seated player, to 0.01 kg, and the shipped
-- "Weight" is static mass + a full tank rounded up to 5 kg. The static mass needs no settling time: the
-- seated player's mass is applied after every spawn and reset, the jbeam's node weights are there from the
-- start. The live total and the current fuel only go into the log line.
local function read_weight(reading)
    local ok, stats = pcall(function() return obj:calcBeamStats() end)
    if ok and type(stats) == "table" and is_finite(stats.total_weight) then
        reading.total = stats.total_weight
    end
    local static, static_why = static_mass()
    if not static then
        add_reason(reading, static_why)
        return
    end
    reading.static = static
    local fuel_now, fuel_full, fuel_why = fuel_masses()
    if not fuel_full then
        add_reason(reading, fuel_why)
        return
    end
    reading.fuel, reading.full_fuel = fuel_now, fuel_full
    reading.weight = static + fuel_full
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

-- The car's live engine power (hp) and weight (kg) as {power, weight, engines, reason} plus the weight's
-- parts for the log {total, static, fuel, full_fuel}. Power is exactly what
-- lua/vehicle/extensions/dynamicVehicleData.lua getVehiclePerformanceData computes, the function that
-- generated the shipped Power metadata: the peak of the final torque curve (turbo, supercharger and nitrous
-- applied, i.e. tuning included) floored, mechanical hp. The weight is unrounded, the car with a full tank
-- and nobody on board (read_weight). A value that cannot be read stays nil and `reason` names why
-- (ADR-0017: every touchpoint probed). getTorqueData subtracts friction scaled by damage, so a damaged car
-- reads lower; GE measures after a respawn or the race-start repair, where the car is fresh.
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
-- The weight's parts as a Lua table literal, the answer's last argument. Its presence is also what tells GE
-- that the weight is the car with a full tank: an older extension sends no parts and a different weight.
local function lua_weight_parts(reading)
    return string.format("{total = %s, static = %s, fuel = %s, full_fuel = %s}", lua_number(reading.total),
        lua_number(reading.static), lua_number(reading.fuel), lua_number(reading.full_fuel))
end

function M.measure_spec(token)
    local ok, reading = pcall(M.read_live_spec)
    if not ok then
        reading = {engines = 0, reason = "measurement failed: " .. tostring(reading)}
    end
    forward(string.format("on_live_spec(%s, %s, %s, %s, %s, %s, %s)",
        lua_number(obj:getId()), lua_number(token), lua_number(reading.power), lua_number(reading.weight),
        lua_number(reading.engines), lua_string(reading.reason), lua_weight_parts(reading)))
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
