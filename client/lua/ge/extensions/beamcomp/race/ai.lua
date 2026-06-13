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
-- knob; skill/rubberband/avoidCars/speedMode are layered as guarded VE calls (spike, see drive_command).
local PRESETS = {
    easy = {aggression = 0.35, skill = 0.5, rubberband = 0, avoidCars = true, speedMode = "limit"},
    medium = {aggression = 0.6, skill = 0.75, rubberband = 0, avoidCars = true, speedMode = "off"},
    hard = {aggression = 0.95, skill = 1.0, rubberband = 0, avoidCars = true, speedMode = "off"},
}
local DEFAULT_PRESET = "medium"

-- Resolve the effective AI driving parameters for a race (ADR-0036 Etappe B). Precedence per parameter:
-- explicit ai*= override (config.params) -> the named preset (config.preset) -> the aiRace content
-- defaults (content_defaults, only when no preset was given) -> the built-in default preset. Returns a
-- params table {aggression, skill, rubberband, avoidCars, speedMode} the drive command reads.
function M.resolve_params(config, content_defaults)
    config = type(config) == "table" and config or {}
    content_defaults = type(content_defaults) == "table" and content_defaults or {}
    local preset = PRESETS[config.preset] or PRESETS[DEFAULT_PRESET]
    local params = {
        aggression = preset.aggression,
        skill = preset.skill,
        rubberband = preset.rubberband,
        avoidCars = preset.avoidCars,
        speedMode = preset.speedMode,
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
    if overrides.speed ~= nil then
        params.speedMode = overrides.speed
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

-- Resolve one AI car's {model, config} via the Etappe-B fallback chain (ADR-0036). Precedence: explicit
-- aicar= (config.car) -> the player vehicle policy (ADR-0032: Mode 2 fixed car / Mode 3 cap-compliant car;
-- Mode 1 = no policy falls through) -> the aiRace content default vehicle(s) -> a random stock model.
-- `index` (1-based) cycles the content vehicle list so multiple AI vary. Returns (model, config).
local function resolve_ai_vehicle(config, content_defaults, policy, index)
    config = type(config) == "table" and config or {}
    policy = type(policy) == "table" and policy or {}
    content_defaults = type(content_defaults) == "table" and content_defaults or {}

    if config.car then
        local model, vehicle_config = split_car_token(config.car)
        if model then
            return model, vehicle_config
        end
    end

    if policy.car then
        return split_car_token(policy.car)
    end
    if policy.maxhp or policy.maxpwr then
        local pick = vehiclespecs.find_compliant(nil, policy.maxhp, policy.maxpwr)
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

    return random_stock_model(), nil
end

-- Spawn one host-owned AI car per slot at its grid pose (ADR-0036). `ai_slots` is the owner's relayed
-- list of {slot, id, label}; `grid_poses` is the full resolved grid (race/start). Each car's vehicle is
-- resolved via the Etappe-B fallback chain (resolve_ai_vehicle) from the relayed `config`/`content_defaults`
-- (ADR-0036 Etappe B) and the player `policy` (ADR-0032). Returns a list of spawned cars
-- {id, slot, label, veh_id}; a slot whose spawn fails is logged and skipped (the field degrades to fewer
-- AI rather than aborting). BeamMP propagates each spawn to all clients.
function M.spawn(ai_slots, grid_poses, config, content_defaults, policy)
    local cars = {}
    if type(ai_slots) ~= "table" or type(grid_poses) ~= "table" then
        return cars
    end
    for index, slot_info in ipairs(ai_slots) do
        local pose = grid_poses[(slot_info.slot or 0) + 1]
        if not pose then
            log("W", LOG_TAG, "no grid pose for AI slot " .. tostring(slot_info.slot))
        else
            local model, vehicle_config = resolve_ai_vehicle(config, content_defaults, policy, index)
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
-- rubberband, avoidCars and a non-default speedMode have no stable ai.driveUsingPath argument across
-- engine versions, so each is emitted as its own pcall-wrapped call: pcall(ai.setX, v) is safe even when
-- ai.setX is nil (pcall catches the nil-call), so a missing API no-ops instead of breaking the proven
-- drive. Returns a "; "-joined call list (possibly empty). rubberband is only emitted when > 0 (off by
-- default in every preset).
--
-- In-game effectiveness on BeamNG 0.38.5 (2-client handover, 2026-06-13): `aggression` and `avoidCars`
-- have a clear visible effect; `aiskill=` has NO visible effect (kept exposed as best-effort, but the
-- real difficulty knob is aggression); `aispeed=` (speedMode) is unverified and likely inert without a
-- companion target speed (ai.setSpeed, not wired). See memory beamcomp-ai-driving-findings.
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
    if params.speedMode and params.speedMode ~= "off" then
        calls[#calls + 1] = string.format("pcall(ai.setSpeedMode, %q)", params.speedMode)
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

-- Arm BeamNG's vehicle AI to drive each car along the race route (SPIKE #1, ADR-0036). Resolves
-- the route to navgraph waypoint names GE-side, lays them out over the lap count
-- (lay_out_lap_waypoints), then queues the drive command -- built from the resolved difficulty `params`
-- (ADR-0036 Etappe B) -- to each car's VE (queueLuaCommand, the channel vehicles.set_vehicle_frozen
-- uses). BeamNG's noOfLaps does not loop a wpTargetList (verified in-game), so every lap is laid out
-- explicitly. pcall-guarded. A nil `params` falls back to the default preset so the call is always safe.
function M.drive(cars, route, laps, params)
    if type(cars) ~= "table" or type(route) ~= "table" then
        return
    end
    params = type(params) == "table" and params or M.resolve_params(nil, nil)
    local lap_count = math.max(1, math.floor(tonumber(laps) or 1))
    local lap_names = resolve_waypoint_names(route)
    local names = lay_out_lap_waypoints(lap_names, lap_count)
    local quoted = {}
    for _, name in ipairs(names) do
        quoted[#quoted + 1] = string.format("%q", name)
    end
    local command = drive_command(table.concat(quoted, ", "), params)
    log("I", LOG_TAG, string.format(
        "AI route: %d waypoint(s)/lap from %d point(s), %d lap(s) -> %d total",
        #lap_names, #route, lap_count, #names))
    log("I", LOG_TAG, string.format(
        "AI lap layout: lap_count=%d, lap_names=[%s]",
        lap_count, table.concat(lap_names, ", ")))
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
