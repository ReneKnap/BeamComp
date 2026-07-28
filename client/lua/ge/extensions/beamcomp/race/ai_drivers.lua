-- BeamComp -- dev-authored AI driver definitions (ADR-0048).
--
-- Lives at lua/ge/extensions/beamcomp/race/ai_drivers.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). SINGLE SOURCE OF TRUTH for the named-AI pool: every driver's name maps to a preferred car
-- (model + config) and a preferred colour. race/ai.lua requires it; the roster editor + roll/reroll chain
-- consume it.
--
-- HAND-EDIT CONTRACT:
--   * Dev-editable in the repo, SHIPS FIXED in the mod zip. End users cannot edit it and the UI cannot write
--     it -- the developer curates the driver identities here.
--   * One driver per line: { name = "<unique nickname>", car = "<model:config>", color = "<rrggbb>" }.
--       - name  : display name; also the roster identity key (keep unique).
--       - car   : a base-game vehicle token, ALWAYS "model:config" (see CRITICAL below). The config is a
--                 REAL .pc preset key (the roster editor's config dropdown, or vehicles/<model>/*.pc).
--       - color : an opaque lowercase hex string, no leading '#'.
--   * Reload the mod (or restart BeamNG) after editing so the client picks up the change (client mod cache).
--
-- CRITICAL -- every car MUST be "model:config", NEVER model-only: a model-only token (config nil) does NOT
-- spawn under BeamMP's spawnRequest -- the AI silently fails to appear. A "model:config" token spawns even
-- when the config is wrong (it degrades to the model's stock config). Memory beamcomp-ai-pool-tokens-need-config.
--
-- CURATION NOTE (regenerated in-game 2026-07-23, feature ai-pool-reroll-cars): the 64 rows below were built
-- from the LIVE vehicle catalog via a one-shot GE console generator -- base-game normal cars only, every
-- token a REAL model:config variant (varied, not stock), non-heavy (curb weight <= 3500 kg, so no
-- trucks/buses/vans), broadly spread across 23 models (max 3 per model). The 64 names + colours are
-- preserved verbatim from the prior pool; only the car changed. To re-generate: re-run the console generator
-- and drop in its beamcomp_ai_drivers_generated.lua output.

return {
    { name = "BrakeChecker99", car = "autobello:110_m", color = "4363d8" },
    { name = "SundayDriver", car = "barstow:291a", color = "9a6324" },
    { name = "CrashTestDummy", car = "bastion:base_v6_A", color = "e6194b" },
    { name = "CaptainOversteer", car = "bluebuck:291a_2door", color = "808000" },
    { name = "LiftOffLenny", car = "bolide:320gtt", color = "42d4f4" },
    { name = "ApexPredator", car = "burnside:2doorSport_early_3M", color = "202020" },
    { name = "GravelMagnet", car = "covet:13s_M", color = "42d4f4" },
    { name = "WallHugger", car = "etk800:844_150_A", color = "e6194b" },
    { name = "LastLapLarry", car = "etkc:kc4_250_A", color = "808000" },
    { name = "TurboTortoise", car = "etki:2400_A", color = "202020" },
    { name = "NitroNoodle", car = "fullsize:bcpd", color = "800000" },
    { name = "HandbrakeHank", car = "hopper:carabinieri", color = "800000" },
    { name = "OversteerOtto", car = "legran:base_i4_M", color = "42d4f4" },
    { name = "UndersteerUncle", car = "midsize:DX_A", color = "42d4f4" },
    { name = "PitLanePete", car = "miramar:base_M", color = "ffe119" },
    { name = "RedMistRandy", car = "moonhawk:detective", color = "9a6324" },
    { name = "SlipstreamSally", car = "pessima:DX_A", color = "9a6324" },
    { name = "TrackLimitTed", car = "roamer:4wd_facelift", color = "9a6324" },
    { name = "DNFDenny", car = "scintilla:custom", color = "808000" },
    { name = "BackmarkerBob", car = "sunburst2:base_CVT", color = "9a6324" },
    { name = "ChicaneCharlie", car = "vivace:hillclimb_SQ", color = "42d4f4" },
    { name = "DriftKingDave", car = "wendover:Street_tuned", color = "a0a0a0" },
    { name = "FuelSaverFred", car = "wigeon:base", color = "e6194b" },
    { name = "GridGoblin", car = "autobello:110a_m", color = "f032e6" },
    { name = "HairpinHarry", car = "barstow:291a_sport", color = "e6194b" },
    { name = "KerbstoneKevin", car = "bastion:base_v6_awd_A", color = "202020" },
    { name = "LockupLuke", car = "bluebuck:291a_2door_mid", color = "9a6324" },
    { name = "MirrorMissingMike", car = "bolide:320gtt_targa", color = "000075" },
    { name = "NoBrakesNed", car = "burnside:2doorSport_late_3A", color = "202020" },
    { name = "OilPatchOllie", car = "covet:15ee_m", color = "bfef45" },
    { name = "PhotoFinishPhil", car = "etk800:844_150_M", color = "42d4f4" },
    { name = "QualifyingQuinn", car = "etkc:kc4_250_M", color = "3cb44b" },
    { name = "RumbleStripRick", car = "etki:2400_A_alt", color = "000075" },
    { name = "SandTrapSam", car = "fullsize:custom", color = "9a6324" },
    { name = "TailgateTina", car = "hopper:classic", color = "42d4f4" },
    { name = "TorqueSteerTom", car = "legran:base_i4_facelift_M", color = "800000" },
    { name = "VMaxVinnie", car = "midsize:DX_M", color = "42d4f4" },
    { name = "WheelspinWalt", car = "miramar:base_export_M_early", color = "f032e6" },
    { name = "YellowFlagYuri", car = "moonhawk:donk", color = "ff1493" },
    { name = "ZigzagZack", car = "pessima:DX_M", color = "911eb4" },
    { name = "AeroLessAndy", car = "roamer:4wd_lxt_facelift", color = "808000" },
    { name = "BargeBoardBarry", car = "scintilla:dark_owl", color = "808000" },
    { name = "CoastingCarl", car = "sunburst2:base_EU_CVT", color = "ffe119" },
    { name = "DiveBombDylan", car = "vivace:gravel_SQ", color = "000075" },
    { name = "EarlyApexEddie", car = "wendover:base_v6_A", color = "911eb4" },
    { name = "FlatOutFinn", car = "wigeon:base_4w", color = "808000" },
    { name = "GhostBraker", car = "autobello:110b_m", color = "42d4f4" },
    { name = "HotLapHugo", car = "barstow:291m", color = "469990" },
    { name = "InsideLineIzzy", car = "bastion:battlehawk_A", color = "42d4f4" },
    { name = "JumpStartJack", car = "bluebuck:291a_4door", color = "f58231" },
    { name = "KamikazeKarl", car = "bolide:320gtt_targa_us", color = "e6194b" },
    { name = "LateBrakeLewis", car = "burnside:2door_early_2A", color = "000075" },
    { name = "MidfieldMarty", car = "covet:15gtz_turbo2_M", color = "9a6324" },
    { name = "NoGripNigel", car = "etk800:844_250_A", color = "ffe119" },
    { name = "OptimisticOwen", car = "etkc:kc4_street_tuned_M", color = "000075" },
    { name = "PanicBrakePaul", car = "etki:2400_M", color = "3cb44b" },
    { name = "RageQuitRoy", car = "fullsize:custom2", color = "42d4f4" },
    { name = "SpinCycleStan", car = "hopper:crawler", color = "ffe119" },
    { name = "ThrottleTherapy", car = "legran:base_i4_wagon_facelift_M", color = "808000" },
    { name = "UnsafeReleaseUli", car = "midsize:LX_A", color = "ffe119" },
    { name = "VibesOnlyVic", car = "miramar:base_export_M_late", color = "ffe119" },
    { name = "WreckItWes", car = "moonhawk:drag", color = "ffe119" },
    { name = "XenonXavier", car = "pessima:GTz", color = "ffe119" },
    { name = "BoxThisLapBen", car = "roamer:4wd_xt_facelift", color = "e6194b" },
}
