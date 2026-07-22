-- BeamComp -- dev-authored AI driver definitions (ADR-0048).
--
-- Lives at lua/ge/extensions/beamcomp/race/ai_drivers.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). This file is the SINGLE SOURCE OF TRUTH for the named-AI pool: every driver's name maps to
-- a preferred car (model + config) and a preferred colour. race/ai.lua requires it and uses it as the pool
-- the roster editor + roll/reroll chain consume (it replaced the old runtime-writable, server-persisted
-- pool of ADR-0047).
--
-- HAND-EDIT CONTRACT:
--   * Dev-editable in the repo, SHIPS FIXED in the mod zip. End users cannot edit it and the UI cannot
--     write it (there is no save-to-pool path anymore) -- the developer curates the driver identities here.
--   * One driver per line: { name = "<unique nickname>", car = "<model[:config]>", color = "<rrggbb>" }.
--       - name  : the driver's display name; also the roster identity key (keep unique).
--       - car   : a base-game vehicle model token WITH a preferred config, e.g. "etk800:844_250_A". The
--                 config is the .pc preset name (the key in the roster editor's config dropdown, or the
--                 vehicles/<model>/*.pc filename). Model-only ("etk800") is still valid and resolves to the
--                 model's stock config. Prefer stock/base-game models so the file is valid on any install;
--                 owned/mod models work too if every player has them.
--       - color : an opaque lowercase hex string, no leading '#'. Any hex works; the 18 aiPalette swatches
--                 (race/ai.lua COLOR_PALETTE) are the picker's presets, but the field is free-form.
--   * Reload the mod (or restart BeamNG) after editing so the client picks up the change (client mod cache).
--
-- SEED NOTE: the 64 rows below are a DETERMINISTIC SEED, not hand-picked. Each name was mapped by an FNV-1a
-- hash of the name to a stock car (24-model list), by a salted hash to a palette colour, and by a second
-- salted hash to a preferred config from that model's candidate list (ADR-0048 amendment 2026-07-22).
-- Stable per name; meant to be hand-tuned -- edit freely.
--
-- CONFIG-TOKEN VALIDITY (best-effort, hand-tunable): the etk800 / etkc configs are VERIFIED (etk800 tokens
-- ship in app.js defaultTourClasses and match the BeamNG docs; etkc follows the same <code>_<hp>_<trans>
-- scheme). Every OTHER model's config is a BEST-EFFORT normalized name from the official BeamNG vehicle
-- catalog and may not match the real .pc filename -- an invalid config degrades to that model's STOCK config
-- in-game (same as a model-only token, no breakage) and is trivially hand-fixable: pick the driver's model
-- in the roster editor and read the valid config keys from the config dropdown, or list vehicles/<model>/
-- *.pc. Fixing a wrong token upgrades that driver from stock to its intended variant.

return {
    { name = "BrakeChecker99",      car = "hopper:trackday",            color = "4363d8" },
    { name = "SundayDriver",        car = "roamer:sport",               color = "9a6324" },
    { name = "CrashTestDummy",      car = "burnside:custom",            color = "e6194b" },
    { name = "CaptainOversteer",    car = "etki:2800_a",                color = "808000" },
    { name = "LiftOffLenny",        car = "scintilla:race",             color = "42d4f4" },
    { name = "ApexPredator",        car = "wigeon:sprint",              color = "202020" },
    { name = "GravelMagnet",        car = "etk800:844_250_A",           color = "42d4f4" },
    { name = "WallHugger",          car = "etk800:844_250_A",           color = "e6194b" },
    { name = "LastLapLarry",        car = "covet:2.0_gtz",              color = "808000" },
    { name = "TurboTortoise",       car = "scintilla:track",            color = "202020" },
    { name = "NitroNoodle",         car = "pessima:2.0_lx_sport_a",     color = "800000" },
    { name = "HandbrakeHank",       car = "legran:sport_s_v6_a",        color = "800000" },
    { name = "OversteerOtto",       car = "covet:2.0_gtz",              color = "42d4f4" },
    { name = "UndersteerUncle",     car = "covet:2.0_gtz",              color = "42d4f4" },
    { name = "PitLanePete",         car = "vivace:gt",                  color = "ffe119" },
    { name = "RedMistRandy",        car = "scintilla:race",             color = "9a6324" },
    { name = "SlipstreamSally",     car = "wendover:lx",                color = "9a6324" },
    { name = "TrackLimitTed",       car = "burnside:deluxe",            color = "9a6324" },
    { name = "DNFDenny",            car = "pessima:2.7_lx_v6_a",        color = "808000" },
    { name = "BackmarkerBob",       car = "hopper:sport_special",       color = "9a6324" },
    { name = "ChicaneCharlie",      car = "legran:sport_se_v6_awd_a",   color = "42d4f4" },
    { name = "DriftKingDave",       car = "scintilla:s",                color = "a0a0a0" },
    { name = "FuelSaverFred",       car = "barstow:353_v8_a",           color = "e6194b" },
    { name = "GridGoblin",          car = "scintilla:track",            color = "f032e6" },
    { name = "HairpinHarry",        car = "etk800:844_250_A",           color = "e6194b" },
    { name = "KerbstoneKevin",      car = "etk800:844_150_A",           color = "202020" },
    { name = "LockupLuke",          car = "sbr4:gt",                    color = "9a6324" },
    { name = "MirrorMissingMike",   car = "hopper:trackday",            color = "000075" },
    { name = "NoBrakesNed",         car = "covet:2.0_gtz",              color = "202020" },
    { name = "OilPatchOllie",       car = "wigeon:sprint",              color = "bfef45" },
    { name = "PhotoFinishPhil",     car = "legran:sport_se_v6_awd_a",   color = "42d4f4" },
    { name = "QualifyingQuinn",     car = "scintilla:s",                color = "3cb44b" },
    { name = "RumbleStripRick",     car = "etkc:Kc4_250_A",             color = "000075" },
    { name = "SandTrapSam",         car = "scintilla:track",            color = "9a6324" },
    { name = "TailgateTina",        car = "covet:track",                color = "42d4f4" },
    { name = "TorqueSteerTom",      car = "covet:track",                color = "800000" },
    { name = "VMaxVinnie",          car = "covet:type_ls",              color = "42d4f4" },
    { name = "WheelspinWalt",       car = "scintilla:s",                color = "f032e6" },
    { name = "YellowFlagYuri",      car = "hopper:sport_special",       color = "ff1493" },
    { name = "ZigzagZack",          car = "etk800:844_250_A",           color = "911eb4" },
    { name = "AeroLessAndy",        car = "etk800:844_250_A",           color = "808000" },
    { name = "BargeBoardBarry",     car = "legran:race",                color = "808000" },
    { name = "CoastingCarl",        car = "etk800:846_340_A",           color = "ffe119" },
    { name = "DiveBombDylan",       car = "scintilla:s",                color = "000075" },
    { name = "EarlyApexEddie",      car = "legran:sport_se_v6_awd_a",   color = "911eb4" },
    { name = "FlatOutFinn",         car = "miramar:canyon_king",        color = "808000" },
    { name = "GhostBraker",         car = "miramar:gtz",                color = "42d4f4" },
    { name = "HotLapHugo",          car = "hopper:trackday",            color = "469990" },
    { name = "InsideLineIzzy",      car = "scintilla:s",                color = "42d4f4" },
    { name = "JumpStartJack",       car = "etk800:844_250_A",           color = "f58231" },
    { name = "KamikazeKarl",        car = "bluebuck:stock_car",         color = "e6194b" },
    { name = "LateBrakeLewis",      car = "scintilla:track",            color = "000075" },
    { name = "MidfieldMarty",       car = "hopper:trackday",            color = "9a6324" },
    { name = "NoGripNigel",         car = "burnside:deluxe",            color = "ffe119" },
    { name = "OptimisticOwen",      car = "scintilla:race",             color = "000075" },
    { name = "PanicBrakePaul",      car = "legran:sport_se_v6_awd_a",   color = "3cb44b" },
    { name = "RageQuitRoy",         car = "etk800:846_340_A",           color = "42d4f4" },
    { name = "SpinCycleStan",       car = "scintilla:s",                color = "ffe119" },
    { name = "ThrottleTherapy",     car = "etk800:844_150_A",           color = "808000" },
    { name = "UnsafeReleaseUli",    car = "burnside:deluxe",            color = "ffe119" },
    { name = "VibesOnlyVic",        car = "etk800:844_250_A",           color = "ffe119" },
    { name = "WreckItWes",          car = "covet:track",                color = "ffe119" },
    { name = "XenonXavier",         car = "etk800:844_250_A",           color = "ffe119" },
    { name = "BoxThisLapBen",       car = "scintilla:track",            color = "e6194b" },
}
