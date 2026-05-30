-- BeamComp -- BeamMP server plugin entry point.
--
-- Deployed to Resources/Server/BeamComp/. BeamMP loads every .lua file in the
-- plugin folder alphabetically at server start.
-- API reference: the BeamMP server-plugin recon note (kept in the project's
-- local docs). Design: ADR-0006 (server-side race state machine).
--
-- Owns a server-authoritative race state machine (ADR-0006):
--   lobby -> spawning -> countdown -> racing -> finished -> lobby
-- An always-on 250 ms tick (MP.CreateEventTimer) drives the timed transitions; a
-- monotonic MP.CreateTimer() stopwatch measures elapsed time per phase. Every
-- transition is broadcast to all clients as a "racePhase" envelope on the
-- "beamcompEvent" channel; the later Phase-3 items (movement lock, countdown UI,
-- release) act on those phases. Finish detection is active (ADR-0013): a player's final
-- crossing arms the finish grace and drives the racing -> finished transition (ADR-0006).
--
-- Chat commands handled (leading token; trailing text is the argument):
--   /race <name> [sprint|circuit] [laps] [recover[:secs]] [repair[:secs]]
--                 from lobby/finished: assign every present player a slot, send each a
--                 "raceStart" event (slot + grid roster + relayed mode/laps + recover/repair
--                 assists), and enter the spawning phase. The client resolves and parses <name>
--                 locally (ADR-0005) and decides the actual mode/laps; the optional sprint|circuit
--                 and lap-count tokens are relayed verbatim as overrides (ADR-0013), and the
--                 optional recover/repair[:secs] tokens relay the opt-in in-race assists (ADR-0017,
--                 default off) -- the server never validates any of them against geometry
--                 (race-blind). While a race is already running, /race queues the new race and runs
--                 a short abort window before restarting. Bare /race replies with usage.
--   /raceend      force the state machine back to lobby (safety hatch).
--   /races        list the time-trial races on the asking player's current map. The server is
--                 race-blind (ADR-0005), so it asks that client (a "listRaces" event); the client
--                 builds the list and sends it back ("raceList"), and the server posts it to the
--                 player. Reply is to the asker only.
--   /dnf          give up the current race: marks the issuing player DNF (did not finish). Racing
--                 only (ADR-0014).
--   /beamcomp     diagnostic ping -- replies in chat AND sends a "ping" event the client
--                 mod surfaces.
-- All five suppress their own chat echo. Anything else relays as normal chat.
-- The server never validates <name> (ADR-0005).

local M = {}

local PLUGIN_VERSION = "0.1.0"
local CHAT_COMMAND_RACE = "/race"
local CHAT_COMMAND_RACEEND = "/raceend"
local CHAT_COMMAND_RACES = "/races"
local CHAT_COMMAND_DNF = "/dnf"
local CHAT_COMMAND_PING = "/beamcomp"

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
-- Server -> client broadcast/request types.
local MSG_STANDINGS = "standings"     -- the live ranked standings table (broadcast)
local MSG_LIST_RACES = "listRaces"    -- ask one client to report its installed-race list (/races)
local MSG_FINISH_GRACE = "finishGrace"  -- the DNF-cutoff countdown duration, broadcast when armed (ADR-0014)

-- Cap on /races reply lines posted to chat, so a misbehaving client can't flood it.
local RACE_LIST_MAX_LINES = 60

-- State-machine tick. ~4x/second: fine enough for a 3-2-1-GO, idle cost is a nil-check.
local TICK_EVENT = "beamcompTick"
local TICK_INTERVAL_MS = 250

-- The five canonical race phases (the racePhase contract, ADR-0006). Referenced by name so a
-- typo is a load error, not a silent mis-compare.
local PHASE = {
    lobby = "lobby",
    spawning = "spawning",
    countdown = "countdown",
    racing = "racing",
    finished = "finished",
}

-- Phase durations in seconds. Editable server config (ADR-0006); not a runtime/in-game UI.
local PHASE_DURATIONS = {
    spawning = 3.0,       -- fixed wait for clients to resolve/parse/spawn (acks deferred: backlog)
    countdown = 3.0,      -- pre-race 3-2-1-GO
    finish_grace = 120.0, -- DNF cutoff: time after the first finisher for others to finish (ADR-0014)
    all_done_grace = 5.0, -- shortened grace once no one can still finish (ADR-0014 early-end)
    abort_window = 1.5,   -- short finished window when /race restarts a running race
    finished_hold = 15.0, -- results-display window before returning to lobby (ADR-0006)
}

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
    pending_race = nil,     -- race name queued by a /race re-issued while one is active
    pending_owner = nil,    -- player id of the queued race's issuer (owns its shared props), or nil
    pending_mode = nil,     -- queued race's relayed mode override ("sprint"/"circuit"), or nil
    pending_laps = nil,     -- queued race's relayed lap-count override, or nil
    pending_assists = nil,  -- queued race's relayed recover/repair assist options (ADR-0017), or nil
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

    local config, path, err = read_config()
    if not config then
        if err == "parse" then
            log_info("beamcomp.cfg", "config at " .. tostring(path)
                .. " is not valid JSON; race-admin gate inactive")
        else
            log_info("beamcomp.cfg", "no config file found; race-admin gate inactive")
        end
        return
    end

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

-- Assign every connected player a 0-based slot, ordered by player id ascending. The
-- order is deterministic so every client computes the same grid from the same roster.
local function build_slots(players)
    local ids = {}
    for id in pairs(players) do
        ids[#ids + 1] = id
    end
    table.sort(ids)

    local slots = {}
    for index, id in ipairs(ids) do
        slots[#slots + 1] = {id = id, slot = index - 1, name = players[id]}
    end
    return slots
end

-- The roster shipped to every client: each player's slot + name, in slot order. Used
-- client-side for the full grid layout and marker labels.
local function build_roster(slots)
    local roster = {}
    for _, entry in ipairs(slots) do
        roster[#roster + 1] = {slot = entry.slot, name = entry.name}
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
            name = entry.name,
            slot = entry.slot,
            completed = 0,
            splits = {},
            total_time = 0,
            finished = false,
            dnf = false,
            lap = 1,
        }
    end
    return progress
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
    for _, record in pairs(session.progress) do
        ranked[#ranked + 1] = record
        if not known_count and record.count then
            known_count = record.count
        end
    end
    table.sort(ranked, function(a, b)
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
    for i, record in ipairs(ranked) do
        entries[i] = {
            position = i,
            slot = record.slot,
            name = record.name,
            completed = record.completed,
            count = record.count or known_count,
            total_time = record.total_time,
            finished = record.finished,
            dnf = record.dnf,
            lap = record.lap,
            -- Cumulative race-relative time at each scored crossing (ADR-0015). Shallow reference --
            -- downstream readers must not mutate. DNF entries carry only the splits completed before
            -- DNF; the results UI derives segment deltas from this.
            splits = record.splits,
        }
    end
    return entries
end

-- Broadcast the standings to every client as a `standings` envelope (ADR-0004). Fired at the
-- racing-phase baseline and after every accepted checkpoint report.
local function broadcast_standings()
    broadcast_event(MSG_STANDINGS, {entries = build_standings()})
end

-- Clear the session and announce the lobby phase.
local function reset_to_lobby()
    session.race = nil
    session.roster = nil
    session.progress = nil
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_mode = nil
    session.pending_laps = nil
    session.pending_assists = nil
    enter_phase(PHASE.lobby, nil)
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
-- mode/laps), and enter the spawning phase. The client resolves and parses the race name locally
-- (ADR-0005) and decides the actual mode/laps; `mode` ("sprint"/"circuit") and `laps` are the
-- admin's overrides relayed verbatim, or nil for "auto" (the client derives them from the race
-- file -- ADR-0013). `owner_id` is the player that issued /race; exactly that player's raceStart
-- carries propOwner = true, designating it as the one client that spawns the shared race props --
-- the knockable cones -- which BeamMP then syncs to every other client (ADR-0009). `assists` carries
-- the per-race recover/repair options (ADR-0017), relayed verbatim like mode/laps (race-blind).
local function start_race(race_name, owner_id, mode, laps, assists)
    local slots = build_slots(MP.GetPlayers())
    local roster = build_roster(slots)

    session.race = race_name
    session.roster = roster
    session.progress = build_progress(slots)
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil
    session.pending_mode = nil
    session.pending_laps = nil
    session.pending_assists = nil

    log_info("beamcomp.race", "starting '" .. race_name .. "' for " .. #slots .. " player(s)")

    for _, entry in ipairs(slots) do
        send_event(entry.id, MSG_RACE_START, {
            race = race_name,
            slot = entry.slot,
            grid = roster,
            variant = "default",
            propOwner = entry.id == owner_id,
            mode = mode,  -- nil = auto (client derives from meta.closed); ADR-0013
            laps = laps,  -- nil = auto (client uses meta.defaultLaps); ADR-0013
            -- Opt-in recover/repair assists (ADR-0017); clients enforce. Disabled by default.
            recoverEnabled = assists.recoverEnabled,
            recoverHoldSeconds = assists.recoverHoldSeconds,
            repairEnabled = assists.repairEnabled,
            repairHoldSeconds = assists.repairHoldSeconds,
        })
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
        local mode = session.pending_mode
        local laps = session.pending_laps
        local assists = session.pending_assists
        session.pending_race = nil
        session.pending_owner = nil
        session.pending_mode = nil
        session.pending_laps = nil
        session.pending_assists = nil
        start_race(pending, owner, mode, laps, assists)
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
local function tick()
    local phase = session.phase
    if phase == PHASE.lobby then
        return
    end

    -- racing ends when the finish grace (armed by the first finisher) elapses; any player still out
    -- on track at that point is marked DNF before the race settles (ADR-0014).
    if phase == PHASE.racing then
        if session.grace_deadline and now() >= session.grace_deadline then
            dnf_active_players("grace expired")
            enter_phase(PHASE.finished, PHASE_DURATIONS.finished_hold)
        end
        return
    end

    -- Every other active phase is timed: advance once its configured duration elapses.
    if not session.phase_duration or phase_elapsed() < session.phase_duration then
        return
    end

    if phase == PHASE.spawning then
        enter_phase(PHASE.countdown, PHASE_DURATIONS.countdown)
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
    "BeamComp: usage -- /race <name> [sprint|circuit] [laps] [recover[:secs]] [repair[:secs]]"

-- Valid /race mode-override tokens; anything else (besides a bare integer lap count or a
-- recover/repair assist token) is rejected.
local RACE_MODES = {sprint = true, circuit = true}

-- Opt-in recover/repair assist hold time (ADR-0017): the seconds the player must hold the key before
-- the assist fires. Used when a "recover"/"repair" token carries no explicit ":secs", and as the
-- clamp bounds for one that does.
local ASSIST_DEFAULT_HOLD_SECONDS = 5
local ASSIST_MIN_HOLD_SECONDS = 1
local ASSIST_MAX_HOLD_SECONDS = 30

-- Clamp a requested assist hold time into the sane [min, max] range.
local function clamp_assist_hold(seconds)
    return math.max(ASSIST_MIN_HOLD_SECONDS, math.min(ASSIST_MAX_HOLD_SECONDS, seconds))
end

-- Read a recover/repair assist token: returns the (clamped) hold seconds if `token` is `keyword` or
-- `keyword:<secs>`, else nil. A bare keyword uses the default hold; `keyword:<secs>` is clamped. A
-- malformed `keyword:<non-digits>` returns nil so the caller rejects it as an unknown token.
local function parse_assist_token(token, keyword)
    local lowered = token:lower()
    if lowered == keyword then
        return ASSIST_DEFAULT_HOLD_SECONDS
    end
    local seconds = lowered:match("^" .. keyword .. ":(%d+)$")
    if seconds then
        return clamp_assist_hold(math.floor(tonumber(seconds)))
    end
    return nil
end

-- Parse a /race argument into the race name plus optional overrides (ADR-0013, ADR-0017). The first
-- whitespace token is the race name (race ids are slug-based, no spaces -- ADR-0005); of the rest, a
-- "sprint"/"circuit" token sets the mode, a bare integer sets the lap count, and "recover"/"repair"
-- (optionally ":secs") enable the matching assist -- all order-independent. Returns name (nil if the
-- argument is empty), mode (or nil = auto), laps (or nil = auto), an assists table (always present,
-- both disabled by default), and the first unrecognized token (or nil) so the caller can reply usage.
local function parse_race_args(argument)
    local tokens = {}
    for token in argument:gmatch("%S+") do
        tokens[#tokens + 1] = token
    end

    local name = tokens[1]
    local mode, laps, bad_token
    local assists = {recoverEnabled = false, repairEnabled = false}
    for i = 2, #tokens do
        local token = tokens[i]
        local recover_hold = parse_assist_token(token, "recover")
        local repair_hold = parse_assist_token(token, "repair")
        if RACE_MODES[token:lower()] then
            mode = token:lower()
        elseif recover_hold then
            assists.recoverEnabled = true
            assists.recoverHoldSeconds = recover_hold
        elseif repair_hold then
            assists.repairEnabled = true
            assists.repairHoldSeconds = repair_hold
        elseif token:match("^%d+$") then
            laps = math.floor(tonumber(token))
        elseif not bad_token then
            bad_token = token
        end
    end
    return name, mode, laps, assists, bad_token
end

-- /race <name> [mode] [laps]: from an idle/finished session start the race; from an active one queue
-- the new race and cut the current one short with a brief abort window before it restarts (ADR-0006).
-- mode/laps are relayed verbatim to clients (race-blind, ADR-0013).
local function handle_race_command(player_id, player_name, argument)
    if not is_race_admin(player_name) then
        MP.SendChatMessage(player_id, "BeamComp: you are not allowed to start races")
        log_info("beamcomp.race", "denied /race from " .. player_name .. " (not a race admin)")
        return
    end

    local race_name, mode, laps, assists, bad_token = parse_race_args(argument)

    if not race_name then
        MP.SendChatMessage(player_id, RACE_USAGE)
        return
    end
    if bad_token then
        MP.SendChatMessage(player_id, "BeamComp: unknown option '" .. bad_token .. "' -- " .. RACE_USAGE)
        return
    end

    log_info("beamcomp.race", string.format("/race '%s' by %s (phase %s)%s%s%s%s",
        race_name, player_name, session.phase,
        mode and (" mode=" .. mode) or "", laps and (" laps=" .. laps) or "",
        assists.recoverEnabled and (" recover=" .. assists.recoverHoldSeconds .. "s") or "",
        assists.repairEnabled and (" repair=" .. assists.repairHoldSeconds .. "s") or ""))

    if session.phase == PHASE.lobby or session.phase == PHASE.finished then
        start_race(race_name, player_id, mode, laps, assists)
        MP.SendChatMessage(player_id, "BeamComp: starting race '" .. race_name .. "'")
        return
    end

    session.pending_race = race_name
    session.pending_owner = player_id
    session.pending_mode = mode
    session.pending_laps = laps
    session.pending_assists = assists
    enter_phase(PHASE.finished, PHASE_DURATIONS.abort_window)
    MP.SendChatMessage(player_id, "BeamComp: restarting with race '" .. race_name .. "'")
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
    if session.phase == PHASE.lobby then
        return
    end
    if is_server_empty_without(player_id) then
        log_info("beamcomp.race", "all players gone; returning to lobby")
        reset_to_lobby()
        return
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

    if command == CHAT_COMMAND_RACES then
        -- Race-blind (ADR-0005): ask the asking client to report its race list; it replies with a
        -- raceList event we post back (handle_race_list).
        send_event(player_id, MSG_LIST_RACES, {})
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

    local record = session.progress and session.progress[player_id]
    if not record then
        log_info("beamcomp.race", "checkpoint report from id " .. tostring(player_id)
            .. " ignored: no race record")
        return
    end

    -- A finished or DNF player is terminal (ADR-0014): drop further reports so a DNF'd player who keeps
    -- driving can never progress or set finished. (Finished players' clients stop sending; this also
    -- guards a DNF'd player whose detector is still armed.)
    if record.finished or record.dnf then
        log_info("beamcomp.race", "checkpoint report from id " .. tostring(player_id)
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

    if seq ~= record.completed then
        log_info("beamcomp.race", string.format(
            "player %d out-of-order checkpoint: got seq %d, expected %d",
            player_id, seq, record.completed))
        return
    end

    record.completed = record.completed + 1
    if count then
        record.count = count
    end
    if lap then
        record.lap = lap
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
    log_info("beamcomp.race", string.format("player %d checkpoint %s%s%s @ %.2fs%s",
        player_id, progress_label,
        lap and string.format(" lap %d", lap) or "",
        index and string.format(" (cp %d)", index) or "",
        time, final and " (final)" or ""))

    broadcast_standings()
    if final then
        maybe_end_race()
    end
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
    elseif decoded.type == MSG_RACE_LIST then
        handle_race_list(player_id, decoded.payload)
    else
        log_info("beamcomp.net", "no handler for client event type=" .. decoded.type)
    end
end

local function on_init()
    log_info("beamcomp", "server plugin loaded v" .. PLUGIN_VERSION)
    load_config()
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
