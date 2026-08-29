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

-- Model Types that are not drivable race cars, the ONE denylist behind every vehicle list BeamComp offers
-- (ADR-0032 amendment 2026-08-09). Props (cones, barriers, …) and trailers are spawnable jbeam "vehicles"
-- that must never back an AI opponent (ADR-0036 Etappe B); Traffic is BeamNG's low-detail traffic filler
-- (`simple_traffic`, ~90 stripped-down look-alike configs) and Debug its crush-test rig
-- (`roof_crush_tester`) -- neither is a race car, and BeamNG hides both from its own selector.
--
-- A stock install's 122 models type as Prop 67 / Car 28 / Trailer 13 / Truck 10 / Heavy Machinery 2 /
-- Traffic 1 / Debug 1, so these four entries drop the props, the trailers and exactly those two models.
-- Truck and Heavy Machinery stay drivable -- the BIG_CAR_MAX_WEIGHT heuristic handles buses/semis.
--
-- A DENYLIST, never an allowlist, and that is load-bearing for modded vehicles: BeamNG's own "usable car"
-- checks (core/funstuff.lua, backgroundActivities/g2g.lua, dragRace/generateDragOpponents.lua) test
-- `Type == "Car" or Type == "Truck"`, which would hide every mod with a custom Type ("Kart", "Bus",
-- "Race Car", …). Here an unreadable, absent or unknown Type counts as a CAR, so the filter only ever
-- removes a KNOWN non-race type. The engine backs that up: a model whose info.json carries no Type is
-- given "Unknown" (core/vehicles.lua), and a vehicle folder without an info.json at all is back-filled
-- as "Car". Accepted consequence: a mod that types a genuinely drivable car as Traffic or Debug is
-- hidden -- deliberate, since those are BeamNG's own meanings for those values.
local NON_CAR_TYPES = {Prop = true, Trailer = true, Traffic = true, Debug = true}

-- Big-vehicle curb-weight ceiling (kg) for the "exclude big vehicles" AI filter (max_weight axis). A
-- config heavier than this is treated as a big vehicle and excluded. 3500 kg keeps every passenger car,
-- sports car and SUV (all at/under ~3000 kg curb in BeamNG) while reliably excluding buses (~13000 kg)
-- and US semi-trucks (~6000 kg+); heavy van/pickup configs near the boundary may slip through, which is
-- accepted for a curb-weight heuristic (a class-based filter is future work). Reusable as a general
-- vehicle-policy weight cap, though this item wires it only into the AI random path (race/ai.lua).
M.BIG_CAR_MAX_WEIGHT = 3500

-- One-shot: log the keys of the first config-info table we read, so the real power/index field names are
-- visible in-game (the single runtime-verification point for this module). Module-scope, reset on reload.
local probed = false

-- One-shot: log how many installed models the race-car filter drops, so a /cars listing that suddenly
-- shows ~40 instead of ~122 entries is explainable from the log. Set only on a non-empty raw list, so an
-- early call made before core_vehicles is ready cannot burn the one-shot on a meaningless "0 of 0".
-- Module-scope, reset on reload (mirrors `probed`).
local filter_logged = false

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

-- Collapse a display string to its trimmed form; nil for a non-string or an all-whitespace value, so a
-- caller can fall back cleanly (an empty Brand/Configuration never leaks a blank or leading-space label).
local function trimmed(value)
    if type(value) ~= "string" then
        return nil
    end
    local result = value:match("^%s*(.-)%s*$")
    if result == "" then
        return nil
    end
    return result
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

-- PRIVATE raw enumeration: every installed vehicle model key, sorted, unfiltered -- props, trailers,
-- traffic fillers and debug rigs included. Empty when the model list is unavailable.
--
-- Deliberately private and deliberately named for what it is: BeamComp has exactly ONE public vehicle
-- list, M.list_car_models, and the point of that is that a second list can never drift away from it
-- again (ADR-0032 amendment 2026-08-09). Nothing user-facing may read this -- it exists only as the
-- source M.list_car_models filters.
local function installed_models()
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
        if type(key) == "string" then
            models[#models + 1] = key
        end
    end
    table.sort(models)
    return models
end

-- The model-level Type ("Car"/"Truck"/"Prop"/"Trailer"/…) for `model`, or nil when unreadable. Read from
-- the model metadata (data.model), the same source collect_client_info uses for the records type field.
local function model_type(model)
    local data = get_model(model)
    local info = data and data.model
    if type(info) ~= "table" then
        return nil
    end
    return info.Type
end

-- THE single "is this model a race car?" decision (ADR-0032 amendment 2026-08-09): the hand-excluded
-- models plus the NON_CAR_TYPES denylist, in one place, so the list filter and the per-model guard below
-- can never disagree. An unreadable/absent/unknown Type is a CAR (see NON_CAR_TYPES) -- the filter only
-- ever removes a KNOWN non-race model, which is what keeps modded vehicles usable.
local function is_race_car(model)
    if EXCLUDED_MODELS[model] then
        return false
    end
    local kind = model_type(model)
    return not (kind ~= nil and NON_CAR_TYPES[kind] == true)
end

-- THE vehicle list of the whole mod: a sorted array of installed race-car model keys. Every enumeration
-- BeamComp offers reads this one function -- the setup panel's three car dropdowns (carlist.options), the
-- /cars chat listing (carlist.build), the player's Mode-3 substitute search (find_compliant) and the
-- random AI pool (find_compliant_car / random_compliant / random_stock_compliant, race/ai.lua) -- so what
-- an admin sees listed is exactly what an AI can draw and what a substitute search can land on
-- (ADR-0032 amendment 2026-08-09; before it, /cars and find_compliant read an unfiltered second list).
function M.list_car_models()
    local models = installed_models()
    local cars = {}
    for _, model in ipairs(models) do
        if is_race_car(model) then
            cars[#cars + 1] = model
        end
    end
    if not filter_logged and #models > 0 then
        filter_logged = true
        local kinds = {}
        for kind in pairs(NON_CAR_TYPES) do
            kinds[#kinds + 1] = kind
        end
        table.sort(kinds)
        log("I", LOG_TAG, string.format("%d of %d installed models are race cars (%d dropped as %s)",
            #cars, #models, #models - #cars, table.concat(kinds, "/")))
    end
    return cars
end

-- True only when `model` is a KNOWN non-race model -- the per-model form of the same decision
-- M.list_car_models filters with, so a model is never listed as a car here and rejected there. An
-- unreadable Type returns false (counts as a car), so this only ever drops a KNOWN non-car.
--
-- Three callers, all "that is not a race car" guards: race/vehicles.lua is_owned_race_car (a player
-- focused on an owned prop/"Stange" or a simplified-traffic car falls through to a fresh default car,
-- ADR-0032 amendment), race/props.lua is_race_prop (bounce the player out of it mid-race) and race/ai.lua
-- roster_car_needs_reroll (a stored roster token that is no longer a race car re-rolls).
function M.is_known_non_car(model)
    return not is_race_car(model)
end

-- The human display name of a model -- "Brand Name" (e.g. "Ibishu Pessima"), read from the model metadata
-- (data.model Brand/Name), the same source model_type reads. Uses whichever of Brand/Name is present and
-- falls back to the model key when both are unreadable, so it never yields an empty or whitespace-only
-- label (degrade-don't-crash, ADR-0032). Backs the setup dropdown labels (carlist.options), display only --
-- the model key stays the selection value.
function M.model_label(model)
    local data = get_model(model)
    local info = data and data.model
    if type(info) == "table" then
        local brand = trimmed(info.Brand)
        local name = trimmed(info.Name)
        if brand and name then
            return brand .. " " .. name
        end
        if brand or name then
            return brand or name
        end
    end
    return type(model) == "string" and model or ""
end

-- The human label of a config-info table -- its in-game Configuration/Name, trimmed, falling back to the
-- config key when both are missing or blank (so an empty Configuration string never leaks a blank label).
local function config_label(info, key)
    if type(info) == "table" then
        return trimmed(info.Configuration) or trimmed(info.Name) or key
    end
    return key
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
            local label = config_label(info, key)
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

-- The config-info table whose BoundingBox represents `model`/`config`, or nil. Resolution (R3 of
-- precompute-default-car-bbox-direct-spawn -- deliberately NO special path for a modified car): a named
-- preset config that actually exists is used as given; anything else -- an inline parts TABLE (a tuned
-- car), a serialized partsTree blob string, or nil (stock spawn) -- falls back to the model's STOCK
-- config (data.model.default_pc), whose box is right for every tuning that does not change the body
-- shell. The model-level info.json carries no BoundingBox of its own, so default_pc is the only
-- model-wide stand-in there is.
local function box_config_info(data, config)
    local configs = data and data.configs
    if type(configs) ~= "table" then
        return nil
    end
    if type(config) == "string" and config ~= "" and type(configs[config]) == "table" then
        return configs[config]
    end
    local info = data.model
    local default_pc = type(info) == "table" and info.default_pc or nil
    if type(default_pc) == "string" and type(configs[default_pc]) == "table" then
        return configs[default_pc]
    end
    return nil
end

-- One corner of a BoundingBox entry as {x, y, z}, or nil when it is not a 3-number array. The field is
-- authored data (dynamicVehicleData writes it, a mod may hand-write it), so validate rather than trust.
local function box_corner(corner)
    if type(corner) ~= "table" then
        return nil
    end
    local x, y, z = corner[1], corner[2], corner[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return {x = x, y = y, z = z}
end

-- The {min, max} box out of a config-info table, or nil when it carries none / a malformed one. Split
-- out so the substituting and the strict lookup share one parse.
local function box_of(info)
    local box = type(info) == "table" and info.BoundingBox or nil
    if type(box) ~= "table" then
        return nil
    end
    local min, max = box_corner(box[1]), box_corner(box[2])
    if not min or not max then
        return nil
    end
    if max.x < min.x or max.y < min.y or max.z < min.z then
        return nil
    end
    return {min = min, max = max}
end

-- (public) One config's VEHICLE-LOCAL bounding box from BeamNG's own metadata, WITHOUT spawning the car:
-- {min = {x, y, z}, max = {x, y, z}}, or nil when it is unknown or unreadable.
--
-- Source: the `BoundingBox` field of info_<config>.json, which core_vehicles.getModel hands through
-- verbatim (core/vehicles.lua: `local configData = readData`) -- the same table config_power/config_weight
-- already read Power/Weight from. The engine uses the field this way itself (career vehicleShopping checks
-- pre-spawn whether a car fits a parking spot). It is written by lua/vehicle/extensions/
-- dynamicVehicleData.lua constructAABB(): the AABB over ALL jbeam nodes, expressed RELATIVE TO THE
-- REFERENCE NODE -- i.e. relative to exactly the point veh:getPosition() returns.
--
-- Coverage in a stock 0.39 install: 1000 of 1689 config infos carry a box, and 40 of the 45
-- non-Prop/Trailer/Traffic/Debug models have one on their DEFAULT config. The gaps are props, trailers,
-- simple_traffic and test rigs -- the set NON_CAR_TYPES filters out anyway.
--
-- THIS IS THE SEAM for a second source: should the metadata prove unavailable under BeamMP (the one thing
-- that cannot be verified headless -- watch for the "bbox lookup: 0 of N cars resolved" line race/
-- vehicles.lua writes on the first grid spawn of a race), a baked-in table gets added HERE, behind this
-- lookup, and no caller changes. It is deliberately NOT built yet.
function M.config_bbox(model, config)
    return box_of(box_config_info(get_model(model), config))
end

-- (public) One config's box ONLY when the model actually ships that config -- no substitution.
--
-- config_bbox above falls back to the model's DEFAULT config for an unknown key. As a placement
-- stand-in that is right: it puts a car a few centimetres off instead of half a car length. As a
-- FOOTPRINT it is a wrong answer dressed as a right one -- an md_series whose partConfig read "Truck"
-- (a name the model does not ship, e.g. a player-saved config) came back as the 6.39 m default dump
-- truck, so a 10.9 m school bus reserved nothing and the field spawned into it.
--
-- An absent config is not the dangerous case: the car then spawns as the model's default, so the default
-- box IS its box. Only a non-empty key the model does not ship yields nil here.
function M.config_bbox_exact(model, config)
    local data = get_model(model)
    local configs = data and data.configs
    if type(configs) ~= "table" then
        return nil
    end
    if type(config) == "string" and config ~= "" then
        return box_of(configs[config])
    end
    local info = data.model
    local default_pc = type(info) == "table" and info.default_pc or nil
    return box_of(type(default_pc) == "string" and configs[default_pc] or nil)
end

-- (public) One config's box PROJECTED INTO PLACEMENT TERMS, or nil when no box is known:
--   forward -- reference point -> the car's FRONT face, along the car's forward axis (metres, positive)
--   lateral -- reference point -> the box centre, along the car's RIGHT axis (signed; negative for the
--              usual right-side reference node)
--   bottom  -- reference point -> the box BOTTOM, along up (signed, normally negative)
--   half    -- half extents {x = width/2, y = length/2, z = height/2}, all positive
--
-- These are exactly the three numbers race/vehicles.lua front_anchored_target derives from a LIVE
-- getSpawnWorldOOBB read (forward_dist / lateral_dist / bottom_offset), so a caller can front-anchor a car
-- that does not exist yet.
--
-- THE AXES ARE THE DANGEROUS PART, so they are derived here rather than assumed. The jbeam frame the box
-- lives in is +x = LEFT, +y = REAR, +z = UP, verified against the shipped 0.39 data:
--   * etk800 slot "Front Wheels" nodeOffset.y = -1.40 vs "Rear Wheels" +1.41 (wheelbase 2.81 m) -> -y is
--     forward; lua/vehicle/wheels.lua computes its "vector facing forward" as nodes[ref] - nodes[back],
--     which for this car is (0, -0.53, 0) -- the same answer.
--   * node fw2r (front wheel RIGHT) sits at x = -0.6898, fw2l (LEFT) at +0.6898 -> -x is right.
--   * cross-check: etk800's box is [[-0.69, -2.05, -0.225], [1.35, 2.62, 1.165]] and its reference node
--     f2r sits at jbeam (-0.33, -0.23, +0.23), so the box centre lands on x = 0 (a car is symmetric) and
--     its floor on z = 0 (the tyre contact patch). citybus: min.y = -1.54 on a 12.63 m body -- the
--     reference node is 1.54 m behind the nose, which is where a bus driver sits.
-- With the local centre c = (min + max) / 2 the projections onto the car's own axes are therefore
-- (forward, right, up) = (-c.y, -c.x, c.z), and substituting the half extents gives
--     forward = -c.y + (max.y - min.y) / 2 = -min.y
--     lateral = -c.x
--     bottom  =  c.z - (max.z - min.z) / 2 =  min.z
-- Reading the box as "+x right / +y forward" instead would put an etk800 57 cm too far forward and 66 cm
-- sideways, and a citybus 9.6 m out.
--
-- `half` is not used by the placement path; it is published because the box is the only place these
-- extents exist pre-spawn, and the terrain-slope follow-up needs them.
function M.config_anchor(model, config)
    local box = M.config_bbox(model, config)
    if not box then
        return nil
    end
    local min, max = box.min, box.max
    return {
        forward = -min.y,
        lateral = -(min.x + max.x) / 2,
        bottom = min.z,
        half = {
            x = (max.x - min.x) / 2,
            y = (max.y - min.y) / 2,
            z = (max.z - min.z) / 2,
        },
    }
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

-- Build a STRICT weight-range spec {min, max} (kg) from the player-facing minkg/maxkg caps for is_compliant,
-- or nil when neither bound is set (so the common no-range path stays a single nil check downstream). Unlike
-- the lenient max_weight axis this range is exclude-on-unreadable (ADR-0032; see is_compliant). Non-numeric
-- bounds are dropped -- the server relays numbers, but stay defensive at the boundary.
function M.weight_range(minkg, maxkg)
    local min_kg = type(minkg) == "number" and minkg or nil
    local max_kg = type(maxkg) == "number" and maxkg or nil
    if min_kg == nil and max_kg == nil then
        return nil
    end
    return {min = min_kg, max = max_kg}
end

-- True when (power, weight) satisfy the caps. A nil cap is "no limit on this axis". The POWER axes
-- (max_power, max_pwr) are safety guarantees: a set cap whose input is unreadable is NOT satisfied (cannot
-- verify => non-compliant, per ADR-0032). max_pwr compares the power-to-weight ratio power/weight (hp per
-- kg). max_weight caps curb weight (kg) for the "exclude big vehicles" NICETY filter, not a safety cap: a
-- config with a READABLE weight over the ceiling is non-compliant, but an unreadable/nil weight is INCLUDED
-- (it must not drop a car whose weight metadata is missing -- an unreadable weight emptying the pool is the
-- random-stock bug). weight_range ({min?, max?} kg, or nil -- build it with M.weight_range) is the
-- player-facing STRICT weight range (maxkg/minkg, ADR-0032), deliberately DISTINCT from the lenient
-- max_weight: an unreadable weight under EITHER set bound is non-compliant (cannot verify => blocked, like
-- the power caps), and a readable weight below min or above max is non-compliant. All caps nil => no policy.
-- Both weight axes are additive: with max_weight and weight_range nil this function is bit-for-bit its
-- pre-weight-axis form (every 4-/5-arg caller is unchanged), and the lenient and strict axes AND together
-- when both are set (the AI random path when the player set a weight range and the AI config excludes big cars).
function M.is_compliant(power, weight, max_power, max_pwr, max_weight, weight_range)
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
    -- Lenient weight axis is include-on-unreadable (see docstring): only a READABLE over-ceiling weight fails.
    if max_weight ~= nil and type(weight) == "number" and weight > max_weight then
        return false
    end
    -- Strict weight range (maxkg/minkg): an unreadable weight under a set bound is non-compliant (cannot verify).
    if weight_range ~= nil then
        local min_kg, max_kg = weight_range.min, weight_range.max
        if min_kg ~= nil or max_kg ~= nil then
            if type(weight) ~= "number" then
                return false
            end
            if min_kg ~= nil and weight < min_kg then
                return false
            end
            if max_kg ~= nil and weight > max_kg then
                return false
            end
        end
    end
    return true
end

-- The strongest compliant config of `model` under the caps, as {config, power}, or nil. "Strongest" =
-- highest power at or under the caps (the best legal trim); configs with unreadable power rank lowest and
-- only win when nothing has a readable power (then the lowest config key, deterministically).
local function strongest_compliant(model, max_power, max_pwr, max_weight, weight_range)
    local best
    for _, entry in ipairs(M.list_configs(model)) do
        if M.is_compliant(entry.power, entry.weight, max_power, max_pwr, max_weight, weight_range) then
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

-- Find the first car satisfying the caps, as {model, config}, or nil. Search order (ADR-0032): the
-- player's own model first (downgrade the trim, keep the brand), then other models alphabetically; within
-- a model the strongest compliant config wins. Deterministic so the pick is predictable. `max_weight` (kg,
-- optional, lenient) and `weight_range` ({min?, max?} kg, optional, strict maxkg/minkg) additionally
-- exclude over-/under-weight trims; nil = no weight limit on that axis (unchanged behavior).
--
-- Searches M.list_car_models like every other path (ADR-0032 amendment 2026-08-09): a substitute for a
-- player's over-cap car is a CAR, never a cone, trailer or traffic filler that happened to sort early.
-- The own-model bias is unaffected -- an own model is tried first whatever its Type, and a player sitting
-- in a non-car reaches here only after is_owned_race_car has already dropped it.
function M.find_compliant(own_model, max_power, max_pwr, max_weight, weight_range)
    if type(own_model) == "string" and own_model ~= "" then
        local own = strongest_compliant(own_model, max_power, max_pwr, max_weight, weight_range)
        if own then
            return {model = own_model, config = own.config}
        end
    end
    for _, model in ipairs(M.list_car_models()) do
        if model ~= own_model then
            local pick = strongest_compliant(model, max_power, max_pwr, max_weight, weight_range)
            if pick then
                return {model = model, config = pick.config}
            end
        end
    end
    return nil
end

-- The no-own-model sibling of find_compliant -- the best-effort deterministic fallback for the random-AI
-- pool, so an AI still gets a real car even when no car passes the active filters (ADR-0036 "AI never
-- spawns a prop" invariant). Both draw from the same list_car_models now; what differs is the bias: the AI
-- random path has no "own" car to try first. Strongest compliant config within a model wins, models
-- alphabetically. Returns
-- {model, config} or nil. max_weight is include-on-unreadable via is_compliant, exactly like find_compliant;
-- the strict weight_range (maxkg/minkg) is exclude-on-unreadable, also via is_compliant.
function M.find_compliant_car(max_power, max_pwr, max_weight, weight_range)
    for _, model in ipairs(M.list_car_models()) do
        local pick = strongest_compliant(model, max_power, max_pwr, max_weight, weight_range)
        if pick then
            return {model = model, config = pick.config}
        end
    end
    return nil
end

-- The config keys of `model` whose power/weight satisfy the caps (its legal trims), as an array; empty when
-- the model has no compliant config. Reuses is_compliant, so an unreadable power/weight under a set cap is
-- non-compliant (excluded), per ADR-0032 -- no new rule. `max_weight` (lenient) and `weight_range`
-- (strict maxkg/minkg) additionally exclude over-/under-weight trims. Backs the random AI selector (random_compliant).
local function compliant_configs(model, max_power, max_pwr, max_weight, weight_range)
    local keys = {}
    for _, entry in ipairs(M.list_configs(model)) do
        if M.is_compliant(entry.power, entry.weight, max_power, max_pwr, max_weight, weight_range) then
            keys[#keys + 1] = entry.config
        end
    end
    return keys
end

-- A RANDOM cap-compliant car as {model, config}, or nil when no installed car satisfies the caps. Unlike
-- find_compliant (deterministic strongest trim, for the player substitute) this draws a model uniformly from
-- the pool of drivable models that have a compliant config, then a compliant trim within it uniformly -- so a
-- field of "random" AI under a Mode-3 cap (ADR-0036 Etappe B) varies per car while never exceeding the cap.
-- Models with no compliant config are never drawn (the pool pre-filter IS the "re-roll among compliant
-- models"), so the cap is never violated. Draws from list_car_models so an AI never spawns as a prop,
-- trailer or traffic filler. Owner-local -> math.random is fine (only the owner spawns AI, no
-- cross-client determinism, like ai.lua's
-- random_stock_model). `max_weight` (lenient) and `weight_range` (strict maxkg/minkg) additionally exclude
-- over-/under-weight trims from the pool.
function M.random_compliant(max_power, max_pwr, max_weight, weight_range)
    local pool = {}
    for _, model in ipairs(M.list_car_models()) do
        local configs = compliant_configs(model, max_power, max_pwr, max_weight, weight_range)
        if #configs > 0 then
            pool[#pool + 1] = {model = model, configs = configs}
        end
    end
    if #pool == 0 then
        return nil
    end
    local choice = pool[math.random(#pool)]
    return {model = choice.model, config = choice.configs[math.random(#choice.configs)]}
end

-- A RANDOM car that keeps its STOCK trim (config = nil = BeamNG's built-in default) and is drawn from the
-- pool of cars that satisfy the caps, as {model, config = nil}, or nil when no installed car qualifies. The
-- filter-aware sibling of random_compliant: instead of a random compliant TRIM it keeps the stock trim, so
-- the AI "random model + default type" path (race/ai.lua randomTrim=false) still honours the active
-- power/weight filters. A car qualifies iff it has AT LEAST ONE compliant config (compliant_configs, the
-- same CONFIG-level read random_compliant uses): the model-level metadata (data.model) is not reliably
-- populated pre-spawn under BeamMP, so reading stock power/weight from it emptied the pool and dropped the
-- AI back to a prop fallback (the random-stock bug); the config-level read IS populated. This is a
-- representative check, not the default config's own specs (BeamNG exposes no clean default-config id here),
-- so under a power cap a car whose default trim exceeds the cap but has a lighter compliant trim may still
-- spawn stock -- accepted, matching the big-car weight heuristic's imprecision. The "exclude big vehicles"
-- (max_weight) path -- the actual bug trigger -- is exact, because config weights are populated. With all
-- caps nil every car that has a config qualifies => uniform random, effectively the unconstrained stock
-- pick. Draws from list_car_models so an AI never spawns as a prop, trailer or traffic filler.
-- Owner-local -> math.random is fine (mirrors random_compliant).
function M.random_stock_compliant(max_power, max_pwr, max_weight, weight_range)
    local pool = {}
    for _, model in ipairs(M.list_car_models()) do
        if #compliant_configs(model, max_power, max_pwr, max_weight, weight_range) > 0 then
            pool[#pool + 1] = model
        end
    end
    if #pool == 0 then
        return nil
    end
    return {model = pool[math.random(#pool)], config = nil}
end

-- Build the random-vehicle spec (for M.random_vehicle) from a relayed PLAYER vehicle policy (ADR-0032
-- amendment). Shared by the player car=random path (race/vehicles.lua respawn_random) and a DEFAULT AI that
-- INHERITS the player's car=random (race/ai.lua resolve_ai_vehicle), so the player and the inheriting AI
-- cannot drift. The player caps compose: max_power/max_pwr from maxhp/maxpwr, the strict weight_range from
-- minkg/maxkg. The two axes default ON when the field is nil (a typed /race car=random; the panel sends
-- explicit booleans): random_trim from policy.randomTrim, and the big-car curb-weight ceiling from
-- policy.noBigCars. The AI caller adds its own best-effort fallback on an empty pool (never a prop).
function M.random_spec_from_policy(policy)
    policy = type(policy) == "table" and policy or {}
    local random_trim = policy.randomTrim
    if random_trim == nil then
        random_trim = true
    end
    local no_big_cars = policy.noBigCars
    if no_big_cars == nil then
        no_big_cars = true
    end
    return {
        max_power = policy.maxhp,
        max_pwr = policy.maxpwr,
        weight_range = M.weight_range(policy.minkg, policy.maxkg),
        max_weight = no_big_cars and M.BIG_CAR_MAX_WEIGHT or nil,
        random_trim = random_trim,
    }
end

-- The SHARED random-vehicle composition for the player (car=random, ADR-0032 amendment) and the AI
-- (aicar=random, ADR-0036) random paths -- extracted so the two pick IDENTICALLY and cannot drift. Given a
-- resolved cap+axis `spec`, draw ONE random car from the matching pool. `spec` fields, all optional:
--   * max_power (hp), max_pwr (hp/kg) -- the power caps;
--   * max_weight (kg) -- the lenient big-car curb-weight ceiling (noBigCars);
--   * weight_range ({min?, max?} kg) -- the strict maxkg/minkg range (build with M.weight_range);
--   * random_trim (bool) -- true = a random compliant TRIM (random_compliant), false/nil = the stock/default
--     trim (random_stock_compliant).
-- All caps nil is an unconstrained pool (both selectors treat nil caps as "no limit"), so this one call
-- covers both the capped and the uncapped case -- no separate branch. Returns {model, config} or nil when NO
-- installed car qualifies (an impossible cap, or no cars installed). The CALLER owns the ultimate fallback,
-- which differs by path: the AI degrades best-effort to a cap-ignoring stock car (silent); the player spawns
-- the fixed default car + warns. Draws only from list_car_models (the one cars-only list), so no branch
-- ever returns a prop, trailer or traffic filler.
function M.random_vehicle(spec)
    spec = type(spec) == "table" and spec or {}
    if spec.random_trim then
        return M.random_compliant(spec.max_power, spec.max_pwr, spec.max_weight, spec.weight_range)
    end
    return M.random_stock_compliant(spec.max_power, spec.max_pwr, spec.max_weight, spec.weight_range)
end

return M
