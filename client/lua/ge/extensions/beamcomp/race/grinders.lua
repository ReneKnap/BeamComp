-- BeamComp -- shared race POWERED prop-vehicle policy (the prefab's self-driven props, e.g. the
-- GridMap v2 GrinderGrandPrix rotating morning-star/flail obstacles, jbeam "large_spinner").
--
-- Lives at lua/ge/extensions/beamcomp/race/grinders.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state): the caller (race/props.lua + init.lua) owns
-- the tracked grinder ids and the activation state, and passes both back in. The activation TIMING,
-- however, is this module's business now -- see the activation-window section below and bug
-- race-prop-steals-player-seat round 2. Target: client GE (LuaJIT 5.1).
--
-- ADR-0020 amendment (2026-07-02, refined R2 2026-07-03): a race prefab's `class == "BeamNGVehicle"`
-- lines are not always knockable cones -- an aiRace mission (ADR-0035) can ship rotating obstacle props
-- that carry their OWN powertrain. BeamComp's pipeline only SPAWNS the prefab (race/props.lua); nothing
-- starts a spawned prop-vehicle's motor, so on the host the grinders spawn but hang motionless, and --
-- being a different jbeam than "cones" -- they are captured by neither cones.keep_new nor reliably the
-- prefab container, so they leak after the race. On non-hosts prefab.filter_statics drops every
-- BeamNGVehicle line, so the grinders (like the cones) arrive only by BeamMP sync from the host. This
-- module is the powered-prop sibling of race/cones.lua (and mirrors ADR-0036's AI cars -- "a cone that
-- drives itself"):
--
--   * M.is_grinder / M.keep_new -- HOST identity by jbeam name (exactly like cones.is_cone), verified
--     from the stock jbeam: the GrinderGrandPrix props are "large_spinner". After the full-prefab spawn
--     M.keep_new returns every NEW "large_spinner" vehicle (diffed against a pre-spawn snapshot) so the
--     caller can activate + track them. Precise identity => precise leak tracking.
--   * M.arm / M.step / M.note_spinning -- HOST-side motor start via the vehicle's `spinner`
--     main-controller (verified from vehicles/large_spinner/lua/controller/spinner.lua). The controller
--     owns an e-motor + wheel-rotator and regulates the throttle itself (PID in updateGFX); it is driven
--     by a target RPM ratio [-1..1], reachable ONLY through
--     onGameplayEvent("controller:spinner", {"setTargetRPMRatio", <ratio>, <lock>}). So activation =
--     ignition to level 2 (jbeam allows only level 2) + engine ignition + target RPM ratio 1 (locked = set
--     immediately, no ramp). All queued to the grinder VE, fully pcall-guarded: a jbeam without the
--     controller/API no-ops instead of throwing. It has to be re-issued over a readiness WINDOW, because
--     the controller only exists after the freshly spawned VE's powertrain init (getControllerSafe returns
--     nil before that). Once set, the locked target ratio holds on its own -- the controller keeps the
--     throttle, so no re-assert is needed once a grinder has confirmed (writing throttle from outside
--     would fight the controller). BeamMP syncs the resulting node motion to clients, so a host-side spin
--     is also the client fix. See the activation-window section for the timing model.
--   * M.clear_scene -- HOST cleanup by veh:delete(), over every grinder found in the SCENE rather than over
--     an id list captured at spawn time. BeamMP propagates the owned delete ('Od:'), removing them for all
--     clients. Scene-based because the spawn-time ids die within seconds (below), which is why the leak this
--     was meant to fix was in fact still open until round 3 of bug race-prop-steals-player-seat.
--
-- THE SPAWN-TIME IDS DO NOT SURVIVE (measured in beamng.3.log, round 3). About five seconds after the prefab
-- load, BeamMP itself deletes both props and immediately re-spawns them under new ids as part of its
-- ownership/sync round-trip (onVehicleDestroyed 34009/34004 -> onVehicleSpawned 34710/34713). Nothing here
-- may therefore trust a snapshot: the activation window re-derives the live set from the scene every frame
-- and cleanup scans the scene. The jbeam identity (M.is_grinder) is the one thing that does not go stale,
-- which is also why the seat bounce -- reactive and jbeam-keyed -- kept working through all of this.
--
-- Non-enterable, but never parked (ADR-0020 amendment, refined by bug race-prop-steals-player-seat): the
-- original amendment kept grinders out of the WHOLE cone policy so a grinder is never parked/frozen -- and
-- threw out the seat bounce with the park/freeze treatment, which let a grinder steal the player's seat for
-- a whole race. The two halves are now separated:
--   * the seat BOUNCE covers grinders (props.is_race_prop keys off M.is_grinder below). It only re-seats
--     the player -- it touches nothing on the prop, so the spin is unaffected.
--   * cones.exclude_from_cycle (isParkingVehicle) stays jbeam-"cones"-keyed. Its effect on a POWERED prop
--     is unverified, and a grinder must keep spinning, so it is deliberately NOT applied here.

local M = {}

local LOG_TAG = "beamcomp.grinders"

-- The jbeam of the GridMap v2 GrinderGrandPrix rotating grinders (verified from the stock content zip
-- vehicles/large_spinner). Single source of grinder identity, exactly like cones.CONE_JBEAM.
local GRINDER_JBEAM = "large_spinner"

-- How long the activation window stays open, in seconds of wall clock measured FROM THE FIRST FRAME the
-- window actually runs (M.step sets the deadline; M.arm deliberately sets no time at all).
--
-- The anchor is the whole point, and it is what round 1 got wrong (bug race-prop-steals-player-seat): the
-- old deadline was `os.clockhp() + 2.0` computed at prefab-load time inside handle_race_start, which then
-- spawned the entire AI field synchronously in the same handler. No onUpdate frame runs until that handler
-- returns, so the budget was spent before the activation was ever issued once. Measured in beamng.3.log:
-- armed 333.566 (deadline 335.566), handler returned 336.476 -- the first frame came 0.9 s after the
-- deadline had already passed, and `activate` was never called at all.
--
-- Round 2 over-corrected by counting FRAMES instead. That fixed the anchor (a frame count cannot be spent
-- by a handler that blocks the frame loop) but changed the unit too, and the unit was never the problem.
-- Round 3 needs wall-clock semantics back, because the thing the window now has to outlast is a NETWORK
-- round-trip, not a per-frame readiness: BeamMP deletes and re-spawns the props ~5 s after the prefab load
-- (see the tracking section). A frame count cannot express that safely across machines -- 600 frames is 20 s
-- at 30 fps but only 4.5 s at 200 fps, i.e. shorter than the very round-trip it must cover. Anchoring the
-- wall clock on the first frame keeps round 2's guarantee and restores the right unit.
--
-- 20 s is ~4x the one round-trip we have actually measured (treated as an observation, not a constant), and
-- sits comfortably inside the ~2 min staging wait. Any fps yields plenty of frames inside it, so the VE
-- powertrain readiness the activation waits for still gets its frames.
local WINDOW_SECONDS = 20.0

-- The VE-side Lua that starts one grinder's motor (verified from the stock `spinner` main-controller,
-- ADR-0020 amendment R2). The rotation is NOT motor throttle we can poke directly: the controller owns
-- the throttle (PID) and is driven by a target RPM ratio reachable only via onGameplayEvent. Every call
-- is pcall-guarded and existence-checked, so a jbeam/build without that controller or API no-ops instead
-- of throwing. Idempotent, so re-issuing it each frame over the readiness window never mis-behaves: the
-- controller only appears after the fresh VE's powertrain init, so a single shot at spawn would usually
-- land before getControllerSafe("spinner") is non-nil. Ratio 1 (full) with locked = true sets the target
-- immediately without a ramp; direction/speed are tunable in the 2-client handover test.
--
-- The tail reports back to GE (round 2), and it reports UNCONDITIONALLY -- carrying whether the controller
-- was found -- because that is what makes the log conclusive: "no reply at all" (the chunk never ran, or
-- the VE->GE path is broken), "replied false" (the chunk ran, the `spinner` controller was not there) and
-- "replied true" (the controller took the command) are three different diagnoses that were previously
-- indistinguishable. GE drops a confirmed grinder from the pending set, so a healthy grinder is re-issued
-- to -- and replies -- only a frame or two.
--
-- The reply goes through the proven GE<->VE convention of lua/vehicle/extensions/beamcomp/init.lua: the
-- loaded GE extension is reachable as the global `beamcomp_init`, and the `if beamcomp_init then ... end`
-- guard makes a missing global a silent no-op rather than an engine error -- which, queued per frame,
-- would be log spam. The id is forced through tonumber before it is interpolated, so the GE chunk we build
-- is always syntactically valid (an unexpected non-numeric id simply sends nothing).
local SPIN_COMMAND = [[
local c = controller and controller.getControllerSafe and controller.getControllerSafe("spinner")
if c then
  pcall(function() if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(2) end end)
  pcall(function() if c.setEngineIgnition then c.setEngineIgnition(true) end end)
  pcall(function() c.onGameplayEvent("controller:spinner", {"setTargetRPMRatio", 1, true}) end)
end
local vid = tonumber(objectId)
if vid == nil then
  local read, id = pcall(function() return obj:getID() end)
  if read then vid = tonumber(id) end
end
if vid ~= nil then
  pcall(function()
    obj:queueGameEngineLua("if beamcomp_init then beamcomp_init.note_grinder_spinning("
      .. tostring(vid) .. ", " .. tostring(c ~= nil) .. ") end")
  end)
end
]]

-- Whether a vehicle object is one of the race prefab's powered grinder prop-vehicles. This is the
-- single source of grinder identity (the spawn loader and the activation both ask here), mirroring
-- cones.is_cone.
function M.is_grinder(veh)
    return veh ~= nil and veh.JBeam == GRINDER_JBEAM
end

-- Every grinder vehicle currently in the scene, as a map tostring(id) -> id. THE source of truth for the
-- grinder set (bug race-prop-steals-player-seat round 3): a spawn-time id snapshot goes stale, because
-- BeamMP deletes and re-spawns the props a few seconds later as part of its ownership/sync round-trip. The
-- jbeam identity does not go stale, so re-deriving the set from the scene is what keeps activation and
-- cleanup pointed at vehicles that actually exist. Keyed by tostring(id) to match the window's sets.
local function live_grinders()
    local live = {}
    if not be then
        return live
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and M.is_grinder(veh) then
            local id = veh:getID()
            live[tostring(id)] = id
        end
    end
    return live
end

-- The grinder vehicles in the scene that did not exist before the load (diffed against `existing_before`,
-- a set of pre-load object ids). Returns a list of game vehicle ids. Scene presence is synchronous after
-- spawnPrefab (unlike BeamMP ownership), so the host's diff is reliable at that instant -- it is only the
-- LATER staleness that the round-3 rescan exists for. Mirrors cones.new_cone_ids.
local function new_grinder_ids(existing_before)
    local ids = {}
    for _, id in pairs(live_grinders()) do
        if not existing_before[id] then
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- HOST path: identify the powered grinder prop-vehicles this prefab load just created. Host-only, called
-- from race/props.lua exactly where cones.keep_new is (same pre-spawn snapshot). BeamMP propagates the
-- spawns ('Os:') to every other client, so the host is the single source of the shared grinder set.
--
-- These ids are now only the window's SEED, not a set anything relies on later: BeamMP replaces the props a
-- few seconds after this returns, so from then on the ids are dead (round 3). The window re-derives the live
-- set every frame and cleanup scans the scene, so nothing downstream trusts this snapshot. It is still worth
-- returning: it tells the window (and the log) how many props the prefab itself contained.
function M.keep_new(existing_before)
    local ids = new_grinder_ids(existing_before)
    log("I", LOG_TAG, string.format("kept %d powered prop(s)", #ids))
    return ids
end

-- ===== activation window =================================================================
-- Two problems have to be solved together here, and both were measured in beamng.3.log (bug
-- race-prop-steals-player-seat rounds 2 + 3):
--
--   1. WHEN to issue. The `spinner` controller only exists once a freshly spawned grinder VE's powertrain
--      init has run, so a single shot at spawn lands too early and no-ops -- hence a window. The window's
--      deadline is anchored on the FIRST FRAME it runs, never at arming time, because the race-start
--      handler blocks the frame loop for seconds (the AI field spawns inside it) and would otherwise
--      consume the whole window before a single activation went out.
--
--   2. WHICH vehicles to issue to. The ids captured at prefab load are dead within ~5 s: BeamMP deletes
--      both props and immediately re-spawns them under new ids as part of its ownership/sync round-trip
--      (`MPVehicleGE.onVehicleDestroyed` 34009/34004 -> `onVehicleSpawned` 34710/34713 at t=338.3, five
--      seconds after the prefab load at t=333.3). Issuing to the snapshot therefore issues to NOTHING,
--      while the live pair sits in no tracked set and never spins. That is why the 2026-07-03 activation
--      most likely never worked in-game. So the window RE-DERIVES the live set from the scene every frame
--      (live_grinders, jbeam-keyed, which does not go stale), adopts anything new, and drops anything that
--      vanished. The same staleness is why cleanup is a scene scan (M.clear_scene) rather than an id list.
--
-- The window therefore does NOT close early on "everyone confirmed": it has to outlast BeamMP's round-trip
-- to see the replacements at all. Re-issuing is idempotent and a confirmed prop is removed from `pending`,
-- so staying open costs a rescan per frame and never re-asserts against a running PID.
--
-- The caller (init.lua) holds the state table this section returns in M.state.grinder_activate and hands it
-- back each frame, so this module stays stateless and reload-safe. Shape:
--   known      -- map tostring(id) -> id of every prop this window has ever tracked (seed + adoptions);
--                 entries are never removed, so a prop is adopted only once
--   pending    -- the subset still awaiting confirmation; a prop leaves it when it confirms (so we stop
--                 re-issuing to it) or when its vehicle vanishes
--   seeded     -- how many props the prefab load itself found (the snapshot count)
--   seen       -- how many props have been tracked in total; seen - seeded = BeamMP replacements
--   confirmed  -- how many reported their controller took the command (which is NOT the same as "visibly
--                 rotating" -- see M.step)
--   vanished   -- how many were dropped because their vehicle disappeared (BeamMP's delete half)
--   replied    -- whether ANY tracked prop VE has answered at all (with or without a controller)
--   issued     -- whether the command was successfully queued to at least one prop VE
--   frames     -- frames the window has actually run (the number the round-1 bug would have shown as 0)
--   armed_at   -- os.clockhp at arming, for the "N.Ns after the prefab load" figures in the log
--   deadline   -- os.clockhp deadline, set on the FIRST FRAME (nil until then -- that is the anchoring)

-- Queue the spin command to one grinder VE. pcall-guarded (the queue call is the engine boundary); the
-- first return is the ok flag.
local function queue_spin(veh)
    return pcall(function() veh:queueLuaCommand(SPIN_COMMAND) end)
end

-- (Re-)issue the activation command to each grinder still pending confirmation. A grinder whose vehicle is
-- gone is skipped. Silent (it runs per frame inside the window; M.step owns the one-shot logging). Returns
-- the count successfully queued to.
local function issue_spin(pending)
    if not be then
        return 0
    end
    local issued = 0
    for _, id in pairs(pending) do
        local veh = be:getObjectByID(id)
        if veh and queue_spin(veh) then
            issued = issued + 1
        end
    end
    return issued
end

-- Seconds since the window was armed (i.e. since the prefab load), for the log lines. This is the figure
-- that exposes a slow race-start handler: a first activation several seconds after arming means the handler
-- (AI spawn, jbeam loads, collision rebuild) held the frame loop for that long.
local function since_armed(state)
    return os.clockhp() - (state.armed_at or os.clockhp())
end

-- HOST: open an activation window. `ids` is an optional SEED (the prefab load's snapshot); the window
-- re-derives the live set from the scene on every frame anyway, so an empty or nil seed is fine -- that is
-- how the caller re-opens a window for a prop BeamMP re-spawned after the previous window had closed.
-- Returns the state table for the caller to store. Deliberately sets NO deadline and issues NOTHING: both
-- happen on the first real frame (M.step), which is what keeps a blocking race-start handler from consuming
-- the window before it has run.
function M.arm(ids)
    local known = {}
    local pending = {}
    local seeded = 0
    if type(ids) == "table" then
        for _, id in ipairs(ids) do
            -- Keyed by tostring(id) so a number/string id mismatch between the spawn diff, the scene rescan
            -- and the VE's reply cannot desync the sets; the value keeps the real id for be:getObjectByID.
            local key = tostring(id)
            known[key] = id
            pending[key] = id
            seeded = seeded + 1
        end
    end
    return {
        known = known,
        pending = pending,
        seeded = seeded,
        seen = seeded,
        confirmed = 0,
        vanished = 0,
        replied = false,
        issued = false,
        frames = 0,
        armed_at = os.clockhp(),
        deadline = nil,
    }
end

-- Adopt every live grinder the window does not know yet. Anything reaching here was NOT in the prefab
-- load's snapshot, so it is a prop that appeared afterwards -- in practice BeamMP's re-spawn of a prop it
-- just deleted. Logged per adoption batch (a rare event, a line or two per race), and deliberately worded so
-- the log distinguishes adopting a replacement from activating the original. Returns the count adopted.
local function adopt_new(state, live)
    local adopted = 0
    for key, id in pairs(live) do
        if state.known[key] == nil then
            state.known[key] = id
            state.pending[key] = id
            state.seen = state.seen + 1
            adopted = adopted + 1
        end
    end
    if adopted > 0 then
        log("I", LOG_TAG, string.format(
            "adopted %d powered prop(s) that appeared after the prefab load (BeamMP re-spawn) on frame %d,"
            .. " %.2fs in -- activating those instead of the dead spawn-time ids",
            adopted, state.frames, since_armed(state)))
    end
    return adopted
end

-- Drop pending props whose vehicle is gone from the scene. This is BeamMP's delete half: it takes the props
-- away under the ids we captured, so without this the window would keep issuing into nothing and would
-- report them as "the controller never came up" at the close. Logged per batch. Never mutates the table
-- mid-pairs. Returns the count dropped.
local function drop_vanished(state, live)
    local gone = nil
    for key in pairs(state.pending) do
        if live[key] == nil then
            gone = gone or {}
            gone[#gone + 1] = key
        end
    end
    if not gone then
        return 0
    end
    for _, key in ipairs(gone) do
        state.pending[key] = nil
    end
    state.vanished = state.vanished + #gone
    log("I", LOG_TAG, string.format(
        "%d tracked powered prop(s) vanished before confirming on frame %d, %.2fs in -- BeamMP re-spawns"
        .. " them under new ids, so a replacement is adopted instead", #gone, state.frames,
        since_armed(state)))
    return #gone
end

-- How many keys a set holds (only called once, when the window closes).
local function count_keys(set)
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

-- The window's single closing verdict, plus one targeted hint when it did not work out. Between them these
-- name every failure mode that has actually occurred in this bug, which is what the round-1/2 logs could
-- not do (memory beamng-client-log-blind-after-15k-lines -- one-shot only, never per frame).
local function log_verdict(state)
    local still_pending = count_keys(state.pending)
    local ok = state.confirmed > 0 and still_pending == 0
    log(ok and "I" or "W", LOG_TAG, string.format(
        "activation window closed after %.1fs / %d frame(s): %d of %d powered prop(s) took the spin"
        .. " activation -- %d seeded by the prefab load, %d adopted after a BeamMP re-spawn, %d vanished"
        .. " before confirming, %d still pending",
        since_armed(state), state.frames, state.confirmed, state.seen, state.seeded,
        state.seen - state.seeded, state.vanished, still_pending))
    if not state.issued then
        log("W", LOG_TAG, "the activation was never queued to a single prop VE -- no prop was ever live"
            .. " while the window ran")
    elseif not state.replied then
        log("W", LOG_TAG, "no prop VE ever answered -- the queued chunk did not run, or the VE->GE reply"
            .. " path does not work from a stock prop VE")
    elseif still_pending > 0 then
        log("W", LOG_TAG, "the `spinner` controller never came up on the props that stayed alive -- the"
            .. " controller name or the readiness assumption is what to check next")
    end
end

-- A grinder VE reporting back (via the queued GE call in SPIN_COMMAND, routed through init.lua's
-- note_grinder_spinning). `has_controller` false means the chunk ran but `spinner` was not up yet -- worth
-- recording as "the VE answered", but not a confirmation. Idempotent: a repeat for an already-confirmed
-- grinder is ignored, so the several replies in flight before the window closes cannot miscount. Returns
-- true when this call newly confirmed a grinder.
function M.note_spinning(state, vehicle_id, has_controller)
    if type(state) ~= "table" or type(state.pending) ~= "table" or vehicle_id == nil then
        return false
    end
    -- Membership is checked BEFORE anything is recorded, so a reply this window did not ask for -- a command
    -- still in flight from a previous race's window -- cannot flip `replied` and send the closing log down
    -- the wrong branch. The diagnosis is only worth having if it reports on this window's own props.
    -- Checked against `known`, not `pending`: a prop that already confirmed, or that vanished and was
    -- dropped, is still one of ours and its reply is still evidence that a prop VE answered.
    local key = tostring(vehicle_id)
    if type(state.known) ~= "table" or state.known[key] == nil then
        return false
    end
    state.replied = true
    if has_controller ~= true then
        return false
    end
    if state.pending[key] == nil then
        return false
    end
    state.pending[key] = nil
    state.confirmed = (state.confirmed or 0) + 1
    return true
end

-- HOST, once per frame: advance the activation window. Returns the state to keep, or nil once the window has
-- closed -- the caller just assigns the result back, so a closed window clears itself.
--
-- Each frame it re-derives the live grinder set from the scene, adopts anything new (BeamMP's re-spawn),
-- drops anything that vanished (BeamMP's delete), and re-issues the activation to whatever is still pending.
-- It runs the FULL window rather than closing as soon as everything known has confirmed: the props that need
-- activating most are the ones that do not exist yet when the first ones confirm. Re-issuing is idempotent
-- and a confirmed prop has already left `pending`, so nothing re-asserts against a running controller PID.
--
-- Logging is one-shot / per-event only -- never per frame (memory beamng-client-log-blind-after-15k-lines).
-- A confirmation means "the `spinner` controller existed and took our three calls without erroring", NOT
-- "the prop is visibly rotating": if everything confirms and they still stand still, the target ratio /
-- direction is the next suspect, not the window.
function M.step(state)
    if type(state) ~= "table" or type(state.known) ~= "table" then
        return nil
    end
    state.frames = (state.frames or 0) + 1
    -- The deadline starts HERE, on the first frame the window actually gets -- not at arming time. See
    -- WINDOW_SECONDS: the race-start handler blocks the frame loop long enough to have eaten the whole
    -- window before this line ever ran (measured: 2.9 s of handler after a 2.0 s budget).
    if state.deadline == nil then
        state.deadline = os.clockhp() + WINDOW_SECONDS
    end

    local live = live_grinders()
    adopt_new(state, live)
    drop_vanished(state, live)

    local issued = issue_spin(state.pending)
    if issued > 0 and not state.issued then
        state.issued = true
        log("I", LOG_TAG, string.format(
            "activation issued to %d powered prop(s) on frame %d, %.2fs after the prefab load",
            issued, state.frames, since_armed(state)))
    end

    if os.clockhp() < state.deadline then
        return state
    end
    log_verdict(state)
    return nil
end

-- HOST cleanup: delete every grinder currently in the SCENE, rather than the ids captured when the prefab
-- was loaded. That id list is dead a few seconds later (BeamMP re-spawns the props under new ids), so the
-- old id-based cleanup deleted nothing that existed and the real props leaked into free-roam after the race
-- -- the very leak the ADR-0020 amendment set out to close, still open until now (bug
-- race-prop-steals-player-seat round 3). Scanning by jbeam identity cannot go stale, and it also reaps a
-- prop left behind by any number of BeamMP round-trips, or by a state-losing Lua reload.
--
-- HOST-ONLY: the caller gates this on being the prop owner. A non-host never spawned a grinder -- its copies
-- are BeamMP-synced from the host, and the host's delete ('Od:') propagates to everyone.
--
-- Trade-off, deliberate: this deletes any `large_spinner` in the scene, not provably only the ones our
-- prefab produced. Given the caller's gate (we are the prop owner of a race whose prefab brought grinders)
-- and that a spinner is not a car anybody drives, that is the right side to err on -- a leaked, indestructible
-- obstacle in free-roam is much worse than deleting a spinner somebody spawned by hand. Returns the count.
function M.clear_scene()
    local ids = {}
    for _, id in pairs(live_grinders()) do
        ids[#ids + 1] = id
    end
    for _, id in ipairs(ids) do
        local veh = be and be:getObjectByID(id)
        if veh then
            pcall(function() veh:delete() end)
        end
    end
    log("I", LOG_TAG, string.format("cleared %d powered prop(s) found in the scene", #ids))
    return #ids
end

return M
