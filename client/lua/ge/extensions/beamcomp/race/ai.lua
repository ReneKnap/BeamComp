-- BeamComp -- host-driven AI race opponents (ADR-0036).
--
-- Lives at lua/ge/extensions/beamcomp/race/ai.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless and reload-safe: this module holds no file-scope mutable state -- the caller
-- (init.lua) owns the tracked AI-car list, the remote id sets and the rolling-route-window store in its
-- reload-surviving M.state and passes them back in, exactly like race/cones.lua.
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
-- The dev-authored driver definitions (ADR-0048): the SINGLE source of the named-AI pool -- every driver's
-- name -> preferred car + preferred colour. Replaces the old built-in NAME_POOL and the runtime-writable,
-- server-persisted custom pool. A mod-bundled data module, hand-edited in the repo, ships fixed.
local drivers = require("beamcomp/race/ai_drivers")

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

-- The presets' driving numbers for the setup panel's placeholder hints (ADR-0037): the grey
-- "<value> (default)" the empty Aggression/Skill/Rubberband fields show for the SELECTED preset. Keyed by
-- preset name, with the field names the panel's overrides already use (aggr/skill/rubber), plus the
-- fallback preset resolve_params applies when no preset is sent. Pushed with the setup data so the panel
-- reads these numbers instead of carrying a second copy of PRESETS that would silently drift.
--
-- Display only, and deliberately NOT a model of the full resolution: the no-preset branch of
-- resolve_params also lets an aiRace track's authored content_defaults override aggression/skill, which is
-- per-race data the panel has no view of. The fallback preset's numbers are what applies whenever the
-- track authors none (the common case).
function M.preset_defaults()
    local presets = {}
    for name, preset in pairs(PRESETS) do
        presets[name] = {aggr = preset.aggression, skill = preset.skill, rubber = preset.rubberband}
    end
    return {presets = presets, fallback = DEFAULT_PRESET}
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
        -- Defensive net (ADR-0036 "an AI never spawns a prop"): a roster token can predate the vehicle
        -- filter -- a preset saved when the prop/traffic models were still pickable, or a roster the
        -- panel-side repair never reached. Such a token falls through to the normal chain and gets a real
        -- car instead of spawning a cone. Only a KNOWN non-race model is rejected, so a modded car is
        -- untouched. Deliberately NOT applied to config.car/policy.car below: an admin who types
        -- `/race aicar=simple_traffic:<config>` has named it explicitly and gets what they asked for.
        if model and vehiclespecs.is_known_non_car(model) then
            log("W", LOG_TAG, "roster car '" .. tostring(slot_policy.car)
                .. "' is not a race car; falling back to the AI-car chain")
        elseif model then
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
            -- The roster's per-AI primary-paint colour (ADR-0047), an opaque hex string relayed per slot;
            -- nil = stock paint (chat path / no roster). Paint is applied inside spawn_at, pcall-guarded --
            -- a paint failure degrades to stock and never blocks the spawn.
            local veh, reason = vehicles.spawn_at(pose, model, vehicle_config, slot_info.color)
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
-- Also returns the WORLD POSITION of each resolved waypoint (map.getMap().nodes[name].pos, the same
-- lookup BeamNG's own race AI uses), 1:1 with the names -- the route checks measure the field against the
-- real drive targets, not against the route points they came from. The position list is all-or-nothing: it
-- comes back empty when any lookup fails, so a caller can only ever read a complete list or none at all.
--
-- KNOWN DEFECT, deliberately not fixed here (diagnosed 2026-08-09, engine-verified):
-- `map.findClosestRoad(pos)` returns the two endpoints of the closest EDGE -- `lua/ge/map.lua`
-- findClosestRoad ranks candidates by `pos:squaredDistanceToLineSegment(n1.pos, n2.pos)` and returns
-- `n1id, n2id` in the graph's own edge order, with NO relation to which endpoint is nearer to `pos`. We
-- keep `n1` unconditionally, so a route point lying near the far end of a long edge resolves to a drive
-- target up to a full edge length away -- on a start straight that is the ~100 m backwards jump the AI
-- were seen making. BeamNG's OWN race path builder does not do this: `gameplay/race/path.lua` computes
-- `xnorm = nodePos:xnormOnLine(a.pos, b.pos)` and swaps to `name_b` when `xnorm > 0.5`, i.e. it always
-- keeps the NEARER endpoint (and searches with `max(40, node.radius)` rather than the 200 m default).
--
-- It is left alone on purpose. The nearer-endpoint rule changes the resolved target of EVERY route point
-- on EVERY track, including the circuits the user has just confirmed good in game, and the symptom it
-- caused is already neutralised at the route's start by the geometric circuit.lead_skip (which now runs
-- for every route shape). What it does NOT cover is a mis-snap in the MIDDLE of a route -- lead_skip only
-- walks the front -- which would show as a short backwards jink mid-lap. Recommended follow-up: adopt the
-- xnorm swap plus the tighter search radius as its own item, with a before/after target diff on a real
-- track, so the change is inspected where its effect can actually be seen.
local function resolve_waypoint_names(route)
    local names, positions = {}, {}
    if type(map) ~= "table" or type(map.findClosestRoad) ~= "function" then
        return names, positions
    end
    local graph_nodes = nil
    if type(map.getMap) == "function" then
        local ok, graph = pcall(map.getMap)
        graph_nodes = (ok and type(graph) == "table") and graph.nodes or nil
    end
    local positions_complete = graph_nodes ~= nil
    for _, point in ipairs(route) do
        local p = point.pos
        local ok, n1 = pcall(map.findClosestRoad, vec3(p.x, p.y, p.z))
        if ok and type(n1) == "string" and n1 ~= "" and names[#names] ~= n1 then
            names[#names + 1] = n1
            local node = graph_nodes and graph_nodes[n1]
            if node and node.pos then
                positions[#names] = {x = node.pos.x, y = node.pos.y, z = node.pos.z}
            else
                positions_complete = false
            end
        end
    end
    if not positions_complete then
        positions = {}
    end
    return names, positions
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

-- ===== loop / circuit drive targets =============================================================
--
-- TWO INDEPENDENT FACTS decide the shape of the target list, and conflating them is what produced both
-- bugs this module has had:
--   * the ROUTE shape -- a LOOP repeats its first drive target as its last one (the engine's linear path
--     repeats a closed path's start node, race/parser.lua build_route_points keeps that repeat);
--   * how the RACE is SCORED -- `closed` = circuit (lap the loop, finish on the line) vs. sprint (every
--     checkpoint once, finish on the LAST one).
-- They are independent: a closed-loop track started with the `sprint` mode override is a loop route scored
-- as a sprint. Its finish is its last route node, NOT the start/finish line -- race/parser.lua
-- build_checkpoints drops the repeated start node for exactly that reason, so the AI route must drop it
-- too instead of driving an extra leg back to the line and extrapolating its overshoot past THAT.
--
-- The ends also need geometry the middle does not: the field is NOT staged on the first drive target
-- (race/grid.lua lays the grid out relative to the race's start POSE, and a custom grid -- ADR-0023 -- may
-- put it anywhere relative to the start/finish node), and the last target must lie PAST the finish,
-- because ai.driveUsingPath brakes to a stop on it.
--
-- One namespace table carries the helpers so they cost a single top-level local (the 200-local ceiling,
-- CLAUDE.md). A genuinely point-to-point route reaches none of this -- its drive path stays exactly as it is.
local circuit = {}

-- How far (metres) a car must sit beyond a drive target along that target's own direction of travel before
-- the target counts as already driven past. Large enough that a car standing essentially on a target does
-- not drop it, small enough to catch a grid staged in front of the start/finish node.
local PASSED_MARGIN = 2.0

-- How close two route points must be to count as the SAME point, i.e. as a route that closes on itself.
-- The closing repeat is literally the same path node, so this only absorbs float noise; a genuinely
-- distinct final node this close to the start would be an authoring degeneracy.
local LOOP_EPSILON = 0.25

-- Whether the route closes on itself: its last point is its first point again (the parser's closing
-- repeat). Positional, because that is what the shape actually is -- and it is the one signal both route
-- variants and the finish extrapolation can agree on.
function circuit.closes_loop(route)
    if #route < 3 then
        return false
    end
    local first, last = route[1].pos, route[#route].pos
    if type(first) ~= "table" or type(last) ~= "table" then
        return false
    end
    local dx, dy, dz = last.x - first.x, last.y - first.y, last.z - first.z
    return dx * dx + dy * dy + dz * dz <= LOOP_EPSILON * LOOP_EPSILON
end

-- A COPY of `route` without its closing repeat, for a loop route scored as a sprint: there the finish is
-- the route's own last node, not the start/finish line. Trimming the route itself (rather than the
-- resolved target list) is what keeps the finish overshoot honest -- append_overshoot_waypoint
-- extrapolates past the route's last segment, so a route still carrying the repeat would put the overshoot
-- past the START line, back into the beginning of the lap.
--
-- Never mutates the input: `route` is the race state's own routePoints table and is reused by every later
-- ai.drive call (each staged-quali launch is one).
function circuit.without_closing_repeat(route)
    local trimmed = {}
    for i = 1, #route - 1 do
        trimmed[i] = route[i]
    end
    return trimmed
end

-- Whether the navgraph has a path between two waypoints. A single unreachable consecutive pair makes
-- ai.driveUsingPath's route builder abort the WHOLE list (verified in BeamNG lua/vehicle/ai.lua: on an
-- empty getPath it returns without ever setting currentRoute, and its input validation is one-shot, so it
-- never retries) -- the car then stands still for the entire race. Any SYNTHETIC target we invent is
-- therefore checked before it is appended. Unavailable API -> true, i.e. today's unchecked behaviour.
function circuit.reachable(from, to)
    if type(map) ~= "table" or type(map.getPath) ~= "function" then
        return true
    end
    local ok, path = pcall(map.getPath, from, to)
    if not ok then
        return true
    end
    return type(path) == "table" and #path > 1
end

-- The unit direction of travel at target `i`: towards the next target that is a real distance away (so
-- coincident points are stepped over). nil when nothing usable follows.
function circuit.direction_at(positions, index)
    local from = positions[index]
    if not from then
        return nil
    end
    for i = index + 1, #positions do
        local to = positions[i]
        local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
        local length = math.sqrt(dx * dx + dy * dy + dz * dz)
        if length >= 0.01 then
            return {x = dx / length, y = dy / length, z = dz / length}
        end
    end
    return nil
end

-- Whether ANY car of the field already sits beyond `point` along `dir` -- i.e. whether making `point` the
-- first drive target would send at least one AI backwards. Checked against the whole field, so the target
-- lap 1 starts on is ahead of every car, not just of the pole. "Beyond" also requires the car to be inside
-- a 45-degree cone in front of the target: a car that projects past a target but lies far off to the side
-- (a hairpin right after the line, a parallel straight) has not driven past it -- it is somewhere else on
-- the track, and dropping that target would cut the route.
function circuit.passed(point, dir, starts)
    for _, start in ipairs(starts) do
        local dx, dy, dz = start.x - point.x, start.y - point.y, start.z - point.z
        local ahead = dx * dir.x + dy * dir.y + dz * dir.z
        if ahead > PASSED_MARGIN then
            local ox, oy, oz = dx - ahead * dir.x, dy - ahead * dir.y, dz - ahead * dir.z
            if ahead * ahead >= ox * ox + oy * oy + oz * oz then
                return true
            end
        end
    end
    return false
end

-- The field's actual starting positions at the gun: each car's live world position, falling back to the
-- grid pose it was staged on. This is what the route is measured against.
function circuit.start_positions(cars)
    local starts = {}
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        local position = nil
        if veh then
            local ok, live = pcall(function() return veh:getPosition() end)
            if ok and live and live.x then
                position = {x = live.x, y = live.y, z = live.z}
            end
        end
        if not position and type(car.pose) == "table" and type(car.pose.pos) == "table" then
            position = car.pose.pos
        end
        if position then
            starts[#starts + 1] = position
        end
    end
    return starts
end

-- How many LEADING drive targets the field has already driven past, so lap 1 starts at the first target
-- ahead of the grid instead of steering back to one behind it -- the AI-side mirror of the player plan's
-- "omit the start line at the gun" rule (race/checkpoints.lua M.plan, ADR-0013). Walks from the front and
-- stops at the first target that is still ahead. An implausible result (more than half the lap read as
-- passed) means the geometry was misread, so the full route is kept. 0 when there is nothing to measure.
--
-- Runs for EVERY route shape, not just a circuit (bug: the AI reversed ~100 m on a closed track run as a
-- SPRINT). Where the field stands relative to the first drive target is geometry; how the race is scored
-- is a separate question, and keying the skip on the scored mode is the same conflation ADR-0036's round-2
-- amendment already recorded for the route's END. It never drops a target that is still ahead -- it stops
-- at the first one -- so a genuine point-to-point sprint, whose field stands behind its first target,
-- skips nothing and is byte-identical.
function circuit.lead_skip(positions, starts)
    if #positions < 3 or #starts == 0 then
        return 0
    end
    local skip = 0
    while skip < #positions - 2 do
        local point = positions[skip + 1]
        local dir = circuit.direction_at(positions, skip + 1)
        if not dir or not circuit.passed(point, dir, starts) then
            break
        end
        skip = skip + 1
    end
    if skip > math.floor(#positions / 2) then
        log("W", LOG_TAG, string.format(
            "route start: %d of %d drive targets read as behind the grid; keeping the full route",
            skip, #positions))
        return 0
    end
    if skip > 0 then
        log("I", LOG_TAG, string.format(
            "route start: skipping %d leading drive target(s) the grid already sits past", skip))
    end
    return skip
end

-- The closed-route finish drive-through (snap variant), the circuit counterpart of the open route's
-- append_overshoot_waypoint: after the last lap, aim at the start/finish waypoint and then at the one
-- AFTER it, so ai.driveUsingPath brakes on a target PAST the line and the AI's final crossing is a real
-- swept crossing the detector can score (race/checkpoints.lua segment_hits_checkpoint). A closed route's
-- point list already ends on its start node (the engine's linear path repeats it, race/parser.lua), so
-- append_waypoint drops the first of the two and the usual result is one extra target; with a point list
-- that does not repeat it, both are appended and pin the route through the line. This is the light form of
-- what BeamNG's own race AI does -- gameplay/race/race.lua startAiVehicle appends aiPath[1] and drives a
-- whole extra lap on a closed path; we stop one node past the line instead of one lap past it.
function circuit.append_drive_through(names, lap_names)
    if #names == 0 or #lap_names < 2 then
        return
    end
    append_waypoint(names, lap_names[1])
    append_waypoint(names, lap_names[2])
    log("I", LOG_TAG, string.format("circuit finish drive-through: '%s' past the line", lap_names[2]))
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
-- instead of stopping short of the last checkpoint's trigger radius. NOTE: this extrapolates exactly ONE
-- point BEHIND the finish -- it never interpolates between route nodes (see resolve_waypoint_names:
-- interpolated snapping wrecks the route; tried, reverted).
--
-- This is the one target we INVENT rather than read off the route, so it is the one that can be
-- unreachable -- and an unreachable target does not merely fail, it aborts the entire drive and leaves the
-- car motionless for the whole race (circuit.reachable). It is therefore both distinct-checked and
-- reachability-checked; a failure doubles the distance and retries once, and a second failure means no
-- overshoot at all (logged) -- the AI then brake on the line, which is the pre-overshoot behaviour and
-- still a racing car rather than a parked one.
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
        if name ~= names[#names] and circuit.reachable(names[#names], name) then
            names[#names + 1] = name
            log("I", LOG_TAG, string.format(
                "finish overshoot waypoint '%s' (%.0f m past the finish)", name, distance))
            return
        end
        if name ~= names[#names] then
            log("W", LOG_TAG, string.format(
                "finish overshoot '%s' has no navgraph path from '%s'; retrying farther out",
                name, tostring(names[#names])))
        end
        distance = distance * 2
    end
    log("I", LOG_TAG, "no usable navgraph node behind the finish; AI will brake on the line")
end

-- Append the open-route finish-overshoot node (direct variant): one synthetic custom-map node
-- OVERSHOOT_DISTANCE past the finish along the final segment, radius inherited from the finish node,
-- targeted exactly once after the last lap -- the same crossing-at-speed intent as
-- append_overshoot_waypoint. Mutates `nodes` (the custom map gains the node, so this must run BEFORE the
-- map is installed) and appends the new node's index to `appended`, which the caller turns into the
-- sequence's end decoration. Closed loops never come here -- a circuit needs no synthetic node, because
-- the node past its finish line already exists in the route (the closing edge plus node 2, see
-- window.append_lap).
local function append_overshoot_node(nodes, appended)
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
    appended[#appended + 1] = #nodes
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
-- wpTargetList). `names` are the custom-map node names ("bc7"), quoted verbatim -- byte-identical to the
-- "'bc%d'" formatting this builder used while it took node indices.
local function drive_command_wptargets(names, params)
    local extras = optional_param_calls(params)
    if extras ~= "" then
        extras = "; " .. extras
    end
    if #names == 0 then
        return string.format(
            "ai.setMode('manual'); ai.setAggression(%.2f); ai.setMode('span')%s",
            params.aggression, extras)
    end
    local quoted = {}
    for _, name in ipairs(names) do
        quoted[#quoted + 1] = string.format("'%s'", name)
    end
    return string.format(
        "ai.setMode('manual'); ai.setAggression(%.2f); "
        .. "ai.driveUsingPath({wpTargetList={%s},aggression=%.2f})%s",
        params.aggression, table.concat(quoted, ","), params.aggression, extras)
end

-- ===== the rolling route window =================================================================
--
-- ai.driveUsingPath arms a target list ONCE and brakes to a stop on its last target, so arming a whole
-- race in one call forced two bad trades at the same time: a circuit QUALIFYING session could only give
-- the AI the RACE lap count (on a one-lap race they set one time and then idled through the rest of a
-- 480 s window), and any long route armed laps x targets-per-lap per car in a single command.
--
-- The window decouples the armed length from the route length. WHAT the sequence is does not change --
-- the same helpers still decide it, ends included -- but at most BLOCK_TARGETS of it are armed at a time
-- and each car is topped up while it still has REFILL margin left. The sequence itself is materialised
-- one lap at a time, so a 60-lap qualifying supply costs nothing until it is actually driven.
--
-- The refill is SEAMLESS where it can be made to hold, and BeamNG lets it hold for both variants:
--   * ai.setPath only sets `manualPath` (lua/vehicle/ai.lua setPath) -- it never touches setState/setMode,
--     so `currentRoute` and the running plan survive and the next manual-mode tick calls
--     pathExtend(currentRoute.path, manualPath).
--   * pathExtend has a hard, SILENT contract: it does nothing at all unless the new path starts on the
--     exact node the live path currently ends on. That node is knowable from here -- driveUsingPath
--     builds its path by concatenating mapData:getPath(target_i, target_i+1), so the live path ends on
--     the LAST TARGET WE ARMED, and each pathExtend moves that end to the last target of the block it
--     appended. The engine's own path clean-up only ever trims the FRONT, so the joint chains.
--   * ai.driveUsingPath, by contrast, is a hard reset (setState -> setMode -> resetMapAndRoute) and makes
--     the car re-plan from its live position. That is why it is the fallback and not the mechanism.
--
-- One namespace table carries the whole thing, so it costs a single top-level local (the 200-local
-- ceiling, CLAUDE.md).
local window = {}

-- Drive targets armed at a time, and the target of a full block on whose arrival the next one is
-- fetched. The five-target margin is what makes the refill seamless: at racing speed that is hundreds of
-- metres, enough for a failed extension to be retried on the next tick AND still fall back to a full
-- re-arm before the car runs out of route. Deliberately counted in TARGETS, not laps -- a 60-checkpoint
-- lap must not cost more to arm than an 8-checkpoint one. No UI knob (user decision 2026-08-08).
local BLOCK_TARGETS = 25
local REFILL_AT = 20

-- How much armed route (metres) a car keeps ahead of it, on top of the target-count rule above. This is
-- not a second policy, it is what makes the count rule safe on a densely authored route: BeamNG's speed
-- planner puts a target speed of ZERO on the last node of the path once its plan reaches it
-- (lua/vehicle/ai.lua: `lastNode.speed = lastNode.manSpeed or 0` when `route.path[lastNode.pathidx+1]` is
-- nil), and the plan looks up to 550 m ahead (getMinPlanLen's own clamp). So an AI starts braking for the
-- end of its block as soon as that end comes within braking distance. Where route points are far apart,
-- five targets of margin is far more than 550 m and the count rule fires first; where they are close
-- together it is not, and without this the AI would lift at every block seam. Above the engine's own 550 m
-- plan ceiling the planner cannot see the end of the block at all.
local REFILL_DISTANCE = 600.0

-- The distance rule only ever tops a car up while a block's worth of targets or fewer is still ahead of
-- it, and a refill adds a whole block -- so a car never holds more than 2 x BLOCK_TARGETS unreached
-- targets, however close together the route's points are. That is the bound that keeps this a WINDOW.
local MAX_TOPUP_AHEAD = BLOCK_TARGETS

-- How close (metres) a car has to come to a drive target, or how far it must project past that target
-- along the target's own direction of travel (while staying within REACH_LATERAL of that line), before
-- the host counts the target as reached. Deliberately permissive: a cursor that STALLS starves the car of
-- route, while a cursor that runs ahead costs nothing -- an extension always appends after the ARMED end
-- rather than after the cursor, and the re-arm fallback re-derives what lies behind the car from the
-- car's own position (window.drop_passed).
local REACH_RADIUS = 10.0
local REACH_LATERAL = 30.0

-- A route-supply descriptor: the recipe the window materialises the drive-target sequence from, one lap
-- at a time. Plain data -- no closures, no engine handles -- so it can live in the caller's
-- reload-surviving state, and it is shared by reference between the cars of one arming (they all drive
-- the same route with the same field-wide leading skip). Fields:
--   variant/closed/route -- what the end decoration is (see window.append_tail)
--   lap / lap_pos        -- one lap's drive targets and their world positions (false = unmeasurable)
--   first / rest_start   -- where lap 1 and every later lap start inside `lap`
--   dedup                -- funnel appends through append_waypoint (snap) or append verbatim (direct)
--   laps / back_laps     -- the drive supply's lap count, and the cap the give-up fallback uses
--   tail / params        -- the precomputed direct-variant end decoration, and the difficulty params
--   built / built_pos    -- the materialised prefix; body/total are set once the tail has been appended
function window.new(fields)
    fields.built = {}
    fields.built_pos = {}
    fields.laps_built = 0
    fields.tail_built = false
    return fields
end

-- Append lap `n` of the sequence to `out` (and its positions to `out_pos`). The ONLY place the lap layout
-- lives, and it keeps the two shapes the variants have always had:
--   * snap -- lap 1 runs lap[first..#lap] and every later lap drops the leading start/finish node
--     (lap[2..#lap]), so the AI never steers back to the line at a lap seam: it crosses the line
--     naturally between the previous lap's last node and this lap's first corner. Every append goes
--     through append_waypoint, because ai.driveUsingPath dislikes two identical consecutive targets.
--   * direct -- the custom graph has one node per route point, so a later lap runs the FULL node list
--     (1..#lap): its node 1 is a real node the closing edge leads back to, not a repeat of the previous
--     lap's last target.
-- Lap 1 starts at `first` in both variants: the car is NOT staged on the first drive target -- race/grid
-- lays the field out relative to the race's start POSE and an ADR-0023 custom grid may put it past the
-- start/finish node -- so the caller passes the first target ahead of the field (circuit.lead_skip). For
-- `direct` that index is additionally clamped to >= 2 by the caller, because ai.driveUsingPath's
-- getPointNodePath(ego.pos -> node 1) degenerates to a 1-node path when the car sits on node 1, which
-- newManualPath cannot plan from; the skipped node still lies on the initial car->node-2 path.
function window.append_lap(seq, n, out, out_pos)
    local from = (n == 1) and seq.first or seq.rest_start
    for i = from, #seq.lap do
        local before = #out
        if seq.dedup then
            append_waypoint(out, seq.lap[i])
        else
            out[#out + 1] = seq.lap[i]
        end
        if #out > before then
            out_pos[#out] = seq.lap_pos[i] or false
        end
    end
end

-- Append the sequence's END DECORATION to `out` -- settled work from ADR-0036's two amendments, delivered
-- in the last block and exactly once: the closed route's finish drive-through, or the open route's
-- overshoot past the finish. `snap` runs the existing helpers on the output list itself, so their dedup
-- and reachability base stays the list's last real target (which is lap[#lap] for every lap count) and
-- the ends land exactly where they always have. `direct`'s decoration was fixed at descriptor time --
-- its open-route overshoot is a synthetic node that has to exist in the custom map BEFORE the map is
-- installed. Tail targets carry no position: they are the last targets of the whole sequence, and once
-- they are armed there is nothing left to refill.
function window.append_tail(seq, out, out_pos)
    if #out == 0 then
        return
    end
    local before = #out
    if seq.variant == "direct" then
        for _, name in ipairs(seq.tail) do
            out[#out + 1] = name
        end
    elseif seq.closed then
        circuit.append_drive_through(out, seq.lap)
    else
        append_overshoot_waypoint(out, seq.route)
    end
    for i = before + 1, #out do
        out_pos[i] = false
    end
end

-- Materialise the shared sequence up to at least `upto` targets: whole laps until the count is reached or
-- the lap budget runs out, and -- only once it has run out -- the end decoration, which is what pins
-- `body` (the last real target) and `total`. Nothing beyond `upto` is ever built, so a qualifying supply
-- of 60 laps never costs more than the blocks actually in flight.
function window.ensure(seq, upto)
    while #seq.built < upto and seq.laps_built < seq.laps do
        seq.laps_built = seq.laps_built + 1
        window.append_lap(seq, seq.laps_built, seq.built, seq.built_pos)
    end
    if seq.laps_built >= seq.laps and not seq.tail_built then
        seq.tail_built = true
        seq.body = #seq.built
        window.append_tail(seq, seq.built, seq.built_pos)
        seq.total = #seq.built
    end
end

-- The nominal total the sequence would reach, for the route log line and the owner's chat notice while
-- the real total is still unknown (nothing past the first block has been materialised yet). Exact unless
-- a lap seam de-duplicates, which on a real route it does not.
function window.estimate(seq)
    local first_lap = math.max(0, #seq.lap - seq.first + 1)
    local later_lap = math.max(0, #seq.lap - seq.rest_start + 1)
    local tail = seq.tail and #seq.tail or (seq.closed and 2 or 1)
    return first_lap + (seq.laps - 1) * later_lap + tail
end

-- The sequence's LAST drive target -- the one the AI brakes on -- for the route diagnostic line. Exact
-- once the sequence has been materialised to its end; before that it is the PLANNED last target, which is
-- exact for every case except an open route driven over several laps (its overshoot waypoint is only
-- snapped when the final block is built, so the last real route target is reported instead).
function window.final_target(seq)
    if seq.total then
        return seq.built[seq.total]
    end
    if seq.variant == "direct" and seq.tail and #seq.tail > 0 then
        return seq.tail[#seq.tail]
    end
    if seq.closed and #seq.lap >= 2 then
        return seq.lap[2]
    end
    return seq.lap[#seq.lap]
end

-- The variant's drive command for a target list -- built by the UNCHANGED builders, so a sequence that
-- fits inside a single block emits exactly the string this module emitted before the window existed.
function window.command(seq, targets)
    if seq.variant == "direct" then
        return drive_command_wptargets(targets, seq.params)
    end
    local quoted = {}
    for _, name in ipairs(targets) do
        quoted[#quoted + 1] = string.format("%q", name)
    end
    return drive_command(table.concat(quoted, ", "), seq.params)
end

-- One AI car's live world position, or nil when its vehicle is gone. Live only (unlike
-- circuit.start_positions, which may fall back to the grid pose): the window measures where the car
-- actually is, and a stale grid pose would freeze the cursor at the start line.
function window.car_position(car)
    local veh = be and be:getObjectByID(car.veh_id)
    if not veh then
        return nil
    end
    local ok, live = pcall(function() return veh:getPosition() end)
    if ok and live and live.x then
        return {x = live.x, y = live.y, z = live.z}
    end
    return nil
end

-- The unit vector from `a` to `b`, or nil when the two (nearly) coincide and carry no direction.
function window.unit_between(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 0.01 then
        return nil
    end
    return {x = dx / length, y = dy / length, z = dz / length}
end

-- The unit direction of travel at target `index`: towards the next measurable target that is a real
-- distance away, or -- at the end of the list -- away from the previous one. nil when nothing usable
-- exists. Tolerates the `false` holes the tail leaves, unlike circuit.direction_at.
function window.dir_at(positions, count, index)
    local from = positions[index]
    if not from then
        return nil
    end
    for i = index + 1, count do
        if positions[i] then
            local dir = window.unit_between(from, positions[i])
            if dir then
                return dir
            end
        end
    end
    for i = index - 1, 1, -1 do
        if positions[i] then
            local dir = window.unit_between(positions[i], from)
            if dir then
                return dir
            end
        end
    end
    return nil
end

-- Whether a car at `position` counts as having reached drive target `index`: within REACH_RADIUS of it,
-- or projected past it along its own direction of travel while staying within REACH_LATERAL of that
-- line. An unmeasurable target (no position) counts as reached -- never let a car starve on a target the
-- host cannot see.
function window.reached(position, positions, count, index)
    local target = positions[index]
    if not target then
        return true
    end
    local dx, dy, dz = position.x - target.x, position.y - target.y, position.z - target.z
    local squared = dx * dx + dy * dy + dz * dz
    if squared <= REACH_RADIUS * REACH_RADIUS then
        return true
    end
    local dir = window.dir_at(positions, count, index)
    if not dir then
        return false
    end
    local ahead = dx * dir.x + dy * dir.y + dz * dir.z
    if ahead <= 0 then
        return false
    end
    return squared - ahead * ahead <= REACH_LATERAL * REACH_LATERAL
end

-- Walk a car's cursor forward over every armed target it has reached since the last tick.
function window.advance(entry, position)
    local seq = entry.seq
    while entry.cursor < entry.armed
        and window.reached(position, seq.built_pos, entry.armed, entry.cursor + 1) do
        entry.cursor = entry.cursor + 1
    end
end

-- The length (metres) of the armed route still ahead of a car: the path along its unreached targets.
-- Walks at most MAX_TOPUP_AHEAD positions, and skips the tail's position-less targets.
function window.armed_distance(entry)
    local positions = entry.seq.built_pos
    local total, prev = 0, nil
    for i = math.max(1, entry.cursor), entry.armed do
        local point = positions[i]
        if point then
            if prev then
                local dx, dy, dz = point.x - prev.x, point.y - prev.y, point.z - prev.z
                total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            prev = point
        end
    end
    return total
end

-- Whether this car needs a top-up now: a retry is pending, only the refill margin is still armed ahead of
-- it (for a full block that is exactly "reached target REFILL_AT of BLOCK_TARGETS"), or -- on a route
-- whose targets sit close together -- less than REFILL_DISTANCE of armed route is left while no more than
-- a block is still ahead. That last clause is the window's bound: a refill adds one block, so a car never
-- holds more than two blocks of unreached targets.
function window.needs_refill(entry)
    if entry.retry ~= nil then
        return true
    end
    local ahead = entry.armed - entry.cursor
    if ahead <= (BLOCK_TARGETS - REFILL_AT) then
        return true
    end
    if ahead > MAX_TOPUP_AHEAD then
        return false
    end
    return window.armed_distance(entry) < REFILL_DISTANCE
end

-- Queue one VE command on a car. Returns true, or false plus the reason.
function window.queue(car, command)
    local veh = be and be:getObjectByID(car.veh_id)
    if not veh then
        return false, "vehicle is gone"
    end
    local ok, err = pcall(function() veh:queueLuaCommand(command) end)
    if not ok then
        return false, tostring(err)
    end
    return true
end

-- Expand a block of drive targets into the CONTIGUOUS node path ai.setPath needs, starting on `from` --
-- the node the live route currently ends on (see the namespace header). The expansion runs GE-side with
-- the same pathfinder and the same parameters the VE would have used (map.getPath, drivability cutoff 0,
-- no direction penalty), so the appended path is the path ai.driveUsingPath would have built for those
-- targets. Every segment is verified rather than assumed: getFilteredPath returns a 1-element path for an
-- unreachable pair, and an unreachable pair is exactly what leaves an AI standing. Returns the node path,
-- or nil plus a reason -- never a partial one.
function window.expand(from, targets)
    if type(from) ~= "string" or from == "" then
        return nil, "no armed target to extend from"
    end
    if type(map) ~= "table" or type(map.getPath) ~= "function" then
        return nil, "navgraph API unavailable"
    end
    local path = {from}
    local prev = from
    for _, target in ipairs(targets) do
        local ok, segment = pcall(map.getPath, prev, target)
        if not ok or type(segment) ~= "table" or #segment < 2
            or segment[1] ~= prev or segment[#segment] ~= target then
            return nil, string.format("no navgraph path '%s' -> '%s'", tostring(prev), tostring(target))
        end
        for i = 2, #segment do
            path[#path + 1] = segment[i]
        end
        prev = target
    end
    return path
end

-- How many leading targets of a re-arm list this car already sits past -- the per-car form of
-- circuit.lead_skip. An ai.driveUsingPath re-arm plans from the car to its FIRST target, so a first
-- target BEHIND the car makes it turn around; the block cursor is a permissive estimate, so the reset
-- re-derives this from the car's own position instead of trusting it. Stops at the first target that is
-- still ahead (or carries no position), and never drops the last one -- the car must keep something to
-- drive to.
function window.drop_passed(targets, positions, position)
    local skip = 0
    while skip < #targets - 1 do
        local point = positions[skip + 1]
        if not point then
            break
        end
        local dir = window.dir_at(positions, #targets, skip + 1)
        if not dir or not circuit.passed(point, dir, {position}) then
            break
        end
        skip = skip + 1
    end
    return skip
end

-- The rest of a degraded car's sequence from `from`, as a FRESH list (targets + positions). Built into a
-- scratch list on purpose: the descriptor is shared, so one car's give-up must never truncate another
-- car's supply. Capped at back_laps -- the race lap count -- so a degraded car in a 60-lap qualifying
-- supply gets today's pre-window behaviour (run the race distance, then idle) instead of the
-- laps x targets runaway the window exists to avoid. The cap is never allowed to hand the car less than
-- one more full lap from where it stands.
function window.remaining(seq, from)
    local per_lap = math.max(1, #seq.lap)
    local budget = per_lap * math.max(1, seq.back_laps or seq.laps)
    window.ensure(seq, from + budget)
    local body = seq.body or #seq.built
    local upto = math.min(from + budget, body)
    local out, out_pos = {}, {}
    for i = from + 1, upto do
        out[#out + 1] = seq.built[i]
        out_pos[#out] = seq.built_pos[i]
    end
    -- Only a list that really runs to the end of the sequence carries the finish decoration.
    if upto >= body and seq.tail_built then
        window.append_tail(seq, out, out_pos)
    end
    return out, out_pos
end

-- The give-up fallback (R4, user decision): re-arm this ONE car with ai.driveUsingPath over its entire
-- remaining route and stop refilling it -- i.e. hand it today's pre-window behaviour. driveUsingPath is a
-- hard reset that re-plans from the car's live position, which is exactly what makes it survive a joint
-- that could not be extended. An AI is never left without a route; that is the single most important rule
-- in this feature, so this path sends something in every case it can and says loudly when it cannot.
function window.rearm(car, entry, position, reason)
    local seq = entry.seq
    entry.done = true
    entry.retry = nil
    local rest, rest_pos = window.remaining(seq, entry.cursor)
    if #rest == 0 then
        log("W", LOG_TAG, string.format(
            "AI '%s' route refill failed (%s) and nothing is left to re-arm; keeping its current route",
            tostring(car.label), tostring(reason)))
        return
    end
    local skip = window.drop_passed(rest, rest_pos, position)
    local targets = {}
    for i = skip + 1, #rest do
        targets[#targets + 1] = rest[i]
    end
    local sent, err = window.queue(car, window.command(seq, targets))
    if not sent then
        log("W", LOG_TAG, string.format("AI '%s' route re-arm could not be queued: %s",
            tostring(car.label), tostring(err)))
        return
    end
    entry.armed = entry.cursor + #rest
    log("W", LOG_TAG, string.format(
        "AI '%s' route refill gave up (%s): re-armed the whole remaining route with %d target(s) "
        .. "('%s' -> '%s', %d leading target(s) already passed) and stopped refilling it",
        tostring(car.label), tostring(reason), #targets, tostring(targets[1]),
        tostring(targets[#targets]), skip))
end

-- Top one car's armed route up by one block, seamlessly. Failure never sends a partial command: it
-- returns to the caller, which retries once on the next tick (the navgraph can legitimately be unready
-- for a frame after a reset) and then falls back to the full re-arm above.
function window.refill(car, entry, position)
    local seq = entry.seq
    window.ensure(seq, entry.armed + BLOCK_TARGETS)
    local upto = math.min(entry.armed + BLOCK_TARGETS, #seq.built)
    if upto <= entry.armed then
        -- Supply exhausted: the final block -- drive-through / overshoot included -- is already armed, and
        -- nothing may be armed after it. This is what makes the race stop exactly on its last lap.
        entry.done = true
        return
    end
    local block = {}
    for i = entry.armed + 1, upto do
        block[#block + 1] = seq.built[i]
    end
    local path, reason = window.expand(seq.built[entry.armed], block)
    if path then
        local quoted = {}
        for _, node in ipairs(path) do
            quoted[#quoted + 1] = string.format("%q", node)
        end
        local sent, err = window.queue(car,
            string.format("ai.setPath({%s})", table.concat(quoted, ", ")))
        if sent then
            entry.block = entry.block + 1
            log("I", LOG_TAG, string.format(
                "AI '%s' route refill: block %d, targets %d-%d of %s, '%s' -> '%s' (extend from '%s', "
                .. "%d node(s))",
                tostring(car.label), entry.block, entry.armed + 1, upto,
                seq.total and tostring(seq.total) or "an open supply",
                tostring(block[1]), tostring(block[#block]), tostring(seq.built[entry.armed]), #path))
            entry.armed = upto
            entry.retry = nil
            if seq.total and entry.armed >= seq.total then
                entry.done = true
            end
            return
        end
        reason = err
    end
    if not entry.retry then
        -- One retry on the next tick before giving up on the seamless path.
        entry.retry = reason
        log("W", LOG_TAG, string.format("AI '%s' route refill failed (%s); retrying next tick",
            tostring(car.label), tostring(reason)))
        return
    end
    window.rearm(car, entry, position, reason)
end
-- ===== end the rolling route window =============================================================

-- Arm BeamNG's vehicle AI to drive each car along the race route (ADR-0036 Step-3b). The route variant is
-- `params.route`: "snap" (default) routes over the per-point navgraph snap (resolve_waypoint_names +
-- wpTargetList, the on-road variant); "direct" installs a custom navgraph whose only road is the race line
-- (install_custom_race_map -> map.reset) and drives the EXACT authored line over it via the non-teleporting
-- ai.driveUsingPath{wpTargetList} (off-road capable, no road snap); an empty result spans the road
-- network so the car still drives. The lap sequence is laid out over the lap count (full-lap repeat +
-- closed-loop finish drive-through), then the drive command -- built from the resolved difficulty `params`
-- -- is queued to each car's VE (queueLuaCommand, the channel vehicles.set_vehicle_frozen uses).
--
-- Both route ends are geometry, not assumption. ai.driveUsingPath plans from the car to its FIRST target
-- (backwards, if that target is behind the field), brakes to a stop ON its LAST one (verified in BeamNG
-- lua/vehicle/ai.lua: the speed planner sets the final path node's speed to 0 when no node follows it),
-- and refuses to build ANY route -- leaving the car motionless all race -- if a single consecutive pair of
-- targets has no navgraph path.
--
-- The START of the route is pure GEOMETRY and belongs to every shape: circuit.lead_skip drops the leading
-- drive targets the field already sits past, whatever the race is scored as. `closed` says how the race is
-- SCORED and decides only the route's END; whether the ROUTE is a loop is a third, separate question (see
-- the circuit namespace). Keying the start on the scored mode is what made the AI reverse ~100 m on a
-- closed track run as a sprint -- the same conflation ADR-0036's round-2 amendment recorded for the finish.
-- The three real combinations differ only in their END:
--   * loop + circuit -- end one node PAST the finish line (the closing edge plus the node behind it, both
--     variants), because a circuit finishes ON the line and driveUsingPath brakes to a stop on its last
--     target;
--   * loop + sprint (the `sprint` mode override on a closed path) -- the finish is the route's LAST node,
--     not the line, so the closing repeat is dropped and the usual overshoot is extrapolated past that
--     last node instead of past the start/finish node;
--   * point-to-point + sprint -- the full route plus one synthetic overshoot target ~OVERSHOOT_DISTANCE
--     behind the finish (both variants). Its field stands behind its first target, so the geometric start
--     skip finds nothing to drop and the emitted command is unchanged.
-- Either way the AI accelerate away from the grid and cross their finish at speed instead of parking short
-- of the last checkpoint's trigger radius. pcall-guarded. A nil `params` uses the default preset.
--
-- The target list is armed in a ROLLING WINDOW (see the window namespace): at most BLOCK_TARGETS targets
-- go out now, and M.step_window tops each car up as it drives. `opts` carries that:
--   * opts.store      -- the caller's per-race window table keyed by AI id (init.lua M.state.ai_window).
--                        Without it nothing is registered and the whole sequence is armed at once.
--   * opts.backLaps   -- the lap count the give-up fallback caps a degraded car's route at (the RACE lap
--                        count; a qualifying supply is far longer than the race, and a fallback must not
--                        re-create the runaway the window exists to avoid).
-- A sequence that fits inside a single block is armed exactly as it was before the window existed, byte
-- for byte, and registers no window entry.
--
-- Returns a summary for the chat notice, incl. customMap=true when a custom navgraph was installed (the
-- caller restores the real one at teardown via M.restore_map).
function M.drive(cars, route, laps, params, closed, opts)
    if type(cars) ~= "table" then
        return
    end
    route = type(route) == "table" and route or {}
    params = type(params) == "table" and params or M.resolve_params(nil, nil)
    opts = type(opts) == "table" and opts or {}
    local lap_count = math.max(1, math.floor(tonumber(laps) or 1))

    -- A loop route scored as a SPRINT finishes on its own last node, not on the start/finish line, so its
    -- closing repeat goes before anything else reads the route: it decides the last drive target AND the
    -- point the finish overshoot is extrapolated past. A circuit keeps it (it is the finish crossing), and
    -- a point-to-point route has none.
    local loop = circuit.closes_loop(route)
    if loop and not closed then
        route = circuit.without_closing_repeat(route)
        log("I", LOG_TAG, string.format(
            "loop route scored as a sprint: dropped the closing repeat, %d route point(s) remain -- the "
            .. "AI finish on the last one, not on the start/finish line", #route))
    end

    local source, per_lap, seq
    local custom_map, span_only = false, false
    -- The route-end checks measure the drive targets against where the field actually stands.
    local starts = circuit.start_positions(cars)
    if params.route == "direct" then
        local nodes = build_route_nodes(route)
        -- The custom map's nodes ARE the route points, so the leading-target check runs on them directly.
        -- Geometry, so it runs for every route shape -- see the header.
        local skip = circuit.lead_skip(nodes, starts)
        -- perLap counts the real route nodes; the overshoot node below is a drive aid, not a lap stop.
        per_lap = #nodes
        -- The end decoration is fixed here, before the map is installed: on a closed loop the closing edge
        -- n->1 carries the AI across the finish and node 2 is the first node PAST it, and on an open route
        -- the overshoot is a SYNTHETIC node that has to be in the map by the time map.reset runs.
        local tail = {}
        if closed and #nodes > 1 then
            tail = {"bc1", "bc2"}
        elseif not closed then
            local appended = {}
            append_overshoot_node(nodes, appended)
            if appended[1] then
                tail = {"bc" .. appended[1]}
            end
        end
        local lap_names, lap_positions = {}, {}
        for i = 1, per_lap do
            lap_names[i] = "bc" .. i
            lap_positions[i] = nodes[i]
        end
        seq = window.new({
            variant = "direct", closed = closed, route = route, params = params,
            lap = lap_names, lap_pos = lap_positions,
            first = math.max(2, 1 + skip), rest_start = 1, dedup = false,
            laps = lap_count, back_laps = tonumber(opts.backLaps) or lap_count, tail = tail,
        })
        if not install_custom_race_map(nodes, closed) then
            -- No custom navgraph, no bc nodes to drive: span the road network so the car still moves.
            span_only = true
            source = "span"
        else
            source = "direct"
            custom_map = true
        end
    else
        -- The drive targets are the SNAPPED navgraph nodes, so the leading-target check runs on their own
        -- positions -- a snap can land a full edge away from the route point it came from, in EITHER
        -- direction (see resolve_waypoint_names). Geometry, so it runs for every route shape -- and on a
        -- sprint it is the only thing standing between a mis-snapped first target and a reversing AI.
        local lap_names, lap_positions = resolve_waypoint_names(route)
        local skip = circuit.lead_skip(lap_positions, starts)
        per_lap = #lap_names
        -- No target positions means no progress trigger, so no window either: cap the supply at the race
        -- lap count and arm it in one call, exactly as before, rather than a route nothing can refill.
        local measurable = (#lap_positions > 0) or (#lap_names == 0)
        if not measurable then
            log("W", LOG_TAG, "AI route window disabled: the drive targets carry no navgraph positions to "
                .. "measure progress against; arming the route in one call")
            lap_count = math.min(lap_count, math.max(1, tonumber(opts.backLaps) or lap_count))
        end
        seq = window.new({
            variant = "snap", closed = closed, route = route, params = params,
            lap = lap_names, lap_pos = lap_positions,
            first = 1 + skip, rest_start = 2, dedup = true, no_window = not measurable,
            laps = lap_count, back_laps = tonumber(opts.backLaps) or lap_count,
        })
        source = "navgraph-snap"
    end

    -- Materialise one block plus one target: the least that answers "does the whole sequence fit inside a
    -- single block?", and also what keeps a qualifying supply from being built up front.
    window.ensure(seq, seq.no_window and math.huge or (BLOCK_TARGETS + 1))
    local windowed = not span_only and not seq.no_window
        and (seq.total == nil or seq.total > BLOCK_TARGETS)
    local armed = windowed and BLOCK_TARGETS or (seq.total or #seq.built)
    local targets = {}
    if not span_only then
        for i = 1, armed do
            targets[i] = seq.built[i]
        end
    end
    local command = window.command(seq, targets)
    if #targets == 0 then
        source = "span"
    end
    local total = seq.total or window.estimate(seq)

    log("I", LOG_TAG, string.format(
        "AI route source=%s: %d node(s)/lap from %d route point(s), %d lap(s) -> %d total",
        source, per_lap, #route, lap_count, total))
    -- The route ends, spelled out: the two things that decide the target list (how the race is SCORED vs.
    -- what the ROUTE looks like) plus the first and last target the AI actually get. A standing-still or
    -- reversing AI is diagnosable from this one line -- no guessing from the outside.
    log("I", LOG_TAG, string.format(
        "AI route ends: scored as %s, loop route=%s, first target=%s, last target=%s",
        closed and "circuit" or "sprint", tostring(loop and true or false),
        tostring(seq.built[1]), tostring(window.final_target(seq))))
    if windowed then
        log("I", LOG_TAG, string.format(
            "AI route window: %d of %s target(s) armed per car, refilled at %d target(s) or %.0f m of "
            .. "route still ahead", armed, seq.total and tostring(seq.total) or "an open supply",
            BLOCK_TARGETS - REFILL_AT, REFILL_DISTANCE))
    end
    local store = type(opts.store) == "table" and opts.store or nil
    for _, car in ipairs(cars) do
        -- Drop any window this car carried from an earlier arming FIRST (a staged-quali relaunch re-arms
        -- one car at a time), so it can never be refilled against the route it drove on its last run.
        if store then
            store[car.id] = nil
        end
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            local ok, err = pcall(function() veh:queueLuaCommand(command) end)
            if not ok then
                log("W", LOG_TAG, "could not arm AI drive on '" .. tostring(car.label)
                    .. "': " .. tostring(err))
            else
                log("I", LOG_TAG, "armed AI drive on '" .. tostring(car.label) .. "'")
            end
            -- A sequence that fits inside one block needs no entry: there is nothing to refill.
            if store and windowed then
                store[car.id] = {seq = seq, armed = armed, cursor = 0, block = 1, done = false}
            end
        end
    end
    -- Summary for the owner's race-start chat notice (which route variant the AI actually got); customMap
    -- tells the caller a custom navgraph is live so it restores the real one at teardown (M.restore_map).
    return {source = source, perLap = per_lap, total = total, laps = lap_count, customMap = custom_map}
end

-- Per-frame, host only: walk each AI's progress through its armed block and top it up before it runs out
-- (the rolling route window). Called from the client tick in the racing and qualifying phases; inert
-- without a window store -- a non-host has none, and a route that fitted in a single block registers no
-- entry.
--
-- `held` is the qualifying hold set (init.lua M.state.quali_ai_held): once an AI's session is over it is
-- parked for the rest of the window (ADR-0041, bug quali-end-ai-not-frozen), so it is never refilled.
-- At most ONE car refills per call: a block expansion costs BLOCK_TARGETS shortest-path queries, and the
-- refill margin is hundreds of metres at racing speed, so spreading the work over frames is free.
function M.step_window(cars, store, held)
    if type(cars) ~= "table" or type(store) ~= "table" then
        return
    end
    local refilled = false
    for _, car in ipairs(cars) do
        local entry = store[car.id]
        if entry and not (held and held[car.id]) then
            local position = window.car_position(car)
            if position then
                window.advance(entry, position)
                if not entry.done and not refilled and window.needs_refill(entry) then
                    refilled = true
                    window.refill(car, entry, position)
                end
            end
        end
    end
end

-- The engine reported one vehicle's AI route done (init.lua M.onAiRouteDone, fired by the VE when the car
-- stops at the end of its path). For a windowed AI that is a FAILURE signal: reaching the end of a block
-- means the seamless extension did not take, and pathExtend is silent when its joint does not line up --
-- exactly the failure that looks like "the NPC just stopped". Re-arm the rest of its route and say so.
-- No-op for a car with no window, one that is already done (its race really is over), or a held one.
function M.route_done(cars, store, held, veh_id)
    if type(cars) ~= "table" or type(store) ~= "table" then
        return
    end
    for _, car in ipairs(cars) do
        if car.veh_id == veh_id then
            local entry = store[car.id]
            if entry and not entry.done and not (held and held[car.id]) then
                local position = window.car_position(car)
                if position then
                    log("W", LOG_TAG, string.format(
                        "AI '%s' ran its armed route out at target %d of %d -- the seamless refill did not "
                        .. "hold", tostring(car.label), entry.cursor, entry.armed))
                    window.rearm(car, entry, position, "armed route ran out")
                end
            end
            return
        end
    end
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

-- ===== Named AI driver pool (ADR-0047 roster + ADR-0048 file-defined pool) =====

-- Name -> driver definition {name, car, color}, built once from the driver file for O(1) pinned lookups
-- (M.resolve_pick). A malformed row (missing/empty name) is skipped; a duplicate name keeps the first.
local DRIVERS_BY_NAME = {}
for _, driver in ipairs(drivers) do
    if type(driver) == "table" and type(driver.name) == "string" and driver.name ~= ""
            and not DRIVERS_BY_NAME[driver.name] then
        DRIVERS_BY_NAME[driver.name] = driver
    end
end

-- The driver definition {name, car, color} for a name, or nil when the file has no such driver (ADR-0048):
-- a hand-typed or legacy roster name that is not in the file resolves to nil (the caller then rolls a car
-- and draws a fallback colour). Public so the pinned-pick GE endpoint can resolve a specific name.
function M.driver_by_name(name)
    if type(name) ~= "string" then
        return nil
    end
    return DRIVERS_BY_NAME[name]
end

-- Built-in colour palette for the named-AI roster (ADR-0047, round 3): ~18 bold, well-distinguishable
-- opaque hex strings (lowercase, no leading #). Each AI is painted in one of these as its PRIMARY paint
-- layer at spawn. Drawn without replacement per roster (>= 16 lets a full 16-AI field stay distinct); the
-- panel renders each as a swatch. The value is an opaque token -- the server never interprets it
-- (ADR-0005), it only relays it per slot; the client maps hex -> RGBA at spawn (race/vehicles). White,
-- near-black and silver are included as realistic car colours alongside the vivid hues.
local COLOR_PALETTE = {
    "e6194b", "f58231", "ffe119", "bfef45", "3cb44b", "469990",
    "42d4f4", "4363d8", "000075", "911eb4", "f032e6", "ff1493",
    "9a6324", "800000", "808000", "ffffff", "202020", "a0a0a0",
}

-- The colour palette, for the panel's swatch picker (ADR-0047). Same list the roster draw uses, so the
-- swatches and the auto-assigned colours come from one source and never drift.
function M.palette()
    return COLOR_PALETTE
end

-- The driver NAME list for the panel's name picker (ADR-0048): every driver name from the file,
-- deduplicated and sorted alphabetically. The editor picks a roster name from this dropdown instead of
-- free typing. Sourced from the mod-bundled driver file (the single pool source) -- no server round-trip.
function M.pool_names()
    local names = {}
    local seen = {}
    for _, driver in ipairs(drivers) do
        if type(driver) == "table" and type(driver.name) == "string" and driver.name ~= ""
                and not seen[driver.name] then
            names[#names + 1] = driver.name
            seen[driver.name] = true
        end
    end
    -- Case-insensitive, mirroring the roster list's own display sort (nameSortKey in BeamCompSetup), so the
    -- picker and the rows it fills read in the same order. This is a DISPLAY sort only: the roll/draw chain
    -- walks `drivers` directly, so the file order that defines the pool itself is untouched. The exact-tie
    -- fallback keeps the comparator a strict ordering for names differing only in case.
    table.sort(names, function(a, b)
        local lower_a, lower_b = a:lower(), b:lower()
        if lower_a == lower_b then
            return a < b
        end
        return lower_a < lower_b
    end)
    return names
end

-- Draw one palette colour not in `used` (a set of hex -> true), or -- when every palette colour is
-- already used (more AI than palette entries) -- any random palette colour so an entry always gets one.
-- Owner/panel-local, so math.random is fine (no cross-client determinism, like the name/car draws).
local function draw_color(used)
    local free = {}
    for _, hex in ipairs(COLOR_PALETTE) do
        if not used[hex] then
            free[#free + 1] = hex
        end
    end
    if #free > 0 then
        return free[math.random(#free)]
    end
    return COLOR_PALETTE[math.random(#COLOR_PALETTE)]
end

-- Draw `count` roster names without replacement from the driver file (ADR-0048), minus `exclude` (the
-- panel's existing roster names, exact match). Every driver carries a preferred car + preferred colour, so
-- every candidate does. The draw is uniform over the remaining drivers. Pool exhaustion (impossible in
-- practice: 64 names vs. max 16 AI) degrades to "AI <k>" fallback names + a log instead of failing the
-- roll. Returns a list of {name, preferred, preferredColor}.
function M.draw_roster_names(count, exclude)
    local taken = {}
    if type(exclude) == "table" then
        for _, name in ipairs(exclude) do
            taken[name] = true
        end
    end
    local candidates = {}
    for _, driver in ipairs(drivers) do
        if type(driver) == "table" and type(driver.name) == "string" and driver.name ~= ""
                and not taken[driver.name] then
            candidates[#candidates + 1] = {
                name = driver.name, preferred = driver.car, preferredColor = driver.color,
            }
            taken[driver.name] = true
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

-- Whether a pool name's PREFERRED CAR participates in a roster roll (ADR-0047 amendment R2): it replaces
-- a car ONLY in the "default" AI-car mode (aicar unset/empty). aicar=random now IGNORES the preferred car
-- and rolls a fresh random one (the R2 flip -- default = each AI's preferred, random = surprise field); an
-- explicit concrete admin choice -- a fixed aicar=<model> or aicar=host -- stays authoritative as before.
-- Colour is orthogonal and stays always-applied (round-3), so this gate is the CAR precedence only.
function M.preferred_applies(config)
    local car = type(config) == "table" and config.car or nil
    return car == nil or car == ""
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
    -- A preferred car that is not a race car at all never applies, whatever the caps say -- the driver
    -- file is hand-edited, and a prop/traffic model slipping into it must not reach a grid slot. The
    -- caller then rolls a car instead, exactly as it does for a cap-violating preference.
    if vehiclespecs.is_known_non_car(model) then
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

-- Whether a roster car token no longer points at a race car and must be re-rolled (ADR-0047 amendment
-- 2026-08-09). True ONLY for a KNOWN non-race model -- a prop, trailer, traffic filler or debug rig that
-- was pickable when the preset was saved and is not offered any more.
--
-- Everything else answers false, and each "no" is deliberate:
--   * "host" is a sentinel resolved at spawn, not a model;
--   * an absent/empty token is a row without a car, which falls through the AI-car chain at spawn and is
--     the admin's business, not a broken pick;
--   * a model the engine cannot read -- an uninstalled mod, or core_vehicles not being ready yet -- is
--     KEPT. That is the R5 rule (only a known non-car is ever removed) and it is what makes the check
--     safe to run at panel-restore time: the worst case is that a repair is missed, never that a valid
--     hand-tuned roster is overwritten because the metadata was momentarily unavailable.
function M.roster_car_needs_reroll(token)
    if type(token) ~= "string" or token == "" or token == "host" then
        return false
    end
    local model = split_car_token(token)
    return model ~= nil and vehiclespecs.is_known_non_car(model)
end

-- Re-roll the cars of the roster entries whose token is no longer a race car (ADR-0047 amendment
-- 2026-08-09). `entries` is the panel's roster as {name, car} pairs; returns ONLY the rows that changed,
-- as {name, from, car, carLabel} -- an empty list means the roster was already fine.
--
-- The replacement comes from M.roll_roster_car, the same chain a normal roll and the spawn use, so a
-- repaired row is indistinguishable from a rolled one (carLabel included) and ADR-0047's "one resolution
-- chain" still holds. `from` lets the caller apply the fix only to the exact token that was vetted, so a
-- manual pick landing in between is not overwritten.
--
-- A replacement that is itself not a race car is only reachable when the admin's own aicar= names one (the
-- typed escape hatch, which the chain honours on purpose). Reporting that as a "repair" would swap one
-- non-car for another, so the row is left alone with a warning instead.
function M.repair_roster_cars(entries, config, policy)
    local repaired = {}
    if type(entries) ~= "table" then
        return repaired
    end
    for index, entry in ipairs(entries) do
        -- The same 16-AI ceiling the roll paths clamp to: one repair can never cost more than a create.
        if index > 16 then
            break
        end
        if type(entry) == "table" and M.roster_car_needs_reroll(entry.car) then
            local car = M.roll_roster_car(config, policy, index)
            if M.roster_car_needs_reroll(car) then
                log("W", LOG_TAG, string.format(
                    "roster repair: '%s' has %s, but the AI car setting rolls %s -- leaving it",
                    tostring(entry.name), tostring(entry.car), tostring(car)))
            else
                log("I", LOG_TAG, string.format("roster repair: '%s' had %s (no longer a race car) -> %s",
                    tostring(entry.name), tostring(entry.car), tostring(car)))
                repaired[#repaired + 1] = {
                    name = entry.name,
                    from = entry.car,
                    car = car,
                    carLabel = M.car_label(car),
                }
            end
        end
    end
    return repaired
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

-- Resolve one drawn candidate ({name, preferred, preferredColor}) to a full roster entry
-- {name, car, carLabel, color} (ADR-0047/0048). Car: the name's preferred car when the row's car would be
-- rolled at all (preferred_applies) and it passes the active restrictions (preferred_car_compliant), else a
-- car rolled through the spawn chain (roll_roster_car). Colour: the name's preferred colour ALWAYS when it
-- carries one (colour is unrestricted -- no compliance, ADR-0047 round 3), else a palette colour drawn
-- without replacement across `used`. `index` cycles content defaults if they ever apply; `used` is the
-- colour set for the fallback draws. Shared by roll_roster_entries (random names) and resolve_pick (a
-- pinned name), so the two never drift.
local function entry_from_drawn(drawn, config, policy, index, used)
    local car
    if drawn.preferred and M.preferred_applies(config)
            and M.preferred_car_compliant(drawn.preferred, config, policy) then
        car = drawn.preferred
    else
        car = M.roll_roster_car(config, policy, index)
    end
    local color = drawn.preferredColor or draw_color(used)
    used[color] = true
    return {name = drawn.name, car = car, carLabel = M.car_label(car), color = color}
end

-- Roll `count` full roster entries for the panel (ADR-0047/0048): draw unique driver names from the file
-- (minus `exclude`), then resolve each to a car + colour via the shared entry_from_drawn. Colours are drawn
-- without replacement across this batch AND `exclude_colors` (the panel's existing roster colours, so an
-- extend stays distinct from the kept entries) -- though every file driver carries a preferred colour, so
-- the fallback draw only fires for a hand-added name without one. Returns a list of
-- {name, car, carLabel, color} ready for the panel.
function M.roll_roster_entries(count, exclude, config, policy, exclude_colors)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    local used = {}
    if type(exclude_colors) == "table" then
        for _, hex in ipairs(exclude_colors) do
            used[hex] = true
        end
    end
    local entries = {}
    for k, drawn in ipairs(M.draw_roster_names(count, exclude)) do
        entries[k] = entry_from_drawn(drawn, config, policy, k, used)
    end
    return entries
end

-- Resolve a specific PINNED driver name to a full roster entry {name, car, carLabel, color} (ADR-0048) --
-- the name-pick load path. Unlike draw_roster_names this does NOT draw randomly: it looks the name up in the
-- driver file and applies the SAME car/colour rules as a rolled entry (entry_from_drawn), so default mode ->
-- the driver's preferred car (when compliant) + preferred colour, and random mode (config.car == "random")
-- -> a freshly rolled car + the preferred colour (Q3: only the car varies by mode). The car+colour it
-- returns always overwrite the row's prior manual selection (Q2). A name absent from the file resolves too:
-- no preferred car -> a rolled car, no preferred colour -> a palette colour. Returns the entry table.
function M.resolve_pick(name, config, policy)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    local driver = M.driver_by_name(name)
    local drawn = {
        name = name,
        preferred = driver and driver.car or nil,
        preferredColor = driver and driver.color or nil,
    }
    return entry_from_drawn(drawn, config, policy, 1, {})
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
