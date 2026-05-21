-- BeamComp -- cross-side message envelope.
--
-- Every BeamComp message between the BeamMP server plugin and the BeamNG client
-- mod is a JSON object of the shape:  { "type": <string>, "payload": <any> }.
-- This module encodes/decodes that shape.
--
-- The server (BeamMP Lua) and client GE (BeamNG LuaJIT) run in isolated Lua
-- states and ship JSON helpers under different names, so this module takes an
-- INJECTED codec rather than calling either directly. Wire it once at load:
--
--   BeamNG client:  envelope.set_codec(jsonEncode, jsonDecode)
--   BeamMP server:  envelope.set_codec(Util.JsonEncode, Util.JsonDecode)
--
-- deploy.ps1 copies this single source file into both payloads at build time.

local M = {}

local json_encode = nil
local json_decode = nil

-- Wire the JSON codec for the host runtime. Call once at extension/plugin load.
function M.set_codec(encode_fn, decode_fn)
    json_encode = encode_fn
    json_decode = decode_fn
end

-- Encode a typed message into an envelope JSON string.
-- Errors if the codec is unset or the type is not a non-empty string.
function M.encode(message_type, payload)
    if not json_encode then
        error("beamcomp.envelope: codec not set; call set_codec() first")
    end
    if type(message_type) ~= "string" or message_type == "" then
        error("beamcomp.envelope: message_type must be a non-empty string")
    end
    return json_encode({type = message_type, payload = payload})
end

-- Decode an envelope JSON string.
-- Returns (message_type, payload) on success, or (nil, error_message) on a
-- malformed string or a missing/invalid "type". A nil payload is valid.
function M.decode(envelope_string)
    if not json_decode then
        return nil, "beamcomp.envelope: codec not set; call set_codec() first"
    end
    if type(envelope_string) ~= "string" then
        return nil, "beamcomp.envelope: expected a string"
    end

    local ok, decoded = pcall(json_decode, envelope_string)
    if not ok or type(decoded) ~= "table" then
        return nil, "beamcomp.envelope: invalid JSON"
    end
    if type(decoded.type) ~= "string" or decoded.type == "" then
        return nil, "beamcomp.envelope: missing or invalid 'type'"
    end

    return decoded.type, decoded.payload
end

return M
