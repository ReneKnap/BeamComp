-- BeamComp -- client GE (Game-Engine) extension.
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
--                 cone. The cones are kept non-enterable / out of the Tab cycle on every client via
--                 race/cones (ADR-0020, superseding ADR-0009).
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
--          (bug quali-hold-reset-and-repaint-leak).
-- setup -- the race-setup panel's GE-side presence: the session open-state set by the admin-gated
--          /raceui open, and the one-shot watchdog that re-adds the app when a UI reload drops it
--          (bug setup-panel-settings-survive-ui-reload).
local quali = {}
local hold = {}
local setup = {}
-- ===== end namespace tables =============================================================

-- How long to mute BeamMP's vehicle-spawn notifications from a race start, covering the host's
-- cone-spawn burst on every other client (race/spawn_mute, ADR-0020 finding #2b).
local SPAWN_NOTIFICATION_MUTE_SECONDS = 5

local EVENT_CHANNEL = "beamcompEvent"
local LOG_TAG = "beamcomp.net"
local RACE_LOG_TAG = "beamcomp.race"

-- HUD self-healing watchdog thresholds (seconds). The app heartbeats ~1s (note_hud_alive); if GE hears
-- nothing for HUD_ACK_STALE while a race wants the HUD up, it re-asserts visibility every
-- HUD_RESHOW_EVERY, and if the surface is still silent at HUD_RELOAD_AFTER it escalates to a one-shot UI
-- reload (recovers an engine/BeamMP UI reload that dropped our late-mounted app, ADR-0008/0012).
local HUD_ACK_STALE = 1.5
local HUD_RESHOW_EVERY = 1.0
local HUD_RELOAD_AFTER = 4.0

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

-- How long to keep retrying BeamMP nametag suppression on a freshly synced cone before giving up. A
-- remote-synced cone is registered in MPVehicleGE asynchronously, a frame or two after onVehicleSpawned
-- fires, so the one-shot hide_nametag there misses it; we retry from onUpdate until it sticks. The
-- timeout is only the give-up bound (registration normally settles almost immediately); on timeout the
-- tag simply stays -- the same accepted fallback as before (ADR-0020 finding #4).
local NAMETAG_RETRY_TIMEOUT = 10.0

-- Seconds to wait for a (swapped or freshly-spawned) car's jbeam to finish loading before re-placing it
-- anyway (fallback for a same-footprint swap, where the bbox never visibly changes). Forward
-- half-length change (metres) that signals the new jbeam has loaded and the bbox now reflects the
-- actual car. Used by restage_swapped_car; declared here so handle_race_start can arm the same flow.
local RESTAGE_MAX_WAIT = 3.0
local RESTAGE_MIN_DELTA = 0.2

-- Stock dashboard/tacho rebind (bug default-dashboard-ui-missing-at-race-start): seconds to let a
-- (re)seated car's VE streams settle after its jbeam is bindable before firing the one-shot rebind, so it
-- acts once the car is actually bindable rather than mid-churn. A longer wait is used after a HUD-watchdog
-- reloadUI (the whole UI must remount first), mirroring the deferred-restage readiness gate.
local DASH_REFRESH_SETTLE = 0.75
local DASH_REFRESH_AFTER_RELOAD = 2.0

-- Distinctive build marker logged at load so a redeploy can be proven live in beamng.log before trusting
-- an in-game result -- the BeamMP client mod is served from a cache that can go stale (memory
-- beammp-client-mod-cache-stale). Bump when shipping a client-visible fix that needs an in-game re-test.
local BUILD_MARKER = "setup-panel-reload-safe/2026-07-26"

-- AI count past which the owner gets a one-shot performance hint (ADR-0036 Etappe B): all AI physics run
-- on the host, so a larger field is heavier on the owner's machine.
local AI_PERF_HINT_THRESHOLD = 6

-- Seconds after a grinder spawn that the host keeps re-issuing the powered-prop activation (ADR-0020
-- amendment). The `spinner` main-controller only exists once the freshly spawned grinder VE's powertrain
-- init has run, so activation is re-issued each frame until it lands, then stopped -- the controller owns
-- the throttle from then on. Wall-clock (os.clockhp) anchored: dtReal is clamped on the spawn-load spike.
local GRINDER_ACTIVATE_WINDOW = 2.0

-- Reload-surviving state (BeamNG serializes M.state across a Lua reload).
M.state = {
    last_event_at = 0,
    registered = false,
    race = nil,          -- current race-start state (slot, poses, roster) or nil
    phase = nil,         -- current server-authoritative race phase (ADR-0006) or nil
    marker_warned = false,
    prop_names = nil,    -- names of the prop prefabs we spawned, for cleanup (or nil)
    cone_ids = nil,      -- ids of the shared cone vehicles we spawned + must clear (host only, ADR-0020)
    grinder_ids = nil,   -- ids of the shared powered prop-vehicles (grinders) we spawned + must clear on teardown (host only, ADR-0020 amendment)
    grinder_activate_until = nil,  -- os.clockhp deadline for re-issuing grinder activation over the spawn readiness window; nil when idle/non-host or the window has closed (ADR-0020 amendment)
    pending_nametag = nil,  -- map of cone game-id -> seconds waited for MPVehicleGE nametag suppression to stick; lazily created, nil when idle (ADR-0020)
    current_vehicle_id = nil,  -- game id of the vehicle the player is in, tracked via onVehicleSwitched
    race_car_id = nil,   -- game id of this client's race car; bounce target for the in-race switch lock
    detection = nil,     -- checkpoint-detection progress (race/checkpoints), armed on the racing phase
    laptimer = nil,      -- circuit lap-clock state (race/laptimer), armed on racing; display only (ADR-0022)
    marker_angles = nil, -- per-checkpoint (keyed by stable index) last-drawn gate-post angle, for the render-only orientation slew-limit (smooth_marker_angle); lazily created, reset per race
    results_min = false,     -- local-only: finished results card minimized to a small restore bar; toggled by /results + the on-card Minimize/restore buttons (ADR-0012/0041 minimize pattern)
    race_records = nil,      -- pre-run PB + track record for the post-race analysis overlay (server raceRecords, ADR-0028), or nil
    analysis_open = false,   -- local-only toggle: show the post-race analysis overlay via /analysis or the card button (ADR-0028)
    provisional_open = true,  -- local-only per-player: auto-show the provisional results card once the local player is finished/DNF while the race still runs; toggled by the HUD buttons / racing-phase /results, reset per race
    interval_mode = "self",  -- local-only live-standings interval reference: "self" | "ahead" | "leader"; cycled by the HUD toggle, session-persistent (not reset per race)
    standings = nil,     -- latest server-broadcast ranked standings entries, or nil
    car_info = nil,      -- one-shot per-driver car descriptors, cached from the carInfo channel keyed by the standings row (slot, else name); the standings entries no longer carry `car` (ADR-0029 amendment, bug partconfig-blob-bloats-standings), or nil
    grace = nil,         -- finish-grace countdown {remaining = seconds}, ticked locally (ADR-0014), or nil
    staging = nil,       -- staging-wait {remaining = seconds}, ticked locally for the indicator (ADR-0021), or nil
    countdown = nil,     -- start-countdown {remaining = seconds}, ticked locally to drive the 8s count (ADR-0021), or nil
    assist_armed = false,  -- whether the VE forwarders have been armed for this race (ADR-0017)
    assist_held = nil,     -- kind ("recover"/"repair") of the assist key currently held, or nil (ADR-0017)
    assist_arming = nil,   -- active recover/repair countdown {kind, remaining}, or nil (ADR-0017)
    assist_notice = nil,   -- which abort reason was last toasted this hold ("moving"), latches one-shot
    freeze_hold_armed = false,  -- whether the VE EV-throttle clamp has been armed for the frozen phases (ADR-0017 amendment)
    restage_pending = false,  -- a staging car (swap or fresh-spawn default) awaits re-placement at the grid slot once its bbox is ready
    restage_baseline = nil,   -- spawn-bbox forward half-length recorded on the first pending frame, to detect the new jbeam loading
    restage_wait = 0,         -- seconds left to wait for the staging car's jbeam before placing anyway
    restage_plate = nil,      -- player's plate to re-apply to a forced/fresh-spawned car on the restage (jbeam regenerates it), or nil
    dash_refresh_pending = false,  -- a stock dashboard/tacho rebind is queued; step_dashboard_refresh fires it once the (re)seated car's VE is ready (bug default-dashboard-ui-missing-at-race-start)
    dash_refresh_wait = 0,         -- seconds left in the readiness-settle window before the queued stock-dashboard rebind fires
    race_caps = nil,          -- Mode-3 caps {maxhp, maxpwr, maxkg, minkg} for the active race, gating the staging swap-compliance check (ADR-0032); nil in Modes 1/2 (no cap)
    staged_spec = nil,        -- spec {model, config, paint...} of the last COMPLIANT staged car, to revert an over-cap staging swap back to (ADR-0032), or nil
    revert_pending = false,   -- one-shot: set when an over-cap revert is issued, so the NEXT consumed replace (our own revert) is marked as the trusted revert cycle; any other replace is a new player swap (ADR-0032)
    staging_swap_reverting = false,  -- true only for the restage cycle that our revert started, so its known-compliant car is adopted without re-gating; recomputed from revert_pending at each consume (prevents a revert loop, ADR-0032)
    reported_name = nil,      -- the license name last sent to the server (ADR-0031 amendment); the staging poll re-reports only when the plate changes from this
    ai_cars = nil,            -- host only: spawned AI cars {id, slot, label, veh_id} to freeze/drive/score/clear (ADR-0036), or nil
    ai_config = nil,          -- host only: relayed AI difficulty/vehicle config {preset, car, params} (ADR-0036 Etappe B), or nil
    ai_policy = nil,          -- host only: the vehicle policy used for the AI car chain (ADR-0032), kept so a quali re-grid can re-spawn fresh AI (ADR-0041), or nil
    ai_custom_map = nil,      -- host only: true while the script-variant custom race navgraph is live (ADR-0036 Step-3b); teardown restores the real one

    ai_detections = nil,      -- host only: per-AI checkpoint-detection state keyed by AI id, armed on racing (ADR-0036), or nil
    ai_laptimers = nil,       -- host only: per-AI circuit lap clock keyed by AI id, armed alongside ai_detections; feeds the proxy best-lap + run-up report (ADR-0036/0022/0041), or nil
    ai_map_pending = false,   -- host only: the aiMap (AI server ids) still has unresolved cars to broadcast (ADR-0036)
    ai_remote_ids = nil,      -- non-owner: set of local game ids resolved as AI cars from the relayed aiMap (ADR-0036), or nil
    ai_server_ids = nil,      -- non-owner: set of BeamMP server ids from the latest aiMap awaiting local resolution (ADR-0036), or nil
    hud_ack_gap = 0,          -- seconds since the HUD app last acked it is alive; the onUpdate watchdog re-shows / reloads the UI as this grows while a race wants the HUD up (ui-missing-for-some-clients-reload)
    hud_reshow_wait = 0,      -- seconds since the watchdog's last re-show, to throttle ensureAppVisible
    hud_reloaded = false,     -- whether the watchdog already escalated to a full UI reload this race (one reload per race; reset on teardown)
    idle_info_shown = false,  -- whether the between-races series info box (ADR-0042) currently holds the HUD app up (lobby/free-roam, no race), so it is shown once and taken down when the series ends
    grid_list_target = nil,   -- routes the next gridList reply by its requester: nil = grid-editor console toast (default) | "setup" = race-setup panel grid dropdown (ADR-0037) | "gridui" = grid-editor panel saved-grid dropdown
    grid_seed_race = nil,     -- a race to pre-select when the grid-editor panel opens (carried from /raceui's "Grid bearbeiten" cross-open); consumed by push_grid_data
    grid_active_name = nil,   -- the saved name of the grid currently being edited (set on save/load, nil for a fresh unsaved grid); reflected to the panel so a reopen restores the overwrite/assign target
    grid_load_anchor = nil,   -- the race to re-anchor a saved grid onto when loading it (the panel's selected race); grid params are relative to a start line, so a grid can be edited against any race
    grid_edit_prop_names = nil,  -- names of the static-scenery prefabs spawned as a positioning reference during a grid edit (lobby only; cleared with the session). Distinct lifecycle from the race's prop_names
    grid_edit_checkpoint = nil,  -- the active direction's first checkpoint {pos, normal, radius}, drawn immediate-mode during a grid edit so the grid can be placed relative to it
    setup_form = nil,         -- the race-setup panel's last form (JSON string), remembered across panel close/reopen within a session so the settings of the last race persist (ADR-0037). The panel autosaves it on every change, so it also survives a UI reload that never runs the panel's Close (bug setup-panel-settings-survive-ui-reload)
    setup_open = false,       -- the race-setup panel is meant to be on screen: set by the admin-gated setupOpen (handle_setup_open), cleared by close_setup / on leaving the level. The ONLY thing the presence watchdog acts on, so it can reproduce an authorized open but never invent one (ADR-0016/0037). Does NOT survive a Lua reload: this extension has no onSerialize/onDeserialize, so a reload rebuilds M.state from this literal -- the panel stays on screen but is no longer watched until the next /raceui
    setup_seen = false,       -- the panel app has acked at least once since that open, so silence is a real loss and not a slow mount -- keeps the one-shot restore from being spent on a false positive
    setup_ack_gap = 0,        -- seconds since the panel app last acked it is alive; setup.ACK_STALE is the loss threshold
    setup_restored = false,   -- one-shot latch: the lost panel has been re-added once for this open, then the watchdog goes quiet (so BeamNG's own app-container X stays usable)
    championship = nil,       -- latest server-broadcast championship snapshot {active, preset, order, raceCount, rows} (ADR-0040), or nil; rendered on the HUD finished card + the setup panel
    tournament = nil,         -- latest server-broadcast class-drop tournament snapshot {active, ended, winner, classes, rows} (ADR-0042), or nil; rendered on the HUD finished card + the setup panel
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
    -- The qualifying HOLD (bug quali-hold-reset-and-repaint-leak, ADR-0017 amendment). hold.is_held() is
    -- the single truth; these two carry the state it cannot derive from the fields above.
    quali_lap_done = false,    -- circuit quali: the local driver's lap closed inside the finish-your-lap grace, so their session is over and the car is held (ADR-0041 amendment)
    quali_hold_locked = false, -- the held-ness last pushed to lock.set_recover_blocked, so the sync only calls the engine on a real edge. Kept in M.state (not a file local): it survives a Lua reload in lockstep with the engine's own serialized filter state
}

-- Queue a one-shot stock dashboard/tacho rebind (bug default-dashboard-ui-missing-at-race-start): armed
-- at every point the race car is (re)seated (race start + AI reseat, regrid, the racing GO boundary, and
-- after a HUD-watchdog reloadUI), it lets step_dashboard_refresh wait for the car's VE to be bindable and
-- then rebind the stock apps once. A plain state setter so it stays callable from the handlers above the
-- onUpdate step that consumes it; the optional wait overrides the default settle (longer after a reload).
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

-- Reports this client's BeamNG license name as the canonical identity (ADR-0031); defined far below but
-- called from handle_race_start (at spawn) above its definition, so forward-declared here.
local report_identity

-- Re-reads the own car's plate during staging and re-reports it on a change (ADR-0031 amendment); defined
-- far below but called from handle_race_phase's countdown branch above its definition, so forward-declared.
local poll_staging_identity

-- Disarms the seated car's VE recovery override; defined far below (next to the assist push) but used
-- earlier in handle_race_phase's lobby teardown, so forward-declared here (ADR-0017).
local disarm_assist_ve

-- Disarms the seated car's VE EV-throttle clamp; defined far below (next to the freeze-hold push) but
-- used earlier in handle_race_phase / handle_race_start, so forward-declared here (ADR-0017 amendment).
local disarm_freeze_hold_ve

local function handle_ping(_payload)
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Server event: ping",
    })
end

-- Resolve + lay out the race for this client, store the state, and surface the slot. On any
-- failure (the server cannot validate the name, ADR-0005) warn and toast the reason.
local function handle_race_start(payload)
    -- A starting race ends any in-progress grid edit so its preview pillars never bleed into the race
    -- (the ADR-0023 editor is a lobby-only authoring tool); clear its reference props and drop the panel.
    if grideditor.state.active then
        grideditor.clear()
        M.state.grid_active_name = nil
        props.clear(M.state.grid_edit_prop_names or {})
        M.state.grid_edit_prop_names = nil
        M.state.grid_edit_checkpoint = nil
        if guihooks then
            guihooks.trigger("appContainer:removeApp", "beamCompGridEditor")
        end
    end

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
        M.state.ai_laptimers = nil
        M.state.ai_map_pending = false
        M.state.ai_remote_ids = nil
        M.state.ai_server_ids = nil
        lock.remove()
        disarm_assist_ve()
        disarm_freeze_hold_ve()
        countdown.clear()
        hud.clear()
        return
    end

    M.state.race = race

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
    -- Reset the HUD watchdog so the (re)started race gets a clean grace window and one reload budget.
    M.state.hud_ack_gap = 0
    M.state.hud_reshow_wait = 0
    M.state.hud_reloaded = false
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
    -- reason cones are cleared here (ADR-0020 amendment). Host-only state; nil on a non-owner.
    grinders.clear(M.state.grinder_ids or {})
    M.state.prop_names, M.state.cone_ids, M.state.grinder_ids = props.load(race.prefabFiles or {},
        payload.propOwner, race.coneFiles or {})
    -- Arm the powered props' (grinders') activation window: their `spinner` controller only comes up after
    -- the freshly spawned VE's powertrain init, so onUpdate re-issues the activation each frame until the
    -- deadline, then stops (ADR-0020 amendment). Anchored on os.clockhp (dtReal is clamped on the load
    -- spike). nil = idle / non-host / no grinders (re-armed on every /race; nil'd again on teardown).
    M.state.grinder_activate_until = (M.state.grinder_ids and #M.state.grinder_ids > 0)
        and (os.clockhp() + GRINDER_ACTIVATE_WINDOW) or nil

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
    M.state.ai_laptimers = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil

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
    }
    -- Remember the Mode-3 caps for the staging swap-compliance gate (ADR-0032): a car swap during staging
    -- must not stage a car over the cap. Mode 3 only -- a fixed car (Mode 2, car=) or no policy (Mode 1)
    -- leaves this nil and the gate is skipped. Seeded fresh here; staged_spec (the compliant car to revert
    -- an over-cap swap back to) is captured at staging entry, once the placed car's jbeam is loaded.
    M.state.race_caps = (not policy.car and (policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg))
        and {maxhp = policy.maxhp, maxpwr = policy.maxpwr, maxkg = policy.maxkg, minkg = policy.minkg} or nil
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
    local race_car, respawn_err, degraded = vehicles.respawn_own_at(race.myPose, own_car, policy)
    if degraded then
        -- No-suitable-car fallback (ADR-0032 §5 superseded): the resolver spawned the fixed default car
        -- because no cap-compliant / random-pool car was available (a Mode-3 cap with no compliant car, or
        -- car=random with an empty cap-composed pool). Warn the player, then STILL race -- the cap is
        -- best-effort now, never a non-participation outcome. The ordinary Mode-1 on-foot fresh-spawn does
        -- NOT set this flag, so a plain foot-start stays silent (it is not a no-suitable-car case).
        log("W", RACE_LOG_TAG, "no suitable car -- spawned default; warning and racing")
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp -- " .. race.name,
            msg = "No suitable car available -- spawning default car",
        })
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
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp -- " .. race.name,
        msg = string.format("Slot %d -- start (%.0f, %.0f, %.0f)",
            race.mySlot, race.myPose.pos.x, race.myPose.pos.y, race.myPose.pos.z),
    })

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
    -- separate clientIdentity message (below), since it is connection-scoped, not per-race (ADR-0031).
    local client_info = vehicles.collect_client_info(race_car)
    send_to_server("clientInfo", {
        race = payload.race,
        vehicle = client_info.vehicle,
        -- Power-to-weight for the start-order pwr mode (ADR-0033); nil when unreadable. The server stores
        -- it per player and only sorts by it -- it never reads the vehicle (race-blind, ADR-0005).
        pwr = client_info.pwr,
    })

    -- Refresh the canonical identity from the race car now that it exists (ADR-0031): the license name
    -- needs a vehicle, and this is the reliable point where one is guaranteed -- the connect-time report
    -- is only best-effort. The server resolves identities live, so a name arriving here updates the
    -- standings/records for this race.
    report_identity(race_car)

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
                    -- nil pwr just leaves the AI in its provisional back-of-grid slot.
                    send_to_server("clientInfo", {
                        race = payload.race,
                        aiId = car.id,
                        pwr = vehicles.collect_client_info(veh).pwr,
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
                guihooks.trigger("toastrMsg", {
                    type = "warning",
                    title = "BeamComp -- AI",
                    msg = string.format("%d AI cars run on your machine -- expect higher load.", #cars),
                })
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
    -- (ADR-0020 amendment). Idempotent + host-only (nil on a non-owner). Shared by lobby end,
    -- onClientEndMission (session leave / level change) and onExtensionUnloaded (reload).
    grinders.clear(M.state.grinder_ids or {})
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
    M.state.ai_laptimers = nil
    M.state.ai_map_pending = false
    M.state.ai_remote_ids = nil
    M.state.ai_server_ids = nil
    M.state.prop_names = nil
    M.state.cone_ids = nil
    M.state.grinder_ids = nil
    M.state.grinder_activate_until = nil
    M.state.race = nil
    M.state.race_car_id = nil
    M.state.detection = nil
    M.state.laptimer = nil
    -- Drop any queued stock-dashboard rebind so it never fires in free-roam after teardown
    -- (bug default-dashboard-ui-missing-at-race-start).
    M.state.dash_refresh_pending = false
    -- Drop the marker orientation slew state so the next race's posts never ease from a stale angle.
    M.state.marker_angles = nil
    M.state.standings = nil
    M.state.car_info = nil
    M.state.race_records = nil
    M.state.analysis_open = false
    M.state.provisional_open = true
    M.state.grace = nil
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
    -- Reset the HUD watchdog so the (re)started race gets a clean grace window and one reload budget.
    M.state.hud_ack_gap = 0
    M.state.hud_reshow_wait = 0
    M.state.hud_reloaded = false
    M.state.assist_armed = false
    M.state.assist_held = nil
    M.state.assist_arming = nil
    M.state.assist_notice = nil
    M.state.freeze_hold_armed = false
    M.state.restage_pending = false
    M.state.restage_plate = nil
    M.state.race_caps = nil
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
-- The caller has already confirmed we are in this race.
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
        local ai_route = ai.drive(M.state.ai_cars,
            M.state.race.routePoints or M.state.race.checkpoints, ai_laps or M.state.race.laps, ai_params,
            M.state.race.mode == "circuit")
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
    -- Auto-show the HUD app for the phase (ADR-0012); removed again on lobby. ensureAppVisible dedups.
    hud.show()
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

-- Push the current held-ness to the recover-key block. Called from every transition that can change it
-- (the phase handler, each staged queue transition, the circuit run's close) and once per qualifying frame
-- as a net, so no path can leave the block out of step with hold.is_held().
--
-- The engine call only fires on a real edge: comparing against the last pushed value keeps the per-frame
-- net down to a boolean compare, and the engine's filter update is not free (it rebuilds the filter and
-- broadcasts an extension hook). The record lives in M.state, which survives a Lua reload in lockstep with
-- the engine's own serialized filter state -- a file-local flag would reset and could strand the block.
function hold.sync()
    local held = hold.is_held()
    if held == M.state.quali_hold_locked then
        return
    end
    M.state.quali_hold_locked = held
    lock.set_recover_blocked(held)
end
-- ===== end the qualifying hold ===========================================================

-- Record the server-authoritative race phase, drive the start lock off it, and surface it. The
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
        lock.install({allow_replace = true})
        hud.show()
        M.state.staging = {remaining = tonumber(payload.duration) or 0, last_shown = nil}
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
        -- Lock in a license name the player changed in the final staging moment (ADR-0031 amendment): the
        -- per-frame poll is throttled, so force one last re-read at the GO boundary -- "last value at GO
        -- wins". After this, no re-read runs (the poll is staging-gated), so an in-race change has no effect.
        poll_staging_identity(true)
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
        -- times; the grid is set afterwards from quali pace. The AI drive too (so the session is populated),
        -- but only for the real race lap count -- ai.drive bakes every lap into the waypoint list (noOfLaps
        -- does not loop, ADR-0036), so the unbounded quali lap count would build a runaway path; they run the
        -- race distance, set a time, then idle; the grid is then set from quali pace. Seed the quali clock from the phase
        -- duration so the HUD shows time remaining; at 0 the finish-your-lap grace runs server-side.
        local quali_state = M.state.race and M.state.race.quali
        M.state.qualifying = {remaining = tonumber(payload.duration) or 0}
        -- Fresh session: nobody has finished their graced lap yet (ADR-0041 amendment).
        M.state.quali_lap_done = false
        if quali_state and quali_state.staged then
            -- Rally staged sprint quali (ADR-0044/Round3): nobody drives at the gun and there is NO global
            -- pre-quali countdown -- the server sent us straight from staging into qualifying. Upgrade to the
            -- full fixed-car lock (normally done at the countdown phase we skipped) and lock in the license
            -- name now; keep the car frozen at its slot. The server places the field: it stages the front
            -- driver at P1 (qualiStage) and holds the rest on slots 2..N (qualiHold). No detector, lap clock,
            -- or sector tracker until this driver launches; clear the overlay for the per-driver counts.
            lock.install()
            poll_staging_identity(true)
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
            M.state.results_min = false
            M.state.analysis_open = false
            countdown.clear()
            -- Keep the HUD app up for the queue view (circuit gets this via begin_driving, which we skip).
            hud.show()
        else
            -- Circuit all-at-once quali (ADR-0041): release everyone and lap the unbounded plan (unchanged).
            M.state.quali_staged = false
            begin_driving(quali_state and quali_state.plan, M.state.race and M.state.race.laps)
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
        M.state.quali_lap_done = false
        -- Stop qualifying sector tracking; the race scores the real plan (feature: quali-live-sector-delta).
        M.state.sector_track = nil
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

    -- Surface the phase as a toast, except staging/countdown/racing/qualifying -- the centered overlay
    -- covers those (the staging indicator, the count, GO!, and the quali drive).
    if phase ~= "staging" and phase ~= "countdown" and phase ~= "racing" and phase ~= "qualifying" then
        guihooks.trigger("toastrMsg", {
            type = "info",
            title = "BeamComp",
            msg = "Race phase: " .. phase,
        })
    end
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
    for _, entry in ipairs(ai_slots) do
        local car = car_by_id[entry.id]
        local pose = (type(entry.slot) == "number") and poses[entry.slot + 1] or nil
        if car and pose then
            car.slot = entry.slot
            car.pose = pose
            local veh = be and be:getObjectByID(car.veh_id)
            if veh then
                vehicles.place_at_grid(veh, pose)
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
    for _, car in ipairs(cars) do
        local veh = be and be:getObjectByID(car.veh_id)
        if veh then
            ai.suppress(veh)
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
    -- Re-place / re-spawn the host's AI cars (owner-only; no-op otherwise) before the own-car logic, so a
    -- missing own slot/pose below never skips it.
    if payload.qualiRespawnAi then
        quali.respawn_ai_for_regrid(payload.aiSlots)
    else
        replace_ai_for_regrid(payload.aiSlots)
    end
    local slot = payload.slot
    local poses = M.state.race.gridPoses
    local pose = (type(slot) == "number" and poses) and poses[slot + 1] or nil
    if not pose then
        log("W", RACE_LOG_TAG, "regrid ignored: no pose for slot " .. tostring(slot))
        return
    end
    M.state.race.mySlot = slot
    M.state.race.myPose = pose
    if type(payload.grid) == "table" then
        M.state.race.roster = payload.grid
    end

    local race_car = (M.state.race_car_id and be) and be:getObjectByID(M.state.race_car_id) or nil
    if not race_car then
        log("W", RACE_LOG_TAG, "regrid: no race car to re-place")
        return
    end
    local placed, place_err = vehicles.respawn_own_at(pose, race_car)
    if not placed then
        log("W", RACE_LOG_TAG, "regrid re-place failed: " .. tostring(place_err))
        return
    end
    vehicles.set_vehicle_frozen(race_car, true)
    -- The regrid re-seated/re-placed the race car: re-queue the stock-dashboard rebind so the tacho
    -- survives this reseat too (bug default-dashboard-ui-missing-at-race-start).
    arm_dashboard_refresh()
    log("I", RACE_LOG_TAG, string.format("re-gridded to slot %d", slot))
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
    M.state.quali_ai_runs = M.state.quali_ai_runs or {}
    M.state.quali_ai_runs[car.id] = qualisprint.new_run(os.clockhp(), count)
    log("I", RACE_LOG_TAG, string.format("staged quali: AI '%s' staged at the ramp", tostring(car.label)))
end

-- Owner: release + drive one AI at the end of its per-driver count (ADR-0044/0036). Arms its proxy detector
-- so step_ai_detections scores + reports it, and re-arms the ramp-clear report for this AI. Single-car
-- ai.drive; the default snap route does not swap the navgraph, so repeated staged launches do not thrash it.
function quali.launch_ai(car_id)
    if M.state.quali_ai_runs then
        M.state.quali_ai_runs[car_id] = nil
    end
    local car = quali.find_ai(car_id)
    if not car or not M.state.race then
        return
    end
    ai.set_frozen({car}, false)
    local params = ai.resolve_params(M.state.ai_config, M.state.race.aiDefaults)
    ai.drive({car}, M.state.race.routePoints or M.state.race.checkpoints,
        M.state.race.laps, params, false)
    M.state.ai_detections = M.state.ai_detections or {}
    if M.state.race.plan then
        M.state.ai_detections[car.id] = checkpoints.new(M.state.race.plan)
    end
    M.state.quali_ai_cleared = M.state.quali_ai_cleared or {}
    M.state.quali_ai_cleared[car.id] = false  -- report once this AI clears the ramp
end

-- Owner: stop an AI + hold it (ADR-0044/Round4). stop=true -> freeze in place (a done AI at the window's
-- end); else -> re-place it at its OWN fixed holding slot (car.pose, its spawned grid position) and freeze.
function quali.hold_ai(ai_id, stop)
    local car = quali.find_ai(ai_id)
    if not car then
        return
    end
    pcall(function() ai.stop({car}) end)
    if M.state.ai_detections then
        M.state.ai_detections[car.id] = nil
    end
    if M.state.quali_ai_runs then
        M.state.quali_ai_runs[car.id] = nil
    end
    if M.state.quali_ai_cleared then
        M.state.quali_ai_cleared[car.id] = nil
    end
    local veh = be and be:getObjectByID(car.veh_id)
    if not veh then
        return
    end
    if not stop and car.pose then
        pcall(function() vehicles.place_at_grid(veh, car.pose) end)
    end
    pcall(function() vehicles.set_vehicle_frozen(veh, true) end)
end

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
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Recover -- new attempt, back of the queue",
    })
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

-- Answer the server's pre-flight validateRace request (ADR-0019): the race-blind server relays the
-- /race options here, we vet them against the locally-parsed race (race/start.validate) and report the
-- verdict back. The server starts on ok, or posts our reason to the issuing admin on a refusal. The
-- nonce is echoed so the server can match the reply to its in-flight check.
local function handle_validate_race(payload)
    local result = race_start.validate(payload)
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
    })
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

-- Push one model's configs to the open race-setup panel (UI -> GE, ADR-0037). The panel calls this when
-- the car model changes; configs are probed lazily per model since an all-models probe is heavy. Public
-- so the app can reach it as beamcomp_init.request_car_configs.
function M.request_car_configs(model)
    if type(model) ~= "string" then
        return
    end
    guihooks.trigger("BeamCompSetupCars", {model = model, configs = carlist.options(model).configs})
end

-- ===== race-setup panel presence (bug setup-panel-settings-survive-ui-reload) =====================
-- The panel is put on screen by the admin-gated /raceui relay and taken down by its own Close button --
-- but an engine/BeamMP UI reload destroys it (and its Angular scope) without ever running that close,
-- and our server-delivered app does not come back on its own (ADR-0008/0012). GE therefore remembers
-- that the panel SHOULD be on screen and re-adds it once when the app's heartbeat goes silent. Same
-- mechanism as the HUD watchdog (M.note_hud_alive / step_hud_watchdog), reduced to its Stage A and
-- latched to a single shot per open: the user wants a lost panel back, not a panel that fights BeamNG's
-- own app-container X.

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
end

-- Watchdog step, called from onUpdate while the panel is meant to be open -- phase-independently, since
-- the panel is used in the lobby and carries the race-stop controls mid-race (ADR-0038 amendment).
-- Silence only counts once we have heard the app alive: a panel that has not linked yet is merely slow
-- (this bug lives on laggy clients), and spending the single restore on that would leave a real loss
-- unrecovered. No Stage B -- unlike the HUD, this surface is not worth a full reloadUI.
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
    -- Guarded + pcall-wrapped like race/hud.lua's trigger_ui: this runs from the onUpdate tick, so a
    -- missing/failed engine call must never take the rest of the frame's work down with it. The latch is
    -- already set above, so a failure costs the one restore rather than repeating every frame.
    if not guihooks then
        return
    end
    local ok, err = pcall(function()
        guihooks.trigger("appContainer:ensureAppVisible", jsonEncode({appName = "beamCompSetup"}))
    end)
    if not ok then
        log("W", RACE_LOG_TAG, "re-adding the race-setup panel failed: " .. tostring(err))
    end
end

-- UI -> GE presence heartbeat from the open panel (mirrors note_hud_alive). Public so the app can reach
-- it as beamcomp_init.note_setup_alive.
function M.note_setup_alive()
    M.state.setup_ack_gap = 0
    M.state.setup_seen = true
end

-- Remove the race-setup panel from the live layout (UI -> GE, ADR-0037), the close counterpart to the
-- setupOpen auto-add. Public so the panel's Close button can reach it as beamcomp_init.close_setup.
function M.close_setup()
    guihooks.trigger("appContainer:removeApp", "beamCompSetup")
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
        } or nil,
    })
end

-- Sync the grid editor's reference scene to the active session (ADR-0037 amendment, tweak): the track's
-- static props + first checkpoint, so the admin places the grid against the real start area. Always drops
-- the previous editor props first. Props are spawned only in the lobby -- during a race the real race props
-- are already in the scene (and share these object names), so we never double-spawn over them; the
-- checkpoint is drawn immediate-mode regardless. Reload-safe: only the prop names are persistent (tracked
-- in M.state), the checkpoint is plain data.
local function refresh_grid_edit_scene()
    props.clear(M.state.grid_edit_prop_names or {})
    M.state.grid_edit_prop_names = nil
    M.state.grid_edit_checkpoint = nil
    if not grideditor.state.active then
        return
    end
    local scene = grideditor.current_scene()
    if not scene then
        return
    end
    M.state.grid_edit_checkpoint = scene.checkpoint
    if M.state.race == nil then
        M.state.grid_edit_prop_names = props.load(scene.prefabFiles or {}, false)
    end
end

-- Open a saved grid the server returned for a beamcomp_grid_edit/gridui fetch (ADR-0023). `found` false
-- means no such grid for this map; otherwise hand the record to the editor -- re-anchored onto the panel's
-- selected race (grid_load_anchor) so a grid authored for another race previews against the current one --
-- then refresh the reference scene and reflect the loaded block to the panel so its knobs fill in.
local function handle_grid_data(payload)
    if type(payload) ~= "table" or not payload.found then
        local name = type(payload) == "table" and payload.name or "?"
        editor_feedback("no saved grid '" .. tostring(name) .. "' on this map", "warning")
        return
    end
    local anchor_race = M.state.grid_load_anchor
    M.state.grid_load_anchor = nil
    local ok, result = grideditor.open({
        forward = payload.forward,
        reverse = payload.reverse,
        race = payload.race,
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

-- Post the current map's saved grid names from a gridListReq (ADR-0023). gridListReq has three callers, so
-- the one-shot grid_list_target (set by the requester) routes this reply: "setup" -> the race-setup panel's
-- grid dropdown (ADR-0037); "gridui" -> the grid-editor panel's saved-grid dropdown (ADR-0037 amendment);
-- nil -> the grid-editor console command's toast (beamcomp_grid_list).
local function handle_grid_list(payload)
    local names = type(payload) == "table" and type(payload.names) == "table" and payload.names or {}
    local target = M.state.grid_list_target
    M.state.grid_list_target = nil
    if target == "setup" then
        guihooks.trigger("BeamCompSetupGrids", {names = names})
        return
    end
    if target == "gridui" then
        guihooks.trigger("BeamCompGridList", {names = names})
        return
    end
    if #names == 0 then
        editor_feedback("no saved grids on this map")
        return
    end
    editor_feedback("saved grids: " .. table.concat(names, ", "))
end

-- Push the current map's saved preset names to the race-setup panel (ADR-0037 amendment). The panel is
-- the sole consumer (unlike gridList's three), so no routing target is needed -- always to the panel.
local function handle_preset_list(payload)
    local names = type(payload) == "table" and type(payload.names) == "table" and payload.names or {}
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
    })
    -- The driver NAME list for the panel's roster name picker (ADR-0048): sourced from the mod-bundled
    -- driver file (the single pool source), so it is complete on the first push with no server round-trip.
    -- The panel picks names from this instead of free typing.
    guihooks.trigger("BeamCompAiPool", {names = ai.pool_names()})
    M.state.grid_list_target = "setup"
    send_to_server("gridListReq", {map = map})
    -- Fetch the map's saved presets too (ADR-0037 amendment), routed back to the panel by handle_preset_list.
    send_to_server("presetListReq", {map = map})
end

-- Open the race-setup panel on the relayed setupOpen (ADR-0037): push the current dataset (refreshes an
-- already-open panel) and make the app visible. A freshly-added app links *after* this push, so the panel
-- also pulls the dataset itself on link via request_setup_data -- the two together cover every timing.
local function handle_setup_open(_payload)
    push_setup_data(false)
    -- Ensure the panel app is on the live layout (ADR-0012 best-effort auto-add); dedups by appName.
    guihooks.trigger("appContainer:ensureAppVisible", jsonEncode({appName = "beamCompSetup"}))
    -- Remember this (server-authorized) open, so a UI reload that drops the app can be recovered once.
    setup.arm()
    -- Auto-minimize the final standings card so the opening panel has a clear view. Only visible in the
    -- finished phase (the snapshot gates it), so this is inert otherwise; manual restore via
    -- M.toggle_results_min and the per-race reset (driving-phase start) stay the counter-force.
    M.state.results_min = true
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
    send_to_server("presetListReq", {map = map})
end

-- Roll a full or additional named-AI roster for the setup panel (UI -> GE, ADR-0047/0048). Payload JSON:
-- {count, mode = "create"|"extend", exclude = [names], ai = {car?, randomTrim, noBigCars},
-- policy = {car?, maxhp?, maxpwr?, maxkg?, minkg?, randomTrim?, noBigCars?}}. Names draw from the
-- mod-bundled driver file (the single pool source, ADR-0048) without replacement; each entry's car
-- resolves through the SAME chain the spawn uses (race/ai.lua), so the shown car IS the spawned car.
-- Result pushed via BeamCompAiRoster. Public as beamcomp_init.roll_ai_roster.
function M.roll_ai_roster(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" then
        log("W", RACE_LOG_TAG, "roll_ai_roster: bad payload")
        return
    end
    local count = math.max(1, math.min(16, math.floor(tonumber(request.count) or 1)))
    -- excludeColors keeps an extend distinct from the kept entries' colours (ADR-0047 round 3); nil on a
    -- fresh create (nothing to exclude).
    local entries = ai.roll_roster_entries(count, request.exclude, request.ai, request.policy,
        request.excludeColors)
    guihooks.trigger("BeamCompAiRoster", {
        mode = request.mode == "extend" and "extend" or "create",
        entries = entries,
    })
end

-- Re-draw one roster entry's name (UI -> GE, ADR-0047): payload {index, exclude, ai, policy}. When the
-- drawn name carries a preferred car that applies (aiCar rolled, restrictions pass), the car rides the
-- reply too -- decision 4's "they always get it". Result pushed via BeamCompAiRosterName. Public as
-- beamcomp_init.reroll_ai_name.
function M.reroll_ai_name(json)
    local ok, request = pcall(jsonDecode, json)
    if not ok or type(request) ~= "table" or tonumber(request.index) == nil then
        log("W", RACE_LOG_TAG, "reroll_ai_name: bad payload")
        return
    end
    local drawn = ai.draw_roster_names(1, request.exclude)[1]
    local reply = {index = tonumber(request.index), name = drawn.name}
    if drawn.preferred and ai.preferred_applies(request.ai)
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
    M.state.grid_list_target = "gridui"
    send_to_server("gridListReq", {map = map})
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
    guihooks.trigger("appContainer:ensureAppVisible", jsonEncode({appName = "beamCompGridEditor"}))
end

-- Pull the grid-editor dataset on demand (UI -> GE): the panel calls this on link (covers the freshly-added
-- app that missed the open push) and from its Refresh button. Public as beamcomp_init.request_grid_data.
function M.request_grid_data()
    push_grid_data()
end

-- Open the grid-editor panel pre-seeded with `race` (UI -> GE): the race-setup panel's "Grid bearbeiten"
-- button calls this so the grid editor starts on the race chosen there. Does not start an edit session --
-- the admin still picks New / Load. The seed persists across the panel's on-link pull; the panel applies it
-- only while its race choice is still empty, so a later Refresh never overrides a manual pick. Public as
-- beamcomp_init.open_grid_editor_with_race.
function M.open_grid_editor_with_race(race)
    M.state.grid_seed_race = (type(race) == "string" and race ~= "") and race or nil
    push_grid_data()
    refresh_grid_edit_scene()
    guihooks.trigger("appContainer:ensureAppVisible", jsonEncode({appName = "beamCompGridEditor"}))
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
-- `anchor_race` (the panel's selected race) re-targets the grid's relative params onto that race's start
-- line; remembered until the reply arrives.
function M.grid_open_saved(name, anchor_race)
    if type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    M.state.grid_load_anchor = (type(anchor_race) == "string" and anchor_race ~= "") and anchor_race or nil
    send_to_server("gridFetch", {map = map, name = name})
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

-- Bind a saved grid as the default for `race` (UI -> GE -> server, ADR-0023). The race is resolved to its
-- canonical id client-side (race_start.resolve_id), exactly like beamcomp_grid_assign.
function M.grid_assign(race, name)
    if type(race) ~= "string" or race == "" or type(name) ~= "string" or name == "" then
        editor_feedback("pick a race and save a grid first", "warning")
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

-- Delete a saved grid (UI -> GE -> server, ADR-0023). The server replies with the updated grid list (routed
-- to the panel via grid_list_target), so the dropdown refreshes itself.
function M.grid_delete(name)
    if type(name) ~= "string" or name == "" then
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    M.state.grid_list_target = "gridui"
    send_to_server("gridDelete", {map = map, name = name})
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
    guihooks.trigger("appContainer:removeApp", "beamCompGridEditor")
end

-- Clear the grid-editor session (GE): end editing, drop the preview pillars + reference props, and reflect
-- the now-empty state so the panel returns to its "pick a race" start. The panel stays open. This is the
-- shared teardown primitive -- Close reuses it (and then removes the panel).
function M.clear_grid_editor()
    grideditor.clear()
    M.state.grid_active_name = nil
    refresh_grid_edit_scene()
    push_grid_state()
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
    local pending = {}
    for _, entry in ipairs(entries) do
        if entry.serverId ~= nil then
            pending[tostring(entry.serverId)] = true
        end
    end
    M.state.ai_server_ids = pending
    resolve_remote_ai()
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
    validateRace = handle_validate_race,
    -- On-demand scenery pull for a client without the track (ADR-0046).
    trackProbe = handle_track_probe,
    trackFetch = handle_track_fetch,
    trackData = handle_track_data,
    finishGrace = handle_finish_grace,
    resultsToggle = handle_results_toggle,
    analysisToggle = handle_analysis_toggle,
    gridData = handle_grid_data,
    gridList = handle_grid_list,
    presetData = handle_preset_data,
    presetList = handle_preset_list,
    bestNotice = handle_best_notice,
    raceRecords = handle_race_records,
    setupOpen = handle_setup_open,
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

-- Draw the grid editor's live preview poses as cyan pillars with P-slot labels, each with a red
-- orientation line in the slot's facing (drive-up) direction (ADR-0023 + amendment). The active
-- segment's pillars read bright and the rest are dimmed, so it is clear which slots the current knobs
-- affect. Immediate-mode: redrawn each frame from grideditor.state, so leaving edit mode (active = false)
-- removes them with no scene objects to clean up.
local function draw_editor_grid()
    if not grideditor.state.active or not grideditor.state.poses then
        return
    end
    local active_segment = grideditor.active_segment()
    local active_color = ColorF(0.35, 0.95, 1.0, 0.95)
    local inactive_color = ColorF(0.16, 0.55, 0.72, 0.6)
    local orient_color = ColorF(1.0, 0.15, 0.15, 0.9)
    local label_fg = ColorF(1, 1, 1, 1)
    local label_bg = ColorI(0, 0, 0, 255)
    for index, pose in ipairs(grideditor.state.poses) do
        local p = pose.pos
        local base = vec3(p.x, p.y, p.z)
        local top = vec3(p.x, p.y, p.z + GRID_COLUMN_HEIGHT)
        local color = (pose.segment == active_segment) and active_color or inactive_color
        debugDrawer:drawCylinder(base, top, GRID_COLUMN_RADIUS, color)
        debugDrawer:drawTextAdvanced(top, "P" .. (index - 1), label_fg, true, false, label_bg)
        -- A short red line in the slot's facing direction so the whole field's orientation reads at a
        -- glance (faceDir is always present -- gate-normal or the fallback heading). Drawn as a thin
        -- cylinder just above the ground (the confirmed draw API; no unverified drawLine).
        local dir = pose.faceDir
        if dir then
            local z = p.z + GRID_ORIENT_LINE_HEIGHT
            local from = vec3(p.x, p.y, z)
            local to = vec3(p.x + dir.x * GRID_ORIENT_LINE_LENGTH,
                p.y + dir.y * GRID_ORIENT_LINE_LENGTH, z)
            debugDrawer:drawCylinder(from, to, GRID_ORIENT_LINE_RADIUS, orient_color)
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

-- This client's BeamNG license name for the canonical identity (ADR-0031), or nil. The license name is
-- what the player sets in BeamNG's options -- the same identity BeamNG's own race highscores use
-- (raceHighscoresLap.lua). Read off the given vehicle's plate, pcall-guarded (the global is unverified
-- under BeamMP). nil when there is no vehicle, no name set, or the read fails -- the server then falls
-- back to the BeamMP name. Steam/online profile names are empty under BeamMP's guest login, so the
-- license name is the only persistent client-side identity available (verified in-game 2026-06-06).
local function collect_player_name(veh)
    if not veh then
        return nil
    end
    local ok, name = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleLicenseText) == "function" then
            return core_vehicles.getVehicleLicenseText(veh)
        end
        return nil
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

-- Report this client's BeamNG license name to the server (ADR-0031), so it keys every identity -- live
-- standings, results, records -- on the persistent license name instead of the rotating BeamMP guest
-- name. Called at connect (the player's freeroam car, best-effort) and at race spawn (the race car), so
-- a name set before the race is picked up early and reliably refreshed once the race car exists. A nil
-- name is not sent and the server falls back to the BeamMP name. send_to_server is a no-op until the MP
-- client is connected. Assigns the forward-declared local so handle_race_start can call it.
function report_identity(veh)
    local name = collect_player_name(veh)
    if name then
        log("I", LOG_TAG, "reporting client identity: " .. name)
        send_to_server("clientIdentity", {name = name})
        -- Remember what we sent so the staging poll only re-reports on an actual change (ADR-0031 amendment).
        M.state.reported_name = name
    else
        log("W", LOG_TAG, "no client name available; server will use the BeamMP name")
    end
end

-- os.clock() reading of the last staging identity poll, throttling the per-frame plate re-read below.
local last_identity_poll_at = 0
local STAGING_IDENTITY_POLL_INTERVAL = 0.75

-- Pick up a license-name change the player makes during the staging wait (ADR-0031 amendment): the name is
-- otherwise reported only at connect and at spawn (handle_race_start), so a plate edited via BeamNG's
-- vehicle/parts config after spawn never reaches the server. Re-read the own car's plate and re-report when
-- it differs from the last sent name. `force` skips the throttle for the staging->countdown lock-in ("last
-- value at GO wins"); the per-frame onUpdate call throttles. Only runs in staging (the caller gates phase),
-- so an in-race name change still has no effect. Re-resolve the own car each time -- a staging config-respawn
-- replaces the handle (memory beamcomp-respawn-own-at-traps); the restage repoints current_vehicle_id first.
function poll_staging_identity(force)
    if not force and os.clock() - last_identity_poll_at < STAGING_IDENTITY_POLL_INTERVAL then
        return
    end
    last_identity_poll_at = os.clock()
    local own = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own then
        return
    end
    local name = collect_player_name(own)
    if name and name ~= M.state.reported_name then
        report_identity(own)
    end
end

function M.onExtensionLoaded()
    -- Keep the extension across level/scenario switches (a race spans a level).
    setExtensionUnloadMode(M, "manual")
    envelope.set_codec(jsonEncode, jsonDecode)
    -- A Lua reload drops BeamMP's handler table, so always re-register from a clean slate
    -- rather than trusting the serialized flag.
    M.state.registered = false
    ensure_registered()
    -- Seed the current-vehicle tracker; onVehicleSwitched keeps it current from here on.
    local own = be and be:getPlayerVehicle(0)
    if own then
        M.state.current_vehicle_id = own:getId()
    end
    -- Report our BeamNG license name so the server can use it as the canonical identity (ADR-0031).
    -- Best-effort from the current freeroam car; refreshed reliably from the race car at spawn. Fires on
    -- a Lua reload / reconnect too, so a reconnecting client re-reports.
    report_identity(own)
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
-- (so the caller lets the switch through rather than trapping the player). Mirrors the cone bounce
-- (cones.enforce_non_enterable), but race-car-general and with the in-race feedback toast.
local function bounce_to_race_car()
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
    if now - last_block_toast_at >= SWITCH_BLOCK_TOAST_THROTTLE then
        last_block_toast_at = now
        guihooks.trigger("toastrMsg", {
            type = "warning",
            title = "BeamComp",
            msg = "Vehicle switching is locked during the race",
        })
    end
    log("I", RACE_LOG_TAG, "blocked vehicle switch -- bounced player back to race car")
    return true
end

-- Track the vehicle the player is currently in, keep them in their race car during the race, and keep
-- them out of the shared cones otherwise. BeamNG fires onVehicleSwitched(old, new) on every switch.
-- During the locked sequence (countdown + racing) any switch to a vehicle that is not the race car is
-- bounced straight back to it (this also covers the cones while racing); when the race car is gone the
-- bounce is skipped so the player is never trapped. Outside the race we keep the latest non-cone `new`
-- as the authoritative seated car, because in BeamMP the polling API be:getPlayerVehicle(0) sticks to
-- the first owned car -- so race/vehicles.lua resolve_own_car prefers this tracked id (confirmed
-- in-game). A switch into a cone bounces back to the last real car and is NOT recorded -- the
-- guaranteed non-enterable layer (ADR-0009). A blocked switch likewise never updates current_vehicle_id
-- (the checkpoint detector must keep reading the race car).
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

-- Put the player back into their last real car after they switched into an AI car (ADR-0036), the cone
-- bounce generalized to the AI cars (which are real models, so cones.enforce_non_enterable -- gated on
-- is_cone -- does not catch them). No fallback car id -> no-op so the player is never trapped. Returns
-- true if it bounced.
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

function M.onVehicleSwitched(_oldId, newId)
    local phase = M.state.phase
    if (phase == "countdown" or phase == "racing" or phase == "qualifying") and M.state.race_car_id ~= nil
            and tostring(newId) ~= tostring(M.state.race_car_id) then
        if bounce_to_race_car() then
            return
        end
    end
    if cones.is_cone(be and be:getObjectByID(newId)) then
        cones.enforce_non_enterable(newId, M.state.current_vehicle_id)
        return
    end
    -- Keep the player out of an AI car (ADR-0036) and never record it as the seated car, so the detector
    -- keeps reading the real own car.
    if is_ai_game_id(newId) then
        bounce_off_ai(newId)
        return
    end
    M.state.current_vehicle_id = newId
end

-- Retry BeamMP nametag suppression for any cone still awaiting MPVehicleGE registration (queued by
-- onVehicleSpawned). Zero-work on the idle path: pending_nametag is nil until a cone misses its
-- one-shot hide, and is reset to nil once the set empties, so this only runs in the brief window after
-- a cone-bearing race start. An id is dropped once its tag is hidden, its vehicle is gone, or the
-- retry window elapses (the tag then stays -- the accepted fallback, ADR-0020 finding #4).
local function retry_pending_nametags(dt)
    local pending = M.state.pending_nametag
    if not pending then
        return
    end
    -- Collect ids to drop and remove them after the loop (never mutate the table mid-pairs).
    local drop = nil
    for id, waited in pairs(pending) do
        local veh = be and be:getObjectByID(id)
        if not veh or cones.hide_nametag(veh) then
            drop = drop or {}
            drop[#drop + 1] = id
        else
            local elapsed = waited + (dt or 0)
            pending[id] = elapsed
            if elapsed >= NAMETAG_RETRY_TIMEOUT then
                drop = drop or {}
                drop[#drop + 1] = id
            end
        end
    end
    if drop then
        for _, id in ipairs(drop) do
            pending[id] = nil
        end
    end
    if next(pending) == nil then
        M.state.pending_nametag = nil
    end
end

-- Min seconds between reload re-arms. One config respawn raises several vehicle-lifecycle events
-- (onVehicleResetted plus the onVehicleSpawned of its despawn/respawn cycle); this collapses them into a
-- single re-arm so nothing stacks or re-fires. os.clock() is monotonic CPU seconds -- far shorter than any
-- human vehicle-config interaction, so a genuine second tune is never swallowed. File scope (not M.state):
-- a Lua reload only forgets it, which at worst allows one redundant re-arm.
local RELOAD_REARM_THROTTLE = 0.5
local last_reload_rearm_at = 0

-- Re-arm the per-vehicle race mechanics IN PLACE after the player's own race car is reset/reloaded while it
-- must stay put -- on the start grid during staging (bug prerace-car-tuning-breaks-lock-and-reset), or held
-- in a qualifying session (bug quali-hold-reset-and-repaint-leak). Applying a change in the vehicle config
-- menu -- tyre pressure, paint, any tuning -- runs veh:respawn(config) (BeamNG partmgmt.mergeConfig),
-- which reloads the car's jbeam in place (the car STAYS on its slot, same game id) but re-instantiates its
-- VE: that drops the movement freeze -- both the GE controller freeze (controller.setFreeze resets on the
-- VE reload) and the EV throttle clamp -- and the recover/repair override (the "5s reset", ADR-0017), so
-- the car can drive off before the start and the assist goes dead. Unlike a model/config SWAP it never
-- goes through replaceVehicle, so restage_swapped_car never sees it.
--
-- Fix: re-freeze IN PLACE. Do NOT re-place/teleport/respawn the car (an earlier deferred-restage re-place
-- looped: each re-place raised another spawn event -> re-arm -> re-place). Re-assert the GE controller
-- freeze (holds combustion + EV bodies) and clear the two VE-arm flags so the existing onUpdate re-pushes
-- the EV clamp (push_freeze_hold) and the recover/repair override (push_assist_arm) to the reloaded VE.
-- Queued VE commands buffer until the reloaded VM is ready (the hooks fire post-respawn, like the engine's
-- own setGravity-at-spawn), so no explicit wait is needed -- and none of this raises a spawn/reset event,
-- so it cannot loop. Called from BOTH onVehicleResetted and onVehicleSpawned, since a config respawn can
-- raise either hook; the throttle collapses the duplicates.
local function rearm_staged_car_on_reload(vehicle_id)
    -- The two windows in which the own car is frozen and a config respawn can reach it: the staging wait
    -- (the swap-allowed lock) and a qualifying HOLD (queued / staged / done / graced-lap-done). Everywhere
    -- else -- countdown, racing, a live quali run -- the car is either meant to be drivable or the full lock
    -- blocks every reset route, and re-freezing there would be wrong. A no-op if the hook fires out of phase.
    if not M.state.race then
        return
    end
    if M.state.phase ~= "staging" and not hold.is_held() then
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
    -- Re-assert the GE controller freeze in place (no teleport) -- the config respawn reset it, and it is
    -- what holds a combustion car (the EV clamp below only holds EVs).
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if own_car then
        local frozen, freeze_err = vehicles.set_vehicle_frozen(own_car, true)
        if not frozen then
            log("W", RACE_LOG_TAG, "could not re-freeze the reset car: " .. tostring(freeze_err))
        end
    end
    -- Clear the GE arm flags so onUpdate re-pushes the EV throttle clamp + the recover/repair override to
    -- the reloaded VE (they stay true across the reset, which is why they were never re-pushed -> the bug).
    M.state.freeze_hold_armed = false
    M.state.assist_armed = false
    log("I", RACE_LOG_TAG, "race car reset/reloaded (tuning) in " .. tostring(M.state.phase)
        .. "; re-froze in place + re-armed assist")
end

-- As each shared cone appears -- the host's local set when its prefab load spawns them, and the
-- remote synced set on every other client (BeamMP vehicle spawns fire this hook too) -- keep it out
-- of the Tab vehicle cycle and suppress BeamMP's owner nametag on it. The bounce (onVehicleSwitched)
-- is the non-enterable guarantee; the nametag suppression is best-effort but no longer one-shot: a
-- remote-synced cone is registered in MPVehicleGE asynchronously, so the first hide here misses it and
-- the cone is queued for retry_pending_nametags (onUpdate) until registration lands (ADR-0020).
function M.onVehicleSpawned(vehicleId)
    if not be then
        return
    end
    local veh = be:getObjectByID(vehicleId)
    cones.exclude_from_cycle(veh)
    -- A freshly synced vehicle may be one of the owner's AI cars (ADR-0036): try to resolve the pending
    -- aiMap now so it is labelled + nametag-suppressed as soon as it appears. No-op when nothing pending
    -- or on the owner (it has no ai_server_ids).
    resolve_remote_ai()
    -- A config/tuning respawn while the car must stay put (staging, or a quali hold) can surface as a
    -- re-spawn of the same race car (a reload runs a despawn/respawn cycle), so re-freeze + re-arm here too.
    -- The guard no-ops for cones, AI, remotes, and any vehicle that is not the player's own race car -- see
    -- onVehicleResetted, the primary hook.
    rearm_staged_car_on_reload(vehicleId)
    if not cones.is_cone(veh) then
        return
    end
    if cones.hide_nametag(veh) then
        if M.state.pending_nametag then
            M.state.pending_nametag[vehicleId] = nil
        end
    else
        M.state.pending_nametag = M.state.pending_nametag or {}
        M.state.pending_nametag[vehicleId] = 0
    end
end

-- BeamNG fires this GE hook (lua/ge/main.lua vehicleReset -> extensions.hook('onVehicleResetted', vid))
-- whenever a vehicle is reset/reloaded in place -- including a vehicle-config reapply (tyre pressure,
-- paint) during staging or a qualifying hold, which runs veh:respawn(config). Re-freeze the player's car in
-- place and re-arm its recover/repair assist; rearm_staged_car_on_reload guards phase, ownership, and
-- throttling, so a reset of any other car or outside those windows is a no-op.
function M.onVehicleResetted(vehicleId)
    rearm_staged_car_on_reload(vehicleId)
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
    netsize.note(message_type, #encoded)
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
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Qualifying run complete -- your car stays parked until the session ends",
    })
end

-- Surface one detected checkpoint passage: log + toast + report to the server. This is the single
-- emission seam for a passage -- keep it the one place a passage is reported. The report carries
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
    guihooks.trigger("toastrMsg", {
        type = "success",
        title = "BeamComp",
        msg = string.format("Checkpoint %d reached @ %.1fs", event.index, event.time),
    })
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
            if event then
                if ai_lt and ai_lt.start_cp and event.index == ai_lt.start_cp.index then
                    laptimer.complete_lap(ai_lt, event.time)
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
            end
            -- Swept run-up test after the detector, mirroring step_detection's trailing laptimer.step: the
            -- first start/finish crossing arms run_up (gun -> line); a no-op once armed.
            if ai_lt then
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
            -- the standings windowing): the server slot when present, else the canonical name (ADR-0031).
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

    -- The post-race analysis block is derived only when the overlay is actually open in the finished
    -- phase -- it runs every frame for the long finished window, so the closed-overlay default (and every
    -- live frame) skips the work entirely (ADR-0028/0030). `analysisAvailable` is the cheap flag the card
    -- button shows on, so the button appears without building the whole block.
    local is_circuit = (race and race.mode == "circuit") or false
    local analysis_available = phase == "finished" and #entries > 0
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
        isCircuit = is_circuit,
        -- F1 light start active this race (ADR-0043): gates the standings React column.
        f1Start = (race and race.startMode == "f1") or false,
        resultsMin = M.state.results_min or false,
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
-- Returns {pos = {x,y,z}, dir = {x,y,z} or nil}; the VE falls back to a default facing on a nil dir.
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
    local grounded = placement.resolve({pos = target_pos, forward = dir})
    return {pos = grounded.pos, dir = dir}
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
        local placed, err = vehicles.recover_to(own_car, target.pos, target.dir)
        if not placed then
            log("W", RACE_LOG_TAG, "recover-to-checkpoint failed: " .. tostring(err))
            return
        end
    end

    log("I", RACE_LOG_TAG, "assist performed: " .. tostring(kind))
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = (kind == "repair") and "Repaired in place" or "Recovered to last checkpoint",
    })
end

-- Clear any in-progress assist countdown and its centered overlay (ADR-0017). Idempotent.
local function clear_assist_arming()
    if M.state.assist_arming then
        M.state.assist_arming = nil
        countdown.clear()
    end
end

-- Speed (m/s) at or below which the car counts as stopped for recover/repair: the countdown only
-- runs while (near) stationary, so it cannot be triggered while driving (ADR-0017).
local ASSIST_STATIONARY_SPEED = 2.0

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

-- Whether the local car is stopped enough to begin/continue a recover/repair hold.
local function is_car_stationary()
    local own_car = vehicles.resolve_own_car(M.state.current_vehicle_id)
    if not own_car then
        return false
    end
    local ok, speed = pcall(function() return own_car:getVelocity():length() end)
    return ok and speed <= ASSIST_STATIONARY_SPEED
end

-- Lowercase verb for an assist kind, for the failure-feedback toasts ("Hold to <verb>").
local function assist_verb(kind)
    return (kind == "repair") and "repair" or "recover"
end

-- Warning toast telling the player WHY a recover/repair did not fire (ADR-0017 amendment): disabled,
-- not stationary, or released too early. Mirrors the lock's notify_spawn_blocked toast style.
local function notify_assist_blocked(msg)
    guihooks.trigger("toastrMsg", {
        type = "warning",
        title = "BeamComp",
        msg = msg,
    })
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
    guihooks.trigger("toastrMsg", {
        type = "info",
        title = "BeamComp",
        msg = "Car repaired",
    })
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

-- Forward half-length (metres) of a vehicle's spawn bounding box, or nil if the API is unavailable.
-- This is the same measurement front_anchored_target uses to anchor the car's front on the grid line.
-- pcall: the bbox API is engine-version-coupled, so a mismatch reads as "unknown" rather than erroring.
local function spawn_oobb_forward(veh)
    local ok, half_y = pcall(function()
        return veh:getSpawnWorldOOBB():getHalfExtents().y
    end)
    if ok and type(half_y) == "number" then
        return half_y
    end
    return nil
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
    guihooks.trigger("toastrMsg", {
        type = "warning",
        title = "BeamComp",
        msg = "Can't stage that car -- " .. detail,
    })
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
-- record the footprint on the first pending frame and wait until the spawn bbox's forward half-length
-- changes by RESTAGE_MIN_DELTA (new jbeam loaded), or until RESTAGE_MAX_WAIT elapses (same-size swap,
-- where placing with the unchanged box is correct anyway).
local function restage_swapped_car(dt_real)
    if not M.state.race_car_id then
        return
    end

    -- A replace happened: (re)start a pending re-placement. Re-arming the VE waits until placement, when
    -- the new jbeam is loaded -- queueing to a still-loading VE would be lost.
    if lock.consume_replace() then
        M.state.restage_pending = true
        M.state.restage_baseline = nil
        M.state.restage_wait = RESTAGE_MAX_WAIT
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

    -- Record the footprint on the first pending frame (still the old car), then wait for it to change
    -- (new jbeam loaded) or for the fallback timeout.
    local current = spawn_oobb_forward(own)
    if M.state.restage_baseline == nil then
        M.state.restage_baseline = current
    end
    M.state.restage_wait = (M.state.restage_wait or 0) - (dt_real or 0)
    local baseline = M.state.restage_baseline
    local loaded = current ~= nil and baseline ~= nil and math.abs(current - baseline) > RESTAGE_MIN_DELTA
    if not loaded and M.state.restage_wait > 0 then
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
        -- place_at_grid, NOT respawn_own_at: respawn_own_at -> keep_own -> despawn_owned_except
        -- deletes every OTHER owned vehicle, which on the host includes the AI cars (they are
        -- host-owned) -- that wiped the whole AI field. place_at_grid does the same front-anchored
        -- repair+teleport without any despawn (the exact path the AI restage uses, ai.lua).
        -- There is no stray own car to clean here anyway: a fresh spawn already despawned at spawn
        -- time, and a staging swap replaces in place.
        local placed, place_err = vehicles.place_at_grid(own, pose)
        if not placed then
            log("W", RACE_LOG_TAG, "could not re-place staging car: " .. tostring(place_err))
        end
    end
    vehicles.set_vehicle_frozen(own, true)
    M.state.assist_armed = false
    M.state.freeze_hold_armed = false
    -- The new car's jbeam is loaded now (the restage waited for it), so its licenseplate init has
    -- already run -- apply the player's captured plate here, where it sticks instead of being
    -- regenerated. Only a forced/fresh spawn set restage_plate; a staging swap leaves it nil and keeps
    -- its own plate. The plate is the canonical identity (ADR-0031), so re-report it once corrected.
    if M.state.restage_plate then
        local applied, plate_err = vehicles.apply_plate(own, M.state.restage_plate)
        if not applied then
            log("W", RACE_LOG_TAG, "could not apply plate to restaged car: " .. tostring(plate_err))
        else
            report_identity(own)
        end
        M.state.restage_plate = nil
    end
    M.state.restage_pending = false
    log("I", RACE_LOG_TAG, "re-placed staging car at grid slot as race car " .. tostring(own_id))
end

-- Tick the staging-wait indicator in wall time (ADR-0021): count the local copy of the server's
-- auto-start window down and push the remaining whole seconds to the centered overlay only when the
-- shown second changes. The server stays authoritative on the actual staging->countdown transition.
local function step_staging(dt_real)
    local staging = M.state.staging
    if not staging then
        return
    end
    staging.remaining = math.max(0, staging.remaining - (dt_real or 0))
    local shown = math.ceil(staging.remaining)
    if shown ~= staging.last_shown then
        staging.last_shown = shown
        -- F1 light start (ADR-0043): a short pre-procedure heads-up during the staging wait, before the
        -- lights begin. Reads the relayed start mode + penalty (the only consumer of those race fields).
        local race = M.state.race
        local hint = nil
        if race and race.startMode == "f1" then
            hint = "F1 light start -- hold until lights out (jump = +"
                .. tostring(race.jumpPenaltySeconds or 15) .. "s)"
        end
        countdown.show_staging(shown, hint)
    end
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
-- present while a race wants it on screen. The app heartbeats via M.note_hud_alive; if that goes silent --
-- an engine/BeamMP UI reload during the spawn churn can drop our server-delivered app (ADR-0008/0012) --
-- re-assert visibility (Stage A), and if the surface stays silent escalate once to a full UI reload
-- (Stage B). Called from onUpdate in the visible phases only, so free-roam is never disturbed.
local function step_hud_watchdog(dt)
    M.state.hud_ack_gap = M.state.hud_ack_gap + (dt or 0)
    if M.state.hud_ack_gap < HUD_ACK_STALE then
        -- App is heartbeating -- surface healthy, reset the re-show throttle.
        M.state.hud_reshow_wait = 0
        return
    end
    -- Stage B: re-showing has not brought the app back within the grace window; reload the UI once.
    if M.state.hud_ack_gap >= HUD_RELOAD_AFTER and not M.state.hud_reloaded then
        M.state.hud_reloaded = true
        M.state.hud_reshow_wait = 0
        log("W", RACE_LOG_TAG, "HUD app silent; reloading UI to recover the race overlay")
        hud.reload_ui()
        -- The full reload restores the saved-layout apps but faces the same stock-dashboard rebind race
        -- as a race start, so re-queue the rebind (longer settle: the UI must remount first). This is the
        -- secondary/contributing path called out in the bug's 1-investigation.md.
        arm_dashboard_refresh(DASH_REFRESH_AFTER_RELOAD)
        return
    end
    -- Stage A: re-assert app visibility, throttled, until it acks (or Stage B fires).
    M.state.hud_reshow_wait = M.state.hud_reshow_wait + (dt or 0)
    if M.state.hud_reshow_wait >= HUD_RESHOW_EVERY then
        M.state.hud_reshow_wait = 0
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
    if not own or spawn_oobb_forward(own) == nil then
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
    -- Phase-independent: a synced cone's MPVehicleGE registration can land a frame or two after its
    -- spawn, so this runs until the queued nametag suppressions stick (no-op when nothing is pending).
    retry_pending_nametags(dtReal)
    -- Phase-independent, host-only: drive the powered props' (grinders') activation over a short readiness
    -- window after spawn. The `spinner` main-controller only comes up after the freshly spawned grinder
    -- VE's powertrain init, so a single activation at spawn can land before getControllerSafe("spinner")
    -- is non-nil (-> no-op); we re-issue each frame until the deadline, then stop -- the controller owns
    -- the throttle from then on (its locked target ratio holds), so re-asserting past the window would
    -- fight its PID (ADR-0020 amendment). grinder_activate_until is nil off-race / on a non-host / once the
    -- window closes, so the idle path is zero-work; os.clockhp (dtReal is clamped). BeamMP syncs the spin.
    if M.state.grinder_activate_until then
        if os.clockhp() < M.state.grinder_activate_until then
            grinders.activate(M.state.grinder_ids)
        else
            M.state.grinder_activate_until = nil
        end
    end
    -- Phase-independent: keep the race-setup panel on screen while it is meant to be open (bug
    -- setup-panel-settings-survive-ui-reload). The panel heartbeats, and a UI reload that dropped our
    -- late-mounted app (ADR-0008/0012) is recovered by a single re-add. Not phase-gated on purpose --
    -- the panel is used in the lobby AND carries the race-stop controls mid-race. One boolean read when
    -- no panel is open.
    if M.state.setup_open then
        setup.step(dtReal)
    end
    if M.state.phase == "staging" and M.state.race then
        -- Tick the staging-wait indicator on the centered overlay (ADR-0021).
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
        step_detection(dtSim)
        step_ai_detections(dtSim)
        -- Recover/repair work in qualifying exactly as in the race (ADR-0017): drive the held assist
        -- countdown so a player can reset a spun/stuck car and keep setting lap times.
        step_assist(dtReal)
        if M.state.qualifying then
            M.state.qualifying.remaining = math.max(0, M.state.qualifying.remaining - (dtReal or 0))
        end
        -- Once the quali clock expires the server arms a finish-your-lap window (ADR-0041): tick its local
        -- copy so the HUD shows the timeout to be at the finish (the server stays authoritative on the cut).
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
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
        -- Host only: step the AI detectors + proxy-report their crossings (ADR-0036). Inert otherwise.
        step_ai_detections(dtSim)
        -- F1 light start (ADR-0043): release the AI on their staggered reaction delay, and measure + report
        -- each car's start reaction for the standings React column (both no-op for a normal start).
        f1_step_ai_release()
        f1_step_reactions()
        -- Drive the held recover/repair countdown (ADR-0017).
        step_assist(dtReal)
        -- Tick the finish-grace countdown in wall time (the server's cutoff is wall-time; ADR-0014).
        -- Visual only -- the server stays authoritative on the actual DNF cutoff.
        if M.state.grace then
            M.state.grace.remaining = math.max(0, M.state.grace.remaining - (dtReal or 0))
        end
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
    -- Pick up a license-name change made during the staging wait (ADR-0031 amendment). Staging only, so an
    -- in-race name change still has no effect; the GO boundary forces a final re-read (handle_race_phase).
    if M.state.phase == "staging" and M.state.race then
        poll_staging_identity(false)
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
    if M.state.race and (M.state.phase == "staging"
            or (M.state.phase == "countdown" and not (M.state.countdown and M.state.countdown.lights))
            or hold.is_held()) then
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
    -- (ui-missing-for-some-clients-reload): the app heartbeats and this re-shows / reloads if it goes
    -- silent. Covers staging (the countdown overlay arms there, ADR-0021) through finished; free-roam is
    -- untouched.
    if M.state.race and (M.state.phase == "staging" or M.state.phase == "countdown"
        or M.state.phase == "racing" or M.state.phase == "finished"
        or M.state.phase == "qualifying" or M.state.phase == "qualiResults") then
        step_hud_watchdog(dtReal)
        -- Re-bind the stock dashboard/tacho once the (re)seated race car is ready, in the same visible
        -- phases (bug default-dashboard-ui-missing-at-race-start). Idle unless a rebind is queued.
        step_dashboard_refresh(dtReal)
    end
end

function M.onPreRender(dtReal, dtSim, dtRaw)
    if not debugDrawer then
        return
    end
    -- Nothing to draw with no race and no edit session (the common free-roam case): skip before building
    -- the pcall closure so the idle path stays zero-work.
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
        -- The grid edit's reference first checkpoint, so the admin can place the grid relative to where
        -- cars first head. Immediate-mode, drawn whenever a session is active (car_pos/line_angle nil ->
        -- full area + stored-normal posts).
        if grideditor.state.active and M.state.grid_edit_checkpoint then
            draw_checkpoint_marker(M.state.grid_edit_checkpoint, CHECKPOINT_STYLE, nil, nil)
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
end

function M.onExtensionUnloaded()
    if AddEventHandler and RemoveEventHandler then
        RemoveEventHandler(EVENT_CHANNEL, "beamcomp")
    end
    M.state.registered = false
    grideditor.clear()
    -- Despawn any grid-edit reference props too (their lifecycle is separate from the race props that
    -- teardown_race_world clears), so a reload mid-edit leaves no orphaned scenery.
    props.clear(M.state.grid_edit_prop_names or {})
    M.state.grid_edit_prop_names = nil
    M.state.grid_edit_checkpoint = nil
    spawn_mute.restore()
    -- Despawn props/cones, lift the in-race lock + start freeze, and drop all race state so a reload
    -- mid-race never leaves orphaned scenery or a stuck-frozen/locked car (ADR-0017).
    teardown_race_world()
    M.state.phase = nil
    log("I", LOG_TAG, "unloaded")
end

-- The grid-editor command surface (ADR-0023). These are intentionally GLOBAL so they can be typed
-- straight into the BeamNG GE Lua console (the only authoring UI this iteration). Each is a thin
-- wrapper over race/grideditor (preview, client-local), with save/assign/fetch/list going over
-- send_to_server (server owns the shared grids file; save/assign are admin-gated server-side).
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

-- GE console command (intentionally global): open a SAVED grid by name for further editing. The grid
-- lives on the server, so we request it (gridFetch); handle_grid_data opens it when the reply arrives.
function beamcomp_grid_edit(grid_name)
    if type(grid_name) ~= "string" or grid_name == "" then
        editor_feedback("usage: beamcomp_grid_edit(\"<gridname>\")", "warning")
        return
    end
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    send_to_server("gridFetch", {map = map, name = grid_name})
    editor_feedback("opening saved grid '" .. grid_name .. "' ...")
end

-- GE console command (intentionally global): list the grids saved for the current map (gridListReq).
function beamcomp_grid_list()
    local map = maps.current()
    if not map then
        editor_feedback("no map loaded", "warning")
        return
    end
    send_to_server("gridListReq", {map = map})
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
function beamcomp_grid_breakpoint(start_slot)
    local ok, applied = grideditor.select_segment(start_slot)
    if ok then
        editor_feedback("editing segment from slot " .. tostring(applied))
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
    M.state.grid_edit_checkpoint = nil
    editor_feedback("grid editing ended -- pillars cleared")
end

return M
