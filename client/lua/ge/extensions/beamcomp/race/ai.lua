-- BeamComp -- host-driven AI race opponents (ADR-0036).
--
-- Lives at lua/ge/extensions/beamcomp/race/ai.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless and reload-safe: this module holds no file-scope mutable state -- the caller
-- (init.lua) owns the tracked AI-car list + remote id sets in its reload-surviving M.state and passes
-- them back in, exactly like race/cones.lua.
--
-- An AI opponent is "a cone that drives itself" (ADR-0036): only the race owner (the /race issuer,
-- flagged with aiSlots in its raceStart) spawns the AI cars, BeamMP propagates them to every other
-- client ('Os:'), and the owner hands each to BeamNG's vehicle AI to drive the race route and reports
-- its checkpoint progress by proxy (the scoring lives in init.lua). Non-owners never spawn an AI car --
-- they only receive the synced one and, via the relayed aiMap, label it + suppress the owner's nametag.
--
-- TWO HANDOVER SPIKES live here (no local Lua interpreter, BeamNG/BeamMP internals unverified):
--   1. M.drive -- the exact `ai.*` call/mode that best tracks a tight race line is unverified; this is
--      one guarded candidate (ai.setMode('manual') + ai.driveUsingPath over the checkpoint names).
--   2. M.server_id_of -- the MPVehicleGE field that carries a vehicle's cross-client BeamMP id is
--      unverified; several plausible names are tried. If it fails, remote nametag suppression no-ops and
--      the owner's tag stays on the AI car -- the same accepted fallback as the cones (ADR-0020).
-- Both are flagged for the 2-client handover test.

local M = {}

local vehicles = require("beamcomp/race/vehicles")
local cones = require("beamcomp/race/cones")
local vehiclespecs = require("beamcomp/race/vehiclespecs")

local LOG_TAG = "beamcomp.ai"

-- The ultimate AI vehicle fallback (ADR-0036): used only when the resolution chain finds nothing and the
-- installed-model list is unavailable. Normal AI vehicles resolve via resolve_ai_vehicle (Etappe B).
local AI_MODEL = "etk800"

-- Difficulty presets (ADR-0036 Etappe B): each maps to BeamNG `ai` driving parameters. The default
-- (medium) keeps the proof's defensive 0.6 aggression. rubberband is OFF in every preset -- a catch-up
-- band is only enabled by an explicit airubber= override, never by a preset. aggression is the proven
-- knob; skill/rubberband/avoidCars are layered as guarded VE calls (spike, see optional_param_calls).
local PRESETS = {
    easy = {aggression = 0.35, skill = 0.5, rubberband = 0, avoidCars = true},
    medium = {aggression = 0.6, skill = 0.75, rubberband = 0, avoidCars = true},
    hard = {aggression = 0.95, skill = 1.0, rubberband = 0, avoidCars = true},
}
local DEFAULT_PRESET = "medium"

-- Resolve the effective AI driving parameters for a race (ADR-0036 Etappe B + Step-3b). Precedence per
-- parameter: explicit ai*= override (config.params) -> the named preset (config.preset) -> the aiRace
-- content defaults (content_defaults, only when no preset was given) -> the built-in default preset.
-- Returns {aggression, skill, rubberband, avoidCars, route} the drive command reads. `route` selects the AI
-- route variant (airoute=snap|direct, default "snap"): "snap" snaps the route onto the road navgraph (the
-- default), "direct" drives the exact authored line via a per-race custom navgraph (off-road capable).
function M.resolve_params(config, content_defaults)
    config = type(config) == "table" and config or {}
    content_defaults = type(content_defaults) == "table" and content_defaults or {}
    local preset = PRESETS[config.preset] or PRESETS[DEFAULT_PRESET]
    local params = {
        aggression = preset.aggression,
        skill = preset.skill,
        rubberband = preset.rubberband,
        avoidCars = preset.avoidCars,
        route = "snap",
    }
    -- With no explicit preset, let the content's authored defaults fill the two knobs it carries.
    if not config.preset then
        if content_defaults.aggression then
            params.aggression = content_defaults.aggression
        end
        if content_defaults.skill then
            params.skill = content_defaults.skill
        end
    end
    -- Explicit ai*= overrides win per parameter.
    local overrides = config.params or {}
    if overrides.aggr ~= nil then
        params.aggression = overrides.aggr
    end
    if overrides.skill ~= nil then
        params.skill = overrides.skill
    end
    if overrides.rubber ~= nil then
        params.rubberband = overrides.rubber
    end
    if overrides.avoid ~= nil then
        params.avoidCars = overrides.avoid
    end
    if overrides.route == "snap" or overrides.route == "direct" then
        params.route = overrides.route
    end
    return params
end

-- Candidate MPVehicleGE entry fields that carry a vehicle's cross-client BeamMP id (spike #2). Tried in
-- order until one yields a value; logged so the handover test can pin the real field.
local SERVER_ID_FIELDS = {"serverVehicleString", "serverVehicleID", "remoteVehID", "gameVehicleID"}

-- Deferred-restage bounds for AI cars (ADR-0036), mirroring the player restage (init.lua): a freshly
-- spawned car reports a stale spawn bbox while its jbeam loads, so front-anchoring immediately lands it
-- offset. Re-place once the spawn-bbox forward half-length changes by RESTAGE_MIN_DELTA (jbeam loaded) or
-- RESTAGE_MAX_WAIT elapses (same-footprint fallback).
local RESTAGE_MAX_WAIT = 3.0
local RESTAGE_MIN_DELTA = 0.2

-- Forward half-length (metres) of a vehicle's spawn bounding box, or nil if unavailable -- the jbeam-load
-- signal the deferred restage waits on (mirrors init.lua's spawn_oobb_forward). pcall-guarded: the bbox
-- API is engine-version-coupled.
local function spawn_oobb_forward(veh)
    local ok, half_y = pcall(function()
        return veh:getSpawnWorldOOBB():getHalfExtents().y
    end)
    if ok and type(half_y) == "number" then
        return half_y
    end
    return nil
end

-- Split an "model[:config]" token into (model, config); config is nil when absent. nil for an empty token.
local function split_car_token(token)
    if type(token) ~= "string" or token == "" then
        return nil
    end
    local model, config = token:match("^([^:]+):(.+)$")
    if model then
        return model, config
    end
    return token, nil
end

-- A random installed DRIVABLE model, owner-local (only the owner spawns AI, so no cross-client determinism
-- is needed). Draws from list_car_models so an AI never spawns as a prop/cone (ADR-0036 Etappe B). Falls
-- back to the fixed stock model when the (filtered) list is unavailable.
local function random_stock_model()
    local models = vehiclespecs.list_car_models()
    if #models == 0 then
        return AI_MODEL
    end
    return models[math.random(#models)]
end

-- Resolve a random-vehicle `spec` to (model, config) with the AI's best-effort fallback chain (ADR-0036):
-- the SHARED pool pick (vehiclespecs.random_vehicle, also used by the player car=random path), then the
-- deterministic cars-only find_compliant_car, then a random stock car -- so an AI slot ALWAYS gets a real
-- car even when no car passes the filters, and no branch can ever return a prop/trailer or nothing. Shared
-- by random_ai_vehicle (explicit aicar=random) and the default-AI-inherits-car=random branch in
-- resolve_ai_vehicle, so the two never drift. Returns (model, config).
local function resolve_random_spec(spec)
    local pick = vehiclespecs.random_vehicle(spec)
    if pick then
        return pick.model, pick.config
    end
    log("W", LOG_TAG, "no compliant car for random AI; using best-effort fallback")
    local fallback = vehiclespecs.find_compliant_car(spec.max_power, spec.max_pwr, spec.max_weight,
        spec.weight_range)
    if fallback then
        return fallback.model, fallback.config
    end
    return random_stock_model(), nil
end

-- A random AI vehicle {model, config} for an EXPLICIT aicar=random, filter-aware (ADR-0032/0037). Composes
-- three orthogonal filters, each rolled independently per AI:
--   * power/weight cap -- the relayed player policy's maxhp/maxpwr and the strict maxkg/minkg weight range,
--     active unless there is a FIXED player car=<model> (car=random is NOT a fixed car -- the caps compose,
--     mirroring the ADR-0032 amendment; only a concrete model drops them, Mode-2-before-Mode-3);
--   * big-car exclusion -- the AI config's noBigCars bool -> the BIG_CAR_MAX_WEIGHT curb-weight ceiling,
--     independent of the player policy (it is the AI's own filter);
--   * trim -- the AI config's randomTrim bool: false = the model's STOCK/default config, true = a random
--     compliant trim. randomTrim is tri-state: nil (typed /race aicar=random, content default, legacy
--     client -- no panel) keeps TODAY's cap-coupled behaviour (cap active -> random compliant trim, else
--     stock) so those callers are unchanged; the panel sends it explicitly to decouple trim from the cap.
-- The pool pick + best-effort fallback is the shared resolve_random_spec. Returns (model, config).
local function random_ai_vehicle(policy, config)
    config = type(config) == "table" and config or {}
    -- The cap applies unless the player forces a FIXED car (a concrete model). car=random is NOT a fixed car
    -- -- the caps still compose with the random pick -- so an explicit aicar=random under car=random maxhp=N
    -- also respects the cap. Only a concrete car=<model> drops the caps (car-wins precedence).
    local fixed_player_car = policy.car ~= nil and policy.car ~= "random"
    local cap_active = not fixed_player_car
        and (policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg)
    -- Resolve the effective trim: nil keeps today's cap-coupled default (random trim under a cap, else
    -- stock); an explicit bool from the panel overrides that coupling.
    local random_trim = config.randomTrim
    if random_trim == nil then
        random_trim = cap_active and true or false
    end
    return resolve_random_spec({
        max_power = cap_active and policy.maxhp or nil,
        max_pwr = cap_active and policy.maxpwr or nil,
        weight_range = cap_active and vehiclespecs.weight_range(policy.minkg, policy.maxkg) or nil,
        max_weight = config.noBigCars and vehiclespecs.BIG_CAR_MAX_WEIGHT or nil,
        random_trim = random_trim,
    })
end

-- Resolve one AI car's {model, config} via the Etappe-B fallback chain (ADR-0036). Precedence: explicit
-- aicar= (config.car), incl. the "random" and "host" sentinels -> the player vehicle policy (ADR-0032:
-- Mode 2 fixed car / Mode 3 cap-compliant car; Mode 1 = no policy falls through) -> the aiRace content
-- default vehicle(s) -> a random stock model. `index` (1-based) cycles the content vehicle list so multiple
-- AI vary. `host_car` is the owner's actual resolved race car {model, config} (aicar=host), read GE-side by
-- the caller at spawn (only the owner spawns AI); nil when unavailable. Returns (model, config).
local function resolve_ai_vehicle(config, content_defaults, policy, index, slot_policy, host_car)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    content_defaults = type(content_defaults) == "table" and content_defaults or {}
    slot_policy = type(slot_policy) == "table" and slot_policy or {}

    -- A per-AI slot policy wins over everything else: in a class-drop tournament each AI must drive the
    -- car/cap of its OWN class (ADR-0042), and outside one the named roster's pre-picked car rides the
    -- same field (ADR-0047). A fixed car spawns it; the roster's "host" sentinel resolves to the owner's
    -- actual race car exactly like aicar=host; a cap finds a compliant car; an empty or unsatisfiable
    -- spec falls through to the normal chain so the AI still races.
    if slot_policy.car == "host" then
        if type(host_car) == "table" and host_car.model then
            return host_car.model, host_car.config
        end
        log("W", LOG_TAG, "roster car 'host': no resolved host car; falling back to the AI-car chain")
    elseif slot_policy.car then
        local model, vehicle_config = split_car_token(slot_policy.car)
        if model then
            return model, vehicle_config
        end
    elseif slot_policy.maxhp or slot_policy.maxpwr then
        local pick = vehiclespecs.find_compliant(nil, slot_policy.maxhp, slot_policy.maxpwr)
        if pick then
            return pick.model, pick.config
        end
    end

    if config.car == "random" then
        -- The panel's "random" AI car (ADR-0037): an independent random car per AI so the field varies,
        -- refined by the composable trim + big-car axes and the active power cap (random_ai_vehicle).
        -- Distinct from no aicar (the content default below).
        return random_ai_vehicle(policy, config)
    elseif config.car == "host" then
        -- "same as host" (aicar=host): the AI inherit the OWNER's actual resolved race car (model+config),
        -- read GE-side at spawn and passed in as host_car (only the owner spawns AI, ADR-0036; the server
        -- relays the opaque "host" sentinel, so vehicle-blindness holds, ADR-0005). host_car.config may be a
        -- string (a named .pc preset) or an inline parts table -- either rides straight into spawn_at. An
        -- unresolved host car (placement degraded) falls through the chain below so the AI still races. The
        -- elseif keeps "host" out of the split_car_token branch (there is no model named "host").
        if type(host_car) == "table" and host_car.model then
            return host_car.model, host_car.config
        end
        log("W", LOG_TAG, "aicar=host: no resolved host car; falling back to the AI-car chain")
    elseif config.car then
        local model, vehicle_config = split_car_token(config.car)
        if model then
            return model, vehicle_config
        end
    end

    if policy.car == "random" then
        -- The player is on car=random and this AI has no explicit aicar= (default): INHERIT the player's
        -- random settings + restrictions (ADR-0032 amendment). Each such AI rolls its OWN random car
        -- (owner-local math.random, so the field varies per AI), composing the player caps AND the player's
        -- random axes via the SAME spec the player uses (random_spec_from_policy) -- so player and inheriting
        -- AI never drift. Empty pool -> the AI best-effort fallback (resolve_random_spec), never a prop or
        -- nothing. Branched BEFORE the split_car_token below so "random" is never spawned as a model name.
        return resolve_random_spec(vehiclespecs.random_spec_from_policy(policy))
    end
    if policy.car then
        return split_car_token(policy.car)
    end
    if policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg then
        local range = vehiclespecs.weight_range(policy.minkg, policy.maxkg)
        local pick = vehiclespecs.find_compliant(nil, policy.maxhp, policy.maxpwr, nil, range)
        if pick then
            return pick.model, pick.config
        end
        -- No compliant car: fall through to content/stock so the AI still races (best effort).
    end

    local vehicle_list = content_defaults.vehicles
    if type(vehicle_list) == "table" and #vehicle_list > 0 then
        local token = vehicle_list[((index - 1) % #vehicle_list) + 1]
        local model, vehicle_config = split_car_token(token)
        if model then
            return model, vehicle_config
        end
    end

    -- Ultimate fallback: a random car honouring the active power cap and the AI's trim/big-car axes
    -- (random_ai_vehicle) -- so an AI resolved this far still respects every active filter.
    return random_ai_vehicle(policy, config)
end

-- Spawn one host-owned AI car per slot at its grid pose (ADR-0036). `ai_slots` is the owner's relayed
-- list of {slot, id, label}; `grid_poses` is the full resolved grid (race/start). Each car's vehicle is
-- resolved via the Etappe-B fallback chain (resolve_ai_vehicle) from the relayed `config`/`content_defaults`
-- (ADR-0036 Etappe B) and the player `policy` (ADR-0032). `host_car` is the owner's actual resolved race car
-- {model, config} for the aicar=host mode, read GE-side by the caller at this spawn; nil otherwise. Returns
-- a list of spawned cars {id, slot, label, veh_id}; a slot whose spawn fails is logged and skipped (the
-- field degrades to fewer AI rather than aborting). BeamMP propagates each spawn to all clients.
function M.spawn(ai_slots, grid_poses, config, content_defaults, policy, host_car)
    local cars = {}
    if type(ai_slots) ~= "table" or type(grid_poses) ~= "table" then
        return cars
    end
    for index, slot_info in ipairs(ai_slots) do
        local pose = grid_poses[(slot_info.slot or 0) + 1]
        if not pose then
            log("W", LOG_TAG, "no grid pose for AI slot " .. tostring(slot_info.slot))
        else
            -- slot_info carries this AI's per-class policy (car/maxhp/maxpwr) in a class-drop tournament
            -- (ADR-0042); it takes precedence inside resolve_ai_vehicle. nil fields = the normal chain.
            local model, vehicle_config = resolve_ai_vehicle(config, content_defaults, policy, index,
                slot_info, host_car)
            local veh, reason = vehicles.spawn_at(pose, model, vehicle_config)
            if veh then
                cars[#cars + 1] = {
                    id = slot_info.id,
                    slot = slot_info.slot,
                    label = slot_info.label,
                    veh_id = veh:getId(),
                    -- Grid pose kept for the deferred front-anchor restage (M.restage); the spawn lands
                    -- center-anchored until then.
                    pose = pose,
                    restaged = false,
                    restage_baseline = nil,
                    restage_wait = RESTAGE_MAX_WAIT,
                }
                -- Diagnostic: the grid pose we aimed for vs where the car actually landed, so a grid
                -- mismatch (wrong slot / pose) is visible in beamng.log against the player's "placed at
                -- grid (x, y, z)" line. The fresh car is center-anchored here (no front-anchor/restage
                -- yet, unlike a player car), so a ~half-car forward offset is expected, not a bug.
                local landed = veh:getPosition()
                log("I", LOG_TAG, string.format(
                    "spawned AI '%s' (%s) '%s%s' slot %s -> pose (%.1f, %.1f, %.1f), "
                    .. "landed (%.1f, %.1f, %.1f)",
                    tostring(slot_info.label), tostring(slot_info.id), tostring(model),
                    vehicle_config and (":" .. vehicle_config) or "", tostring(slot_info.slot),
                    pose.pos.x, pose.pos.y, pose.pos.z, landed.x, landed.y, landed.z))
            else
                log("W", LOG_TAG, "AI spawn failed for slot " .. tostring(slot_info.slot)
                    .. ": " .. tostring(reason))
            end
        end
    end
    return cars
end

-- Freeze or release every AI car in place (ADR-0036): the AI cars are held through staging + countdown
-- like the players' cars and released on the racing phase. Reuses the player freeze (controller.setFreeze
-- queued to the car's VE). No-op on cars whose vehicle is gone.
function M.set_frozen(cars, frozen)
    if type(cars) ~= "table" then
        return
    end
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            vehicles.set_vehicle_frozen(veh, frozen)
        end
    end
end

-- Deferred front-anchor restage of each AI car onto its grid pose (ADR-0036), the per-car mirror of the
-- player restage. The spawn lands the car center-anchored at the pose; once its jbeam has loaded (spawn
-- bbox changes) or RESTAGE_MAX_WAIT elapses, re-place it front-anchored (vehicles.place_at_grid, which
-- touches no other car) and re-freeze it (still held until racing). Called per frame over the frozen
-- phases; each car restages once (`restaged`). No-op once all are done.
function M.restage(cars, dt)
    if type(cars) ~= "table" or not be then
        return
    end
    for _, car in ipairs(cars) do
        if not car.restaged then
            local veh = be:getObjectByID(car.veh_id)
            if veh and car.pose then
                local current = spawn_oobb_forward(veh)
                if car.restage_baseline == nil then
                    car.restage_baseline = current
                end
                car.restage_wait = (car.restage_wait or RESTAGE_MAX_WAIT) - (dt or 0)
                local loaded = current ~= nil and car.restage_baseline ~= nil
                    and math.abs(current - car.restage_baseline) > RESTAGE_MIN_DELTA
                if loaded or car.restage_wait <= 0 then
                    vehicles.place_at_grid(veh, car.pose)
                    vehicles.set_vehicle_frozen(veh, true)
                    car.restaged = true
                    log("I", LOG_TAG, string.format("re-placed AI '%s' on grid slot %s",
                        tostring(car.label), tostring(car.slot)))
                end
            elseif not veh then
                car.restaged = true  -- vehicle gone; nothing to restage
            end
        end
    end
end

-- Resolve a race route (list of {pos = {x,y,z}}) to a de-duplicated list of navgraph WAYPOINT NAMES,
-- GE-side (SPIKE #1, ADR-0036). The checkpoint names are race-internal ("Pathnode 3") and are not in the
-- AI navgraph, so each route position is mapped to its nearest navgraph waypoint via the GE `map` global
-- (the VE has no `map`; doing it GE-side keeps the queued VE command trivial and crash-proof). Each lookup
-- is pcall-guarded. Returns the names list (empty if `map` is unavailable -> the caller falls back to a
-- span drive so the car still moves). NOTE: do NOT interpolate extra points between route nodes and snap
-- them -- a straight-line interpolation lands off-road and findClosestRoad then jumps to unrelated roads,
-- wrecking the route (tried, reverted). Tightening the lap-seam line needs the authored calcAIPath line
-- (Etappe B), not denser navgraph snapping.
local function resolve_waypoint_names(route)
    local names = {}
    if type(map) ~= "table" or type(map.findClosestRoad) ~= "function" then
        return names
    end
    for _, point in ipairs(route) do
        local p = point.pos
        local ok, n1 = pcall(map.findClosestRoad, vec3(p.x, p.y, p.z))
        if ok and type(n1) == "string" and n1 ~= "" and names[#names] ~= n1 then
            names[#names + 1] = n1
        end
    end
    return names
end

-- The optional difficulty-parameter VE calls beyond aggression (SPIKE, ADR-0036 Etappe B). skill,
-- rubberband and avoidCars have no stable ai.driveUsingPath argument across engine versions, so each is
-- emitted as its own pcall-wrapped call: pcall(ai.setX, v) is safe even when ai.setX is nil (pcall catches
-- the nil-call), so a missing API no-ops instead of breaking the proven drive. Returns a "; "-joined call
-- list (possibly empty). rubberband is only emitted when > 0 (off by default in every preset).
--
-- In-game effectiveness on BeamNG 0.38.5 (2-client, 2026-06-13): `aggression` and `avoidCars` have a clear
-- visible effect; `aiskill=` has NO visible effect (kept best-effort). The old `aispeed=` speed-mode knob
-- was inert and has been retired. See memory beamcomp-ai-driving-findings.
local function optional_param_calls(params)
    local calls = {}
    if params.skill ~= nil then
        calls[#calls + 1] = string.format("pcall(ai.setSkill, %.2f)", params.skill)
    end
    if params.rubberband and params.rubberband > 0 then
        calls[#calls + 1] = string.format("pcall(ai.setRubberbandValue, %.2f)", params.rubberband)
    end
    if params.avoidCars ~= nil then
        calls[#calls + 1] = string.format("pcall(ai.setAvoidCars, %q)", params.avoidCars and "on" or "off")
    end
    return table.concat(calls, "; ")
end

-- The VE-side Lua that drives one AI car (SPIKE #1, ADR-0036): set manual AI + the resolved aggression,
-- then either follow the resolved navgraph waypoints (ai.driveUsingPath) or, if none resolved, span the
-- road network so the car still drives. The proven driveUsingPath arg set (wpTargetList/noOfLaps/
-- aggression) is kept byte-for-byte; the Etappe-B difficulty params ride as guarded trailing calls
-- (optional_param_calls) so they never regress the proven drive. Trivial + cannot throw -- the heavy
-- navgraph lookup happened GE-side. Multi-lap repetition is baked into `names_literal` (noOfLaps does NOT
-- loop a wpTargetList, verified in-game), so noOfLaps stays 1.
local function drive_command(names_literal, params)
    local extras = optional_param_calls(params)
    if extras ~= "" then
        extras = "; " .. extras
    end
    if names_literal == "" then
        return string.format(
            "ai.setMode('manual'); ai.setAggression(%.2f); ai.setMode('span')%s",
            params.aggression, extras)
    end
    return string.format(
        "ai.setMode('manual'); ai.setAggression(%.2f); "
        .. "ai.driveUsingPath({wpTargetList = {%s}, noOfLaps = 1, aggression = %.2f})%s",
        params.aggression, names_literal, params.aggression, extras)
end

-- Append `name` to `names` unless it repeats the current tail. ai.driveUsingPath dislikes
-- two identical consecutive waypoints, so every layout path funnels through this.
local function append_waypoint(names, name)
    if names[#names] ~= name then
        names[#names + 1] = name
    end
end

-- Lay the resolved single-lap waypoint sequence out across `lap_count` laps (ADR-0036). The
-- first lap drives the full resolved route -- lap_names[1] is the start/finish node the car is
-- spawned on. Every later lap drops that leading start/finish node, so the AI never steers back
-- to the start line at the lap seam: it crosses the line naturally on the racing line between the
-- previous lap's last node and this lap's first corner. laps=1 is byte-for-byte the proven
-- single-lap path. Consecutive duplicates are dropped throughout. Pure; returns the name list.
local function lay_out_lap_waypoints(lap_names, lap_count)
    local names = {}
    for _, name in ipairs(lap_names) do
        append_waypoint(names, name)
    end
    for _ = 2, lap_count do
        for i = 2, #lap_names do
            append_waypoint(names, lap_names[i])
        end
    end
    return names
end

-- The race route as a list of {x, y, z, r?} nodes (ADR-0036 Step-3b): each route point's position plus its
-- corridor radius. These become the nodes of the custom race navgraph the AI drives over
-- (install_custom_race_map) -- the exact authored line, no road snap, off-road capable. Pure geometry,
-- GE-side. Points with no position are skipped; a missing radius falls back to a default at drive time.
local function build_route_nodes(route)
    local nodes = {}
    for _, point in ipairs(route) do
        local p = point.pos
        if type(p) == "table" and p.x and p.y and p.z then
            nodes[#nodes + 1] = {x = p.x, y = p.y, z = p.z, r = point.radius}
        end
    end
    return nodes
end

-- How far past an open route's finish line the AI's final drive target sits (metres). Far enough that
-- the car crosses the line at speed and brakes only behind it, short enough to stay on plausibly
-- raceable ground behind the finish.
local OVERSHOOT_DISTANCE = 30.0

-- `distance` metres past `last` along the prev->last direction, as {x, y, z}; nil when the two points
-- (nearly) coincide and carry no direction.
local function extrapolate_past(prev, last, distance)
    local dx, dy, dz = last.x - prev.x, last.y - prev.y, last.z - prev.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 0.01 then
        return nil
    end
    local scale = distance / length
    return {x = last.x + dx * scale, y = last.y + dy * scale, z = last.z + dz * scale}
end

-- The overshoot target position for an open route: `distance` metres past the last node along the final
-- segment's direction. Walks back past degenerate (coincident) nodes for a usable direction; nil when
-- the route has fewer than 2 distinct positions (no overshoot, by design).
local function overshoot_position(nodes, distance)
    local last = nodes[#nodes]
    for i = #nodes - 1, 1, -1 do
        local position = extrapolate_past(nodes[i], last, distance)
        if position then
            return position
        end
    end
    return nil
end

-- Append the open-route finish-overshoot waypoint (snap variant): extrapolate OVERSHOOT_DISTANCE past
-- the finish along the final route segment, snap that ONE point to the navgraph, and append it once as
-- the final drive target -- so the AI crosses the finish line at speed and brakes only behind it
-- instead of stopping short of the last checkpoint's trigger radius. If the snap lands back on the
-- current route end (the finish node), the distance is doubled and retried once; still no distinct
-- node -> no overshoot (logged), i.e. the prior brake-on-the-line behaviour. NOTE: this extrapolates
-- exactly ONE point BEHIND the finish -- it never interpolates between route nodes (see
-- resolve_waypoint_names: interpolated snapping wrecks the route; tried, reverted).
local function append_overshoot_waypoint(names, route)
    if #names == 0 then
        return
    end
    if type(map) ~= "table" or type(map.findClosestRoad) ~= "function" then
        return
    end
    local nodes = build_route_nodes(route)
    local distance = OVERSHOOT_DISTANCE
    for _ = 1, 2 do
        local position = overshoot_position(nodes, distance)
        if not position then
            log("I", LOG_TAG, "no finish overshoot: route has no usable final segment")
            return
        end
        local ok, name = pcall(map.findClosestRoad, vec3(position.x, position.y, position.z))
        if not ok or type(name) ~= "string" or name == "" then
            log("W", LOG_TAG, "no finish overshoot: navgraph snap behind the finish failed")
            return
        end
        if name ~= names[#names] then
            names[#names + 1] = name
            log("I", LOG_TAG, string.format(
                "finish overshoot waypoint '%s' (%.0f m past the finish)", name, distance))
            return
        end
        distance = distance * 2
    end
    log("I", LOG_TAG, "no distinct navgraph node behind the finish; AI will brake on the line")
end

-- The wpTargetList node-index sequence across `lap_count` laps. The custom graph has one node per route
-- point (1..node_count); a lap drives them in order, every lap repeated in full. The car spawns ON node 1
-- (the start line), and ai.driveUsingPath's getPointNodePath(ego.pos -> node 1) then returns a 1-node path
-- that newManualPath crashes on (it needs path[2]); so the FIRST lap starts at node 2 -- node 1 still lies
-- on the initial car->node-2 path, so it is driven, just not listed as an explicit target. Later laps run
-- the full node list, and on a closed loop index 1 is appended once more so the AI drives THROUGH the
-- finish (the closing edge n->1 carries it). Returns a list of 1-based node indices.
local function lay_out_node_indices(node_count, lap_count, closed)
    local seq = {}
    for lap = 1, lap_count do
        local first = (lap == 1) and 2 or 1
        for i = first, node_count do
            seq[#seq + 1] = i
        end
    end
    if closed and node_count > 1 then
        seq[#seq + 1] = 1
    end
    return seq
end

-- Append the open-route finish-overshoot node (direct variant): one synthetic custom-map node
-- OVERSHOOT_DISTANCE past the finish along the final segment, radius inherited from the finish node,
-- targeted exactly once after the last lap -- the same crossing-at-speed intent as
-- append_overshoot_waypoint. Mutates `nodes` (the custom map gains the node and its N->N+1 link) and
-- `index_sequence` (the one extra final target). Closed loops never come here -- their closing edge
-- already carries the AI through the finish (lay_out_node_indices).
local function append_overshoot_node(nodes, index_sequence)
    if #nodes < 2 then
        return
    end
    local position = overshoot_position(nodes, OVERSHOOT_DISTANCE)
    if not position then
        log("I", LOG_TAG, "no finish overshoot: route has no usable final segment")
        return
    end
    position.r = nodes[#nodes].r
    nodes[#nodes + 1] = position
    index_sequence[#index_sequence + 1] = #nodes
end

local DEFAULT_NODE_RADIUS = 4.0  -- corridor half-width when a route point ships none

-- Build a BeamNG navgraph (map.nodes format) whose ONLY road is the race line, and install it as the
-- client's live map via map.reset (ADR-0036 Step-3b). Unlike the VE mapmgr.setCustomMap, map.reset
-- (= map.loadMap) rebuilds ALL derived structures -- edgeKdTree, the graphpath, lane config, rules -- and
-- pushes a COMPLETE map to every vehicle, so ai.driveUsingPath{wpTargetList} drives it with BeamNG's full
-- planner and none of the missing-field crashes a hand-set custom map hits. GE-side, owner-only. The nodes
-- are bc1..bcN at the route positions, linked in order (plus a closing edge on a circuit); each edge
-- carries the in/out positions + radii loadMap's kd-tree build indexes. Returns true when installed; the
-- real navgraph is restored by M.restore_map() after the race.
local function install_custom_race_map(nodes, closed)
    if type(map) ~= "table" or type(map.reset) ~= "function" or #nodes < 2 then
        return false
    end
    local custom = {}
    for i, n in ipairs(nodes) do
        custom["bc" .. i] = {
            pos = vec3(n.x, n.y, n.z),
            radius = n.r or DEFAULT_NODE_RADIUS,
            links = {},
        }
    end
    local function link(i, j)
        local a, b = "bc" .. i, "bc" .. j
        local data = {
            inNode = a, outNode = b, drivability = 1, speedLimit = 100, lanes = nil,
            oneWay = false, gatedRoad = false,
            inPos = custom[a].pos, inRadius = custom[a].radius,
            outPos = custom[b].pos, outRadius = custom[b].radius,
        }
        custom[a].links[b] = data
        custom[b].links[a] = data
    end
    for i = 1, #nodes - 1 do
        link(i, i + 1)
    end
    if closed then
        link(#nodes, 1)
    end
    local ok, err = pcall(map.reset, custom)
    if not ok then
        log("W", LOG_TAG, "could not install custom race map: " .. tostring(err))
        return false
    end
    log("I", LOG_TAG, string.format("installed custom race map: %d node(s)", #nodes))
    return true
end

-- Restore the real navgraph after a race that installed a custom race map (ADR-0036 Step-3b): map.reset()
-- with no argument rebuilds the map from the scene. Guarded; no-op when map is unavailable.
function M.restore_map()
    if type(map) == "table" and type(map.reset) == "function" then
        pcall(map.reset)
        log("I", LOG_TAG, "restored real navgraph after race")
    end
end

-- The VE-side Lua that drives one AI car along the installed custom race map (ADR-0036 Step-3b): manual AI
-- + the resolved aggression, then the non-teleporting ai.driveUsingPath{wpTargetList} over the bc nodes.
-- The map is complete (map.reset built it), so no field patching is needed -- BeamNG's planner handles
-- curvature/speed/lanes. The Etappe-B difficulty params ride as guarded trailing calls. With no targets it
-- spans the road network so the car still drives. noOfLaps is not used (the lap sequence is baked into the
-- wpTargetList).
local function drive_command_wptargets(index_sequence, params)
    local extras = optional_param_calls(params)
    if extras ~= "" then
        extras = "; " .. extras
    end
    if #index_sequence == 0 then
        return string.format(
            "ai.setMode('manual'); ai.setAggression(%.2f); ai.setMode('span')%s",
            params.aggression, extras)
    end
    local quoted = {}
    for _, idx in ipairs(index_sequence) do
        quoted[#quoted + 1] = string.format("'bc%d'", idx)
    end
    return string.format(
        "ai.setMode('manual'); ai.setAggression(%.2f); "
        .. "ai.driveUsingPath({wpTargetList={%s},aggression=%.2f})%s",
        params.aggression, table.concat(quoted, ","), params.aggression, extras)
end

-- Arm BeamNG's vehicle AI to drive each car along the race route (ADR-0036 Step-3b). The route variant is
-- `params.route`: "snap" (default) routes over the per-point navgraph snap (resolve_waypoint_names +
-- wpTargetList, the on-road variant); "direct" installs a custom navgraph whose only road is the race line
-- (install_custom_race_map -> map.reset) and drives the EXACT authored line over it via the non-teleporting
-- ai.driveUsingPath{wpTargetList} (off-road capable, no road snap); an empty result spans the road
-- network so the car still drives. The lap sequence is laid out over the lap count (full-lap repeat +
-- closed-loop finish drive-through), then the drive command -- built from the resolved difficulty `params`
-- -- is queued to each car's VE (queueLuaCommand, the channel vehicles.set_vehicle_frozen uses). `closed` (a
-- circuit) adds the closing edge + drive-through; an OPEN route instead gets one overshoot target
-- ~OVERSHOOT_DISTANCE behind the finish (both variants) so the AI crosses the line at speed and brakes
-- only behind it -- ai.driveUsingPath brakes to a stop ON its final target, which otherwise parks the car
-- short of the last checkpoint's trigger radius. pcall-guarded. A nil `params` uses the default preset.
-- Returns a summary for the chat notice, incl. customMap=true when a custom navgraph was installed (the
-- caller restores the real one at teardown via M.restore_map).
function M.drive(cars, route, laps, params, closed)
    if type(cars) ~= "table" then
        return
    end
    route = type(route) == "table" and route or {}
    params = type(params) == "table" and params or M.resolve_params(nil, nil)
    local lap_count = math.max(1, math.floor(tonumber(laps) or 1))

    local source, command, per_lap, total
    local custom_map = false
    if params.route == "direct" then
        local nodes = build_route_nodes(route)
        local index_sequence = lay_out_node_indices(#nodes, lap_count, closed)
        -- perLap counts the real route nodes; the overshoot node below is a drive aid, not a lap stop.
        per_lap = #nodes
        if not closed then
            append_overshoot_node(nodes, index_sequence)
        end
        if install_custom_race_map(nodes, closed) then
            command = drive_command_wptargets(index_sequence, params)
            source = "direct"
            custom_map = true
        else
            command = drive_command_wptargets({}, params)
            source = "span"
        end
        total = #index_sequence
    else
        local lap_names = resolve_waypoint_names(route)
        local names = lay_out_lap_waypoints(lap_names, lap_count)
        if not closed then
            append_overshoot_waypoint(names, route)
        end
        local quoted = {}
        for _, name in ipairs(names) do
            quoted[#quoted + 1] = string.format("%q", name)
        end
        command = drive_command(table.concat(quoted, ", "), params)
        source = #names > 0 and "navgraph-snap" or "span"
        per_lap, total = #lap_names, #names
    end

    log("I", LOG_TAG, string.format(
        "AI route source=%s: %d node(s)/lap from %d route point(s), %d lap(s) -> %d total",
        source, per_lap, #route, lap_count, total))
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            local ok, err = pcall(function() veh:queueLuaCommand(command) end)
            if not ok then
                log("W", LOG_TAG, "could not arm AI drive on '" .. tostring(car.label)
                    .. "': " .. tostring(err))
            else
                log("I", LOG_TAG, "armed AI drive on '" .. tostring(car.label) .. "'")
            end
        end
    end
    -- Summary for the owner's race-start chat notice (which route variant the AI actually got); customMap
    -- tells the caller a custom navgraph is live so it restores the real one at teardown (M.restore_map).
    return {source = source, perLap = per_lap, total = total, laps = lap_count, customMap = custom_map}
end

-- Stop the AI before despawn so a half-driven car does not lurch on teardown (best-effort). No-op on a
-- gone vehicle; guarded.
function M.stop(cars)
    if type(cars) ~= "table" then
        return
    end
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            pcall(function() veh:queueLuaCommand("ai.setMode('disabled')") end)
        end
    end
end

-- Despawn the host's AI cars (ADR-0036): delete each tracked vehicle. Tolerant of an already-gone
-- vehicle. BeamMP propagates the owned delete ('Od:'), removing them for all clients. Returns the count
-- processed. Mirrors cones.clear.
function M.clear(cars)
    if type(cars) ~= "table" then
        return 0
    end
    local cleared = 0
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            pcall(function() veh:delete() end)
        end
        cleared = cleared + 1
    end
    if cleared > 0 then
        log("I", LOG_TAG, string.format("cleared %d AI car(s)", cleared))
    end
    return cleared
end

-- Suppress the owner's BeamMP nametag on a (host-local or remote-synced) AI car and keep it out of the
-- Tab vehicle cycle (ADR-0036), reusing the cone policy. Best-effort + guarded; a not-yet-registered
-- vehicle keeps its tag and is retried by the caller. Returns true if the nametag was hidden this call.
function M.suppress(veh)
    if not veh then
        return false
    end
    cones.exclude_from_cycle(veh)
    return cones.hide_vehicle_nametag(veh)
end

-- A vehicle's cross-client BeamMP id, or nil (SPIKE #2). The owner reads it for each AI car to build the
-- aiMap; a remote reads it per synced vehicle to match the relayed set. Tries the candidate MPVehicleGE
-- fields in order, fully guarded; logs the first field that yields a value so the handover test can pin
-- it. nil outside a BeamMP session or when no field resolves.
function M.server_id_of(veh)
    if not veh then
        return nil
    end
    if type(MPVehicleGE) ~= "table" or type(MPVehicleGE.getVehicleByGameID) ~= "function" then
        return nil
    end
    local ok, server_id = pcall(function()
        local entry = MPVehicleGE.getVehicleByGameID(veh:getID())
        if type(entry) ~= "table" then
            return nil
        end
        for _, field in ipairs(SERVER_ID_FIELDS) do
            local value = entry[field]
            if value ~= nil and value ~= "" then
                return value
            end
        end
        return nil
    end)
    if not ok then
        log("W", LOG_TAG, "server_id_of failed: " .. tostring(server_id))
        return nil
    end
    return server_id
end

-- ===== Named AI roster (ADR-0047) =====

-- Built-in nickname pool for the named-AI roster: 64 tongue-in-cheek English racing gamer tags (no real
-- people or brands). Custom names saved by admins live in the server-persisted pool and mix in via the
-- custom_pool argument of the draw helpers; only those custom entries can carry a preferred car.
local NAME_POOL = {
    "BrakeChecker99", "SundayDriver", "CrashTestDummy", "CaptainOversteer",
    "LiftOffLenny", "ApexPredator", "GravelMagnet", "WallHugger",
    "LastLapLarry", "TurboTortoise", "NitroNoodle", "HandbrakeHank",
    "OversteerOtto", "UndersteerUncle", "PitLanePete", "RedMistRandy",
    "SlipstreamSally", "TrackLimitTed", "DNFDenny", "BackmarkerBob",
    "ChicaneCharlie", "DriftKingDave", "FuelSaverFred", "GridGoblin",
    "HairpinHarry", "KerbstoneKevin", "LockupLuke", "MirrorMissingMike",
    "NoBrakesNed", "OilPatchOllie", "PhotoFinishPhil", "QualifyingQuinn",
    "RumbleStripRick", "SandTrapSam", "TailgateTina", "TorqueSteerTom",
    "VMaxVinnie", "WheelspinWalt", "YellowFlagYuri", "ZigzagZack",
    "AeroLessAndy", "BargeBoardBarry", "CoastingCarl", "DiveBombDylan",
    "EarlyApexEddie", "FlatOutFinn", "GhostBraker", "HotLapHugo",
    "InsideLineIzzy", "JumpStartJack", "KamikazeKarl", "LateBrakeLewis",
    "MidfieldMarty", "NoGripNigel", "OptimisticOwen", "PanicBrakePaul",
    "RageQuitRoy", "SpinCycleStan", "ThrottleTherapy", "UnsafeReleaseUli",
    "VibesOnlyVic", "WreckItWes", "XenonXavier", "BoxThisLapBen",
}

-- Draw `count` roster names without replacement (ADR-0047): custom pool entries (which may carry a
-- preferred car) plus the built-ins, minus `exclude` (the panel's existing roster names, exact match).
-- Custom names take pool priority only in candidate ORDER; the draw itself is uniform over all remaining
-- candidates. Pool exhaustion (impossible in practice: 64+ names vs. max 16 AI) degrades to "AI <k>"
-- fallback names + a log instead of failing the roll. Returns a list of {name, preferred?}.
function M.draw_roster_names(count, exclude, custom_pool)
    local taken = {}
    if type(exclude) == "table" then
        for _, name in ipairs(exclude) do
            taken[name] = true
        end
    end
    local candidates = {}
    if type(custom_pool) == "table" then
        for _, entry in ipairs(custom_pool) do
            if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= ""
                    and not taken[entry.name] then
                candidates[#candidates + 1] = {name = entry.name, preferred = entry.car}
                taken[entry.name] = true
            end
        end
    end
    for _, name in ipairs(NAME_POOL) do
        if not taken[name] then
            candidates[#candidates + 1] = {name = name}
            taken[name] = true
        end
    end
    local drawn = {}
    for k = 1, count do
        if #candidates > 0 then
            drawn[k] = table.remove(candidates, math.random(#candidates))
        else
            log("W", LOG_TAG, "roster name pool exhausted; falling back to 'AI " .. k .. "'")
            drawn[k] = {name = "AI " .. k}
        end
    end
    return drawn
end

-- Whether a pool name's PREFERRED CAR participates in a roster roll (ADR-0047 decision 4): it replaces a
-- ROLLED car ("they always get it, even on random"), but an explicit concrete admin choice -- a fixed
-- aicar=<model> or aicar=host -- stays authoritative for every entry.
function M.preferred_applies(config)
    local car = type(config) == "table" and config.car or nil
    return car == nil or car == "" or car == "random"
end

-- Whether a preferred-car token passes the ACTIVE vehicle restrictions, with the same filter set the
-- random roll for this row would compose (ADR-0047 / ADR-0032): the player policy caps -- unless a fixed
-- player car dropped them (the random_ai_vehicle gate) -- plus the AI big-car ceiling. No active filter
-- means compliant. A "model:config" token checks that config's own power/weight; a model-only (stock)
-- token uses the representative "any compliant trim" rule (random_stock_compliant's rule -- model-level
-- metadata is unreliable pre-spawn). Unreadable specs under a set cap are non-compliant
-- (vehiclespecs.is_compliant), so the caller then treats the preferred car like a discarded random
-- candidate and keeps rolling.
function M.preferred_car_compliant(token, config, policy)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    local model, vehicle_config = split_car_token(token)
    if not model or model == "host" then
        return false
    end
    local fixed_player_car = policy.car ~= nil and policy.car ~= "random"
    local cap_active = not fixed_player_car
        and (policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg)
    local max_power = cap_active and policy.maxhp or nil
    local max_pwr = cap_active and policy.maxpwr or nil
    local range = cap_active and vehiclespecs.weight_range(policy.minkg, policy.maxkg) or nil
    local max_weight = config.noBigCars and vehiclespecs.BIG_CAR_MAX_WEIGHT or nil
    if not (max_power or max_pwr or range or max_weight) then
        return true
    end
    if vehicle_config then
        local power = vehiclespecs.config_power(model, vehicle_config)
        local weight = vehiclespecs.config_weight(model, vehicle_config)
        return vehiclespecs.is_compliant(power, weight, max_power, max_pwr, max_weight, range)
    end
    for _, entry in ipairs(vehiclespecs.list_configs(model)) do
        if vehiclespecs.is_compliant(entry.power, entry.weight, max_power, max_pwr, max_weight, range) then
            return true
        end
    end
    return false
end

-- Roll one roster car token for the panel (ADR-0047): the SAME resolution chain as the spawn
-- (resolve_ai_vehicle) minus the spawn-only inputs -- content defaults come from the parsed race (not
-- available at panel time) and the host car resolves at spawn, so aicar=host stays the opaque "host"
-- sentinel. Because the rolled token then rides the per-slot ai_entry.car with highest precedence, the
-- panel-shown car IS the spawned car by construction (one-truth). `index` is 1-based (varies content
-- cycling if defaults ever apply). Returns "model[:config]" or "host".
function M.roll_roster_car(config, policy, index)
    config = type(config) == "table" and config or {}
    if config.car == "host" then
        return "host"
    end
    local model, vehicle_config = resolve_ai_vehicle(config, nil, policy, index or 1, nil, nil)
    return vehicle_config and (model .. ":" .. vehicle_config) or model
end

-- A human label for a roster car token (ADR-0047): the model's display name (vehiclespecs.model_label)
-- plus the config's in-game name when the token carries one; "host's car" for the host sentinel. Display
-- only -- the opaque token stays the value everywhere.
function M.car_label(token)
    if token == "host" then
        return "host's car"
    end
    local model, vehicle_config = split_car_token(token)
    if not model then
        return tostring(token or "?")
    end
    local label = vehiclespecs.model_label(model)
    if not vehicle_config then
        return label
    end
    for _, entry in ipairs(vehiclespecs.list_configs(model)) do
        if entry.config == vehicle_config then
            return label .. " - " .. entry.name
        end
    end
    return label .. " - " .. vehicle_config
end

-- Roll `count` full roster entries for the panel (ADR-0047): draw unique names (built-ins + the custom
-- pool, minus `exclude`), then per entry either apply the name's preferred car -- when the row's car
-- would be rolled at all (preferred_applies) and the token passes the active restrictions
-- (preferred_car_compliant) -- or roll a car through the spawn chain (roll_roster_car). Returns a list of
-- {name, car, carLabel} ready for the panel.
function M.roll_roster_entries(count, exclude, config, policy, custom_pool)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    local entries = {}
    for k, drawn in ipairs(M.draw_roster_names(count, exclude, custom_pool)) do
        local car
        if drawn.preferred and M.preferred_applies(config)
                and M.preferred_car_compliant(drawn.preferred, config, policy) then
            car = drawn.preferred
        else
            car = M.roll_roster_car(config, policy, k)
        end
        entries[k] = {name = drawn.name, car = car, carLabel = M.car_label(car)}
    end
    return entries
end

-- The owner's aiMap entries (ADR-0036): each AI car's label + its BeamMP server id, for the relay that
-- lets remotes label + suppress the cars. Skips a car whose server id has not resolved yet (the owner
-- can rebuild + resend until all resolve). Returns a list of {label, serverId}.
function M.server_map(cars)
    local entries = {}
    if type(cars) ~= "table" then
        return entries
    end
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        local server_id = veh and M.server_id_of(veh) or nil
        if server_id ~= nil then
            entries[#entries + 1] = {label = car.label, serverId = server_id}
        end
    end
    return entries
end

return M
