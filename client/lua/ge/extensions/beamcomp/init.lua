-- BeamComp -- client GE (Game-Engine) extension (placeholder).
--
-- Lives at lua/ge/extensions/beamcomp/init.lua inside the client mod zip and
-- loads under the name `beamcomp_init`. The GE VM owns the scene, level, UI,
-- camera, and vehicle spawning, and is where the BeamMP client<->server
-- messaging endpoint lives.
--
-- Placeholder: the lifecycle hooks (onExtensionLoaded / onExtensionUnloaded /
-- onUpdate / ...) and the server->client message handler (Sprint-1 item 5) go
-- here. No logic yet -- see the BeamNG modding-hooks recon note for the hook
-- contract and hot-reload discipline.

local M = {}

return M
