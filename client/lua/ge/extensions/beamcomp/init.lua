-- BeamComp -- client GE (Game-Engine) extension.
--
-- Lives at lua/ge/extensions/beamcomp/init.lua inside the client mod zip and
-- loads under the name `beamcomp_init` (brought up by scripts/beamcomp/modScript.lua).
-- The GE VM owns the scene, level, UI, camera, and vehicle spawning, and is where
-- the BeamMP client<->server messaging endpoint lives.
--
-- Receives server->client events on the "beamcompEvent" channel (ADR-0004: the
-- name is colon-free because the BeamMP client parser splits names on ':'). Each
-- event is a JSON envelope { type, payload }; we decode it with the shared envelope
-- module, log it, and surface an on-screen toast. No race logic yet (Phase 2+).

local M = {}

local envelope = require("beamcomp/envelope")

local EVENT_CHANNEL = "beamcompEvent"
local LOG_TAG = "beamcomp.net"

-- Reload-surviving state (BeamNG serializes M.state across a Lua reload).
M.state = {
    last_event_at = 0,
    registered = false,
}

-- Handle one server->client event. `data` arrives as a JSON string -- the BeamMP
-- client delivers event payloads as strings, regardless of how the server sent them.
local function on_server_event(data)
    local message_type, payload = envelope.decode(data)
    if not message_type then
        -- On failure envelope.decode returns (nil, error_message).
        log("W", LOG_TAG, "dropped malformed server event: " .. tostring(payload))
        return
    end

    M.state.last_event_at = os.time()
    log("I", LOG_TAG, "server event type=" .. tostring(message_type))
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Server event: " .. tostring(message_type),
    })
end

-- Register the server->client handler. AddEventHandler is a GE global provided by
-- BeamMP's MPGameNetwork, which may not be loaded yet when this extension comes up,
-- so registration is retried from onUpdate until it sticks. The handler is a plain
-- function value plus a stable source name ("beamcomp") -- re-registering from the
-- same name patches in place, so a Lua reload never stacks duplicate handlers.
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
    -- A Lua reload drops BeamMP's handler table, so always re-register from a clean
    -- slate rather than trusting the serialized flag.
    M.state.registered = false
    ensure_registered()
    log("I", LOG_TAG, "loaded")
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    log("I", LOG_TAG, "unloaded")
end

return M
