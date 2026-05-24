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
--                 race's static-scenery prop prefab(s) into the scene (race/props).
--   racePhase  -- the server-authoritative race phase (lobby/spawning/countdown/racing/finished,
--                 ADR-0006). We record + surface it, and drive the start lock off it: the car is
--                 spawned frozen (handle_race_start) and held through the countdown, released on
--                 racing, with a defensive release on lobby. Countdown UI is a later Phase-3 item.

local M = {}

local envelope = require("beamcomp/envelope")
local race_start = require("beamcomp/race/start")
local vehicles = require("beamcomp/race/vehicles")
local props = require("beamcomp/race/props")

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

    -- Load the race's static-scenery prefab(s) BEFORE the vehicle respawn, so the fresh car's
    -- spawn + auto-enter stays the LAST scene action and the player lands seated in it. Loading
    -- props after the respawn left the player's camera latched onto a prop (a pylon) instead of
    -- the car. Clear first so re-issuing /race never stacks duplicates; placement is client-local
    -- + deterministic (see race/props.lua).
    props.clear(M.state.prop_names or {})
    M.state.prop_names = props.load(race.prefabFiles or {})

    -- Clear this client's vehicles and spawn a fresh copy of its own car at the assigned grid
    -- pose. Owned-only + BeamMP-propagated (see race/vehicles.lua); kept last so auto-enter seats
    -- the player. The grid markers keep rendering from M.state.race regardless.
    local spawned, respawn_err = vehicles.respawn_own_at(race.myPose)
    if spawned then
        -- Re-assert the player into the fresh car. props.load above removes the prefab's
        -- prop-vehicles (cones) first, but this guarantees seating even if one slipped past the
        -- auto-enter race rather than leaving the player on a prop.
        if be then
            pcall(function() be:enterVehicle(0, spawned) end)
        end
        -- Spawn the car frozen: hold it in place from spawn through the countdown so nobody can
        -- jump the start (released on the racing phase, see handle_race_phase). Freeze the spawned
        -- handle rather than getPlayerVehicle(0): the spawn/enter settle over later frames, so the
        -- command must be queued to this exact vehicle's VE.
        local frozen, freeze_err = vehicles.set_vehicle_frozen(spawned, true)
        if not frozen then
            log("W", RACE_LOG_TAG, "could not freeze spawned car: " .. tostring(freeze_err))
        end
        log("I", RACE_LOG_TAG, string.format("respawned at grid slot %d", race.mySlot))
    else
        log("W", RACE_LOG_TAG, "respawn skipped: " .. tostring(respawn_err))
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
-- defensively on lobby (the car is preserved in place, only unlocked). Countdown UI is a later item.
local function handle_race_phase(payload)
    local phase = type(payload) == "table" and payload.phase or nil
    if type(phase) ~= "string" then
        log("W", RACE_LOG_TAG, "racePhase ignored: missing phase")
        return
    end

    M.state.phase = phase
    log("I", RACE_LOG_TAG, "race phase -> " .. phase)

    if phase == "racing" then
        -- Countdown over: release the start lock so the car can drive.
        local released, release_err = vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
        if not released then
            log("W", RACE_LOG_TAG, "could not release start lock: " .. tostring(release_err))
        end
    elseif phase == "lobby" then
        -- Race over (back to lobby): despawn the track props and stop drawing the grid markers,
        -- but leave the player's vehicle exactly where it is -- never despawn or move it. Release
        -- the start lock too, so a /raceend mid-countdown leaves the preserved car drivable. The
        -- abort-restart path skips lobby (finished -> spawning), where handle_race_start reloads
        -- props and re-freezes instead.
        props.clear(M.state.prop_names or {})
        M.state.prop_names = nil
        M.state.race = nil
        vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    end

    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Race phase: " .. phase,
    })
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
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
    log("I", LOG_TAG, "loaded")
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
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
    props.clear(M.state.prop_names or {})
    M.state.prop_names = nil
    M.state.race = nil
    -- Release the start lock so a reload mid-countdown never leaves a stuck-frozen car.
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

return M
