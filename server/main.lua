-- BeamComp -- BeamMP server plugin entry point.
--
-- Deployed to Resources/Server/BeamComp/. BeamMP loads every .lua file in the
-- plugin folder alphabetically at server start.
-- API reference: the BeamMP server-plugin recon note (kept in the project's
-- local docs).
--
-- Chat commands handled (leading token; trailing text is the argument):
--   /race <name>  assign every present player a slot and send each one a server->client
--                 "raceStart" event (channel "beamcompEvent") carrying its slot + the
--                 grid roster; the client resolves and parses <name> locally (ADR-0005).
--                 Bare /race replies with usage. The server never validates <name>.
--   /beamcomp     diagnostic ping -- replies in chat AND sends a "ping" event the client
--                 mod surfaces.
-- Both suppress their own chat echo. Anything else relays as normal chat.
-- Spawning/movement (Phase 2 items 3-5, Phase 3+) is not here yet.

local M = {}

local PLUGIN_VERSION = "0.1.0"
local CHAT_COMMAND_RACE = "/race"
local CHAT_COMMAND_PING = "/beamcomp"
-- Server -> client event channel. Must be colon-free: the BeamMP client parser
-- splits incoming events on ':' (see ADR-0004).
local EVENT_CHANNEL = "beamcompEvent"

local function log_info(subsystem, msg)
    print("[" .. subsystem .. "] " .. msg)
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

local function handle_race_command(player_id, player_name, race_name)
    if race_name == "" then
        MP.SendChatMessage(player_id, "BeamComp: usage -- /race <name>")
        return
    end

    local slots = build_slots(MP.GetPlayers())
    local roster = build_roster(slots)

    log_info("beamcomp.race", "race '" .. race_name .. "' requested by " .. player_name
        .. " (id " .. player_id .. ") for " .. #slots .. " player(s)")

    for _, entry in ipairs(slots) do
        send_event(entry.id, "raceStart", {
            race = race_name,
            slot = entry.slot,
            grid = roster,
            variant = "default",
        })
    end

    MP.SendChatMessage(player_id, "BeamComp: starting race '" .. race_name .. "' with "
        .. #slots .. " player(s)")
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

    if command == CHAT_COMMAND_PING then
        handle_ping_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end
    -- not a BeamComp command: return nothing so the message relays normally
end

local function on_init()
    log_info("beamcomp", "server plugin loaded v" .. PLUGIN_VERSION)
end

-- The two functions below are the only file-scope globals in this plugin.
-- BeamMP's MP.RegisterEvent binds a handler by its global function name, so the
-- registered entry points must be global. Each stays a thin wrapper that
-- delegates straight into a local function.

-- BeamMP event handler (must be global)
function beamcomp_on_chat(player_id, player_name, message)
    return on_chat_message(player_id, player_name, message)
end

-- BeamMP event handler (must be global)
function beamcomp_on_init()
    return on_init()
end

MP.RegisterEvent("onChatMessage", "beamcomp_on_chat")
MP.RegisterEvent("onInit", "beamcomp_on_init")

return M
