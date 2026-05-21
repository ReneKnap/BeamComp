-- BeamComp -- BeamMP server plugin entry point.
--
-- Deployed to Resources/Server/BeamComp/. BeamMP loads every .lua file in the
-- plugin folder alphabetically at server start.
-- API reference: the BeamMP server-plugin recon note (kept in the project's
-- local docs).
--
-- Placeholder: no behaviour yet. The chat-command handler and the
-- server->client messaging (Sprint-1 items 4 & 5) register here, e.g.:
--
--   -- BeamMP event handler (must be global)
--   function beamcomp_on_chat(sender_id, sender_name, message)
--     return beamcomp.handle_chat(sender_id, sender_name, message)
--   end
--   MP.RegisterEvent("onChatMessage", "beamcomp_on_chat")
--
-- See the project conventions for why event handlers must be global functions.

print("[beamcomp] server plugin loaded (scaffold)")
