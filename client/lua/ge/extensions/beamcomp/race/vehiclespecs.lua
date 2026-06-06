-- BeamComp -- GE-side vehicle/config enumeration + power/weight reads (ADR-0032).
--
-- Lives at lua/ge/extensions/beamcomp/race/vehiclespecs.lua inside the client mod zip. Stateless apart
-- from a one-shot field-probe flag. Target: client GE (LuaJIT 5.1).
--
-- The server is vehicle-blind (ADR-0005), so all vehicle knowledge lives here: which models/configs are
-- installed, each config's engine power (hp) and curb weight (kg, for the power-to-weight cap), and the
-- search for a config that satisfies a Mode-3 power / power-to-weight cap. Shared by carlist (the /cars
-- listing) and the race-start policy (race/vehicles.lua).
--
-- POWER-READ RISK (the load-bearing assumption of ADR-0032): per-config power is read from BeamNG's
-- vehicle metadata WITHOUT spawning the candidate. The exact field name and whether it is populated
-- pre-spawn are unverified under BeamMP -- the same getVehicleDetails-family API works for the records
-- `type` field, but power may only be computed for a spawned vehicle. Every read is pcall-guarded and
-- degrades to nil (a nil power = "cannot verify" = treated as non-compliant by the caller), and
-- `probe_config_fields` logs one config's available keys on first use so the real field names can be
-- confirmed in-game. If per-config power proves unreadable, only the Mode-3 substitute search degrades;
-- Modes 1 and 2 do not touch this module.

local M = {}

local LOG_TAG = "beamcomp.vehiclespecs"

-- Candidate metadata keys for engine power (hp) and curb weight (kg), tried in order. Kept as lists
-- because the populated key is unverified under BeamMP (see the POWER-READ RISK note); the probe log
-- narrows them in-game.
local POWER_FIELDS = {"Power", "power", "Power (KW)", "Power (hp)"}
local WEIGHT_FIELDS = {"Weight", "weight", "Weight (kg)"}

-- The walking unicycle is never a race car (mirrors race/vehicles.lua); kept out of every listing/search.
local EXCLUDED_MODELS = {unicycle = true}

-- One-shot: log the keys of the first config-info table we read, so the real power/index field names are
-- visible in-game (the single runtime-verification point for this module). Module-scope, reset on reload.
local probed = false

-- Pull the first parseable number out of a value that may be a number or a string like "150 hp" /
-- "110 kW / 150 hp". Returns a number or nil.
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

-- Read the first present+numeric field from an info table across candidate keys. Returns a number or nil.
local function read_numeric(info, fields)
    if type(info) ~= "table" then
        return nil
    end
    for _, key in ipairs(fields) do
        local value = info[key]
        if value ~= nil then
            local number = to_number(value)
            if number then
                return number
            end
        end
    end
    return nil
end

-- Log one config-info table's keys the first time we touch metadata, so the populated power/index field
-- can be confirmed in-game without guessing. No-op after the first call (per module load).
local function probe_config_fields(info)
    if probed or type(info) ~= "table" then
        return
    end
    probed = true
    local keys = {}
    for key in pairs(info) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    log("I", LOG_TAG, "config-info fields: " .. table.concat(keys, ", "))
end

-- The BeamNG model table for `model` ({model = info, configs = {key = info}, ...}), or nil. pcall-guarded:
-- core_vehicles is a GE global, unverified under BeamMP (degrade to nil rather than error).
local function get_model(model)
    if type(model) ~= "string" or type(core_vehicles) ~= "table"
            or type(core_vehicles.getModel) ~= "function" then
        return nil
    end
    local ok, data = pcall(core_vehicles.getModel, model)
    if not ok or type(data) ~= "table" then
        return nil
    end
    return data
end

-- Sorted array of installed vehicle model keys (excluding the unicycle), or an empty table when the
-- model list is unavailable. Source for /cars and the cross-model substitute search.
function M.list_models()
    local models = {}
    if type(core_vehicles) ~= "table" or type(core_vehicles.getModelList) ~= "function" then
        return models
    end
    local ok, list = pcall(core_vehicles.getModelList)
    if not ok or type(list) ~= "table" then
        return models
    end
    local by_key = list.models or list
    if type(by_key) ~= "table" then
        return models
    end
    for key in pairs(by_key) do
        if type(key) == "string" and not EXCLUDED_MODELS[key] then
            models[#models + 1] = key
        end
    end
    table.sort(models)
    return models
end

-- Sorted array of one model's configs: {config = key, name = label, power = n|nil, weight = n|nil}. Empty
-- when the model is unknown or has no configs. `name` is the human label when present, else the key.
function M.list_configs(model)
    local configs = {}
    local data = get_model(model)
    if not data or type(data.configs) ~= "table" then
        return configs
    end
    for key, info in pairs(data.configs) do
        if type(key) == "string" then
            probe_config_fields(info)
            local label = (type(info) == "table" and (info.Configuration or info.Name)) or key
            configs[#configs + 1] = {
                config = key,
                name = label,
                power = read_numeric(info, POWER_FIELDS),
                weight = read_numeric(info, WEIGHT_FIELDS),
            }
        end
    end
    table.sort(configs, function(a, b) return a.config < b.config end)
    return configs
end

-- Engine power (hp) of one config from metadata, without spawning. Number or nil (unreadable). Used by
-- the substitute search; a nil result makes a candidate non-compliant (cannot verify => excluded).
function M.config_power(model, config)
    local data = get_model(model)
    if not data or type(data.configs) ~= "table" then
        return nil
    end
    local info = data.configs[config]
    probe_config_fields(info)
    return read_numeric(info, POWER_FIELDS)
end

-- Curb weight (kg) of one config from metadata, or nil. With config_power it yields the power-to-weight
-- ratio used by the Mode-3 maxpwr cap.
function M.config_weight(model, config)
    local data = get_model(model)
    if not data or type(data.configs) ~= "table" then
        return nil
    end
    return read_numeric(data.configs[config], WEIGHT_FIELDS)
end

-- Engine power (hp) of a SPAWNED vehicle, read from its live details -- the reliable source for the
-- player's own car's compliance check (computed for a real vehicle, unlike static config metadata).
-- Number or nil. pcall-guarded; mirrors vehicles.collect_client_info's getVehicleDetails read.
function M.vehicle_power(veh)
    if not veh then
        return nil
    end
    local ok, power = pcall(function()
        if type(core_vehicles) ~= "table" or type(core_vehicles.getVehicleDetails) ~= "function" then
            return nil
        end
        local details = core_vehicles.getVehicleDetails(veh:getId())
        local info = details and (details.configs or details.model)
        return read_numeric(info, POWER_FIELDS)
    end)
    if not ok then
        return nil
    end
    return power
end

-- Curb weight (kg) of a SPAWNED vehicle from its live details -- the reliable source for the own car's
-- power-to-weight check. Number or nil. pcall-guarded; mirrors vehicle_power.
function M.vehicle_weight(veh)
    if not veh then
        return nil
    end
    local ok, weight = pcall(function()
        if type(core_vehicles) ~= "table" or type(core_vehicles.getVehicleDetails) ~= "function" then
            return nil
        end
        local details = core_vehicles.getVehicleDetails(veh:getId())
        local info = details and (details.configs or details.model)
        return read_numeric(info, WEIGHT_FIELDS)
    end)
    if not ok then
        return nil
    end
    return weight
end

-- True when (power, weight) satisfy the caps. A nil cap is "no limit on this axis"; a set cap whose
-- input is unreadable is NOT satisfied (cannot verify => non-compliant, per ADR-0032). max_pwr compares
-- the power-to-weight ratio power/weight (hp per kg). Both caps nil => not Mode 3.
function M.is_compliant(power, weight, max_power, max_pwr)
    if max_power ~= nil and not (type(power) == "number" and power <= max_power) then
        return false
    end
    if max_pwr ~= nil then
        if type(power) ~= "number" or type(weight) ~= "number" or weight <= 0 then
            return false
        end
        if power / weight > max_pwr then
            return false
        end
    end
    return true
end

-- The strongest compliant config of `model` under the caps, as {config, power}, or nil. "Strongest" =
-- highest power at or under the caps (the best legal trim); configs with unreadable power rank lowest and
-- only win when nothing has a readable power (then the lowest config key, deterministically).
local function strongest_compliant(model, max_power, max_pwr)
    local best
    for _, entry in ipairs(M.list_configs(model)) do
        if M.is_compliant(entry.power, entry.weight, max_power, max_pwr) then
            if not best then
                best = entry
            else
                local bp = best.power or -1
                local ep = entry.power or -1
                if ep > bp then
                    best = entry
                end
            end
        end
    end
    if not best then
        return nil
    end
    return {config = best.config, power = best.power}
end

-- Find the first car satisfying the Mode-3 caps, as {model, config}, or nil. Search order (ADR-0032):
-- the player's own model first (downgrade the trim, keep the brand), then other models alphabetically;
-- within a model the strongest compliant config wins. Deterministic so the pick is predictable.
function M.find_compliant(own_model, max_power, max_pwr)
    if type(own_model) == "string" and own_model ~= "" then
        local own = strongest_compliant(own_model, max_power, max_pwr)
        if own then
            return {model = own_model, config = own.config}
        end
    end
    for _, model in ipairs(M.list_models()) do
        if model ~= own_model then
            local pick = strongest_compliant(model, max_power, max_pwr)
            if pick then
                return {model = model, config = pick.config}
            end
        end
    end
    return nil
end

return M
