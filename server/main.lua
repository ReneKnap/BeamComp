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
--   /race [map:|menu:]<name> [sprint|circuit] [laps] [reverse] [force] [recover[:secs]] [repair[:secs]] [grid=<name>] [car=<model[:config]>] [maxhp=<n>] [maxpwr=<n>] [order=entry|random|last|pwr|championship|quali[:rev]] [quali=<min>] [ai <n> [easy|medium|hard]] [aicar=<model[:config]>] [aiaggr=/aiskill=/airubber=<0..1>] [all]
--                 (each keyword token also accepts any unambiguous prefix: s/c, rev, f, rec/rep)
--                 vehicle policy (ADR-0032): car=<model[:config]> = one fixed car for everyone (Mode 2);
--                 maxhp=<n> (hp) / maxpwr=<n> (power-to-weight, hp per kg) = per-player caps that keep a
--                 compliant car or substitute one (Mode 3); none = keep own car (Mode 1). car= wins.
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
--   /go /start /racestart  start the race now: end the staging wait early and begin the countdown
--                 (ADR-0021). Admin-gated like /race; only acts while a race is staging.
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

local M = {}

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
local MSG_CLIENT_IDENTITY = "clientIdentity"  -- a client's BeamNG name, reported on connect, for identity resolution (ADR-0031)
local MSG_GRID_SAVE = "gridSave"      -- editor saves a named grid for a map (ADR-0023; admin-gated)
local MSG_GRID_ASSIGN = "gridAssign"  -- editor sets a map's default grid for a race (ADR-0023; admin-gated)
local MSG_GRID_DELETE = "gridDelete"  -- editor deletes a saved grid for a map (ADR-0023; admin-gated)
local MSG_GRID_FETCH = "gridFetch"    -- editor opens a saved grid: request its data (ADR-0023; read-only)
local MSG_GRID_LIST_REQ = "gridListReq"  -- editor lists a map's saved grids (ADR-0023; read-only)
local MSG_GRID_DATA = "gridData"      -- reply to gridFetch: a saved grid's params (server -> client)
local MSG_GRID_LIST = "gridList"      -- reply to gridListReq: the map's saved grid names (server -> client)
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
    staging = 120.0,      -- pre-countdown staging wait; ends early on /go|/start|/racestart (ADR-0021)
    countdown = 8.0,      -- pre-race countdown (ADR-0021: was 3.0)
    finish_grace = 120.0, -- DNF cutoff: time after the first finisher for others to finish (ADR-0014)
    all_done_grace = 5.0, -- shortened grace once no one can still finish (ADR-0014 early-end)
    abort_window = 1.5,   -- short finished window when /race restarts a running race
    finished_hold = 900.0, -- long results + free-roam window before returning to lobby (ADR-0006 amendment)
    quali_default = 480.0, -- default qualifying session length, 8 min (ADR-0041); per-event override in session.quali.duration
    quali_lap_grace = 45.0, -- finish-your-lap cap after the quali clock expires before quali-results (ADR-0041)
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
    pending_prefab_content = nil, -- queued race's serialized statics content, relayed verbatim (ADR-0039)
    pending_validation = nil, -- in-flight pre-flight check {race, overrides, owner_id, nonce, deadline} (ADR-0019)
    validation_seq = 0,       -- monotonic nonce source so a stale/duplicate raceValidation is ignored
    cleanup_warned = false,   -- one-shot guard for the ~60 s "props/results clear soon" warning (B3)
    spawn_pending = nil,      -- set of rostered player ids whose spawnReady ack is still awaited (ADR-0006 amendment)
    spawn_ready_count = 0,    -- how many distinct clients acked spawnReady this race (0 at timeout = empty race)
    identities = nil,         -- per-player {vehicle, pwr} reported via clientInfo, for records (ADR-0027) + start-order (ADR-0033); name moved to client_names (ADR-0031)
    order = nil,              -- this race's start-order {mode, rev} (ADR-0033), or nil = entry order
    last_order = nil,         -- previous race's finishing order as a list of identities (ADR-0033); session-scoped, survives reset_to_lobby so order=last has a source
    championship = nil,       -- active multi-race championship {points_preset, order, standings, race_count} or nil (ADR-0040); session-scoped, survives reset_to_lobby like last_order
    quali = nil,              -- active quali-then-race event {duration, lap_grace_deadline, done} or nil (ADR-0041); per-event, cleared by reset_to_lobby (unlike last_order/championship)
    owner_id = nil,           -- player id that issued the active race -- the prop + AI owner (ADR-0009/0036), or nil
}

-- Race-command permissions / plugin config (ADR-0016). The race-admin allowlist gates /race, /raceend and
-- /raceclear; it is loaded on init from the plugin config file. Candidate paths tolerate the unverified
-- runtime working directory (recon TODO #4) -- server root first, then the plugin folder. An empty,
-- missing, or unparseable config leaves the gate inactive (opt-in: everyone may start/end races).
local CONFIG_CANDIDATE_PATHS = {
    "Resources/Server/BeamComp/beamcomp.config.json",
    "beamcomp.config.json",
}

-- Normalized (trimmed, lowercased) admin names -> true, and whether the gate is on.
local race_admins = {}
local race_admin_gate_active = false

-- Whether player identity resolves to the client-reported BeamNG name instead of the BeamMP name
-- (ADR-0031). Default on -- a missing or unparseable config keeps it on, so the guest-name fix applies
-- out of the box. Set false in beamcomp.config.json to fall back to BeamMP names everywhere.
local use_client_name = true

-- Connection-scoped BeamNG name per player id (ADR-0031), reported once on connect via clientIdentity
-- and cleared on disconnect. Survives lobby resets -- unlike session.identities, which is per race --
-- so resolve_identity has the name from join onward. An opaque client string (race-blind, ADR-0005).
local client_names = {}

-- The canonical display/record identity for a player (ADR-0031): the client-reported BeamNG name when
-- the option is on and one was reported, else the BeamMP name. The single chokepoint every name read
-- goes through -- the option and the fallback live here only. nil only if BeamMP has no name for the id.
local function resolve_identity(player_id)
    if use_client_name then
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

-- grids[map][name] = {forward = <params>, reverse = <params>?}; defaults[map][raceId] = name.
local grid_store = {grids = {}, defaults = {}}
local grids_file_path = nil
-- Whether grid_store has been populated from disk in THIS Lua-state instance. A BeamMP file-watch
-- reload (recon gotcha 12) re-runs this chunk -- resetting grid_store + this flag -- which is exactly
-- what happens when the editor writes the grids file; lazy-loading on first access (ensure_grids_loaded)
-- repopulates the store after such a reload, so a saved default is not lost.
local grids_loaded = false

-- Persistent best-times records (ADR-0027). A separate data file from the settings config (ADR-0016):
-- records[race_name] = {track_best = {...}, players = {[identity] = {...}}}. The server stores only
-- numbers + opaque client-reported strings keyed on the relayed race name, so race-blindness (ADR-0005)
-- holds. Candidate paths tolerate the unverified working directory exactly like config + grids; writes
-- go back to the loaded path, else the first candidate that opens. deploy.ps1 preserves this file
-- across the server-folder wipe (like beamcomp.grids.json) so accumulated times survive a redeploy.
local RECORDS_CANDIDATE_PATHS = {
    "Resources/Server/BeamComp/beamcomp.records.json",
    "beamcomp.records.json",
}

-- records[race_name] = {...}; see capture_records. Empty until loaded from disk.
local records_store = {}
local records_file_path = nil
local records_loaded = false


local function log_info(subsystem, msg)
    print("[" .. subsystem .. "] " .. msg)
end

-- Normalize a player name for allowlist comparison: trim surrounding whitespace, then lowercase.
local function normalize_name(name)
    return (name:gsub("^%s*(.-)%s*$", "%1")):lower()
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
    race_admins = {}
    race_admin_gate_active = false
    use_client_name = true

    local config, path, err = read_config()
    if not config then
        if err == "parse" then
            log_info("beamcomp.cfg", "config at " .. tostring(path)
                .. " is not valid JSON; race-admin gate inactive")
        else
            log_info("beamcomp.cfg", "no config file found; race-admin gate inactive")
        end
        log_info("beamcomp.cfg", "useClientName=on (default; no config)")
        return
    end

    -- Default on (ADR-0031): only an explicit false turns it off; a missing key stays on.
    use_client_name = config.useClientName ~= false
    log_info("beamcomp.cfg", "useClientName=" .. (use_client_name and "on" or "off"))

    if type(config.raceAdmins) ~= "table" then
        log_info("beamcomp.cfg", "config at " .. path
            .. " has no raceAdmins array; race-admin gate inactive")
        return
    end

    local count = 0
    for _, name in ipairs(config.raceAdmins) do
        if type(name) == "string" then
            local normalized = normalize_name(name)
            if normalized ~= "" and not race_admins[normalized] then
                race_admins[normalized] = true
                count = count + 1
            end
        end
    end

    if count == 0 then
        log_info("beamcomp.cfg", "loaded config from " .. path
            .. "; no race admins listed, gate inactive")
        return
    end

    race_admin_gate_active = true
    log_info("beamcomp.cfg", "loaded config from " .. path .. "; "
        .. count .. " race admin(s), gate active")
end

-- Whether `player_name` may issue the gated race commands. With the gate inactive (no admins
-- configured) everyone is allowed -- the opt-in default (ADR-0016).
local function is_race_admin(player_name)
    if not race_admin_gate_active then
        return true
    end
    return race_admins[normalize_name(player_name)] == true
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
-- empty, so every race uses the procedural grid -- the safe default. The resolved path is logged so the
-- write target is visible in the server console (recon TODO #4). Called from on_init.
local function load_grids()
    grid_store = {grids = {}, defaults = {}}

    local data, path, err = read_grids()
    grids_file_path = path
    if not data then
        if err == "parse" then
            log_info("beamcomp.grid", "grids file at " .. tostring(path)
                .. " is not valid JSON; using procedural grids")
        else
            log_info("beamcomp.grid", "no grids file found; using procedural grids")
        end
        return
    end

    if type(data.grids) == "table" then
        grid_store.grids = data.grids
    end
    if type(data.defaults) == "table" then
        grid_store.defaults = data.defaults
    end
    log_info("beamcomp.grid", "loaded grids from " .. path)
end

-- Populate grid_store once per Lua-state instance, lazily on first access. This makes grid resolution
-- robust to a file-watch reload that resets the in-memory store without re-firing onInit (ADR-0023):
-- the next save/resolve/fetch repopulates from disk.
local function ensure_grids_loaded()
    if grids_loaded then
        return
    end
    grids_loaded = true
    load_grids()
end

-- The grid param record for a race start, or nil to fall back to the procedural grid (ADR-0023).
-- An explicit `grid_name` (from /race grid=<name>) wins; otherwise the map's default for this race is
-- used. A requested-but-unknown name resolves to nil, so a typo'd /race grid= silently falls back
-- rather than failing the start. The server never interprets the record -- it relays it verbatim.
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

    local record = map_grids[name]
    if type(record) ~= "table" then
        log_info("beamcomp.grid", "resolve: grid '" .. name .. "' missing for '" .. map .. "' -> procedural")
        return nil
    end
    log_info("beamcomp.grid", "resolve: using grid '" .. name .. "' for race '" .. tostring(race_name) .. "'")
    return record
end

-- Serialize grid_store and write it back, trying the loaded path first then the candidates (ADR-0023).
-- Returns true + path on success, false otherwise. pcall-guarded around the encode + file I/O so a
-- write failure is reported, never thrown into the BeamMP runtime.
local function write_grids()
    local ok, encoded = pcall(Util.JsonEncode, {grids = grid_store.grids, defaults = grid_store.defaults})
    if not ok then
        log_info("beamcomp.grid", "could not encode grids: " .. tostring(encoded))
        return false
    end

    local candidates = {}
    if grids_file_path then
        candidates[#candidates + 1] = grids_file_path
    end
    for _, path in ipairs(GRIDS_CANDIDATE_PATHS) do
        candidates[#candidates + 1] = path
    end

    for _, path in ipairs(candidates) do
        local file = io.open(path, "w")
        if file then
            file:write(encoded)
            file:close()
            grids_file_path = path
            return true, path
        end
    end
    log_info("beamcomp.grid", "could not open any grids path for writing")
    return false
end

-- Store a named grid for a map and persist it (ADR-0023). `record` is {forward = <params>,
-- reverse = <params>?}. Returns the write_grids result.
local function save_grid(map, name, record)
    ensure_grids_loaded()
    if type(grid_store.grids[map]) ~= "table" then
        grid_store.grids[map] = {}
    end
    grid_store.grids[map][name] = record
    return write_grids()
end

-- Set a map's default grid for a race and persist it (ADR-0023). Returns the write_grids result.
local function assign_default(map, race_name, name)
    ensure_grids_loaded()
    if type(grid_store.defaults[map]) ~= "table" then
        grid_store.defaults[map] = {}
    end
    grid_store.defaults[map][race_name] = name
    return write_grids()
end

-- Delete a saved grid from a map and persist it (ADR-0023). Also drops any race defaults that pointed at
-- it, so a deleted grid leaves no dangling default mapping. Returns (existed, write_grids ok): existed is
-- false when there was no such grid (nothing written).
local function delete_grid(map, name)
    ensure_grids_loaded()
    local map_grids = grid_store.grids[map]
    if type(map_grids) ~= "table" or type(map_grids[name]) ~= "table" then
        return false
    end
    map_grids[name] = nil
    local map_defaults = grid_store.defaults[map]
    if type(map_defaults) == "table" then
        for race_name, default_name in pairs(map_defaults) do
            if default_name == name then
                map_defaults[race_name] = nil
            end
        end
    end
    local ok = write_grids()
    return true, ok
end

-- Read and JSON-decode the records file from the first candidate path that opens (ADR-0027). Returns
-- the decoded table + resolved path, or nil + path + error label ("parse"/"missing"). pcall-guarded so
-- a malformed file never crashes the plugin load -- mirrors read_config/read_grids.
local function read_records()
    for _, path in ipairs(RECORDS_CANDIDATE_PATHS) do
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

-- Populate records_store from the records file (ADR-0027). A missing or unparseable file leaves the
-- store empty -- the first finish then seeds it. The resolved path is logged so the write target is
-- visible in the server console (recon TODO #4). Called lazily via ensure_records_loaded.
local function load_records()
    records_store = {}

    local data, path, err = read_records()
    records_file_path = path
    if not data then
        if err == "parse" then
            log_info("beamcomp.records", "records file at " .. tostring(path)
                .. " is not valid JSON; starting empty")
        else
            log_info("beamcomp.records", "no records file found; starting empty")
        end
        return
    end

    records_store = data
    log_info("beamcomp.records", "loaded records from " .. path)
end

-- Populate records_store once per Lua-state instance, lazily on first access -- robust to a file-watch
-- reload that resets the in-memory store without re-firing onInit, exactly like ensure_grids_loaded.
local function ensure_records_loaded()
    if records_loaded then
        return
    end
    records_loaded = true
    load_records()
end

-- Serialize records_store and write it back, trying the loaded path first then the candidates
-- (ADR-0027). Returns true + path on success, false otherwise. pcall-guarded around the encode + file
-- I/O so a write failure is reported, never thrown into the BeamMP runtime -- mirrors write_grids.
local function write_records()
    local ok, encoded = pcall(Util.JsonEncode, records_store)
    if not ok then
        log_info("beamcomp.records", "could not encode records: " .. tostring(encoded))
        return false
    end

    local candidates = {}
    if records_file_path then
        candidates[#candidates + 1] = records_file_path
    end
    for _, path in ipairs(RECORDS_CANDIDATE_PATHS) do
        candidates[#candidates + 1] = path
    end

    for _, path in ipairs(candidates) do
        local file = io.open(path, "w")
        if file then
            file:write(encoded)
            file:close()
            records_file_path = path
            return true, path
        end
    end
    log_info("beamcomp.records", "could not open any records path for writing")
    return false
end

local function now()
    return clock:GetCurrent()
end

local function phase_elapsed()
    return now() - session.phase_started_at
end

-- Send a typed event to one client as a { type, payload } envelope. BeamMP
-- JSON-encodes the table; the client decodes it with the shared envelope module.
local function send_event(player_id, message_type, payload)
    local ok, err = MP.TriggerClientEventJson(player_id, EVENT_CHANNEL, {
        type = message_type,
        payload = payload,
    })
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
    -- An id's ranking identity: AI ids are strings "ai:<k>" that carry the display name "AI <k>" in the
    -- standings (mirrors AI_ID_PREFIX / make_slot_entry), so the championship can rank AI alongside players;
    -- real player ids are numbers resolved via resolve_identity (ADR-0031).
    local function identity_of(id)
        if type(id) == "string" then
            return "AI " .. id:sub(4)
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

-- One slot record for an id at a 0-based slot. AI ids (ADR-0036) carry the "AI <k>" display name and the
-- ai flag; real players carry their connected name. Keeps build_slots free of the player/AI branch.
local function make_slot_entry(id, slot, players)
    if is_ai_id(id) then
        return {id = id, slot = slot, name = "AI " .. id:sub(#AI_ID_PREFIX + 1), ai = true}
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
    else
        ids = order_ids(players, order, last_order)
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            ids[#ids + 1] = ai_id
        end
    end
    local slots = {}
    for index, id in ipairs(ids) do
        slots[index] = make_slot_entry(id, index - 1, players)
    end
    return slots
end

-- The roster shipped to every client: each player's slot + name, in slot order. Used
-- client-side for the full grid layout and marker labels. The name resolves through resolve_identity
-- (ADR-0031), so the grid labels show the client name like every other surface.
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
            -- The BeamMP name as a baseline (ADR-0031); standings and records resolve the canonical
            -- client name live via resolve_identity, since it may only arrive at spawn (license name).
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
    if type(vehicle.variant) == "string" and vehicle.variant ~= "" then
        return vehicle.model .. "/" .. vehicle.variant
    end
    return vehicle.model
end

-- A compact car descriptor for the standings entry and the records payload (ADR-0029): the records key
-- plus the raw fields the overlay shows. nil when there is no usable vehicle.
local function car_descriptor(vehicle)
    local key = vehicle_car_key(vehicle)
    if not key then
        return nil
    end
    return {key = key, model = vehicle.model, variant = vehicle.variant, modified = vehicle.modified}
end

-- Build the live ranked standings from session.progress: a pure function over the per-player
-- records (race-blind, ADR-0005). Sort key: non-DNF before DNF (ADR-0014), then most checkpoints
-- completed, then earliest time at that checkpoint, then slot as a stable tiebreak -- so finishers and
-- active racers rank above DNFs, finished players lead by finish time, and DNFs rank by how far they
-- got. Each entry carries a 1-based position; `count` falls back to a shared known_count so entries
-- agree once any report has set it (nil at race-start baseline).
local function build_standings()
    if not session.progress then
        return {}
    end

    local ranked = {}
    local known_count
    local identities = session.identities or {}
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
        if a.total_time ~= b.total_time then
            return a.total_time < b.total_time
        end
        return a.slot < b.slot
    end)

    local entries = {}
    for i, item in ipairs(ranked) do
        local record = item.record
        local info = identities[item.id]
        entries[i] = {
            position = i,
            slot = record.slot,
            -- Resolve the canonical identity live (ADR-0031): the license name may have arrived only at
            -- spawn, after this player's progress baseline was seeded with the BeamMP name.
            name = resolve_identity(item.id) or record.name,
            completed = record.completed,
            count = record.count or known_count,
            total_time = record.total_time,
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
            -- The driver's car (ADR-0029), so the client can filter "best lap with the car" in the
            -- analysis overlay. nil when no identity/vehicle was reported.
            car = car_descriptor(info and info.vehicle),
            -- Synthetic host-driven AI slot (ADR-0036), so the HUD can tag it; nil for real players.
            ai = record.ai or nil,
        }
    end
    return entries
end

-- Broadcast the standings to every client as a `standings` envelope (ADR-0004). Fired at the
-- racing-phase baseline and after every accepted checkpoint report.
local function broadcast_standings()
    broadcast_event(MSG_STANDINGS, {entries = build_standings()})
end

-- Capture the just-finished race's order as a list of identities (ADR-0033), in build_standings rank
-- order (finishers by time first, DNF last). Stored in session.last_order, which reset_to_lobby leaves
-- intact so the next race's order=last has a source; overwritten on the next finish. Identities match
-- what build_slots resolves (resolve_identity), so order=last maps players back to their finishing place.
local function capture_finishing_order()
    local order = {}
    for _, entry in ipairs(build_standings()) do
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
    local standings = build_standings()
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

-- Selectable qualifying lengths in minutes for the panel presets (ADR-0041); the chat grammar also accepts
-- a free quali=<n>. A free value is clamped to [MIN, MAX] seconds.
quali.PRESETS = {5, 8, 12, 15}
quali.MIN_SECONDS = 60.0
quali.MAX_SECONDS = 1800.0

-- Whether this race is a quali event at all (qualifying pending or already handed off to the race).
function quali.is_active()
    return session.quali ~= nil
end

-- Whether the qualifying session still owns the event -- it has not yet handed the grid to the race. The
-- tick uses this to route the first countdown into qualifying (vs. the race) for a quali event.
function quali.is_pending()
    return session.quali ~= nil and not session.quali.done
end

-- Clamp a requested quali length (seconds) into the sane bounds (ADR-0041).
function quali.clamp(seconds)
    return math.max(quali.MIN_SECONDS, math.min(quali.MAX_SECONDS, seconds))
end

-- Begin a quali event with a session length in seconds (already resolved/clamped by the caller, else the
-- default). Cleared by reset_to_lobby, so it never outlives the event (contrast last_order/championship).
function quali.begin(duration)
    session.quali = {
        duration = tonumber(duration) or PHASE_DURATIONS.quali_default,
        lap_grace_deadline = nil,  -- set when the quali clock expires, to let an in-progress lap finish
        done = false,              -- flips true at the quali-results -> countdown hand-off (race grid set)
        regridded = false,         -- flips true when the AI re-grid fires inside quali-results (ADR-0041)
    }
end

function quali.clear()
    session.quali = nil
end

-- The qualifying classification as a ranked list of {identity, pace, ai} (ADR-0041). Pace = the
-- client-reported best_lap (circuit); a sprint reports none, so a finisher's total run time stands in
-- (single-run degradation until the rally-staged sprint quali ships). Faster pace ranks ahead; a driver
-- with no valid time keeps entry (slot) order at the back. Pure over build_standings -- race-blind.
function quali.ranking()
    local timed, untimed = {}, {}
    for _, entry in ipairs(build_standings()) do
        if entry.name then
            local pace = tonumber(entry.best_lap)
            if not pace and entry.finished then
                pace = tonumber(entry.total_time)
            end
            if pace then
                timed[#timed + 1] = {identity = entry.name, pace = pace, slot = entry.slot or 0, ai = entry.ai}
            else
                untimed[#untimed + 1] = {identity = entry.name, slot = entry.slot or 0, ai = entry.ai}
            end
        end
    end
    table.sort(timed, function(a, b)
        if a.pace ~= b.pace then
            return a.pace < b.pace  -- fastest lap/run on pole
        end
        return a.slot < b.slot       -- stable tiebreak on the provisional slot
    end)
    table.sort(untimed, function(a, b) return a.slot < b.slot end)
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

-- A client-facing snapshot of the qualifying classification (ADR-0041), shipped on entering quali-results
-- for the HUD results card. Rows carry the pace as seconds (nil for an unclassified driver).
function quali.snapshot()
    local rows = {}
    for position, item in ipairs(quali.ranking()) do
        rows[#rows + 1] = {
            position = position,
            name = item.identity,
            time = item.pace,
            ai = item.ai or nil,
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

    local slots = {}
    for index, id in ipairs(ordered) do
        slots[#slots + 1] = make_slot_entry(id, index - 1, players)
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
            ai_regrid[#ai_regrid + 1] = {id = entry.id, slot = entry.slot, label = entry.name}
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

-- Advance the qualifying phase from the tick (ADR-0041): run for session.quali.duration, then arm a
-- bounded finish-your-lap grace (so an in-progress lap still counts), then broadcast the classification and
-- enter the results pause. Mirrors the racing finish-grace handling -- handled explicitly (not by the
-- generic timed advance) so the grace can sit between the clock and the pause.
function quali.advance_qualifying()
    local q = session.quali
    if not q or phase_elapsed() < q.duration then
        return  -- still within the quali clock
    end
    if not q.lap_grace_deadline then
        q.lap_grace_deadline = now() + PHASE_DURATIONS.quali_lap_grace
        -- Tell clients the finish-your-lap window length so each still-circulating driver sees the timeout
        -- to be at the finish (reuses the racing finish-grace display, ADR-0014/0041).
        broadcast_event(MSG_FINISH_GRACE, {duration = PHASE_DURATIONS.quali_lap_grace})
        log_info("beamcomp.race", "quali clock expired; finish-your-lap grace armed")
        return
    end
    if now() >= q.lap_grace_deadline then
        broadcast_event(quali.MSG, quali.snapshot())
        -- Carry the re-grid lead so the client can split the pause display: a clean "results" countdown
        -- (pause - lead) before the respawn, then the settle timer (the remaining pause) after it (ADR-0041).
        enter_phase(PHASE.quali_results, PHASE_DURATIONS.quali_results,
            {regridLead = PHASE_DURATIONS.quali_regrid_lead})
    end
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
    enter_phase(PHASE.countdown, PHASE_DURATIONS.countdown)
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
    for index, entry in ipairs(slots) do
        entry.slot = index - 1
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

-- Leave staging for the countdown (ADR-0021), applying the pwr re-grid first when order=pwr (ADR-0033).
-- The single seam both the staging timeout and the manual /go route through.
local function enter_countdown_from_staging()
    regrid_by_pwr()
    enter_phase(PHASE.countdown, PHASE_DURATIONS.countdown)
end

-- Clear the session and announce the lobby phase. If a race was active, tell players the world is
-- back to free-roam (B3) -- so a /raceclear or the finished-window expiry has a visible close-out.
local function reset_to_lobby()
    local had_race = session.race ~= nil
    session.race = nil
    session.roster = nil
    session.progress = nil
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_overrides = nil
    session.pending_map = nil
    session.pending_race_id = nil
    session.pending_race_data = nil
    session.pending_prefab_content = nil
    session.cleanup_warned = false
    session.spawn_pending = nil
    session.spawn_ready_count = 0
    session.identities = nil
    session.owner_id = nil
    -- session.quali (ADR-0041) is per-event, so unlike last_order/championship it is cleared here -- a
    -- qualifying belongs to one race event and must not bleed into the next.
    session.quali = nil
    -- session.last_order (ADR-0033) and session.championship (ADR-0040) deliberately persist across the
    -- lobby -- they are the cross-race order sources and must outlive a single race.
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
    local active = 0
    for _, record in pairs(session.progress) do
        if not record.finished and not record.dnf then
            active = active + 1
        end
    end
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
        log_info("beamcomp.race", "all players accounted for; grace shortened to results window")
    end
end

-- Begin a fresh race: assign slots, send each player its raceStart (slot + grid roster + relayed
-- overrides), and enter the spawning phase. The client resolves and parses the race name locally
-- (ADR-0005) and decides the actual mode/laps/direction; `overrides` carries the admin's verbatim
-- {mode, laps, direction, force, assists} (each nil/false = auto/off -- the client derives from the
-- race file, ADR-0013/0018). `owner_id` is the player that issued /race; exactly that player's
-- raceStart carries propOwner = true, designating it as the one client that spawns the shared race
-- props -- the knockable cones -- which BeamMP then syncs to every other client (ADR-0009).
local function start_race(race_name, owner_id, overrides, map, race_id, race_data, prefab_content)
    -- Resolve the grid start order (ADR-0033/0040/0041): entry/random/last/championship are applied to the
    -- slot assignment now; pwr and quali are provisional here and re-gridded later (pwr after staging, quali
    -- after the qualifying session). While a championship is active its stored order grids the race unless
    -- the admin gave an explicit order=.
    local effective_order = overrides.order or champ.active_order()
    session.order = effective_order
    -- order=quali makes this a two-phase event (ADR-0041): begin the qualifying session state now; the
    -- provisional grid below is random, and quali.regrid sets the real race grid by pace after qualifying.
    -- Length precedence: an explicit per-race quali= wins; else a championship driving the quali grid
    -- supplies its configured length; else the default.
    if effective_order and effective_order.mode == "quali" then
        local quali_seconds = overrides.quali_duration
        if not quali_seconds and champ.is_active() then
            quali_seconds = session.championship.quali_seconds
        end
        quali.begin(quali_seconds)
    else
        quali.clear()
    end
    -- The requested AI opponents become synthetic participant slots (ADR-0036), so the roster, grid
    -- layout, and standings include them like any participant; the owner spawns + drives them. They mix
    -- into a random order and sort by reported pwr; otherwise they take the back of the grid.
    local slots = build_slots(MP.GetPlayers(), effective_order, session.last_order,
        champ.order_identities(), overrides.ai and overrides.ai.count)
    local roster = build_roster(slots)
    local assists = overrides.assists
    -- Resolve the named/default grid for this race on the issuer-reported map (ADR-0023). The default is
    -- keyed by the canonical race id (race_id) so it resolves whatever shorthand was typed for /race;
    -- fall back to the raw name if the client did not report an id. nil = no custom grid -> clients lay
    -- out the procedural grid. The server relays the params verbatim and never interprets them (ADR-0005).
    local grid_params = resolve_grid(map, race_id or race_name, overrides.grid)

    session.race = race_name
    session.roster = roster
    session.owner_id = owner_id
    session.progress = build_progress(slots)
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_overrides = nil
    session.pending_map = nil
    session.pending_race_id = nil
    session.pending_race_data = nil
    session.pending_prefab_content = nil
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
            ai_slots[#ai_slots + 1] = {slot = entry.slot, id = entry.id, label = entry.name}
        end
    end
    -- Drop any identity/vehicle reports from a prior race so a re-issue (abort path, no reset_to_lobby)
    -- starts clean; each player re-reports clientInfo on the new spawn (ADR-0027).
    session.identities = nil

    log_info("beamcomp.race", string.format("starting '%s' for %d player(s) + %d AI",
        race_name, #slots - #ai_slots, #ai_slots))

    for _, entry in ipairs(slots) do
        -- AI slots have no client (ADR-0036): skip them. The owner alone receives aiSlots, so it spawns
        -- and drives the AI cars; everyone else just sees them in the roster + standings.
        if not is_ai_id(entry.id) then
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
                } or nil,
                mode = overrides.mode,            -- nil = auto (client derives from meta.closed); ADR-0013
                laps = overrides.laps,            -- nil = auto (client uses meta.defaultLaps); ADR-0013
                direction = overrides.direction,  -- nil = forward; "reverse" if reversible (ADR-0018)
                force = overrides.force,          -- override a geometry mismatch where possible (ADR-0018)
                all = overrides.all,              -- opt the deprecated quickrace source into resolution (ADR-0026)
                -- Opt-in recover/repair assists (ADR-0017); clients enforce. Disabled by default.
                recoverEnabled = assists.recoverEnabled,
                recoverHoldSeconds = assists.recoverHoldSeconds,
                repairEnabled = assists.repairEnabled,
                repairHoldSeconds = assists.repairHoldSeconds,
                -- Resolved custom-grid params (ADR-0023); nil = procedural grid. Same for every slot --
                -- clients pick their own pose from the shared layout by slot.
                gridParams = grid_params,
                -- Vehicle policy (ADR-0032), relayed verbatim and never interpreted (ADR-0005): car =
                -- fixed "model[:config]" for everyone (Mode 2); maxhp (hp) / maxpwr (power-to-weight, hp
                -- per kg) = per-player caps (Mode 3). All nil = keep own car (Mode 1). car wins client-side.
                car = overrides.car,
                maxhp = overrides.maxhp,
                maxpwr = overrides.maxpwr,
                -- The issuer-serialized race definition + statics content (ADR-0039), relayed verbatim and
                -- never interpreted (ADR-0005): a client without the local race file builds + spawns the
                -- race from these. Same for every slot; the host (which has the file) ignores them and
                -- parses locally. nil when the issuer's client did not ship them (older client).
                raceData = race_data,
                prefabContent = prefab_content,
                -- Qualifying event (ADR-0041): present only for order=quali, carrying the session length so
                -- the client builds an unbounded-lap quali plan + shows the quali clock. nil = normal race.
                quali = session.quali and {duration = session.quali.duration} or nil,
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
        local prefab_content = session.pending_prefab_content
        session.pending_race = nil
        session.pending_owner = nil
        session.pending_overrides = nil
        session.pending_map = nil
        session.pending_race_id = nil
        session.pending_race_data = nil
        session.pending_prefab_content = nil
        start_race(pending, owner, overrides, map, race_id, race_data, prefab_content)
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
-- lobby instead of running an empty race until /raceclear; otherwise proceed to staging. A no-op until
-- the wait resolves, so it is safe to call every tick.
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
    else
        enter_phase(PHASE.staging, PHASE_DURATIONS.staging)
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
    if not session.race or not session.progress then
        return snapshot
    end
    ensure_records_loaded()
    local race = records_store[session.race]
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
    if not identity then
        return {anyCar = any_car, thisCar = this_car}
    end
    for _, race_record in pairs(records_store) do
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
    if not session.race or not session.progress then
        return
    end

    ensure_records_loaded()
    prerun = prerun or {}

    local race = records_store[session.race]
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

-- Capture every non-DNF finisher's best times into the persistent records at the racing -> finished
-- seam (ADR-0027). One pass over session.progress, one file write. Per finisher: pick the primary
-- metric (best lap for a circuit -- signalled by the non-nil best_lap the client reported -- else the
-- total time), derive per-CP segments from the cumulative splits, and update the player record and the
-- race's track record when improved. The server reads only numbers + the opaque client-reported
-- identity/vehicle, keyed on session.race, so race-blindness (ADR-0005) holds. Improved finishers get
-- a bestNotice. DNFs are not scored.
local function capture_records()
    if not session.race or not session.progress then
        return
    end

    -- Nothing to record when no real player finished (all DNF / AI only): skip the load + write. AI never
    -- hold records (ADR-0036/0027), so an AI finisher does not count here.
    local has_finisher = false
    for _, record in pairs(session.progress) do
        if record.finished and not record.dnf and not record.ai then
            has_finisher = true
            break
        end
    end
    if not has_finisher then
        return
    end

    ensure_records_loaded()

    local race = records_store[session.race]
    if type(race) ~= "table" then
        race = {players = {}, track_best = {}}
        records_store[session.race] = race
    end
    if type(race.players) ~= "table" then
        race.players = {}
    end
    if type(race.track_best) ~= "table" then
        race.track_best = {}
    end

    local date = os.date("%Y-%m-%d")
    local identities = session.identities or {}
    local notify = {}

    for id, record in pairs(session.progress) do
        if record.finished and not record.dnf and not record.ai then
            local info = identities[id]
            local identity = resolve_identity(id) or record.name
            local vehicle = info and info.vehicle or nil
            local car_key = vehicle_car_key(vehicle)
            local is_circuit = record.best_lap ~= nil
            local primary = is_circuit and record.best_lap or record.total_time
            local time = record.total_time
            local aggregate = run_section_aggregate(record)

            local is_pb = update_player_record(race.players, identity, car_key, is_circuit, primary,
                time, aggregate, vehicle, date)
            local is_track_record = update_track_best(race.track_best, car_key, is_circuit, primary,
                time, aggregate, identity, vehicle, date)

            if (is_pb or is_track_record) and identity then
                notify[id] = {pb = is_pb, track_record = is_track_record}
            end
        end
    end

    local ok = write_records()
    if not ok then
        log_info("beamcomp.records", "capture: write failed; records kept in memory only")
    else
        log_info("beamcomp.records", "captured best times for race '" .. session.race .. "'")
    end

    for id, flags in pairs(notify) do
        send_event(id, MSG_BEST_NOTICE, {pb = flags.pb, trackRecord = flags.track_record})
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
    enter_phase(PHASE.finished, PHASE_DURATIONS.finished_hold)
end

local function tick()
    expire_stale_validation()
    maybe_warn_cleanup()

    local phase = session.phase
    if phase == PHASE.lobby then
        return
    end

    -- racing ends when the finish grace (armed by the first finisher) elapses; any player still out
    -- on track at that point is marked DNF before the race settles (ADR-0014).
    if phase == PHASE.racing then
        if session.grace_deadline and now() >= session.grace_deadline then
            finalize_race("grace expired")
        end
        return
    end

    -- qualifying is time-boxed (ADR-0041): handled ahead of the generic timed advance so the finish-your-lap
    -- grace can sit between the quali clock and the classification pause (mirrors the racing grace).
    if phase == PHASE.qualifying then
        quali.advance_qualifying()
        return
    end

    -- spawning ends on spawn-ready acks (or a timeout), not a fixed delay -- handled ahead of the
    -- generic timed advance so a full ack set can leave early (ADR-0006 amendment).
    if phase == PHASE.spawning then
        advance_spawning()
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

    if phase == PHASE.staging then
        enter_countdown_from_staging()
    elseif phase == PHASE.countdown then
        -- For a quali event the first countdown gates the qualifying session, not the race (ADR-0041): the
        -- second countdown (after quali-results sets the grid) gates the race. Either way send the baseline
        -- standings (every participant at zero) so clients have a table to show from the start.
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
    .. "[recover[:secs|off]] [repair[:secs|off]] [grid=<name>] [car=<model[:config]>] "
    .. "[maxhp=<n>] [maxpwr=<n>] [order=entry|random|last|pwr|championship|quali[:rev]] [quali=<min>] "
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
local RACE_KEYWORDS = {"sprint", "circuit", "reverse", "recover", "repair", "force"}
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
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to start races")
        log_info("beamcomp.race", "denied race request from " .. tostring(player_name) .. " (not a race admin)")
        return
    end

    -- Vehicle-policy precedence (ADR-0032): a fixed car= wins over a power/power-to-weight cap. Drop the
    -- caps so the relay is unambiguous and tell the admin. Pure option bookkeeping -- no vehicle reading.
    if overrides.car and (overrides.maxhp or overrides.maxpwr) then
        overrides.maxhp = nil
        overrides.maxpwr = nil
        MP.SendChatMessage(player_id, "BeamComp: car= set -- maxhp/maxpwr ignored")
    end

    local assists = overrides.assists
    local order_echo = ""
    if overrides.order then
        order_echo = " order=" .. overrides.order.mode .. (overrides.order.rev and ":rev" or "")
    end
    log_info("beamcomp.race", string.format(
        "race '%s' by %s (phase %s)%s%s%s%s recover=%s repair=%s%s%s%s%s%s",
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
local function commit_validated_race(race_name, owner_id, overrides, map, race_id, race_data, prefab_content)
    if session.phase == PHASE.lobby or session.phase == PHASE.finished then
        start_race(race_name, owner_id, overrides, map, race_id, race_data, prefab_content)
        MP.SendChatMessage(owner_id, "BeamComp: starting race '" .. race_name .. "'")
        return
    end

    session.pending_race = race_name
    session.pending_owner = owner_id
    session.pending_overrides = overrides
    session.pending_map = map
    session.pending_race_id = race_id
    session.pending_race_data = race_data
    session.pending_prefab_content = prefab_content
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
        -- The issuer's serialized race definition + statics content (ADR-0039): captured here as an opaque
        -- blob and relayed verbatim into raceStart so a file-less client can build the race. The server
        -- never parses or inspects it -- race-blindness holds (ADR-0005). nil from an older client.
        local race_data = type(payload.raceData) == "table" and payload.raceData or nil
        local prefab_content = type(payload.prefabContent) == "table" and payload.prefabContent or nil
        commit_validated_race(pending.race, pending.owner_id, overrides, map, race_id,
            race_data, prefab_content)
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
-- connect via clientIdentity (ADR-0031). Logged once so the unverified vehicle globals are visible.
local function handle_client_info(player_id, payload)
    if session.phase == PHASE.lobby or type(payload) ~= "table"
        or payload.race ~= session.race then
        return
    end
    local vehicle = type(payload.vehicle) == "table" and payload.vehicle or nil
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
    -- pwr (power-to-weight) feeds the start-order pwr re-grid (ADR-0033); stored verbatim, never
    -- interpreted (race-blind, ADR-0005). nil/non-number when the client could not read it.
    session.identities[target_id] = {vehicle = vehicle, pwr = tonumber(payload.pwr)}
    log_info("beamcomp.records", string.format(
        "clientInfo id=%s vehicle=%s/%s modified=%s",
        tostring(target_id),
        tostring(vehicle and vehicle.model),
        tostring(vehicle and vehicle.type),
        tostring(vehicle and vehicle.modified)))
end

-- Store a client's reported BeamNG name for identity resolution (ADR-0031). Connection-scoped: kept
-- across races and lobby resets, cleared on disconnect, so the name is available from join onward. The
-- value is opaque to the server (race-blind, ADR-0005) -- only echoed back as a display/record key.
-- Logged once so the unverified client name source is visible in the server console.
local function handle_client_identity(player_id, payload)
    if type(payload) ~= "table" or type(payload.name) ~= "string" or payload.name == "" then
        return
    end
    local changed = client_names[player_id] ~= payload.name
    client_names[player_id] = payload.name
    log_info("beamcomp.records", string.format("clientIdentity id=%s name=%s",
        tostring(player_id), payload.name))
    -- A name arriving mid-race (license name is reported at spawn) refreshes the live board so the
    -- standings switch from the BeamMP name to the client name without waiting for the next checkpoint.
    if changed and session.progress then
        broadcast_standings()
    end
end

-- /raceclear: force the machine back to lobby + cleanup/despawn from any active phase (safety hatch). This
-- is the former /raceend behavior; /raceend now force-finishes into the results screen instead (ADR-0038).
local function handle_raceclear_command(player_id, player_name)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to end races")
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
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to end races")
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

    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to manage the championship")
        log_info("beamcomp.champ", "denied /championship from " .. player_name .. " (not a race admin)")
        return
    end

    if action == "start" then
        champ.start(preset, order, quali_seconds)  -- nil/reversed -> reversed grid; "normal"/"quali" as given
        champ.broadcast()
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

-- /go, /start, /racestart: end the staging wait early and start the countdown (ADR-0021). Admin-gated
-- like /race; a no-op (with a notice) from any phase other than staging.
local function handle_start_command(player_id, player_name)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to start races")
        log_info("beamcomp.race", "denied /go from " .. player_name .. " (not a race admin)")
        return
    end

    if session.phase ~= PHASE.staging then
        MP.SendChatMessage(player_id, "BeamComp: nothing to start (no race staging)")
        return
    end
    log_info("beamcomp.race", "manual start by " .. player_name)
    enter_countdown_from_staging()
    MP.SendChatMessage(player_id, "BeamComp: countdown started")
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

-- /raceui: open the asking admin's race-setup panel (ADR-0037). Admin-gated like /race, since the panel
-- starts races; the client assembles the option lists + opens the app on this relay. Race-blind: the
-- server only relays the open signal, it builds no race data.
local function handle_raceui_command(player_id, player_name)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to start races")
        log_info("beamcomp.race", "denied " .. CHAT_COMMAND_RACEUI .. " from " .. player_name .. " (not a race admin)")
        return
    end
    send_event(player_id, MSG_SETUP_OPEN, {})
    -- Seed the panel with the current championship state (ADR-0040) so its section reflects reality on
    -- open; subsequent changes arrive via the broadcast.
    send_event(player_id, champ.MSG, champ.snapshot())
    log_info("beamcomp.race", CHAT_COMMAND_RACEUI .. " open by " .. player_name)
end

-- Admin-gated open of the asking player's grid-editor panel (ADR-0037 amendment / ADR-0023). Like
-- /raceui, the server only relays the open signal; the client assembles the race list + opens the app.
-- The grid edit/save/assign messages this panel drives are already admin-gated server-side (ADR-0023).
local function handle_gridui_command(player_id, player_name)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to edit grids")
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
    -- Drop the connection-scoped name regardless of phase (ADR-0031) -- a player may leave in lobby too.
    client_names[player_id] = nil
    if session.phase == PHASE.lobby then
        return
    end
    if is_server_empty_without(player_id) then
        log_info("beamcomp.race", "all players gone; returning to lobby")
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

    if command == CHAT_COMMAND_RESULTS then
        handle_results_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if command == CHAT_COMMAND_ANALYSIS then
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

    broadcast_standings()
    if final then
        maybe_end_race()
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

-- Store a named grid sent by the in-game editor (ADR-0023). Admin-gated like /race (ADR-0016): only a
-- race admin may write the shared grids file. The server validates shape but never interprets the param
-- numbers (race-blind, ADR-0005). Payload: {map, name, forward = <params>, reverse = <params>?}.
local function handle_grid_save(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to save grids")
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

    -- Store the race the grid was authored against (canonical id) so beamcomp_grid_edit can re-anchor a
    -- reopened grid to the right start line (ADR-0023).
    local record = {forward = payload.forward, race = payload.race}
    if type(payload.reverse) == "table" then
        record.reverse = payload.reverse
    end

    local ok, path = save_grid(payload.map, payload.name, record)
    if ok then
        MP.SendChatMessage(player_id, "BeamComp: saved grid '" .. payload.name .. "' for " .. payload.map)
        log_info("beamcomp.grid", string.format("saved grid '%s' for map '%s' (%s) by %s",
            payload.name, payload.map, tostring(path), player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write grids file")
    end
end

-- Set a map's default grid for a race, sent by the editor (ADR-0023). Admin-gated. The grid must
-- already exist for that map. Payload: {map, race, name}.
local function handle_grid_assign(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to assign grids")
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
    if type(map_grids) ~= "table" or type(map_grids[payload.name]) ~= "table" then
        MP.SendChatMessage(player_id, "BeamComp: no grid '" .. payload.name .. "' saved for " .. payload.map)
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

-- Delete a saved grid sent by the editor (ADR-0023). Admin-gated like save/assign. Replies with the map's
-- updated grid-name list (MSG_GRID_LIST) so the panel's dropdown refreshes without a second round-trip.
-- Payload: {map, name}.
local function handle_grid_delete(player_id, payload)
    local player_name = player_name_of(player_id)
    if not player_name or not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to delete grids")
        return
    end
    if type(payload) ~= "table" or type(payload.map) ~= "string" or payload.map == ""
        or type(payload.name) ~= "string" or payload.name == "" then
        MP.SendChatMessage(player_id, "BeamComp: grid delete rejected -- bad data")
        return
    end

    local existed, ok = delete_grid(payload.map, payload.name)
    if not existed then
        MP.SendChatMessage(player_id, "BeamComp: no grid '" .. payload.name .. "' saved for " .. payload.map)
    elseif ok then
        MP.SendChatMessage(player_id, "BeamComp: deleted grid '" .. payload.name .. "' for " .. payload.map)
        log_info("beamcomp.grid", string.format("deleted grid '%s' for map '%s' by %s",
            payload.name, payload.map, player_name))
    else
        MP.SendChatMessage(player_id, "BeamComp: could not write grids file")
    end

    -- Always echo the current names so the editor's dropdown reflects the post-delete state.
    local names = {}
    local map_grids = grid_store.grids[payload.map]
    if type(map_grids) == "table" then
        for grid_name in pairs(map_grids) do
            names[#names + 1] = grid_name
        end
        table.sort(names)
    end
    send_event(player_id, MSG_GRID_LIST, {names = names})
end

-- Return a saved grid's data so the editor can reopen it (ADR-0023). Read-only, so ungated like
-- /races. A missing map/name or unknown grid replies found = false rather than an error.
local function handle_grid_fetch(player_id, payload)
    if type(payload) ~= "table" or type(payload.map) ~= "string" or type(payload.name) ~= "string" then
        send_event(player_id, MSG_GRID_DATA, {found = false})
        return
    end
    ensure_grids_loaded()
    local map_grids = grid_store.grids[payload.map]
    local record = type(map_grids) == "table" and map_grids[payload.name] or nil
    if type(record) ~= "table" then
        send_event(player_id, MSG_GRID_DATA, {name = payload.name, found = false})
        return
    end
    send_event(player_id, MSG_GRID_DATA, {
        name = payload.name,
        found = true,
        forward = record.forward,
        reverse = record.reverse,
        race = record.race,
    })
end

-- Return the saved grid names for a map (ADR-0023). Read-only, sorted for a stable listing.
local function handle_grid_list_request(player_id, payload)
    ensure_grids_loaded()
    local names = {}
    local map = type(payload) == "table" and payload.map or nil
    local map_grids = type(map) == "string" and grid_store.grids[map] or nil
    if type(map_grids) == "table" then
        for name in pairs(map_grids) do
            names[#names + 1] = name
        end
        table.sort(names)
    end
    send_event(player_id, MSG_GRID_LIST, {names = names})
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
        grid = (type(raw.grid) == "string" and raw.grid ~= "") and raw.grid or nil,
    }

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
    end

    -- Qualifying length (ADR-0041): a UI-supplied minutes value for order=quali, clamped to bounds.
    local quali_minutes = tonumber(raw.qualiMinutes)
    if quali_minutes then
        overrides.quali_duration = quali.clamp(quali_minutes * 60)
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
    elseif decoded.type == MSG_SPAWN_READY then
        handle_spawn_ready(player_id, decoded.payload)
    elseif decoded.type == MSG_CLIENT_INFO then
        handle_client_info(player_id, decoded.payload)
    elseif decoded.type == MSG_CLIENT_IDENTITY then
        handle_client_identity(player_id, decoded.payload)
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
    elseif decoded.type == MSG_START_RACE then
        handle_start_race(player_id, decoded.payload)
    elseif decoded.type == MSG_RACE_GO then
        handle_race_go(player_id)
    elseif decoded.type == champ.MSG_CMD then
        champ.handle_cmd(player_id, decoded.payload)
    else
        log_info("beamcomp.net", "no handler for client event type=" .. decoded.type)
    end
end

local function on_init()
    log_info("beamcomp", "server plugin loaded v" .. PLUGIN_VERSION)
    -- Seed the RNG for the random / no-source-fallback start orders (ADR-0033).
    math.randomseed(os.time())
    load_config()
    ensure_grids_loaded()
    ensure_records_loaded()
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
function beamcomp_on_disconnect(player_id)
    return on_player_disconnect(player_id)
end

-- BeamMP event handler (must be global)
function beamcomp_on_client_event(player_id, data)
    return handle_client_event(player_id, data)
end

MP.RegisterEvent("onChatMessage", "beamcomp_on_chat")
MP.RegisterEvent("onInit", "beamcomp_on_init")
MP.RegisterEvent("onPlayerDisconnect", "beamcomp_on_disconnect")
MP.RegisterEvent(TICK_EVENT, "beamcomp_on_tick")
MP.RegisterEvent(EVENT_CHANNEL, "beamcomp_on_client_event")

return M
