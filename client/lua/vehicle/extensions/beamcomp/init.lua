-- BeamComp -- client VE (Vehicle-Engine) extension (placeholder).
--
-- Lives at lua/vehicle/extensions/beamcomp/init.lua inside the client mod zip
-- and loads under the name `beamcomp_init` in the per-vehicle Lua VM. The VE VM
-- owns per-vehicle physics, electrics, and input -- a different VM from GE with
-- no shared state.
--
-- Placeholder: per-vehicle hooks (updateGFX / onReset / ...) go here only if a
-- task genuinely needs per-vehicle physics access. Most BeamComp logic belongs
-- on GE; prefer it unless VE is required. No logic yet.

local M = {}

return M
