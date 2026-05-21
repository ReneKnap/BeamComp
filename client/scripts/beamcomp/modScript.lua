-- BeamComp -- client mod bootstrap.
--
-- BeamNG runs every scripts/**/modScript.lua of an activated mod once, in the
-- Game-Engine VM, when the mod is mounted (the core mod manager scans for and
-- executes modScripts on activation). Extensions under lua/ge/extensions/ are
-- NOT auto-loaded, so this is where the BeamComp GE extension is brought up.
--
-- "beamcomp_init" maps to lua/ge/extensions/beamcomp/init.lua (underscores ->
-- slashes). That extension calls setExtensionUnloadMode(M, "manual") on load so
-- it survives level/scenario switches. See ADR-0004.

extensions.load("beamcomp_init")
