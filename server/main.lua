-- BeamComp -- BeamMP server plugin entry point.
--
-- Deployed to Resources/Server/BeamComp/. BeamMP loads every .lua file in the
-- plugin folder alphabetically at server start.
-- API reference: the BeamMP server-plugin recon note (kept in the project's
-- local docs). Design: ADR-0006 (server-side race state machine).
--
-- Owns a server-authoritative race state machine (ADR-0006, staging phase ADR-0021):
--   lobby -> spawning -> staging -> countdown -> racing -> finished -> lobby
-- finished is a long results + free-roam window (ADR-0006 amendment, B3): results and props stay
-- up for PHASE_DURATIONS.finished_hold (or until /raceclear) with a heads-up before cleanup.
-- An always-on 250 ms tick (MP.CreateEventTimer) drives the timed transitions; a
-- monotonic MP.CreateTimer() stopwatch measures elapsed time per phase. Every
-- transition is broadcast to all clients as a "racePhase" envelope on the
-- "beamcompEvent" channel; the later Phase-3 items (movement lock, countdown UI,
-- release) act on those phases. Finish detection is active (ADR-0013): a player's final
-- crossing arms the finish grace and drives the racing -> finished transition (ADR-0006).
--
-- Chat commands handled (leading token; trailing text is the argument):
--   /race [map:|menu:]<name> [sprint|circuit] [laps] [reverse] [force] [recover[:secs]] [repair[:secs]] [grid=<name>] [car=<model[:config]|random>] [maxhp=<n>] [maxpwr=<n>] [maxkg=<n>] [minkg=<n>] [order=entry|random|last|pwr|championship|quali[:rev]] [quali=<min>] [ai <n> [easy|medium|hard]] [aicar=<model[:config]>] [aiaggr=/aiskill=/airubber=<0..1>] [all]
--                 (each keyword token also accepts any unambiguous prefix: s/c, rev, f, rec/rep)
--                 vehicle policy (ADR-0032): car=<model[:config]> = one fixed car for everyone (Mode 2);
--                 car=random = a per-player random car composing with the caps (the exception to car-wins);
--                 maxhp=<n> (hp) / maxpwr=<n> (power-to-weight, hp per kg) / maxkg=<n> + minkg=<n> (curb-weight
--                 range, kg) = per-player caps that keep a compliant car or substitute one (Mode 3); the caps
--                 AND together; none = keep own car (Mode 1). A FIXED car= wins (drops all caps); car=random
--                 keeps them. The two random axes (randomTrim/noBigCars) are panel-only, relayed verbatim.
--                 AI opponents (ADR-0036): ai <n> [preset] adds n host-driven AI (no count = content
--                 default, [1..16]); preset easy|medium|hard, aicar=/aiaggr=/aiskill=/airubber=/aiavoid=
--                 configure their vehicle + driving. airoute=snap|direct picks the AI line (snap =
--                 road-navgraph snap, default; direct = exact custom-navgraph race line, off-road,
--                 Step-3b). AI mix into random and sort by reported pwr; else back of grid.
--                 start order (ADR-0033/0040/0041): order=entry (default) | random | last (prev race
--                 result) | pwr (power-to-weight) | championship (points table) | quali (qualifying pace);
--                 :rev flips a directional mode (last:rev/pwr:rev = handicap). quali=<min> sets the
--                 qualifying length (default 8) for order=quali.
--                 the deprecated quickrace ("menu:") source is hidden from bare-name resolution unless
--                 "all" is given or the name carries an explicit "menu:" prefix (ADR-0026).
--                 <name> may carry a "map:"/"menu:" source prefix (freeroam-mission vs Time-Trial-menu
--                 set, ADR-0024); the server relays it verbatim and the client resolves it (race-blind).
--                 from lobby/finished: assign every present player a slot, send each a
--                 "raceStart" event (slot + grid roster + relayed overrides), and enter the spawning
--                 phase. The client resolves and parses <name> locally (ADR-0005) and decides the
--                 actual mode/laps/direction; the sprint|circuit, lap-count, reverse, and force tokens
--                 are relayed verbatim as overrides (ADR-0013/0018), and recover/repair[:secs] relay
--                 the opt-in in-race assists (ADR-0017, default off) -- the server never validates any
--                 of them against geometry (race-blind). Instead it runs a pre-flight check (ADR-0019):
--                 it asks the issuer's client (validateRace) to vet the options, and only on an "ok"
--                 reply (raceValidation) does it start; on a mismatch or bad name nothing starts and the
--                 reason is posted to the admin, who can re-issue with force. While a race is already
--                 running, an ok'd /race queues the new race and runs a short abort window before
--                 restarting. Bare /race replies with usage.
--   /go /start /racestart  start the race now: end the staging wait and begin the countdown (ADR-0021).
--                 Admin-gated like /race; only acts while a race is staging. Staging never starts by
--                 itself -- this (or the panel's equivalent button) is the only way forward.
--   /raceend      force the race straight to the finished/results screen, no despawn -- runs the same
--                 finalize as a grace expiry from any active pre-finished phase (ADR-0038). Admin-gated.
--   /raceclear    force the state machine back to lobby + cleanup/despawn (safety hatch; old /raceend).
--   /races [all]  list the time-trial races on the asking player's current map. The server is
--                 race-blind (ADR-0005), so it asks that client (a "listRaces" event); the client
--                 builds the list and sends it back ("raceList"), and the server posts it to the
--                 player. Reply is to the asker only. The deprecated quickrace ("menu") source is
--                 hidden (shown as a count hint) unless "all" is given (ADR-0026).
--   /cars [model] list installed vehicles -- bare lists models, /cars <model> lists that model's
--                 configs with power (and index). Vehicle-blind like /races (ADR-0005/0032): asks the
--                 client ("listVehicles"), which replies ("vehicleList") and the server posts it back.
--   /dnf          give up the current race: marks the issuing player DNF (did not finish). Racing
--                 only (ADR-0014).
--   /results      toggle the asking player's own finished-results card on/off (ADR-0022). Open to
--                 all players; affects only that player's view (a "resultsToggle" event).
--   /analysis     toggle the asking player's own post-race analysis overlay on/off (ADR-0028). Open to
--                 all players; affects only that player's view (an "analysisToggle" event).
--   /beamcomp     diagnostic ping -- replies in chat AND sends a "ping" event the client
--                 mod surfaces.
-- All commands suppress their own chat echo. Anything else relays as normal chat.
-- The server never validates <name> (ADR-0005).

-- F1 light-start namespace (ADR-0043). This reuses what used to be the vestigial module-export table
-- `M`: BeamMP registers handlers via global functions and ignores the chunk return, so `M` was never
-- populated or read. Renaming it to `f1` lets every new F1 start-mode symbol hang off one namespace --
-- like champ/quali/tour -- WITHOUT adding a top-level local (main.lua is at the 200/200 local ceiling).
-- All per-race F1 state lives on session/overrides/progress; only constants + pure helpers live here.
local f1 = {}
f1.LIGHT_COUNT = 5            -- red lights in the start tower
f1.LIGHT_STEP = 1.0          -- seconds between each light coming on (the build-up)
f1.HOLD_MIN = 0.2            -- shortest random all-lit hold before lights out
f1.HOLD_MAX = 3.0            -- longest random all-lit hold
f1.DEFAULT_PENALTY = 15      -- default jump-start time penalty in seconds (panel-configurable)
f1.MSG_REACTION = "reaction" -- client -> server: a car's start reaction ({race, aiId?, reaction}); jump = reaction < 0

-- Roll one F1 standing start's full countdown duration (seconds): the fixed light build-up plus a random
-- all-lit hold. math.random is seeded in on_init. Lights-out is the countdown -> racing transition, which
-- the server broadcasts once, so every client sees the same lights-out moment.
function f1.countdown_duration()
    return f1.LIGHT_COUNT * f1.LIGHT_STEP + f1.HOLD_MIN + math.random() * (f1.HOLD_MAX - f1.HOLD_MIN)
end

local PLUGIN_VERSION = "0.1.0"
local CHAT_COMMAND_RACE = "/race"
local CHAT_COMMAND_RACEEND = "/raceend"  -- force-finish the race straight to the results screen, no despawn (ADR-0038)
local CHAT_COMMAND_RACECLEAR = "/raceclear"  -- force the machine back to lobby + cleanup/despawn (old /raceend; ADR-0038)
local CHAT_COMMAND_RACES = "/races"
local CHAT_COMMAND_CARS = "/cars"  -- list installed vehicle models, or one model's configs (ADR-0032)
local CHAT_COMMAND_DNF = "/dnf"
local CHAT_COMMAND_PING = "/beamcomp"
local CHAT_COMMAND_RESULTS = "/results"  -- toggle the asking player's finished-results card (ADR-0022)
local CHAT_COMMAND_ANALYSIS = "/analysis"  -- toggle the asking player's post-race analysis overlay (ADR-0028)
local CHAT_COMMAND_RACEUI = "/raceui"  -- open the asking admin's race-setup panel (ADR-0037; admin-gated)
local CHAT_COMMAND_GRIDUI = "/gridui"  -- open the asking admin's grid-editor panel (ADR-0037 amendment / ADR-0023; admin-gated)
-- Manual race-start aliases (ADR-0021): any of these ends the staging wait early and starts the
-- countdown. All three route to one handler.
local CHAT_COMMAND_GO = "/go"
local CHAT_COMMAND_START = "/start"
local CHAT_COMMAND_RACESTART = "/racestart"

-- Server <-> client event channel. Must be colon-free: the BeamMP client parser
-- splits incoming events on ':' (see ADR-0004). Bidirectional (ADR-0011): the server
-- sends raceStart/racePhase/ping on it via TriggerClientEventJson, and receives client
-- reports on it via MP.RegisterEvent (the client fires TriggerServerEvent on the same name).
local EVENT_CHANNEL = "beamcompEvent"
local MSG_RACE_START = "raceStart"
local MSG_RACE_PHASE = "racePhase"
-- Client -> server message types (received on EVENT_CHANNEL; ADR-0011).
local MSG_CHECKPOINT = "checkpoint"
local MSG_RACE_LIST = "raceList"  -- a client's /races reply: pre-formatted chat lines to post back
local MSG_VEHICLE_LIST = "vehicleList"  -- a client's /cars reply: pre-formatted chat lines to post back (ADR-0032)
local MSG_RACE_VALIDATION = "raceValidation"  -- the issuer's pre-flight verdict on /race options (ADR-0019)
local MSG_SPAWN_READY = "spawnReady"  -- a client's "car spawned + seated" ack, gating spawning (ADR-0006 amendment)
local MSG_CLIENT_INFO = "clientInfo"  -- a client's vehicle metadata for best-times records (ADR-0027)
local MSG_CLIENT_IDENTITY = "clientIdentity"  -- a client's player-set name, reported on connect, for identity resolution (ADR-0054)
local MSG_GRID_SAVE = "gridSave"      -- editor saves a named grid for a race (ADR-0023; admin-gated)
local MSG_GRID_ASSIGN = "gridAssign"  -- editor sets a race's default grid (ADR-0023; admin-gated)
local MSG_GRID_DELETE = "gridDelete"  -- editor deletes one of a race's saved grids (ADR-0023; admin-gated)
local MSG_GRID_FETCH = "gridFetch"    -- editor opens a saved grid: request its data (ADR-0023; read-only)
local MSG_GRID_LIST_REQ = "gridListReq"  -- editor lists a map's saved grids (ADR-0023; read-only)
local MSG_GRID_DATA = "gridData"      -- reply to gridFetch: a saved grid's params (server -> client)
local MSG_GRID_LIST = "gridList"      -- reply to gridListReq: the map's grids as {name, race, isDefault}
local MSG_START_RACE = "startRace"   -- the settings UI's structured race request: {race, overrides} (ADR-0037; admin-gated)
local MSG_RACE_GO = "raceGo"         -- the settings UI's "start now": end staging -> countdown, the /go equivalent (ADR-0037; admin-gated)
-- Server -> client broadcast/request types.
local MSG_STANDINGS = "standings"     -- the live ranked standings table (broadcast)
local MSG_LIST_RACES = "listRaces"    -- ask one client to report its installed-race list (/races)
local MSG_LIST_VEHICLES = "listVehicles"  -- ask one client to report its installed vehicles/configs (/cars, ADR-0032)
local MSG_FINISH_GRACE = "finishGrace"  -- the DNF-cutoff countdown duration, broadcast when armed (ADR-0014)
local MSG_VALIDATE_RACE = "validateRace"  -- ask the issuer's client to vet /race options pre-start (ADR-0019)
local MSG_RESULTS_TOGGLE = "resultsToggle"  -- tell one client to hide/show its finished-results card (ADR-0022)
local MSG_BEST_NOTICE = "bestNotice"  -- tell a finisher they set a personal best / track record (ADR-0027)
local MSG_RACE_RECORDS = "raceRecords"  -- ship a participant's pre-run PB + the race's track record at the finish seam (ADR-0028)
local MSG_ANALYSIS_TOGGLE = "analysisToggle"  -- tell one client to open/close its post-race analysis overlay (ADR-0028)
local MSG_SETUP_OPEN = "setupOpen"  -- tell one client to open its race-setup panel (ADR-0037)
local MSG_GRID_SETUP_OPEN = "gridSetupOpen"  -- tell one client to open its grid-editor panel (ADR-0037 amendment)
local MSG_REGRID = "regrid"  -- tell one client its reassigned grid slot + the reordered roster for a pwr re-grid (ADR-0033)
local MSG_AI_MAP = "aiMap"  -- owner -> all: which synced vehicles are AI cars, so remotes label/suppress them (ADR-0036)
local MSG_AI_ROUTE_NOTICE = "aiRouteNotice"  -- owner -> server: which AI route variant was used, posted to chat (ADR-0036 Step-3)

-- Cap on /races reply lines posted to chat, so a misbehaving client can't flood it.
local RACE_LIST_MAX_LINES = 60

-- Cap on /cars reply lines (ADR-0032): higher than races -- a stock install has more models/configs.
local VEHICLE_LIST_MAX_LINES = 200

-- State-machine tick. ~4x/second: fine enough for a 3-2-1-GO, idle cost is a nil-check.
local TICK_EVENT = "beamcompTick"
local TICK_INTERVAL_MS = 250

-- The five canonical race phases (the racePhase contract, ADR-0006). Referenced by name so a
-- typo is a load error, not a silent mis-compare.
local PHASE = {
    lobby = "lobby",
    spawning = "spawning",
    staging = "staging",
    countdown = "countdown",
    qualifying = "qualifying",      -- time-boxed qualifying session before the race (ADR-0041); reuses racing machinery
    quali_results = "qualiResults", -- short classification pause after qualifying, before the race countdown (ADR-0041)
    racing = "racing",
    finished = "finished",
}

-- Phase durations in seconds. Editable server config (ADR-0006); not a runtime/in-game UI.
local PHASE_DURATIONS = {
    spawning = 10.0,      -- max wait for spawn-ready acks before proceeding anyway (ADR-0006 amendment)
    -- Staging is NOT timed (ADR-0021 amendment, staging-waits-for-host): the staged field waits for the
    -- host and only /go|/start|/racestart or the panel's raceGo starts it. This is the invisible
    -- emergency exit -- after it the server discards the staged race by itself, so a race prepared and
    -- then forgotten cannot hold everyone's car frozen on the grid forever. Deliberately far beyond any
    -- legitimate wait (loading, a car swap, grid tweaks -- minutes at most): 2x the longest window
    -- BeamComp ships (finished_hold, 15 min). Erring long is the safe direction -- firing too early
    -- would kill a live race prep, firing late only extends a wait nobody is in. NOT applied as the
    -- phase duration: that field is what makes a phase timed and clients mirror it as a visible
    -- countdown, so this is checked against phase_elapsed() in the tick instead.
    staging_abandon = 1800.0,
    countdown = 8.0,      -- pre-race countdown (ADR-0021: was 3.0)
    finish_grace = 120.0, -- DNF cutoff: time after the first finisher for others to finish (ADR-0014)
    all_done_grace = 5.0, -- shortened grace once no one can still finish (ADR-0014 early-end)
    abort_window = 1.5,   -- short finished window when /race restarts a running race
    finished_hold = 900.0, -- long results + free-roam window before returning to lobby (ADR-0006 amendment)
    quali_default = 480.0, -- default qualifying session length, 8 min (ADR-0041); per-event override in session.quali.duration
    -- Finish-your-lap window after the quali clock expires, before quali-results (ADR-0041). Sized per
    -- session by quali.lap_grace_window to the field's slowest best lap (a lap's worth of time) rather than
    -- a flat cap; these keys are its fallback and clamp bounds. All defensible defaults:
    quali_lap_grace_fallback = 120.0, -- window when no active driver has a valid best lap yet (everyone on
                                      -- lap 1, or a sprint quali with nil best_lap); generous, well above the
                                      -- old flat 45 s, equal to the racing finish_grace (a lap's worth)
    quali_lap_grace_min = 20.0,  -- floor: even a pathologically small best lap still lets a mid-lap driver cross
    quali_lap_grace_max = 300.0, -- ceiling (5 min): covers genuinely long laps yet caps one slow/limping lap
                                 -- so it cannot hold the whole field for minutes
    quali_results = 30.0,  -- classification pause between qualifying and the race countdown (ADR-0041):
                           -- ~10 s results display + a ~20 s settle window after the re-grid (see lead)
    quali_regrid_lead = 20.0, -- lead before the countdown at which the AI re-grid + respawn run inside
                              -- quali-results, so (a) the multi-second re-spawn freeze lands on the static
                              -- results card, not the race countdown, and (b) a settle window of this length
                              -- follows the respawn. The freeze eats the first seconds of that window, so the
                              -- visible settle (the client's small "race starts in" timer, counting the
                              -- remaining pause to 0) is ~lead minus the freeze -- generous so it always runs
                              -- fully to the countdown rather than being cut short (ADR-0041). The
                              -- despawn->respawn gap that keeps cars under MaxCars stays quali_results - lead.
}

-- Seconds before the finished results window expires to warn players that the props and results
-- are about to be cleared (delayed-race-cleanup / B3). Not a phase duration: the finished phase
-- still ends at PHASE_DURATIONS.finished_hold; this is just the one-shot heads-up offset.
local FINISHED_CLEANUP_WARNING = 60.0

-- How long the server waits for the issuer's client to answer a pre-flight validateRace before giving
-- up and telling the admin (covers a client that disconnected mid-check; ADR-0019).
local VALIDATION_TIMEOUT = 5.0

-- Monotonic stopwatch for phase timing; only elapsed differences are used, so its origin
-- (creation moment) does not matter.
local clock = MP.CreateTimer()

-- In-memory session state. Resets on a Lua-state reload (a race spanning a code reload is a
-- dev-only scenario), so nothing unrecoverable lives here.
local session = {
    phase = PHASE.lobby,
    race = nil,             -- active race name, or nil
    roster = nil,           -- grid roster shipped in raceStart, or nil
    progress = nil,         -- per-player checkpoint tracking keyed by player id, or nil
    phase_started_at = 0,   -- clock seconds at the current phase's entry
    phase_duration = nil,   -- configured length of the current timed phase, or nil if open-ended
    grace_deadline = nil,   -- clock seconds when the finish grace ends (set by start_finish_grace)
    pending_race = nil,      -- race name queued by a /race re-issued while one is active
    pending_owner = nil,     -- player id of the queued race's issuer (owns its shared props), or nil
    pending_overrides = nil, -- queued race's relayed {mode, laps, direction, force, assists} (ADR-0018)
    pending_map = nil,       -- queued race's issuer-reported map, for grid resolution (ADR-0023)
    pending_race_id = nil,   -- queued race's canonical id, the default-grid lookup key (ADR-0023)
    pending_race_data = nil, -- queued race's serialized definition, relayed verbatim in raceStart (ADR-0039)
    pending_validation = nil, -- in-flight pre-flight check {race, overrides, owner_id, nonce, deadline} (ADR-0019)
    validation_seq = 0,       -- monotonic nonce source so a stale/duplicate raceValidation is ignored
    cleanup_warned = false,   -- one-shot guard for the ~60 s "props/results clear soon" warning (B3)
    spawn_pending = nil,      -- set of rostered player ids whose spawnReady ack is still awaited (ADR-0006 amendment)
    spawn_ready_count = 0,    -- how many distinct clients acked spawnReady this race (0 at timeout = empty race)
    identities = nil,         -- per-player {vehicle, pwr, car_length, car_width} reported via clientInfo, for records (ADR-0027) + start-order (ADR-0033) + slot reservation (ADR-0051); name moved to client_names (ADR-0054)
    grid_record = nil,        -- the active race's resolved grid record (ADR-0023), kept so the slot reservation can read its gaps + column pin (ADR-0051); per-race
    grid_direction = nil,     -- the active race's relayed travel direction, picking the grid record's forward/reverse block exactly as the clients do
    grid_ramp = nil,          -- true when the clients split a P1 start ramp off the front of the layout (staged sprint quali, ADR-0044): participant slot k sits at layout index k + 1
    order = nil,              -- this race's start-order {mode, rev} (ADR-0033), or nil = entry order
    start_mode = nil,         -- this race's start style: "f1" = light start (ADR-0043), or nil = lock countdown
    jump_penalty_seconds = nil, -- F1 jump-start time penalty in seconds for this race (ADR-0043)
    last_order = nil,         -- previous race's finishing order as a list of identities (ADR-0033); session-scoped, survives reset_to_lobby so order=last has a source
    championship = nil,       -- active multi-race championship {points_preset, order, standings, race_count} or nil (ADR-0040); session-scoped, survives reset_to_lobby like last_order
    tournament = nil,         -- active class-drop tournament {classes, order, standings, race_count, winner, ended} or nil (ADR-0042); session-scoped, survives reset_to_lobby like championship
    quali = nil,              -- active quali-then-race event {duration, lap_grace_deadline, done} or nil (ADR-0041); per-event, cleared by reset_to_lobby (unlike last_order/championship)
    owner_id = nil,           -- player id that issued the active race -- the prop + AI owner (ADR-0009/0036), or nil
    staged_by = nil,          -- player id that prepared the race now waiting in staging (ADR-0021 amendment), or nil.
                              -- Distinct from owner_id, which must outlive staging (props/AI): this one exists ONLY
                              -- while staging, so that this specific admin leaving cancels the race nobody else will
                              -- start. Seeded at the staging entry, dropped by enter_phase on any other phase.
    ai_roster = nil,          -- named AI roster for the active race (ADR-0047): [k] = {name, car?} for AI id "ai:<k>", sanitized from the panel's overrides.ai.roster; nil on the chat path (classic "AI <k>" labels). Per-race, cleared by reset_to_lobby
    runs_logged = nil,        -- whether this race's runs already went into the run log (ADR-0050). Set by runlog.capture, cleared per race, so the finish seam and the two abort paths cannot log the same race twice. Stays nil for the WHOLE race while statistics are off (ADR-0053): runlog.capture returns before it would set this, so the guard reads a consistent "nothing was logged" instead of a half-armed state
    race_event = nil,         -- id shared by every logged run of THIS race instance (ADR-0050), so field size, start slot and finishing position can be related across rows; assigned in start_race
}

-- Race-command permissions / plugin config (ADR-0016). The race-admin allowlist gates /race, /raceend and
-- /raceclear; it is loaded on init from the plugin config file. Candidate paths tolerate the unverified
-- runtime working directory (recon TODO #4) -- server root first, then the plugin folder. An empty,
-- missing, or unparseable config leaves the gate inactive (opt-in: everyone may start/end races).
local CONFIG_CANDIDATE_PATHS = {
    "Resources/Server/BeamComp/beamcomp.config.json",
    "beamcomp.config.json",
}

-- The plugin config, as read from beamcomp.config.json (ADR-0016). One namespace table rather than a
-- local per setting: main.lua lives at LuaJIT's 200-local ceiling (see grid_store / f1), and a table
-- costs one local no matter how many settings it grows.
--   * `admins` / `admin_gate_active` -- normalized (trimmed, lowercased) admin names -> true, and
--     whether the race-admin gate is on at all (no admins configured = everyone may start races).
--   * `use_client_name` -- whether player identity resolves to the client-reported player-set name
--     instead of the BeamMP name (ADR-0054). Default on -- a missing/unparseable config keeps it on, so the
--     guest-name fix applies out of the box. Set false in beamcomp.config.json to fall back everywhere.
--   * `stats_enabled` -- whether the per-run statistics subsystem exists at all (ADR-0053): the run log,
--     best times, track records, the bestNotice toast, the raceRecords push, the analysis overlay and
--     /analysis. JSON key `enableStatistics`. Default OFF, and note the polarity is the OPPOSITE of
--     use_client_name above: only an explicit `true` enables it, so a missing key, a missing file, a
--     malformed file or a non-boolean value all leave the feature dead. A suppression switch has to fail
--     closed. The key is DELIBERATELY ABSENT from the shipped beamcomp.config.json -- it is documented
--     here and in ADR-0053, not in the file users read, so the feature does not exist to anyone who was
--     not told about it. Do not "helpfully" add it to the shipped config.
--   * `password` -- the server password that turns any player into a race admin for the duration of his
--     connection (ADR-0056). JSON key `racePassword`, nil when unset. Trimmed on read: a trailing space
--     in a JSON string is invisible in every editor and would lock the operator out of his own server
--     with no symptom to see. Lives on cfg (it is config, like `admins` above); the GRANTS it hands out
--     live on `access` below, because those are what the session accumulates. That split is what makes
--     "a Lua-state reload drops every grant" true by construction -- the reload rebuilds both literals,
--     load_config refills this one and access comes back empty.
local cfg = {
    admins = {},
    admin_gate_active = false,
    use_client_name = true,
    stats_enabled = false,
    password = nil,
}

-- Password-based race-admin access (ADR-0056, superseding ADR-0016 in part). The name allowlist above
-- authorizes by BeamMP display name -- and that name ROTATES on every game start while BeamMP login is
-- broken (measured: four consecutive sessions of the same user gave four different guest names), so it
-- cannot identify anybody. A password does not depend on identity at all, which is why it works here.
--
-- One namespace table, not a local per symbol: main.lua's main chunk sits at LuaJIT's 200-local ceiling
-- (see the cfg / identity / f1 / grid_store namespaces around it), and a table costs ONE local no matter
-- how much it carries. Declared HERE, above is_race_admin, because the gate reads `granted`; the
-- functions are assigned further down, next to the locals they close over (send_event, player_name_of,
-- champ/tour/identity). A table field needs no forward declaration.
--
-- `granted` is written in exactly ONE place, access.handle_unlock, after a successful comparison.
-- Nothing else in this plugin assigns into it -- keep it that way.
local access = {
    -- player_id -> true for a connection that entered the server password. Keyed to the ID and not to a
    -- name on purpose: ADR-0054 forbids authorizing on anything the player can set with /name, and a
    -- player_id is issued by BeamMP. Cleared in on_player_disconnect -- NOT optional bookkeeping, since
    -- BeamMP reuses player ids and a grant left behind is inherited by whoever takes the slot next.
    granted = {},
    -- player_id -> {n = <consecutive failures>, locked_until = <now() deadline or nil>}. Cleared on
    -- disconnect with the grant, so a fresh joiner never inherits somebody else's lockout.
    attempts = {},
    MSG_LOCKED = "setupLocked",    -- server -> client: open the race-setup panel in its LOCKED state
    MSG_UNLOCK = "raceUnlock",     -- client -> server: a password attempt {password = "..."}
    MSG_RESULT = "unlockResult",   -- server -> client: the verdict {ok, reason, triesLeft, wait}
    -- Wrong attempts before a cooldown, and the cooldown in seconds. High enough that a fat-fingered
    -- admin never notices the limit, low enough that one guess per 12 s is not a way in.
    MAX_TRIES = 5,
    LOCKOUT_SECONDS = 60,
}

-- Connection-scoped player-set name per player id (ADR-0054), reported once on connect via
-- clientIdentity and cleared on disconnect. Survives lobby resets -- unlike session.identities, which is
-- per race -- so resolve_identity has the name from join onward. An opaque client string (race-blind,
-- ADR-0005).
--
-- A PLAIN player_id -> name MAP, walked with pairs() by the collision check and the disconnect clear.
-- NEVER hang a function, a flag or any other non-name field on it: it would be read as somebody's
-- player name. New identity code goes on the `identity` namespace below instead.
local client_names = {}

-- Everything the player-set identity needs (ADR-0054, superseding ADR-0031): the /name command, its
-- validation, the shared collision suffix, the delayed join hint and the admin-facing "who has no name"
-- surface.
--
-- One namespace table, not a local per symbol: main.lua's main chunk sits at LuaJIT's 200-local ceiling
-- (see the f1 / grid_store / runlog namespaces above), and a table costs ONE local no matter how much it
-- carries. Message-type strings and chat texts are top-level locals too when written as `local MSG_...`,
-- so they ride here as fields as well.
--
-- Constants and state live here; the functions are assigned in a later block, after the locals they
-- close over (send_event, broadcast_event, broadcast_standings, is_race_admin, normalize_name). A table
-- field needs no forward declaration and every cross-call is a runtime lookup, so the order is free.
local identity = {
    CHAT_COMMAND = "/name",
    MSG_SET = "nameSet",              -- server -> client: the accepted REQUESTED name, for the client to persist
    MSG_PLAYERS = "playerList",       -- server -> clients: every connected player + whether his name is temporary (setup panel)
    MSG_REMIND = "remindUnnamed",     -- client -> server: admin asks us to hint every player still on a temporary name
    -- Name length in BYTES (#name), not codepoints: a name with umlauts therefore reaches the cap sooner
    -- than 20 visible characters. Deliberate -- a UTF-8-aware count is not worth its complexity for a
    -- display name, and the byte bound is what keeps the hand-assembled chat/standings lines sane. Do not
    -- "fix" this to a utf8.len.
    MIN_BYTES = 2,
    MAX_BYTES = 20,
    -- Seconds between a player joining and the hint being emitted. A client that HAS a stored name
    -- reports it a moment after the join, so an immediate check would hint at exactly the people who are
    -- about to be named; the grace lets that report land first.
    HINT_DELAY = 8,
    -- player_id -> deadline (now()) for a hint that is armed but not yet due.
    pending = {},
}
identity.HINT = "BeamComp: you have no race name set -- type \"" .. identity.CHAT_COMMAND
    .. " <your name>\" to pick the name everyone sees"
identity.USAGE = "BeamComp: usage -- " .. identity.CHAT_COMMAND .. " <your name> ("
    .. identity.MIN_BYTES .. "-" .. identity.MAX_BYTES .. " characters, spaces allowed)"

-- The canonical display/record identity for a player (ADR-0054): the player-set name reported by the
-- client when the option is on and one was reported, else the BeamMP name. The single chokepoint every
-- name read goes through -- the option and the fallback live here only. nil only if BeamMP has no name
-- for the id.
local function resolve_identity(player_id)
    if cfg.use_client_name then
        local name = client_names[player_id]
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return MP.GetPlayers()[player_id]
end

-- Named parametric start grids (ADR-0023). The server stores opaque grid params keyed by map + name,
-- plus a per-map "which grid is default for this race" mapping, and relays the resolved params in
-- raceStart -- it never interprets the numbers or parses a race, so race-blindness (ADR-0005) holds.
-- Loaded on init and written by the in-game editor's gridSave/gridAssign. Candidate paths tolerate the
-- unverified working directory exactly like the config file (ADR-0016); writes go back to the path we
-- loaded from, else the first candidate that opens.
local GRIDS_CANDIDATE_PATHS = {
    "Resources/Server/BeamComp/beamcomp.grids.json",
    "beamcomp.grids.json",
}

-- grids[map][raceId][name] = {forward = <params>, reverse = <params>?, previewCount = <n>};
-- defaults[map][raceId] = name.
-- A grid belongs to a RACE, not to a map (ADR-0023 amendment 2026-07-27): the race id is the middle key,
-- so grid names are unique per race and two races on one map may both own a grid called "Main". The
-- record carries no `race` field -- it IS the key; gridData echoes the race back from the request.
-- `previewCount` is the grid's authored FIELD SIZE (ADR-0023 amendment 2026-08-02): the editor's preview
-- extent, and the size above which the race start warns the issuer. It is the ONE record field this
-- server reads instead of relaying verbatim (the documented ADR-0005 exception) -- a meta number, never
-- forward/reverse, never the geometry. It sits at the record's top level on purpose: the direction blocks
-- are param sets the client feeds to its knob setter, which rejects unknown knobs.
-- defaults stays the single source of truth for "which grid is this race's default" (no flag in the
-- record); grid_store.ensure_default holds the one-default-per-race invariant.
-- presets[map][name] = <race-setup form JSON string> is the named-preset store (ADR-0037 amendment
-- 2026-07-03), folded onto this same table -- see the preset block below.
--
-- The grid store's own two state fields ride here as well, mirroring the presets' `presets_path` /
-- `presets_loaded` below and for the same reason (the 200/200 local ceiling):
--   * `grids_path`   -- the grids file we loaded from; writes go back to it, else the first candidate.
--   * `grids_loaded` -- whether the store has been populated from disk in THIS Lua-state instance. A
--     BeamMP file-watch reload (recon gotcha 12) re-runs this chunk -- rebuilding this table and so
--     clearing the flag -- which is exactly what happens when the editor writes the grids file;
--     lazy-loading on first access (ensure_grids_loaded) repopulates the store after such a reload, so
--     a saved default is not lost.
local grid_store = {
    grids = {},
    defaults = {},
    presets = {},
    grids_path = nil,
    grids_loaded = false,
    -- Set when the loaded grids file was rejected as the pre-2026-07-27 map-keyed schema. It blocks
    -- write_grids, so an in-game save can never overwrite an unmigrated file with the empty store the
    -- rejection left behind (that file still holds the admin's authored grids).
    grids_legacy = false,
    -- True only when load_grids ran all the way through -- i.e. past BOTH its early returns (no file /
    -- unparseable, and the legacy map-keyed schema). The startup migration gates on it, so an unattended
    -- write can never fire against a file we refused to read (ADR-0023 amendment 2026-08-02).
    grids_clean = false,
}

-- Named race-setup presets (ADR-0037 amendment 2026-07-03). A preset is the setup panel's form JSON,
-- stored map-scoped and opaque -- the server never interprets it (race-blind, ADR-0005), it stores and
-- returns the string verbatim, exactly like the grid store returns opaque numbers. Its state, message
-- constants and helper/handler functions all hang off grid_store as *fields* rather than new top-level
-- locals: main.lua is at LuaJIT's 200/200 local ceiling (see the f1 namespace, lines 74-92, and the
-- inlined raceControl handler), so a sibling `local preset_store` would fail to compile. load_grids and
-- load_presets therefore clear their fields in place (never reassign grid_store) so these folded symbols
-- survive a reload. presets_path is the resolved data file; presets_loaded gates the lazy load like
-- grids_loaded.
grid_store.presets_path = nil
grid_store.presets_loaded = false
grid_store.PRESETS_CANDIDATE_PATHS = {
    "Resources/Server/BeamComp/beamcomp.presets.json",
    "beamcomp.presets.json",
}
grid_store.MSG_PRESET_SAVE = "presetSave"         -- panel saves a named form preset for a map (admin-gated)
grid_store.MSG_PRESET_DELETE = "presetDelete"     -- panel deletes a saved preset for a map (admin-gated)
grid_store.MSG_PRESET_FETCH = "presetFetch"       -- panel loads a preset: request its form blob (read-only)
grid_store.MSG_PRESET_LIST_REQ = "presetListReq"  -- panel lists a map's saved presets (read-only)
grid_store.MSG_PRESET_DATA = "presetData"         -- reply to presetFetch: a preset's form blob (server -> client)
grid_store.MSG_PRESET_LIST = "presetList"         -- reply to presetListReq: the map's saved preset names (server -> client)

-- Persistent per-run records (ADR-0050, superseding ADR-0027 §1/§2). The truth on disk is an
-- APPEND-ONLY run log: one JSON object per line, one line per run, written with io.open(path, "a").
-- The best-times aggregate the push contract reads (ADR-0028/0029/0030) is NOT stored -- it is derived
-- in RAM by replaying the log once per Lua state, so there is one truth and it cannot drift.
--
-- All of it hangs off this single namespace table rather than a local per field/function: main.lua's
-- main chunk sits at Lua's 200-local ceiling (see grid_store / champ / f1), and a table costs one local
-- no matter how much it carries. Retiring beamcomp.records.json frees seven slots on top of that.
--
-- The server stores only numbers + opaque client-reported strings keyed on the relayed race name, so
-- race-blindness (ADR-0005) holds. Candidate paths tolerate the unverified working directory exactly
-- like config + grids; deploy.ps1 preserves the log across the server-folder wipe (like
-- beamcomp.grids.json) so accumulated runs survive a redeploy.
--
-- Functions are assigned in three later blocks, each after the locals it closes over (path/append near
-- the other file I/O, fold/replay after update_track_best, capture after build_standings). A table field
-- needs no forward declaration and every cross-call is a runtime lookup, so the order is free.
local runlog = {
    CANDIDATE_PATHS = {
        "Resources/Server/BeamComp/beamcomp.runs.jsonl",
        "beamcomp.runs.jsonl",
    },
    RECORD_VERSION = 1,   -- schema tag on every written line, so a later format change stays readable
    path = nil,           -- resolved log path, set on first use
    loaded = false,       -- whether store has been replayed from the log in this Lua state
    -- The derived aggregate: store[race_name] = {track_best = {...}, players = {[identity] = {...}}},
    -- shape unchanged from ADR-0029/0030. Empty until replayed; never written to disk.
    store = {},
    event_seq = 0,        -- monotonic counter behind the per-race-instance event id
}


local function log_info(subsystem, msg)
    print("[" .. subsystem .. "] " .. msg)
end

-- Normalize a player name for allowlist comparison: trim surrounding whitespace, then lowercase.
local function normalize_name(name)
    return (name:gsub("^%s*(.-)%s*$", "%1")):lower()
end

-- Trim surrounding whitespace, case INTACT -- the password counterpart of normalize_name above, which
-- lowercases and is therefore unusable for a case-sensitive secret (ADR-0056). The extra parentheses
-- drop gsub's second return value, so this yields exactly one string.
function access.trim(text)
    return (text:gsub("^%s*(.-)%s*$", "%1"))
end

-- Read and JSON-decode the plugin config from the first candidate path that opens. Returns the decoded
-- table plus the resolved path, or nil plus the resolved path and an error label ("parse"/"missing").
-- The decode is pcall-guarded so a malformed file can never crash the plugin load.
local function read_config()
    for _, path in ipairs(CONFIG_CANDIDATE_PATHS) do
        local file = io.open(path, "r")
        if file then
            local contents = file:read("*a")
            file:close()
            local ok, decoded = pcall(Util.JsonDecode, contents)
            if not ok or type(decoded) ~= "table" then
                return nil, path, "parse"
            end
            return decoded, path, nil
        end
    end
    return nil, nil, "missing"
end

-- Populate the race-admin allowlist from the plugin config (ADR-0016). An empty list, a missing file,
-- or a parse error all leave the gate inactive so the existing open behaviour is preserved (opt-in);
-- only a real parse error warns. The resolved path is logged so the runtime working directory is
-- visible in the server console (recon TODO #4). Called from on_init.
local function load_config()
    cfg.admins = {}
    cfg.admin_gate_active = false
    cfg.use_client_name = true
    cfg.stats_enabled = false
    cfg.password = nil

    local config, path, err = read_config()
    if not config then
        if err == "parse" then
            log_info("beamcomp.cfg", "config at " .. tostring(path)
                .. " is not valid JSON; race-admin gate inactive")
        else
            log_info("beamcomp.cfg", "no config file found; race-admin gate inactive")
        end
        log_info("beamcomp.cfg", "useClientName=on (default; no config)")
        log_info("beamcomp.cfg", "enableStatistics=off (default; no config)")
        return
    end

    -- The server password (ADR-0056). Read HERE, above the raceAdmins handling, for the same reason
    -- enableStatistics is: the next block returns early when raceAdmins is missing or empty -- and empty
    -- is exactly the config of a server that relies on the password, so a read placed below those
    -- returns would be dead code on every server that needs it.
    --
    -- Trimmed at both ends, and so is every attempt (access.trim). normalize_name is unusable here: it
    -- lowercases, and a password is case-sensitive. An empty string, a missing key or a non-string all
    -- mean "no password configured". The VALUE is never logged, here or anywhere else.
    if type(config.racePassword) == "string" then
        local password = access.trim(config.racePassword)
        if password ~= "" then
            cfg.password = password
        end
    end

    -- Default on (ADR-0054): only an explicit false turns it off; a missing key stays on.
    cfg.use_client_name = config.useClientName ~= false
    log_info("beamcomp.cfg", "useClientName=" .. (cfg.use_client_name and "on" or "off"))

    -- Default OFF (ADR-0053), and the opposite polarity to useClientName above: ONLY an explicit true
    -- enables the statistics subsystem. A missing key, a truthy non-boolean, the string "true" -- all
    -- stay off. Read here rather than below because the raceAdmins early return is next, so a config
    -- carrying enableStatistics but no raceAdmins array must still be honoured. This log line is the
    -- one place the switch is observable; it is the acceptance check after a deploy.
    cfg.stats_enabled = config.enableStatistics == true
    log_info("beamcomp.cfg", "enableStatistics=" .. (cfg.stats_enabled and "on" or "off"))

    if type(config.raceAdmins) ~= "table" then
        log_info("beamcomp.cfg", "config at " .. path
            .. " has no raceAdmins array; race-admin gate inactive")
        return
    end

    local count = 0
    for _, name in ipairs(config.raceAdmins) do
        if type(name) == "string" then
            local normalized = normalize_name(name)
            if normalized ~= "" and not cfg.admins[normalized] then
                cfg.admins[normalized] = true
                count = count + 1
            end
        end
    end

    if count == 0 then
        log_info("beamcomp.cfg", "loaded config from " .. path
            .. "; no race admins listed, gate inactive")
        return
    end

    cfg.admin_gate_active = true
    log_info("beamcomp.cfg", "loaded config from " .. path .. "; "
        .. count .. " race admin(s), gate active")
end

-- Whether the issuing player may run the gated race commands. Two independent ways in (ADR-0056,
-- amending ADR-0016): the SESSION GRANT -- this connection entered the server password in the
-- race-setup panel -- or the NAME ALLOWLIST, the original ADR-0016 gate. With neither a password nor a
-- populated allowlist the gate is inactive and everyone is allowed: ADR-0016's opt-in default,
-- deliberately unchanged so an upgrade breaks no existing server.
--
-- Three things here are load-bearing:
--
--   * A CONFIGURED PASSWORD ACTIVATES THE GATE. cfg.admin_gate_active is false whenever raceAdmins is
--     empty -- which is every server that relies on the password. Reading only that flag would leave
--     "empty list = everyone may do everything" in force and the password would gate nothing at all.
--     This is the line the whole feature turns on.
--   * `player_id` is a plain second argument and Lua does not enforce it -- which FAILS CLOSED. A call
--     site that forgets it can never see a grant, so the worst a missed site can do is refuse an
--     unlocked admin; it can never admit a stranger. That is the safe direction for an omitted argument.
--   * This stays the SINGLE chokepoint. All 14 call sites call exactly this function; there is no
--     second predicate anywhere in the plugin, and adding one is how a refusal path silently goes open.
--
-- The name check reads the RAW BeamMP name at every site (ADR-0054): a name the player can set with
-- /name must never be an authorization key. A player_id is not settable by the player, so keying the
-- grant to it does not violate that rule.
local function is_race_admin(player_name, player_id)
    if not cfg.admin_gate_active and not cfg.password then
        return true
    end
    if player_id ~= nil and access.granted[player_id] then
        return true
    end
    return cfg.admin_gate_active and player_name ~= nil
        and cfg.admins[normalize_name(player_name)] == true
end

-- The one place a race-admin refusal is worded. `what` is the action in the caller's own words
-- ("start races", "edit grids", ...), so every site keeps the line it has always sent.
--
-- With a server password configured the refusal also says HOW to get in (ADR-0056): /raceui is the only
-- place the password can be entered, and a player who does not know that is simply stuck. Without a
-- password the line is byte-identical to before, because there would be nothing to point at.
--
-- One helper rather than 14 edited string literals: the hint has to reach every refusal or it is a
-- coin flip whether a locked-out player ever learns the password exists -- and a list of 14 literals is
-- exactly the kind of list that goes stale at the 15th site.
function access.refuse(player_id, what)
    local line = "BeamComp: you are not allowed to " .. what
    if cfg.password then
        line = line .. " -- type " .. CHAT_COMMAND_RACEUI .. " and enter the server password"
    end
    MP.SendChatMessage(player_id, line)
end

-- Log what actually protects this server, once, at startup (ADR-0056). Called from on_init right after
-- load_config -- deliberately NOT from inside it: load_config has four returns, and the two that skip
-- its tail (no config file, no raceAdmins array) are exactly the paths where "nothing protects this
-- server" is most likely true. A warning written at the end of load_config would be missing precisely
-- when it matters. One call site every path converges on is a property; four branches that each
-- remember to warn is a claim. (Same reasoning as ADR-0053's layer 0.)
--
-- The password itself is never logged -- only whether one is set.
function access.log_startup_state()
    log_info("beamcomp.cfg", "racePassword=" .. (cfg.password and "set" or "not set"))

    if not cfg.admin_gate_active and not cfg.password then
        -- Boxed because it has to survive a scrolling BeamMP console. This is the release-visible half
        -- of the "unconfigured stays open" decision: the behaviour is unchanged, the silence is not.
        log_info("beamcomp.cfg", "############################################################")
        log_info("beamcomp.cfg", "#  NO ADMIN PROTECTION IS ACTIVE                            #")
        log_info("beamcomp.cfg", "#  EVERY player on this server may start and abort races,   #")
        log_info("beamcomp.cfg", "#  overwrite and delete saved grids and presets, and run    #")
        log_info("beamcomp.cfg", "#  the championship and tournament.                         #")
        log_info("beamcomp.cfg", "#  Set \"racePassword\" in beamcomp.config.json and restart.  #")
        log_info("beamcomp.cfg", "############################################################")
        return
    end

    if cfg.admin_gate_active then
        -- The reason this item exists, told to the one operator who can still act on it: whoever just
        -- filled in raceAdmins. Measured 2026-09-09 -- four consecutive sessions of the same user
        -- produced four different guest names.
        log_info("beamcomp.cfg", "NOTE: raceAdmins matches the BeamMP name, and while BeamMP login is"
            .. " broken every player connects as a guest whose name CHANGES on every game start."
            .. " An entry here will not match the same person tomorrow -- use racePassword instead.")
    end
end

-- Read and JSON-decode the grids file from the first candidate path that opens (ADR-0023). Returns
-- the decoded table + resolved path, or nil + path + error label ("parse"/"missing"). The decode is
-- pcall-guarded so a malformed file never crashes the plugin load.
local function read_grids()
    for _, path in ipairs(GRIDS_CANDIDATE_PATHS) do
        local file = io.open(path, "r")
        if file then
            local contents = file:read("*a")
            file:close()
            local ok, decoded = pcall(Util.JsonDecode, contents)
            if not ok or type(decoded) ~= "table" then
                return nil, path, "parse"
            end
            return decoded, path, nil
        end
    end
    return nil, nil, "missing"
end

-- Populate grid_store from the grids file (ADR-0023). A missing or unparseable file leaves the store
-- empty, so every race uses the procedural grid -- the safe default. A file still written in the old
-- map-keyed schema is treated exactly like an unreadable one (ADR-0023 amendment 2026-07-27): there is
-- deliberately NO migration path, so it is rejected whole with one clear log line and the write path is
-- blocked until it has been migrated by hand. The resolved path is logged so the write target is visible
-- in the server console (recon TODO #4). Called from on_init.
local function load_grids()
    -- Clear the grid fields in place rather than reassigning grid_store: the named-preset store folds
    -- its state + helpers onto this same table (200/200 local ceiling), and a fresh table would drop them.
    grid_store.grids = {}
    grid_store.defaults = {}
    grid_store.grids_legacy = false
    grid_store.grids_clean = false

    local data, path, err = read_grids()
    grid_store.grids_path = path
    if not data then
        if err == "parse" then
            log_info("beamcomp.grid", "grids file at " .. tostring(path)
                .. " is not valid JSON; using procedural grids")
        else
            log_info("beamcomp.grid", "no grids file found; using procedural grids")
        end
        return
    end

    if type(data.grids) == "table" and grid_store.is_legacy_grids(data.grids) then
        grid_store.grids_legacy = true
        log_info("beamcomp.grid", "grids file at " .. path .. " is still keyed by map only"
            .. " (grids[map][name]); grids now belong to a race (grids[map][race][name]) and must be"
            .. " migrated by hand -- using procedural grids and refusing to write this file")
        return
    end
    if type(data.grids) == "table" then
        grid_store.grids = data.grids
    end
    if type(data.defaults) == "table" then
        grid_store.defaults = data.defaults
    end
    -- Past both early returns: this file was read cleanly and the store mirrors it, so writing it back is
    -- safe. Nothing else may set this flag (ADR-0023 amendment 2026-08-02).
    grid_store.grids_clean = true
    log_info("beamcomp.grid", "loaded grids from " .. path)
end

-- Populate grid_store once per Lua-state instance, lazily on first access. This makes grid resolution
-- robust to a file-watch reload that resets the in-memory store without re-firing onInit (ADR-0023):
-- the next save/resolve/fetch repopulates from disk.
local function ensure_grids_loaded()
    if grid_store.grids_loaded then
        return
    end
    grid_store.grids_loaded = true
    load_grids()
    -- Stamp the authored field size into records saved before that field existed, and write the file back
    -- once (ADR-0023 amendment 2026-08-02). A FIELD lookup, resolved at call time on purpose:
    -- stamp_preview_counts is declared further down the chunk because it must be able to call write_grids
    -- (a local declared after this function), and nothing calls ensure_grids_loaded before the chunk has
    -- finished loading. Harmless on the lazy re-load path -- a stamped store finds nothing to do.
    grid_store.stamp_preview_counts()
end

-- The grid param record for a race start, or nil to fall back to the procedural grid (ADR-0023).
-- Grids belong to a race, so both lookups are scoped to `race_name` (the canonical race id, or the raw
-- name when the client reported none): an explicit `grid_name` (from /race grid=<name>) is looked up
-- among THAT race's grids, otherwise the race's default is used. Every miss resolves to nil, so a typo'd
-- /race grid= silently falls back rather than failing the start -- these log lines are the only trace it
-- leaves. The race id is an opaque table key here, never parsed (race-blind, ADR-0005), and the server
-- never interprets the record -- it relays it verbatim.
local function resolve_grid(map, race_name, grid_name)
    ensure_grids_loaded()
    if type(map) ~= "string" then
        return nil
    end
    local map_grids = grid_store.grids[map]
    if type(map_grids) ~= "table" then
        log_info("beamcomp.grid", "resolve: no saved grids for map '" .. map .. "' -> procedural")
        return nil
    end
    local race_grids = type(race_name) == "string" and map_grids[race_name] or nil
    if type(race_grids) ~= "table" then
        log_info("beamcomp.grid", "resolve: no saved grids for race '" .. tostring(race_name)
            .. "' on '" .. map .. "' -> procedural")
        return nil
    end

    local name = grid_name
    if not name then
        local map_defaults = grid_store.defaults[map]
        name = type(map_defaults) == "table" and map_defaults[race_name] or nil
    end
    if not name then
        log_info("beamcomp.grid", "resolve: no grid for race '" .. tostring(race_name)
            .. "' on '" .. map .. "' -> procedural")
        return nil
    end

    local record = race_grids[name]
    if type(record) ~= "table" then
        log_info("beamcomp.grid", "resolve: grid '" .. name .. "' missing for race '"
            .. tostring(race_name) .. "' -> procedural")
        return nil
    end
    log_info("beamcomp.grid", "resolve: using grid '" .. name .. "' for race '" .. tostring(race_name) .. "'")
    return record
end

-- Serialize grid_store and write it back, trying the loaded path first then the candidates (ADR-0023).
-- Returns true + path on success, false otherwise. pcall-guarded around the encode + file I/O so a
-- write failure is reported, never thrown into the BeamMP runtime.
local function write_grids()
    -- Never write over a file we refused to load: the rejected legacy-schema file still holds the admin's
    -- authored grids, and the store is empty by design, so a write would wipe them before the hand
    -- migration ever happens (ADR-0023 amendment 2026-07-27).
    if grid_store.grids_legacy then
        log_info("beamcomp.grid", "refusing to write grids: the file at " .. tostring(grid_store.grids_path)
            .. " is still keyed by map only and must be migrated to grids[map][race][name] first")
        return false
    end

    local ok, encoded = pcall(Util.JsonEncode, {grids = grid_store.grids, defaults = grid_store.defaults})
    if not ok then
        log_info("beamcomp.grid", "could not encode grids: " .. tostring(encoded))
        return false
    end

    local candidates = {}
    if grid_store.grids_path then
        candidates[#candidates + 1] = grid_store.grids_path
    end
    for _, path in ipairs(GRIDS_CANDIDATE_PATHS) do
        candidates[#candidates + 1] = path
    end

    for _, path in ipairs(candidates) do
        -- Atomic write: fill a temp file in the same directory, then swap it into place. A crash mid-
        -- write leaves the live file untouched (unlike truncate-then-write). os.rename can't overwrite
        -- an existing target on Windows, so drop it first -- that gap writes no data, and the complete
        -- temp survives a crash there for recovery.
        local tmp = path .. ".tmp"
        local file = io.open(tmp, "w")
        if file then
            local ok_write = file:write(encoded)
            local ok_close = file:close()
            if ok_write and ok_close then
                -- Swap only once the full content is safely on disk. On a partial write (e.g. disk
                -- full) the live file is left untouched -- the very data loss this fix prevents.
                os.remove(path)
                if os.rename(tmp, path) then
                    grid_store.grids_path = path
                    return true, path
                end
                log_info("beamcomp.grid", "could not commit grids write at " .. path)
            else
                log_info("beamcomp.grid", "could not write grids temp at " .. path)
            end
            os.remove(tmp)
        end
    end
    log_info("beamcomp.grid", "could not open any grids path for writing")
    return false
end

-- Store a named grid for a race on a map and persist it (ADR-0023 amendment 2026-07-27). `record` is
-- {forward = <params>, reverse = <params>?} -- the race is the key, not a field. Returns the write_grids
-- result plus the name ensure_default promoted, so the caller can tell the admin that this save also made
-- the grid the race's default (the FIRST grid of a race becomes its default with nobody assigning it).
local function save_grid(map, race_name, name, record)
    ensure_grids_loaded()
    if type(grid_store.grids[map]) ~= "table" then
        grid_store.grids[map] = {}
    end
    local race_grids = grid_store.grids[map][race_name]
    if type(race_grids) ~= "table" then
        race_grids = {}
        grid_store.grids[map][race_name] = race_grids
    end
    race_grids[name] = record

    local promoted = grid_store.ensure_default(map, race_name)
    local ok, path = write_grids()
    return ok, path, promoted
end

-- Point a race's default grid at `name` and persist it (ADR-0023). The explicit counterpart to
-- grid_store.ensure_default's automatic promotion; the caller checks that the grid exists for that race.
-- Returns the write_grids result.
local function assign_default(map, race_name, name)
    ensure_grids_loaded()
    if type(grid_store.defaults[map]) ~= "table" then
        grid_store.defaults[map] = {}
    end
    grid_store.defaults[map][race_name] = name
    return write_grids()
end

-- Delete one of a race's saved grids and persist it (ADR-0023 amendment 2026-07-27). Deleting the race's
-- default promotes a survivor; deleting the last grid leaves the race with no default at all -- both via
-- the one ensure_default that also runs on save, so the invariant has a single owner. Returns
-- (existed, write_grids ok, promoted name): existed is false when there was no such grid (nothing written).
local function delete_grid(map, race_name, name)
    ensure_grids_loaded()
    local map_grids = grid_store.grids[map]
    local race_grids = type(map_grids) == "table" and map_grids[race_name] or nil
    if type(race_grids) ~= "table" or type(race_grids[name]) ~= "table" then
        return false
    end
    race_grids[name] = nil
    -- Drop an emptied race bucket so "this race has grids" stays a plain presence check.
    if next(race_grids) == nil then
        map_grids[race_name] = nil
    end

    local promoted = grid_store.ensure_default(map, race_name)
    local ok = write_grids()
    return true, ok, promoted
end

-- Hold the one-default-per-race invariant (ADR-0023 amendment 2026-07-27): a race with at least one grid
-- has exactly one default, a race with none has no default. Called after every grid insert/delete, so the
-- FIRST grid saved for a race becomes its default automatically and deleting the default promotes the
-- alphabetically first survivor. A standing default that still resolves is never overridden -- an explicit
-- gridAssign wins. Returns the newly promoted name, or nil when nothing changed. The caller persists.
-- On grid_store (not a top-level local) like every other helper added since main.lua hit 200/200.
function grid_store.ensure_default(map, race_name)
    local map_grids = grid_store.grids[map]
    local race_grids = type(map_grids) == "table" and map_grids[race_name] or nil
    local map_defaults = grid_store.defaults[map]
    if type(race_grids) ~= "table" or next(race_grids) == nil then
        if type(map_defaults) == "table" then
            map_defaults[race_name] = nil
        end
        return nil
    end

    local current = type(map_defaults) == "table" and map_defaults[race_name] or nil
    if type(current) == "string" and type(race_grids[current]) == "table" then
        return nil
    end

    local first = nil
    for grid_name in pairs(race_grids) do
        if first == nil or grid_name < first then
            first = grid_name
        end
    end
    if type(map_defaults) ~= "table" then
        map_defaults = {}
        grid_store.defaults[map] = map_defaults
    end
    map_defaults[race_name] = first
    return first
end

-- Whether a decoded `grids` table is still in the pre-2026-07-27 map-keyed schema (grids[map][name] =
-- record) instead of the race-keyed one (grids[map][race][name] = record). Discriminates on SHAPE alone,
-- by DEPTH: the second level holds race buckets now, records before.
--   old:  grids[map].<name>.forward   = <params>   -- and a param set has no `forward` of its own
--   new:  grids[map].<race>.<name>.forward = <params>
-- So a second-level entry whose `forward` is a table is a record only if THAT table is not itself a
-- record -- which is what keeps a race whose grid is literally named "forward" from being mistaken for
-- the old schema. No key is ever inspected and no param value is read, so the server stays race-blind
-- (ADR-0005). `forward` alone is enough: every saved record has one (handle_grid_save rejects it
-- otherwise). There is deliberately no reader for the old shape -- see load_grids.
function grid_store.is_legacy_grids(grids)
    for _, map_grids in pairs(grids) do
        if type(map_grids) == "table" then
            for _, entry in pairs(map_grids) do
                if type(entry) == "table" and type(entry.forward) == "table"
                    and type(entry.forward.forward) ~= "table" then
                    return true
                end
            end
        end
    end
    return false
end

-- The authored field size of a grid (ADR-0023 amendment 2026-08-02). These three mirror
-- DEFAULT/MIN/MAX_PREVIEW_COUNT in the client's race/grideditor.lua; the server cannot require a client
-- module (ADR-0004/0011), so this is a deliberate second copy -- keep them in step.
grid_store.PREVIEW_COUNT_DEFAULT = 16
grid_store.PREVIEW_COUNT_MIN = 1
grid_store.PREVIEW_COUNT_MAX = 32

-- The usable previewCount carried by a grid record (or by a gridSave payload -- both name the field the
-- same), coerced tonumber -> floor -> clamp, or nil when the field is absent or unusable. Deliberately
-- not called "stored": what comes back is the CLAMPED number, not the literal one in the file (a
-- hand-written 999 reads as 32 and stays 999 on disk). The nil is what the migration keys on -- "this
-- record has no usable count, stamp it"; every reader wants preview_count_of below.
-- Reading this field is the server's ONE documented exception to relaying a grid record verbatim
-- (ADR-0005): a meta number the editor writes for exactly this purpose, and nothing else in the record.
function grid_store.usable_preview_count(record)
    if type(record) ~= "table" then
        return nil
    end
    local number = tonumber(record.previewCount)
    -- NaN survives tonumber and every comparison below, so it has to be rejected on its own.
    if not number or number ~= number then
        return nil
    end
    number = math.floor(number)
    if number < grid_store.PREVIEW_COUNT_MIN then
        return grid_store.PREVIEW_COUNT_MIN
    end
    if number > grid_store.PREVIEW_COUNT_MAX then
        return grid_store.PREVIEW_COUNT_MAX
    end
    return number
end

-- The field size a grid was authored for, defaulting when it carries none. The startup migration stamps
-- the field into every stored record, but this read-time default stays as the backstop: a legacy-schema
-- file the migration correctly refused, a hand-added record, or a client on an older server can all still
-- reach a read path without one.
function grid_store.preview_count_of(record)
    return grid_store.usable_preview_count(record) or grid_store.PREVIEW_COUNT_DEFAULT
end

-- Tell the player who started the race, once, when more cars line up than the resolved grid was authored
-- for (ADR-0023 amendment 2026-08-02). Information, not an error, and deliberately private to the issuer:
-- they are the only person who can act on it, and the race is fine either way. It says what the ADMIN can
-- do something about -- this grid is not tuned for a field this size -- rather than describing where the
-- surplus cars end up, which is the layout's business and not a decision anyone has to make. Nothing is
-- blocked, clamped or adjusted; the layout is count-independent and every pose is what it would have been.
-- Silent for the procedural fallback (grid_params nil: no authored count exists) and at or below the
-- count; `starters` is #roster, which is one entry per grid slot, AI included (ADR-0036).
function grid_store.warn_over_capacity(owner_id, grid_params, starters)
    if owner_id == nil or type(grid_params) ~= "table" then
        return
    end
    local authored = grid_store.preview_count_of(grid_params)
    if starters <= authored then
        return
    end
    -- "1 drivers" is reachable: MIN_PREVIEW_COUNT is 1 and a one-car grid is a legitimate thing to
    -- author. `starters` is always plural here (it is strictly greater than an authored count of at
    -- least 1), so only the second noun needs the singular.
    local drivers = (authored == 1) and "driver" or "drivers"
    MP.SendChatMessage(owner_id, string.format(
        "BeamComp: %d starters -- this grid is not tuned for more than %d %s",
        starters, authored, drivers))
    log_info("beamcomp.grid", string.format("field of %d exceeds the grid's authored %d; issuer notified",
        starters, authored))
end

-- Give every stored grid an explicit authored field size and persist it once (ADR-0023 amendment
-- 2026-08-02). Grids saved before the field existed get the default; a record whose previewCount is
-- unusable is repaired the same way. A record that already carries a usable one is left EXACTLY as it
-- stands, even when it is not the default -- this migration only ever adds the key it is named after.
-- Returns how many records were stamped. Called from ensure_grids_loaded, right after load_grids.
--
-- This is the first write to the grids file that no admin triggered, so it is fenced accordingly:
--   * it goes through write_grids (atomic temp -> rename, and it refuses a legacy-schema file itself);
--   * grids_clean gates it, so a missing/unparseable/legacy file -- for which load_grids returns early
--     with a deliberately EMPTY store -- is never rewritten from that empty store. That would be data
--     loss, and it is the whole reason the legacy guard exists (ADR-0023 amendment 2026-07-27);
--   * nothing stamped means nothing written at all. That is what makes it idempotent -- and writing the
--     grids file is itself what trips BeamMP's file watcher into re-running this chunk (see grid_store's
--     grids_loaded note), so the run that follows the migration's own write MUST find nothing to do or
--     the pair would write each other in a loop. It re-loads, finds every record stamped, and stops.
-- Declared here (with the other post-write_grids grid_store helpers) because it calls write_grids, a
-- local declared after load_grids -- see the call site in ensure_grids_loaded.
function grid_store.stamp_preview_counts()
    if not grid_store.grids_clean then
        return 0
    end

    local stamped = 0
    for _, map_grids in pairs(grid_store.grids) do
        if type(map_grids) == "table" then
            for _, race_grids in pairs(map_grids) do
                if type(race_grids) == "table" then
                    for _, record in pairs(race_grids) do
                        if type(record) == "table" and not grid_store.usable_preview_count(record) then
                            record.previewCount = grid_store.PREVIEW_COUNT_DEFAULT
                            stamped = stamped + 1
                        end
                    end
                end
            end
        end
    end
    if stamped == 0 then
        return 0
    end

    local ok, path = write_grids()
    if ok then
        log_info("beamcomp.grid", string.format("stamped a preview count of %d into %d saved grid(s);"
            .. " wrote %s", grid_store.PREVIEW_COUNT_DEFAULT, stamped, tostring(path)))
    else
        log_info("beamcomp.grid", string.format("stamped a preview count into %d saved grid(s) in memory"
            .. " but could not write the grids file", stamped))
    end
    return stamped
end

-- Preset store helpers (ADR-0037 amendment). Attached to grid_store, not top-level locals (200/200
-- ceiling). Mirror the grid read/load/ensure/write helpers above; the handlers live near the grid
-- handlers (below player_name_of/send_event). The server treats the form blob opaquely (ADR-0005).

-- Read + JSON-decode the presets file from the first candidate path that opens. Returns the decoded
-- table + resolved path, or nil + path + error label ("parse"/"missing"). pcall-guarded like read_grids.
function grid_store.read_presets()
    for _, path in ipairs(grid_store.PRESETS_CANDIDATE_PATHS) do
        local file = io.open(path, "r")
        if file then
            local contents = file:read("*a")
            file:close()
            local ok, decoded = pcall(Util.JsonDecode, contents)
            if not ok or type(decoded) ~= "table" then
                return nil, path, "parse"
            end
            return decoded, path, nil
        end
    end
    return nil, nil, "missing"
end

-- Populate grid_store.presets from the presets file. A missing or unparseable file leaves it empty
-- (an empty preset list -- the safe default). Clears in place so the folded symbols survive; the
-- resolved path is logged so the write target is visible in the console. Mirrors load_grids.
function grid_store.load_presets()
    grid_store.presets = {}

    local data, path, err = grid_store.read_presets()
    grid_store.presets_path = path
    if not data then
        if err == "parse" then
            log_info("beamcomp.preset", "presets file at " .. tostring(path)
                .. " is not valid JSON; starting with no presets")
        else
            log_info("beamcomp.preset", "no presets file found; starting with no presets")
        end
        return
    end

    if type(data.presets) == "table" then
        grid_store.presets = data.presets
    end
    log_info("beamcomp.preset", "loaded presets from " .. path)
end

-- Populate grid_store.presets once per Lua-state instance, lazily on first access, so preset access is
-- robust to a file-watch reload that resets the in-memory store without re-firing onInit (like grids).
function grid_store.ensure_presets_loaded()
    if grid_store.presets_loaded then
        return
    end
    grid_store.presets_loaded = true
    grid_store.load_presets()
end

-- Serialize grid_store.presets and write it back, trying the loaded path first then the candidates.
-- Atomic temp-swap + pcall-guarded, mirroring write_grids. Returns true + path on success, false else.
function grid_store.write_presets()
    local ok, encoded = pcall(Util.JsonEncode, {presets = grid_store.presets})
    if not ok then
        log_info("beamcomp.preset", "could not encode presets: " .. tostring(encoded))
        return false
    end

    local candidates = {}
    if grid_store.presets_path then
        candidates[#candidates + 1] = grid_store.presets_path
    end
    for _, path in ipairs(grid_store.PRESETS_CANDIDATE_PATHS) do
        candidates[#candidates + 1] = path
    end

    for _, path in ipairs(candidates) do
        -- Atomic write: fill a temp file, then swap it into place (a crash mid-write leaves the live
        -- file untouched). os.rename can't overwrite on Windows, so drop the target first -- see write_grids.
        local tmp = path .. ".tmp"
        local file = io.open(tmp, "w")
        if file then
            local ok_write = file:write(encoded)
            local ok_close = file:close()
            if ok_write and ok_close then
                os.remove(path)
                if os.rename(tmp, path) then
                    grid_store.presets_path = path
                    return true, path
                end
                log_info("beamcomp.preset", "could not commit presets write at " .. path)
            else
                log_info("beamcomp.preset", "could not write presets temp at " .. path)
            end
            os.remove(tmp)
        end
    end
    log_info("beamcomp.preset", "could not open any presets path for writing")
    return false
end

-- Resolve the run log's path once (ADR-0050): an existing file at the first candidate that opens for
-- reading wins, so a redeployed server keeps writing where its history already is; otherwise the first
-- candidate that can be created wins. Mirrors the config/grids candidate-path strategy (ADR-0016), which
-- tolerates the unverified runtime working directory. Returns the path, or nil when none is writable.
function runlog.resolve_path()
    -- Layer 0 of the statistics gate (ADR-0053), and the one that turns "the file is never created" from
    -- a claim about a checklist into a property of the code: the SECOND loop below probes candidates with
    -- io.open(path, "a"), which CREATES an empty beamcomp.runs.jsonl as a side effect. Every other run-log
    -- function reaches the file through this one, so even a caller the switch failed to gate cannot bring
    -- the file into existence. Do not move this below the runlog.path cache -- a path resolved while the
    -- feature was on must not keep answering after it is turned off.
    if not cfg.stats_enabled then
        return nil
    end
    if runlog.path then
        return runlog.path
    end
    for _, path in ipairs(runlog.CANDIDATE_PATHS) do
        local file = io.open(path, "r")
        if file then
            file:close()
            runlog.path = path
            return path
        end
    end
    for _, path in ipairs(runlog.CANDIDATE_PATHS) do
        local file = io.open(path, "a")
        if file then
            file:close()
            runlog.path = path
            return path
        end
    end
    return nil
end

-- Append runs to the log as one JSON object per line (ADR-0050). The whole race goes out in a single
-- open/write/close -- no rewrite, so cost is independent of how much history has accumulated. Encoding
-- and file I/O are pcall-guarded: a failure is logged and the run is lost, never thrown into the BeamMP
-- runtime. Every line is newline-terminated, so a crash mid-write can only damage the last line, which
-- readers skip. Returns true when the block reached disk.
function runlog.append(runs)
    -- Layer 1 of the statistics gate (ADR-0053): the write itself. resolve_path below already refuses
    -- while off, so this is redundant by construction -- it is stated anyway because this is the single
    -- line the whole acceptance test hangs on, and a reader should not have to trace two calls deep to
    -- convince themselves nothing is written.
    if not cfg.stats_enabled then
        return false
    end
    if #runs == 0 then
        return true
    end
    local path = runlog.resolve_path()
    if not path then
        log_info("beamcomp.records", "could not open any run log path for appending")
        return false
    end

    local encoded = {}
    for _, run in ipairs(runs) do
        local ok, line = pcall(Util.JsonEncode, run)
        if ok then
            encoded[#encoded + 1] = line
        else
            log_info("beamcomp.records", "could not encode run: " .. tostring(line))
        end
    end
    if #encoded == 0 then
        return false
    end

    local file = io.open(path, "a")
    if not file then
        log_info("beamcomp.records", "could not open run log at " .. path .. " for appending")
        return false
    end
    local ok_write = file:write(table.concat(encoded, "\n"), "\n")
    local ok_close = file:close()
    if not ok_write or not ok_close then
        log_info("beamcomp.records", "could not append " .. #encoded .. " run(s) to " .. path)
        return false
    end
    log_info("beamcomp.records", string.format("appended %d run(s) to %s", #encoded, path))
    return true
end

-- Derive the aggregate once per Lua-state instance, lazily on first access -- robust to a file-watch
-- reload that resets the in-memory store without re-firing onInit, exactly like ensure_grids_loaded.
-- runlog.replay is assigned further down (after the fold helpers it needs); by the time anything calls
-- this, the chunk has fully executed.
function runlog.ensure()
    -- Layer 1 of the statistics gate (ADR-0053): no replay while off, so runlog.store stays empty and
    -- nothing downstream can derive a best time from a log we are not reading. Gating here covers all
    -- three callers at once (on_init, snapshot_prerun_section_bests, capture_records).
    --
    -- Deliberately does NOT set runlog.loaded on the way out: turning the key back on and reloading the
    -- plugin must replay for real, not find a "already loaded" latch left behind by the disabled run.
    if not cfg.stats_enabled then
        return
    end
    if runlog.loaded then
        return
    end
    runlog.loaded = true
    runlog.replay()
end

local function now()
    return clock:GetCurrent()
end

local function phase_elapsed()
    return now() - session.phase_started_at
end

-- Outgoing payload sizes per message type, as a high-water mark (bug offroad-race-massive-network-
-- payload-lag). The decisive measurement: it says whether any standings/racePhase broadcast ever comes
-- near the ~145 KB the client decompresses per checkpoint, or whether only raceStart is ever big.
--
-- Sparse by construction -- a type is logged only when it sets a NEW size peak, so a broadcast (one
-- send_event per player with the same payload) collapses to a single line and a steady-state race falls
-- silent. Peaks are deliberately never reset: the lag arrives "from one race to the next", so a type that
-- keeps setting new peaks race after race is itself the finding (something accumulates).
--
-- Sizes only, never payload contents -- the server measures the LENGTH of the envelope it already ships
-- and reads nothing inside it, so race-blindness (ADR-0005) holds. Hangs off a namespace table rather
-- than top-level locals: main.lua sits at LuaJIT's 200-local ceiling (see grid_store / f1).
local net = {peak = {}}

-- Guard a reported partConfig `variant` before it can key a record, ride the wire, or be persisted (bug
-- partconfig-blob-bloats-standings). A real preset name is a short string; an inline-customized car can
-- report its full serialized partsTree (~74 KB) as `variant`, which pre-fix leaked into car.key and bloated
-- every ~1 Hz standings broadcast to ~150 KB, freezing the host. Accept only a short (<= 64 char),
-- single-line string with no serialized-table markers ("{" / "partsTree"); anything else -> nil, so the car
-- buckets under model-only (vehicle_car_key). The 64 cap matches the client gate (race/vehicles.lua).
-- Defense-in-depth: the client already gates this at the source, but an old/malformed client -- or an old
-- run-log line loaded into track.vehicle -- can still carry a blob. On `net` (not a top-level local):
-- main.lua sits at LuaJIT's 200-local ceiling, and guarding what goes on the wire is a net concern.
function net.safe_variant(variant)
    if type(variant) ~= "string" or variant == "" or #variant > 64 then
        return nil
    end
    if variant:find("[{\r\n]") or variant:find("partsTree", 1, true) then
        return nil
    end
    return variant
end

-- Note an outgoing envelope's encoded size; log it only if it is that type's largest so far. The encode
-- is pcall-guarded and its result discarded (BeamMP re-encodes the table for the wire) -- a measurement
-- must never be the thing that breaks a send.
function net.note_size(message_type, envelope)
    local ok, encoded = pcall(Util.JsonEncode, envelope)
    if not ok or type(encoded) ~= "string" then
        return
    end
    local size = #encoded
    if size <= (net.peak[message_type] or 0) then
        return
    end
    net.peak[message_type] = size
    log_info("beamcomp.net", string.format("payload peak: %s = %d B", message_type, size))
end

-- Send a typed event to one client as a { type, payload } envelope. BeamMP
-- JSON-encodes the table; the client decodes it with the shared envelope module.
local function send_event(player_id, message_type, payload)
    local envelope = {
        type = message_type,
        payload = payload,
    }
    net.note_size(message_type, envelope)
    local ok, err = MP.TriggerClientEventJson(player_id, EVENT_CHANNEL, envelope)
    if not ok then
        log_info("beamcomp.net", "client event '" .. message_type .. "' to id "
            .. player_id .. " failed: " .. tostring(err))
    end
end

-- Send a typed event to every connected player. BeamMP has no broadcast for
-- TriggerClientEvent*, so loop over the player table (server API note, section 7).
local function broadcast_event(message_type, payload)
    for player_id in pairs(MP.GetPlayers()) do
        send_event(player_id, message_type, payload)
    end
end

-- ===== targeted track distribution (ADR-0046) ============================================
-- A client that does not have the race installed still races it: the issuer serializes the track and the
-- server relays it (ADR-0039). It used to ride the raceValidation + every player's raceStart -- tens of KB
-- shipped to EVERYONE at the busiest instant of the session, and thrown away by everyone who has the track
-- (they parse locally). Now it is pulled on demand instead:
--
--   race validated -> trackProbe (all but the issuer) -> trackNeed (only from clients that cannot resolve
--   the race locally) -> trackFetch (to the issuer, which provably has the files) -> trackUpload -> cached
--   here -> trackData (only to the clients that asked).
--
-- If everyone has the track, not one further byte is sent. The probe fires the moment the race passes
-- validation -- before the spawning phase, and for a QUEUED race an entire race early -- so the content is
-- there before it is needed rather than inside the race-start burst.
--
-- The blob is opaque: cached, relayed, never parsed. Race-blindness (ADR-0005) holds.
local track = {}

track.MSG_PROBE = "trackProbe"    -- server -> all but the issuer: "this race is coming; do you need it?"
track.MSG_NEED = "trackNeed"      -- client -> server: "I cannot resolve that race locally, send it"
track.MSG_FETCH = "trackFetch"    -- server -> issuer: "serialize that race's scenery for me"
track.MSG_UPLOAD = "trackUpload"  -- issuer -> server: the serialized scenery
track.MSG_DATA = "trackData"      -- server -> a needing client: the serialized scenery

track.content = {}   -- raceId -> the opaque prefab-content blob, cached for this server's lifetime
track.waiting = {}   -- raceId -> {player_id -> true}: who asked while no blob was cached yet
track.probed = {}    -- raceId -> true: the races the SERVER itself announced; only these are ever served
track.fetching = {}  -- raceId -> true: an upload we have asked the CURRENT issuer for (one per race)
track.owner_id = nil -- the last validated race's issuer: the one client known to hold the files

-- Announce a validated race to everyone but its issuer, so a client without the files can pull them now
-- rather than at the start. Records the issuer as the client to fetch from -- it just parsed this race for
-- its pre-flight verdict (ADR-0019), so it demonstrably has the content.
function track.probe(race_id, owner_id)
    if type(race_id) ~= "string" or race_id == "" then
        return
    end
    -- A DIFFERENT issuer voids every request we still have outstanding: those were addressed to the old
    -- one, which may well be gone. Only on a change, though -- the same admin queuing a second race must
    -- not invalidate the upload that the *running* race's clients are still waiting on.
    if track.owner_id ~= owner_id then
        track.fetching = {}
    end
    track.owner_id = owner_id
    track.probed[race_id] = true
    for player_id in pairs(MP.GetPlayers()) do
        if player_id ~= owner_id then
            send_event(player_id, track.MSG_PROBE, {raceId = race_id})
        end
    end
end

-- A client reports it cannot build this race locally. Serve it from the cache, or ask the issuer once and
-- park the client until the upload lands.
function track.handle_need(player_id, payload)
    if type(payload) ~= "table" or type(payload.raceId) ~= "string" then
        return
    end
    local race_id = payload.raceId

    -- Only ever service a race the server itself announced. Without this, any client could name an
    -- arbitrary string and have us order the ISSUER's client to resolve and parse it -- unbounded work on
    -- someone else's machine, driven from the network, once per made-up id. Everything legitimate is
    -- covered: a probe answer echoes an id we sent, and the race-start backstop's id was probed in
    -- commit_validated_race, which is the only way into a race at all.
    if not track.probed[race_id] then
        log_info("beamcomp.track", "ignored track request for an unannounced race from id "
            .. tostring(player_id))
        return
    end

    local cached = track.content[race_id]
    if cached then
        send_event(player_id, track.MSG_DATA, {raceId = race_id, prefabContent = cached})
        return
    end

    local waiting = track.waiting[race_id]
    if not waiting then
        waiting = {}
        track.waiting[race_id] = waiting
    end
    waiting[player_id] = true

    if track.fetching[race_id] then
        return  -- already asked; this client rides the same upload
    end
    if not track.owner_id then
        log_info("beamcomp.track", "no issuer to fetch '" .. race_id .. "' from")
        return
    end
    track.fetching[race_id] = true
    send_event(track.owner_id, track.MSG_FETCH, {raceId = race_id})
end

-- The issuer's serialized scenery. Accepted ONLY from the client we asked and ONLY for a race we actually
-- asked it about: this content is written to disk and spawned as scene objects on every receiver, so an
-- unguarded upload would let any client poison the cache and spawn arbitrary objects on everyone else (the
-- same owner discipline as the ADR-0019 handshake). Cached opaquely, then fanned out to whoever waited.
-- The request is cleared before caching, so a second upload for the same race can never overwrite it.
function track.handle_upload(player_id, payload)
    if type(payload) ~= "table" or type(payload.raceId) ~= "string" then
        return
    end
    if player_id ~= track.owner_id or not track.fetching[payload.raceId] then
        log_info("beamcomp.track", "dropped unsolicited track upload from id " .. tostring(player_id))
        return
    end

    local race_id = payload.raceId
    track.fetching[race_id] = nil
    -- An empty list is a legitimate answer (a race with no prefabs, or one the issuer could not read):
    -- cache it too, so the waiting clients are released instead of hanging on a fetch that never repeats.
    local content = type(payload.prefabContent) == "table" and payload.prefabContent or {}
    track.content[race_id] = content

    local waiting = track.waiting[race_id]
    track.waiting[race_id] = nil
    if not waiting then
        return
    end

    local served = 0
    for waiting_id in pairs(waiting) do
        send_event(waiting_id, track.MSG_DATA, {raceId = race_id, prefabContent = content})
        served = served + 1
    end
    log_info("beamcomp.track", string.format(
        "track '%s': %d prefab(s) cached, served to %d client(s)", race_id, #content, served))
end
-- ===== end targeted track distribution ===================================================

-- Send a chat line to every connected player. Like broadcast_event, BeamMP has no single broadcast,
-- so loop the player table (server API note, section 7).
local function broadcast_chat(message)
    for player_id in pairs(MP.GetPlayers()) do
        MP.SendChatMessage(player_id, message)
    end
end

-- Move the session into `phase`, stamp the entry time, and announce it to all clients as a
-- racePhase envelope. `duration` (seconds) is carried for timed phases so a client can render a
-- synced countdown; pass nil for open-ended phases (lobby, racing).
local function enter_phase(phase, duration, extra)
    -- The staged race's preparer is only meaningful while staging (ADR-0021 amendment). Dropping it here
    -- -- the one seam every transition passes -- means no exit can leave a stale id behind: not the
    -- manual start, not /raceclear, not the abandon net, and not /raceend, which reaches `finished`
    -- without going through reset_to_lobby.
    if phase ~= PHASE.staging then
        session.staged_by = nil
    end
    session.phase = phase
    session.phase_duration = duration
    session.phase_started_at = now()
    log_info("beamcomp.race", "phase -> " .. phase)
    local payload = {phase = phase, duration = duration}
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            payload[key] = value
        end
    end
    broadcast_event(MSG_RACE_PHASE, payload)
end

-- Enter the standing-race start countdown (ADR-0043). With the F1 light start active (and `allow_lights`,
-- i.e. this countdown leads to racing, not a quali out-lap), use a longer, randomly-held countdown flagged
-- `lights` so clients render the light tower and free the car; lights-out is the unchanged countdown ->
-- racing transition the tick already fires. Otherwise the plain fixed countdown (the default lock start).
function f1.enter_countdown(allow_lights)
    if allow_lights and session.start_mode == "f1" then
        enter_phase(PHASE.countdown, f1.countdown_duration(), {lights = true})
    else
        enter_phase(PHASE.countdown, PHASE_DURATIONS.countdown)
    end
end

-- Shuffle an array in place (Fisher-Yates) using math.random (seeded in on_init). Used by the random
-- start order and the no-source fallback for last (ADR-0033).
local function shuffle(items)
    for i = #items, 2, -1 do
        local j = math.random(i)
        items[i], items[j] = items[j], items[i]
    end
    return items
end

-- Order ids by an identity ranking list (ADR-0033/0040): ids whose identity (ADR-0031) appears in
-- `ranking` come first in ranking order (optionally reversed), the rest keep their incoming entry order at
-- the back. Shared by order=last (previous finish) and order=championship (points table). An empty ranking
-- leaves every id in the back group, i.e. plain entry order.
local function place_by_identity(ids, ranking, rev)
    -- An id's ranking identity: AI ids are strings "ai:<k>" whose display name -- the roster name or
    -- "AI <k>" (ADR-0047) -- keys them in the standings, so the championship/last-order/quali rankings can
    -- match AI alongside players; real player ids are numbers resolved via resolve_identity (ADR-0031).
    -- grid_store.ai_display_name is defined further down (next to the AI helpers) but exists by the time
    -- this runs -- place_by_identity is only called during race operations.
    local function identity_of(id)
        if type(id) == "string" then
            return grid_store.ai_display_name(id)
        end
        return resolve_identity(id)
    end
    local rank = {}
    for pos, identity in ipairs(ranking) do
        rank[identity] = pos
    end
    local placed, rest = {}, {}
    for _, id in ipairs(ids) do  -- ids are in entry order, so rest stays entry-ordered
        if rank[identity_of(id)] then
            placed[#placed + 1] = id
        else
            rest[#rest + 1] = id
        end
    end
    table.sort(placed, function(a, b)
        return rank[identity_of(a)] < rank[identity_of(b)]
    end)
    if rev then
        for i = 1, math.floor(#placed / 2) do
            placed[i], placed[#placed - i + 1] = placed[#placed - i + 1], placed[i]
        end
    end
    for _, id in ipairs(rest) do
        placed[#placed + 1] = id
    end
    return placed
end

-- Order the player ids for slot assignment per the start-order mode (ADR-0033). `entry` (default) is id
-- ascending -- the historical order and the stable base the other modes build on; `random` shuffles;
-- `last` follows the previous race's finishing order (by identity, ADR-0031), with absent ids appended at
-- the back in entry order and `:rev` reversing just the placed group. `pwr` orders as entry here -- it is
-- resolved after staging by the re-grid -- and `last` with no source falls back to random. `championship`
-- is handled in build_slots, since it ranks the AI into the field too (ADR-0040), not here.
local function order_ids(players, order, last_order)
    local ids = {}
    for id in pairs(players) do
        ids[#ids + 1] = id
    end
    table.sort(ids)

    local mode = order and order.mode or "entry"

    if mode == "random" then
        return shuffle(ids)
    end

    if mode == "last" then
        if type(last_order) ~= "table" or #last_order == 0 then
            return shuffle(ids)  -- no finishing-order source yet -> random fallback
        end
        return place_by_identity(ids, last_order, order.rev)
    end

    -- entry, or pwr/quali (provisional entry order until their re-grid resolves it -- pwr after staging,
    -- quali after the qualifying session; ADR-0033/0041).
    return ids
end

-- Synthetic AI participants (ADR-0036): host-driven opponents that fill the grid for small lobbies. They
-- are ordinary id-keyed participant records whose id is a string "ai:<k>" (so a numeric player id never
-- collides), whose grid car the race owner spawns + drives, and whose progress the owner reports by
-- proxy. The server never drives or reads them -- race-blindness (ADR-0005) holds; AI are just a
-- participant kind kept out of every per-client path (no client backs an AI slot).
local AI_ID_PREFIX = "ai:"
local MAX_AI = 16
local DEFAULT_AI_COUNT = 1

-- Whether a participant id is a synthetic AI slot rather than a real player id (a BeamMP numeric id).
local function is_ai_id(id)
    return type(id) == "string" and id:sub(1, #AI_ID_PREFIX) == AI_ID_PREFIX
end

-- The synthetic AI ids "ai:1".."ai:<n>" for a count (ADR-0036). Empty for a nil/zero count.
local function ai_id_list(ai_count)
    local ids = {}
    for k = 1, (tonumber(ai_count) or 0) do
        ids[#ids + 1] = AI_ID_PREFIX .. k
    end
    return ids
end

-- The roster entry for an AI id (ADR-0047): entry k of session.ai_roster backs "ai:<k>". nil without a
-- roster (the chat path) or for an unknown/foreign id. Attached to grid_store like the preset helpers,
-- NOT a new top-level local (200-local ceiling); grid_store is in scope from line ~318, so the earlier
-- place_by_identity can call these at runtime even though they are defined here, next to the AI helpers.
function grid_store.ai_roster_entry(id)
    local index = tonumber(tostring(id):sub(#AI_ID_PREFIX + 1))
    if not index or not session.ai_roster then
        return nil
    end
    return session.ai_roster[index]
end

-- The display name for a synthetic AI id (ADR-0047): the admin-authored roster name when the panel
-- shipped one, else the classic "AI <k>". The SINGLE resolver behind every AI name read
-- (place_by_identity, make_slot_entry, quali.identity_of, tour.identity_of) -- the name doubles as the
-- identity KEY for quali bests, championship points, tournament classes and order=last, so all sites
-- must agree. Without a roster this is byte-identical to the former inline "AI <k>" derivations.
function grid_store.ai_display_name(id)
    local entry = grid_store.ai_roster_entry(id)
    if entry and type(entry.name) == "string" and entry.name ~= "" then
        return entry.name
    end
    return "AI " .. tostring(id):sub(#AI_ID_PREFIX + 1)
end

-- The roster's pre-picked car token for an AI id (ADR-0047), or nil (chat path / no roster / entry
-- without a car). An opaque string ("model[:config]" or the "host" sentinel) -- never interpreted here
-- (race-blind, ADR-0005); it rides the per-slot ai_entry.car seam the class-drop tournament established.
function grid_store.ai_roster_car(id)
    local entry = grid_store.ai_roster_entry(id)
    return entry and entry.car or nil
end

-- The roster's per-AI primary-paint colour for an AI id (ADR-0047, round 3), or nil (chat path / no
-- roster). An opaque hex string -- never interpreted here (race-blind, ADR-0005); it rides a per-slot
-- ai_entry.color field to the owner, who maps it to a paint layer at spawn. Orthogonal to the car: it is
-- set on EVERY roster AI, including inside a class-drop tournament (the class wins the car, the roster
-- still colours it).
function grid_store.ai_roster_color(id)
    local entry = grid_store.ai_roster_entry(id)
    return entry and entry.color or nil
end

-- Sanitize the panel's roster for the session (ADR-0047): keep entry order (entry k backs "ai:<k>") and
-- disambiguate names DETERMINISTICALLY -- roster names are identity keys, so a collision with a connected
-- player's identity or an earlier roster entry (the UI prevents both, this is the defensive net) gets a
-- " (2)" / " (3)" ... suffix instead of mixing keys. Returns the sanitized array, or nil for no/empty
-- roster (the chat path -- every downstream read then falls back to "AI <k>").
function grid_store.sanitize_ai_roster(raw)
    if type(raw) ~= "table" or #raw == 0 then
        return nil
    end
    local taken = {}
    for id in pairs(MP.GetPlayers()) do
        local identity = resolve_identity(id)
        if identity then
            taken[identity] = true
        end
    end
    local roster = {}
    for k, entry in ipairs(raw) do
        if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
            local name = entry.name
            local suffix = 2
            while taken[name] do
                name = entry.name .. " (" .. suffix .. ")"
                suffix = suffix + 1
            end
            taken[name] = true
            roster[k] = {
                name = name,
                car = (type(entry.car) == "string" and entry.car ~= "") and entry.car or nil,
                -- Opaque per-AI paint colour (ADR-0047 round 3); relayed verbatim, never interpreted.
                color = (type(entry.color) == "string" and entry.color ~= "") and entry.color or nil,
            }
        end
    end
    if next(roster) == nil then
        return nil
    end
    return roster
end

-- ===== size-aware grid slot reservation (ADR-0051) =======================================
-- A bus or a semi is longer than the grid's row gap, and cars stand FRONT-anchored on their poses
-- (ADR-0034), so such a car's tail ends up exactly where the car behind it has its nose. The fix is a
-- SLOT MAP WITH HOLES: the big car keeps its slot, the slots its body covers are skipped when slots are
-- handed out and stay empty, and the field behind it moves back by exactly those slots. The grid math
-- itself (race/grid.lua, ADR-0023) is untouched -- clients simply lay out more poses than there are
-- participants, exactly as the ADR-0044 rally start ramp already does.
--
-- Only the server can decide this: each client computes its own poses, but the roster it gets is
-- {slot, name}, so no client knows what the others drive and two of them would claim the same free slot.
--
-- Everything hangs off this one table -- main.lua sits at the 200-top-level-local ceiling, so a bare
-- `local` per helper is not available (the same reason the f1 / quali / tour tables exist).
local grid_fit = {}

-- Clear air (metres) demanded between two cars, longitudinally and laterally. A fixed value by design:
-- explicitly NOT a grid-editor knob (ADR-0051 keeps the editor untouched).
grid_fit.SAFETY_MARGIN = 0.5

-- Mirrors of race/grid.lua's layout defaults, for a race with NO custom grid (the procedural fallback).
-- Reading the stored grid params numerically is the server's second documented exception to ADR-0023's
-- relay-verbatim rule -- the first is previewCount. Keep in step with DEFAULT_COLUMNS / DEFAULT_ROW_GAP /
-- DEFAULT_COL_GAP / MAX_AXIS_PIN over there; a drift costs a slightly wrong reservation, never a
-- desync (the server's slot map stays the single truth and the client derives its layout from it).
--
-- AXIS_CAPACITY is the odd one out: not a default the server falls back to, but the CLAMP a stored
-- rows/columns pin is cut to before the column count is derived from it -- and the one of the four whose
-- drift is not slight. A server clamping tighter than the client reserves its holes in a grid of a
-- different width than the one the client lays out, which is a wrong reservation for every pin between
-- the two bounds. It moved from 8 to 32 with the client's pin cap (bug
-- grideditor-knobs-missing-upper-clamp). MAX_PASSES below is unaffected by that: a columns-pinned
-- segment's geometry does not depend on the extent at all, and a rows-pinned one still maps the extent
-- through ceil(count / rows) -- a wider range of pins, not a new way for the fixpoint to oscillate.
grid_fit.DEFAULT_COLUMNS = 2
grid_fit.DEFAULT_ROW_GAP = 8.0
grid_fit.DEFAULT_COL_GAP = 4.0
grid_fit.AXIS_CAPACITY = 32

-- Safety rails.
--   MAX_PASSES -- the allocation is a fixpoint: a ROWS-pinned segment derives its column count from how
--     many poses are laid out (race/grid.lua), which is what the allocation itself decides. It settles on
--     the first comparison for the columns-pinned default; give the rows-pinned case a few tries and then
--     give up rather than guess, because server and client must agree on the column count exactly.
--   MAX_SCAN_PER_CAR -- hard bound on the search for a free slot, so a degenerate grid (or a logic slip)
--     can never spin the BeamMP server's single Lua thread.
grid_fit.MAX_PASSES = 6
grid_fit.MAX_SCAN_PER_CAR = 64

-- The per-direction param block a client will feed to its grid math, out of a stored grid record.
-- Mirrors race/start.lua grid_params_for including its fallback: a reverse race on a grid with no
-- reverse block lays out the procedural default (nil here).
function grid_fit.direction_block(record, direction)
    if type(record) ~= "table" then
        return nil
    end
    if direction == "reverse" then
        return record.reverse
    end
    return record.forward
end

-- The ordered segment list a block expands to, mirroring race/grid.lua block_to_segments: the block's
-- own params are segment 0, its optional `segments` array supplies the rest, sorted by start slot. Only
-- the width pin and the two gaps are ever read from a param set -- the offsets, heading and mirror move
-- poses around but never change which slot sits behind or beside which.
function grid_fit.segments(block)
    local list = {{start = 0, params = type(block) == "table" and block or {}}}
    local extra = type(block) == "table" and block.segments or nil
    if type(extra) == "table" then
        for _, segment in ipairs(extra) do
            if type(segment) == "table" and type(segment.params) == "table" then
                local start = tonumber(segment.startSlot)
                if start and start >= 1 then
                    list[#list + 1] = {start = math.floor(start), params = segment.params}
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.start < b.start end)
    return list
end

-- The layout geometry in force at a layout index, given how many poses the client lays out in total:
-- {start, columns, row_gap, col_gap}. Mirrors race/grid.lua resolved_params plus compute_segment's
-- column rule -- an explicit `columns` pins the width, an explicit `rows` lets the columns grow with the
-- SEGMENT's size, neither pins the two-column default, and both pins clamp to [1, AXIS_CAPACITY].
-- A gap that is absent falls back to the default; a gap that is present but not a usable positive
-- number comes back as 0, which switches that axis of the fit off rather than dividing by it.
function grid_fit.geometry(segments, index, total)
    local position = 1
    for step = 2, #segments do
        if segments[step].start <= index then
            position = step
        end
    end
    local segment = segments[position]
    local next_start = segments[position + 1] and segments[position + 1].start or total
    local count = math.max(math.min(next_start, total) - segment.start, 1)
    local params = segment.params

    local has_columns = type(params.columns) == "number" and params.columns >= 1
    local has_rows = type(params.rows) == "number" and params.rows >= 1
    local columns
    if has_columns then
        columns = math.max(1, math.min(grid_fit.AXIS_CAPACITY, math.floor(params.columns)))
    elseif not has_rows then
        columns = grid_fit.DEFAULT_COLUMNS
    else
        local rows = math.max(1, math.min(grid_fit.AXIS_CAPACITY, math.floor(params.rows)))
        columns = math.ceil(count / rows)
    end

    return {
        start = segment.start,
        columns = columns,
        row_gap = grid_fit.gap(params.rowGap, grid_fit.DEFAULT_ROW_GAP),
        col_gap = grid_fit.gap(params.colGap, grid_fit.DEFAULT_COL_GAP),
    }
end

-- A usable positive gap: the default when the param is absent, 0 when it is present but unusable.
-- Stored grids are hand-editable JSON, and race/grid.lua's `params.rowGap or DEFAULT` would let a 0
-- through (0 is truthy in Lua) -- here that 0 has to mean "do not reason about this axis".
function grid_fit.gap(value, fallback)
    if value == nil then
        return fallback
    end
    if type(value) ~= "number" or value ~= value or value <= 0 then
        return 0
    end
    return value
end

-- Where a layout index sits inside its segment, in metres: `setback` back along the travel axis and
-- `lateral` across it. Mirrors race/grid.lua's slot_setback and column spread, minus every term that is
-- identical for all slots of one segment (offsetForward / offsetLateral / mirror / headingDeg) -- those
-- cancel when two slots of the same segment are compared.
--
-- The columns are STAGGERED: the next slot is only row_gap/columns further back, and only the slot
-- `columns` later sits a full row_gap behind. That is why the fit compares actual rectangles instead of
-- testing a length against row_gap -- the nearest car in the travel direction is normally the diagonal
-- one, not the one in the same column.
function grid_fit.slot_offsets(geometry, index)
    local local_index = index - geometry.start
    local column = local_index % geometry.columns
    local row = math.floor(local_index / geometry.columns)
    return row * geometry.row_gap + column * (geometry.row_gap / geometry.columns),
        column * geometry.col_gap
end

-- Whether two cars on the same segment keep the safety margin. Each car is a rectangle: its front on its
-- pose with the body extending BACKWARD by its length (front-anchored, ADR-0034), centred laterally on
-- the pose (the placement puts the box centre there). They are clear when at least one axis separates
-- them by the margin -- which is exactly what "these two cannot touch" means.
--
-- This one rule replaces the per-axis proxies of round 1 (length vs row_gap, width vs col_gap). Each of
-- those was right about the case it was named after and blind to the others: the staggered diagonal
-- neighbour, a wide car beside an already-placed narrow one, and a long car reaching across a row
-- boundary into the next column.
function grid_fit.clears(one, two)
    local lateral = math.abs(one.lateral - two.lateral) - (one.width + two.width) / 2
    if lateral >= grid_fit.SAFETY_MARGIN then
        return true
    end
    local longitudinal = math.max(one.setback - (two.setback + two.length),
        two.setback - (one.setback + one.length))
    return longitudinal >= grid_fit.SAFETY_MARGIN
end

-- One allocation pass over `ordered` (participant ids in START ORDER -- never re-sorted), assuming the
-- client lays `total` poses out. `offset` shifts a participant slot onto its layout index: 1 for the
-- staged-quali start ramp the client splits off the front (ADR-0044), else 0.
--
-- Each car takes the first slot at or after the previous one that clears every car already placed on the
-- same segment. Slots that no longer clear are simply passed over and stay empty -- that IS the
-- reservation, and it needs no separate bookkeeping. A car whose footprint is unknown takes the next slot
-- and constrains nobody, the same way an unreported pwr just sorts to the back instead of failing.
--
-- Cars on DIFFERENT segments are never compared: a segment starts at its predecessor's continuation point
-- with its own offsets and heading (race/grid.lua), which the server does not reproduce. Returns the slot
-- per ordered position plus the resulting participant-slot extent, or nil when the search ran away.
function grid_fit.assign_pass(ordered, sizes, segments, offset, total)
    local placed = {}
    local slots = {}
    local cursor = 0
    for position, id in ipairs(ordered) do
        local size = sizes[id]
        local slot
        for candidate = cursor, cursor + grid_fit.MAX_SCAN_PER_CAR do
            local index = candidate + offset
            local geometry = grid_fit.geometry(segments, index, total)
            -- No footprint, or a grid whose gaps cannot be reasoned about (a hand-edited 0): take the
            -- slot as it comes, exactly as before this feature existed.
            if not size or geometry.row_gap <= 0 or geometry.col_gap <= 0 then
                slot = candidate
                break
            end
            local setback, lateral = grid_fit.slot_offsets(geometry, index)
            local box = {
                setback = setback,
                lateral = lateral,
                length = size.length,
                width = size.width,
                segment = geometry.start,
            }
            local free = true
            for _, other in ipairs(placed) do
                if other.segment == box.segment and not grid_fit.clears(box, other) then
                    free = false
                    break
                end
            end
            if free then
                slot = candidate
                placed[#placed + 1] = box
                break
            end
        end
        if not slot then
            return nil
        end
        slots[position] = slot
        cursor = slot + 1
    end
    return slots, cursor
end

-- The reported footprints keyed by participant id (ADR-0051 §3). Only a complete, positive pair counts:
-- a car whose box could not be read reserves nothing, the same way an unreported pwr just sorts to the
-- back instead of failing the grid.
function grid_fit.sizes()
    local sizes = {}
    for id, info in pairs(session.identities or {}) do
        local length = tonumber(info.car_length)
        local width = tonumber(info.car_width)
        if length and width and length > 0 and width > 0 then
            sizes[id] = {length = length, width = width}
        end
    end
    return sizes
end

-- Assign every participant in `ordered` a 0-based slot, leaving the slots an oversized car covers empty.
-- Returns the slot list (1:1 with `ordered`), or nil when there is nothing to reserve or the fit could
-- not be resolved -- the caller then falls back to today's contiguous slots.
--
-- The loop is the fixpoint from ADR-0051 §5: a rows-pinned segment's column count depends on how many
-- poses are laid out, which is what this decides, so a pass is re-run until the extent it produces is
-- the one it assumed. Bailing out on no-settle is deliberate -- a server that assumed a different column
-- count than the client uses would place cars into the wrong holes.
function grid_fit.assign(ordered)
    if #ordered == 0 then
        return nil
    end
    local sizes = grid_fit.sizes()
    if next(sizes) == nil then
        return nil
    end
    local segments = grid_fit.segments(grid_fit.direction_block(session.grid_record,
        session.grid_direction))
    local offset = session.grid_ramp and 1 or 0
    local extent = #ordered
    for _ = 1, grid_fit.MAX_PASSES do
        local slots, next_extent =
            grid_fit.assign_pass(ordered, sizes, segments, offset, extent + offset)
        if not slots then
            log_info("beamcomp.grid", "slot reservation ran out of candidate slots; using a plain grid")
            return nil
        end
        if next_extent == extent then
            return slots
        end
        extent = next_extent
    end
    log_info("beamcomp.grid", "slot reservation did not settle on a grid size; using a plain grid")
    return nil
end

-- ===== footprints known BEFORE the slots are handed out (ADR-0051 round 2) ================
-- Round 1 reported every footprint from inside the race-start handler -- which runs AFTER the server has
-- assigned slots and sent raceStart, so the first grid a player ever saw was necessarily the unreserved
-- one and the reservation could only ever be a correction. These two sources close that: a car the server
-- already knows about when /race is issued reserves its space in the FIRST slot assignment.
--
-- Neither makes the race start wait on anything. A footprint that is missing simply is not there, slots
-- are handed out densely as before, and the post-spawn report corrects it exactly as it does today.

grid_fit.MSG_SIZE = "carSize"

-- Footprints of the car each connected player is currently sitting in, keyed by player id.
-- CONNECTION-scoped, not race-scoped -- modelled on client_names (ADR-0031) for the same reason: it has
-- to be available before a race exists. Cleared on disconnect.
grid_fit.client_sizes = {}

-- A client reports the car it is sitting in (unsolicited, from the lobby). Two plain numbers, arithmetic
-- only, never a vehicle the server reads (race-blind, ADR-0005). An unreadable pair clears the entry
-- rather than keeping a stale one -- a footprint that no longer describes the car is worse than none.
function grid_fit.handle_size(player_id, payload)
    if type(payload) ~= "table" then
        return
    end
    local length = tonumber(payload.carLength)
    local width = tonumber(payload.carWidth)
    if not length or not width or length <= 0 or width <= 0 then
        grid_fit.client_sizes[player_id] = nil
        return
    end
    grid_fit.client_sizes[player_id] = {length = length, width = width}
    log_info("beamcomp.grid", string.format("carSize id=%s %.2f x %.2f m",
        tostring(player_id), length, width))
end

-- The roster's per-AI car tokens as {index, car} entries (ADR-0047), for the pre-flight footprint
-- request. A list, not a sparse array: entries without a pre-picked car are left out, and a sparse Lua
-- array does not survive a JSON round trip as one.
function grid_fit.roster_cars(roster)
    if type(roster) ~= "table" then
        return nil
    end
    local list = {}
    for index, entry in ipairs(roster) do
        if type(entry) == "table" and type(entry.car) == "string" and entry.car ~= "" then
            list[#list + 1] = {index = index, car = entry.car}
        end
    end
    if #list == 0 then
        return nil
    end
    return list
end

-- A reported {carLength, carWidth} pair as {length, width}, or nil when it is not a usable pair.
function grid_fit.usable_pair(reported)
    if type(reported) ~= "table" then
        return nil
    end
    local length = tonumber(reported.carLength)
    local width = tonumber(reported.carWidth)
    if not length or not width or length <= 0 or width <= 0 then
        return nil
    end
    return {length = length, width = width}
end

-- A list of {index, carLength, carWidth} entries as a table keyed by index.
function grid_fit.indexed_pairs(reported)
    if type(reported) ~= "table" then
        return nil
    end
    local sizes = {}
    for _, entry in ipairs(reported) do
        local index = type(entry) == "table" and tonumber(entry.index) or nil
        local pair = grid_fit.usable_pair(entry)
        if index and pair then
            sizes[math.floor(index)] = pair
        end
    end
    if next(sizes) == nil then
        return nil
    end
    return sizes
end

-- Write a footprint into this race's identity record without disturbing anything else already there.
function grid_fit.seed(id, length, width)
    if not id or not length or not width then
        return
    end
    session.identities = session.identities or {}
    local record = session.identities[id] or {}
    record.car_length = length
    record.car_width = width
    session.identities[id] = record
end

-- Seed the footprints that are already known at race start, before the slots are assigned.
--
--   * every connected player's LOBBY car -- but only when the policy actually leaves them in it. A fixed
--     car=, a weight/power cap that may substitute, or a class-drop class car all mean the lobby car is
--     not the car that will be on the grid, and a wrong footprint is worse than none.
--   * the FIXED car, for everyone, when there is one (the issuer's client resolved its box during the
--     pre-flight check).
--   * each AI's roster car, else the uniform aicar (same source). A randomly rolled AI car cannot be
--     known here and is reported after its spawn.
function grid_fit.seed_known(overrides, ai_count)
    local capped = overrides.maxhp or overrides.maxpwr or overrides.maxkg or overrides.minkg
    if overrides.car_size then
        for id in pairs(MP.GetPlayers()) do
            grid_fit.seed(id, overrides.car_size.length, overrides.car_size.width)
        end
    -- session.tournament rather than tour.is_active(): the tour table is declared later in the file
    -- (the same reason quali.regrid reads the field directly).
    elseif not overrides.car and not capped and session.tournament == nil then
        for id in pairs(MP.GetPlayers()) do
            local size = grid_fit.client_sizes[id]
            if size then
                grid_fit.seed(id, size.length, size.width)
            end
        end
    end
    for k = 1, (tonumber(ai_count) or 0) do
        local size = (overrides.ai_roster_sizes and overrides.ai_roster_sizes[k]) or overrides.ai_car_size
        if size then
            grid_fit.seed(AI_ID_PREFIX .. k, size.length, size.width)
        end
    end
end

-- One slot record for an id at a 0-based slot. AI ids (ADR-0036) carry their display name -- the roster
-- name when the panel shipped one, else "AI <k>" (ADR-0047) -- and the ai flag; real players carry their
-- connected name. Keeps build_slots free of the player/AI branch.
local function make_slot_entry(id, slot, players)
    if is_ai_id(id) then
        return {id = id, slot = slot, name = grid_store.ai_display_name(id), ai = true}
    end
    return {id = id, slot = slot, name = players[id]}
end

-- Assign every participant (connected players + the requested AI, ADR-0036 Etappe B) a 0-based slot in
-- the resolved start order (ADR-0033). For `random` the AI shuffle into the field with the players; for
-- `championship` the AI are ranked into the field by their own points (ADR-0040), since they score too; for
-- entry/last/pwr/quali the players are ordered first and the AI appended at the back -- their natural
-- position (no entry/finish history) and it avoids the mixed numeric/string id sort. pwr re-sorts the AI
-- into the field after staging (regrid_by_pwr); quali re-grids the whole field by pace after the qualifying
-- session (quali.regrid, ADR-0041). Deterministic for a given mode + roster so every client computes the
-- same grid.
local function build_slots(players, order, last_order, champ_order, ai_count)
    local mode = order and order.mode
    -- The quali provisional grid honors the selectable quali-start order (ADR-0044 amendment,
    -- quali-start-order): random (default) or `last` (previous finish). Reuse the existing random / last
    -- slot paths verbatim, so the AI handling and the last_order source behave exactly as order=random /
    -- order=last; the deferred quali.regrid still sets the real race grid by pace after the qualifying
    -- session (ADR-0041). The staged launch queue is built from these slots (quali.start_session), so the
    -- spawn-slot order and the launch order are one and the same (ADR-0044). qualiStart is UI-only -- the
    -- chat order=quali path leaves it nil, which defaults to random (byte-identical to before). Only the
    -- local `order`/`mode` are rebound here; session.order keeps mode="quali" so the quali lifecycle holds.
    if mode == "quali" then
        if order.qualiStart == "last" then
            order = {mode = "last", rev = false}  -- pole to the previous winner; quali takes no :rev
            mode = "last"
        else
            mode = "random"
        end
    end
    local ids
    if mode == "random" then
        ids = {}
        for id in pairs(players) do
            ids[#ids + 1] = id
        end
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            ids[#ids + 1] = ai_id
        end
        ids = shuffle(ids)
    elseif mode == "championship" then
        -- AI score in the championship too (ADR-0040), so rank them into the grid with the players (by the
        -- points table) instead of pinning them to the back. The combined field starts in entry order
        -- (players by id, then AI), then place_by_identity ranks + optionally reverses it.
        local field = {}
        for id in pairs(players) do
            field[#field + 1] = id
        end
        table.sort(field)
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            field[#field + 1] = ai_id
        end
        if type(champ_order) ~= "table" or #champ_order == 0 then
            ids = shuffle(field)  -- first race, everyone on 0 points -> random grid (ADR-0040)
        else
            ids = place_by_identity(field, champ_order, order and order.rev)
        end
    elseif mode == "last" then
        -- order=last (ADR-0033) over the FULL field: session.last_order is captured from the final
        -- standings, which carry the AI's display names (ADR-0031/0047), so the AI have last-race finish
        -- info too. Rank players + AI together by it -- exactly the championship branch's mixed numeric/
        -- string-id handling -- instead of ordering only the players and pinning the AI to the back. AI
        -- present in last_order land in their last-finish order; AI absent from it (fresh roster / first
        -- race) fall to the back via place_by_identity's rest group. An empty/missing source -> random
        -- fallback, exactly as the players-only path did (order_ids) and as championship does. This is the
        -- shared build_slots seam, so it fixes order=last for the main-race grid AND the quali provisional
        -- grid (qualiStart=last is remapped to this mode above) -- one coherent behavior.
        local field = {}
        for id in pairs(players) do
            field[#field + 1] = id
        end
        table.sort(field)
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            field[#field + 1] = ai_id
        end
        if type(last_order) ~= "table" or #last_order == 0 then
            ids = shuffle(field)  -- no finishing-order source yet -> random fallback (ADR-0033 §2)
        else
            ids = place_by_identity(field, last_order, order and order.rev)
        end
    else
        ids = order_ids(players, order, last_order)
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            ids[#ids + 1] = ai_id
        end
    end
    -- Keep the space behind an oversized car free (ADR-0051). The ORDER resolved above is final -- only
    -- the slot NUMBERS may skip ahead. nil = nothing to reserve, which is the normal case right here (no
    -- car has spawned yet, so no footprint is known); the early and binding passes re-run the fit once
    -- the reports arrive.
    local assigned = grid_fit.assign(ids)
    local slots = {}
    for index, id in ipairs(ids) do
        slots[index] = make_slot_entry(id, assigned and assigned[index] or index - 1, players)
    end
    return slots
end

-- The roster shipped to every client: each player's slot + name, in slot order. Used
-- client-side for the full grid layout and marker labels. The name resolves through resolve_identity
-- (ADR-0054), so the grid labels show the player-set name like every other surface.
local function build_roster(slots)
    local roster = {}
    for _, entry in ipairs(slots) do
        roster[#roster + 1] = {slot = entry.slot, name = resolve_identity(entry.id) or entry.name}
    end
    return roster
end

-- Seed a per-player progress record for every slot, keyed by player id. Each record tracks the
-- player's checkpoint progress, cumulative split times, total time, and current lap (1-based, set
-- from each report -- ADR-0013); `finished` flips on the final crossing, and `dnf` flips (terminally)
-- on disconnect, /dnf, or finish-grace expiry (ADR-0014). Splits are 1-based: splits[k] is the
-- cumulative race-relative time at the k-th scored crossing; segment deltas are derived, not stored.
local function build_progress(slots)
    local progress = {}
    for _, entry in ipairs(slots) do
        progress[entry.id] = {
            -- The BeamMP name as a baseline (ADR-0054); standings and records resolve the canonical
            -- player-set name live via resolve_identity, since a player may still set one mid-session.
            name = entry.name,
            slot = entry.slot,
            completed = 0,
            splits = {},
            total_time = 0,
            finished = false,
            dnf = false,
            lap = 1,
            -- Synthetic host-driven AI participant (ADR-0036): excluded from records + the pwr re-grid,
            -- flagged in the standings. nil for real players, so the record is otherwise identical.
            ai = entry.ai or nil,
        }
    end
    return progress
end

-- The per-car records key from a reported vehicle (ADR-0029): the model, plus the variant (partConfig
-- preset name) when known. Inline-modified cars (no preset name) bucket under model-only; a nil vehicle
-- or missing model yields nil, so the run is counted only at the player/track level (no car attribution).
local function vehicle_car_key(vehicle)
    if type(vehicle) ~= "table" or type(vehicle.model) ~= "string" or vehicle.model == "" then
        return nil
    end
    -- Only a short, non-serialized preset name is a valid variant (bug partconfig-blob-bloats-standings). A
    -- malformed/old client or an old run-log line can carry a full serialized partsTree here; gate it
    -- so it can never key a record or ride a payload. Rejected -> model-only key (the inline-modified bucket).
    local variant = net.safe_variant(vehicle.variant)
    if variant then
        return vehicle.model .. "/" .. variant
    end
    return vehicle.model
end

-- A compact car descriptor for the one-shot carInfo channel and the records payload (ADR-0029 amendment): the
-- records key plus the raw fields the overlay shows. nil when there is no usable vehicle. `variant` is NOT
-- shipped separately -- `key` already encodes the (capped) variant, so the client derives the label from it
-- (car_label); shipping both duplicated the ~74 KB blob pre-fix (bug partconfig-blob-bloats-standings).
local function car_descriptor(vehicle)
    local key = vehicle_car_key(vehicle)
    if not key then
        return nil
    end
    return {key = key, model = vehicle.model, modified = vehicle.modified}
end

-- Build the live ranked standings from session.progress: a pure function over the per-player
-- records (race-blind, ADR-0005). Sort key: non-DNF before DNF (ADR-0014), then most checkpoints
-- completed, then earliest time at that checkpoint, then slot as a stable tiebreak -- so finishers and
-- active racers rank above DNFs, finished players lead by finish time, and DNFs rank by how far they
-- got. Each entry carries a 1-based position; `count` falls back to a shared known_count so entries
-- agree once any report has set it (nil at race-start baseline).
local function build_standings(final)
    if not session.progress then
        return {}
    end

    local ranked = {}
    local known_count
    for id, record in pairs(session.progress) do
        ranked[#ranked + 1] = {id = id, record = record}
        if not known_count and record.count then
            known_count = record.count
        end
    end
    table.sort(ranked, function(a, b)
        a, b = a.record, b.record
        if a.dnf ~= b.dnf then
            return not a.dnf  -- non-DNF ranks ahead of DNF (ADR-0014)
        end
        if a.completed ~= b.completed then
            return a.completed > b.completed
        end
        -- The F1 jump-start penalty (ADR-0043) only moves the order in the FINAL standings (`final`): live,
        -- a jumper keeps its on-track position and just carries the "+Ns" tag (the penalty is pending); at
        -- the finish the effective time = raw + penalty applies, demoting the jumper -- and so its
        -- championship/tournament points, which rank off this final order. Records keep the raw time.
        local a_time = (a.total_time or 0) + (final and (a.jump_penalty or 0) or 0)
        local b_time = (b.total_time or 0) + (final and (b.jump_penalty or 0) or 0)
        if a_time ~= b_time then
            return a_time < b_time
        end
        return a.slot < b.slot
    end)

    local entries = {}
    for i, item in ipairs(ranked) do
        local record = item.record
        entries[i] = {
            -- Participant id (the progress key): the client joins the one-shot car descriptor (carInfo
            -- channel) to this entry by id. Small + regrid-stable (survives quali.regrid re-seeding progress
            -- with new slots), unlike slot (ADR-0029 amendment, bug partconfig-blob-bloats-standings).
            id = item.id,
            position = i,
            slot = record.slot,
            -- Resolve the canonical identity live (ADR-0054): a player may set his name after this
            -- progress baseline was seeded with the BeamMP name.
            name = resolve_identity(item.id) or record.name,
            completed = record.completed,
            count = record.count or known_count,
            total_time = record.total_time,
            -- F1 jump-start penalty in seconds applied to this car's result (ADR-0043), or nil. The HUD
            -- tags the row "+Ns"; the sort above already ranks by the penalized effective time.
            jump_penalty = record.jump_penalty,
            -- F1 start reaction in seconds (ADR-0043): time from lights-out to first movement; negative =
            -- jumped. nil for a non-F1 race / before the car has moved. Shown in the HUD React column.
            reaction = record.reaction,
            finished = record.finished,
            dnf = record.dnf,
            lap = record.lap,
            best_lap = record.best_lap,
            -- Run-up time (gun -> start/finish line, circuit only; ADR-0022). Relayed for the analysis
            -- overlay's S0 column and clean lap-1 derivation (ADR-0028). nil for sprints / pre-line.
            run_up = record.run_up,
            -- Cumulative race-relative time at each scored crossing (ADR-0015). Shallow reference --
            -- downstream readers must not mutate. DNF entries carry only the splits completed before
            -- DNF; the results UI derives segment deltas from this.
            splits = record.splits,
            -- The driver's car (ADR-0029) is NO LONGER on the periodic standings entry (ADR-0029 amendment,
            -- bug partconfig-blob-bloats-standings): it is static per driver per race, so it now travels once
            -- on the carInfo channel (see handle_client_info) and the client renders it from its cache. This
            -- keeps a standings broadcast size-independent of the car.
            -- Synthetic host-driven AI slot (ADR-0036), so the HUD can tag it; nil for real players.
            ai = record.ai or nil,
        }
    end
    return entries
end

-- Broadcast the standings to every client as a `standings` envelope (ADR-0004). Fired at the
-- racing-phase baseline and after every accepted checkpoint report.
-- Broadcast the standings. `final` applies the F1 jump penalty to the order (ADR-0043) -- passed true only
-- for the finalize broadcast so the finished card shows the demotion; the live in-race broadcasts pass
-- false (default), so a jumper keeps its on-track position live and just carries the "+Ns" tag.
local function broadcast_standings(final)
    broadcast_event(MSG_STANDINGS, {entries = build_standings(final)})
end

-- Capture the just-finished race's order as a list of identities (ADR-0033), in build_standings rank
-- order (finishers by time first, DNF last). Stored in session.last_order, which reset_to_lobby leaves
-- intact so the next race's order=last has a source; overwritten on the next finish. Identities match
-- what build_slots resolves (resolve_identity), so order=last maps players back to their finishing place.
local function capture_finishing_order()
    local order = {}
    -- Final order (ADR-0043): the jump penalty counts, so order=last grids the next race by the penalized
    -- result.
    for _, entry in ipairs(build_standings(true)) do
        if entry.name then
            order[#order + 1] = entry.name
        end
    end
    session.last_order = order
end


-- Multi-race points championship (ADR-0040). All championship logic hangs off this one `champ` namespace
-- table -- a single top-level local, because main.lua's main chunk is near Lua's 200-local limit and a flat
-- set of ~20 locals would overflow it (the plugin then fails to load entirely). The state itself lives in
-- session.championship and -- like session.last_order -- survives reset_to_lobby, so points accumulate
-- across the races of a play-session; it is in-memory only (a plugin restart ends a championship). nil = no
-- championship active.
local champ = {}

-- Cross-side message + command names (ADR-0040), kept on the table to spare top-level local slots.
champ.CHAT_COMMAND = "/championship"  -- manage the championship (mutations admin-gated)
champ.MSG = "championship"            -- table + settings, broadcast on change + after each award
champ.MSG_CMD = "championshipCmd"     -- the setup panel's control: {action, preset, order} (ADR-0037)

-- Points schemes (ADR-0040). Only finishers score (DNF = 0, enforced by the caller). F1 is a fixed table by
-- finishing position. linear gives the winner one point per starter (everyone who lined up, finished or
-- not) and one less per place below -- so a full grid is worth more even if some crash out. quadratic is a
-- fixed halving from 64 (64, 32, 16, ... ) that stops once a place would score below one point.
champ.F1_POINTS = {25, 18, 15, 12, 10, 8, 6, 4, 2, 1}
champ.QUADRATIC_TOP = 64  -- P1 in the quadratic scheme; each place below scores half, floored, until < 1
champ.PRESETS = {"f1", "linear", "quadratic"}
champ.DEFAULT_PRESET = "f1"

-- The points a classified finisher at `position` (1-based among finishers) scores under `preset`, given
-- `starters` = the total field that lined up (finishers + DNFs). Out-of-range positions / unknown presets
-- score 0; the caller already gives DNFs nothing.
function champ.points(preset, position, starters)
    if type(position) ~= "number" or position < 1 then
        return 0
    end
    if preset == "linear" then
        return math.max(0, starters - position + 1)  -- P1 = one point per starter, -1 per place
    end
    if preset == "quadratic" then
        local pts = champ.QUADRATIC_TOP / (2 ^ (position - 1))
        return pts >= 1 and math.floor(pts) or 0  -- 64, 32, 16, ...; below 1 point scores nothing
    end
    return champ.F1_POINTS[position] or 0  -- f1 (default): fixed table, 0 beyond P10
end

-- Whether a championship is currently accumulating points.
function champ.is_active()
    return session.championship ~= nil
end

-- The grid order a championship imposes, from a grid choice string (ADR-0040/0041). "reversed" (default)
-- = current leader starts at the back (handicap); "normal" = leader on pole; "quali" = each race runs a
-- qualifying session and grids by pace (ADR-0041), the championship still scoring from the race result.
function champ.order(grid)
    if grid == "quali" then
        return {mode = "quali"}
    end
    return {mode = "championship", rev = grid ~= "normal"}
end

-- A grid-choice label ("reversed"/"normal"/"quali") for an order table, for the snapshot + chat lines.
function champ.order_label(order)
    if order.mode == "quali" then
        return "quali"
    end
    return order.rev and "reversed" or "normal"
end

-- Begin a fresh championship with empty standings (ADR-0040). preset defaults to F1; grid defaults to
-- reversed (the handicap default) -- the caller passes the parsed grid string ("normal"/"quali") or nil.
-- quali_seconds is the qualifying length used when grid="quali" (ADR-0041), defaulting to quali's default.
function champ.start(preset, grid, quali_seconds)
    session.championship = {
        points_preset = preset or champ.DEFAULT_PRESET,
        order = champ.order(grid or "reversed"),
        quali_seconds = quali_seconds or PHASE_DURATIONS.quali_default,
        standings = {},   -- keyed by identity (players) / display name (AI): {points, races, wins, best_finish, ai}
        race_count = 0,
    }
end

-- End the championship and clear its table.
function champ.reset()
    session.championship = nil
end

-- Live preset / grid-order changes on an active championship (ADR-0040). No-ops when none is active.
function champ.set_preset(preset)
    if champ.is_active() and preset then
        session.championship.points_preset = preset
    end
end

function champ.set_order(grid)
    if champ.is_active() then
        session.championship.order = champ.order(grid)
    end
end

-- Live qualifying-length change for a championship whose grid is quali (ADR-0041). seconds is already
-- clamped by the caller (the `quali` table is defined later in the file, so champ cannot call quali.clamp).
function champ.set_quali(seconds)
    if champ.is_active() and seconds then
        session.championship.quali_seconds = seconds
    end
end

-- Wins (P1 finishes) recorded for a championship entry -- finishes[1], or 0 (ADR-0040).
function champ.wins_of(entry)
    return (entry.finishes and entry.finishes[1]) or 0
end

-- The standings as a ranked list (ADR-0040): {identity, entry} ordered by points desc, then a
-- finishing-position countback (most 1st places, then most 2nds, then 3rds, ... -- motorsport style), then
-- identity as a stable final tiebreak. Drives both order=championship and the table.
function champ.rank_list()
    if not champ.is_active() then
        return {}
    end
    local ranked = {}
    for identity, entry in pairs(session.championship.standings) do
        ranked[#ranked + 1] = {identity = identity, entry = entry}
    end
    -- Compare two entries by countback: whoever has more finishes at the best still-differing position wins.
    -- Returns 1/-1 when one is ahead, 0 when fully tied (then the caller falls back to identity).
    local function countback(a, b)
        local maxp = 0
        for p in pairs(a.finishes) do if p > maxp then maxp = p end end
        for p in pairs(b.finishes) do if p > maxp then maxp = p end end
        for p = 1, maxp do
            local ca, cb = a.finishes[p] or 0, b.finishes[p] or 0
            if ca ~= cb then
                return ca > cb and 1 or -1
            end
        end
        return 0
    end
    table.sort(ranked, function(x, y)
        local a, b = x.entry, y.entry
        if a.points ~= b.points then
            return a.points > b.points
        end
        local cb = countback(a, b)
        if cb ~= 0 then
            return cb > 0
        end
        return x.identity < y.identity
    end)
    return ranked
end

-- The ranked identities alone, for the order=championship placement (ADR-0040).
function champ.order_identities()
    local ids = {}
    for _, item in ipairs(champ.rank_list()) do
        ids[#ids + 1] = item.identity
    end
    return ids
end

-- The grid order a live championship imposes on the next race, or nil when none is active (ADR-0040).
-- Applied in start_race unless the race carries an explicit order=.
function champ.active_order()
    if not champ.is_active() then
        return nil
    end
    return session.championship.order
end

-- Fold the just-finished race into the championship standings (ADR-0040). Called at the racing->finished
-- seam after every still-out player is DNF'd, so each standings entry is terminal (finished or DNF). DNF
-- scores 0 but still counts as a participation; classified finishers score by the active preset. Keyed by
-- canonical identity (players) or the AI slot's display name (ADR-0036). A no-op with no active championship.
function champ.award()
    if not champ.is_active() then
        return
    end
    local state = session.championship
    local standings = build_standings(true)  -- final order: the jump penalty counts toward points (ADR-0043)
    local starters = #standings  -- the whole field that lined up (finishers + DNFs); linear scores off this
    -- Everyone starts this race's gain at 0; a non-participant (in the table but not this race) keeps 0, so
    -- the "last race" column reads true for the whole table.
    for _, record in pairs(state.standings) do
        record.last_gain = 0
    end
    for _, entry in ipairs(standings) do
        local identity = entry.name
        if identity then
            local record = state.standings[identity]
            if not record then
                record = {points = 0, races = 0, finishes = {}, last_gain = 0, ai = entry.ai or nil}
                state.standings[identity] = record
            end
            record.races = record.races + 1
            if not entry.dnf then
                local gain = champ.points(state.points_preset, entry.position, starters)
                record.points = record.points + gain
                record.last_gain = gain
                record.finishes[entry.position] = (record.finishes[entry.position] or 0) + 1
            end
        end
    end
    state.race_count = state.race_count + 1
end

-- A client-facing snapshot of the championship table (ADR-0040): active flag, settings, ranked rows.
-- Shipped in the championship broadcast for the HUD finished card + the setup panel; active=false (no
-- rows) tells a client to hide the table after a reset. wins is derived from the finishes histogram;
-- lastGain is the points added in the most recent race (0 for a non-participant).
function champ.snapshot()
    if not champ.is_active() then
        return {active = false}
    end
    local state = session.championship
    local rows = {}
    for position, item in ipairs(champ.rank_list()) do
        local entry = item.entry
        rows[#rows + 1] = {
            position = position,
            name = item.identity,
            points = entry.points,
            wins = champ.wins_of(entry),
            races = entry.races,
            lastGain = entry.last_gain or 0,
            ai = entry.ai or nil,
        }
    end
    return {
        active = true,
        preset = state.points_preset,
        order = champ.order_label(state.order),
        -- Qualifying length in minutes for the panel control when grid=quali (ADR-0041).
        qualiMinutes = math.floor((state.quali_seconds or PHASE_DURATIONS.quali_default) / 60),
        raceCount = state.race_count,
        rows = rows,
    }
end

-- Broadcast the current championship table to every client (ADR-0040).
function champ.broadcast()
    broadcast_event(champ.MSG, champ.snapshot())
end

-- The overall winner line for the reset announcement (ADR-0040): the top of the ranked table (tie already
-- broken by points, best finish, wins), or nil when nobody scored.
function champ.winner_text()
    local top = champ.rank_list()[1]
    if not top then
        return nil
    end
    return string.format("%s (%d pts)", top.identity, top.entry.points)
end

-- Post the current championship table to one player as chat lines (ADR-0040), like /races. Open to all.
function champ.post_table(player_id)
    if not champ.is_active() then
        MP.SendChatMessage(player_id, "BeamComp: no championship active")
        return
    end
    local state = session.championship
    MP.SendChatMessage(player_id, string.format(
        "BeamComp championship (points=%s, grid=%s, races=%d):",
        state.points_preset, champ.order_label(state.order), state.race_count))
    local ranked = champ.rank_list()
    if #ranked == 0 then
        MP.SendChatMessage(player_id, "  (no points yet)")
        return
    end
    for position, item in ipairs(ranked) do
        local entry = item.entry
        local wins = champ.wins_of(entry)
        MP.SendChatMessage(player_id, string.format("  %d. %s -- %d pts (last +%d, %d win%s)",
            position, item.identity, entry.points, entry.last_gain or 0, wins, wins == 1 and "" or "s"))
    end
end


-- ===== driver liveness =====================================================================
-- One seam for all three finish graces: which drivers their own client has reported as AFK.
--
-- The server is race-blind (ADR-0005) -- no geometry, no positions, no velocities, and no client sends
-- telemetry -- so it has NO way of its own to tell a parked wreck from someone still driving. The client
-- can see that and reports it; this namespace is only the record of what was reported.
--
-- It used to guess instead, from the gap since a driver's last scored checkpoint. That heuristic ended a
-- real qualifying under a driver who was still driving, and the same log showed 90 s between two of their
-- checkpoints on a normal lap -- no fixed or adaptive threshold can separate that from a wreck. It was
-- removed rather than retuned (2026-09-03; ADR-0014). If no client ever reports, a grace simply runs its
-- full length, which is the pre-928a938 behaviour and never worse than the bug.
--
-- A namespace table rather than a set of top-level locals, because main.lua's main chunk sits near
-- Lua's 200-local ceiling: a table costs ONE local no matter how many functions it carries.
--
-- The flags live on session.stall_reported -- deliberately a sibling of session.progress, not a field on
-- the progress records. build_standings and the run log both read those records, and a new record field
-- is the shape that leaks into a broadcast or persisted blob; a sibling table cannot, which is what
-- keeps the wire format byte-identical here.
--
-- Declared ahead of the `quali` namespace on purpose: quali.advance_staged closes over `stall`, and Lua
-- binds upvalues when the closure is created, so a local declared after that function would silently
-- resolve to a nil global inside it.
local stall = {}

-- client->server: {stalled = bool} for the sender's own car, {aiId = ..., stalled = bool} for one of the
-- owner's AI. THE input to the predicate below -- the only one there is. Kept on the table, not as a
-- top-level local (200-local ceiling), like quali.MSG_* and track.MSG_*.
stall.MSG = "stallReport"

-- THE liveness predicate, and now a pure lookup: all three finish graces ask this one question --
-- maybe_end_race for the racing grace (ADR-0014), quali.advance_staged for the staged sprint's
-- finish-your-run grace (ADR-0044) and quali.anyone_lapping for the circuit quali's finish-your-lap
-- grace (ADR-0041).
--
-- Returns nil while the driver still counts as able to finish, or a short reason string when they do not,
-- which each caller drops straight into its log line.
--
-- There is exactly ONE input, and it is not the server's. A client report is a MEASUREMENT of a car
-- standing still; the crossing-gap guess that used to sit beside it was measuring nothing and is gone.
-- Silence therefore means "still driving", always -- an unreported driver holds their grace open for its
-- full length, which is the safe direction and the pre-928a938 behaviour.
function stall.verdict(id)
    if session.stall_reported and session.stall_reported[id] then
        return "reported stalled by its client"
    end
    return nil
end

-- Drop every reported flag. Per-race, like session.progress: called at race start and from
-- reset_to_lobby, so one race's staleness can never be read as the next race's liveness.
function stall.clear()
    session.stall_reported = nil
end

-- A grace is arming: drop every verdict from before it.
--
-- THE invariant: session.stall_reported may only ever describe the grace that is CURRENTLY armed. Each
-- client starts its 15 s standstill clock the instant it sees the MSG_FINISH_GRACE broadcast, so the
-- server must hold no flags at that same instant. Otherwise a verdict banked in an EARLIER grace -- a
-- qualifying session's, most easily -- discounts that driver in the very second the next grace arms, and
-- the 15 s everybody is promised is silently skipped. Observed exactly that way: four AI discounted at
-- "finish grace armed" with no report at all between the green light and the arm.
--
-- Arming is the one moment the two sides are guaranteed to be in step, which is why the clear belongs
-- here and not on a phase boundary: the client cannot lift a stale flag itself, because it drops its own
-- tracking table whenever no grace is running and so never sends the matching "moving again".
--
-- Deliberately NOT called from the tick, nor from maybe_end_race's shortening re-broadcast: WITHIN an
-- armed grace the flags are precisely what the three graces read, and clearing them there would erase
-- the answer instead of the staleness.
--
-- (This is the one job stall.arm_field did alongside seeding the checkpoint-gap stamps. The stamps went
-- with the heuristic; this responsibility was never re-homed, which is how the bug above got in.)
function stall.begin_grace()
    stall.clear()
end

-- Record or clear a CLIENT-MEASURED stall verdict for one driver (feature
-- stall-detection-client-measured-movement). The client owns the measurement -- it can see positions and
-- we cannot (ADR-0005) -- and reports only the two edges, so this is called once when a driver goes still
-- and once when they move again, never per frame. Edge-guarded here as well, so a client that lost its own
-- latch still cannot produce a second log line.
--
-- Purely a "stops holding the grace open" claim, and fully reversible: nothing here marks anybody DNF,
-- touches a progress record, or moves a car. The DNF still comes from finalize_race when the grace expires.
function stall.set_reported(id, stalled)
    local flags = session.stall_reported
    if stalled then
        if flags and flags[id] then
            return
        end
        flags = flags or {}
        session.stall_reported = flags
        flags[id] = true
        log_info("beamcomp.race", "driver " .. tostring(id)
            .. " reported stalled by its client -- no longer counts as able to finish")
        return
    end
    if not (flags and flags[id]) then
        return
    end
    flags[id] = nil
    log_info("beamcomp.race", "driver " .. tostring(id)
        .. " reported moving again by its client -- counts as able to finish once more")
end

-- Client->server stall verdict (stall.MSG). A player reports its own car; the race owner proxies each of
-- its AI with aiId -- the same split, and the same validation, as quali.handle_cleared and the checkpoint
-- proxy: accepted only from the owner and only for a known AI slot, so no client can flag another
-- participant. Reports outside a race phase, or for an id with no progress record, are dropped.
function stall.handle_report(player_id, payload)
    if session.phase ~= PHASE.racing and session.phase ~= PHASE.qualifying then
        return
    end
    if type(payload) ~= "table" then
        return
    end
    local subject_id = player_id
    if payload.aiId ~= nil then
        if player_id ~= session.owner_id or not is_ai_id(payload.aiId) then
            log_info("beamcomp.race", "stall report from id " .. tostring(player_id)
                .. " ignored: not the owner or bad aiId " .. tostring(payload.aiId))
            return
        end
        subject_id = payload.aiId
    end
    if not (session.progress and session.progress[subject_id]) then
        return
    end
    stall.set_reported(subject_id, payload.stalled == true)
end
-- ===== end driver liveness =================================================================


-- Qualifying-then-race format (ADR-0041). Like `champ`, all logic hangs off this one `quali` namespace
-- table to spare top-level local slots -- main.lua's main chunk sits near Lua's 200-local limit, and a flat
-- set of locals would overflow it and fail the whole plugin load. The event state lives in session.quali
-- and -- unlike last_order/championship -- is per-event: reset_to_lobby clears it. nil = not a quali event.
--
-- Qualifying is a DEFERRED start-order source modeled on order=pwr (ADR-0033): order=quali assigns a
-- provisional random grid at race start, runs a time-boxed session in which drivers set lap times, then
-- re-grids by quali pace (quali.regrid) before the race countdown. The server ranks the client-reported
-- best_lap/total_time only -- it never reads geometry (race-blind, ADR-0005).
local quali = {}

quali.MSG = "quali"  -- classification snapshot for the quali HUD + results card, broadcast on quali-results

-- Staged sprint quali cross-side messages (ADR-0044), kept on the table to spare top-level local slots.
quali.MSG_QUEUE = "qualiQueue"    -- holding-queue snapshot for the staged-quali HUD (own position/status/best)
quali.MSG_STAGE = "qualiStage"    -- "you're up": stage at the ramp and run the per-driver count (to driver / owner+aiId)
quali.MSG_HOLD = "qualiHold"      -- return to your holding slot (or stop in place) (to driver / owner+aiId)
quali.MSG_RESET = "qualiReset"    -- client->server: I hit recover, requeue me to the back of the queue
quali.MSG_CLEARED = "qualiCleared"-- client->server: the launched driver has cleared the ramp (>=15 m; Round 4)

-- Rally staged sprint quali timing (ADR-0044/Round4): a driver is teleported from its holding slot onto the
-- ramp, counts down STAGE_COUNTDOWN, then launches; the NEXT driver is not staged until the launcher has both
-- physically cleared the ramp (the client >=15 m gate) AND STAGE_GAP has passed since GO. The per-driver
-- count is rendered client-side; the server only paces on these timers, holding no geometry (race-blind).
quali.STAGE_COUNTDOWN = 8.0 -- start count at the ramp (8 -> GO), then the driver launches; NO pre-settle
                            -- (Round 4: the driver is teleported onto the ramp and the count begins at once)
-- Clearance countdown AFTER a driver launches and BEFORE the next is teleported onto the ramp, so the next
-- never spawns into the one just driving off. Round 4: the next stages only once BOTH this gap has passed
-- AND the launched driver has physically cleared the ramp (the >=15 m gate the client reports, quali.MSG_CLEARED).
-- Round 10: the gap doubles as a SETTLE timer -- when the clearing driver's run ends early (recover, finish,
-- forced requeue), the gap restarts from the requeue moment, covering the network round-trip of the teleport
-- back to the holding slot before anyone is staged onto the ramp.
quali.STAGE_GAP = 5.0
-- Fallback so a stuck/AFK driver who never clears the ramp cannot stall the whole field: this long after the
-- launch without a clear report the driver is FORCE-REQUEUED back to its holding slot (Round 10; players and
-- AI alike). The requeue restarts the gap as a settle timer, so the next driver still stages no earlier than
-- STAGE_GAP after the ramp actually emptied -- the cleared-AND-gap release gate is never bypassed. The client
-- 15 m gate normally fires first. Stays well above STAGE_GAP (5 s) so the two timers never collide.
quali.STAGE_CLEAR_TIMEOUT = 20.0

-- Selectable qualifying lengths in minutes for the panel presets (ADR-0041); the chat grammar also accepts
-- a free quali=<n>. A free value is clamped to [MIN, MAX] seconds.
quali.PRESETS = {5, 8, 12, 15}
quali.MIN_SECONDS = 60.0
quali.MAX_SECONDS = 1800.0

-- Buffer applied to the slowest best lap when sizing the finish-your-lap window (quali.lap_grace_window):
-- best_lap is by definition a driver's FASTEST lap, but the lap they are completing when the clock expires
-- is usually slower, so a flat "= best lap" would slightly under-serve the slowest driver. +10 % covers
-- normal lap-to-lap variance; kept minimal (the spec is "= best lap"). Applied before the clamp.
quali.LAP_GRACE_BUFFER = 1.10

-- Whether this race is a quali event at all (qualifying pending or already handed off to the race).
function quali.is_active()
    return session.quali ~= nil
end

-- Whether the qualifying session still owns the event -- it has not yet handed the grid to the race. The
-- tick uses this to route the first countdown into qualifying (vs. the race) for a quali event.
function quali.is_pending()
    return session.quali ~= nil and not session.quali.done
end

-- Whether this is the rally-style staged sprint quali (ADR-0044) rather than the ADR-0041 all-at-once
-- circuit best-lap quali. Set from the issuer client's stagedQuali verdict (meta.closed=false -> sprint).
function quali.is_staged()
    return session.quali ~= nil and session.quali.staged == true
end

-- The standings identity for a participant id (ADR-0031/0036): AI ids carry their display name -- the
-- roster name or "AI <k>" (ADR-0047) -- players resolve to the canonical client name (falling back to the
-- seeded record name / raw id). Keys session.quali.best consistently with build_standings entry.name, so
-- the staged ranking + re-grid line up (ADR-0044).
function quali.identity_of(id)
    if is_ai_id(id) then
        return grid_store.ai_display_name(id)
    end
    local record = session.progress and session.progress[id]
    return resolve_identity(id) or (record and record.name) or tostring(id)
end

-- Clamp a requested quali length (seconds) into the sane bounds (ADR-0041).
function quali.clamp(seconds)
    return math.max(quali.MIN_SECONDS, math.min(quali.MAX_SECONDS, seconds))
end

-- The qualifying's OWN start-order modes (ADR-0044 amendment, quali-start-order): the base order used
-- INSIDE a quali -- its provisional grid + the staged launch queue -- distinct from the race order= that
-- grids the main race (ADR-0033). Only `random` (default = today) and `last` (the previous race's
-- finishing order); NOT the full entry/pwr set. Kept on the quali table (no new top-level local, 200-local
-- ceiling).
quali.START_MODES = {random = true, last = true}

-- Normalize a UI-supplied quali-start value to a known mode, defaulting to random (quali-start-order):
-- an unknown or absent value falls back to random, so a chat /race order=quali (which carries no field)
-- stays byte-identical to today. Parsed defensively -- only a known string survives.
function quali.normalize_start(value)
    if type(value) == "string" and quali.START_MODES[value] then
        return value
    end
    return "random"
end

-- Begin a quali event with a session length in seconds (already resolved/clamped by the caller, else the
-- default). Cleared by reset_to_lobby, so it never outlives the event (contrast last_order/championship).
function quali.begin(duration, staged)
    session.quali = {
        duration = tonumber(duration) or PHASE_DURATIONS.quali_default,
        lap_grace_deadline = nil,  -- set when the quali clock expires, to let an in-progress lap finish
        done = false,              -- flips true at the quali-results -> countdown hand-off (race grid set)
        regridded = false,         -- flips true when the AI re-grid fires inside quali-results (ADR-0041)
        -- Rally-style staged sprint quali (ADR-0044): drivers start one at a time from P1, ~8 s apart, and
        -- the best complete Start->Ziel run sets the grid. staged=false is the ADR-0041 all-at-once circuit
        -- best-lap quali (unchanged). The queue state is seeded lazily at the qualifying phase entry
        -- (quali.start_session) -- session.progress is not built until after quali.begin runs.
        staged = staged == true,
        queue = nil,        -- turn order: ids waiting for their ramp turn (seeded by start_session)
        staging_id = nil,   -- the id counting down at the ramp (before GO), or nil
        staged_at = nil,    -- now() when staging_id was released (its count ends STAGE_COUNTDOWN later)
        clearing_id = nil,  -- the id that launched but has not yet freed the ramp (blocks the next), or nil
        launched_at = nil,  -- now() when clearing_id launched (GO); restarted by a requeue (Round-10 settle)
        cleared = false,    -- true once clearing_id reported >=15 m clear -- or left the track via a
                            -- requeue, which purpose-serves the distance condition (Round 10)
        status = nil,       -- per-id "queued|staged|running|done" for the HUD (seeded by start_session)
        best = nil,         -- per-identity best complete run time in seconds (ADR-0031)
        best_cp = nil,      -- per-identity max progress pair {cp, time} across ALL runs (Round 11): the
                            -- most checkpoints any run reached + the smallest run-relative time to that
                            -- count. Board + ranking measure timeless drivers on this, not the live
                            -- record, which every requeue resets (seeded by start_session, like best)
        sector_best = nil,  -- per-sector field best split across ALL drivers and runs (Round 13):
                            -- [k] = the fastest splits[k]-splits[k-1] any scored crossing produced,
                            -- relayed as `sectorBests` on the queue snapshot so the staged HUD's
                            -- record colouring degrades live (seeded by start_session, like best_cp)
        sector_count = nil, -- per-sector count of scored crossings across ALL drivers and runs
                            -- (Round 13/r4): [k] = how many splits ever folded into sector_best[k],
                            -- relayed as `sectorCounts` so a no-reference (white) sector upgrades to
                            -- purple once a second scoring exists (seeded by start_session, same
                            -- fold seam and lifecycle as sector_best)
        stall_logged = nil, -- per-id guard so the "reported AFK" line logs once per driver instead of
                            -- once per tick -- the tick keeps running for the whole length of the
                            -- finish-your-run grace (seeded by start_session, like status). The reported
                            -- flags themselves live on session.stall_reported (the `stall` namespace)
    }
end

function quali.clear()
    session.quali = nil
end

-- The qualifying classification as a ranked list of {identity, pace, ai} (ADR-0041). Pace = the
-- client-reported best_lap (circuit); a staged sprint (ADR-0044) uses the best complete Start->Ziel run.
-- Faster pace ranks ahead. A driver with no complete run/lap ranks behind every timed driver; those
-- timeless drivers order by checkpoint count (Round 7: most checkpoints -> earliest time at that
-- checkpoint -> slot). A staged sprint measures that on the MAX across all runs (Round 11 -- the live
-- record resets on every requeue); a circuit reads the live record, which nothing resets mid-session, so
-- live IS the max there (Round 12 -- previously the circuit fell back to slot order). This is the single
-- seam the live board, the results card and the race grid all read, so they classify timeless drivers
-- identically. Pure over build_standings + the quali table -- race-blind (ADR-0005).
function quali.ranking()
    local timed, untimed = {}, {}
    local staged = quali.is_staged()
    for _, entry in ipairs(build_standings()) do
        if entry.name then
            local pace
            if staged then
                -- Staged sprint (ADR-0044): rank by the best complete Start->Ziel run recorded on the quali
                -- table (progress is reset between runs, so total_time in the live record is not the pace).
                pace = session.quali.best and session.quali.best[entry.name]
            else
                pace = tonumber(entry.best_lap)
                if not pace and entry.finished then
                    pace = tonumber(entry.total_time)
                end
            end
            if pace then
                timed[#timed + 1] = {identity = entry.name, pace = pace, slot = entry.slot or 0, ai = entry.ai}
            else
                -- Carry the checkpoint progress that ranks timeless drivers by how far they got. Staged:
                -- the MAX across all runs (Round 11: best_cp, live-record fallback), not the live record
                -- alone, which every requeue resets -- a driver who reached CP 7 in an earlier run keeps
                -- ranking on 7. Circuit: best_cp is never seeded, so max_cp_of passes the live record
                -- through -- which nothing resets mid-session, so it already is the max (Round 12).
                local cp, cp_time = quali.max_cp_of(entry.name,
                    entry.completed or 0, entry.total_time or 0)
                untimed[#untimed + 1] = {
                    identity = entry.name,
                    slot = entry.slot or 0,
                    ai = entry.ai,
                    cp = cp,
                    cp_time = cp_time,
                }
            end
        end
    end
    table.sort(timed, function(a, b)
        if a.pace ~= b.pace then
            return a.pace < b.pace  -- fastest lap/run on pole
        end
        return a.slot < b.slot       -- stable tiebreak on the provisional slot
    end)
    -- Rank timeless drivers by how far they got -- most checkpoints first, then earliest to reach that
    -- checkpoint, then slot -- the same tie-break build_standings uses for the live in-race order.
    -- Staged since Round 7 (on the max across runs, Round 11); the circuit joined in Round 12 (its live
    -- board tail was already CP-ordered via build_standings position -- the classification, results card
    -- and race grid now match it instead of falling back to slot order).
    table.sort(untimed, function(a, b)
        if a.cp ~= b.cp then
            return a.cp > b.cp
        end
        if a.cp_time ~= b.cp_time then
            return a.cp_time < b.cp_time
        end
        return a.slot < b.slot
    end)
    local ranked = {}
    for _, item in ipairs(timed) do ranked[#ranked + 1] = item end
    for _, item in ipairs(untimed) do ranked[#ranked + 1] = item end
    return ranked
end

-- The ranked identities alone (fastest first), for the quali.regrid placement (ADR-0041).
function quali.order_identities()
    local ids = {}
    for _, item in ipairs(quali.ranking()) do
        ids[#ids + 1] = item.identity
    end
    return ids
end

-- The run's shared total checkpoint count for a staged CP-progress denominator: the first progress record
-- that still carries a count -- a requeue reset wipes the per-record count, so scan for any survivor. nil
-- before the session's first crossing (the display then shows the reached count only). Staged-quali data,
-- server-paced (ADR-0044); broadcast_queue and quali.snapshot read this one seam so their "/y" agrees.
function quali.checkpoint_total()
    if not session.progress then
        return nil
    end
    for _, record in pairs(session.progress) do
        if record.count then
            return record.count
        end
    end
    return nil
end

-- A client-facing snapshot of the qualifying classification (ADR-0041), shipped on entering quali-results
-- for the HUD results card. Rows carry the pace as seconds (nil for an unclassified driver). A timeless row
-- also carries the checkpoint progress quali.ranking already computed (cp), so the results card mirrors the
-- live board's "CP x/y" instead of "--" (feature quali-results-cp-progress); a staged row adds cpTotal (the
-- run's total, the number broadcast_queue relays). The circuit "/y" is one lap's cps -- client-local
-- knowledge the client fills in (the HUD's qualiCpsPerLap), never derived here (the server count is the
-- whole quali plan). Timed rows carry only their time. Race-blind (ADR-0005) -- quali classification only.
function quali.snapshot()
    local rows = {}
    local cp_total = quali.is_staged() and quali.checkpoint_total() or nil
    for position, item in ipairs(quali.ranking()) do
        local timeless = item.pace == nil
        rows[#rows + 1] = {
            position = position,
            name = item.identity,
            time = item.pace,
            ai = item.ai or nil,
            -- Only a timeless row renders CP; cp keeps 0 (Lua 0 is truthy). cpTotal is staged-only, so a
            -- circuit row omits it and the client uses its per-lap count instead.
            cp = timeless and item.cp or nil,
            cpTotal = timeless and cp_total or nil,
        }
    end
    return {rows = rows}
end

-- Re-grid the field by the qualifying classification at the quali-results -> countdown seam (ADR-0041),
-- mirroring regrid_by_pwr: reassign every participant a slot in quali-pace order (pole = fastest), rebuild
-- the roster, and send each client its new slot + the reordered roster so it re-places (regrid) before the
-- race countdown. AI slots ride the owner's regrid (ADR-0036). A no-op when this is not a quali event or no
-- one set a time (the provisional random grid then stands).
function quali.regrid()
    if not session.progress or not quali.is_active() then
        return
    end
    local players = MP.GetPlayers()
    local ids = {}
    for id in pairs(session.progress) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b) return session.progress[a].slot < session.progress[b].slot end)
    -- place_by_identity maps each id's identity (player license or "AI <k>") onto the quali ranking, fastest
    -- first; unranked ids (no time) keep slot order at the back. Never reversed -- quali is pole-to-the-fast.
    local ordered = place_by_identity(ids, quali.order_identities(), false)

    -- Keep the space behind an oversized car free on the quali-earned grid too (ADR-0051): the pace
    -- order above is untouched, only the slot numbers may skip. This is the binding fit pass for a quali
    -- event -- it is the last slot assignment before the race countdown.
    local assigned = grid_fit.assign(ordered)
    local slots = {}
    for index, id in ipairs(ordered) do
        slots[#slots + 1] = make_slot_entry(id, assigned and assigned[index] or index - 1, players)
    end
    session.roster = build_roster(slots)
    -- Re-seed progress fresh on the quali-earned grid so the race starts from a clean baseline (completed 0,
    -- no splits/best_lap); the quali session's progress was only ever a means to the classification.
    session.progress = build_progress(slots)

    -- AI slots carry the label too (ADR-0041): the owner re-spawns fresh AI on the quali grid for the race
    -- (a quali drive leaves them in a state a teleport does not reliably recover), so it needs the display
    -- name like the original raceStart aiSlots.
    local ai_regrid = {}
    for _, entry in ipairs(slots) do
        if is_ai_id(entry.id) then
            -- The roster's pre-picked car (ADR-0047) rides along: the owner RE-SPAWNS fresh AI on the
            -- quali grid, so without the token it would re-roll the car and break the one-truth roster.
            -- Suppressed while a tournament runs (the class car wins there, ADR-0042; checked via
            -- session.tournament -- the tour table is declared later in the file) and nil without a
            -- roster, keeping the aiConfig chain byte-identical.
            ai_regrid[#ai_regrid + 1] = {
                id = entry.id,
                slot = entry.slot,
                label = entry.name,
                car = (session.tournament == nil) and grid_store.ai_roster_car(entry.id) or nil,
                -- Colour rides the fresh re-spawn too (ADR-0047 round 3), ALWAYS -- unlike the car it is
                -- not suppressed under a tournament (roster colours the class car).
                color = grid_store.ai_roster_color(entry.id),
            }
        end
    end
    for _, entry in ipairs(slots) do
        if not is_ai_id(entry.id) then
            local payload = {slot = entry.slot, grid = session.roster}
            if entry.id == session.owner_id and #ai_regrid > 0 then
                payload.aiSlots = ai_regrid
                payload.qualiRespawnAi = true  -- tell the owner to re-spawn (not teleport) the AI (ADR-0041)
            end
            send_event(entry.id, MSG_REGRID, payload)
        end
    end
    log_info("beamcomp.race", string.format("quali re-grid: %d participant(s) by best time", #ordered))
end

-- Size the finish-your-lap grace when the quali clock expires (ADR-0041): a lap's worth of time so a
-- still-circulating driver can complete the lap they are on, instead of a flat cap that is too short on long
-- tracks and needlessly long on short ones. Take the SLOWEST best lap of the active field -- classified
-- drivers (players and AI) still circulating: those with a valid best_lap that are not DNF and not finished
-- (a disconnect DNFs the record, so "connected" is captured by "not dnf"; ADR-0014) -- so the whole field
-- can finish, add a small buffer for lap-to-lap variance (quali.LAP_GRACE_BUFFER), and clamp to sane bounds
-- so one pathological lap cannot stall the session. Race-blind: reads only the client-reported best_lap
-- already in build_standings, the same source quali.ranking uses (ADR-0005). Falls back to a generous fixed
-- window when no active driver has set a lap yet (everyone on lap 1, or a sprint quali with nil best_lap).
function quali.lap_grace_window()
    local slowest
    if quali.is_staged() then
        -- Staged sprint (ADR-0044): size the finish-your-run grace to the slowest complete run recorded so
        -- far, so a driver still on track when the clock expires can complete their Start->Ziel run.
        for _, run in pairs(session.quali.best or {}) do
            local pace = tonumber(run)
            if pace and pace > 0 and (not slowest or pace > slowest) then
                slowest = pace
            end
        end
    else
        for _, entry in ipairs(build_standings()) do
            if entry.name and not entry.dnf and not entry.finished then
                local pace = tonumber(entry.best_lap)
                if pace and pace > 0 and (not slowest or pace > slowest) then
                    slowest = pace
                end
            end
        end
    end
    if not slowest then
        return PHASE_DURATIONS.quali_lap_grace_fallback
    end
    local window = slowest * quali.LAP_GRACE_BUFFER
    return math.max(PHASE_DURATIONS.quali_lap_grace_min,
                    math.min(PHASE_DURATIONS.quali_lap_grace_max, window))
end

-- Log one driver being discounted from the circuit quali's finish-your-lap grace, ONCE per driver.
--
-- The sibling of quali.note_stall for the ADR-0041 circuit quali, and deliberately NOT that function: its
-- latch (q.stall_logged) is seeded by quali.start_session, which is staged-only, so on a circuit session it
-- is nil and note_stall would return at its first guard and log nothing at all. Same latch TABLE, created
-- lazily here -- a session is either staged or circuit, so the two can never collide -- and the same
-- never-cleared semantics: the tick re-evaluates the predicate for the whole length of the grace, so an
-- unguarded line would repeat thousands of times and bury the entry the verification looks for.
function quali.note_lap_stall(id, reason)
    local q = session.quali
    if not q then
        return
    end
    q.stall_logged = q.stall_logged or {}
    if q.stall_logged[id] then
        return
    end
    q.stall_logged[id] = true
    log_info("beamcomp.race", string.format(
        "circuit quali: driver %s %s -- no longer holding the finish-your-lap grace open",
        tostring(id), reason))
end

-- Is anyone still circulating in the circuit quali? The ADR-0041 half of the one liveness predicate --
-- maybe_end_race and quali.advance_staged ask stall.verdict the same question for their own graces.
--
-- The set is session.progress minus the DNF'd and the finished, the same shape maybe_end_race uses.
-- Excluding `finished` is safe here and was verified rather than assumed: the circuit quali plan is sized
-- so the field CANNOT run it out (race/start.lua builds it with max(10, ceil(duration / 8)) laps, an
-- ~8 s/lap floor), so record.finished stays false for everyone for the whole session -- and a driver who
-- somehow did complete it has a done detector and can set no further lap times anyway.
-- quali.lap_grace_window, the file's other statement of "who is still circulating", excludes it too.
--
-- session.progress rather than build_standings(): it is keyed by the id stall.verdict wants, it does not
-- sort the whole field on every 250 ms tick, and -- the deciding reason -- it has no `entry.name` filter.
-- A participant whose identity resolved to nil would be dropped from the standings-based set, i.e. counted
-- as NOT circulating, which fails towards ending the session early. That direction must stay impossible.
--
-- Scans the whole field instead of breaking on the first mover, so every discounted driver gets its one
-- log line whatever order pairs() happens to walk in.
function quali.anyone_lapping()
    local anyone = false
    for id, record in pairs(session.progress or {}) do
        if not record.dnf and not record.finished then
            local reason = stall.verdict(id)
            if reason then
                quali.note_lap_stall(id, reason)
            else
                anyone = true
            end
        end
    end
    return anyone
end

-- Advance the qualifying phase from the tick (ADR-0041): run for session.quali.duration, then arm a
-- bounded finish-your-lap grace (so an in-progress lap still counts), then broadcast the classification and
-- enter the results pause. Mirrors the racing finish-grace handling -- handled explicitly (not by the
-- generic timed advance) so the grace can sit between the clock and the pause.
--
-- The grace is gated on somebody actually still circulating, like the other two (ADR-0014 amendment). It
-- used to arm unconditionally and run its full length whatever the field was doing -- observed live as a
-- 120 s wait on a session whose AI had long stopped moving. Both ends are gated: an already-stalled field
-- at clock expiry is never armed at all, and an armed grace ends on the tick where the last mover goes
-- quiet. The window LENGTH is untouched -- this changes only whether it is armed and when it ends.
--
-- Both inputs get their moment. At clock expiry the client has reported nothing yet (it only reports while
-- the grace is armed), so the checkpoint-gap backstop decides whether to arm at all -- which is what the
-- qualifying phase-entry stamp exists for. Once armed, the client's own 15 s measurement lands and ends it.
function quali.advance_qualifying()
    local q = session.quali
    if not q or phase_elapsed() < q.duration then
        return  -- still within the quali clock
    end
    local t = now()
    -- ALWAYS arm. Nobody can be reported AFK at this instant: the clients only start their standstill
    -- clock when this very broadcast reaches them, so asking the predicate here could only ever say
    -- "everyone is still going". The gate below is where it earns its keep.
    if not q.lap_grace_deadline then
        local window = quali.lap_grace_window()
        q.lap_grace_deadline = t + window
        stall.begin_grace()
        -- Tell clients the finish-your-lap window length so each still-circulating driver sees the
        -- timeout to be at the finish (reuses the racing finish-grace display, ADR-0014/0041). The
        -- window tracks the field's slowest best lap, so its length varies with the track/pace rather
        -- than being a flat cap.
        broadcast_event(MSG_FINISH_GRACE, {duration = window})
        log_info("beamcomp.race",
            string.format("quali clock expired; finish-your-lap grace armed (%.1fs)", window))
        return
    end
    if quali.anyone_lapping() and t < q.lap_grace_deadline then
        return
    end
    broadcast_event(quali.MSG, quali.snapshot())
    -- Carry the re-grid lead so the client can split the pause display: a clean "results" countdown
    -- (pause - lead) before the respawn, then the settle timer (the remaining pause) after it (ADR-0041).
    enter_phase(PHASE.quali_results, PHASE_DURATIONS.quali_results,
        {regridLead = PHASE_DURATIONS.quali_regrid_lead})
end

-- Run the quali re-grid once, a lead time before the results pause ends (ADR-0041 amendment). The owner
-- re-spawns fresh AI here, on the static results card, so the AI-spawn frame hitch never lands on the race
-- countdown -- which ticks locally and would otherwise lose those seconds and finish behind the server (the
-- race starting before the count reaches GO). The client despawned the quali AI at quali-results entry, so
-- this lead also preserves the despawn -> respawn gap that keeps the car count under MaxCars. A no-op until
-- the lead point, and after it has run once.
function quali.maybe_regrid()
    local q = session.quali
    if not q or q.regridded then
        return
    end
    local pause = session.phase_duration or PHASE_DURATIONS.quali_results
    if phase_elapsed() < pause - PHASE_DURATIONS.quali_regrid_lead then
        return
    end
    q.regridded = true
    quali.regrid()
end

-- Leave the quali-results pause for the race (ADR-0041): ensure the field is gridded by quali pace (the
-- re-grid normally ran a lead time earlier via quali.maybe_regrid; this is the fallback if that window was
-- skipped), mark the event done (so the next countdown gates the race, not another quali), and enter the
-- race countdown.
function quali.advance_results()
    quali.maybe_regrid()
    if session.quali then
        session.quali.done = true
    end
    -- This second countdown always leads to racing (ADR-0041), so the F1 light start applies here (ADR-0043).
    f1.enter_countdown(true)
end

-- ===== Rally staged sprint quali (ADR-0044) ================================================
-- Extends the ADR-0041 quali framework for point-to-point sprints: instead of everyone lapping at once,
-- drivers start one at a time from the ramp (P1), gated by the clear + gap, and the fastest complete Start->Ziel
-- run sets the race grid. The server owns only the holding QUEUE, the release TIMERS, and the reported run
-- TIMES (race-blind, ADR-0005) -- the client owns the P1 teleport, the per-driver count, the drive, and the
-- reset. All logic hangs off the existing `quali` table (no new top-level local, 200/200 ceiling).

-- Tell one driver to stage at the ramp and run the per-driver start count (ADR-0044/Round4: no pre-settle,
-- the count begins on arrival). A player id -> that client; an AI id -> the race owner tagged with aiId,
-- since the owner spawns/drives the AI (ADR-0036).
function quali.stage_driver(id)
    local payload = {countdown = quali.STAGE_COUNTDOWN}
    if is_ai_id(id) then
        if session.owner_id then
            payload.aiId = id
            send_event(session.owner_id, quali.MSG_STAGE, payload)
        end
    else
        send_event(id, quali.MSG_STAGE, payload)
    end
end

-- Tell one driver to return to its own fixed holding slot, or (stop=true) to stop + freeze in place
-- (ADR-0044/Round4). There is NO roll-forward: each driver's holding slot is fixed (its own grid position),
-- so the client re-places itself there (the owner re-places an AI at its spawned pose) -- the server sends
-- no slot index, only the stop flag. `stop=true` = a driver marked done at the window's end. Same routing as
-- stage_driver: direct to a player, via the owner (aiId) for an AI.
function quali.hold_driver(id, stop)
    if is_ai_id(id) then
        if session.owner_id then
            send_event(session.owner_id, quali.MSG_HOLD, {aiId = id, stop = stop or nil})
        end
    else
        send_event(id, quali.MSG_HOLD, {stop = stop or nil})
    end
end

-- Release the front of the turn queue to the ramp (ADR-0044/Round4): pop the queue front, mark it staged,
-- and tell it to stage at the ramp. The ramp holds one driver at a time; the others stay put on their fixed
-- holding slots (no roll-forward).
function quali.release_next()
    local q = session.quali
    local id = table.remove(q.queue, 1)
    if not id then
        return
    end
    q.staging_id = id
    q.staged_at = now()
    q.status[id] = "staged"
    quali.stage_driver(id)
end

-- Broadcast the staged-quali holding queue for the HUD (ADR-0044): every participant's slot, identity,
-- status (queued|staged|running|done), the classification `position` (Round 7: the best-run-then-checkpoint
-- rank, so the live board mirrors the grid it sets), the waiting-line `queuePos` (drives "you're next"),
-- best complete run time, checkpoint progress (cp/cpTotal), the best run's splits, and the ai flag --
-- plus the field-wide per-sector best splits as one top-level `sectorBests` field (Round 13). Each
-- client picks its own row by slot. Reported numbers only -- race-blind (ADR-0005).
function quali.broadcast_queue()
    if not quali.is_staged() or not session.progress then
        return
    end
    local q = session.quali
    -- position (Round 7): the classification rank -- timed drivers by best complete run, then timeless drivers
    -- by checkpoint count -- so the board mirrors the grid. quali.ranking is the single seam that also orders
    -- the results card + re-grid; map its identity order to a rank. (Pre-Round 7 this was the turn order.)
    local position = {}
    for rank, item in ipairs(quali.ranking()) do
        position[item.identity] = rank
    end
    -- queuePos (Round 5): the driver's 1-based place in the WAITING line only (q.queue, excluding the driver
    -- currently at the ramp). queuePos 1 = truly next to stage; nil for the staged/running/done drivers. The
    -- HUD "you're next" keys off THIS, not `position` (which is now the classification rank, not the turn order).
    local queue_pos = {}
    for i, id in ipairs(q.queue or {}) do
        queue_pos[id] = i
    end
    -- Shared total checkpoint count for the CP progress display (Round 7): the first record that still
    -- carries a count (a requeue reset wipes the per-record count). nil before the session's first crossing;
    -- the board then shows the reached count only (0). quali.snapshot reads the same seam for the results card.
    local known_count = quali.checkpoint_total()
    local rows = {}
    for id, record in pairs(session.progress) do
        local identity = quali.identity_of(id)
        local status = (q.status and q.status[id]) or "queued"
        rows[#rows + 1] = {
            slot = record.slot,
            name = identity,
            status = status,
            position = position[identity],
            queuePos = queue_pos[id],
            best = q.best and q.best[identity] or nil,
            -- Checkpoint progress (Round 7; since Round 11 the MAX across all runs): the board always shows
            -- a timeless driver's best reached count -- max(current run, best so far) -- so a requeue never
            -- drops the row back to CP 0. The driver's own live run progress stays on the right-panel
            -- readout (broadcast_standings), untouched. Still only client-reported numbers already stored
            -- on the progress record / quali table -- no geometry read, race-blind (ADR-0005).
            cp = quali.max_cp_of(identity, record.completed or 0, record.total_time or 0),
            cpTotal = record.count or known_count,
            -- The best complete run's cumulative crossing splits (Round 6), for the staged HUD sector
            -- readout's personal + session references. nil until this identity has finished a run.
            bestSplits = q.best_splits and q.best_splits[identity] or nil,
            ai = is_ai_id(id) or nil,
        }
    end
    table.sort(rows, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    -- `waiting` (Round 4): a driver has launched but not yet cleared the ramp, so the next stage is held --
    -- the HUD shows "Waiting for driver to start". The staged driver's own count is not "waiting". Also true
    -- through a Round-10 settle (the clearing driver was requeued; the ramp frees when the settle gap ends).
    -- `sectorBests` (Round 13): the field-wide per-sector best splits, ONE top-level field (not per row) --
    -- the staged HUD's session reference for the record colouring of the bar + readout. This broadcast
    -- already fires on every scored crossing (handle_checkpoint_report / requeue), so an improvement
    -- reaches every client on the report that set it -- live degradation needs no extra cadence.
    -- `sectorCounts` (r4): the companion crossing counter per sector, same fold seam -- lets a client
    -- upgrade a no-reference (white) sector to purple once a second scoring of that sector exists.
    broadcast_event(quali.MSG_QUEUE, {
        rows = rows,
        waiting = (q.clearing_id ~= nil) or nil,
        sectorBests = q.sector_best,
        sectorCounts = q.sector_count,
    })
end

-- Seed the turn queue at the staging -> qualifying seam and stage the first driver at the ramp
-- (ADR-0044/Round4): there is NO global pre-quali countdown -- the field spawned on grid positions 2..N+1
-- (P1 = the ramp is empty), and the first driver is teleported onto the ramp now while the rest stay put on
-- their fixed holding slots (no roll-forward). Every participant is seeded in slot order (session.progress
-- exists by now). No-op for the circuit all-at-once quali; the tick's quali.advance_staged paces the rest.
function quali.start_session()
    if not quali.is_staged() or not session.progress then
        return
    end
    local ids = {}
    for id in pairs(session.progress) do
        ids[#ids + 1] = id
    end
    -- Build the turn queue in SLOT order (ADR-0044 amendment, quali-start-order): the holding slots ARE the
    -- quali provisional grid, which already honors the chosen quali-start order (random default, or last;
    -- build_slots). So the launch sequence == the spawn-slot order -- whoever spawns on grid position 2
    -- launches first, position 3 next, ... -- and the two orderings are one and the same at session start.
    -- (Round 5's independent shuffle here is removed; the ordering now lives in the grid assignment.) AI are
    -- regular queue participants in slot order. Race-blind -- just an ordering of participant ids the server
    -- owns + broadcasts, so every client stays consistent. Reset/requeue still appends to the back (unchanged).
    table.sort(ids, function(a, b) return session.progress[a].slot < session.progress[b].slot end)
    local q = session.quali
    q.queue = ids
    q.staging_id = nil
    q.staged_at = nil
    q.clearing_id = nil
    q.launched_at = nil
    q.cleared = false
    q.status = {}
    q.best = {}
    -- Best complete run's cumulative crossing splits per identity (Round 6), relayed on the queue snapshot
    -- so the staged HUD can show the same live sector readout as the circuit quali (its reference is the
    -- best run, not the per-run splits, which reset_progress wipes on each requeue). Keyed like q.best.
    q.best_splits = {}
    -- Max checkpoint progress per identity across all runs (Round 11): {cp, time} pairs folded per scored
    -- crossing (quali.note_cp_progress). The board + ranking measure timeless drivers on this, so a
    -- requeue -- which wipes the live record -- can never regress what a driver already reached. Staged
    -- only: a circuit quali never seeds it -- there the live record is never reset mid-session, so it
    -- already is the max and ranks the timeless drivers directly (Round 12).
    q.best_cp = {}
    -- Field-wide best split per sector across all drivers and runs (Round 13): folded per scored
    -- crossing (quali.note_sector_best) and relayed as ONE top-level queue-snapshot field
    -- (sectorBests), so every client's record colouring -- bar + readout -- degrades live the moment
    -- anyone beats a sector. Staged only, like best_cp: the circuit derives its session reference
    -- client-side from the live standings splits (ADR-0015) and never allocates this.
    q.sector_best = {}
    -- Companion crossing counter per sector (r4), same fold seam: `sectorCounts` lets the client
    -- upgrade a no-reference (white) sector to purple once at least one FURTHER scoring exists.
    q.sector_count = {}
    -- Once-per-driver guard for the "reported AFK" line; the flags it pairs with live on
    -- session.stall_reported (the `stall` namespace), written only by a client report.
    q.stall_logged = {}
    for _, id in ipairs(ids) do
        q.status[id] = "queued"
    end
    log_info("beamcomp.race", string.format("staged sprint quali started with %d driver(s)", #ids))
    -- Ramp is empty; stage the first driver onto it. The others wait on their spawned holding slots.
    quali.release_next()
    quali.broadcast_queue()
end

-- Reset one driver's progress record to a fresh baseline for their next staged run (ADR-0044): completed 0,
-- no count/splits/best/finished. Keeps slot/name/ai. The best complete run time (q.best, captured before
-- this is called) and the max checkpoint progress (q.best_cp, folded per crossing) live on the quali
-- table, so the reset never loses them.
function quali.reset_progress(id)
    local record = session.progress and session.progress[id]
    if not record then
        return
    end
    record.completed = 0
    record.count = nil
    record.splits = {}
    record.total_time = 0
    record.finished = false
    record.dnf = false
    record.lap = 1
    record.best_lap = nil
    record.run_up = nil
end

-- The measured checkpoint progress for a timeless driver (Round 11): the lexicographic max of the stored
-- best_cp pair and the caller's live values -- more checkpoints win; at an equal count the smaller
-- run-relative time (the fastest way to that count) wins. Falls back to the live values when no pair is
-- stored (first run, or a circuit quali, which never seeds best_cp). Because note_cp_progress folds every
-- scored crossing, the stored pair is always >= the live record -- so this IS max(current run, best so far).
function quali.max_cp_of(identity, live_cp, live_time)
    local q = session.quali
    local best = q and q.best_cp and q.best_cp[identity]
    if best and (best.cp > live_cp or (best.cp == live_cp and best.time < live_time)) then
        return best.cp, best.time
    end
    return live_cp, live_time
end

-- Fold one scored crossing into the driver's max progress pair (Round 11). Called per checkpoint report
-- during a staged qualifying, so EVERY scored crossing counts -- including those of a run later aborted
-- by a recover/forced requeue, which wipes only the live record, never this pair. Lexicographic update:
-- more checkpoints replace the pair; the same count with a smaller run-relative time improves it (the
-- run-relative total is comparable across runs because reset_progress zeroes it per run). Keyed by
-- identity like q.best, so it survives requeues and matches the ranking side (ADR-0031/0036).
function quali.note_cp_progress(id)
    local q = session.quali
    local record = session.progress and session.progress[id]
    if not q or not q.best_cp or not record or record.completed <= 0 then
        return
    end
    local identity = quali.identity_of(id)
    local time = record.total_time or 0
    local best = q.best_cp[identity]
    if not best or record.completed > best.cp
            or (record.completed == best.cp and time < best.time) then
        q.best_cp[identity] = {cp = record.completed, time = time}
    end
end

-- Fold one scored crossing into the field-wide per-sector best splits (Round 13) and bump the
-- sector's crossing counter (r4). Called per checkpoint report under the staged gate, like
-- note_cp_progress, so EVERY scored crossing counts -- aborted runs included. The sector split is
-- the difference of consecutive run-relative cumulative splits (splits[k] - splits[k-1], ADR-0015
-- semantics; k = 1 bases on 0 -- the staged run starts at the ramp, no run-up). Crossings arrive in
-- seq order, so both arrays stay dense (sector k is never folded before 1..k-1). Race-blind
-- (ADR-0005): a min + a count of client-reported numbers, the q.best pattern.
function quali.note_sector_best(id)
    local q = session.quali
    local record = session.progress and session.progress[id]
    if not q or not q.sector_best or not record or record.completed <= 0 then
        return
    end
    local k = record.completed
    local cumulative = record.splits and record.splits[k]
    local previous = (k == 1) and 0 or (record.splits and record.splits[k - 1])
    if type(cumulative) ~= "number" or type(previous) ~= "number" then
        return
    end
    local split = cumulative - previous
    if not q.sector_best[k] or split < q.sector_best[k] then
        q.sector_best[k] = split
    end
    if q.sector_count then
        q.sector_count[k] = (q.sector_count[k] or 0) + 1
    end
end

-- Hold the ramp for one STAGE_GAP after a driver left it other than by clearing it normally (the Round-10
-- settle). The car is still physically on/near the ramp -- the hold teleport, or BeamMP's despawn of a
-- leaver, is a network round-trip away -- so the ramp must not be handed to the next driver yet. Expressed
-- in the existing clearing gate rather than a second timer: the distance condition is purpose-served (this
-- driver is off the track for gate purposes) and the gap restarts from now, so advance_staged frees the ramp
-- exactly STAGE_GAP later. clearing_id stays set until then, which keeps release_next held and the queue
-- broadcast's `waiting` flag honest. Callers: quali.requeue (Round 10) and quali.purge_driver (disconnect).
function quali.settle_ramp(id)
    local q = session.quali
    q.clearing_id = id
    q.cleared = true
    q.launched_at = now()
end

-- Take one driver out of the waiting line, leaving the order of everyone else intact. Callers append the id
-- back afterwards when the driver is only going to the back (quali.requeue); a purge just drops them.
function quali.drop_from_queue(id)
    local q = session.quali
    local remaining = {}
    for _, qid in ipairs(q.queue or {}) do
        if qid ~= id then
            remaining[#remaining + 1] = qid
        end
    end
    q.queue = remaining
end

-- Requeue a driver whose run ended (ADR-0044/Round4): reset their record so the next run scores from zero,
-- release any ramp state they held (a held clearing gate becomes a settle timer, Round 10), then either
-- append them to the back of the turn queue (another attempt, returning to their own fixed holding slot)
-- or mark them done. The window is the ONLY thing that ends a driver's session: while it is open EVERY
-- driver -- player or AI (ADR-0044/Round9) -- goes back into the rotation; a run that ends after it closed
-- marks done + freeze-in-place.
function quali.requeue(id)
    local q = session.quali
    if not q or not q.staged then
        return
    end
    quali.reset_progress(id)
    -- Free the ramp count if this driver held it (a requeue while still counting at the ramp).
    if q.staging_id == id then
        q.staging_id = nil
        q.staged_at = nil
    end
    -- If this driver held the clearing gate, do NOT free it outright (Round 10): settle the ramp instead,
    -- so the next driver stages no earlier than STAGE_GAP from this requeue.
    if q.clearing_id == id then
        quali.settle_ramp(id)
    end
    quali.drop_from_queue(id)
    local window_open = session.phase == PHASE.qualifying and phase_elapsed() < q.duration
    if not window_open then
        -- The run ended after the window closed: this driver is finished for the session. They stay where
        -- they rolled out (no teleport) -- the pre-race re-grid puts the whole field back on the grid anyway.
        q.status[id] = "done"
        quali.hold_driver(id, true)  -- stop + freeze in place
    else
        -- Back of the turn queue; the driver returns to its own fixed holding slot (no roll-forward). The
        -- client owns which pose that is, so hold_driver carries no slot -- just "go hold" (stop=false).
        q.queue[#q.queue + 1] = id
        q.status[id] = "queued"
        quali.hold_driver(id, false)
    end
    quali.broadcast_queue()
end

-- A driver completed a staged Start->Ziel run (ADR-0044): fold their run time into the per-identity best
-- (fastest complete run stands), then requeue them. Called from handle_checkpoint_report's final branch
-- while this is a staged qualifying session. AI requeue exactly like players (ADR-0044/Round9): back to
-- their own holding slot, back of the turn queue, another run for as long as the window is open.
function quali.finish_run(id)
    local q = session.quali
    if not q or not q.staged then
        return
    end
    local record = session.progress and session.progress[id]
    if record then
        local identity = quali.identity_of(id)
        local time = tonumber(record.total_time)
        if time and time > 0 and (not q.best[identity] or time < q.best[identity]) then
            q.best[identity] = time
            -- Snapshot this run's cumulative crossing splits as the identity's best-run reference (Round 6),
            -- before requeue -> reset_progress replaces record.splits with a fresh table. Copied so a later
            -- run mutating its own splits array never disturbs the stored best.
            local best_splits = {}
            for i, split in ipairs(record.splits or {}) do
                best_splits[i] = split
            end
            q.best_splits[identity] = best_splits
            log_info("beamcomp.race", string.format("staged quali: %s run %.2fs (best)", identity, time))
        end
    end
    quali.requeue(id)
end

-- A player hit RECOVER mid-run (client->server qualiReset, ADR-0044/Round4): start a new attempt -- requeue
-- them to the back so they go after the drivers currently ahead. (Repair is separate: it does NOT reset the
-- attempt, so the client only sends this on recover, not repair.) Accepted only during a staged qualifying
-- phase from a driver in this race; an AI never resets (the owner reports no reset for it).
function quali.handle_reset(player_id, payload)
    if not quali.is_staged() or session.phase ~= PHASE.qualifying then
        return
    end
    if not (session.progress and session.progress[player_id]) then
        return
    end
    quali.requeue(player_id)
    log_info("beamcomp.race", "player " .. tostring(player_id) .. " recover -> requeued (staged quali)")
end

-- Drop a disconnected driver out of the turn rotation (called from on_player_disconnect). Without this the
-- leaver's id stays in the queue forever and keeps being handed ramp turns nobody drives: release_next stages
-- the ghost, nothing ever reports its clear, and STAGE_CLEAR_TIMEOUT force-requeues it to the back -- a ~33 s
-- cycle that burns ramp time the real drivers need for the rest of the window.
--
-- Deliberately NOT quali.requeue: that would send a hold to a client that is gone, and its reset_progress
-- would clear the record.dnf the disconnect handler just set. The record itself stays exactly as it is --
-- the leaver keeps their DNF mark, their best run time, their classification rank and the grid slot it earns
-- (ADR-0014; quali.ranking measures pace, not presence). Only the rotation drops them.
--
-- Staged qualifying only: the circuit quali (ADR-0041) has no queue, and every other phase is already
-- covered by the disconnect handler's own branches.
function quali.purge_driver(id)
    if not quali.is_staged() or session.phase ~= PHASE.qualifying then
        return
    end
    if not (session.progress and session.progress[id]) then
        return
    end
    local q = session.quali
    -- Defensive, like advance_staged: the queue/status are seeded by quali.start_session in the same call
    -- that enters the qualifying phase, so this should never be nil -- but a disconnect callback is the last
    -- place we want an index error, and there is nothing to purge from before the seeding anyway.
    if not q.status or not q.queue then
        return
    end
    -- The leaver occupied the ramp, counting down on it or driving off it. BeamMP does not despawn their car
    -- instantly, so free the ramp through a settle rather than outright -- the next driver must never be
    -- teleported into it in the same tick. Both roles settle: a driver mid-count is parked ON the ramp, which
    -- is if anything more in the way than one that has already launched.
    local held_ramp = q.staging_id == id or q.clearing_id == id
    if q.staging_id == id then
        q.staging_id = nil
        q.staged_at = nil
    end
    if held_ramp then
        quali.settle_ramp(id)
    end
    quali.drop_from_queue(id)
    -- "done" rather than removing the row: the HUD keeps showing them, reading finished instead of queued.
    q.status[id] = "done"
    log_info("beamcomp.race", string.format(
        "staged quali: driver %s disconnected -- purged from the turn queue (%s)",
        tostring(id),
        held_ramp and "held the ramp, settling for STAGE_GAP" or "was waiting in the queue"))
    -- Re-broadcast now so the remaining drivers' queuePos and the `waiting` flag are right immediately,
    -- rather than at whatever the next state change happens to be.
    quali.broadcast_queue()
end

-- The launched driver has cleared the ramp (client->server qualiCleared, ADR-0044/Round4): the >=15 m gate
-- the client (player, or the owner for an AI) reports, so the next driver may stage once the clearance gap
-- has also passed. Accepted only for the current clearing driver: a player reports its own clear; the owner
-- reports an AI's with aiId. A stale/spoofed report for anyone else is dropped.
function quali.handle_cleared(player_id, payload)
    if not quali.is_staged() or session.phase ~= PHASE.qualifying then
        return
    end
    local id
    if type(payload) == "table" and payload.aiId ~= nil then
        if player_id ~= session.owner_id or not is_ai_id(payload.aiId) then
            return
        end
        id = payload.aiId
    else
        id = player_id
    end
    if session.quali.clearing_id == id then
        session.quali.cleared = true
    end
end

-- Classify the staged session and hand off to the ADR-0041 quali-results pause (ADR-0044). Mirrors the
-- circuit advance_qualifying tail: broadcast the pace snapshot, then enter quali-results carrying the
-- re-grid lead so the client can split the pause display. The re-grid by best time reuses quali.regrid
-- (which reads quali.ranking, staged-aware).
function quali.finish_session()
    broadcast_event(quali.MSG, quali.snapshot())
    enter_phase(PHASE.quali_results, PHASE_DURATIONS.quali_results,
        {regridLead = PHASE_DURATIONS.quali_regrid_lead})
end

-- Log one driver being discounted from the finish-your-run grace, ONCE per driver per session. The tick
-- re-evaluates the predicate continuously for the whole length of that grace, so an unguarded line here
-- would repeat thousands of times and bury the very entry the in-game verification looks for. A driver
-- who somehow resumes, crosses a checkpoint and then stalls again is not logged a second time -- the
-- guard is deliberately never cleared, because one line per driver is the contract.
function quali.note_stall(id, reason)
    local q = session.quali
    if not q or not q.stall_logged or q.stall_logged[id] then
        return
    end
    q.stall_logged[id] = true
    log_info("beamcomp.race", string.format(
        "staged quali: driver %s %s -- no longer holding the finish-your-run grace open",
        tostring(id), reason))
end

-- Advance the staged sprint quali from the tick (ADR-0044/Round4). Paces one ramp at a time (race-blind):
-- the staged driver counts for STAGE_COUNTDOWN, then launches (-> clearing_id); the next driver is not staged
-- until the launcher has BOTH cleared the ramp (the client >=15 m report) AND the STAGE_GAP clearance has
-- passed -- a strict AND with no bypass (Round 10). A launcher that never clears within STAGE_CLEAR_TIMEOUT
-- is force-requeued (players and AI alike), which restarts the gap as a settle timer instead of releasing.
-- The waiting field stays put on their fixed slots (no roll-forward). When the window expires, stop releasing
-- and arm a finish-your-run grace, then classify. Circuit uses quali.advance_qualifying instead.
function quali.advance_staged()
    local q = session.quali
    if not q then
        return
    end
    -- Defensive: the queue/status are seeded by quali.start_session at the qualifying entry; if a stray
    -- tick reaches here before that (it should not), seed now rather than index a nil status table.
    if not q.status or not q.queue then
        quali.start_session()
        return
    end
    local t = now()
    local changed = false

    -- The staged driver's count has finished -> they launch (GO). Move them to the clearing gate: they are
    -- now driving (running + scored) but still block the ramp until they clear it + the gap passes.
    if q.staging_id and t >= (q.staged_at or 0) + quali.STAGE_COUNTDOWN then
        q.status[q.staging_id] = "running"
        q.clearing_id = q.staging_id
        q.launched_at = t
        q.cleared = false
        q.staging_id = nil
        q.staged_at = nil
        changed = true
    end

    -- The ramp frees ONLY when both the >=15 m gate (q.cleared -- client-reported, or purpose-served by a
    -- requeue) AND the clearance gap have passed: the strict AND gate (Round 10), no bypass. A driver stuck
    -- at the ramp (no clear report within STAGE_CLEAR_TIMEOUT) is force-requeued back to its holding slot
    -- instead of being staged past; quali.requeue converts this gate into a settle timer (cleared=true,
    -- launched_at=now), so the release still waits the full gap for the return teleport to land. requeue
    -- broadcasts the queue itself (no changed flag here), and it keeps clearing_id set, so the release
    -- check below cannot fire in this same tick.
    if q.clearing_id then
        if q.cleared and t >= (q.launched_at or 0) + quali.STAGE_GAP then
            q.clearing_id = nil
            q.launched_at = nil
            q.cleared = false
            changed = true
        elseif not q.cleared and t >= (q.launched_at or 0) + quali.STAGE_CLEAR_TIMEOUT then
            log_info("beamcomp.race", string.format(
                "staged quali: ramp clear timeout -- forcing requeue of stuck driver %s",
                tostring(q.clearing_id)))
            quali.requeue(q.clearing_id)
        end
    end

    local window_open = phase_elapsed() < q.duration

    -- Release the next driver to the ramp while the window is open and the ramp is free (no one counting and
    -- no one still clearing). The others stay put on their holding slots (no roll-forward).
    if window_open and not q.staging_id and not q.clearing_id and #q.queue > 0 then
        quali.release_next()
        changed = true
    end

    if changed then
        quali.broadcast_queue()
    end

    if window_open then
        return
    end

    -- Window closed: let any driver still counting at the ramp / clearing / running finish their run, then
    -- classify. (A staged driver mid-count still gets to launch + run; the flip above runs before this.)
    --
    -- "Still out" means still DRIVING, not merely present (staged-quali-stuck-ai-never-requeued). A
    -- driver who wrecked or hung mid-stage keeps `running` for the rest of the window -- by design nothing
    -- recovers them -- and counting them armed this grace even when nobody left on track would ever move
    -- again, then held it to its FULL deadline (minutes, on a sprint) while the whole field watched a car
    -- that would never move again. So a `running` driver counts only while their own client has not
    -- reported them AFK. That driver is otherwise untouched: same status, same HUD row, same banked best
    -- time and checkpoint progress -- they just stop making everyone else wait, and they start counting
    -- again the moment they move. The ramp roles on the first line are deliberately NOT filtered:
    -- staging_id is bounded by STAGE_COUNTDOWN and clearing_id by STAGE_CLEAR_TIMEOUT, so neither can
    -- hold this long.
    local anyone_out = q.staging_id ~= nil or q.clearing_id ~= nil
    if not anyone_out then
        -- Scans the whole field instead of breaking on the first mover, so every AFK driver gets its
        -- one log line whatever order pairs() happens to walk in.
        for id in pairs(session.progress or {}) do
            if q.status[id] == "running" then
                -- Only once THIS grace is armed, the same gate maybe_end_race applies. On the tick that
                -- decides whether to arm, no client has started its clock yet, so a flag present here
                -- could only be a leftover from an earlier grace -- and consulting it would discount the
                -- driver, leave anyone_out false, and classify the session immediately WITHOUT ever
                -- arming (so the arming clear below could never run). Unreachable today, because the
                -- window-close arm is the first grace of a staged event and start_race clears; gated so
                -- it stays impossible by construction rather than by ordering.
                local reason = q.lap_grace_deadline and stall.verdict(id)
                if reason then
                    quali.note_stall(id, reason)
                else
                    -- No report counts as still driving, always -- the server has no opinion of its own.
                    anyone_out = true
                end
            end
        end
    end
    if not q.lap_grace_deadline then
        if anyone_out then
            local window = quali.lap_grace_window()
            q.lap_grace_deadline = t + window
            stall.begin_grace()
            broadcast_event(MSG_FINISH_GRACE, {duration = window})
            log_info("beamcomp.race",
                string.format("staged quali window closed; finish-your-run grace armed (%.1fs)", window))
            return
        end
        q.lap_grace_deadline = t  -- no one on track -> classify immediately
    end
    if anyone_out and t < q.lap_grace_deadline then
        -- Keep the live board refreshing through the finish-your-run grace (Round 6). The release path
        -- above, which drove the periodic broadcast during the window, is gated on window_open, so without
        -- this the board would freeze until classification. Per-crossing broadcasts (handle_checkpoint_report)
        -- already refresh it as the running driver progresses; this covers the between-crossing ticks.
        quali.broadcast_queue()
        return
    end
    quali.finish_session()
end
-- ===== end rally staged sprint quali =======================================================


-- Class-drop elimination tournament (ADR-0042). A multi-race handicap series: every driver starts in the
-- fastest of an ordered list of car classes, the winner of each race drops one class for the next, and the
-- tournament ends when someone wins in the slowest class. Like `champ`/`quali`, every piece of logic hangs
-- off this one `tour` namespace table -- a single top-level local, because main.lua sits at Lua's 200-local
-- ceiling and a flat set of functions would overflow it (the plugin then fails to load entirely). The
-- cross-race state lives in session.tournament; like the championship it survives reset_to_lobby (one
-- tournament = one play-session) and is in-memory only.
local tour = {}

-- Cross-side message + command names (ADR-0042), kept on the table to spare top-level local slots.
tour.MSG = "tournament"          -- table + per-driver class, broadcast on change + after each award
tour.MSG_CMD = "tournamentCmd"   -- the setup panel's control: {action, classes, order} (ADR-0037)

tour.DEFAULT_CLASS_COUNT = 4
tour.MIN_CLASSES = 2
tour.MAX_CLASSES = 6

-- Whether a class-drop tournament is currently running.
function tour.is_active()
    return session.tournament ~= nil
end

-- The standings identity for a participant id: AI ids "ai:<k>" carry their display name -- the roster
-- name or "AI <k>" (ADR-0036/0047) -- real player ids resolve to the canonical client name (ADR-0031).
-- Matches build_standings/make_slot_entry, so a driver's class keys consistently across the spawn relay
-- and the award fold.
function tour.identity_of(id)
    if is_ai_id(id) then
        return grid_store.ai_display_name(id)
    end
    return resolve_identity(id)
end

-- The car/cap descriptor of one class spec, or nil for keep-own (an empty spec). For chat + UI labels.
function tour.spec_label(spec)
    if type(spec) ~= "table" then
        return nil
    end
    if spec.car then
        return spec.car
    end
    if spec.maxhp then
        return "<=" .. tostring(spec.maxhp) .. " hp"
    end
    if spec.maxpwr then
        return "<=" .. tostring(spec.maxpwr) .. " hp/kg"
    end
    return nil
end

-- A short human label for a class index (ADR-0042): "class N" plus the car or cap it enforces. Class 1 is
-- the fastest. Used in the drop/win chat announcements.
function tour.class_label(index)
    local state = session.tournament
    local detail = state and tour.spec_label(state.classes[index])
    if detail then
        return string.format("class %d (%s)", index, detail)
    end
    return string.format("class %d", index)
end

-- Normalize the admin-authored class list into ordered opaque specs (ADR-0042/0032). Each class buckets into
-- exactly one shape: a fixed car {car="model[:config]"} or a power cap {maxhp=N} / {maxpwr=N} (car wins if both
-- are somehow present). Empty/unconfigured rows are dropped, not kept as a no-op class -- so an admin who left
-- the rows blank gets the "too few classes" feedback instead of a degenerate keep-own tournament. The server
-- never interprets the tokens (race-blind, ADR-0005); it only buckets each entry so policy_for + the labels
-- are predictable. Returns nil when fewer than MIN_CLASSES valid entries remain; excess past MAX is dropped.
function tour.sanitize_classes(raw)
    if type(raw) ~= "table" then
        return nil
    end
    local classes = {}
    for _, spec in ipairs(raw) do
        if #classes >= tour.MAX_CLASSES then
            break
        end
        if type(spec) == "table" then
            local clean
            if type(spec.car) == "string" and spec.car ~= "" then
                clean = {car = spec.car}
            elseif tonumber(spec.maxhp) then
                clean = {maxhp = tonumber(spec.maxhp)}
            elseif tonumber(spec.maxpwr) then
                clean = {maxpwr = tonumber(spec.maxpwr)}
            end
            if clean then
                classes[#classes + 1] = clean
            end
        end
    end
    if #classes < tour.MIN_CLASSES then
        return nil
    end
    return classes
end

-- The grid order for the tournament from a panel choice (ADR-0042). Defaults to random -- the car class is
-- the handicap, so the grid is not also handicapped by default. Accepts the per-race order modes that resolve
-- at start (ADR-0033: entry/random/last/pwr); an unknown/empty choice falls back to random. quali is not
-- offered here (a tournament does not compose a qualifying session in v1).
function tour.order(choice)
    local mode = type(choice) == "table" and choice.mode or choice
    if mode == "entry" or mode == "random" or mode == "last" or mode == "pwr" then
        return {mode = mode, rev = (type(choice) == "table" and choice.rev) or nil}
    end
    return {mode = "random"}
end

-- The grid order a live tournament imposes on the next race, or nil when none is active (ADR-0042). Feeds the
-- effective_order chain in start_race unless the race carries an explicit order=.
function tour.active_order()
    if not tour.is_active() then
        return nil
    end
    return session.tournament.order
end

-- Begin a fresh class-drop tournament with the given ordered class specs (ADR-0042). order defaults to random.
-- Returns the class count on success, or nil when too few valid classes were given. Mutual exclusion with the
-- points-championship (ADR-0040) is enforced by the command handler (champ is defined earlier in the file), so
-- start itself does not reference champ.
function tour.start(classes, order)
    local clean = tour.sanitize_classes(classes)
    if not clean then
        return nil
    end
    session.tournament = {
        -- keyed by identity (players) / display name (AI): {class_index, reached_at{class->race}, races, finishes, ai}
        classes = clean,
        order = tour.order(order),
        standings = {},
        race_count = 0,
        winner = nil,
        ended = false,
    }
    return #clean
end

-- End the tournament and clear its state.
function tour.reset()
    session.tournament = nil
end

-- The overall tournament winner line for the reset announcement (ADR-0042): the champion's identity, set
-- when a driver wins in the slowest class (tour.fold), or nil when reset before anyone won. Mirrors
-- champ.winner_text so tour.handle_cmd's reset path can announce the winner symmetrically -- without it the
-- reset handler called a nil field and aborted before tour.reset(), so "off" never cleared the tournament.
function tour.winner_text()
    local state = session.tournament
    return state and state.winner or nil
end

-- Live changes to a running tournament (ADR-0042). New class specs apply to subsequent spawns only -- a driver
-- keeps their class_index, only the car for that index changes (non-retroactive, like a championship preset
-- change). A nil argument leaves that setting unchanged; invalid classes are ignored. No-op when none active.
function tour.set(classes, order)
    if not tour.is_active() then
        return
    end
    if classes ~= nil then
        local clean = tour.sanitize_classes(classes)
        if clean then
            session.tournament.classes = clean
        end
    end
    if order ~= nil then
        session.tournament.order = tour.order(order)
    end
end

-- The class a driver currently races in (1 = fastest). Drivers absent from the standings -- including late
-- joiners (ADR-0042) -- default to class 1, clamped to the configured class count. nil identity -> class 1.
function tour.class_index_of(identity)
    local state = session.tournament
    if not identity or not state then
        return 1
    end
    local record = state.standings[identity]
    local index = (record and record.class_index) or 1
    if index > #state.classes then
        index = #state.classes
    end
    return index
end

-- The vehicle policy a participant spawns under this race (ADR-0042 / ADR-0032 amendment): the car or cap of
-- their current class, relayed verbatim per-recipient. A missing/empty class spec degrades to keep-own (Mode 1)
-- so a misconfigured class never crashes or strands a driver. Returns a {car?, maxhp?, maxpwr?} subset.
function tour.policy_for(id)
    if not tour.is_active() then
        return {}
    end
    local spec = session.tournament.classes[tour.class_index_of(tour.identity_of(id))]
    if type(spec) ~= "table" then
        return {}
    end
    return {car = spec.car, maxhp = spec.maxhp, maxpwr = spec.maxpwr}
end

-- The race winner's identity for the class-drop fold: the top classified finisher (P1, not DNF), or nil when
-- nobody finished (an all-DNF race drops no one). Race-blind -- reads build_standings rank order (ADR-0015).
function tour.race_winner(standings)
    local top = standings[1]
    if top and not top.dnf and top.name then
        return top.name
    end
    return nil
end

-- Fold the just-finished race into the tournament (ADR-0042). Called at the racing->finished seam after
-- champ.award (a no-op unless a tournament is active and unfinished). Every classified/DNF participant gets a
-- class-1 record on first sighting and a bumped race + finishes count (the never-winner countback tiebreak).
-- The race winner then drops one class (stamping the race number at which they reached it), or -- if already
-- in the slowest class -- ends the tournament as overall winner. Keyed by identity / AI display name.
function tour.award()
    if not tour.is_active() or session.tournament.ended then
        return
    end
    local state = session.tournament
    local standings = build_standings(true)  -- final order: the jump penalty counts toward the rank (ADR-0043)
    for _, entry in ipairs(standings) do
        local identity = entry.name
        if identity then
            local record = state.standings[identity]
            if not record then
                record = {class_index = 1, reached_at = {[1] = 0}, races = 0, finishes = {}, ai = entry.ai or nil}
                state.standings[identity] = record
            end
            record.races = record.races + 1
            if not entry.dnf then
                record.finishes[entry.position] = (record.finishes[entry.position] or 0) + 1
            end
        end
    end
    state.race_count = state.race_count + 1

    local winner = tour.race_winner(standings)
    if not winner then
        return  -- all-DNF race: no class change, the tournament continues
    end
    local record = state.standings[winner]
    if record.class_index < #state.classes then
        record.class_index = record.class_index + 1
        record.reached_at[record.class_index] = state.race_count
        broadcast_chat(string.format("BeamComp: %s wins -- drops to %s",
            winner, tour.class_label(record.class_index)))
    else
        state.winner = winner
        state.ended = true
        broadcast_chat(string.format("BeamComp: %s wins the class-drop tournament!", winner))
    end
end

-- Countback of two finish histograms (ADR-0040 style): whoever has more finishes at the best still-differing
-- position is ahead. Returns 1 (a ahead), -1 (b ahead), or 0 (tied) -- the final tiebreak among drivers who
-- never dropped a class (all still in class 1, reached at race 0).
function tour.countback(a, b)
    local maxp = 0
    for p in pairs(a) do if p > maxp then maxp = p end end
    for p in pairs(b) do if p > maxp then maxp = p end end
    for p = 1, maxp do
        local ca, cb = a[p] or 0, b[p] or 0
        if ca ~= cb then
            return ca > cb and 1 or -1
        end
    end
    return 0
end

-- The tournament standings as a ranked list (ADR-0042): {identity, entry}. The overall winner (set when a
-- driver wins in the slowest class) is pinned to 1st -- another driver may have reached the slowest class
-- earlier without winning there, so descent depth alone would mis-rank the actual winner. Everyone else is
-- ordered by deepest class reached (slower = better), then the earliest race that reached it, then a finish
-- countback, then identity. Drives the HUD/panel table.
function tour.rank_list()
    if not tour.is_active() then
        return {}
    end
    local state = session.tournament
    local winner = state.winner
    local ranked = {}
    for identity, entry in pairs(state.standings) do
        ranked[#ranked + 1] = {identity = identity, entry = entry}
    end
    table.sort(ranked, function(x, y)
        if winner then
            if x.identity == winner then return true end
            if y.identity == winner then return false end
        end
        local a, b = x.entry, y.entry
        if a.class_index ~= b.class_index then
            return a.class_index > b.class_index  -- deeper (slower) class first
        end
        local ra = a.reached_at[a.class_index] or 0
        local rb = b.reached_at[b.class_index] or 0
        if ra ~= rb then
            return ra < rb  -- reached this class in an earlier race = better
        end
        local cb = tour.countback(a.finishes, b.finishes)
        if cb ~= 0 then
            return cb > 0
        end
        return x.identity < y.identity
    end)
    return ranked
end

-- A client-facing snapshot of the tournament (ADR-0042) for the HUD results card + the setup panel: active
-- flag, the configured classes, the ranked rows with each driver's current class, and the overall winner once
-- the tournament has ended. active=false (no rows) tells a client to hide the table.
function tour.snapshot()
    if not tour.is_active() then
        return {active = false}
    end
    local state = session.tournament
    local classes = {}
    for index, spec in ipairs(state.classes) do
        classes[index] = {
            index = index,
            car = spec.car,
            maxhp = spec.maxhp,
            maxpwr = spec.maxpwr,
            label = tour.spec_label(spec),
        }
    end
    local rows = {}
    for position, item in ipairs(tour.rank_list()) do
        local entry = item.entry
        local class_index = math.min(entry.class_index, #state.classes)
        rows[#rows + 1] = {
            position = position,
            name = item.identity,
            class = class_index,
            classLabel = tour.spec_label(state.classes[class_index]),
            races = entry.races,
            ai = entry.ai or nil,
        }
    end
    return {
        active = true,
        ended = state.ended or nil,
        winner = state.winner,
        classCount = #state.classes,
        raceCount = state.race_count,
        classes = classes,
        rows = rows,
    }
end

-- Broadcast the current tournament table to every client (ADR-0042).
function tour.broadcast()
    broadcast_event(tour.MSG, tour.snapshot())
end


-- Resolve the pwr start order at the staging->countdown seam (ADR-0033): sort the rostered players by
-- their reported power-to-weight (desc by default = strongest on pole, asc for :rev = weakest on pole),
-- with players who reported none to the back in current slot order. Reassign slots, rebuild the roster,
-- and send each client its new slot + the reordered roster so it re-places (regrid). A no-op for non-pwr
-- orders or when nobody reported pwr (the provisional entry order then stands).
local function regrid_by_pwr()
    if not session.progress or not session.order or session.order.mode ~= "pwr" then
        return
    end
    local identities = session.identities or {}
    local players = MP.GetPlayers()

    local ranked, unranked = {}, {}
    for id, record in pairs(session.progress) do
        local info = identities[id]
        local pwr = info and tonumber(info.pwr)
        if pwr then
            ranked[#ranked + 1] = {id = id, pwr = pwr, slot = record.slot}
        else
            unranked[#unranked + 1] = {id = id, slot = record.slot}
        end
    end
    if #ranked == 0 then
        return  -- no pwr data -> keep the provisional order (fallback)
    end

    local rev = session.order.rev
    table.sort(ranked, function(a, b)
        if a.pwr ~= b.pwr then
            if rev then
                return a.pwr < b.pwr  -- weakest on pole (handicap)
            end
            return a.pwr > b.pwr      -- strongest on pole
        end
        return a.slot < b.slot         -- stable tiebreak on the provisional slot
    end)
    table.sort(unranked, function(a, b) return a.slot < b.slot end)

    local slots = {}
    for _, entry in ipairs(ranked) do
        slots[#slots + 1] = {id = entry.id}
    end
    for _, entry in ipairs(unranked) do
        slots[#slots + 1] = {id = entry.id}
    end
    -- Keep the space behind an oversized car free (ADR-0051): the power order above is untouched, only
    -- the slot numbers may skip. Running it here rather than only in grid_fit.apply means the pwr re-grid
    -- ships the final slot map in ONE message instead of being corrected by a second one.
    local ordered = {}
    for index, entry in ipairs(slots) do
        ordered[index] = entry.id
    end
    local assigned = grid_fit.assign(ordered)
    for index, entry in ipairs(slots) do
        entry.slot = assigned and assigned[index] or index - 1
        entry.name = players[entry.id]
        session.progress[entry.id].slot = entry.slot
    end
    session.roster = build_roster(slots)

    -- Tell each player its new slot + the reordered roster so it re-places before the countdown. AI slots
    -- have no client (ADR-0036): the owner re-places them, so its regrid also carries the AI slots' new
    -- positions (id + slot) for it to re-place its host-driven cars (ADR-0036 Etappe B).
    local ai_regrid = {}
    for _, entry in ipairs(slots) do
        if is_ai_id(entry.id) then
            ai_regrid[#ai_regrid + 1] = {id = entry.id, slot = entry.slot}
        end
    end
    for _, entry in ipairs(slots) do
        if not is_ai_id(entry.id) then
            local payload = {slot = entry.slot, grid = session.roster}
            if entry.id == session.owner_id and #ai_regrid > 0 then
                payload.aiSlots = ai_regrid
            end
            send_event(entry.id, MSG_REGRID, payload)
        end
    end
    log_info("beamcomp.race", string.format("pwr re-grid: %d ranked, %d unranked", #ranked, #unranked))
end


-- Send each participant its slot plus the rebuilt roster so it re-places, mirroring regrid_by_pwr's
-- roll-out. AI slots have no client (ADR-0036): the owner re-places them, so its message carries their
-- new slots too. Plain re-place, never a re-spawn -- the quali variant of that stays in quali.regrid.
function grid_fit.broadcast(slots)
    local ai_slots = {}
    for _, entry in ipairs(slots) do
        if is_ai_id(entry.id) then
            ai_slots[#ai_slots + 1] = {id = entry.id, slot = entry.slot}
        end
    end
    for _, entry in ipairs(slots) do
        if not is_ai_id(entry.id) then
            local payload = {slot = entry.slot, grid = session.roster}
            if entry.id == session.owner_id and #ai_slots > 0 then
                payload.aiSlots = ai_slots
            end
            send_event(entry.id, MSG_REGRID, payload)
        end
    end
end

-- Re-run the slot reservation for the field's CURRENT start order and roll the result out over the
-- existing regrid message (ADR-0033) -- but only when the slot map actually moved, so a report that
-- changes nothing costs one arithmetic pass and no network traffic.
--
-- This is both passes of ADR-0051 §6: the EARLY one (a footprint arriving from any client, so a big car
-- is accounted for within a moment of its spawn) and the BINDING one at the staging -> countdown seam,
-- which is what covers the orders that have no re-grid of their own (entry/random/last/championship).
-- Order-preserving by construction: the ids are read back in their current slot order and only their
-- slot NUMBERS move. Phase-gated to the windows where the field is parked on the grid and a re-place is
-- safe -- never during the countdown, a qualifying session, the race, or the results window.
function grid_fit.apply(reason)
    if not session.progress or not session.roster then
        return
    end
    if session.phase ~= PHASE.spawning and session.phase ~= PHASE.staging
        and session.phase ~= PHASE.quali_results then
        return
    end
    local ordered = {}
    for id in pairs(session.progress) do
        ordered[#ordered + 1] = id
    end
    table.sort(ordered, function(a, b) return session.progress[a].slot < session.progress[b].slot end)

    local assigned = grid_fit.assign(ordered)
    if not assigned then
        return
    end
    local moved = false
    for index, id in ipairs(ordered) do
        if session.progress[id].slot ~= assigned[index] then
            moved = true
            break
        end
    end
    if not moved then
        return
    end

    local players = MP.GetPlayers()
    local slots = {}
    for index, id in ipairs(ordered) do
        session.progress[id].slot = assigned[index]
        slots[index] = make_slot_entry(id, assigned[index], players)
    end
    session.roster = build_roster(slots)
    grid_fit.broadcast(slots)
    log_info("beamcomp.grid", string.format(
        "size-aware re-grid (%s): %d participant(s) over %d grid slots",
        tostring(reason), #slots, assigned[#assigned] + 1))
end

-- Leave staging for the countdown (ADR-0021), applying the pwr re-grid first when order=pwr (ADR-0033).
-- The single seam every non-quali start routes through -- /go|/start|/racestart and the panel's raceGo,
-- which is the same handler (ADR-0021 amendment: there is no longer a staging timeout).
local function enter_countdown_from_staging()
    regrid_by_pwr()
    -- The binding slot reservation (ADR-0051 §6): the last point at which every car -- including one
    -- swapped during staging -- is known. A no-op after regrid_by_pwr (which already fitted the order it
    -- produced) and for a field of ordinary cars; it is what covers the orders with no re-grid of their
    -- own (entry/random/last/championship).
    grid_fit.apply("countdown")
    -- The F1 light start applies only when this countdown leads to racing; for an order=quali event the
    -- first countdown leads to the qualifying out-lap, which keeps the plain countdown (ADR-0043/0041).
    f1.enter_countdown(not quali.is_pending())
end

-- Clear the session and announce the lobby phase. If a race was active, tell players the world is
-- back to free-roam (B3) -- so a /raceclear or the finished-window expiry has a visible close-out.
local function reset_to_lobby()
    local had_race = session.race ~= nil
    -- A race cleared before it settled (/raceclear, or the server running empty) never reaches
    -- finalize_race, so its runs would be lost. Log them here as aborted/DNF before the state is dropped
    -- (ADR-0050); a no-op after a normal finish, and skipped when nobody reached a checkpoint.
    runlog.capture(true)
    session.runs_logged = nil
    session.race_event = nil
    session.race = nil
    session.roster = nil
    session.progress = nil
    -- The slot reservation's view of this race's grid (ADR-0051); per-race, like the roster.
    session.grid_record = nil
    session.grid_direction = nil
    session.grid_ramp = nil
    session.grace_deadline = nil
    -- The liveness stamps are per-race like the progress they measure: a stale one must never be read
    -- as the next race's liveness.
    stall.clear()
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_overrides = nil
    session.pending_map = nil
    session.pending_race_id = nil
    session.pending_race_data = nil
    session.cleanup_warned = false
    session.spawn_pending = nil
    session.spawn_ready_count = 0
    session.identities = nil
    session.owner_id = nil
    -- session.ai_roster (ADR-0047) is per-race: the panel re-sends the roster with every start, so a
    -- stale one must never name the next race's AI (e.g. a follow-up typed /race without a roster).
    session.ai_roster = nil
    -- session.quali (ADR-0041) is per-event, so unlike last_order/championship it is cleared here -- a
    -- qualifying belongs to one race event and must not bleed into the next.
    session.quali = nil
    -- session.last_order (ADR-0033), session.championship (ADR-0040) and session.tournament (ADR-0042)
    -- deliberately persist across the lobby -- they are the cross-race order sources / series state and must
    -- outlive a single race.
    enter_phase(PHASE.lobby, nil)
    if had_race then
        broadcast_chat("BeamComp: race cleared -- back in free roam")
    end
end

-- Early-end check (ADR-0014): once no player can still finish, don't wait out the full grace. With at
-- least one finisher, cut the grace to a short results window (never extend, and re-broadcast so the
-- client countdown resyncs); with everyone DNF and no finisher there is nothing to show, so return to
-- lobby. Called after any finish/DNF while racing.
local function maybe_end_race()
    if session.phase ~= PHASE.racing or not session.progress then
        return
    end
    -- A driver wrecked or parked on track can no longer finish, but nothing in their record says so:
    -- they stay not-finished and not-dnf for the whole grace, so it ran its full 120 s even when every
    -- driver left out there had stopped moving -- observed as six AI DNF'ing simultaneously, exactly
    -- 120 s after "finish grace armed". Discount a driver whose own client has reported them AFK, so
    -- this existing early end fires for them too.
    --
    -- Discounting is NOT a DNF and nothing here is terminal: the driver's record is untouched, and a
    -- client reporting them moving again puts them straight back into `active`. The DNF still arrives
    -- only from finalize_race when the grace actually expires.
    --
    -- ONLY while the finish grace is armed, and the gate is EXPLICIT because it has to be. This function
    -- also runs from /dnf, from a disconnect and from the first finish, and the block below arms a
    -- deadline even when NOBODY has finished (the ADR-0014 all-DNF path) -- so an ungated discount could
    -- end a race that nobody had finished yet and DNF the whole field over one quiet moment. Gated, the
    -- discount can only ever shorten a grace that is already running. (It used to ride on `threshold and`
    -- being nil, which was easy to lose when the threshold itself was deleted.)
    local grace_armed = session.grace_deadline ~= nil
    local active = 0
    local stalled
    for id, record in pairs(session.progress) do
        if not record.finished and not record.dnf then
            local reason = grace_armed and stall.verdict(id)
            if reason then
                stalled = stalled or {}
                stalled[#stalled + 1] = string.format("%s (%s)", tostring(id), reason)
            else
                -- Nobody has reported this driver standing still, so they still count.
                active = active + 1
            end
        end
    end
    -- The all-or-nothing gate, and the safety property of this whole change: the grace is shortened only
    -- when EVERY remaining driver is stalled. One driver still crossing checkpoints and nothing happens.
    -- It matters more here than in the quali: there a false positive ended one run, here it is a DNF.
    if active > 0 then
        return
    end
    -- No one can still finish (everyone finished and/or DNF): run the short results/countdown window,
    -- then the race settles via the normal tick (racing -> finished -> lobby) -- the same 5 s end for an
    -- all-DNF race as for a completed one (ADR-0014). The window is armed even with no finisher, so an
    -- all-DNF race no longer hangs.
    local short_deadline = now() + PHASE_DURATIONS.all_done_grace
    if not session.grace_deadline or short_deadline < session.grace_deadline then
        session.grace_deadline = short_deadline
        broadcast_event(MSG_FINISH_GRACE, {duration = PHASE_DURATIONS.all_done_grace})
        -- Fires exactly once: after this the stored deadline IS the short one, so a later
        -- now() + all_done_grace is no longer smaller than it and the branch is dead.
        log_info("beamcomp.race", stalled
            and string.format("grace shortened to results window; %d AFK driver(s) discounted: %s",
                #stalled, table.concat(stalled, ", "))
            or "all players accounted for; grace shortened to results window")
    end
end

-- Begin a fresh race: assign slots, send each player its raceStart (slot + grid roster + relayed
-- overrides), and enter the spawning phase. The client resolves and parses the race name locally
-- (ADR-0005) and decides the actual mode/laps/direction; `overrides` carries the admin's verbatim
-- {mode, laps, direction, force, assists} (each nil/false = auto/off -- the client derives from the
-- race file, ADR-0013/0018). `owner_id` is the player that issued /race; exactly that player's
-- raceStart carries propOwner = true, designating it as the one client that spawns the shared race
-- props -- the knockable cones -- which BeamMP then syncs to every other client (ADR-0009).
local function start_race(race_name, owner_id, overrides, map, race_id, race_data)
    -- A /race re-issued while one is running goes racing -> finished (abort window) -> here, bypassing
    -- finalize_race, so the outgoing race's runs are logged now -- before its state is overwritten
    -- (ADR-0050). A no-op from the lobby and after a normal finish.
    runlog.capture(true)
    session.runs_logged = nil
    session.race_event = runlog.next_event_id()
    -- Resolve the grid start order (ADR-0033/0040/0041): entry/random/last/championship are applied to the
    -- slot assignment now; pwr and quali are provisional here and re-gridded later (pwr after staging, quali
    -- after the qualifying session). While a championship is active its stored order grids the race unless
    -- the admin gave an explicit order=.
    -- While a class-drop tournament is active its stored order grids the race too (ADR-0042); it defaults to
    -- random since the car class is the handicap. champ/tour are mutually exclusive, so at most one applies.
    local effective_order = overrides.order or champ.active_order() or tour.active_order()
    session.order = effective_order
    -- F1 light start for this race (ADR-0043), relayed opaquely (race-blind). nil = the default lock
    -- countdown. The penalty seconds default when the option is on but no value was given.
    session.start_mode = overrides.startMode
    session.jump_penalty_seconds = overrides.jumpPenaltySeconds or f1.DEFAULT_PENALTY
    -- order=quali makes this a two-phase event (ADR-0041): begin the qualifying session state now; the
    -- provisional grid below is random, and quali.regrid sets the real race grid by pace after qualifying.
    -- Length precedence: an explicit per-race quali= wins; else a championship driving the quali grid
    -- supplies its configured length; else the default.
    if effective_order and effective_order.mode == "quali" then
        local quali_seconds = overrides.quali_duration
        if not quali_seconds and champ.is_active() then
            quali_seconds = session.championship.quali_seconds
        end
        -- Staged sprint variant (ADR-0044) when the issuer's client reported this race as a sprint
        -- (meta.closed=false, captured onto overrides.staged_quali in handle_race_validation); circuit
        -- keeps the ADR-0041 all-at-once best-lap quali. A championship quali grid is always circuit here.
        quali.begin(quali_seconds, overrides.staged_quali)
    else
        quali.clear()
    end
    -- The panel's named AI roster (ADR-0047): entry k names + pre-picks the car of AI id "ai:<k>". Stored
    -- on the session BEFORE build_slots so make_slot_entry and every identity read resolve the roster
    -- names; nil without a roster (the typed-chat path) keeps the classic "AI <k>" labels byte-identical.
    session.ai_roster = grid_store.sanitize_ai_roster(overrides.ai and overrides.ai.roster)
    -- Resolve the named/default grid for this race on the issuer-reported map (ADR-0023). Grids AND
    -- defaults are keyed by the canonical race id (race_id) so they resolve whatever shorthand was typed
    -- for /race; fall back to the raw name if the client did not report an id. nil = no custom grid ->
    -- clients lay out the procedural grid. The server relays the params verbatim, never interprets them,
    -- and never parses the race id -- it is a table key only (ADR-0005).
    local grid_params = resolve_grid(map, race_id or race_name, overrides.grid)
    -- The three facts the slot reservation needs to know which slot sits behind or beside which
    -- (ADR-0051): the record itself, which direction block the clients will use (their resolve_direction
    -- is a pure payload.direction == "reverse", so this is exact), and whether they split a P1 start ramp
    -- off the front of the layout (ADR-0044) -- which shifts every participant slot one layout index back.
    -- Set BEFORE build_slots so the fit is available from the very first slot assignment on.
    session.grid_record = grid_params
    session.grid_direction = overrides.direction
    session.grid_ramp = quali.is_staged() or nil
    -- Drop any identity/vehicle reports from a prior race so a re-issue (abort path, no reset_to_lobby)
    -- starts clean; each player re-reports clientInfo on the new spawn (ADR-0027). Cleared BEFORE the slot
    -- assignment: a stale footprint from the last race must never reserve a slot on this grid (ADR-0051).
    session.identities = nil
    -- Seed every footprint that is ALREADY known (ADR-0051 round 2) -- the lobby cars, the fixed car and
    -- the rostered AI cars -- so this first slot assignment can reserve rather than only correct later.
    grid_fit.seed_known(overrides, overrides.ai and overrides.ai.count)
    -- The requested AI opponents become synthetic participant slots (ADR-0036), so the roster, grid
    -- layout, and standings include them like any participant; the owner spawns + drives them. They mix
    -- into a random order and sort by reported pwr; otherwise they take the back of the grid.
    local slots = build_slots(MP.GetPlayers(), effective_order, session.last_order,
        champ.order_identities(), overrides.ai and overrides.ai.count)
    local roster = build_roster(slots)
    local assists = overrides.assists
    -- One heads-up to the issuer when the field outgrew what this grid was authored for (ADR-0023
    -- amendment 2026-08-02). Reading that one meta number is the server's only exception to relaying a
    -- grid record verbatim; everything below this line is unchanged -- same layout, same poses, same
    -- gridParams on the wire.
    grid_store.warn_over_capacity(owner_id, grid_params, #roster)

    session.race = race_name
    session.roster = roster
    session.owner_id = owner_id
    session.progress = build_progress(slots)
    session.grace_deadline = nil
    stall.clear()
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_overrides = nil
    session.pending_map = nil
    session.pending_race_id = nil
    session.pending_race_data = nil
    session.cleanup_warned = false

    -- Seed the spawn-ready gate: await one spawnReady ack per rostered player before leaving the
    -- spawning phase (ADR-0006 amendment). A timeout caps the wait; 0 acks at that point = empty race.
    session.spawn_pending = {}
    session.spawn_ready_count = 0
    for _, entry in ipairs(slots) do
        -- AI slots have no client to ack spawnReady (ADR-0036), so they must not gate the spawning phase.
        if not is_ai_id(entry.id) then
            session.spawn_pending[entry.id] = true
        end
    end

    -- The AI slots the owner spawns + drives (ADR-0036): only the owner's raceStart carries them; every
    -- other client just sees the AI in the roster. Built once from the appended back-of-grid slots.
    local ai_slots = {}
    for _, entry in ipairs(slots) do
        if is_ai_id(entry.id) then
            local ai_entry = {slot = entry.slot, id = entry.id, label = entry.name}
            -- In a class-drop tournament each AI drives the car/cap of its current class (ADR-0042); the
            -- owner resolves a cap to a compliant car exactly as it does for the player policy (ADR-0036).
            -- Absent (no tournament) the roster's pre-picked car (ADR-0047) rides the SAME per-slot field
            -- -- highest precedence in the owner's resolve_ai_vehicle, so the panel-shown car IS the
            -- spawned car (one-truth); nil (chat path / no roster) keeps the uniform aiConfig chain.
            if tour.is_active() then
                local vp = tour.policy_for(entry.id)
                ai_entry.car = vp.car
                ai_entry.maxhp = vp.maxhp
                ai_entry.maxpwr = vp.maxpwr
            else
                ai_entry.car = grid_store.ai_roster_car(entry.id)
            end
            -- The roster's per-AI paint colour (ADR-0047 round 3) is ALWAYS set -- orthogonal to the car,
            -- so it applies even in a tournament (class wins the car, roster still colours it). Opaque,
            -- owner-only, nil without a roster. The owner maps it to a primary paint layer at spawn.
            ai_entry.color = grid_store.ai_roster_color(entry.id)
            ai_slots[#ai_slots + 1] = ai_entry
        end
    end

    log_info("beamcomp.race", string.format("starting '%s' for %d player(s) + %d AI",
        race_name, #slots - #ai_slots, #ai_slots))

    for _, entry in ipairs(slots) do
        -- AI slots have no client (ADR-0036): skip them. The owner alone receives aiSlots, so it spawns
        -- and drives the AI cars; everyone else just sees them in the roster + standings.
        if not is_ai_id(entry.id) then
            -- Per-recipient vehicle policy (ADR-0032 amendment): a class-drop tournament gives each driver the
            -- car/cap of their current class (ADR-0042); otherwise every client gets the uniform admin policy,
            -- byte-for-byte as before. policy_for degrades to keep-own (Mode 1) for a missing/empty class spec.
            local policy = (tour.is_active() and tour.policy_for(entry.id))
                or {car = overrides.car, maxhp = overrides.maxhp, maxpwr = overrides.maxpwr,
                    maxkg = overrides.maxkg, minkg = overrides.minkg}
            send_event(entry.id, MSG_RACE_START, {
                race = race_name,
                slot = entry.slot,
                grid = roster,
                propOwner = entry.id == owner_id,
                -- The synthetic AI participants this client must spawn + drive (ADR-0036); owner-only,
                -- absent for everyone else and when no AI were requested.
                aiSlots = (entry.id == owner_id and #ai_slots > 0) and ai_slots or nil,
                -- The resolved AI difficulty + vehicle config (ADR-0036 Etappe B); owner-only, relayed
                -- verbatim (race-blind). The owner fills any gaps from the race's content defaults.
                aiConfig = (entry.id == owner_id and #ai_slots > 0) and {
                    preset = overrides.ai.preset,
                    car = overrides.ai.car,
                    params = overrides.ai.params,
                    -- Composable AI random-vehicle axes (relayed verbatim, resolved owner-side): stock vs
                    -- random trim, and exclude big/heavy vehicles.
                    randomTrim = overrides.ai.randomTrim,
                    noBigCars = overrides.ai.noBigCars,
                } or nil,
                mode = overrides.mode,            -- nil = auto (client derives from meta.closed); ADR-0013
                laps = overrides.laps,            -- nil = auto (client uses meta.defaultLaps); ADR-0013
                direction = overrides.direction,  -- nil = forward; "reverse" if reversible (ADR-0018)
                force = overrides.force,          -- override a geometry mismatch where possible (ADR-0018)
                all = overrides.all,              -- opt the deprecated quickrace source into resolution (ADR-0026)
                -- F1 light start (ADR-0043): "f1" = lights + free car + jump-start penalty; nil = the default
                -- lock countdown. The penalty seconds ride along so the offender's client can label its banner.
                startMode = session.start_mode,
                jumpPenaltySeconds = session.start_mode and session.jump_penalty_seconds or nil,
                -- Opt-in recover/repair assists (ADR-0017); clients enforce. Disabled by default.
                recoverEnabled = assists.recoverEnabled,
                recoverHoldSeconds = assists.recoverHoldSeconds,
                repairEnabled = assists.repairEnabled,
                repairHoldSeconds = assists.repairHoldSeconds,
                -- Resolved custom-grid params (ADR-0023); nil = procedural grid. Same for every slot --
                -- clients pick their own pose from the shared layout by slot.
                gridParams = grid_params,
                -- Vehicle policy (ADR-0032, per-recipient since the ADR-0042 amendment), relayed verbatim and
                -- never interpreted (ADR-0005): car = fixed "model[:config]" (Mode 2); maxhp (hp) / maxpwr
                -- (power-to-weight, hp per kg) / maxkg + minkg (strict curb-weight range, kg) = caps (Mode 3);
                -- all nil = keep own car (Mode 1). car wins client-side. `policy` is this driver's class car in
                -- a tournament (weight range absent -- class specs are car/maxhp/maxpwr only, ADR-0042), else
                -- the uniform admin policy.
                car = policy.car,
                maxhp = policy.maxhp,
                maxpwr = policy.maxpwr,
                maxkg = policy.maxkg,
                minkg = policy.minkg,
                -- car=random composable axes (ADR-0032 amendment): the random trim + big-car exclusion for a
                -- car=random player, relayed verbatim and resolved client-side. A GLOBAL admin choice (not
                -- per-class), so read from overrides, not the per-recipient policy (a tournament fills policy
                -- with car/maxhp/maxpwr only). nil for a non-random car -- the client ignores them then.
                randomTrim = overrides.randomTrim,
                noBigCars = overrides.noBigCars,
                -- The issuer-serialized race GEOMETRY (ADR-0039), relayed verbatim and never interpreted
                -- (ADR-0005): a client without the local race file builds the grid + checkpoints from this,
                -- so it is scored identically and cannot cut the course. Same for every slot; the host
                -- (which has the file) ignores it and parses locally. nil from an older client.
                --
                -- The SCENERY no longer rides here (ADR-0046). It is tens of KB, it was duplicated into
                -- every player's raceStart, and everyone who has the track threw it away. It is now pulled
                -- on demand (trackProbe/trackNeed/trackData), before the start, only by clients that lack
                -- the files -- so this message stays lean and most races ship none of it at all.
                raceData = race_data,
                -- Qualifying event (ADR-0041): present only for order=quali, carrying the session length so
                -- the client builds an unbounded-lap quali plan + shows the quali clock. nil = normal race.
                quali = session.quali and {duration = session.quali.duration} or nil,
                -- Whether the statistics subsystem exists on this server (ADR-0053). Gates the client's
                -- results-card Analysis button and the whole analysis overlay. Shipped as a plain setting
                -- and never interpreted here, so race-blindness holds (ADR-0005); it rides the existing
                -- raceStart envelope rather than a new message type (ADR-0011) so re-enabling restores the
                -- UI without a new client build. Always sent explicitly -- the client treats an ABSENT
                -- field as off, so an older server degrades to "no statistics UI" rather than to a button
                -- with nothing behind it.
                statsEnabled = cfg.stats_enabled,
            })
        end
    end

    enter_phase(PHASE.spawning, PHASE_DURATIONS.spawning)
end

-- Arm the finish-grace countdown: once the first player crosses the line the race runs for
-- finish_grace more seconds, then ends. Armed by handle_checkpoint_report when a player crosses
-- the final checkpoint (the documented racing -> finished seam, ADR-0006). Idempotent: later
-- finishers re-call it harmlessly once grace_deadline is set.
local function start_finish_grace()
    if session.phase ~= PHASE.racing or session.grace_deadline then
        return
    end
    session.grace_deadline = now() + PHASE_DURATIONS.finish_grace
    log_info("beamcomp.race", "finish grace armed")
    stall.begin_grace()
    -- Tell every client the cutoff length so still-racing players can show a live countdown (ADR-0014).
    broadcast_event(MSG_FINISH_GRACE, {duration = PHASE_DURATIONS.finish_grace})
end

-- A finished phase either restarts into a queued race (a re-issued /race) or settles to lobby.
local function advance_from_finished()
    local pending = session.pending_race
    if pending then
        local owner = session.pending_owner
        local overrides = session.pending_overrides
        local map = session.pending_map
        local race_id = session.pending_race_id
        local race_data = session.pending_race_data
        session.pending_race = nil
        session.pending_owner = nil
        session.pending_overrides = nil
        session.pending_map = nil
        session.pending_race_id = nil
        session.pending_race_data = nil
            start_race(pending, owner, overrides, map, race_id, race_data)
        return
    end
    reset_to_lobby()
end

-- Mark every still-active player (not finished, not already DNF) as DNF, then broadcast the standings.
-- Called when the finish grace expires so the race settles with everyone classified (ADR-0014).
local function dnf_active_players(reason)
    if not session.progress then
        return
    end
    for id, record in pairs(session.progress) do
        if not record.finished and not record.dnf then
            record.dnf = true
            log_info("beamcomp.race", string.format("player %s DNF (%s)", tostring(id), reason))
        end
    end
    broadcast_standings()
end

-- Advance the state machine one step. Runs on every tick; a no-op while idle in lobby.
-- Drop a pre-flight validation whose issuer never answered (e.g. disconnected mid-check) and tell the
-- admin, so a dead check never lingers (ADR-0019). Runs every tick, including while idle in lobby.
local function expire_stale_validation()
    local pending = session.pending_validation
    if pending and now() >= pending.deadline then
        session.pending_validation = nil
        MP.SendChatMessage(pending.owner_id,
            "BeamComp: race validation timed out -- no response from your client")
        log_info("beamcomp.race", "/race '" .. pending.race .. "' validation timed out")
    end
end

-- One-shot heads-up, ~FINISHED_CLEANUP_WARNING seconds before the finished results window expires,
-- that the props and results are about to clear (B3). Only the long results window qualifies: the
-- 1.5 s abort_window (a re-issued /race) sets session.pending_race, so it is excluded.
local function maybe_warn_cleanup()
    if session.phase ~= PHASE.finished or session.cleanup_warned or session.pending_race then
        return
    end
    if not session.phase_duration then
        return
    end
    if phase_elapsed() < session.phase_duration - FINISHED_CLEANUP_WARNING then
        return
    end
    session.cleanup_warned = true
    broadcast_chat("BeamComp: race props and results clear in 1 minute -- /raceclear to clear now")
end

-- Leave the spawning phase once every rostered player is accounted for -- acked via spawnReady or
-- gone (pruned on disconnect) -- or the spawning timeout caps the wait (ADR-0006 amendment). If not a
-- single client acked by then, the roster never spawned (all left or none ran the mod), so abort to
-- lobby instead of running an empty race until /raceclear; otherwise proceed to staging, open-ended --
-- the staged field waits for the host (ADR-0021 amendment). A no-op until the wait resolves, so it is
-- safe to call every tick.
local function advance_spawning()
    if not session.spawn_pending then
        return
    end
    local all_accounted = next(session.spawn_pending) == nil
    local timed_out = session.phase_duration and phase_elapsed() >= session.phase_duration
    if not all_accounted and not timed_out then
        return
    end
    if session.spawn_ready_count == 0 then
        log_info("beamcomp.race", "no players spawned; cancelling race")
        broadcast_chat("BeamComp: no players spawned -- race cancelled")
        reset_to_lobby()
    elseif not MP.GetPlayers()[session.owner_id] then
        -- The admin who prepared this race left during the spawn gate, so the field would come up
        -- waiting for a host who is not there -- and the preparer-left rule below cannot help, since it
        -- only watches disconnects that happen DURING staging. Same outcome, applied one seam earlier
        -- (ADR-0021 amendment).
        log_info("beamcomp.race", "race preparer left before staging; cancelling race")
        broadcast_chat("BeamComp: the host who prepared the race left -- race cancelled")
        reset_to_lobby()
    else
        -- nil duration = open-ended (like lobby and racing): no auto-start, and clients render a wait
        -- rather than a countdown, since duration is what they mirror as a clock.
        enter_phase(PHASE.staging, nil)
        -- Remember who prepared this race, so their leaving can cancel a wait nobody else will end
        -- (ADR-0021 amendment). This is the single staging entry, and both prepare routes -- /race and
        -- the panel -- set owner_id in handle_race_start, so one assignment covers both.
        session.staged_by = session.owner_id
    end
end

-- Lower each stored per-section best with a faster one from this run (ADR-0030). In-place on `target`,
-- keyed by section index; the per-car section_best leaves use it for the "best lap with the car" rows.
local function improve_segments(target, segments)
    for k, seconds in pairs(segments) do
        if type(seconds) == "number"
                and (type(target[k]) ~= "number" or seconds < target[k]) then
            target[k] = seconds
        end
    end
end

-- Split a cumulative splits array into per-lap section arrays (ADR-0030): lap l has section[s] =
-- splits[(l-1)*cps + s] - splits[(l-1)*cps + s - 1] and total = splits[l*cps] - splits[(l-1)*cps]. Only
-- fully-completed laps are returned. Mirrors the client's laps_from_splits; the server derives laps from
-- the splits it already stored, with cps from count/lap -- no geometry parsing, so race-blindness holds.
local function laps_from_splits(splits, cps)
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
            laps[#laps + 1] = {sections = sections, total = splits[base + cps] - base_time}
        end
        lap_index = lap_index + 1
    end
    return laps
end

-- Per-section minimum and sum over a run's laps (ADR-0030), plus the lap count -- the source for a car's
-- persistent per-section best (#2/#5) and per-section average (#4). Returns {min = [cps], sum = [cps],
-- lap_count}.
local function aggregate_run_sections(laps, cps)
    local mins, sums = {}, {}
    for s = 1, cps do
        local min_value, sum_value, has = nil, 0, false
        for _, lap in ipairs(laps) do
            local value = lap.sections[s]
            if type(value) == "number" then
                sum_value = sum_value + value
                if not min_value or value < min_value then
                    min_value = value
                end
                has = true
            end
        end
        if has then
            mins[s] = min_value
            sums[s] = sum_value
        end
    end
    return {min = mins, sum = sums, lap_count = #laps}
end

-- The per-section aggregate for a finisher's run, or nil when it cannot be derived. cps = count/lap (the
-- server learns the per-lap checkpoint count from the numbers the client already reported, ADR-0030);
-- skipped when count/lap is missing or not cleanly divisible.
local function run_section_aggregate(record)
    local count, lap = record.count, record.lap
    if type(count) ~= "number" or type(lap) ~= "number" or lap < 1 then
        return nil
    end
    local cps = math.floor(count / lap)
    if cps < 1 or cps * lap ~= count then
        return nil
    end
    local laps = laps_from_splits(record.splits, cps)
    if #laps == 0 then
        return nil
    end
    return aggregate_run_sections(laps, cps)
end

-- Fold this run's per-section aggregate into a car leaf (ADR-0030): lower each section best, and -- for a
-- player car leaf -- add the section sums and bump the lap count (the per-section average source). Track
-- car leaves keep only the cross-player section best (with_average false).
local function fold_car_sections(car, aggregate, with_average)
    if type(car.section_best) ~= "table" then
        car.section_best = {}
    end
    improve_segments(car.section_best, aggregate.min)
    if with_average then
        if type(car.section_sum) ~= "table" then
            car.section_sum = {}
        end
        for s, sum in pairs(aggregate.sum) do
            car.section_sum[s] = (car.section_sum[s] or 0) + sum
        end
        car.lap_count = (car.lap_count or 0) + (aggregate.lap_count or 0)
    end
end

-- Fold one finisher's run into a best leaf (player or track; ADR-0029/0030): bump the run/time counters
-- and lower the headline best. `field` is the headline key (best_total/total_time for sprint,
-- best_lap for circuit). Returns true on a new headline best. Tolerant of a leaf with missing counters.
local function bump_best_leaf(leaf, field, primary, time, date)
    leaf.run_count = (leaf.run_count or 0) + 1
    leaf.time_sum = (leaf.time_sum or 0) + (time or 0)
    if type(primary) == "number" and (type(leaf[field]) ~= "number" or primary < leaf[field]) then
        leaf[field] = primary
        leaf.date = date
        return true
    end
    return false
end

-- Update one player's record for this race (ADR-0030): the overall leaf (any car) and, when a car key is
-- known, the per-car leaf with the per-section aggregate. Returns true on a new overall personal best.
-- A nil identity is not recorded (no stable key).
local function update_player_record(players, identity, car_key, is_circuit, primary, time, aggregate,
        vehicle, date)
    if not identity then
        return false
    end
    local field = is_circuit and "best_lap" or "best_total"
    local entry = players[identity]
    if type(entry) ~= "table" then
        entry = {}
        players[identity] = entry
    end

    local is_pb = bump_best_leaf(entry, field, primary, time, date)
    if is_pb then
        entry.vehicle = vehicle
    end

    if car_key then
        if type(entry.cars) ~= "table" then
            entry.cars = {}
        end
        local car = entry.cars[car_key]
        if type(car) ~= "table" then
            car = {}
            entry.cars[car_key] = car
        end
        if bump_best_leaf(car, field, primary, time, date) then
            car.modified = vehicle and vehicle.modified or nil
        end
        if aggregate then
            fold_car_sections(car, aggregate, true)
        end
    end

    return is_pb
end

-- Update the race's cross-player track record (ADR-0030): the overall best (any car) plus the per-car
-- best (with the cross-player per-section best) when a car key is known. Returns true on a new overall
-- track record.
local function update_track_best(track, car_key, is_circuit, primary, time, aggregate, identity, vehicle,
        date)
    local field = is_circuit and "best_lap" or "total_time"
    track.run_count = (track.run_count or 0) + 1
    track.time_sum = (track.time_sum or 0) + (time or 0)

    local is_record = false
    if type(primary) == "number" and (type(track[field]) ~= "number" or primary < track[field]) then
        track[field] = primary
        track.holder = identity
        track.vehicle = vehicle
        track.date = date
        is_record = true
    end

    if car_key then
        if type(track.cars) ~= "table" then
            track.cars = {}
        end
        local car = track.cars[car_key]
        if type(car) ~= "table" then
            car = {}
            track.cars[car_key] = car
        end
        car.run_count = (car.run_count or 0) + 1
        car.time_sum = (car.time_sum or 0) + (time or 0)
        if type(primary) == "number" and (type(car[field]) ~= "number" or primary < car[field]) then
            car[field] = primary
            car.holder = identity
            car.modified = vehicle and vehicle.modified or nil
            car.date = date
        end
        if aggregate then
            fold_car_sections(car, aggregate, false)
        end
    end

    return is_record
end

-- Fold one logged run into the derived aggregate (ADR-0050). THE single place a run becomes an
-- aggregate: both the live capture at the finish seam and the startup replay go through here, so the
-- running server and a restarted one cannot drift apart. Only finished runs count -- DNF and aborted
-- runs are kept in the log for later analysis but never touch a best time (ADR-0027 §3, unchanged).
-- The run's field names match a live session.progress record, so run_section_aggregate takes it
-- verbatim and best_lap ~= nil is the circuit signal exactly as before (ADR-0030).
-- Returns whether this run set a new personal best and/or a new track record.
function runlog.fold(run)
    if type(run) ~= "table" or type(run.race) ~= "string" or run.status ~= "finished" then
        return false, false
    end

    local race = runlog.store[run.race]
    if type(race) ~= "table" then
        race = {players = {}, track_best = {}}
        runlog.store[run.race] = race
    end
    if type(race.players) ~= "table" then
        race.players = {}
    end
    if type(race.track_best) ~= "table" then
        race.track_best = {}
    end

    local is_circuit = run.best_lap ~= nil
    local primary = is_circuit and run.best_lap or run.total_time
    local aggregate = run_section_aggregate(run)

    local is_pb = update_player_record(race.players, run.identity, run.car_key, is_circuit, primary,
        run.total_time, aggregate, run.vehicle, run.date)
    local is_track_record = update_track_best(race.track_best, run.car_key, is_circuit, primary,
        run.total_time, aggregate, run.identity, run.vehicle, run.date)
    return is_pb, is_track_record
end

-- Rebuild the aggregate from the run log (ADR-0050), once per Lua state via runlog.ensure. The log is
-- append-only and therefore already in chronological order, so replaying it top to bottom reproduces
-- exactly the sequence of folds the live server performed -- including which run owns a record's date.
-- Every line is decoded under pcall and type-checked: Util.JsonDecode answers a torn last line with
-- (true, nil) rather than an error, so an ok status alone would not catch it. A missing log leaves the
-- store empty and the first finish seeds it.
function runlog.replay()
    runlog.store = {}

    local path = runlog.resolve_path()
    if not path then
        log_info("beamcomp.records", "no run log found; starting empty")
        return
    end

    local file = io.open(path, "r")
    if not file then
        log_info("beamcomp.records", "could not open run log at " .. path .. "; starting empty")
        return
    end

    local folded, skipped = 0, 0
    for raw in file:lines() do
        -- Trim a trailing CR before anything else. The log is written in text mode, so it holds CRLF on
        -- Windows, and reading it back on Linux (BeamMP ships a Linux server binary) leaves the CR on
        -- every line. Without this, every line would fail the check below and the whole history would
        -- silently fold to an empty aggregate -- indistinguishable from lost data.
        local line = raw:gsub("\r+$", "")
        -- Cheap completeness check before the decode: a whole run line is a JSON object, so it opens
        -- with "{" and closes with "}". A torn final line fails here and is skipped silently -- handing
        -- it to Util.JsonDecode would work too (it answers nil), but it also prints a [LUA ERROR] into
        -- the server console on every start, which reads like a fault when it is just a truncated write.
        if line:sub(1, 1) == "{" and line:sub(-1) == "}" then
            local ok, run = pcall(Util.JsonDecode, line)
            if ok and type(run) == "table" then
                runlog.fold(run)
                folded = folded + 1
            else
                skipped = skipped + 1
            end
        elseif line ~= "" then
            skipped = skipped + 1
        end
    end
    file:close()

    log_info("beamcomp.records", string.format("replayed %d run(s) from %s%s", folded, path,
        skipped > 0 and (" (" .. skipped .. " unreadable line(s) skipped)") or ""))
end

-- How one participant's run ended (ADR-0050). Every real player's run is logged whatever the outcome,
-- so the history keeps DNFs and abandoned races too; only "finished" ever folds into a best time
-- (runlog.fold), which is why leaderboards are unaffected by the wider logging.
function runlog.run_status(record)
    if record.finished and not record.dnf then
        return "finished"
    end
    if record.dnf then
        return "dnf"
    end
    return "aborted"
end

-- A fresh id for one race instance (ADR-0050): unix seconds at the start plus a counter, so every run
-- of the same race shares it and two races on the same track on the same day stay distinguishable. The
-- counter breaks ties when two races start within the same second.
function runlog.next_event_id()
    runlog.event_seq = runlog.event_seq + 1
    return string.format("%d-%d", os.time(), runlog.event_seq)
end

-- The race-level context every run of this race shares (ADR-0050), read straight off the session -- no
-- new client report, nothing the server does not already know. The race SOURCE (ADR-0035/0045) is
-- deliberately absent: the server never learns it, "map:"/"menu:" is only a name-resolution prefix on
-- the typed command and the client's validation verdict reports map/raceId/raceData but no source.
function runlog.race_context()
    local humans, ai = 0, 0
    for _, record in pairs(session.progress or {}) do
        if record.ai then
            ai = ai + 1
        else
            humans = humans + 1
        end
    end
    -- Unpacked rather than folded into `x and y or nil`: order.rev is a boolean whose `false` is
    -- meaningful (forward), and the and/or idiom would silently turn that into nil (unknown).
    local order_mode, order_rev
    if session.order then
        order_mode = session.order.mode
        order_rev = session.order.rev
    end
    return {
        field = humans + ai,
        humans = humans,
        ai = ai,
        order = order_mode,
        order_rev = order_rev,
        start_mode = session.start_mode,
        -- The phase the run was captured in. A normal finish captures during "racing"; an abort during a
        -- qualifying session (ADR-0041 reuses the racing machinery and writes quali laps into
        -- session.progress) captures during "qualifying". Without this a cleared quali would look exactly
        -- like an aborted race run in the history. Never folds -- those runs are aborted, not finished.
        phase = session.phase,
    }
end

-- Final position per participant id, from the same ranked standings the results card shows and the next
-- race's order=last grids by (ADR-0043 penalty included). build_standings is pure, so this is a free read.
function runlog.final_positions()
    local positions = {}
    for _, entry in ipairs(build_standings(true)) do
        positions[entry.id] = entry.position
    end
    return positions
end

-- The log record for one participant's run (ADR-0050). The timing field names deliberately match a live
-- session.progress record, so a decoded run feeds run_section_aggregate verbatim and best_lap ~= nil
-- stays the circuit signal (ADR-0030). The vehicle is COPIED down to the four fields the aggregate and
-- the push actually read, never referenced: the ingestion gate already dropped any serialized partConfig
-- blob and this keeps it out of the log too (bug partconfig-blob-bloats-standings). car_key is stored as
-- captured and reused on replay, so a later change to the key rule leaves old aggregates intact.
function runlog.build_run(id, record, date, timestamp, context, position)
    local info = (session.identities or {})[id]
    local vehicle = info and info.vehicle or nil
    -- The shared race context first, then this driver's own fields -- so a context key added later can
    -- never shadow the per-run slot/position.
    local ctx = {}
    for key, value in pairs(context) do
        ctx[key] = value
    end
    ctx.slot = record.slot
    ctx.pos = position
    return {
        v = runlog.RECORD_VERSION,
        ts = timestamp,
        date = date,
        event = session.race_event,
        race = session.race,
        identity = resolve_identity(id) or record.name,
        status = runlog.run_status(record),
        car_key = vehicle_car_key(vehicle),
        vehicle = vehicle and {
            model = vehicle.model,
            variant = net.safe_variant(vehicle.variant),
            modified = vehicle.modified,
            type = vehicle.type,
        } or nil,
        total_time = record.total_time,
        best_lap = record.best_lap,
        lap = record.lap,
        count = record.count,
        splits = record.splits,
        ctx = ctx,
    }
end

-- Whether any real player got far enough for this race to be worth recording: at least one scored
-- checkpoint. Gates the two abort paths -- a race cleared during spawning or staging has nothing to say
-- and would only add all-zero rows. The finish seam does NOT gate on this: a genuine zero-progress DNF
-- is a fact about a race that actually ran.
function runlog.any_real_progress()
    if not session.progress then
        return false
    end
    for _, record in pairs(session.progress) do
        if not record.ai and (record.completed or 0) > 0 then
            return true
        end
    end
    return false
end

-- Append every real player's run of the active race to the log (ADR-0050). AI slots are skipped -- they
-- never hold records (ADR-0036/0027) and are not part of the driver history. Returns the {id, run} pairs
-- that were written, so the caller can fold them and address the bestNotice back to the right player.
--
-- Called from three seams: the finish (capture_records), the lobby reset (/raceclear, server ran empty)
-- and the top of start_race (a /race re-issued mid-race never passes through finalize_race). Whichever
-- fires first wins -- session.runs_logged makes the capture idempotent per race. `require_progress` is
-- set by the two abort seams; see runlog.any_real_progress.
function runlog.capture(require_progress)
    local logged = {}
    -- Layer 2 of the statistics gate (ADR-0053). Returns BEFORE session.runs_logged is set, deliberately:
    -- the flag then stays nil for the entire race, so the double-log guard shared by the finish seam and
    -- the two abort seams (ADR-0038) sees a consistent "nothing was ever logged" rather than a half-armed
    -- state that claims a capture happened.
    if not cfg.stats_enabled then
        return logged
    end
    if not session.race or not session.progress or session.runs_logged then
        return logged
    end
    if require_progress and not runlog.any_real_progress() then
        return logged
    end
    session.runs_logged = true

    local runs = {}
    local date = os.date("%Y-%m-%d")
    local timestamp = os.time()
    local context = runlog.race_context()
    local positions = runlog.final_positions()
    for id, record in pairs(session.progress) do
        if not record.ai then
            local run = runlog.build_run(id, record, date, timestamp, context, positions[id])
            runs[#runs + 1] = run
            logged[#logged + 1] = {id = id, run = run}
        end
    end

    runlog.append(runs)
    return logged
end

-- Shallow copy of a 1-based numeric array, or nil. Used to snapshot a section-best array before capture
-- mutates it in place (ADR-0030).
local function copy_array(array)
    if type(array) ~= "table" then
        return nil
    end
    local out = {}
    for k, v in pairs(array) do
        out[k] = v
    end
    return out
end

-- The pre-run headline of a track-record leaf (the overall record or a per-car leaf): primary metric +
-- holder, captured before the fold so the Track section can show the OLD record once a run beats it
-- (ADR-0030). Same fields slim_track_record ships for the post-fold record. nil leaf -> nil.
local function old_record_headline(leaf)
    if type(leaf) ~= "table" then
        return nil
    end
    return {
        best_lap = leaf.best_lap,
        total_time = leaf.total_time,
        holder = leaf.holder,
    }
end

-- Snapshot each finisher's PRE-run records (their own car + track car section bests for the Race
-- section deltas, plus the track-record headline any-car / this-car for the Track section's "old record"
-- after a run beats it) so everything diffs against the state BEFORE this run (ADR-0030). Must run
-- before capture_records mutates the store; returns a map keyed by player id.
local function snapshot_prerun_section_bests()
    local snapshot = {}
    -- Layer 2 of the statistics gate (ADR-0053): with no store to diff against there is nothing to
    -- snapshot, and the empty table it returns is exactly what send_race_records already expects.
    if not cfg.stats_enabled then
        return snapshot
    end
    if not session.race or not session.progress then
        return snapshot
    end
    runlog.ensure()
    local race = runlog.store[session.race]
    local players = (type(race) == "table" and type(race.players) == "table") and race.players or {}
    local track_best = (type(race) == "table" and type(race.track_best) == "table")
        and race.track_best or nil
    local track_cars = (type(track_best) == "table" and type(track_best.cars) == "table")
        and track_best.cars or {}
    local identities = session.identities or {}

    for id, record in pairs(session.progress) do
        if record.finished and not record.dnf then
            local info = identities[id]
            local identity = resolve_identity(id) or record.name
            local car_key = vehicle_car_key(info and info.vehicle)
            if car_key then
                local entry = players[identity]
                local player_car = type(entry) == "table" and type(entry.cars) == "table"
                    and entry.cars[car_key] or nil
                snapshot[id] = {
                    playerCarSectionBest = copy_array(player_car and player_car.section_best),
                    trackCarSectionBest = copy_array(track_cars[car_key]
                        and track_cars[car_key].section_best),
                    trackRecordAnyCarOld = old_record_headline(track_best),
                    trackRecordThisCarOld = old_record_headline(track_cars[car_key]),
                }
            end
        end
    end
    return snapshot
end

-- Trim a player's track record to the push payload (ADR-0030): the overall headline + counters plus only
-- the own-car slice (with the per-section average source), never the whole cars map. nil record -> nil.
local function slim_player_record(record, car_key)
    if type(record) ~= "table" then
        return nil
    end
    local cars = type(record.cars) == "table" and record.cars or {}
    local car = car_key and cars[car_key] or nil
    return {
        run_count = record.run_count,
        time_sum = record.time_sum,
        best_total = record.best_total,
        best_lap = record.best_lap,
        car = car and {
            run_count = car.run_count,
            time_sum = car.time_sum,
            best_total = car.best_total,
            best_lap = car.best_lap,
            section_sum = car.section_sum,
            lap_count = car.lap_count,
        } or nil,
    }
end

-- Trim the race's track record to the push payload (ADR-0030): overall headline + counters plus the
-- own-car slice (totals + holder only; the per-section best rides in the pre-run snapshot). nil -> nil.
local function slim_track_record(track, car_key)
    if type(track) ~= "table" then
        return nil
    end
    local cars = type(track.cars) == "table" and track.cars or {}
    local car = car_key and cars[car_key] or nil
    return {
        run_count = track.run_count,
        time_sum = track.time_sum,
        total_time = track.total_time,
        best_lap = track.best_lap,
        holder = track.holder,
        -- The car that set the overall (any-car) record, so the overlay can label it like the this-car
        -- record instead of only the holder identity. nil when the record-setter's vehicle is unknown.
        recordCar = car_descriptor(track.vehicle),
        car = car and {
            total_time = car.total_time,
            best_lap = car.best_lap,
            holder = car.holder,
            run_count = car.run_count,
            time_sum = car.time_sum,
        } or nil,
    }
end

-- The player's cross-track aggregates for the Driver section (ADR-0030), split any-car / this-car:
-- summed runs and raced time over every race, and the count of track records currently held (overall and
-- with this car). Computed by scanning the loaded store -- a handful of races, off any hot path.
local function compute_driver_totals(identity, car_key)
    local any_car = {run_count = 0, time_sum = 0, records_held = 0}
    local this_car = {run_count = 0, time_sum = 0, records_held = 0}
    -- Layer 2 of the statistics gate (ADR-0053). Only reachable from send_race_records, which is gated
    -- itself; stated here so this cannot start answering out of an empty store if a later caller appears.
    if not cfg.stats_enabled or not identity then
        return {anyCar = any_car, thisCar = this_car}
    end
    for _, race_record in pairs(runlog.store) do
        if type(race_record) == "table" then
            local player = type(race_record.players) == "table" and race_record.players[identity] or nil
            if type(player) == "table" then
                any_car.run_count = any_car.run_count + (player.run_count or 0)
                any_car.time_sum = any_car.time_sum + (player.time_sum or 0)
                local player_car = car_key and type(player.cars) == "table"
                    and player.cars[car_key] or nil
                if type(player_car) == "table" then
                    this_car.run_count = this_car.run_count + (player_car.run_count or 0)
                    this_car.time_sum = this_car.time_sum + (player_car.time_sum or 0)
                end
            end
            local track = race_record.track_best
            if type(track) == "table" then
                if track.holder == identity then
                    any_car.records_held = any_car.records_held + 1
                end
                local track_car = car_key and type(track.cars) == "table"
                    and track.cars[car_key] or nil
                if type(track_car) == "table" and track_car.holder == identity then
                    this_car.records_held = this_car.records_held + 1
                end
            end
        end
    end
    return {anyCar = any_car, thisCar = this_car}
end

-- Ship each race participant their records for the analysis overlay at the racing -> finished seam
-- (ADR-0028/0030). Sent AFTER capture_records, so counters, displayed bests, and the per-section average
-- include this run (current-inclusive); the `prerun` section bests (captured before the fold) carry the
-- pre-run "best lap with the car" references the Race section diffs against. Read-only here; identity
-- resolves via session.identities with the progress name as fallback.
local function send_race_records(prerun)
    -- Layer 2 of the statistics gate (ADR-0053): no raceRecords event leaves the server while off. The
    -- client defaults its own flag to off too, but this is the half that must not be shipped in the first
    -- place -- an absent message is what makes the feature undetectable from a client's side.
    if not cfg.stats_enabled then
        return
    end
    if not session.race or not session.progress then
        return
    end

    runlog.ensure()
    prerun = prerun or {}

    local race = runlog.store[session.race]
    local players = (type(race) == "table" and type(race.players) == "table") and race.players or {}
    local track_record = type(race) == "table" and race.track_best or nil
    local identities = session.identities or {}

    for id, record in pairs(session.progress) do
        -- AI slots have no client and hold no records (ADR-0036/0027): nothing to ship them.
        if not record.ai then
            local info = identities[id]
            local identity = resolve_identity(id) or record.name
            local car = car_descriptor(info and info.vehicle)
            local car_key = car and car.key or nil
            send_event(id, MSG_RACE_RECORDS, {
                race = session.race,
                car = car,
                pb = slim_player_record(identity and players[identity] or nil, car_key),
                trackRecord = slim_track_record(track_record, car_key),
                driverTotals = compute_driver_totals(identity, car_key),
                prerun = prerun[id] or {},
            })
        end
    end
end

-- Persist this race at the racing -> finished seam (ADR-0027 §3, storage per ADR-0050): append every
-- real player's run to the log, then fold the finishers into the derived aggregate. runlog.capture logs
-- finishers, DNFs and aborted drivers alike, while runlog.fold counts only the finishers -- so the
-- history keeps everything and the leaderboards are exactly what they were. The old
-- "no finisher -> return early" shortcut is gone: it existed only to skip a file load and a full
-- rewrite, and there is no rewrite any more. The server reads only numbers + the opaque client-reported
-- identity/vehicle, keyed on session.race, so race-blindness (ADR-0005) holds. Improved finishers get
-- a bestNotice.
local function capture_records()
    -- Layer 2 of the statistics gate (ADR-0053): no fold, and above all no bestNotice. This is where the
    -- "new personal best" toast originates, so gating here is what keeps a fast lap silent while off.
    if not cfg.stats_enabled then
        return
    end
    if not session.race or not session.progress then
        return
    end

    runlog.ensure()

    for _, entry in ipairs(runlog.capture()) do
        local is_pb, is_track_record = runlog.fold(entry.run)
        if (is_pb or is_track_record) and entry.run.identity then
            send_event(entry.id, MSG_BEST_NOTICE, {pb = is_pb, trackRecord = is_track_record})
        end
    end
end

-- Settle the race into the finished results window (ADR-0006): classify everyone still out as DNF, fold this
-- run into the records, remember the order, and switch phase. No despawn -- finished keeps cars/props up (B3).
-- Shared by the finish-grace expiry (tick) and the /raceend force-finish (ADR-0038).
local function finalize_race(reason)
    dnf_active_players(reason)
    -- Snapshot pre-run per-car section bests BEFORE capture folds this run in, so the Race section can show
    -- "vs your/anyone's previous best lap with the car"; then capture (this run now counts) and send the
    -- current-inclusive records (ADR-0030).
    local prerun = snapshot_prerun_section_bests()
    capture_records()
    send_race_records(prerun)
    -- Remember the finishing order so the next race's order=last can grid by it (ADR-0033).
    capture_finishing_order()
    -- Fold this race into the championship table and push the updated standings (ADR-0040); both no-ops
    -- when no championship is active.
    champ.award()
    if champ.is_active() then
        champ.broadcast()
    end
    -- Fold this race into the class-drop tournament and push its table (ADR-0042); both no-ops when no
    -- tournament is active. Mutually exclusive with the championship -- only one format runs at a time.
    tour.award()
    if tour.is_active() then
        tour.broadcast()
    end
    -- Re-broadcast the standings with the F1 jump penalty now applied (ADR-0043): the live in-race
    -- broadcasts left a jumper in its on-track position with just the tag, so the finished card needs this
    -- final, penalized order. Sent before the finished phase message; the card reads this snapshot.
    broadcast_standings(true)
    enter_phase(PHASE.finished, PHASE_DURATIONS.finished_hold)
end

local function tick()
    expire_stale_validation()
    maybe_warn_cleanup()
    -- Ahead of the lobby early return below: a player who just joined and has no name is sitting in the
    -- lobby, which is precisely where his hint has to reach him (ADR-0054).
    identity.step()

    local phase = session.phase
    if phase == PHASE.lobby then
        return
    end

    -- racing ends when the finish grace (armed by the first finisher) elapses; any player still out
    -- on track at that point is marked DNF before the race settles (ADR-0014).
    if phase == PHASE.racing then
        if session.grace_deadline then
            if now() >= session.grace_deadline then
                finalize_race("grace expired")
                return
            end
            -- Re-evaluate the early end while the grace runs. A driver going quiet is not an event but
            -- the ABSENCE of one, so the three report-driven callers (a finish, a /dnf, a disconnect)
            -- can never observe it -- only a poll can. Idempotent via the shortening guard inside.
            maybe_end_race()
        end
        return
    end

    -- qualifying is time-boxed (ADR-0041): handled ahead of the generic timed advance so the finish-your-lap
    -- grace can sit between the quali clock and the classification pause (mirrors the racing grace).
    if phase == PHASE.qualifying then
        -- Staged sprint quali (ADR-0044) paces a holding queue of single-car P1 starts; the ADR-0041
        -- circuit quali laps everyone at once. Both arm the finish-your-run/lap grace before quali-results.
        if quali.is_staged() then
            quali.advance_staged()
        else
            quali.advance_qualifying()
        end
        return
    end

    -- spawning ends on spawn-ready acks (or a timeout), not a fixed delay -- handled ahead of the
    -- generic timed advance so a full ack set can leave early (ADR-0006 amendment).
    if phase == PHASE.spawning then
        advance_spawning()
        return
    end

    -- staging waits for the host (ADR-0021 amendment, staging-waits-for-host): it is open-ended, so the
    -- generic timed advance below never reaches it and there is no auto-start -- /go|/start|/racestart,
    -- the panel's raceGo, and /raceclear are the only ways out. Handled here purely for the invisible
    -- emergency exit, measured on phase_elapsed() rather than session.phase_duration: putting the window
    -- in the phase duration would make the phase timed and clients would render a 30-minute clock.
    if phase == PHASE.staging then
        if phase_elapsed() >= PHASE_DURATIONS.staging_abandon then
            -- %.0f, not %d: the durations are an editable server config (ADR-0006), and a fractional
            -- one would make %d a runtime error inside the tick.
            log_info("beamcomp.race", string.format("staged race abandoned -- no host start within %.0f s",
                PHASE_DURATIONS.staging_abandon))
            broadcast_chat("BeamComp: staged race abandoned -- nobody started it")
            reset_to_lobby()
        end
        return
    end

    -- quali-results runs the AI re-grid a lead time before the pause ends (ADR-0041 amendment), so the AI
    -- re-spawn hitch lands on the static results card rather than the race countdown. No return: the pause's
    -- own timed end (-> countdown) still fires via the generic advance below.
    if phase == PHASE.quali_results then
        quali.maybe_regrid()
    end

    -- Every other active phase is timed: advance once its configured duration elapses.
    if not session.phase_duration or phase_elapsed() < session.phase_duration then
        return
    end

    if phase == PHASE.countdown then
        -- For a (circuit) quali event the first countdown gates the qualifying session, not the race
        -- (ADR-0041): the second countdown (after quali-results sets the grid) gates the race. Either way
        -- send the baseline standings (every participant at zero) so clients have a table from the start.
        -- (A staged sprint quali never reaches this branch -- it skips the global countdown above.)
        if quali.is_pending() then
            enter_phase(PHASE.qualifying, session.quali.duration)
        else
            enter_phase(PHASE.racing, nil)
        end
        broadcast_standings()
    elseif phase == PHASE.quali_results then
        quali.advance_results()
    elseif phase == PHASE.finished then
        advance_from_finished()
    end
end

local RACE_USAGE =
    "BeamComp: usage -- /race [map:|menu:]<name> [sprint|circuit] [laps] [reverse] [force] "
    .. "[recover[:secs|off]] [repair[:secs|off]] [grid=<name>] [car=<model[:config]|random>] "
    .. "[maxhp=<n>] [maxpwr=<n>] [maxkg=<n>] [minkg=<n>] "
    .. "[order=entry|random|last|pwr|championship|quali[:rev]] [quali=<min>] "
    .. "[ai <n> [easy|medium|hard]] [aicar=<model[:config]>] [aiaggr=/aiskill=/airubber=<0..1>] "
    .. "[aiavoid=on|off] [airoute=snap|direct] [all]"

-- Opt-in recover/repair assist hold time (ADR-0017): the seconds the player must hold the key before
-- the assist fires. Used when a "recover"/"repair" token carries no explicit ":secs", and as the
-- clamp bounds for one that does.
local ASSIST_DEFAULT_HOLD_SECONDS = 5
local ASSIST_MIN_HOLD_SECONDS = 1
local ASSIST_MAX_HOLD_SECONDS = 30

-- Tokens that turn an assist OFF via its ":suffix" (recover:off / recover:-1 / recover:false). The
-- delay value doubles as the on/off switch, so there is no separate enable flag (ADR-0017 amendment).
local ASSIST_DISABLE_TOKENS = {off = true, ["false"] = true, ["-1"] = true}

-- Clamp a requested assist hold time into the sane [min, max] range.
local function clamp_assist_hold(seconds)
    return math.max(ASSIST_MIN_HOLD_SECONDS, math.min(ASSIST_MAX_HOLD_SECONDS, seconds))
end

-- Interpret the ":suffix" on a recover/repair token. No suffix (bare keyword) -> enabled at the
-- default hold; a disable token -> disabled; a positive integer -> enabled at that clamped hold;
-- anything else -> nil so the caller rejects the whole token and replies usage.
local function parse_assist_suffix(suffix)
    if not suffix then
        return {enabled = true, hold = ASSIST_DEFAULT_HOLD_SECONDS}
    end
    if ASSIST_DISABLE_TOKENS[suffix] then
        return {enabled = false}
    end
    if suffix:match("^%d+$") then
        return {enabled = true, hold = clamp_assist_hold(math.floor(tonumber(suffix)))}
    end
    return nil
end

-- The /race keyword options. RACE_KEYWORDS is the full union matched by unambiguous prefix across ALL
-- of them at once (resolve below), so the shortest typeable form of one option never silently shadows
-- another: "s"/"c" -> sprint/circuit, "rev" -> reverse, "f" -> force, while the shared "re"/"r" stay
-- three-way ambiguous (rec/rep/rev). There is deliberately no "forward" keyword -- forward is the
-- default direction and is never typed, which keeps "f" unambiguously force. RACE_MODES and
-- ASSIST_KEYWORDS classify a resolved keyword; only assist keywords accept a ":secs" suffix (ADR-0018).
local RACE_KEYWORDS = {"sprint", "circuit", "reverse", "recover", "repair", "force", "lights"}
local RACE_MODES = {sprint = true, circuit = true}
local ASSIST_KEYWORDS = {recover = true, repair = true}

-- AI difficulty presets, matched as the positional token right after "ai [<n>]" by unambiguous prefix
-- (ADR-0036 Etappe B). e/m/h are unique, so the shortest forms all resolve. The preset->parameter
-- mapping is client-side (race/ai.lua); the server only relays the resolved name.
local AI_PRESET_LIST = {"easy", "medium", "hard"}

-- Resolve a keyword from a (lowercased) word by unambiguous prefix -- the same "shortest form that
-- stays unambiguous" convenience the race shortnames use. `word` must be a non-empty prefix of
-- exactly one entry in `keywords`; a word that prefixes none, or more than one, resolves to nil.
-- Returns the full keyword or nil.
local function resolve_keyword(word, keywords)
    if word == "" then
        return nil
    end
    local matched
    for _, keyword in ipairs(keywords) do
        if keyword:sub(1, #word) == word then
            if matched then
                return nil  -- prefix of more than one keyword: ambiguous
            end
            matched = keyword
        end
    end
    return matched
end

-- Classify one /race option token into the override it sets, by unambiguous prefix across the whole
-- keyword union. Returns a (kind, value) pair: "mode"/<keyword>, "direction"/"reverse", "force"/true,
-- or "assist"/{keyword, enabled, hold}; or nil if the token is not a recognized option (ambiguous/
-- unknown prefix, not letters, or a ":" suffix on a non-assist keyword, or an unrecognized assist
-- suffix). A ":" suffix is valid only on the assist keywords: ":<secs>" sets the clamped hold and
-- ":off"/":-1"/":false" disables it; a bare keyword is enabled at the default hold (ADR-0017/0018).
local function parse_option_token(token)
    local lowered = token:lower()
    local word = lowered:match("^(%a+)$")
    local suffix
    if not word then
        word, suffix = lowered:match("^(%a+):(.+)$")
    end
    if not word then
        return nil
    end
    local keyword = resolve_keyword(word, RACE_KEYWORDS)
    if not keyword then
        return nil
    end
    if suffix and not ASSIST_KEYWORDS[keyword] then
        return nil  -- a ":" suffix only applies to recover/repair
    end
    if RACE_MODES[keyword] then
        return "mode", keyword
    elseif keyword == "reverse" then
        return "direction", "reverse"
    elseif keyword == "force" then
        return "force", true
    elseif keyword == "lights" then
        return "lights", true  -- F1 light start (ADR-0043); penalty seconds set by jumppenalty=
    end
    local assist = parse_assist_suffix(suffix)
    if not assist then
        return nil  -- recover/repair with an unrecognized suffix (not :secs, not a disable token)
    end
    return "assist", {keyword = keyword, enabled = assist.enabled, hold = assist.hold}
end

-- Start-order modes for /race order= (ADR-0033/0040/0041). entry/random are non-directional; last/pwr/
-- championship accept :rev. championship orders by the live points table (ADR-0040); quali runs a
-- qualifying session first and grids by pace (ADR-0041, pole = fastest, no :rev).
local ORDER_MODES = {entry = true, random = true, last = true, pwr = true, championship = true, quali = true}

-- Parse an order= value "<mode>[:rev]" into {mode, rev}, or nil when the mode is unknown or a suffix
-- other than "rev" is given. :rev flips a directional mode (last/pwr); entry/random ignore it (ADR-0033).
local function parse_order_value(value)
    local lowered = value:lower()
    local mode, suffix = lowered:match("^(%a+):(%a+)$")
    if mode then
        if suffix ~= "rev" then
            return nil
        end
    else
        mode = lowered
    end
    if not ORDER_MODES[mode] then
        return nil
    end
    return {mode = mode, rev = suffix == "rev"}
end

-- Parse a /race argument into the race name plus an overrides table (ADR-0013, ADR-0017, ADR-0018). The
-- first whitespace token is the race name (slug-based, no spaces -- ADR-0005); each remaining token is
-- an order-independent option, matched by unambiguous prefix across the whole keyword set:
-- sprint|circuit (mode), reverse (direction), force, recover|repair[:secs|off] (assists), a bare
-- integer (lap count), grid=<name> (a server-stored start grid, ADR-0023), or the literal "all" (opt
-- the deprecated quickrace source into name resolution, ADR-0026). Returns name (nil if the argument is
-- empty), an overrides table (always present; mode/laps/direction nil = auto, force/all false, both
-- assists ON at the default hold), and the first unrecognized token (or nil) so the caller can reply
-- usage. Both assists default ON at the default hold; a recover:off / repair:off (or :-1 / :false) token
-- turns one back off (ADR-0017 amendment).
-- Classify one "ai*=" raw-parameter override token into the BeamNG ai parameter it sets (ADR-0036
-- Etappe B + Step-3b). aggression/skill/rubberband take a [0,1] number (clamped); avoid takes on/off;
-- route takes snap|direct (the AI route variant, default snap: snap = road-navgraph snap, direct = exact
-- custom-navgraph race line, off-road). Returns (key, value) or nil for an unknown ai key or an invalid
-- value, so the caller can reply usage. "aicar=" is NOT an ai parameter (model token) and resolves to nil.
local function parse_ai_param_token(token)
    local key, raw = token:match("^[Aa][Ii](%a+)=(.+)$")
    if not key then
        return nil
    end
    key = key:lower()
    if key == "aggr" or key == "skill" or key == "rubber" then
        local value = tonumber(raw)
        if not value then
            return nil
        end
        return key, math.max(0, math.min(1, value))
    end
    if key == "avoid" then
        local lowered = raw:lower()
        if lowered == "on" or lowered == "true" then
            return key, true
        end
        if lowered == "off" or lowered == "false" then
            return key, false
        end
        return nil
    end
    if key == "route" then
        local lowered = raw:lower()
        if lowered == "snap" or lowered == "direct" then
            return key, lowered
        end
        return nil
    end
    return nil
end

-- Extract the optional "ai [<n>] [<preset>]" opponent request before the generic option scan (ADR-0036).
-- The count is a following bare integer that the lap-count parser would otherwise claim, and the preset
-- is a following easy/medium/hard token (unambiguous prefix), so both are pulled out here with "ai" and
-- removed. `explicit` records whether a count was typed -- when false the server fills the aiRace content
-- default count (Etappe B). A missing/non-integer count defaults to one AI; the count is clamped to
-- [1, MAX_AI]. Returns {count, explicit, preset} or nil when no ai token is present.
local function extract_ai_request(tokens)
    for i = 2, #tokens do
        if tokens[i]:lower() == "ai" then
            local count, explicit, preset = DEFAULT_AI_COUNT, false, nil
            local remove = {i}  -- always drop the "ai" token itself
            local cursor = i + 1
            if tokens[cursor] and tokens[cursor]:match("^%d+$") then
                count = math.max(1, math.min(MAX_AI, math.floor(tonumber(tokens[cursor]))))
                explicit = true
                remove[#remove + 1] = cursor
                cursor = cursor + 1
            end
            local preset_word = tokens[cursor] and tokens[cursor]:lower():match("^(%a+)$")
            local resolved = preset_word and resolve_keyword(preset_word, AI_PRESET_LIST)
            if resolved then
                preset = resolved
                remove[#remove + 1] = cursor
            end
            -- Remove the consumed indices high-to-low so earlier removals don't shift later ones.
            table.sort(remove, function(a, b) return a > b end)
            for _, idx in ipairs(remove) do
                table.remove(tokens, idx)
            end
            return {count = count, explicit = explicit, preset = preset}
        end
    end
    return nil
end

local function parse_race_args(argument)
    local tokens = {}
    for token in argument:gmatch("%S+") do
        tokens[#tokens + 1] = token
    end

    local name = tokens[1]
    local ai = extract_ai_request(tokens)
    local bad_token
    -- AI vehicle + raw-parameter overrides (ADR-0036 Etappe B), collected in the scan below and attached
    -- to overrides.ai afterwards. Only meaningful when an `ai` request is present; an ai*= token without
    -- one falls to bad_token via the terminal branch.
    local ai_car, ai_params = nil, {}
    local overrides = {
        force = false,
        all = false,
        -- Host-driven AI opponents (ADR-0036), extracted above; nil = none. Relayed only to the owner.
        ai = ai,
        assists = {
            recoverEnabled = true,
            recoverHoldSeconds = ASSIST_DEFAULT_HOLD_SECONDS,
            repairEnabled = true,
            repairHoldSeconds = ASSIST_DEFAULT_HOLD_SECONDS,
        },
    }
    for i = 2, #tokens do
        local token = tokens[i]
        local kind, value = parse_option_token(token)
        if kind == "mode" then
            overrides.mode = value
        elseif kind == "direction" then
            overrides.direction = value
        elseif kind == "force" then
            overrides.force = true
        elseif kind == "lights" then
            -- F1 light start for this race (ADR-0043): an optional start style relayed verbatim like the
            -- other options (race-blind, ADR-0005). Default off = the lock countdown.
            overrides.startMode = "f1"
        elseif kind == "assist" then
            local assists = overrides.assists
            if value.keyword == "recover" then
                assists.recoverEnabled = value.enabled
                if value.enabled then
                    assists.recoverHoldSeconds = value.hold
                end
            else
                assists.repairEnabled = value.enabled
                if value.enabled then
                    assists.repairHoldSeconds = value.hold
                end
            end
        elseif token:lower() == "all" then
            -- Opt the deprecated quickrace source into name resolution (ADR-0026); relayed to the client.
            overrides.all = true
        elseif token:match("^%d+$") then
            overrides.laps = math.floor(tonumber(token))
        elseif token:match("^[Gg][Rr][Ii][Dd]=.+$") then
            -- grid=<name> selects a server-stored grid for this race (ADR-0023); case-insensitive key,
            -- value kept verbatim. An empty value (bare "grid=") is not this branch -> falls to bad_token.
            overrides.grid = token:match("^[Gg][Rr][Ii][Dd]=(.+)$")
        elseif token:match("^[Cc][Aa][Rr]=.+$") then
            -- car=<model[:config]> forces one fixed car for every player (Mode 2, ADR-0032);
            -- case-insensitive key, value (model or model:config) kept verbatim -- the client splits and
            -- spawns it (race-blind, ADR-0005). A bare "car=" is not this branch -> falls to bad_token.
            overrides.car = token:match("^[Cc][Aa][Rr]=(.+)$")
        elseif token:match("^[Mm][Aa][Xx][Hh][Pp]=.+$") then
            -- maxhp=<n> caps engine power per player (Mode 3, ADR-0032); the client keeps a compliant car
            -- or substitutes one. Relayed as a number; a non-numeric value falls to bad_token.
            overrides.maxhp = tonumber(token:match("^[Mm][Aa][Xx][Hh][Pp]=(.+)$"))
            if not overrides.maxhp and not bad_token then
                bad_token = token
            end
        elseif token:match("^[Mm][Aa][Xx][Pp][Ww][Rr]=.+$") then
            -- maxpwr=<n> caps power-to-weight (hp per kg) per player (Mode 3, ADR-0032), analogous to
            -- maxhp. Relayed as a number; a non-numeric value falls to bad_token.
            overrides.maxpwr = tonumber(token:match("^[Mm][Aa][Xx][Pp][Ww][Rr]=(.+)$"))
            if not overrides.maxpwr and not bad_token then
                bad_token = token
            end
        elseif token:match("^[Mm][Aa][Xx][Kk][Gg]=.+$") then
            -- maxkg=<n> sets the upper curb-weight (kg) bound per player (Mode 3, ADR-0032), the weight-axis
            -- sibling of maxhp/maxpwr. Relayed as a number, never interpreted (race-blind, ADR-0005); the
            -- client applies it as a STRICT cap. A non-numeric value falls to bad_token.
            overrides.maxkg = tonumber(token:match("^[Mm][Aa][Xx][Kk][Gg]=(.+)$"))
            if not overrides.maxkg and not bad_token then
                bad_token = token
            end
        elseif token:match("^[Mm][Ii][Nn][Kk][Gg]=.+$") then
            -- minkg=<n> sets the lower curb-weight (kg) bound per player (Mode 3, ADR-0032). Combines with
            -- maxkg into a range (both AND client-side); an impossible range just yields an empty pool the
            -- client aborts on (no minkg<=maxkg check server-side, race-blind). Non-numeric => bad_token.
            overrides.minkg = tonumber(token:match("^[Mm][Ii][Nn][Kk][Gg]=(.+)$"))
            if not overrides.minkg and not bad_token then
                bad_token = token
            end
        elseif token:match("^[Oo][Rr][Dd][Ee][Rr]=.+$") then
            -- order=<mode>[:rev] sets the grid start order (ADR-0033); server-internal, not relayed. An
            -- unknown mode or a bad suffix falls to bad_token.
            overrides.order = parse_order_value(token:match("^[Oo][Rr][Dd][Ee][Rr]=(.+)$"))
            if not overrides.order and not bad_token then
                bad_token = token
            end
        elseif token:match("^[Qq][Uu][Aa][Ll][Ii]=.+$") then
            -- quali=<minutes> sets the qualifying session length for order=quali (ADR-0041); stored in
            -- seconds, clamped to the sane bounds. A non-numeric value falls to bad_token.
            local minutes = tonumber(token:match("^[Qq][Uu][Aa][Ll][Ii]=(.+)$"))
            if minutes then
                overrides.quali_duration = quali.clamp(minutes * 60)
            elseif not bad_token then
                bad_token = token
            end
        elseif token:match("^[Jj][Uu][Mm][Pp][Pp][Ee][Nn][Aa][Ll][Tt][Yy]=.+$") then
            -- jumppenalty=<secs> sets the F1 jump-start time penalty (ADR-0043); only meaningful with
            -- `lights`. Stored as a number; a non-numeric value falls to bad_token.
            overrides.jumpPenaltySeconds = tonumber(token:match("^[Jj][Uu][Mm][Pp][Pp][Ee][Nn][Aa][Ll][Tt][Yy]=(.+)$"))
            if not overrides.jumpPenaltySeconds and not bad_token then
                bad_token = token
            end
        else
            -- AI config tokens (ADR-0036 Etappe B), only accepted alongside an `ai` request: aicar= sets
            -- the AI vehicle, ai*= set raw difficulty parameters. Anything else is an unknown option.
            local handled = false
            if ai then
                local car = token:match("^[Aa][Ii][Cc][Aa][Rr]=(.+)$")
                if car then
                    ai_car = car
                    handled = true
                else
                    local ai_key, ai_value = parse_ai_param_token(token)
                    if ai_key then
                        ai_params[ai_key] = ai_value
                        handled = true
                    end
                end
            end
            if not handled and not bad_token then
                bad_token = token
            end
        end
    end

    -- Attach the collected AI vehicle + parameter overrides to the request (ADR-0036 Etappe B); the
    -- preset and content defaults fill the rest client-side.
    if ai then
        ai.car = ai_car
        if next(ai_params) then
            ai.params = ai_params
        end
    end

    return name, overrides, bad_token
end

-- Admin-gate, apply the vehicle-policy precedence bookkeeping, log, and launch the issuer-client
-- validation handshake for a race request. Shared by the /race chat command and the settings-UI
-- startRace event (ADR-0037): both produce the same `overrides` shape (parse_race_args output), relayed
-- verbatim to clients (race-blind, ADR-0005/0013/0018) for the client to validate against geometry. The
-- caller supplies an already-resolved race_name + overrides; this owns everything from the admin check on.
local function begin_race_request(player_id, player_name, race_name, overrides)
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "start races")
        log_info("beamcomp.race", "denied race request from " .. tostring(player_name) .. " (not a race admin)")
        return
    end

    -- Vehicle-policy precedence (ADR-0032): a FIXED car= wins over the power/weight caps. Drop the caps so
    -- the relay is unambiguous and tell the admin. Pure option bookkeeping -- no vehicle reading. car=random
    -- is the DELIBERATE exception (ADR-0032 amendment): the caps still COMPOSE with the random pick, so they
    -- are kept -- the client draws the random car from the cap-compliant pool.
    if overrides.car and overrides.car ~= "random"
            and (overrides.maxhp or overrides.maxpwr or overrides.maxkg or overrides.minkg) then
        overrides.maxhp = nil
        overrides.maxpwr = nil
        overrides.maxkg = nil
        overrides.minkg = nil
        MP.SendChatMessage(player_id, "BeamComp: car= set -- maxhp/maxpwr/maxkg/minkg ignored")
    end

    local assists = overrides.assists
    local order_echo = ""
    if overrides.order then
        order_echo = " order=" .. overrides.order.mode .. (overrides.order.rev and ":rev" or "")
    end
    log_info("beamcomp.race", string.format(
        "race '%s' by %s (phase %s)%s%s%s%s recover=%s repair=%s%s%s%s%s%s%s%s",
        race_name, player_name, session.phase,
        overrides.mode and (" mode=" .. overrides.mode) or "",
        overrides.laps and (" laps=" .. overrides.laps) or "",
        overrides.direction and (" dir=" .. overrides.direction) or "",
        overrides.force and " force" or "",
        assists.recoverEnabled and (assists.recoverHoldSeconds .. "s") or "off",
        assists.repairEnabled and (assists.repairHoldSeconds .. "s") or "off",
        overrides.car and (" car=" .. overrides.car) or "",
        overrides.maxhp and (" maxhp=" .. overrides.maxhp) or "",
        overrides.maxpwr and (" maxpwr=" .. overrides.maxpwr) or "",
        overrides.maxkg and (" maxkg=" .. overrides.maxkg) or "",
        overrides.minkg and (" minkg=" .. overrides.minkg) or "",
        order_echo,
        overrides.ai and (" ai=" .. overrides.ai.count
            .. (overrides.ai.explicit and "" or "(default)")
            .. (overrides.ai.preset and (" " .. overrides.ai.preset) or "")) or ""))

    -- Race-blind, so we cannot vet the options against geometry here (ADR-0005). Ask the issuer's
    -- client to validate first (ADR-0019): nothing starts until it answers raceValidation ok. The nonce
    -- lets a stale/duplicate reply (e.g. a re-issued request) be ignored.
    session.validation_seq = session.validation_seq + 1
    local nonce = session.validation_seq
    session.pending_validation = {
        race = race_name,
        overrides = overrides,
        owner_id = player_id,
        nonce = nonce,
        deadline = now() + VALIDATION_TIMEOUT,
    }
    send_event(player_id, MSG_VALIDATE_RACE, {
        race = race_name,
        mode = overrides.mode,
        laps = overrides.laps,
        direction = overrides.direction,
        force = overrides.force,
        all = overrides.all,  -- opt the deprecated quickrace source into resolution (ADR-0026)
        nonce = nonce,
        -- The cars this race has ALREADY decided on (ADR-0051 round 2): the fixed car= policy, the
        -- uniform aicar, and the roster's pre-picked AI cars. The issuer's client resolves their
        -- footprints from vehicle metadata and returns them in the verdict, so the slot assignment that
        -- follows can reserve for them right away instead of waiting for a spawn report. The tokens are
        -- the admin's own, relayed back verbatim -- the server neither parses nor interprets them.
        car = overrides.car,
        aiCar = overrides.ai and overrides.ai.car or nil,
        aiRoster = grid_fit.roster_cars(overrides.ai and overrides.ai.roster),
    })
end

-- /race <name> [options]: parse the chat argument into a race name + overrides, then hand off to the
-- shared kickoff (ADR-0037). From an idle/finished session it starts the race; from an active one it
-- queues the new race after a brief abort window (ADR-0006), both downstream of the validation handshake.
local function handle_race_command(player_id, player_name, argument)
    local race_name, overrides, bad_token = parse_race_args(argument)

    if not race_name then
        MP.SendChatMessage(player_id, RACE_USAGE)
        return
    end
    if bad_token then
        MP.SendChatMessage(player_id, "BeamComp: unknown option '" .. bad_token .. "' -- " .. RACE_USAGE)
        return
    end

    begin_race_request(player_id, player_name, race_name, overrides)
end

-- Start (or, mid-race, queue) a race whose options the issuer's client has validated (ADR-0019). The
-- phase is re-checked here, not at request time, since the race may have ended while the check was in
-- flight: from lobby/finished start now; from an active phase queue + run the brief abort window.
local function commit_validated_race(race_name, owner_id, overrides, map, race_id, race_data)
    -- Prefetch the track for anyone who lacks it (ADR-0046). Fired here, at the earliest moment the race
    -- is known to be going ahead: a client can pull the scenery during the spawning phase instead of
    -- receiving it inside its raceStart -- and when this race is QUEUED behind a running one (below), an
    -- entire race early. Costs nothing on a server where everyone has the track: nobody answers.
    track.probe(race_id, owner_id)

    if session.phase == PHASE.lobby or session.phase == PHASE.finished then
        start_race(race_name, owner_id, overrides, map, race_id, race_data)
        MP.SendChatMessage(owner_id, "BeamComp: starting race '" .. race_name .. "'")
        return
    end

    session.pending_race = race_name
    session.pending_owner = owner_id
    session.pending_overrides = overrides
    session.pending_map = map
    session.pending_race_id = race_id
    session.pending_race_data = race_data
    enter_phase(PHASE.finished, PHASE_DURATIONS.abort_window)
    MP.SendChatMessage(owner_id, "BeamComp: restarting with race '" .. race_name .. "'")
end

-- The issuer's client's pre-flight verdict (ADR-0019). Match it to the in-flight check by nonce + owner
-- so a stale or spoofed reply is dropped, then either commit the race (ok) or relay why it was refused.
local function handle_race_validation(player_id, payload)
    local pending = session.pending_validation
    if not pending or type(payload) ~= "table" or payload.nonce ~= pending.nonce
        or player_id ~= pending.owner_id then
        return
    end
    session.pending_validation = nil

    if payload.ok then
        -- The client reports its map + canonical race id in the verdict (ADR-0023); the server keys the
        -- grid lookup on them. Either missing just means no custom grid resolves (procedural fallback).
        local map = type(payload.map) == "string" and payload.map or nil
        local race_id = type(payload.raceId) == "string" and payload.raceId or nil
        -- Fill the content default AI count when the admin opted into AI without a number (ADR-0036
        -- Etappe B): the race-blind server takes racerCount from the issuer client's reply (ADR-0019/0005).
        local overrides = pending.overrides
        if overrides.ai and not overrides.ai.explicit and type(payload.aiDefaults) == "table" then
            local content_count = tonumber(payload.aiDefaults.count)
            if content_count then
                overrides.ai.count = math.max(1, math.min(MAX_AI, math.floor(content_count)))
            end
        end
        -- Staged sprint quali activation (ADR-0044): the race-blind server cannot read meta.closed, so the
        -- issuer's client reports whether an order=quali on this race is the staged sprint variant (sprint =
        -- meta.closed false, or a sprint mode override). Captured verbatim; only read when order=quali.
        overrides.staged_quali = payload.stagedQuali == true
        -- The footprints of the already-decided cars (ADR-0051 round 2), resolved by the issuer's client
        -- from the tokens we relayed. Kept on overrides so they ride into start_race -- including a race
        -- queued behind a running one -- and are seeded before the slots are handed out.
        overrides.car_size = grid_fit.usable_pair(payload.carSize)
        overrides.ai_car_size = grid_fit.usable_pair(payload.aiCarSize)
        overrides.ai_roster_sizes = grid_fit.indexed_pairs(payload.aiRosterSizes)
        -- The issuer's serialized race definition + statics content (ADR-0039): captured here as an opaque
        -- blob and relayed verbatim into raceStart so a file-less client can build the race. The server
        -- never parses or inspects it -- race-blindness holds (ADR-0005). nil from an older client.
        local race_data = type(payload.raceData) == "table" and payload.raceData or nil
        commit_validated_race(pending.race, pending.owner_id, overrides, map, race_id, race_data)
    else
        local reason = type(payload.reason) == "string" and payload.reason or "race options rejected"
        MP.SendChatMessage(pending.owner_id, "BeamComp: " .. reason)
        log_info("beamcomp.race", string.format("/race '%s' refused: %s", pending.race, reason))
    end
end

-- A client reports its car is spawned + seated (ADR-0006 amendment). Counts toward the spawning gate
-- only while spawning, from a rostered player still awaited, for the active race -- the phase/roster/
-- race guards drop stale or duplicate acks (mirrors the raceValidation nonce/phase guards, ADR-0019).
local function handle_spawn_ready(player_id, payload)
    if session.phase ~= PHASE.spawning or type(payload) ~= "table"
        or payload.race ~= session.race then
        return
    end
    if not session.spawn_pending or not session.spawn_pending[player_id] then
        return
    end
    session.spawn_pending[player_id] = nil
    session.spawn_ready_count = session.spawn_ready_count + 1
end

-- Stash a client's reported vehicle for this race's best-times records (ADR-0027/0031). Guarded like
-- the spawnReady ack -- accepted only during an active race for the matching race name -- so a stale
-- report from a previous race is dropped. The values are opaque to the server (race-blind, ADR-0005);
-- they are read at the finish capture. Identity is no longer carried here -- it is reported once on
-- connect via clientIdentity (ADR-0054). Logged once so the unverified vehicle globals are visible.
local function handle_client_info(player_id, payload)
    if session.phase == PHASE.lobby or type(payload) ~= "table"
        or payload.race ~= session.race then
        return
    end
    local vehicle = type(payload.vehicle) == "table" and payload.vehicle or nil
    -- Gate the reported variant at ingestion (bug partconfig-blob-bloats-standings): a serialized partsTree
    -- blob is dropped here, in place, before it is keyed, broadcast, or persisted -- the run log copies the
    -- vehicle from here, so this one gate covers the persisted history too.
    if vehicle then
        vehicle.variant = net.safe_variant(vehicle.variant)
    end
    session.identities = session.identities or {}
    -- A proxied AI report (ADR-0036 Etappe B): the owner reports an AI car's pwr tagged with its aiId, so
    -- the pwr re-grid can sort the AI into the field (ADR-0033). Stored under the AI id, never the owner's,
    -- and accepted only from the race owner for a known AI slot -- mirrors the proxied checkpoint route.
    local target_id = player_id
    if payload.aiId ~= nil then
        if player_id ~= session.owner_id or not is_ai_id(payload.aiId)
            or not (session.progress and session.progress[payload.aiId]) then
            return
        end
        target_id = payload.aiId
    end
    -- pwr (power-to-weight) feeds the start-order pwr re-grid (ADR-0033); carLength/carWidth (metres)
    -- feed the size-aware slot reservation (ADR-0051). All three are stored verbatim and only computed
    -- with, never interpreted as a vehicle (race-blind, ADR-0005). nil/non-number when the client could
    -- not read them -- that car then sorts to the back / reserves nothing rather than failing the grid.
    --
    -- The footprint is the one field that is KEPT when a report does not carry it. Everything else here
    -- describes the report itself, but a footprint may already have arrived from an earlier, different
    -- source -- the lobby report or the pre-flight resolve, both of which land before the slots are even
    -- assigned (round 2). Letting a later read that happened to fail wipe it would silently un-reserve a
    -- bus mid-staging; keeping it costs at worst one slot that nobody needed.
    local previous = session.identities[target_id]
    session.identities[target_id] = {
        vehicle = vehicle,
        pwr = tonumber(payload.pwr),
        car_length = tonumber(payload.carLength) or (previous and previous.car_length),
        car_width = tonumber(payload.carWidth) or (previous and previous.car_width),
    }
    -- The footprint rides this line too, so the ADR-0051 reservation can be diagnosed from the server
    -- console alone: an early (pre-spawn) report shows a size with no vehicle, and a car that reserves
    -- nothing shows "size=unknown".
    local reported = session.identities[target_id]
    log_info("beamcomp.records", string.format(
        "clientInfo id=%s vehicle=%s/%s modified=%s size=%s",
        tostring(target_id),
        tostring(vehicle and vehicle.model),
        tostring(vehicle and vehicle.type),
        tostring(vehicle and vehicle.modified),
        (reported.car_length and reported.car_width)
            and string.format("%.2fx%.2f m", reported.car_length, reported.car_width)
            or "unknown"))

    -- One-shot per-driver car channel (ADR-0029 amendment, bug partconfig-blob-bloats-standings): the car
    -- descriptor is STATIC per driver per race, so ship it ONCE here (when first known / on change) instead
    -- of on every ~1 Hz standings broadcast. Keyed by the participant id (matches the standings entry id;
    -- regrid-stable). The client caches it and renders the overlay from the cache; build_standings no longer
    -- carries `car`. AI report no vehicle -> no descriptor -> no entry (car stays nil, as before). "carInfo"
    -- matches the client HANDLERS key (inlined -- main.lua has no MSG_* table to extend and sits at the
    -- 200-local ceiling). Race-blind: the descriptor is opaque relayed data (ADR-0005).
    local car = car_descriptor(vehicle)
    if car and session.progress and session.progress[target_id] then
        broadcast_event("carInfo", {entries = {{id = target_id, car = car}}})
    end

    -- The EARLY slot-reservation pass (ADR-0051 §6): a footprint that changes the fit rolls out over the
    -- existing regrid straight away, so a bus is accounted for within a moment of its spawn instead of
    -- only at the countdown. Self-gating -- it does nothing unless the slot map actually moves, and it
    -- refuses any phase where the field is not parked on the grid. The race start never waits on it.
    grid_fit.apply("clientInfo")
end

-- Whether `candidate` may be used as a player-set name (ADR-0054). Returns true, or false plus the chat
-- line explaining what is wrong -- the /name handler posts that line verbatim, so each rejection reads as
-- its own reason instead of one generic refusal.
--
-- Runs on BOTH entry points: the /name command AND the connect report. The client persists its name in a
-- player-editable JSON file, so validating only the command would leave the `guest` disguise rule and the
-- admin-name rule bypassable with a text editor. A name that /name accepted always passes here, so this
-- rejects nothing legitimate.
function identity.validate(candidate)
    if type(candidate) ~= "string" then
        return false, identity.USAGE  -- defensive: /name and the report both hand over a string
    end
    -- Bytes, not characters -- see identity.MAX_BYTES.
    if #candidate < identity.MIN_BYTES or #candidate > identity.MAX_BYTES then
        return false, string.format("BeamComp: a name is %d-%d characters long (yours is %d)",
            identity.MIN_BYTES, identity.MAX_BYTES, #candidate)
    end
    -- Defensive: the chat lines and standings entries around this name are assembled by hand, and a
    -- newline or a terminal escape inside one would corrupt them.
    --
    -- A byte scan, not a pattern: the obvious "[%z\1-\31]" leans on the %z class, which Lua 5.2 REMOVED
    -- (this server runs 5.3.5, where an unknown class letter is documented to match that literal
    -- character -- so on a stricter build the class would silently start rejecting every name containing
    -- a "z" instead of a control character). This loop cannot drift with the interpreter.
    for i = 1, #candidate do
        if candidate:byte(i) < 0x20 then
            return false, "BeamComp: a name may not contain control characters"
        end
    end
    local normalized = normalize_name(candidate)
    -- A player calling himself "guest…" would look unnamed and so escape the join hint and the admin's
    -- reminder list -- the one hole that would defeat the whole discovery mechanism.
    if normalized:sub(1, 5) == "guest" then
        return false, "BeamComp: a name may not start with \"guest\""
    end
    -- Wearing an admin's name visually. Meaningful only while the gate is active: a server with no admins
    -- configured has an empty allowlist and nothing to protect (ADR-0016).
    if cfg.admins[normalized] == true then
        return false, "BeamComp: that name belongs to a race admin"
    end
    return true
end

-- Store `requested` as this player's identity, disambiguated against the other connected players
-- (ADR-0054, carrying over the ADR-0031 amendment). Returns the name that took effect plus whether it
-- changed. The single implementation both entry points -- /name and the connect report -- go through, so
-- the two can never drift apart.
--
-- Append the lowest free integer on a collision (SPEEDY -> SPEEDY2 -> SPEEDY3); without it two connected
-- players with one name would silently merge in the live standings and in this session's records. The own
-- entry is skipped, so an unchanged re-report keeps its name and reverting to a now-free name drops the
-- suffix. Cross-session/historical collisions stay accepted (ADR-0031 decision 5).
function identity.apply(player_id, requested)
    local function taken(candidate)
        for id, name in pairs(client_names) do
            if id ~= player_id and name == candidate then
                return true
            end
        end
        return false
    end
    local unique = requested
    local suffix = 1
    while taken(unique) do
        suffix = suffix + 1
        unique = requested .. tostring(suffix)
    end
    local changed = client_names[player_id] ~= unique
    client_names[player_id] = unique
    -- A name arriving after the race started refreshes the live board, so the standings switch from the
    -- BeamMP name to the set name without waiting for the next checkpoint.
    if changed and session.progress then
        broadcast_standings()
    end
    -- The panel's row for this player changes on ANY accepted name, not only on his first one: the list
    -- shows every connected player, so a rename moves the row's text and its sort group. Here rather than
    -- at the two call sites -- this is the only place a client_names entry is written, so the push cannot
    -- be forgotten by a third entry point later.
    if changed then
        identity.broadcast_players()
    end
    return unique, changed
end

-- Whether player-set names do anything on this server (ADR-0054). `useClientName` is an operator-editable
-- key in the shipped beamcomp.config.json (ADR-0031 §4): with it off, resolve_identity ignores
-- client_names entirely, so a name set here would change nothing anywhere. Everything the feature shows
-- the player -- the command, the join hint, the admin's list -- goes through this, so an operator who
-- turns identity off gets a server that says so rather than one that quietly ignores /name.
function identity.is_enabled()
    return cfg.use_client_name == true
end

-- EVERY connected player as {id, name, temporary}, for the race-setup panel's Players section
-- (ADR-0054, round 2). `name` is the name the player is actually shown under -- resolve_identity, the
-- same chokepoint the standings read -- and `temporary` marks a name BeamMP handed out that he can still
-- replace with /name.
--
-- `temporary` is deliberately NOT simply "he has no client_names entry": with useClientName off nobody
-- can change his name, so marking it temporary would be an instruction he cannot follow. The field says
-- exactly what the marker in the panel claims, under both settings.
--
-- Derived from MP.GetPlayers() on every call -- there is no second bookkeeping table to keep in step with
-- reality.
--
-- Sorted temporary-first, then alphabetically inside each group: the temporary names are the admin's
-- reason to open this list, and a deterministic order keeps rows from jumping between pushes.
--
-- `leaving_id` drops one player from the result. The disconnect path needs it: onPlayerDisconnect may or
-- may not still list the leaving player (see is_server_empty_without), so without it a leaver could
-- linger in the admin's list until the next unrelated change.
function identity.player_list(leaving_id)
    local rows = {}
    local enabled = identity.is_enabled()
    for player_id, beammp_name in pairs(MP.GetPlayers()) do
        if player_id ~= leaving_id then
            rows[#rows + 1] = {
                id = player_id,
                name = resolve_identity(player_id) or beammp_name,
                temporary = enabled and client_names[player_id] == nil,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.temporary ~= b.temporary then
            return a.temporary
        end
        return tostring(a.name) < tostring(b.name)
    end)
    return rows
end

-- Push the player list to every client (ADR-0054), so an open race-setup panel reflects reality.
-- Broadcast rather than sent to admins only: the list carries names that are already on everyone's
-- standings board, and filtering per player would mean tracking who is an admin -- new bookkeeping for
-- nothing. Only the admin-gated panel renders it.
function identity.broadcast_players(leaving_id)
    broadcast_event(identity.MSG_PLAYERS, {players = identity.player_list(leaving_id)})
end

-- The Remind button in the race-setup panel (ADR-0054): send the join hint to everyone still on a
-- temporary name, so the admin can fix a grid full of guest names before the start instead of after it.
-- The panel lists ALL players but Remind targets only the temporary ones -- it filters the very list the
-- panel renders, so the button can never reach somebody the panel does not mark.
-- Admin-gated like the grid messages (ADR-0023) -- it writes to every targeted player's chat.
--
-- Reads the caller's name straight off MP.GetPlayers rather than through player_name_of: that local is
-- declared further down the chunk, so a closure created here could not see it.
function identity.handle_remind(player_id)
    local player_name = MP.GetPlayers()[player_id]
    if not player_name then
        return
    end
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "remind players")
        log_info("beamcomp.identity", "denied " .. identity.MSG_REMIND .. " from " .. player_name
            .. " (not a race admin)")
        return
    end

    local reminded = 0
    for _, row in ipairs(identity.player_list()) do
        if row.temporary then
            MP.SendChatMessage(row.id, identity.HINT)
            reminded = reminded + 1
        end
    end
    MP.SendChatMessage(player_id, string.format("BeamComp: reminded %d player(s) to set a name", reminded))
    log_info("beamcomp.identity", string.format("%s by %s reached %d player(s)", identity.MSG_REMIND,
        player_name, reminded))
end

-- A player joined (ADR-0054): put him on the panel's list and arm his one-time hint.
--
-- The two halves have DIFFERENT timing on purpose. The list is pushed NOW, because the panel shows every
-- connected player and a join changes it immediately -- he appears at once marked `temporary name`, and
-- loses the marker seconds later when his stored name arrives. The HINT waits out a grace instead: a
-- client that HAS a stored name reports it a moment after joining, so hinting at the join instant would
-- write to exactly the people who are about to be named. identity.step emits it once the grace has
-- passed and the player is still without an entry.
--
-- Idempotent, and a re-arm only pushes the deadline later -- which is what makes registering both join
-- events safe (see the MP.RegisterEvent block at the end of the file). The second call re-pushes the list
-- as well, which also covers an earlier event that fired before MP.GetPlayers knew the id.
function identity.handle_join(player_id)
    identity.broadcast_players()
    if client_names[player_id] or not identity.is_enabled() then
        return
    end
    identity.pending[player_id] = now() + identity.HINT_DELAY
end

-- Emit any join hint whose grace has run out. Called from the top of tick(), ABOVE its lobby early
-- return: the lobby is exactly where a joining player is.
--
-- The `client_names[id] == nil` test here is the ONE place that decides whether a hint is still
-- warranted -- neither /name nor the connect report clears the pending entry, so there is no list of
-- accept paths that has to stay complete for the rule to hold. Clearing the entry before the send makes
-- it a one-shot even if the send throws; a player who is named by now, or gone, gets nothing.
function identity.step()
    if next(identity.pending) == nil then
        return
    end
    local due = now()
    local players = MP.GetPlayers()
    for player_id, deadline in pairs(identity.pending) do
        if due >= deadline then
            identity.pending[player_id] = nil
            if client_names[player_id] == nil and players[player_id] then
                MP.SendChatMessage(player_id, identity.HINT)
                log_info("beamcomp.identity", "hinted id " .. tostring(player_id) .. " to set a name")
            end
        end
    end
    -- No list push here. The grace belongs to the HINT, not to the display: the player has been on the
    -- panel's list since he joined, marked `temporary name`, and a chat line changes nothing about the row.
end

-- /name <x>: the player picks the name everyone sees (ADR-0054). Open to every player -- it changes only
-- how that player is labelled, never what he may do. parse_command already hands over the trimmed
-- remainder of the line, so "/name Max Mustermann" arrives whole and spaces need no handling here.
--
-- The phase gate sits AHEAD of the content rules on purpose: during a race the reason a /name is refused
-- is the lock, and answering "your name is too long" instead would send the player off fixing something
-- that was never going to be accepted either way. Read off the PHASE table, so a renamed phase is a load
-- error rather than a silently dead comparison.
function identity.handle_command(player_id, player_name, argument)
    if not identity.is_enabled() then
        MP.SendChatMessage(player_id, "BeamComp: this server shows BeamMP names -- "
            .. identity.CHAT_COMMAND .. " is switched off")
        return
    end
    if argument == nil or argument == "" then
        MP.SendChatMessage(player_id, identity.USAGE)
        return
    end

    if session.phase ~= PHASE.lobby and session.phase ~= PHASE.staging then
        MP.SendChatMessage(player_id, "BeamComp: too late to change your name -- "
            .. identity.CHAT_COMMAND .. " works in the lobby and while the field is staging")
        return
    end

    local ok, reason = identity.validate(argument)
    if not ok then
        MP.SendChatMessage(player_id, reason)
        return
    end

    local unique = identity.apply(player_id, argument)
    log_info("beamcomp.identity", string.format("%s by %s (id=%s) -> %s", identity.CHAT_COMMAND,
        tostring(player_name), tostring(player_id), unique))
    -- Send back what the player TYPED, not the suffixed form that took effect: the client persists this
    -- value, and storing "SPEEDY2" would strand him on the suffix forever, while re-requesting "SPEEDY"
    -- each session correctly drops it once the colliding player is gone.
    send_event(player_id, identity.MSG_SET, {name = argument})
    MP.SendChatMessage(player_id, unique == argument
        and ("BeamComp: you race as " .. unique)
        or ("BeamComp: name taken -- you race as " .. unique))
end

-- Store a client's reported player-set name for identity resolution (ADR-0054). Connection-scoped: kept
-- across races and lobby resets, cleared on disconnect, so the name is available from join onward. The
-- value is opaque to the server (race-blind, ADR-0005) -- only echoed back as a display/record key.
--
-- The client sends this once at connect from its settings file, so a rejection here is a tampered or
-- stale file rather than a player action: log it and drop it, no chat line.
local function handle_client_identity(player_id, payload)
    if type(payload) ~= "table" or type(payload.name) ~= "string" then
        return
    end
    local requested = payload.name
    local ok, reason = identity.validate(requested)
    if not ok then
        log_info("beamcomp.identity", string.format("clientIdentity id=%s rejected: %s (name=%s)",
            tostring(player_id), reason, requested))
        return
    end

    local unique, changed = identity.apply(player_id, requested)
    log_info("beamcomp.identity", string.format("clientIdentity id=%s name=%s%s",
        tostring(player_id), unique,
        unique ~= requested and (" (requested " .. requested .. ")") or ""))
    -- Tell the player the adjusted name when it was suffixed, so the standings name is not a silent surprise.
    -- Gate on `changed` too, so a permanently same-named player isn't re-notified on every unchanged report
    -- (the suffix is announced once, when it first takes effect).
    if changed and unique ~= requested then
        MP.SendChatMessage(player_id, "BeamComp: name taken, using " .. unique)
    end
end

-- /raceclear: force the machine back to lobby + cleanup/despawn from any active phase (safety hatch). This
-- is the former /raceend behavior; /raceend now force-finishes into the results screen instead (ADR-0038).
local function handle_raceclear_command(player_id, player_name)
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "end races")
        log_info("beamcomp.race", "denied /raceclear from " .. player_name .. " (not a race admin)")
        return
    end

    if session.phase == PHASE.lobby then
        MP.SendChatMessage(player_id, "BeamComp: no race in progress")
        return
    end
    log_info("beamcomp.race", "/raceclear by " .. player_name)
    reset_to_lobby()
    MP.SendChatMessage(player_id, "BeamComp: race cleared")
end

-- /raceend: force the race straight into the finished/results screen without despawn (ADR-0038). Runs the
-- same finalize as a grace expiry (classify everyone, capture records) from any active pre-finished phase;
-- the cars/props stay up until /raceclear or the finished window expires.
local function handle_raceend_command(player_id, player_name)
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "end races")
        log_info("beamcomp.race", "denied /raceend from " .. player_name .. " (not a race admin)")
        return
    end

    if session.phase == PHASE.lobby then
        MP.SendChatMessage(player_id, "BeamComp: no race in progress")
        return
    end
    if session.phase == PHASE.finished then
        MP.SendChatMessage(player_id, "BeamComp: race already finished")
        return
    end
    log_info("beamcomp.race", "/raceend (force finish) by " .. player_name)
    finalize_race("force finish")
    MP.SendChatMessage(player_id, "BeamComp: race finished -- results up (cars stay; /raceclear to clear)")
end

-- Parse a /championship argument into an action plus optional settings (ADR-0040). Recognizes a bare
-- action token (start | reset/end/stop | show/status) and points=<preset> / order=normal|reversed tokens.
-- An unknown preset prefix or order word is dropped (left nil); the caller normalizes a bare points=/order=
-- into a live "set". Order is forgiving so both the chat command and the panel's reconstructed string parse.
function champ.parse_args(argument)
    local action, preset, order, quali_seconds
    for token in argument:gmatch("%S+") do
        local lowered = token:lower()
        local key, value = lowered:match("^(%a+)=(%w+)$")  -- %w: the f1 preset carries a digit
        if key == "points" then
            preset = resolve_keyword(value, champ.PRESETS)
        elseif key == "order" then
            if value == "normal" or value == "reversed" or value == "quali" then
                order = value
            end
        elseif key == "quali" then  -- quali=<min>: the qualifying length for grid=quali (ADR-0041)
            local minutes = tonumber(value)
            if minutes then
                quali_seconds = quali.clamp(minutes * 60)
            end
        elseif lowered == "start" or lowered == "reset" or lowered == "end" or lowered == "stop"
            or lowered == "show" or lowered == "status" then
            action = lowered
        end
    end
    return action, preset, order, quali_seconds
end

-- /championship: manage the multi-race points championship (ADR-0040). `start [points=<preset>]
-- [order=normal|reversed]` begins one; `reset`/`end`/`stop` ends it and announces the overall winner; a
-- bare points=/order= changes settings live; a bare command (or show/status) posts the current table.
-- Mutations are admin-gated (ADR-0016); the query is open to everyone like /races. Shared by the chat
-- command and the setup panel (champ.handle_cmd), so both reuse one validated mutation path.
function champ.handle_command(player_id, player_name, argument)
    local action, preset, order, quali_seconds = champ.parse_args(argument)

    if action == "end" or action == "stop" then
        action = "reset"
    elseif action == "status" then
        action = "show"
    elseif not action and (preset or order or quali_seconds) then
        action = "set"  -- a bare points=/order=/quali= is a live change
    elseif not action then
        action = "show"
    end

    if action == "show" then
        champ.post_table(player_id)
        return
    end

    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "manage the championship")
        log_info("beamcomp.champ", "denied /championship from " .. player_name .. " (not a race admin)")
        return
    end

    if action == "start" then
        tour.reset()  -- mutual exclusion: starting a championship ends any class-drop tournament (ADR-0042)
        champ.start(preset, order, quali_seconds)  -- nil/reversed -> reversed grid; "normal"/"quali" as given
        champ.broadcast()
        tour.broadcast()  -- tell clients the tournament (if it was on) is now off
        broadcast_chat(string.format("BeamComp: championship started -- points=%s, grid=%s",
            session.championship.points_preset, champ.order_label(session.championship.order)))
        log_info("beamcomp.champ", "championship started by " .. player_name)
        return
    end

    if action == "reset" then
        if not champ.is_active() then
            MP.SendChatMessage(player_id, "BeamComp: no championship active")
            return
        end
        local winner = champ.winner_text()
        champ.reset()
        champ.broadcast()
        broadcast_chat(winner and ("BeamComp: championship over -- winner: " .. winner)
            or "BeamComp: championship reset")
        log_info("beamcomp.champ", "championship reset by " .. player_name)
        return
    end

    -- action == "set": a live preset / grid-order change on an active championship.
    if not champ.is_active() then
        MP.SendChatMessage(player_id, "BeamComp: no championship active -- /championship start first")
        return
    end
    champ.set_preset(preset)
    if order then
        champ.set_order(order)
    end
    champ.set_quali(quali_seconds)
    champ.broadcast()
    MP.SendChatMessage(player_id, string.format("BeamComp: championship updated -- points=%s, grid=%s",
        session.championship.points_preset, champ.order_label(session.championship.order)))
end

-- /go, /start, /racestart: end the staging wait and start the countdown (ADR-0021). Admin-gated like
-- /race; a no-op (with a notice) from any phase other than staging. Since the ADR-0021 amendment this
-- is the ONLY way a staged race moves forward -- staging no longer times out -- and the panel's raceGo
-- routes through here too (handle_race_go), so both host routes share one admin gate and one end state.
local function handle_start_command(player_id, player_name)
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "start races")
        log_info("beamcomp.race", "denied /go from " .. player_name .. " (not a race admin)")
        return
    end

    if session.phase ~= PHASE.staging then
        MP.SendChatMessage(player_id, "BeamComp: nothing to start (no race staging)")
        return
    end
    log_info("beamcomp.race", "manual start by " .. player_name)
    -- Staged sprint quali (ADR-0044/Round4): the staged event skips the global countdown -- otherwise the
    -- 3-2-1 renders -- and goes straight into the staged queue, where each driver gets their own
    -- per-driver settle + start count at P1. The circuit quali and every normal race run the global
    -- countdown via enter_countdown_from_staging.
    if quali.is_staged() then
        enter_phase(PHASE.qualifying, session.quali.duration)
        broadcast_standings()
        quali.start_session()
        MP.SendChatMessage(player_id, "BeamComp: qualifying started")
    else
        enter_countdown_from_staging()
        MP.SendChatMessage(player_id, "BeamComp: countdown started")
    end
end

-- /dnf: the issuing player gives up the current race -- mark them DNF (terminal, ADR-0014). Racing
-- only; a finished or already-DNF player is told so. Broadcasts standings so all clients reflect it.
local function handle_dnf_command(player_id, player_name)
    if session.phase ~= PHASE.racing then
        MP.SendChatMessage(player_id, "BeamComp: no race in progress")
        return
    end
    local record = session.progress and session.progress[player_id]
    if not record then
        MP.SendChatMessage(player_id, "BeamComp: you are not in this race")
        return
    end
    if record.finished then
        MP.SendChatMessage(player_id, "BeamComp: you already finished")
        return
    end
    if record.dnf then
        MP.SendChatMessage(player_id, "BeamComp: you are already out (DNF)")
        return
    end
    record.dnf = true
    log_info("beamcomp.race", "/dnf by " .. player_name .. " (id " .. tostring(player_id) .. ")")
    broadcast_standings()
    MP.SendChatMessage(player_id, "BeamComp: you are out (DNF)")
    maybe_end_race()
end

local function handle_ping_command(player_id, player_name)
    local player_count = MP.GetPlayerCount()
    log_info("beamcomp", CHAT_COMMAND_PING .. " from " .. player_name .. " (id " .. player_id .. ")")
    MP.SendChatMessage(player_id, "BeamComp v" .. PLUGIN_VERSION .. " -- alive (" .. player_count .. " players online)")
    send_event(player_id, "ping", {
        v = PLUGIN_VERSION,
        players = player_count,
        ts = os.time(),
    })
end

-- /results: toggle the asking player's own finished-results card (ADR-0022). Open to all (not
-- admin-gated) -- it only affects that player's view. The client owns the on/off state; the server
-- just relays the toggle to the sender.
local function handle_results_command(player_id, player_name)
    send_event(player_id, MSG_RESULTS_TOGGLE, {})
    log_info("beamcomp.race", CHAT_COMMAND_RESULTS .. " toggle by " .. player_name)
end

-- /analysis: toggle the asking player's own post-race analysis overlay (ADR-0028). Open to all and
-- per-player like /results -- it only flips that player's local overlay flag; the client owns the state.
local function handle_analysis_command(player_id, player_name)
    send_event(player_id, MSG_ANALYSIS_TOGGLE, {})
    log_info("beamcomp.race", CHAT_COMMAND_ANALYSIS .. " toggle by " .. player_name)
end

-- Open one player's race-setup panel and seed it. Shared by /raceui and by a successful password unlock
-- (ADR-0056), so an unlocked panel fills EXACTLY as a normal open does -- a property of there being one
-- function, not of two send lists being kept equal. Race-blind: the server only relays the open signal,
-- it builds no race data.
--
-- Every caller is downstream of the admin check. Do not call this from anywhere that has not passed it.
function access.open_setup(player_id)
    send_event(player_id, MSG_SETUP_OPEN, {})
    -- Seed the panel with the current championship + tournament state (ADR-0040/0042) so its tournament
    -- section reflects reality on open; subsequent changes arrive via the broadcasts.
    send_event(player_id, champ.MSG, champ.snapshot())
    send_event(player_id, tour.MSG, tour.snapshot())
    -- Same deal for the connected players (ADR-0054): seed the freshly opened panel, then let
    -- identity.broadcast_players keep it current.
    send_event(player_id, identity.MSG_PLAYERS, {players = identity.player_list()})
end

-- A password attempt from the locked race-setup panel (ADR-0056). Verifies, grants or refuses, and
-- answers the panel in every branch so it can never sit waiting.
--
-- THE ONLY WRITER of access.granted. The attempt string is never logged -- the log records WHO tried and
-- THAT it failed, which is what an operator needs, and nothing an onlooker could use.
--
-- Reads the name straight off MP.GetPlayers rather than through player_name_of, exactly as
-- identity.handle_remind does and for the same reason: that local is declared further down the chunk,
-- so a closure created here could not see it. It is the same raw BeamMP name either way, and it is used
-- for the LOG LINE only -- the authorization decision keys on player_id.
function access.handle_unlock(player_id, payload)
    local player_name = MP.GetPlayers()[player_id] or ("id " .. tostring(player_id))

    if not cfg.password then
        -- Not reachable through the UI (a panel only opens locked when a password is set), but a client
        -- may send anything; answer rather than drop, so a stale panel does not hang.
        send_event(player_id, access.MSG_RESULT, {ok = false, reason = "unavailable"})
        return
    end

    if access.granted[player_id] then
        access.open_setup(player_id)
        send_event(player_id, access.MSG_RESULT, {ok = true})
        return
    end

    local state = access.attempts[player_id]
    if state and state.locked_until and now() < state.locked_until then
        send_event(player_id, access.MSG_RESULT, {
            ok = false,
            reason = "lockout",
            wait = math.ceil(state.locked_until - now()),
        })
        log_info("beamcomp.access", "password attempt from " .. player_name .. " ignored: locked out")
        return
    end

    local attempt = type(payload) == "table" and payload.password or nil
    if type(attempt) ~= "string" or access.trim(attempt) ~= cfg.password then
        state = state or {n = 0}
        state.n = state.n + 1
        state.locked_until = nil
        access.attempts[player_id] = state
        if state.n >= access.MAX_TRIES then
            -- Counter reset with the lockout, so the cooldown is the punishment rather than a permanent
            -- one-try-per-minute state the player can never climb out of.
            state.n = 0
            state.locked_until = now() + access.LOCKOUT_SECONDS
            send_event(player_id, access.MSG_RESULT, {
                ok = false,
                reason = "lockout",
                wait = access.LOCKOUT_SECONDS,
            })
            log_info("beamcomp.access", "wrong password from " .. player_name
                .. "; locked out for " .. access.LOCKOUT_SECONDS .. "s")
            return
        end
        send_event(player_id, access.MSG_RESULT, {
            ok = false,
            reason = "wrong",
            triesLeft = access.MAX_TRIES - state.n,
        })
        log_info("beamcomp.access", "wrong password from " .. player_name
            .. " (" .. (access.MAX_TRIES - state.n) .. " tries left)")
        return
    end

    access.granted[player_id] = true
    access.attempts[player_id] = nil
    access.open_setup(player_id)
    send_event(player_id, access.MSG_RESULT, {ok = true})
    log_info("beamcomp.access", player_name .. " unlocked race admin with the server password")
end

-- /raceui: open the asking admin's race-setup panel (ADR-0037). Admin-gated like /race, since the panel
-- starts races; the client assembles the option lists + opens the app on this relay.
local function handle_raceui_command(player_id, player_name)
    if not is_race_admin(player_name, player_id) then
        -- With a server password configured /raceui is the way IN rather than a wall (ADR-0056): open
        -- the panel in its LOCKED state, where the only control is the password box. Without a password
        -- there is nothing to type, so the original refusal stands.
        --
        -- This is an operating gate, not a data boundary. The panel's link-time pulls read client state
        -- the server broadcasts to everyone anyway, and the real boundary is unchanged: all 14
        -- server-side checks re-verify every single action, so a tampered client that forces its own
        -- panel open gains nothing.
        if cfg.password then
            send_event(player_id, access.MSG_LOCKED, {})
            log_info("beamcomp.race", CHAT_COMMAND_RACEUI .. " opened locked for " .. tostring(player_name))
            return
        end
        access.refuse(player_id, "start races")
        log_info("beamcomp.race", "denied " .. CHAT_COMMAND_RACEUI .. " from " .. player_name .. " (not a race admin)")
        return
    end
    access.open_setup(player_id)
    log_info("beamcomp.race", CHAT_COMMAND_RACEUI .. " open by " .. player_name)
end

-- Admin-gated open of the asking player's grid-editor panel (ADR-0037 amendment / ADR-0023). Like
-- /raceui, the server only relays the open signal; the client assembles the race list + opens the app.
-- The grid edit/save/assign messages this panel drives are already admin-gated server-side (ADR-0023).
local function handle_gridui_command(player_id, player_name)
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "edit grids")
        log_info("beamcomp.grid", "denied " .. CHAT_COMMAND_GRIDUI .. " from " .. player_name .. " (not a race admin)")
        return
    end
    send_event(player_id, MSG_GRID_SETUP_OPEN, {})
    log_info("beamcomp.grid", CHAT_COMMAND_GRIDUI .. " open by " .. player_name)
end

-- True if no connected player other than `leaving_id` remains. onPlayerDisconnect may or may
-- not still list the leaving player, so exclude it explicitly.
local function is_server_empty_without(leaving_id)
    for id in pairs(MP.GetPlayers()) do
        if id ~= leaving_id then
            return false
        end
    end
    return true
end

-- A player leaving mid-race is marked DNF so the race can still settle; if they were the last one
-- there is no one to race, so fall back to lobby instead (ADR-0014).
local function on_player_disconnect(player_id)
    -- Drop the connection-scoped name regardless of phase (ADR-0054) -- a player may leave in lobby too,
    -- and with it any join hint still waiting out its grace.
    client_names[player_id] = nil
    identity.pending[player_id] = nil
    -- Drop the password grant and the failed-attempt counter with it (ADR-0056). NOT optional
    -- bookkeeping: BeamMP reuses player ids, so a grant left behind is inherited by whoever takes the
    -- slot next -- and a stale counter would have a fresh joiner start out half-locked-out.
    access.granted[player_id] = nil
    access.attempts[player_id] = nil
    -- Unconditional: the panel lists EVERY connected player, so any leave changes it -- including a
    -- leaver who had a set name. The id is passed because onPlayerDisconnect may or may not still list
    -- him (see is_server_empty_without); without it he could linger in the admin's list.
    identity.broadcast_players(player_id)
    -- Same for the lobby footprint (ADR-0051 round 2); a reconnecting player re-reports it.
    grid_fit.client_sizes[player_id] = nil
    if session.phase == PHASE.lobby then
        return
    end
    if is_server_empty_without(player_id) then
        log_info("beamcomp.race", "all players gone; returning to lobby")
        reset_to_lobby()
        return
    end
    -- The admin who prepared this race left while the field is still waiting for them to start it
    -- (ADR-0021 amendment). Nothing would ever start it, so discard the staged race now instead of
    -- holding everyone frozen on the grid until the abandon window. Deliberately narrow: only the
    -- recorded preparer triggers it, another admin being present does not prevent it. Ahead of the DNF
    -- bookkeeping below -- there is no race left to settle.
    if session.phase == PHASE.staging and player_id == session.staged_by then
        log_info("beamcomp.race", "staging preparer " .. tostring(player_id) .. " left; clearing staged race")
        broadcast_chat("BeamComp: the host who prepared the race left -- race cancelled")
        reset_to_lobby()
        return
    end
    -- A player leaving during the spawning gate is no longer awaited, so the advance can resolve on the
    -- remaining clients rather than waiting out the full timeout (ADR-0006 amendment).
    if session.spawn_pending then
        session.spawn_pending[player_id] = nil
    end
    local record = session.progress and session.progress[player_id]
    if record and not record.finished and not record.dnf then
        record.dnf = true
        log_info("beamcomp.race", "player " .. tostring(player_id) .. " disconnected; DNF")
        broadcast_standings()
        maybe_end_race()
    end
    -- A staged sprint quali (ADR-0044) hands out ramp turns from a queue, and nothing above removes the
    -- leaver from it -- so they would keep being staged for the rest of the window. Purge them from the
    -- rotation after the DNF bookkeeping, and unconditionally: a leaver whose record already reads
    -- finished/dnf skips the block above but must still be dropped from the queue. No-op in every other
    -- phase and in a circuit quali (the purge guards itself).
    quali.purge_driver(player_id)
end

-- Split a chat message into its leading command token and the trimmed remainder.
local function parse_command(message)
    return message:match("^(%S+)%s*(.-)%s*$")
end

-- Whether a command argument contains the literal "all" opt-in token (ADR-0026), case-insensitive. Used
-- by /races to relay the deprecated-source opt-in; /race detects the same token in parse_race_args.
local function has_all_token(argument)
    for token in argument:gmatch("%S+") do
        if token:lower() == "all" then
            return true
        end
    end
    return false
end

local function on_chat_message(player_id, player_name, message)
    if type(message) ~= "string" then
        return
    end

    local command, argument = parse_command(message)

    if command == CHAT_COMMAND_RACE then
        handle_race_command(player_id, player_name, argument)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_RACEEND then
        handle_raceend_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_RACECLEAR then
        handle_raceclear_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_GO or command == CHAT_COMMAND_START
        or command == CHAT_COMMAND_RACESTART then
        handle_start_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_RACES then
        -- Race-blind (ADR-0005): ask the asking client to report its race list; it replies with a
        -- raceList event we post back (handle_race_list). A trailing "all" token (ADR-0026) opts the
        -- deprecated quickrace source into the listing -- relayed as a flag the client interprets.
        send_event(player_id, MSG_LIST_RACES, {all = has_all_token(argument)})
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_CARS then
        -- Vehicle-blind (ADR-0005/0032): ask the asking client to report its installed vehicles; it
        -- replies with a vehicleList event we post back (handle_vehicle_list). A bare /cars lists models;
        -- /cars <model> lists that model's configs -- the model token is relayed verbatim, never read.
        local model = argument:match("^%s*(%S+)")
        send_event(player_id, MSG_LIST_VEHICLES, {model = model})
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_DNF then
        handle_dnf_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_PING then
        handle_ping_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == identity.CHAT_COMMAND then
        identity.handle_command(player_id, player_name, argument)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_RESULTS then
        handle_results_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    -- Layer 3 of the statistics gate (ADR-0053): while off the command is not RECOGNISED at all. Falling
    -- through here reaches the "not a BeamComp command" return at the end of this function, so /analysis
    -- relays into chat as an ordinary message -- exactly like any other unknown command. Suppressing the
    -- echo instead would be the one observable difference that proves the feature exists, which is why
    -- the condition sits on the dispatch rather than inside handle_analysis_command.
    if cfg.stats_enabled and command == CHAT_COMMAND_ANALYSIS then
        handle_analysis_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_RACEUI then
        handle_raceui_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_GRIDUI then
        handle_gridui_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == champ.CHAT_COMMAND then
        champ.handle_command(player_id, player_name, argument)
        return 1  -- suppress the command's own chat echo
    end
    -- not a BeamComp command: return nothing so the message relays normally
end

-- Record an F1 start-reaction report into the car's progress (ADR-0043): reaction = first-movement time -
-- lights-out time (negative = jumped before lights out, positive = launch reaction). A client reports its
-- own car; the race owner proxies an AI by aiId -- accepted only from the owner for a known AI slot, like
-- the checkpoint proxy below. Race-blind (ADR-0005): the client/owner measure it (only they read
-- positions), the server stores it for the standings React column and, when it is negative (a jump),
-- applies the configured time penalty once. build_standings folds the penalty into the final effective
-- time (so it also moves championship/tournament points); the offender's own client shows its JUMP-START
-- banner locally and this broadcasts the chat line for everyone.
function f1.handle_reaction(player_id, payload)
    if session.start_mode ~= "f1" or session.phase ~= PHASE.racing then
        return
    end
    if type(payload) ~= "table" then
        return
    end

    local subject_id = player_id
    if payload.aiId ~= nil then
        if player_id ~= session.owner_id or not is_ai_id(payload.aiId) then
            log_info("beamcomp.race", "reaction from id " .. tostring(player_id)
                .. " ignored: not the owner or bad aiId " .. tostring(payload.aiId))
            return
        end
        subject_id = payload.aiId
    end

    local record = session.progress and session.progress[subject_id]
    if not record or record.dnf or record.reaction ~= nil then
        return  -- no record, terminal (DNF), or already reported -- the reaction is once per race per car
    end

    record.reaction = tonumber(payload.reaction)
    if record.reaction and record.reaction < 0 then
        record.jump_penalty = session.jump_penalty_seconds or f1.DEFAULT_PENALTY
        local name = resolve_identity(subject_id) or record.name or "A driver"
        broadcast_chat(string.format("%s jumped the start -- +%gs penalty", name, record.jump_penalty))
    end
    broadcast_standings()
end

-- Record one client checkpoint report into the reporting player's progress (ADR-0011 path).
-- Advances the completed count, appends the cumulative split time, updates the running total, tracks
-- the current lap, and arms the finish grace (the ADR-0006 racing -> finished seam) on the final
-- crossing. Stays race-blind (ADR-0005): progress and the finish threshold come from the payload
-- seq/count, not race geometry. Ordered by `seq` (the 0-based ordinal in the client's traversal
-- plan -- ADR-0013), not the stable checkpoint index, so a circuit's reordered/repeated indices are
-- accepted; only the next expected seq advances -- duplicates, gaps, out-of-order, a report outside
-- racing, or one from an unseeded player are logged and dropped.
local function handle_checkpoint_report(player_id, payload)
    if type(payload) ~= "table" or type(payload.seq) ~= "number" then
        log_info("beamcomp.net", "checkpoint report from id " .. tostring(player_id)
            .. " ignored: bad payload")
        return
    end

    -- Accept reports while racing and while qualifying (ADR-0041): the quali session uses the same
    -- checkpoint/best-lap path to set lap times, which feed the quali grid. The finish-grace + end-race
    -- hooks below self-guard on the racing phase, so a quali crossing never finishes the race.
    if session.phase ~= PHASE.racing and session.phase ~= PHASE.qualifying then
        log_info("beamcomp.race", "checkpoint report from id " .. tostring(player_id)
            .. " ignored: not racing (phase " .. session.phase .. ")")
        return
    end

    -- Route an AI-proxied report (ADR-0036): the race owner reports a synthetic AI slot's crossing with
    -- aiId set. Accept it only from the owner and only for a known AI slot -- otherwise a client could
    -- spoof another participant's progress. A normal report keys on the sender's own id.
    local subject_id = player_id
    if payload.aiId ~= nil then
        if player_id ~= session.owner_id or not is_ai_id(payload.aiId) then
            log_info("beamcomp.race", "ai checkpoint from id " .. tostring(player_id)
                .. " ignored: not the owner or bad aiId " .. tostring(payload.aiId))
            return
        end
        subject_id = payload.aiId
    end

    local record = session.progress and session.progress[subject_id]
    if not record then
        log_info("beamcomp.race", "checkpoint report for " .. tostring(subject_id)
            .. " ignored: no race record")
        return
    end

    -- A finished or DNF player is terminal (ADR-0014): drop further reports so a DNF'd player who keeps
    -- driving can never progress or set finished. (Finished players' clients stop sending; this also
    -- guards a DNF'd player whose detector is still armed.)
    if record.finished or record.dnf then
        log_info("beamcomp.race", "checkpoint report for " .. tostring(subject_id)
            .. " ignored: already " .. (record.finished and "finished" or "DNF"))
        return
    end

    -- Coerce to integers: a fractional seq/count from a bad client would break the %d formatting
    -- (Lua 5.3 rejects non-integer floats) and the ordering compare. count may be absent, in which
    -- case finish cannot be detected and only progress is tracked. index/lap are optional metadata
    -- (display + logging); seq is the ordering key (ADR-0013).
    local seq = math.floor(payload.seq)
    local count = (type(payload.count) == "number") and math.floor(payload.count) or nil
    local time = tonumber(payload.time) or 0
    local lap = (type(payload.lap) == "number") and math.floor(payload.lap) or nil
    local index = (type(payload.index) == "number") and math.floor(payload.index) or nil
    -- Client-reported best lap so far (circuit; ADR-0022). Relayed in standings, never interpreted --
    -- the server stays race-blind (ADR-0005), it just stores the latest number this player sent.
    local best_lap = tonumber(payload.bestLap)
    -- Client-reported run-up: the gun -> start/finish line time (lap 1's real start, circuit only;
    -- ADR-0022). Same deal as best_lap -- stored and relayed verbatim for the analysis overlay's S0
    -- column / clean lap-1 derivation (ADR-0028), never interpreted server-side (ADR-0005).
    local run_up = tonumber(payload.runUp)

    if seq ~= record.completed then
        log_info("beamcomp.race", string.format(
            "%s out-of-order checkpoint: got seq %d, expected %d",
            tostring(subject_id), seq, record.completed))
        return
    end

    record.completed = record.completed + 1
    if count then
        record.count = count
    end
    if lap then
        record.lap = lap
    end
    if best_lap then
        record.best_lap = best_lap
    end
    if run_up then
        record.run_up = run_up
    end
    record.splits[record.completed] = time
    record.total_time = time

    local final = record.count and (record.completed >= record.count)
    if final then
        record.finished = true
        start_finish_grace()
    end

    local progress_label = record.count
        and string.format("%d/%d", record.completed, record.count)
        or tostring(record.completed)
    log_info("beamcomp.race", string.format("%s checkpoint %s%s%s @ %.2fs%s",
        tostring(subject_id), progress_label,
        lap and string.format(" lap %d", lap) or "",
        index and string.format(" (cp %d)", index) or "",
        time, final and " (final)" or ""))

    -- Staged sprint quali (Round 11): fold this scored crossing into the driver's max progress pair --
    -- and the field-wide per-sector best splits (Round 13) -- BEFORE the queue-board broadcast below
    -- reads them. Every scored crossing counts -- final ones too, and those of a run later aborted by a
    -- recover/forced requeue (the fold is per crossing, so an abort can never lose banked progress).
    -- Circuit quali / normal race: gated off. (The progress stamp that used to sit here is now taken
    -- unconditionally further up, since the racing finish grace needs it too.)
    if quali.is_staged() and session.phase == PHASE.qualifying then
        quali.note_cp_progress(subject_id)
        quali.note_sector_best(subject_id)
    end
    broadcast_standings()
    -- Staged sprint quali (Round 6): refresh the holding-queue board on every crossing, so the live-timing
    -- table shows the running driver's progress in real time -- including through the finish-your-run grace,
    -- where the window-gated release path no longer broadcasts. The final crossing is covered by finish_run
    -- below (it folds the best, then broadcasts). Circuit quali / normal race: no-op.
    if not final and quali.is_staged() and session.phase == PHASE.qualifying then
        quali.broadcast_queue()
    end
    if final then
        maybe_end_race()
        -- Staged sprint quali (ADR-0044): a completed Start->Ziel run folds its time into the best and
        -- requeues the driver for another attempt (resetting their record). Done after the standings
        -- broadcast so the finished run shows once, then the record resets for the next run. No-op for the
        -- circuit quali (it keeps lapping the same detector) and a normal race.
        if quali.is_staged() and session.phase == PHASE.qualifying then
            quali.finish_run(subject_id)
        end
    end
end

-- Relay the owner's AI-vehicle map to every client (ADR-0036): the owner spawned the AI cars and resolved
-- their BeamMP-synced ids, and the other clients need that set to label the cars "AI N" and suppress the
-- owner's nametag on them (their own race car must keep its tag). Accepted only from the active race's
-- owner; the opaque entries are rebroadcast verbatim (race-blind, ADR-0005 -- the server reads no vehicle).
local function handle_ai_map(player_id, payload)
    if session.phase == PHASE.lobby or player_id ~= session.owner_id then
        log_info("beamcomp.net", "aiMap from id " .. tostring(player_id)
            .. " ignored: not the active race owner")
        return
    end
    local entries = type(payload) == "table" and payload.entries or nil
    if type(entries) ~= "table" then
        return
    end
    broadcast_event(MSG_AI_MAP, {entries = entries})
end

-- Post which AI route variant the owner's AI actually got, to all players' chat (ADR-0036 Step-3). The
-- owner drives the AI and resolves the route (authored navgraph path / navgraph snap / span), so only the
-- owner reports it; the server just relays the line (race-blind, reads no geometry). Lets players see at
-- race start whether the authored aiRace line was used or it fell back to the snap.
local function handle_ai_route_notice(player_id, payload)
    if session.phase == PHASE.lobby or player_id ~= session.owner_id then
        return
    end
    local source = type(payload) == "table" and type(payload.source) == "string" and payload.source or nil
    if not source then
        return
    end
    local per_lap = tonumber(type(payload) == "table" and payload.perLap) or 0
    broadcast_chat(string.format("BeamComp: AI route source=%s: %d waypoint(s)/lap", source, per_lap))
end

-- Post a client's /races reply to that player. The client (which owns race knowledge, ADR-0005) built
-- the chat lines and sent them back (ADR-0011); the server only relays them. `player_id` is the
-- responder -- i.e. the player who ran /races -- so no request tracking is needed. Capped to
-- RACE_LIST_MAX_LINES so a misbehaving client cannot flood chat.
local function handle_race_list(player_id, payload)
    local lines = type(payload) == "table" and payload.lines or nil
    if type(lines) ~= "table" then
        log_info("beamcomp.net", "raceList from id " .. tostring(player_id) .. " ignored: no lines")
        return
    end
    for i, line in ipairs(lines) do
        if i > RACE_LIST_MAX_LINES then
            break
        end
        if type(line) == "string" then
            MP.SendChatMessage(player_id, line)
        end
    end
end

-- Post a client's /cars reply to that player (ADR-0032). The client owns all vehicle knowledge
-- (ADR-0005), so it built the chat lines and sent them back (ADR-0011); the server only relays them.
-- `player_id` is the responder -- the player who ran /cars -- so no request tracking is needed. Capped
-- to VEHICLE_LIST_MAX_LINES so a misbehaving client cannot flood chat. Mirrors handle_race_list.
local function handle_vehicle_list(player_id, payload)
    local lines = type(payload) == "table" and payload.lines or nil
    if type(lines) ~= "table" then
        log_info("beamcomp.net", "vehicleList from id " .. tostring(player_id) .. " ignored: no lines")
        return
    end
    for i, line in ipairs(lines) do
        if i > VEHICLE_LIST_MAX_LINES then
            break
        end
        if type(line) == "string" then
            MP.SendChatMessage(player_id, line)
        end
    end
end

-- A connected player's display name by id, or nil if not present.
local function player_name_of(player_id)
    return MP.GetPlayers()[player_id]
end

-- Send a map's saved grids to one client (ADR-0023 amendment 2026-07-27): {grids = {{name, race,
-- isDefault}, ...}}, sorted by race then name. The whole map travels in ONE reply so all three consumers
-- can filter locally -- the setup panel narrows it to the selected race, the grid editor splits it into
-- "this race" plus the rest of the map, and the GE console groups it for its toast -- and so switching
-- race in a panel stays a local, synchronous operation instead of a new round-trip. Shared by the list
-- request and the delete echo, so a panel always sees the post-change truth.
-- Lives here rather than with the other grid_store helpers because it captures send_event/MSG_GRID_LIST,
-- which are declared further up the chunk than those.
function grid_store.send_grid_list(player_id, map)
    ensure_grids_loaded()
    local entries = {}
    local map_grids = type(map) == "string" and grid_store.grids[map] or nil
    local map_defaults = type(map) == "string" and grid_store.defaults[map] or nil
    if type(map_grids) == "table" then
        for race_name, race_grids in pairs(map_grids) do
            if type(race_grids) == "table" then
                local default_name = type(map_defaults) == "table" and map_defaults[race_name] or nil
                for name in pairs(race_grids) do
                    entries[#entries + 1] = {
                        name = name,
                        race = race_name,
                        isDefault = name == default_name,
                    }
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.race ~= b.race then
            return a.race < b.race
        end
        return a.name < b.name
    end)
    send_event(player_id, MSG_GRID_LIST, {grids = entries})
end

-- Store a named grid sent by the in-game editor (ADR-0023). Admin-gated like /race (ADR-0016): only a
-- race admin may write the shared grids file. The server validates shape but never interprets the param
-- numbers (race-blind, ADR-0005). Payload: {map, race, name, forward = <params>, reverse = <params>?}.
local function handle_grid_save(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "save grids")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.name) ~= "string" or payload.name == ""
        or type(payload.race) ~= "string" or payload.race == ""
        or type(payload.forward) ~= "table" then
        MP.SendChatMessage(player_id, "BeamComp: grid save rejected -- bad data")
        log_info("beamcomp.grid", "gridSave from id " .. tostring(player_id) .. " rejected: bad payload")
        return
    end

    -- The race the grid was authored against is its OWNER (the store key), and it is also what lets
    -- beamcomp_grid_edit re-anchor a reopened grid to the right start line (ADR-0023 amendment).
    local record = {forward = payload.forward}
    if type(payload.reverse) == "table" then
        record.reverse = payload.reverse
    end
    -- The authored field size (ADR-0023 amendment 2026-08-02), coerced rather than relayed so the stored
    -- number is always usable whatever a client sent -- and so a client too old to send one stores the
    -- default instead of a record the migration would later have to fix.
    record.previewCount = grid_store.preview_count_of(payload)

    local ok, path, promoted = save_grid(payload.map, payload.race, payload.name, record)
    if ok then
        local message = "BeamComp: saved grid '" .. payload.name .. "' for " .. payload.race
        if promoted == payload.name then
            -- The race had no (valid) default, so this grid just became it. Say so: nothing else in the
            -- editor surfaces that automatic assignment.
            message = message .. " -- it is now this race's default grid"
        end
        MP.SendChatMessage(player_id, message)
        log_info("beamcomp.grid", string.format("saved grid '%s' for race '%s' on map '%s' (%s) by %s",
            payload.name, payload.race, payload.map, tostring(path), player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write grids file")
    end
end

-- Set a race's default grid, sent by the editor (ADR-0023). Admin-gated. The grid must already exist for
-- that race. Payload: {map, race, name}.
local function handle_grid_assign(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "assign grids")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.race) ~= "string" or payload.race == ""
        or type(payload.name) ~= "string" or payload.name == "" then
        MP.SendChatMessage(player_id, "BeamComp: grid assign rejected -- bad data")
        return
    end

    ensure_grids_loaded()
    local map_grids = grid_store.grids[payload.map]
    local race_grids = type(map_grids) == "table" and map_grids[payload.race] or nil
    if type(race_grids) ~= "table" or type(race_grids[payload.name]) ~= "table" then
        MP.SendChatMessage(player_id, "BeamComp: no grid '" .. payload.name .. "' saved for " .. payload.race)
        return
    end

    local ok = assign_default(payload.map, payload.race, payload.name)
    if ok then
        MP.SendChatMessage(player_id, string.format("BeamComp: '%s' is now the default grid for %s",
            payload.name, payload.race))
        log_info("beamcomp.grid", string.format("assigned grid '%s' as default for race '%s' on map '%s' by %s",
            payload.name, payload.race, payload.map, player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write grids file")
    end
end

-- Delete one of a race's saved grids, sent by the editor (ADR-0023). Admin-gated like save/assign.
-- Replies with the map's updated grid list (MSG_GRID_LIST) so the panel's dropdown refreshes without a
-- second round-trip. Payload: {map, race, name}.
local function handle_grid_delete(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "delete grids")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.race) ~= "string" or payload.race == ""
        or type(payload.name) ~= "string" or payload.name == "" then
        MP.SendChatMessage(player_id, "BeamComp: grid delete rejected -- bad data")
        return
    end

    local existed, ok, promoted = delete_grid(payload.map, payload.race, payload.name)
    if not existed then
        MP.SendChatMessage(player_id, "BeamComp: no grid '" .. payload.name .. "' saved for " .. payload.race)
    elseif ok then
        local message = "BeamComp: deleted grid '" .. payload.name .. "' for " .. payload.race
        if promoted then
            -- The deleted grid was this race's default, so a survivor took over (a race with grids always
            -- has exactly one default).
            message = message .. " -- '" .. promoted .. "' is now its default grid"
        end
        MP.SendChatMessage(player_id, message)
        log_info("beamcomp.grid", string.format("deleted grid '%s' for race '%s' on map '%s' by %s",
            payload.name, payload.race, payload.map, player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write grids file")
    end

    -- Always echo the current list so the editor's dropdown reflects the post-delete state.
    grid_store.send_grid_list(player_id, payload.map)
end

-- Return a saved grid's data so the editor can reopen it (ADR-0023). Read-only, so ungated like
-- /races. Payload: {map, race, name} -- the name alone no longer identifies a grid. A missing field or an
-- unknown grid replies found = false rather than an error. The race is echoed back from the request (it
-- is the store key, not a record field), so the editor can re-anchor the reopened grid.
local function handle_grid_fetch(player_id, payload)
    if type(payload) ~= "table" or type(payload.map) ~= "string" or type(payload.race) ~= "string"
        or type(payload.name) ~= "string" then
        send_event(player_id, MSG_GRID_DATA, {found = false})
        return
    end
    ensure_grids_loaded()
    local map_grids = grid_store.grids[payload.map]
    local race_grids = type(map_grids) == "table" and map_grids[payload.race] or nil
    local record = type(race_grids) == "table" and race_grids[payload.name] or nil
    if type(record) ~= "table" then
        send_event(player_id, MSG_GRID_DATA, {name = payload.name, race = payload.race, found = false})
        return
    end
    send_event(player_id, MSG_GRID_DATA, {
        name = payload.name,
        found = true,
        forward = record.forward,
        reverse = record.reverse,
        race = payload.race,
        -- The authored field size the editor restores (ADR-0023 amendment 2026-08-02). Defaulted here,
        -- so a record that predates the field (or one the migration could not touch) reopens at 16
        -- instead of arriving as nil.
        previewCount = grid_store.preview_count_of(record),
    })
end

-- Return the saved grids for a map (ADR-0023). Read-only; see grid_store.send_grid_list for the shape.
local function handle_grid_list_request(player_id, payload)
    grid_store.send_grid_list(player_id, type(payload) == "table" and payload.map or nil)
end

-- Preset handlers (ADR-0037 amendment). Attached to grid_store, not top-level locals (200/200 ceiling);
-- structured like the grid handlers above -- admin gate on the mutations, opaque form blob throughout.

-- Send a map's saved preset names (sorted) to one client. Shared by save/delete (echo the post-change
-- list) and the list request, so the panel's dropdown is always server-authoritative, not local state.
function grid_store.send_preset_list(player_id, map)
    grid_store.ensure_presets_loaded()
    local names = {}
    local map_presets = type(map) == "string" and grid_store.presets[map] or nil
    if type(map_presets) == "table" then
        for name in pairs(map_presets) do
            names[#names + 1] = name
        end
        table.sort(names)
    end
    send_event(player_id, grid_store.MSG_PRESET_LIST, {names = names})
end

-- Save a named race-setup preset for a map, sent by the panel. Admin-gated like gridSave. The form is an
-- opaque JSON string stored verbatim (race-blind, ADR-0005). Echoes the updated name list. Payload:
-- {map, name, form}.
function grid_store.handle_preset_save(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "save presets")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.name) ~= "string" or payload.name == ""
        or type(payload.form) ~= "string" or payload.form == "" then
        MP.SendChatMessage(player_id, "BeamComp: preset save rejected -- bad data")
        log_info("beamcomp.preset", "presetSave from id " .. tostring(player_id) .. " rejected: bad payload")
        return
    end

    grid_store.ensure_presets_loaded()
    if type(grid_store.presets[payload.map]) ~= "table" then
        grid_store.presets[payload.map] = {}
    end
    grid_store.presets[payload.map][payload.name] = payload.form

    local ok, path = grid_store.write_presets()
    if ok then
        MP.SendChatMessage(player_id, "BeamComp: saved preset '" .. payload.name .. "' for " .. payload.map)
        log_info("beamcomp.preset", string.format("saved preset '%s' for map '%s' (%s) by %s",
            payload.name, payload.map, tostring(path), player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write presets file")
    end

    grid_store.send_preset_list(player_id, payload.map)
end

-- Delete a saved preset for a map, sent by the panel. Admin-gated. Echoes the updated name list so the
-- dropdown refreshes. Payload: {map, name}.
function grid_store.handle_preset_delete(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "delete presets")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.name) ~= "string" or payload.name == "" then
        MP.SendChatMessage(player_id, "BeamComp: preset delete rejected -- bad data")
        return
    end

    grid_store.ensure_presets_loaded()
    local map_presets = grid_store.presets[payload.map]
    if type(map_presets) ~= "table" or map_presets[payload.name] == nil then
        MP.SendChatMessage(player_id, "BeamComp: no preset '" .. payload.name .. "' saved for " .. payload.map)
    else
        map_presets[payload.name] = nil
        if grid_store.write_presets() then
            MP.SendChatMessage(player_id, "BeamComp: deleted preset '" .. payload.name .. "' for " .. payload.map)
            log_info("beamcomp.preset", string.format("deleted preset '%s' for map '%s' by %s",
                payload.name, payload.map, player_name))
        else
            MP.SendChatMessage(player_id, "BeamComp: could not write presets file")
        end
    end

    grid_store.send_preset_list(player_id, payload.map)
end

-- Return a saved preset's opaque form blob so the panel can load it. Read-only, ungated like the grid
-- fetch. A missing map/name or unknown preset replies found = false. Payload: {map, name}.
function grid_store.handle_preset_fetch(player_id, payload)
    if type(payload) ~= "table" or type(payload.map) ~= "string" or type(payload.name) ~= "string" then
        send_event(player_id, grid_store.MSG_PRESET_DATA, {found = false})
        return
    end
    grid_store.ensure_presets_loaded()
    local map_presets = grid_store.presets[payload.map]
    local form = type(map_presets) == "table" and map_presets[payload.name] or nil
    if type(form) ~= "string" then
        send_event(player_id, grid_store.MSG_PRESET_DATA, {name = payload.name, found = false})
        return
    end
    send_event(player_id, grid_store.MSG_PRESET_DATA, {
        name = payload.name,
        found = true,
        form = form,
    })
end

-- Return the saved preset names for a map. Read-only, sorted for a stable listing. Payload: {map}.
function grid_store.handle_preset_list_request(player_id, payload)
    local map = type(payload) == "table" and payload.map or nil
    grid_store.send_preset_list(player_id, map)
end

-- Coerce the settings UI's decoded overrides into the shape begin_race_request/start_race expect (the
-- parse_race_args output, ADR-0037). The payload is an untrusted network boundary, so every field is
-- type-checked and clamped; unknown fields are dropped. Most values are opaque relay (race-blind,
-- ADR-0005) -- the issuer client validates them against geometry -- but the few the server itself reads
-- (order.mode, ai.count, assists.*) must be well-formed so a malformed payload cannot crash it.
local function sanitize_overrides(raw)
    if type(raw) ~= "table" then
        raw = {}
    end
    local laps = tonumber(raw.laps)
    local overrides = {
        force = raw.force == true,
        all = raw.all == true,
        mode = (raw.mode == "sprint" or raw.mode == "circuit") and raw.mode or nil,
        direction = (raw.direction == "reverse") and "reverse" or nil,
        laps = laps and math.max(1, math.floor(laps)) or nil,
        car = (type(raw.car) == "string" and raw.car ~= "") and raw.car or nil,
        maxhp = tonumber(raw.maxhp),
        maxpwr = tonumber(raw.maxpwr),
        maxkg = tonumber(raw.maxkg),
        minkg = tonumber(raw.minkg),
        grid = (type(raw.grid) == "string" and raw.grid ~= "") and raw.grid or nil,
        -- F1 light start (ADR-0043): only "f1" survives; nil = the default lock countdown.
        startMode = (raw.startMode == "f1") and "f1" or nil,
    }

    -- car=random composable player-policy axes (ADR-0032 amendment): opaque booleans relayed verbatim to the
    -- client's respawn_own_at resolver (race-blind, ADR-0005 -- the server never maps them to a model or
    -- weight). Kept only as booleans; absent/non-bool drops (the client then defaults both ON). Meaningful
    -- only for car=random, but relayed regardless of the car value -- the client ignores them otherwise.
    if type(raw.randomTrim) == "boolean" then
        overrides.randomTrim = raw.randomTrim
    end
    if type(raw.noBigCars) == "boolean" then
        overrides.noBigCars = raw.noBigCars
    end

    -- Assists default both ON at the default hold (parse_race_args parity); the UI may turn either off or
    -- set a custom hold.
    local a = type(raw.assists) == "table" and raw.assists or {}
    overrides.assists = {
        recoverEnabled = a.recoverEnabled ~= false,
        recoverHoldSeconds = tonumber(a.recoverHoldSeconds) or ASSIST_DEFAULT_HOLD_SECONDS,
        repairEnabled = a.repairEnabled ~= false,
        repairHoldSeconds = tonumber(a.repairHoldSeconds) or ASSIST_DEFAULT_HOLD_SECONDS,
    }

    -- Start order (ADR-0033): only a known mode survives; rev is a flag on a directional mode.
    if type(raw.order) == "table" and ORDER_MODES[raw.order.mode] then
        overrides.order = {mode = raw.order.mode, rev = raw.order.rev == true}
        -- The qualifying's OWN start order (ADR-0044 amendment, quali-start-order): only for order=quali,
        -- only a known value survives, default random -- so a chat /race order=quali (no field) stays
        -- byte-identical. It seeds the quali provisional grid (build_slots), and the staged launch queue
        -- follows that grid (quali.start_session), so the spawn slot and the launch order agree.
        if raw.order.mode == "quali" then
            overrides.order.qualiStart = quali.normalize_start(raw.order.qualiStart)
        end
    end

    -- Qualifying length (ADR-0041): a UI-supplied minutes value for order=quali, clamped to bounds.
    local quali_minutes = tonumber(raw.qualiMinutes)
    if quali_minutes then
        overrides.quali_duration = quali.clamp(quali_minutes * 60)
    end

    -- F1 jump-start penalty (ADR-0043): a UI-supplied seconds value, floored at 0; nil lets start_race default it.
    local jump_penalty = tonumber(raw.jumpPenaltySeconds)
    if jump_penalty then
        overrides.jumpPenaltySeconds = math.max(0, jump_penalty)
    end

    -- AI opponents (ADR-0036): present only when a count is given. Count clamped to [1, MAX_AI]; preset
    -- resolved against the known set; vehicle + raw driving params relayed verbatim to the owner. explicit
    -- defaults true (the UI carries a count) but may be set false to take the race's content-default count.
    if type(raw.ai) == "table" and raw.ai.count ~= nil then
        local count = math.max(1, math.min(MAX_AI, math.floor(tonumber(raw.ai.count) or DEFAULT_AI_COUNT)))
        local ai = {count = count, explicit = raw.ai.explicit ~= false}
        local preset = type(raw.ai.preset) == "string" and resolve_keyword(raw.ai.preset, AI_PRESET_LIST)
        if preset then
            ai.preset = preset
        end
        if type(raw.ai.car) == "string" and raw.ai.car ~= "" then
            ai.car = raw.ai.car
        end
        if type(raw.ai.params) == "table" then
            local params = {}
            for _, key in ipairs({"aggr", "skill", "rubber"}) do
                local value = tonumber(raw.ai.params[key])
                if value then
                    params[key] = math.max(0, math.min(1, value))
                end
            end
            if type(raw.ai.params.avoid) == "boolean" then
                params.avoid = raw.ai.params.avoid
            end
            if raw.ai.params.route == "snap" or raw.ai.params.route == "direct" then
                params.route = raw.ai.params.route
            end
            if next(params) then
                ai.params = params
            end
        end
        -- Composable random-vehicle axes (AI random picker): randomTrim = stock vs random trim, noBigCars =
        -- exclude big/heavy vehicles. Opaque booleans relayed to the owner's resolver (race/ai.lua),
        -- race-blind (ADR-0005) -- the server never maps them to a model or weight.
        if type(raw.ai.randomTrim) == "boolean" then
            ai.randomTrim = raw.ai.randomTrim
        end
        if type(raw.ai.noBigCars) == "boolean" then
            ai.noBigCars = raw.ai.noBigCars
        end
        -- Named AI roster (ADR-0047): opaque {name, car?} entries relayed race-blind (ADR-0005). The
        -- Create gate makes the roster the source of truth, so the AI count follows its length; entries
        -- past MAX_AI drop. Absent on the typed-chat path (parse_race_args never builds a roster).
        if type(raw.ai.roster) == "table" then
            local roster = {}
            for _, entry in ipairs(raw.ai.roster) do
                if #roster >= MAX_AI then
                    break
                end
                if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
                    roster[#roster + 1] = {
                        name = entry.name,
                        car = (type(entry.car) == "string" and entry.car ~= "") and entry.car or nil,
                        color = (type(entry.color) == "string" and entry.color ~= "")
                            and entry.color or nil,
                    }
                end
            end
            if #roster > 0 then
                ai.roster = roster
                ai.count = #roster
            end
        end
        overrides.ai = ai
    end

    return overrides
end

-- The settings UI's structured race request (ADR-0037): {race, overrides}. Resolve the issuer's name for
-- the admin gate, coerce the overrides to a safe shape, and hand off to the shared kickoff -- the same
-- validation handshake + start path the typed /race uses. Race-blind: overrides are relayed, not parsed.
local function handle_start_race(player_id, payload)
    if type(payload) ~= "table" or type(payload.race) ~= "string" or payload.race == "" then
        MP.SendChatMessage(player_id, "BeamComp: race setup rejected -- no race selected")
        return
    end
    local player_name = player_name_of(player_id)
    if not player_name then
        return
    end
    begin_race_request(player_id, player_name, payload.race, sanitize_overrides(payload.overrides))
end

-- The settings UI's "Start Race" (ADR-0037): end the staging wait and begin the countdown -- the /go
-- equivalent. Resolves the issuer's name and reuses handle_start_command, which admin-gates and checks the
-- staging phase, so a stray raceGo outside staging is a harmless no-op message.
local function handle_race_go(player_id)
    local player_name = player_name_of(player_id)
    if not player_name then
        return
    end
    handle_start_command(player_id, player_name)
end

-- The setup panel's championship control (ADR-0037/0040): {action, preset, order}. Resolve the issuer's
-- name and route through the same handler the chat command uses by reconstructing an equivalent
-- /championship argument -- so the panel reuses one admin-gated mutation path (no duplicated logic).
function champ.handle_cmd(player_id, payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then
        return
    end
    local player_name = player_name_of(player_id)
    if not player_name then
        return
    end
    local parts = {payload.action}
    if type(payload.preset) == "string" then
        parts[#parts + 1] = "points=" .. payload.preset
    end
    if type(payload.order) == "string" then
        parts[#parts + 1] = "order=" .. payload.order
    end
    if tonumber(payload.qualiMinutes) then
        parts[#parts + 1] = "quali=" .. math.floor(tonumber(payload.qualiMinutes))
    end
    champ.handle_command(player_id, player_name, table.concat(parts, " "))
end

-- Handle the setup panel's tournamentCmd (ADR-0042) -- the only entry point, since class-drop is panel-only
-- (no chat command). action start/set/reset; classes is the ordered fast->slow spec list (each {car} or a
-- {maxhp}/{maxpwr} cap), order the grid choice. Mutations are admin-gated (ADR-0016). Starting a tournament
-- ends any active points-championship -- the two formats are mutually exclusive (champ is in scope here, so
-- the cross-reset lives at the call site, not inside tour.start).
function tour.handle_cmd(player_id, payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then
        return
    end
    local player_name = player_name_of(player_id)
    if not player_name then
        return
    end
    if not is_race_admin(player_name, player_id) then
        access.refuse(player_id, "manage tournaments")
        log_info("beamcomp.tour", "denied tournamentCmd from " .. player_name .. " (not a race admin)")
        return
    end

    local action = payload.action
    if action == "start" then
        champ.reset()  -- mutual exclusion: only one tournament format runs at a time (ADR-0042)
        local count = tour.start(payload.classes, payload.order)
        if not count then
            MP.SendChatMessage(player_id, string.format(
                "BeamComp: need at least %d valid classes to start a tournament", tour.MIN_CLASSES))
            return
        end
        champ.broadcast()  -- tell clients the championship (if it was on) is now off
        tour.broadcast()
        broadcast_chat(string.format("BeamComp: class-drop tournament started -- %d classes", count))
        log_info("beamcomp.tour", string.format("tournament started by %s (%d classes)", player_name, count))
        return
    end

    if action == "reset" then
        if not tour.is_active() then
            MP.SendChatMessage(player_id, "BeamComp: no tournament active")
            return
        end
        local winner = tour.winner_text()
        tour.reset()
        tour.broadcast()
        broadcast_chat(winner and ("BeamComp: tournament over -- winner: " .. winner)
            or "BeamComp: tournament reset")
        log_info("beamcomp.tour", "tournament reset by " .. player_name)
        return
    end

    -- action == "set": a live class/order change on a running tournament (non-retroactive on class_index).
    if not tour.is_active() then
        MP.SendChatMessage(player_id, "BeamComp: no tournament active -- start one first")
        return
    end
    tour.set(payload.classes, payload.order)
    tour.broadcast()
    MP.SendChatMessage(player_id, "BeamComp: tournament updated")
end

-- Receive a client -> server { type, payload } envelope on EVENT_CHANNEL (ADR-0011). The server
-- hand-decodes (it does not load the shared envelope module, ADR-0004); `data` arrives as a JSON
-- string. A non-string `data` means the handler arg order differs from the assumed (player_id, data)
-- -- log both arg types so the real signature is visible in-game (the one runtime-verification point).
local function handle_client_event(player_id, data)
    if type(data) ~= "string" then
        log_info("beamcomp.net", "client event: unexpected arg types (arg1=" .. type(player_id)
            .. ", arg2=" .. type(data) .. ")")
        return
    end

    local ok, decoded = pcall(Util.JsonDecode, data)
    if not ok or type(decoded) ~= "table" or type(decoded.type) ~= "string" then
        log_info("beamcomp.net", "dropped malformed client event from id " .. tostring(player_id))
        return
    end

    if decoded.type == MSG_CHECKPOINT then
        handle_checkpoint_report(player_id, decoded.payload)
    elseif decoded.type == MSG_AI_MAP then
        handle_ai_map(player_id, decoded.payload)
    elseif decoded.type == MSG_AI_ROUTE_NOTICE then
        handle_ai_route_notice(player_id, decoded.payload)
    elseif decoded.type == MSG_RACE_LIST then
        handle_race_list(player_id, decoded.payload)
    elseif decoded.type == MSG_VEHICLE_LIST then
        handle_vehicle_list(player_id, decoded.payload)
    elseif decoded.type == MSG_RACE_VALIDATION then
        handle_race_validation(player_id, decoded.payload)
    elseif decoded.type == track.MSG_NEED then
        track.handle_need(player_id, decoded.payload)
    elseif decoded.type == track.MSG_UPLOAD then
        track.handle_upload(player_id, decoded.payload)
    elseif decoded.type == MSG_SPAWN_READY then
        handle_spawn_ready(player_id, decoded.payload)
    elseif decoded.type == MSG_CLIENT_INFO then
        handle_client_info(player_id, decoded.payload)
    elseif decoded.type == MSG_CLIENT_IDENTITY then
        handle_client_identity(player_id, decoded.payload)
    elseif decoded.type == identity.MSG_REMIND then
        identity.handle_remind(player_id)
    elseif decoded.type == access.MSG_UNLOCK then
        -- A password attempt from the locked race-setup panel (ADR-0056). Deliberately NOT gated on
        -- is_race_admin: this is the one message whose whole job is to be sent by somebody who is not
        -- an admin yet.
        access.handle_unlock(player_id, decoded.payload)
    elseif decoded.type == grid_fit.MSG_SIZE then
        grid_fit.handle_size(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_SAVE then
        handle_grid_save(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_ASSIGN then
        handle_grid_assign(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_DELETE then
        handle_grid_delete(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_FETCH then
        handle_grid_fetch(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_LIST_REQ then
        handle_grid_list_request(player_id, decoded.payload)
    elseif decoded.type == grid_store.MSG_PRESET_SAVE then
        grid_store.handle_preset_save(player_id, decoded.payload)
    elseif decoded.type == grid_store.MSG_PRESET_DELETE then
        grid_store.handle_preset_delete(player_id, decoded.payload)
    elseif decoded.type == grid_store.MSG_PRESET_FETCH then
        grid_store.handle_preset_fetch(player_id, decoded.payload)
    elseif decoded.type == grid_store.MSG_PRESET_LIST_REQ then
        grid_store.handle_preset_list_request(player_id, decoded.payload)
    elseif decoded.type == MSG_START_RACE then
        handle_start_race(player_id, decoded.payload)
    elseif decoded.type == MSG_RACE_GO then
        handle_race_go(player_id)
    elseif decoded.type == champ.MSG_CMD then
        champ.handle_cmd(player_id, decoded.payload)
    elseif decoded.type == tour.MSG_CMD then
        tour.handle_cmd(player_id, decoded.payload)
    elseif decoded.type == f1.MSG_REACTION then
        f1.handle_reaction(player_id, decoded.payload)
    elseif decoded.type == quali.MSG_RESET then
        -- Staged sprint quali (ADR-0044): a player hit recover -> requeue to the back for a new attempt.
        quali.handle_reset(player_id, decoded.payload)
    elseif decoded.type == quali.MSG_CLEARED then
        -- Staged sprint quali (ADR-0044/Round4): the launched driver cleared the ramp (>=15 m gate).
        quali.handle_cleared(player_id, decoded.payload)
    elseif decoded.type == stall.MSG then
        -- A client-measured movement verdict for its own car, or one of the owner's AI: the second input
        -- to the liveness predicate both finish graces read (ADR-0014 amendment).
        stall.handle_report(player_id, decoded.payload)
    elseif decoded.type == "raceControl" then
        -- Panel-triggered race stop (ADR-0038 amendment): delegate to the existing chat-command handlers so
        -- the admin gate, phase guards, chat replies and logging are reused. Inlined (not a named handler)
        -- to add no top-level local under the 200/200 ceiling.
        local name = player_name_of(player_id)
        local action = type(decoded.payload) == "table" and decoded.payload.action or nil
        if name then
            if action == "cancel" then
                handle_raceclear_command(player_id, name)
            elseif action == "end" then
                handle_raceend_command(player_id, name)
            end
        end
    else
        log_info("beamcomp.net", "no handler for client event type=" .. decoded.type)
    end
end

local function on_init()
    log_info("beamcomp", "server plugin loaded v" .. PLUGIN_VERSION)
    -- Seed the RNG for the random / no-source-fallback start orders (ADR-0033).
    math.randomseed(os.time())
    load_config()
    -- Every load_config return path converges here, which is what makes the "nothing protects this
    -- server" warning complete rather than merely intended (ADR-0056).
    access.log_startup_state()
    ensure_grids_loaded()
    grid_store.ensure_presets_loaded()
    -- Replay the run log into the derived aggregate. A no-op while statistics are switched off
    -- (ADR-0053): runlog.ensure self-gates, so the log is neither read nor -- via resolve_path's
    -- io.open(path, "a") probe -- created at startup. No call-site condition here on purpose; one gate
    -- inside ensure covers all three of its callers and cannot fall out of step with them.
    runlog.ensure()
    -- Start the always-on state-machine tick. Deferred to onInit (not load) so the engine is
    -- fully up; the tick is a no-op while the session sits in lobby.
    MP.CreateEventTimer(TICK_EVENT, TICK_INTERVAL_MS, MP.CallStrategy.BestEffort)
    log_info("beamcomp.race", "state-machine tick started (" .. TICK_INTERVAL_MS .. "ms)")
end

-- The functions below are the only file-scope globals in this plugin. BeamMP's MP.RegisterEvent
-- binds a handler by its global function name, so registered entry points must be global. Each
-- stays a thin wrapper that delegates straight into a local function.

-- BeamMP event handler (must be global)
function beamcomp_on_chat(player_id, player_name, message)
    return on_chat_message(player_id, player_name, message)
end

-- BeamMP event handler (must be global)
function beamcomp_on_init()
    return on_init()
end

-- BeamMP event handler (must be global)
function beamcomp_on_tick()
    return tick()
end

-- BeamMP event handler (must be global)
function beamcomp_on_join(player_id)
    return identity.handle_join(player_id)
end

-- BeamMP event handler (must be global)
function beamcomp_on_disconnect(player_id)
    return on_player_disconnect(player_id)
end

-- BeamMP event handler (must be global)
function beamcomp_on_client_event(player_id, data)
    return handle_client_event(player_id, data)
end

MP.RegisterEvent("onChatMessage", "beamcomp_on_chat")
MP.RegisterEvent("onInit", "beamcomp_on_init")
-- BOTH join events, onto the same handler (ADR-0054). MP.RegisterEvent takes any string, and an event
-- name the server does not know is a SILENT no-op -- the same class of trap as the engine input-action
-- names in CLAUDE.md, with no error and no log line to notice it by.
--   * onPlayerJoin is the intended one: BeamMP-Server v3.9.2 carries it as a standalone string literal
--     immediately after its " is now synced!" log line, i.e. the sync-complete path fires it.
--   * onPlayerJoining is the only join event our own references/beammp-server-api.md documents, and it
--     exists in the binary too (it fires earlier, right after the mod download).
-- Arming is idempotent and a re-arm only pushes the deadline later, so when both fire the grace ends up
-- anchored on the later one. Registering both costs a line and removes the whole "did we pick the right
-- name" failure mode.
MP.RegisterEvent("onPlayerJoin", "beamcomp_on_join")
MP.RegisterEvent("onPlayerJoining", "beamcomp_on_join")
MP.RegisterEvent("onPlayerDisconnect", "beamcomp_on_disconnect")
MP.RegisterEvent(TICK_EVENT, "beamcomp_on_tick")
MP.RegisterEvent(EVENT_CHANNEL, "beamcomp_on_client_event")

return f1
