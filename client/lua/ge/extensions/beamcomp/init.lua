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
local carlist = require("beamcomp/race/carlist")
local maps = require("beamcomp/race/maps")
local grideditor = require("beamcomp/race/grideditor")
local placement = require("beamcomp/race/placement")
local ai = require("beamcomp/race/ai")

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
local CHECKPOINT_FADE_BAND = 60.0       -- meters above the radius over which the area cylinder fades
                                        -- in: full alpha at radius + this, alpha 0 at the volume edge.
                                        -- Doubles as the band over which the gate posts ease from
                                        -- player-facing to the stored gate normal (gate_line_angle).
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

-- How long to keep retrying BeamMP nametag suppression on a freshly synced cone before giving up. A
-- remote-synced cone is registered in MPVehicleGE asynchronously, a frame or two after onVehicleSpawned
-- fires, so the one-shot hide_nametag there misses it; we retry from onUpdate until it sticks. The
-- timeout is only the give-up bound (registration normally settles almost immediately); on timeout the
-- tag simply stays -- the same accepted fallback as before (ADR-0020 finding #4).
local NAMETAG_RETRY_TIMEOUT = 10.0

-- Seconds to wait for a (swapped or freshly-spawned) car's jbeam to finish loading before re-placing it
-- anyway (fallback for a same-footprint swap, where the bbox never visibly changes). Forward
-- half-length change (metres) that signals the new jbeam has loaded and the bbox now reflects the
-- actual car. Used by restage_swapped_car; declared here so handle_race_start can arm the same flow.
local RESTAGE_MAX_WAIT = 3.0
local RESTAGE_MIN_DELTA = 0.2

-- AI count past which the owner gets a one-shot performance hint (ADR-0036 Etappe B): all AI physics run
-- on the host, so a larger field is heavier on the owner's machine.
local AI_PERF_HINT_THRESHOLD = 6

-- Reload-surviving state (BeamNG serializes M.state across a Lua reload).
M.state = {
    last_event_at = 0,
    registered = false,
    race = nil,          -- current race-start state (slot, poses, roster) or nil
    phase = nil,         -- current server-authoritative race phase (ADR-0006) or nil
    marker_warned = false,
    prop_names = nil,    -- names of the prop prefabs we spawned, for cleanup (or nil)
    cone_ids = nil,      -- ids of the shared cone vehicles we spawned + must clear (host only, ADR-0020)
    pending_nametag = nil,  -- map of cone game-id -> seconds waited for MPVehicleGE nametag suppression to stick; lazily created, nil when idle (ADR-0020)
    current_vehicle_id = nil,  -- game id of the vehicle the player is in, tracked via onVehicleSwitched
    race_car_id = nil,   -- game id of this client's race car; bounce target for the in-race switch lock
    detection = nil,     -- checkpoint-detection progress (race/checkpoints), armed on the racing phase
    laptimer = nil,      -- circuit lap-clock state (race/laptimer), armed on racing; display only (ADR-0022)
    results_hidden = false,  -- local-only toggle: hide the finished results card via /results (ADR-0022)
    race_records = nil,      -- pre-run PB + track record for the post-race analysis overlay (server raceRecords, ADR-0028), or nil
    analysis_open = false,   -- local-only toggle: show the post-race analysis overlay via /analysis or the card button (ADR-0028)
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
    ai_cars = nil,            -- host only: spawned AI cars {id, slot, label, veh_id} to freeze/drive/score/clear (ADR-0036), or nil
    ai_config = nil,          -- host only: relayed AI difficulty/vehicle config {preset, car, params} (ADR-0036 Etappe B), or nil
    ai_detections = nil,      -- host only: per-AI checkpoint-detection state keyed by AI id, armed on racing (ADR-0036), or nil
    ai_map_pending = false,   -- host only: the aiMap (AI server ids) still has unresolved cars to broadcast (ADR-0036)
    ai_remote_ids = nil,      -- non-owner: set of local game ids resolved as AI cars from the relayed aiMap (ADR-0036), or nil
    ai_server_ids = nil,      -- non-owner: set of BeamMP server ids from the latest aiMap awaiting local resolution (ADR-0036), or nil
}

-- Client->server send primitive; defined below but forward-declared so the event handlers (and the
-- HANDLERS table) above its definition can reference it.
local send_to_server

-- Reports this client's BeamNG license name as the canonical identity (ADR-0031); defined far below but
-- called from handle_race_start (at spawn) above its definition, so forward-declared here.
local report_identity

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
        M.state.race_records = nil
        M.state.analysis_open = false
        M.state.grace = nil
        M.state.assist_armed = false
        M.state.assist_held = nil
        M.state.assist_arming = nil
        M.state.assist_notice = nil
        M.state.freeze_hold_armed = false
        -- Clear any AI cars from a prior race too (ADR-0036): on an abort-restart this client may have
        -- been the previous owner, so its host-spawned AI must not linger into a race it is not in.
        ai.stop(M.state.ai_cars or {})
        ai.clear(M.state.ai_cars or {})
        M.state.ai_cars = nil
        M.state.ai_config = nil
        M.state.ai_detections = nil
        M.state.ai_map_pending = false
        M.state.ai_remote_ids = nil
        M.state.ai_server_ids = nil
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
    M.state.race_records = nil
    M.state.analysis_open = false
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

    -- Clear any AI cars from a prior race up front so a re-issued /race never stacks them (ADR-0036), the
    -- same reason cones are cleared here. Host-only state; all nil on a non-owner. The new AI cars are
    -- spawned at the end, once this client's own car is placed.
    ai.stop(M.state.ai_cars or {})
    ai.clear(M.state.ai_cars or {})
    M.state.ai_cars = nil
    M.state.ai_config = nil
    M.state.ai_detections = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil

    -- Place this client's own car at the assigned grid pose: the car the player is in is repaired +
    -- teleported in place (preserving its settings), or a fresh one is spawned as a fallback
    -- (ADR-0007). Owned-only + BeamMP-propagated (see race/vehicles.lua). The grid markers keep
    -- rendering from M.state.race regardless.
    -- The relayed vehicle policy (ADR-0032), read straight off the payload like propOwner (not via
    -- race_start.prepare, which only handles race geometry): car = fixed car for all (Mode 2),
    -- maxhp/maxpwr = per-player power / power-to-weight caps (Mode 3), all nil = keep own car (Mode 1).
    local policy = {
        car = payload.car,
        maxhp = payload.maxhp,
        maxpwr = payload.maxpwr,
    }
    local race_car, respawn_err, policy_abort = vehicles.respawn_own_at(race.myPose, own_car, policy)
    if policy_abort then
        -- Mode-3 abort: no installed car meets the cap (ADR-0032). Warn the player and bail BEFORE the
        -- spawnReady ack so the server's spawning gate is not told we're in. The gate's timeout caps the
        -- wait; if every player aborts, the 0-ack path cancels the race (ADR-0006). Drop the race state
        -- so countdown/lock/HUD never target a car we never got.
        log("W", RACE_LOG_TAG, "vehicle policy abort: " .. tostring(respawn_err))
        guihooks.trigger("toastrMsg", {
            type = "error",
            title = "BeamComp -- " .. race.name,
            msg = "No car under the limit -- you can't join (" .. tostring(respawn_err) .. ")",
        })
        M.state.race = nil
        M.state.race_car_id = nil
        M.state.detection = nil
        M.state.laptimer = nil
        lock.remove()
        countdown.clear()
        hud.clear()
        return
    end
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

    -- Tell the server this client is spawned + seated so it can leave the spawning phase once everyone
    -- is ready instead of waiting a fixed delay (ADR-0006 amendment). Sent unconditionally -- even if
    -- placement degraded above -- so a spawn hiccup never hangs the race; the deferred restage (if any)
    -- runs after this and does not gate the ack. Echo payload.race (the exact name the server relayed,
    -- == session.race), not the resolved race.meta.name, so the server's stale-ack guard matches.
    send_to_server("spawnReady", {race = payload.race})

    -- Report the vehicle metadata so the server can record what car was driven (ADR-0027). A dedicated
    -- message, not piggybacked on the ack above, so the spawnReady contract stays narrow. Echo
    -- payload.race like the ack so the server's race-guard matches. Sent unconditionally;
    -- collect_client_info degrades every field to nil on a spawn hiccup. The player identity rides a
    -- separate clientIdentity message (below), since it is connection-scoped, not per-race (ADR-0031).
    local client_info = vehicles.collect_client_info(race_car)
    send_to_server("clientInfo", {
        race = payload.race,
        vehicle = client_info.vehicle,
        -- Power-to-weight for the start-order pwr mode (ADR-0033); nil when unreadable. The server stores
        -- it per player and only sorts by it -- it never reads the vehicle (race-blind, ADR-0005).
        pwr = client_info.pwr,
    })

    -- Refresh the canonical identity from the race car now that it exists (ADR-0031): the license name
    -- needs a vehicle, and this is the reliable point where one is guaranteed -- the connect-time report
    -- is only best-effort. The server resolves identities live, so a name arriving here updates the
    -- standings/records for this race.
    report_identity(race_car)

    -- Host only: spawn the AI opponents the server assigned this client (ADR-0036). Only the owner's
    -- raceStart carries aiSlots, so non-owners skip this entirely -- they just receive the synced cars and
    -- the aiMap. The cars spawn frozen at their grid poses (held through staging/countdown, released on
    -- racing), are kept out of this client's Tab cycle, and are queued for the aiMap broadcast that lets
    -- remotes label + suppress them. The spawn-notification mute armed above also covers their burst.
    if type(payload.aiSlots) == "table" and #payload.aiSlots > 0 then
        -- The relayed AI difficulty/vehicle config (ADR-0036 Etappe B), owner-only; the driving params and
        -- the per-car vehicle choice resolve from it plus the race's content defaults.
        M.state.ai_config = payload.aiConfig
        -- The AI vehicle chain reuses the relayed player policy (ADR-0032) as its second tier.
        local cars = ai.spawn(payload.aiSlots, race.gridPoses, payload.aiConfig, race.aiDefaults, policy)
        if #cars > 0 then
            ai.set_frozen(cars, true)
            for _, car in ipairs(cars) do
                local veh = be and be:getObjectByID(car.veh_id)
                if veh then
                    ai.suppress(veh)
                    -- Report this AI car's power-to-weight by proxy (ADR-0036 Etappe B) so the server can
                    -- sort it into an order=pwr grid (ADR-0033); aiId-tagged, owner-only. Best-effort: a
                    -- nil pwr just leaves the AI in its provisional back-of-grid slot.
                    send_to_server("clientInfo", {
                        race = payload.race,
                        aiId = car.id,
                        pwr = vehicles.collect_client_info(veh).pwr,
                    })
                end
            end
            M.state.ai_cars = cars
            M.state.ai_map_pending = true  -- broadcast the server-id map once BeamMP registers the cars
            -- Spawning a car auto-enters the player into it, so after the AI burst the player can be
            -- sitting in the last AI car. Re-seat them in their own race car and re-assert it as the
            -- tracked seated car so the detector keeps reading the right vehicle.
            if race_car and be then
                pcall(function() be:enterVehicle(0, race_car) end)
                M.state.current_vehicle_id = race_car:getId()
            end
            log("I", RACE_LOG_TAG, string.format("spawned %d AI opponent(s)", #cars))
            -- Performance hint (ADR-0036 Etappe B): all AI physics run on this host, so warn once past a
            -- handful. Owner-local + non-blocking -- it never gates the spawn.
            if #cars >= AI_PERF_HINT_THRESHOLD then
                guihooks.trigger("toastrMsg", {
                    type = "warning",
                    title = "BeamComp -- AI",
                    msg = string.format("%d AI cars run on your machine -- expect higher load.", #cars),
                })
            end
        end
    end
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
    -- Despawn the host's AI cars (ADR-0036): stop them first so none lurches on the delete frame.
    -- Idempotent + host-only (all nil on a non-owner). Remote AI id sets are just dropped below.
    ai.stop(M.state.ai_cars or {})
    ai.clear(M.state.ai_cars or {})
    M.state.ai_cars = nil
    M.state.ai_config = nil
    M.state.ai_detections = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.race = nil
    M.state.race_car_id = nil
    M.state.detection = nil
    M.state.laptimer = nil
    M.state.standings = nil
    M.state.race_records = nil
    M.state.analysis_open = false
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
        else
            log("W", RACE_LOG_TAG, "racing: no traversal plan; checkpoint detection disabled")
        end
        -- Host only: release the AI cars, hand them to BeamNG's AI to drive the route, and arm one
        -- checkpoint detector per AI so the host scores them by proxy each frame (ADR-0036). Non-owners
        -- have no ai_cars, so this is inert for them -- the AI cars just sync in and drive on the owner.
        if M.state.ai_cars and #M.state.ai_cars > 0 and plan and M.state.race then
            ai.set_frozen(M.state.ai_cars, false)
            -- Drive BeamNG's authored AI navgraph path when the content ships one (aiWaypoints), else fall
            -- back to the navgraph snap of the dense route points, else the visible checkpoints, for the
            -- race's full lap count so the AI runs every lap (ADR-0036 Step-3 three-tier source). The
            -- resolved difficulty params (ADR-0036 Etappe B) come from the relayed config + content.
            local ai_params = ai.resolve_params(M.state.ai_config, M.state.race.aiDefaults)
            local ai_route = ai.drive(M.state.ai_cars, M.state.race.aiWaypoints,
                M.state.race.routePoints or M.state.race.checkpoints, M.state.race.laps, ai_params,
                M.state.race.mode == "circuit")
            -- Tell the server which route variant the AI got so it posts it to chat (the owner drives the
            -- AI, so only the owner reports this); lets players see authored vs navgraph-snap at a glance.
            if ai_route then
                send_to_server("aiRouteNotice", ai_route)
            end
            local detections = {}
            for _, car in ipairs(M.state.ai_cars) do
                detections[car.id] = checkpoints.new(plan)
            end
            M.state.ai_detections = detections
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
        -- Each race starts with its results card shown and its analysis overlay closed; the /results and
        -- /analysis toggles only last that race (ADR-0022/0028).
        M.state.results_hidden = false
        M.state.analysis_open = false
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

-- Answer the server's listVehicles request (/cars, ADR-0032): the vehicle-blind server (ADR-0005)
-- relays the optional model token, we build the installed-vehicle listing locally and ship the chat
-- lines back for the server to post (ADR-0011). A model lists that model's configs; nil lists all models.
local function handle_list_vehicles(payload)
    local model = type(payload) == "table" and payload.model or nil
    send_to_server("vehicleList", {lines = carlist.build(model)})
end

-- Re-place the owner's host-driven AI cars onto their re-gridded poses (ADR-0036 Etappe B). `ai_slots` is
-- the {id, slot} list the pwr re-grid sends the owner (ADR-0033); for each, update the tracked car's
-- slot/pose and front-anchor it at the new grid pose, re-frozen until racing. No-op for a non-owner (no
-- ai_cars) or a missing car/pose. Mirrors the player re-place below, run per AI car.
local function replace_ai_for_regrid(ai_slots)
    if type(ai_slots) ~= "table" or not M.state.ai_cars or not M.state.race then
        return
    end
    local poses = M.state.race.gridPoses
    if type(poses) ~= "table" then
        return
    end
    local car_by_id = {}
    for _, car in ipairs(M.state.ai_cars) do
        car_by_id[car.id] = car
    end
    for _, entry in ipairs(ai_slots) do
        local car = car_by_id[entry.id]
        local pose = (type(entry.slot) == "number") and poses[entry.slot + 1] or nil
        if car and pose then
            car.slot = entry.slot
            car.pose = pose
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                vehicles.place_at_grid(veh, pose)
                vehicles.set_vehicle_frozen(veh, true)
            end
        end
    end
end

-- The server re-gridded the start order (ADR-0033, order=pwr): adopt the new slot, re-place the race car
-- at its new grid pose (picked from the pose set we already hold), and re-freeze. Mirrors
-- restage_swapped_car; runs during staging, before the countdown. No-op if we are not in this race or the
-- car/pose is unavailable -- the spawn-freeze on the old pose then just holds the car where it is. The
-- owner's regrid also carries its AI cars' new slots (ADR-0036 Etappe B), re-placed first.
local function handle_regrid(payload)
    if not M.state.race or type(payload) ~= "table" then
        return
    end
    -- Re-place the host's AI cars (owner-only; no-op otherwise) before the own-car logic, so a missing
    -- own slot/pose below never skips the AI re-place.
    replace_ai_for_regrid(payload.aiSlots)
    local slot = payload.slot
    local poses = M.state.race.gridPoses
    local pose = (type(slot) == "number" and poses) and poses[slot + 1] or nil
    if not pose then
        log("W", RACE_LOG_TAG, "regrid ignored: no pose for slot " .. tostring(slot))
        return
    end
    M.state.race.mySlot = slot
    M.state.race.myPose = pose
    if type(payload.grid) == "table" then
        M.state.race.roster = payload.grid
    end

    local race_car = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if not race_car then
        log("W", RACE_LOG_TAG, "regrid: no race car to re-place")
        return
    end
    local placed, place_err = vehicles.respawn_own_at(pose, race_car)
    if not placed then
        log("W", RACE_LOG_TAG, "regrid re-place failed: " .. tostring(place_err))
        return
    end
    vehicles.set_vehicle_frozen(race_car, true)
    log("I", RACE_LOG_TAG, string.format("re-gridded to slot %d", slot))
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
        -- The aiRace content AI defaults (ADR-0036 Etappe B): the server uses aiDefaults.count to seed the
        -- AI slots when /race requested AI without an explicit number. nil for non-aiRace content.
        aiDefaults = result.aiDefaults,
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

-- Toggle the local post-race analysis overlay (ADR-0028). Public so the results-card button can call it
-- via bngApi.engineLua (UI -> GE, ADR-0012); the /analysis command routes here through the
-- analysisToggle handler. The overlay only renders in the finished phase (the snapshot gates it), so a
-- flip in any other phase is inert -- it is reset to closed on each racing start and on lobby teardown.
function M.toggle_analysis()
    M.state.analysis_open = not M.state.analysis_open
    log("I", RACE_LOG_TAG, "analysis overlay " .. (M.state.analysis_open and "shown" or "hidden"))
end

-- The /analysis relay (server -> this client) flips the same overlay flag as the results-card button.
local function handle_analysis_toggle()
    M.toggle_analysis()
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

-- A server bestNotice: this client set a personal best and/or the race's track record (ADR-0027).
-- Surface it as a toast; the track record wins the message when both are set.
local function handle_best_notice(payload)
    if type(payload) ~= "table" or (not payload.pb and not payload.trackRecord) then
        return
    end
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp",
        msg = payload.trackRecord and "New track record!" or "New personal best!",
    })
end

-- A server raceRecords: this race's pre-run best times for the post-race analysis overlay (ADR-0028) --
-- the local player's own personal-best record (pb) and the cross-player track record (trackRecord),
-- both as the opaque numbers the records store holds. Store as-is; build_hud_snapshot derives the
-- per-CP deltas client-side. Cleared on lobby teardown.
local function handle_race_records(payload)
    if type(payload) ~= "table" then
        return
    end
    M.state.race_records = {
        race = payload.race,
        car = payload.car,
        pb = payload.pb,
        trackRecord = payload.trackRecord,
        driverTotals = payload.driverTotals,
        prerun = payload.prerun,
    }
end

-- Non-owner: resolve the relayed aiMap (BeamMP server ids) to local synced game ids, marking each AI car
-- so it is kept out of the Tab cycle and the owner's nametag is suppressed on it (ADR-0036). Scans the
-- scene for a vehicle whose cross-client server id is in the pending set; a match is recorded in
-- ai_remote_ids and dropped from the pending set, so the scan shrinks and stops once all resolve.
-- Retried from onUpdate + onVehicleSpawned, since a synced car may not exist yet at relay time. The
-- server-id read is SPIKE #2 (race/ai): if it never resolves, the cars keep the owner's tag -- the same
-- accepted fallback as the cones (ADR-0020). No-op when nothing is pending.
local function resolve_remote_ai()
    local pending = M.state.ai_server_ids
    if not pending or not be then
        return
    end
    M.state.ai_remote_ids = M.state.ai_remote_ids or {}
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        local server_id = veh and ai.server_id_of(veh) or nil
        if server_id ~= nil and pending[tostring(server_id)] then
            M.state.ai_remote_ids[veh:getID()] = true
            ai.suppress(veh)
            pending[tostring(server_id)] = nil
        end
    end
    if next(pending) == nil then
        M.state.ai_server_ids = nil
    end
end

-- Non-owner handler for the owner's aiMap (ADR-0036): the server ids of the synced AI cars. Store them as
-- a pending set and resolve to local handles now (retried until the synced cars exist). The owner ignores
-- its own relayed map -- it already tracks ai_cars locally.
local function handle_ai_map(payload)
    if M.state.ai_cars then
        return
    end
    local entries = type(payload) == "table" and payload.entries or nil
    if type(entries) ~= "table" then
        return
    end
    local pending = {}
    for _, entry in ipairs(entries) do
        if entry.serverId ~= nil then
            pending[tostring(entry.serverId)] = true
        end
    end
    M.state.ai_server_ids = pending
    resolve_remote_ai()
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
    standings = handle_standings,
    listRaces = handle_list_races,
    listVehicles = handle_list_vehicles,
    regrid = handle_regrid,
    aiMap = handle_ai_map,
    validateRace = handle_validate_race,
    finishGrace = handle_finish_grace,
    resultsToggle = handle_results_toggle,
    analysisToggle = handle_analysis_toggle,
    gridData = handle_grid_data,
    gridList = handle_grid_list,
    bestNotice = handle_best_notice,
    raceRecords = handle_race_records,
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

-- Gate-line angle (radians) for a checkpoint's player-facing posts, eased toward the gate's true
-- orientation by distance. The far target is the line perpendicular to the horizontal car->checkpoint
-- direction (the gate presents square-on to the approach); the near target is the line of the stored
-- gate normal (its real orientation). Across the same band the area fade uses, the angle blends
-- linearly from fully player-facing at radius + CHECKPOINT_FADE_BAND to fully normal-facing at the
-- volume edge (dist <= radius), where it then rests -- so the closer the car, the less the gate swings
-- and it ends square on its true line (the freeze edge = 100% normal). A gate line repeats every pi
-- (the two posts are interchangeable), so the blend step is wrapped into [-pi/2, pi/2] -- the shortest
-- turn onto the same line. A checkpoint without a stored normal has no true line to ease toward, so it
-- stays fully player-facing. Returns nil when there is no car position or the car is horizontally at
-- the center, signalling the caller to fall back to the stored-normal posts.
local function gate_line_angle(checkpoint, car_pos)
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
    local player_angle = math.atan2(dy, dx) + math.pi / 2

    -- No stored normal: nothing to ease toward, stay fully player-facing (the prior behavior).
    local normal = checkpoint.normal
    if not normal then
        return player_angle
    end
    local nlen = math.sqrt(normal.x * normal.x + normal.y * normal.y)
    if nlen < 1e-6 then
        return player_angle
    end
    -- The line of the stored normal, in the same angle convention post_edges expects (perp = the
    -- gate line; gate_edges builds it from (normal.y, -normal.x)).
    local normal_angle = math.atan2(-normal.x, normal.y)

    -- Blend fraction by distance: 0 (player) at radius + band and beyond, 1 (normal) at the volume
    -- edge and inside. Linear between, so 50% of the way through the band is a 50/50 mix.
    local radius = checkpoint.radius or MARKER_RADIUS
    local t = (radius + CHECKPOINT_FADE_BAND - len) / CHECKPOINT_FADE_BAND
    t = math.max(0.0, math.min(1.0, t))

    -- Shortest step from the player line onto the same pi-periodic normal line, scaled by t.
    local diff = (normal_angle - player_angle + math.pi / 2) % math.pi - math.pi / 2
    return player_angle + t * diff
end

-- The two horizontal points (left, right) to draw the side posts at, from a smoothed gate-line angle
-- (gate_line_angle). Falls back to the stored-normal placement (gate_edges) when the angle is nil
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
local function draw_next_checkpoint(race, detection, car_pos)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return
    end
    local final_seq = #entries

    -- Circuit: before the lap clock arms (the run-up from the grid to the line), also draw the
    -- start/finish line itself, so the player sees the line the lap is counted from -- the scored
    -- plan's next marker is CP1, not this line (ADR-0022). Once the line is crossed (lt.started) it
    -- stops here and reappears later as the regular lap/finish marker. Purely visual.
    local lt = M.state.laptimer
    if lt and not lt.started and lt.start_cp then
        -- First-lap run-up: the start/finish line holds its true gate orientation (fixed stored
        -- normal, no car-tracking rotation) until the line is first crossed, so it reads as a proper
        -- start line rather than swinging to face the grid. A nil angle makes post_edges fall back to
        -- gate_edges (the stored normal). With no stored normal there is nothing to lock to, so keep
        -- the car-facing angle (the prior behavior, avoids dropping the posts). Once crossed
        -- (lt.started) the line reappears as the regular lap/finish marker and rotates normally again.
        local start_angle = nil
        if not lt.start_cp.normal then
            start_angle = gate_line_angle(lt.start_cp, car_pos)
        end
        draw_checkpoint_marker(lt.start_cp, marker_style(lt.start_cp, false), car_pos, start_angle)
    end

    local next_entry = entries[detection.seq + 1]
    local next_checkpoint = next_entry and race.checkpoints[next_entry.cursor]
    if not next_checkpoint then
        return
    end
    local next_style = marker_style(next_checkpoint, detection.seq + 1 == final_seq)
    local next_angle = gate_line_angle(next_checkpoint, car_pos)
    draw_checkpoint_marker(next_checkpoint, next_style, car_pos, next_angle)

    local ahead_entry = entries[detection.seq + 2]
    local ahead_checkpoint = ahead_entry and race.checkpoints[ahead_entry.cursor]
    if ahead_checkpoint then
        local ahead_angle = gate_line_angle(ahead_checkpoint, car_pos)
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

-- This client's BeamNG license name for the canonical identity (ADR-0031), or nil. The license name is
-- what the player sets in BeamNG's options -- the same identity BeamNG's own race highscores use
-- (raceHighscoresLap.lua). Read off the given vehicle's plate, pcall-guarded (the global is unverified
-- under BeamMP). nil when there is no vehicle, no name set, or the read fails -- the server then falls
-- back to the BeamMP name. Steam/online profile names are empty under BeamMP's guest login, so the
-- license name is the only persistent client-side identity available (verified in-game 2026-06-06).
local function collect_player_name(veh)
    if not veh then
        return nil
    end
    local ok, name = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleLicenseText) == "function" then
            return core_vehicles.getVehicleLicenseText(veh)
        end
        return nil
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- Report this client's BeamNG license name to the server (ADR-0031), so it keys every identity -- live
-- standings, results, records -- on the persistent license name instead of the rotating BeamMP guest
-- name. Called at connect (the player's freeroam car, best-effort) and at race spawn (the race car), so
-- a name set before the race is picked up early and reliably refreshed once the race car exists. A nil
-- name is not sent and the server falls back to the BeamMP name. send_to_server is a no-op until the MP
-- client is connected. Assigns the forward-declared local so handle_race_start can call it.
function report_identity(veh)
    local name = collect_player_name(veh)
    if name then
        log("I", LOG_TAG, "reporting client identity: " .. name)
        send_to_server("clientIdentity", {name = name})
    else
        log("W", LOG_TAG, "no client name available; server will use the BeamMP name")
    end
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
    local own = be and be:getPlayerVehicle(0)
    if own then
        M.state.current_vehicle_id = own:getId()
    end
    -- Report our BeamNG license name so the server can use it as the canonical identity (ADR-0031).
    -- Best-effort from the current freeroam car; refreshed reliably from the race car at spawn. Fires on
    -- a Lua reload / reconnect too, so a reconnecting client re-reports.
    report_identity(own)
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
-- Whether a game vehicle id is one of this client's AI cars (ADR-0036): the host's spawned ai_cars or, on
-- a non-owner, a synced car resolved from the relayed aiMap (ai_remote_ids). Used to keep the player out
-- of an AI car the same way cones are kept non-enterable.
local function is_ai_game_id(game_id)
    if game_id == nil then
        return false
    end
    local cars = M.state.ai_cars
    if cars then
        for _, car in ipairs(cars) do
            if tostring(car.veh_id) == tostring(game_id) then
                return true
            end
        end
    end
    local remote = M.state.ai_remote_ids
    if remote then
        for id in pairs(remote) do
            if tostring(id) == tostring(game_id) then
                return true
            end
        end
    end
    return false
end

-- Put the player back into their last real car after they switched into an AI car (ADR-0036), the cone
-- bounce generalized to the AI cars (which are real models, so cones.enforce_non_enterable -- gated on
-- is_cone -- does not catch them). No fallback car id -> no-op so the player is never trapped. Returns
-- true if it bounced.
local function bounce_off_ai(new_id)
    local fallback_id = M.state.current_vehicle_id
    if not be or fallback_id == nil or tostring(new_id) == tostring(fallback_id) then
        return false
    end
    local fallback = be:getObjectByID(fallback_id)
    if not fallback then
        return false
    end
    return pcall(function() be:enterVehicle(0, fallback) end)
end

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
    -- Keep the player out of an AI car (ADR-0036) and never record it as the seated car, so the detector
    -- keeps reading the real own car.
    if is_ai_game_id(newId) then
        bounce_off_ai(newId)
        return
    end
    M.state.current_vehicle_id = newId
end

-- Retry BeamMP nametag suppression for any cone still awaiting MPVehicleGE registration (queued by
-- onVehicleSpawned). Zero-work on the idle path: pending_nametag is nil until a cone misses its
-- one-shot hide, and is reset to nil once the set empties, so this only runs in the brief window after
-- a cone-bearing race start. An id is dropped once its tag is hidden, its vehicle is gone, or the
-- retry window elapses (the tag then stays -- the accepted fallback, ADR-0020 finding #4).
local function retry_pending_nametags(dt)
    local pending = M.state.pending_nametag
    if not pending then
        return
    end
    -- Collect ids to drop and remove them after the loop (never mutate the table mid-pairs).
    local drop = nil
    for id, waited in pairs(pending) do
        local veh = be and be:getObjectByID(id)
        if not veh or cones.hide_nametag(veh) then
            drop = drop or {}
            drop[#drop + 1] = id
        else
            local elapsed = waited + (dt or 0)
            pending[id] = elapsed
            if elapsed >= NAMETAG_RETRY_TIMEOUT then
                drop = drop or {}
                drop[#drop + 1] = id
            end
        end
    end
    if drop then
        for _, id in ipairs(drop) do
            pending[id] = nil
        end
    end
    if next(pending) == nil then
        M.state.pending_nametag = nil
    end
end

-- As each shared cone appears -- the host's local set when its prefab load spawns them, and the
-- remote synced set on every other client (BeamMP vehicle spawns fire this hook too) -- keep it out
-- of the Tab vehicle cycle and suppress BeamMP's owner nametag on it. The bounce (onVehicleSwitched)
-- is the non-enterable guarantee; the nametag suppression is best-effort but no longer one-shot: a
-- remote-synced cone is registered in MPVehicleGE asynchronously, so the first hide here misses it and
-- the cone is queued for retry_pending_nametags (onUpdate) until registration lands (ADR-0020).
function M.onVehicleSpawned(vehicleId)
    if not be then
        return
    end
    local veh = be:getObjectByID(vehicleId)
    cones.exclude_from_cycle(veh)
    -- A freshly synced vehicle may be one of the owner's AI cars (ADR-0036): try to resolve the pending
    -- aiMap now so it is labelled + nametag-suppressed as soon as it appears. No-op when nothing pending
    -- or on the owner (it has no ai_server_ids).
    resolve_remote_ai()
    if not cones.is_cone(veh) then
        return
    end
    if cones.hide_nametag(veh) then
        if M.state.pending_nametag then
            M.state.pending_nametag[vehicleId] = nil
        end
    else
        M.state.pending_nametag = M.state.pending_nametag or {}
        M.state.pending_nametag[vehicleId] = 0
    end
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
    -- `runUp` rides along the same way: the gun -> start/finish line run-up (lap 1's real start), so
    -- the analysis overlay can show it as S0 and clean it out of lap-1 times for every driver
    -- (ADR-0028). Set once the line is crossed, which is before this first report, so it is present
    -- from the first scored crossing onward.
    send_to_server("checkpoint", {
        seq = event.seq,
        index = event.index,
        name = event.name,
        lap = event.lap,
        time = event.time,
        count = count,
        bestLap = lt and lt.best or nil,
        runUp = lt and lt.run_up or nil,
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

-- Host only: step each AI car's checkpoint detector and report its crossings to the server by proxy
-- (ADR-0036). The owner drives the AI cars locally, so it reads each car's position and runs the same
-- ADR-0010 detector against the same plan as a player, sending every crossing as a normal checkpoint
-- report tagged with aiId -- the server routes it into that AI's progress record. Race-blind: an
-- identical report plus one field. No-op for non-owners (no ai_detections) and once a detector is done.
local function step_ai_detections(dt_sim)
    local detections = M.state.ai_detections
    local cars = M.state.ai_cars
    local race = M.state.race
    if not detections or not cars or not race or not race.checkpoints then
        return
    end
    for _, car in ipairs(cars) do
        local detection = detections[car.id]
        if detection and not detection.done then
            local veh_pos = nil
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                local ok, pos = pcall(function() return veh:getPosition() end)
                if ok then
                    veh_pos = pos
                end
            end
            local event = checkpoints.step(detection, race.checkpoints, veh_pos, dt_sim)
            if event then
                send_to_server("checkpoint", {
                    -- Proxy tag (ADR-0036): the server records this crossing into the AI slot's progress,
                    -- not the owner's. Accepted only from the race owner for a known AI id (server-side).
                    aiId = car.id,
                    seq = event.seq,
                    index = event.index,
                    name = event.name,
                    lap = event.lap,
                    time = event.time,
                    count = detection.plan.count,
                })
                log("I", RACE_LOG_TAG, string.format("AI '%s' checkpoint seq %d @ %.2fs",
                    tostring(car.label), event.seq, event.time))
            end
        end
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

-- Per-CP segment times from a cumulative splits array (ADR-0015): segment[k] = splits[k] - splits[k-1],
-- with splits[0] = 0. Mirrors the server's derive_segments -- the analysis overlay derives everything
-- client-side from the broadcast splits (ADR-0028). Returns a 1-based array.
local function derive_segments(splits)
    local segments = {}
    if type(splits) ~= "table" then
        return segments
    end
    local previous = 0
    for k = 1, #splits do
        local cumulative = splits[k]
        if type(cumulative) == "number" then
            segments[k] = cumulative - previous
            previous = cumulative
        end
    end
    return segments
end

-- A human label for a car descriptor (ADR-0029): "model: variant" with a "(mod)" suffix when parts were
-- changed. The variant is shown as its leaf preset name only -- any directory prefix and the ".pc"
-- extension are stripped, so a full partConfig path like "vehicles/van/offroad_alt.pc" reads as
-- "offroad_alt". nil when there is no car.
local function car_label(car)
    if type(car) ~= "table" then
        return nil
    end
    local label = car.model or "?"
    if type(car.variant) == "string" and car.variant ~= "" then
        local short = (car.variant:gsub("^.*/", ""):gsub("%.pc$", ""))
        label = label .. ": " .. short
    end
    if car.modified == true then
        label = label .. " (mod)"
    end
    return label
end

-- Split a cumulative splits array into per-lap section arrays (ADR-0029): lap l has section[s] =
-- splits[(l-1)*cps + s] - splits[(l-1)*cps + s - 1] and total = splits[l*cps] - splits[(l-1)*cps].
-- Only fully-completed laps are returned (a partial final lap from a DNF is dropped). For a sprint
-- (one lap of all CPs) this yields the single run. cps = checkpoints per lap.
--
-- `run_up` (optional, circuit only; ADR-0022/0028) is the gun -> start/finish-line time baked into
-- lap 1: the scored plan starts at CP1 from the gun, so lap 1's first section and total carry the
-- run-up from the grid to the real start of the lap. When given, it is subtracted from lap 1 (and
-- only lap 1) so every lap reads as a clean line-to-line lap. nil / sprint -> no change.
local function laps_from_splits(splits, cps, run_up)
    local laps = {}
    if type(splits) ~= "table" or type(cps) ~= "number" or cps < 1 then
        return laps
    end
    local lap_index = 1
    while lap_index * cps <= #splits do
        local base = (lap_index - 1) * cps
        local base_time = base == 0 and 0 or splits[base]
        local sections = {}
        local ok = type(base_time) == "number"
        for s = 1, cps do
            local cumulative = splits[base + s]
            local prev = (s == 1) and base_time or splits[base + s - 1]
            if ok and type(cumulative) == "number" and type(prev) == "number" then
                sections[s] = cumulative - prev
            else
                ok = false
            end
        end
        if ok then
            local total = splits[base + cps] - base_time
            if base == 0 and type(run_up) == "number" and type(sections[1]) == "number" then
                sections[1] = sections[1] - run_up
                total = total - run_up
            end
            laps[#laps + 1] = {sections = sections, total = total}
        end
        lap_index = lap_index + 1
    end
    return laps
end

-- The fastest completed lap in a list (min total), or nil for an empty list.
local function best_lap_of(laps)
    local best = nil
    for _, lap in ipairs(laps) do
        if type(lap.total) == "number" and (not best or lap.total < best.total) then
            best = lap
        end
    end
    return best
end

-- The mean lap as a {sections, total} pseudo-lap (ADR-0029): each section/total averaged over the laps
-- that have it. nil for an empty list.
local function avg_lap(laps)
    if #laps == 0 then
        return nil
    end
    local section_count = #laps[1].sections
    local sections = {}
    for s = 1, section_count do
        local sum, n = 0, 0
        for _, lap in ipairs(laps) do
            local value = lap.sections[s]
            if type(value) == "number" then
                sum = sum + value
                n = n + 1
            end
        end
        sections[s] = n > 0 and (sum / n) or nil
    end
    local total_sum, total_n = 0, 0
    for _, lap in ipairs(laps) do
        if type(lap.total) == "number" then
            total_sum = total_sum + lap.total
            total_n = total_n + 1
        end
    end
    return {sections = sections, total = total_n > 0 and (total_sum / total_n) or nil}
end

-- A per-section + total delta row of `other` against the `reference` lap (ADR-0029): cell[s].delta =
-- other.sections[s] - reference.sections[s]. Cells are an aligned array so the UI iterates (no numeric
-- indexing across the Lua->JS bridge). Negative = faster than the reference. cps = section count.
local function lap_delta_row(other, reference, cps)
    local cells = {}
    for s = 1, cps do
        local a = other.sections[s]
        local b = reference.sections[s]
        cells[s] = {delta = (type(a) == "number" and type(b) == "number") and (a - b) or nil}
    end
    local total = (type(other.total) == "number" and type(reference.total) == "number")
        and (other.total - reference.total) or nil
    return {cells = cells, total = total}
end

-- The fastest lap across a set of standings entries (optionally filtered to a car key, optionally
-- excluding the local player), as {lap, holder} or nil. Used for "best lap of the other drivers"
-- (ADR-0030).
local function fastest_lap_across(entries, cps, car_key, exclude_local)
    local best, holder = nil, nil
    for _, e in ipairs(entries) do
        if (not exclude_local or not e.isLocal) and (not car_key or (e.car and e.car.key == car_key)) then
            local candidate = best_lap_of(laps_from_splits(e.splits, cps, e.run_up))
            if candidate and (not best or candidate.total < best.total) then
                best, holder = candidate, e.name
            end
        end
    end
    if not best then
        return nil
    end
    return {lap = best, holder = holder}
end

-- A pseudo-lap {sections, total} from a per-section array (e.g. a persistent section-best or average),
-- for diffing against your best lap (ADR-0030). nil when the array is missing or has no numbers.
local function pseudo_lap_from_sections(sections, cps)
    if type(sections) ~= "table" then
        return nil
    end
    local total, has = 0, false
    for s = 1, cps do
        if type(sections[s]) == "number" then
            total = total + sections[s]
            has = true
        end
    end
    return has and {sections = sections, total = total} or nil
end

-- A pseudo-lap of per-section averages from accumulated section sums + lap count (ADR-0030, #4). nil when
-- there is no data.
local function avg_lap_from_sums(section_sum, lap_count, cps)
    if type(section_sum) ~= "table" or type(lap_count) ~= "number" or lap_count < 1 then
        return nil
    end
    local sections = {}
    for s = 1, cps do
        if type(section_sum[s]) == "number" then
            sections[s] = section_sum[s] / lap_count
        end
    end
    return pseudo_lap_from_sections(sections, cps)
end

-- Driver section (ADR-0030): the local player's own history as an any-car / this-car table -- runs and
-- time over all tracks, track records held, runs here, and best time here. Each row carries `kind` so the
-- UI formats it (count / duration / time). Tolerant of missing fields -> zeros / nil placeholders.
local function build_driver_section(records, local_name)
    if type(records) ~= "table" then
        return nil
    end
    local pb = type(records.pb) == "table" and records.pb or {}
    local pb_car = type(pb.car) == "table" and pb.car or {}
    local totals = type(records.driverTotals) == "table" and records.driverTotals or {}
    local any = type(totals.anyCar) == "table" and totals.anyCar or {}
    local this = type(totals.thisCar) == "table" and totals.thisCar or {}
    return {
        name = local_name,
        carLabel = car_label(records.car),
        rows = {
            {label = "Runs (all tracks)", kind = "count",
                any = any.run_count or 0, this = this.run_count or 0},
            {label = "Time (all tracks)", kind = "duration",
                any = any.time_sum or 0, this = this.time_sum or 0},
            {label = "Track records held", kind = "count",
                any = any.records_held or 0, this = this.records_held or 0},
            {label = "Runs here", kind = "count",
                any = pb.run_count or 0, this = pb_car.run_count or 0},
            {label = "Best here", kind = "time",
                any = pb.best_lap or pb.best_total, this = pb_car.best_lap or pb_car.best_total},
        },
    }
end

-- The pre-run headline value of a record leaf (best lap on a circuit, else total time), or nil.
local function old_record_value(leaf)
    if type(leaf) ~= "table" then
        return nil
    end
    return leaf.best_lap or leaf.total_time
end

-- Track section (ADR-0029): this track's totals across all players, plus the track record (any car /
-- this car) with holders, and the pre-run "old record" headline when this run beat it. Tolerant of
-- missing fields.
local function build_track_section(records, race_name)
    if type(records) ~= "table" then
        return nil
    end
    local track = type(records.trackRecord) == "table" and records.trackRecord or nil
    local track_car = track and type(track.car) == "table" and track.car or nil
    -- Pre-run record headlines (captured before this run folded in): show "old record" only when this
    -- run actually beat the standing one, i.e. an old value exists and differs from the current. Same
    -- opaque store number on both sides, so an exact compare is safe (no float tolerance needed).
    local prerun = type(records.prerun) == "table" and records.prerun or {}
    local record_any_car = track and (track.best_lap or track.total_time) or nil
    local record_this_car = track_car and (track_car.best_lap or track_car.total_time) or nil
    local old_any = prerun.trackRecordAnyCarOld
    local old_this = prerun.trackRecordThisCarOld
    local old_any_val = old_record_value(old_any)
    local old_this_val = old_record_value(old_this)
    local beat_any = old_any_val ~= nil and old_any_val ~= record_any_car
    local beat_this = old_this_val ~= nil and old_this_val ~= record_this_car
    return {
        name = race_name,
        trackRuns = track and track.run_count or 0,
        trackTime = track and track.time_sum or 0,
        carRuns = track_car and track_car.run_count or 0,
        recordAnyCar = record_any_car,
        recordAnyCarHolder = track and track.holder or nil,
        recordAnyCarLabel = track and car_label(track.recordCar) or nil,
        recordAnyCarOld = beat_any and old_any_val or nil,
        recordAnyCarOldHolder = beat_any and old_any.holder or nil,
        recordThisCar = record_this_car,
        recordThisCarHolder = track_car and track_car.holder or nil,
        recordThisCarOld = beat_this and old_this_val or nil,
        recordThisCarOldHolder = beat_this and old_this.holder or nil,
        carLabel = car_label(records.car),
    }
end

-- Race section (ADR-0030): this race's lap analysis. Reference = your best lap this race (absolute
-- sections + total). Then per-section delta rows against five references: the other drivers' best lap
-- this race, your best lap with the car ever (pre-run), your average this race, your average with the car
-- over all sessions here (persistent), and the car's track record (pre-run). The two average rows are
-- dropped for a single-lap run (sprint). All derived client-side from the splits + the payload; nil when
-- there is no local entry or no completed lap.
local function build_race_section(entries, race, local_entry, records)
    local cps = (race and race.checkpoints) and #race.checkpoints or 0
    if cps < 1 or not local_entry then
        return nil
    end
    -- Subtract the run-up so lap 1 is a clean line-to-line lap like the rest (circuit only; ADR-0022).
    local my_laps = laps_from_splits(local_entry.splits, cps, local_entry.run_up)
    local my_best = best_lap_of(my_laps)
    if not my_best then
        return nil
    end

    local columns = {}
    local your_best_cells = {}
    for s = 1, cps do
        columns[s] = "S" .. s
        your_best_cells[s] = {value = my_best.sections[s]}
    end

    local prerun = type(records) == "table" and type(records.prerun) == "table" and records.prerun or {}
    local pb_car = type(records) == "table" and type(records.pb) == "table"
        and type(records.pb.car) == "table" and records.pb.car or {}
    local track_car = type(records) == "table" and type(records.trackRecord) == "table"
        and type(records.trackRecord.car) == "table" and records.trackRecord.car or {}

    local rows = {}
    local function add_row(label, pseudo_lap, holder)
        if pseudo_lap then
            local row = lap_delta_row(pseudo_lap, my_best, cps)
            row.label = label
            row.holder = holder
            rows[#rows + 1] = row
        end
    end

    local others = fastest_lap_across(entries, cps, nil, true)
    add_row("Other drivers", others and others.lap, others and others.holder)
    add_row("You, best w/ car", pseudo_lap_from_sections(prerun.playerCarSectionBest, cps))
    if #my_laps > 1 then
        add_row("You, avg this race", avg_lap(my_laps))
    end
    -- Skip the all-time average on the first visit to this track: pb_car is current-inclusive, so with a
    -- single run here the average is just this race's lap(s), making the delta ~0.00 in every section
    -- (ADR-0030). Only meaningful once a prior run exists (run_count > 1).
    if (race and race.mode == "circuit") and (tonumber(pb_car.run_count) or 0) > 1 then
        add_row("You, avg all-time", avg_lap_from_sums(pb_car.section_sum, pb_car.lap_count, cps))
    end
    add_row("Car record", pseudo_lap_from_sections(prerun.trackCarSectionBest, cps), track_car.holder)

    return {
        isCircuit = (race and race.mode == "circuit") or false,
        columns = columns,
        yourBest = {cells = your_best_cells, total = my_best.total},
        rows = rows,
    }
end

-- Build the post-race analysis block from the finished-phase standings and the pre-run records
-- (ADR-0028/0029). Pure client-side derivation -- the race-blind server only ships numbers (ADR-0005).
-- Carries the cross-driver segment matrix (aligned {value, fastest} cells, fastest = column minimum) plus
-- the three sections: Driver (your records), Track (all players), Race (this race's laps from the splits).
-- For circuits the matrix gains a leading S0 column -- the gun -> start/finish run-up -- and the first
-- real segment is cleaned of it, so every lap reads from the real start of the lap (ADR-0022/0028).
-- All cells are aligned arrays so the UI iterates rather than indexing across the Lua->JS bridge. Returns
-- nil with nothing to show.
local function build_analysis(entries, records, race)
    if not entries or #entries == 0 then
        return nil
    end

    -- S0 = the gun -> start/finish-line run-up (ADR-0022/0028). In a circuit the scored splits start at
    -- CP1, so this run-up is baked into the first segment. When any driver reported it, surface it as a
    -- leading S0 column and subtract it from the first segment, so every segment reads from the real
    -- start of a lap (S0 | S1=CP0->CP1 | ...). Sprints have no line crossing and keep S1.. unchanged.
    local with_runup = false
    if (race and race.mode == "circuit") then
        for _, e in ipairs(entries) do
            if type(e.run_up) == "number" then
                with_runup = true
                break
            end
        end
    end

    local max_seg = 0
    local drivers = {}
    for i, e in ipairs(entries) do
        local segments = derive_segments(e.splits)
        if #segments > max_seg then
            max_seg = #segments
        end
        drivers[i] = {
            name = e.name,
            isLocal = e.isLocal,
            dnf = e.dnf,
            position = e.position,
            segments = segments,   -- scratch for the column passes; replaced by cells below
            run_up = e.run_up,     -- scratch for the S0 column / first-segment cleanup
        }
    end
    -- One extra leading column (S0) once the run-up is shown. Reading a driver's value at a 1-based
    -- column maps S0 -> run_up and S{j-1} -> segments[j-1], with the first real segment cleaned of the
    -- run-up so it is line-to-line. Without the run-up column, column j is simply segments[j].
    local segment_count = with_runup and (max_seg + 1) or max_seg
    local function column_value(driver, j)
        if not with_runup then
            return driver.segments[j]
        end
        if j == 1 then
            return driver.run_up
        end
        local k = j - 1
        local seconds = driver.segments[k]
        if k == 1 and type(seconds) == "number" and type(driver.run_up) == "number" then
            return seconds - driver.run_up
        end
        return seconds
    end

    -- Fastest time in each column across drivers (the purple highlight, ADR-0028).
    local column_best = {}
    for j = 1, segment_count do
        local best = nil
        for _, driver in ipairs(drivers) do
            local seconds = column_value(driver, j)
            if type(seconds) == "number" and (not best or seconds < best) then
                best = seconds
            end
        end
        column_best[j] = best
    end

    local columns = {}
    for j = 1, segment_count do
        columns[j] = "S" .. (with_runup and (j - 1) or j)
    end
    for _, driver in ipairs(drivers) do
        local cells = {}
        local total, has_total = 0, false
        for j = 1, segment_count do
            local seconds = column_value(driver, j)
            cells[j] = {
                value = seconds,
                fastest = type(seconds) == "number" and column_best[j] ~= nil
                    and seconds == column_best[j],
            }
            if type(seconds) == "number" then
                total = total + seconds
                has_total = true
            end
        end
        driver.cells = cells
        -- Sum of the shown columns = the driver's total race time (S0 + cleaned S1 == the original
        -- first segment, so the run-up split changes nothing here). A DNF's partial columns sum to a
        -- partial total; nil when nothing crossed, so the UI shows a placeholder rather than 0.
        driver.total = has_total and total or nil
        driver.segments = nil
        driver.run_up = nil
    end

    local local_entry = nil
    local local_name = nil
    for _, e in ipairs(entries) do
        if e.isLocal then
            local_entry = e
            local_name = e.name
            break
        end
    end

    return {
        columns = columns,
        drivers = drivers,
        driver = build_driver_section(records, local_name),
        track = build_track_section(records, race and (race.displayName or race.name) or nil),
        race = build_race_section(entries, race, local_entry, records),
    }
end

-- Build the HUD snapshot for the render app (ADR-0012): the full ranked standings list, tagged
-- with the current phase so the app can branch live-HUD vs results template. During racing the
-- local player's row uses the live detector (ticking time, crossing count, lap); during finished
-- it falls back to the server-broadcast values so the frozen final readout matches every other
-- client. `lapCount` is the resolved race lap count (1 for sprint; the HUD shows a lap indicator
-- only when > 1, ADR-0013). Per-entry `splits` (cumulative race-time at each crossing, ADR-0015)
-- rides through opaquely for the results template; the finished phase also derives the analysis
-- block (ADR-0028). Pure read of M.state; the server is unaffected.
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
                run_up = e.run_up,  -- gun -> start/finish run-up (ADR-0022), for the analysis S0 column
                car = e.car,  -- driver's car (ADR-0029), for the Race section's "best lap with the car"
                ai = e.ai or nil,  -- synthetic host-driven AI slot (ADR-0036), so the row can be tagged
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

    -- The post-race analysis block is derived only when the overlay is actually open in the finished
    -- phase -- it runs every frame for the long finished window, so the closed-overlay default (and every
    -- live frame) skips the work entirely (ADR-0028/0030). `analysisAvailable` is the cheap flag the card
    -- button shows on, so the button appears without building the whole block.
    local is_circuit = (race and race.mode == "circuit") or false
    local analysis_available = phase == "finished" and #entries > 0
    local analysis = nil
    if analysis_available and M.state.analysis_open then
        analysis = build_analysis(entries, M.state.race_records, race)
    end

    return {
        active = true,
        phase = phase,
        entries = entries,
        grace = grace,
        graceCanFinish = grace_can_finish,
        isCircuit = is_circuit,
        resultsHidden = M.state.results_hidden or false,
        analysisAvailable = analysis_available,
        analysisOpen = M.state.analysis_open or false,
        analysis = analysis,
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

    -- Drop the recover target onto the real surface and clear of walls (ADR-0034): a checkpoint's
    -- authored centre sits above the road, so a raw teleport there would bury the car. Pass the facing
    -- as `forward` so the wall-nudge knows which way is down-track. (The seq <= 0 grid pose is already
    -- grounded by start.prepare; re-grounding it is idempotent.)
    local grounded = placement.resolve({pos = target_pos, forward = dir})
    return {pos = grounded.pos, dir = dir}
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
    -- Phase-independent: a synced cone's MPVehicleGE registration can land a frame or two after its
    -- spawn, so this runs until the queued nametag suppressions stick (no-op when nothing is pending).
    retry_pending_nametags(dtReal)
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
        -- Host only: step the AI detectors + proxy-report their crossings (ADR-0036). Inert otherwise.
        step_ai_detections(dtSim)
        -- Drive the held recover/repair countdown (ADR-0017).
        step_assist(dtReal)
        -- Tick the finish-grace countdown in wall time (the server's cutoff is wall-time; ADR-0014).
        -- Visual only -- the server stays authoritative on the actual DNF cutoff.
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
    end
    -- Host only: once BeamMP has registered the spawned AI cars, broadcast their server ids so remotes can
    -- label + suppress them (ADR-0036). Registration is async, so this retries while pending until every
    -- AI car resolves a server id (SPIKE #2); if one never resolves, the map is simply not sent and the
    -- owner's tag stays on the cars (the accepted cone fallback, ADR-0020).
    if M.state.ai_map_pending and M.state.ai_cars then
        local entries = ai.server_map(M.state.ai_cars)
        if #entries == #M.state.ai_cars then
            send_to_server("aiMap", {entries = entries})
            M.state.ai_map_pending = false
            log("I", RACE_LOG_TAG, string.format("broadcast aiMap for %d AI car(s)", #entries))
        end
    end
    -- Non-owner: keep resolving the relayed aiMap to local handles until every synced AI car is found.
    resolve_remote_ai()
    -- Host only: deferred front-anchor restage of the AI cars onto the grid over the frozen phases, once
    -- each car's jbeam has loaded (ADR-0036) -- the per-car mirror of the player restage above.
    if (M.state.phase == "staging" or M.state.phase == "countdown") and M.state.ai_cars then
        ai.restage(M.state.ai_cars, dtReal)
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
                draw_next_checkpoint(race, detection, car_pos)
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
--   columns        -- explicit number of columns: pins the grid width so it does not grow with a large
--                     field (e.g. many AI); overrides rows. Setting rows again switches back to deriving.

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
