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
--   * M.clear -- HOST cleanup by id (veh:delete()), the same proven ADR-0009/0020-fallback path cones.clear
--     uses. BeamMP propagates the owned delete ('Od:'), removing them for all clients. This fixes the leak
--     regardless of whether activation succeeds.
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

-- Activation window budget, counted in ONUPDATE FRAMES -- not in wall-clock seconds, and not even in
-- summed frame deltas. Two reasons, both from bug race-prop-steals-player-seat round 2:
--   * The round-1 window was a wall-clock deadline (os.clockhp() + 2.0) armed at prefab-load time inside
--     handle_race_start -- which then spawned the entire AI field synchronously in the same handler. No
--     onUpdate frame runs until that handler returns, so the whole budget could be spent before the
--     activation was issued even once, and the grinders never got the command at all. A frame count cannot
--     be spent by a handler that blocks the frame loop: it starts on the first frame that actually runs.
--   * What we are waiting for -- the fresh VE's powertrain init bringing `spinner` up -- advances per
--     frame, so frames are the honest unit. Counting summed dt would also re-introduce a dependency on a
--     dt that is clamped on the spawn-load spike (and a zero/nil dt would never close the window at all).
-- 600 frames is ~10 s at 60 fps and ~20 s at 30 fps -- deliberately generous, where the old 2.0 s had no
-- headroom for a heavy start. Being generous is cheap because the window STOPS EARLY on evidence: it closes
-- as soon as every grinder's VE has confirmed its controller took the command (M.note_spinning), so a
-- healthy start costs a couple of frames. Only a FAILING start runs the budget out -- and that is exactly
-- the case whose diagnosis we want. Wall-clock elapsed is still reported in the log lines (armed_at).
local ACTIVATE_WINDOW_FRAMES = 600

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

-- The grinder vehicles in the scene that did not exist before the load (diffed against `existing_before`,
-- a set of pre-load object ids). Returns a list of game vehicle ids. Scene presence is synchronous after
-- spawnPrefab (unlike BeamMP ownership), so the host's diff is reliable here. Mirrors cones.new_cone_ids.
local function new_grinder_ids(existing_before)
    local ids = {}
    if not be then
        return ids
    end
    for i = 0, be:getObjectCount() - 1 do
        local veh = be:getObject(i)
        if veh and M.is_grinder(veh) then
            local id = veh:getID()
            if not existing_before[id] then
                ids[#ids + 1] = id
            end
        end
    end
    return ids
end

-- HOST path: identify the powered grinder prop-vehicles this prefab load just created and return their
-- ids so the caller can activate + track them for cleanup. Host-only, called from race/props.lua exactly
-- where cones.keep_new is (same pre-spawn snapshot). BeamMP propagates the spawns ('Os:') to every other
-- client, so the host is the single source of the shared grinder set.
function M.keep_new(existing_before)
    local ids = new_grinder_ids(existing_before)
    log("I", LOG_TAG, string.format("kept %d powered prop(s)", #ids))
    return ids
end

-- ===== activation window =================================================================
-- The `spinner` controller only exists once a freshly spawned grinder VE's powertrain init has run, so a
-- single shot at spawn lands too early and no-ops. Activation therefore re-issues over a window -- and the
-- window is driven by FRAMES, because the readiness it waits for only advances on frames (bug
-- race-prop-steals-player-seat round 2; the round-1 wall-clock deadline armed at prefab-load time could be
-- spent inside handle_race_start before a single frame ran, so the command was never issued at all).
--
-- The caller (init.lua) holds the state table this section returns in M.state.grinder_activate and hands it
-- back each frame, so this module stays stateless and reload-safe. Shape:
--   pending    -- map tostring(id) -> id of the grinders still to confirm (a confirmed one is removed, so
--                 we stop re-issuing to it and never fight its running PID)
--   total      -- how many grinders the window started with
--   confirmed  -- how many have reported their controller took the command (which is NOT the same as
--                 "visibly rotating" -- see M.step)
--   replied    -- whether ANY grinder VE has answered at all (with or without a controller)
--   issued     -- whether the command was successfully queued to at least one grinder VE
--   frames     -- frames the window has actually run, and the budget it is spending (the number the
--                 round-1 bug would have shown as 0)
--   armed_at   -- os.clockhp at arming, for the "N.Ns after the prefab load" figures in the log

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

-- HOST: open an activation window for the grinders just spawned. Returns the state table for the caller to
-- store, or nil when there is nothing to activate (no grinders / non-host) so the caller's per-frame path
-- stays a single nil check. Deliberately does NOT issue anything itself: the first issue happens on the
-- first real frame (M.step), which is the whole point of the frame anchoring.
function M.arm(ids)
    if type(ids) ~= "table" or #ids == 0 then
        return nil
    end
    local pending = {}
    for _, id in ipairs(ids) do
        -- Keyed by tostring(id) so a number/string id mismatch between the spawn diff and the VE's reply
        -- cannot desync the set; the value keeps the original id for be:getObjectByID.
        pending[tostring(id)] = id
    end
    return {
        pending = pending,
        total = #ids,
        confirmed = 0,
        replied = false,
        issued = false,
        frames = 0,
        armed_at = os.clockhp(),
    }
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
    -- Membership is checked BEFORE anything is recorded, so a reply this window did not ask for -- a
    -- command still in flight from a previous race's window, or a duplicate for an already-confirmed
    -- grinder -- cannot flip `replied` and send the closing log down the wrong branch. The diagnosis is
    -- only worth having if it reports on this window's own props.
    local key = tostring(vehicle_id)
    if state.pending[key] == nil then
        return false
    end
    state.replied = true
    if has_controller ~= true then
        return false
    end
    state.pending[key] = nil
    state.confirmed = (state.confirmed or 0) + 1
    return true
end

-- HOST, once per frame: advance the activation window. Returns the state to keep, or nil when the window is
-- done (all grinders confirmed, or the budget is spent) -- the caller just assigns the result back, so a
-- closed window clears itself.
--
-- Exactly two one-shot log lines can come out of a window, and between them they say which of the possible
-- failures happened -- the round-1 log could not distinguish "never issued" from "issued but no controller"
-- (bug race-prop-steals-player-seat round 2). No per-frame logging (memory
-- beamng-client-log-blind-after-15k-lines).
function M.step(state)
    if type(state) ~= "table" then
        return nil
    end
    state.frames = (state.frames or 0) + 1
    -- Read defensively: M.state is serialized across a Lua reload, and an arithmetic error on this
    -- per-frame path would log every single frame.
    local total = state.total or 0
    local confirmed = state.confirmed or 0

    -- Confirmations arrive between frames, so check before spending another round of commands. NB the
    -- confirmation means "the `spinner` controller existed and took our three calls without erroring" --
    -- NOT "the prop is visibly rotating". If every prop confirms and they still stand still, the target
    -- ratio / direction is the next suspect, not the window.
    if confirmed >= total then
        log("I", LOG_TAG, string.format(
            "all %d powered prop(s) took the spin activation %.2fs after the prefab load (%d frame(s))",
            total, since_armed(state), state.frames))
        return nil
    end

    local issued = issue_spin(state.pending)
    if issued > 0 and not state.issued then
        state.issued = true
        log("I", LOG_TAG, string.format(
            "activation issued to %d powered prop(s) on frame %d, %.2fs after the prefab load",
            issued, state.frames, since_armed(state)))
    end

    if state.frames < ACTIVATE_WINDOW_FRAMES then
        return state
    end

    if not state.issued then
        -- Round-1 failure mode: the window was armed but the command never reached a single VE.
        log("W", LOG_TAG, string.format(
            "activation window closed WITHOUT ever issuing -- %d frame(s), %.2fs after the prefab load;"
            .. " the powered props will not spin", state.frames, since_armed(state)))
    elseif not state.replied then
        log("W", LOG_TAG, string.format(
            "activation issued but NO powered prop VE answered in %.2fs (%d frame(s)) -- the queued chunk"
            .. " did not run, or the VE->GE reply path is broken", since_armed(state), state.frames))
    else
        log("W", LOG_TAG, string.format(
            "only %d of %d powered prop(s) took the spin activation in %.2fs (%d frame(s)) -- their VE"
            .. " answered, so the `spinner` controller never came up on the rest",
            confirmed, total, since_armed(state), state.frames))
    end
    return nil
end

-- HOST cleanup: delete the tracked grinder vehicles by id. Tolerant of ids whose vehicle is already gone.
-- BeamMP propagates the owned delete ('Od:'), removing them for all clients. Returns the count processed.
-- Mirrors cones.clear -- the proven ADR-0009/0020-fallback cleanup path.
function M.clear(ids)
    if type(ids) ~= "table" then
        return 0
    end
    local cleared = 0
    for _, id in ipairs(ids) do
        local veh = be and be:getObjectByID(id)
        if veh then
            pcall(function() veh:delete() end)
        end
        cleared = cleared + 1
    end
    log("I", LOG_TAG, string.format("cleared %d powered prop(s)", cleared))
    return cleared
end

return M
