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
-- release) act on those phases. The finish-grace hook and the racing -> finished
-- trigger are built but dormant -- finish detection lands in Phase 4.
--
-- Chat commands handled (leading token; trailing text is the argument):
--   /race <name>  from lobby/finished: assign every present player a slot, send each a
--                 "raceStart" event (slot + grid roster), and enter the spawning phase. The
--                 client resolves and parses <name> locally (ADR-0005). While a race is
--                 already running, /race queues the new race and runs a short abort window
--                 before restarting. Bare /race replies with usage.
--   /raceend      force the state machine back to lobby (safety hatch).
--   /beamcomp     diagnostic ping -- replies in chat AND sends a "ping" event the client
--                 mod surfaces.
-- All three suppress their own chat echo. Anything else relays as normal chat.
-- The server never validates <name> (ADR-0005).

local M = {}

local PLUGIN_VERSION = "0.1.0"
local CHAT_COMMAND_RACE = "/race"
local CHAT_COMMAND_RACEEND = "/raceend"
local CHAT_COMMAND_PING = "/beamcomp"

-- Server <-> client event channel. Must be colon-free: the BeamMP client parser
-- splits incoming events on ':' (see ADR-0004). Bidirectional (ADR-0011): the server
-- sends raceStart/racePhase/ping on it via TriggerClientEventJson, and receives client
-- reports on it via MP.RegisterEvent (the client fires TriggerServerEvent on the same name).
local EVENT_CHANNEL = "beamcompEvent"
local MSG_RACE_START = "raceStart"
local MSG_RACE_PHASE = "racePhase"
-- Client -> server message type (received on EVENT_CHANNEL; ADR-0011).
local MSG_CHECKPOINT = "checkpoint"

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
    finish_grace = 30.0,  -- after the first finisher (Phase-4 hook; dormant here)
    abort_window = 1.5,   -- short finished window when /race restarts a running race
    finished_hold = 8.0,  -- results/cleanup window before returning to lobby
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
}


local function log_info(subsystem, msg)
    print("[" .. subsystem .. "] " .. msg)
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
-- player's checkpoint progress, cumulative split times, and total time; `finished` flips on the
-- final crossing and leaves room for a future DNF state (Phase 5). Splits are 1-based: splits[k] is
-- the cumulative race-relative time at the k-th checkpoint; segment deltas are derived, not stored.
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
        }
    end
    return progress
end

-- Clear the session and announce the lobby phase.
local function reset_to_lobby()
    session.race = nil
    session.roster = nil
    session.progress = nil
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil
    enter_phase(PHASE.lobby, nil)
end

-- Begin a fresh race: assign slots, send each player its raceStart (slot + grid roster), and
-- enter the spawning phase. The client resolves and parses the race name locally (ADR-0005).
-- `owner_id` is the player that issued /race; exactly that player's raceStart carries
-- propOwner = true, designating it as the one client that spawns the shared race props -- the
-- knockable cones -- which BeamMP then syncs to every other client (ADR-0009).
local function start_race(race_name, owner_id)
    local slots = build_slots(MP.GetPlayers())
    local roster = build_roster(slots)

    session.race = race_name
    session.roster = roster
    session.progress = build_progress(slots)
    session.grace_deadline = nil
    session.pending_race = nil
    session.pending_owner = nil

    log_info("beamcomp.race", "starting '" .. race_name .. "' for " .. #slots .. " player(s)")

    for _, entry in ipairs(slots) do
        send_event(entry.id, MSG_RACE_START, {
            race = race_name,
            slot = entry.slot,
            grid = roster,
            variant = "default",
            propOwner = entry.id == owner_id,
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
end

-- A finished phase either restarts into a queued race (a re-issued /race) or settles to lobby.
local function advance_from_finished()
    local pending = session.pending_race
    if pending then
        local owner = session.pending_owner
        session.pending_race = nil
        session.pending_owner = nil
        start_race(pending, owner)
        return
    end
    reset_to_lobby()
end

-- Advance the state machine one step. Runs on every tick; a no-op while idle in lobby.
local function tick()
    local phase = session.phase
    if phase == PHASE.lobby then
        return
    end

    -- racing is open-ended: it ends only when the (Phase-3-dormant) finish grace elapses.
    if phase == PHASE.racing then
        if session.grace_deadline and now() >= session.grace_deadline then
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
        -- The release signal itself is a later Phase-3 item; here we only enter racing.
        enter_phase(PHASE.racing, nil)
    elseif phase == PHASE.finished then
        advance_from_finished()
    end
end

-- /race <name>: from an idle/finished session start the race; from an active one queue the new
-- race and cut the current one short with a brief abort window before it restarts (ADR-0006).
local function handle_race_command(player_id, player_name, race_name)
    if race_name == "" then
        MP.SendChatMessage(player_id, "BeamComp: usage -- /race <name>")
        return
    end

    log_info("beamcomp.race", "/race '" .. race_name .. "' by " .. player_name
        .. " (phase " .. session.phase .. ")")

    if session.phase == PHASE.lobby or session.phase == PHASE.finished then
        start_race(race_name, player_id)
        MP.SendChatMessage(player_id, "BeamComp: starting race '" .. race_name .. "'")
        return
    end

    session.pending_race = race_name
    session.pending_owner = player_id
    enter_phase(PHASE.finished, PHASE_DURATIONS.abort_window)
    MP.SendChatMessage(player_id, "BeamComp: restarting with race '" .. race_name .. "'")
end

-- /raceend: force the machine back to lobby from any active phase (safety hatch).
local function handle_raceend_command(player_id, player_name)
    if session.phase == PHASE.lobby then
        MP.SendChatMessage(player_id, "BeamComp: no race in progress")
        return
    end
    log_info("beamcomp.race", "/raceend by " .. player_name)
    reset_to_lobby()
    MP.SendChatMessage(player_id, "BeamComp: race ended")
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

-- If the last player leaves mid-race there is no one to race -- fall back to lobby.
local function on_player_disconnect(player_id)
    if session.phase == PHASE.lobby then
        return
    end
    if is_server_empty_without(player_id) then
        log_info("beamcomp.race", "all players gone; returning to lobby")
        reset_to_lobby()
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

    if command == CHAT_COMMAND_PING then
        handle_ping_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end
    -- not a BeamComp command: return nothing so the message relays normally
end

-- Record one client checkpoint report into the reporting player's progress (ADR-0011 path).
-- Advances the completed count, appends the cumulative split time, updates the running total, and
-- arms the finish grace (the ADR-0006 racing -> finished seam) on the final crossing. Stays
-- race-blind (ADR-0005): progress and the finish threshold come from the payload index/count, not
-- race geometry. Strict-sequential: only the next expected index is accepted; duplicates, gaps,
-- out-of-order, a report outside racing, or one from an unseeded player are logged and dropped.
local function handle_checkpoint_report(player_id, payload)
    if type(payload) ~= "table" or type(payload.index) ~= "number" then
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

    -- Coerce to integers: a fractional index/count from a bad client would break the %d formatting
    -- (Lua 5.3 rejects non-integer floats) and the ordering compare. count may be absent, in which
    -- case finish cannot be detected and only progress is tracked.
    local index = math.floor(payload.index)
    local count = (type(payload.count) == "number") and math.floor(payload.count) or nil
    local time = tonumber(payload.time) or 0

    if index ~= record.completed then
        log_info("beamcomp.race", string.format(
            "player %d out-of-order checkpoint: got %d, expected %d",
            player_id, index, record.completed))
        return
    end

    record.completed = record.completed + 1
    if count then
        record.count = count
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
    log_info("beamcomp.race", string.format("player %d checkpoint %s @ %.2fs%s",
        player_id, progress_label, time, final and " (final)" or ""))
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
    else
        log_info("beamcomp.net", "no handler for client event type=" .. decoded.type)
    end
end

local function on_init()
    log_info("beamcomp", "server plugin loaded v" .. PLUGIN_VERSION)
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
