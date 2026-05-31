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
--                 cones are shared: only the payload's propOwner (host) spawns them and BeamMP syncs
--                 them to everyone; non-hosts spawn a statics-only prefab and never instantiate a
--                 cone. The cones are kept non-enterable / out of the Tab cycle on every client via
--                 race/cones (ADR-0020, superseding ADR-0009).
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
local spawn_mute = require("beamcomp/race/spawn_mute")
local countdown = require("beamcomp/race/countdown")
local checkpoints = require("beamcomp/race/checkpoints")
local lock = require("beamcomp/race/lock")
local hud = require("beamcomp/race/hud")
local racelist = require("beamcomp/race/racelist")
local maps = require("beamcomp/race/maps")

-- How long to mute BeamMP's vehicle-spawn notifications from a race start, covering the host's
-- cone-spawn burst on every other client (race/spawn_mute, ADR-0020 finding #2b).
local SPAWN_NOTIFICATION_MUTE_SECONDS = 5

local EVENT_CHANNEL = "beamcompEvent"
local LOG_TAG = "beamcomp.net"
local RACE_LOG_TAG = "beamcomp.race"

local MARKER_RADIUS = 0.6

-- In-world marker styling. Checkpoints render singleplayer-style: a pale translucent column
-- spanning the whole checkpoint radius, with thin posts marking the gate sides. Grid poses render
-- as slot-colored pillars. All immediate-mode debugDrawer, redrawn each frame (nothing to clean up).
-- Checkpoint columns extend far up (seen over buildings / at distance) and well below ground
-- (no visible bottom end on a slope). The pale fill is a cylinder shell, so the extra length does
-- not accumulate opacity.
local CHECKPOINT_COLUMN_UP = 300.0      -- column reach above the checkpoint center
local CHECKPOINT_COLUMN_DOWN = 100.0    -- column reach below the checkpoint center
local GATE_POST_RADIUS = 0.15           -- radius of the thin left/right gate-side posts
local GRID_COLUMN_HEIGHT = 2.5          -- height of a start-grid pillar (label sits on top)
local GRID_COLUMN_RADIUS = 0.25         -- radius of a start-grid pillar

-- Per-target marker colors ({r, g, b, a}). The next checkpoint is colored by role: regular
-- (pale fill + red posts), the lap line (CP0 crossed at the end of a non-final lap, blue), or the
-- race finish (green). The look-ahead -- the checkpoint after next -- always uses yellow posts, so
-- it reads as "the one after" by color rather than by fading.
local CHECKPOINT_STYLE = {
    area = {r = 0.85, g = 0.88, b = 0.95, a = 0.12},
    post = {r = 1.0, g = 0.15, b = 0.15, a = 0.85},
}
local LAP_STYLE = {
    area = {r = 0.45, g = 0.65, b = 1.0, a = 0.16},
    post = {r = 0.2, g = 0.5, b = 1.0, a = 0.9},
}
local FINISH_STYLE = {
    area = {r = 0.55, g = 1.0, b = 0.6, a = 0.16},
    post = {r = 0.3, g = 1.0, b = 0.4, a = 0.9},
}
local LOOKAHEAD_STYLE = {
    area = {r = 0.85, g = 0.88, b = 0.95, a = 0.1},
    post = {r = 1.0, g = 0.85, b = 0.1, a = 0.85},
}

-- Min seconds between "switch locked" toasts, so spamming Tab during a race shows one toast, not a
-- flood (the bounce itself still fires every time).
local SWITCH_BLOCK_TOAST_THROTTLE = 2.0

-- Reload-surviving state (BeamNG serializes M.state across a Lua reload).
M.state = {
    last_event_at = 0,
    registered = false,
    race = nil,          -- current race-start state (slot, poses, roster) or nil
    phase = nil,         -- current server-authoritative race phase (ADR-0006) or nil
    marker_warned = false,
    prop_names = nil,    -- names of the prop prefabs we spawned, for cleanup (or nil)
    cone_ids = nil,      -- ids of the shared cone vehicles we spawned + must clear (host only, ADR-0020)
    current_vehicle_id = nil,  -- game id of the vehicle the player is in, tracked via onVehicleSwitched
    race_car_id = nil,   -- game id of this client's race car; bounce target for the in-race switch lock
    detection = nil,     -- checkpoint-detection progress (race/checkpoints), armed on the racing phase
    standings = nil,     -- latest server-broadcast ranked standings entries, or nil
    grace = nil,         -- finish-grace countdown {remaining = seconds}, ticked locally (ADR-0014), or nil
    assist_armed = false,  -- whether the VE forwarders have been armed for this race (ADR-0017)
    assist_held = nil,     -- kind ("recover"/"repair") of the assist key currently held, or nil (ADR-0017)
    assist_arming = nil,   -- active recover/repair countdown {kind, remaining}, or nil (ADR-0017)
}

-- Client->server send primitive; defined below but forward-declared so the event handlers (and the
-- HANDLERS table) above its definition can reference it.
local send_to_server

-- Disarms the seated car's VE recovery override; defined far below (next to the assist push) but used
-- earlier in handle_race_phase's lobby teardown, so forward-declared here (ADR-0017).
local disarm_assist_ve

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
        -- countdown/racing for a race we are not in, and nothing stale lingers. Lift the in-race lock
        -- and restore the car's recovery too: on an abort-restart (finished -> spawning, no lobby) a
        -- prior race we DID run could otherwise leave us locked through a race we are not in (ADR-0017).
        M.state.race = nil
        M.state.race_car_id = nil
        M.state.detection = nil
        M.state.standings = nil
        M.state.grace = nil
        M.state.assist_armed = false
        M.state.assist_held = nil
        M.state.assist_arming = nil
        lock.remove()
        disarm_assist_ve()
        countdown.clear()
        hud.clear()
        return
    end

    M.state.race = race
    M.state.marker_warned = false
    -- Mute BeamMP's spawn notifications for the spawn burst: the host's ~14 synced cones would
    -- otherwise flood every other client's notification list (ADR-0020 finding #2b). Armed on every
    -- client; the raceStart always arrives before the host's cone spawns can propagate, so the window
    -- opens in time. A real player spawning inside the window is muted too -- accepted edge case.
    spawn_mute.mute_for(SPAWN_NOTIFICATION_MUTE_SECONDS)
    -- Drop any stale race-car id up front; it is re-set below once the car is placed, and left nil if
    -- the placement fails (so the switch lock has no bounce target and lets switches through).
    M.state.race_car_id = nil
    -- Reset checkpoint detection and any stale standings/grace; all are refreshed during the race (the
    -- abort-restart path is finished -> spawning, skipping the lobby reset, so clear them too).
    M.state.detection = nil
    M.state.standings = nil
    M.state.grace = nil
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    -- Blank the HUD so an abort-restart never carries a stale frozen readout into the countdown.
    hud.clear()

    -- Lift any in-race lock before respawning (ADR-0017): the abort-restart path (finished -> spawning)
    -- skips the lobby reset, so a prior race's lock could still be guarding core_vehicles.spawnNewVehicle
    -- and refuse our own fresh-spawn fallback. The countdown phase re-arms it.
    lock.remove()

    -- Resolve the car the player is in, preferring the onVehicleSwitched-tracked id (the polling API
    -- be:getPlayerVehicle(0) sticks to the first owned car in BeamMP). Resolve BEFORE loading props
    -- so the choice is taken before any prop-vehicle churn.
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)

    -- Load the race's static-scenery prefab(s) BEFORE the vehicle respawn, so the fresh car's
    -- spawn + auto-enter stays the LAST scene action and the player lands seated in it. Loading
    -- props after the respawn left the player's camera latched onto a prop (a pylon) instead of
    -- the car. Clear first so re-issuing /race never stacks duplicates; placement is client-local
    -- + deterministic (see race/props.lua). The knockable cones are shared (ADR-0020): only the
    -- propOwner (host) spawns + keeps them (cone_ids, cleared here on re-issue too); non-hosts spawn
    -- a statics-only prefab and never instantiate a cone. The abort/restart path skips the lobby
    -- branch, so clearing here is what prevents host cone-stacking on a re-issued /race.
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names, M.state.cone_ids = props.load(race.prefabFiles or {}, payload.propOwner)

    -- Place this client's own car at the assigned grid pose: the car the player is in is repaired +
    -- teleported in place (preserving its settings), or a fresh one is spawned as a fallback
    -- (ADR-0007). Owned-only + BeamMP-propagated (see race/vehicles.lua). The grid markers keep
    -- rendering from M.state.race regardless.
    local race_car, respawn_err = vehicles.respawn_own_at(race.myPose, own_car)
    if race_car then
        -- Remember the race car as the bounce target for the in-race switch lock (onVehicleSwitched):
        -- during countdown/racing any switch to another vehicle is bounced back to this id.
        M.state.race_car_id = race_car:getId()
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
        -- Arm the in-race vehicle-action lock for the whole countdown + racing span (ADR-0017): no
        -- switching, spawning, replacing, or alternative recover/reset until the race returns to lobby.
        lock.install()
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
        -- Lift the in-race vehicle-action lock (ADR-0017): switching/spawning/recover are free again.
        lock.remove()
        -- Restore the seated car's vanilla recovery before the race state is cleared below.
        disarm_assist_ve()
        props.clear(M.state.prop_names or {})
        cones.clear(M.state.cone_ids or {})
        M.state.prop_names = nil
        M.state.cone_ids = nil
        M.state.race = nil
        M.state.race_car_id = nil
        M.state.detection = nil
        M.state.standings = nil
        M.state.grace = nil
        M.state.assist_armed = false
        M.state.assist_held = nil
        M.state.assist_arming = nil
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

-- Answer the server's pre-flight validateRace request (ADR-0019): the race-blind server relays the
-- /race options here, we vet them against the locally-parsed race (race/start.validate) and report the
-- verdict back. The server starts on ok, or posts our reason to the issuing admin on a refusal. The
-- nonce is echoed so the server can match the reply to its in-flight check.
local function handle_validate_race(payload)
    local result = race_start.validate(payload)
    send_to_server("raceValidation", {
        nonce = type(payload) == "table" and payload.nonce or nil,
        ok = result.ok,
        reason = result.reason,
    })
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
    validateRace = handle_validate_race,
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

-- Draw a slot-colored pillar + label at every grid pose (own slot highlighted), harmonized with
-- the checkpoint columns. Immediate-mode: redrawn each frame from M.state, so there are no scene
-- objects to clean up -- clearing M.state.race removes the markers.
local function draw_grid_markers(race)
    local mine = ColorF(0.2, 1.0, 0.3, 0.9)
    local other = ColorF(1.0, 0.8, 0.1, 0.7)
    local centers = {}
    for index, pose in ipairs(race.gridPoses) do
        local p = pose.pos
        local base = vec3(p.x, p.y, p.z)
        local top = vec3(p.x, p.y, p.z + GRID_COLUMN_HEIGHT)
        centers[index] = top
        local slot = index - 1
        debugDrawer:drawCylinder(base, top, GRID_COLUMN_RADIUS, (slot == race.mySlot) and mine or other)
    end

    -- Labels last + lower-confidence API: if drawTextAdvanced/ColorI mismatch here, the
    -- pillars above have already drawn this frame (the onPreRender pcall warns once).
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

-- The two horizontal gate-edge points (left, right) of an oriented checkpoint, derived from its
-- gate normal the way BeamNG's own pathnode renderer does -- the perpendicular to the normal in the
-- ground plane (cross(normal, up)). Returns nil for a checkpoint with no normal: a pure-radius
-- checkpoint has no meaningful left/right side, so only its area column is drawn.
local function gate_edges(checkpoint)
    local normal = checkpoint.normal
    if not normal then
        return nil
    end
    local len = math.sqrt(normal.x * normal.x + normal.y * normal.y)
    if len < 1e-6 then
        return nil
    end
    local perp_x = normal.y / len
    local perp_y = -normal.x / len
    local radius = checkpoint.radius or MARKER_RADIUS
    local p = checkpoint.pos
    local left = vec3(p.x - perp_x * radius, p.y - perp_y * radius, p.z)
    local right = vec3(p.x + perp_x * radius, p.y + perp_y * radius, p.z)
    return left, right
end

-- The style for the next checkpoint, by role: the race's final scored crossing is the finish
-- (green); a non-final start/finish line (CP0, stable index 0) is a lap line (blue); every other
-- checkpoint uses the regular pale-fill + red-post style.
local function marker_style(checkpoint, is_finish)
    if is_finish then
        return FINISH_STYLE
    end
    if checkpoint.index == 0 then
        return LAP_STYLE
    end
    return CHECKPOINT_STYLE
end

-- Draw one checkpoint as a singleplayer-style gate: a pale translucent column spanning the whole
-- checkpoint radius, plus -- for an oriented gate -- two thin posts marking the left/right sides.
local function draw_checkpoint_marker(checkpoint, style)
    local p = checkpoint.pos
    local radius = checkpoint.radius or MARKER_RADIUS
    local base = vec3(p.x, p.y, p.z - CHECKPOINT_COLUMN_DOWN)
    local top = vec3(p.x, p.y, p.z + CHECKPOINT_COLUMN_UP)
    local area = style.area
    debugDrawer:drawCylinder(base, top, radius, ColorF(area.r, area.g, area.b, area.a))

    local left, right = gate_edges(checkpoint)
    if not left then
        return
    end
    local post = style.post
    local post_color = ColorF(post.r, post.g, post.b, post.a)
    local left_base = vec3(left.x, left.y, left.z - CHECKPOINT_COLUMN_DOWN)
    local right_base = vec3(right.x, right.y, right.z - CHECKPOINT_COLUMN_DOWN)
    local left_top = vec3(left.x, left.y, left.z + CHECKPOINT_COLUMN_UP)
    local right_top = vec3(right.x, right.y, right.z + CHECKPOINT_COLUMN_UP)
    debugDrawer:drawCylinder(left_base, left_top, GATE_POST_RADIUS, post_color)
    debugDrawer:drawCylinder(right_base, right_top, GATE_POST_RADIUS, post_color)
end

-- Draw the next expected checkpoint -- and the one after it as a yellow-posted look-ahead -- as
-- singleplayer-style gates, so the player sees where to head next and can plan the line. Immediate-
-- mode like draw_grid_markers (redrawn each frame, nothing to clean up). The next checkpoint is the
-- plan entry at detection.seq + 1, the look-ahead the entry after it; each cursor indexes the
-- checkpoints array (ADR-0013) -- so on a circuit they point at CP1 first and back at the start/
-- finish line (CP0) for the final crossing.
local function draw_next_checkpoint(race, detection)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return
    end
    local final_seq = #entries

    local next_entry = entries[detection.seq + 1]
    local next_checkpoint = next_entry and race.checkpoints[next_entry.cursor]
    if not next_checkpoint then
        return
    end
    local next_style = marker_style(next_checkpoint, detection.seq + 1 == final_seq)
    draw_checkpoint_marker(next_checkpoint, next_style)

    local ahead_entry = entries[detection.seq + 2]
    local ahead_checkpoint = ahead_entry and race.checkpoints[ahead_entry.cursor]
    if ahead_checkpoint then
        draw_checkpoint_marker(ahead_checkpoint, LOOKAHEAD_STYLE)
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

-- os.clock() reading of the last switch-lock toast, for SWITCH_BLOCK_TOAST_THROTTLE (CPU seconds is
-- monotonic and precise enough to gate a UI toast). A plain file-scope local: a Lua reload resets it,
-- which at worst shows one extra toast -- not worth M.state.
local last_block_toast_at = 0

-- Put the player straight back into their race car after a blocked switch, and surface a throttled
-- toast so a deliberate Tab press is not silently swallowed. Returns false when the race car is gone
-- (so the caller lets the switch through rather than trapping the player). Mirrors the cone bounce
-- (cones.enforce_non_enterable), but race-car-general and with the in-race feedback toast.
local function bounce_to_race_car()
    local race_car = be and be:getObjectByID(M.state.race_car_id)
    if not race_car then
        return false
    end
    local ok, err = pcall(function() be:enterVehicle(0, race_car) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not bounce player back to race car: " .. tostring(err))
        return false
    end
    local now = os.clock()
    if now - last_block_toast_at >= SWITCH_BLOCK_TOAST_THROTTLE then
        last_block_toast_at = now
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = "Vehicle switching is locked during the race",
        })
    end
    log("I", RACE_LOG_TAG, "blocked vehicle switch -- bounced player back to race car")
    return true
end

-- Track the vehicle the player is currently in, keep them in their race car during the race, and keep
-- them out of the shared cones otherwise. BeamNG fires onVehicleSwitched(old, new) on every switch.
-- During the locked sequence (countdown + racing) any switch to a vehicle that is not the race car is
-- bounced straight back to it (this also covers the cones while racing); when the race car is gone the
-- bounce is skipped so the player is never trapped. Outside the race we keep the latest non-cone `new`
-- as the authoritative seated car, because in BeamMP the polling API be:getPlayerVehicle(0) sticks to
-- the first owned car -- so race/vehicles.lua resolve_own_car prefers this tracked id (confirmed
-- in-game). A switch into a cone bounces back to the last real car and is NOT recorded -- the
-- guaranteed non-enterable layer (ADR-0009). A blocked switch likewise never updates current_vehicle_id
-- (the checkpoint detector must keep reading the race car).
function M.onVehicleSwitched(_oldId, newId)
    local phase = M.state.phase
    if (phase == "countdown" or phase == "racing") and M.state.race_car_id ~= nil
            and tostring(newId) ~= tostring(M.state.race_car_id) then
        if bounce_to_race_car() then
            return
        end
    end
    if cones.is_cone(be and be:getObjectByID(newId)) then
        cones.enforce_non_enterable(newId, M.state.current_vehicle_id)
        return
    end
    M.state.current_vehicle_id = newId
end

-- As each shared cone appears -- the host's local set when its prefab load spawns them, and the
-- remote synced set on every other client (BeamMP vehicle spawns fire this hook too) -- keep it out
-- of the Tab vehicle cycle and suppress BeamMP's owner nametag on it. Both are best-effort layers
-- (the onVehicleSwitched bounce is the non-enterable guarantee; the tag may stay if the cone is not
-- yet registered in MPVehicleGE -- accepted, ADR-0020).
function M.onVehicleSpawned(vehicleId)
    if not be then
        return
    end
    local veh = be:getObjectByID(vehicleId)
    cones.exclude_from_cycle(veh)
    cones.hide_nametag(veh)
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

-- Normalize a plain {x, y, z} vector, or nil when it is degenerate (too short to give a direction).
local function normalize_dir(v)
    local length = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if length < 1e-6 then
        return nil
    end
    return {x = v.x / length, y = v.y / length, z = v.z / length}
end

-- The checkpoint at a 1-based plan ordinal (entries[ordinal].cursor -> checkpoints[cursor]), or nil.
local function plan_checkpoint(race, ordinal)
    local entries = race.plan and race.plan.entries
    local entry = entries and entries[ordinal]
    return entry and race.checkpoints[entry.cursor] or nil
end

-- The recover target for the local player: the last passed checkpoint (ADR-0010/0013) facing the
-- next one, or -- before any checkpoint is passed -- the grid start pose facing the first checkpoint.
-- Returns {pos = {x,y,z}, dir = {x,y,z} or nil}; the VE falls back to a default facing on a nil dir.
local function recover_target(race, detection)
    local seq = (detection and detection.seq) or 0
    local target_pos, face_pos
    if seq <= 0 then
        target_pos = race.myPose.pos
        local first = plan_checkpoint(race, 1)
        face_pos = first and first.pos
    else
        local last = plan_checkpoint(race, seq)
        target_pos = (last and last.pos) or race.myPose.pos
        local next_cp = plan_checkpoint(race, seq + 1)
        face_pos = next_cp and next_cp.pos
    end

    local dir
    if face_pos and target_pos then
        dir = normalize_dir({
            x = face_pos.x - target_pos.x,
            y = face_pos.y - target_pos.y,
            z = face_pos.z - target_pos.z,
        })
    end
    return {pos = target_pos, dir = dir}
end

-- Arm the seated car's VE key forwarders for the race (ADR-0017). GE owns the enable check, countdown,
-- and action, so nothing but a bare "arm" is sent. Pushed once (tracked by assist_armed). Vehicle
-- extensions under lua/vehicle/extensions/ are NOT auto-loaded (only the .../auto subdir is;
-- vehicle/main.lua), so load ours into the car's VM first; extensions.load is synchronous, so
-- beamcomp_init is available on the same command. No-op until the own car resolves; retried from onUpdate.
local function push_assist_arm()
    local race = M.state.race
    if not race or not race.assists or M.state.assist_armed then
        return
    end
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end

    local command = "if not beamcomp_init then extensions.load('beamcomp_init') end "
        .. "if beamcomp_init then beamcomp_init.on_assist_arm() end"
    local ok, err = pcall(function() own_car:queueLuaCommand(command) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not arm assist forwarders on VE: " .. tostring(err))
        return
    end
    M.state.assist_armed = true
end

-- Tell the seated car's VE to restore the vanilla recovery functions (ADR-0017): the race is over, so
-- recover/repair behave normally again. Best-effort -- if the car is gone the override died with it.
-- Assigns the forward-declared local so handle_race_phase (above) can call it.
function disarm_assist_ve()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end
    pcall(function()
        own_car:queueLuaCommand("if beamcomp_init then beamcomp_init.on_assist_disarm() end")
    end)
end

-- Perform a recover/repair once its countdown completes (ADR-0017). GE owns the action: "repair"
-- fixes the car in place (queued recovery.recoverInPlace), "recover" teleports + repairs to the last
-- passed checkpoint (grid pose before the first). Reseed the detector so the teleport jump is not
-- swept as a spurious crossing next frame.
local function perform_assist(kind)
    local race = M.state.race
    if not race then
        return
    end
    if M.state.detection then
        M.state.detection.prev_pos = nil
    end

    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        log("W", RACE_LOG_TAG, "assist '" .. tostring(kind) .. "' completed but no own car resolved")
        return
    end

    if kind == "repair" then
        pcall(function() own_car:queueLuaCommand("recovery.recoverInPlace()") end)
    else
        local target = recover_target(race, M.state.detection)
        local placed, err = vehicles.recover_to(own_car, target.pos, target.dir)
        if not placed then
            log("W", RACE_LOG_TAG, "recover-to-checkpoint failed: " .. tostring(err))
            return
        end
    end

    log("I", RACE_LOG_TAG, "assist performed: " .. tostring(kind))
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = (kind == "repair") and "Repaired in place" or "Recovered to last checkpoint",
    })
end

-- Clear any in-progress assist countdown and its on-screen flash (ADR-0017). Idempotent.
local function clear_assist_arming()
    if M.state.assist_arming then
        M.state.assist_arming = nil
        countdown.clear()
    end
end

-- Speed (m/s) at or below which the car counts as stopped for recover/repair: the countdown only
-- runs while (near) stationary, so it cannot be triggered while driving (ADR-0017).
local ASSIST_STATIONARY_SPEED = 2.0

-- The (enabled, holdSeconds) setting for an assist kind, read with an explicit branch (the enabled
-- flags are booleans, so `a and b or c` would wrongly fall through to the other assist).
local function assist_setting(kind)
    local assists = M.state.race and M.state.race.assists
    if not assists then
        return false, 0
    end
    if kind == "repair" then
        return assists.repairEnabled, assists.repairHoldSeconds
    end
    return assists.recoverEnabled, assists.recoverHoldSeconds
end

-- Whether the local car is stopped enough to begin/continue a recover/repair hold.
local function is_car_stationary()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return false
    end
    local ok, speed = pcall(function() return own_car:getVelocity():length() end)
    return ok and speed <= ASSIST_STATIONARY_SPEED
end

-- A recover/repair key went down (forwarded from the VE, ADR-0017): record which assist is held so
-- the per-frame stepper can run the hold. Racing only, enabled assists only -- a disabled assist's
-- key is inert (blocked). The actual countdown starts in step_assist once the car is stationary.
function M.on_assist_key_down(kind)
    if not M.state.race or M.state.phase ~= "racing" then
        return
    end
    local enabled = assist_setting(kind)
    if not enabled then
        return
    end
    M.state.assist_held = kind
end

-- The held recover/repair key was released: drop the hold and cancel any running countdown.
function M.on_assist_key_up()
    M.state.assist_held = nil
    clear_assist_arming()
end

-- Drive the hold-to-activate recover/repair each frame (ADR-0017): the countdown runs only while the
-- key is held AND the car is (near) stationary -- releasing or driving off cancels it. On completion
-- the held kind is consumed (cleared) so it does not immediately re-fire while the key is still down.
local function step_assist(dt_real)
    local held = M.state.assist_held
    if not held or not is_car_stationary() then
        clear_assist_arming()
        return
    end

    local arming = M.state.assist_arming
    if not arming or arming.kind ~= held then
        local _, seconds = assist_setting(held)
        arming = {kind = held, remaining = seconds}
        M.state.assist_arming = arming
        countdown.show_assist_countdown(held == "repair" and "Repair" or "Recover", math.ceil(seconds))
    end

    arming.remaining = arming.remaining - (dt_real or 0)
    if arming.remaining <= 0 then
        local kind = arming.kind
        clear_assist_arming()
        M.state.assist_held = nil
        perform_assist(kind)
    end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
    if M.state.phase == "racing" and M.state.race then
        step_detection(dtSim)
        -- Drive the held recover/repair countdown (ADR-0017).
        step_assist(dtReal)
        -- Tick the finish-grace countdown in wall time (the server's cutoff is wall-time; ADR-0014).
        -- Visual only -- the server stays authoritative on the actual DNF cutoff.
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
    end
    -- Arm the seated car's VE key forwarders across the locked sequence (countdown + racing). The
    -- first successful arm installs the override + reset guard, so vanilla recover/reset is never
    -- available mid-race even with both assists off (ADR-0017).
    if (M.state.phase == "countdown" or M.state.phase == "racing") and M.state.race then
        push_assist_arm()
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
    -- Lift the in-race vehicle-action lock so a reload mid-race never leaves switching/spawning or the
    -- guarded core_vehicles functions stuck blocked (ADR-0017), and restore the seated car's recovery.
    lock.remove()
    disarm_assist_ve()
    spawn_mute.restore()
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.race = nil
    M.state.race_car_id = nil
    M.state.detection = nil
    M.state.grace = nil
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    -- Release the start lock so a reload mid-countdown never leaves a stuck-frozen car.
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

return M
