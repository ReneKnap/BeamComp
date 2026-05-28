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
--                 also arms the local checkpoint detector (race/checkpoints, ADR-0010), which walks
--                 the race's sprint/circuit traversal plan (ADR-0013), stepped each frame in onUpdate
--                 and surfacing each passed checkpoint as a toast + log line + server report.

local M = {}

local envelope = require("beamcomp/envelope")
local race_start = require("beamcomp/race/start")
local vehicles = require("beamcomp/race/vehicles")
local props = require("beamcomp/race/props")
local cones = require("beamcomp/race/cones")
local countdown = require("beamcomp/race/countdown")
local checkpoints = require("beamcomp/race/checkpoints")
local hud = require("beamcomp/race/hud")
local racelist = require("beamcomp/race/racelist")
local maps = require("beamcomp/race/maps")

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
    grace = nil,         -- finish-grace countdown {remaining = seconds}, ticked locally (ADR-0014), or nil
}

-- Client->server send primitive; defined below but forward-declared so the event handlers (and the
-- HANDLERS table) above its definition can reference it.
local send_to_server

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
        -- A raceStart we can't resolve still means the server has begun a new race, so any prior race
        -- on this client is over. Drop its state (and blank the HUD) so the phase guard below skips the
        -- countdown/racing for a race we are not in, and nothing stale lingers.
        M.state.race = nil
        M.state.detection = nil
        M.state.standings = nil
        M.state.grace = nil
        hud.clear()
        return
    end

    M.state.race = race
    M.state.marker_warned = false
    -- Reset checkpoint detection and any stale standings/grace; all are refreshed during the race (the
    -- abort-restart path is finished -> spawning, skipping the lobby reset, so clear them too).
    M.state.detection = nil
    M.state.standings = nil
    M.state.grace = nil
    -- Blank the HUD so an abort-restart never carries a stale frozen readout into the countdown.
    hud.clear()

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

    log("I", RACE_LOG_TAG, string.format("race '%s': you are slot %d, mode=%s laps=%d",
        race.name, race.mySlot, tostring(race.mode), race.laps or 1))
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp -- " .. race.name,
        msg = string.format("Slot %d -- start (%.0f, %.0f, %.0f)",
            race.mySlot, race.myPose.pos.x, race.myPose.pos.y, race.myPose.pos.z),
    })
    -- The server can't validate the requested mode against geometry (race-blind); a fallback was
    -- decided client-side in race/start (ADR-0013), so surface it here.
    if race.modeWarning then
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = race.modeWarning,
        })
    end
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

    -- Ignore phases for a race this client is not in: with no resolved race (unknown name, wrong map)
    -- there is no car, plan, or checkpoints, so the server-driven countdown/racing must not render or
    -- arm detection. Lobby still runs so any prior race tears down normally.
    if not M.state.race and phase ~= "lobby" then
        log("I", RACE_LOG_TAG, "racePhase '" .. phase .. "' ignored: no active race on this client")
        return
    end

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
        -- Arm checkpoint detection now the lock is released: it walks the race's traversal plan
        -- (sprint/circuit, ADR-0013), testing the local car against the planned-next checkpoint each
        -- frame (onUpdate) while racing (ADR-0010).
        local plan = M.state.race and M.state.race.plan
        if plan then
            M.state.detection = checkpoints.new(plan)
        else
            log("W", RACE_LOG_TAG, "racing: no traversal plan; checkpoint detection disabled")
        end
        -- Auto-show the HUD app for the race (ADR-0012); removed again on lobby. ensureAppVisible
        -- dedups, so a manually-added copy is not duplicated.
        hud.show()
    elseif phase == "lobby" then
        -- Race over (back to lobby): clear any countdown overlay, despawn the track props and stop
        -- drawing the grid markers, but leave the player's vehicle exactly where it is -- never
        -- despawn or move it. Release the start lock too, so a /raceend mid-countdown leaves the
        -- preserved car drivable. The abort-restart path skips lobby (finished -> spawning), where
        -- handle_race_start reloads props and re-freezes instead.
        countdown.clear()
        hud.clear()
        hud.hide()
        props.clear(M.state.prop_names or {})
        cones.clear(M.state.cone_ids or {})
        M.state.prop_names = nil
        M.state.cone_ids = nil
        M.state.race = nil
        M.state.detection = nil
        M.state.standings = nil
        M.state.grace = nil
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

-- Answer the server's listRaces request: build this client's installed-race list for the loaded map
-- and ship it back for the server to post to the asking player (ADR-0005: the server is race-blind,
-- so the client owns the list; ADR-0011: client->server reply). The request payload is empty -- it is
-- just the server asking us to report.
local function handle_list_races(_payload)
    send_to_server("raceList", {lines = racelist.build(maps.current())})
end

-- Store the server-issued finish-grace countdown (ADR-0014): once the first player finishes, every
-- still-racing player has this many seconds to finish or be marked DNF. Ticked down locally in
-- onUpdate; shown on the HUD only while the local player has not finished.
local function handle_finish_grace(payload)
    local duration = type(payload) == "table" and tonumber(payload.duration) or nil
    if not duration or duration <= 0 then
        log("W", RACE_LOG_TAG, "finishGrace ignored: bad duration")
        return
    end
    M.state.grace = {remaining = duration}
    log("I", RACE_LOG_TAG, string.format("finish grace: %.0fs to finish or DNF", duration))
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
    standings = handle_standings,
    listRaces = handle_list_races,
    finishGrace = handle_finish_grace,
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

-- Draw the next expected checkpoint as an in-world sphere so the player sees where to head next.
-- Distinct blue vs the grid markers' green/amber; immediate-mode like draw_grid_markers (redrawn
-- each frame, nothing to clean up). The next checkpoint is the plan entry at detection.seq + 1, whose
-- cursor indexes the checkpoints array (ADR-0013) -- so on a circuit it points at CP1 first and back
-- at the start/finish line (CP0) for the final crossing.
local function draw_next_checkpoint(race, detection)
    local entry = detection.plan and detection.plan.entries[detection.seq + 1]
    local checkpoint = entry and race.checkpoints[entry.cursor]
    if not checkpoint then
        return
    end
    local c = checkpoint.pos
    local center = vec3(c.x, c.y, c.z + MARKER_LIFT)
    local radius = checkpoint.radius or MARKER_RADIUS
    debugDrawer:drawSphere(center, radius, ColorF(0.2, 0.6, 1.0, 0.5))
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
-- spawn-ready acks) reuse it. Forward-declared above (local) so handlers defined earlier can call it.
function send_to_server(message_type, payload)
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
-- emission seam for a passage -- keep it the one place a passage is reported. The report carries
-- `seq` (the plan ordinal, the server's ordering key), `lap`, the display `index`/`name`, the time,
-- and `count` (total scored crossings) so the race-blind server (ADR-0005) tracks progress and the
-- final crossing without parsing the race (ADR-0011, ADR-0013).
local function on_checkpoint_reached(event, count)
    log("I", RACE_LOG_TAG, string.format("checkpoint %d (%s) lap %d reached @ %.2fs (seq %d)",
        event.index, tostring(event.name), event.lap, event.time, event.seq))
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp",
        msg = string.format("Checkpoint %d reached @ %.1fs", event.index, event.time),
    })
    send_to_server("checkpoint", {
        seq = event.seq,
        index = event.index,
        name = event.name,
        lap = event.lap,
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
        on_checkpoint_reached(event, detection.plan.count)
    end
end

-- The lap the local player is currently on, read from the detector's plan: the lap of the next plan
-- entry, or the final entry's lap once done (ADR-0013). Defaults to 1 when there is no plan.
local function detection_lap(detection)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return 1
    end
    local next_entry = entries[detection.seq + 1]
    if next_entry then
        return next_entry.lap
    end
    local last_entry = entries[#entries]
    return last_entry and last_entry.lap or 1
end

-- Build the HUD snapshot for the render app (ADR-0012): the full ranked standings list, tagged
-- with the current phase so the app can branch live-HUD vs results template. During racing the
-- local player's row uses the live detector (ticking time, crossing count, lap); during finished
-- it falls back to the server-broadcast values so the frozen final readout matches every other
-- client. `lapCount` is the resolved race lap count (1 for sprint; the HUD shows a lap indicator
-- only when > 1, ADR-0013). Per-entry `splits` (cumulative race-time at each crossing, ADR-0015)
-- rides through opaquely for the results template. Pure read of M.state; the server is unaffected.
local function build_hud_snapshot()
    local race = M.state.race
    local detection = M.state.detection
    local standings = M.state.standings
    local phase = M.state.phase
    local my_slot = race and race.mySlot
    local checkpoint_count = (race and race.plan and race.plan.count)
        or ((race and race.checkpoints) and #race.checkpoints) or 0
    local lap_count = (race and race.laps) or 1
    local local_finished = detection and detection.done
    local local_dnf = false

    local entries = {}
    if standings then
        for i, e in ipairs(standings) do
            local is_local = my_slot ~= nil and e.slot == my_slot
            local checkpoint = e.completed
            local time = e.total_time
            local lap = e.lap or 1
            -- Only substitute live detector values for the local row during racing -- once the race
            -- is finished, every client must show the same server-authoritative totals.
            if is_local and detection and phase == "racing" then
                checkpoint = detection.seq
                time = detection.elapsed
                lap = detection_lap(detection)
            end
            if is_local then
                local_dnf = e.dnf and true or false
            end
            entries[i] = {
                position = e.position,
                name = e.name,
                checkpoint = checkpoint,
                count = e.count or checkpoint_count,
                time = time,
                finished = e.finished,
                dnf = e.dnf,
                isLocal = is_local,
                lap = lap,
                lapCount = lap_count,
                splits = e.splits,
            }
        end
    end

    -- Gap (vs leader) and interval (vs entry ahead), computed at the highest checkpoint both have
    -- crossed (their splits arrays, ADR-0015). At the same shared crossing the comparison is fair
    -- regardless of who has since progressed further: positive = entry is behind. For two finishers
    -- the shared crossing is the final one, so the value equals the total-time delta. DNF rows and
    -- pairs without a shared crossing leave the fields nil; the template renders a placeholder.
    local function shared_split_gap(entry, reference)
        local a, b = entry.splits, reference.splits
        if not a or not b then
            return nil
        end
        local shared = math.min(#a, #b)
        if shared <= 0 then
            return nil
        end
        return a[shared] - b[shared]
    end

    local leader = entries[1]
    if leader and not leader.dnf then
        for i = 2, #entries do
            local entry = entries[i]
            local ahead = entries[i - 1]
            if not entry.dnf then
                entry.gap = shared_split_gap(entry, leader)
                if not ahead.dnf then
                    entry.interval = shared_split_gap(entry, ahead)
                end
            end
        end
    end

    -- Show the finish-grace countdown to everyone during the grace; the label adapts to whether the
    -- local player can still finish (ADR-0014) -- finished/DNF players see how long until the race ends.
    local grace = M.state.grace and M.state.grace.remaining or nil
    local grace_can_finish = not local_finished and not local_dnf

    return {
        active = true,
        phase = phase,
        entries = entries,
        grace = grace,
        graceCanFinish = grace_can_finish,
    }
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
    if M.state.phase == "racing" and M.state.race then
        step_detection(dtSim)
        -- Tick the finish-grace countdown in wall time (the server's cutoff is wall-time; ADR-0014).
        -- Visual only -- the server stays authoritative on the actual DNF cutoff.
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
    end
    -- Keep pushing during the finished phase too so the results template (ADR-0012) renders the
    -- frozen final standings, not the last frame caught mid-racing.
    if (M.state.phase == "racing" or M.state.phase == "finished") and M.state.race then
        hud.push(build_hud_snapshot())
    end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
    local race = M.state.race
    if not race or not debugDrawer then
        return
    end
    -- Guard the draws: debugDrawer's exact API is runtime-confirmed here, so a mismatch warns once
    -- rather than spamming every frame. The next-checkpoint marker only shows while racing.
    local ok, err = pcall(function()
        draw_grid_markers(race)
        local detection = M.state.detection
        if M.state.phase == "racing" and detection and not detection.done then
            draw_next_checkpoint(race, detection)
        end
    end)
    if not ok and not M.state.marker_warned then
        M.state.marker_warned = true
        log("W", RACE_LOG_TAG, "marker draw failed (debugDrawer API?): " .. tostring(err))
    end
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    countdown.clear()
    hud.clear()
    hud.hide()
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.race = nil
    M.state.detection = nil
    M.state.grace = nil
    -- Release the start lock so a reload mid-countdown never leaves a stuck-frozen car.
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

return M
