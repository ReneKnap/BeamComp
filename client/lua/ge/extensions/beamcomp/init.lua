-- BeamComp -- client GE (Game-Engine) extension.
--
-- Lives at lua/ge/extensions/beamcomp/init.lua inside the client mod zip and loads under
-- the name `beamcomp_init` (brought up by scripts/beamcomp/modScript.lua). The GE VM owns
-- the scene, level, UI, camera, and vehicle spawning, and is where the BeamMP client<->
-- server messaging endpoint lives.
--
-- Receives server->client events on the "beamcompEvent" channel (ADR-0004: the name is
-- colon-free because the BeamMP client parser splits names on ':'). Each event is a JSON
-- envelope { type, payload }; we decode it with the shared envelope module and dispatch on
-- `type` (ADR-0004). Handled types:
--   ping       -- diagnostic; surfaces a toast.
--   raceStart  -- resolve + parse the race locally, compute this client's grid start pose
--                 (race/start + race/grid), draw the grid markers (onPreRender), respawn this
--                 client's own car fresh at its assigned grid pose (race/vehicles), and load the
--                 race's static-scenery prop prefab(s) into the scene (race/props). The knockable
--                 cones are shared: the payload's propOwner client keeps the set its load spawns
--                 (BeamMP syncs it to everyone), and the cones are kept non-enterable / out of the
--                 Tab cycle on every client via race/cones (ADR-0009).
--   racePhase  -- the server-authoritative race phase (lobby/spawning/countdown/racing/finished,
--                 ADR-0006). We record + surface it, and drive the start lock off it: the car is
--                 spawned frozen (handle_race_start) and held through the countdown, released on
--                 racing, with a defensive release on lobby. The synced 3-2-1-GO! countdown UI
--                 runs off the same phases (race/countdown + ADR-0008): countdown starts the
--                 count, racing shows GO! on the release, lobby/reload clears it. The racing phase
--                 also arms the local checkpoint detector (race/checkpoints, ADR-0010), stepped each
--                 frame in onUpdate, which surfaces each passed checkpoint as a toast + log line.

local M = {}

local envelope = require("beamcomp/envelope")
local race_start = require("beamcomp/race/start")
local vehicles = require("beamcomp/race/vehicles")
local props = require("beamcomp/race/props")
local cones = require("beamcomp/race/cones")
local countdown = require("beamcomp/race/countdown")
local checkpoints = require("beamcomp/race/checkpoints")

local EVENT_CHANNEL = "beamcompEvent"
local LOG_TAG = "beamcomp.net"
local RACE_LOG_TAG = "beamcomp.race"

local MARKER_RADIUS = 0.6
local MARKER_LIFT = 1.0  -- raise the sphere off the ground so it stays visible

-- Reload-surviving state (BeamNG serializes M.state across a Lua reload).
M.state = {
    last_event_at = 0,
    registered = false,
    race = nil,          -- current race-start state (slot, poses, roster) or nil
    phase = nil,         -- current server-authoritative race phase (ADR-0006) or nil
    marker_warned = false,
    prop_names = nil,    -- names of the prop prefabs we spawned, for cleanup (or nil)
    cone_ids = nil,      -- ids of the shared cone vehicles we own + must clear (owner only, ADR-0009)
    current_vehicle_id = nil,  -- game id of the vehicle the player is in, tracked via onVehicleSwitched
    detection = nil,     -- checkpoint-detection progress (race/checkpoints), armed on the racing phase
    standings = nil,     -- latest server-broadcast ranked standings entries, or nil
}

local function handle_ping(_payload)
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Server event: ping",
    })
end

-- Resolve + lay out the race for this client, store the state, and surface the slot. On any
-- failure (the server cannot validate the name, ADR-0005) warn and toast the reason.
local function handle_race_start(payload)
    local race, reason = race_start.prepare(payload)
    if not race then
        log("W", RACE_LOG_TAG, "raceStart ignored: " .. tostring(reason))
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = "Race not started: " .. tostring(reason),
        })
        return
    end

    M.state.race = race
    M.state.marker_warned = false
    -- Reset checkpoint detection and any stale standings; both are refreshed during the race (the
    -- abort-restart path is finished -> spawning, skipping the lobby reset, so clear them too).
    M.state.detection = nil
    M.state.standings = nil

    -- Resolve the car the player is in, preferring the onVehicleSwitched-tracked id (the polling API
    -- be:getPlayerVehicle(0) sticks to the first owned car in BeamMP). Resolve BEFORE loading props
    -- so the choice is taken before any prop-vehicle churn.
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)

    -- Load the race's static-scenery prefab(s) BEFORE the vehicle respawn, so the fresh car's
    -- spawn + auto-enter stays the LAST scene action and the player lands seated in it. Loading
    -- props after the respawn left the player's camera latched onto a prop (a pylon) instead of
    -- the car. Clear first so re-issuing /race never stacks duplicates; placement is client-local
    -- + deterministic (see race/props.lua). The knockable cones are shared (ADR-0009): only the
    -- propOwner keeps the set its load creates (cone_ids, cleared here on re-issue too); the
    -- abort/restart path skips the lobby branch, so clearing here is what prevents owner stacking.
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names, M.state.cone_ids = props.load(race.prefabFiles or {}, payload.propOwner)

    -- Place this client's own car at the assigned grid pose: the car the player is in is repaired +
    -- teleported in place (preserving its settings), or a fresh one is spawned as a fallback
    -- (ADR-0007). Owned-only + BeamMP-propagated (see race/vehicles.lua). The grid markers keep
    -- rendering from M.state.race regardless.
    local race_car, respawn_err = vehicles.respawn_own_at(race.myPose, own_car)
    if race_car then
        -- Re-assert the player into the race car. Harmless when they are already seated (kept-car
        -- path); on the fresh-spawn fallback this guarantees seating even if a prop-vehicle slipped
        -- past the auto-enter race rather than leaving the player on a prop.
        if be then
            pcall(function() be:enterVehicle(0, race_car) end)
        end
        -- Spawn/place the car frozen: hold it from race start through the countdown so nobody can
        -- jump the start (released on the racing phase, see handle_race_phase). Freeze the resolved
        -- handle directly: on the fallback the spawn settles over later frames, so the command must
        -- be queued to this exact vehicle's VE.
        local frozen, freeze_err = vehicles.set_vehicle_frozen(race_car, true)
        if not frozen then
            log("W", RACE_LOG_TAG, "could not freeze race car: " .. tostring(freeze_err))
        end
        log("I", RACE_LOG_TAG, string.format("placed at grid slot %d", race.mySlot))
    else
        log("W", RACE_LOG_TAG, "race-car placement skipped: " .. tostring(respawn_err))
    end

    log("I", RACE_LOG_TAG, string.format("race '%s': you are slot %d", race.name, race.mySlot))
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp -- " .. race.name,
        msg = string.format("Slot %d -- start (%.0f, %.0f, %.0f)",
            race.mySlot, race.myPose.pos.x, race.myPose.pos.y, race.myPose.pos.z),
    })
end

-- Record the server-authoritative race phase, drive the start lock off it, and surface it. The
-- server broadcasts a racePhase on every transition (ADR-0006). The car is spawned frozen in
-- handle_race_start and held through the countdown; here we release it on racing, and release
-- defensively on lobby (the car is preserved in place, only unlocked). The countdown UI is driven
-- off the same phases via race/countdown (ADR-0008): countdown starts the count, racing shows GO!.
local function handle_race_phase(payload)
    local phase = type(payload) == "table" and payload.phase or nil
    if type(phase) ~= "string" then
        log("W", RACE_LOG_TAG, "racePhase ignored: missing phase")
        return
    end

    M.state.phase = phase
    log("I", RACE_LOG_TAG, "race phase -> " .. phase)

    if phase == "countdown" then
        -- Start the synced 3-2-1 count off the server-issued duration (built-in flash surface).
        countdown.show_countdown(payload.duration)
    elseif phase == "racing" then
        -- Countdown over: show GO! (server-authoritative, so it lands exactly on the release)
        -- and release the start lock so the car can drive.
        countdown.show_go()
        local released, release_err = vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
        if not released then
            log("W", RACE_LOG_TAG, "could not release start lock: " .. tostring(release_err))
        end
        -- Arm checkpoint detection now the lock is released: it tests the local car against the
        -- next expected checkpoint each frame (onUpdate) while racing (ADR-0010).
        M.state.detection = checkpoints.new()
    elseif phase == "lobby" then
        -- Race over (back to lobby): clear any countdown overlay, despawn the track props and stop
        -- drawing the grid markers, but leave the player's vehicle exactly where it is -- never
        -- despawn or move it. Release the start lock too, so a /raceend mid-countdown leaves the
        -- preserved car drivable. The abort-restart path skips lobby (finished -> spawning), where
        -- handle_race_start reloads props and re-freezes instead.
        countdown.clear()
        props.clear(M.state.prop_names or {})
        cones.clear(M.state.cone_ids or {})
        M.state.prop_names = nil
        M.state.cone_ids = nil
        M.state.race = nil
        M.state.detection = nil
        M.state.standings = nil
        vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    end

    -- Surface the phase as a toast, except countdown/racing -- the countdown UI covers those.
    if phase ~= "countdown" and phase ~= "racing" then
        guihooks.trigger("toastrMsg", {
            type = "info",
            title = "BeamComp",
            msg = "Race phase: " .. phase,
        })
    end
end

-- Store the latest server-broadcast standings for the HUD to render (item 5). Receive and store
-- only -- no rendering here. The summary log lets a single client confirm the path and the payload.
local function handle_standings(payload)
    local entries = type(payload) == "table" and payload.entries or nil
    if type(entries) ~= "table" then
        log("W", LOG_TAG, "standings ignored: missing entries")
        return
    end

    M.state.standings = entries

    local leader = entries[1]
    if not leader then
        log("I", RACE_LOG_TAG, "standings: 0 entries")
        return
    end

    local progress = tostring(leader.completed)
    if leader.count then
        progress = progress .. "/" .. tostring(leader.count)
    end
    log("I", RACE_LOG_TAG, string.format("standings: %d entr%s -- leader %s %s @ %.2fs",
        #entries, #entries == 1 and "y" or "ies", tostring(leader.name), progress,
        tonumber(leader.total_time) or 0))
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
    standings = handle_standings,
}

-- Handle one server->client event. `data` arrives as a JSON string -- the BeamMP client
-- delivers event payloads as strings, regardless of how the server sent them.
local function on_server_event(data)
    local message_type, payload = envelope.decode(data)
    if not message_type then
        -- On failure envelope.decode returns (nil, error_message).
        log("W", LOG_TAG, "dropped malformed server event: " .. tostring(payload))
        return
    end

    M.state.last_event_at = os.time()

    local handler = HANDLERS[message_type]
    if not handler then
        log("W", LOG_TAG, "no handler for server event type=" .. message_type)
        return
    end

    log("I", LOG_TAG, "server event type=" .. message_type)
    handler(payload)
end

-- Draw a debug sphere + label at every grid pose (own slot highlighted). Immediate-mode:
-- redrawn each frame from M.state, so there are no scene objects to clean up -- clearing
-- M.state.race removes the markers.
local function draw_grid_markers(race)
    local mine = ColorF(0.2, 1.0, 0.3, 1.0)
    local other = ColorF(1.0, 0.8, 0.1, 0.7)
    local centers = {}
    for index, pose in ipairs(race.gridPoses) do
        local center = vec3(pose.pos.x, pose.pos.y, pose.pos.z + MARKER_LIFT)
        centers[index] = center
        local slot = index - 1
        debugDrawer:drawSphere(center, MARKER_RADIUS, (slot == race.mySlot) and mine or other)
    end

    -- Labels last + lower-confidence API: if drawTextAdvanced/ColorI mismatch here, the
    -- spheres above have already drawn this frame (the onPreRender pcall warns once).
    local label_fg = ColorF(1, 1, 1, 1)
    local label_bg = ColorI(0, 0, 0, 255)
    for index, center in ipairs(centers) do
        local slot = index - 1
        local entry = race.roster[index]
        local name = entry and entry.name
        local label = name and ("P" .. slot .. " " .. name) or ("P" .. slot)
        debugDrawer:drawTextAdvanced(center, label, label_fg, true, false, label_bg)
    end
end

-- Register the server->client handler. AddEventHandler is a GE global provided by BeamMP's
-- MPGameNetwork, which may not be loaded yet when this extension comes up, so registration
-- is retried from onUpdate until it sticks. The handler is a plain function value plus a
-- stable source name ("beamcomp") -- re-registering from the same name patches in place, so
-- a Lua reload never stacks duplicate handlers.
local function ensure_registered()
    if M.state.registered then
        return
    end
    if not AddEventHandler then
        return
    end
    AddEventHandler(EVENT_CHANNEL, on_server_event, "beamcomp")
    M.state.registered = true
    log("I", LOG_TAG, "registered handler on channel " .. EVENT_CHANNEL)
end

function M.onExtensionLoaded()
    -- Keep the extension across level/scenario switches (a race spans a level).
    setExtensionUnloadMode(M, "manual")
    envelope.set_codec(jsonEncode, jsonDecode)
    -- A Lua reload drops BeamMP's handler table, so always re-register from a clean slate
    -- rather than trusting the serialized flag.
    M.state.registered = false
    ensure_registered()
    -- Seed the current-vehicle tracker; onVehicleSwitched keeps it current from here on.
    if be and be:getPlayerVehicle(0) then
        M.state.current_vehicle_id = be:getPlayerVehicle(0):getId()
    end
    log("I", LOG_TAG, "loaded")
end

-- Track the vehicle the player is currently in, and keep them out of the shared cones. BeamNG fires
-- onVehicleSwitched(old, new) on every switch; we keep the latest non-cone `new` as the
-- authoritative seated car, because in BeamMP the polling API be:getPlayerVehicle(0) sticks to the
-- first owned car -- so race/vehicles.lua resolve_own_car prefers this tracked id (confirmed
-- in-game). If the player switches into a cone (Tab cycle or auto-enter), bounce them straight back
-- to the last real car and do NOT record the cone -- the guaranteed non-enterable layer (ADR-0009).
function M.onVehicleSwitched(_oldId, newId)
    if cones.is_cone(be and be:getObjectByID(newId)) then
        cones.enforce_non_enterable(newId, M.state.current_vehicle_id)
        return
    end
    M.state.current_vehicle_id = newId
end

-- Keep the shared cones out of the Tab vehicle cycle as they appear: the owner's local set when its
-- prefab load spawns them, and the remote synced set on every other client (BeamMP vehicle spawns
-- fire this hook too). Best-effort exclusion layer; the onVehicleSwitched bounce is the guarantee
-- (ADR-0009).
function M.onVehicleSpawned(vehicleId)
    if not be then
        return
    end
    cones.exclude_from_cycle(be:getObjectByID(vehicleId))
end

-- Send a typed { type, payload } envelope to the server -- the client->server mirror of the server's
-- send_event (ADR-0004, ADR-0011). Encode via the shared module (the client already loads it for
-- decode), then ship the string with TriggerServerEvent, a GE global present only inside an MP
-- session. Reliable + ordered TCP, so fire-and-forget. Generic so later client->server messages (e.g.
-- spawn-ready acks) reuse it.
local function send_to_server(message_type, payload)
    if not TriggerServerEvent then
        return
    end
    local ok, encoded = pcall(envelope.encode, message_type, payload)
    if not ok then
        log("W", LOG_TAG, "could not encode '" .. message_type .. "' for server: "
            .. tostring(encoded))
        return
    end
    local sent, err = pcall(TriggerServerEvent, EVENT_CHANNEL, encoded)
    if not sent then
        log("W", LOG_TAG, "TriggerServerEvent failed for '" .. message_type .. "': "
            .. tostring(err))
    end
end

-- Surface one detected checkpoint passage: log + toast + report to the server. This is the single
-- emission seam for a passage -- keep it the one place a passage is reported. `count` is the race's
-- total checkpoint count, sent so the race-blind server (ADR-0005) can derive progress (index+1 of
-- count) and recognize the final crossing without parsing the race (ADR-0011).
local function on_checkpoint_reached(event, count)
    log("I", RACE_LOG_TAG, string.format("checkpoint %d (%s) reached @ %.2fs",
        event.index, tostring(event.name), event.time))
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp",
        msg = string.format("Checkpoint %d reached @ %.1fs", event.index, event.time),
    })
    send_to_server("checkpoint", {
        index = event.index,
        name = event.name,
        time = event.time,
        count = count,
    })
end

-- Step the checkpoint detector for one racing frame: resolve this client's own car (the tracked
-- seated id, BeamMP-correct -- see race/vehicles.lua), read its world position, and advance the
-- detector. Emits each crossed checkpoint through on_checkpoint_reached. No-op until armed
-- (M.state.detection set on the racing phase) and once the sequence is done.
local function step_detection(dt_sim)
    local detection = M.state.detection
    local race = M.state.race
    if not detection or detection.done or not race or not race.checkpoints then
        return
    end

    local veh_pos = nil
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if own_car then
        local ok, pos = pcall(function() return own_car:getPosition() end)
        if ok then
            veh_pos = pos
        end
    end

    local event = checkpoints.step(detection, race.checkpoints, veh_pos, dt_sim)
    if event then
        on_checkpoint_reached(event, #race.checkpoints)
    end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
    if M.state.phase == "racing" then
        step_detection(dtSim)
    end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
    local race = M.state.race
    if not race or not debugDrawer then
        return
    end
    -- Guard the draw: debugDrawer's exact API is runtime-confirmed here, so a mismatch
    -- warns once rather than spamming every frame.
    local ok, err = pcall(draw_grid_markers, race)
    if not ok and not M.state.marker_warned then
        M.state.marker_warned = true
        log("W", RACE_LOG_TAG, "grid marker draw failed (debugDrawer API?): " .. tostring(err))
    end
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    countdown.clear()
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.race = nil
    M.state.detection = nil
    -- Release the start lock so a reload mid-countdown never leaves a stuck-frozen car.
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

return M
