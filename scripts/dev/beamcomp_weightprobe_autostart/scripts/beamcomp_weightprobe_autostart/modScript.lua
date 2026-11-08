-- BeamComp dev tool, NOT SHIPPED -- autostart for the weight probe (scripts/dev/beamcomp_weightprobe).
--
-- BeamNG runs every scripts/**/modScript.lua of an active mod once, in the Game-Engine VM, when the mod
-- manager mounts the mod. Starting the extension from the command line (-onLevelLoad_ext) does not work for
-- an unpacked mod: it loads before the mod manager mounts mods and finds nothing (measured 2026-11-08).
-- "beamcompdev_autostart" maps to lua/ge/extensions/beamcompdev/autostart.lua (underscores -> slashes).

extensions.load("beamcompdev_autostart")
