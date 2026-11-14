-- BeamComp -- one drag run, measured (ADR-0067).
--
-- Lives at lua/ge/extensions/beamcomp/race/dragrun.lua inside the client mod zip. Target: client GE (LuaJIT
-- 5.1). Pure: plain tables and numbers in, no engine call, so it runs headless.
--
-- Two things a heat needs on every client:
--   * the Pro tree's state at a time (M.tree / M.lights): dark, all three ambers at `amber`, green
--     `greenAfter` later. The server sends both delays; nothing here hardcodes them.
--   * the run of one car (M.new / M.sample / M.report): fed its position and speed along the strip axis each
--     frame, it finds the reaction (the beam crossing relative to green, negative = red light), the ET at
--     every distance timer from that crossing, the trap speeds, the finish, and the end of a run that does
--     not finish (standing still for STALL_SECONDS after green, or the run limit).
-- The rules are the game's own (gameplay/drag/times.lua, phaseHandlers.lua): the deciding time is R/T + the
-- finish ET, the finish is the farthest distance timer. Every distance is the car's travel from where it
-- stood when the tree started, so every car covers the same distance whatever it measures.
--
-- The heat ORDER is not decided here; the server owns that rule (ADR-0067 §3).

local M = {}

-- A car slower than this for STALL_SECONDS after green has stopped: its run ends where it stands (the game's
-- stationaryTooLong, 1 m/s for 5 s).
M.STALL_SPEED = 1.0
M.STALL_SECONDS = 5.0

-- (public) The tree of one heat, anchored on the local clock at `start` (the moment dragTree arrived).
function M.tree(start, amber_delay, green_after)
    local amber = start + amber_delay
    return {start = start, amber = amber, green = amber + green_after}
end

-- (public) "dark" before the ambers, "amber" between the ambers and green, "green" after.
function M.lights(tree, t)
    if t < tree.amber then
        return "dark"
    end
    if t < tree.green then
        return "amber"
    end
    return "green"
end

-- (public) A run tracker. `opts`:
--   origin, axis -- where the car stands at the tree start ({x, y, z}) and the strip direction (unit {x, y})
--   beam         -- the reaction beam distance (0.178 m)
--   finish       -- the finish distance (the farthest distance timer)
--   timers       -- the strip's timers {id, kind = "distance"|"speed", distance}
--   green        -- the local time of green
--   limit        -- seconds after green a run may last
function M.new(opts)
    return {
        origin = opts.origin,
        axis = opts.axis,
        beam = opts.beam,
        finish = opts.finish,
        timers = opts.timers,
        green = opts.green,
        limit = opts.limit,
        last = nil,        -- the previous sample {t, d, v}
        farthest = 0,      -- the farthest distance reached
        leave = nil,       -- the local time the car crossed the beam
        red = false,       -- left before green
        splits = {},       -- timer id -> ET from the beam crossing
        speeds = {},       -- timer id -> speed (m/s) at that distance
        finished = false,
        finish_time = nil, -- the local time of the finish crossing
        still_since = nil, -- when the car last went below STALL_SPEED after green
        done = false,
        reason = nil,      -- "finish", "stopped", "limit" or "gone"
    }
end

-- The distance travelled along the axis from the origin.
local function along(tracker, pos)
    return (pos.x - tracker.origin.x) * tracker.axis.x + (pos.y - tracker.origin.y) * tracker.axis.y
end

-- The time and speed at which `distance` was crossed between the previous sample and this one, or nil.
local function crossing(last, t, d, v, distance)
    if not last or last.d >= distance or d < distance then
        return nil
    end
    local fraction = (distance - last.d) / (d - last.d)
    return last.t + fraction * (t - last.t), last.v + fraction * (v - last.v)
end

local function finish_run(tracker, reason)
    tracker.done = true
    tracker.reason = reason
end

-- Fold every timer crossed between the previous sample and this one.
local function fold_timers(tracker, t, d, v)
    for _, timer in ipairs(tracker.timers) do
        local at, speed = crossing(tracker.last, t, d, v, timer.distance)
        if at then
            if timer.kind == "speed" then
                tracker.speeds[timer.id] = speed
            elseif timer.distance > tracker.beam and tracker.leave then
                tracker.splits[timer.id] = at - tracker.leave
            end
        end
    end
end

-- (public) Feed one sample: the local time `t`, the car's position {x, y, z} and its speed along the axis
-- (m/s). Returns the events this sample produced, in order: "leave" (the beam crossed), "jump" (crossed
-- before green: a red light), "finish", "stopped", "limit". A done tracker takes no more samples.
function M.sample(tracker, t, pos, speed)
    local events = {}
    if tracker.done then
        return events
    end
    local d = along(tracker, pos)
    local v = speed or 0
    if tracker.last == nil then
        tracker.last = {t = t, d = d, v = v}
    end

    if not tracker.leave then
        local at = crossing(tracker.last, t, d, v, tracker.beam)
        if at then
            tracker.leave = at
            events[#events + 1] = "leave"
            if at < tracker.green then
                tracker.red = true
                events[#events + 1] = "jump"
            end
        end
    end
    fold_timers(tracker, t, d, v)
    tracker.farthest = math.max(tracker.farthest, d)

    local finish_at = crossing(tracker.last, t, d, v, tracker.finish)
    tracker.last = {t = t, d = d, v = v}
    if finish_at and tracker.leave then
        tracker.finished = true
        tracker.finish_time = finish_at
        finish_run(tracker, "finish")
        events[#events + 1] = "finish"
        return events
    end

    if t < tracker.green then
        return events
    end
    if t - tracker.green >= tracker.limit then
        finish_run(tracker, "limit")
        events[#events + 1] = "limit"
        return events
    end
    if v < M.STALL_SPEED then
        tracker.still_since = tracker.still_since or math.max(t, tracker.green)
        if t - tracker.still_since >= M.STALL_SECONDS then
            finish_run(tracker, "stopped")
            events[#events + 1] = "stopped"
        end
    else
        tracker.still_since = nil
    end
    return events
end

-- (public) End a run whose car can no longer be measured (it left the scene).
function M.abandon(tracker)
    if not tracker.done then
        finish_run(tracker, "gone")
    end
end

-- (public) The reaction time: the beam crossing relative to green, negative for a red light, nil while the car
-- has not left.
function M.reaction(tracker)
    return tracker.leave and (tracker.leave - tracker.green) or nil
end

-- (public) The report the server folds, final or partial (the moment of a red light, so every client's tree
-- can show it). Field names are the wire contract (dragRun); `splits` and `speeds` are relayed opaquely.
function M.report(tracker)
    local finished = tracker.finished
    return {
        final = tracker.done,
        redLight = tracker.red,
        rt = M.reaction(tracker),
        et = finished and (tracker.finish_time - tracker.leave) or nil,
        total = finished and (tracker.finish_time - tracker.green) or nil,
        finished = finished,
        distance = tracker.farthest,
        reason = tracker.reason,
        splits = tracker.splits,
        speeds = tracker.speeds,
    }
end

return M
