-- BeamComp dev tool -- live weight probe (bug caps-live-weight-differs-from-metadata).
--
-- NOT SHIPPED: it lives under scripts/dev/, which neither scripts/deploy.ps1 nor scripts/package.ps1
-- copies, and it is never loaded by the mod. A standalone GE extension for SINGLEPLAYER free roam. It
-- spawns stock presets one after another as the player's own car and records, per preset, what the
-- vehicle limit's live check reads (obj:calcBeamStats().total_weight and the peak engine power, the way
-- lua/vehicle/extensions/beamcomp/init.lua read_live_spec reads them) and what that weight is made of:
--   * the jbeam's static node mass (sum of v.data.nodes[*].nodeWeight),
--   * the fuel, N2O and air the energy storages put on their nodes (lua/vehicle/energyStorage/*.lua),
--   * the BeamNG 0.40 seat occupants: gameplay_seatOccupants seats the player as an 89 kg cargo container
--     that ramps in (maxVolumeRate 200 per second) after every spawn and every reset,
-- and next to it the preset's metadata ("Weight", "Performance Data".weight, "Power").
--
-- Per preset it samples a spawn series, a reset series (the race-start check measures 0.5 s after a reset,
-- race/capcheck.lua START_SETTLE), the car with its occupants switched off, and the car with its fuel taken
-- out. Results go to the user folder after every preset, so an aborted run keeps what it measured:
--   beamcomp_weightprobe.json  every sample
--   beamcomp_weightprobe.csv   one row per preset
-- plus one summary line per preset in beamng.log (tag beamcomp.weightprobe).
--
-- Install: copy the folder scripts/dev/beamcomp_weightprobe to
--   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamcomp_weightprobe
-- Run, sitting in any car in singleplayer free roam, in the GE Lua console:
--   extensions.load("beamcompdev_weightprobe") beamcompdev_weightprobe.run()
-- Options: run({presets = {"model:config", ...}}) or run({models = {"vivace"}}) for every config of a
-- model; stop() ends a run early and writes what it has.
--
-- Every engine touchpoint is probed (ADR-0017): a missing API writes a named reason into the result instead
-- of a guess. Target: client GE (LuaJIT 2.1). The VE half travels as a string (VE_SAMPLE_BODY) and runs in
-- the car's own VM, so nothing has to be installed on the vehicle side.

local M = {}

local LOG_TAG = "beamcomp.weightprobe"
local RESULT_JSON = "/beamcomp_weightprobe.json"
local RESULT_CSV = "/beamcomp_weightprobe.csv"
local TOOL_VERSION = 1

-- read_live_spec and dynamicVehicleData.lua round the weight up to this many kg.
local WEIGHT_ROUND_KG = 5

-- race/vehiclespecs.lua WEIGHT_FIELDS / POWER_FIELDS: the metadata keys the lists and the AI pick read.
local WEIGHT_FIELDS = {"Weight", "weight", "Weight (kg)"}
local POWER_FIELDS = {"Power", "power", "Power (KW)", "Power (hp)"}

-- Seconds of clamped sim time, like race/capcheck.lua (DT_CLAMP), so the reset series counts the 0.5 s the
-- race-start check waits exactly the way the check counts it: the spawn stall cannot eat the early samples.
local DT_CLAMP = 0.1
local SPAWN_TIMEOUT = 20.0
local ANSWER_TIMEOUT = 5.0

-- The presets measured by default, chosen from the headless analysis (analysis/summary.txt of the bug): the
-- reported car, both model groups ("Performance Data".weight - "Weight" = 0 + 11.8 per seat on the newer
-- models, 69 + 11.9 per seat on the older ones), electric controls, large fuel loads, the two outliers and
-- one vehicle with no engine, no tank and no seat.
M.DEFAULT_PRESETS = {
    "sunburst2:sport_RS_DCT",
    "sunburst2:track_attack",
    "wendover:se_v8_A",
    "atv:base",
    "vivace:vivace_S_310_DCT",
    "vivace:vivace_150d_DCT",
    "vivace:vivace_E",
    "sbr:electric_500",
    "covet:DX_M",
    "covet:race",
    "autobello:110_m",
    "etk800:844_150_A",
    "etk800:854_150d_A",
    "scintilla:gt",
    "citybus:base",
    "us_semi:t83s_dump",
    "cargotrailer:default",
}

-- One preset's script in seconds after its car was found loaded. `sample` is the label the VE reading
-- carries, `ge` an action on the car before the sample is asked for, `ve` an action the VE carries out
-- right before it measures.
local TIMELINE = {
    {at = 0.0, sample = "spawn_0.00"},
    {at = 0.25, sample = "spawn_0.25"},
    {at = 0.5, sample = "spawn_0.50"},
    {at = 1.0, sample = "spawn_1.00"},
    {at = 2.0, sample = "spawn_2.00"},
    {at = 4.0, sample = "spawn_4.00"},
    {at = 7.0, sample = "spawn_7.00"},
    {at = 7.5, ge = "reset", sample = "reset_0.00"},
    {at = 7.6, sample = "reset_0.10"},
    {at = 7.75, sample = "reset_0.25"},
    {at = 8.0, sample = "reset_0.50"},
    {at = 8.25, sample = "reset_0.75"},
    {at = 8.5, sample = "reset_1.00"},
    {at = 9.5, sample = "reset_2.00"},
    {at = 10.5, sample = "reset_3.00"},
    {at = 11.0, ge = "occupants_off", sample = "occupants_off_0.00"},
    {at = 11.5, sample = "occupants_off_0.50"},
    {at = 12.5, sample = "occupants_off_1.50"},
    {at = 13.5, sample = "occupants_off_2.50"},
    {at = 14.0, ge = "occupants_on", sample = "occupants_on_0.00"},
    {at = 15.5, sample = "occupants_on_1.50"},
    {at = 17.0, sample = "occupants_on_3.00"},
    {at = 17.5, ve = "fuel_off", sample = "fuel_off_0.00"},
    {at = 18.0, sample = "fuel_off_0.50"},
    {at = 19.0, sample = "fuel_off_1.50"},
    {at = 19.5, ve = "fuel_restore", sample = "fuel_restored_0.00"},
}

-- The samples the per-preset summary is built from.
local SETTLED = "spawn_7.00"
local FIRST = "spawn_0.00"
local AT_START_SETTLE = "reset_0.50"
local RESET_SETTLED = "reset_3.00"
local OCCUPANTS_OFF = "occupants_off_2.50"
local OCCUPANTS_BACK = "occupants_on_3.00"
local FUEL_OFF = "fuel_off_1.50"

-- The VE half. Prefixed with `local token, action = <n>, <"name"|nil>` and sent with queueLuaCommand; it
-- measures, answers GE through queueGameEngineLua with one JSON string, and leaves no global behind (the VE
-- warns on every new global, utils.lua detectGlobalWrites). The cargo module is read only when something
-- else already loaded it: `extensions.<name>` would load it, so it is looked up with rawget.
local VE_SAMPLE_BODY = [==[
local reading = {token = token, action = action, reasons = {}}

local function note(reason)
    reading.reasons[#reading.reasons + 1] = reason
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function guarded(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        note(name .. ": " .. tostring(err))
    end
end

local function storages()
    if type(energyStorage) ~= "table" or type(energyStorage.getStorages) ~= "function" then
        return nil
    end
    return energyStorage.getStorages() or {}
end

local function fuel_tanks()
    local tanks = {}
    for _, storage in pairs(storages() or {}) do
        if type(storage) == "table" and storage.type == "fuelTank" then
            tanks[#tanks + 1] = storage
        end
    end
    return tanks
end

local function count_entries(entries)
    local count = 0
    for _ in pairs(type(entries) == "table" and entries or {}) do
        count = count + 1
    end
    return count
end

-- What one storage puts on its nodes, the way its own updateGFX does: fuelTank and n2oTank add
-- storedEnergy * coefficient per node, pressureTank remainingMass * coefficient.
local function storage_node_mass(storage)
    local nodes, coefficient, amount
    if storage.type == "fuelTank" then
        nodes, coefficient, amount = storage.fuelNodes, storage.fuelNodeMassCoef, storage.storedEnergy
    elseif storage.type == "n2oTank" or storage.type == "pressureTank" then
        nodes, coefficient = storage.nodes, storage.nodeMassCoef
        amount = storage.type == "n2oTank" and storage.storedEnergy or storage.remainingMass
    elseif storage.type == "electricBattery" then
        return 0
    else
        return nil, "storage type '" .. tostring(storage.type) .. "' has no known node mass"
    end
    if not finite(coefficient) or not finite(amount) then
        return nil, "storage '" .. tostring(storage.name) .. "' has no readable node mass"
    end
    return amount * coefficient * count_entries(nodes)
end

if action == "fuel_off" then
    guarded("fuel_off", function()
        for _, tank in ipairs(fuel_tanks()) do
            if tank.beamcompProbeEnergy == nil then
                tank.beamcompProbeEnergy = tank.storedEnergy
            end
            tank.storedEnergy = 0
        end
    end)
elseif action == "fuel_restore" then
    guarded("fuel_restore", function()
        for _, tank in ipairs(fuel_tanks()) do
            if tank.beamcompProbeEnergy ~= nil then
                tank.storedEnergy = tank.beamcompProbeEnergy
                tank.beamcompProbeEnergy = nil
            end
        end
    end)
end

guarded("config", function()
    reading.vehicle_id = obj:getId()
    reading.pc_file = type(v.config) == "table" and v.config.partConfigFilename or nil
end)

guarded("calcBeamStats", function()
    local stats = obj:calcBeamStats()
    reading.stats = {}
    for key, value in pairs(stats) do
        if finite(value) then
            reading.stats[key] = value
        end
    end
    reading.total_weight = stats.total_weight
end)
if not finite(reading.total_weight) then
    note("calcBeamStats gave no total_weight")
end

guarded("jbeam nodes", function()
    local static, occupant, nodes, occupant_nodes = 0, 0, 0, 0
    for _, node in pairs(v.data.nodes) do
        if type(node) == "table" and finite(node.nodeWeight) then
            static = static + node.nodeWeight
            nodes = nodes + 1
            if type(node.cargoGroup) == "string" and node.cargoGroup:find("Occupant$") then
                occupant = occupant + node.nodeWeight
                occupant_nodes = occupant_nodes + 1
            end
        end
    end
    reading.static_mass = static
    reading.static_nodes = nodes
    reading.occupant_static_mass = occupant
    reading.occupant_nodes = occupant_nodes
end)

-- The physics masses node by node, if this game build has a per-node read. No reason entry when it has
-- none: the decomposition does not need it, it would only confirm total_weight from a second side.
local has_node_mass, node_mass_read = pcall(function() return obj.getNodeMass end)
if has_node_mass and type(node_mass_read) == "function" then
    guarded("getNodeMass", function()
        local physics, occupant = 0, 0
        for _, node in pairs(v.data.nodes) do
            if type(node) == "table" and node.cid ~= nil then
                local mass = obj:getNodeMass(node.cid)
                physics = physics + mass
                if type(node.cargoGroup) == "string" and node.cargoGroup:find("Occupant$") then
                    occupant = occupant + mass
                end
            end
        end
        reading.node_mass = physics
        reading.occupant_node_mass = occupant
    end)
else
    reading.node_mass_reason = "obj.getNodeMass unavailable"
end

guarded("energy storages", function()
    local all = storages()
    if not all then
        note("energyStorage.getStorages unavailable")
        return
    end
    reading.storages = {}
    reading.fuel_mass, reading.n2o_mass, reading.air_mass, reading.fuel_capacity_mass = 0, 0, 0, 0
    for name, storage in pairs(all) do
        if type(storage) == "table" then
            local mass, why = storage_node_mass(storage)
            if why then
                note(why)
            end
            -- The same tank full: what the nodes would carry at energyCapacity, whatever the fill level.
            local full_mass
            local coefficient = storage.fuelNodeMassCoef
            if storage.type == "fuelTank" and finite(storage.energyCapacity) and finite(coefficient) then
                full_mass = storage.energyCapacity * coefficient * count_entries(storage.fuelNodes)
                reading.fuel_capacity_mass = reading.fuel_capacity_mass + full_mass
            end
            local entry = {
                name = tostring(name),
                type = storage.type,
                energy_type = storage.energyType,
                stored_energy = storage.storedEnergy,
                energy_capacity = storage.energyCapacity,
                energy_density = storage.energyDensity,
                remaining_volume = storage.remainingVolume,
                remaining_mass = storage.remainingMass,
                mass_nodes = count_entries(storage.fuelNodes or storage.nodes),
                node_mass = mass,
                full_node_mass = full_mass,
            }
            local density = storage.energyDensity
            if finite(storage.storedEnergy) and finite(density) and density > 0 then
                entry.content_mass = storage.storedEnergy / density
            end
            reading.storages[#reading.storages + 1] = entry
            if finite(mass) then
                if storage.type == "fuelTank" then
                    reading.fuel_mass = reading.fuel_mass + mass
                elseif storage.type == "n2oTank" then
                    reading.n2o_mass = reading.n2o_mass + mass
                elseif storage.type == "pressureTank" then
                    reading.air_mass = reading.air_mass + mass
                end
            end
        end
    end
end)

guarded("cargo containers", function()
    local module = rawget(_G, "gameplayInterfaceModules_interactCargoContainers")
    if type(module) ~= "table" then
        reading.cargo_module = "not loaded"
        return
    end
    local lookup = type(module.moduleLookups) == "table" and module.moduleLookups.getCargoContainers or nil
    if type(lookup) ~= "function" then
        reading.cargo_module = "no getCargoContainers lookup"
        return
    end
    local result = lookup({})
    reading.cargo_module = "loaded"
    reading.cargo = {}
    local entries = type(result) == "table" and type(result[1]) == "table" and result[1] or {}
    for _, container in ipairs(entries) do
        reading.cargo[#reading.cargo + 1] = {
            name = tostring(container.name),
            group = container.groupId,
            capacity = container.capacity,
            current_volume = container.currentVolume,
            target_volume = container.targetVolume,
        }
    end
end)

-- Peak engine power exactly like read_live_spec: one engine's maxPower, several engines' final power curves
-- summed rpm by rpm. Floored, mechanical hp.
guarded("power", function()
    if type(powertrain) ~= "table" or type(powertrain.getDevicesByCategory) ~= "function" then
        note("powertrain.getDevicesByCategory unavailable")
        return
    end
    local engines = powertrain.getDevicesByCategory("engine") or {}
    reading.engines = #engines
    if #engines == 0 then
        return
    end
    local peak
    if #engines == 1 then
        peak = engines[1]:getTorqueData().maxPower
    else
        local curve = {}
        for _, engine in ipairs(engines) do
            local data = engine:getTorqueData()
            for rpm, power in pairs(data.curves[data.finalCurveName].power) do
                curve[rpm] = (curve[rpm] or 0) + power
            end
        end
        peak = -1
        for _, power in pairs(curve) do
            if power > peak then
                peak = power
            end
        end
    end
    if finite(peak) and peak > 0 then
        reading.power = math.floor(peak)
    else
        note("no positive power on the torque curve")
    end
end)

-- A reading that cannot be encoded travels as its failure text instead, never as hand-made JSON.
local encoded_ok, encoded = pcall(jsonEncode, reading)
local reading_literal, failure_literal = "nil", "nil"
if encoded_ok and type(encoded) == "string" then
    reading_literal = string.format("%q", encoded)
else
    failure_literal = string.format("%q", "jsonEncode failed: " .. tostring(encoded))
end
obj:queueGameEngineLua(string.format(
    "if beamcompdev_weightprobe then beamcompdev_weightprobe.on_sample(%d, %s, %s) end", token,
    reading_literal, failure_literal))
]==]

-- The run in progress, or nil. A dev tool's whole state; a GE Lua reload drops it (and the run with it).
local run = nil


local function to_number(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        local digits = value:match("([%d%.]+)")
        return digits and tonumber(digits) or nil
    end
    return nil
end

local function read_numeric(info, fields)
    if type(info) ~= "table" then
        return nil
    end
    for _, key in ipairs(fields) do
        local number = to_number(info[key])
        if number then
            return number
        end
    end
    return nil
end

local function ceil_to_round(weight)
    if type(weight) ~= "number" then
        return nil
    end
    return math.ceil(weight / WEIGHT_ROUND_KG) * WEIGHT_ROUND_KG
end

local function add_reason(result, reason)
    result.reasons[#result.reasons + 1] = reason
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(type(map) == "table" and map or {}) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return keys
end


-- "model:config" -> {model, config}, or nil for a malformed entry.
local function parse_preset(token)
    if type(token) ~= "string" then
        return nil
    end
    local model, config = token:match("^([^:]+):(.+)$")
    if not model then
        return nil
    end
    return {model = model, config = config}
end

local function get_model(model)
    if type(core_vehicles) ~= "table" or type(core_vehicles.getModel) ~= "function" then
        return nil, "core_vehicles.getModel unavailable"
    end
    local ok, data = pcall(core_vehicles.getModel, model)
    if not ok or type(data) ~= "table" or type(data.configs) ~= "table" then
        return nil, "unknown model '" .. tostring(model) .. "'"
    end
    return data
end

-- Every config key of `model`, sorted, as presets.
local function presets_of_model(model)
    local data = get_model(model)
    local presets = {}
    for _, config in ipairs(sorted_keys(data and data.configs)) do
        presets[#presets + 1] = {model = model, config = config}
    end
    return presets
end

local function build_presets(options)
    local presets = {}
    if type(options.models) == "table" then
        for _, model in ipairs(options.models) do
            for _, preset in ipairs(presets_of_model(model)) do
                presets[#presets + 1] = preset
            end
        end
        return presets
    end
    for _, token in ipairs(type(options.presets) == "table" and options.presets or M.DEFAULT_PRESETS) do
        local preset = parse_preset(token)
        if preset then
            presets[#presets + 1] = preset
        else
            log("W", LOG_TAG, "skipping malformed preset '" .. tostring(token) .. "' (want model:config)")
        end
    end
    return presets
end

-- The preset's metadata as the lists read it (core_vehicles.getModel ... configs[config], vehiclespecs
-- WEIGHT_FIELDS / POWER_FIELDS) plus the second weight the info file carries.
local function read_metadata(preset)
    local data, why = get_model(preset.model)
    if not data then
        return {reason = why}
    end
    local info = data.configs[preset.config]
    if type(info) ~= "table" then
        return {reason = "model '" .. preset.model .. "' ships no config '" .. preset.config .. "'"}
    end
    local performance = type(info["Performance Data"]) == "table" and info["Performance Data"] or {}
    return {
        model_type = type(data.model) == "table" and data.model.Type or nil,
        weight = read_numeric(info, WEIGHT_FIELDS),
        pd_weight = to_number(performance.weight),
        power = read_numeric(info, POWER_FIELDS),
        fuel_type = info["Fuel Type"],
        propulsion = info.Propulsion,
        pd_fuel_types = table.concat(sorted_keys(performance.fuelType), "|"),
    }
end

-- What the live check's log line compares against: the metadata core_vehicles.getVehicleDetails matches
-- to the spawned car (race/vehiclespecs.lua metadata_weight / metadata_power).
local function read_details(vehicle_id)
    if type(core_vehicles) ~= "table" or type(core_vehicles.getVehicleDetails) ~= "function" then
        return {reason = "core_vehicles.getVehicleDetails unavailable"}
    end
    local ok, details = pcall(core_vehicles.getVehicleDetails, vehicle_id)
    if not ok or type(details) ~= "table" then
        return {reason = "getVehicleDetails failed: " .. tostring(details)}
    end
    local current = type(details.current) == "table" and details.current or {}
    local info = details.configs or details.model
    return {
        config_key = current.config_key,
        pc_file = current.pc_file,
        weight = read_numeric(info, WEIGHT_FIELDS),
        power = read_numeric(info, POWER_FIELDS),
    }
end

local function seat_occupants()
    local module = rawget(_G, "gameplay_seatOccupants")
    return type(module) == "table" and module or nil
end

-- Who sits in the car right now, from gameplay_seatOccupants.getSeats.
local function read_seats(vehicle_id)
    local occupants = seat_occupants()
    if not occupants or type(occupants.getSeats) ~= "function" then
        return {reason = "gameplay_seatOccupants.getSeats unavailable"}
    end
    local ok, seats = pcall(occupants.getSeats, vehicle_id)
    if not ok or type(seats) ~= "table" then
        return {reason = "getSeats failed: " .. tostring(seats)}
    end
    local state = {seats = #seats, occupied = 0, weights = {}}
    for _, seat in ipairs(seats) do
        if seat.occupied then
            state.occupied = state.occupied + 1
            state.weights[#state.weights + 1] = seat.weight or -1
            if seat.isDriver then
                state.driver_weight = seat.weight
            end
        end
    end
    return state
end

local function player_vehicle()
    if be and type(be.getPlayerVehicle) == "function" then
        local ok, veh = pcall(be.getPlayerVehicle, be, 0)
        if ok then
            return veh
        end
    end
    if type(getPlayerVehicle) == "function" then
        return getPlayerVehicle(0)
    end
    return nil
end

local function vehicle_of(vehicle_id)
    if be and type(be.getObjectByID) == "function" then
        return be:getObjectByID(vehicle_id)
    end
    return nil
end

local function jbeam_of(veh)
    local ok, name = pcall(function() return veh:getJBeamFilename() end)
    return ok and name or nil
end

-- Spawn the preset as the player's car: replace the car he sits in (he stays seated, as in a race), or
-- spawn a new one when he has none.
local function spawn_preset(preset)
    if type(core_vehicles) ~= "table" then
        return false, "core_vehicles unavailable"
    end
    local options = {config = preset.config}
    local spawn = player_vehicle() and core_vehicles.replaceVehicle or core_vehicles.spawnNewVehicle
    if type(spawn) ~= "function" then
        return false, "core_vehicles.replaceVehicle / spawnNewVehicle unavailable"
    end
    local ok, err = pcall(spawn, preset.model, options)
    if not ok then
        return false, "spawn failed: " .. tostring(err)
    end
    return true
end

-- The race-start repair: setPositionRotation on the pose the car already has resets it in place.
local function reset_in_place(veh)
    local ok, err = pcall(function()
        local pos = veh:getPosition()
        local rot = quat(veh:getRotation())
        veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    end)
    return ok, err
end

local function set_occupants_enabled(vehicle_id, enabled)
    local occupants = seat_occupants()
    if not occupants or type(occupants.setVehicleOccupantsEnabledOverride) ~= "function" then
        return false, "gameplay_seatOccupants.setVehicleOccupantsEnabledOverride unavailable"
    end
    local ok, err = pcall(occupants.setVehicleOccupantsEnabledOverride, vehicle_id, enabled)
    return ok, err
end

-- Carry out a step's GE action on the car. Failures become reasons on the preset.
local function act_on_car(result, veh, action)
    local ok, err = true, nil
    if action == "reset" then
        ok, err = reset_in_place(veh)
    elseif action == "occupants_off" then
        ok, err = set_occupants_enabled(result.vehicle_id, false)
    elseif action == "occupants_on" then
        ok, err = set_occupants_enabled(result.vehicle_id, nil)
    end
    if not ok then
        add_reason(result, action .. ": " .. tostring(err))
    end
end

local function ve_command(token, action)
    local action_literal = action and string.format("%q", action) or "nil"
    return string.format("local token, action = %d, %s\n", token, action_literal) .. VE_SAMPLE_BODY
end

-- Ask the car's VE for one sample; the answer comes back through M.on_sample with the token.
local function request_sample(veh, step)
    local token = run.next_token
    run.next_token = token + 1
    run.pending[token] = {
        label = step.sample,
        result = run.result,
        sent_at = run.clock,
        seats = read_seats(run.result.vehicle_id),
    }
    local ok, err = pcall(function() veh:queueLuaCommand(ve_command(token, step.ve)) end)
    if not ok then
        run.pending[token] = nil
        add_reason(run.result, step.sample .. ": queueLuaCommand failed: " .. tostring(err))
    end
end


local function sample_by_label(result, label)
    for _, reading in ipairs(result.samples) do
        if reading.label == label then
            return reading
        end
    end
    return nil
end

local function total_of(result, label)
    local reading = sample_by_label(result, label)
    return reading and reading.total_weight or nil
end

local function difference(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then
        return nil
    end
    return a - b
end

local function sum_known(...)
    local total = 0
    for _, value in ipairs({...}) do
        if type(value) ~= "number" then
            return nil
        end
        total = total + value
    end
    return total
end

-- The per-preset row: the raw readings that decide the bug, and the two decompositions.
--   occupant_effect = settled - occupants switched off        (measured, not computed)
--   fuel_effect     = occupants back on - fuel taken out       (measured, not computed)
--   car_only        = settled - fuel - N2O - air - occupant_effect
--   car_full_tank   = car_only + the fuel the tanks hold when full (fill level taken out of the reading)
--   residual        = settled - static jbeam mass - fuel - N2O - air - occupant_effect  (0 = all explained)
function M.summarize(result)
    local settled = sample_by_label(result, SETTLED) or {}
    local meta = result.meta or {}
    local details = result.details or {}
    local seats = settled.seats_at_answer or {}
    local total = settled.total_weight
    local occupant_effect = difference(total, total_of(result, OCCUPANTS_OFF))
    local consumables = sum_known(settled.fuel_mass, settled.n2o_mass, settled.air_mass)
    local car_only = difference(difference(total, consumables), occupant_effect)
    local live_minus_fuel = difference(total, settled.fuel_mass)
    return {
        model = result.model,
        config = result.config,
        model_type = meta.model_type,
        fuel_type = meta.fuel_type,
        meta_weight = meta.weight,
        meta_pd_weight = meta.pd_weight,
        meta_power = meta.power,
        details_config = details.config_key,
        details_weight = details.weight,
        live_power = settled.power,
        engines = settled.engines,
        seats = seats.seats,
        seated = seats.occupied,
        driver_weight = seats.driver_weight,
        first_raw = total_of(result, FIRST),
        settled_raw = total,
        settled_rounded = ceil_to_round(total),
        start_settle_raw = total_of(result, AT_START_SETTLE),
        start_settle_rounded = ceil_to_round(total_of(result, AT_START_SETTLE)),
        reset_settled_raw = total_of(result, RESET_SETTLED),
        static_mass = settled.static_mass,
        occupant_static_mass = settled.occupant_static_mass,
        node_mass = settled.node_mass,
        fuel_mass = settled.fuel_mass,
        fuel_capacity_mass = settled.fuel_capacity_mass,
        n2o_mass = settled.n2o_mass,
        air_mass = settled.air_mass,
        occupant_effect = occupant_effect,
        fuel_effect = difference(total_of(result, OCCUPANTS_BACK), total_of(result, FUEL_OFF)),
        live_minus_fuel_raw = live_minus_fuel,
        live_minus_fuel_rounded = ceil_to_round(live_minus_fuel),
        car_only_raw = car_only,
        car_only_rounded = ceil_to_round(car_only),
        car_full_tank_raw = sum_known(car_only, settled.fuel_capacity_mass),
        residual = difference(car_only, settled.static_mass),
        samples = #result.samples,
        reasons = table.concat(result.reasons, "; "),
    }
end

local CSV_COLUMNS = {
    "model", "config", "model_type", "fuel_type", "meta_weight", "meta_pd_weight", "meta_power",
    "details_config", "details_weight", "live_power", "engines", "seats", "seated", "driver_weight",
    "first_raw", "settled_raw", "settled_rounded", "start_settle_raw", "start_settle_rounded",
    "reset_settled_raw", "static_mass", "occupant_static_mass", "node_mass", "fuel_mass",
    "fuel_capacity_mass", "n2o_mass", "air_mass", "occupant_effect", "fuel_effect", "live_minus_fuel_raw",
    "live_minus_fuel_rounded", "car_only_raw", "car_only_rounded", "car_full_tank_raw", "residual", "samples",
    "reasons",
}

local function csv_field(value)
    if value == nil then
        return ""
    end
    if type(value) == "number" then
        return value == math.floor(value) and string.format("%d", value) or string.format("%.3f", value)
    end
    local text = tostring(value)
    if text:find('[,"\n]') then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

function M.build_csv(rows)
    local lines = {table.concat(CSV_COLUMNS, ",")}
    for _, row in ipairs(rows) do
        local fields = {}
        for i, column in ipairs(CSV_COLUMNS) do
            fields[i] = csv_field(row[column])
        end
        lines[#lines + 1] = table.concat(fields, ",")
    end
    return table.concat(lines, "\n") .. "\n"
end

local function write_text(path, text)
    if type(writeFile) == "function" then
        local ok, written = pcall(writeFile, path, text)
        return ok and written == true
    end
    local file = io.open(path, "w")
    if not file then
        return false
    end
    file:write(text)
    file:close()
    return true
end

local function encode_json(document)
    local encode = type(jsonEncodePretty) == "function" and jsonEncodePretty or jsonEncode
    local ok, text = pcall(encode, document)
    return ok and text or nil
end

local function game_version()
    return rawget(_G, "beamng_versiond") or rawget(_G, "beamng_version")
end

local function write_results()
    local json = encode_json({
        tool = "beamcomp_weightprobe",
        version = TOOL_VERSION,
        game_version = game_version(),
        started = run.started,
        timeline = TIMELINE,
        rows = run.rows,
        presets = run.results,
    })
    local json_ok = json ~= nil and write_text(RESULT_JSON, json)
    local csv_ok = write_text(RESULT_CSV, M.build_csv(run.rows))
    if not json_ok or not csv_ok then
        log("E", LOG_TAG, string.format("could not write the results (json %s, csv %s)", tostring(json_ok),
            tostring(csv_ok)))
    end
end

local function format_kg(value)
    return type(value) == "number" and string.format("%.1f", value) or "?"
end

local function log_row(row, index, count)
    log("I", LOG_TAG, string.format(
        "%d/%d %s:%s live %s kg (start check %s) | Weight %s, PD %s | fuel %s, occupants %s, car only %s, "
            .. "residual %s | %s hp vs %s%s",
        index, count, row.model, row.config, format_kg(row.settled_raw), format_kg(row.start_settle_raw),
        format_kg(row.meta_weight), format_kg(row.meta_pd_weight), format_kg(row.fuel_mass),
        format_kg(row.occupant_effect), format_kg(row.car_only_raw), format_kg(row.residual),
        tostring(row.live_power), tostring(row.meta_power),
        row.reasons ~= "" and (" | " .. row.reasons) or ""))
end

local function user_path()
    local ok, path = pcall(function() return FS:getUserPath() end)
    return ok and path or "<user folder>"
end

local function new_result(preset)
    return {model = preset.model, config = preset.config, samples = {}, reasons = {}}
end

local function finish_run(why)
    log("I", LOG_TAG, string.format("run %s: %d of %d presets measured, results in %s%s and %s", why,
        #run.rows, #run.presets, user_path(), RESULT_JSON:sub(2), RESULT_CSV:sub(2)))
    run = nil
end

local start_preset

-- Drop the preset's unanswered requests and name them in one reason, earliest first.
local function drop_unanswered(result)
    local missing = {}
    for token, request in pairs(run.pending) do
        if request.result == result then
            run.pending[token] = nil
            missing[#missing + 1] = request
        end
    end
    if #missing == 0 then
        return
    end
    table.sort(missing, function(a, b) return a.sent_at < b.sent_at end)
    local labels = {}
    for i, request in ipairs(missing) do
        labels[i] = request.label
    end
    add_reason(result, string.format("%d of %d samples got no answer (%s)", #missing, #TIMELINE,
        table.concat(labels, ", ")))
end

local function finish_preset()
    local result = run.result
    drop_unanswered(result)
    table.sort(result.samples, function(a, b) return (a.sent_at or 0) < (b.sent_at or 0) end)
    local row = M.summarize(result)
    run.results[#run.results + 1] = result
    run.rows[#run.rows + 1] = row
    log_row(row, run.index, #run.presets)
    write_results()
    run.index = run.index + 1
    run.result = nil
    if run.stopping then
        finish_run("stopped")
    elseif run.index > #run.presets then
        finish_run("complete")
    else
        start_preset()
    end
end

-- Begin the next preset: read its metadata, spawn it, wait for its jbeam.
start_preset = function()
    local preset = run.presets[run.index]
    local result = new_result(preset)
    run.result = result
    run.seen_reasons = {}
    result.meta = read_metadata(preset)
    if result.meta.reason then
        add_reason(result, result.meta.reason)
        finish_preset()
        return
    end
    local ok, why = spawn_preset(preset)
    if not ok then
        add_reason(result, why)
        finish_preset()
        return
    end
    run.stage = "spawn_wait"
    run.clock = 0
    run.step = 1
end

-- Whether the car carries the preset's .pc. A non-string partConfig (an inline table) cannot say, and a
-- same-model replace is what makes the check necessary: the jbeam name alone would pass on the old car.
local function carries_config(veh, config)
    local ok, part_config = pcall(function() return veh.partConfig end)
    if not ok or type(part_config) ~= "string" then
        return true
    end
    return part_config:find("/" .. config .. ".pc", 1, true) ~= nil
end

local function loaded_car()
    local veh = player_vehicle()
    if veh and jbeam_of(veh) == run.result.model and carries_config(veh, run.result.config) then
        return veh
    end
    return nil
end

local function step_spawn_wait()
    local veh = loaded_car()
    if veh then
        local result = run.result
        result.vehicle_id = veh:getId()
        result.spawn_wait = run.clock
        result.details = read_details(result.vehicle_id)
        run.stage = "timeline"
        run.clock = 0
        return
    end
    if run.clock > SPAWN_TIMEOUT then
        add_reason(run.result, string.format("the car did not load within %.0f s", SPAWN_TIMEOUT))
        finish_preset()
    end
end

local function step_timeline()
    local veh = vehicle_of(run.result.vehicle_id)
    if not veh then
        add_reason(run.result, "the car disappeared during the timeline")
        finish_preset()
        return
    end
    while TIMELINE[run.step] and run.clock >= TIMELINE[run.step].at do
        local step = TIMELINE[run.step]
        if step.ge then
            act_on_car(run.result, veh, step.ge)
        end
        request_sample(veh, step)
        run.step = run.step + 1
    end
    if not TIMELINE[run.step] then
        run.stage = "answers"
        run.answers_since = run.clock
    end
end

local function has_pending_answers()
    for _, request in pairs(run.pending) do
        if request.result == run.result then
            return true
        end
    end
    return false
end

local function step_answers()
    if not has_pending_answers() or run.clock - run.answers_since > ANSWER_TIMEOUT then
        finish_preset()
    end
end

-- Start a run (see the file header for the options). Returns false when one is already running or nothing
-- is to be measured.
function M.run(options)
    if run then
        log("W", LOG_TAG, "a run is already in progress; beamcompdev_weightprobe.stop() ends it")
        return false
    end
    options = type(options) == "table" and options or {}
    local presets = build_presets(options)
    if #presets == 0 then
        log("W", LOG_TAG, "nothing to measure")
        return false
    end
    run = {
        presets = presets,
        index = 1,
        results = {},
        rows = {},
        pending = {},
        next_token = 1,
        clock = 0,
        started = os.date("%Y-%m-%d %H:%M:%S"),
    }
    log("I", LOG_TAG, string.format("measuring %d presets, about %d s each (game %s)", #presets,
        math.ceil(TIMELINE[#TIMELINE].at + 2), tostring(game_version())))
    start_preset()
    return true
end

-- End a run early; the preset in progress is written with what it has.
function M.stop()
    if not run then
        return false
    end
    run.stopping = true
    if run.result then
        add_reason(run.result, "run stopped")
        finish_preset()
    else
        finish_run("stopped")
    end
    return true
end

local function decode_reading(encoded, failure)
    if failure then
        return {reasons = {failure}}
    end
    local ok, reading = pcall(jsonDecode, encoded)
    if not ok or type(reading) ~= "table" then
        return {reasons = {"the answer was not decodable"}}
    end
    return reading
end

-- Lift a sample's reasons onto its preset, each text once, so a missing engine API shows in the CSV row and
-- the log line and not only inside the JSON.
local function lift_reasons(result, reading)
    for _, reason in ipairs(type(reading.reasons) == "table" and reading.reasons or {}) do
        if not run.seen_reasons[reason] then
            run.seen_reasons[reason] = true
            add_reason(result, reading.label .. ": " .. tostring(reason))
        end
    end
end

-- The VE's answer to request_sample (sent by VE_SAMPLE_BODY): the reading as JSON, or nil and why not.
function M.on_sample(token, encoded, failure)
    local request = run and run.pending[token]
    if not request then
        return
    end
    run.pending[token] = nil
    local reading = decode_reading(encoded, failure)
    reading.label = request.label
    reading.sent_at = request.sent_at
    reading.answered_at = run.clock
    reading.seats_at_send = request.seats
    reading.seats_at_answer = read_seats(request.result.vehicle_id)
    request.result.samples[#request.result.samples + 1] = reading
    lift_reasons(request.result, reading)
end

function M.onUpdate(_, dt_sim)
    if not run then
        return
    end
    run.clock = run.clock + math.min(dt_sim or 0, DT_CLAMP)
    if run.stage == "spawn_wait" then
        step_spawn_wait()
    elseif run.stage == "timeline" then
        step_timeline()
    elseif run.stage == "answers" then
        step_answers()
    end
end

function M.onExtensionUnloaded()
    run = nil
end

return M
