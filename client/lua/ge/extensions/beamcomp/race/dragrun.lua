-- BeamComp -- one drag run, measured (ADR-0067).
--
-- Lives at lua/ge/extensions/beamcomp/race/dragrun.lua inside the client mod zip. Target: client GE (LuaJIT
-- 5.1). Pure: plain tables and numbers in, no engine call, so it runs headless.
--
-- Two things a heat needs on every client:
--   * the Pro tree's state at a time (M.tree / M.lights): dark, all three ambers at `amber`, green
--     `greenAfter` later. The server sends both delays; nothing here hardcodes them.
--   * the run of one car (M.new / M.sample / M.report): fed its position and speed each frame, it finds the
--     reaction (the beam crossing relative to green, negative = red light), the ET at every distance timer
--     from that crossing, the trap speeds, the finish, and the end of a run that does not finish (standing
--     still for STALL_SECONDS after green, the run limit, or the server's cut).
-- The rules are the game's own (gameplay/drag/times.lua, phaseHandlers.lua): the deciding time is R/T + the
-- finish ET. Every distance is the car's travel ALONG ITS ROUTE from where it stood when the tree started
-- (M.route / M.along_route): on a strip the route is the straight from the stage line to the 1/4 mile and the
-- finish is that distance; on any other race it is the race's own line and the finish is the race's own,
-- reported by the caller through M.finish (ADR-0067 amendment 2026-11-15).
--
-- The heat ORDER is not decided here; the server owns that rule (ADR-0067 §3).

local M = {}

-- A car slower than this for STALL_SECONDS after green has stopped: its run ends where it stands (the game's
-- stationaryTooLong, 1 m/s for 5 s).
M.STALL_SPEED = 1.0
M.STALL_SECONDS = 5.0

-- How many route segments ahead of the last one a position is matched against, and how many behind. A car
-- covers well under one segment per frame, and the window keeps a circuit's start from matching its own
-- closing segment, which runs right past it.
local WINDOW_AHEAD = 8
local WINDOW_BEHIND = 2
-- How far along its route a run's starting point is looked for: a drag grid stands at the route's start, maybe
-- some way past it. The closing segment of a circuit runs right past the start and is never a candidate.
local START_REACH = 200

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

-- (public) A measuring route from a list of at least two {x, y, z} points: the points and the distance along
-- the route at each of them (horizontal).
function M.route(points)
    local cumulative = {0}
    for i = 2, #points do
        local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
        cumulative[i] = cumulative[i - 1] + math.sqrt(dx * dx + dy * dy)
    end
    return {points = points, cumulative = cumulative, length = cumulative[#cumulative] or 0}
end

-- The distance along segment `i` of `pos`, and its squared distance from the segment. The first segment
-- extends straight backwards and the last one straight on, so a car behind the start or past the end still
-- measures (a strip's two-point route is then exactly the projection on its axis).
local function project(route, i, pos)
    local a, b = route.points[i], route.points[i + 1]
    local dx, dy = b.x - a.x, b.y - a.y
    local length_sq = dx * dx + dy * dy
    local t = 0
    if length_sq > 1e-12 then
        t = ((pos.x - a.x) * dx + (pos.y - a.y) * dy) / length_sq
    end
    local last = #route.points - 1
    if t < 0 and i > 1 then
        t = 0
    elseif t > 1 and i < last then
        t = 1
    end
    local px, py = a.x + dx * t, a.y + dy * t
    return route.cumulative[i] + t * math.sqrt(length_sq), (pos.x - px) ^ 2 + (pos.y - py) ^ 2
end

-- (public) The distance along `route` of `pos`, matched against the segments around `hint` (the segment of the
-- previous sample; nil = the route's first segments). Returns the distance and the segment it matched.
function M.along_route(route, pos, hint)
    local last = #route.points - 1
    local first, final
    if hint then
        first, final = math.max(1, hint - WINDOW_BEHIND), math.min(last, hint + WINDOW_AHEAD)
    else
        first, final = 1, 1
        while final + 1 < last and route.cumulative[final + 1] < START_REACH do
            final = final + 1
        end
    end
    local best_s, best_d, best_i = 0, math.huge, first
    for i = first, final do
        local s, d = project(route, i, pos)
        if d < best_d then
            best_s, best_d, best_i = s, d, i
        end
    end
    return best_s, best_i
end

-- (public) The time a car crossed a gate plane between two samples ({x, y, z} positions at times t0, t1), or
-- t1 when the gate has no usable normal or the samples do not straddle it.
function M.gate_time(p0, t0, p1, t1, gate_pos, gate_normal)
    if type(gate_normal) ~= "table" then
        return t1
    end
    local d0 = (p0.x - gate_pos.x) * gate_normal.x + (p0.y - gate_pos.y) * gate_normal.y
    local d1 = (p1.x - gate_pos.x) * gate_normal.x + (p1.y - gate_pos.y) * gate_normal.y
    if d0 == d1 or d0 * d1 > 0 then
        return t1
    end
    return t0 + (d0 / (d0 - d1)) * (t1 - t0)
end

-- (public) A run tracker. `opts`:
--   origin -- where the car stands at the tree start ({x, y, z})
--   route  -- the measuring route (M.route)
--   beam   -- the reaction beam distance (0.178 m)
--   finish -- the finish distance on a strip; nil = the caller reports the finish (M.finish)
--   timers -- the timers {id, kind = "distance"|"speed", distance}
--   green  -- the local time of green
--   limit  -- seconds after green a run may last
function M.new(opts)
    local start, segment = M.along_route(opts.route, opts.origin, nil)
    return {
        route = opts.route,
        start = start,     -- the origin's distance along the route
        segment = segment, -- the segment of the last sample
        beam = opts.beam,
        finish = opts.finish,
        timers = opts.timers,
        green = opts.green,
        limit = opts.limit,
        last = nil,        -- the previous sample {t, d, v, pos}
        farthest = 0,      -- the farthest distance reached
        leave = nil,       -- the local time the car crossed the beam
        red = false,       -- left before green
        splits = {},       -- timer id -> ET from the beam crossing
        speeds = {},       -- timer id -> speed (m/s) at that distance
        finished = false,
        finish_time = nil, -- the local time of the finish crossing
        still_since = nil, -- when the car last went below STALL_SPEED after green
        done = false,
        reason = nil,      -- "finish", "stopped", "limit", "cut" or "gone"
    }
end

-- The time and speed at which `distance` was crossed between the previous sample and this one, or nil.
local function crossing(last, t, d, v, distance)
    if not last or last.d >= distance or d < distance then
        return nil
    end
    local fraction = (distance - last.d) / (d - last.d)
    return last.t + fraction * (t - last.t), last.v + fraction * (v - last.v)
end

local function end_run(tracker, reason)
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

-- (public) Feed one sample: the local time `t`, the car's position {x, y, z} and its speed (m/s). Returns the
-- events this sample produced, in order: "leave" (the beam crossed), "jump" (crossed before green: a red
-- light), "finish" (a strip's), "stopped", "limit". A done tracker takes no more samples.
function M.sample(tracker, t, pos, speed)
    local events = {}
    if tracker.done then
        return events
    end
    local along, segment = M.along_route(tracker.route, pos, tracker.segment)
    tracker.segment = segment
    local d = along - tracker.start
    local v = speed or 0
    local position = {x = pos.x, y = pos.y, z = pos.z}
    if tracker.last == nil then
        tracker.last = {t = t, d = d, v = v, pos = position}
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

    local finish_at = tracker.finish and crossing(tracker.last, t, d, v, tracker.finish)
    tracker.previous = tracker.last
    tracker.last = {t = t, d = d, v = v, pos = position}
    if finish_at and tracker.leave then
        M.finish(tracker, finish_at)
        events[#events + 1] = "finish"
        return events
    end

    if t < tracker.green then
        return events
    end
    if t - tracker.green >= tracker.limit then
        end_run(tracker, "limit")
        events[#events + 1] = "limit"
        return events
    end
    if v < M.STALL_SPEED then
        tracker.still_since = tracker.still_since or math.max(t, tracker.green)
        if t - tracker.still_since >= M.STALL_SECONDS then
            end_run(tracker, "stopped")
            events[#events + 1] = "stopped"
        end
    else
        tracker.still_since = nil
    end
    return events
end

-- (public) The car crossed its finish at local time `t` (a strip's distance, or the race's own finish line the
-- caller detected). A car that never left the beam cannot finish.
function M.finish(tracker, t)
    if tracker.done or not tracker.leave then
        return
    end
    tracker.finished = true
    tracker.finish_time = t
    end_run(tracker, "finish")
end

-- (public) The server ended the heat while this car was still out: the run ends where it is.
function M.cut(tracker)
    if not tracker.done then
        end_run(tracker, "cut")
    end
end

-- (public) End a run whose car can no longer be measured (it left the scene).
function M.abandon(tracker)
    if not tracker.done then
        end_run(tracker, "gone")
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
