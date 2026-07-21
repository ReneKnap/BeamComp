-- BeamComp -- dev-authored AI driver definitions (ADR-0048).
--
-- Lives at lua/ge/extensions/beamcomp/race/ai_drivers.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). This file is the SINGLE SOURCE OF TRUTH for the named-AI pool: every driver's name maps to
-- a preferred car and a preferred colour. race/ai.lua requires it and uses it as the pool the roster editor
-- + roll/reroll chain consume (it replaced the old runtime-writable, server-persisted pool of ADR-0047).
--
-- HAND-EDIT CONTRACT:
--   * Dev-editable in the repo, SHIPS FIXED in the mod zip. End users cannot edit it and the UI cannot
--     write it (there is no save-to-pool path anymore) -- the developer curates the driver identities here.
--   * One driver per line: { name = "<unique nickname>", car = "<model[:config]>", color = "<rrggbb>" }.
--       - name  : the driver's display name; also the roster identity key (keep unique).
--       - car   : a base-game vehicle model token, e.g. "etk800", or with a config "etk800:844_250_A".
--                 Model-only resolves to that model's stock config. Prefer stock/base-game models so the
--                 file is valid on any install; owned/mod models work too if every player has them.
--       - color : an opaque lowercase hex string, no leading '#'. Any hex works; the 18 aiPalette swatches
--                 (race/ai.lua COLOR_PALETTE) are the picker's presets, but the field is free-form.
--   * Reload the mod (or restart BeamNG) after editing so the client picks up the change (client mod cache).
--
-- SEED NOTE: the 64 rows below are a DETERMINISTIC SEED, not hand-picked -- each name was mapped by an
-- FNV-1a hash of the name to a stock car (24-model list) and by a salted hash to a palette colour (stable
-- per name). They are meant to be hand-tuned; edit freely.

return {
    { name = "BrakeChecker99",      car = "hopper",      color = "4363d8" },
    { name = "SundayDriver",        car = "roamer",      color = "9a6324" },
    { name = "CrashTestDummy",      car = "burnside",    color = "e6194b" },
    { name = "CaptainOversteer",    car = "etki",        color = "808000" },
    { name = "LiftOffLenny",        car = "scintilla",   color = "42d4f4" },
    { name = "ApexPredator",        car = "wigeon",      color = "202020" },
    { name = "GravelMagnet",        car = "etk800",      color = "42d4f4" },
    { name = "WallHugger",          car = "etk800",      color = "e6194b" },
    { name = "LastLapLarry",        car = "covet",       color = "808000" },
    { name = "TurboTortoise",       car = "scintilla",   color = "202020" },
    { name = "NitroNoodle",         car = "pessima",     color = "800000" },
    { name = "HandbrakeHank",       car = "legran",      color = "800000" },
    { name = "OversteerOtto",       car = "covet",       color = "42d4f4" },
    { name = "UndersteerUncle",     car = "covet",       color = "42d4f4" },
    { name = "PitLanePete",         car = "vivace",      color = "ffe119" },
    { name = "RedMistRandy",        car = "scintilla",   color = "9a6324" },
    { name = "SlipstreamSally",     car = "wendover",    color = "9a6324" },
    { name = "TrackLimitTed",       car = "burnside",    color = "9a6324" },
    { name = "DNFDenny",            car = "pessima",     color = "808000" },
    { name = "BackmarkerBob",       car = "hopper",      color = "9a6324" },
    { name = "ChicaneCharlie",      car = "legran",      color = "42d4f4" },
    { name = "DriftKingDave",       car = "scintilla",   color = "a0a0a0" },
    { name = "FuelSaverFred",       car = "barstow",     color = "e6194b" },
    { name = "GridGoblin",          car = "scintilla",   color = "f032e6" },
    { name = "HairpinHarry",        car = "etk800",      color = "e6194b" },
    { name = "KerbstoneKevin",      car = "etk800",      color = "202020" },
    { name = "LockupLuke",          car = "sbr4",        color = "9a6324" },
    { name = "MirrorMissingMike",   car = "hopper",      color = "000075" },
    { name = "NoBrakesNed",         car = "covet",       color = "202020" },
    { name = "OilPatchOllie",       car = "wigeon",      color = "bfef45" },
    { name = "PhotoFinishPhil",     car = "legran",      color = "42d4f4" },
    { name = "QualifyingQuinn",     car = "scintilla",   color = "3cb44b" },
    { name = "RumbleStripRick",     car = "etkc",        color = "000075" },
    { name = "SandTrapSam",         car = "scintilla",   color = "9a6324" },
    { name = "TailgateTina",        car = "covet",       color = "42d4f4" },
    { name = "TorqueSteerTom",      car = "covet",       color = "800000" },
    { name = "VMaxVinnie",          car = "covet",       color = "42d4f4" },
    { name = "WheelspinWalt",       car = "scintilla",   color = "f032e6" },
    { name = "YellowFlagYuri",      car = "hopper",      color = "ff1493" },
    { name = "ZigzagZack",          car = "etk800",      color = "911eb4" },
    { name = "AeroLessAndy",        car = "etk800",      color = "808000" },
    { name = "BargeBoardBarry",     car = "legran",      color = "808000" },
    { name = "CoastingCarl",        car = "etk800",      color = "ffe119" },
    { name = "DiveBombDylan",       car = "scintilla",   color = "000075" },
    { name = "EarlyApexEddie",      car = "legran",      color = "911eb4" },
    { name = "FlatOutFinn",         car = "miramar",     color = "808000" },
    { name = "GhostBraker",         car = "miramar",     color = "42d4f4" },
    { name = "HotLapHugo",          car = "hopper",      color = "469990" },
    { name = "InsideLineIzzy",      car = "scintilla",   color = "42d4f4" },
    { name = "JumpStartJack",       car = "etk800",      color = "f58231" },
    { name = "KamikazeKarl",        car = "bluebuck",    color = "e6194b" },
    { name = "LateBrakeLewis",      car = "scintilla",   color = "000075" },
    { name = "MidfieldMarty",       car = "hopper",      color = "9a6324" },
    { name = "NoGripNigel",         car = "burnside",    color = "ffe119" },
    { name = "OptimisticOwen",      car = "scintilla",   color = "000075" },
    { name = "PanicBrakePaul",      car = "legran",      color = "3cb44b" },
    { name = "RageQuitRoy",         car = "etk800",      color = "42d4f4" },
    { name = "SpinCycleStan",       car = "scintilla",   color = "ffe119" },
    { name = "ThrottleTherapy",     car = "etk800",      color = "808000" },
    { name = "UnsafeReleaseUli",    car = "burnside",    color = "ffe119" },
    { name = "VibesOnlyVic",        car = "etk800",      color = "ffe119" },
    { name = "WreckItWes",          car = "covet",       color = "ffe119" },
    { name = "XenonXavier",         car = "etk800",      color = "ffe119" },
    { name = "BoxThisLapBen",       car = "scintilla",   color = "e6194b" },
}
