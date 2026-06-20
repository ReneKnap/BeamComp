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
-- up for PHASE_DURATIONS.finished_hold (or until /raceend) with a heads-up before cleanup.
-- An always-on 250 ms tick (MP.CreateEventTimer) drives the timed transitions; a
-- monotonic MP.CreateTimer() stopwatch measures elapsed time per phase. Every
-- transition is broadcast to all clients as a "racePhase" envelope on the
-- "beamcompEvent" channel; the later Phase-3 items (movement lock, countdown UI,
-- release) act on those phases. Finish detection is active (ADR-0013): a player's final
-- crossing arms the finish grace and drives the racing -> finished transition (ADR-0006).
--
-- Chat commands handled (leading token; trailing text is the argument):
--   /race [map:|menu:]<name> [sprint|circuit] [laps] [reverse] [force] [recover[:secs]] [repair[:secs]] [grid=<name>] [car=<model[:config]>] [maxhp=<n>] [maxpwr=<n>] [order=entry|random|last|pwr[:rev]] [ai <n> [easy|medium|hard]] [aicar=<model[:config]>] [aiaggr=/aiskill=/airubber=<0..1>] [all]
--                 (each keyword token also accepts any unambiguous prefix: s/c, rev, f, rec/rep)
--                 vehicle policy (ADR-0032): car=<model[:config]> = one fixed car for everyone (Mode 2);
--                 maxhp=<n> (hp) / maxpwr=<n> (power-to-weight, hp per kg) = per-player caps that keep a
--                 compliant car or substitute one (Mode 3); none = keep own car (Mode 1). car= wins.
--                 AI opponents (ADR-0036): ai <n> [preset] adds n host-driven AI (no count = content
--                 default, [1..16]); preset easy|medium|hard, aicar=/aiaggr=/aiskill=/airubber=/aiavoid=
--                 configure their vehicle + driving. airoute=snap|direct picks the AI line (snap =
--                 road-navgraph snap, default; direct = exact custom-navgraph race line, off-road,
--                 Step-3b). AI mix into random and sort by reported pwr; else back of grid.
--                 start order (ADR-0033): order=entry (default) | random | last (prev race result) |
--                 pwr (power-to-weight); :rev flips a directional mode (last:rev/pwr:rev = handicap).
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
--   /raceend      force the state machine back to lobby (safety hatch).
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
local CHAT_COMMAND_RACEEND = "/raceend"
local CHAT_COMMAND_RACES = "/races"
local CHAT_COMMAND_CARS = "/cars"  -- list installed vehicle models, or one model's configs (ADR-0032)
local CHAT_COMMAND_DNF = "/dnf"
local CHAT_COMMAND_PING = "/beamcomp"
local CHAT_COMMAND_RESULTS = "/results"  -- toggle the asking player's finished-results card (ADR-0022)
local CHAT_COMMAND_ANALYSIS = "/analysis"  -- toggle the asking player's post-race analysis overlay (ADR-0028)
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
local MSG_GRID_FETCH = "gridFetch"    -- editor opens a saved grid: request its data (ADR-0023; read-only)
local MSG_GRID_LIST_REQ = "gridListReq"  -- editor lists a map's saved grids (ADR-0023; read-only)
local MSG_GRID_DATA = "gridData"      -- reply to gridFetch: a saved grid's params (server -> client)
local MSG_GRID_LIST = "gridList"      -- reply to gridListReq: the map's saved grid names (server -> client)
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
    pending_validation = nil, -- in-flight pre-flight check {race, overrides, owner_id, nonce, deadline} (ADR-0019)
    validation_seq = 0,       -- monotonic nonce source so a stale/duplicate raceValidation is ignored
    cleanup_warned = false,   -- one-shot guard for the ~60 s "props/results clear soon" warning (B3)
    spawn_pending = nil,      -- set of rostered player ids whose spawnReady ack is still awaited (ADR-0006 amendment)
    spawn_ready_count = 0,    -- how many distinct clients acked spawnReady this race (0 at timeout = empty race)
    identities = nil,         -- per-player {vehicle, pwr} reported via clientInfo, for records (ADR-0027) + start-order (ADR-0033); name moved to client_names (ADR-0031)
    order = nil,              -- this race's start-order {mode, rev} (ADR-0033), or nil = entry order
    last_order = nil,         -- previous race's finishing order as a list of identities (ADR-0033); session-scoped, survives reset_to_lobby so order=last has a source
    owner_id = nil,           -- player id that issued the active race -- the prop + AI owner (ADR-0009/0036), or nil
}

-- Race-command permissions / plugin config (ADR-0016). The race-admin allowlist gates /race and
-- /raceend; it is loaded on init from the plugin config file. Candidate paths tolerate the unverified
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
local function enter_phase(phase, duration)
    session.phase = phase
    session.phase_duration = duration
    session.phase_started_at = now()
    log_info("beamcomp.race", "phase -> " .. phase)
    broadcast_event(MSG_RACE_PHASE, {phase = phase, duration = duration})
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

-- Order the player ids for slot assignment per the start-order mode (ADR-0033). `entry` (default) is id
-- ascending -- the historical order and the stable base the other modes build on; `random` shuffles;
-- `last` follows the previous race's finishing order (by identity, ADR-0031), with players absent from it
-- appended at the back in entry order, and `:rev` reversing just the placed group. `pwr` orders as entry
-- here -- it is resolved after staging by the re-grid -- and `last` with no source falls back to random.
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
        local rank = {}
        for pos, identity in ipairs(last_order) do
            rank[identity] = pos
        end
        local placed, rest = {}, {}
        for _, id in ipairs(ids) do  -- ids are in entry order, so rest stays entry-ordered
            if rank[resolve_identity(id)] then
                placed[#placed + 1] = id
            else
                rest[#rest + 1] = id
            end
        end
        table.sort(placed, function(a, b)
            return rank[resolve_identity(a)] < rank[resolve_identity(b)]
        end)
        if order.rev then
            for i = 1, math.floor(#placed / 2) do
                placed[i], placed[#placed - i + 1] = placed[#placed - i + 1], placed[i]
            end
        end
        for _, id in ipairs(rest) do
            placed[#placed + 1] = id
        end
        return placed
    end

    -- entry, or pwr (provisional entry order until the post-staging re-grid resolves it).
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
-- entry/last/pwr the players are ordered first and the AI appended at the back -- their natural position
-- (no entry/finish history) and it avoids the mixed numeric/string id sort. pwr re-sorts the AI into the
-- field after staging (regrid_by_pwr). Deterministic for a given mode + roster so every client computes
-- the same grid.
local function build_slots(players, order, last_order, ai_count)
    local ids
    if order and order.mode == "random" then
        ids = {}
        for id in pairs(players) do
            ids[#ids + 1] = id
        end
        for _, ai_id in ipairs(ai_id_list(ai_count)) do
            ids[#ids + 1] = ai_id
        end
        ids = shuffle(ids)
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
-- back to free-roam (B3) -- so a /raceend or the finished-window expiry has a visible close-out.
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
    session.cleanup_warned = false
    session.spawn_pending = nil
    session.spawn_ready_count = 0
    session.identities = nil
    session.owner_id = nil
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
local function start_race(race_name, owner_id, overrides, map, race_id)
    -- Resolve the grid start order (ADR-0033): entry/random/last are applied to the slot assignment now;
    -- pwr is provisional here and re-gridded after staging. last reads the previous race's finishing order.
    session.order = overrides.order
    -- The requested AI opponents become synthetic participant slots (ADR-0036), so the roster, grid
    -- layout, and standings include them like any participant; the owner spawns + drives them. They mix
    -- into a random order and sort by reported pwr; otherwise they take the back of the grid.
    local slots = build_slots(MP.GetPlayers(), overrides.order, session.last_order,
        overrides.ai and overrides.ai.count)
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
        session.pending_race = nil
        session.pending_owner = nil
        session.pending_overrides = nil
        session.pending_map = nil
        session.pending_race_id = nil
        start_race(pending, owner, overrides, map, race_id)
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
    broadcast_chat("BeamComp: race props and results clear in 1 minute -- /raceend to clear now")
end

-- Leave the spawning phase once every rostered player is accounted for -- acked via spawnReady or
-- gone (pruned on disconnect) -- or the spawning timeout caps the wait (ADR-0006 amendment). If not a
-- single client acked by then, the roster never spawned (all left or none ran the mod), so abort to
-- lobby instead of running an empty race until /raceend; otherwise proceed to staging. A no-op until
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
            dnf_active_players("grace expired")
            -- Snapshot pre-run per-car section bests BEFORE capture folds this run in, so the Race
            -- section can show "vs your/anyone's previous best lap with the car"; then capture (this run
            -- now counts) and send the current-inclusive records (ADR-0030).
            local prerun = snapshot_prerun_section_bests()
            capture_records()
            send_race_records(prerun)
            -- Remember the finishing order so the next race's order=last can grid by it (ADR-0033).
            capture_finishing_order()
            enter_phase(PHASE.finished, PHASE_DURATIONS.finished_hold)
        end
        return
    end

    -- spawning ends on spawn-ready acks (or a timeout), not a fixed delay -- handled ahead of the
    -- generic timed advance so a full ack set can leave early (ADR-0006 amendment).
    if phase == PHASE.spawning then
        advance_spawning()
        return
    end

    -- Every other active phase is timed: advance once its configured duration elapses.
    if not session.phase_duration or phase_elapsed() < session.phase_duration then
        return
    end

    if phase == PHASE.staging then
        enter_countdown_from_staging()
    elseif phase == PHASE.countdown then
        -- The release signal itself is a later Phase-3 item; here we enter racing and send the
        -- baseline standings (every player at zero) so clients have a table to show from the start.
        enter_phase(PHASE.racing, nil)
        broadcast_standings()
    elseif phase == PHASE.finished then
        advance_from_finished()
    end
end

local RACE_USAGE =
    "BeamComp: usage -- /race [map:|menu:]<name> [sprint|circuit] [laps] [reverse] [force] "
    .. "[recover[:secs|off]] [repair[:secs|off]] [grid=<name>] [car=<model[:config]>] "
    .. "[maxhp=<n>] [maxpwr=<n>] [order=entry|random|last|pwr[:rev]] "
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

-- Start-order modes for /race order= (ADR-0033). entry/random are non-directional; last/pwr accept :rev.
local ORDER_MODES = {entry = true, random = true, last = true, pwr = true}

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

-- /race <name> [options]: from an idle/finished session start the race; from an active one queue the
-- new race and cut the current one short with a brief abort window before it restarts (ADR-0006). The
-- overrides (mode/laps/direction/force/assists) are relayed verbatim to clients (race-blind, ADR-0013/
-- 0018); the client validates them against the parsed race geometry.
local function handle_race_command(player_id, player_name, argument)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to start races")
        log_info("beamcomp.race", "denied /race from " .. player_name .. " (not a race admin)")
        return
    end

    local race_name, overrides, bad_token = parse_race_args(argument)

    if not race_name then
        MP.SendChatMessage(player_id, RACE_USAGE)
        return
    end
    if bad_token then
        MP.SendChatMessage(player_id, "BeamComp: unknown option '" .. bad_token .. "' -- " .. RACE_USAGE)
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
        "/race '%s' by %s (phase %s)%s%s%s%s recover=%s repair=%s%s%s%s%s%s",
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
    -- lets a stale/duplicate reply (e.g. a re-issued /race) be ignored.
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

-- Start (or, mid-race, queue) a race whose options the issuer's client has validated (ADR-0019). The
-- phase is re-checked here, not at request time, since the race may have ended while the check was in
-- flight: from lobby/finished start now; from an active phase queue + run the brief abort window.
local function commit_validated_race(race_name, owner_id, overrides, map, race_id)
    if session.phase == PHASE.lobby or session.phase == PHASE.finished then
        start_race(race_name, owner_id, overrides, map, race_id)
        MP.SendChatMessage(owner_id, "BeamComp: starting race '" .. race_name .. "'")
        return
    end

    session.pending_race = race_name
    session.pending_owner = owner_id
    session.pending_overrides = overrides
    session.pending_map = map
    session.pending_race_id = race_id
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
        commit_validated_race(pending.race, pending.owner_id, overrides, map, race_id)
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

-- /raceend: force the machine back to lobby from any active phase (safety hatch).
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
    log_info("beamcomp.race", "/raceend by " .. player_name)
    reset_to_lobby()
    MP.SendChatMessage(player_id, "BeamComp: race ended")
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

    if session.phase ~= PHASE.racing then
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
    elseif decoded.type == MSG_GRID_FETCH then
        handle_grid_fetch(player_id, decoded.payload)
    elseif decoded.type == MSG_GRID_LIST_REQ then
        handle_grid_list_request(player_id, decoded.payload)
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
