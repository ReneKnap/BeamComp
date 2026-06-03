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
local laptimer = require("beamcomp/race/laptimer")
local lock = require("beamcomp/race/lock")
local hud = require("beamcomp/race/hud")
local racelist = require("beamcomp/race/racelist")
local maps = require("beamcomp/race/maps")
local grideditor = require("beamcomp/race/grideditor")

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
local CHECKPOINT_FADE_BAND = 30.0       -- meters above the radius over which the area cylinder fades
                                        -- in: full alpha at radius + this, alpha 0 at the volume edge
local POST_MAX_TURN_RATE = math.rad(7.5) -- max rad/s the player-facing gate posts may rotate, so they
                                         -- ease toward the player instead of snapping near the center
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

-- Seconds to wait for a (swapped or freshly-spawned) car's jbeam to finish loading before re-placing it
-- anyway (fallback for a same-footprint swap, where the bbox never visibly changes). Forward
-- half-length change (metres) that signals the new jbeam has loaded and the bbox now reflects the
-- actual car. Used by restage_swapped_car; declared here so handle_race_start can arm the same flow.
local RESTAGE_MAX_WAIT = 3.0
local RESTAGE_MIN_DELTA = 0.2

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
    laptimer = nil,      -- circuit lap-clock state (race/laptimer), armed on racing; display only (ADR-0022)
    results_hidden = false,  -- local-only toggle: hide the finished results card via /results (ADR-0022)
    post_orient = nil,   -- smoothed gate-line angle per checkpoint index, for player-facing posts
    standings = nil,     -- latest server-broadcast ranked standings entries, or nil
    grace = nil,         -- finish-grace countdown {remaining = seconds}, ticked locally (ADR-0014), or nil
    staging = nil,       -- staging-wait {remaining = seconds}, ticked locally for the indicator (ADR-0021), or nil
    countdown = nil,     -- start-countdown {remaining = seconds}, ticked locally to drive the 8s count (ADR-0021), or nil
    assist_armed = false,  -- whether the VE forwarders have been armed for this race (ADR-0017)
    assist_held = nil,     -- kind ("recover"/"repair") of the assist key currently held, or nil (ADR-0017)
    assist_arming = nil,   -- active recover/repair countdown {kind, remaining}, or nil (ADR-0017)
    assist_notice = nil,   -- which abort reason was last toasted this hold ("moving"), latches one-shot
    freeze_hold_armed = false,  -- whether the VE EV-throttle clamp has been armed for the frozen phases (ADR-0017 amendment)
    restage_pending = false,  -- a staging car (swap or fresh-spawn default) awaits re-placement at the grid slot once its bbox is ready
    restage_baseline = nil,   -- spawn-bbox forward half-length recorded on the first pending frame, to detect the new jbeam loading
    restage_wait = 0,         -- seconds left to wait for the staging car's jbeam before placing anyway
}

-- Client->server send primitive; defined below but forward-declared so the event handlers (and the
-- HANDLERS table) above its definition can reference it.
local send_to_server

-- Disarms the seated car's VE recovery override; defined far below (next to the assist push) but used
-- earlier in handle_race_phase's lobby teardown, so forward-declared here (ADR-0017).
local disarm_assist_ve

-- Disarms the seated car's VE EV-throttle clamp; defined far below (next to the freeze-hold push) but
-- used earlier in handle_race_phase / handle_race_start, so forward-declared here (ADR-0017 amendment).
local disarm_freeze_hold_ve

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
        M.state.laptimer = nil
        M.state.standings = nil
        M.state.grace = nil
        M.state.assist_armed = false
        M.state.assist_held = nil
        M.state.assist_arming = nil
        M.state.assist_notice = nil
        M.state.freeze_hold_armed = false
        lock.remove()
        disarm_assist_ve()
        disarm_freeze_hold_ve()
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
    M.state.laptimer = nil
    M.state.standings = nil
    M.state.grace = nil
    M.state.staging = nil
    M.state.countdown = nil
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    M.state.assist_notice = nil
    -- Re-arm the EV freeze clamp for this race: cleared here so push_freeze_hold fires again in staging
    -- (the abort-restart path skips the lobby reset, ADR-0017 amendment).
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
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
    M.state.prop_names, M.state.cone_ids = props.load(race.prefabFiles or {}, payload.propOwner,
        race.coneFiles or {})

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
        -- A fresh-spawn fallback (no own car -> default vehicle) lands center-anchored, since the spawn
        -- path cannot front-anchor a car whose jbeam is still loading. Arm the same deferred re-stage a
        -- staging swap uses (restage_swapped_car) so it gets front-anchored at the grid slot once its
        -- bbox is ready -- identical placement to every other car.
        if not own_car then
            M.state.restage_pending = true
            M.state.restage_baseline = nil
            M.state.restage_wait = RESTAGE_MAX_WAIT
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

-- Despawn everything BeamComp put into the world for a race and drop all race-scoped state, leaving
-- the player's own car exactly where it is (only unfrozen + unlocked, never despawned or moved).
-- Idempotent: props.clear/cones.clear no-op on already-gone objects and set_vehicle_frozen no-ops on
-- a nil car, so calling it when nothing is spawned is harmless. Shared by the lobby phase (regular
-- end / raceend), onClientEndMission (left the session / changed level mid-race), and
-- onExtensionUnloaded (Lua reload). Deliberately does NOT touch M.state.phase, the BeamMP event
-- handler, or editor/spawn-mute state -- each caller owns those.
local function teardown_race_world()
    countdown.clear()
    hud.clear()
    hud.hide()
    -- Lift the in-race vehicle-action lock and restore the seated car's vanilla recovery (ADR-0017).
    lock.remove()
    disarm_assist_ve()
    -- Release the EV start-freeze throttle clamp too (ADR-0017 amendment); idempotent on absent cars.
    disarm_freeze_hold_ve()
    -- Despawn the track props and the host's shared cones (idempotent on absent names/ids, ADR-0020).
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.race = nil
    M.state.race_car_id = nil
    M.state.detection = nil
    M.state.laptimer = nil
    M.state.standings = nil
    M.state.grace = nil
    M.state.staging = nil
    M.state.countdown = nil
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    M.state.assist_notice = nil
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
    -- Release the start freeze so the preserved car is drivable (no-op if already free / car gone).
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
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

    if phase == "staging" then
        -- Arm the in-race vehicle-action lock in swap-allowed mode for the staging wait
        -- (ADR-0017/0021 amendments): the player may still change car (replace the model/config via the
        -- vehicle/parts selector), but cannot spawn an extra car, switch, reset, recover, or grab. A
        -- swap is re-staged in onUpdate (re-freeze + bounce target + VE re-arm). The lock upgrades to the
        -- full fixed-car lock at countdown. The car is already frozen at its grid slot
        -- (handle_race_start) and stays so until racing. Force the HUD app visible now so the countdown
        -- overlay it hosts is present before the count starts (ADR-0021), and seed the staging indicator.
        lock.install({allow_replace = true})
        hud.show()
        M.state.staging = {remaining = tonumber(payload.duration) or 0, last_shown = nil}
    elseif phase == "countdown" then
        -- Staging over: upgrade the lock to the full fixed-car lock (no more replace or selector) for
        -- the countdown + racing span, then seed the start countdown; the local onUpdate tick renders
        -- each whole second and plays the final beeps on the centered overlay (ADR-0021).
        lock.install()
        M.state.staging = nil
        M.state.countdown = {remaining = tonumber(payload.duration) or 0, last_shown = nil}
    elseif phase == "racing" then
        -- Countdown over: show GO! (server-authoritative, so it lands exactly on the release), play
        -- the GO cue, stop the local count, and release the start lock so the car can drive.
        M.state.countdown = nil
        countdown.show_go()
        countdown.play_go()
        local released, release_err = vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
        if not released then
            log("W", RACE_LOG_TAG, "could not release start lock: " .. tostring(release_err))
        end
        -- Release the EV throttle clamp now the freeze is lifting, so the car can pull away (ADR-0017
        -- amendment). Idempotent + a no-op on combustion cars / when never armed.
        disarm_freeze_hold_ve()
        M.state.freeze_hold_armed = false
        -- Arm checkpoint detection now the lock is released: it walks the race's traversal plan
        -- (sprint/circuit, ADR-0013), testing the local car against the planned-next checkpoint each
        -- frame (onUpdate) while racing (ADR-0010).
        local plan = M.state.race and M.state.race.plan
        if plan then
            M.state.detection = checkpoints.new(plan)
            M.state.post_orient = {}
        else
            log("W", RACE_LOG_TAG, "racing: no traversal plan; checkpoint detection disabled")
        end
        -- Circuit only: arm the client-side lap clock on the start/finish line (ADR-0022). It is a
        -- display-only derivation -- no server report -- so it never touches the scored plan above.
        local race_state = M.state.race
        if race_state and race_state.mode == "circuit" and race_state.checkpoints
            and race_state.checkpoints[1] then
            M.state.laptimer = laptimer.new(race_state.checkpoints[1])
        else
            M.state.laptimer = nil
        end
        -- Each race starts with its results card shown; a /results toggle only lasts that race.
        M.state.results_hidden = false
        -- Auto-show the HUD app for the race (ADR-0012); removed again on lobby. ensureAppVisible
        -- dedups, so a manually-added copy is not duplicated.
        hud.show()
    elseif phase == "finished" then
        -- Race over, but the results + props stay up for the long free-roam window (ADR-0006/0017
        -- amendments, B3). Release the in-race lock and hand the recover/repair keys back to vanilla
        -- now, so players can drive, switch vehicles, recover, and roam the track while results show.
        -- Everything else (race state, props, standings, HUD) lives on until the lobby teardown.
        lock.remove()
        disarm_assist_ve()
    elseif phase == "lobby" then
        -- Race over (back to lobby): despawn the track props/cones and drop all race state, but leave
        -- the player's vehicle exactly where it is -- never despawn or move it (only unfrozen, so a
        -- /raceend mid-countdown leaves the preserved car drivable). The abort-restart path skips
        -- lobby (finished -> spawning), where handle_race_start reloads props and re-freezes instead.
        teardown_race_world()
    end

    -- Surface the phase as a toast, except staging/countdown/racing -- the centered overlay covers
    -- those (the staging indicator, the count, and GO!).
    if phase ~= "staging" and phase ~= "countdown" and phase ~= "racing" then
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
-- so the client owns the list; ADR-0011: client->server reply). The relayed `all` flag (ADR-0026)
-- includes the deprecated quickrace source in the listing; otherwise it is hidden with a count hint.
local function handle_list_races(payload)
    local include_deprecated = type(payload) == "table" and payload.all == true
    send_to_server("raceList", {lines = racelist.build(maps.current(), include_deprecated)})
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
        -- The server keys custom-grid resolution on the issuer's map + the canonical race id (ADR-0023):
        -- only the client knows them. Sent on every verdict; harmless when no grid is configured. raceId
        -- lets a default assigned for the full id resolve whatever shorthand was typed for /race.
        map = maps.current(),
        raceId = result.raceId,
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

-- Toggle the local finished-results card on/off (the server relays a /results from this player; ADR-0022).
-- Local-only and per-player: it just flips a flag the HUD snapshot carries, so a player can look around
-- after finishing without affecting anyone else.
local function handle_results_toggle()
    M.state.results_hidden = not M.state.results_hidden
    log("I", RACE_LOG_TAG, "results card " .. (M.state.results_hidden and "hidden" or "shown"))
end

-- Surface grid-editor feedback both as a toast (visible while in-game) and in the log (visible in the
-- console where the command was typed). `kind` is a toastr type ("info"/"warning").
local function editor_feedback(msg, kind)
    if guihooks then
        guihooks.trigger("toastrMsg", {type = kind or "info", title = "BeamComp grid", msg = msg})
    end
    log("I", RACE_LOG_TAG, "grid editor: " .. msg)
end

-- Open a saved grid the server returned for a beamcomp_grid_edit fetch (ADR-0023). `found` false means
-- no such grid for this map; otherwise hand the record to the editor, which re-anchors to its race.
local function handle_grid_data(payload)
    if type(payload) ~= "table" or not payload.found then
        local name = type(payload) == "table" and payload.name or "?"
        editor_feedback("no saved grid '" .. tostring(name) .. "' on this map", "warning")
        return
    end
    local ok, result = grideditor.open({
        forward = payload.forward,
        reverse = payload.reverse,
        race = payload.race,
    })
    if ok then
        editor_feedback("editing saved grid '" .. tostring(payload.name) .. "' for " .. tostring(result))
    else
        editor_feedback(tostring(result), "warning")
    end
end

-- Post the current map's saved grid names from a beamcomp_grid_list request (ADR-0023).
local function handle_grid_list(payload)
    local names = type(payload) == "table" and payload.names or nil
    if type(names) ~= "table" or #names == 0 then
        editor_feedback("no saved grids on this map")
        return
    end
    editor_feedback("saved grids: " .. table.concat(names, ", "))
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
    standings = handle_standings,
    listRaces = handle_list_races,
    validateRace = handle_validate_race,
    finishGrace = handle_finish_grace,
    resultsToggle = handle_results_toggle,
    gridData = handle_grid_data,
    gridList = handle_grid_list,
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

-- Draw the grid editor's live preview poses as cyan pillars with P-slot labels (ADR-0023). Immediate-
-- mode: redrawn each frame from grideditor.state, so leaving edit mode (active = false) removes them
-- with no scene objects to clean up.
local function draw_editor_grid()
    if not grideditor.state.active or not grideditor.state.poses then
        return
    end
    local color = ColorF(0.2, 0.8, 1.0, 0.85)
    local label_fg = ColorF(1, 1, 1, 1)
    local label_bg = ColorI(0, 0, 0, 255)
    for index, pose in ipairs(grideditor.state.poses) do
        local p = pose.pos
        local base = vec3(p.x, p.y, p.z)
        local top = vec3(p.x, p.y, p.z + GRID_COLUMN_HEIGHT)
        debugDrawer:drawCylinder(base, top, GRID_COLUMN_RADIUS, color)
        debugDrawer:drawTextAdvanced(top, "P" .. (index - 1), label_fg, true, false, label_bg)
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

-- Smoothed gate-line angle (radians) for a checkpoint's player-facing posts: the line perpendicular
-- to the horizontal car->checkpoint direction, so the gate presents square-on to the approach. To
-- kill the fast swing as the car nears/crosses the center, the angle eases toward the target at no
-- more than POST_MAX_TURN_RATE and is frozen once the car is inside the volume (dist <= radius). A
-- gate line repeats every pi (the two posts are interchangeable), so the step is wrapped into
-- [-pi/2, pi/2] -- the shortest turn that lands on the same line. The per-checkpoint angle is cached
-- (keyed by stable index) in M.state.post_orient. Returns nil when there is no car position or the
-- car is horizontally at the center, signalling the caller to fall back to the stored-normal posts.
local function smooth_gate_angle(checkpoint, car_pos, dt, cache)
    if not car_pos then
        return nil
    end
    local p = checkpoint.pos
    local dx = p.x - car_pos.x
    local dy = p.y - car_pos.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
        return nil
    end
    local target = math.atan2(dy, dx) + math.pi / 2
    local key = checkpoint.index
    local current = cache[key]
    if current == nil then
        cache[key] = target
        return target
    end
    local radius = checkpoint.radius or MARKER_RADIUS
    if len <= radius then
        return current  -- frozen inside the volume: hold the last orientation
    end
    local diff = (target - current + math.pi / 2) % math.pi - math.pi / 2
    local max_step = POST_MAX_TURN_RATE * (dt or 0)
    if diff > max_step then
        diff = max_step
    elseif diff < -max_step then
        diff = -max_step
    end
    current = current + diff
    cache[key] = current
    return current
end

-- The two horizontal points (left, right) to draw the side posts at, from a smoothed gate-line angle
-- (smooth_gate_angle). Falls back to the stored-normal placement (gate_edges) when the angle is nil
-- (no car / degenerate) -- that fallback is itself nil for a pure-radius checkpoint, so no posts are
-- drawn that frame, the prior behavior.
local function post_edges(checkpoint, line_angle)
    if line_angle == nil then
        return gate_edges(checkpoint)
    end
    local perp_x = math.cos(line_angle)
    local perp_y = math.sin(line_angle)
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

-- Fade factor [0, 1] for a checkpoint's drive-through area cylinder, by the local car's horizontal
-- distance to the checkpoint center: full (1) at radius + CHECKPOINT_FADE_BAND and beyond, ramping
-- linearly to 0 at the volume edge (radius) so there is no wall to drive through up close. Only the
-- horizontal distance counts -- the column reaches hundreds of meters up/down and must not skew it.
-- With no car position resolved, stays at 1 so the marker shows as before.
local function area_fade_factor(checkpoint, car_pos)
    if not car_pos then
        return 1.0
    end
    local p = checkpoint.pos
    local dx = p.x - car_pos.x
    local dy = p.y - car_pos.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local radius = checkpoint.radius or MARKER_RADIUS
    local factor = (dist - radius) / CHECKPOINT_FADE_BAND
    return math.max(0.0, math.min(1.0, factor))
end

-- Draw one checkpoint as a singleplayer-style gate: a pale translucent column spanning the whole
-- checkpoint radius, plus two thin posts at the (already smoothed) player-facing gate-line angle.
-- The area column fades out as the local car (car_pos) nears the checkpoint; the posts stay solid.
local function draw_checkpoint_marker(checkpoint, style, car_pos, line_angle)
    local p = checkpoint.pos
    local radius = checkpoint.radius or MARKER_RADIUS
    local base = vec3(p.x, p.y, p.z - CHECKPOINT_COLUMN_DOWN)
    local top = vec3(p.x, p.y, p.z + CHECKPOINT_COLUMN_UP)
    local area = style.area
    local fade = area_fade_factor(checkpoint, car_pos)
    debugDrawer:drawCylinder(base, top, radius, ColorF(area.r, area.g, area.b, area.a * fade))

    local left, right = post_edges(checkpoint, line_angle)
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
-- mode (redrawn each frame, nothing to clean up). The next checkpoint is the
-- plan entry at detection.seq + 1, the look-ahead the entry after it; each cursor indexes the
-- checkpoints array (ADR-0013) -- so on a circuit they point at CP1 first and back at the start/
-- finish line (CP0) for the final crossing.
local function draw_next_checkpoint(race, detection, car_pos, dt)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return
    end
    local cache = M.state.post_orient
    if not cache then
        cache = {}
        M.state.post_orient = cache
    end
    local final_seq = #entries

    -- Circuit: before the lap clock arms (the run-up from the grid to the line), also draw the
    -- start/finish line itself, so the player sees the line the lap is counted from -- the scored
    -- plan's next marker is CP1, not this line (ADR-0022). Once the line is crossed (lt.started) it
    -- stops here and reappears later as the regular lap/finish marker. Stable index 0 keeps its own
    -- post-orient cache key, distinct from the next/look-ahead checkpoints. Purely visual.
    local lt = M.state.laptimer
    if lt and not lt.started and lt.start_cp then
        -- First-lap run-up: the start/finish line holds its true gate orientation (fixed stored
        -- normal, no car-tracking rotation) until the line is first crossed, so it reads as a proper
        -- start line rather than swinging to face the grid. A nil angle makes post_edges fall back to
        -- gate_edges (the stored normal). With no stored normal there is nothing to lock to, so keep
        -- the smoothed car-facing angle (the prior behavior, avoids dropping the posts). Once crossed
        -- (lt.started) the line reappears as the regular lap/finish marker and rotates normally again.
        local start_angle = nil
        if not lt.start_cp.normal then
            start_angle = smooth_gate_angle(lt.start_cp, car_pos, dt, cache)
        end
        draw_checkpoint_marker(lt.start_cp, marker_style(lt.start_cp, false), car_pos, start_angle)
    end

    local next_entry = entries[detection.seq + 1]
    local next_checkpoint = next_entry and race.checkpoints[next_entry.cursor]
    if not next_checkpoint then
        return
    end
    local next_style = marker_style(next_checkpoint, detection.seq + 1 == final_seq)
    local next_angle = smooth_gate_angle(next_checkpoint, car_pos, dt, cache)
    draw_checkpoint_marker(next_checkpoint, next_style, car_pos, next_angle)

    local ahead_entry = entries[detection.seq + 2]
    local ahead_checkpoint = ahead_entry and race.checkpoints[ahead_entry.cursor]
    if ahead_checkpoint then
        local ahead_angle = smooth_gate_angle(ahead_checkpoint, car_pos, dt, cache)
        draw_checkpoint_marker(ahead_checkpoint, LOOKAHEAD_STYLE, car_pos, ahead_angle)
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
    -- A scored crossing of the start/finish line closes a lap on the display clock (ADR-0022). The
    -- start node is the only plan entry at that stable index, so this fires once per lap, never on the
    -- body checkpoints. Done before the report so the report carries the just-completed lap's best.
    local lt = M.state.laptimer
    if lt and lt.start_cp and event.index == lt.start_cp.index then
        laptimer.complete_lap(lt, event.time)
    end
    -- `bestLap` rides the existing report as an additive field: the server stores the latest per
    -- player and relays it in the standings (ADR-0022) so the results card can show every player's
    -- best lap. The server stays race-blind -- it just passes the number through (ADR-0005).
    send_to_server("checkpoint", {
        seq = event.seq,
        index = event.index,
        name = event.name,
        lap = event.lap,
        time = event.time,
        count = count,
        bestLap = lt and lt.best or nil,
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

    -- Advance the circuit lap clock with the same car position + race clock (ADR-0022). Until it
    -- arms on the first start/finish crossing this watches the line; after that it is a no-op and
    -- lap boundaries arrive through on_checkpoint_reached above.
    if M.state.laptimer then
        laptimer.step(M.state.laptimer, veh_pos, detection.elapsed)
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
            -- Lap clock (ADR-0022): best lap is the server-relayed per-player value (so every results
            -- row has one); the local row prefers its own laptimer for an instant best + the live lap
            -- time. The header CP count is per-lap on a circuit (resets each lap), cumulative on sprint.
            local lap_time = nil
            local best_lap = e.best_lap
            local cp_in_lap = nil
            local cp_per_lap = nil
            if is_local then
                local_dnf = e.dnf and true or false
                local lt = M.state.laptimer
                if lt then
                    best_lap = lt.best or best_lap
                    if detection and phase == "racing" then
                        lap_time = laptimer.current(lt, detection.elapsed)
                    end
                end
                if detection and phase == "racing" then
                    cp_per_lap = (race and race.checkpoints) and #race.checkpoints or checkpoint_count
                    if (race and race.mode == "circuit") and cp_per_lap > 0 then
                        cp_in_lap = detection.seq % cp_per_lap
                    else
                        cp_in_lap = detection.seq
                    end
                end
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
                lapTime = lap_time,
                bestLap = best_lap,
                cpInLap = cp_in_lap,
                cpPerLap = cp_per_lap,
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
        isCircuit = (race and race.mode == "circuit") or false,
        resultsHidden = M.state.results_hidden or false,
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

-- Arm the seated car's VE EV-throttle clamp for the frozen phases (ADR-0017 amendment). Mirrors
-- push_assist_arm but is NOT gated on race.assists -- the EV creep guard applies to every race -- and
-- is tracked separately (freeze_hold_armed). The VE detects the drivetrain once and clamps the throttle
-- only on EVs, so a bare "arm" is all GE sends. Loads the VE extension first (not auto-loaded; see
-- push_assist_arm) and retries from onUpdate until the own car resolves.
local function push_freeze_hold()
    if M.state.freeze_hold_armed then
        return
    end
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end

    local command = "if not beamcomp_init then extensions.load('beamcomp_init') end "
        .. "if beamcomp_init then beamcomp_init.on_freeze_hold_arm() end"
    local ok, err = pcall(function() own_car:queueLuaCommand(command) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not arm freeze hold on VE: " .. tostring(err))
        return
    end
    M.state.freeze_hold_armed = true
end

-- Tell the seated car's VE to release the EV-throttle clamp (ADR-0017 amendment): the freeze is lifting
-- (racing) or the race is over. Best-effort -- if the car is gone the clamp died with it. Assigns the
-- forward-declared local so handle_race_phase / handle_race_start (above) can call it.
function disarm_freeze_hold_ve()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end
    pcall(function()
        own_car:queueLuaCommand("if beamcomp_init then beamcomp_init.on_freeze_hold_disarm() end")
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

-- Clear any in-progress assist countdown and its centered overlay (ADR-0017). Idempotent.
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

-- Lowercase verb for an assist kind, for the failure-feedback toasts ("Hold to <verb>").
local function assist_verb(kind)
    return (kind == "repair") and "repair" or "recover"
end

-- Warning toast telling the player WHY a recover/repair did not fire (ADR-0017 amendment): disabled,
-- not stationary, or released too early. Mirrors the lock's notify_spawn_blocked toast style.
local function notify_assist_blocked(msg)
    guihooks.trigger("toastrMsg", {
        type = "warning",
        title = "BeamComp",
        msg = msg,
    })
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
        notify_assist_blocked(((kind == "repair") and "Repair" or "Recover")
            .. " is disabled in this race")
        return
    end
    M.state.assist_held = kind
    M.state.assist_notice = nil
end

-- The held recover/repair key was released: drop the hold and cancel any running countdown. If a
-- countdown was actually mid-flight (not completed, not never-started), tell the player they let go
-- too early -- "released too early" is only a failure when the hold was genuinely running.
function M.on_assist_key_up()
    local was_arming = M.state.assist_arming ~= nil
    local kind = M.state.assist_held
    M.state.assist_held = nil
    clear_assist_arming()
    M.state.assist_notice = nil
    if was_arming and kind then
        notify_assist_blocked("Hold to " .. assist_verb(kind))
    end
end

-- Drive the hold-to-activate recover/repair each frame (ADR-0017): the countdown runs only while the
-- key is held AND the car is (near) stationary -- releasing or driving off cancels it. On completion
-- the held kind is consumed (cleared) so it does not immediately re-fire while the key is still down.
local function step_assist(dt_real)
    local held = M.state.assist_held
    if not held then
        clear_assist_arming()
        return
    end
    if not is_car_stationary() then
        -- Held while moving: cancel the hold and tell the player once (latched so it does not flood
        -- every frame the car keeps rolling).
        if M.state.assist_notice ~= "moving" then
            notify_assist_blocked("Stop the car to " .. assist_verb(held))
            M.state.assist_notice = "moving"
        end
        clear_assist_arming()
        return
    end

    local arming = M.state.assist_arming
    if not arming or arming.kind ~= held then
        local _, seconds = assist_setting(held)
        arming = {kind = held, remaining = seconds, last_shown = nil}
        M.state.assist_arming = arming
    end

    arming.remaining = arming.remaining - (dt_real or 0)
    if arming.remaining <= 0 then
        local kind = arming.kind
        clear_assist_arming()
        M.state.assist_held = nil
        perform_assist(kind)
        return
    end

    -- Push the centered overlay each whole second so it counts down live (the GE side drives it a
    -- beat at a time; ADR-0021).
    local shown = math.max(1, math.ceil(arming.remaining))
    if shown ~= arming.last_shown then
        arming.last_shown = shown
        countdown.show_assist(held == "repair" and "Repair" or "Recover", shown)
    end
end

-- Forward half-length (metres) of a vehicle's spawn bounding box, or nil if the API is unavailable.
-- This is the same measurement front_anchored_target uses to anchor the car's front on the grid line.
-- pcall: the bbox API is engine-version-coupled, so a mismatch reads as "unknown" rather than erroring.
local function spawn_oobb_forward(veh)
    local ok, half_y = pcall(function()
        return veh:getSpawnWorldOOBB():getHalfExtents().y
    end)
    if ok and type(half_y) == "number" then
        return half_y
    end
    return nil
end

-- Re-stage the staging car to its grid slot, front-anchored, once its jbeam has loaded. Two arming
-- paths share this one deferred placement:
--   1. A staging vehicle swap (ADR-0021/0017 amendments, staging-allow-vehicle-swap): the swap-allowed
--      lock leaves replaceVehicle open but wraps it to flag the replace (lock.consume_replace) -- the
--      reliable trigger, since a replace keeps the SAME vehicle id, so an id comparison never fires
--      (confirmed in-game: the swap produced no adoption). The replacement spawns unfrozen, would drive
--      off in the countdown, and reloads its VE (losing the assist override + EV clamp).
--   2. A fresh-spawn default car (no own car at race start, default-vehicle-when-player-has-none):
--      handle_race_start arms restage_pending directly, since the spawn path lands it center-anchored.
-- Either way we re-place it at the grid slot, re-freeze it, and clear the VE-arm flags so onUpdate
-- re-arms the VE.
--
-- The grid re-placement is DEFERRED: a freshly replaced or spawned car keeps reporting a stale bounding
-- box for a moment while its jbeam loads, so front-anchoring immediately uses the wrong footprint and
-- lands a differently-sized car offset (confirmed in-game: small -> large swap sat too far forward). We
-- record the footprint on the first pending frame and wait until the spawn bbox's forward half-length
-- changes by RESTAGE_MIN_DELTA (new jbeam loaded), or until RESTAGE_MAX_WAIT elapses (same-size swap,
-- where placing with the unchanged box is correct anyway).
local function restage_swapped_car(dt_real)
    if not M.state.race_car_id then
        return
    end

    -- A replace happened: (re)start a pending re-placement. Re-arming the VE waits until placement, when
    -- the new jbeam is loaded -- queueing to a still-loading VE would be lost.
    if lock.consume_replace() then
        M.state.restage_pending = true
        M.state.restage_baseline = nil
        M.state.restage_wait = RESTAGE_MAX_WAIT
        log("I", RACE_LOG_TAG, "staging vehicle replace detected; re-staging")
    end

    if not M.state.restage_pending then
        return
    end

    local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own then
        return
    end

    -- Record the footprint on the first pending frame (still the old car), then wait for it to change
    -- (new jbeam loaded) or for the fallback timeout.
    local current = spawn_oobb_forward(own)
    if M.state.restage_baseline == nil then
        M.state.restage_baseline = current
    end
    M.state.restage_wait = (M.state.restage_wait or 0) - (dt_real or 0)
    local baseline = M.state.restage_baseline
    local loaded = current ~= nil and baseline ~= nil and math.abs(current - baseline) > RESTAGE_MIN_DELTA
    if not loaded and M.state.restage_wait > 0 then
        return
    end

    -- Adopt the staging car: re-point the bounce target, re-place front-anchored to its now-correct
    -- footprint, re-freeze, and clear the VE-arm flags so onUpdate re-arms its VE this frame.
    local own_id = own:getId()
    M.state.race_car_id = own_id
    M.state.current_vehicle_id = own_id
    local pose = M.state.race and M.state.race.myPose
    if pose then
        local placed, place_err = vehicles.respawn_own_at(pose, own)
        if not placed then
            log("W", RACE_LOG_TAG, "could not re-place staging car: " .. tostring(place_err))
        end
    end
    vehicles.set_vehicle_frozen(own, true)
    M.state.assist_armed = false
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
    log("I", RACE_LOG_TAG, "re-placed staging car at grid slot as race car " .. tostring(own_id))
end

-- Tick the staging-wait indicator in wall time (ADR-0021): count the local copy of the server's
-- auto-start window down and push the remaining whole seconds to the centered overlay only when the
-- shown second changes. The server stays authoritative on the actual staging->countdown transition.
local function step_staging(dt_real)
    local staging = M.state.staging
    if not staging then
        return
    end
    staging.remaining = math.max(0, staging.remaining - (dt_real or 0))
    local shown = math.ceil(staging.remaining)
    if shown ~= staging.last_shown then
        staging.last_shown = shown
        countdown.show_staging(shown)
    end
end

-- Tick the start countdown in wall time off the server-issued duration (ADR-0021): render each whole
-- second on the centered overlay and play the final 3-2-1 beeps as the shown number changes. GO! and
-- the actual release are driven by the server `racing` phase, not this tick.
local function step_start_countdown(dt_real)
    local count = M.state.countdown
    if not count then
        return
    end
    count.remaining = math.max(0, count.remaining - (dt_real or 0))
    local shown = math.max(1, math.ceil(count.remaining))
    if shown ~= count.last_shown then
        count.last_shown = shown
        countdown.show_start(shown)
        countdown.play_beat(shown)
    end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
    if M.state.phase == "staging" and M.state.race then
        -- Tick the staging-wait indicator on the centered overlay (ADR-0021).
        step_staging(dtReal)
        -- Adopt a staging car swap as the new race car (re-freeze + bounce target + VE re-arm).
        restage_swapped_car(dtReal)
    elseif M.state.phase == "countdown" and M.state.race then
        -- Tick the start countdown on the centered overlay (ADR-0021).
        step_start_countdown(dtReal)
    elseif M.state.phase == "racing" and M.state.race then
        step_detection(dtSim)
        -- Drive the held recover/repair countdown (ADR-0017).
        step_assist(dtReal)
        -- Tick the finish-grace countdown in wall time (the server's cutoff is wall-time; ADR-0014).
        -- Visual only -- the server stays authoritative on the actual DNF cutoff.
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
    end
    -- Arm the seated car's VE key forwarders across the locked sequence (staging + countdown + racing).
    -- The first successful arm installs the override + reset guard, so vanilla recover/reset is never
    -- available mid-race even with both assists off (ADR-0017). It must cover staging too: the lock
    -- arms there (ADR-0021), but the recover keys are owned by this VE override (not action-filtered),
    -- so without it Insert/Ctrl+Insert would still trigger vanilla recover and break the grid freeze.
    if (M.state.phase == "staging" or M.state.phase == "countdown" or M.state.phase == "racing")
        and M.state.race then
        push_assist_arm()
    end
    -- Arm the EV start-freeze throttle clamp over the frozen phases only (staging + countdown), so it
    -- lifts on racing with the GE freeze (ADR-0017 amendment). The VE clamps only on EVs.
    if (M.state.phase == "staging" or M.state.phase == "countdown") and M.state.race then
        push_freeze_hold()
    end
    -- Keep pushing during the finished phase too so the results template (ADR-0012) renders the
    -- frozen final standings, not the last frame caught mid-racing.
    if (M.state.phase == "racing" or M.state.phase == "finished") and M.state.race then
        hud.push(build_hud_snapshot())
    end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
    if not debugDrawer then
        return
    end
    -- Nothing to draw with no race and no edit session (the common free-roam case): skip before building
    -- the pcall closure so the idle path stays zero-work.
    if not M.state.race and not grideditor.state.active then
        return
    end
    -- Guard the draws: debugDrawer's exact API is runtime-confirmed here, so a mismatch warns once
    -- rather than spamming every frame. The editor preview draws independent of a race (it is used in
    -- free-roam); the next-checkpoint marker only while a race is racing.
    local ok, err = pcall(function()
        draw_editor_grid()
        local race = M.state.race
        if race then
            local detection = M.state.detection
            if M.state.phase == "racing" and detection and not detection.done then
                -- Use the same owned car the detector crosses checkpoints with (step_detection), so the
                -- posts face the point that actually triggers the gate, not a different camera vehicle.
                local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
                local car_pos = own_car and own_car:getPosition()
                draw_next_checkpoint(race, detection, car_pos, dtReal)
            end
        end
    end)
    if not ok and not M.state.marker_warned then
        M.state.marker_warned = true
        log("W", RACE_LOG_TAG, "marker draw failed (debugDrawer API?): " .. tostring(err))
    end
end

-- The level is ending -- the player left the BeamMP session or changed level, possibly mid-race.
-- The extension is pinned to manual unload (onExtensionLoaded) so it survives level switches during a
-- race, which means onExtensionUnloaded does NOT fire here; without this hook a mid-race exit would
-- orphan the spawned props/cones into the next singleplayer load of the same map. Tear the race world
-- down but keep the BeamMP handler registered -- the extension lives on for the next race. Mirrors
-- core/groundMarkers + core/checkpoints, which reset their scene state on onClientEndMission likewise.
function M.onClientEndMission(_levelPath)
    teardown_race_world()
    M.state.phase = nil
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    grideditor.clear()
    spawn_mute.restore()
    -- Despawn props/cones, lift the in-race lock + start freeze, and drop all race state so a reload
    -- mid-race never leaves orphaned scenery or a stuck-frozen/locked car (ADR-0017).
    teardown_race_world()
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

-- The grid-editor command surface (ADR-0023). These are intentionally GLOBAL so they can be typed
-- straight into the BeamNG GE Lua console (the only authoring UI this iteration). Each is a thin
-- wrapper over race/grideditor (preview, client-local), with save/assign/fetch/list going over
-- send_to_server (server owns the shared grids file; save/assign are admin-gated server-side).
-- Knobs (beamcomp_grid_set):
--   offsetForward  -- shift the whole grid forward/back along the travel axis (m)
--   offsetLateral  -- shift the whole grid left/right (m)
--   rowGap         -- spacing between positions front-to-back (m)
--   colGap         -- spacing between positions left-to-right (m)
--   headingDeg     -- rotate the whole grid about vertical (deg)
--   rows           -- number of rows (columns = ceil(field / rows); columns auto-stagger by rowGap/cols)

-- GE console command (intentionally global): start a fresh grid from the track's generated layout.
function beamcomp_grid_new(race_name)
    local ok, reason = grideditor.start_fresh(race_name)
    if ok then
        editor_feedback("editing new grid for '" .. tostring(reason)
            .. "' -- tune with beamcomp_grid_set(\"<knob>\", <value>)")
    else
        editor_feedback(tostring(reason), "warning")
    end
end

-- GE console command (intentionally global): open a SAVED grid by name for further editing. The grid
-- lives on the server, so we request it (gridFetch); handle_grid_data opens it when the reply arrives.
function beamcomp_grid_edit(grid_name)
    if type(grid_name) ~= "string" or grid_name == "" then
        editor_feedback("usage: beamcomp_grid_edit(\"<gridname>\")", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    send_to_server("gridFetch", {map = map, name = grid_name})
    editor_feedback("opening saved grid '" .. grid_name .. "' ...")
end

-- GE console command (intentionally global): list the grids saved for the current map (gridListReq).
function beamcomp_grid_list()
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    send_to_server("gridListReq", {map = map})
end

-- GE console command (intentionally global)
function beamcomp_grid_set(knob, value)
    local ok, applied = grideditor.set(knob, value)
    if ok then
        editor_feedback(tostring(knob) .. " = " .. tostring(applied))
    else
        -- On failure the second return is the reason string.
        editor_feedback(tostring(applied), "warning")
    end
end

-- GE console command (intentionally global)
function beamcomp_grid_dir(direction)
    local ok, reason = grideditor.set_direction(direction)
    if ok then
        editor_feedback("editing " .. tostring(direction) .. " block")
    else
        editor_feedback(tostring(reason), "warning")
    end
end

-- GE console command (intentionally global)
function beamcomp_grid_save(name)
    if type(name) ~= "string" or name == "" then
        editor_feedback("usage: beamcomp_grid_save(\"<name>\")", "warning")
        return
    end
    if name:find("%s") then
        -- A name with spaces could never be selected via /race grid=<name> (the arg parser splits on
        -- whitespace), so reject it at the source.
        editor_feedback("grid name must not contain spaces", "warning")
        return
    end
    local snapshot = grideditor.snapshot(name)
    if not snapshot then
        editor_feedback("not editing -- beamcomp_grid_new(\"<race>\") first", "warning")
        return
    end
    send_to_server("gridSave", snapshot)
    editor_feedback("saving grid '" .. name .. "' ...")
end

-- GE console command (intentionally global): bind a saved grid as the default for a race. Race + grid
-- are explicit, so it works without an active edit session; the race is resolved to its canonical id.
function beamcomp_grid_assign(race_name, grid_name)
    if type(race_name) ~= "string" or race_name == "" or type(grid_name) ~= "string" or grid_name == "" then
        editor_feedback("usage: beamcomp_grid_assign(\"<race>\", \"<gridname>\")", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    local race_id, reason = race_start.resolve_id(race_name)
    if not race_id then
        editor_feedback(tostring(reason), "warning")
        return
    end
    send_to_server("gridAssign", {map = map, race = race_id, name = grid_name})
    editor_feedback("assigning '" .. grid_name .. "' as default for " .. race_id .. " ...")
end

-- GE console command (intentionally global): despawn the preview pillars and leave edit mode.
function beamcomp_grid_cancel()
    grideditor.clear()
    editor_feedback("grid editing ended -- pillars cleared")
end

return M
