-- BeamComp -- BeamMP server plugin entry point.
--
-- Deployed to Resources/Server/BeamComp/. BeamMP loads every .lua file in the
-- plugin folder alphabetically at server start.
-- API reference: the BeamMP server-plugin recon note (kept in the project's
-- local docs).
--
-- Chat commands handled (exact match only):
--   /race      race-start stub -- acknowledges in chat + log; no race yet.
--   /beamcomp  diagnostic ping -- replies with plugin version + player count.
-- Both suppress their own chat echo. Anything else relays as normal chat.
-- Server -> client messaging (Sprint-1 item 5) and the actual race logic
-- (Phase 2+) are not here yet.

local M = {}

local PLUGIN_VERSION = "0.1.0"
local CHAT_COMMAND_RACE = "/race"
local CHAT_COMMAND_PING = "/beamcomp"

local function log_info(subsystem, msg)
    print("[" .. subsystem .. "] " .. msg)
end

local function handle_race_command(player_id, player_name)
    log_info("beamcomp.chat", CHAT_COMMAND_RACE .. " from " .. player_name .. " (id " .. player_id .. ")")
    MP.SendChatMessage(player_id, "BeamComp: /race empfangen (skeleton)")
end

local function handle_ping_command(player_id, player_name)
    local player_count = MP.GetPlayerCount()
    log_info("beamcomp", CHAT_COMMAND_PING .. " from " .. player_name .. " (id " .. player_id .. ")")
    MP.SendChatMessage(player_id, "BeamComp v" .. PLUGIN_VERSION .. " -- alive (" .. player_count .. " players online)")
end

local function on_chat_message(player_id, player_name, message)
    if message == CHAT_COMMAND_RACE then
        handle_race_command(player_id, player_name)
        return 1  -- suppress the command's own chat echo
    end

    if message == CHAT_COMMAND_PING then
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
