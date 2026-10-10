-- BeamComp -- client GE (Game-Engine) extension.
--
-- Copyright 2026 Rene Knap. Licensed under the PolyForm Strict License 1.0.0 plus an additional
-- permission; the full terms are in the LICENSE file at the root of this mod zip. Run it, do not
-- redistribute it.
--
-- Lives at lua/ge/extensions/beamcomp/init.lua inside the client mod zip and loads under
-- the name `beamcomp_init` (brought up by scripts/beamcomp/modScript.lua). The GE VM owns
-- the scene, level, UI, camera, and vehicle spawning, and is where the BeamMP client<->
-- server messaging endpoint lives.
--
-- Receives server->client events on the "beamcompEvent" channel (ADR-0004: the name is
-- colon-free because the BeamMP client parser splits names on ':'). Each event is a JSON
-- envelope { type, payload }; we decode it with the shared envelope module and dispatch on
-- `type` (ADR-0004). Handled types:
--   ping       -- diagnostic; surfaces a toast.
--   raceStart  -- resolve + parse the race locally, compute this client's grid start pose
--                 (race/start + race/grid), draw the grid markers (onPreRender), respawn this
--                 client's own car fresh at its assigned grid pose (race/vehicles), and load the
--                 race's static-scenery prop prefab(s) into the scene (race/props). The knockable
--                 cones are shared: only the payload's propOwner (host) spawns them and BeamMP syncs
--                 them to everyone; non-hosts spawn a statics-only prefab and never instantiate a
--                 cone. Every race prop -- cone or powered grinder -- is kept non-enterable on every
--                 client via race/props (ADR-0020, superseding ADR-0009), and the cones additionally
--                 stay out of the Tab cycle via race/cones.
--   racePhase  -- the server-authoritative race phase (lobby/spawning/countdown/racing/finished,
--                 ADR-0006). We record + surface it, and drive the start lock off it: the car is
--                 spawned frozen (handle_race_start) and held through the countdown, released on
--                 racing, with a defensive release on lobby. The synced 3-2-1-GO! countdown UI
--                 runs off the same phases (race/countdown + ADR-0008): countdown starts the
--                 count, racing shows GO! on the release, lobby/reload clears it. The racing phase
--                 also arms the local checkpoint detector (race/checkpoints, ADR-0010), which walks
--                 the race's sprint/circuit traversal plan (ADR-0013), stepped each frame in onUpdate
--                 and surfacing each passed checkpoint as a toast + log line + server report.
--
-- !! THIS CHUNK SITS AT LUA'S 200-LOCAL CEILING. READ BEFORE ADDING A TOP-LEVEL LOCAL. !!
--
-- LuaJIT / Lua 5.1 allow at most LUAI_MAXVARS = 200 active local variables per function, and the
-- main chunk of a file IS a function. Every top-level `local x` / `local function f` in this file
-- counts against that 200. Blowing it is NOT a runtime error you can catch: the file fails to
-- COMPILE ("main function has more than 200 local variables"), so the whole GE extension never
-- loads -- no HUD, no setup panel, no chat commands, no clue why. It has happened once already
-- (bug quali-hold-reset-and-repaint-leak, round 1: 203/200).
--
-- So: DO NOT add a bare top-level local for a new helper. Hang it on an existing namespace table
-- (`quali`, `hold`, ...) or open a new one -- a table costs ONE local no matter how many functions
-- it holds. This is the same ceiling `server/main.lua` has managed for a while with its `f1` /
-- `quali` / `tour` tables (memory beamcomp-server-200-local-limit); it applies to BOTH big files.
--
-- Count before you commit -- do not estimate:
--   grep -c "^local " on this file UNDER-counts (it misses multi-name declarations and counts
--   nothing about scope). Count `local` declarations at block depth 0.

local M = {}

local envelope = require("beamcomp/envelope")
local race_start = require("beamcomp/race/start")
local vehicles = require("beamcomp/race/vehicles")
local props = require("beamcomp/race/props")
local cones = require("beamcomp/race/cones")
local nametags = require("beamcomp/race/nametags")
local grinders = require("beamcomp/race/grinders")
local spawn_mute = require("beamcomp/race/spawn_mute")
local countdown = require("beamcomp/race/countdown")
local checkpoints = require("beamcomp/race/checkpoints")
local laptimer = require("beamcomp/race/laptimer")
local sectors = require("beamcomp/race/sectors")
local lock = require("beamcomp/race/lock")
local hud = require("beamcomp/race/hud")
local racelist = require("beamcomp/race/racelist")
local carlist = require("beamcomp/race/carlist")
local maps = require("beamcomp/race/maps")
local grideditor = require("beamcomp/race/grideditor")
local placement = require("beamcomp/race/placement")
local ai = require("beamcomp/race/ai")
-- Rally staged sprint qualifying per-driver run state machine (ADR-0044); pure timing helpers.
local qualisprint = require("beamcomp/race/qualisprint")
-- BeamNG 0.39 UI-app layout compat (bug beamng-039-breakage): every panel show/remove goes through
-- this seam since the Angular appContainer guihooks died in 0.39. Hung on M instead of a `local`
-- to spare a slot under the 200-local ceiling (see the header) -- which also makes it reachable
-- from the in-game console as beamcomp_init.uilayout for manual verification.
M.uilayout = require("beamcomp/race/uilayout")
-- The grid editor's camera (ADR-0063): jumps above the grid being edited and owns every way back out.
-- Hung on M for the same reason as uilayout -- it costs no top-level local -- which also lets its pose
-- constants be tuned live from the console (beamcomp_init.gridcam.PITCH_DEG = 45).
M.gridcam = require("beamcomp/race/gridcam")

-- ===== namespace tables (the 200-local ceiling, see the header) ==========================
-- Each of these costs exactly ONE top-level local no matter how many functions it carries, which is
-- the only reason this file still compiles. Mirrors the `f1` / `quali` / `tour` tables in
-- server/main.lua. Declared up here so every definition below can just assign into them -- which
-- also means a table field never needs a forward declaration, unlike a plain local function.
--
-- quali -- everything the qualifying session owns client-side: the staged sprint's per-driver
--          geometry + queue handling (ramp/holding teleports, launch, requeue, the AI proxy
--          sequence, the ramp-clear gate, ADR-0044), the quali snapshot handler and the results
--          re-grid AI respawn (ADR-0041), and the HUD's quali row.
-- hold  -- the qualifying HOLD: the single `is_held()` predicate and the layers that enforce it
--          (bug quali-hold-reset-and-repaint-leak), plus `is_frozen_phase()` -- the wider "the
--          local driver's car is supposed to be standing still right now" window that the EV
--          throttle clamp and the in-place reload re-arm share (bug
--          recover-unguarded-when-assists-disabled).
-- setup -- the race-setup panel's GE-side presence: the session open-state set by the admin-gated
--          /raceui open, the one-shot watchdog that re-adds the app when a UI reload drops it
--          (bug setup-panel-settings-survive-ui-reload), the panel's AI-roster car re-resolve
--          (ADR-0047 live amendment), the record of which panel request the staged grid was
--          built from (feature setup-confirm-grid-stale-hint), and the request/arrival trail of the
--          saved grid and preset lists with the check that drops a list for another map (bug
--          raceui-misses-other-admins-presets-and-grids).
-- stall -- the client half of the driver-liveness predicate (feature
--          stall-detection-client-measured-movement): measure whether each car THIS client owns has
--          actually covered ground, and report the verdict to the race-blind server while a finish
--          grace is armed. Named after -- and only meaningful together with -- the `stall` namespace
--          in server/main.lua, which folds this verdict and its own checkpoint-gap backstop into ONE
--          predicate. Deliberately not a field on `quali`: this runs in the racing phase too, where
--          there is no qualifying session at all.
-- identity -- the player-set name (ADR-0054): the settings file it is persisted in, the one report to
--          the server at connect, and the admin panel's "who has no name" list. It carries NO cached
--          copy of the name -- the file is the truth and is re-read on load, which is what makes a GE
--          Lua reload a non-event here (ADR-0052).
-- notice -- where a player-facing message goes (feature race-toast-cleanup-and-checkpoint-readout):
--          the ONE phase predicate, the centred message line, the checkpoint readout, and the tick that
--          ages both. Every message in this file and in race/lock.lua goes through notice.say, so a call
--          site states WHAT it reports and never WHERE -- the chokepoint reasoning of is_race_admin and
--          resolve_identity (CLAUDE.md), which is also what makes the next message land right without
--          anyone remembering the rule.
local quali = {}
local hold = {}
local setup = {}
local stall = {}
local identity = {}
local notice = {}
-- ===== end namespace tables =============================================================

-- How long to mute BeamMP's vehicle-spawn notifications from a race start, covering the host's
-- cone-spawn burst on every other client (race/spawn_mute, ADR-0020 finding #2b).
local SPAWN_NOTIFICATION_MUTE_SECONDS = 5

local EVENT_CHANNEL = "beamcompEvent"
local LOG_TAG = "beamcomp.net"
local RACE_LOG_TAG = "beamcomp.race"

-- HUD self-healing watchdog thresholds (seconds). The app heartbeats ~1s (note_hud_alive); if GE hears
-- nothing for HUD_ACK_STALE while a race wants the HUD up, it re-asserts visibility (a dedup'd
-- layout re-add via the 0.39 seam) on a doubling backoff: the first re-show comes HUD_RESHOW_EVERY
-- after the stale mark, then the cadence doubles up to HUD_RESHOW_MAX.
--
-- There is NO Stage-B reloadUI escalation any more (bug beamng-039-breakage round 4). It existed for
-- the pre-0.39 failure mode "an engine/BeamMP UI reload drops our late-mounted, server-delivered app
-- and nothing brings it back" (ADR-0008/0012). Since 0.39 that is structurally impossible: our apps
-- persist in the user's current layout FILE (round 1), and every completed UI boot re-renders the
-- whole layout from disk (UiAppsOverlay mounts -> appLayoutsStore.loadInitialData -> render), so the
-- app always returns on its own once the UI is up; a missing layout ENTRY is exactly what the Stage-A
-- re-add repairs. Worse, Stage B mis-fired: 0.39 hides the entire HUD-apps layer in menu routes
-- (uiApps.shown=false -> the overlay's v-if UNMOUNTS the hosted apps), so the heartbeat goes silent
-- legitimately whenever the user sits in a menu -- and the "rescue" reloaded a perfectly healthy UI
-- (observed live 2026-07-31, second session). The backoff keeps that legitimate-silence churn to one
-- cheap layout check per HUD_RESHOW_MAX while staying just as fast on a real loss (first re-show
-- ~HUD_ACK_STALE + HUD_RESHOW_EVERY after the last heartbeat).
local HUD_ACK_STALE = 1.5
local HUD_RESHOW_EVERY = 1.0
local HUD_RESHOW_MAX = 15.0

local MARKER_RADIUS = 0.6

-- In-world marker styling. Checkpoints render singleplayer-style: a pale translucent column
-- spanning the whole checkpoint radius, with thin posts marking the gate sides. Grid poses render
-- as slot-colored pillars. All immediate-mode debugDrawer, redrawn each frame (nothing to clean up).
-- Checkpoint columns extend far up (seen over buildings / at distance) and well below ground
-- (no visible bottom end on a slope). The pale fill is a cylinder shell, so the extra length does
-- not accumulate opacity.
local CHECKPOINT_COLUMN_UP = 300.0      -- column reach above the checkpoint center
local CHECKPOINT_COLUMN_DOWN = 100.0    -- column reach below the checkpoint center
local GATE_POST_RADIUS = 0.15           -- radius of the thin left/right gate-side posts
local CHECKPOINT_FADE_BAND = 60.0       -- meters above the radius over which the area cylinder fades
                                        -- in: full alpha at radius + this, alpha 0 at the volume edge.

-- Gate-post orientation. The two side posts ease from player-facing (square-on to the approach, so
-- the gate reads clearly at distance) toward the gate's true stored normal as the car nears. Two
-- distance thresholds bound that blend -- deliberately independent of CHECKPOINT_FADE_BAND, so the
-- area-cylinder fade and the post orientation tune separately. On top of the distance blend the
-- drawn angle is slew-limited (smooth_marker_angle) so it can never rotate faster than
-- MARKER_MAX_TURN_RATE: the posts ease smoothly toward the distance-blended target rather than
-- snapping onto it, and reach the true line well before the gate instead of right in front of the car.
local MARKER_ORIENT_START_DIST = 200.0  -- distance from center at/beyond which posts stay fully player-facing (the turn begins here)
local MARKER_ORIENT_FULL_DIST = 60.0    -- distance from center at/within which posts sit fully on the true gate line
local MARKER_MAX_TURN_RATE = math.rad(10)   -- max post turn speed (rad/s); caps the per-frame angle step
local MARKER_DT_CLAMP = 0.1             -- max dt (s) fed to the slew-limit, so a frame hitch can't yield a big step
local GRID_COLUMN_HEIGHT = 2.5          -- height of a start-grid pillar (label sits on top)
local GRID_COLUMN_RADIUS = 0.25         -- radius of a start-grid pillar
local GRID_ORIENT_LINE_LENGTH = 2.5     -- length of the red orientation line off each preview marker (m)
local GRID_ORIENT_LINE_RADIUS = 0.06    -- thickness of the orientation line (a thin cylinder)
local GRID_ORIENT_LINE_HEIGHT = 0.15    -- height above the marker base the orientation line sits at (m)

-- Per-target marker colors ({r, g, b, a}). The next checkpoint is colored by role: regular
-- (pale fill + red posts), the lap line (CP0 crossed at the end of a non-final lap, blue), or the
-- race finish (green). The look-ahead -- the checkpoint after next -- always uses yellow posts, so
-- it reads as "the one after" by color rather than by fading.
local CHECKPOINT_STYLE = {
    area = {r = 0.85, g = 0.88, b = 0.95, a = 0.12},
    post = {r = 1.0, g = 0.15, b = 0.15, a = 0.85},
}
local LAP_STYLE = {
    area = {r = 0.45, g = 0.65, b = 1.0, a = 0.16},
    post = {r = 0.2, g = 0.5, b = 1.0, a = 0.9},
}
local FINISH_STYLE = {
    area = {r = 0.55, g = 1.0, b = 0.6, a = 0.16},
    post = {r = 0.3, g = 1.0, b = 0.4, a = 0.9},
}
local LOOKAHEAD_STYLE = {
    area = {r = 0.85, g = 0.88, b = 0.95, a = 0.1},
    post = {r = 1.0, g = 0.85, b = 0.1, a = 0.85},
}

-- Min seconds between "switch locked" toasts, so spamming Tab during a race shows one toast, not a
-- flood (the bounce itself still fires every time).
local SWITCH_BLOCK_TOAST_THROTTLE = 2.0

-- Min seconds between "car over the cap" toasts on a rejected staging swap (ADR-0032), so mashing the
-- vehicle selector shows one toast, not a flood (the revert still fires each time). Mirrors the switch/
-- spawn block throttles.
local CAP_SWAP_TOAST_THROTTLE = 2.0

-- Seconds to wait for a (swapped or freshly-spawned) car's jbeam to finish loading before re-placing it
-- anyway (fallback for a same-footprint swap, where the bbox never visibly changes). Forward
-- half-length change (metres) that signals the new jbeam has loaded and the bbox now reflects the
-- actual car. Used by restage_swapped_car; declared here so handle_race_start can arm the same flow.
local RESTAGE_MAX_WAIT = 3.0
local RESTAGE_MIN_DELTA = 0.2

-- Stock dashboard/tacho rebind (bug default-dashboard-ui-missing-at-race-start): seconds to let a
-- (re)seated car's VE streams settle after its jbeam is bindable before firing the one-shot rebind, so it
-- acts once the car is actually bindable rather than mid-churn.
local DASH_REFRESH_SETTLE = 0.75

-- Distinctive build marker logged at load so a redeploy can be proven live in beamng.log before trusting
-- an in-game result -- the BeamMP client mod is served from a cache that can go stale (memory
-- beammp-client-mod-cache-stale). Bump when shipping a client-visible fix that needs an in-game re-test.
-- Names every item in this build on purpose. Live checks 10-13 are accepted (2026-10-05); of the items
-- named here only the list normalisation (lists-r1) is still outstanding, gridcam is the grid editor's
-- camera, partlock (the forced-car part lock), confirmhint (the setup panel's stale-grid hint) and
-- recoverground (the recover assist's placement), qualilaps (the circuit-quali AI lap supply),
-- hostaitags (the host's own AI tags) and keysdup (the /keys window's duplicate keys) are new since
-- then, and adminlists (another admin's saved presets and grids) is new in this build.
-- A client logging r2 has the nametags but no race-setup button; one logging r3 has both; one
-- logging aicar-r1 on top of r3 also has the forced-car precedence in the AI roster; one logging
-- lists-r1 on top of that also normalises an empty list pushed from GE (the preset dropdown and the
-- HUD standings during a race started over a running one); one logging gridcam-r1 on top of that also
-- moves the camera above the grid being edited and gives it back when the editor closes; one logging
-- gridcam-r2 also puts a camera still free from the editor back into the car when a race starts; one
-- logging gridcam-r3 also shows every checkpoint in the grid editor (CP0 red, CP1 yellow, the rest grey);
-- one logging partlock-r1 also locks a forced car's parts and its staging swap, with tuning left free;
-- one logging confirmhint-r1 also has the setup panel point at Confirm & Build Grid when the settings
-- differ from the staged grid, and shows Start Race only while a race is staging; one logging
-- recoverground-r1 also has the recover assist set the car's box bottom on the surface the way the grid
-- does and measure the slope with the grid's window; one logging qualilaps-r1 also has the circuit-quali
-- AI keep lapping until the quali clock ends, and names the path in its arming, park and grace lines;
-- one logging hostaitags-r1 also lets the host see the names over his own AI cars, drawn by BeamComp,
-- and BeamMP's nametag toggles switch them too; one logging keysdup-r1 also has the /keys window never
-- write a key an assist already has, and show each key once; one logging keysdup-r3 also has Reset UI
-- layout in a gear menu in the /keys window's title bar instead of its footer (keysdup-r2 was a test
-- build with no reset in that window at all); one logging adminlists-r1 also has its open race setup
-- panel and grid editor follow another admin's preset and grid saves, assigns and deletes without a
-- reopen, drops a list for a map it is not on, and logs every list it asks for and every list it gets.
local BUILD_MARKER = "raceui-reopen-and-nametags-r3-aicar-r1-lists-r1-gridcam-r3-partlock-r1-confirmhint-r1-recoverground-r1-qualilaps-r1-hostaitags-r1-keysdup-r3-adminlists-r1/2026-10-10"

-- Speed (m/s) at or below which a car counts as STOPPED. One number, deliberately shared by the only two
-- questions in this mod that ask it, so the two can never drift apart (user decision 2026-09-03, "dann ist
-- das auch einheitlich"):
--   * may a recover/repair hold run? (ADR-0017, is_car_stationary) -- must not fire while driving
--   * is this driver AFK during a finish grace? (stall.is_stopped)
-- Declared up here rather than beside the assist code because the `stall` namespace below closes over it,
-- and Lua binds upvalues at closure-creation time -- declared later it would silently be a nil global there.
local STATIONARY_SPEED = 2.0

-- AI count past which the owner gets a one-shot performance hint (ADR-0036 Etappe B): all AI physics run
-- on the host, so a larger field is heavier on the owner's machine.
local AI_PERF_HINT_THRESHOLD = 6

-- The extension's whole mutable state. It does NOT survive a GE Lua reload -- a comment here claimed
-- the opposite for a long time and the mistake spread as an idiom, so the reasoning is spelled out once,
-- here, and nowhere else (refactor ge-state-not-reload-surviving-comment-wrong).
--
-- BeamNG really does have an M.state serialization convention: lua/common/extensions.lua takes a
-- module's `state` field as its serialized part. But only for a module that defines onSerialize,
-- onDeserialize or onDeserialized -- that is the gate the old comment missed. This extension defines
-- none of the three, so it is skipped in BOTH directions and a GE Lua reload rebuilds this table from
-- the literal below. Every field comes back at its default.
--
-- A VE reload -- vehicle respawn, reset, config/tuning re-apply -- is a DIFFERENT event in a different
-- Lua VM and does not touch this table at all. Comments about state surviving THAT are correct and mean
-- something else (rearm_own_car_on_reload & co.); do not "fix" them.
--
-- Why losing it all is safe, and the invariant to keep: the same event runs M.onExtensionUnloaded ->
-- teardown_race_world(), which puts every system this table mirrors back to its default -- input filter,
-- VE overrides, spawned scenery, AI cars + navgraph, HUD, start freeze. After a reload there is nothing
-- left for this state to describe. So do not add a field whose correctness needs its own previous value
-- to survive: either re-assert it in onExtensionLoaded (see `registered` and `quali_hold_locked`), or
-- make sure the teardown resets the thing it mirrors.
M.state = {
    last_event_at = 0,
    registered = false,
    race = nil,          -- current race-start state (slot, poses, roster) or nil
    phase = nil,         -- current server-authoritative race phase (ADR-0006) or nil
    marker_warned = false,
    prop_names = nil,    -- names of the prop prefabs we spawned, for cleanup (or nil)
    cone_ids = nil,      -- ids of the shared cone vehicles we spawned + must clear (host only, ADR-0020)
    prop_owner = false,  -- whether we are (or were) the client that spawns + owns the shared prop-vehicles (payload.propOwner, ADR-0020); gates the grinder activation window and the scene-scan cleanup long after handle_race_start, and survives teardown on purpose so a repeat cleanup pass still reaps a late re-spawn (see teardown_race_world)
    grinder_activate = nil,  -- powered-prop activation window state owned by race/grinders (arm/step/note_spinning): tracked + pending ids, confirmations, deadline; nil when idle/non-host or the window has closed. No spawn-time id list is kept any more -- BeamMP re-spawns the props under new ids, so the window re-derives them from the scene (ADR-0020 amendment, bug race-prop-steals-player-seat rounds 2+3)
    prop_before = nil,   -- host only: the vehicle ids that existed BEFORE this race's prefab load, as string keys (props.load). The whole basis of prop identity (ADR-0062): everything new since then, minus the cars we put there ourselves, is a prop. Kept for the race, not just the load, because BeamMP re-spawns props under new ids and the diff has to be re-runnable. nil off-race / on a non-host
    prop_ids = nil,      -- set of cross-client BeamMP ids of the race's props, as string keys: derived locally on the host, relayed (propMap) everywhere else. nil = nothing to silence (ADR-0062)
    prop_map_pending = false,  -- host only: the prop map has to be rebuilt and, if it changed, re-sent. Set by the prefab load and by every vehicle spawn during a race we own the props of -- which is what catches BeamMP's ~5 s delete-and-respawn of the props under new ids
    prop_map_sent = nil,  -- host only: signature of the last propMap that went out, so an unchanged map costs no message
    prop_map_wait = 0,   -- host only: seconds until the next rebuild attempt while prop_map_pending
    prop_map_budget = 0, -- host only: seconds of rebuild attempts left before we stop and WARN about the vehicles that never registered with BeamMP. A silent give-up on an incomplete map is how the old suppression hid a 49%-coverage gap for a year
    ai_names = nil,      -- non-owner: cross-client BeamMP id -> the AI's standings label, from the relayed aiMap (ADR-0036/0062), or nil. The owner ignores its own aiMap, so this stays nil there; the owner's policy derives the same map from its live ai_cars instead (identity.own_ai_names)
    show_driver_names = nil,  -- whether drivers (humans AND AI) carry a name over their car on this server (ADR-0062). nil = not heard yet, and the safe reading of nil is ON: a client that never got the policy behaves exactly like plain BeamMP. Only an explicit false hides them. Props are outside this and silent either way. Connection-scoped: cleared at the session boundary (identity.clear_policy) and nowhere else -- a race end does not touch it (decision 6), and neither does closing the setup panel (bug panel-close-wipes-nametag-policy)
    tag_written = nil,   -- what THIS client changed on BeamMP's nametag entries: {hidden = {}, named = {}} keyed by cross-client id, so a tag is only ever given back or cleared if we took it away or set it (ADR-0062). Lazily created. Connection-scoped like the policy itself and dropped only by identity.clear_policy: a client that forgets this record while its writes still stand can never give those tags back, which is what made a panel close reopen the prop defect
    tag_wait = 0,        -- seconds until the next nametag reconcile sweep; the sweep is what beats a rebuilt MPVehicleGE entry, which comes back tagged (hideNametag/customName are not serialized)
    current_vehicle_id = nil,  -- game id of the vehicle the player is in, tracked via onVehicleSwitched
    race_car_id = nil,   -- game id of this client's race car; bounce target for the in-race switch lock
    detection = nil,     -- checkpoint-detection progress (race/checkpoints), armed on the racing phase
    laptimer = nil,      -- circuit lap-clock state (race/laptimer), armed on racing; display only (ADR-0022)
    marker_angles = nil, -- per-checkpoint (keyed by stable index) last-drawn gate-post angle, for the render-only orientation slew-limit (smooth_marker_angle); lazily created, reset per race
    results_min = false,     -- local-only: finished results card minimized to a small restore bar; toggled by /results + the on-card Minimize/restore buttons (ADR-0012/0041 minimize pattern)
    race_records = nil,      -- pre-run PB + track record for the post-race analysis overlay (server raceRecords, ADR-0028), or nil
    analysis_open = false,   -- local-only toggle: show the post-race analysis overlay via /analysis or the card button (ADR-0028)
    stats_enabled = false,   -- whether the SERVER has the statistics subsystem switched on (payload.statsEnabled from raceStart, ADR-0053). Gates analysis_available and M.toggle_analysis. Default false and that is the load-bearing part: unknown MUST mean off, so a rejoin into a finished phase, an older server or any dropped field hides the analysis UI rather than showing a button with nothing behind it. Mirrors a server setting, not race state -- re-asserted on every raceStart, cleared by teardown_race_world, so the ADR-0052 rebuild-on-reload lands on exactly the teardown value
    provisional_open = true,  -- local-only per-player: auto-show the provisional results card once the local player is finished/DNF while the race still runs; toggled by the HUD buttons / racing-phase /results, reset per race
    interval_mode = "self",  -- local-only live-standings interval reference: "self" | "ahead" | "leader"; cycled by the HUD toggle, session-persistent (not reset per race)
    standings = nil,     -- latest server-broadcast ranked standings entries, or nil
    car_info = nil,      -- one-shot per-driver car descriptors, cached from the carInfo channel keyed by the standings row (slot, else name); the standings entries no longer carry `car` (ADR-0029 amendment, bug partconfig-blob-bloats-standings), or nil
    grace = nil,         -- finish-grace countdown {remaining = seconds}, ticked locally (ADR-0014), or nil
    stall_cutoff = nil,  -- server-broadcast AFK cutoff {remaining = seconds}: how long until the LAST still-standing driver is counted out and the finish grace shortens (feature standings-afk-cutoff-counter). Ticked locally beside `grace` in stall.step_clocks, which also drops it whenever `grace` is gone -- the addendum may never outlive the counter it stands behind. nil = nothing to announce, which is also what an older server, a dropped message and a GE Lua reload leave behind (ADR-0052): absence means unknown, never "what I saw last"
    staging = nil,       -- staging-wait {remaining = seconds}, ticked locally for the indicator (ADR-0021), or nil
    countdown = nil,     -- start-countdown {remaining = seconds}, ticked locally to drive the 8s count (ADR-0021), or nil
    f1 = nil,            -- F1 light start (ADR-0043): grid baselines, first-movement times and report latches for the own car and (host) each AI, plus lights_out_at; nil outside an F1 start
    ai_release = nil,    -- host only: F1 staggered release schedule {[ai id] = os.clockhp when that car is unfrozen}, dropped once all are out (ADR-0043), or nil
    assist_armed = false,  -- whether the VE forwarders have been armed for this race (ADR-0017)
    assist_held = nil,     -- kind ("recover"/"repair") of the assist key currently held, or nil (ADR-0017)
    assist_arming = nil,   -- active recover/repair countdown {kind, remaining}, or nil (ADR-0017)
    assist_notice = nil,   -- which abort reason was last toasted this hold ("moving"), latches one-shot
    freeze_hold_armed = false,  -- whether the VE EV-throttle clamp has been armed for the frozen phases (ADR-0017 amendment)
    restage_pending = false,  -- a staging car (swap or fresh-spawn default) awaits re-placement at the grid slot once its bbox is ready
    restage_baseline = nil,   -- spawn-bbox forward half-length the jbeam-load detection compares against: taken off the OUTGOING car by the replace wrapper for a swap, recorded on the first pending frame for a fresh spawn
    restage_prebaseline = nil,  -- that pre-replace reading, parked by on_before_replace until the replace is consumed one or more frames later; nil outside a swap
    restage_wait = 0,         -- seconds left to wait for the staging car's jbeam before placing anyway
    restage_plate = nil,      -- player's plate to re-apply to a forced/fresh-spawned car on the restage (jbeam regenerates it), or nil
    restage_preplaced = 0,    -- metadata front-anchor teleports already spent this restage cycle, capped at vehicles.PREPLACE_MAX_TRIES
    size_track = {},          -- lobby car-footprint poll state {wait, reported} owned by race/vehicles.poll_own_size (ADR-0051 round 2); plain numbers, so no engine handle can go stale in it
    dash_refresh_pending = false,  -- a stock dashboard/tacho rebind is queued; step_dashboard_refresh fires it once the (re)seated car's VE is ready (bug default-dashboard-ui-missing-at-race-start)
    dash_refresh_wait = 0,         -- seconds left in the readiness-settle window before the queued stock-dashboard rebind fires
    race_caps = nil,          -- Mode-3 caps {maxhp, maxpwr, maxkg, minkg} for the active race, gating the staging swap-compliance check (ADR-0032); nil in Modes 1/2 (no cap)
    race_forced_car = false,  -- whether the active race forces this player's car (payload.car: car=<model[:config]>, random, host, or a class-drop class with a car). Read by race/lock.lua through lock.car_is_forced on every install: true locks the parts and the staging swap, tuning and paint stay free (ADR-0064). Set at raceStart; the literal's false is also the teardown value (ADR-0052)
    staged_spec = nil,        -- spec {model, config, paint...} of the last COMPLIANT staged car, to revert an over-cap staging swap back to (ADR-0032), or nil
    revert_pending = false,   -- one-shot: set when an over-cap revert is issued, so the NEXT consumed replace (our own revert) is marked as the trusted revert cycle; any other replace is a new player swap (ADR-0032)
    staging_swap_reverting = false,  -- true only for the restage cycle that our revert started, so its known-compliant car is adopted without re-gating; recomputed from revert_pending at each consume (prevents a revert loop, ADR-0032)
    ai_cars = nil,            -- host only: spawned AI cars {id, slot, label, veh_id} to freeze/drive/score/clear (ADR-0036), or nil
    ai_config = nil,          -- host only: relayed AI difficulty/vehicle config {preset, car, params} (ADR-0036 Etappe B), or nil
    ai_policy = nil,          -- host only: the vehicle policy used for the AI car chain (ADR-0032), kept so a quali re-grid can re-spawn fresh AI (ADR-0041), or nil
    ai_custom_map = nil,      -- host only: true while the script-variant custom race navgraph is live (ADR-0036 Step-3b); teardown restores the real one

    ai_window = nil,          -- host only: per-AI rolling-route-window state keyed by AI id (race/ai.lua owns the shape; this module owns the storage, like ai_cars). Present only while a route is longer than one block; race/ai.lua M.step_window tops each car up from it. nil off-race / on a non-host
    ai_detections = nil,      -- host only: per-AI checkpoint-detection state keyed by AI id, armed on racing (ADR-0036), or nil
    ai_laptimers = nil,       -- host only: per-AI circuit lap clock keyed by AI id, armed alongside ai_detections; feeds the proxy best-lap + run-up report (ADR-0036/0022/0041), or nil
    ai_map_pending = false,   -- host only: the aiMap (AI server ids) still has unresolved cars to broadcast (ADR-0036)
    ai_remote_ids = nil,      -- non-owner: set of local game ids resolved as AI cars from the relayed aiMap (ADR-0036), or nil
    ai_server_ids = nil,      -- non-owner: set of BeamMP server ids from the latest aiMap awaiting local resolution (ADR-0036), or nil
    hud_ack_gap = 0,          -- seconds since the HUD app last acked it is alive; the onUpdate watchdog re-shows the app on a backoff while this grows and a race wants the HUD up (heartbeat silence is also legitimate: 0.39 unmounts the whole apps layer in menu routes)
    hud_reshow_wait = 0,      -- seconds since the watchdog's last re-show, compared against the backoff interval below
    hud_reshow_interval = HUD_RESHOW_EVERY,  -- current re-show cadence: starts at HUD_RESHOW_EVERY on each healthy heartbeat, doubles per silent re-show up to HUD_RESHOW_MAX (menu-hidden silence then costs one layout check per 15s)
    idle_info_shown = false,  -- whether the between-races series info box (ADR-0042) currently holds the HUD app up (lobby/free-roam, no race), so it is shown once and taken down when the series ends
    grid_seed_race = nil,     -- a race to pre-select when the grid-editor panel opens (carried from /raceui's "Grid bearbeiten" cross-open); consumed by push_grid_data
    grid_active_name = nil,   -- the saved name of the grid currently being edited (set on save/load, nil for a fresh unsaved grid); reflected to the panel so a reopen restores the overwrite/assign target
    grid_load_anchor = nil,   -- the race to re-anchor a saved grid onto when loading it (the panel's selected race); grid params are relative to a start line, so a grid can be edited against any race
    grid_edit_prop_names = nil,  -- names of the static-scenery prefabs spawned as a positioning reference during a grid edit (lobby only; cleared with the session). Distinct lifecycle from the race's prop_names
    grid_edit_checkpoints = nil,  -- the active direction's checkpoints in traversal order, CP0 first ({index, pos, normal, radius} each), drawn immediate-mode during a grid edit -- CP0 red, CP1 yellow, the rest grey -- so the grid can be placed against the start line and the route seen from the free camera
    setup_form = nil,         -- the race-setup panel's last form (JSON string), remembered across panel close/reopen within a session so the settings of the last race persist (ADR-0037). The panel autosaves it on every change, so it also survives a UI reload that never runs the panel's Close (bug setup-panel-settings-survive-ui-reload)
    setup_built = nil,        -- the race request (the panel's JSON string, VERBATIM -- never decoded and re-encoded, which would reorder keys and turn an empty list into {}) the staged race was built from, or nil when that is not known: no race, or one this panel did not build (another admin's, a typed /race). The panel compares its form against it and points at Confirm & Build Grid when they differ (feature setup-confirm-grid-stale-hint, ADR-0037 amendment 2026-10-06). Set ONLY by setup.note_race_start; survives the panel's Close on purpose -- the grid is still standing -- and is dropped by teardown_race_world. nil after a GE Lua reload (ADR-0052), and nil means "no hint", so the reload can cost a hint but never fake one
    setup_request = nil,      -- the panel's last Confirm & Build Grid that has not become a race yet: {json, race, overrides, validated, sends}. Tied to its race by setup.note_validation (the validateRace the server sends this client for it) and promoted into setup_built by the raceStart that carries propOwner for it; `sends` counts a double click. A newer Confirm replaces it; a refusal, another request of ours or leaving the session drops it. Deliberately NOT reset by teardown_race_world (it can still become the next race); nil after a GE Lua reload, which costs that one race its hint and nothing else (ADR-0052)
    setup_open = false,       -- the race-setup panel is meant to be on screen: set by the admin-gated setupOpen (handle_setup_open), cleared by close_setup / on leaving the level. The ONLY thing the presence watchdog acts on, so it can reproduce an authorized open but never invent one (ADR-0016/0037). Does NOT survive a Lua reload: this extension has no onSerialize/onDeserialize, so a reload rebuilds M.state from this literal -- the panel stays on screen but is no longer watched until the next /raceui
    setup_seen = false,       -- the panel app has acked at least once since that open, so silence is a real loss and not a slow mount -- keeps the one-shot restore from being spent on a false positive
    setup_ack_gap = 0,        -- seconds since the panel app last acked it is alive; setup.ACK_STALE is the loss threshold
    setup_restored = false,   -- one-shot latch: the lost panel has been re-added once for this open, then the watchdog goes quiet (so BeamNG's own app-container X stays usable)
    controls_open = false,    -- the controls window (/keys, ADR-0061) is on the layout: set by M.toggle_controls, cleared by M.close_controls (the window's own X and the toggle's close half). Local-only and not admin-gated -- it shows this player his own key bindings and nothing else. Deliberately NOT reload-proof (ADR-0052): a GE Lua reload rebuilds it as false while the window is still on screen, so the next /keys re-adds it (ensure_visible dedups, nothing visible happens) and the one after closes it -- one wasted command against no new serialization contract. Nothing else in the mod reads it, so a stale true can only cost that one command
    input_capture = false,    -- the controls window armed BeamNG's input capture and the three global switches (ActionMap.enableBindingCapturing, Input.setForwardRawEvents, setCEFTyping) are presumed on, i.e. the player's controls are dead until something turns them off. Set by M.arm_input_capture, checked and cleared inside M.release_input_capture -- one chokepoint, so no caller can forget the check. Does not survive a GE Lua reload (ADR-0052), which is harmless in the only direction that matters: onExtensionUnloaded runs BEFORE the state is rebuilt and releases there
    server_defaults = nil,    -- the defaults the SERVER owns, as it sent them on setupOpen ({jumpPenalty = 15}, ADR-0043), or nil. Relayed verbatim to the setup panel with EVERY push_setup_data -- not just the opening one -- because the panel also pulls its dataset itself on link (request_setup_data), and a value hanging off setupOpen alone would be gone after a UI reload. GE reads no key of it: the next server-owned default is a key on the server plus a placeholder in the markup. Safe at nil across a GE reload (ADR-0052): it mirrors a server constant and needs no previous value of its own, and nil means "not heard yet", which the panel shows as the neutral "default" rather than a number nothing stands behind. Cleared by setup.clear, which onClientEndMission runs when the player leaves the session -- so one server's numbers can never be shown as the next server's
    own_player_id = nil,      -- the id this connection has on the server, as it named it on setupOpen (yourPlayerId), or nil. Lets the setup panel mark this player's own row in its player list -- the list is a broadcast and cannot say who the reader is. Nil after a GE Lua reload like every other M.state field (ADR-0052), which is why identity.own_id falls back to BeamMP's own copy of the same id -- MPConfig DOES survive a reload. Cleared by setup.clear on leaving the session, so the next server's list is never matched against the previous server's id
    setup_may_open = false,   -- whether the SERVER has told this connection it may open the race-setup panel (setupAccess, feature raceui-reopen-without-typing). The one and only thing the final-standings card's "Race setup" button is drawn off. Set ONLY by that message -- like setup_locked beside it, the client never decides for itself that it is admin, and it derives this from no circumstantial evidence of its own ("I once got a setupOpen", "I have an own_player_id"): those guess right nearly always, which is what makes them the wrong shape. Default false and fail-closed: unknown means no button, so an older server, a dropped message and the ADR-0052 reload rebuild all hide it rather than show a button that would refuse. Connection-scoped, cleared by identity.clear_policy and NOWHERE else -- the grant belongs to the connection (ADR-0056), so dropping it when the panel closes would be the panel-close-wipes-nametag-policy mistake again, with a button that vanishes the first time an admin closes his panel
    setup_locked = false,     -- the race-setup panel shows only its password box (ADR-0056). Set ONLY by a server message -- setupLocked sets it, setupOpen and a successful unlockResult clear it -- so the panel never decides for itself that it is admin. Cleared by setup.clear, and a GE reload rebuilds it as false while taking the panel down with it (ADR-0052), so its correctness never depends on its own previous value. Remembered across the watchdog's re-add, which is why it lives here and not in the app
    championship = nil,       -- latest server-broadcast championship snapshot {active, preset, order, raceCount, rows} (ADR-0040), or nil; rendered on the HUD finished card + the setup panel
    tournament = nil,         -- latest server-broadcast class-drop tournament snapshot {active, ended, winner, classes, rows} (ADR-0042), or nil; rendered on the HUD finished card + the setup panel
    player_list = nil,        -- latest server-broadcast list of the connected players {{id, name, temporary}, ...} (ADR-0054), or nil; rendered in the setup panel's Players section. Safe at nil across a GE reload: the panel then shows its empty state until the next broadcast, and the server pushes on every join, leave and accepted name
    qualifying = nil,         -- qualifying-clock {remaining} for the quali time-remaining HUD (ADR-0041), ticked locally; nil outside the qualifying phase
    qualiResults = nil,       -- quali-results pause clock {remaining} for the "race starts in" countdown (ADR-0041), ticked locally; nil outside quali-results
    quali_settle = false,     -- true once the quali re-grid has placed the cars on the race grid, opening the post-spawn settle window before the start countdown (ADR-0041)
    quali = nil,              -- latest server-broadcast quali classification snapshot {rows} (ADR-0041), or nil; rendered on the quali-results card
    sector_track = nil,       -- qualifying live sector-split tracker (race/sectors), armed on a circuit quali; nil on a sprint quali / outside qualifying
    -- Rally staged sprint quali (ADR-0044): the staged single-car-from-P1 sprint variant. All nil/false
    -- outside a staged qualifying phase, so every staged code path no-ops on a normal race or circuit quali.
    quali_staged = false,     -- true during a staged sprint qualifying phase (M.state.race.quali.staged)
    quali_status = nil,       -- local driver's staged status "queued"|"staged"|"running"|"done", or nil
    quali_run = nil,          -- local per-driver run (qualisprint.new_run) while counting to GO at the ramp, or nil
    quali_queue = nil,        -- latest server-broadcast staged queue snapshot {rows, waiting}, for the HUD; or nil
    quali_ai_runs = nil,      -- host only: {[ai id] = per-driver run} for AI currently counting at the ramp, or nil
    quali_clear_sent = false, -- local driver has reported clearing the ramp (>=15 m) for its current run (Round 4)
    quali_ai_cleared = nil,   -- host only: {[ai id] = true} once a launched AI has reported clearing the ramp
    -- The AI-side mirror of hold.is_held() (bug quali-end-ai-not-frozen). BOTH quali modes: {[ai id] = true}
    -- while that AI is frozen and must STAY frozen -- staged (queued on its slot / counting at the ramp /
    -- done) and circuit (its lap closed inside the finish-your-lap grace). Host only (nil elsewhere; ai_cars
    -- is nil on a non-host, ADR-0036). Drives quali.step_ai_hold's per-frame re-assert, which is what the
    -- player already gets from hold.sync() + rearm_own_car_on_reload and the AI never had.
    quali_ai_held = nil,
    quali_ai_reassert = nil,  -- host only: {[ai id] = os.clockhp of the last re-assert}, the per-car cooldown
    -- The qualifying HOLD (bug quali-hold-reset-and-repaint-leak, ADR-0017 amendment). hold.is_held() is
    -- the single truth; these two carry the state it cannot derive from the fields above.
    quali_lap_done = false,    -- circuit quali: the local driver's lap closed inside the finish-your-lap grace, so their session is over and the car is held (ADR-0041 amendment)
    quali_hold_locked = false, -- the held-ness last pushed to lock.set_recover_blocked, so the sync only calls the engine on a real edge. A cache of an engine state that DOES outlive a GE Lua reload (core/input/actionFilter.lua serializes its action groups) while this flag does not, so it is re-asserted in onExtensionLoaded rather than trusted -- the first sync after a load must never compare against a guessed value
    -- Per-owned-car standstill clock for the client-measured AFK verdict (feature
    -- stall-detection-client-measured-movement), keyed "self" for the local car and by AI id for each
    -- host-driven AI: {since, announced, reported} -- when this car last started standing still, and the
    -- two one-shot latches (its due time was sent / its AFK verdict was sent). A number and two booleans
    -- on purpose, so no engine handle can go stale in it
    -- (like size_track); a GE Lua reload drops it with the rest of M.state, which costs nothing here --
    -- it is re-seeded from zero the next time the finish timer arms. Exists ONLY while M.state.grace is armed:
    -- stall.step drops the whole table whenever the finish timer is not running, which is also what makes
    -- every car start its 15 s from zero the instant the timer arms. nil the rest of the time
    stall_track = nil,
    -- The three centred message surfaces (feature race-toast-cleanup-and-checkpoint-readout, extended by
    -- standings-afk-cutoff-counter), owned by the `notice` namespace: the message line
    -- {text, kind, remaining}, the checkpoint readout {label, time, remaining} and the standing driver's
    -- AFK count {seconds, hint}, plus the shared seconds-to-next-repaint clock. nil when nothing stands.
    --
    -- afk_notice is the odd one out and deliberately so: it carries no `remaining`, because it is a
    -- MEASUREMENT and not a message. stall.check raises it, moves it and drops it; notice.step only keeps
    -- it painted and enforces that it never stands without M.state.grace.
    --
    -- ADR-0052 contract: pure transients whose teardown value IS their literal value here, and
    -- teardown_race_world calls notice.clear(), which also pushes the CLEARING frame to the app -- so a GE
    -- Lua reload can never leave a message stranded on a surface whose GE-side owner has forgotten it.
    notice = nil,
    cp_readout = nil,
    afk_notice = nil,
    notice_repaint = 0,
}

-- Queue a one-shot stock dashboard/tacho rebind (bug default-dashboard-ui-missing-at-race-start): armed
-- at every point the race car is (re)seated (race start + AI reseat, regrid, the racing GO boundary), it
-- lets step_dashboard_refresh wait for the car's VE to be bindable and then rebind the stock apps once.
-- A plain state setter so it stays callable from the handlers above the onUpdate step that consumes it;
-- the optional wait overrides the default settle.
local function arm_dashboard_refresh(wait)
    M.state.dash_refresh_pending = true
    M.state.dash_refresh_wait = wait or DASH_REFRESH_SETTLE
end

-- Outgoing payload sizes per message type, as a high-water mark (bug offroad-race-massive-network-
-- payload-lag). BeamNG stops logging after 15,000 entries and BeamMP's own packet logging can exhaust
-- that budget before a race even starts, so a per-send line would destroy the very data it is meant to
-- produce: a type is logged only when it sets a NEW size peak. Peaks are deliberately never reset -- the
-- lag appears "from one race to the next", so a type that keeps setting new peaks race after race is
-- itself the finding (something accumulates). Sizes only, never payload contents.
local netsize = {peak = {}}

-- Note an outgoing message's encoded size; log it only if it is that type's largest so far.
function netsize.note(message_type, size)
    if size <= (netsize.peak[message_type] or 0) then
        return
    end
    netsize.peak[message_type] = size
    log("I", "beamcomp.net", string.format("payload peak: %s = %d B", message_type, size))
end

-- Client->server send primitive; defined below but forward-declared so the event handlers (and the
-- HANDLERS table) above its definition can reference it.
local send_to_server

-- Disarms the seated car's VE recovery override; defined far below (next to the assist push) but used
-- earlier in handle_race_phase's lobby teardown, so forward-declared here (ADR-0017).
local disarm_assist_ve

-- Disarms the seated car's VE EV-throttle clamp; defined far below (next to the freeze-hold push) but
-- used earlier in handle_race_phase / handle_race_start, so forward-declared here (ADR-0017 amendment).
local disarm_freeze_hold_ve

-- ===== centred race messages (feature race-toast-cleanup-and-checkpoint-readout) ==========
-- Every player-facing message this mod raises goes through notice.say. While the race HUD stands it
-- lands in the screen centre, under the countdown block; anywhere else it stays the top-left toast it
-- always was. The cut runs along the PHASE, not along the text: at a panel or in the grid editor the
-- player is already looking at the screen edge, at the wheel he is looking at the road.

-- How long a centred message stands before it clears itself, and how long the checkpoint readout does.
-- Both are in-game tuning knobs -- neither can be judged outside the game -- as are the two CSS tops in
-- BeamCompHud/app.html (--bc-notice-top, --bc-cp-readout-top).
notice.LIFETIME = 4.0
notice.READOUT_LIFETIME = 2.0

-- Seconds between re-pushes while either surface stands. Same recovery, same reason, same number as
-- countdown.STAGING_REPAINT_INTERVAL: the HUD app mounts best-effort (ADR-0012 section 3) and can be
-- added or UI-reloaded at any moment, and the EARLIEST messages here fire during the raceStart spawn
-- burst -- before the staging phase has ever called hud.show(). A one-shot push in that window would be
-- sent at an app that is not listening yet and lost with no symptom, which is the exact failure this
-- feature exists to end.
notice.REPAINT_INTERVAL = 1.0

-- The phases in which this client's race HUD stands. `spawning` is in the list, and the lobby/nil
-- reading during the raceStart window resolves to it -- see notice.in_race.
notice.RACE_PHASES = {
    spawning = true,
    staging = true,
    countdown = true,
    racing = true,
    qualifying = true,
    qualiResults = true,
    finished = true,
}

-- Whether a message raised right now belongs in the screen centre. THE single phase boundary -- no call
-- site decides this for itself.
--
-- Two readings, and both are load-bearing:
--   * M.state.race -- a race THIS client resolved. A raceStart we could not resolve (handle_race_start's
--     failure path) leaves it nil while the SERVER still walks spawning..finished; there is no HUD on
--     this client then, so a centred push would land on a surface nobody can see. The phase alone would
--     send it there anyway.
--   * M.state.phase -- the server-authoritative phase. `lobby`/nil WITH a resolved race is the raceStart
--     window: the server sends raceStart before it broadcasts the spawning phase (server/main.lua
--     start_race), so the phase still reads lobby while this client is already spawning its car. Two race
--     messages fire in that window (no suitable car, AI load). It can mean nothing else -- the lobby
--     transition nils M.state.race in the same handler (teardown_race_world).
function notice.in_race()
    if not M.state.race then
        return false
    end
    local phase = M.state.phase
    return phase == nil or phase == "lobby" or notice.RACE_PHASES[phase] == true
end

-- Push the current truth of ALL THREE centred surfaces, and restart the repaint clock. Always the whole
-- state, never a delta: one owner writing everything is what keeps this clear of the countdown channel's
-- one-slot failure (see NOTICE_HOOK in race/countdown.lua). The rule scales with the number of surfaces --
-- the AFK count is the third, and it is written here for the same reason the other two are.
function notice.paint()
    M.state.notice_repaint = notice.REPAINT_INTERVAL
    countdown.show_notice(
        M.state.notice and {text = M.state.notice.text, kind = M.state.notice.kind} or nil,
        M.state.cp_readout and {label = M.state.cp_readout.label, time = M.state.cp_readout.time} or nil,
        M.state.afk_notice
            and {seconds = M.state.afk_notice.seconds, hint = M.state.afk_notice.hint} or nil)
end

-- Say one thing to the player. `kind` is the toastr type ("info" / "warning" / "success") and doubles as
-- the centred line's colour; `title` is used only on the toast path, so the two richer toast titles
-- survive verbatim where they are still shown (no text is rewritten by this feature).
function notice.say(msg, kind, title)
    if not notice.in_race() then
        if guihooks then
            guihooks.trigger("toastrMsg", {type = kind or "info", title = title or "BeamComp", msg = msg})
        end
        return
    end
    M.state.notice = {text = msg, kind = kind or "info", remaining = notice.LIFETIME}
    -- The surface lives in the race HUD app, and the staging phase would otherwise be the first thing to
    -- put that app on the layout -- too late for the spawn-time messages. ensure_visible dedups, so this
    -- never disturbs an existing placement (ADR-0012).
    hud.show()
    notice.paint()
end

-- Show one checkpoint passage on the centred readout: "CP 3/8" plus the total time, ~2 s, then gone.
-- Replaces the per-crossing toast -- the one message in the race that fired unasked and repeatedly
-- (8 checkpoints over 3 laps = 24 toasts in a single race).
--
-- Two passages are deliberately silent:
--   * the one that ENDS the race (the last plan entry, seq + 1 == count): the green finish banner and the
--     results card own that moment. That is the last CROSSING, not every crossing of the start/finish
--     line -- a circuit closes a lap on that line every lap, and those do show.
--   * every passage in qualifying: the sector readout already sits on this exact spot with a richer line
--     (split + delta), and qualifying stays untouched. Hence the `racing`-only gate rather than
--     notice.in_race().
--
-- Everything it needs is already at the client (ADR-0011): no new traffic.
function notice.checkpoint(event, count)
    if M.state.phase ~= "racing" then
        return
    end
    if count and event.seq + 1 >= count then
        return
    end
    local race = M.state.race
    local per_lap = ((race and race.checkpoints) and #race.checkpoints) or count or 0
    if per_lap <= 0 then
        -- Unreachable with a live detector (it needs race.checkpoints to step at all), but a readout
        -- reading "CP 5/0" is worse than no readout, so it never gets the chance.
        return
    end
    local done = event.seq + 1
    local in_lap = done
    if race and race.mode == "circuit" then
        in_lap = done % per_lap
        -- A lap-closing crossing lands on 0 here; it is that lap's Nth checkpoint, not its zeroth. The
        -- HUD's own counter reads 0/N in the same second because it describes the NEW lap's progress --
        -- this line describes the crossing that just happened, so the two differ on purpose.
        if in_lap == 0 then
            in_lap = per_lap
        end
    end
    M.state.cp_readout = {
        label = string.format("CP %d/%d", in_lap, per_lap),
        time = event.time,
        remaining = notice.READOUT_LIFETIME,
    }
    notice.paint()
end

-- Drop all three surfaces and tell the app. Called from teardown_race_world, which also runs on
-- onExtensionUnloaded -- see the ADR-0052 note on the M.state fields.
function notice.clear()
    if not M.state.notice and not M.state.cp_readout and not M.state.afk_notice then
        return
    end
    M.state.notice = nil
    M.state.cp_readout = nil
    M.state.afk_notice = nil
    notice.paint()
end

-- Age the two timed surfaces one frame, expire what is due, and keep what stands painted. Called
-- unconditionally from onUpdate: a message raised in the last racing frame still has to expire, and by
-- then the race phase may already be gone. Three nil checks when nothing stands.
--
-- The AFK count is NOT aged here -- it has no lifetime, stall.check owns it. What it does get here is its
-- one unconditional guard: it belongs to the finish timer, so no timer means no count. This runs in every
-- phase where stall.step does not, which is what makes it a property rather than a list of clear sites.
function notice.step(dt)
    local line = M.state.notice
    local readout = M.state.cp_readout
    if not line and not readout and not M.state.afk_notice then
        return
    end
    local expired = false
    if M.state.afk_notice and not M.state.grace then
        M.state.afk_notice = nil
        expired = true
    end
    if line then
        line.remaining = line.remaining - (dt or 0)
        if line.remaining <= 0 then
            M.state.notice = nil
            expired = true
        end
    end
    if readout then
        readout.remaining = readout.remaining - (dt or 0)
        if readout.remaining <= 0 then
            M.state.cp_readout = nil
            expired = true
        end
    end
    M.state.notice_repaint = (M.state.notice_repaint or 0) - (dt or 0)
    if expired or M.state.notice_repaint <= 0 then
        notice.paint()
    end
end
-- ===== end centred race messages ==========================================================

-- The server's heartbeat. Nothing to tell the player -- it used to echo "Server event: ping" as a toast,
-- which is a developer's confirmation that the channel is alive, not a race message. The log line is that
-- confirmation now.
local function handle_ping(_payload)
    log("I", LOG_TAG, "server ping")
end

-- Resolve + lay out the race for this client and store the state. On any failure (the server cannot
-- validate the name, ADR-0005) warn and toast the reason -- the only message here that still belongs
-- top-left, because a race we could not resolve leaves this client with no HUD to speak on.
local function handle_race_start(payload)
    -- Adopt the server's statistics setting (ADR-0053) before anything else in this handler. Position is
    -- deliberate: BOTH per-race clear blocks below -- the resolve-failure path and the accept path -- run
    -- after this point, and this is a property of the SERVER, not of a race we may have failed to resolve,
    -- so it must survive either of them. Not added to those clear lists for the same reason.
    --
    -- The `== true` is the entire "unknown means off" rule: an absent field, an older server, a truthy
    -- non-boolean -- every one of them leaves the analysis UI hidden. Absence never resurrects the feature.
    M.state.stats_enabled = type(payload) == "table" and payload.statsEnabled == true

    -- The server's nametag policy, re-asserted with every race (ADR-0062). Unlike statsEnabled the safe
    -- reading of "unknown" here is ON, not off: this setting defaults to on, so an absent field, an
    -- older server or a dropped message has to leave the session looking like plain BeamMP rather than
    -- silently stripping everybody's name. The props are outside it and silent either way.
    M.state.show_driver_names = not (type(payload) == "table" and payload.showDriverNames == false)

    -- A starting race ends any in-progress grid edit so its preview pillars never bleed into the race
    -- (the ADR-0023 editor is a lobby-only authoring tool); clear its reference props and drop the panel.
    if grideditor.state.active then
        grideditor.clear()
        M.state.grid_active_name = nil
        props.clear(M.state.grid_edit_prop_names or {})
        M.state.grid_edit_prop_names = nil
        M.state.grid_edit_checkpoints = nil
        M.uilayout.remove("beamCompGridEditor")
    end
    -- ...and the camera that followed the edit gets no old pose back, which would fight the race placement;
    -- if it is still free from our jump, it goes into the car instead (ADR-0063). Outside the branch above
    -- on purpose -- a remembered camera can outlive its session (M.clear_grid_editor alone leaves it
    -- standing), and it must not reach into a race either way.
    M.gridcam.leave("race")

    local race, reason = race_start.prepare(payload)
    if not race then
        log("W", RACE_LOG_TAG, "raceStart ignored: " .. tostring(reason))
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = "Race not started: " .. tostring(reason),
        })
        -- A raceStart we can't resolve still means the server has begun a new race, so any prior race
        -- on this client is over. Drop its state (and blank the HUD) so the phase guard below skips the
        -- countdown/racing for a race we are not in, and nothing stale lingers. Lift the in-race lock
        -- and restore the car's recovery too: on an abort-restart (finished -> spawning, no lobby) a
        -- prior race we DID run could otherwise leave us locked through a race we are not in (ADR-0017).
        M.state.race = nil
        M.state.race_car_id = nil
        M.state.race_caps = nil
        M.state.race_forced_car = false
        M.state.staged_spec = nil
        M.state.revert_pending = false
        M.state.staging_swap_reverting = false
        M.state.detection = nil
        M.state.laptimer = nil
        M.state.marker_angles = nil
        M.state.standings = nil
        M.state.car_info = nil
        M.state.race_records = nil
        M.state.analysis_open = false
        M.state.provisional_open = true
        M.state.grace = nil
        M.state.stall_track = nil
        M.state.stall_cutoff = nil
        M.state.assist_armed = false
        M.state.assist_held = nil
        M.state.assist_arming = nil
        M.state.assist_notice = nil
        M.state.freeze_hold_armed = false
        M.state.dash_refresh_pending = false
        -- Clear any AI cars from a prior race too (ADR-0036): on an abort-restart this client may have
        -- been the previous owner, so its host-spawned AI must not linger into a race it is not in.
        ai.stop(M.state.ai_cars or {})
        ai.clear(M.state.ai_cars or {})
        if M.state.ai_custom_map then
            ai.restore_map()
            M.state.ai_custom_map = nil
        end
        M.state.ai_cars = nil
        M.state.ai_config = nil
        M.state.ai_detections = nil
        M.state.ai_window = nil
        M.state.ai_laptimers = nil
        M.state.ai_map_pending = false
        M.state.ai_remote_ids = nil
        M.state.ai_server_ids = nil
        lock.remove()
        disarm_assist_ve()
        disarm_freeze_hold_ve()
        countdown.clear()
        hud.clear()
        -- No race on this client means no grid the setup panel could describe -- and if this was the
        -- panel's own Confirm, it will not stage here either.
        setup.forget_build("race start rejected")
        setup.drop_request("race start rejected")
        return
    end

    M.state.race = race
    -- Whether the setup panel built this race decides whether it may compare against it (feature
    -- setup-confirm-grid-stale-hint). Here, before the spawn below: the panel hears the answer before
    -- the staging phase that shows it.
    setup.note_race_start(payload)

    -- Backstop for the scenery pull (ADR-0046): we are racing off the host's relayed definition -- so we
    -- do NOT have this track -- and have no scenery for it. Either the prefetch probe never reached us or
    -- its answer is still in flight. Ask (again): the server serves it from its cache, and
    -- handle_track_data spawns the props the moment they land, still inside the frozen pre-race phases. A
    -- duplicate request is harmless (the server dedupes on its waiting set), and a client that has the
    -- track never gets here at all.
    if race.relayed and #(race.prefabFiles or {}) == 0 then
        send_to_server("trackNeed", {raceId = race.raceId})
    end
    M.state.marker_warned = false
    -- Mute BeamMP's spawn notifications for the spawn burst: the host's ~14 synced cones would
    -- otherwise flood every other client's notification list (ADR-0020 finding #2b). Armed on every
    -- client; the raceStart always arrives before the host's cone spawns can propagate, so the window
    -- opens in time. A real player spawning inside the window is muted too -- accepted edge case.
    spawn_mute.mute_for(SPAWN_NOTIFICATION_MUTE_SECONDS)
    -- Drop any stale race-car id up front; it is re-set below once the car is placed, and left nil if
    -- the placement fails (so the switch lock has no bounce target and lets switches through).
    M.state.race_car_id = nil
    -- Reset checkpoint detection and any stale standings/grace; all are refreshed during the race (the
    -- abort-restart path is finished -> spawning, skipping the lobby reset, so clear them too).
    M.state.detection = nil
    M.state.laptimer = nil
    -- Same reason for the marker orientation slew state: a back-to-back restart skips teardown, so the
    -- posts must not ease from the prior race's stored angles.
    M.state.marker_angles = nil
    M.state.standings = nil
    M.state.car_info = nil
    M.state.race_records = nil
    M.state.analysis_open = false
    M.state.provisional_open = true
    M.state.grace = nil
    M.state.stall_track = nil
    M.state.stall_cutoff = nil
    M.state.staging = nil
    M.state.countdown = nil
    -- Drop any F1 light-start state (ADR-0043) so a prior race's latched jump can never leak into this one.
    M.state.f1 = nil
    M.state.ai_release = nil
    -- Drop any quali state from a prior event (ADR-0041) so a stale clock/results card never carries over.
    M.state.qualifying = nil
    M.state.qualiResults = nil
    M.state.quali = nil
    M.state.quali_settle = false
    -- Drop staged sprint quali state (ADR-0044) so a prior event's queue/run never leaks in.
    M.state.quali_staged = false
    M.state.quali_status = nil
    M.state.quali_run = nil
    M.state.quali_queue = nil
    M.state.quali_ai_runs = nil
    M.state.quali_clear_sent = false
    M.state.quali_ai_cleared = nil
    -- Drop the quali hold (bug quali-hold-reset-and-repaint-leak): handle_race_start lifts the whole lock
    -- (lock.remove above), which releases the recover keys, so the record of the block must follow it.
    M.state.quali_lap_done = false
    M.state.quali_hold_locked = false
    -- Drop the qualifying live sector-delta tracker (feature: quali-live-sector-delta); it is re-armed
    -- in the qualifying phase for a circuit quali.
    M.state.sector_track = nil
    -- Reset the HUD watchdog so the (re)started race gets a clean grace window and a fresh (fast)
    -- re-show cadence.
    M.state.hud_ack_gap = 0
    M.state.hud_reshow_wait = 0
    M.state.hud_reshow_interval = HUD_RESHOW_EVERY
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    M.state.assist_notice = nil
    -- Re-arm the EV freeze clamp for this race: cleared here so push_freeze_hold fires again in staging
    -- (the abort-restart path skips the lobby reset, ADR-0017 amendment).
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
    M.state.restage_plate = nil
    -- Drop any queued stock-dashboard rebind from a prior race; this race re-arms it once its car is seated
    -- (bug default-dashboard-ui-missing-at-race-start).
    M.state.dash_refresh_pending = false
    -- Blank the HUD so an abort-restart never carries a stale frozen readout into the countdown.
    hud.clear()

    -- Lift any in-race lock before respawning (ADR-0017): the abort-restart path (finished -> spawning)
    -- skips the lobby reset, so a prior race's lock could still be guarding core_vehicles.spawnNewVehicle
    -- and refuse our own fresh-spawn fallback. The countdown phase re-arms it.
    lock.remove()

    -- Resolve the car the player is in, preferring the onVehicleSwitched-tracked id (the polling API
    -- be:getPlayerVehicle(0) sticks to the first owned car in BeamMP). Resolve BEFORE loading props
    -- so the choice is taken before any prop-vehicle churn.
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)

    -- Load the race's static-scenery prefab(s) BEFORE the vehicle respawn, so the fresh car's
    -- spawn + auto-enter stays the LAST scene action and the player lands seated in it. Loading
    -- props after the respawn left the player's camera latched onto a prop (a pylon) instead of
    -- the car. Clear first so re-issuing /race never stacks duplicates; placement is client-local
    -- + deterministic (see race/props.lua). The knockable cones are shared (ADR-0020): only the
    -- propOwner (host) spawns + keeps them (cone_ids, cleared here on re-issue too); non-hosts spawn
    -- a statics-only prefab and never instantiate a cone. The abort/restart path skips the lobby
    -- branch, so clearing here is what prevents host cone-stacking on a re-issued /race.
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    -- Despawn any prior powered props (grinders) too, so a re-issued /race never stacks them -- the same
    -- reason cones are cleared here (ADR-0020 amendment). By SCENE SCAN, not by the ids the last load
    -- captured: BeamMP re-spawns the props under new ids a few seconds after they appear, so a stored id
    -- list is dead and deleted nothing (bug race-prop-steals-player-seat round 3). Run it when we owned the
    -- previous set OR are about to spawn a new one, so a leftover can never stack under a fresh load.
    if M.state.prop_owner or payload.propOwner then
        grinders.clear_scene()
    end
    local grinder_seed, prop_before
    M.state.prop_names, M.state.cone_ids, grinder_seed, prop_before = props.load(race.prefabFiles or {},
        payload.propOwner, race.coneFiles or {})
    -- The host keeps the pre-load vehicle snapshot for the whole race: it is what "a prop" MEANS
    -- (ADR-0062). Everything that appeared since, minus the cars this client put on the grid itself, is
    -- one -- re-derivable, so BeamMP re-spawning the props under new ids a few seconds from now changes
    -- nothing. Non-hosts spawn no prop and derive nothing; they are told (propMap).
    M.state.prop_before = payload.propOwner and prop_before or nil
    M.state.prop_ids = nil
    M.state.prop_map_sent = nil
    M.state.prop_map_pending = M.state.prop_before ~= nil
    M.state.prop_map_wait = 0
    M.state.prop_map_budget = identity.PROP_MAP_BUDGET
    -- Whether we are the client that spawns and owns the shared prop-vehicles (ADR-0020). Kept in state
    -- because the grinder paths need it long after this handler: the activation window and the scene-scan
    -- cleanup must both stay host-only, and teardown runs with no payload in hand.
    M.state.prop_owner = payload.propOwner == true
    -- Arm the powered props' (grinders') activation window: their `spinner` controller only comes up after
    -- the freshly spawned VE's powertrain init, so onUpdate re-issues the activation while the window is open
    -- (ADR-0020 amendment). Arming only OPENS it -- the deadline starts on the first frame that actually
    -- runs, so the rest of this handler (the AI field spawns synchronously below, plus the own-car respawn
    -- and the collision rebuild) cannot spend the window before a single activation went out; that is
    -- precisely what happened before (round 2). The prefab's ids are only a SEED: grinders.step re-derives
    -- the live set from the scene each frame, because BeamMP replaces the props under new ids a few seconds
    -- in (round 3). nil = idle / non-host / no grinders (re-armed on every /race; nil'd again on teardown).
    M.state.grinder_activate = payload.propOwner and grinders.arm(grinder_seed) or nil

    -- Clear any AI cars from a prior race up front so a re-issued /race never stacks them (ADR-0036), the
    -- same reason cones are cleared here. Host-only state; all nil on a non-owner. The new AI cars are
    -- spawned at the end, once this client's own car is placed.
    ai.stop(M.state.ai_cars or {})
    ai.clear(M.state.ai_cars or {})
    if M.state.ai_custom_map then
        ai.restore_map()
        M.state.ai_custom_map = nil
    end
    M.state.ai_cars = nil
    M.state.ai_config = nil
    M.state.ai_detections = nil
    M.state.ai_window = nil
    M.state.ai_laptimers = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil
    M.state.ai_names = nil

    -- Place this client's own car at the assigned grid pose: the car the player is in is repaired +
    -- teleported in place (preserving its settings), or a fresh one is spawned as a fallback
    -- (ADR-0007). Owned-only + BeamMP-propagated (see race/vehicles.lua). The grid markers keep
    -- rendering from M.state.race regardless.
    -- The relayed vehicle policy (ADR-0032), read straight off the payload like propOwner (not via
    -- race_start.prepare, which only handles race geometry): car = fixed car for all (Mode 2),
    -- maxhp/maxpwr = per-player power / power-to-weight caps, maxkg/minkg = per-player strict curb-weight
    -- range (Mode 3), all nil = keep own car (Mode 1).
    local policy = {
        car = payload.car,
        maxhp = payload.maxhp,
        maxpwr = payload.maxpwr,
        maxkg = payload.maxkg,
        minkg = payload.minkg,
        -- car=random composable axes (ADR-0032 amendment), relayed verbatim + resolved client-side: a random
        -- compliant trim vs. the stock trim, and the big-car curb-weight exclusion. Meaningful only for
        -- car=random; nil (any other car) is ignored by respawn_own_at.
        randomTrim = payload.randomTrim,
        noBigCars = payload.noBigCars,
        -- car=host (ADR-0032 amendment): the {model, config} the ISSUER's client captured at the
        -- pre-flight verdict, relayed opaquely by the vehicle-blind server. Read only for car=host;
        -- "host" is not a model name and never reaches a car-token parser.
        hostCar = payload.hostCar,
        -- Whether THIS client is the one whose car was captured -- IDENTITY, not a value compare. The
        -- server sets propOwner for entry.id == owner_id, and owner_id is exactly the client that
        -- answered validateRace, so the flag means "the relayed spec is a copy of my own car". The host
        -- must therefore be left alone; comparing the relayed config against a fresh partConfig read
        -- instead would be table == table on two separate reads for a TUNED car -- always false -- and
        -- would respawn the host into a stock copy, losing its plate, paint and tuning in the one case
        -- where nothing should happen at all.
        hostCarIsOwn = payload.propOwner == true,
    }
    -- Remember the Mode-3 caps for the staging swap-compliance gate (ADR-0032): a car swap during staging
    -- must not stage a car over the cap. Mode 3 only -- a fixed car (Mode 2, car=) or no policy (Mode 1)
    -- leaves this nil and the gate is skipped. Seeded fresh here; staged_spec (the compliant car to revert
    -- an over-cap swap back to) is captured at staging entry, once the placed car's jbeam is loaded.
    M.state.race_caps = (not policy.car and (policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg))
        and {maxhp = policy.maxhp, maxpwr = policy.maxpwr, maxkg = policy.maxkg, minkg = policy.minkg} or nil
    -- Whether this race forces the car, for the race lock's parts guard (ADR-0064). All four forced modes
    -- (a model, random, host, a class-drop class with a car) arrive in this one field, so the lock never
    -- needs to know which. Decided on the policy, not on the car that ends up on the slot: a car=host whose
    -- relay failed keeps the own car, and the lock then freezes that car as it stands.
    M.state.race_forced_car = type(policy.car) == "string" and policy.car ~= ""
    M.state.staged_spec = nil
    M.state.revert_pending = false
    M.state.staging_swap_reverting = false
    -- Capture the own-car id BEFORE respawn: a forced/fresh spawn (spawn_fixed / fresh_spawn_own)
    -- despawns own_car inside respawn_own_at, so own_car:getId() afterwards would call a method on a
    -- deleted handle and abort handle_race_start (no spawnReady, no AI -> the race cancels to lobby).
    -- We only need the id below to detect a fresh spawn, so read it now while the car is still alive.
    local own_car_id = own_car and own_car:getId() or nil
    -- Read the player's plate now, before respawn_own_at despawns own_car. A forced/substitute spawn
    -- (Mode 2 / Class-Drop / Mode-3) comes up with a GENERATED plate -- spawnNewVehicle ignores a
    -- spawn-time licenseText and the jbeam regenerates it -- so we re-apply this plate on the deferred
    -- restage once the new car's jbeam has loaded (vehicles.apply_plate in restage_swapped_car).
    local own_plate = vehicles.read_plate(own_car)
    -- Report the footprint of the car we are ABOUT to put on the grid, before spawning it (ADR-0051).
    -- Wherever the car is already decided -- a fixed car= policy, a class-drop class car, or simply
    -- keeping our own -- the server can reserve the space behind it right away instead of waiting for
    -- the post-spawn report at the end of this handler. It never gates anything: a car that is only
    -- decided at spawn time (a Mode-3 substitute, car=random) reports nil here and nothing is sent.
    local planned_length, planned_width = vehicles.planned_size(policy, own_car)
    if planned_length then
        send_to_server("clientInfo", {
            race = payload.race,
            carLength = planned_length,
            carWidth = planned_width,
        })
    end
    -- Open the bounding-box tally for this race: every car this client puts on the grid below (own car
    -- plus, on the host, the AI field) counts whether its footprint could be read from metadata before
    -- the spawn. Closed by log_bbox_report at the end of this handler with a single verdict line.
    vehicles.begin_bbox_report()
    local race_car, respawn_err, degraded = vehicles.respawn_own_at(race.myPose, own_car, policy)
    if degraded then
        -- No-suitable-car fallback (ADR-0032 §5 superseded): the resolver spawned the fixed default car
        -- because no cap-compliant / random-pool car was available (a Mode-3 cap with no compliant car, or
        -- car=random with an empty cap-composed pool). Warn the player, then STILL race -- the cap is
        -- best-effort now, never a non-participation outcome. The ordinary Mode-1 on-foot fresh-spawn does
        -- NOT set this flag, so a plain foot-start stays silent (it is not a no-suitable-car case).
        log("W", RACE_LOG_TAG, "no suitable car -- spawned default; warning and racing")
        notice.say("No suitable car available -- spawning default car", "warning",
            "BeamComp -- " .. race.name)
    end
    if race_car then
        -- Remember the race car as the bounce target for the in-race switch lock (onVehicleSwitched):
        -- during countdown/racing any switch to another vehicle is bounced back to this id.
        M.state.race_car_id = race_car:getId()
        -- Re-assert the player into the race car. Harmless when they are already seated (kept-car
        -- path); on the fresh-spawn fallback this guarantees seating even if a prop-vehicle slipped
        -- past the auto-enter race rather than leaving the player on a prop.
        if be then
            pcall(function() be:enterVehicle(0, race_car) end)
        end
        -- Spawn/place the car frozen: hold it from race start through the countdown so nobody can
        -- jump the start (released on the racing phase, see handle_race_phase). Freeze the resolved
        -- handle directly: on the fallback the spawn settles over later frames, so the command must
        -- be queued to this exact vehicle's VE.
        local frozen, freeze_err = vehicles.set_vehicle_frozen(race_car, true)
        if not frozen then
            log("W", RACE_LOG_TAG, "could not freeze race car: " .. tostring(freeze_err))
        end
        -- A freshly spawned race car lands center-anchored: the spawn path can't front-anchor
        -- a car whose jbeam is still loading. Arm the deferred re-stage (restage_swapped_car) so
        -- it front-anchors at the grid slot once its bbox loads -- identical placement to every
        -- other car (and to the AI restage). This fires for ANY fresh spawn: a forced car
        -- (Mode 2 / Class-Drop) or a Mode-3 substitute spawns fresh like the Mode-1 no-own-car
        -- fallback. Detect it by id (own_car_id, captured before the respawn) -- a kept car
        -- (keep_own / Mode-3 compliant) keeps the SAME id, a fresh spawn gets a new one.
        if not own_car_id or race_car:getId() ~= own_car_id then
            M.state.restage_pending = true
            M.state.restage_baseline = nil
            M.state.restage_wait = RESTAGE_MAX_WAIT
            M.state.restage_preplaced = 0
            -- The fresh car came up with a generated plate; re-apply the player's own plate on the
            -- restage, once its jbeam has loaded. Only this fresh-spawn path carries a plate -- a staging
            -- swap (lock.consume_replace) is the player's own pick and keeps the plate it spawned with.
            M.state.restage_plate = own_plate
        end
        log("I", RACE_LOG_TAG, string.format("placed at grid slot %d", race.mySlot))
    else
        log("W", RACE_LOG_TAG, "race-car placement skipped: " .. tostring(respawn_err))
    end

    log("I", RACE_LOG_TAG, string.format("race '%s': you are slot %d, mode=%s laps=%d",
        race.name, race.mySlot, tostring(race.mode), race.laps or 1))

    -- Tell the server this client is spawned + seated so it can leave the spawning phase once everyone
    -- is ready instead of waiting a fixed delay (ADR-0006 amendment). Sent unconditionally -- even if
    -- placement degraded above -- so a spawn hiccup never hangs the race; the deferred restage (if any)
    -- runs after this and does not gate the ack. Echo payload.race (the exact name the server relayed,
    -- == session.race), not the resolved race.meta.name, so the server's stale-ack guard matches.
    send_to_server("spawnReady", {race = payload.race})

    -- Report the vehicle metadata so the server can record what car was driven (ADR-0027). A dedicated
    -- message, not piggybacked on the ack above, so the spawnReady contract stays narrow. Echo
    -- payload.race like the ack so the server's race-guard matches. Sent unconditionally;
    -- collect_client_info degrades every field to nil on a spawn hiccup. The player identity rides a
    -- separate clientIdentity message (at connect), since it is connection-scoped, not per-race (ADR-0054).
    local client_info = vehicles.collect_client_info(race_car)
    send_to_server("clientInfo", {
        race = payload.race,
        vehicle = client_info.vehicle,
        -- Power-to-weight for the start-order pwr mode (ADR-0033); nil when unreadable. The server stores
        -- it per player and only sorts by it -- it never reads the vehicle (race-blind, ADR-0005).
        pwr = client_info.pwr,
        -- Grid footprint in metres for the size-aware slot reservation (ADR-0051); same form as pwr --
        -- numbers the server does arithmetic on, never a vehicle it reads.
        carLength = client_info.car_length,
        carWidth = client_info.car_width,
    })

    -- Host only: spawn the AI opponents the server assigned this client (ADR-0036). Only the owner's
    -- raceStart carries aiSlots, so non-owners skip this entirely -- they just receive the synced cars and
    -- the aiMap. The cars spawn frozen at their grid poses (held through staging/countdown, released on
    -- racing), are kept out of this client's Tab cycle, and are queued for the aiMap broadcast that lets
    -- remotes label + suppress them. The spawn-notification mute armed above also covers their burst.
    if type(payload.aiSlots) == "table" and #payload.aiSlots > 0 then
        -- The relayed AI difficulty/vehicle config (ADR-0036 Etappe B), owner-only; the driving params and
        -- the per-car vehicle choice resolve from it plus the race's content defaults.
        M.state.ai_config = payload.aiConfig
        -- Keep the policy so a quali re-grid (ADR-0041) can re-spawn fresh AI on the earned grid.
        M.state.ai_policy = policy
        -- The AI vehicle chain reuses the relayed player policy (ADR-0032) as its second tier. The
        -- "same as host" mode (aicar=host) inherits the owner's ACTUAL seated race car (model+config), read
        -- GE-side here from race_car so the server stays vehicle-blind (ADR-0005/0036); re-read on each
        -- (re)spawn so the AI follow if the host's car changes. nil when placement degraded -> the resolver
        -- logs and falls through so the AI still race.
        local host_car = race_car and vehicles.host_car_spec(race_car) or nil
        -- Report the footprint of every AI whose car is already decided -- a roster pick (ADR-0047) or a
        -- class-drop class car (ADR-0042) -- BEFORE spawning them, so a bus in the AI field reserves its
        -- space on the earliest grid the server can build (ADR-0051). A randomly rolled AI car is only
        -- known afterwards and rides the post-spawn proxy report below.
        for _, ai_slot in ipairs(payload.aiSlots) do
            local ai_length, ai_width = vehicles.token_size(ai_slot.car)
            if ai_length then
                send_to_server("clientInfo", {
                    race = payload.race,
                    aiId = ai_slot.id,
                    carLength = ai_length,
                    carWidth = ai_width,
                })
            end
        end
        local cars = ai.spawn(payload.aiSlots, race.gridPoses, payload.aiConfig, race.aiDefaults, policy,
            host_car)
        if #cars > 0 then
            ai.set_frozen(cars, true)
            for _, car in ipairs(cars) do
                local veh = be and be:getObjectByID(car.veh_id)
                if veh then
                    ai.suppress(veh)
                    -- Report this AI car's power-to-weight by proxy (ADR-0036 Etappe B) so the server can
                    -- sort it into an order=pwr grid (ADR-0033); aiId-tagged, owner-only. Best-effort: a
                    -- nil pwr just leaves the AI in its provisional back-of-grid slot. The footprint
                    -- rides along (ADR-0051) so an AI bus reserves the slot behind it too -- this is the
                    -- only report that sees a RANDOMLY rolled AI car, which no pre-spawn read can know.
                    local ai_info = vehicles.collect_client_info(veh)
                    send_to_server("clientInfo", {
                        race = payload.race,
                        aiId = car.id,
                        pwr = ai_info.pwr,
                        carLength = ai_info.car_length,
                        carWidth = ai_info.car_width,
                    })
                end
            end
            M.state.ai_cars = cars
            M.state.ai_map_pending = true  -- broadcast the server-id map once BeamMP registers the cars
            -- Spawning a car auto-enters the player into it, so after the AI burst the player can be
            -- sitting in the last AI car. Re-seat them in their own race car and re-assert it as the
            -- tracked seated car so the detector keeps reading the right vehicle.
            if race_car and be then
                pcall(function() be:enterVehicle(0, race_car) end)
                M.state.current_vehicle_id = race_car:getId()
            end
            log("I", RACE_LOG_TAG, string.format("spawned %d AI opponent(s)", #cars))
            -- Performance hint (ADR-0036 Etappe B): all AI physics run on this host, so warn once past a
            -- handful. Owner-local + non-blocking -- it never gates the spawn.
            if #cars >= AI_PERF_HINT_THRESHOLD then
                notice.say(string.format("%d AI cars run on your machine -- expect higher load.", #cars),
                    "warning", "BeamComp -- AI")
            end
        end
    end

    -- Race-start seat churn is done (own-car seat + any AI reseat above): queue the one-shot stock
    -- dashboard/tacho rebind so it fires once the race car's VE is bindable, instead of trusting the
    -- implicit be:enterVehicle switch alone to have re-bound it under the spawn lag (bug
    -- default-dashboard-ui-missing-at-race-start). No car placed -> nothing to rebind.
    if M.state.race_car_id then
        arm_dashboard_refresh()
    end

    -- Every grid spawn of this race is done: one line saying whether the pre-spawn bounding-box lookup
    -- carried. This is the in-game proof that BeamMP passes core_vehicles' config metadata through; a
    -- "0 of N cars resolved (metadata unavailable)" means the cars fell back to the old centre-anchored
    -- spawn plus restage, and that a second box source is needed.
    vehicles.log_bbox_report()
end

-- Despawn everything BeamComp put into the world for a race and drop all race-scoped state, leaving
-- the player's own car exactly where it is (only unfrozen + unlocked, never despawned or moved).
-- Idempotent: props.clear/cones.clear no-op on already-gone objects and set_vehicle_frozen no-ops on
-- a nil car, so calling it when nothing is spawned is harmless. Shared by the lobby phase (regular
-- end / raceend), onClientEndMission (left the session / changed level mid-race), and
-- onExtensionUnloaded (Lua reload). Deliberately does NOT touch M.state.phase, the BeamMP event
-- handler, or editor/spawn-mute state -- each caller owns those.
local function teardown_race_world()
    countdown.clear()
    -- Take any standing centred message + checkpoint readout down with the race, and push the clearing
    -- frame while the app is still there to hear it (feature race-toast-cleanup-and-checkpoint-readout).
    -- This also runs from onExtensionUnloaded, which is what keeps a GE Lua reload from stranding a
    -- message on a surface whose GE-side owner has just been rebuilt empty (ADR-0052).
    notice.clear()
    hud.clear()
    hud.hide()
    -- Lift the in-race vehicle-action lock and restore the seated car's vanilla recovery (ADR-0017).
    lock.remove()
    disarm_assist_ve()
    -- Release the EV start-freeze throttle clamp too (ADR-0017 amendment); idempotent on absent cars.
    disarm_freeze_hold_ve()
    -- Despawn the track props and the host's shared cones (idempotent on absent names/ids, ADR-0020).
    props.clear(M.state.prop_names or {})
    cones.clear(M.state.cone_ids or {})
    -- Despawn the host's powered props (grinders) too, so they never orphan into free-roam after the race
    -- (ADR-0020 amendment). Shared by lobby end, onClientEndMission (session leave / level change) and
    -- onExtensionUnloaded (reload). By SCENE SCAN and gated on being the prop owner: the ids captured at the
    -- prefab load are dead within seconds (BeamMP re-spawns the props), so the old id-based clear deleted
    -- nothing that existed and the real grinders leaked into free-roam -- the ADR-0020 leak was still open
    -- until now (bug race-prop-steals-player-seat round 3).
    if M.state.prop_owner then
        grinders.clear_scene()
    end
    -- Despawn the host's AI cars (ADR-0036): stop them first so none lurches on the delete frame.
    -- Idempotent + host-only (all nil on a non-owner). Remote AI id sets are just dropped below.
    ai.stop(M.state.ai_cars or {})
    ai.clear(M.state.ai_cars or {})
    if M.state.ai_custom_map then
        ai.restore_map()
        M.state.ai_custom_map = nil
    end
    M.state.ai_cars = nil
    M.state.ai_config = nil
    M.state.ai_detections = nil
    M.state.ai_window = nil
    M.state.ai_laptimers = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.grinder_activate = nil
    -- The nametag half of the props goes with them (ADR-0062). The props themselves are deleted just
    -- above, so their BeamMP entries disappear and nothing is left half-silenced; the driver policy is
    -- connection-scoped and deliberately NOT cleared here (ADR-0062 decision 6: it applies to the whole
    -- session, not to a race).
    M.state.prop_before = nil
    M.state.prop_ids = nil
    M.state.prop_map_pending = false
    M.state.prop_map_sent = nil
    M.state.ai_names = nil
    -- Drop the staging-swap pre-anchor hook with the race that installed it, so no closure outlives the
    -- pose it was built for (ADR-0051 round 2). Re-installed on the next staging phase.
    lock.on_before_replace = nil
    -- Re-report the lobby car footprint after a race: the car (and with it the footprint) is very likely a
    -- different one now, and the next /race must not assign slots from the pre-race value.
    M.state.size_track = {}
    -- prop_owner is deliberately NOT cleared here: it is the "we spawned the shared props" marker that gates
    -- the scene-scan cleanup, and teardown runs from several places (lobby, session leave, extension
    -- unload). Clearing it would make every pass after the first a no-op, so a prop that reappeared late --
    -- BeamMP's re-spawn racing our delete -- could never be reaped. handle_race_start overwrites it with the
    -- new race's value, and nothing else reads it without also requiring an active race.
    M.state.race = nil
    M.state.race_car_id = nil
    M.state.detection = nil
    M.state.laptimer = nil
    -- The grid the setup panel compares against goes with the race (feature
    -- setup-confirm-grid-stale-hint). A Confirm still on its way is left alone: it can still become the
    -- next race, and only this client's own race check ties it to one.
    setup.forget_build("race torn down")
    -- Drop any queued stock-dashboard rebind so it never fires in free-roam after teardown
    -- (bug default-dashboard-ui-missing-at-race-start).
    M.state.dash_refresh_pending = false
    -- Drop the marker orientation slew state so the next race's posts never ease from a stale angle.
    M.state.marker_angles = nil
    M.state.standings = nil
    M.state.car_info = nil
    M.state.race_records = nil
    M.state.analysis_open = false
    -- Back to "unknown", which means OFF (ADR-0053). Cleared HERE and not in handle_race_start's per-race
    -- blocks, so this is the ADR-0052 contract for the field: a GE Lua reload rebuilds M.state from its
    -- literal, and the literal's `false` is exactly the value this teardown leaves behind. Safe to clear
    -- between races because teardown also drops M.state.standings, so it provably cannot run between
    -- racing and finished -- the finished card would be empty. The next raceStart re-asserts the truth.
    M.state.stats_enabled = false
    M.state.provisional_open = true
    M.state.grace = nil
    M.state.stall_track = nil
    M.state.stall_cutoff = nil
    M.state.staging = nil
    M.state.countdown = nil
    -- Drop any F1 light-start state (ADR-0043) so a prior race's latched jump can never leak into this one.
    M.state.f1 = nil
    M.state.ai_release = nil
    -- Drop any quali state from a prior event (ADR-0041) so a stale clock/results card never carries over.
    M.state.qualifying = nil
    M.state.qualiResults = nil
    M.state.quali = nil
    M.state.quali_settle = false
    -- Drop staged sprint quali state (ADR-0044) so a prior event's queue/run never leaks in.
    M.state.quali_staged = false
    M.state.quali_status = nil
    M.state.quali_run = nil
    M.state.quali_queue = nil
    M.state.quali_ai_runs = nil
    M.state.quali_clear_sent = false
    M.state.quali_ai_cleared = nil
    -- Drop the quali hold (bug quali-hold-reset-and-repaint-leak): lock.remove above already released the
    -- recover keys, so the record of the block must follow it -- otherwise the next quali hold would see a
    -- stale "already blocked" and never push the block.
    M.state.quali_lap_done = false
    M.state.quali_hold_locked = false
    -- Drop the qualifying live sector-delta tracker (feature: quali-live-sector-delta); it is re-armed
    -- in the qualifying phase for a circuit quali.
    M.state.sector_track = nil
    -- Reset the HUD watchdog so the (re)started race gets a clean grace window and a fresh (fast)
    -- re-show cadence.
    M.state.hud_ack_gap = 0
    M.state.hud_reshow_wait = 0
    M.state.hud_reshow_interval = HUD_RESHOW_EVERY
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    M.state.assist_notice = nil
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
    M.state.restage_plate = nil
    M.state.race_caps = nil
    M.state.race_forced_car = false
    M.state.staged_spec = nil
    M.state.revert_pending = false
    M.state.staging_swap_reverting = false
    -- Release the start freeze so the preserved car is drivable (no-op if already free / car gone).
    vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
end

-- ===== F1 light start (ADR-0043) ===========================================================
-- An optional standing-start style: 5 red lights fill, hold a random beat, then all go out = GO. The car
-- is physically free from the first light (no movement lock -- only the action lock stays), so launching
-- before lights-out is a jump start, detected here (own car) and on the host (its AI), and penalized
-- server-side. All of this runs only for an F1 start (M.state.countdown.lights / M.state.race.startMode ==
-- "f1"); the default lock countdown path is untouched. Timing rides os.clockhp wall-clock, not dtReal.
local F1_LIGHT_COUNT = 5            -- red lights in the tower (matches the server's f1.LIGHT_COUNT)
local F1_LIGHT_STEP = 1.0          -- seconds between each light coming on (matches the server)
local F1_JUMP_DIST = 0.2           -- metres the player's car may drift before it counts as a jump (tight)
local F1_AI_JUMP_DIST = 1.0        -- metres for AI: looser, so a frozen AI's settle jitter never false-trips
local F1_JUMP_SPEED = 0.7          -- m/s (~2.5 km/h) that also counts as a jump (player car)
local F1_AI_REACTION_MIN = 0.05    -- shortest AI launch reaction after lights-out
local F1_AI_REACTION_MAX = 1.0     -- longest AI launch reaction (visibly staggered)
local F1_REACTION_MSG = "reaction" -- client -> server start-reaction report (jump = negative; matches f1.MSG_REACTION)

-- A vehicle's world position as a plain {x,y,z}, or nil. pcall-guarded (engine boundary).
local function f1_position(veh)
    if not veh then
        return nil
    end
    local ok, pos = pcall(function() return veh:getPosition() end)
    if ok and pos then
        return {x = pos.x, y = pos.y, z = pos.z}
    end
    return nil
end

-- True if `veh` has left `start_pos` by more than the jump tolerance (distance OR speed). pcall-guarded;
-- a missing API degrades to "no jump" (distance is the primary, reliable signal).
local function f1_moved(veh, start_pos)
    if not veh or not start_pos then
        return false
    end
    local ok_pos, pos = pcall(function() return veh:getPosition() end)
    if ok_pos and pos then
        local dx, dy, dz = pos.x - start_pos.x, pos.y - start_pos.y, pos.z - start_pos.z
        if dx * dx + dy * dy + dz * dz > F1_JUMP_DIST * F1_JUMP_DIST then
            return true
        end
    end
    local ok_spd, speed = pcall(function() return veh:getVelocity():length() end)
    if ok_spd and speed and speed > F1_JUMP_SPEED then
        return true
    end
    return false
end

-- Enter the F1 light start: free the player's car at the first light (the action lock from lock.install
-- stays -- only the position freeze + EV clamp lift) and capture the jump baselines for the own car and,
-- on the host, each AI (which stay frozen but can be shoved over the line).
local function f1_begin_lights()
    local own = getPlayerVehicle(0)
    local released, release_err = vehicles.set_vehicle_frozen(own, false)
    if not released then
        log("W", RACE_LOG_TAG, "F1 start: could not free the car: " .. tostring(release_err))
    end
    disarm_freeze_hold_ve()
    M.state.freeze_hold_armed = false
    M.state.f1 = {
        start_pos = f1_position(own),  -- own car's grid baseline
        own_move_at = nil,             -- os.clockhp of the own car's first movement (jump or launch)
        own_reported = false,
        ai_start = {},                 -- per-AI settled grid baseline (first hold / racing frame)
        ai_move_at = {},               -- per-AI first-movement time
        ai_reported = {},
        lights_out_at = nil,           -- os.clockhp at the racing transition (lights out); set in begin_driving
    }
end

-- Host, during the all-lit HOLD only (`holding`): record the time an AI is shoved off its grid spot before
-- lights-out (its move time -> a negative reaction = jump). The own car is watched inline in f1_step_lights;
-- AI stay frozen and never launch on their own, so this only catches a push. It must NOT run during the
-- light build-up: the deferred grid restage (ai.lua, RESTAGE_MAX_WAIT 3 s) front-anchors a car with a
-- place_at_grid TELEPORT and ticks AFTER this in the same onUpdate, so a build-up baseline read the teleport
-- as movement on every restaged car (the "all AI penalized" false positive). The hold starts at 5 s (> the
-- 3 s cap), so every car is restaged + settled by then: baseline at the first hold frame, record a real
-- shove past the (looser) AI distance tolerance.
local function f1_watch_ai_jumps(holding)
    local f = M.state.f1
    if not f or not holding or not M.state.ai_cars then
        return
    end
    for _, car in ipairs(M.state.ai_cars) do
        if car.restaged and not f.ai_move_at[car.id] then
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                local base = f.ai_start[car.id]
                if not base then
                    f.ai_start[car.id] = f1_position(veh)  -- first hold frame: settled baseline, no move yet
                else
                    local ok, pos = pcall(function() return veh:getPosition() end)
                    if ok and pos then
                        local dx, dy, dz = pos.x - base.x, pos.y - base.y, pos.z - base.z
                        if dx * dx + dy * dy + dz * dz > F1_AI_JUMP_DIST * F1_AI_JUMP_DIST then
                            f.ai_move_at[car.id] = os.clockhp()
                        end
                    end
                end
            end
        end
    end
end

-- Tick the F1 light tower in wall time: light i comes on at i * F1_LIGHT_STEP, all stay lit through the
-- random hold, and the all-off "lights out" rides the server racing transition (begin_driving -> show_go).
-- Also samples the now-free own car for a jump start, and the AI on the host. Replaces the numeric count.
local function f1_step_lights(count)
    local elapsed = os.clockhp() - count.anchor
    local lit = math.max(0, math.min(F1_LIGHT_COUNT, math.floor(elapsed / F1_LIGHT_STEP)))
    -- Show the "hold" hint during the build-up only, then drop it for the all-lit suspense.
    local hint = (lit < F1_LIGHT_COUNT) and "Hold position until lights out" or nil
    if lit ~= count.last_shown then
        count.last_shown = lit
        countdown.show_lights(lit, hint)
    end
    local f = M.state.f1
    if f and not f.own_move_at and f1_moved(getPlayerVehicle(0), f.start_pos) then
        f.own_move_at = os.clockhp()  -- moving during the lights = a jump (negative reaction vs lights-out)
    end
    -- AI only during the all-lit hold (lights fully built), so the grid restage teleport (build-up) is past.
    f1_watch_ai_jumps(lit >= F1_LIGHT_COUNT)
end

-- Lights out (the racing transition): stamp the lights-out time so reactions are measured against it, and
-- tell the caller whether this was an F1 light start (true -> stagger the AI release; false for a normal
-- start and the quali out-lap, which reuse begin_driving but never ran the lights, so their AI release
-- together as usual). The reactions themselves -- own car + AI, jump (negative) or launch (positive) -- are
-- reported by f1_step_reactions during racing, since a clean launch only happens after lights-out.
local function f1_arm_reactions()
    local f = M.state.f1
    if not f then
        return false
    end
    f.lights_out_at = os.clockhp()
    return true
end

-- Racing: release the AI on their per-car reaction delay (0.05-0.5 s after lights-out), unfreezing each as
-- its timer comes due, then clearing the schedule once all are out. No-op without an F1 release schedule --
-- the normal start releases the AI together in begin_driving.
local function f1_step_ai_release()
    local release = M.state.ai_release
    if not release or not M.state.ai_cars then
        return
    end
    local now = os.clockhp()
    local pending = false
    for _, car in ipairs(M.state.ai_cars) do
        local due = release[car.id]
        if due then
            if now >= due then
                vehicles.set_vehicle_frozen(be and be:getObjectByID(car.veh_id), false)
                release[car.id] = nil
            else
                pending = true
            end
        end
    end
    if not pending then
        M.state.ai_release = nil
    end
end

-- Racing: measure each car's start reaction = first-movement time - lights-out time (negative = jumped
-- before lights out, positive = launch reaction) and report it once per car (own + each AI by proxy, owner
-- only). The server stores it for the standings React column and applies the jump penalty when negative.
-- The own car / a shoved AI may already carry a move time from the lights/hold (a jump); everyone else gets
-- theirs here on their first movement after lights-out. No-op without an armed F1 start.
local function f1_step_reactions()
    local f = M.state.f1
    if not f or not f.lights_out_at then
        return
    end
    local race_name = M.state.race and M.state.race.name
    if not f.own_reported then
        if not f.own_move_at and f1_moved(getPlayerVehicle(0), f.start_pos) then
            f.own_move_at = os.clockhp()
        end
        if f.own_move_at then
            f.own_reported = true
            send_to_server(F1_REACTION_MSG, {race = race_name, reaction = f.own_move_at - f.lights_out_at})
        end
    end
    if not M.state.ai_cars then
        return
    end
    for _, car in ipairs(M.state.ai_cars) do
        if not f.ai_reported[car.id] then
            if not f.ai_move_at[car.id] then
                local veh = be and be:getObjectByID(car.veh_id)
                if veh then
                    local base = f.ai_start[car.id]
                    if not base then
                        base = f1_position(veh)  -- no hold baseline yet: settle the grid pose now
                        f.ai_start[car.id] = base
                    end
                    -- Responsive launch detection: in racing the restage teleport is long past, so use the
                    -- same tight distance-OR-speed test the player uses (not the looser hold tolerance) --
                    -- otherwise the AI "reaction" includes the time to crawl 1 m and reads as >1 s.
                    if f1_moved(veh, base) then
                        f.ai_move_at[car.id] = os.clockhp()
                    end
                end
            end
            if f.ai_move_at[car.id] then
                f.ai_reported[car.id] = true
                send_to_server(F1_REACTION_MSG,
                    {race = race_name, aiId = car.id, reaction = f.ai_move_at[car.id] - f.lights_out_at})
            end
        end
    end
end
-- ===== end F1 light start ===================================================================

-- Release the start lock and arm detection + the lap clock for a driving phase -- the racing phase, and
-- the qualifying session that reuses the same machinery on its unbounded plan (ADR-0041). `plan` is the
-- traversal plan to score against (the real race plan, or the quali plan); the host's AI drive the route
-- for `ai_laps` laps (the race lap count, or the quali plan's lap count so they keep lapping the session).
-- The caller has already confirmed we are in this race. Returns the ai.drive summary and the back_laps the
-- AI were armed with -- both nil when no AI were armed -- for the qualifying arming line (quali.note_arming).
local function begin_driving(plan, ai_laps)
    -- Countdown over: show GO! on the server-authoritative release, play the cue, stop the local count, and
    -- release the start lock so the car can drive.
    M.state.countdown = nil
    countdown.show_go()
    countdown.play_go()
    local released, release_err = vehicles.set_vehicle_frozen(getPlayerVehicle(0), false)
    if not released then
        log("W", RACE_LOG_TAG, "could not release start lock: " .. tostring(release_err))
    end
    disarm_freeze_hold_ve()
    M.state.freeze_hold_armed = false
    -- F1 light start (ADR-0043): this racing transition is lights-out. Stamp it so each car's start reaction
    -- is measured against it (reported during racing by f1_step_reactions). The return says whether an F1
    -- light start actually ran (false for a normal start and the quali out-lap), gating the AI release.
    local f1_start = f1_arm_reactions()
    local ai_route, back_laps = nil, nil
    -- Arm checkpoint detection on the plan: it walks the traversal plan (sprint/circuit, ADR-0013), testing
    -- the local car against the planned-next checkpoint each frame while driving (ADR-0010).
    if plan then
        M.state.detection = checkpoints.new(plan)
    else
        log("W", RACE_LOG_TAG, "driving: no traversal plan; checkpoint detection disabled")
    end
    -- Host only: release the AI cars, hand them to BeamNG's AI to drive the route, and arm one detector per
    -- AI so the host scores them by proxy (ADR-0036). On a circuit each AI also gets a lap clock, so the host
    -- reports their best lap + run-up by proxy (ADR-0022); the AI lap-time the quali plan too and qualify on
    -- pace via the server's quali.ranking (ADR-0041) rather than always gridding at the back.
    if M.state.ai_cars and #M.state.ai_cars > 0 and plan and M.state.race then
        if f1_start then
            -- F1 light start (ADR-0043): keep the AI frozen and release them on a per-car reaction delay
            -- (0.05-0.5 s after lights-out) so they don't all leap as one; ai.drive still arms the route
            -- below. f1_step_ai_release (onUpdate, racing) unfreezes each car when its timer is due.
            local now = os.clockhp()
            local release = {}
            for _, car in ipairs(M.state.ai_cars) do
                release[car.id] = now + F1_AI_REACTION_MIN
                    + math.random() * (F1_AI_REACTION_MAX - F1_AI_REACTION_MIN)
            end
            M.state.ai_release = release
        else
            ai.set_frozen(M.state.ai_cars, false)
        end
        local ai_params = ai.resolve_params(M.state.ai_config, M.state.race.aiDefaults)
        -- Rolling route window: the AI get at most one block of drive targets now and are topped up per
        -- car from the client tick (step_ai_window), so a qualifying session can be lapped for its whole
        -- length without arming laps x targets up front. `backLaps` is the RACE lap count -- the cap on each
        -- re-arm of the window's give-up fallback, so a degraded car cannot re-create that runaway (in a
        -- qualifying session the window keeps refilling after such a re-arm).
        M.state.ai_window = {}
        back_laps = M.state.race.laps
        ai_route = ai.drive(M.state.ai_cars,
            M.state.race.routePoints or M.state.race.checkpoints, ai_laps or M.state.race.laps, ai_params,
            M.state.race.mode == "circuit",
            {store = M.state.ai_window, backLaps = back_laps})
        M.state.ai_custom_map = ai_route and ai_route.customMap or nil
        if ai_route then
            send_to_server("aiRouteNotice", ai_route)
        end
        local detections = {}
        -- Circuit only: a per-AI lap clock mirroring the player's, armed at the start/finish line (the same
        -- checkpoints[1] the player's laptimer watches), so the host reports each AI's best lap + run-up (S0)
        -- by proxy. nil on a sprint -- no best-lap column, no S0 column (ADR-0022/0036/0041).
        local ai_laptimers = nil
        if M.state.race.mode == "circuit" and M.state.race.checkpoints
            and M.state.race.checkpoints[1] then
            ai_laptimers = {}
        end
        for _, car in ipairs(M.state.ai_cars) do
            detections[car.id] = checkpoints.new(plan)
            if ai_laptimers then
                ai_laptimers[car.id] = laptimer.new(M.state.race.checkpoints[1])
            end
        end
        M.state.ai_detections = detections
        M.state.ai_laptimers = ai_laptimers
    end
    -- Circuit only: arm the client-side lap clock on the start/finish line (ADR-0022); display-only, so it
    -- never touches the scored plan. In qualifying its best-lap drives the grid (server-reported, ADR-0041).
    local race_state = M.state.race
    if race_state and race_state.mode == "circuit" and race_state.checkpoints
        and race_state.checkpoints[1] then
        M.state.laptimer = laptimer.new(race_state.checkpoints[1])
    else
        M.state.laptimer = nil
    end
    -- Each driving phase starts with its results card shown (not minimized), analysis overlay closed, and the
    -- provisional results card armed to auto-show on finish (ADR-0022/0028).
    M.state.results_min = false
    M.state.analysis_open = false
    M.state.provisional_open = true
    -- Auto-show the HUD app for the phase (ADR-0012); removed again on lobby. The show dedups.
    hud.show()
    return ai_route, back_laps
end

-- ===== the qualifying hold (bug quali-hold-reset-and-repaint-leak) =======================
-- THE single truth for "the local driver's car must stay put in this qualifying session". Every
-- enforcement layer -- the recover-key block (lock.set_recover_blocked), the GE assist-key guard, the
-- re-freeze after a vehicle-config respawn, and the EV throttle clamp -- reads this one predicate, so a
-- held state can never be enforced by some layers and not others.
--
-- Held is every quali state in which the driver is frozen and MUST stay frozen:
--   * staged sprint (ADR-0044): queued (holding slot), staged (at the ramp), done (session over).
--     "running" is the one state that is free -- there the recover key is the requeue (ADR-0044/Round4).
--   * circuit (ADR-0041): once the driver's lap has closed inside the finish-your-lap grace, their
--     session is over and they are parked for the rest of the window (ADR-0041 amendment).
function hold.is_held()
    if M.state.phase ~= "qualifying" then
        return false
    end
    if M.state.quali_staged then
        local status = M.state.quali_status
        return status == "queued" or status == "staged" or status == "done"
    end
    return M.state.quali_lap_done == true
end

-- The FULL "the local driver's car is supposed to be standing still right now" window: the two frozen
-- start phases plus the qualifying hold above. Two layers read it and must never disagree -- the EV
-- throttle clamp arms on it (push_freeze_hold's onUpdate gate) and the in-place reload re-arm
-- re-asserts the GE controller freeze on it (rearm_own_car_on_reload, bug
-- recover-unguarded-when-assists-disabled). One predicate, so they cannot drift apart.
--
-- The F1 light start is carved out on purpose: it keeps the phase at `countdown` while f1_begin_lights
-- has already FREED the car at the first light (ADR-0043), so anything re-freezing on a blanket
-- `countdown` would strand the driver on the grid at lights-out. Race-agnostic -- callers add their own
-- M.state.race check (the reload re-arm has already made it by the time it asks).
function hold.is_frozen_phase()
    return M.state.phase == "staging"
        or (M.state.phase == "countdown" and not (M.state.countdown and M.state.countdown.lights))
        or hold.is_held()
end

-- Push the current held-ness to the recover-key block. Called from every transition that can change it
-- (the phase handler, each staged queue transition, the circuit run's close) and once per qualifying frame
-- as a net, so no path can leave the block out of step with hold.is_held().
--
-- The engine call only fires on a real edge: comparing against the last pushed value keeps the per-frame
-- net down to a boolean compare, and the engine's filter update is not free (it rebuilds the filter and
-- broadcasts an extension hook). The record lives in M.state so the whole race teardown can reset it in
-- one place -- it does NOT survive a GE Lua reload, and the engine's own filter state does (see
-- lock.set_recover_blocked), so onExtensionLoaded re-asserts the released state rather than letting this
-- comparison run against a value the literal guessed.
function hold.sync()
    local held = hold.is_held()
    if held == M.state.quali_hold_locked then
        return
    end
    M.state.quali_hold_locked = held
    lock.set_recover_blocked(held)
end
-- ===== end the qualifying hold ===========================================================

-- Record the server-authoritative race phase and drive the start lock off it. The
-- server broadcasts a racePhase on every transition (ADR-0006/0041). The car is spawned frozen in
-- handle_race_start and held through the countdown; here we release it on racing/qualifying, and release
-- defensively on lobby (the car is preserved in place, only unlocked). The countdown UI is driven
-- off the same phases via race/countdown (ADR-0008): countdown starts the count, racing shows GO!.
local function handle_race_phase(payload)
    local phase = type(payload) == "table" and payload.phase or nil
    if type(phase) ~= "string" then
        log("W", RACE_LOG_TAG, "racePhase ignored: missing phase")
        return
    end

    M.state.phase = phase
    log("I", RACE_LOG_TAG, "race phase -> " .. phase)

    -- Feed the admin setup panel the current phase so it can show/hide the race-stop controls (ADR-0038
    -- amendment). Pushed on every transition; the panel also pulls via request_race_phase on link/open.
    if guihooks then
        guihooks.trigger("BeamCompSetupPhase", {phase = phase})
    end

    -- Ignore phases for a race this client is not in: with no resolved race (unknown name, wrong map)
    -- there is no car, plan, or checkpoints, so the server-driven countdown/racing must not render or
    -- arm detection. Lobby still runs so any prior race tears down normally.
    if not M.state.race and phase ~= "lobby" then
        log("I", RACE_LOG_TAG, "racePhase '" .. phase .. "' ignored: no active race on this client")
        return
    end

    if phase == "staging" then
        -- Arm the in-race vehicle-action lock in swap-allowed mode for the staging wait
        -- (ADR-0017/0021 amendments): the player may still change car (replace the model/config via the
        -- vehicle/parts selector), but cannot spawn an extra car, switch, reset, recover, or grab. A
        -- swap is re-staged in onUpdate (re-freeze + bounce target + VE re-arm). The lock upgrades to the
        -- full fixed-car lock at countdown. The car is already frozen at its grid slot
        -- (handle_race_start) and stays so until racing. Force the HUD app visible now so the countdown
        -- overlay it hosts is present before the count starts (ADR-0021), and seed the staging indicator.
        -- A race that forces the car narrows this (ADR-0064): the lock asks lock.car_is_forced itself, then
        -- refuses the replace and every parts change from here on while tuning and paint stay free -- so
        -- under a forced car neither the swap below nor its pre-anchor hook ever runs.
        lock.install({allow_replace = true})
        -- Make a staging car swap land on the grid slot WITHOUT the visible correction afterwards
        -- (ADR-0051 round 2). BeamNG's replaceVehicle gives the new car the outgoing car's reference
        -- point, so a differently sized replacement comes up offset and used to be nudged into place a
        -- frame later -- a small jump the player sees. The lock already wraps replaceVehicle for the
        -- staging swap, so it can hand us the model that is about to exist; we then move the OUTGOING car
        -- to the reference point that model needs, and the replacement inherits exactly the right spot.
        -- Moving the outgoing car is invisible: it is deleted inside the same call.
        --
        -- Everything about this is best-effort. The hook is pcall-guarded on the lock side, every step
        -- here bails out silently, and preplace_at_grid + the deferred restage stay behind it as the
        -- safety net -- they simply find nothing left to do when this works.
        lock.on_before_replace = function(model_name, opt)
            -- Cleared before anything that can fail: the lock calls this inside a pcall, and a reading
            -- left over from an earlier swap must never be adopted as this one's baseline.
            M.state.restage_prebaseline = nil
            local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
            -- Take the deferred restage's jbeam-load baseline HERE, while the OUTGOING car still stands.
            -- Measured in-game: the replace stalls the game engine for ~2 s loading the new jbeam, so the
            -- first frame restage_swapped_car gets afterwards already sees the NEW car's bounding box.
            -- Recording the baseline there compared the new box against itself, the "box changed = jbeam
            -- loaded" test could never fire, and every single swap fell through to the RESTAGE_MAX_WAIT
            -- timeout -- putting the correction as late as it can possibly be (4.5 s after the swap in
            -- the measured case). Read one frame earlier, against the car being replaced, the test has an
            -- actual before-value and fires on the first frame instead.
            M.state.restage_prebaseline = own and vehicles.spawn_oobb_forward(own) or nil
            local pose = M.state.race and M.state.race.myPose
            if not pose or not own then
                return
            end
            local placed, reason = vehicles.preplace_for_replacement(own, pose, model_name,
                type(opt) == "table" and opt.config or nil)
            if placed then
                log("I", RACE_LOG_TAG, string.format(
                    "pre-anchored the grid slot for the incoming '%s'", tostring(model_name)))
            else
                log("I", RACE_LOG_TAG, "swap pre-anchor skipped: " .. tostring(reason))
            end
        end
        hud.show()
        -- No clock: staging is open-ended and waits for the host (ADR-0021 amendment), so the server
        -- sends no duration. Zero makes the first onUpdate paint the waiting line immediately.
        M.state.staging = {repaint_in = 0}
        -- Seed the compliance revert target from the (guaranteed compliant) car we staged, so an over-cap
        -- swap can be reverted to it (ADR-0032). Mode 3 only; the race car's jbeam is loaded by staging, so
        -- the spec read is reliable. A later compliant swap moves the target forward (restage_swapped_car).
        if M.state.race_caps and M.state.race_car_id and be then
            local staged = be:getObjectByID(M.state.race_car_id)
            if staged then
                M.state.staged_spec = vehicles.capture_spec(staged) or M.state.staged_spec
            end
        end
    elseif phase == "countdown" then
        -- Staging over: upgrade the lock to the full fixed-car lock (no more replace or selector) for
        -- the countdown + racing span, then seed the start countdown; the local onUpdate tick renders
        -- each whole second and plays the final beeps on the centered overlay (ADR-0021).
        lock.install()
        M.state.staging = nil
        -- Anchor the count to a wall clock (os.clockhp) rather than accumulating the clamped per-frame dt,
        -- so a spawn/despawn hitch at the quali seam can't make it finish behind the server's wall-time
        -- phase (ADR-0041); the quali re-grid now re-spawns the AI a lead time earlier, so this count is
        -- normally hitch-free anyway. Display only -- the server owns the countdown -> racing transition.
        M.state.countdown = {
            total = tonumber(payload.duration) or 0,
            anchor = os.clockhp(),
            last_shown = nil,
            -- F1 light start (ADR-0043): the server flags the standing-start countdown so we render the
            -- light tower instead of the numeric count and free the car now (the jump window).
            lights = payload.lights == true,
        }
        if M.state.countdown.lights then
            f1_begin_lights()
        end
    elseif phase == "qualifying" then
        -- Qualifying session (ADR-0041): release the lock and lap the unbounded quali plan to set lap
        -- times; the grid is set afterwards from quali pace. The AI drive the SAME unbounded plan (feature
        -- ai-rolling-route-window): ai.drive arms only a rolling block of drive targets and refills it per
        -- car, so the quali lap count no longer builds a runaway waypoint list and the AI lap the session
        -- for its full length instead of running the race distance and idling. Seed the quali clock from
        -- the phase duration so the HUD shows time remaining; at 0 the finish-your-lap grace runs
        -- server-side.
        local quali_state = M.state.race and M.state.race.quali
        local quali_seconds = tonumber(payload.duration) or 0
        -- `remaining` is the HUD clock (ticked by dtReal); `total` + `anchor` are the same clock on the wall
        -- (os.clockhp), which the arming/park/grace diagnostics read so a frame hitch cannot fake a
        -- "clock left" warning (quali.clock_left).
        M.state.qualifying = {remaining = quali_seconds, total = quali_seconds, anchor = os.clockhp()}
        -- Fresh session: nobody has finished their graced lap yet (ADR-0041 amendment).
        M.state.quali_lap_done = false
        if quali_state and quali_state.staged then
            -- Rally staged sprint quali (ADR-0044/Round3): nobody drives at the gun and there is NO global
            -- pre-quali countdown -- the server sent us straight from staging into qualifying. Upgrade to the
            -- full fixed-car lock (normally done at the countdown phase we skipped); keep the car frozen at
            -- its slot. The server places the field: it stages the front driver at P1 (qualiStage) and holds
            -- the rest on slots 2..N (qualiHold). No detector, lap clock, or sector tracker until this
            -- driver launches; clear the overlay for the per-driver counts.
            lock.install()
            M.state.staging = nil
            M.state.countdown = nil
            M.state.quali_staged = true
            M.state.quali_status = "queued"
            M.state.quali_run = nil
            M.state.detection = nil
            M.state.laptimer = nil
            -- Arm the live sector-delta tracker for the staged run (Round 6): the point-to-point run scores
            -- each checkpoint once (crossing_seq 0..N-1), so #checkpoints sectors. The tracker persists across
            -- the driver's runs so the per-sector personal best accumulates; quali.launch_local resets the
            -- per-run progress on each launch. Feeds the same right-side split readout as the circuit quali.
            local staged_race = M.state.race
            if staged_race and staged_race.checkpoints and #staged_race.checkpoints >= 1 then
                M.state.sector_track = sectors.new(#staged_race.checkpoints)
            else
                M.state.sector_track = nil
            end
            M.state.quali_ai_runs = {}
            -- Every AI starts this session queued and frozen on its holding slot (they were frozen through
            -- staging and nothing releases them here), so seed them all as held (bug quali-end-ai-not-frozen).
            -- quali.launch_ai clears the one AI that is actually driving. Host only -- ai_cars is nil on a
            -- non-host, which leaves an empty set and a net that no-ops (ADR-0036).
            M.state.quali_ai_held = {}
            M.state.quali_ai_reassert = {}
            for _, car in ipairs(M.state.ai_cars or {}) do
                M.state.quali_ai_held[car.id] = true
            end
            M.state.results_min = false
            M.state.analysis_open = false
            countdown.clear()
            -- Keep the HUD app up for the queue view (circuit gets this via begin_driving, which we skip).
            hud.show()
        else
            -- Circuit all-at-once quali (ADR-0041): release everyone and lap the unbounded plan (unchanged).
            M.state.quali_staged = false
            -- Nothing is held yet -- every AI is about to be released to lap. They are parked one at a time
            -- as their own lap closes inside the finish-your-lap grace (step_ai_detections, bug
            -- quali-end-ai-not-frozen).
            M.state.quali_ai_held = {}
            M.state.quali_ai_reassert = {}
            -- The AI drive the quali plan's own lap count, not the race's: that is what makes them lap the
            -- session instead of parking after the race distance. The plan is sized so the clock runs out
            -- first (race/start.lua quali_for), and the rolling window keeps the armed part constant.
            local ai_route, back_laps = begin_driving(quali_state and quali_state.plan,
                (quali_state and quali_state.laps) or (M.state.race and M.state.race.laps))
            quali.note_arming(quali_state, ai_route, back_laps)
            -- Arm the live sector-delta tracker (feature: quali-live-sector-delta): a circuit quali laps the
            -- unbounded plan, so each scored crossing closes a per-checkpoint sector the HUD diffs against the
            -- chosen reference. cps == #checkpoints (ADR-0013 circuit plan). Sprint quali has no repeated laps
            -- -> no sectors (delta stays inactive), so leave the tracker nil there.
            local quali_race = M.state.race
            if quali_race and quali_race.mode == "circuit" and quali_race.checkpoints
                and #quali_race.checkpoints >= 1 then
                M.state.sector_track = sectors.new(#quali_race.checkpoints)
            else
                M.state.sector_track = nil
            end
        end
    elseif phase == "racing" then
        -- Countdown over: release the lock, arm detection on the real race plan, drive the host's AI, and
        -- arm the lap clock (ADR-0006/0036/0022). After a quali event this is the second countdown -> race,
        -- on the quali-earned grid set by the preceding regrid.
        M.state.qualifying = nil
        M.state.qualiResults = nil
        M.state.quali_settle = false
        -- Drop staged sprint quali run state (ADR-0044): the race grid was set by the quali re-grid.
        M.state.quali_staged = false
        M.state.quali_status = nil
        M.state.quali_run = nil
        M.state.quali_ai_runs = nil
        M.state.quali_clear_sent = false
        M.state.quali_ai_cleared = nil
        M.state.quali_ai_held = nil
        M.state.quali_ai_reassert = nil
        M.state.quali_lap_done = false
        -- Stop qualifying sector tracking; the race scores the real plan (feature: quali-live-sector-delta).
        M.state.sector_track = nil
        -- Drop the qualifying phase's standstill clocks at the green light (feature
        -- stall-detection-client-measured-movement). We cannot lift a verdict we already sent -- no grace
        -- is running here, so stall.step is inert and sends nothing -- which is why the SERVER clears its
        -- side at every grace arm (stall.begin_grace), not at this boundary.
        M.state.stall_track = nil
        begin_driving(M.state.race and M.state.race.plan, M.state.race and M.state.race.laps)
        -- Guaranteed rebind pass at GO: by racing the car's VE has been up through the whole countdown, so
        -- this is the highest-confidence point to re-assert the stock dashboard/tacho binding -- it also
        -- covers a race where the pre-race passes never caught a bindable car (bug
        -- default-dashboard-ui-missing-at-race-start).
        arm_dashboard_refresh()
    elseif phase == "qualiResults" then
        -- Qualifying over (ADR-0041): stop scoring -- the classification card renders from the quali
        -- snapshot. The settle window stays closed until the re-grid places the cars on the race grid.
        M.state.qualifying = nil
        M.state.grace = nil
        M.state.stall_track = nil
        M.state.stall_cutoff = nil
        M.state.detection = nil
        M.state.laptimer = nil
        M.state.quali_settle = false
        -- Drop staged sprint quali run state (ADR-0044): the session is classified; the re-grid follows.
        M.state.quali_staged = false
        M.state.quali_status = nil
        M.state.quali_run = nil
        M.state.quali_ai_runs = nil
        M.state.quali_clear_sent = false
        M.state.quali_ai_cleared = nil
        -- The AI are despawned a few lines below, so there is nothing left to hold (bug
        -- quali-end-ai-not-frozen).
        M.state.quali_ai_held = nil
        M.state.quali_ai_reassert = nil
        M.state.quali_lap_done = false
        -- Qualifying over -- drop the sector-delta tracker (feature: quali-live-sector-delta).
        M.state.sector_track = nil
        -- Count the pause down for the card's "race starts in" line, anchored to a wall clock (os.clockhp)
        -- rather than accumulating the clamped per-frame dt, so the AI-despawn frame hitch below cannot make
        -- it drift behind the server's wall-time pause (ADR-0041). Display only -- the card hides
        -- server-authoritatively on the phase change regardless. remaining is kept fresh by the tick for the
        -- HUD snapshot to read.
        local quali_results_seconds = tonumber(payload.duration) or 0
        M.state.qualiResults = {
            total = quali_results_seconds,
            anchor = os.clockhp(),
            remaining = quali_results_seconds,
            -- The re-grid/respawn fires `lead` before the pause ends, splitting the pause into a results
            -- display (pause - lead) and the post-respawn settle window (lead). The card shows the results
            -- count before the respawn; the settle timer shows the remaining pause after it (ADR-0041).
            lead = tonumber(payload.regridLead) or 0,
        }
        -- Despawn the host's quali AI NOW, at the start of the pause -- the gap until the re-grid (which now
        -- runs a lead time before the countdown, ADR-0041) lets BeamMP fully remove them before fresh cars
        -- re-spawn on the earned grid, so a delete+spawn overlap never pushes the car count past MaxCars
        -- (which silently drops the new AI). Restore the navgraph the quali drive may have swapped.
        -- Owner-only (ai_cars nil elsewhere).
        ai.stop(M.state.ai_cars or {})
        ai.clear(M.state.ai_cars or {})
        if M.state.ai_custom_map then
            ai.restore_map()
            M.state.ai_custom_map = nil
        end
        M.state.ai_cars = nil
        M.state.ai_detections = nil
        M.state.ai_window = nil
        M.state.ai_laptimers = nil
    elseif phase == "finished" then
        -- Race over, but the results + props stay up for the long free-roam window (ADR-0006/0017
        -- amendments, B3). Release the in-race lock and hand the recover/repair keys back to vanilla
        -- now, so players can drive, switch vehicles, recover, and roam the track while results show.
        -- Everything else (race state, props, standings, HUD) lives on until the lobby teardown.
        lock.remove()
        disarm_assist_ve()
    elseif phase == "lobby" then
        -- Race over (back to lobby): despawn the track props/cones and drop all race state, but leave
        -- the player's vehicle exactly where it is -- never despawn or move it (only unfrozen, so a
        -- /raceend mid-countdown leaves the preserved car drivable). The abort-restart path skips
        -- lobby (finished -> spawning), where handle_race_start reloads props and re-freezes instead.
        teardown_race_world()
    end

    -- One sync for every phase transition (bug quali-hold-reset-and-repaint-leak): the qualifying entry
    -- blocks the recover keys for a staged driver holding in the queue, and every phase after qualifying
    -- releases them again. Placed after the branch so it reads the phase's freshly-set quali state.
    hold.sync()
end

-- Store the latest server-broadcast standings for the HUD to render (item 5). Receive and store
-- only -- no rendering here. The summary log lets a single client confirm the path and the payload.
local function handle_standings(payload)
    local entries = type(payload) == "table" and payload.entries or nil
    if type(entries) ~= "table" then
        log("W", LOG_TAG, "standings ignored: missing entries")
        return
    end

    M.state.standings = entries

    local leader = entries[1]
    if not leader then
        log("I", RACE_LOG_TAG, "standings: 0 entries")
        return
    end

    local progress = tostring(leader.completed)
    if leader.count then
        progress = progress .. "/" .. tostring(leader.count)
    end
    log("I", RACE_LOG_TAG, string.format("standings: %d entr%s -- leader %s %s @ %.2fs",
        #entries, #entries == 1 and "y" or "ies", tostring(leader.name), progress,
        tonumber(leader.total_time) or 0))
end

-- Store the latest server-broadcast championship table (ADR-0040) and reflect it to the setup panel. The
-- HUD finished card reads it from the per-frame snapshot (build_hud_snapshot); the panel is not on the
-- per-frame path, so it gets an immediate push here. payload.active=false (a reset) clears the table, so
-- both the card and the panel hide it.
local function handle_championship(payload)
    M.state.championship = type(payload) == "table" and payload or nil
    if guihooks then
        guihooks.trigger("BeamCompChampionship", M.state.championship or {active = false})
    end
end

-- Store the latest server-broadcast class-drop tournament table (ADR-0042) and reflect it to the setup panel,
-- exactly like handle_championship: the HUD finished card reads it from the per-frame snapshot; the panel is
-- not on the per-frame path, so it gets an immediate push here. payload.active=false (no tournament / reset)
-- clears the table, so both the card and the panel hide it.
local function handle_tournament(payload)
    M.state.tournament = type(payload) == "table" and payload or nil
    if guihooks then
        guihooks.trigger("BeamCompTournament", M.state.tournament or {active = false})
    end
end

-- Store the latest qualifying classification (ADR-0041), broadcast by the server when qualifying ends.
-- The HUD reads it from the per-frame snapshot to render the quali-results card during the pause; cleared
-- on the next race start so a stale card never lingers.
function quali.handle_snapshot(payload)
    M.state.quali = (type(payload) == "table" and type(payload.rows) == "table") and payload or nil
end

-- Answer the server's listRaces request: build this client's installed-race list for the loaded map
-- and ship it back for the server to post to the asking player (ADR-0005: the server is race-blind,
-- so the client owns the list; ADR-0011: client->server reply). The relayed `all` flag (ADR-0026)
-- includes the deprecated quickrace source in the listing; otherwise it is hidden with a count hint.
local function handle_list_races(payload)
    local include_deprecated = type(payload) == "table" and payload.all == true
    send_to_server("raceList", {lines = racelist.build(maps.current(), include_deprecated)})
end

-- Answer the server's listVehicles request (/cars, ADR-0032): the vehicle-blind server (ADR-0005)
-- relays the optional model token, we build the installed-vehicle listing locally and ship the chat
-- lines back for the server to post (ADR-0011). A model lists that model's configs; nil lists all models.
local function handle_list_vehicles(payload)
    local model = type(payload) == "table" and payload.model or nil
    send_to_server("vehicleList", {lines = carlist.build(model)})
end

-- Re-place the owner's host-driven AI cars onto their re-gridded poses (ADR-0036 Etappe B). `ai_slots` is
-- the {id, slot} list the pwr re-grid sends the owner (ADR-0033); for each, update the tracked car's
-- slot/pose and front-anchor it at the new grid pose, re-frozen until racing. No-op for a non-owner (no
-- ai_cars) or a missing car/pose. Mirrors the player re-place below, run per AI car.
local function replace_ai_for_regrid(ai_slots)
    if type(ai_slots) ~= "table" or not M.state.ai_cars or not M.state.race then
        return
    end
    local poses = M.state.race.gridPoses
    if type(poses) ~= "table" then
        return
    end
    local car_by_id = {}
    for _, car in ipairs(M.state.ai_cars) do
        car_by_id[car.id] = car
    end
    -- A re-grid reaches every client even when it moved nobody here, and a size-aware one can fire while
    -- the field is still spawning (ADR-0051). Leave an AI that is already standing on its pose alone:
    -- re-placing it would measure a bounding box that may still be loading and shove it off its slot,
    -- which the per-frame ai.restage would then have to walk back.
    local parked = M.state.phase == "spawning" or M.state.phase == "staging"
    for _, entry in ipairs(ai_slots) do
        local car = car_by_id[entry.id]
        local pose = (type(entry.slot) == "number") and poses[entry.slot + 1] or nil
        if car and pose then
            local settled = parked and car.slot == entry.slot
                and race_start.pose_matches(car.pose, pose)
            car.slot = entry.slot
            car.pose = pose
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                if not settled then
                    vehicles.place_at_grid(veh, pose)
                end
                vehicles.set_vehicle_frozen(veh, true)
            end
        end
    end
end

-- Re-spawn the host's AI fresh on the quali-earned grid for the race (ADR-0041). A quali drive leaves the
-- AI in a state a teleport does not reliably recover (custom navgraph + driveUsingPath), so the owner
-- despawns the quali AI and spawns clean cars at the new slots via the proven race-start spawn path. The
-- regrid carries each AI's {id, slot, label}; the config + policy were kept from the spawn. No-op for a
-- non-owner or when the inputs are missing.
function quali.respawn_ai_for_regrid(ai_slots)
    if type(ai_slots) ~= "table" or #ai_slots == 0 or not M.state.race then
        return
    end
    -- The quali AI were despawned at quali-results entry, so BeamMP has had the lead gap (the pause minus
    -- quali_regrid_lead) to remove them; spawn fresh + frozen at the new poses now, with the same
    -- spawn-notification mute as race start.
    -- Lift the in-race action lock first: the full fixed-car lock persists from the first countdown through
    -- qualifying and this pause, and it gates core_vehicles.spawnNewVehicle -- which would silently refuse
    -- the AI spawn (ai.spawn returns 0). It is re-installed at the end of this function: the re-grid now runs
    -- during the quali-results pause (a lead before the countdown), so waiting for the countdown handler to
    -- restore it would leave the car swappable for the rest of the pause -- the race must keep the same car
    -- from quali start to finish.
    lock.remove()
    spawn_mute.mute_for(SPAWN_NOTIFICATION_MUTE_SECONDS)
    -- Re-read the owner's current race car for the aicar=host mode so the re-spawned AI follow the host's
    -- car onto the quali grid (ADR-0036); nil -> the resolver falls through so the AI still race.
    local host_race_car = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    local host_car = host_race_car and vehicles.host_car_spec(host_race_car) or nil
    local cars = ai.spawn(ai_slots, M.state.race.gridPoses, M.state.ai_config, M.state.race.aiDefaults,
        M.state.ai_policy, host_car)
    if type(cars) ~= "table" or #cars == 0 then
        log("W", RACE_LOG_TAG, "quali AI re-spawn: ai.spawn returned no cars")
        lock.install()  -- restore the lock removed above, even on the spawn-failure path
        return
    end
    ai.set_frozen(cars, true)
    -- The AI cars are RE-SPAWNED here, not teleported, so a chat-path field without a fixed roster car
    -- re-rolls its random cars. Re-report each one's footprint and pwr (ADR-0051 / ADR-0033) so the
    -- reservation and the power order describe the cars that are actually on the race grid.
    local race_name = M.state.race.serverName
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            ai.suppress(veh)
            if race_name then
                local ai_info = vehicles.collect_client_info(veh)
                send_to_server("clientInfo", {
                    race = race_name,
                    aiId = car.id,
                    pwr = ai_info.pwr,
                    carLength = ai_info.car_length,
                    carWidth = ai_info.car_width,
                })
            end
        end
    end
    M.state.ai_cars = cars
    M.state.ai_map_pending = true  -- re-broadcast the server-id map so remotes label + suppress the new cars
    -- Spawning auto-enters the player into the last AI car: re-seat them in their own race car.
    local race_car = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if race_car and be then
        pcall(function() be:enterVehicle(0, race_car) end)
        M.state.current_vehicle_id = race_car:getId()
    end
    -- Re-install the fixed-car lock now that the spawn + re-seat are done (see the lock.remove note above
    -- for why this can't wait for the countdown). The own-car re-place that follows in handle_regrid is a
    -- programmatic keep_own teleport, not a player action, so the restored lock does not block it.
    lock.install()
    log("I", RACE_LOG_TAG, string.format("re-spawned %d AI on the quali grid", #cars))
end

-- The server re-gridded the start order (ADR-0033, order=pwr; ADR-0041, order=quali): adopt the new slot,
-- re-place the race car at its new grid pose (picked from the pose set we already hold), and re-freeze.
-- Mirrors restage_swapped_car. No-op if we are not in this race or the car/pose is unavailable. The owner's
-- regrid also carries its AI cars' new slots: pwr re-places them in situ, while a quali re-grid re-spawns
-- them fresh (qualiRespawnAi), since a quali drive leaves them unteleportable.
local function handle_regrid(payload)
    if not M.state.race or type(payload) ~= "table" then
        return
    end
    -- A quali re-grid (fired during the quali-results pause) is the cars landing on the earned race grid:
    -- open the settle window so the HUD steps the big results card back for a small "race starts in" timer
    -- before the start countdown (ADR-0041). A pwr re-grid runs in staging and never enters this phase, so
    -- it leaves the flag untouched. Set before the own-car re-place below so an edge-case early return there
    -- cannot skip it -- the server still advances to the countdown regardless.
    if M.state.phase == "qualiResults" then
        M.state.quali_settle = true
    end
    local slot = payload.slot
    -- Adopt the new roster and re-lay the grid FIRST, before any car is moved: the server hands out
    -- sparse slots to keep the space behind an oversized car free (ADR-0051), so a re-grid can need
    -- more poses than the current layout has -- and on a rows-pinned grid every pose can move. The AI
    -- re-place below reads race.gridPoses, so it has to see the new set.
    if type(payload.grid) == "table" then
        M.state.race.roster = payload.grid
    end
    local extent = race_start.layout_extent(M.state.race.roster, slot)
    if extent ~= M.state.race.layoutCount then
        local poses, ramp = race_start.layout_for(M.state.race.gridLayout, extent)
        if poses then
            M.state.race.gridPoses = poses
            M.state.race.rampPose = ramp
            M.state.race.layoutCount = extent
            log("I", RACE_LOG_TAG, string.format("regrid: grid re-laid for %d poses", extent))
        else
            log("W", RACE_LOG_TAG, "regrid: could not re-lay the grid; keeping the current poses")
        end
    end
    -- Re-place / re-spawn the host's AI cars (owner-only; no-op otherwise) before the own-car logic, so a
    -- missing own slot/pose below never skips it.
    if payload.qualiRespawnAi then
        quali.respawn_ai_for_regrid(payload.aiSlots)
    else
        replace_ai_for_regrid(payload.aiSlots)
    end
    local poses = M.state.race.gridPoses
    local pose = (type(slot) == "number" and poses) and poses[slot + 1] or nil
    if not pose then
        log("W", RACE_LOG_TAG, "regrid ignored: no pose for slot " .. tostring(slot))
        return
    end
    -- A re-grid that only moved OTHER cars still reaches every client (the roster has to stay in sync),
    -- so skip the teleport when this car's own pose is unchanged. Without this, one incoming footprint
    -- report would re-place the whole field (ADR-0051). Compared by value, not by identity: the
    -- re-layout above builds fresh pose tables even where the numbers did not move.
    --
    -- Only in the phases where the field is PARKED on the grid. A quali re-grid (qualiResults) is what
    -- brings the cars back from the track, so an unchanged pole slot must still be teleported -- the
    -- stored pose says nothing about where the car actually is there.
    local parked = M.state.phase == "spawning" or M.state.phase == "staging"
    local settled = parked and M.state.race.mySlot == slot
        and race_start.pose_matches(M.state.race.myPose, pose)
    M.state.race.mySlot = slot
    M.state.race.myPose = pose

    local race_car = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if not race_car then
        log("W", RACE_LOG_TAG, "regrid: no race car to re-place")
        return
    end
    if not settled then
        local placed, place_err = vehicles.respawn_own_at(pose, race_car)
        if not placed then
            log("W", RACE_LOG_TAG, "regrid re-place failed: " .. tostring(place_err))
            return
        end
        -- The regrid re-seated/re-placed the race car: re-queue the stock-dashboard rebind so the tacho
        -- survives this reseat too (bug default-dashboard-ui-missing-at-race-start).
        arm_dashboard_refresh()
        log("I", RACE_LOG_TAG, string.format("re-gridded to slot %d", slot))
    end
    -- Re-asserted either way: it is one queued VE command, and a car that lost its freeze must not stay
    -- loose just because this particular re-grid did not move it.
    vehicles.set_vehicle_frozen(race_car, true)
end

-- ===== Rally staged sprint quali, client side (ADR-0044) ==================================
-- The staged sprint variant: drivers run one at a time from position 1. The server owns the queue + the
-- release timing (qualiStage / qualiHold); this side owns the geometry -- teleport to P1, the per-driver
-- 3+5 s count on the shared countdown overlay, the launch, the drive (the existing detector/report path),
-- and reset->requeue. Everything no-ops off a staged qualifying phase, so a normal race / circuit quali is
-- untouched. The owner runs the same sequence for its AI cars (ADR-0036), timed by the existing proxy path.

-- Repair + teleport the local race car to a grid pose + re-freeze. Shared by the P1 teleport (stage) and
-- the return-to-holding (hold / requeue). Uses place_at_grid (front-anchored repair+teleport, ADR-0034) --
-- NOT respawn_own_at: on the host, respawn_own_at despawns the player's OTHER owned cars, which would delete
-- the AI mid-quali; place_at_grid touches no other vehicle. No-op if the car/pose is unavailable.
function quali.place_own(pose)
    if type(pose) ~= "table" then
        return
    end
    local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if not own then
        return
    end
    local placed, err = vehicles.place_at_grid(own, pose)
    if not placed then
        log("W", RACE_LOG_TAG, "staged quali re-place failed: " .. tostring(err))
        return
    end
    vehicles.set_vehicle_frozen(own, true)
    -- Re-seated the race car: re-queue the stock-dashboard rebind (bug default-dashboard-ui-missing).
    arm_dashboard_refresh()
end

-- Distance (m) the launched driver must be from the ramp before the next may stage (ADR-0044/Round4 gate).
-- Paired with the server's quali.STAGE_GAP (5 s): the next stages only once BOTH are satisfied. Raise either
-- to give the next driver more room behind the one launching.
quali.STAGE_CLEAR_DIST = 15.0

-- The AI hold net (bug quali-end-ai-not-frozen). A held AI that is measurably moving has lost its freeze,
-- so re-assert it. Both live on the quali table, not as top-level locals (200-local ceiling).
--   * CREEP_SPEED: m/s above which a held car counts as actually moving rather than settling on its springs.
--     Same value F1_JUMP_SPEED uses for "this car really moved" (~2.5 km/h).
--   * REASSERT_EVERY: seconds between re-asserts for one car, so a car that keeps rolling (on a slope, or
--     while its VE is still coming back up) costs at most one command pair + one log line per second.
quali.HOLD_CREEP_SPEED = 0.7
quali.HOLD_REASSERT_EVERY = 1.0

-- Mark / unmark one AI as held for the qualifying session (bug quali-end-ai-not-frozen). The AI mirror of
-- the player's hold.is_held(): "this car is frozen right now and must stay frozen". Set wherever an AI is
-- frozen (quali.stage_ai, quali.hold_ai, the circuit grace park), cleared where it is legitimately released
-- (quali.launch_ai). Host only -- the table is nil on a non-host, so this no-ops there.
function quali.set_ai_held(ai_id, held)
    if held then
        M.state.quali_ai_held = M.state.quali_ai_held or {}
        M.state.quali_ai_held[ai_id] = true
        return
    end
    if M.state.quali_ai_held then
        M.state.quali_ai_held[ai_id] = nil
    end
    if M.state.quali_ai_reassert then
        M.state.quali_ai_reassert[ai_id] = nil
    end
end

-- The dedicated P1 start ramp pose (ADR-0044/Round4), split off the front of the grid so P1 is empty at the
-- start; the active driver is teleported here for their run. nil for a normal race / circuit quali.
function quali.ramp_pose()
    return M.state.race and M.state.race.rampPose or nil
end

-- A driver's OWN fixed holding pose = gridPoses[slot+1] (grid positions 2..N+1; no roll-forward, so a driver
-- always returns to their own slot). Defaults to the local player's slot.
function quali.own_hold_pose(slot)
    local poses = M.state.race and M.state.race.gridPoses
    slot = slot or (M.state.race and M.state.race.mySlot) or 0
    if not poses then
        return nil
    end
    return poses[slot + 1]
end

-- Distance from a vehicle to the ramp (ADR-0044/Round4), or nil if unavailable. Used for the >=15 m gate.
function quali.dist_from_ramp(veh)
    local ramp = quali.ramp_pose()
    if not veh or type(ramp) ~= "table" or type(ramp.pos) ~= "table" then
        return nil
    end
    local ok, pos = pcall(function() return veh:getPosition() end)
    if not ok or not pos then
        return nil
    end
    local dx = pos.x - ramp.pos.x
    local dy = pos.y - ramp.pos.y
    local dz = pos.z - ramp.pos.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Launch the local car at the end of its per-driver count (ADR-0044): show GO, release the freeze, and arm
-- the checkpoint detector on the real race plan so the Start->Ziel run is scored + reported (the existing
-- path). A sprint has no lap clock; the sector tracker's per-run progress is reset here (Round 6). Re-arm
-- the ramp-clear report for this run.
function quali.launch_local()
    M.state.quali_run = nil
    M.state.quali_status = "running"
    M.state.quali_clear_sent = false  -- report once we clear the ramp (>=15 m)
    -- The one queue state that is NOT held: hand the recover key back, so recover = requeue again (Round 4).
    hold.sync()
    countdown.show_go()
    countdown.play_go()
    local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if own then
        local released, err = vehicles.set_vehicle_frozen(own, false)
        if not released then
            log("W", RACE_LOG_TAG, "staged quali launch: " .. tostring(err))
        end
    end
    disarm_freeze_hold_ve()
    M.state.freeze_hold_armed = false
    local plan = M.state.race and M.state.race.plan
    if plan then
        M.state.detection = checkpoints.new(plan)
    else
        log("W", RACE_LOG_TAG, "staged quali launch: no race plan; detection disabled")
    end
    M.state.laptimer = nil
    -- New run: base the sector splits from 0 again (fresh detector, crossing_seq restarts) while keeping the
    -- accumulated per-sector personal best for the record colouring (Round 6).
    sectors.reset_run(M.state.sector_track)
end

-- Find one of the owner's AI cars by its synthetic id, or nil.
function quali.find_ai(ai_id)
    for _, car in ipairs(M.state.ai_cars or {}) do
        if car.id == ai_id then
            return car
        end
    end
    return nil
end

-- Owner: stage an AI car at the ramp for its run (ADR-0044/0036). Reposition it (front-anchored, no other
-- car touched) + freeze, then start its per-driver count; quali.launch_ai releases + drives it at GO.
function quali.stage_ai(ai_id, count)
    local car = quali.find_ai(ai_id)
    local pose = quali.ramp_pose()
    if not car or not pose then
        return
    end
    local veh = be and be:getObjectByID(car.veh_id)
    if veh then
        pcall(function() vehicles.place_at_grid(veh, pose) end)
        pcall(function() vehicles.set_vehicle_frozen(veh, true) end)
    end
    -- Still held: the car sits frozen on the ramp until GO, exactly like the player's staged state, so the
    -- re-assert net keeps it there if the ramp teleport's VE churn drops the freeze (bug
    -- quali-end-ai-not-frozen).
    quali.set_ai_held(car.id, true)
    M.state.quali_ai_runs = M.state.quali_ai_runs or {}
    M.state.quali_ai_runs[car.id] = qualisprint.new_run(os.clockhp(), count)
    log("I", RACE_LOG_TAG, string.format("staged quali: AI '%s' staged at the ramp", tostring(car.label)))
end

-- Owner: release + drive one AI at the end of its per-driver count (ADR-0044/0036). Arms its proxy detector
-- so step_ai_detections scores + reports it, and re-arms the ramp-clear report for this AI. Single-car
-- ai.drive, and the ONLY ai.drive a staged session makes -- the staged branch skips begin_driving, so
-- everything begin_driving does for the field at the gun has to happen here for this one car. The default
-- snap route swaps no navgraph; the opt-in airoute=direct installs one, and the live-map flag handed back
-- in below keeps that install to once per session instead of once per released driver.
function quali.launch_ai(car_id)
    if M.state.quali_ai_runs then
        M.state.quali_ai_runs[car_id] = nil
    end
    local car = quali.find_ai(car_id)
    if not car or not M.state.race then
        return
    end
    -- GO: the one AI state that is free (the mirror of the player's "running"). Drop the hold BEFORE the
    -- release, so the per-frame net cannot re-freeze the car we are about to launch (bug
    -- quali-end-ai-not-frozen).
    quali.set_ai_held(car.id, false)
    ai.set_frozen({car}, false)
    local params = ai.resolve_params(M.state.ai_config, M.state.race.aiDefaults)
    -- Same rolling window as the race start, for this one car: ai.drive replaces (or clears) only this
    -- car's entry, so a relaunch never refills against the route it drove on its previous run.
    M.state.ai_window = M.state.ai_window or {}
    -- Passing the live-map flag in is what makes the custom navgraph (airoute=direct) a once-per-session
    -- install: route and `closed` are constant across a session's launches -- routePoints is written once
    -- at prepare, `closed` is the literal false below -- so the map a later launch would build is the one
    -- that is already live. A re-issued /race restores the map and clears the flag before it re-arms
    -- anything, so the flag can never outlive the map it describes.
    local ai_route = ai.drive({car}, M.state.race.routePoints or M.state.race.checkpoints,
        M.state.race.laps, params, false,
        {store = M.state.ai_window, backLaps = M.state.race.laps,
            mapLive = M.state.ai_custom_map})
    -- LATCH, never mirror. This is the one ai.drive caller that runs many times per session (once per
    -- released driver), so it only ever SETS the flag; the four `if M.state.ai_custom_map then
    -- ai.restore_map()` sites stay the only place that clears it. Copying begin_driving's
    -- `= customMap or nil` would clear the flag on any launch reporting no custom map -- and since that
    -- flag gates every restore, the line-only navgraph would then leak until the level changes. Dropping
    -- the return value entirely was exactly that bug (staged-quali-ai-custom-map-never-restored);
    -- begin_driving may mirror because it arms the whole field exactly once.
    if ai_route and ai_route.customMap then
        M.state.ai_custom_map = true
    end
    M.state.ai_detections = M.state.ai_detections or {}
    if M.state.race.plan then
        M.state.ai_detections[car.id] = checkpoints.new(M.state.race.plan)
    end
    M.state.quali_ai_cleared = M.state.quali_ai_cleared or {}
    M.state.quali_ai_cleared[car.id] = false  -- report once this AI clears the ramp
end

-- Owner: stop an AI + hold it (ADR-0044/Round4). stop=true -> freeze in place (a done AI at the window's
-- end); else -> re-place it at its OWN fixed holding slot (car.pose, its spawned grid position) and freeze.
--
-- Used by BOTH quali modes (bug quali-end-ai-not-frozen): the staged sprint reaches it through the server's
-- qualiHold, the circuit through step_ai_detections when an AI closes its lap inside the finish-your-lap
-- grace. It is the ONE place an AI is parked -- the mirror of hold.circuit_run for the player -- so the
-- semantics (ai.stop + freeze in place, no teleport) can only ever be defined once.
function quali.hold_ai(ai_id, stop)
    local car = quali.find_ai(ai_id)
    if not car then
        -- Not a silent drop: an unknown id here means a hold was routed for an AI this owner does not have,
        -- which is exactly the kind of failure that looks like "the NPC just keeps driving".
        log("W", RACE_LOG_TAG, "quali hold: no AI car for id " .. tostring(ai_id))
        return
    end
    -- Held from here until this AI is launched again (or the session ends): the per-frame net re-asserts the
    -- freeze if a VE reload throws it off -- controller.setFreeze is a soft per-VE flag that init/reset clear
    -- (bug quali-hold-reset-and-repaint-leak, same failure family).
    quali.set_ai_held(car.id, true)
    pcall(function() ai.stop({car}) end)
    if M.state.ai_detections then
        M.state.ai_detections[car.id] = nil
    end
    -- A held AI's route is over: drop its rolling window so nothing tops it up while it is parked. The
    -- per-frame step also skips every held car, so this is the second of the two layers -- the same
    -- belt-and-braces the freeze net uses (bug quali-end-ai-not-frozen).
    if M.state.ai_window then
        M.state.ai_window[car.id] = nil
    end
    if M.state.quali_ai_runs then
        M.state.quali_ai_runs[car.id] = nil
    end
    if M.state.quali_ai_cleared then
        M.state.quali_ai_cleared[car.id] = nil
    end
    local veh = be and be:getObjectByID(car.veh_id)
    if not veh then
        log("W", RACE_LOG_TAG, string.format(
            "quali hold: AI '%s' has no vehicle to hold", tostring(car.label)))
        return
    end
    if not stop and car.pose then
        pcall(function() vehicles.place_at_grid(veh, car.pose) end)
    end
    pcall(function() vehicles.set_vehicle_frozen(veh, true) end)
    -- The single place an AI is parked, so this one line answers the first live question for BOTH modes:
    -- did the hold reach this client at all? If it is missing while an AI drives on, the hold was never
    -- sent/routed; if it is present and the car still moves, the freeze is being thrown off -- which the
    -- re-assert net then reports separately (bug quali-end-ai-not-frozen).
    log("I", RACE_LOG_TAG, string.format("quali hold: AI '%s' held (%s)", tostring(car.label),
        stop and "stopped in place" or "returned to its holding slot"))
end

-- ===== circuit quali diagnostics (bug quali-ai-drives-only-one-lap) =======================
-- Three lines, one per event, so the next live circuit quali names the path by which an AI stops. Each
-- line states the numbers its hypothesis turns on:
--   * the arming -- which lap count reached the AI (quali plan vs race), windowed or not, back_laps;
--   * an AI park -- the lap it closed and how much quali clock was left (parked with clock left = W);
--   * a finishGrace arriving in qualifying -- its length and the quali clock left (clock left = W).
-- "Clock left" is read off a wall-clock anchor stamped at the phase entry, not off the dtReal-ticked HUD
-- clock, so a frame hitch cannot fake one; the HUD value rides along because it is what the player saw.

-- Seconds of quali clock a park or a grace may still find left before it counts as "the session was
-- still running". Covers the network delay between the server's expiry and the finishGrace landing here.
quali.CLOCK_SLACK = 2.0

-- The local quali clock still left on the wall (seconds), or nil outside a qualifying session.
function quali.clock_left()
    local clock = M.state.qualifying
    if not clock or not clock.anchor then
        return nil
    end
    return math.max(0, clock.total - (os.clockhp() - clock.anchor))
end

-- "N s left (HUD M s)" for a log line, plus whether that is more than the slack -- the W condition.
function quali.clock_text()
    local left = quali.clock_left()
    if not left then
        return "unknown (no quali clock)", false
    end
    local hud = M.state.qualifying and M.state.qualifying.remaining or left
    return string.format("%.1f s left (HUD %.1f s)", left, hud), left > quali.CLOCK_SLACK
end

-- The circuit quali just armed (or failed to arm) the host's AI. `ai_route` / `back_laps` are what
-- begin_driving armed them with, both nil when nothing was armed. Host only: a client without AI says
-- nothing. W whenever the AI cannot lap the whole session from this arming alone: no plan reached them,
-- they were given fewer laps than the quali plan, or a car carries no rolling window.
function quali.note_arming(quali_state, ai_route, back_laps)
    local cars = M.state.ai_cars
    if not cars or #cars == 0 then
        return
    end
    local race_laps = M.state.race and M.state.race.laps
    local plan_laps = quali_state and quali_state.laps
    if not ai_route then
        log("W", RACE_LOG_TAG, string.format(
            "circuit quali AI arming: %d AI NOT armed -- no quali plan reached begin_driving (quali plan "
            .. "%s, race %s lap(s)); they stay on the grid", #cars, tostring(plan_laps), tostring(race_laps)))
        return
    end
    local windowed = 0
    for _, car in ipairs(cars) do
        if M.state.ai_window and M.state.ai_window[car.id] then
            windowed = windowed + 1
        end
    end
    local short = plan_laps == nil or (tonumber(ai_route.laps) or 0) < plan_laps or windowed < #cars
    log(short and "W" or "I", RACE_LOG_TAG, string.format(
        "circuit quali AI arming: %d AI given %s lap(s) (quali plan %s, race %s lap(s)), windowed %d of %d, "
        .. "back_laps %s, route source %s%s", #cars, tostring(ai_route.laps), tostring(plan_laps),
        tostring(race_laps), windowed, #cars, tostring(back_laps), tostring(ai_route.source),
        short and " -- the AI cannot lap the whole session from this arming" or ""))
end

-- One AI closed a lap inside the circuit quali's finish-your-lap grace and is about to be parked for the
-- session (step_ai_detections). Intended once the clock is out (ADR-0041 amendment); a park with clock
-- left is the H2 signature and is said loudly.
function quali.note_ai_park(car, event)
    local clock, clock_left = quali.clock_text()
    local grace = M.state.grace and M.state.grace.remaining
    log(clock_left and "W" or "I", RACE_LOG_TAG, string.format(
        "circuit quali: AI '%s' parked after lap %s -- it closed a lap inside the finish-your-lap grace "
        .. "(%s s of grace left); quali clock %s%s", tostring(car.label), tostring(event and event.lap),
        grace and string.format("%.0f", grace) or "?", clock,
        clock_left and " -- PARKED WHILE THE SESSION WAS STILL RUNNING" or ""))
end

-- A finishGrace landed during qualifying (handle_finish_grace). The server sends it when the quali clock
-- has run out; one that lands with clock left would park every AI at its next lap close.
function quali.note_grace(duration)
    local clock, clock_left = quali.clock_text()
    log(clock_left and "W" or "I", RACE_LOG_TAG, string.format(
        "finishGrace during qualifying: %.0f s finish-your-lap grace, quali clock %s%s", duration, clock,
        clock_left and " -- every AI will be parked at its next lap close although the session is running"
            or ""))
end
-- ===== end circuit quali diagnostics ======================================================

-- "You're up" (server qualiStage, ADR-0044/Round4): a player payload -> stage the local car at the ramp; an
-- aiId (owner only) -> stage that AI. Guarded to a staged qualifying phase.
function quali.handle_stage(payload)
    if not M.state.race or not M.state.quali_staged or type(payload) ~= "table" then
        return
    end
    if payload.aiId ~= nil then
        quali.stage_ai(payload.aiId, payload.countdown)
        return
    end
    local pose = quali.ramp_pose()
    if not pose then
        log("W", RACE_LOG_TAG, "qualiStage ignored: no ramp pose")
        return
    end
    quali.place_own(pose)
    M.state.quali_status = "staged"
    M.state.detection = nil
    M.state.quali_clear_sent = false
    M.state.quali_run = qualisprint.new_run(os.clockhp(), payload.countdown)
    -- Still held: the car sits frozen on the ramp until GO, so the recover key stays blocked.
    hold.sync()
    log("I", RACE_LOG_TAG, "staged quali: your turn -- staged at the ramp")
end

-- "Hold" (server qualiHold, ADR-0044/Round4): a player payload -> hold the local car; an aiId (owner only)
-- -> stop + hold that AI. payload.stop=true means "stop + freeze in place" (a driver marked done at the
-- window's end); otherwise the driver returns to its OWN fixed holding slot (no roll-forward). Sent on a
-- finish/reset requeue and when marked done.
function quali.handle_hold(payload)
    if not M.state.race or not M.state.quali_staged then
        return
    end
    if type(payload) == "table" and payload.aiId ~= nil then
        quali.hold_ai(payload.aiId, payload.stop)
        return
    end
    M.state.quali_run = nil
    M.state.detection = nil
    M.state.laptimer = nil
    M.state.quali_clear_sent = true  -- not running anymore; suppress the ramp-clear report
    local stop = type(payload) == "table" and payload.stop
    if stop then
        M.state.quali_status = "done"
        -- Stop the run + freeze in place, no teleport.
        local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
        if own then
            vehicles.set_vehicle_frozen(own, true)
        end
    else
        M.state.quali_status = "queued"
        quali.place_own(quali.own_hold_pose())
    end
    -- Held either way (done in place, or queued back on the holding slot): block the recover key so the car
    -- cannot free itself out of the hold (bug quali-hold-reset-and-repaint-leak).
    hold.sync()
    countdown.clear()
end

-- Store the staged queue snapshot for the HUD (server qualiQueue, ADR-0044): own position/status/best +
-- the "waiting for driver to start" flag are read from it in build_hud_snapshot. Receive + store only.
function quali.handle_queue(payload)
    M.state.quali_queue = (type(payload) == "table" and type(payload.rows) == "table") and payload or nil
end

-- RECOVER -> new attempt (ADR-0044/Round4): the local driver hit their recover key mid-run. Tell the server
-- (it appends us to the back of the queue and sends a qualiHold to return us to our holding slot) and freeze
-- the car in place NOW, so it does not keep driving before that qualiHold lands. Repair does NOT come here
-- (it repairs in place, the run continues) -- only the recover key requeues. Called from M.on_assist_key_down
-- while the run's detector is armed; the recover key is owned by the VE override during the race (ADR-0017),
-- so it works with assists off.
function quali.request_requeue()
    M.state.quali_run = nil
    M.state.detection = nil
    M.state.laptimer = nil
    M.state.quali_status = "queued"
    M.state.quali_clear_sent = true
    -- Back in the queue = held again: block the recover key until this driver is staged and launched anew.
    hold.sync()
    send_to_server("qualiReset", {})
    -- Freeze in place immediately; the server's qualiHold returns us to our holding slot momentarily.
    local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if own then
        vehicles.set_vehicle_frozen(own, true)
    end
    countdown.clear()
    notice.say("Recover -- new attempt, back of the queue", "info")
    log("I", RACE_LOG_TAG, "staged quali: requeued self on recover")
end

-- Report to the server when the just-launched driver has cleared the ramp (>=15 m, ADR-0044/Round4), so the
-- next may stage. Once per run: the local player reports its own car; the owner reports each launched AI.
function quali.step_clearing()
    if M.state.quali_status == "running" and not M.state.quali_clear_sent
        and M.state.detection and not M.state.detection.done then
        local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
        local dist = own and quali.dist_from_ramp(own)
        if dist and dist >= quali.STAGE_CLEAR_DIST then
            M.state.quali_clear_sent = true
            send_to_server("qualiCleared", {})
        end
    end
    -- Owner: the same gate for a launched AI (only one is ever clearing at a time; the server matches).
    local cars = M.state.ai_cars
    local dets = M.state.ai_detections
    if cars and dets then
        M.state.quali_ai_cleared = M.state.quali_ai_cleared or {}
        for _, car in ipairs(cars) do
            local det = dets[car.id]
            if det and not det.done and not M.state.quali_ai_cleared[car.id] then
                local veh = be and be:getObjectByID(car.veh_id)
                local dist = veh and quali.dist_from_ramp(veh)
                if dist and dist >= quali.STAGE_CLEAR_DIST then
                    M.state.quali_ai_cleared[car.id] = true
                    send_to_server("qualiCleared", {aiId = car.id})
                end
            end
        end
    end
end

-- Host only: keep every HELD AI actually held, once per qualifying frame (bug quali-end-ai-not-frozen).
-- This is the AI's half of what hold.sync() + rearm_own_car_on_reload do for the player, and the piece
-- the AI side never had.
--
-- Why it is needed at all: vehicles.set_vehicle_frozen queues controller.setFreeze, and in the game's own
-- vehicleController that is a soft per-VE flag (`isFrozen`, applied as `M.brake = 1`) which init() and
-- reset() set straight back to false. Any VE reload -- a config respawn, a BeamMP re-sync, a reset -- drops
-- the hold silently, and the parked car rolls away. The player is netted out against exactly this; an AI
-- was not, so a one-shot freeze was the only thing holding it.
--
-- Gated on real movement rather than re-pushed blindly: a queueLuaCommand per AI per frame is genuine VE
-- traffic, whereas one velocity read per held car is nearly free. It also makes every re-assert a POSITIVE
-- OBSERVATION of the defect -- the log line below is the live diagnosis for the staged path, which cannot be
-- reproduced outside a real session. Per-car cooldown so a car that keeps rolling costs at most one command
-- pair and one log line per second.
function quali.step_ai_hold()
    local held = M.state.quali_ai_held
    local cars = M.state.ai_cars
    if not held or not cars then
        return  -- non-host (ai_cars nil, ADR-0036), or nothing held
    end
    local now = os.clockhp()
    for _, car in ipairs(cars) do
        if held[car.id] then
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                local ok, speed = pcall(function() return veh:getVelocity():length() end)
                if ok and speed and speed > quali.HOLD_CREEP_SPEED then
                    M.state.quali_ai_reassert = M.state.quali_ai_reassert or {}
                    local last = M.state.quali_ai_reassert[car.id] or 0
                    if now - last >= quali.HOLD_REASSERT_EVERY then
                        M.state.quali_ai_reassert[car.id] = now
                        -- Same two calls quali.hold_ai makes, in the same order, on the same car: stop the AI
                        -- (which zeroes its inputs and drops its route) and re-freeze IN PLACE. Never a
                        -- teleport -- the user's binding decision is that a parked AI stays where it stopped.
                        pcall(function() ai.stop({car}) end)
                        pcall(function() vehicles.set_vehicle_frozen(veh, true) end)
                        log("I", RACE_LOG_TAG, string.format(
                            "quali hold: AI '%s' moved at %.1f m/s while held (%s quali) -- re-froze in place",
                            tostring(car.label), speed,
                            M.state.quali_staged and "staged" or "circuit"))
                    end
                end
            end
        end
    end
end

-- Per-frame staged-quali step (ADR-0044/Round4), from onUpdate during a staged qualifying phase. Advances
-- the local per-driver count (count -> GO) and each staging AI's count, then reports ramp-clear. The detector
-- stepping + reporting rides the existing step_detection / step_ai_detections (they no-op until a run
-- launches). There is no pre-settle -- the count begins as soon as the driver is on the ramp.
function quali.step_staged()
    local now = os.clockhp()
    local run = M.state.quali_run
    if run then
        local st = qualisprint.step(run, now)
        if st.stage == "count" then
            if run.last_count ~= st.count then
                run.last_count = st.count
                countdown.play_beat(st.count)
            end
            countdown.show_start(st.count)
        elseif st.stage == "go" and st.launch then
            quali.launch_local()
        end
    end
    local ai_runs = M.state.quali_ai_runs
    if ai_runs then
        for car_id, ai_run in pairs(ai_runs) do
            local st = qualisprint.step(ai_run, now)
            if st.stage == "go" and st.launch then
                quali.launch_ai(car_id)
            end
        end
    end
    quali.step_clearing()
end
-- ===== end rally staged sprint quali (client) ============================================


-- ===== client-measured driver liveness ===================================================
-- The client half of the server's `stall` predicate (feature stall-detection-client-measured-movement).
--
-- The server is race-blind (ADR-0005): it holds no positions, no telemetry, and no client sends either.
-- It therefore has NO way of its own to tell a parked wreck from someone still driving, so this client is
-- the ONLY source of that verdict. (It used to guess from the gap since a driver last scored a checkpoint;
-- that heuristic ended a real qualifying under a driver who was still driving -- the same log shows 90 s
-- between two checkpoints on a normal lap -- and it was removed rather than retuned. See ADR-0014.)
--
-- A report is ONLY ever an AFK claim, never a DNF: it takes a driver out of "can still finish" and puts
-- them straight back in the moment they move again. The DNF still comes from the server grace expiry.

-- Seconds of continuous standstill before this client reports a car as AFK. Counted ONLY while the finish
-- timer is running (user decision 2026-09-03: "erst wenn der finish timer laeuft zaehlen die 15 sekunden,
-- nicht schon vorher"), so 15 s always means 15 s OF THAT TIMER -- a driver who was already parked when it
-- armed gets the same 15 s as everybody else. Predictable, at the price of a stalled field taking 15 s to
-- resolve rather than being reported at once.
stall.WINDOW = 15.0

-- Seconds of standstill at which the count starts: the local player sees a running "AFK in n" from here
-- to WINDOW, and the server is told at the same instant when this car is due to be counted out. THE one
-- place the "last 10 seconds" threshold exists -- the server mirrors no constant of it and has no opinion
-- about the length of a standstill window (feature standings-afk-cutoff-counter). Was 10.0, which showed
-- the driver only the last 5 s. AI raise no count -- there is nobody to show it to -- but their due time
-- is reported all the same, because the cutoff is decided by the LAST driver of the field.
stall.WARN_AT = 5.0

-- Client->server verdict, matching the server's stall.MSG: {stalled = bool} for our own car,
-- {aiId = ..., stalled = bool} for one of the host's AI (the qualiCleared split). The third shape,
-- {standing = true, dueIn = <seconds>}, is the early edge the cutoff counter runs on -- a prediction, and
-- explicitly NOT a verdict: the server keeps it in its own table and its liveness predicate never reads
-- it, so a driver who has just gone quiet still holds the grace open for the full WINDOW (ADR-0014).
stall.MSG = "stallReport"

-- server->client: the field's AFK cutoff, shown behind the finish-timer counter on the provisional
-- results card and the three qualifying lines. {active = true, dueIn = <seconds>} arms it,
-- {active = false} takes it back; the seconds are ticked down locally, like the finish grace itself.
stall.MSG_CUTOFF = "afkCutoff"

-- The sentence under the driver's own count. Kept beside the count rather than in the app, so the whole
-- message has one owner and every push carries it (ADR-0057). It is the second half of the message this
-- feature turned from a one-shot into a count -- the words are unchanged.
stall.HINT = "move now, or you stop holding the finish timer open"

-- Is this car standing still? THE criterion, and deliberately the very same test the recover/repair hold
-- uses to decide whether it may run (ADR-0017, is_car_stationary): one predicate, one number, applied to
-- the local player car and to each of the host AI alike. If you are stopped enough to hit recover, you are
-- stopped enough to count as AFK -- which is also the rule that is easiest to explain in-game.
--
-- Body velocity is the right read here BECAUSE it is the recover criterion. The earlier displacement
-- measure went with the server-side crossing-gap heuristic (ADR-0014, 2026-09-03).
-- An unreadable car answers `false`, i.e. MOVING. Both callers want that: a recover hold must not start
-- on a car we cannot vouch for, and an AFK claim must never rest on a failed read.
function stall.is_stopped(veh)
    local ok, speed = pcall(function() return veh:getVelocity():length() end)
    return ok and speed ~= nil and speed <= STATIONARY_SPEED
end

-- Name one measured car for a log line. Built only on a real transition, never per frame.
function stall.who(car)
    if car then
        return "AI '" .. tostring(car.label) .. "'"
    end
    return "own car"
end

-- Show the LOCAL player how long they have left, as a count that follows their own standstill clock.
-- Never for an AI: there is nobody to show it to.
--
-- It is a third sub-surface of the centred `notice` payload (ADR-0057), not a message: it has NO lifetime
-- of its own, because stall.check owns when it appears and when it goes. Stretching notice.LIFETIME over
-- a ten-second count would be the wrong seam -- the count would outlive the standstill that justifies it.
--
-- Repainted only when the displayed second changes, so a 10 s count costs ten pushes, not 600.
function stall.show_countdown(remaining)
    local seconds = math.max(0, math.ceil(remaining))
    local shown = M.state.afk_notice
    if shown and shown.seconds == seconds then
        return
    end
    M.state.afk_notice = {seconds = seconds, hint = stall.HINT}
    if not shown then
        -- Only on the arming push, and for the same reason notice.say does it: the HUD app mounts
        -- best-effort (ADR-0012 section 3), so the surface has to be on the layout before the first
        -- frame of the count. ensure_visible dedups, so this never disturbs an existing placement.
        hud.show()
    end
    notice.paint()
end

-- Drop the count. Called the instant the car moves, when the verdict lands (the prediction has resolved;
-- "AFK in 0" would be a forecast of something that already happened), and on the way out of every phase
-- and grace that could have raised it. Idempotent -- two nil checks when nothing stands.
function stall.clear_countdown()
    if not M.state.afk_notice then
        return
    end
    M.state.afk_notice = nil
    notice.paint()
end

-- Server->client cutoff counter (stall.MSG_CUTOFF): how long until the LAST still-standing driver of the
-- field is counted out, i.e. until the finish grace shortens. Stored as a local clock and ticked down in
-- onUpdate, exactly like M.state.grace -- the wire carries one edge, never a second per second.
--
-- Anything that is not an explicit arm clears it. A counter announcing a race end that does not come is
-- worse than no counter, so an absent field, a malformed payload or an older server all mean "no
-- addendum" rather than "whatever was there last".
function stall.handle_cutoff(payload)
    local remaining = (type(payload) == "table" and payload.active == true)
        and tonumber(payload.dueIn) or nil
    if not remaining or remaining < 0 then
        if M.state.stall_cutoff then
            M.state.stall_cutoff = nil
            log("I", RACE_LOG_TAG, "AFK cutoff withdrawn")
        end
        return
    end
    M.state.stall_cutoff = {remaining = remaining}
    log("I", RACE_LOG_TAG, string.format(
        "AFK cutoff in %.1fs -- every remaining driver is standing still", remaining))
end

-- Tick both finish-timer clocks one frame. Display only -- the server stays authoritative on the actual
-- cutoff (ADR-0014) and on the AFK verdict.
--
-- ONE function for both, called from both race phases, because the AFK addendum may never outlive the
-- counter it stands behind: no grace, no addendum. That is a property of this function rather than a
-- promise made at each of the places that drop M.state.grace.
function stall.step_clocks(dt)
    if not M.state.grace then
        M.state.stall_cutoff = nil
        return
    end
    M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dt or 0))
    local cutoff = M.state.stall_cutoff
    if cutoff then
        -- Floors at 0 and stays there until the server takes it back, which rides the same tick that
        -- shortens the grace: the last second must not blink out before the thing it announced happens.
        cutoff.remaining = math.max(0, cutoff.remaining - (dt or 0))
    end
end

-- Run one owned car's standstill clock and report the AFK / MOVING-AGAIN edges, once each.
--
-- `car` is nil for the local player's own car and the AI's entry when the host proxies one -- so an AI
-- report carries aiId and ours does not, which is the qualiCleared split verbatim.
--
-- Only ever called while the finish timer is armed (stall.step gates on it), so the clock measures
-- standstill DURING the timer and nothing else -- a driver who was already parked when it started still
-- gets the full WINDOW.
--
-- Moving clears the whole episode: the reversal is reported if we had said anything about this car at
-- all, and the entry is dropped, so a later standstill counts again from scratch.
--
-- Three edges, not two, since the cutoff counter (feature standings-afk-cutoff-counter): at WARN_AT the
-- server is told WHEN this car is due to be counted out, at WINDOW that it now is, and on movement that
-- it is not. The first is a prediction and the server keeps it well away from its liveness predicate --
-- it exists so the provisional card can print "AFK in 7" behind the counter it is about to change.
function stall.check(veh, t, car)
    local ai_id = car and car.id
    local key = ai_id or "self"
    local seen = M.state.stall_track
    local entry = seen[key]

    if not stall.is_stopped(veh) then
        if entry then
            -- `announced` and not just `reported`: a due time we sent is a claim about this car too, and
            -- leaving it standing would keep a countdown on everybody's card for a car that is driving.
            if entry.reported or entry.announced then
                send_to_server(stall.MSG, {aiId = ai_id, stalled = false})
                log("I", RACE_LOG_TAG, string.format(
                    "stall: %s is moving again -- reported as still running", stall.who(car)))
            end
            seen[key] = nil
        end
        if not ai_id then
            stall.clear_countdown()
        end
        return
    end

    if not entry then
        seen[key] = {since = t, announced = false, reported = false}
        return
    end
    if entry.reported then
        return  -- already claimed; only movement changes anything now
    end

    local standing = t - entry.since
    if standing >= stall.WINDOW then
        entry.reported = true
        send_to_server(stall.MSG, {aiId = ai_id, stalled = true})
        log("I", RACE_LOG_TAG, string.format(
            "stall: %s has been standing still for %.0f s of the finish timer -- reported AFK",
            stall.who(car), stall.WINDOW))
        if not ai_id then
            stall.clear_countdown()
        end
        return
    end
    if standing < stall.WARN_AT then
        return
    end

    local due_in = stall.WINDOW - standing
    if not entry.announced then
        entry.announced = true
        -- The measured remainder, not the WINDOW - WARN_AT literal: whatever frame this lands on, the
        -- server gets the deadline this client is actually counting to.
        send_to_server(stall.MSG, {aiId = ai_id, standing = true, dueIn = due_in})
        log("I", RACE_LOG_TAG, string.format(
            "stall: %s standing still for %.0f s -- reported due in %.1f s", stall.who(car),
            stall.WARN_AT, due_in))
    end
    if not ai_id then
        stall.show_countdown(due_in)
    end
end

-- Per-frame liveness step, from onUpdate in the racing and qualifying phases.
--
-- Only cars that can still finish are measured, and `detection` is this file's own truth for that: it is
-- nil while a staged-quali driver waits in the queue, nil after a requeue, dropped for an AI by
-- quali.hold_ai, and `done` the moment a car crosses the finish. hold.is_held() / quali_ai_held are the
-- second layer over the same truth -- redundant today, kept because a car WE froze on purpose being
-- reported stalled is a false positive with a real consequence.
--
-- Host only for the AI: M.state.ai_cars is nil on every other client (ADR-0036), so a non-host does no AI
-- work at all. Nobody ever reports for a car they do not own.
function stall.step()
    local phase = M.state.phase
    if not M.state.race or (phase ~= "racing" and phase ~= "qualifying") then
        stall.clear_countdown()
        return
    end
    -- Nothing counts until the finish timer runs (user decision 2026-09-03). Dropping the table here is
    -- also precisely what starts every car's 15 s from zero the moment the timer arms, so "15 s" always
    -- means 15 s of the timer -- and it keeps a normal race completely free of both work and traffic.
    if not M.state.grace then
        M.state.stall_track = nil
        stall.clear_countdown()
        return
    end
    local seen = M.state.stall_track
    if not seen then
        seen = {}
        M.state.stall_track = seen
    end
    local t = os.clockhp()

    local measured_own = false
    local detection = M.state.detection
    if detection and not detection.done and not hold.is_held() then
        -- The car the detector scores checkpoints with, not M.state.race_car_id: if a switch ever gets
        -- past the in-race lock, the stall verdict must follow the car actually being scored, or we would
        -- report a stall for a car the player is no longer in.
        local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
        if own then
            stall.check(own, t, nil)
            measured_own = true
        end
    end
    if not measured_own then
        -- The driver's count is the face of a measurement, so a frame that does not measure this car has
        -- nothing to show: finished, held, or momentarily unresolved, the count goes. Cheaper than
        -- arguing that every one of those transitions has to pass through a moving frame first.
        stall.clear_countdown()
    end

    local cars = M.state.ai_cars
    local detections = M.state.ai_detections
    if not cars or not detections then
        return
    end
    local held = M.state.quali_ai_held
    for _, car in ipairs(cars) do
        local det = detections[car.id]
        if det and not det.done and not (held and held[car.id]) then
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                stall.check(veh, t, car)
            end
        end
    end
end
-- ===== end client-measured driver liveness ===============================================

-- Answer the server's pre-flight validateRace request (ADR-0019): the race-blind server relays the
-- /race options here, we vet them against the locally-parsed race (race/start.validate) and report the
-- verdict back. The server starts on ok, or posts our reason to the issuing admin on a refusal. The
-- nonce is echoed so the server can match the reply to its in-flight check.
local function handle_validate_race(payload)
    local result = race_start.validate(payload)
    -- Footprints of the cars this race has already pinned (ADR-0051 round 2), resolved from the tokens
    -- the server relayed. Answering here is the earliest possible moment: it lands BEFORE the server
    -- assigns slots, so a bus fixed by car= or pre-picked for an AI reserves its space in the very first
    -- grid instead of in a correction afterwards.
    local sizes = vehicles.resolve_pinned_sizes(payload)
    -- car=host (ADR-0032 amendment): WE are the issuer, so the car everyone is about to race is the one
    -- under us right now. It is read ONCE, here: the server cannot read it (vehicle-blind, ADR-0005) and
    -- no other client can (it never sees this car's config), so this verdict is the only moment the spec
    -- can enter the race. host_car_spec is the same capture the AI's aicar=host inherits, blob gate
    -- (safe_config) included -- there is exactly one way a spec is captured in this mod.
    local host_car, host_car_name
    if result.ok and type(payload) == "table" and payload.car == "host" then
        host_car = vehicles.host_car_spec(vehicles.resolve_own_car(M.state.current_vehicle_id))
        if host_car then
            -- The first parts table BeamComp puts on the wire (user decision 2026-09-25). Its size was
            -- never measured, so measure it rather than guess: one line, once per race start, and the
            -- number is what decides whether relaying the whole spec ever needs revisiting.
            local encodable, encoded = pcall(jsonEncode, host_car)
            encodable = encodable and type(encoded) == "string"
            -- The measurement doubles as an ENCODABILITY probe, which is what earns it its pcall: a config
            -- jsonEncode cannot take would make send_to_server drop the WHOLE verdict below, and the race
            -- would then never start with one encode warning to show for it. Dropping the config here
            -- degrades that to "everyone in the host's model, stock trim" plus a named warning -- and the
            -- model alone is what the AI's host mode has always been able to fall back to. Dropped BEFORE
            -- the name is built, so the line cannot promise a tune that is not travelling.
            if not encodable then
                log("W", LOG_TAG,
                    "car=host: the captured config cannot be encoded -- relaying the model only")
                host_car.config = nil
            end
            host_car_name = vehicles.spec_label(host_car)
            log("I", LOG_TAG, string.format("car=host: captured '%s' (%s B on the wire)", host_car_name,
                encodable and tostring(#encoded) or "unmeasurable"))
            -- The footprint IS knowable now, unlike from the "host" token itself (token_size answers
            -- nothing for a sentinel), and this verdict lands BEFORE the server assigns slots -- so a host
            -- in a bus reserves everyone's space in the very first grid (ADR-0051 round 2). Best-effort:
            -- a miss reports nothing and the post-spawn reports correct it, as for every other car.
            local length, width = vehicles.spec_size_of(host_car)
            if length then
                sizes.carSize = {carLength = length, carWidth = width}
            end
        else
            -- No car under the host: refuse (user decision 2026-09-25). Degrading to keep-own would start
            -- a race nobody asked for, with everyone in a different car, and say nothing about it. The
            -- server posts this reason to the issuing admin exactly like a geometry refusal, and the
            -- geometry blob is dropped -- nothing is going to be built from this verdict.
            result.ok = false
            result.reason = "car=host needs you in a car -- get in the one everyone should race, "
                .. "then start again"
            result.raceData = nil
        end
    end
    send_to_server("raceValidation", {
        nonce = type(payload) == "table" and payload.nonce or nil,
        ok = result.ok,
        reason = result.reason,
        -- The server keys custom-grid resolution on the issuer's map + the canonical race id (ADR-0023):
        -- only the client knows them. Sent on every verdict; harmless when no grid is configured. raceId
        -- lets a default assigned for the full id resolve whatever shorthand was typed for /race.
        map = maps.current(),
        raceId = result.raceId,
        -- The aiRace content AI defaults (ADR-0036 Etappe B): the server uses aiDefaults.count to seed the
        -- AI slots when /race requested AI without an explicit number. nil for non-aiRace content.
        aiDefaults = result.aiDefaults,
        -- The serialized race GEOMETRY (ADR-0039): the race-blind server relays it verbatim in raceStart so
        -- a client without the local race file can still build the grid + checkpoints. nil on a refusal (no
        -- parse happened). The SCENERY is not here any more -- it is pulled on demand, ahead of the start,
        -- and only by the clients that actually lack the files (ADR-0046, trackProbe/trackNeed/trackData).
        raceData = result.raceData,
        -- Staged sprint quali activation (ADR-0044): whether an order=quali on this race is the rally
        -- staged single-car variant (sprint) vs. the ADR-0041 all-at-once circuit quali. The race-blind
        -- server reads this (it cannot see meta.closed) only when the race is order=quali.
        stagedQuali = result.stagedQuali,
        -- Footprints of the cars this race already pinned (ADR-0051 round 2). Plain numbers the server
        -- only computes with; absent whenever the car is not knowable yet (car=random, a cap that may
        -- substitute, an AI whose car is rolled at spawn).
        carSize = sizes.carSize,
        aiCarSize = sizes.aiCarSize,
        aiRosterSizes = sizes.aiRosterSizes,
        -- The issuer's own car for car=host (ADR-0032 amendment): {model, config}, the same shape the AI's
        -- "same as host" spawns from. The server keeps it opaque and relays it into every player's
        -- raceStart -- the fifth client-only fact this verdict carries (ADR-0019). nil for every other
        -- car= value, so an ordinary race ships none of it.
        hostCar = host_car,
        -- The captured car's human name for the one chat line the server sends the host. A DISPLAY string,
        -- relayed like `reason` above -- it is what lets the server name the car in chat without ever
        -- reading hostCar.model (vehicle-blind, ADR-0005).
        hostCarName = host_car_name,
    })
    -- This check is how a race request of ours is tied to the race it becomes: the setup panel's
    -- Confirm, or something else this client asked for in the meantime (feature
    -- setup-confirm-grid-stale-hint). Read with the FINAL verdict, car=host refusal included.
    setup.note_validation(payload, result.ok)
end

-- ===== the on-demand scenery pull (ADR-0046) =============================================
-- A client that does not have the race installed races it off the host's relayed definition (ADR-0039).
-- The geometry rides the raceStart; the scenery -- tens of KB -- is pulled here instead, so it never sits
-- in the race-start burst and is only ever sent to the clients that actually need it.

-- The server announces a validated race to everyone but its issuer. Answer only if we cannot build this
-- track ourselves -- then the scenery is pulled NOW, during spawning (and for a queued race, a whole race
-- early), rather than arriving with the start. Everyone who has the track stays silent, which is the
-- normal case and costs nothing.
local function handle_track_probe(payload)
    if type(payload) ~= "table" or type(payload.raceId) ~= "string" then
        return
    end
    if race_start.needs_track(payload.raceId) then
        log("I", LOG_TAG, "track '" .. payload.raceId .. "' not installed here -- requesting it")
        send_to_server("trackNeed", {raceId = payload.raceId})
    end
end

-- We are the issuer, and somebody on the server cannot build this race. We are the one client known to
-- hold the files (we just parsed the race for the pre-flight verdict), so serialize the scenery and ship
-- it once; the server caches it and fans it out to whoever needs it.
local function handle_track_fetch(payload)
    if type(payload) ~= "table" or type(payload.raceId) ~= "string" then
        return
    end
    local content = race_start.track_content(payload.raceId)
    if not content then
        return
    end
    send_to_server("trackUpload", {raceId = payload.raceId, prefabContent = content})
end

-- The scenery for a race we lack. Write it out and keep it for the session. If the race is already
-- prepared and running without its props (the pull did not beat the start), spawn them now -- we are in
-- the frozen pre-race phases, so nothing is missed. If it beat the start, M.prepare picks the paths up
-- from the cache and the props load with the car, exactly like a locally parsed race.
local function handle_track_data(payload)
    if type(payload) ~= "table" or type(payload.raceId) ~= "string" then
        return
    end
    race_start.absorb_track(payload.raceId, payload.prefabContent)

    local race = M.state.race
    if not race or not race.relayed or race.raceId ~= payload.raceId then
        return
    end
    if M.state.prop_names and #M.state.prop_names > 0 then
        return  -- already spawned (a re-sent blob, or a second race on the same track)
    end
    local files = race_start.track_prefabs(payload.raceId, race.direction)
    if #files == 0 then
        return
    end
    -- Never the prop owner here: a client that lacks the files is never the host, so no cones are kept
    -- (they are BeamMP-synced from the host, ADR-0020) and there is no cone source to spawn.
    race.prefabFiles = files
    M.state.prop_names = props.load(files, false, {})
    log("I", LOG_TAG, string.format("track '%s': spawned %d late prefab(s)", payload.raceId, #files))
end
-- ===== end the on-demand scenery pull ====================================================

-- Store the server-issued finish-grace countdown (ADR-0014): once the first player finishes, every
-- still-racing player has this many seconds to finish or be marked DNF. Ticked down locally in
-- onUpdate; shown on the HUD only while the local player has not finished.
local function handle_finish_grace(payload)
    local duration = type(payload) == "table" and tonumber(payload.duration) or nil
    if not duration or duration <= 0 then
        log("W", RACE_LOG_TAG, "finishGrace ignored: bad duration")
        return
    end
    M.state.grace = {remaining = duration}
    log("I", RACE_LOG_TAG, string.format("finish grace: %.0fs to finish or DNF", duration))
    -- In a qualifying session the grace is what parks every AI at its next lap close, so its arrival is
    -- stamped against the quali clock (bug quali-ai-drives-only-one-lap).
    if M.state.phase == "qualifying" then
        quali.note_grace(duration)
    end
end

-- True when the local player is out of the running race -- finished (detection done) or DNF'd (their
-- standings row is flagged, ADR-0014). Gates the provisional results view during the racing phase.
local function local_is_out()
    local detection = M.state.detection
    if detection and detection.done then
        return true
    end
    local race = M.state.race
    local my_slot = race and race.mySlot
    local standings = M.state.standings
    if my_slot ~= nil and standings then
        for _, e in ipairs(standings) do
            if e.slot == my_slot then
                return e.dnf and true or false
            end
        end
    end
    return false
end

-- Toggle the local results card on/off (the server relays a /results from this player; ADR-0022).
-- Local-only and per-player: it just flips a flag the HUD snapshot carries, so a player can look around
-- without affecting anyone else. Phase-aware: while the race still runs, a finished/DNF'd player toggles
-- the provisional card; once finished it toggles the final results card.
local function handle_results_toggle()
    if M.state.phase == "racing" and local_is_out() then
        M.toggle_provisional_results()
        return
    end
    M.toggle_results_min()
end

-- Toggle the local post-race analysis overlay (ADR-0028). Public so the results-card button can call it
-- via bngApi.engineLua (UI -> GE, ADR-0012); the /analysis command routes here through the
-- analysisToggle handler. The overlay only renders in the finished phase (the snapshot gates it), so a
-- flip in any other phase is inert -- it is reset to closed on each racing start and on lobby teardown.
function M.toggle_analysis()
    -- A no-op while the server has statistics switched off (ADR-0053). The button is already hidden and
    -- the server never relays /analysis, so this is only reachable through a direct bngApi.engineLua call
    -- or a stale UI frame -- but it is the single entry point that could force analysis_open true, and
    -- the overlay's own ng-if reads exactly that flag.
    if not M.state.stats_enabled then
        log("I", RACE_LOG_TAG, "analysis overlay ignored: statistics are disabled on this server")
        return
    end
    M.state.analysis_open = not M.state.analysis_open
    log("I", RACE_LOG_TAG, "analysis overlay " .. (M.state.analysis_open and "shown" or "hidden"))
end

-- Toggle the local provisional results card (ADR-0022 pattern). Public so the HUD's "Ergebnisse"/Schließen
-- buttons reach it via bngApi.engineLua as beamcomp_init.toggle_provisional_results (UI -> GE, ADR-0012);
-- the racing-phase /results also routes here. Only renders while the local player is finished/DNF and the
-- race still runs (the snapshot gates it), so a flip otherwise is inert; reset to shown on each racing start.
function M.toggle_provisional_results()
    M.state.provisional_open = not M.state.provisional_open
    log("I", RACE_LOG_TAG, "provisional results " .. (M.state.provisional_open and "shown" or "hidden"))
end

-- Minimize/restore the finished results card (ADR-0012/0041 minimize pattern). Public so the HUD's Minimize +
-- restore buttons reach it via bngApi (UI -> GE), and so the /results command (handle_results_toggle) routes
-- here in the finished phase. Local-only: it flips a flag the HUD snapshot carries, collapsing the card to a
-- small restore bar rather than fully hiding it. Reset to restored on each driving-phase start.
function M.toggle_results_min()
    M.state.results_min = not M.state.results_min
    log("I", RACE_LOG_TAG, "results card " .. (M.state.results_min and "minimized" or "restored"))
end

-- The /analysis relay (server -> this client) flips the same overlay flag as the results-card button.
local function handle_analysis_toggle()
    M.toggle_analysis()
end

-- Cycle the live-standings interval reference (self -> ahead -> leader -> self). Public so the HUD's
-- REL toggle can call it via bngApi.engineLua (UI -> GE, ADR-0012). Local-only display state read by
-- build_hud_snapshot; session-persistent (not reset per race). The next per-frame snapshot reflects it.
function M.cycle_interval_mode()
    local order = {self = "ahead", ahead = "leader", leader = "self"}
    M.state.interval_mode = order[M.state.interval_mode] or "self"
    log("I", RACE_LOG_TAG, "standings interval mode -> " .. M.state.interval_mode)
end

-- Heartbeat from the HUD app (UI -> GE, ADR-0012): the AngularJS directive calls this on link and once a
-- second after via bngApi.engineLua. Resetting the gap tells the onUpdate watchdog the app surface is
-- alive; if the heartbeat stops while a race wants the HUD up (an engine/BeamMP UI reload during the
-- spawn churn can drop our late-mounted app, ADR-0008), the watchdog re-shows the app and, failing that,
-- reloads the UI. Public so the app can reach it as beamcomp_init.note_hud_alive (mirrors toggle_analysis).
function M.note_hud_alive()
    M.state.hud_ack_gap = 0
end

-- Engine hook: the UI announces every COMPLETED boot here (ui/entrypoints/main/boot.js calls
-- uiReady() in GE, ge/main.lua fires extensions.hook("onUiReady")) -- the initial boot and every
-- engine/BeamMP reload. 0.39 holds the entire in-game UI boot until preloading is done, so
-- heartbeat silence up to this moment is a booting UI, not a lost app: restart the watchdog's
-- silence accounting from zero with a fresh (fast) re-show cadence, so the freshly booted UI gets
-- its mount-and-heartbeat window without a pointless immediate re-add, while a REAL entry loss
-- right after a boot is still repaired at full Stage-A speed (bug beamng-039-breakage rounds 3+4).
function M.onUiReady()
    M.state.hud_ack_gap = 0
    M.state.hud_reshow_wait = 0
    M.state.hud_reshow_interval = HUD_RESHOW_EVERY
end

-- Submit the race-setup panel's choices (UI -> GE -> server, ADR-0037). The panel serialises its form to
-- a JSON string and calls this via bngApi.engineLua; we decode and relay it to the server as a structured
-- startRace request that joins the same validation + start path as a typed /race. Public so the app can
-- reach it as beamcomp_init.start_race_from_ui. Guarded: a bad encode/shape is dropped, never thrown.
function M.start_race_from_ui(json)
    local ok, decoded = pcall(jsonDecode, json)
    if not ok or type(decoded) ~= "table" or type(decoded.race) ~= "string" or decoded.race == "" then
        log("W", RACE_LOG_TAG, "start_race_from_ui: bad payload")
        return
    end
    -- Remember what this Confirm asked for, so the grid it builds can be compared with the panel later.
    -- The string as the panel sent it, not `decoded` re-encoded (see M.state.setup_built).
    setup.note_request(json, decoded)
    send_to_server("startRace", {race = decoded.race, overrides = decoded.overrides})
end

-- The panel's "Start Race" (ADR-0037): end the staging wait and begin the countdown (the /go equivalent).
-- Two-stage flow -- start_race_from_ui prepares + stages, this fires the actual start. Public as
-- beamcomp_init.go_race_from_ui.
function M.go_race_from_ui()
    send_to_server("raceGo", {})
end

-- The panel's race-stop controls (ADR-0038 amendment): relay a single raceControl event the server routes
-- through the existing /raceclear (cancel, no scoring) and /raceend (end & score) handlers. Public as
-- beamcomp_init.cancel_race_from_ui / beamcomp_init.end_race_from_ui.
function M.cancel_race_from_ui()
    send_to_server("raceControl", {action = "cancel"})
end

function M.end_race_from_ui()
    send_to_server("raceControl", {action = "end"})
end

-- The setup panel's championship control (ADR-0037/0040/0041): the panel serialises
-- {action, preset, order, qualiMinutes} and calls this; we decode and relay it as a championshipCmd
-- that routes through the same admin-gated handler as the /championship chat command. Public as
-- beamcomp_init.championship_cmd. A bad payload is dropped.
function M.championship_cmd(json)
    local ok, decoded = pcall(jsonDecode, json)
    if not ok or type(decoded) ~= "table" or type(decoded.action) ~= "string" then
        log("W", RACE_LOG_TAG, "championship_cmd: bad payload")
        return
    end
    send_to_server("championshipCmd", {
        action = decoded.action,
        preset = decoded.preset,
        order = decoded.order,
        qualiMinutes = decoded.qualiMinutes,  -- length for a grid=quali championship (ADR-0041)
    })
end

-- Re-push the last-known championship state to the panel (UI -> GE, ADR-0040): the panel calls this on link
-- so a freshly-added app that missed the open-time broadcast still fills. Public as
-- beamcomp_init.request_championship.
function M.request_championship()
    if guihooks then
        guihooks.trigger("BeamCompChampionship", M.state.championship or {active = false})
    end
end

-- Re-push the current race phase to the setup panel (UI -> GE), mirroring request_championship so a freshly
-- linked or reopened panel learns the phase and can show/hide the race-stop controls. Public as
-- beamcomp_init.request_race_phase.
function M.request_race_phase()
    if guihooks then
        guihooks.trigger("BeamCompSetupPhase", {phase = M.state.phase or "lobby"})
    end
end

-- The setup panel's class-drop tournament control (ADR-0037/0042): the panel serialises {action, classes,
-- order} and calls this; we decode and relay it as a tournamentCmd routed through the same admin-gated server
-- handler the panel uses. Public as beamcomp_init.tournament_cmd. A bad payload is dropped.
function M.tournament_cmd(json)
    local ok, decoded = pcall(jsonDecode, json)
    if not ok or type(decoded) ~= "table" or type(decoded.action) ~= "string" then
        log("W", RACE_LOG_TAG, "tournament_cmd: bad payload")
        return
    end
    send_to_server("tournamentCmd", {
        action = decoded.action,
        classes = decoded.classes,  -- ordered fast->slow specs: each {car="model[:config]"} or {maxhp=N}/{maxpwr=N}
        order = decoded.order,
    })
end

-- Re-push the last-known tournament state to the panel (UI -> GE, ADR-0042), mirroring request_championship
-- so a freshly-added app that missed the open-time broadcast still fills. Public as
-- beamcomp_init.request_tournament.
function M.request_tournament()
    if guihooks then
        guihooks.trigger("BeamCompTournament", M.state.tournament or {active = false})
    end
end

-- Re-push the last-known player list to the panel (UI -> GE, ADR-0054), mirroring request_championship
-- so a freshly linked or reopened panel fills without waiting for the next server broadcast. Public as
-- beamcomp_init.request_players.
function M.request_players()
    identity.push_players()
end

-- The panel's Remind button (ADR-0054): ask the server to chat-hint every player still on a temporary
-- name. The panel lists everyone, but Remind deliberately targets only those -- the server decides who,
-- from the same list it sent us. Admin-gated server-side like the grid messages. Public as
-- beamcomp_init.remind_unnamed.
function M.remind_unnamed()
    send_to_server("remindUnnamed", {})
end

-- The panel's Send-keys button (ADR-0058): ask the server to re-send every player the chat lines naming
-- HIS own assist keys -- the same lines he got on joining, built by the same
-- builder. The counterpart to Remind, and admin-gated server-side exactly like it, so a non-admin panel
-- simply gets a refusal in chat. Public as beamcomp_init.remind_keys.
function M.remind_keys()
    send_to_server("remindKeys", {})
end

-- The panel's "Show driver names" switch (ADR-0062). This is a SERVER setting, not a local preference,
-- so nothing is applied here: the server verifies the caller is a race admin, changes the value, writes
-- it back to beamcomp.config.ini and broadcasts the new policy -- and the broadcast is what moves both
-- the nametags and this panel's checkbox, on every client rather than just this one. A non-admin panel
-- gets a refusal in chat and nothing changes anywhere, exactly like Remind.
--
-- The argument arrives as the panel's "1"/"0" string (geLuaArg), the same shape request_setup_data uses.
-- Public as beamcomp_init.set_driver_names.
function M.set_driver_names(flag)
    send_to_server("setDriverNames", {value = flag == "1" or flag == true})
end

-- Push one model's configs to the open race-setup panel (UI -> GE, ADR-0037). The panel calls this when
-- the car model changes; configs are probed lazily per model since an all-models probe is heavy. Public
-- so the app can reach it as beamcomp_init.request_car_configs.
function M.request_car_configs(model)
    if type(model) ~= "string" then
        return
    end
    guihooks.trigger("BeamCompSetupCars", {model = model, configs = carlist.options(model).configs})
end

-- Push ONE race's track metadata to the open race-setup panel (UI -> GE, ADR-0037). The panel calls this
-- when the selected race changes; it needs `closed` to preselect sprint vs circuit and to decide whether a
-- lap count means anything (ADR-0013 amendment), and `defaultLaps` to show the lap count that applies when
-- the Laps field is left empty, as its grey "3 (default)" placeholder (ADR-0049).
--
-- Lazy per race for the same reason configs are lazy per model: racelist.options deliberately parses no
-- geometry, and a map can carry well over a hundred races. Both fields are nil when the race cannot be
-- resolved or parsed -- the panel then keeps its "track type unknown" fallback and its "auto" placeholder
-- instead of being told something false. Public so the app can reach it as beamcomp_init.request_race_meta.
--
-- defaultLaps is put through race_start.resolve_laps with no request, which is literally the panel's
-- question: "what does this race run if I type nothing?". That covers the track that names no lap count
-- at all -- the answer is one lap, and it is race/start.lua's answer, not a second one invented here.
function M.request_race_meta(race_id)
    if type(race_id) ~= "string" then
        return
    end
    local meta = racelist.meta_for(maps.current(), race_id)
    guihooks.trigger("BeamCompRaceMeta", {
        id = race_id,
        closed = meta and meta.closed,
        defaultLaps = meta and race_start.resolve_laps(nil, meta.defaultLaps) or nil,
    })
end

-- ===== race-setup panel presence (bug setup-panel-settings-survive-ui-reload) =====================
-- The panel is put on screen by the admin-gated /raceui relay and taken down by its own Close button --
-- but an engine/BeamMP UI reload destroys it (and its Angular scope) without ever running that close,
-- and our server-delivered app does not come back on its own (ADR-0008/0012). GE therefore remembers
-- that the panel SHOULD be on screen and re-adds it once when the app's heartbeat goes silent. Same
-- mechanism as the HUD watchdog (M.note_hud_alive / step_hud_watchdog), latched to a single re-add
-- per open: the user wants a lost panel back, not a panel that fights BeamNG's own app-container X.

-- Seconds of heartbeat silence (the app beats ~1 s) after which the panel counts as lost. Two missed
-- beats of tolerance: the loss is permanent when it is real (the app is gone until something re-adds
-- it), so reacting a second later costs nothing, while a UI thread that merely stutters is not worth
-- spending the single restore on.
setup.ACK_STALE = 3.0

-- Start tracking a freshly authorized open. Called ONLY from handle_setup_open, i.e. downstream of the
-- server's admin check, so the watchdog can reproduce an authorized open state but never invent one
-- (ADR-0016/0037).
function setup.arm()
    M.state.setup_open = true
    M.state.setup_seen = false
    M.state.setup_ack_gap = 0
    M.state.setup_restored = false
end

-- Forget the open state, so nothing can pop the panel back up: the panel's own Close (the clean way out)
-- and the level boundary, where the UI reloads anyway and a remembered open would surface as a zombie
-- panel on the next map. Deliberately NOT called from teardown_race_world: that also runs on the
-- finished -> lobby transition, and the lobby is exactly where the panel is most legitimately open
-- (setting up the next race). A race end cannot produce a zombie -- an open panel is still on screen,
-- and a closed one has already cleared this.
function setup.clear()
    M.state.setup_open = false
    M.state.setup_seen = false
    M.state.setup_ack_gap = 0
    M.state.setup_restored = false
    -- The next open re-asserts this from the server, so forgetting it here is the safe direction
    -- (ADR-0056): a closed panel cannot be locked, and a reopen decides afresh.
    M.state.setup_locked = false
    -- Same direction, and here it is the point: onClientEndMission calls this when the player LEAVES the
    -- BeamMP session, so dropping the numbers here is what keeps one server's defaults from being shown
    -- as the next server's. Costs nothing -- handle_setup_open re-asserts them before the push that
    -- carries them, so a reopen never flashes the unknown state.
    M.state.server_defaults = nil
    -- Same reason, and here it matters more than for the numbers: BeamMP hands out player ids per
    -- server, so an id kept from the last one would match a stranger's row on the next.
    M.state.own_player_id = nil
    -- The nametag policy (ADR-0062) is deliberately NOT cleared here, and that is the whole point of this
    -- comment: this function has TWO callers and they mean different things. onClientEndMission is a
    -- session boundary; the panel's own Close is not. Clearing the policy here dropped this client's
    -- record of what it had already written on every Close -- and a tag is only ever given back by
    -- whoever remembers taking it away (nametags.lua show_entry), so the props came back named at the
    -- next BeamMP entry rebuild: exactly the defect ADR-0062 closed, reopened by a button an admin
    -- presses every race. The session boundary clears it through identity.clear_policy instead.
end

-- Watchdog step, called from onUpdate while the panel is meant to be open -- phase-independently, since
-- the panel is used in the lobby and carries the race-stop controls mid-race (ADR-0038 amendment).
-- Silence only counts once we have heard the app alive: a panel that has not linked yet is merely slow
-- (this bug lives on laggy clients), and spending the single restore on that would leave a real loss
-- unrecovered. Re-add only -- a reload stage never existed here, and since round 4 the HUD watchdog
-- has none either.
function setup.step(dt)
    if M.state.setup_restored or not M.state.setup_seen then
        return
    end
    M.state.setup_ack_gap = M.state.setup_ack_gap + (dt or 0)
    if M.state.setup_ack_gap < setup.ACK_STALE then
        return
    end
    M.state.setup_restored = true
    log("I", RACE_LOG_TAG, "race-setup panel went silent -- re-adding it once")
    -- The compat seam self-guards and pcalls every engine call (race/uilayout.lua), so this onUpdate
    -- tick can never be taken down. The latch is already set above, so a failure costs the one
    -- restore rather than repeating every frame -- and spending it is safe even when the player is
    -- sitting in BeamNG's HUD-apps menu: the seam defers a call it cannot make there and replays it
    -- itself (M.uilayout.step, bug ui-glitches-after-ingame-menu-resize).
    M.uilayout.ensure_visible("beamCompSetup")
end

-- UI -> GE presence heartbeat from the open panel (mirrors note_hud_alive). Public so the app can reach
-- it as beamcomp_init.note_setup_alive.
function M.note_setup_alive()
    M.state.setup_ack_gap = 0
    M.state.setup_seen = true
end

-- Remove the race-setup panel from the current layout (UI -> GE, ADR-0037), the close counterpart to
-- the setupOpen auto-add. Public so the panel's Close button can reach it as beamcomp_init.close_setup.
function M.close_setup()
    M.uilayout.remove("beamCompSetup")
    -- The admin is done with the panel, so stop expecting it on screen (nothing re-adds it from here).
    setup.clear()
end

-- Surface grid-editor feedback both as a toast (visible while in-game) and in the log (visible in the
-- console where the command was typed). `kind` is a toastr type ("info"/"warning").
local function editor_feedback(msg, kind)
    if guihooks then
        guihooks.trigger("toastrMsg", {type = kind or "info", title = "BeamComp grid", msg = msg})
    end
    log("I", RACE_LOG_TAG, "grid editor: " .. msg)
end

-- Reflect the live grid-editor session back to the grid-editor panel (ADR-0037 amendment): the editor
-- (race/grideditor.lua) is the source of truth, the panel only displays this state and calls the knob
-- setters. Pushed after every mutating bridge call. knobs is the active direction's block (or nil when no
-- session), so the panel's steppers show the authoritative, clamped values; the non-pinned width axis
-- (rows or columns) is nil/derived and reads blank ("auto") in the panel.
local function push_grid_state()
    local editor = grideditor.state
    -- The knobs reflect the ACTIVE segment's params (ADR-0023 amendment); segment_bounds + activeSegment
    -- let the panel drive the breakpoint selector and show which segment is being edited.
    local block = editor.active and grideditor.active_params() or nil
    local bounds = grideditor.segment_bounds()
    local active_segment = grideditor.active_segment()
    guihooks.trigger("BeamCompGridState", {
        active = editor.active,
        race = editor.race,
        name = M.state.grid_active_name,
        direction = editor.direction,
        hasReverse = (editor.blocks ~= nil and editor.blocks.reverse ~= nil),
        previewCount = grideditor.preview_count(),
        -- The ordered breakpoint boundaries, the active segment index (1-based) and its start slot, so the
        -- panel shows "segment i of n, from slot s" and can add/remove/select breakpoints.
        segments = bounds,
        activeSegment = active_segment,
        activeStartSlot = bounds[active_segment] and bounds[active_segment].startSlot or 0,
        knobs = block and {
            offsetForward = block.offsetForward,
            offsetLateral = block.offsetLateral,
            offsetHeight = block.offsetHeight,
            headingDeg = block.headingDeg,
            rowGap = block.rowGap,
            colGap = block.colGap,
            rows = block.rows,
            columns = block.columns,
            mirror = block.mirror,
            -- The segment's three placement options (ADR-0023 amendment 2026-09-01): how high above the
            -- inherited chain height its ground search starts, and the two switches that turn the drop
            -- and the measured tilt off for this part of the field.
            castHeight = block.castHeight,
            noDowncast = block.noDowncast,
            noSlope = block.noSlope,
        } or nil,
        -- The layout defaults behind the knobs above, so a knob a stored block omits (offsetHeight on a
        -- grid saved before that knob existed) shows the value that actually applies as its grey
        -- placeholder instead of a bare "-". Constant, but sent with the knobs it annotates so the panel
        -- always has both together.
        knobDefaults = grideditor.knob_defaults(),
    })
end

-- Sync the grid editor's reference scene to the active session (ADR-0037 amendment, tweak): the track's
-- static props + its checkpoints in this direction's order, so the admin places the grid against the real
-- start area and sees the route from the free camera (ADR-0023 amendment 2026-10-06). Always drops the
-- previous editor props first. Props are spawned only in the lobby -- during a race the real race props
-- are already in the scene (and share these object names), so we never double-spawn over them; the
-- checkpoints are drawn immediate-mode regardless. Reload-safe: only the prop names are persistent
-- (tracked in M.state), the checkpoints are plain data.
local function refresh_grid_edit_scene()
    props.clear(M.state.grid_edit_prop_names or {})
    M.state.grid_edit_prop_names = nil
    M.state.grid_edit_checkpoints = nil
    if not grideditor.state.active then
        return
    end
    local scene = grideditor.current_scene()
    if not scene then
        return
    end
    M.state.grid_edit_checkpoints = scene.checkpoints
    if M.state.race == nil then
        M.state.grid_edit_prop_names = props.load(scene.prefabFiles or {}, false)
    end
end

-- Open a saved grid the server returned for a beamcomp_grid_edit/gridui fetch (ADR-0023). `found` false
-- means that race has no such grid; otherwise hand the record to the editor -- re-anchored onto the panel's
-- selected race (grid_load_anchor) so a grid owned by another race previews against the current one --
-- then refresh the reference scene and reflect the loaded block to the panel so its knobs fill in.
local function handle_grid_data(payload)
    if type(payload) ~= "table" or not payload.found then
        local name = type(payload) == "table" and payload.name or "?"
        local race = type(payload) == "table" and payload.race or "?"
        editor_feedback("no saved grid '" .. tostring(name) .. "' for " .. tostring(race), "warning")
        return
    end
    local anchor_race = M.state.grid_load_anchor
    M.state.grid_load_anchor = nil
    local ok, result = grideditor.open({
        forward = payload.forward,
        reverse = payload.reverse,
        race = payload.race,
        -- The grid's authored field size (ADR-0023 amendment 2026-08-02). This rebuild names every field
        -- it keeps, so the count has to be listed here or the reopened grid silently falls back to 16.
        -- grideditor coerces it, so a missing or hand-edited value degrades instead of breaking.
        previewCount = payload.previewCount,
    }, anchor_race)
    if ok then
        -- Remember the loaded name so the panel can offer overwrite (same-name save) + assign without
        -- retyping, and so a panel reopen restores that target.
        M.state.grid_active_name = type(payload.name) == "string" and payload.name or nil
        editor_feedback("editing saved grid '" .. tostring(payload.name) .. "' for " .. tostring(result))
        refresh_grid_edit_scene()
        push_grid_state()
    else
        editor_feedback(tostring(result), "warning")
    end
end

-- ===== the saved grid and preset lists: request, arrival, map check (ADR-0023 amendment 2026-10-10) =====
-- Another admin's save, assign or delete reaches EVERY connected player now, not just the writer (bug
-- raceui-misses-other-admins-presets-and-grids). Two things ride on that. A list can land on a client
-- that is still loading a map or is already on another one, so each list names its map and is dropped
-- here when that is not this client's. And whether a list reached a panel is a question only a live
-- two-machine session can answer, so every request and every arrival leaves one line, beside the
-- server's line for every list it sends. None of it is per frame: an open, a refresh or a write.

-- A map key as these lines print it: quoted, or "(none)" when there is none.
function setup.map_text(map)
    if map == nil then
        return "(none)"
    end
    return "'" .. tostring(map) .. "'"
end

-- Ask the server for the current map's saved grids (gridListReq) or presets (presetListReq), and say
-- so. `target` is the gridList routing string (see handle_grid_list); a preset request names none.
function setup.request_list(message_type, map, target)
    log("I", LOG_TAG, string.format("requesting %s: map %s, target %s",
        message_type, setup.map_text(map), tostring(target or "none")))
    send_to_server(message_type, {map = map, target = target})
end

-- Whether an arrived gridList / presetList is for the map this client is on, logging the arrival either
-- way. A list that names a map other than this client's is dropped -- an unknown current map included,
-- which is a client mid-load. A list that names NO map comes from a server older than this check and is
-- taken as it always was. `count` is read by the caller from the list it has already normalised.
function setup.accept_list(message_type, payload, count)
    local list_map = type(payload) == "table" and payload.map or nil
    local target = type(payload) == "table" and payload.target or nil
    local summary = string.format("%s of map %s, %d entr%s, target %s", message_type,
        setup.map_text(list_map), count, count == 1 and "y" or "ies", tostring(target or "none"))
    local here = maps.current()
    if list_map ~= nil and list_map ~= here then
        log("W", LOG_TAG, summary .. ": DROPPED, this client is on map " .. setup.map_text(here))
        return false
    end
    log("I", LOG_TAG, summary .. ": received")
    return true
end

-- Post the current map's saved grids from a gridList reply (ADR-0023). The reply carries the WHOLE map as
-- {name, race, isDefault} entries sorted by race then name (ADR-0023 amendment 2026-07-27), so each
-- consumer filters/groups it locally instead of asking again per race.
--
-- It also carries the DESTINATION it is for (ADR-0023 amendment 2026-09-25): the requester names one and
-- the server relays it back untouched, so nothing has to be remembered between the two halves of the
-- round trip. That is what the retired one-shot M.state.grid_list_target could not do -- with one slot
-- and three callers, two requests in flight (both panels link at once after a UI reload) let the first
-- reply consume the other's destination, stranding a panel on an empty list for the session.
--   "setup"   -> the race-setup panel's grid dropdown (ADR-0037)
--   "gridui"  -> the grid-editor panel's saved-grid dropdown (ADR-0037 amendment)
--   "console" -> the grid-editor console command's toast (beamcomp_grid_list), grouped by race
--   absent    -> nobody named one: an unsolicited echo after a save/assign/delete -- this client's own
--                or another admin's (ADR-0023 amendment 2026-10-10) -- or a server too old to relay the
--                field. Serve BOTH panel hooks -- they are open at the same time in the normal flow
--                ("Edit..." leaves the setup panel standing), and a guihooks.trigger at a panel that is
--                not on screen is a no-op, so this needs to know nothing about what is up.
-- The console toast is reachable ONLY on the literal "console", which only that one command sends, so a
-- save can never surface as a toast whatever else is in flight. A list for another map goes nowhere
-- (setup.accept_list).
local function handle_grid_list(payload)
    local grids = type(payload) == "table" and type(payload.grids) == "table" and payload.grids or {}
    local target = type(payload) == "table" and payload.target or nil
    if not setup.accept_list("gridList", payload, #grids) then
        return
    end
    if target == "setup" then
        guihooks.trigger("BeamCompSetupGrids", {grids = grids})
        return
    end
    if target == "gridui" then
        guihooks.trigger("BeamCompGridList", {grids = grids})
        return
    end
    if target ~= "console" then
        guihooks.trigger("BeamCompSetupGrids", {grids = grids})
        guihooks.trigger("BeamCompGridList", {grids = grids})
        return
    end
    if #grids == 0 then
        editor_feedback("no saved grids on this map")
        return
    end
    -- Console toast: one "<race>: a*, b" group per race, the default marked with a star. The server
    -- already sorted by race then name, so consecutive entries of one race group without a lookup.
    local groups = {}
    local current_race = nil
    for _, entry in ipairs(grids) do
        if entry.race ~= current_race then
            current_race = entry.race
            groups[#groups + 1] = {race = current_race, names = {}}
        end
        local names = groups[#groups].names
        names[#names + 1] = tostring(entry.name) .. (entry.isDefault and "*" or "")
    end
    local lines = {}
    for _, group in ipairs(groups) do
        lines[#lines + 1] = tostring(group.race) .. ": " .. table.concat(group.names, ", ")
    end
    editor_feedback("saved grids (* = race default) -- " .. table.concat(lines, " | "))
end

-- Push the current map's saved preset names to the race-setup panel (ADR-0037 amendment). The panel is
-- the sole consumer (unlike gridList's three), so no routing target is needed -- always to the panel.
-- The list arrives after this client's own save or delete, after another admin's (ADR-0023 amendment
-- 2026-10-10), and on request; a list for another map goes nowhere (setup.accept_list).
local function handle_preset_list(payload)
    local names = type(payload) == "table" and type(payload.names) == "table" and payload.names or {}
    if not setup.accept_list("presetList", payload, #names) then
        return
    end
    guihooks.trigger("BeamCompSetupPresets", {names = names})
end

-- Apply a loaded preset to the race-setup panel (ADR-0037 amendment). On a found reply, push the opaque
-- form blob so the panel restores it through the same path as the session form-restore
-- (applyStoredForm/BeamCompSetupForm). `found` false means no such preset for this map (a stale entry).
local function handle_preset_data(payload)
    if type(payload) ~= "table" or not payload.found or type(payload.form) ~= "string" then
        local name = type(payload) == "table" and payload.name or "?"
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp preset",
            msg = "preset '" .. tostring(name) .. "' not found on this map",
        })
        return
    end
    guihooks.trigger("BeamCompSetupPresetData", {form = payload.form})
end

-- Build the race-setup panel's option dataset and push it to the app (ADR-0037): the startable races +
-- drivable car models (built locally since the server is race/vehicle-blind, ADR-0005), plus an async
-- request for the map's saved grids (routed back by handle_grid_list). Static enums (modes, order,
-- presets, airoute) live in the panel template; config lists load per model on demand. Used both when the
-- panel opens and when it pulls/refreshes itself.
local function push_setup_data(include_deprecated)
    local map = maps.current()
    guihooks.trigger("BeamCompSetupData", {
        races = racelist.options(map, include_deprecated),
        cars = carlist.options().models,
        -- The static AI colour palette (ADR-0047 round 3) for the roster swatch picker; same list the
        -- GE roster draw uses, so swatches and auto-assigned colours share one source.
        aiPalette = ai.palette(),
        -- The default values behind the panel's OPTIONAL number fields, so an empty field can show its
        -- real default as the grey placeholder ("5 (default)") instead of a useless "default"/"-". Both
        -- come straight from the modules that resolve them, so the panel carries no second copy that
        -- could drift: the AI difficulty numbers per preset (race/ai.lua PRESETS, preset-dependent, so
        -- the panel re-reads them whenever the Preset dropdown changes) and the recover/repair assist
        -- hold seconds (race/start.lua, a constant).
        aiDefaults = ai.preset_defaults(),
        assistHoldDefault = race_start.assist_hold_default(),
        -- The keyboard keys the recover/repair assists actually sit on right now (ADR-0017/0049), so the
        -- panel's hover help can name the real key instead of a hardcoded guess. Either field is absent
        -- when the action has no keyboard binding; the panel then names the command and no key.
        assistKeys = lock.assist_controls(),
        -- The defaults the SERVER owns, relayed verbatim from its setupOpen (M.state.server_defaults).
        -- Unlike the three above it is NOT a GE constant, so it can genuinely be missing -- an older
        -- server, or this GE state rebuilt by a Lua reload (ADR-0052). It is sent on every push, absent
        -- included: the panel must read an absent table as "unknown" and fall back to a neutral
        -- "default", never keep showing a number GE can no longer vouch for.
        serverDefaults = M.state.server_defaults,
        -- Whether drivers carry a name over their car (ADR-0062) -- a SERVER setting the panel can flip,
        -- not a local preference, so it rides the dataset the panel already pulls on link. Unknown reads
        -- as on, exactly as the policy itself does.
        showDriverNames = M.state.show_driver_names ~= false,
    })
    -- The driver NAME list for the panel's roster name picker (ADR-0048): sourced from the mod-bundled
    -- driver file (the single pool source), so it is complete on the first push with no server round-trip.
    -- The panel picks names from this instead of free typing.
    guihooks.trigger("BeamCompAiPool", {names = ai.pool_names()})
    setup.request_list("gridListReq", map, "setup")
    -- Fetch the map's saved presets too (ADR-0037 amendment), routed back to the panel by handle_preset_list.
    setup.request_list("presetListReq", map)
end

-- Open the race-setup panel on the relayed setupOpen (ADR-0037): push the current dataset (refreshes an
-- already-open panel) and make the app visible. A freshly-added app links *after* this push, so the panel
-- also pulls the dataset itself on link via request_setup_data -- the two together cover every timing.
local function handle_setup_open(payload)
    -- Remember the server's own defaults BEFORE the push that carries them on (see push_setup_data).
    -- Taken as one opaque table: GE relays it and reads no key, so a server that adds one needs nothing
    -- here. A payload without it clears the field on purpose -- the message carries the whole truth, and
    -- a server that names no defaults must not leave the previous server's numbers standing.
    local defaults = type(payload) == "table" and payload.serverDefaults or nil
    M.state.server_defaults = type(defaults) == "table" and defaults or nil
    -- Which row of the player list is this client (identity.own_id). The server names it here because
    -- the list itself goes out as one broadcast to everybody; a payload without it leaves the field nil
    -- and the fallback answers instead.
    M.state.own_player_id = type(payload) == "table" and tonumber(payload.yourPlayerId) or nil
    -- Re-stamp the list we already hold: on a FRESH open the panel pulls it itself on link, but a
    -- /raceui into an ALREADY open panel links nothing, and the list cached before this message knows
    -- nothing about the id that just arrived.
    identity.push_players()
    push_setup_data(false)
    -- Ensure the panel app is on the current layout (ADR-0012 best-effort auto-add); dedups by appName.
    M.uilayout.ensure_visible("beamCompSetup")
    -- A normal open is BY DEFINITION an authorized open -- the server sends setupOpen only downstream of
    -- its admin check -- so it also lifts the lock (ADR-0056). Clearing it here as well as in the unlock
    -- verdict is what makes the unlock order-independent: whichever of the two messages lands first, the
    -- panel ends up unlocked.
    M.state.setup_locked = false
    setup.push_lock()
    -- Remember this (server-authorized) open, so a UI reload that drops the app can be recovered once.
    setup.arm()
    -- Auto-minimize the final standings card so the opening panel has a clear view. Only visible in the
    -- finished phase (the snapshot gates it), so this is inert otherwise; manual restore via
    -- M.toggle_results_min and the per-race reset (driving-phase start) stay the counter-force.
    M.state.results_min = true
end

-- ===== race-setup panel password lock (ADR-0056) ==================================================
-- A server with a racePassword answers /raceui from a non-admin with setupLocked instead of a refusal:
-- the panel opens showing only a password box, the player submits, and the server either grants him
-- race admin for the rest of his connection or refuses.
--
-- GE is a relay here and decides nothing. The lock state is set only by a server message, the password
-- is passed through without being kept or logged, and the verdict's wording is left to the panel. Two
-- functions on the existing `setup` namespace rather than two new top-level locals -- init.lua sits at
-- LuaJIT's 200-local ceiling. Both are assigned above the HANDLERS table, which reads them at load.

-- The client -> server message type carrying a password attempt. A field rather than a literal because
-- send_to_server has to recognise it too, to keep its payload-size instrumentation off this one message
-- (see there) -- and two copies of the string is exactly how that exemption would quietly stop matching.
setup.MSG_UNLOCK = "raceUnlock"

-- Tell the panel whether it is locked. Also the answer to its link-time pull: a freshly-added app links
-- AFTER the open-time push, exactly as with the setup dataset, so the panel asks for this itself too.
function setup.push_lock()
    guihooks.trigger("BeamCompSetupLock", {locked = M.state.setup_locked})
end

-- Open the panel in its LOCKED state (server -> client, setupLocked). Deliberately does not push the
-- setup dataset: the panel pulls what it needs on link, and withholding it would buy nothing anyway --
-- the same data is broadcast to every client. The presence watchdog is armed exactly as for a normal
-- open, so a locked panel lost to a UI reload comes back locked.
function setup.handle_locked(_payload)
    M.uilayout.ensure_visible("beamCompSetup")
    M.state.setup_locked = true
    setup.push_lock()
    setup.arm()
end

-- The server's verdict on a password attempt (server -> client, unlockResult). On success the server
-- also sends the normal open, which fills the panel and clears the lock on its own -- doing it here as
-- well is what makes the two messages order-independent. The payload's numbers (triesLeft, wait) are
-- relayed verbatim; the panel words them.
function setup.handle_result(payload)
    if type(payload) == "table" and payload.ok then
        M.state.setup_locked = false
        setup.push_lock()
    end
    guihooks.trigger("BeamCompSetupUnlock", payload or {})
end

-- Submit a password attempt (UI -> GE, ADR-0056). Public as beamcomp_init.submit_setup_password.
--
-- The string is forwarded and forgotten: never stored in M.state, never written to the setup form (which
-- GE remembers and the server persists as a preset), and NEVER logged -- not the value, not its length,
-- not even on a failure. The server logs who tried, which is the part an operator needs.
function M.submit_setup_password(password)
    if type(password) ~= "string" or password == "" then
        return
    end
    send_to_server(setup.MSG_UNLOCK, {password = password})
end

-- Push the lock state on demand (UI -> GE): the panel's link-time pull. Public as
-- beamcomp_init.request_setup_lock.
function M.request_setup_lock()
    setup.push_lock()
end

-- Ask the SERVER to open this client's race-setup panel (UI -> GE -> server, feature
-- raceui-reopen-without-typing). Public as beamcomp_init.open_race_setup so the final-standings card's
-- "Race setup" button reaches it via bngApi.engineLua, exactly like M.toggle_analysis.
--
-- It asks; it does not open. Opening the panel from here would need the things only a server message
-- brings (the server-owned defaults, this connection's player id, the lock state), and ADR-0037's
-- panel is an admin-gated open for a reason -- so this is a second SENDER in front of the /raceui
-- path, nothing more. The server answers it through handle_raceui_command, i.e. through the very
-- same gate (ADR-0056).
--
-- Deliberately NO local permission check. The client's one reading of the server's statement is the
-- button's visibility (build_hud_snapshot); asking it a second time here would be a second place that
-- could disagree with the server, and it would buy nothing -- the gate is server-side and re-answers this
-- message on arrival. A forced call therefore lands exactly where typing /raceui lands.
--
-- Not a toggle (user decision 6): a second press re-opens and re-fills, which is what a second /raceui
-- does today. The panel's own Close stays the only way to shut it.
function M.open_race_setup()
    log("I", RACE_LOG_TAG, "asking the server to open the race-setup panel")
    send_to_server("setupReopen", {})
end

-- Push the dataset on demand (UI -> GE, ADR-0037): the panel calls this on link -- so a freshly-added app
-- that missed the open-time push still fills -- and from its Refresh / include-deprecated toggle. The arg
-- is the toggle's string flag ("1" = include deprecated races in the list). Public as
-- beamcomp_init.request_setup_data.
function M.request_setup_data(include_flag)
    push_setup_data(include_flag == "1")
end

-- Remember the race-setup panel's form (UI -> GE, ADR-0037): a JSON string the panel sends on close, so the
-- next open restores the last race's settings within the session. Stored opaquely (the panel owns the
-- shape); a non-string is ignored. Public as beamcomp_init.store_setup_form.
function M.store_setup_form(json)
    if type(json) == "string" and json ~= "" then
        M.state.setup_form = json
    end
end

-- Push the remembered race-setup form to the panel (UI -> GE, ADR-0037): the panel pulls it once on link to
-- restore the last settings; nil when nothing has been stored this session (the panel keeps its defaults).
-- Public as beamcomp_init.request_setup_form.
function M.request_setup_form()
    guihooks.trigger("BeamCompSetupForm", {form = M.state.setup_form})
end

-- ===== the setup panel's build record (feature setup-confirm-grid-stale-hint) ======================
-- Which race request the staged grid was built from, so the setup panel can point at Confirm & Build
-- Grid when its settings have moved on since (ADR-0037 amendment 2026-10-06). Start Race only ends the
-- staging of the race that is already built, so a setting changed after the build silently does
-- nothing -- this is what makes that visible. The panel decides nothing about attribution: it is handed
-- a request or nil and compares. Whether the staged race was built from the panel at all is decided here.
--
-- The tie is the pre-flight handshake (ADR-0019). Every race request this client issues -- from the
-- panel or typed as /race -- comes back to THIS client as exactly one validateRace before any raceStart
-- can carry propOwner for it, and the server starts no race that did not pass one. So the panel's
-- request is matched to the validateRace that comes back for it, and only a validated request is
-- promoted by the propOwner raceStart of its race. A typed /race in between never inherits it: its own
-- validateRace does not match and drops the request. Every doubt ends in nil, and nil means no hint --
-- the one direction that cannot claim anything false about a grid.

setup.LOG_TAG = "beamcomp.setup"

-- Hand the panel the request the staged grid was built from, verbatim (nil = not known, no hint). Also
-- the answer to the panel's link-time pull, since a freshly-added app misses every earlier push.
function setup.push_build()
    if guihooks then
        guihooks.trigger("BeamCompSetupBuild", {request = M.state.setup_built})
    end
end

-- Forget the staged grid's request. Logs and pushes only when one was remembered, so every lobby
-- after a race this panel did not build stays silent.
function setup.forget_build(reason)
    if M.state.setup_built == nil then
        return
    end
    M.state.setup_built = nil
    log("I", setup.LOG_TAG, "staged grid forgotten: " .. reason)
    setup.push_build()
end

-- Drop the Confirm that has not become a race yet. The staged grid is untouched: whatever stands is
-- still what the last promoted request built.
function setup.drop_request(reason)
    local request = M.state.setup_request
    if not request then
        return
    end
    M.state.setup_request = nil
    log("I", setup.LOG_TAG, string.format("grid request for '%s' dropped: %s", tostring(request.race),
        reason))
end

-- Confirm & Build Grid sent `json`, which `decoded` is the table of. A newer Confirm replaces a request
-- still on its way -- it is the one the panel shows. The SAME request again (a double click) is counted
-- instead: each send gets its own validateRace from the server and can become its own race, and starting
-- over would let the second check drop the first one's record.
function setup.note_request(json, decoded)
    log("I", setup.LOG_TAG, string.format("grid request sent for '%s'", decoded.race))
    local request = M.state.setup_request
    if request and request.json == json then
        request.sends = request.sends + 1
        return
    end
    M.state.setup_request = {
        json = json,
        race = decoded.race,
        overrides = type(decoded.overrides) == "table" and decoded.overrides or {},
        validated = false,
        sends = 1,
    }
end

-- A lap count the way the server's sanitize_overrides leaves it (whole, at least 1), so a value the
-- server rounds on the way still matches the request it came from.
function setup.lap_count(value)
    local laps = tonumber(value)
    return laps and math.max(1, math.floor(laps)) or nil
end

-- Whether a validateRace is the check of `request`. Compares the fields the server relays back in it, so
-- a typed /race for the same track still differs in practice: the panel always names the track's mode,
-- a typed race rarely does. A false "no" costs one hint; a false "yes" would cost a true one.
function setup.same_request(request, payload)
    local overrides = request.overrides
    local ai = type(overrides.ai) == "table" and overrides.ai or {}
    return payload.race == request.race
        and payload.mode == overrides.mode
        and payload.direction == overrides.direction
        and payload.laps == setup.lap_count(overrides.laps)
        and payload.car == overrides.car
        and payload.aiCar == ai.car
        and (payload.force == true) == (overrides.force == true)
        and (payload.all == true) == (overrides.all == true)
end

-- The server's pre-flight check of a request from THIS client, with our own verdict on it (ADR-0019).
-- A check that does not match the Confirm is something else this client asked for -- a typed /race --
-- which is now ahead of it on the server, so the Confirm can no longer be told apart from it. A matching
-- one is the Confirm's own (or its double click's).
function setup.note_validation(payload, ok)
    local request = M.state.setup_request
    if not request or type(payload) ~= "table" then
        return
    end
    if not setup.same_request(request, payload) then
        setup.drop_request("another race request from this client")
        return
    end
    if not ok then
        setup.drop_request("refused by the race check")
        return
    end
    request.validated = true
end

-- A race has started and this client resolved it. It was built from the panel exactly when it is ours
-- (propOwner: this client issued it) and our validated request is for this race; anything else -- another
-- admin's race, a typed /race -- leaves the panel without knowledge of the grid, so it says nothing.
-- A request not validated yet is kept: this race cannot be it, and it can still become the next one.
function setup.note_race_start(payload)
    local request = M.state.setup_request
    if payload.propOwner == true and request and request.validated and request.race == payload.race then
        -- One race per send: a double click's second send may still start a race of its own.
        request.sends = request.sends - 1
        if request.sends <= 0 then
            M.state.setup_request = nil
        end
        M.state.setup_built = request.json
        log("I", setup.LOG_TAG, string.format("staged grid remembered as built from the panel ('%s')",
            request.race))
        setup.push_build()
        return
    end
    setup.forget_build("this race was not built from the panel")
end

-- Push the staged grid's request on demand (UI -> GE): the panel's link-time pull. Public as
-- beamcomp_init.request_setup_build.
function M.request_setup_build()
    setup.push_build()
end
-- ===== end the setup panel's build record ==========================================================

-- Save the current race-setup form as a named, map-scoped preset (UI -> GE -> server, ADR-0037 amendment).
-- The panel serialises its form minus the tournament/championship fields and passes {name, form}; GE relays
-- the opaque blob with the current map. Public as beamcomp_init.save_preset. A bad payload is dropped.
function M.save_preset(json)
    local ok, decoded = pcall(jsonDecode, json)
    if not ok or type(decoded) ~= "table"
        or type(decoded.name) ~= "string" or decoded.name == ""
        or type(decoded.form) ~= "string" or decoded.form == "" then
        log("W", RACE_LOG_TAG, "save_preset: bad payload")
        return
    end
    local map = maps.current()
    if not map then
        log("W", RACE_LOG_TAG, "save_preset: no map loaded")
        return
    end
    send_to_server("presetSave", {map = map, name = decoded.name, form = decoded.form})
end

-- Load a saved preset by name (UI -> GE -> server, ADR-0037 amendment): request its form blob; the server's
-- presetData reply is applied to the panel by handle_preset_data. Public as beamcomp_init.load_preset.
function M.load_preset(name)
    if type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        log("W", RACE_LOG_TAG, "load_preset: no map loaded")
        return
    end
    send_to_server("presetFetch", {map = map, name = name})
end

-- Delete a saved preset by name (UI -> GE -> server, ADR-0037 amendment): the server echoes the updated
-- name list (handle_preset_list), so the dropdown refreshes itself. Public as beamcomp_init.delete_preset.
function M.delete_preset(name)
    if type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        log("W", RACE_LOG_TAG, "delete_preset: no map loaded")
        return
    end
    send_to_server("presetDelete", {map = map, name = name})
end

-- Request the current map's saved preset names (UI -> GE -> server, ADR-0037 amendment): the panel calls
-- this to refresh its dropdown; the reply routes back via handle_preset_list. Public as
-- beamcomp_init.request_presets.
function M.request_presets()
    local map = maps.current()
    if not map then
        return
    end
    setup.request_list("presetListReq", map)
end

-- Re-resolve the CARS of an existing roster (the "cars" mode of roll_ai_roster, ADR-0047 live amendment):
-- one entry per requested name, in the requested order, carrying {name, car, carLabel} and deliberately NO
-- colour -- a colour belongs to the driver, not to the AI-car settings that trigger this roll.
--
-- Each name goes through ai.resolve_pick, the PINNED-name resolver behind the panel's name pick, because it
-- shares entry_from_drawn with roll_roster_entries: the car a name gets here is exactly the car a fresh
-- create would give it, including the driver's file-preferred car under the default AI-car mode (ADR-0048).
-- Rolling each car with reroll_ai_car's helper instead would NOT do -- that path is a MANUAL override that
-- deliberately bypasses the preferred car (see below), so switching the panel's AI car back to "default"
-- would hand out random cars.
--
-- Hangs off the `setup` namespace table rather than being a top-level local: init.lua sits at 187/200
-- (memory beamcomp-200-local-ceiling).
function setup.roster_cars(names, config, policy)
    local entries = {}
    if type(names) ~= "table" then
        return entries
    end
    for k, name in ipairs(names) do
        -- The same 16-AI ceiling the count branch below clamps to: one roll can never cost more work
        -- than a full create, whatever a caller hands in.
        if #entries >= 16 then
            break
        end
        if type(name) == "string" and name ~= "" then
            local entry = ai.resolve_pick(name, config, policy)
            entries[#entries + 1] = {name = name, car = entry.car, carLabel = entry.carLabel}
        else
            log("W", RACE_LOG_TAG, "roll_ai_roster: skipping unnamed roster entry " .. tostring(k))
        end
    end
    return entries
end

-- Roll a named-AI roster for the setup panel (UI -> GE, ADR-0047/0048). Payload JSON:
-- {token, count, mode = "create"|"extend"|"cars", exclude = [names], names = [names] (cars mode),
-- ai = {car?, randomTrim, noBigCars}, policy = {car?, maxhp?, maxpwr?, maxkg?, minkg?, randomTrim?,
-- noBigCars?}}. Names draw from the mod-bundled driver file (the single pool source, ADR-0048) without
-- replacement; each entry's car resolves through the SAME chain the spawn uses (race/ai.lua), so the shown
-- car IS the spawned car. "cars" re-rolls an existing roster's cars in place (see setup.roster_cars above).
--
-- `token` is the panel's request id, echoed back untouched: these replies ride guihooks with no correlation,
-- and the panel now rolls automatically on a settings change, so overlapping rolls and a reply landing after
-- the admin unticked the box are real. The panel applies only its newest request's reply.
-- Result pushed via BeamCompAiRoster. Public as beamcomp_init.roll_ai_roster.
function M.roll_ai_roster(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" then
        log("W", RACE_LOG_TAG, "roll_ai_roster: bad payload")
        return
    end
    if request.mode == "cars" then
        guihooks.trigger("BeamCompAiRoster", {
            token = request.token,
            mode = "cars",
            entries = setup.roster_cars(request.names, request.ai, request.policy),
        })
        return
    end
    local count = math.max(1, math.min(16, math.floor(tonumber(request.count) or 1)))
    -- excludeColors keeps an extend distinct from the kept entries' colours (ADR-0047 round 3); nil on a
    -- fresh create (nothing to exclude).
    local entries = ai.roll_roster_entries(count, request.exclude, request.ai, request.policy,
        request.excludeColors)
    guihooks.trigger("BeamCompAiRoster", {
        token = request.token,
        mode = request.mode == "extend" and "extend" or "create",
        entries = entries,
    })
end

-- Re-draw one roster entry's name (UI -> GE, ADR-0047): payload {index, exclude, ai, policy}. When the
-- drawn name carries a preferred car that applies (nothing else names a car, restrictions pass), the car
-- rides the reply too -- decision 4's "they always get it". The policy goes into preferred_applies for the
-- same reason entry_from_drawn passes it: a forced Car (all) beats the driver file (ADR-0048 amendment
-- 2026-09-28), and omitting it here would leave this one path handing out preferred cars silently.
-- Result pushed via BeamCompAiRosterName. Public as beamcomp_init.reroll_ai_name.
function M.reroll_ai_name(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" or tonumber(request.index) == nil then
        log("W", RACE_LOG_TAG, "reroll_ai_name: bad payload")
        return
    end
    local drawn = ai.draw_roster_names(1, request.exclude)[1]
    local reply = {index = tonumber(request.index), name = drawn.name}
    if drawn.preferred and ai.preferred_applies(request.ai, request.policy)
            and ai.preferred_car_compliant(drawn.preferred, request.ai, request.policy) then
        reply.car = drawn.preferred
        reply.carLabel = ai.car_label(drawn.preferred)
    end
    -- A drawn pool name's preferred colour ALWAYS rides along (ADR-0047 round 3): colour is unrestricted,
    -- so unlike the car there is no compliance gate.
    if drawn.preferredColor then
        reply.color = drawn.preferredColor
    end
    guihooks.trigger("BeamCompAiRosterName", reply)
end

-- Load a specific PINNED driver's car + colour for a roster entry (UI -> GE, ADR-0048): payload
-- {index, name, ai, policy}. Unlike reroll_ai_name (a random draw), this resolves the NAMED driver's file
-- entry via ai.resolve_pick -- default AI-car mode -> the driver's preferred car + colour; random mode -> a
-- freshly rolled car + the driver's preferred colour (Q3: only the car varies by mode). The reply always
-- carries a concrete car + colour, so the panel OVERWRITES any prior manual selection for that row (Q2).
-- Result pushed via the shared BeamCompAiRosterName path. Public as beamcomp_init.pick_ai_name.
function M.pick_ai_name(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" or tonumber(request.index) == nil
            or type(request.name) ~= "string" or request.name == "" then
        log("W", RACE_LOG_TAG, "pick_ai_name: bad payload")
        return
    end
    local entry = ai.resolve_pick(request.name, request.ai, request.policy)
    guihooks.trigger("BeamCompAiRosterName", {
        index = tonumber(request.index),
        name = entry.name,
        car = entry.car,
        carLabel = entry.carLabel,
        color = entry.color,
    })
end

-- Re-roll one roster entry's car (UI -> GE, ADR-0047): payload {index, ai, policy}. An explicit re-roll
-- is a manual override, so it deliberately bypasses the name's preferred car (which would pin the button
-- to one result). Result pushed via BeamCompAiRosterCar. Public as beamcomp_init.reroll_ai_car.
function M.reroll_ai_car(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" or tonumber(request.index) == nil then
        log("W", RACE_LOG_TAG, "reroll_ai_car: bad payload")
        return
    end
    local index = tonumber(request.index)
    local car = ai.roll_roster_car(request.ai, request.policy, index + 1)
    guihooks.trigger("BeamCompAiRosterCar", {index = index, car = car, carLabel = ai.car_label(car)})
end

-- Vet a RESTORED roster's cars and re-roll the ones that are no longer race cars (UI -> GE, ADR-0047
-- amendment 2026-08-09): payload {token, entries = [{name, car}], ai, policy}. The panel calls this from
-- applyStoredForm, i.e. on every session restore and preset load, because a preset saved before the
-- vehicle filter can carry a token for a model BeamComp no longer offers (a simplified-traffic car being
-- the case that prompted this).
--
-- GE is the arbiter on purpose. The panel's own valid-model list (scope.opts.rosterCar) is filled
-- asynchronously from carlist.options, so a panel-side check could run against an empty list and
-- "repair" a perfectly good roster; core_vehicles is readable here and now, so there is no window in
-- which the answer can be wrong. The reply carries only the CHANGED rows, each with the `from` token that
-- was vetted, so the panel can refuse to overwrite a row the admin edited in the meantime. `token` is
-- echoed untouched for the same last-request-wins rule the roll replies use.
-- Result pushed via BeamCompAiRosterRepair. Public as beamcomp_init.repair_ai_roster.
function M.repair_ai_roster(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" then
        log("W", RACE_LOG_TAG, "repair_ai_roster: bad payload")
        return
    end
    local entries = ai.repair_roster_cars(request.entries, request.ai, request.policy)
    -- Silence is the answer for a healthy roster, which is the overwhelmingly common case: nothing to
    -- apply, and an EMPTY Lua table crosses the CEF bridge as a JSON object ({}), not an array -- so not
    -- sending it also keeps the panel from ever seeing a non-iterable `entries`.
    if #entries == 0 then
        return
    end
    guihooks.trigger("BeamCompAiRosterRepair", {token = request.token, entries = entries})
end

-- Build the grid-editor panel's option dataset and push it to the app (ADR-0037 amendment): every race on
-- the current map (deprecated included -- a grid can be authored for any race) and the race to pre-seed
-- (carried from the race-setup panel's cross-open), plus an async request for the map's saved grids (routed
-- back to the panel by handle_grid_list). Used on open and on the panel's own pull/refresh.
local function push_grid_data()
    local map = maps.current()
    guihooks.trigger("BeamCompGridData", {
        races = racelist.options(map, true),
        seedRace = M.state.grid_seed_race,
    })
    setup.request_list("gridListReq", map, "gridui")
    -- Reflect the live edit session too, so a reopened panel (its Angular scope is fresh) restores the
    -- active grid's knobs, direction and overwrite/assign target rather than showing a blank form.
    push_grid_state()
end

-- Open the grid-editor panel on the relayed gridSetupOpen (/gridui, ADR-0037 amendment): no carried race,
-- so clear any stale seed, push the dataset, and make the app visible. A freshly-added app links after this
-- push, so the panel also pulls on link via request_grid_data -- together they cover every timing.
local function handle_grid_setup_open(_payload)
    M.state.grid_seed_race = nil
    push_grid_data()
    -- Re-spawn the reference scene if a session is still active on open (e.g. one started from the GE
    -- console) -- its props are otherwise only spawned when the session begins.
    refresh_grid_edit_scene()
    M.uilayout.ensure_visible("beamCompGridEditor")
end

-- Pull the grid-editor dataset on demand (UI -> GE): the panel calls this once, on link -- it covers the
-- freshly-added app that missed the open push, and together with that push and the server's echo after a
-- save/delete it is every timing there is. Public as beamcomp_init.request_grid_data.
function M.request_grid_data()
    push_grid_data()
end

-- Open the grid-editor panel pre-seeded with `race` (UI -> GE): the race-setup panel's "Grid bearbeiten"
-- button calls this so the grid editor starts on the race chosen there. Does not start an edit session --
-- the admin still picks New / Load. The seed persists across the panel's on-link pull; the panel applies it
-- only while its race choice is still empty, so a later push never overrides a manual pick. Public as
-- beamcomp_init.open_grid_editor_with_race.
function M.open_grid_editor_with_race(race)
    M.state.grid_seed_race = (type(race) == "string" and race ~= "") and race or nil
    push_grid_data()
    refresh_grid_edit_scene()
    M.uilayout.ensure_visible("beamCompGridEditor")
end

-- Start a fresh grid for `race` from the track's generated default (UI -> GE) and reflect the new session.
function M.grid_open_new(race)
    if type(race) ~= "string" or race == "" then
        editor_feedback("pick a race first", "warning")
        return
    end
    local ok, reason = grideditor.start_fresh(race)
    if not ok then
        editor_feedback(tostring(reason), "warning")
        return
    end
    -- A fresh grid has no saved name yet -- it must be Saved before it can be overwritten or assigned.
    M.state.grid_active_name = nil
    refresh_grid_edit_scene()
    push_grid_state()
end

-- Request a saved grid's data so the editor opens it (UI -> GE); handle_grid_data opens + reflects on reply.
-- `race` is the race the grid BELONGS to (its store key, ADR-0023 amendment) -- the name alone no longer
-- identifies a grid. `anchor_race` (the panel's selected race) re-targets the grid's relative params onto
-- that race's start line, which is how a finished layout is copied onto another track: saving it there
-- moves the grid to that race. Remembered until the reply arrives.
function M.grid_open_saved(race, name, anchor_race)
    if type(race) ~= "string" or race == "" or type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    M.state.grid_load_anchor = (type(anchor_race) == "string" and anchor_race ~= "") and anchor_race or nil
    send_to_server("gridFetch", {map = map, race = race, name = name})
end

-- Set one knob on the active SEGMENT (UI -> GE) and reflect the clamped result back to the panel.
function M.grid_set(knob, value)
    local ok, applied_or_reason = grideditor.set(knob, value)
    if not ok then
        editor_feedback(tostring(applied_or_reason), "warning")
        return
    end
    push_grid_state()
end

-- Select (or create) the segment starting at `start_slot` as the active one (UI -> GE, ADR-0023
-- amendment) and reflect. A new breakpoint is seeded from the covering segment's params; the knobs then
-- edit it. Slot 0 selects the base segment.
function M.grid_select_segment(start_slot)
    local ok, applied_or_reason = grideditor.select_segment(start_slot)
    if not ok then
        editor_feedback(tostring(applied_or_reason), "warning")
        return
    end
    push_grid_state()
end

-- Remove the active breakpoint, merging its slots back into the previous segment (UI -> GE) and reflect.
function M.grid_remove_segment()
    local ok, reason = grideditor.remove_segment()
    if not ok then
        editor_feedback(tostring(reason), "warning")
        return
    end
    push_grid_state()
end

-- Switch the edited block to forward/reverse (UI -> GE) and reflect; a race with no reverse geometry warns.
-- The reference scene (props + first checkpoint) is direction-specific, so refresh it too.
function M.grid_set_direction(direction)
    local ok, reason = grideditor.set_direction(direction)
    if not ok then
        editor_feedback(tostring(reason), "warning")
        return
    end
    refresh_grid_edit_scene()
    push_grid_state()
end

-- Put the camera back above slot 1 of the grid being edited (UI -> GE, the panel's Camera to grid,
-- ADR-0063). Never during a race. The admin just pressed a button, so a refusal is said out loud instead
-- of leaving him with a camera that did nothing.
function M.grid_camera_to_grid()
    local ok, reason = M.gridcam.to_grid(grideditor.state, M.state.race ~= nil, "button")
    if not ok then
        editor_feedback(tostring(reason), "warning")
    end
end

-- Set how many slots the preview shows (UI -> GE) and reflect.
function M.grid_set_preview(count)
    local ok, reason = grideditor.set_preview_count(count)
    if not ok then
        editor_feedback(tostring(reason), "warning")
        return
    end
    push_grid_state()
end

-- Save the active grid under `name` (UI -> GE -> server, ADR-0023). Mirrors beamcomp_grid_save's guards: a
-- name is required and may not contain whitespace (it must be selectable via /race grid=<name>).
function M.grid_save(name)
    if type(name) ~= "string" or name == "" then
        editor_feedback("enter a grid name", "warning")
        return
    end
    if name:find("%s") then
        editor_feedback("grid name must not contain spaces", "warning")
        return
    end
    local snapshot = grideditor.snapshot(name)
    if not snapshot then
        editor_feedback("not editing -- start or load a grid first", "warning")
        return
    end
    send_to_server("gridSave", snapshot)
    -- This name is now the active grid's saved target (overwrite + assign without retyping).
    M.state.grid_active_name = name
    push_grid_state()
    editor_feedback("saving grid '" .. name .. "' ...")
end

-- Make a saved grid the default of `race` (UI -> GE -> server, ADR-0023). Since a grid belongs to a race,
-- the panel always passes the ACTIVE grid's own race here -- there is no cross-race assignment any more.
-- The race is resolved to its canonical id client-side (race_start.resolve_id, idempotent on an id),
-- exactly like beamcomp_grid_assign.
function M.grid_assign(race, name)
    if type(race) ~= "string" or race == "" or type(name) ~= "string" or name == "" then
        editor_feedback("save (or load) a grid first", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    local race_id, reason = race_start.resolve_id(race)
    if not race_id then
        editor_feedback(tostring(reason), "warning")
        return
    end
    send_to_server("gridAssign", {map = map, race = race_id, name = name})
    editor_feedback("assigning '" .. name .. "' as default for " .. race_id .. " ...")
end

-- Delete one of `race`'s saved grids (UI -> GE -> server, ADR-0023). The server echoes the updated grid
-- list unasked, so both panels refresh themselves -- no destination is named here (see handle_grid_list).
function M.grid_delete(race, name)
    if type(race) ~= "string" or race == "" or type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    send_to_server("gridDelete", {map = map, race = race, name = name})
    editor_feedback("deleting grid '" .. name .. "' ...")
end

-- Close the grid-editor panel (UI -> GE): END the edit session, then hide the app. Close is now a clean
-- teardown -- it runs the shared clear (grideditor.clear + grid_active_name = nil), which also drops the
-- reference props and the preview, then removes the panel, so a reopen starts empty at "pick a race".
-- A grid you want to keep across a close must be Saved first: there is no reopen-restore. (The old
-- "keep the session alive on close" behaviour was reversed 2026-07-23, folding the standalone Clear
-- button's teardown into Close/New/Load.)
function M.close_grid_editor()
    M.state.grid_seed_race = nil
    -- Reuse the full teardown primitive (session + name + props + checkpoint + reflect); no duplication.
    M.clear_grid_editor()
    -- The end of the visit: the camera goes back to where it was before the first jump (ADR-0063).
    M.gridcam.leave("close")
    M.uilayout.remove("beamCompGridEditor")
end

-- Clear the grid-editor session (GE): end editing, drop the preview pillars + reference props, and reflect
-- the now-empty state so the panel returns to its "pick a race" start. The panel stays open. This is the
-- shared teardown primitive -- Close reuses it (and then removes the panel).
-- Deliberately does NOT give the camera back (ADR-0063): this looks like the end of a session and is not
-- one. The camera follows Close and the other exits in gridcam's EXITS table, never this primitive alone.
function M.clear_grid_editor()
    grideditor.clear()
    M.state.grid_active_name = nil
    refresh_grid_edit_scene()
    push_grid_state()
end

-- ===== the controls window (ADR-0061) =============================================================
-- /keys opens (and a second /keys closes) a window that draws where BeamComp's two in-race assists are
-- bound, on every device, with the game's own binding glyphs -- and jumps into BeamNG's binding dialog on
-- a click. GE owns nothing but the on/off state: the app reads the bindings from BeamNG's own
-- InputBindingsChanged broadcast and never asks GE for data.
--
-- Everything here is a field on M, not a top-level local: init.lua sits at LuaJIT's 200-local ceiling
-- (182/200 measured 2026-09-23) and a plain `local function` here would spend one of the eighteen left.

-- Open or close the window. Called by the server's controlsOpen relay (/keys) and by nothing else --
-- the X inside the window goes to M.close_controls, so both paths flip the same flag and can never
-- disagree about what a second /keys means.
--
-- M.state.controls_open does NOT survive a GE Lua reload (ADR-0052) and is not made to: after one it
-- reads false while the window is still on the layout, so the next /keys re-adds it (ensure_visible
-- dedups by appName, so nothing visible happens) and the one after that closes it. One wasted command
-- after a reload, against no new serialization contract -- deliberately the cheaper side.
function M.toggle_controls()
    if M.state.controls_open then
        M.close_controls()
        return
    end
    M.state.controls_open = true
    -- Through the seam, never at the layout file: a call the player's HUD-apps menu would swallow is
    -- recorded and replayed by M.uilayout.step, not dropped (bug ui-glitches-after-ingame-menu-resize).
    M.uilayout.ensure_visible("beamCompControls")
    log("I", "beamcomp.ui", "controls window shown")
end

-- Close the window. Public so its own X can reach it as beamcomp_init.close_controls (UI -> GE,
-- ADR-0012), and the toggle's close half.
function M.close_controls()
    M.state.controls_open = false
    -- A window closed mid-capture would otherwise leave the player with dead controls: the app is gone,
    -- so nothing on that side can undo it any more (see release_input_capture). No-op when not armed.
    M.release_input_capture()
    M.uilayout.remove("beamCompControls")
    log("I", "beamcomp.ui", "controls window hidden")
end

-- One log line from the controls window (UI -> GE). The window's two engine touchpoints -- the game's own
-- <binding> directive and its binding-edit route -- both fail SILENTLY when a BeamNG version moves them,
-- so the app probes each and reports which case it landed in. This is the only place that report becomes
-- visible; the tag matches race/uilayout.lua's, since both are about the app surface.
--
-- The app reaches this by name through bngApi, which is why it is a plain M field and why the tag lives
-- here instead of in the app: an app that could pass its own log tag could pass anything.
function M.note_controls(msg)
    log("I", "beamcomp.ui", "controls window: " .. tostring(msg))
end

-- ----- the input capture's safety exit (round 3, 2026-09-24) ---------------------------------------
-- THE ONE PROMISE THIS FEATURE HAS TO KEEP.
--
-- Rebinding a key means asking the engine to capture the next input. `window.bngVue.controls
-- .captureBinding` does that by switching THREE things on globally: ActionMap.enableBindingCapturing
-- (so a keypress no longer runs its action -- otherwise ESC would close the menu mid-capture),
-- Input.setForwardRawEvents and setCEFTyping. While they are on, the player's controls are DEAD, and in
-- BeamComp that can be a rolling car mid-race.
--
-- The engine turns them off again in exactly one place: the capture's own stopListening(), which runs
-- ONLY when a valid input arrives (ui-vue/src/services/controls.js:498-511). The handle to call it
-- early -- `_captureHelper` -- is module-local and NOT on the exposed store (ui-vue/src/main.js:244).
-- There is no cancel. So the way out has to be ours, and it has to hold for every way a capture can end
-- badly: the player cancels, he closes the window, the app is torn down, GE reloads its Lua.
--
-- The levers are the same three calls, and they are reachable from Lua -- BeamNG's own (old) options UI
-- restores them exactly like this on $destroy (ui/modules/options/options.js:2359). Doing it HERE rather
-- than in the app is what covers the last two cases: an app that is gone cannot run its own cleanup,
-- and a GE Lua reload runs onExtensionUnloaded, which can.
--
-- The armed flag is what keeps this from being a blunt instrument: a release that fires when we never
-- armed would switch off a capture somebody else started. It is checked and cleared HERE, not at the
-- call sites -- one chokepoint is a property, a list of callers that remember to check is a claim.
-- M.state.input_capture not surviving a GE Lua reload (ADR-0052) is harmless in the only direction that
-- matters: onExtensionUnloaded runs BEFORE the state is rebuilt, so the release still sees the flag.

-- The app is about to call captureBinding. From here on the three switches are presumed on.
function M.arm_input_capture()
    M.state.input_capture = true
    log("I", "beamcomp.ui", "controls window: input capture armed")
end

-- Give the player his controls back. A no-op unless we armed, so it can be called from anywhere that
-- might be the end of a capture without having to know whether one is running.
--
-- Each call is on its own pcall: these are engine globals, and one missing on some build must not cost
-- the other two -- being left with raw-event forwarding on is survivable, being left with every input
-- swallowed is not.
function M.release_input_capture()
    if not M.state.input_capture then
        return false
    end
    M.state.input_capture = false
    local ok_actions = pcall(function() ActionMap.enableBindingCapturing(false) end)
    local ok_raw = pcall(function() Input.setForwardRawEvents(false) end)
    local ok_typing = pcall(function() setCEFTyping(false) end)
    log("I", "beamcomp.ui", string.format(
        "controls window: input capture released (bindingCapturing=%s rawEvents=%s cefTyping=%s)",
        tostring(ok_actions), tostring(ok_raw), tostring(ok_typing)))
    return true
end

-- ----- the jump into the key bindings (round 2, 2026-09-24) ---------------------------------------
-- WHERE THE CLICK ON A KEY LEADS, AND WHY IT IS NOT THE ROUTE IT USED TO BE.
--
-- Round 1 jumped to `menu.options.controls.bindings.edit`, copied from BeamNG's own Keys app
-- (ui/modules/apps/Keys/app.js:43). Measured in-game: that lands in the OLD Angular dialog, while a
-- player who walks there himself sees the NEW options UI. The route is one of the legacy Angular
-- router's (ui/entrypoints/main/main.js:393); that the game's own app still uses it says when that app
-- was written, not where the game goes today.
--
-- The new UI is driven by the LUA router: ui/router/routes/options.lua declares the options branch
-- uiTypes = {"vue"} / uiTypesFilter = only, and a route name the Lua router does not know falls through
-- to the legacy host -- exactly what was seen. There is NO deep link onto a single action in the new UI:
-- its edit dialog is a popup opened from the bindings list's own click handlers
-- (ui-vue/.../options/controls/Bindings.vue runEditBindingPopup), and the store's `selectedBinding` is
-- set, never watched. The reachable target is therefore the CATEGORY, and the controls category has
-- exactly one subpage -- the bindings list (ui-vue/src/modules/options/runtime/layout.json, items[8]:
-- categoryId "controls", subpage "ControlsBindings"). Owner's decision 2026-09-24: the new UI, even
-- though the action has to be found by hand there.
--
-- WHY THIS SITS IN GE AND NOT IN THE APP. window.bngVue.gotoGameState(name, {params}) ends in the very
-- same call (ui-vue/src/App.vue:212 -> lua.extensions.ui_router.navigate), and the app could reach it --
-- but it offers no way to ASK whether a route exists; it hands the name over and the answer comes back
-- only as a resolved promise inside the Vue bridge. Here the existence question is answerable with the
-- exact predicate navigate itself resolves with, and navigate's own return value is readable. That is
-- the difference between a probe and a hope, and it is the whole point of this feature. bngApi is also
-- the channel every other UI -> GE call in this mod already uses, while window.bngVue is an internal
-- Vue global -- one version-coupled surface fewer.

-- The route that opens the new options UI on the key bindings, or nil when this build has none.
--
-- The candidate list is a PREFERENCE ORDER, never a claim: every name is checked against
-- ui_router_routeManager.getRoute, which is what ui_router.navigate resolves with (ui/router.lua:258).
-- An invented route name is a silent no-op there -- navigate logs "Route not found" and returns a
-- failure table nobody reads -- the same trap as an invented input-action name (ADR-0017 / CLAUDE.md).
-- The pause family comes first because a player clicking a key in this window is driving, not sitting
-- in the main menu. Nothing is cached: the table cannot change within a session, and resolving again
-- costs a table lookup while a cache would have to survive a GE Lua reload (ADR-0052).
--
-- The candidates live inside the function on purpose -- a top-level local would spend one of the
-- eighteen this file has left.
function M.controls_route()
    local ok, resolved = pcall(function()
        local manager = extensions.ui_router_routeManager
        if type(manager) ~= "table" or type(manager.getRoute) ~= "function" then
            return nil
        end
        local candidates = {"pause.options.category", "options.category", "pause.options", "options"}
        for _, candidate in ipairs(candidates) do
            if manager.getRoute(candidate) then
                return candidate
            end
        end
        return nil
    end)
    if not ok then
        log("W", "beamcomp.ui", "controls window: could not read the router's route table: "
            .. tostring(resolved))
        return nil
    end
    return resolved
end

-- Tell the window which of its jump targets exists (GE -> UI). The app asks for this once on link and
-- picks its rung from the answer; it keeps its own legacy rung for the empty answer, so a build without
-- the new router behaves exactly as round 1 did rather than losing the button.
--
-- Pushed as a guihook like every other GE -> UI payload in this mod, not answered through bngApi's
-- callback channel: that channel works, but nothing else here uses it, and one messaging pattern is
-- worth more than one saved round-trip.
function M.request_controls_route()
    local route = M.controls_route()
    guihooks.trigger("BeamCompControlsRoute", {route = route or ""})
end

-- Take the player to the key bindings in the new options UI. Returns whether the router accepted it.
--
-- `category` is the id the new UI keys its pages by, and "controls" resolves to the bindings list with
-- no tab to pick afterwards. It rides even on the two category-less candidates: the Vue side declares
-- the parameter optional on the same component (/pause/options/:category?), so it is either used or
-- ignored, never wrong.
--
-- navigate does NOT throw on an unknown route or a blocked guard -- it returns a failure table. Reading
-- it is the only way this can be anything but silent, so the reason goes into the log beside the route.
function M.open_controls_bindings()
    local route = M.controls_route()
    if not route then
        log("W", "beamcomp.ui", "controls window: no options route in this build; not navigating")
        return false
    end
    local ok, result = pcall(function()
        return extensions.ui_router.navigate(route, {category = "controls"}, nil)
    end)
    if not ok then
        log("W", "beamcomp.ui", "controls window: navigate to '" .. route .. "' threw: "
            .. tostring(result))
        return false
    end
    -- Both outcomes come back as a table -- {success = true, ...} or {success = false, reason = ...}
    -- (ui/router.lua:233 and :523). Only an explicit false counts as a refusal, so a build that answers
    -- nothing, or answers in a shape we do not know, is taken at its word instead of reported as broken.
    if type(result) == "table" and result.success == false then
        log("W", "beamcomp.ui", "controls window: router refused '" .. route .. "': "
            .. tostring(result.reason or "unknown"))
        return false
    end
    log("I", "beamcomp.ui", "controls window: opened the key bindings via '" .. route .. "'")
    return true
end

-- ===== reset the BeamComp windows (feature ui-reset-to-default-size) ==============================
-- ONE function, reached from both doors: the setup panel's gear menu and the controls window's gear
-- menu (a footer button until 2026-10-10). The setup panel sits behind the admin gate while a plain
-- player's BeamComp windows are the HUD and the controls window, so neither door alone would reach
-- everybody -- but there is only this one action, with no parameter that could make one door reset
-- more or less than the other.
--
-- The whole reset lives in race/uilayout.lua (RESET_APPS + derive_placement); this says nothing about
-- geometry and nothing about which apps exist. It turns the seam's status into the one line the player
-- reads, and the five statuses are five different sentences on purpose: "the layout system did not
-- answer" must not read like "there was nothing to reset", because a fallback that mimics its main
-- path's failure makes that failure invisible (ADR-0058).
--
-- A field on M, not a top-level local: this file sits at LuaJIT's 200-local ceiling (182/200 measured
-- 2026-09-25) and the apps reach it by name through bngApi anyway.
--
-- One interaction worth knowing before it is rediscovered: in a race notice.say ends in hud.show(), so a
-- reset that was DEFERRED is immediately followed by a deferred "add" for beamCompHud, which supersedes
-- the HUD's reset intent (one intent per app, last wins -- race/uilayout.lua). It costs the HUD's
-- geometry and nothing else, and it can only happen inside a window a button press cannot reach: both
-- halves of the guard require the player to be inside BeamNG's HUD-apps menu, and that route unmounts the
-- whole app layer these buttons live on (ADR-0012 amendment 2026-07-31). The deferral is there for the
-- replay path and for the day that stops being true, not for a case anybody can click into today.
function M.reset_ui_layout()
    local result = M.uilayout.reset_to_defaults()
    local status = type(result) == "table" and result.status or "failed"
    if status == "reset" then
        local count = result.count or 0
        notice.say("Reset " .. count .. " BeamComp window" .. (count == 1 and "" or "s")
            .. " to default size and position.", "info")
        return
    end
    if status == "none" then
        notice.say("No BeamComp window on your layout -- nothing to reset.", "info")
        return
    end
    if status == "deferred" then
        notice.say("The HUD apps menu has your layout -- the reset runs when you leave it.", "info")
        return
    end
    if status == "unavailable" then
        notice.say("Could not read your window layout -- nothing was reset.", "warning")
        return
    end
    notice.say("Could not write your window layout -- nothing was reset.", "warning")
end

-- A server bestNotice: this client set a personal best and/or the race's track record (ADR-0027).
-- Surface it as a toast; the track record wins the message when both are set.
local function handle_best_notice(payload)
    if type(payload) ~= "table" or (not payload.pb and not payload.trackRecord) then
        return
    end
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp",
        msg = payload.trackRecord and "New track record!" or "New personal best!",
    })
end

-- A server raceRecords: this race's pre-run best times for the post-race analysis overlay (ADR-0028) --
-- the local player's own personal-best record (pb) and the cross-player track record (trackRecord),
-- both as the opaque numbers the records store holds. Store as-is; build_hud_snapshot derives the
-- per-CP deltas client-side. Cleared on lobby teardown.
local function handle_race_records(payload)
    if type(payload) ~= "table" then
        return
    end
    M.state.race_records = {
        race = payload.race,
        car = payload.car,
        pb = payload.pb,
        trackRecord = payload.trackRecord,
        driverTotals = payload.driverTotals,
        prerun = payload.prerun,
    }
end

-- Non-owner: resolve the relayed aiMap (BeamMP server ids) to local synced game ids, marking each AI car
-- so it is kept out of the Tab cycle and the owner's nametag is suppressed on it (ADR-0036). Scans the
-- scene for a vehicle whose cross-client server id is in the pending set; a match is recorded in
-- ai_remote_ids and dropped from the pending set, so the scan shrinks and stops once all resolve.
-- Retried from onUpdate + onVehicleSpawned, since a synced car may not exist yet at relay time. The
-- server-id read is SPIKE #2 (race/ai): if it never resolves, the cars keep the owner's tag -- the same
-- accepted fallback as the cones (ADR-0020). No-op when nothing is pending.
local function resolve_remote_ai()
    local pending = M.state.ai_server_ids
    if not pending or not be then
        return
    end
    M.state.ai_remote_ids = M.state.ai_remote_ids or {}
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        local server_id = veh and ai.server_id_of(veh) or nil
        if server_id ~= nil and pending[tostring(server_id)] then
            M.state.ai_remote_ids[veh:getID()] = true
            ai.suppress(veh)
            pending[tostring(server_id)] = nil
        end
    end
    if next(pending) == nil then
        M.state.ai_server_ids = nil
    end
end

-- Non-owner handler for the owner's aiMap (ADR-0036): the server ids of the synced AI cars. Store them as
-- a pending set and resolve to local handles now (retried until the synced cars exist). The owner ignores
-- its own relayed map -- it already tracks ai_cars locally.
local function handle_ai_map(payload)
    if M.state.ai_cars then
        return
    end
    local entries = type(payload) == "table" and payload.entries or nil
    if type(entries) ~= "table" then
        return
    end
    local pending, labels = {}, {}
    for _, entry in ipairs(entries) do
        if entry.serverId ~= nil then
            local key = tostring(entry.serverId)
            pending[key] = true
            -- The label has ridden in this message since ADR-0036 and no remote has ever read it. It is
            -- the name the standings show for that car -- ai_entry.label = entry.name =
            -- grid_store.ai_display_name(id), the same call make_slot_entry uses -- so an AI races under
            -- exactly the name the board gives it, with no (AI) and no number (ADR-0062, decision 3).
            if type(entry.label) == "string" and entry.label ~= "" then
                labels[key] = entry.label
            end
        end
    end
    M.state.ai_server_ids = pending
    M.state.ai_names = next(labels) ~= nil and labels or nil
    resolve_remote_ai()
    identity.apply_tags()
end

local HANDLERS = {
    ping = handle_ping,
    raceStart = handle_race_start,
    racePhase = handle_race_phase,
    standings = handle_standings,
    -- One-shot per-driver car descriptors (ADR-0029 amendment, bug partconfig-blob-bloats-standings): merge
    -- each into the cache keyed by the participant id (the standings entry's id). The standings entries no
    -- longer carry `car`; the overlay renders it from this cache. id is regrid-stable (survives a quali
    -- re-grid re-seeding progress with new slots). Defined inline (a table field costs no top-level local --
    -- init.lua is near the ceiling). Cleared alongside M.state.standings on every race reset.
    carInfo = function(payload)
        local entries = type(payload) == "table" and payload.entries or nil
        if type(entries) ~= "table" then
            return
        end
        M.state.car_info = M.state.car_info or {}
        for _, entry in ipairs(entries) do
            if entry.id ~= nil then
                M.state.car_info[tostring(entry.id)] = entry.car
            end
        end
    end,
    -- The server can reach us now, so send everything we report at connect (ADR-0058): the player-set
    -- name and the keys the two in-race assists sit on.
    --
    -- THIS is the path that lands on a fresh join, not the pair of calls in onExtensionLoaded. That runs
    -- inside BeamMP's resource handshake, ~27 s before the server counts this player as joined, and
    -- BeamMP drops every client -> server event until then -- silently on this side, which is why two
    -- reports were being lost with nothing in this log to show for it (measured 2026-09-19). The load-time
    -- calls stay because they are the path for a GE Lua reload in a session that is already up, where the
    -- server has long stopped asking.
    --
    -- Both reports are safe to repeat: the server re-reads the name idempotently and hints about the keys
    -- once per connection. Defined inline -- a table field costs no top-level local, and both callees are
    -- table fields resolved at call time, so their definitions further down this chunk are no problem.
    needReports = function()
        log("I", LOG_TAG, "server asked for the connect reports; sending name + assist keys")
        identity.report()
        M.report_assist_keys()
    end,
    -- The server accepted a /name (ADR-0054): persist what the player TYPED, so the next session reports
    -- it without him typing anything. The command is entered into chat, which this Lua never sees, so the
    -- server telling us is the only way we can learn it. Defined inline -- a table field costs no
    -- top-level local, and the identity block that owns save() is assigned further down this chunk.
    nameSet = function(payload)
        if type(payload) == "table" then
            identity.save(payload.name)
        end
    end,
    -- Every connected player plus whether his name is a temporary one (ADR-0054), seeded on /raceui and
    -- re-broadcast on every join, leave and accepted name. Cache it and push it straight to the setup
    -- panel, exactly like handle_championship -- the panel is not on the per-frame HUD path, so it needs
    -- the immediate push.
    playerList = function(payload)
        M.state.player_list = (type(payload) == "table" and type(payload.players) == "table")
            and payload.players or {}
        identity.push_players()
        -- The same list is what every driver's nametag says (ADR-0062), so a join, a leave and an
        -- accepted /name all reach the cars in the same message that reaches the panel.
        identity.apply_tags()
    end,
    championship = handle_championship,
    tournament = handle_tournament,
    quali = quali.handle_snapshot,
    -- Rally staged sprint quali (ADR-0044): the staged queue snapshot + the per-driver stage/hold commands.
    qualiQueue = quali.handle_queue,
    qualiStage = quali.handle_stage,
    qualiHold = quali.handle_hold,
    listRaces = handle_list_races,
    listVehicles = handle_list_vehicles,
    regrid = handle_regrid,
    aiMap = handle_ai_map,
    -- Whether drivers carry a name over their car on this server (ADR-0062). Broadcast on every change
    -- and pushed to each client the moment the server can reach it, so a client with no panel open is
    -- just as current as the admin who flipped it.
    --
    -- A payload without the field reads as ON, the same reading as never having heard the message at
    -- all: the setting defaults to on, so "unknown" must look like plain BeamMP rather than like a
    -- server that silently stripped everybody's name. Defined inline -- a table field costs no top-level
    -- local.
    namePolicy = function(payload)
        M.state.show_driver_names = not (type(payload) == "table" and payload.showDriverNames == false)
        identity.apply_tags()
        identity.push_name_policy()
        log("I", LOG_TAG, "driver names are " .. (M.state.show_driver_names and "on" or "off")
            .. " on this server")
    end,
    -- The cross-client BeamMP ids of the vehicles the owner's prefab load created (ADR-0062). They carry
    -- no name on any client, in either setting of showDriverNames -- a prop is never a driver.
    --
    -- The set is REPLACED, not merged. Every message carries the whole truth, which is what keeps a prop
    -- BeamMP deleted and re-spawned under a new id from leaving its dead id behind while its live one
    -- goes uncovered. The host derives its own set (identity.prop_map_step) and ignores the echo of its
    -- own message, exactly like the owner ignores its own aiMap. Defined inline: a table field costs no
    -- top-level local, and init.lua is near LuaJIT's ceiling.
    propMap = function(payload)
        if M.state.prop_before then
            return
        end
        local ids = type(payload) == "table" and payload.ids or nil
        local set, count = {}, 0
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                if id ~= nil then
                    set[tostring(id)] = true
                    count = count + 1
                end
            end
        end
        M.state.prop_ids = count > 0 and set or nil
        identity.apply_tags()
        log("I", RACE_LOG_TAG, string.format("race props: %d vehicle(s) carry no name here", count))
    end,
    validateRace = handle_validate_race,
    -- On-demand scenery pull for a client without the track (ADR-0046).
    trackProbe = handle_track_probe,
    trackFetch = handle_track_fetch,
    trackData = handle_track_data,
    finishGrace = handle_finish_grace,
    -- The AFK cutoff counter shown behind the finish-timer counter (feature
    -- standings-afk-cutoff-counter). Keyed off the constant so the wire name lives in exactly one place
    -- on this side, and handled on the `stall` namespace so it costs no top-level local.
    [stall.MSG_CUTOFF] = stall.handle_cutoff,
    resultsToggle = handle_results_toggle,
    analysisToggle = handle_analysis_toggle,
    -- /keys (ADR-0061): open or close this client's controls window. An inline function rather than a
    -- named handler on purpose -- a `local function handle_controls_open` would spend one of init.lua's
    -- remaining top-level locals for a one-line relay, and the real work is a public M function anyway.
    controlsOpen = function()
        M.toggle_controls()
    end,
    gridData = handle_grid_data,
    gridList = handle_grid_list,
    presetData = handle_preset_data,
    presetList = handle_preset_list,
    bestNotice = handle_best_notice,
    raceRecords = handle_race_records,
    setupOpen = handle_setup_open,
    -- Race-setup panel password lock (ADR-0056): the locked open and the verdict on an attempt.
    setupLocked = setup.handle_locked,
    unlockResult = setup.handle_result,
    -- Whether the SERVER says this connection may open the race-setup panel (feature
    -- raceui-reopen-without-typing). The single writer of M.state.setup_may_open, which is the single
    -- thing the final-standings card's button is drawn off -- so the whole chain from the server's
    -- is_race_admin to the ng-if has exactly one link on this side.
    --
    -- Anything but an explicit true reads as FALSE: a payload without the field, a garbled one and a
    -- never-sent one all mean no button. That is the opposite reading from namePolicy above, and
    -- deliberately so -- an unknown name policy must look like plain BeamMP, while an unknown permission
    -- must look like no permission. Defined inline: a table field costs no top-level local.
    setupAccess = function(payload)
        M.state.setup_may_open = type(payload) == "table" and payload.mayOpen == true
        -- beamcomp.race, not the net tag the handler beside it uses: on_server_event has already logged
        -- the arrival, and what this line adds is what it MEANS -- so it reads under the same subsystem as
        -- the press it enables (M.open_race_setup), and the pair greps as one.
        log("I", RACE_LOG_TAG, "race setup is "
            .. (M.state.setup_may_open and "mine to open" or "not mine to open"))
    end,
    gridSetupOpen = handle_grid_setup_open,
}

-- Handle one server->client event. `data` arrives as a JSON string -- the BeamMP client
-- delivers event payloads as strings, regardless of how the server sent them.
local function on_server_event(data)
    local message_type, payload = envelope.decode(data)
    if not message_type then
        -- On failure envelope.decode returns (nil, error_message).
        log("W", LOG_TAG, "dropped malformed server event: " .. tostring(payload))
        return
    end

    M.state.last_event_at = os.time()

    local handler = HANDLERS[message_type]
    if not handler then
        log("W", LOG_TAG, "no handler for server event type=" .. message_type)
        return
    end

    log("I", LOG_TAG, "server event type=" .. message_type)
    handler(payload)
end

-- Draw the grid editor's live preview poses as cyan pillars with P-position labels, each with a red
-- orientation line in the slot's facing (drive-up) direction (ADR-0023 + amendment). The active
-- segment's pillars read bright and the rest are dimmed, so it is clear which slots the current knobs
-- affect. Immediate-mode: redrawn each frame from grideditor.state, so leaving edit mode (active = false)
-- removes them with no scene objects to clean up.
--
-- Pillar and line follow the slot's MEASURED ground slope, and the four points that slope was measured
-- at get a blob each (ADR-0034 amendment 2026-08-30). Both read the normal race/placement put on the
-- pose and tilt through placement.plane_axis -- the same values the spawn orients the car by, never a
-- second approximation of the terrain. Nothing here logs: this runs every frame, and the client log
-- stops recording after ~15k lines (memory beamng-client-log-blind-after-15k-lines).
local function draw_editor_grid()
    if not grideditor.state.active or not grideditor.state.poses then
        return
    end
    local active_segment = grideditor.active_segment()
    local active_color = ColorF(0.35, 0.95, 1.0, 0.95)
    local inactive_color = ColorF(0.16, 0.55, 0.72, 0.6)
    local orient_color = ColorF(1.0, 0.15, 0.15, 0.9)
    local sample_color = ColorF(1.0, 0.78, 0.2, 0.85)
    local label_fg = ColorF(1, 1, 1, 1)
    local label_bg = ColorI(0, 0, 0, 255)
    for index, pose in ipairs(grideditor.state.poses) do
        local p = pose.pos
        local base = vec3(p.x, p.y, p.z)
        -- The pillar stands along the measured surface normal, so it leans exactly as the car will.
        -- No normal (flat ground answered, or nothing measured) -> world up, i.e. upright as before.
        local up = pose.up and vec3(pose.up.x, pose.up.y, pose.up.z) or vec3(0, 0, 1)
        local top = base + up * GRID_COLUMN_HEIGHT
        local color = (pose.segment == active_segment) and active_color or inactive_color
        debugDrawer:drawCylinder(base, top, GRID_COLUMN_RADIUS, color)
        -- The label is in DISPLAY space (ADR-0023 amendment 2026-08-01): the admin reads grid positions
        -- 1-based, so the front pillar is "P1", like every other P in this mod (the race HUD's P<pos>).
        -- ipairs is 1-based and the GE slot is `index - 1`, so the label is `slot + 1` == `index` exactly.
        -- Everything underneath -- pose.segment, the params, the wire, the spawn maths -- stays 0-based;
        -- do not "correct" this back to the slot number.
        debugDrawer:drawTextAdvanced(top, "P" .. index, label_fg, true, false, label_bg)
        -- A short red line in the slot's facing direction so the whole field's orientation reads at a
        -- glance (faceDir is always present -- gate-normal or the fallback heading). Drawn as a thin
        -- cylinder just above the ground (the confirmed draw API; no unverified drawLine).
        local dir = pose.faceDir
        if dir then
            -- Laid IN the surface through the same projection the spawn orientation uses, so the line
            -- keeps its distance to the ground over its whole length on a slope.
            local along = (pose.up and placement.plane_axis(dir, pose.up)) or dir
            local from = base + up * GRID_ORIENT_LINE_HEIGHT
            local to = from + vec3(along.x, along.y, along.z or 0) * GRID_ORIENT_LINE_LENGTH
            debugDrawer:drawCylinder(from, to, GRID_ORIENT_LINE_RADIUS, orient_color)
        end
        -- The four points the slope was measured at, as flat discs lying in it. The slope is taken
        -- unclamped by design, so a sample on a kerb tips its slot hard -- showing WHERE it measured is
        -- what turns that from a mystery into "move this slot half a metre".
        if pose.samples then
            local thickness = up * grideditor.SAMPLE_BLOB_HEIGHT
            for _, sample in ipairs(pose.samples) do
                local centre = vec3(sample.x, sample.y, sample.z)
                debugDrawer:drawCylinder(centre - thickness, centre + thickness,
                    grideditor.SAMPLE_BLOB_RADIUS, sample_color)
            end
        end
    end
end

-- The two horizontal gate-edge points (left, right) of an oriented checkpoint, derived from its
-- gate normal the way BeamNG's own pathnode renderer does -- the perpendicular to the normal in the
-- ground plane (cross(normal, up)). Returns nil for a checkpoint with no normal: a pure-radius
-- checkpoint has no meaningful left/right side, so only its area column is drawn.
local function gate_edges(checkpoint)
    local normal = checkpoint.normal
    if not normal then
        return nil
    end
    local len = math.sqrt(normal.x * normal.x + normal.y * normal.y)
    if len < 1e-6 then
        return nil
    end
    local perp_x = normal.y / len
    local perp_y = -normal.x / len
    local radius = checkpoint.radius or MARKER_RADIUS
    local p = checkpoint.pos
    local left = vec3(p.x - perp_x * radius, p.y - perp_y * radius, p.z)
    local right = vec3(p.x + perp_x * radius, p.y + perp_y * radius, p.z)
    return left, right
end

-- Gate-line angle (radians) for a checkpoint's player-facing posts: the un-slewed TARGET the caller
-- eases toward (smooth_marker_angle applies the rotation-rate limit on top). The far target is the
-- line perpendicular to the horizontal car->checkpoint direction (the gate presents square-on to the
-- approach); the near target is the line of the stored gate normal (its real orientation). The angle
-- blends linearly from fully player-facing at MARKER_ORIENT_START_DIST to fully normal-facing at
-- MARKER_ORIENT_FULL_DIST -- both distances from the center, independent of the area-fade band -- then
-- rests, so the posts reach and hold their true line well before the gate rather than snapping to it
-- right in front of the car. A gate line repeats every pi (the two posts are interchangeable), so the
-- blend step is wrapped into [-pi/2, pi/2] -- the shortest turn onto the same line. A checkpoint
-- without a stored normal has no true line to ease toward, so it stays fully player-facing. Returns
-- nil when there is no car position or the car is horizontally at the center, signalling the caller to
-- fall back to the stored-normal posts.
local function gate_line_angle(checkpoint, car_pos)
    if not car_pos then
        return nil
    end
    local p = checkpoint.pos
    local dx = p.x - car_pos.x
    local dy = p.y - car_pos.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
        return nil
    end
    local player_angle = math.atan2(dy, dx) + math.pi / 2

    -- No stored normal: nothing to ease toward, stay fully player-facing (the prior behavior).
    local normal = checkpoint.normal
    if not normal then
        return player_angle
    end
    local nlen = math.sqrt(normal.x * normal.x + normal.y * normal.y)
    if nlen < 1e-6 then
        return player_angle
    end
    -- The line of the stored normal, in the same angle convention post_edges expects (perp = the
    -- gate line; gate_edges builds it from (normal.y, -normal.x)).
    local normal_angle = math.atan2(-normal.x, normal.y)

    -- Blend fraction by distance: 0 (player-facing) at the start distance and beyond, 1 (true gate
    -- line) at the full-orient distance and inside, linear between. The thresholds are guarded so a
    -- large-radius gate still reaches full orientation by its volume edge and the band stays positive.
    local radius = checkpoint.radius or MARKER_RADIUS
    local full_dist = math.max(MARKER_ORIENT_FULL_DIST, radius)
    local start_dist = math.max(MARKER_ORIENT_START_DIST, full_dist + 1.0)
    local t = (start_dist - len) / (start_dist - full_dist)
    t = math.max(0.0, math.min(1.0, t))

    -- Shortest step from the player line onto the same pi-periodic normal line, scaled by t.
    local diff = (normal_angle - player_angle + math.pi / 2) % math.pi - math.pi / 2
    return player_angle + t * diff
end

-- Slew-limit the drawn gate-post angle toward `target` (the un-slewed goal from gate_line_angle) so
-- the posts turn at most MARKER_MAX_TURN_RATE per second instead of snapping. State lives in
-- M.state.marker_angles keyed by the checkpoint's stable index, so each gate keeps its own continuity
-- across frames -- including when the look-ahead marker is promoted to the next marker. A gate line is
-- pi-periodic (the posts are interchangeable), so the step is wrapped into [-pi/2, pi/2]: the shortest
-- turn onto the same line. A nil target (no car / gate at center) or a nil index passes through
-- untouched and leaves any stored angle, so a re-acquisition eases from where it left off; the first
-- frame for a gate snaps to the target (nothing to ease from).
local function smooth_marker_angle(index, target, dt)
    if target == nil or index == nil then
        return target
    end
    local store = M.state.marker_angles
    if not store then
        store = {}
        M.state.marker_angles = store
    end
    local prev = store[index]
    if prev == nil then
        store[index] = target
        return target
    end
    -- Shortest signed step onto the same pi-periodic gate line, then clamp it to this frame's budget.
    local diff = (target - prev + math.pi / 2) % math.pi - math.pi / 2
    local max_step = MARKER_MAX_TURN_RATE * dt
    if diff > max_step then
        diff = max_step
    elseif diff < -max_step then
        diff = -max_step
    end
    local angle = prev + diff
    store[index] = angle
    return angle
end

-- The two horizontal points (left, right) to draw the side posts at, from a smoothed gate-line angle
-- (gate_line_angle). Falls back to the stored-normal placement (gate_edges) when the angle is nil
-- (no car / degenerate) -- that fallback is itself nil for a pure-radius checkpoint, so no posts are
-- drawn that frame, the prior behavior.
local function post_edges(checkpoint, line_angle)
    if line_angle == nil then
        return gate_edges(checkpoint)
    end
    local perp_x = math.cos(line_angle)
    local perp_y = math.sin(line_angle)
    local radius = checkpoint.radius or MARKER_RADIUS
    local p = checkpoint.pos
    local left = vec3(p.x - perp_x * radius, p.y - perp_y * radius, p.z)
    local right = vec3(p.x + perp_x * radius, p.y + perp_y * radius, p.z)
    return left, right
end

-- The style for the next checkpoint, by role: the race's final scored crossing is the finish
-- (green); a non-final start/finish line (CP0, stable index 0) is a lap line (blue); every other
-- checkpoint uses the regular pale-fill + red-post style.
local function marker_style(checkpoint, is_finish)
    if is_finish then
        return FINISH_STYLE
    end
    if checkpoint.index == 0 then
        return LAP_STYLE
    end
    return CHECKPOINT_STYLE
end

-- Fade factor [0, 1] for a checkpoint's drive-through area cylinder, by the local car's horizontal
-- distance to the checkpoint center: full (1) at radius + CHECKPOINT_FADE_BAND and beyond, ramping
-- linearly to 0 at the volume edge (radius) so there is no wall to drive through up close. Only the
-- horizontal distance counts -- the column reaches hundreds of meters up/down and must not skew it.
-- With no car position resolved, stays at 1 so the marker shows as before.
local function area_fade_factor(checkpoint, car_pos)
    if not car_pos then
        return 1.0
    end
    local p = checkpoint.pos
    local dx = p.x - car_pos.x
    local dy = p.y - car_pos.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local radius = checkpoint.radius or MARKER_RADIUS
    local factor = (dist - radius) / CHECKPOINT_FADE_BAND
    return math.max(0.0, math.min(1.0, factor))
end

-- Draw one checkpoint as a singleplayer-style gate: a pale translucent column spanning the whole
-- checkpoint radius, plus two thin posts at the (already smoothed) player-facing gate-line angle.
-- The area column fades out as the local car (car_pos) nears the checkpoint; the posts stay solid.
local function draw_checkpoint_marker(checkpoint, style, car_pos, line_angle)
    local p = checkpoint.pos
    local radius = checkpoint.radius or MARKER_RADIUS
    local base = vec3(p.x, p.y, p.z - CHECKPOINT_COLUMN_DOWN)
    local top = vec3(p.x, p.y, p.z + CHECKPOINT_COLUMN_UP)
    local area = style.area
    local fade = area_fade_factor(checkpoint, car_pos)
    debugDrawer:drawCylinder(base, top, radius, ColorF(area.r, area.g, area.b, area.a * fade))

    local left, right = post_edges(checkpoint, line_angle)
    if not left then
        return
    end
    local post = style.post
    local post_color = ColorF(post.r, post.g, post.b, post.a)
    local left_base = vec3(left.x, left.y, left.z - CHECKPOINT_COLUMN_DOWN)
    local right_base = vec3(right.x, right.y, right.z - CHECKPOINT_COLUMN_DOWN)
    local left_top = vec3(left.x, left.y, left.z + CHECKPOINT_COLUMN_UP)
    local right_top = vec3(right.x, right.y, right.z + CHECKPOINT_COLUMN_UP)
    debugDrawer:drawCylinder(left_base, left_top, GATE_POST_RADIUS, post_color)
    debugDrawer:drawCylinder(right_base, right_top, GATE_POST_RADIUS, post_color)
end

-- Draw the next expected checkpoint -- and the one after it as a yellow-posted look-ahead -- as
-- singleplayer-style gates, so the player sees where to head next and can plan the line. Immediate-
-- mode (redrawn each frame, nothing to clean up). The next checkpoint is the
-- plan entry at detection.seq + 1, the look-ahead the entry after it; each cursor indexes the
-- checkpoints array (ADR-0013) -- so on a circuit they point at CP1 first and back at the start/
-- finish line (CP0) for the final crossing. Each post orientation is slew-limited per frame
-- (smooth_marker_angle, driven by `dt`) so it eases toward its target instead of snapping.
local function draw_next_checkpoint(race, detection, car_pos, dt)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return
    end
    local final_seq = #entries

    -- Circuit: before the lap clock arms (the run-up from the grid to the line), also draw the
    -- start/finish line itself, so the player sees the line the lap is counted from -- the scored
    -- plan's next marker is CP1, not this line (ADR-0022). Once the line is crossed (lt.started) it
    -- stops here and reappears later as the regular lap/finish marker. Purely visual.
    local lt = M.state.laptimer
    if lt and not lt.started and lt.start_cp then
        -- First-lap run-up: the start/finish line holds its true gate orientation (fixed stored
        -- normal, no car-tracking rotation) until the line is first crossed, so it reads as a proper
        -- start line rather than swinging to face the grid. A nil angle makes post_edges fall back to
        -- gate_edges (the stored normal). With no stored normal there is nothing to lock to, so keep
        -- the car-facing angle (the prior behavior, avoids dropping the posts). Once crossed
        -- (lt.started) the line reappears as the regular lap/finish marker and rotates normally again.
        local start_angle = nil
        if not lt.start_cp.normal then
            start_angle = smooth_marker_angle(lt.start_cp.index,
                gate_line_angle(lt.start_cp, car_pos), dt)
        end
        draw_checkpoint_marker(lt.start_cp, marker_style(lt.start_cp, false), car_pos, start_angle)
    end

    local next_entry = entries[detection.seq + 1]
    local next_checkpoint = next_entry and race.checkpoints[next_entry.cursor]
    if not next_checkpoint then
        return
    end
    local next_style = marker_style(next_checkpoint, detection.seq + 1 == final_seq)
    local next_angle = smooth_marker_angle(next_checkpoint.index,
        gate_line_angle(next_checkpoint, car_pos), dt)
    draw_checkpoint_marker(next_checkpoint, next_style, car_pos, next_angle)

    local ahead_entry = entries[detection.seq + 2]
    local ahead_checkpoint = ahead_entry and race.checkpoints[ahead_entry.cursor]
    if ahead_checkpoint then
        local ahead_angle = smooth_marker_angle(ahead_checkpoint.index,
            gate_line_angle(ahead_checkpoint, car_pos), dt)
        draw_checkpoint_marker(ahead_checkpoint, LOOKAHEAD_STYLE, car_pos, ahead_angle)
    end
end

-- Register the server->client handler. AddEventHandler is a GE global provided by BeamMP's
-- MPGameNetwork, which may not be loaded yet when this extension comes up, so registration
-- is retried from onUpdate until it sticks. The handler is a plain function value plus a
-- stable source name ("beamcomp") -- re-registering from the same name patches in place, so
-- a Lua reload never stacks duplicate handlers.
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

-- Where the player-set name lives (ADR-0054). A settings file, so it survives a game restart and travels
-- with the player to any BeamComp server -- the same mechanism and path shape BeamMP's own MPConfig uses
-- for /settings/BeamMP/config.json (MPConfig.lua:189/276/296), so it is proven in exactly this
-- environment.
identity.PATH = "/settings/beamcomp_identity.json"

-- The stored name, or nil. A missing file, a malformed file or an unexpected shape all mean "no name
-- set" -- never an error (jsonReadFile returns nil for all three, lua/common/utils.lua:476).
--
-- Read from disk on every call rather than cached in a local: the file is the single truth, so a GE Lua
-- reload cannot leave a stale copy behind (ADR-0052) and there is no field whose correctness depends on
-- its own previous value.
function identity.load()
    local ok, data = pcall(jsonReadFile, identity.PATH)
    if not ok or type(data) ~= "table" or type(data.name) ~= "string" or data.name == "" then
        return nil
    end
    return data.name
end

-- Persist the name the server accepted (ADR-0054). The value is what the player TYPED, not the
-- collision-suffixed form that took effect: storing "SPEEDY2" would strand him on the suffix long after
-- the colliding player left, while re-requesting "SPEEDY" each session correctly drops it once free.
-- Skips the write when nothing changed, so a normal session touches the disk zero times.
function identity.save(name)
    if type(name) ~= "string" or name == "" or name == identity.load() then
        return
    end
    local ok, written = pcall(jsonWriteFile, identity.PATH, {name = name}, true)
    if ok and written then
        log("I", LOG_TAG, "stored race name '" .. name .. "' in " .. identity.PATH)
    else
        log("W", LOG_TAG, "could not store the race name in " .. identity.PATH)
    end
end

-- Report the stored name to the server so it keys every identity -- live standings, results, the grid
-- roster -- on the name the player picked instead of his rotating BeamMP guest name (ADR-0054).
--
-- There is nothing to re-read later: the name is a file, not a property of a car, so the ADR-0031 spawn
-- report, staging poll and GO lock-in are all gone. No stored name means we send nothing and the server
-- shows the BeamMP name -- and hints the player about /name.
--
-- Called from TWO places, and the one at load is the weaker of them (ADR-0058). onExtensionLoaded runs
-- inside BeamMP's resource handshake, and until the server counts this player as joined BeamMP drops
-- every client -> server event without telling this side -- so on a fresh join that call is best-effort
-- and normally lands nowhere. The reliable path is the server asking (needReports), which it does as soon
-- as it can reach us. The load-time call still earns its place: after a GE Lua reload the session is long
-- up, the server is no longer asking, and it is the only path left.
function identity.report()
    local name = identity.load()
    if not name then
        log("I", LOG_TAG, "no race name set; the server will show the BeamMP name")
        return
    end
    log("I", LOG_TAG, "reporting race name: " .. name)
    send_to_server("clientIdentity", {name = name})
end

-- Which player id this connection has on the server, or nil when neither source answers. The setup
-- panel's player list is the same list for everybody, so this is what tells the panel which of its rows
-- belongs to the player reading it.
--
-- TWO sources, the server first:
--
--   1. The server names it on setupOpen (`yourPlayerId`). Authoritative, and free of any BeamMP
--      internal -- but it does not survive a GE Lua reload (M.state is rebuilt from its literal,
--      ADR-0052), and the panel's link-time pull goes to GE rather than to the server, so nothing
--      re-sends it until the next /raceui.
--   2. BeamMP's own MPConfig carries the very same id -- the server assigns it at connect and the
--      client stores it from the 'P' packet (MPGameNetwork.lua:469). It DOES survive a GE Lua reload:
--      MPConfig defines onSerialize/onDeserialized and takes PlayerServerID with it (MPConfig.lua:314),
--      which is exactly the gate our own M.state does not pass. Being a BeamMP internal it is guarded
--      like every other one here (race/cones.lua) and stays the fallback, never the source of truth.
--
-- The stored race name is NOT a third source. identity.load() holds what the player TYPED, not the
-- collision-suffixed name the server actually gave him, so matching a row by it would mark the OTHER
-- player's row in precisely the case where the two differ.
--
-- Logs which of the two answered, and only when the answer changes -- the house rule for every engine /
-- BeamMP signal in this codebase (input action names, the uilayout route prefix). A marker that is
-- missing and a marker nobody asked for look identical on screen; the log line is what tells them apart.
function identity.own_id()
    local id = tonumber(M.state.own_player_id)
    local source = "server"
    if id == nil then
        source = "beammp"
        if type(MPConfig) == "table" and type(MPConfig.getPlayerServerID) == "function" then
            local ok, value = pcall(MPConfig.getPlayerServerID)
            if ok then
                id = tonumber(value)
            end
        end
    end
    if id == nil then
        source = "none"
    end
    -- Keyed on the source AND the id, not the source alone: hopping from one server to the next keeps
    -- the source at "server" while the id changes, and that is exactly the case where the log is worth
    -- having.
    local answer = source .. ":" .. tostring(id)
    if identity.id_source ~= answer then
        identity.id_source = answer
        if id == nil then
            log("I", LOG_TAG, "own player id unknown; the panel marks nobody as (you)")
        else
            log("I", LOG_TAG, "own player id " .. tostring(id) .. " (source: " .. source .. ")")
        end
    end
    return id
end

-- Push the connected-player list to the setup panel, marking this client's own row (ADR-0054 display).
-- The ONE push point for BeamCompPlayers: both the server broadcast and the panel's link-time pull come
-- through here, so the marker cannot be on one path and missing on the other.
--
-- `isYou` is re-stamped on every row on every push rather than set once. The id can arrive after a list
-- has already been cached -- setupOpen and a join broadcast land in either order -- and a flag that is
-- only ever set would leave a stale mark behind on the row of whoever held that id before.
function identity.push_players()
    local rows = M.state.player_list or {}
    local own = identity.own_id()
    for i = 1, #rows do
        local row = rows[i]
        row.isYou = (own ~= nil and tonumber(row.id) == own) or nil
    end
    if guihooks then
        guihooks.trigger("BeamCompPlayers", {players = rows})
    end
end


-- ===== nametags: which vehicle carries a name, and what it says (ADR-0062) =========================
-- On `identity` rather than on a namespace of its own for the reason its header gives: this namespace
-- owns the name a player is shown under, and a floating nametag is that name on a car. race/nametags.lua
-- owns the BeamMP boundary; everything here is the policy this client can state.

identity.SWEEP_INTERVAL = 0.5     -- seconds between reconcile sweeps
identity.PROP_MAP_RETRY = 0.25    -- seconds between prop-map rebuild attempts while something is unresolved
identity.PROP_MAP_BUDGET = 20.0   -- seconds of attempts before giving up on the stragglers -- loudly

-- Vehicles this client knowingly put on the grid, as string keys. They are the exception to "everything
-- that appeared after the prefab load is a prop": the own race car (possibly freshly spawned, so not in
-- the pre-load snapshot) and the AI field.
--
-- The two seated-car reads are the belt to race_car_id's braces. A staging swap and a quali re-grid both
-- replace the own car, and for the frames between the spawn and the state write the tracked seat is the
-- only current answer. A stale answer costs nothing here: it can only name a car that existed before the
-- load, which the snapshot already excludes.
function identity.race_car_ids()
    local ids = {}
    local function keep(id)
        if id ~= nil then
            ids[tostring(id)] = true
        end
    end
    keep(M.state.race_car_id)
    keep(M.state.current_vehicle_id)
    for _, car in ipairs(M.state.ai_cars or {}) do
        keep(car.veh_id)
    end
    if be then
        local ok, seated = pcall(function() return be:getPlayerVehicle(0) end)
        if ok and seated then
            keep(seated:getId())
        end
    end
    return ids
end

-- The prop ids in a stable order: the wire payload and, concatenated, the signature that decides whether
-- anything has to be sent at all.
function identity.prop_list(ids)
    local list = {}
    for id in pairs(ids or {}) do
        list[#list + 1] = id
    end
    table.sort(list)
    return list
end

-- HOST ONLY: re-derive this race's prop set and relay it when it changed (ADR-0062).
--
-- Idle cost is one boolean test. While pending, it re-runs every PROP_MAP_RETRY seconds -- which is what
-- covers BeamMP registering a fresh prop asynchronously and, ~5 s later, deleting and re-spawning the
-- whole set under new ids (memory beammp-respawns-prefab-vehicles-under-new-ids). onVehicleSpawned
-- re-arms it, so a prop that appears at any later point gets back in.
--
-- The three endings are three different log lines on purpose. "all 14 props are silent", "12 of 14, still
-- asking" and "gave up with 2 unregistered" must not look alike: a confident line over an incomplete set
-- is how the old suppression's 49 % coverage went unnoticed for a year.
function identity.prop_map_step(dt)
    if not M.state.prop_map_pending or not M.state.prop_before then
        return
    end
    M.state.prop_map_wait = (M.state.prop_map_wait or 0) - (dt or 0)
    if M.state.prop_map_wait > 0 then
        return
    end
    M.state.prop_map_wait = identity.PROP_MAP_RETRY

    local ids, unresolved = props.live_prop_ids(M.state.prop_before, identity.race_car_ids())
    local list = identity.prop_list(ids)
    local signature = table.concat(list, ",")
    if signature ~= M.state.prop_map_sent then
        M.state.prop_ids = ids
        M.state.prop_map_sent = signature
        send_to_server("propMap", {ids = list})
        -- Our own props too: invisible to us (BeamMP never draws a tag over an own vehicle), but it keeps
        -- one rule for both sides instead of a host that is quietly exempt from its own policy.
        identity.apply_tags()
        -- The set changed, so the derivation is making progress -- give the stragglers the full budget
        -- again rather than timing out mid-churn.
        M.state.prop_map_budget = identity.PROP_MAP_BUDGET
        log("I", RACE_LOG_TAG, string.format("relayed %d race prop(s) as nameless", #list))
    end

    if unresolved == 0 then
        M.state.prop_map_pending = false
        return
    end
    M.state.prop_map_budget = (M.state.prop_map_budget or 0) - identity.PROP_MAP_RETRY
    if M.state.prop_map_budget <= 0 then
        M.state.prop_map_pending = false
        log("W", RACE_LOG_TAG, string.format("%d race prop(s) relayed as nameless, but %d vehicle(s) "
            .. "never registered with BeamMP -- those keep the host's name", #list, unresolved))
    end
end

-- HOST ONLY: the AI cars this client spawned, as {[cross-client id] = label} -- the shape the relayed aiMap
-- gives every other client (ADR-0062 decision 5, which never excluded the host). nil when this client owns
-- no AI; a car BeamMP has not registered yet is simply absent until the next sweep.
--
-- The owner ignores its own aiMap (handle_ai_map), so without this its policy had no AI at all and named
-- them after himself -- invisible, because BeamMP never draws an own vehicle, until the host draws them.
--
-- Derived from the live ai_cars on every call and never remembered: BeamMP hands a freed vehicle id to the
-- next car spawned, so after the quali despawn and the re-grid the host's own new race car can carry an id
-- an AI had. A map kept from the broadcast would put an AI's name on the host's own car; one built from
-- ai_cars cannot contain it.
function identity.own_ai_names()
    local cars = M.state.ai_cars
    if not cars then
        return nil
    end
    local names = nil
    for _, entry in ipairs(ai.server_map(cars)) do
        if type(entry.label) == "string" and entry.label ~= "" then
            names = names or {}
            names[tostring(entry.serverId)] = entry.label
        end
    end
    return names
end

-- Everything this client currently knows about who carries a name, in the shape race/nametags.apply
-- consumes. Rebuilt per call: it is three table reads and a walk over the player list, and a cached copy
-- would be one more thing to invalidate on every join, leave, rename and race start.
function identity.tag_policy()
    local names = nil
    local rows = M.state.player_list
    if rows then
        names = {}
        for _, row in ipairs(rows) do
            if row.id ~= nil and type(row.name) == "string" then
                names[tostring(row.id)] = row.name
            end
        end
    end
    M.state.tag_written = M.state.tag_written or {}
    return {
        props = M.state.prop_ids,
        -- The owner knows its AI from the cars it spawned, everybody else from the relayed aiMap.
        ai = identity.own_ai_names() or M.state.ai_names,
        names = names,
        -- Only an explicit false hides drivers: a client that has not heard the policy looks exactly like
        -- plain BeamMP, which is the safe reading of "unknown" for a setting that defaults to on.
        show = M.state.show_driver_names ~= false,
        written = M.state.tag_written,
    }
end

-- Apply the policy, and keep it for the per-frame draw of the host's own AI tags (identity.draw_tags),
-- together with the ai_cars table it was built from. The draw reads exactly what was just applied -- never
-- a second build -- so a frame can never name a car the sweep did not, and per frame nothing is allocated.
function identity.apply_tags()
    local policy = identity.tag_policy()
    nametags.apply(policy)
    identity.drawn_policy = policy
    identity.drawn_cars = M.state.ai_cars
end

-- HOST ONLY, every frame: draw the names over this client's own AI cars, which BeamMP never draws because
-- they are local here (ADR-0062 amendment 2026-10-08). Only the owner spawns AI (ADR-0036), so without
-- ai_cars there is no AI entry BeamMP skips, and the idle path is this one nil test. A policy built from
-- an earlier ai_cars table -- before the quali despawn, before the re-grid -- is void: BeamMP may have
-- handed one of its ids to the host's own new car. Nothing is drawn until the next sweep (<= 0.5 s)
-- builds one from the cars that exist now.
function identity.draw_tags()
    local cars = M.state.ai_cars
    if cars == nil or identity.drawn_policy == nil or identity.drawn_cars ~= cars then
        return
    end
    nametags.draw_local_ai(identity.drawn_policy)
end

-- Forget what THIS server told this connection about itself. Called at the SESSION boundary and nowhere
-- else (onClientEndMission): every field here belongs to the server we are leaving, so carrying one
-- to the next server would apply a stranger's statement until his own lands. Absence has to mean
-- unknown, never "what I saw last".
--
-- Unknown is not the same value for every field, and that is the whole care this function needs: an
-- unheard name policy reads as ON (plain BeamMP), while an unheard permission reads as NO (fail-closed).
-- Each field's own comment in M.state says which and why.
--
-- The record of what this client wrote goes with it, and that is the field that must not be dropped
-- anywhere else: cross-client ids are per server, so a kept entry could give a tag back on a vehicle we
-- never touched -- while dropping it too early leaves tags we took away and can no longer return.
--
-- The two per-race fields are really teardown_race_world's (it clears them with the props it deletes);
-- they are restated here so this function is complete on its own rather than depending on the order of
-- two calls in onClientEndMission.
function identity.clear_policy()
    M.state.show_driver_names = nil
    M.state.tag_written = nil
    M.state.prop_ids = nil
    M.state.ai_names = nil
    -- Whether the race-setup panel is this player's to open (feature raceui-reopen-without-typing). It
    -- belongs here and NOT in setup.clear: the password grant behind it hangs off the connection
    -- (ADR-0056), while setup.clear also runs on the panel's own Close button -- so a button that
    -- disappeared the first time an admin closed his panel would be bug panel-close-wipes-nametag-policy
    -- a second time. Cleared to false rather than nil, because false IS the unknown value here.
    M.state.setup_may_open = false
end

-- Reflect the server's name policy into an open setup panel. Its own dataset push carries the value too,
-- but that one is pulled on link -- this is what moves the checkbox when another admin flips it while
-- this panel is already on screen, the same reason the player list has a push of its own.
function identity.push_name_policy()
    if guihooks then
        guihooks.trigger("BeamCompNamePolicy", {showDriverNames = M.state.show_driver_names ~= false})
    end
end

-- Re-assert the policy on a slow tick. This is the part that makes it a property instead of a claim:
-- neither hideNametag nor customName is in Vehicle:onSerialized(), and BeamMP rebuilds an entry on a
-- vehicle EDIT as well as on a spawn -- and an edit fires no BeamNG spawn hook, so no event of ours
-- would ever hear about it. A sweep over an unchanged scene writes nothing at all.
--
-- The guard above it is the idle path: a client that knows no props, no AI, no players and no "off"
-- policy has nothing to assert and pays five nil tests. ai_cars is the owner's half of "knows AI": a host
-- with AI but no props, no player list and names on would otherwise never sweep, and nothing would name
-- (or draw) his AI.
function identity.tag_step(dt)
    if M.state.prop_ids == nil and M.state.ai_names == nil and M.state.player_list == nil
            and M.state.show_driver_names ~= false and M.state.ai_cars == nil then
        return
    end
    M.state.tag_wait = (M.state.tag_wait or 0) - (dt or 0)
    if M.state.tag_wait > 0 then
        return
    end
    M.state.tag_wait = identity.SWEEP_INTERVAL
    identity.apply_tags()
end

-- Report which keys the two in-race assists sit on here, so the server can name them in this player's
-- chat (ADR-0058). Only the client knows its own bindings and only the server can write a chat line, so
-- the knowledge has to travel.
--
-- An M field rather than a top-level local: init.lua sits at LuaJIT's 200-local ceiling (CLAUDE.md), and
-- an M field costs none. Not a `local function` called once either -- being reachable as
-- beamcomp_init.report_assist_keys() is what lets the binding be re-checked from the console in-game.
--
-- Sends NOTHING when the bindings cannot be read (see lock.assist_key_report). The server stays silent in
-- that case, which is the whole point: it never guesses a key, not even BeamNG's defaults.
--
-- Called from onExtensionLoaded AND from the needReports handler, exactly like identity.report and for
-- the same reason -- see the note there. The needReports call is also the better READ of the two: it
-- happens well after the engine has filled its binding table, where the load-time call can still find it
-- empty.
function M.report_assist_keys()
    local report = lock.assist_key_report()
    if not report then
        log("I", LOG_TAG, "no assist key bindings to report; the server will say nothing about them")
        return
    end
    send_to_server("clientKeys", {assists = report})
end

function M.onExtensionLoaded()
    -- Keep the extension across level/scenario switches (a race spans a level).
    setExtensionUnloadMode(M, "manual")
    envelope.set_codec(jsonEncode, jsonDecode)
    -- A Lua reload drops BeamMP's handler table, so always re-register from a clean slate
    -- rather than trusting the flag the fresh M.state literal came back with.
    M.state.registered = false
    ensure_registered()
    -- Same treatment for the qualifying hold's recover-key block, and for the same reason. This one is
    -- the sharper case: the engine's input filter DOES survive a GE Lua reload (core/input/
    -- actionFilter.lua defines onSerialize/onDeserialized) while our record of what we last pushed to it
    -- does not, so trusting the fresh `false` would mean comparing against a guess. hold.sync only calls
    -- the engine on an edge, so a guess that happened to match would skip the correction entirely.
    -- Releasing is always the right state to land on here: a hold needs a race and the qualifying phase,
    -- both nil at load, and hold.sync re-blocks on the next transition. Costs one filter update per load.
    -- Safe on the SHARED filter 0 (every subsystem toggles its own group there, see lock.lua): releasing
    -- a group makes the engine rebuild the filter from its whole group table, and ge/main.lua's init()
    -- restores that table (importPersistentData) BEFORE the mod manager mounts mods and loads us -- so
    -- this rebuilds from the complete restored set and cannot drop another subsystem's block.
    M.state.quali_hold_locked = false
    lock.set_recover_blocked(false)
    -- Seed the current-vehicle tracker; onVehicleSwitched keeps it current from here on.
    local own = be and be:getPlayerVehicle(0)
    if own then
        M.state.current_vehicle_id = own:getId()
    end
    -- Hand race/lock.lua the message chokepoint (feature race-toast-cleanup-and-checkpoint-readout).
    -- It cannot reach `notice` itself -- we require it, not the other way round -- and its own built-in
    -- default is the old top-left toast, so a load path that missed this line degrades to the previous
    -- surface rather than to silence. Re-installed here because a GE Lua reload re-requires the module.
    lock.notify = notice.say
    -- Hand it the race's car policy the same way (ADR-0064): every lock.install asks this, so a parts lock
    -- re-armed by the quali re-grid's remove/install needs nothing from that call site. Reads M.state live,
    -- so the closure never holds a stale answer; re-installed here after a GE Lua reload like notify above.
    lock.car_is_forced = function()
        return M.state.race_forced_car == true
    end
    -- Listen to BeamMP's two nametag switches (the "Player Nametags" key and hideNicknames), so the AI tags
    -- the host draws itself go on and off with every other tag (ADR-0062 amendment 2026-10-08). Given back
    -- in onExtensionUnloaded; a second install unwraps an earlier one instead of stacking on it. Guarded
    -- like its counterpart there: nothing below in this hook may depend on it.
    local tags_ok, tags_err = pcall(nametags.install_toggle_mirror)
    if not tags_ok then
        log("W", "beamcomp.nametags", "nametag toggles could not be mirrored: " .. tostring(tags_err))
    end
    -- Blank the centred surfaces from the freshly rebuilt (empty) state. onExtensionUnloaded runs WITHOUT
    -- a pcall, so a teardown that threw part way is no guarantee its clearing push went out (ADR-0052) --
    -- and after the reload M.state carries no message left to expire, so nothing else would ever take a
    -- stranded line back down.
    notice.paint()
    -- Report the name the player set with /name, so the server keys every identity on it (ADR-0054), and
    -- which keys this machine has the two in-race assists on, so the server can tell the player how to
    -- repair his car and how to get back on track (ADR-0058). Neither needs a vehicle or a later refresh.
    --
    -- BEST-EFFORT HERE, and that is not a caveat but the design (ADR-0058). On a fresh join this runs
    -- inside BeamMP's resource handshake, ~27 s before the server counts this player as joined, and
    -- BeamMP drops both events without a word to this side. The server asks again the moment it can
    -- reach us (the needReports handler above), which is what lands on a join. These two calls are what
    -- covers a GE Lua reload in a session that is already up, where nobody is going to ask.
    identity.report()
    M.report_assist_keys()
    -- Include a distinctive build marker so a redeploy can be confirmed live in beamng.log before trusting
    -- an in-game result -- the BeamMP client mod cache can serve a stale zip (memory
    -- beammp-client-mod-cache-stale).
    log("I", LOG_TAG, "loaded (build " .. BUILD_MARKER .. ")")
end

-- os.clock() reading of the last switch-lock toast, for SWITCH_BLOCK_TOAST_THROTTLE (CPU seconds is
-- monotonic and precise enough to gate a UI toast). A plain file-scope local: a Lua reload resets it,
-- which at worst shows one extra toast -- not worth M.state.
local last_block_toast_at = 0

-- Put the player straight back into their race car after a blocked switch, and surface a throttled
-- toast so a deliberate Tab press is not silently swallowed. Returns false when the race car is gone
-- (so the caller lets the switch through rather than trapping the player). Mirrors the race-prop bounce
-- (props.enforce_non_enterable), but race-car-general and with the in-race feedback toast.
--
-- `silent` suppresses only the toast, never the log line: the staging caller passes it because every
-- switch reaching it there is engine-driven rather than a player key press (see onVehicleSwitched).
local function bounce_to_race_car(silent)
    local race_car = be and be:getObjectByID(M.state.race_car_id)
    if not race_car then
        return false
    end
    local ok, err = pcall(function() be:enterVehicle(0, race_car) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not bounce player back to race car: " .. tostring(err))
        return false
    end
    local now = os.clock()
    if not silent and now - last_block_toast_at >= SWITCH_BLOCK_TOAST_THROTTLE then
        last_block_toast_at = now
        notice.say("Vehicle switching is locked during the race", "warning")
    end
    log("I", RACE_LOG_TAG, "blocked vehicle switch -- bounced player back to race car")
    return true
end

-- Whether a game vehicle id is one of this client's AI cars (ADR-0036): the host's spawned ai_cars or, on
-- a non-owner, a synced car resolved from the relayed aiMap (ai_remote_ids). Used to keep the player out
-- of an AI car the same way cones are kept non-enterable.
local function is_ai_game_id(game_id)
    if game_id == nil then
        return false
    end
    local cars = M.state.ai_cars
    if cars then
        for _, car in ipairs(cars) do
            if tostring(car.veh_id) == tostring(game_id) then
                return true
            end
        end
    end
    local remote = M.state.ai_remote_ids
    if remote then
        for id in pairs(remote) do
            if tostring(id) == tostring(game_id) then
                return true
            end
        end
    end
    return false
end

-- Put the player back into their last real car after they switched into an AI car (ADR-0036), the prop
-- bounce generalized to the AI cars (which are real car models, so props.is_race_prop does not catch
-- them). The fallback is current_vehicle_id, which the prop rule guarantees is never a prop itself. No
-- fallback car id -> no-op so the player is never trapped. Returns true if it bounced.
local function bounce_off_ai(new_id)
    local fallback_id = M.state.current_vehicle_id
    if not be or fallback_id == nil or tostring(new_id) == tostring(fallback_id) then
        return false
    end
    local fallback = be:getObjectByID(fallback_id)
    if not fallback then
        return false
    end
    return pcall(function() be:enterVehicle(0, fallback) end)
end

-- Track the vehicle the player is currently in, keep them in their race car for the whole locked race
-- sequence, and keep them out of the race's prop vehicles at all times. BeamNG fires
-- onVehicleSwitched(old, new) on every switch -- a player-driven one AND the engine's own auto-enter
-- after a spawn, which is what a race prop rides in on.
--
-- Outside those rules we keep the latest `new` as the authoritative seated car, because in BeamMP the
-- polling API be:getPlayerVehicle(0) sticks to the first owned car -- so race/vehicles.lua
-- resolve_own_car prefers this tracked id (confirmed in-game). Every bounce branch returns WITHOUT
-- recording, so a prop / AI car / blocked switch never becomes current_vehicle_id (the checkpoint
-- detector must keep reading the real race car, and bounce_off_ai must never fall back onto a prop).
--
-- The three rules, in order:
--   1. RACE PROPS (bug race-prop-steals-player-seat) -- cones, the powered grinders, and any known
--      non-car model while a race runs. First and phase-independent, because a prop auto-enter can land
--      in ANY phase -- including staging (the reported case) and the part of handle_race_start where
--      race_car_id is still nil, neither of which rule 2 covers. The player's own assigned race car is
--      exempted up front so a mis-read model Type can never bounce them out of the car they are racing.
--   2. THE RACE SEAT LOCK -- during staging + countdown + racing + qualifying any switch away from the
--      race car is bounced back to it. staging is included because switching cars is not allowed there
--      either (the staging relaxation is a model/parts REPLACE, which keeps the same vehicle id, so an
--      id comparison can never fight it -- lock.lua replace_seen, restage_swapped_car). When the race
--      car is gone the bounce is skipped so the player is never trapped.
--   3. AI CARS (ADR-0036) -- real car models, so rule 1 does not catch them.
function M.onVehicleSwitched(_oldId, newId)
    local phase = M.state.phase
    local race_car_id = M.state.race_car_id
    local is_race_car = race_car_id ~= nil and tostring(newId) == tostring(race_car_id)
    local race_active = M.state.race ~= nil
    if not is_race_car and props.is_race_prop(be and be:getObjectByID(newId), race_active) then
        props.enforce_non_enterable(newId, race_car_id, M.state.current_vehicle_id)
        return
    end
    if (phase == "staging" or phase == "countdown" or phase == "racing" or phase == "qualifying")
            and race_car_id ~= nil and not is_race_car then
        -- Silent in staging: the swap-allowed lock already blocks every switch key there, so a switch
        -- that still arrives is engine-driven (a prop or AI auto-enter) and toasting the player about a
        -- lock they never hit would be pure noise. The log line is kept in both cases.
        if bounce_to_race_car(phase == "staging") then
            return
        end
    end
    -- Keep the player out of an AI car (ADR-0036) and never record it as the seated car, so the detector
    -- keeps reading the real own car.
    if is_ai_game_id(newId) then
        bounce_off_ai(newId)
        return
    end
    M.state.current_vehicle_id = newId
end

-- Min seconds between reload re-arms. One config respawn raises several vehicle-lifecycle events
-- (onVehicleResetted plus the onVehicleSpawned of its despawn/respawn cycle); this collapses them into a
-- single re-arm so nothing stacks or re-fires. os.clock() is monotonic CPU seconds -- far shorter than any
-- human vehicle-config interaction, so a genuine second tune is never swallowed. File scope (not M.state):
-- a Lua reload only forgets it, which at worst allows one redundant re-arm.
local RELOAD_REARM_THROTTLE = 0.5
local last_reload_rearm_at = 0

-- Re-arm the per-vehicle race mechanics IN PLACE after the player's own race car is reset/reloaded at ANY
-- point of a running race. Applying a change in the vehicle config menu -- tyre pressure, paint, any
-- tuning -- runs veh:respawn(config) (BeamNG partmgmt.mergeConfig), which reloads the car's jbeam in place
-- (the car STAYS on its slot, same game id) but re-instantiates its VE. That drops everything BeamComp
-- installed on the old VE: the recover/repair override (the "5s reset", ADR-0017) plus, in the frozen
-- windows, the movement freeze -- both the GE controller freeze (controller.setFreeze resets on the VE
-- reload) and the EV throttle clamp. Unlike a model/config SWAP it never goes through replaceVehicle, so
-- restage_swapped_car never sees it.
--
-- The override matters in EVERY racing phase, not just where the car must stay put: the two recover keys
-- are deliberately NOT action-filtered during a race (ADR-0017 decision 1 -- the VE override owns them),
-- so once the override is gone Insert / Ctrl+Insert are plain VANILLA recover for the rest of the race,
-- even in a race whose recover assist is switched off (bug recover-unguarded-when-assists-disabled). GE's
-- one-shot arm flag survives the reload, so nothing re-installs it unless this handler clears it.
--
-- Hence the split contract:
--   * ALWAYS (every phase in which onUpdate pushes the arm) -- clear assist_armed so push_assist_arm
--     re-installs the override on the reloaded VE.
--   * ONLY where the car is supposed to be standing (hold.is_frozen_phase) -- re-assert the GE controller
--     freeze (holds combustion + EV bodies) and clear freeze_hold_armed so push_freeze_hold re-pushes the
--     EV clamp. Re-freezing a car that is meant to be DRIVING would be the worse bug.
--
-- Re-freeze IN PLACE. Do NOT re-place/teleport/respawn the car (an earlier deferred-restage re-place
-- looped: each re-place raised another spawn event -> re-arm -> re-place). Queued VE commands buffer until
-- the reloaded VM is ready (the hooks fire post-respawn, like the engine's own setGravity-at-spawn), so no
-- explicit wait is needed -- and none of this raises a spawn/reset event, so it cannot loop. Called from
-- BOTH onVehicleResetted and onVehicleSpawned, since a config respawn can raise either hook; the throttle
-- collapses the duplicates.
local function rearm_own_car_on_reload(vehicle_id)
    -- Exactly the phases in which onUpdate pushes the arm (the push_assist_arm gate below) -- staging, the
    -- countdown, racing and both qualifying phases; a quali HOLD is inside `qualifying` and needs no extra
    -- term. Keep the two lists in step. Everywhere else the handler stays a no-op: with no race, in
    -- `finished` and in the lobby disarm_assist_ve has already restored the vanilla functions, so a re-arm
    -- there would resurrect the override in free-roam.
    if not M.state.race then
        return
    end
    local phase = M.state.phase
    if phase ~= "staging" and phase ~= "countdown" and phase ~= "racing"
            and phase ~= "qualifying" and phase ~= "qualiResults" then
        return
    end
    -- Only the player's own staged race car matters; a reset keeps the same game id, so compare against
    -- the tracked race car. An AI car (host-owned) reset or any other vehicle is ignored.
    local race_id = M.state.race_car_id
    if race_id == nil then
        return
    end
    if tostring(vehicle_id) ~= tostring(race_id)
            and tostring(vehicle_id) ~= tostring(M.state.current_vehicle_id) then
        return
    end
    -- Collapse the several lifecycle events one respawn raises into a single re-arm (also stops any stray
    -- repeat from re-freezing every frame).
    local now = os.clock()
    if now - last_reload_rearm_at < RELOAD_REARM_THROTTLE then
        return
    end
    last_reload_rearm_at = now
    -- The freeze half runs only where the car is supposed to be standing still: the staging wait, a
    -- numeric countdown, or a qualifying HOLD. hold.is_frozen_phase() is the SAME predicate the EV clamp
    -- arms on, F1-lights carve-out included -- during a light start the phase is still `countdown` while
    -- ADR-0043 has already freed the car, and re-freezing it there would strand the driver at lights-out.
    local freeze_note = " (drivable phase: not re-frozen)"
    if hold.is_frozen_phase() then
        -- Re-assert the GE controller freeze in place (no teleport) -- the config respawn reset it, and it
        -- is what holds a combustion car (the EV clamp only holds EVs). set_vehicle_frozen reports a
        -- missing car itself, so the note below never claims a freeze that did not happen.
        local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
        local frozen, freeze_err = vehicles.set_vehicle_frozen(own_car, true)
        freeze_note = frozen and " + re-froze in place" or " + re-freeze failed"
        if not frozen then
            log("W", RACE_LOG_TAG, "could not re-freeze the reset car: " .. tostring(freeze_err))
        end
        -- Paired with the freeze: onUpdate re-pushes the EV throttle clamp to the reloaded VE.
        M.state.freeze_hold_armed = false
    end
    -- Every phase: the recover/repair override died with the old VE, and this flag surviving the reload is
    -- what kept push_assist_arm from re-installing it (-> the recover keys fell back to vanilla).
    M.state.assist_armed = false
    -- No cause claim: a vehicle-config reapply is the usual trigger, but the widened phase list also
    -- catches the quali re-grid's repair-reset, so the line reports the phase and what was done.
    log("I", RACE_LOG_TAG, "own race car reset/reloaded in " .. tostring(phase)
        .. "; re-armed assist" .. freeze_note)
end

-- Every vehicle appearing in the scene passes here -- the host's own prefab spawns, the AI field, and
-- every BeamMP-synced car and prop on every client. Four consequences are drawn from that, and the
-- nametag one is deliberately the cheapest: this hook only ARMS the work, it does not do it.
--
-- Arming rather than deciding matters. A spawn lands in the middle of handle_race_start (the own car,
-- then the AI field, all synchronous), so a decision taken here would read a half-built M.state and
-- could mistake this client's own fresh race car for a prop. onUpdate runs after the handler has
-- finished, where race_car_id and ai_cars are both current (ADR-0062).
function M.onVehicleSpawned(vehicleId)
    if not be then
        return
    end
    local veh = be:getObjectByID(vehicleId)
    -- Cones only, on purpose: exclude_from_cycle sets isParkingVehicle, and its effect on a POWERED prop
    -- is unverified while a grinder MUST keep spinning (ADR-0020 amendment). Keeping a grinder in the Tab
    -- cycle costs nothing -- switching is input-blocked for the whole race, the grinders are deleted at
    -- race end, and onVehicleSwitched bounces the player out of one anyway (bug
    -- race-prop-steals-player-seat).
    cones.exclude_from_cycle(veh)
    -- A powered prop appearing while we own the race's props is BeamMP re-spawning one it just deleted (its
    -- ownership round-trip, ~5 s after the prefab load). While a window is open its per-frame rescan adopts
    -- the newcomer by itself; this branch is for the case the rescan cannot cover -- a re-spawn that lands
    -- after the window has already closed. Re-opening a seedless window is enough: its first frame discovers
    -- whatever is in the scene. Gated on an active race so a spinner spawned in free-roam is never driven
    -- (bug race-prop-steals-player-seat round 3).
    if M.state.prop_owner and M.state.race and not M.state.grinder_activate
            and grinders.is_grinder(veh) then
        M.state.grinder_activate = grinders.arm(nil)
        log("I", RACE_LOG_TAG, "powered prop re-spawned after the activation window closed; re-opening it")
    end
    -- A freshly synced vehicle may be one of the owner's AI cars (ADR-0036): try to resolve the pending
    -- aiMap now so it is labelled + nametag-suppressed as soon as it appears. No-op when nothing pending
    -- or on the owner (it has no ai_server_ids).
    resolve_remote_ai()
    -- A config/tuning respawn during a race can surface as a re-spawn of the same race car (a reload runs a
    -- despawn/respawn cycle), so re-arm the assist override -- and, in the frozen windows, the freeze --
    -- here too. The guard no-ops for cones, AI, remotes, and any vehicle that is not the player's own race
    -- car -- see onVehicleResetted, the primary hook.
    rearm_own_car_on_reload(vehicleId)
    -- Host: a vehicle appearing while we own this race's props may BE a prop -- either one the prefab load
    -- just created, or BeamMP re-spawning one under a new id ~5 s later (memory
    -- beammp-respawns-prefab-vehicles-under-new-ids). Re-arm the derivation; onUpdate re-runs the diff and
    -- re-sends the map only if it actually changed (ADR-0062).
    if M.state.prop_before then
        M.state.prop_map_pending = true
        M.state.prop_map_budget = identity.PROP_MAP_BUDGET
    end
    -- Everyone: a new entry in BeamMP's vehicle table starts tagged with its owner's name, so whatever
    -- this client already knows about props, AI and race names is applied to it now instead of at the
    -- next sweep.
    identity.apply_tags()
end

-- BeamNG fires this GE hook (lua/ge/main.lua vehicleReset -> extensions.hook('onVehicleResetted', vid))
-- whenever a vehicle is reset/reloaded in place -- including a vehicle-config reapply (tyre pressure,
-- paint) at any point of a race, which runs veh:respawn(config). Re-arm the player's recover/repair assist
-- on the reloaded VE, and re-freeze the car in place where it is supposed to be standing;
-- rearm_own_car_on_reload guards phase, ownership, and throttling, so a reset of any other car or outside
-- a running race is a no-op.
function M.onVehicleResetted(vehicleId)
    rearm_own_car_on_reload(vehicleId)
end

-- BeamNG fires this GE hook (lua/vehicle/ai.lua queues onAiRouteDone(<id>) when a car stops at the end of
-- its AI path; lua/ge/main.lua dispatches it to every extension) -- the engine telling us an AI ran out of
-- route. For a car on a rolling route window that is a FAILURE report: the seamless refill extends the
-- live path, and pathExtend does nothing at all -- silently -- if its joint does not line up, which looks
-- exactly like "the NPC just stopped". race/ai.lua re-arms the rest of that car's route and logs why; it
-- no-ops for a car whose race really is over, one that is held, and every non-AI vehicle.
function M.onAiRouteDone(vehicleId)
    ai.route_done(M.state.ai_cars, M.state.ai_window, M.state.quali_ai_held, vehicleId)
end

-- Send a typed { type, payload } envelope to the server -- the client->server mirror of the server's
-- send_event (ADR-0004, ADR-0011). Encode via the shared module (the client already loads it for
-- decode), then ship the string with TriggerServerEvent, a GE global present only inside an MP
-- session. Reliable + ordered TCP, so fire-and-forget. Generic so later client->server messages (e.g.
-- spawn-ready acks) reuse it. Forward-declared above (local) so handlers defined earlier can call it.
function send_to_server(message_type, payload)
    if not TriggerServerEvent then
        return
    end
    local ok, encoded = pcall(envelope.encode, message_type, payload)
    if not ok then
        log("W", LOG_TAG, "could not encode '" .. message_type .. "' for server: "
            .. tostring(encoded))
        return
    end
    -- The envelope is already encoded here, so its size is free to take (bug offroad-race-massive-
    -- network-payload-lag): this is the client->server measurement point -- it is what shows the
    -- raceValidation weighing tens of KB, and what proves the ADR-0046 gate brought it down.
    --
    -- ONE exemption: the password attempt (ADR-0056). netsize.note logs a "payload peak" line naming the
    -- type and the byte count, and this envelope is otherwise fixed-size -- so the number would put the
    -- password's LENGTH in the client log. There is nothing to diagnose here either: it is a one-shot
    -- message of a few dozen bytes, while the instrumentation exists for the multi-kilobyte ones.
    if message_type ~= setup.MSG_UNLOCK then
        netsize.note(message_type, #encoded)
    end
    local sent, err = pcall(TriggerServerEvent, EVENT_CHANNEL, encoded)
    if not sent then
        log("W", LOG_TAG, "TriggerServerEvent failed for '" .. message_type .. "': "
            .. tostring(err))
    end
end

-- Park the local car for the rest of a CIRCUIT qualifying window (ADR-0041 amendment, bug
-- quali-hold-reset-and-repaint-leak): the driver closed a lap inside the finish-your-lap grace, so their
-- session is over -- they are held exactly as a done driver is in the staged sprint (ADR-0044), instead of
-- driving on in a session they are no longer scored in. The car is released again by the quali re-grid,
-- which teleports + repairs it onto the earned race grid.
--
-- Accepted trade-off (user decision 2026-07-12): on a circuit everyone laps at once, so a parked car is a
-- static obstacle on the racing line while the others finish their lap. Chosen for consistency with the
-- staged sprint; if it proves disruptive live, drop the freeze here -- the recover-key guard is an
-- independent layer and keys off hold.is_held() alone.
function hold.circuit_run()
    M.state.quali_lap_done = true
    local own = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if own then
        local frozen, err = vehicles.set_vehicle_frozen(own, true)
        if not frozen then
            log("W", RACE_LOG_TAG, "quali hold: could not park the finished car: " .. tostring(err))
        end
    end
    -- Block the recover keys and (via the same predicate) arm the EV throttle clamp + the re-freeze after a
    -- vehicle-config respawn, so the freeze cannot be thrown off again.
    hold.sync()
    log("I", RACE_LOG_TAG, "quali hold: lap closed in the grace window; car parked for the session")
    notice.say("Qualifying run complete -- your car stays parked until the session ends", "info")
end

-- Surface one detected checkpoint passage: log + centred readout + report to the server. This is the
-- single emission seam for a passage -- keep it the one place a passage is reported. The report carries
-- `seq` (the plan ordinal, the server's ordering key), `lap`, the display `index`/`name`, the time,
-- and `count` (total scored crossings) so the race-blind server (ADR-0005) tracks progress and the
-- The session sector reference (the field's best time per sector) AND its companion crossing
-- counter, as two return values -- ONE derivation for the crossing-time freeze, the bar
-- re-evaluation and the readout (feature quali-sector-progress-bar, Round 3/4). Staged sprint: the
-- server-relayed field bests + counts (`sectorBests`/`sectorCounts`, folded per scored crossing,
-- ADR-0044). Circuit: derived from the live standings splits (ADR-0015; the raw broadcast entries
-- carry .splits/.run_up), where session_reference returns both values. The counter feeds the
-- round-4 white->purple upgrade (a still-fastest sector turns purple once a SECOND scoring exists).
-- Both sources update only on a server broadcast, so a value read synchronously at crossing time
-- can never contain that crossing itself. nil when no reference/count exists yet. On the quali
-- namespace table -- init.lua sits at 186/200 top-level locals.
function quali.sector_session_reference(cps)
    if M.state.quali_staged then
        local queue = M.state.quali_queue
        local relayed = queue and queue.sectorBests
        local counts = queue and queue.sectorCounts
        return (type(relayed) == "table") and relayed or nil,
            (type(counts) == "table") and counts or nil
    end
    return sectors.session_reference(M.state.standings, cps)
end

-- final crossing without parsing the race (ADR-0011, ADR-0013).
local function on_checkpoint_reached(event, count)
    log("I", RACE_LOG_TAG, string.format("checkpoint %d (%s) lap %d reached @ %.2fs (seq %d)",
        event.index, tostring(event.name), event.lap, event.time, event.seq))
    notice.checkpoint(event, count)
    -- A scored crossing of the start/finish line closes a lap on the display clock (ADR-0022). The
    -- start node is the only plan entry at that stable index, so this fires once per lap, never on the
    -- body checkpoints. Done before the report so the report carries the just-completed lap's best.
    local lt = M.state.laptimer
    if lt and lt.start_cp and event.index == lt.start_cp.index then
        laptimer.complete_lap(lt, event.time)
        -- During the qualifying finish-your-lap window (ADR-0041), completing a lap ends this driver's
        -- quali: stop the detector after this crossing is reported, so no further checkpoints are scored or
        -- shown for them, and park the car for the rest of the window (ADR-0041 amendment). The report below
        -- still carries this lap's best time. Circuit only by construction -- a staged sprint run has no lap
        -- clock (quali.launch_local nils it), so it can never reach this branch.
        if M.state.phase == "qualifying" and M.state.grace then
            M.state.detection = nil
            hold.circuit_run()
        end
    end
    -- Qualifying live sector delta (feature: quali-live-sector-delta): record this crossing's just-completed
    -- sector (split time, per-sector personal best, lap cumulative) for the HUD readout; lt.run_up bases
    -- lap 1's first sector on the start/finish line so it reads clean line-to-line. The current session
    -- sector reference rides along to be FROZEN as this sector's pre-crossing field best (Round 3): read
    -- synchronously before the report below is sent, it cannot contain this crossing -- so the first-ever
    -- time in a sector classifies "normal", never purple/green against its own relayed-back value.
    if M.state.phase == "qualifying" and M.state.sector_track then
        -- Parenthesised: the helper returns (reference, counts); only the reference is frozen here.
        sectors.on_crossing(M.state.sector_track, event.seq, event.time, lt and lt.run_up or nil,
            (quali.sector_session_reference(M.state.sector_track.cps)))
    end
    -- `bestLap` rides the existing report as an additive field: the server stores the latest per
    -- player and relays it in the standings (ADR-0022) so the results card can show every player's
    -- best lap. The server stays race-blind -- it just passes the number through (ADR-0005).
    -- `runUp` rides along the same way: the gun -> start/finish line run-up (lap 1's real start), so
    -- the analysis overlay can show it as S0 and clean it out of lap-1 times for every driver
    -- (ADR-0028). Set once the line is crossed, which is before this first report, so it is present
    -- from the first scored crossing onward.
    send_to_server("checkpoint", {
        seq = event.seq,
        index = event.index,
        name = event.name,
        lap = event.lap,
        time = event.time,
        count = count,
        bestLap = lt and lt.best or nil,
        runUp = lt and lt.run_up or nil,
    })
end

-- Step the checkpoint detector for one racing frame: resolve this client's own car (the tracked
-- seated id, BeamMP-correct -- see race/vehicles.lua), read its world position, and advance the
-- detector. Emits each crossed checkpoint through on_checkpoint_reached. No-op until armed
-- (M.state.detection set on the racing phase) and once the sequence is done.
local function step_detection(dt_sim)
    local detection = M.state.detection
    local race = M.state.race
    if not detection or detection.done or not race or not race.checkpoints then
        return
    end

    local veh_pos = nil
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if own_car then
        local ok, pos = pcall(function() return own_car:getPosition() end)
        if ok then
            veh_pos = pos
        end
    end

    local event = checkpoints.step(detection, race.checkpoints, veh_pos, dt_sim)
    if event then
        on_checkpoint_reached(event, detection.plan.count)
    end

    -- Advance the circuit lap clock with the same car position + race clock (ADR-0022). Until it
    -- arms on the first start/finish crossing this watches the line; after that it is a no-op and
    -- lap boundaries arrive through on_checkpoint_reached above.
    if M.state.laptimer then
        laptimer.step(M.state.laptimer, veh_pos, detection.elapsed)
    end
end

-- Host only: step each AI car's checkpoint detector and report its crossings to the server by proxy
-- (ADR-0036). The owner drives the AI cars locally, so it reads each car's position and runs the same
-- ADR-0010 detector against the same plan as a player, sending every crossing as a normal checkpoint
-- report tagged with aiId -- the server routes it into that AI's progress record. Race-blind: an
-- identical report plus one field. No-op for non-owners (no ai_detections) and once a detector is done.
local function step_ai_detections(dt_sim)
    local detections = M.state.ai_detections
    local cars = M.state.ai_cars
    local race = M.state.race
    local laptimers = M.state.ai_laptimers
    if not detections or not cars or not race or not race.checkpoints then
        return
    end
    for _, car in ipairs(cars) do
        local detection = detections[car.id]
        if detection and not detection.done then
            local veh_pos = nil
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                local ok, pos = pcall(function() return veh:getPosition() end)
                if ok then
                    veh_pos = pos
                end
            end
            local event = checkpoints.step(detection, race.checkpoints, veh_pos, dt_sim)
            -- Circuit only (nil otherwise): the AI's lap clock mirrors the player's path (step_detection +
            -- on_checkpoint_reached). A scored start/finish crossing closes a lap, folding in the best before
            -- the report; the report then carries this AI's best lap + run-up so the server stores them by
            -- proxy exactly like a player (ADR-0036/0022). Both stay nil on a sprint -> harmless.
            local ai_lt = laptimers and laptimers[car.id]
            -- Circuit quali (bug quali-end-ai-not-frozen): does this crossing end the AI's session? The exact
            -- predicate on_checkpoint_reached uses for the player -- a scored start/finish crossing that
            -- closes a lap while the finish-your-lap grace is running. The park itself happens AFTER the
            -- report below, which still has to read the live detector (detection.plan.count) and carry this
            -- lap's best time, just as the player's report does.
            local session_over = false
            if event then
                if ai_lt and ai_lt.start_cp and event.index == ai_lt.start_cp.index then
                    laptimer.complete_lap(ai_lt, event.time)
                    session_over = M.state.phase == "qualifying" and M.state.grace ~= nil
                end
                send_to_server("checkpoint", {
                    -- Proxy tag (ADR-0036): the server records this crossing into the AI slot's progress,
                    -- not the owner's. Accepted only from the race owner for a known AI id (server-side).
                    aiId = car.id,
                    seq = event.seq,
                    index = event.index,
                    name = event.name,
                    lap = event.lap,
                    time = event.time,
                    count = detection.plan.count,
                    bestLap = ai_lt and ai_lt.best or nil,
                    runUp = ai_lt and ai_lt.run_up or nil,
                })
                log("I", RACE_LOG_TAG, string.format("AI '%s' checkpoint seq %d @ %.2fs",
                    tostring(car.label), event.seq, event.time))
                if session_over then
                    -- The AI's qualifying session is over: park it exactly as hold.circuit_run parks the
                    -- player -- ai.stop + freeze IN PLACE, no teleport (user decision 2026-08-08) -- and mark
                    -- it held so quali.step_ai_hold keeps it there. quali.hold_ai drops this AI's detector, so
                    -- nothing further is scored or reported for it, mirroring the player's `detection = nil`.
                    -- quali.note_ai_park says WHY and against which clock; quali.hold_ai then logs the hold.
                    quali.note_ai_park(car, event)
                    quali.hold_ai(car.id, true)
                end
            end
            -- Swept run-up test after the detector, mirroring step_detection's trailing laptimer.step: the
            -- first start/finish crossing arms run_up (gun -> line); a no-op once armed. Skipped for an AI
            -- just parked -- its session is over, and its detector is gone.
            if ai_lt and not session_over then
                laptimer.step(ai_lt, veh_pos, detection.elapsed)
            end
        end
    end
end

-- The lap the local player is currently on, read from the detector's plan: the lap of the next plan
-- entry, or the final entry's lap once done (ADR-0013). Defaults to 1 when there is no plan.
local function detection_lap(detection)
    local entries = detection.plan and detection.plan.entries
    if not entries then
        return 1
    end
    local next_entry = entries[detection.seq + 1]
    if next_entry then
        return next_entry.lap
    end
    local last_entry = entries[#entries]
    return last_entry and last_entry.lap or 1
end

-- Per-CP segment times from a cumulative splits array (ADR-0015): segment[k] = splits[k] - splits[k-1],
-- with splits[0] = 0. Mirrors the server's derive_segments -- the analysis overlay derives everything
-- client-side from the broadcast splits (ADR-0028). Returns a 1-based array.
local function derive_segments(splits)
    local segments = {}
    if type(splits) ~= "table" then
        return segments
    end
    local previous = 0
    for k = 1, #splits do
        local cumulative = splits[k]
        if type(cumulative) == "number" then
            segments[k] = cumulative - previous
            previous = cumulative
        end
    end
    return segments
end

-- A human label for a car descriptor (ADR-0029): "model: variant" with a "(mod)" suffix when parts were
-- changed. The variant leaf is derived from the descriptor `key` ("model/variant") rather than a duplicated
-- `variant` field (ADR-0029 amendment, bug partconfig-blob-bloats-standings) -- any directory prefix and the
-- ".pc" extension are stripped, so a full partConfig path like "vehicles/van/offroad_alt.pc" reads as
-- "offroad_alt". nil when there is no car.
local function car_label(car)
    if type(car) ~= "table" then
        return nil
    end
    local label = car.model or "?"
    -- The key is "model" or "model/variant"; the portion after the first "/" is the variant. When present,
    -- show its leaf preset name only (strip any dir prefix + ".pc").
    if type(car.key) == "string" then
        local slash = car.key:find("/", 1, true)
        if slash then
            local short = (car.key:sub(slash + 1):gsub("^.*/", ""):gsub("%.pc$", ""))
            if short ~= "" then
                label = label .. ": " .. short
            end
        end
    end
    if car.modified == true then
        label = label .. " (mod)"
    end
    return label
end

-- Split a cumulative splits array into per-lap section arrays (ADR-0029): lap l has section[s] =
-- splits[(l-1)*cps + s] - splits[(l-1)*cps + s - 1] and total = splits[l*cps] - splits[(l-1)*cps].
-- Only fully-completed laps are returned (a partial final lap from a DNF is dropped). For a sprint
-- (one lap of all CPs) this yields the single run. cps = checkpoints per lap.
--
-- `run_up` (optional, circuit only; ADR-0022/0028) is the gun -> start/finish-line time baked into
-- lap 1: the scored plan starts at CP1 from the gun, so lap 1's first section and total carry the
-- run-up from the grid to the real start of the lap. When given, it is subtracted from lap 1 (and
-- only lap 1) so every lap reads as a clean line-to-line lap. nil / sprint -> no change.
local function laps_from_splits(splits, cps, run_up)
    local laps = {}
    if type(splits) ~= "table" or type(cps) ~= "number" or cps < 1 then
        return laps
    end
    local lap_index = 1
    while lap_index * cps <= #splits do
        local base = (lap_index - 1) * cps
        local base_time = base == 0 and 0 or splits[base]
        local sections = {}
        local ok = type(base_time) == "number"
        for s = 1, cps do
            local cumulative = splits[base + s]
            local prev = (s == 1) and base_time or splits[base + s - 1]
            if ok and type(cumulative) == "number" and type(prev) == "number" then
                sections[s] = cumulative - prev
            else
                ok = false
            end
        end
        if ok then
            local total = splits[base + cps] - base_time
            if base == 0 and type(run_up) == "number" and type(sections[1]) == "number" then
                sections[1] = sections[1] - run_up
                total = total - run_up
            end
            laps[#laps + 1] = {sections = sections, total = total}
        end
        lap_index = lap_index + 1
    end
    return laps
end

-- The fastest completed lap in a list (min total), or nil for an empty list.
local function best_lap_of(laps)
    local best = nil
    for _, lap in ipairs(laps) do
        if type(lap.total) == "number" and (not best or lap.total < best.total) then
            best = lap
        end
    end
    return best
end

-- The mean lap as a {sections, total} pseudo-lap (ADR-0029): each section/total averaged over the laps
-- that have it. nil for an empty list.
local function avg_lap(laps)
    if #laps == 0 then
        return nil
    end
    local section_count = #laps[1].sections
    local sections = {}
    for s = 1, section_count do
        local sum, n = 0, 0
        for _, lap in ipairs(laps) do
            local value = lap.sections[s]
            if type(value) == "number" then
                sum = sum + value
                n = n + 1
            end
        end
        sections[s] = n > 0 and (sum / n) or nil
    end
    local total_sum, total_n = 0, 0
    for _, lap in ipairs(laps) do
        if type(lap.total) == "number" then
            total_sum = total_sum + lap.total
            total_n = total_n + 1
        end
    end
    return {sections = sections, total = total_n > 0 and (total_sum / total_n) or nil}
end

-- A per-section + total delta row of `other` against the `reference` lap (ADR-0029): cell[s].delta =
-- other.sections[s] - reference.sections[s]. Cells are an aligned array so the UI iterates (no numeric
-- indexing across the Lua->JS bridge). Negative = faster than the reference. cps = section count.
local function lap_delta_row(other, reference, cps)
    local cells = {}
    for s = 1, cps do
        local a = other.sections[s]
        local b = reference.sections[s]
        cells[s] = {delta = (type(a) == "number" and type(b) == "number") and (a - b) or nil}
    end
    local total = (type(other.total) == "number" and type(reference.total) == "number")
        and (other.total - reference.total) or nil
    return {cells = cells, total = total}
end

-- The fastest lap across a set of standings entries (optionally filtered to a car key, optionally
-- excluding the local player), as {lap, holder} or nil. Used for "best lap of the other drivers"
-- (ADR-0030).
local function fastest_lap_across(entries, cps, car_key, exclude_local)
    local best, holder = nil, nil
    for _, e in ipairs(entries) do
        if (not exclude_local or not e.isLocal) and (not car_key or (e.car and e.car.key == car_key)) then
            local candidate = best_lap_of(laps_from_splits(e.splits, cps, e.run_up))
            if candidate and (not best or candidate.total < best.total) then
                best, holder = candidate, e.name
            end
        end
    end
    if not best then
        return nil
    end
    return {lap = best, holder = holder}
end

-- A pseudo-lap {sections, total} from a per-section array (e.g. a persistent section-best or average),
-- for diffing against your best lap (ADR-0030). nil when the array is missing or has no numbers.
local function pseudo_lap_from_sections(sections, cps)
    if type(sections) ~= "table" then
        return nil
    end
    local total, has = 0, false
    for s = 1, cps do
        if type(sections[s]) == "number" then
            total = total + sections[s]
            has = true
        end
    end
    return has and {sections = sections, total = total} or nil
end

-- A pseudo-lap of per-section averages from accumulated section sums + lap count (ADR-0030, #4). nil when
-- there is no data.
local function avg_lap_from_sums(section_sum, lap_count, cps)
    if type(section_sum) ~= "table" or type(lap_count) ~= "number" or lap_count < 1 then
        return nil
    end
    local sections = {}
    for s = 1, cps do
        if type(section_sum[s]) == "number" then
            sections[s] = section_sum[s] / lap_count
        end
    end
    return pseudo_lap_from_sections(sections, cps)
end

-- Driver section (ADR-0030): the local player's own history as an any-car / this-car table -- runs and
-- time over all tracks, track records held, runs here, and best time here. Each row carries `kind` so the
-- UI formats it (count / duration / time). Tolerant of missing fields -> zeros / nil placeholders.
local function build_driver_section(records, local_name)
    if type(records) ~= "table" then
        return nil
    end
    local pb = type(records.pb) == "table" and records.pb or {}
    local pb_car = type(pb.car) == "table" and pb.car or {}
    local totals = type(records.driverTotals) == "table" and records.driverTotals or {}
    local any = type(totals.anyCar) == "table" and totals.anyCar or {}
    local this = type(totals.thisCar) == "table" and totals.thisCar or {}
    return {
        name = local_name,
        carLabel = car_label(records.car),
        rows = {
            {label = "Runs (all tracks)", kind = "count",
                any = any.run_count or 0, this = this.run_count or 0},
            {label = "Time (all tracks)", kind = "duration",
                any = any.time_sum or 0, this = this.time_sum or 0},
            {label = "Track records held", kind = "count",
                any = any.records_held or 0, this = this.records_held or 0},
            {label = "Runs here", kind = "count",
                any = pb.run_count or 0, this = pb_car.run_count or 0},
            {label = "Best here", kind = "time",
                any = pb.best_lap or pb.best_total, this = pb_car.best_lap or pb_car.best_total},
        },
    }
end

-- The pre-run headline value of a record leaf (best lap on a circuit, else total time), or nil.
local function old_record_value(leaf)
    if type(leaf) ~= "table" then
        return nil
    end
    return leaf.best_lap or leaf.total_time
end

-- Track section (ADR-0029): this track's totals across all players, plus the track record (any car /
-- this car) with holders, and the pre-run "old record" headline when this run beat it. Tolerant of
-- missing fields.
local function build_track_section(records, race_name)
    if type(records) ~= "table" then
        return nil
    end
    local track = type(records.trackRecord) == "table" and records.trackRecord or nil
    local track_car = track and type(track.car) == "table" and track.car or nil
    -- Pre-run record headlines (captured before this run folded in): show "old record" only when this
    -- run actually beat the standing one, i.e. an old value exists and differs from the current. Same
    -- opaque store number on both sides, so an exact compare is safe (no float tolerance needed).
    local prerun = type(records.prerun) == "table" and records.prerun or {}
    local record_any_car = track and (track.best_lap or track.total_time) or nil
    local record_this_car = track_car and (track_car.best_lap or track_car.total_time) or nil
    local old_any = prerun.trackRecordAnyCarOld
    local old_this = prerun.trackRecordThisCarOld
    local old_any_val = old_record_value(old_any)
    local old_this_val = old_record_value(old_this)
    local beat_any = old_any_val ~= nil and old_any_val ~= record_any_car
    local beat_this = old_this_val ~= nil and old_this_val ~= record_this_car
    return {
        name = race_name,
        trackRuns = track and track.run_count or 0,
        trackTime = track and track.time_sum or 0,
        carRuns = track_car and track_car.run_count or 0,
        recordAnyCar = record_any_car,
        recordAnyCarHolder = track and track.holder or nil,
        recordAnyCarLabel = track and car_label(track.recordCar) or nil,
        recordAnyCarOld = beat_any and old_any_val or nil,
        recordAnyCarOldHolder = beat_any and old_any.holder or nil,
        recordThisCar = record_this_car,
        recordThisCarHolder = track_car and track_car.holder or nil,
        recordThisCarOld = beat_this and old_this_val or nil,
        recordThisCarOldHolder = beat_this and old_this.holder or nil,
        carLabel = car_label(records.car),
    }
end

-- Race section (ADR-0030): this race's lap analysis. Reference = your best lap this race (absolute
-- sections + total). Then per-section delta rows against five references: the other drivers' best lap
-- this race, your best lap with the car ever (pre-run), your average this race, your average with the car
-- over all sessions here (persistent), and the car's track record (pre-run). The two average rows are
-- dropped for a single-lap run (sprint). All derived client-side from the splits + the payload; nil when
-- there is no local entry or no completed lap.
local function build_race_section(entries, race, local_entry, records)
    local cps = (race and race.checkpoints) and #race.checkpoints or 0
    if cps < 1 or not local_entry then
        return nil
    end
    -- Subtract the run-up so lap 1 is a clean line-to-line lap like the rest (circuit only; ADR-0022).
    local my_laps = laps_from_splits(local_entry.splits, cps, local_entry.run_up)
    local my_best = best_lap_of(my_laps)
    if not my_best then
        return nil
    end

    local columns = {}
    local your_best_cells = {}
    for s = 1, cps do
        columns[s] = "S" .. s
        your_best_cells[s] = {value = my_best.sections[s]}
    end

    local prerun = type(records) == "table" and type(records.prerun) == "table" and records.prerun or {}
    local pb_car = type(records) == "table" and type(records.pb) == "table"
        and type(records.pb.car) == "table" and records.pb.car or {}
    local track_car = type(records) == "table" and type(records.trackRecord) == "table"
        and type(records.trackRecord.car) == "table" and records.trackRecord.car or {}

    local rows = {}
    local function add_row(label, pseudo_lap, holder)
        if pseudo_lap then
            local row = lap_delta_row(pseudo_lap, my_best, cps)
            row.label = label
            row.holder = holder
            rows[#rows + 1] = row
        end
    end

    local others = fastest_lap_across(entries, cps, nil, true)
    add_row("Other drivers", others and others.lap, others and others.holder)
    add_row("You, best w/ car", pseudo_lap_from_sections(prerun.playerCarSectionBest, cps))
    if #my_laps > 1 then
        add_row("You, avg this race", avg_lap(my_laps))
    end
    -- Skip the all-time average on the first visit to this track: pb_car is current-inclusive, so with a
    -- single run here the average is just this race's lap(s), making the delta ~0.00 in every section
    -- (ADR-0030). Only meaningful once a prior run exists (run_count > 1).
    if (race and race.mode == "circuit") and (tonumber(pb_car.run_count) or 0) > 1 then
        add_row("You, avg all-time", avg_lap_from_sums(pb_car.section_sum, pb_car.lap_count, cps))
    end
    add_row("Car record", pseudo_lap_from_sections(prerun.trackCarSectionBest, cps), track_car.holder)

    return {
        isCircuit = (race and race.mode == "circuit") or false,
        columns = columns,
        yourBest = {cells = your_best_cells, total = my_best.total},
        rows = rows,
    }
end

-- Build the post-race analysis block from the finished-phase standings and the pre-run records
-- (ADR-0028/0029). Pure client-side derivation -- the race-blind server only ships numbers (ADR-0005).
-- Carries the cross-driver segment matrix (aligned {value, fastest} cells, fastest = column minimum) plus
-- the three sections: Driver (your records), Track (all players), Race (this race's laps from the splits).
-- For circuits the matrix gains a leading S0 column -- the gun -> start/finish run-up -- and the first
-- real segment is cleaned of it, so every lap reads from the real start of the lap (ADR-0022/0028).
-- All cells are aligned arrays so the UI iterates rather than indexing across the Lua->JS bridge. Returns
-- nil with nothing to show.
local function build_analysis(entries, records, race)
    if not entries or #entries == 0 then
        return nil
    end

    -- S0 = the gun -> start/finish-line run-up (ADR-0022/0028). In a circuit the scored splits start at
    -- CP1, so this run-up is baked into the first segment. When any driver reported it, surface it as a
    -- leading S0 column and subtract it from the first segment, so every segment reads from the real
    -- start of a lap (S0 | S1=CP0->CP1 | ...). Sprints have no line crossing and keep S1.. unchanged.
    local with_runup = false
    if (race and race.mode == "circuit") then
        for _, e in ipairs(entries) do
            if type(e.run_up) == "number" then
                with_runup = true
                break
            end
        end
    end

    local max_seg = 0
    local drivers = {}
    for i, e in ipairs(entries) do
        local segments = derive_segments(e.splits)
        if #segments > max_seg then
            max_seg = #segments
        end
        drivers[i] = {
            name = e.name,
            isLocal = e.isLocal,
            dnf = e.dnf,
            position = e.position,
            segments = segments,   -- scratch for the column passes; replaced by cells below
            run_up = e.run_up,     -- scratch for the S0 column / first-segment cleanup
        }
    end
    -- One extra leading column (S0) once the run-up is shown. Reading a driver's value at a 1-based
    -- column maps S0 -> run_up and S{j-1} -> segments[j-1], with the first real segment cleaned of the
    -- run-up so it is line-to-line. Without the run-up column, column j is simply segments[j].
    local segment_count = with_runup and (max_seg + 1) or max_seg
    local function column_value(driver, j)
        if not with_runup then
            return driver.segments[j]
        end
        if j == 1 then
            return driver.run_up
        end
        local k = j - 1
        local seconds = driver.segments[k]
        if k == 1 and type(seconds) == "number" and type(driver.run_up) == "number" then
            return seconds - driver.run_up
        end
        return seconds
    end

    -- Fastest time in each column across drivers (the purple highlight, ADR-0028).
    local column_best = {}
    for j = 1, segment_count do
        local best = nil
        for _, driver in ipairs(drivers) do
            local seconds = column_value(driver, j)
            if type(seconds) == "number" and (not best or seconds < best) then
                best = seconds
            end
        end
        column_best[j] = best
    end

    local columns = {}
    for j = 1, segment_count do
        columns[j] = "S" .. (with_runup and (j - 1) or j)
    end
    for _, driver in ipairs(drivers) do
        local cells = {}
        local total, has_total = 0, false
        for j = 1, segment_count do
            local seconds = column_value(driver, j)
            cells[j] = {
                value = seconds,
                fastest = type(seconds) == "number" and column_best[j] ~= nil
                    and seconds == column_best[j],
            }
            if type(seconds) == "number" then
                total = total + seconds
                has_total = true
            end
        end
        driver.cells = cells
        -- Sum of the shown columns = the driver's total race time (S0 + cleaned S1 == the original
        -- first segment, so the run-up split changes nothing here). A DNF's partial columns sum to a
        -- partial total; nil when nothing crossed, so the UI shows a placeholder rather than 0.
        driver.total = has_total and total or nil
        driver.segments = nil
        driver.run_up = nil
    end

    local local_entry = nil
    local local_name = nil
    for _, e in ipairs(entries) do
        if e.isLocal then
            local_entry = e
            local_name = e.name
            break
        end
    end

    return {
        columns = columns,
        drivers = drivers,
        driver = build_driver_section(records, local_name),
        track = build_track_section(records, race and (race.displayName or race.name) or nil),
        race = build_race_section(entries, race, local_entry, records),
    }
end

-- The local driver's own row in the staged-quali holding queue (ADR-0044), resolved from the broadcast
-- queue snapshot by slot: {status, position, best, name, ai}. nil outside a staged quali or before the
-- first snapshot. Feeds the HUD "you're up / next / Pn queued / running" line + own best time.
function quali.local_row(my_slot)
    local queue = M.state.quali_queue
    if not queue or type(queue.rows) ~= "table" or my_slot == nil then
        return nil
    end
    for _, row in ipairs(queue.rows) do
        if row.slot == my_slot then
            return row
        end
    end
    return nil
end

-- Build the HUD snapshot for the render app (ADR-0012): the full ranked standings list, tagged
-- with the current phase so the app can branch live-HUD vs results template. During racing the
-- local player's row uses the live detector (ticking time, crossing count, lap); during finished
-- it falls back to the server-broadcast values so the frozen final readout matches every other
-- client. `lapCount` is the resolved race lap count (1 for sprint; the HUD shows a lap indicator
-- only when > 1, ADR-0013). Per-entry `splits` (cumulative race-time at each crossing, ADR-0015)
-- rides through opaquely for the results template; the finished phase also derives the analysis
-- block (ADR-0028), and an open provisional card derives its penalized row list (ADR-0043). Pure read
-- of M.state; the server is unaffected.
local function build_hud_snapshot()
    local race = M.state.race
    local detection = M.state.detection
    local standings = M.state.standings
    local phase = M.state.phase
    local my_slot = race and race.mySlot
    local checkpoint_count = (race and race.plan and race.plan.count)
        or ((race and race.checkpoints) and #race.checkpoints) or 0
    local lap_count = (race and race.laps) or 1
    local local_finished = detection and detection.done
    local local_dnf = false
    -- Both racing and qualifying drive the local detector + lap clock (ADR-0041), so the live local-row
    -- substitutions (checkpoint, time, lap clock) apply to both.
    local driving = phase == "racing" or phase == "qualifying"

    local entries = {}
    if standings then
        for i, e in ipairs(standings) do
            local is_local = my_slot ~= nil and e.slot == my_slot
            local checkpoint = e.completed
            local time = e.total_time
            local lap = e.lap or 1
            -- The HUD lap counter shows the *current* lap (1-based): 1/N at the start, N/N on the
            -- final lap and at the finish. `lap` itself stays the server current-lap value (ADR-0013)
            -- the other rows carry.
            local current_lap = nil
            -- Only substitute live detector values for the local row while driving (racing/qualifying) --
            -- once finished, every client must show the same server-authoritative totals.
            if is_local and detection and driving then
                checkpoint = detection.seq
                time = detection.elapsed
                lap = detection_lap(detection)
                current_lap = (detection.done and lap_count) or math.min(lap, lap_count)
            end
            -- Lap clock (ADR-0022): best lap is the server-relayed per-player value (so every results
            -- row has one); the local row prefers its own laptimer for an instant best + the live lap
            -- time. The header CP count is per-lap on a circuit (resets each lap), cumulative on sprint.
            local lap_time = nil
            local best_lap = e.best_lap
            -- Last completed lap for the qualifying right-side lap timer (feature: quali-live-sector-delta):
            -- laptimer already tracks it; local row only. nil until the first lap closes.
            local last_lap = nil
            local cp_in_lap = nil
            local cp_per_lap = nil
            if is_local then
                local_dnf = e.dnf and true or false
                local lt = M.state.laptimer
                if lt then
                    best_lap = lt.best or best_lap
                    last_lap = lt.last_lap
                    if detection and driving then
                        lap_time = laptimer.current(lt, detection.elapsed)
                    end
                end
                if detection and driving then
                    cp_per_lap = (race and race.checkpoints) and #race.checkpoints or checkpoint_count
                    if (race and race.mode == "circuit") and cp_per_lap > 0 then
                        -- Per-lap reset, but the final lap counts through to N/N at the finish line
                        -- (done) instead of wrapping back to 0 -- flips together with current_lap.
                        cp_in_lap = (detection.done and cp_per_lap) or (detection.seq % cp_per_lap)
                    else
                        cp_in_lap = detection.seq
                    end
                end
            end
            -- Stable per-row key for the client's position-gain flash (keyed across frames, independent of
            -- the standings windowing): the server slot when present, else the canonical name (ADR-0054).
            entries[i] = {
                id = (e.slot ~= nil and "s" .. tostring(e.slot)) or ("n" .. tostring(e.name)),
                position = e.position,
                name = e.name,
                checkpoint = checkpoint,
                count = e.count or checkpoint_count,
                time = time,
                finished = e.finished,
                dnf = e.dnf,
                isLocal = is_local,
                lap = lap,
                currentLap = current_lap,
                lapCount = lap_count,
                lapTime = lap_time,
                lastLap = last_lap,  -- last completed lap (local row), for the quali lap timer
                bestLap = best_lap,
                cpInLap = cp_in_lap,
                cpPerLap = cp_per_lap,
                splits = e.splits,
                run_up = e.run_up,  -- gun -> start/finish run-up (ADR-0022), for the analysis S0 column
                -- Driver's car (ADR-0029), for the Race section's "best lap with the car". No longer on the
                -- standings entry (ADR-0029 amendment, bug partconfig-blob-bloats-standings) -- joined from the
                -- one-shot carInfo cache by the participant id, so a standings broadcast stays car-size-independent.
                car = M.state.car_info and e.id ~= nil and M.state.car_info[tostring(e.id)] or nil,
                ai = e.ai or nil,  -- synthetic host-driven AI slot (ADR-0036), so the row can be tagged
                jumpPenalty = e.jump_penalty,  -- F1 jump-start penalty seconds (ADR-0043); HUD tags "+Ns"
                reaction = e.reaction,  -- F1 start reaction seconds (ADR-0043); HUD React column, neg = jump
            }
        end
    end

    -- Gap (vs leader) and interval (vs entry ahead), computed at the highest checkpoint both have
    -- crossed (their splits arrays, ADR-0015). At the same shared crossing the comparison is fair
    -- regardless of who has since progressed further: positive = entry is behind. For two finishers
    -- the shared crossing is the final one, so the value equals the total-time delta. DNF rows and
    -- pairs without a shared crossing leave the fields nil; the template renders a placeholder.
    local function shared_split_gap(entry, reference)
        local a, b = entry.splits, reference.splits
        if not a or not b then
            return nil
        end
        local shared = math.min(#a, #b)
        if shared <= 0 then
            return nil
        end
        return a[shared] - b[shared]
    end

    -- The interval column's reference is the local live-standings view mode (ADR-0012): "self" (every
    -- row vs the local player, default), "ahead" (vs the car directly ahead), or "leader" (vs P1). The
    -- finished results card always reads the vs-ahead interval, so the frozen card is identical for every
    -- client regardless of each viewer's mode. `cpInterval` (signed raw crossing difference, no lap
    -- conversion) follows the same reference; the HUD shows it alongside the time when |gap| > 1 CP.
    local interval_mode = (phase == "racing" and M.state.interval_mode) or "ahead"
    local local_entry = nil
    for i = 1, #entries do
        if entries[i].isLocal then
            local_entry = entries[i]
            break
        end
    end

    local leader = entries[1]
    if leader and not leader.dnf then
        for i = 1, #entries do
            local entry = entries[i]
            if not entry.dnf then
                if i > 1 then
                    entry.gap = shared_split_gap(entry, leader)
                    -- Completed-crossing gap to the leader (mode-independent); the provisional card shows
                    -- it alongside the leader time when more than one checkpoint apart.
                    entry.cpGap = leader.checkpoint - entry.checkpoint
                end
                local reference
                if interval_mode == "self" then
                    reference = local_entry
                elseif interval_mode == "leader" then
                    reference = leader
                else
                    reference = entries[i - 1]
                end
                if reference and reference ~= entry and not reference.dnf then
                    entry.interval = shared_split_gap(entry, reference)
                    entry.cpInterval = reference.checkpoint - entry.checkpoint
                end
            end
        end
    end

    -- Rows for the provisional results card (ADR-0022): the live classification re-ranked by the F1
    -- jump-start penalty (ADR-0043), i.e. the order build_standings(true) will produce at the finish. That
    -- card is a RESULT view, so a jumper must not sit on a position the final card then visibly takes away
    -- again. Returns nil when nothing is penalized (every non-F1 race) -- the app binds `entries` unchanged.
    --
    -- Derived COPIES, never a mutation: `entries` is shared with the live corner board (hud.liveEntries
    -- slices the same row tables), and that board deliberately keeps the on-track order with the penalty
    -- still pending (ADR-0043 -- you should see live who is actually ahead).
    --
    -- Ranks on the SERVER keys (the broadcast standings rows, index-aligned with the rendered `rows`), not
    -- on the rendered values: the local row's checkpoint/time are the live detector's, which keep advancing
    -- for a DNF'd viewer and would drift that viewer's own row through the classification. On the server
    -- keys the order is exactly build_standings(true), and with no penalty every key is the one the server
    -- already sorted on -- so the card stays identical to before. Final tiebreak is the server's own rank,
    -- in which it has already resolved slot (and which, unlike slot, is never nil).
    local function build_provisional_entries(rows, sent_rows)
        local penalized = false
        for i = 1, #rows do
            if sent_rows[i] and sent_rows[i].jump_penalty then
                penalized = true
                break
            end
        end
        if not penalized then
            return nil
        end

        local ranked = {}
        for i = 1, #rows do
            local sent = sent_rows[i] or {}
            ranked[i] = {
                row = rows[i],
                rank = i,
                dnf = sent.dnf and true or false,
                completed = sent.completed or 0,
                -- Effective time = raw + penalty, the term build_standings(true) sorts on.
                time = (sent.total_time or 0) + (sent.jump_penalty or 0),
            }
        end
        table.sort(ranked, function(x, y)
            if x.dnf ~= y.dnf then
                return not x.dnf  -- non-DNF ranks ahead of DNF (ADR-0014)
            end
            if x.completed ~= y.completed then
                return x.completed > y.completed
            end
            if x.time ~= y.time then
                return x.time < y.time
            end
            return x.rank < y.rank
        end)

        local out = {}
        for i, item in ipairs(ranked) do
            local copy = {}
            for k, v in pairs(item.row) do
                copy[k] = v
            end
            copy.position = i  -- the broadcast position is the live rank and is stale in this order
            -- Effective time in the Time column, so the shown times stay monotone with the shown order.
            -- The template renders it for finishers only; the "+Ns" tag on the name stays as the reason.
            if copy.time ~= nil then
                copy.time = copy.time + (copy.jumpPenalty or 0)
            end
            -- Live-order metrics: the interval belongs to the corner board's reference (this card renders
            -- none), and an inherited leader gap would contradict the new order. Gaps recomputed below.
            copy.gap, copy.cpGap, copy.interval, copy.cpInterval = nil, nil, nil, nil
            out[i] = copy
        end

        -- Leader gap on the NEW order: the raw shared-crossing split gap (ADR-0015) plus the penalty
        -- difference, so each gap matches the position the row now holds -- otherwise the card could show
        -- a smaller gap below a larger one. The CP gap stays raw: that is a track metric, not a time.
        local new_leader = out[1]
        if new_leader and not new_leader.dnf then
            for i = 2, #out do
                local entry = out[i]
                if not entry.dnf then
                    local raw_gap = shared_split_gap(entry, new_leader)
                    if raw_gap ~= nil then
                        entry.gap = raw_gap + (entry.jumpPenalty or 0) - (new_leader.jumpPenalty or 0)
                    end
                    entry.cpGap = new_leader.checkpoint - entry.checkpoint
                end
            end
        end
        -- Those gaps were the only consumer of the shared splits reference (ADR-0015 hands it out
        -- read-only); dropping it keeps this second row list off the per-frame UI payload's size.
        for i = 1, #out do
            out[i].splits = nil
        end
        return out
    end

    -- Show the finish-grace countdown to everyone during the grace; the label adapts to whether the
    -- local player can still finish (ADR-0014) -- finished/DNF players see how long until the race ends.
    local grace = M.state.grace and M.state.grace.remaining or nil
    local grace_can_finish = not local_finished and not local_dnf
    -- The AFK cutoff addendum (feature standings-afk-cutoff-counter), read from INSIDE the same condition
    -- as the counter it stands behind: it explains a jump of that counter, so a screen without the
    -- counter must never carry it. Reading `grace` rather than M.state.grace a second time is what makes
    -- that structural instead of a habit.
    local afk_cutoff = (grace ~= nil and M.state.stall_cutoff)
        and M.state.stall_cutoff.remaining or nil

    -- The post-race analysis block is derived only when the overlay is actually open in the finished
    -- phase -- it runs every frame for the long finished window, so the closed-overlay default (and every
    -- live frame) skips the work entirely (ADR-0028/0030). `analysisAvailable` is the cheap flag the card
    -- button shows on, so the button appears without building the whole block.
    local is_circuit = (race and race.mode == "circuit") or false
    -- The server's statistics switch comes FIRST (ADR-0053), so a server with the feature off can never
    -- show the button whatever the phase and entry count say. Note this condition never depended on
    -- records at all: withholding the raceRecords push alone would have left the button on screen over an
    -- empty overlay, which is worse than leaving the feature on.
    local analysis_available = M.state.stats_enabled and phase == "finished" and #entries > 0
    local analysis = nil
    if analysis_available and M.state.analysis_open then
        analysis = build_analysis(entries, M.state.race_records, race)
    end

    -- Keep the compact series info box (ADR-0042, the lobby/staging readout) up through the finished phase
    -- too, so the running format + progress stays glanceable while everyone waits for the admin to prepare
    -- the next race. The championship has no decider, so it shows in every finished while active; class-drop
    -- shows only between races -- never in its *deciding* race (tournament.ended), where the champion banner
    -- + the card's "Winner" line own the moment. The box reuses this snapshot's championship/tournament
    -- tables (below); the app gates it on idleInfo, exactly as the build_idle_info_snapshot path does.
    local show_series_box = phase == "finished" and (
        (M.state.championship and M.state.championship.active)
        or (M.state.tournament and M.state.tournament.active and not M.state.tournament.ended)
    ) or false

    -- Qualifying live sector readout (feature: quali-live-sector-delta): the just-completed sector's split
    -- time, a per-segment delta vs your per-sector personal best, a cumulative delta vs your fastest run,
    -- and a motorsport record class (purple session / green personal / yellow slower / red off / grey
    -- normal). Persists the last completed sector until the next crossing. The bottom progress bar
    -- (feature: quali-sector-progress-bar) shows the whole current lap/run in the same classes,
    -- re-evaluated per push against the CURRENT session reference so a purple degrades live. All derived
    -- here from the tracker + the reference splits so the app stays a dumb renderer.
    local sector_info = nil
    local sector_bar = nil
    local sector_track = M.state.sector_track
    local sector_cps = (race and race.checkpoints) and #race.checkpoints or 0
    if phase == "qualifying" and sector_track and sector_cps >= 1 then
        -- Session reference (the field's best per sector), shared by the readout and the bar -- the same
        -- derivation the crossing-time freeze uses (Round 3). Circuit: live standings splits (ADR-0015,
        -- partial laps included). Staged: the server-relayed field bests (`sectorBests`, folded per scored
        -- crossing -- ADR-0044 Round 13); the old per-row bestSplits derivation only knew COMPLETE runs,
        -- too stale to degrade a purple live.
        local session_ref, session_counts = quali.sector_session_reference(sector_cps)
        -- The bar shows in both variants whenever the quali HUD is up: grey before the first crossing,
        -- and between staged runs it keeps the last run's states until the next launch wipes them
        -- (decision 3/4). run_states re-classifies against session_ref on every push (degradation) and
        -- against session_counts (round 4: a still-fastest white upgrades to purple once a second
        -- scoring of the sector exists).
        local bar_states = sectors.run_states(sector_track, session_ref, session_counts)
        if bar_states then
            sector_bar = {cps = sector_cps, states = bar_states}
        end
        local show_sector = sector_track.last ~= nil
        -- The staged sprint (Round 6) only shows the readout while the local driver is actually on their
        -- run; between runs the tracker's last sector would otherwise linger. Circuit persists it as before.
        if M.state.quali_staged and M.state.quali_status ~= "running" then
            show_sector = false
        end
        if show_sector then
            local last = sector_track.last
            -- Personal reference for the cumulative delta: the circuit reads your own live standings splits;
            -- the staged sprint wipes a driver's splits on every requeue, so it reads the server-relayed best
            -- COMPLETE run splits carried per row on the queue snapshot (bestSplits); there is no run-up (the
            -- run starts at the ramp = the line).
            local personal_splits, personal_run_up
            if M.state.quali_staged then
                local mine = quali.local_row(my_slot)
                personal_splits = mine and mine.bestSplits or nil
                personal_run_up = nil
            else
                personal_splits = local_entry and local_entry.splits or nil
                personal_run_up = local_entry and local_entry.run_up or nil
            end
            -- The readout classifies on the SAME frozen/effective reference as the bar (Round 3/4):
            -- the live field best applies when strictly faster, a second scoring upgrades a
            -- still-fastest white to purple, else the value frozen at crossing time -- the readout
            -- must never show purple where the bar is white (nor stay white where the bar upgraded).
            local session_best = sectors.effective_session_best(last.split,
                last.prev_session_best, session_ref and session_ref[last.sector] or nil,
                session_counts and session_counts[last.sector] or nil)
            -- Cumulative delta vs your PREVIOUS best run: this run's time through the sector minus that
            -- run's. At the finish crossing on a CIRCUIT the just-finished lap is already folded into
            -- personal_splits (local_entry.splits), so exclude it -- otherwise a new best would diff
            -- against itself and read ±0 (bug quali-finish-delta-prev-best). The staged sprint reads the
            -- server-relayed best COMPLETE run (bestSplits), which is still the previous best at the
            -- finish frame (the round-trip that folds this run in has not returned yet), so it must NOT
            -- be excluded -- it is a single run, and dropping it would discard the legitimate reference.
            local at_finish = (last.sector == sector_cps)
            local exclude_just_finished = at_finish and not M.state.quali_staged
            local best_sections = sectors.personal_reference(personal_splits, personal_run_up,
                sector_cps, exclude_just_finished)
            local best_cumulative = best_sections
                and sectors.cumulative_through(best_sections, last.sector) or nil
            local cumulative, cumulative_total = nil, nil
            if type(best_cumulative) == "number" then
                cumulative = last.lap_cumulative - best_cumulative
            end
            if at_finish then
                -- Always show the absolute lap/run total at the finish; the delta (if any) renders
                -- behind it (feature quali-finish-time-with-delta). Intermediate sectors keep the
                -- running delta only (cumulative_total stays nil there).
                cumulative_total = last.lap_cumulative
            end
            sector_info = {
                sector = last.sector,
                split = last.split,
                -- Per-segment delta vs your prior personal best for this sector (nil the first time).
                splitDelta = (last.prev_personal_best ~= nil)
                    and (last.split - last.prev_personal_best) or nil,
                cumulative = cumulative,  -- vs your previous best run (nil until a prior run exists)
                cumulativeTotal = cumulative_total,  -- absolute lap/run total at the finish (any completed lap/run); nil at intermediate sectors
                record = sectors.record_class(last.split, last.prev_personal_best, session_best),
            }
        end
    end

    -- Provisional results card (ADR-0022), shown to a finished/DNF'd player while the race still runs.
    -- Its penalized row list is built only while the card is actually up -- like the analysis block above,
    -- the closed default costs nothing per frame.
    local provisional_available = ((phase == "racing") and (local_finished or local_dnf)) and true or false
    local provisional_entries = nil
    if provisional_available and M.state.provisional_open and standings then
        provisional_entries = build_provisional_entries(entries, standings)
    end

    return {
        active = true,
        phase = phase,
        entries = entries,
        intervalMode = M.state.interval_mode or "self",  -- live-standings interval reference for the REL toggle label
        grace = grace,
        graceCanFinish = grace_can_finish,
        -- Seconds until the LAST still-standing driver is counted out and the finish timer shortens, or
        -- nil when that is not happening. Rendered as " . AFK in n" behind the provisional card's counter
        -- and the three qualifying lines (feature standings-afk-cutoff-counter).
        afkCutoff = afk_cutoff,
        isCircuit = is_circuit,
        -- F1 light start active this race (ADR-0043): gates the standings React column.
        f1Start = (race and race.startMode == "f1") or false,
        resultsMin = M.state.results_min or false,
        -- The "Race setup" button on the final-standings card (feature raceui-reopen-without-typing): the
        -- server's own verdict (setupAccess), narrowed to the finished phase. That window is where
        -- the next race gets set up and it lasts 900 s, and it is the ONLY place this button appears
        -- -- not in the lobby, not on the provisional card, not on the quali-results card (decision 4).
        --
        -- Phase-gated here as well as by the card's own ng-if, exactly like analysisAvailable above: the
        -- reach of the button is a requirement, so it is readable in one place rather than inferred from
        -- which template happens to hold it.
        setupReopenAvailable = (phase == "finished" and M.state.setup_may_open == true) or false,
        analysisAvailable = analysis_available,
        analysisOpen = M.state.analysis_open or false,
        analysis = analysis,
        -- Provisional results card: shown to a finished/DNF'd player while the race still runs (ADR-0022).
        provisionalAvailable = provisional_available,
        provisionalOpen = M.state.provisional_open,
        -- The same rows re-ranked by the F1 jump-start penalty (see build_provisional_entries): that card
        -- is a result view, so it shows the order the final card will show. nil = nothing to re-rank; the
        -- app then binds `entries` unchanged. The live corner board always binds `entries` (ADR-0043).
        provisionalEntries = provisional_entries,
        -- The multi-race championship table (ADR-0040), shown on the finished results card when active; nil
        -- or active=false hides it. Rides opaquely through to the app.
        championship = M.state.championship,
        -- The class-drop tournament table (ADR-0042), shown on the finished results card when active; nil or
        -- active=false hides it. Rides opaquely through to the app, like the championship.
        tournament = M.state.tournament,
        -- Show the compact series info box in the finished phase too (see show_series_box above): the app
        -- renders the box whenever idleInfo is set, so this lights it up alongside the results card.
        idleInfo = show_series_box and true or nil,
        -- Qualifying (ADR-0041): the live time-remaining clock (qualifying phase), the finish-your-lap
        -- timeout once the clock expires, the pause countdown to the race, and the classification snapshot
        -- for the quali-results card. nil outside a quali event; the app reads phase to pick the view.
        qualiRemaining = M.state.qualifying and M.state.qualifying.remaining or nil,
        qualiGrace = (phase == "qualifying" and M.state.grace) and M.state.grace.remaining or nil,
        -- The local driver has completed their finish-your-lap lap (detector stopped during the grace), so
        -- the HUD shows "waiting for others" instead of the timeout (ADR-0041).
        qualiDone = (phase == "qualifying" and M.state.grace ~= nil and M.state.detection == nil) and true or false,
        qualiResultsRemaining = M.state.qualiResults and M.state.qualiResults.remaining or nil,
        -- The results-display portion of the pause (before the respawn): the full remaining minus the settle
        -- lead, so the card's "race starts in" reads a clean count to the respawn rather than the whole pause.
        qualiResultsPreRemaining = M.state.qualiResults
            and math.max(0, M.state.qualiResults.remaining - (M.state.qualiResults.lead or 0)) or nil,
        -- Settle window (ADR-0041): true from the quali re-grid (cars on the grid) until the start countdown,
        -- so the app swaps the big results card for a small "race starts in" timer. The remaining seconds reuse
        -- qualiResultsRemaining (the freeze eats the lead's first seconds; the rest is the visible settle).
        qualiSettleActive = (phase == "qualiResults" and M.state.quali_settle) and true or false,
        quali = M.state.quali,
        -- One lap's checkpoint count for the quali boards' "CP x/y" cells (Round 12): client-local
        -- knowledge, because the server-relayed per-row `count` is the whole traversal plan -- on the
        -- unbounded circuit quali plan that is laps * cps, useless as the per-lap denominator. Every
        -- client resolves the same race, so every board shows the same y. Kept live through quali-results
        -- too (feature quali-results-cp-progress), so the results card has the circuit denominator during
        -- the pause; nil outside those two phases.
        qualiCpsPerLap = ((phase == "qualifying" or phase == "qualiResults") and race and race.checkpoints
            and #race.checkpoints > 0) and #race.checkpoints or nil,
        -- Rally staged sprint quali (ADR-0044): flag the staged view + carry the holding queue and the local
        -- driver's own row (status/position/best), resolved from the broadcast queue snapshot by slot. nil /
        -- false outside a staged qualifying phase, so the app falls back to the circuit best-lap board.
        qualiStaged = (phase == "qualifying" and M.state.quali_staged) and true or false,
        qualiQueue = (M.state.quali_queue and M.state.quali_queue.rows) or nil,
        qualiMine = quali.local_row(my_slot),
        -- A driver has launched but not yet cleared the ramp (Round 4): the HUD shows "Waiting for driver to
        -- start" so waiters know why the next stage is held. From the server queue snapshot's `waiting` flag.
        qualiWaiting = (phase == "qualifying" and M.state.quali_staged
            and M.state.quali_queue and M.state.quali_queue.waiting) and true or false,
        -- Qualifying live sector readout (feature: quali-live-sector-delta): the last completed sector's
        -- split time, per-segment + cumulative deltas, and record class (nil = nothing to show yet).
        sector = sector_info,
        -- Qualifying sector progress bar (feature: quali-sector-progress-bar): the current lap/run as
        -- {cps, states = {class, ...}} -- one record class per sector, live re-evaluated. nil outside
        -- qualifying, so the bar leaves with the quali HUD.
        sectorBar = sector_bar,
    }
end

-- A minimal HUD snapshot for the between-races idle window (ADR-0042): just enough for the compact series
-- info box to show which multi-race format is active and how far along, without running the full per-frame
-- standings build. `idleInfo` gates the box: it shows here (lobby/free-roam + staging) and through the
-- finished phase -- the full snapshot sets idleInfo too while a series is active (except the class-drop
-- deciding race; see show_series_box in build_hud_snapshot) -- but never during the countdown/race/quali,
-- whose full snapshots leave idleInfo absent. The championship/tournament tables ride through as on the
-- full snapshot; both persist across the lobby, so they are current here.
local function build_idle_info_snapshot()
    return {
        active = true,
        phase = M.state.phase or "lobby",
        idleInfo = true,
        championship = M.state.championship,
        tournament = M.state.tournament,
    }
end

-- Normalize a plain {x, y, z} vector, or nil when it is degenerate (too short to give a direction).
local function normalize_dir(v)
    local length = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if length < 1e-6 then
        return nil
    end
    return {x = v.x / length, y = v.y / length, z = v.z / length}
end

-- The checkpoint at a 1-based plan ordinal (entries[ordinal].cursor -> checkpoints[cursor]), or nil.
local function plan_checkpoint(race, ordinal)
    local entries = race.plan and race.plan.entries
    local entry = entries and entries[ordinal]
    return entry and race.checkpoints[entry.cursor] or nil
end

-- The recover target for the local player: the last passed checkpoint (ADR-0010/0013) facing the
-- next one, or -- before any checkpoint is passed -- the grid start pose facing the first checkpoint.
-- Returns {pos = {x,y,z}, dir = {x,y,z} or nil, up = {x,y,z} or nil, samples, surface}; `up` is the
-- surface normal placement measured under the final position, and a nil dir or up puts the car down
-- level. `samples` (the four points that normal was measured at) and `surface` (the ground under the
-- target) only feed vehicles.recover_to's log line. `pos` is where the car's box centre-bottom goes
-- (ADR-0034 amendment 2026-10-07) -- the target itself is unchanged by that.
local function recover_target(race, detection)
    local seq = (detection and detection.seq) or 0
    local target_pos, face_pos
    if seq <= 0 then
        target_pos = race.myPose.pos
        local first = plan_checkpoint(race, 1)
        face_pos = first and first.pos
    else
        local last = plan_checkpoint(race, seq)
        target_pos = (last and last.pos) or race.myPose.pos
        local next_cp = plan_checkpoint(race, seq + 1)
        face_pos = next_cp and next_cp.pos
    end

    local dir
    if face_pos and target_pos then
        dir = normalize_dir({
            x = face_pos.x - target_pos.x,
            y = face_pos.y - target_pos.y,
            z = face_pos.z - target_pos.z,
        })
    end

    -- Drop the recover target onto the real surface and clear of walls (ADR-0034): a checkpoint's
    -- authored centre sits above the road, so a raw teleport there would bury the car. Pass the facing
    -- as `forward` so the wall-nudge knows which way is down-track. (The seq <= 0 grid pose is already
    -- grounded by start.prepare; re-grounding it is idempotent.)
    --
    -- `up` is the slope placement measured under the position it settled on -- the car is laid INTO
    -- that surface instead of flat into the landscape (ADR-0034 amendment 2026-09-01).
    local grounded = placement.resolve({pos = target_pos, forward = dir})
    return {
        pos = grounded.pos,
        dir = dir,
        up = grounded.up,
        samples = grounded.samples,
        surface = grounded.surface,
    }
end

-- Arm the seated car's VE key forwarders for the race (ADR-0017). GE owns the enable check, countdown,
-- and action, so nothing but a bare "arm" is sent. Pushed once (tracked by assist_armed). Vehicle
-- extensions under lua/vehicle/extensions/ are NOT auto-loaded (only the .../auto subdir is;
-- vehicle/main.lua), so load ours into the car's VM first; extensions.load is synchronous, so
-- beamcomp_init is available on the same command. No-op until the own car resolves; retried from onUpdate.
local function push_assist_arm()
    local race = M.state.race
    if not race or not race.assists or M.state.assist_armed then
        return
    end
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end

    local command = "if not beamcomp_init then extensions.load('beamcomp_init') end "
        .. "if beamcomp_init then beamcomp_init.on_assist_arm() end"
    local ok, err = pcall(function() own_car:queueLuaCommand(command) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not arm assist forwarders on VE: " .. tostring(err))
        return
    end
    M.state.assist_armed = true
end

-- Tell the seated car's VE to restore the vanilla recovery functions (ADR-0017): the race is over, so
-- recover/repair behave normally again. Best-effort -- if the car is gone the override died with it.
-- Assigns the forward-declared local so handle_race_phase (above) can call it.
function disarm_assist_ve()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end
    pcall(function()
        own_car:queueLuaCommand("if beamcomp_init then beamcomp_init.on_assist_disarm() end")
    end)
end

-- Arm the seated car's VE EV-throttle clamp for the frozen phases (ADR-0017 amendment). Mirrors
-- push_assist_arm but is NOT gated on race.assists -- the EV creep guard applies to every race -- and
-- is tracked separately (freeze_hold_armed). The VE detects the drivetrain once and clamps the throttle
-- only on EVs, so a bare "arm" is all GE sends. Loads the VE extension first (not auto-loaded; see
-- push_assist_arm) and retries from onUpdate until the own car resolves.
local function push_freeze_hold()
    if M.state.freeze_hold_armed then
        return
    end
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end

    local command = "if not beamcomp_init then extensions.load('beamcomp_init') end "
        .. "if beamcomp_init then beamcomp_init.on_freeze_hold_arm() end"
    local ok, err = pcall(function() own_car:queueLuaCommand(command) end)
    if not ok then
        log("W", RACE_LOG_TAG, "could not arm freeze hold on VE: " .. tostring(err))
        return
    end
    M.state.freeze_hold_armed = true
end

-- Tell the seated car's VE to release the EV-throttle clamp (ADR-0017 amendment): the freeze is lifting
-- (racing) or the race is over. Best-effort -- if the car is gone the clamp died with it. Assigns the
-- forward-declared local so handle_race_phase / handle_race_start (above) can call it.
function disarm_freeze_hold_ve()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end
    pcall(function()
        own_car:queueLuaCommand("if beamcomp_init then beamcomp_init.on_freeze_hold_disarm() end")
    end)
end

-- Perform a recover/repair once its countdown completes (ADR-0017). GE owns the action: "repair"
-- fixes the car in place (queued recovery.recoverInPlace), "recover" teleports + repairs to the last
-- passed checkpoint (grid pose before the first). Reseed the detector so the teleport jump is not
-- swept as a spurious crossing next frame.
local function perform_assist(kind)
    local race = M.state.race
    if not race then
        return
    end
    if M.state.detection then
        M.state.detection.prev_pos = nil
    end

    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        log("W", RACE_LOG_TAG, "assist '" .. tostring(kind) .. "' completed but no own car resolved")
        return
    end

    if kind == "repair" then
        pcall(function() own_car:queueLuaCommand("recovery.recoverInPlace()") end)
    else
        local target = recover_target(race, M.state.detection)
        local placed, err = vehicles.recover_to(own_car, target)
        if not placed then
            log("W", RACE_LOG_TAG, "recover-to-checkpoint failed: " .. tostring(err))
            return
        end
    end

    log("I", RACE_LOG_TAG, "assist performed: " .. tostring(kind))
    notice.say((kind == "repair") and "Repaired in place" or "Recovered to last checkpoint", "info")
end

-- Clear any in-progress assist countdown and its centered overlay (ADR-0017). Idempotent.
local function clear_assist_arming()
    if M.state.assist_arming then
        M.state.assist_arming = nil
        countdown.clear()
    end
end

-- Min seconds between staging repairs, so a held/mashed Insert re-places + toasts once, not every frame
-- (os.clock is monotonic CPU seconds -- the same gate the lock's spawn-block toast uses). Not reset per
-- race: os.clock only climbs, so a new staging is always well past the throttle.
local STAGING_REPAIR_THROTTLE = 1.0
local last_staging_repair_at = 0

-- The (enabled, holdSeconds) setting for an assist kind, read with an explicit branch (the enabled
-- flags are booleans, so `a and b or c` would wrongly fall through to the other assist).
local function assist_setting(kind)
    local assists = M.state.race and M.state.race.assists
    if not assists then
        return false, 0
    end
    if kind == "repair" then
        return assists.repairEnabled, assists.repairHoldSeconds
    end
    return assists.recoverEnabled, assists.recoverHoldSeconds
end

-- Whether the local car is stopped enough to begin/continue a recover/repair hold (ADR-0017). The speed
-- test itself is stall.is_stopped -- the SAME predicate the AFK detection applies, to the same number.
local function is_car_stationary()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    return own_car ~= nil and stall.is_stopped(own_car)
end

-- Lowercase verb for an assist kind, for the failure-feedback toasts ("Hold to <verb>").
local function assist_verb(kind)
    return (kind == "repair") and "repair" or "recover"
end

-- Tell the player WHY a recover/repair did not fire (ADR-0017 amendment): disabled, not stationary, or
-- released too early. Seven callers, one seam -- and since it only ever speaks during a race, every one
-- of them lands on the centred line.
local function notify_assist_blocked(msg)
    notice.say(msg, "warning")
end

-- Tell a held qualifying driver why their recover key did nothing (bug quali-hold-reset-and-repaint-leak).
-- The key is normally already blocked at the input filter, so this only ever fires as the second layer --
-- but it also has to read right for a player who has that filter silently no-op on a future engine version.
function hold.notify_blocked()
    if M.state.quali_status == "done" or M.state.quali_lap_done then
        notify_assist_blocked("Your qualifying run is over -- the car stays put")
    elseif M.state.quali_status == "staged" then
        notify_assist_blocked("Reset is locked -- your run starts in a moment")
    else
        notify_assist_blocked("Reset is locked -- wait for your turn")
    end
end

-- Repair the player's own car during the pre-race staging window (ADR-0017 staging-allow-repair): the
-- cars spawn repaired on the grid, but a car damaged ON the grid during the staging wait (a neighbour
-- bumping it through the soft start-freeze, a botched swap) would otherwise start the race broken. Reuses
-- the restage path -- place_at_grid (repair + front-anchored grid placement) then re-freeze -- so the car
-- ends up undamaged, on its exact slot, and still frozen for the start (no forward-roll advantage).
-- Skipped while a restage is pending: the swapped/fresh car is about to be placed clean anyway, and its
-- jbeam may still be loading, which would mis-anchor an immediate place. Throttled against key spam.
local function perform_staging_repair()
    local race = M.state.race
    local pose = race and race.myPose
    if not pose or M.state.restage_pending then
        return
    end
    local now = os.clock()
    if now - last_staging_repair_at < STAGING_REPAIR_THROTTLE then
        return
    end
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return
    end
    last_staging_repair_at = now
    local placed, err = vehicles.place_at_grid(own_car, pose)
    if not placed then
        log("W", RACE_LOG_TAG, "staging repair failed: " .. tostring(err))
        return
    end
    -- place_at_grid teleports, so re-assert the freeze for the rest of staging + the countdown, exactly
    -- as the restage does (init.lua restage_swapped_car).
    vehicles.set_vehicle_frozen(own_car, true)
    log("I", RACE_LOG_TAG, "staging repair: re-placed own car on its grid slot")
    notice.say("Car repaired", "info")
end

-- A recover/repair key went down (forwarded from the VE, ADR-0017): record which assist is held so
-- the per-frame stepper can run the hold. Racing + qualifying (ADR-0041), enabled assists only -- a
-- disabled assist's key is inert (blocked). The actual countdown starts in step_assist once stationary.
function M.on_assist_key_down(kind)
    -- Pre-race staging: a single Insert (repair) press repairs the own car on its grid slot (ADR-0017
    -- staging-allow-repair). Instant -- no hold -- since the car is frozen, so there is no driving exploit
    -- and the in-race hold (a time cost) would be pointless friction here. Ctrl+Insert (recover) is inert.
    -- Works regardless of the race's repair-assist enable: "fix your car before the start" is a separate
    -- guarantee. Returns before the in-race hold path below.
    if M.state.phase == "staging" then
        if M.state.race and kind == "repair" then
            perform_staging_repair()
        end
        return
    end
    if not M.state.race or (M.state.phase ~= "racing" and M.state.phase ~= "qualifying") then
        return
    end
    -- Qualifying HOLD (bug quali-hold-reset-and-repaint-leak): a held driver's car must not move, so neither
    -- recover nor repair may act. This is the SECOND layer -- lock.set_recover_blocked already stops both
    -- keys at the engine's input filter, which is what also covers the moment right after a vehicle-config
    -- respawn, where the VE override has been reloaded away and the keys are briefly vanilla. This guard
    -- catches a key that reaches GE anyway (a silently no-op'd filter on a future engine version).
    -- Nothing is lost by refusing repair too: every entry into a held state re-places the car with
    -- place_at_grid, which repairs it, so a held car is already pristine.
    if hold.is_held() then
        hold.notify_blocked()
        return
    end
    -- Staged sprint quali (ADR-0044/Round4): the RECOVER key starts a new attempt -- requeue the running
    -- driver to the back of the queue. ONLY recover (not repair): repair falls through to the normal in-place
    -- repair below, which does NOT end the run (ADR-0017). Available regardless of the assist enable (a
    -- recover-requeue must always be possible) and while moving (no hold), unlike the normal assist. Gated on
    -- the run's detector being armed and not done, so a press while holding/staged or after finishing is inert.
    if kind == "recover" and M.state.quali_staged and M.state.phase == "qualifying"
        and M.state.detection and not M.state.detection.done then
        quali.request_requeue()
        return
    end
    local enabled = assist_setting(kind)
    if not enabled then
        notify_assist_blocked(((kind == "repair") and "Repair" or "Recover")
            .. " is disabled in this race")
        return
    end
    M.state.assist_held = kind
    M.state.assist_notice = nil
end

-- The held recover/repair key was released: drop the hold and cancel any running countdown. If a
-- countdown was actually mid-flight (not completed, not never-started), tell the player they let go
-- too early -- "released too early" is only a failure when the hold was genuinely running.
function M.on_assist_key_up()
    local was_arming = M.state.assist_arming ~= nil
    local kind = M.state.assist_held
    M.state.assist_held = nil
    clear_assist_arming()
    M.state.assist_notice = nil
    if was_arming and kind then
        notify_assist_blocked("Hold to " .. assist_verb(kind))
    end
end

-- A powered prop's (grinder's) VE reporting whether its `spinner` controller took the activation command
-- (ADR-0020 amendment, bug race-prop-steals-player-seat round 2). Reached from the grinder VE as
-- `beamcomp_init.note_grinder_spinning(...)`, the same GE<->VE path the assist keys above use. A thin
-- wrapper over the module that owns the window; a reply with no window open (teardown raced the last queued
-- command) is a no-op. This is what lets the window stop on evidence instead of on a timer, and what makes
-- the log say whether the controller ever came up.
function M.note_grinder_spinning(vehicle_id, has_controller)
    grinders.note_spinning(M.state.grinder_activate, vehicle_id, has_controller)
end

-- Drive the hold-to-activate recover/repair each frame (ADR-0017): the countdown runs only while the
-- key is held AND the car is (near) stationary -- releasing or driving off cancels it. On completion
-- the held kind is consumed (cleared) so it does not immediately re-fire while the key is still down.
local function step_assist(dt_real)
    -- A qualifying hold can engage while an assist key is still physically DOWN -- e.g. the repair key held
    -- across the finish line, where the finish itself puts the driver into `done`. From that moment the
    -- input filter swallows the key-UP as well, so on_assist_key_up never fires and assist_held stays
    -- latched. Its countdown only requires a stationary car -- and a frozen car IS stationary -- so it would
    -- run to completion and fire the assist, breaking the very hold we just engaged. Drop the latched hold
    -- the moment the driver is held (bug quali-hold-reset-and-repaint-leak).
    if hold.is_held() then
        M.state.assist_held = nil
        M.state.assist_notice = nil
        clear_assist_arming()
        return
    end
    local held = M.state.assist_held
    if not held then
        clear_assist_arming()
        return
    end
    if not is_car_stationary() then
        -- Held while moving: cancel the hold and tell the player once (latched so it does not flood
        -- every frame the car keeps rolling).
        if M.state.assist_notice ~= "moving" then
            notify_assist_blocked("Stop the car to " .. assist_verb(held))
            M.state.assist_notice = "moving"
        end
        clear_assist_arming()
        return
    end

    local arming = M.state.assist_arming
    if not arming or arming.kind ~= held then
        local _, seconds = assist_setting(held)
        arming = {kind = held, remaining = seconds, last_shown = nil}
        M.state.assist_arming = arming
    end

    arming.remaining = arming.remaining - (dt_real or 0)
    if arming.remaining <= 0 then
        local kind = arming.kind
        clear_assist_arming()
        M.state.assist_held = nil
        perform_assist(kind)
        return
    end

    -- Push the centered overlay each whole second so it counts down live (the GE side drives it a
    -- beat at a time; ADR-0021).
    local shown = math.max(1, math.ceil(arming.remaining))
    if shown ~= arming.last_shown then
        arming.last_shown = shown
        countdown.show_assist(held == "repair" and "Repair" or "Recover", shown)
    end
end

-- os.clock() reading of the last over-cap staging-swap toast, throttled by CAP_SWAP_TOAST_THROTTLE. A
-- plain file-scope local (a Lua reload resets it -- at worst one extra toast), mirroring last_block_toast_at.
local last_cap_swap_toast_at = 0

-- English label for the active strict weight range: "1200-1800 kg", "<=1500 kg", or ">=1200 kg".
-- Only called with at least one of maxkg/minkg set (the weight branch of warn_over_cap).
local function weight_limit_label(caps)
    if caps.minkg and caps.maxkg then
        return string.format("%d-%d kg", math.floor(caps.minkg + 0.5), math.floor(caps.maxkg + 0.5))
    elseif caps.maxkg then
        return string.format("<=%d kg", math.floor(caps.maxkg + 0.5))
    end
    return string.format(">=%d kg", math.floor(caps.minkg + 0.5))
end

-- True when the live weight breaks the strict range: an unreadable weight under a set bound fails (cannot
-- verify => blocked, ADR-0032), else a readable weight below minkg or above maxkg fails.
local function breaks_weight_range(weight, caps)
    if not (caps.maxkg or caps.minkg) then
        return false
    end
    if type(weight) ~= "number" then
        return true
    end
    return (caps.minkg and weight < caps.minkg) or (caps.maxkg and weight > caps.maxkg) or false
end

-- Warn (throttled, English, native toast) that a staging car swap was rejected for breaking the Mode-3 cap
-- (ADR-0032). Names the offending car and the numbers, e.g. "etk800 has 450 hp -- limit is 300 hp". Reports
-- the first axis that failed off the live power/weight and the caps, in is_compliant order: the max-HP cap,
-- then the power-to-weight cap, then the strict weight range (maxkg/minkg); an unreadable value says that
-- reading couldn't be verified (cannot verify => blocked, ADR-0032's load-bearing rule). Uses the same
-- guihooks toast surface as the switch/spawn block warnings.
local function warn_over_cap(veh, power, weight, caps)
    local now = os.clock()
    if now - last_cap_swap_toast_at < CAP_SWAP_TOAST_THROTTLE then
        return
    end
    last_cap_swap_toast_at = now
    local name = (veh and veh.JBeam) or "That car"
    local pwr_ok = caps.maxpwr == nil
        or (type(power) == "number" and type(weight) == "number" and weight > 0
            and power / weight <= caps.maxpwr)
    local detail
    if caps.maxhp and not (type(power) == "number" and power <= caps.maxhp) then
        if type(power) == "number" then
            detail = string.format("%s has %d hp -- limit is %d hp", name, math.floor(power + 0.5), caps.maxhp)
        else
            detail = string.format("%s: engine power couldn't be verified -- limit is %d hp", name, caps.maxhp)
        end
    elseif caps.maxpwr and not pwr_ok then
        if type(power) == "number" and type(weight) == "number" and weight > 0 then
            detail = string.format("%s has %.2f hp/kg -- limit is %.2f hp/kg",
                name, power / weight, caps.maxpwr)
        else
            detail = string.format("%s: power-to-weight couldn't be verified -- limit is %.2f hp/kg",
                name, caps.maxpwr)
        end
    elseif breaks_weight_range(weight, caps) then
        if type(weight) == "number" then
            detail = string.format("%s weighs %d kg -- limit is %s", name, math.floor(weight + 0.5),
                weight_limit_label(caps))
        else
            detail = string.format("%s: curb weight couldn't be verified -- limit is %s", name,
                weight_limit_label(caps))
        end
    else
        detail = name .. " exceeds the vehicle limit"
    end
    notice.say("Can't stage that car -- " .. detail, "warning")
    log("I", RACE_LOG_TAG, "rejected over-cap staging swap: " .. detail)
end

-- Re-stage the staging car to its grid slot, front-anchored, once its jbeam has loaded. Two arming
-- paths share this one deferred placement:
--   1. A staging vehicle swap (ADR-0021/0017 amendments, staging-allow-vehicle-swap): the swap-allowed
--      lock leaves replaceVehicle open but wraps it to flag the replace (lock.consume_replace) -- the
--      reliable trigger, since a replace keeps the SAME vehicle id, so an id comparison never fires
--      (confirmed in-game: the swap produced no adoption). The replacement spawns unfrozen, would drive
--      off in the countdown, and reloads its VE (losing the assist override + EV clamp).
--   2. A freshly spawned race car -- no own car (default-vehicle-when-player-has-none), OR a forced
--      car (Mode 2 / Class-Drop) or a Mode-3 substitute that spawns fresh: handle_race_start arms
--      restage_pending directly, since the spawn path lands it center-anchored.
-- Either way we re-place it at the grid slot, re-freeze it, and clear the VE-arm flags so onUpdate
-- re-arms the VE.
--
-- The grid re-placement is DEFERRED: a freshly replaced or spawned car keeps reporting a stale bounding
-- box for a moment while its jbeam loads, so front-anchoring immediately uses the wrong footprint and
-- lands a differently-sized car offset (confirmed in-game: small -> large swap sat too far forward). We
-- wait until the spawn bbox's forward half-length changes by RESTAGE_MIN_DELTA against a baseline (new
-- jbeam loaded), or until RESTAGE_MAX_WAIT elapses (same-size swap, where placing with the unchanged box
-- is correct anyway).
--
-- WHERE THE BASELINE COMES FROM is what makes that test work at all. For a SWAP the replace wrapper takes
-- it off the outgoing car before the engine runs (on_before_replace); this function only adopts it. It
-- cannot be recorded here, because the replace stalls the engine for ~2 s loading the new jbeam and the
-- first frame we get afterwards already reports the NEW car's box -- measured in-game, and it made the
-- detection compare the new box against itself, so every swap ran into the timeout and got its correction
-- as late as the design allows. A fresh spawn has no outgoing car and still records on its first pending
-- frame, where the stale-box premise does hold.
--
-- The wait is unchanged, but the placement at the end of it is now a CHECK: a freshly spawned car was
-- already front-anchored from its config bounding box, so it is normally standing on its slot by the time
-- we get here and restage_at_grid leaves it alone. That removes the late shuffle players used to see; a
-- car the prediction missed, and any staging swap, is still corrected in full.
local function restage_swapped_car(dt_real)
    if not M.state.race_car_id then
        return
    end

    -- A replace happened: (re)start a pending re-placement. Re-arming the VE waits until placement, when
    -- the new jbeam is loaded -- queueing to a still-loading VE would be lost.
    if lock.consume_replace() then
        M.state.restage_pending = true
        -- Adopt the baseline the replace wrapper took off the OUTGOING car (on_before_replace). Only a
        -- swap has one; the fresh-spawn arming path leaves it nil and the first pending frame records the
        -- baseline itself, exactly as before.
        M.state.restage_baseline = M.state.restage_prebaseline
        M.state.restage_prebaseline = nil
        M.state.restage_wait = RESTAGE_MAX_WAIT
        M.state.restage_preplaced = 0
        -- Scope the compliance-gate skip to THIS restage cycle only (ADR-0032): if this consumed replace is
        -- our own over-cap revert (revert_pending), its car is the known-compliant target -- skip the gate
        -- so a transient nil read can't loop. Any OTHER replace is a new player swap and must be re-gated,
        -- so the skip is cleared. Recomputed here (not left latched from the revert) so it can never span
        -- the reverted car's multi-frame load wait, which would otherwise let a second over-cap swap through.
        M.state.staging_swap_reverting = M.state.revert_pending == true
        M.state.revert_pending = false
        log("I", RACE_LOG_TAG, "staging vehicle replace detected; re-staging")
    end

    if not M.state.restage_pending then
        return
    end

    local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own then
        return
    end

    -- Wait for the footprint to change (new jbeam loaded) or for the fallback timeout. A SWAP brought its
    -- baseline with it, taken off the outgoing car before the replace -- on the first pending frame the
    -- car here is already the new one, so recording it now would compare the new box against itself.
    -- Only the fresh-spawn arming path (handle_race_start), which has no outgoing car, records here.
    local current = vehicles.spawn_oobb_forward(own)
    if M.state.restage_baseline == nil then
        M.state.restage_baseline = current
    end
    M.state.restage_wait = (M.state.restage_wait or 0) - (dt_real or 0)
    local baseline = M.state.restage_baseline
    local loaded = current ~= nil and baseline ~= nil and math.abs(current - baseline) > RESTAGE_MIN_DELTA
    if not loaded and M.state.restage_wait > 0 then
        -- Still waiting for the jbeam -- but the WAIT is only there because MEASURING needs it. A swap
        -- inherits the old car's reference point (BeamNG _replaceVehicle: `localOptions.pos =
        -- veh:getPosition()`), so the replacement stands off by the two cars' size difference, and the
        -- metadata box can say by how much without measuring anything. Correct it now instead of seconds
        -- from now; the tolerance gate inside makes this a no-op once it has landed (and a no-op the whole
        -- time for a fresh spawn, which the spawn path already anchored).
        --
        -- Everything the wait actually guards stays behind it: the Mode-3 compliance gate needs the LIVE
        -- power/weight read (ADR-0032), the plate must be applied after the jbeam's licenseplate init, and
        -- the re-freeze belongs with the adoption. This only moves the car.
        local tries = M.state.restage_preplaced or 0
        if tries < vehicles.PREPLACE_MAX_TRIES then
            local moved, delta, model = vehicles.preplace_at_grid(own, M.state.race and M.state.race.myPose)
            if moved then
                M.state.restage_preplaced = tries + 1
                -- One line per cycle, so a test can tell this path apart from the restage safety net
                -- behind it. Silent when there was nothing to correct.
                if tries == 0 then
                    log("I", RACE_LOG_TAG, string.format(
                        "pre-placed swapped car '%s' on its grid slot from metadata (%.2f m off)",
                        tostring(model), delta))
                end
            end
        end
        return
    end

    -- Mode-3 compliance gate (ADR-0032): the swap-allowed staging lock lets the player replace their car via
    -- the vehicle/parts selector, but must not let them stage a car over the power cap. The jbeam is loaded
    -- here (we are past the load wait), so the car's LIVE power/weight read is reliable -- unlike pre-spawn
    -- config metadata, and unlike a pre-intercepted replace it also handles a customized car correctly. On a
    -- violation, warn and revert to the last compliant staged car; the reverting flag makes the next cycle
    -- adopt that known-compliant car without re-gating, so a transient nil read can't loop. Mode 1/2
    -- (race_caps nil) skip the gate; a fresh Mode-3 substitute is compliant by construction. See ADR-0032:
    -- reverting (not a true pre-intercept) is the documented behavior -- the over-cap car is briefly visible
    -- while its jbeam loads, the same load window any staging swap already has.
    local caps = M.state.race_caps
    local staged_ok = true  -- whether the car about to be adopted is cap-compliant (always true without caps)
    if caps and not M.state.staging_swap_reverting then
        local compliant, power, weight =
            vehicles.car_compliant(own, caps.maxhp, caps.maxpwr, caps.minkg, caps.maxkg)
        if not compliant then
            staged_ok = false
            warn_over_cap(own, power, weight, caps)
            -- Revert only in the staging phase: replaceVehicle is a working pass-through only under the
            -- swap-allowed staging lock. Past staging (a late swap whose jbeam loads only after the
            -- countdown began) the full lock refuses replaceVehicle silently, so a revert can't take effect
            -- there -- we adopt (warned) rather than falsely believe we reverted. Needs a compliant car
            -- captured to revert to.
            if M.state.staged_spec and M.state.phase == "staging" then
                local reverted, revert_err = vehicles.replace_spec(own, M.state.staged_spec)
                if reverted then
                    -- Mark our own revert so the consume branch skips the gate for exactly the cycle it
                    -- starts (and no later player swap); the reverted car is adopted on the next cycle.
                    M.state.revert_pending = true
                    log("I", RACE_LOG_TAG, "over-cap staging swap reverted to the last compliant car")
                    return
                end
                -- Revert call failed outright: fall through and adopt so the player is at least frozen on
                -- the grid -- they were warned above.
                log("W", RACE_LOG_TAG, "could not revert over-cap staging swap: " .. tostring(revert_err))
            else
                -- No compliant car to revert to, or past staging where the lock refuses a replace: adopt
                -- (warned) rather than trap the player.
                log("W", RACE_LOG_TAG, "over-cap staging swap not reverted (no target / not staging); adopting")
            end
        end
    end
    -- Clear the one-cycle revert flag and, when the adopted car is compliant, move the revert target forward
    -- to it (Mode 3 only) so a later over-cap swap reverts to the car actually staged now. A non-compliant
    -- car we had to adopt (revert failed / nothing to revert to) must NOT become the revert target.
    M.state.staging_swap_reverting = false
    if caps and staged_ok then
        M.state.staged_spec = vehicles.capture_spec(own) or M.state.staged_spec
    end

    -- Adopt the staging car: re-point the bounce target, re-place front-anchored to its now-correct
    -- footprint, re-freeze, and clear the VE-arm flags so onUpdate re-arms its VE this frame.
    local own_id = own:getId()
    M.state.race_car_id = own_id
    M.state.current_vehicle_id = own_id
    local pose = M.state.race and M.state.race.myPose
    if pose then
        -- restage_at_grid, NOT respawn_own_at: respawn_own_at -> keep_own -> despawn_owned_except
        -- deletes every OTHER owned vehicle, which on the host includes the AI cars (they are
        -- host-owned) -- that wiped the whole AI field. restage_at_grid does the same front-anchored
        -- repair+teleport without any despawn (the exact path the AI restage uses, ai.lua).
        -- There is no stray own car to clean here anyway: a fresh spawn already despawned at spawn
        -- time, and a staging swap replaces in place.
        -- restage_at_grid, not place_at_grid: the fresh-spawn path already front-anchored the car from
        -- its config bounding box, so this measures the now-loaded jbeam and only teleports when the car
        -- is genuinely off its slot. A staging swap into a differently sized car still gets its full
        -- correction; a correctly predicted car is left standing where it is.
        local moved, delta = vehicles.restage_at_grid(own, pose)
        if moved == nil then
            log("W", RACE_LOG_TAG, "could not re-place staging car: " .. tostring(delta))
        elseif not moved then
            log("I", RACE_LOG_TAG, string.format(
                "staging car already on its grid slot (%.3f m); no re-place", delta))
        else
            -- The correction itself, which the log could not see before. This teleport is what a player
            -- watching their swapped car actually notices, so how far it moves -- and whether it still
            -- moves at all -- is the one number that says whether a staging swap sits right.
            log("I", RACE_LOG_TAG, "re-placed staging car onto its grid slot ("
                .. (delta and string.format("%.3f m off", delta) or "deviation unreadable") .. ")")
        end
    end
    vehicles.set_vehicle_frozen(own, true)
    M.state.assist_armed = false
    M.state.freeze_hold_armed = false
    -- The new car's jbeam is loaded now (the restage waited for it), so its licenseplate init has
    -- already run -- apply the player's captured plate here, where it sticks instead of being
    -- regenerated. Only a forced/fresh spawn set restage_plate; a staging swap leaves it nil and keeps
    -- its own plate. Purely cosmetic since ADR-0054: the plate carries no identity any more, it just
    -- keeps the player's car looking like his car across a forced respawn.
    if M.state.restage_plate then
        local applied, plate_err = vehicles.apply_plate(own, M.state.restage_plate)
        if not applied then
            log("W", RACE_LOG_TAG, "could not apply plate to restaged car: " .. tostring(plate_err))
        end
        M.state.restage_plate = nil
    end
    -- Re-report the adopted car (ADR-0051). A staging swap can make the car bigger OR smaller, so the
    -- reservation behind it has to be able to appear AND disappear again -- and this is the one point
    -- where the swapped car's jbeam is loaded, which is what makes the read reliable. It also brings the
    -- reported pwr (ADR-0033) and the recorded car (ADR-0027) in line with the car actually staged;
    -- until now both still described the car this client first spawned with.
    local race_name = M.state.race and M.state.race.serverName
    if race_name then
        local swapped_info = vehicles.collect_client_info(own)
        send_to_server("clientInfo", {
            race = race_name,
            vehicle = swapped_info.vehicle,
            pwr = swapped_info.pwr,
            carLength = swapped_info.car_length,
            carWidth = swapped_info.car_width,
        })
    end
    M.state.restage_pending = false
    log("I", RACE_LOG_TAG, "staging car adopted at its grid slot as race car " .. tostring(own_id))
end

-- Keep the staging-wait line on the centered overlay (ADR-0021 amendment). There is nothing to count
-- any more -- staging is open-ended and only the host starts it -- so this re-pushes the same payload on
-- a slow cadence rather than ticking a clock; see countdown.STAGING_REPAINT_INTERVAL for why it repeats
-- at all. The server stays authoritative on the actual staging->countdown transition.
local function step_staging(dt_real)
    local staging = M.state.staging
    if not staging then
        return
    end
    staging.repaint_in = staging.repaint_in - (dt_real or 0)
    if staging.repaint_in > 0 then
        return
    end
    staging.repaint_in = countdown.STAGING_REPAINT_INTERVAL
    -- F1 light start (ADR-0043): a short pre-procedure heads-up during the staging wait, before the
    -- lights begin. Reads the relayed start mode + penalty (the only consumer of those race fields).
    --
    -- The penalty rides in with raceStart and the server always fills it for an F1 start, so the number
    -- is there in every real case. Should it ever not be, the sentence LOSES the figure rather than
    -- naming a guessed one: a driver reads this as what will happen to him, and there is no channel here
    -- to check a guess against -- an ordinary player never sees a setupOpen.
    local race = M.state.race
    local hint = nil
    if race and race.startMode == "f1" then
        hint = "F1 light start -- hold until lights out"
        local penalty = tonumber(race.jumpPenaltySeconds)
        if penalty then
            hint = hint .. " (jump = +" .. tostring(penalty) .. "s)"
        end
    end
    countdown.show_staging(hint)
end

-- Tick the start countdown in wall time off the server-issued duration (ADR-0021): render each whole
-- second on the centered overlay and play the final 3-2-1 beeps as the shown number changes. GO! and
-- the actual release are driven by the server `racing` phase, not this tick.
local function step_start_countdown()
    local count = M.state.countdown
    if not count then
        return
    end
    if count.lights then
        -- F1 light start (ADR-0043): render the light tower + watch for a jump instead of the numeric count.
        f1_step_lights(count)
        return
    end
    local remaining = math.max(0, count.total - (os.clockhp() - count.anchor))
    local shown = math.max(1, math.ceil(remaining))
    if shown ~= count.last_shown then
        count.last_shown = shown
        countdown.show_start(shown)
        countdown.play_beat(shown)
    end
end

-- Self-healing HUD watchdog (ui-missing-for-some-clients-reload): keep the HUD/countdown app surface
-- present while a race wants it on screen. The app heartbeats via M.note_hud_alive; on silence the
-- watchdog re-asserts visibility -- a dedup'd re-add of the layout ENTRY via the 0.39 seam -- on a
-- doubling backoff. That is the ONLY stage: the historic Stage-B reloadUI escalation is retired,
-- because 0.39 both made it unnecessary (apps persist in the layout file and every completed UI boot
-- re-renders it -- the pre-0.39 "dropped app never comes back" case cannot happen) and made it harmful
-- (menu routes unmount the whole apps layer, so silence is often a hidden-but-healthy UI, and the
-- "rescue" reloaded it -- see the threshold block). Silence therefore means one of: menu open (re-add
-- is a cheap dedup no-op, backoff keeps it rare), UI booting (the entry renders when the boot
-- finishes; onUiReady resets the cadence), or the entry really got removed -- which the very first
-- re-show repairs. Called from onUpdate in the visible phases only, so free-roam is never disturbed.
local function step_hud_watchdog(dt)
    M.state.hud_ack_gap = M.state.hud_ack_gap + (dt or 0)
    if M.state.hud_ack_gap < HUD_ACK_STALE then
        -- App is heartbeating -- surface healthy, reset the re-show throttle to the fast cadence.
        M.state.hud_reshow_wait = 0
        M.state.hud_reshow_interval = HUD_RESHOW_EVERY
        return
    end
    -- Re-assert app visibility on the backoff, until the app heartbeats again.
    M.state.hud_reshow_wait = M.state.hud_reshow_wait + (dt or 0)
    if M.state.hud_reshow_wait >= (M.state.hud_reshow_interval or HUD_RESHOW_EVERY) then
        M.state.hud_reshow_wait = 0
        M.state.hud_reshow_interval =
            math.min((M.state.hud_reshow_interval or HUD_RESHOW_EVERY) * 2, HUD_RESHOW_MAX)
        hud.show()
    end
end

-- Re-bind the stock, vehicle-bound dashboard/tacho to the confirmed active race car after the race-start
-- seat churn (bug default-dashboard-ui-missing-at-race-start). Fired once per anchor by
-- step_dashboard_refresh, only after the car's VE is bindable. Two guarded layers cover the two
-- root-cause sub-cases from 1-investigation.md:
--   1. Re-assert the seat with the now-ready VE (be:enterVehicle, the legitimate switch path used all over
--      this file) -- re-points the UI's vehicle-stream source at the race car. Fixes "the switch landed
--      before the VE streams were up / onto a transient car".
--   2. Replay the engine's own vehicle-focus dispatch (hud.rebind_vehicle_apps) so the stock apps re-bind
--      even when the seat was ALREADY active and step 1 short-circuits. Fixes "already seated but the final
--      refresh was missed".
-- Both are pcall-guarded and target only the race car, so a healthy dashboard is undisturbed and the
-- in-race lock / seat-bounce (ADR-0017) is never fought (the race car is the bounce target).
local function refresh_stock_dashboard(race_car)
    if not race_car then
        return
    end
    local ok_id, race_id = pcall(function() return race_car:getId() end)
    if not ok_id then
        race_id = nil
    end
    if be then
        pcall(function() be:enterVehicle(0, race_car) end)
    end
    hud.rebind_vehicle_apps(race_id)
    log("I", RACE_LOG_TAG, "stock dashboard rebind fired for race car " .. tostring(race_id))
end

-- Drive the queued stock-dashboard rebind (bug default-dashboard-ui-missing-at-race-start): wait until the
-- (re)seated race car resolves and its jbeam bbox is loaded (the same readiness proxy the deferred restage
-- uses -- streams come up around then), then let a short settle window elapse and fire the rebind once,
-- clearing the flag. Zero-work on the idle path (pending false). Mirrors restage_swapped_car's deferred,
-- readiness-gated shape. Called from onUpdate in the HUD-visible phases only, so free-roam is untouched.
local function step_dashboard_refresh(dt)
    if not M.state.dash_refresh_pending then
        return
    end
    local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own or vehicles.spawn_oobb_forward(own) == nil then
        -- No seated own car yet, or its jbeam is still loading: keep waiting (the settle timer only counts
        -- down once the car is bindable, so a slow spawn never fires the rebind against a not-ready VE).
        return
    end
    M.state.dash_refresh_wait = (M.state.dash_refresh_wait or 0) - (dt or 0)
    if M.state.dash_refresh_wait > 0 then
        return
    end
    refresh_stock_dashboard(own)
    M.state.dash_refresh_pending = false
end

function M.onUpdate(dtReal, dtSim, dtRaw)
    if not M.state.registered then
        ensure_registered()
    end
    -- Phase-independent, host-only: drive the powered props' (grinders') activation readiness window. The
    -- `spinner` main-controller only comes up after the freshly spawned grinder VE's powertrain init, so a
    -- single activation at spawn lands before getControllerSafe("spinner") is non-nil (-> no-op); step
    -- re-issues per frame and stops the moment every grinder's VE confirms its controller took the command,
    -- so we never re-assert against a running PID (ADR-0020 amendment). The budget is counted in FRAMES
    -- here, which is the fix for round 2 of bug race-prop-steals-player-seat: the old wall-clock deadline
    -- was armed before the AI field spawned synchronously in handle_race_start, so it could expire before
    -- this line ever ran once. grinder_activate is nil off-race / on a non-host / once the window closes, so
    -- the idle path is one nil check. BeamMP syncs the resulting spin to every client.
    if M.state.grinder_activate then
        M.state.grinder_activate = grinders.step(M.state.grinder_activate)
    end
    -- Phase-independent: keep the race-setup panel on screen while it is meant to be open (bug
    -- setup-panel-settings-survive-ui-reload). The panel heartbeats, and a UI reload that dropped our
    -- late-mounted app (ADR-0008/0012) is recovered by a single re-add. Not phase-gated on purpose --
    -- the panel is used in the lobby AND carries the race-stop controls mid-race. One boolean read when
    -- no panel is open.
    if M.state.setup_open then
        setup.step(dtReal)
    end
    -- Phase-independent: age the centred message line + checkpoint readout, and keep whatever still
    -- stands painted (feature race-toast-cleanup-and-checkpoint-readout). NOT phase-gated: a message
    -- raised in the last racing frame still has to expire, and by then the phase may be gone. Two nil
    -- checks when nothing stands.
    notice.step(dtReal)
    -- Phase-independent: retry whatever BeamNG's HUD-apps layout UI swallowed while it owned the
    -- layout document (bug ui-glitches-after-ingame-menu-resize). Every panel show/close in this file
    -- is a one-shot, so a call that lands in that window used to be lost for good -- the seam now
    -- records it and replays it here once the UI is done. One nil check when nothing is pending.
    M.uilayout.step()
    -- Phase-independent: write the one delayed read-back line of the last recover (how the car actually
    -- stands a second after the teleport, ADR-0034 amendment 2026-10-07) -- even if the race ended in
    -- that second. Physics time, so a paused game does not read a car that has not moved yet. One nil
    -- check when no recover is pending.
    vehicles.step_recover_readback(dtSim)
    -- Phase-independent: keep the server's picture of this client's car footprint current, so the next
    -- race can reserve grid space for it from the very first slot assignment (ADR-0051 round 2). The
    -- polling lives in race/vehicles (it is a measurement of the car); this is only the wiring, kept
    -- inline so it costs no top-level local in a file that sits near the 200 ceiling. During a race the
    -- per-car clientInfo reports own the footprint, so the poll stands down.
    if not M.state.race then
        -- Re-created rather than assumed: a Lua reload restores M.state as it was serialized, which for a
        -- state written before this field existed has no tracker at all -- and a nil one would silently
        -- kill the poll for the rest of the session.
        M.state.size_track = M.state.size_track or {}
        local own_size = vehicles.poll_own_size(M.state.size_track, M.state.current_vehicle_id, dtReal)
        if own_size then
            send_to_server("carSize", {carLength = own_size.length, carWidth = own_size.width})
            log("I", "beamcomp.grid", string.format("reported own car footprint %.2f x %.2f m",
                own_size.length, own_size.width))
        end
    end
    if M.state.phase == "staging" and M.state.race then
        -- Keep the staging-wait line up on the centered overlay (ADR-0021 amendment).
        step_staging(dtReal)
        -- Adopt a staging car swap as the new race car (re-freeze + bounce target + VE re-arm).
        restage_swapped_car(dtReal)
    elseif M.state.phase == "countdown" and M.state.race then
        -- Finish a still-pending re-stage into the countdown too (no-op once placed): a forced/fresh
        -- car whose jbeam loads slowly can miss its RESTAGE_MAX_WAIT inside a short staging phase.
        -- Mirrors the AI restage, which also spans staging + countdown.
        restage_swapped_car(dtReal)
        -- Tick the start countdown on the centered overlay (ADR-0021).
        step_start_countdown()
    elseif M.state.phase == "qualifying" and M.state.race then
        -- Qualifying (ADR-0041): the same detection + lap-clock path as racing, plus the host's AI
        -- detectors (the AI lap the quali plan too) and the local quali-clock countdown for the HUD. The
        -- server stays authoritative on the actual qualifying->results transition; this clock is display
        -- only and floors at 0 ("finish your lap" while the server runs the finish-your-lap grace).
        -- Staged sprint quali (ADR-0044): advance the per-driver spawn/count/GO sequence (own car + staging
        -- AI). step_detection / step_ai_detections below no-op until a driver launches (detector nil while
        -- holding), so a staged driver holds silently until its turn.
        if M.state.quali_staged then
            quali.step_staged()
        end
        -- Keep the recover-key block in step with hold.is_held() (bug quali-hold-reset-and-repaint-leak).
        -- Every transition syncs it already; this is the net that makes the predicate the single truth even
        -- if a future queue path forgets to. Costs one boolean compare -- the engine call only fires on an
        -- actual edge.
        hold.sync()
        -- The AI's half of the same net (bug quali-end-ai-not-frozen): re-assert the freeze on any parked AI
        -- that has started moving again. Covers BOTH quali modes -- the staged queue/ramp/done holds and the
        -- circuit "closed its lap in the grace window" park -- and no-ops on a non-host.
        quali.step_ai_hold()
        -- Host only: keep each AI's rolling route window topped up so they lap the whole session instead
        -- of running out of route (feature ai-rolling-route-window). Held AI are skipped -- their session
        -- is over. Inert on a non-host and for a route that fitted in a single block.
        ai.step_window(M.state.ai_cars, M.state.ai_window, M.state.quali_ai_held)
        step_detection(dtSim)
        step_ai_detections(dtSim)
        -- Run the AFK clock for every car this client owns and report the verdict to the server, ONLY
        -- while a finish-your-run/lap timer is running (feature stall-detection-client-measured-movement).
        -- After the detectors on purpose: a driver who crossed the line this frame is already `done` and
        -- is not measured on the way out.
        stall.step()
        -- Recover/repair work in qualifying exactly as in the race (ADR-0017): drive the held assist
        -- countdown so a player can reset a spun/stuck car and keep setting lap times.
        step_assist(dtReal)
        if M.state.qualifying then
            M.state.qualifying.remaining = math.max(0, M.state.qualifying.remaining - (dtReal or 0))
        end
        -- Once the quali clock expires the server arms a finish-your-lap window (ADR-0041): tick its local
        -- copy so the HUD shows the timeout to be at the finish (the server stays authoritative on the cut),
        -- and the AFK cutoff addendum with it.
        stall.step_clocks(dtReal)
    elseif M.state.phase == "qualiResults" and M.state.race then
        -- Update the quali-results card's "race starts in" remaining from the wall-clock anchor (os.clockhp),
        -- so the AI-despawn frame hitch can't drift it behind the server pause (ADR-0041). Display only.
        local quali_results = M.state.qualiResults
        if quali_results then
            quali_results.remaining =
                math.max(0, quali_results.total - (os.clockhp() - quali_results.anchor))
        end
    elseif M.state.phase == "racing" and M.state.race then
        step_detection(dtSim)
        -- Host only: top each AI's rolling route window up before it runs out of armed targets (feature
        -- ai-rolling-route-window). The counting is against the total sequence, so the final block ends
        -- exactly on the finish and nothing is armed after it. Inert otherwise.
        ai.step_window(M.state.ai_cars, M.state.ai_window, nil)
        -- Host only: step the AI detectors + proxy-report their crossings (ADR-0036). Inert otherwise.
        step_ai_detections(dtSim)
        -- Run the AFK clock for every car this client owns and report the verdict to the server, ONLY
        -- while the finish grace is running (feature stall-detection-client-measured-movement). The
        -- race-blind server has no other source for this; outside a grace nothing is measured or sent.
        stall.step()
        -- F1 light start (ADR-0043): release the AI on their staggered reaction delay, and measure + report
        -- each car's start reaction for the standings React column (both no-op for a normal start).
        f1_step_ai_release()
        f1_step_reactions()
        -- Drive the held recover/repair countdown (ADR-0017).
        step_assist(dtReal)
        -- Tick the finish-grace countdown, and the AFK cutoff addendum behind it, in wall time (the
        -- server's cutoff is wall-time; ADR-0014). Visual only -- the server stays authoritative on the
        -- actual DNF cutoff.
        stall.step_clocks(dtReal)
    end
    -- Host only: once BeamMP has registered the spawned AI cars, broadcast their server ids so remotes can
    -- label + suppress them (ADR-0036). Registration is async, so this retries while pending until every
    -- AI car resolves a server id (SPIKE #2); if one never resolves, the map is simply not sent and the
    -- owner's tag stays on the cars (the accepted cone fallback, ADR-0020).
    if M.state.ai_map_pending and M.state.ai_cars then
        local entries = ai.server_map(M.state.ai_cars)
        if #entries == #M.state.ai_cars then
            send_to_server("aiMap", {entries = entries})
            M.state.ai_map_pending = false
            log("I", RACE_LOG_TAG, string.format("broadcast aiMap for %d AI car(s)", #entries))
        end
    end
    -- Non-owner: keep resolving the relayed aiMap to local handles until every synced AI car is found.
    resolve_remote_ai()
    -- Host only: keep the race's prop set derived and relayed while anything about it is still moving
    -- (ADR-0062). One boolean test when there is nothing pending.
    identity.prop_map_step(dtReal)
    -- Everyone: re-assert who carries a name. Slow tick, writes only on a difference, and guarded by a
    -- nil chain when this client knows nothing about names at all.
    identity.tag_step(dtReal)
    -- Host only: deferred front-anchor restage of the AI cars onto the grid over the frozen phases, once
    -- each car's jbeam has loaded (ADR-0036) -- the per-car mirror of the player restage above. Includes
    -- qualiResults so the quali re-spawned AI (which now spawn a lead time before the countdown, ADR-0041)
    -- are straightened onto the grid during the pause, not mid-countdown.
    if (M.state.phase == "staging" or M.state.phase == "countdown" or M.state.phase == "qualiResults")
        and M.state.ai_cars then
        ai.restage(M.state.ai_cars, dtReal)
    end
    -- Arm the seated car's VE key forwarders across the locked sequence (staging + countdown + racing).
    -- The first successful arm installs the override + reset guard, so vanilla recover/reset is never
    -- available mid-race even with both assists off (ADR-0017). It must cover staging too: the lock
    -- arms there (ADR-0021), but the recover keys are owned by this VE override (not action-filtered),
    -- so without it Insert/Ctrl+Insert would still trigger vanilla recover and break the grid freeze.
    if (M.state.phase == "staging" or M.state.phase == "countdown" or M.state.phase == "racing"
        or M.state.phase == "qualifying" or M.state.phase == "qualiResults") and M.state.race then
        push_assist_arm()
    end
    -- Arm the EV start-freeze throttle clamp over the frozen phases (staging + countdown), so it lifts on
    -- racing with the GE freeze (ADR-0017 amendment). The VE clamps only on EVs. Skip it during an F1
    -- light-start countdown: that frees the car at the first light (ADR-0043), so the clamp must not re-arm.
    --
    -- A qualifying HOLD is a frozen phase too (bug quali-hold-reset-and-repaint-leak): controller.setFreeze
    -- is a soft hold that an EV's instant 0-rpm torque creeps through, so without the clamp an electric car
    -- can simply drive out of the hold under full throttle -- no key press needed. quali.launch_local already
    -- disarms the clamp at GO (as begin_driving and f1_begin_lights do on their releases), which is what this
    -- arm was always missing its other half of.
    --
    -- The window itself is hold.is_frozen_phase(), shared with the in-place reload re-arm
    -- (rearm_own_car_on_reload) so the two layers that enforce it cannot drift apart.
    if M.state.race and hold.is_frozen_phase() then
        push_freeze_hold()
    end
    -- Keep pushing during the finished phase too so the results template (ADR-0012) renders the
    -- frozen final standings, not the last frame caught mid-racing. Qualifying + quali-results push too,
    -- so the HUD renders the quali clock/classification and the results card (ADR-0041). Countdown pushes
    -- as well so the quali-results card clears when the pause ends -> race countdown (else the frozen
    -- qualiResults snapshot would linger until racing); all HUD cards are gated off countdown, so it stays
    -- blank behind the centered count.
    local full_hud = (M.state.phase == "racing" or M.state.phase == "finished" or M.state.phase == "qualifying"
        or M.state.phase == "qualiResults" or M.state.phase == "countdown") and M.state.race
    local series_active = (M.state.tournament and M.state.tournament.active)
        or (M.state.championship and M.state.championship.active)
    if full_hud then
        hud.push(build_hud_snapshot())
        M.state.idle_info_shown = false
    elseif series_active and (M.state.phase == "staging"
            or (not M.state.race and (M.state.phase == nil or M.state.phase == "lobby"))) then
        -- Show the compact series info box (ADR-0042) while a championship/tournament is active and the full
        -- HUD time block is NOT up: between races (lobby/free-roam) AND during the staging prepare window, so
        -- the running format + progress stays visible through the pre-race wait (the in-race time block slot).
        -- The full HUD takes over from the countdown onward; free-roam stays otherwise untouched (the push
        -- only fires while a series is active).
        if not M.state.idle_info_shown then
            hud.show()
            M.state.idle_info_shown = true
        end
        hud.push(build_idle_info_snapshot())
    elseif M.state.idle_info_shown then
        -- The series ended/reset while idle: take the info box down and revert to the normal HUD.
        hud.clear()
        hud.hide()
        M.state.idle_info_shown = false
    end
    -- Keep the HUD/countdown app surface alive while a race wants it on screen
    -- (ui-missing-for-some-clients-reload): the app heartbeats and this re-shows the layout entry on
    -- a backoff if it goes silent (no reload stage since 0.39, see step_hud_watchdog). Covers staging
    -- (the countdown overlay arms there, ADR-0021) through finished; free-roam is untouched.
    if M.state.race and (M.state.phase == "staging" or M.state.phase == "countdown"
        or M.state.phase == "racing" or M.state.phase == "finished"
        or M.state.phase == "qualifying" or M.state.phase == "qualiResults") then
        step_hud_watchdog(dtReal)
        -- Re-bind the stock dashboard/tacho once the (re)seated race car is ready, in the same visible
        -- phases (bug default-dashboard-ui-missing-at-race-start). Idle unless a rebind is queued.
        step_dashboard_refresh(dtReal)
    end
    -- Phase-independent: follow the grid editor's session with the camera (ADR-0063). It watches the
    -- session counter instead of being called by every New / Load / console start, so a session start
    -- added later moves the camera too. One boolean read while nobody is editing. Last in this function on
    -- purpose: whatever it ever does wrong, it can never skip a line of the race loop above.
    M.gridcam.step(grideditor.state, M.state.race ~= nil)
end

function M.onPreRender(dtReal, dtSim, dtRaw)
    if not debugDrawer then
        return
    end
    -- Nothing to draw with no race and no edit session (the common free-roam case): skip before building
    -- the pcall closure so the idle path stays zero-work. This never hides an AI tag: the host's AI cars
    -- are spawned only after raceStart has set M.state.race and are all gone before anything sets it back
    -- to nil (teardown, a rejected raceStart) -- checked 2026-10-08, feature host-sees-ai-nametags.
    if not M.state.race and not grideditor.state.active then
        return
    end
    -- Per-frame turn budget for the marker orientation slew-limit: real frame time, self-clamped so a
    -- frame hitch can never yield a big single-frame step that would read as a snap (dtReal is already
    -- clamped by the engine, but be defensive).
    local marker_dt = math.min(math.max(dtReal or 0, 0), MARKER_DT_CLAMP)
    -- Guard the draws: debugDrawer's exact API is runtime-confirmed here, so a mismatch warns once
    -- rather than spamming every frame. The editor preview draws independent of a race (it is used in
    -- free-roam); the next-checkpoint marker only while a race is racing.
    local ok, err = pcall(function()
        draw_editor_grid()
        -- The grid edit's route (ADR-0023 amendment 2026-10-06): CP0 red, CP1 in the yellow the race uses
        -- for "the one after", every other checkpoint grey, no distance limit and no finish colour. Drawn
        -- grey first, then yellow, then red, so the two that matter win where columns overlap. Inline
        -- rather than a helper because a helper here would be a top-level local (200-local ceiling).
        -- Immediate-mode, drawn whenever a session is active (car_pos/line_angle nil -> full area +
        -- stored-normal posts).
        local route = grideditor.state.active and M.state.grid_edit_checkpoints
        if route then
            for i = #route, 3, -1 do
                draw_checkpoint_marker(route[i], grideditor.ROUTE_CHECKPOINT_STYLE, nil, nil)
            end
            if route[2] then
                draw_checkpoint_marker(route[2], LOOKAHEAD_STYLE, nil, nil)
            end
            if route[1] then
                draw_checkpoint_marker(route[1], CHECKPOINT_STYLE, nil, nil)
            end
        end
        local race = M.state.race
        if race then
            local detection = M.state.detection
            if (M.state.phase == "racing" or M.state.phase == "qualifying")
                and detection and not detection.done then
                -- Use the same owned car the detector crosses checkpoints with (step_detection), so the
                -- posts face the point that actually triggers the gate, not a different camera vehicle.
                local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
                local car_pos = own_car and own_car:getPosition()
                draw_next_checkpoint(race, detection, car_pos, marker_dt)
            end
        end
    end)
    if not ok and not M.state.marker_warned then
        M.state.marker_warned = true
        log("W", RACE_LOG_TAG, "marker draw failed (debugDrawer API?): " .. tostring(err))
    end
    -- The names over the host's own AI cars (ADR-0062 amendment 2026-10-08). Outside the marker pcall on
    -- purpose: it guards itself and warns under its own tag, so a marker failure can never hide the tags
    -- and a tag failure can never hide the markers.
    identity.draw_tags()
end

-- The level is ending -- the player left the BeamMP session or changed level, possibly mid-race.
-- The extension is pinned to manual unload (onExtensionLoaded) so it survives level switches during a
-- race, which means onExtensionUnloaded does NOT fire here; without this hook a mid-race exit would
-- orphan the spawned props/cones into the next singleplayer load of the same map. Tear the race world
-- down but keep the BeamMP handler registered -- the extension lives on for the next race. Mirrors
-- core/groundMarkers + core/checkpoints, which reset their scene state on onClientEndMission likewise.
function M.onClientEndMission(_levelPath)
    teardown_race_world()
    M.state.phase = nil
    -- Leaving the level reloads the UI and drops our server-delivered apps; without this the remembered
    -- open state would pop the setup panel back up on the next map, unasked (ADR-0037 stays
    -- command-opened -- bug setup-panel-settings-survive-ui-reload).
    setup.clear()
    -- Leaving the session is where the server's nametag policy stops applying (ADR-0062), and where its
    -- statement about the race-setup panel stops too. A separate call rather than a line inside
    -- setup.clear, because that function also runs on the panel's Close, which is not a session boundary
    -- (bug panel-close-wipes-nametag-policy).
    identity.clear_policy()
    -- A Confirm still on its way belongs to the server we just left (teardown above already dropped the
    -- staged grid's record). Not in setup.clear, which the panel's Close runs too.
    setup.drop_request("left the session")
    -- Drop the grid editor's remembered camera, never restore it: a pose on the old level means nothing
    -- on the next one (ADR-0063). The edit session itself is left as it was.
    M.gridcam.leave("level")
    -- Drop the remembered race scan (feature raceui-reopen-without-typing): a level change is the one
    -- moment the installed set can plausibly have changed since we looked. Required inline rather than at
    -- the top of the file because init.lua sits at LuaJIT's 200-local ceiling and this is its only caller
    -- -- require is memoized, so it costs a table lookup (same trade as race/parser.lua's path loader).
    require("beamcomp/race/discovery").invalidate()
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    -- A GE Lua reload mid-capture takes the controls window's app down with the UI, so nothing over
    -- there can restore the three input switches any more. This runs BEFORE M.state is rebuilt, so the
    -- armed flag is still readable (ADR-0052). No-op when no capture is armed.
    M.release_input_capture()
    -- Give the grid editor's camera back while somebody still knows where it was: after the reload nothing
    -- does (ADR-0063, ADR-0052). Guarded on its own because this hook is called without a pcall, and a
    -- throw here would skip the whole teardown below.
    local cam_ok, cam_err = pcall(M.gridcam.leave, "reload")
    if not cam_ok then
        log("W", "beamcomp.grid", "camera could not be given back on unload: " .. tostring(cam_err))
    end
    grideditor.clear()
    -- Despawn any grid-edit reference props too (their lifecycle is separate from the race props that
    -- teardown_race_world clears), so a reload mid-edit leaves no orphaned scenery.
    props.clear(M.state.grid_edit_prop_names or {})
    M.state.grid_edit_prop_names = nil
    M.state.grid_edit_checkpoints = nil
    spawn_mute.restore()
    -- Despawn props/cones, lift the in-race lock + start freeze, and drop all race state so a reload
    -- mid-race never leaves orphaned scenery or a stuck-frozen/locked car (ADR-0017).
    teardown_race_world()
    M.state.phase = nil
    -- Give BeamMP its nametag switches back. Guarded on its own like the camera above: this hook has no
    -- pcall around it, and the unwrap must not be the reason the log line below never comes.
    local tags_ok, tags_err = pcall(nametags.uninstall_toggle_mirror)
    if not tags_ok then
        log("W", "beamcomp.nametags", "nametag toggles could not be given back: " .. tostring(tags_err))
    end
    log("I", LOG_TAG, "unloaded")
end

-- The grid-editor command surface (ADR-0023). These are intentionally GLOBAL so they can be typed
-- straight into the BeamNG GE Lua console (the only authoring UI this iteration). Each is a thin
-- wrapper over race/grideditor (preview, client-local), with save/assign/fetch/list going over
-- send_to_server (server owns the shared grids file; save/assign are admin-gated server-side).
-- A grid BELONGS to a race (ADR-0023 amendment 2026-07-27) -- the race it is authored/anchored against
-- when saved -- and names are unique only within one race, so beamcomp_grid_edit takes the race too:
-- beamcomp_grid_edit("<race>", "<gridname>"). The first grid saved for a race becomes that race's default
-- grid automatically; beamcomp_grid_assign re-points it.
-- Knobs (beamcomp_grid_set):
--   offsetForward  -- shift the whole grid forward/back along the travel axis (m)
--   offsetLateral  -- shift the whole grid left/right (m)
--   offsetHeight   -- lift each pose of the segment this far ABOVE the ground (m), applied AFTER the
--                     surface snap at spawn and in the preview (+1 = hovers exactly 1 m). Per segment;
--                     does not chain into later segments.
--   rowGap         -- spacing between positions front-to-back (m)
--   colGap         -- spacing between positions left-to-right (m)
--   headingDeg     -- rotate the whole grid about vertical (deg)
--   rows           -- number of rows (columns = ceil(field / rows); columns auto-stagger by rowGap/cols)
--   columns        -- explicit number of columns: pins the grid width so it does not grow with a large
--                     field (e.g. many AI); overrides rows. Setting rows again switches back to deriving.
--   mirror         -- boolean lateral side flip: on moves the pole to the other side (pole-right)
--                     while keeping the stagger and front-to-back order; off (default) is pole-left.
-- Segments (ADR-0023 amendment): beamcomp_grid_breakpoint(slot) selects (or creates, seeded from the
-- covering segment) the segment starting at `slot` -- the knobs above then edit that segment, which
-- stacks behind the previous one; beamcomp_grid_removebreak() drops the active breakpoint. Slot 0 is the
-- base segment. A NEW breakpoint auto-seeds an internal pre-grounding height anchor from the terrain
-- (chains into the tail, re-centers the ground-cast window on climbing terrain); the anchor is not a
-- knob -- re-create the breakpoint to re-seed it. A grid with no breakpoints is exactly today's
-- single-block behaviour.

-- GE console command (intentionally global): start a fresh grid from the track's generated layout.
function beamcomp_grid_new(race_name)
    local ok, reason = grideditor.start_fresh(race_name)
    if ok then
        editor_feedback("editing new grid for '" .. tostring(reason)
            .. "' -- tune with beamcomp_grid_set(\"<knob>\", <value>)")
    else
        editor_feedback(tostring(reason), "warning")
    end
end

-- GE console command (intentionally global): open a SAVED grid for further editing. A grid belongs to a
-- race and names are unique only within one (ADR-0023 amendment), so the race is part of the address; it
-- is resolved to its canonical id here like in beamcomp_grid_assign. The grid lives on the server, so we
-- request it (gridFetch); handle_grid_data opens it when the reply arrives.
function beamcomp_grid_edit(race_name, grid_name)
    if type(race_name) ~= "string" or race_name == "" or type(grid_name) ~= "string" or grid_name == "" then
        editor_feedback("usage: beamcomp_grid_edit(\"<race>\", \"<gridname>\")", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    local race_id, reason = race_start.resolve_id(race_name)
    if not race_id then
        editor_feedback(tostring(reason), "warning")
        return
    end
    send_to_server("gridFetch", {map = map, race = race_id, name = grid_name})
    editor_feedback("opening saved grid '" .. grid_name .. "' of " .. race_id .. " ...")
end

-- GE console command (intentionally global): list the grids saved for the current map (gridListReq),
-- grouped by race with the per-race default starred (see handle_grid_list). The ONE caller that names
-- "console" as its destination, which is what keeps the toast off every other reply.
function beamcomp_grid_list()
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    setup.request_list("gridListReq", map, "console")
end

-- GE console command (intentionally global)
function beamcomp_grid_set(knob, value)
    local ok, applied = grideditor.set(knob, value)
    if ok then
        editor_feedback(tostring(knob) .. " = " .. tostring(applied))
    else
        -- On failure the second return is the reason string.
        editor_feedback(tostring(applied), "warning")
    end
end

-- GE console command (intentionally global)
function beamcomp_grid_dir(direction)
    local ok, reason = grideditor.set_direction(direction)
    if ok then
        editor_feedback("editing " .. tostring(direction) .. " block")
    else
        editor_feedback(tostring(reason), "warning")
    end
end

-- GE console command (intentionally global): select (or create) the segment starting at `start_slot`
-- as the active one; the knobs then edit it (ADR-0023 amendment). Slot 0 selects the base segment.
-- The ARGUMENT stays a 0-based GE slot -- it is this command's contract and the same number the editor
-- stores. Only the feedback carries both numbers (see below).
function beamcomp_grid_breakpoint(start_slot)
    local ok, applied = grideditor.select_segment(start_slot)
    if ok then
        -- The one place the two number spaces meet in one sentence (ADR-0023 amendment 2026-08-01), and
        -- the only user-visible text that still shows a raw slot: `applied` is the 0-based slot, kept
        -- legible for whoever typed it into the console, and the parenthesised P is the 1-based label the
        -- preview pillars and the editor panel show for that same slot.
        editor_feedback("editing segment from slot " .. tostring(applied)
            .. " (P" .. tostring(applied + 1) .. ")")
    else
        editor_feedback(tostring(applied), "warning")
    end
end

-- GE console command (intentionally global): remove the active breakpoint, merging its slots back into
-- the previous segment.
function beamcomp_grid_removebreak()
    local ok, reason = grideditor.remove_segment()
    if ok then
        editor_feedback("breakpoint removed -- merged into the previous segment")
    else
        editor_feedback(tostring(reason), "warning")
    end
end

-- GE console command (intentionally global)
function beamcomp_grid_save(name)
    if type(name) ~= "string" or name == "" then
        editor_feedback("usage: beamcomp_grid_save(\"<name>\")", "warning")
        return
    end
    if name:find("%s") then
        -- A name with spaces could never be selected via /race grid=<name> (the arg parser splits on
        -- whitespace), so reject it at the source.
        editor_feedback("grid name must not contain spaces", "warning")
        return
    end
    local snapshot = grideditor.snapshot(name)
    if not snapshot then
        editor_feedback("not editing -- beamcomp_grid_new(\"<race>\") first", "warning")
        return
    end
    send_to_server("gridSave", snapshot)
    editor_feedback("saving grid '" .. name .. "' ...")
end

-- GE console command (intentionally global): bind a saved grid as the default for a race. Race + grid
-- are explicit, so it works without an active edit session; the race is resolved to its canonical id.
function beamcomp_grid_assign(race_name, grid_name)
    if type(race_name) ~= "string" or race_name == "" or type(grid_name) ~= "string" or grid_name == "" then
        editor_feedback("usage: beamcomp_grid_assign(\"<race>\", \"<gridname>\")", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    local race_id, reason = race_start.resolve_id(race_name)
    if not race_id then
        editor_feedback(tostring(reason), "warning")
        return
    end
    send_to_server("gridAssign", {map = map, race = race_id, name = grid_name})
    editor_feedback("assigning '" .. grid_name .. "' as default for " .. race_id .. " ...")
end

-- GE console command (intentionally global): despawn the preview pillars and leave edit mode.
function beamcomp_grid_cancel()
    grideditor.clear()
    props.clear(M.state.grid_edit_prop_names or {})
    M.state.grid_edit_prop_names = nil
    M.state.grid_edit_checkpoints = nil
    -- The console's Close: the camera goes back to where it was before the first jump (ADR-0063).
    M.gridcam.leave("cancel")
    editor_feedback("grid editing ended -- pillars cleared")
end

return M
