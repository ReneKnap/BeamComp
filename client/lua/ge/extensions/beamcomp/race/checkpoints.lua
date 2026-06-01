-- BeamComp -- client-side race checkpoint detector (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/checkpoints.lua inside the client mod zip. Target:
-- client GE (LuaJIT 5.1). Stateless module: the per-race detection progress lives in the caller's
-- reload-surviving M.state (init.lua), and is stepped here one frame at a time.
--
-- Detects when the local player's car passes the next expected checkpoint, using an own lightweight
-- swept test against the parser's normalized checkpoints (stable 0-based index, ADR-0005) rather than
-- driving BeamNG's gameplay/race/race.lua (ADR-0010). The detector walks a per-race traversal plan
-- (M.plan): an ordered list of {cursor, lap} entries built from the race mode + lap count (ADR-0013).
-- Only the planned-next checkpoint is tested, so out-of-order / skipped checkpoints never advance;
-- the sequence ends once the final plan entry is passed (the finish). Two modes:
--   sprint  -- every checkpoint once; finish at the last.
--   circuit -- CP1..CP(N-1) then CP0 (the start/finish line) per lap, repeated for L laps; the
--              start-line CP0 crossing at the gun is never scored, so there is no spurious t=0 hit.

local M = {}

local EPSILON = 1e-9

-- Vector helpers on plain {x, y, z} tables (the parser flattens engine vec3 to these, and a
-- vehicle's getPosition() vec3 exposes the same fields) -- keeps the geometry engine-independent.
local function sub(a, b)
    return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

-- Closest point on the segment [a, b] to point p. Clamps the projection parameter to [0, 1] so it
-- stays on the segment (a degenerate zero-length segment returns a).
local function closest_on_segment(p, a, b)
    local ab = sub(b, a)
    local ab_len2 = dot(ab, ab)
    local t = 0
    if ab_len2 > EPSILON then
        t = dot(sub(p, a), ab) / ab_len2
        t = math.max(0, math.min(1, t))
    end
    return {x = a.x + ab.x * t, y = a.y + ab.y * t, z = a.z + ab.z * t}
end

-- Whether the swept segment from prev_pos to cur_pos crosses the checkpoint: the segment passes
-- within `radius` of the centre, and -- for an oriented gate -- the crossing point is on the
-- positive-normal half-space (mirrors pathnode.lua C:inside). The segment (not point) form catches a
-- fast pass-through that a single-frame point test would miss.
local function segment_hits_checkpoint(prev_pos, cur_pos, checkpoint)
    local center = checkpoint.pos
    local closest = closest_on_segment(center, prev_pos, cur_pos)
    local offset = sub(closest, center)
    if dot(offset, offset) > checkpoint.radius * checkpoint.radius then
        return false
    end
    if checkpoint.normal then
        return dot(offset, checkpoint.normal) >= 0
    end
    return true
end

-- Build the traversal plan for a race (ADR-0013): the ordered checkpoints to score, each a
-- {cursor, lap} entry (cursor is 1-based into `checkpoints`, lap is 1-based). Sprint scores every
-- checkpoint once. Circuit scores CP1..CP(N-1) then CP0 per lap, repeated `laps` times -- the
-- start-line CP0 (cursor 1) is omitted from the lap's front, so it is only scored as the lap/finish
-- crossing, never at the gun. A circuit needs >= 2 checkpoints for a distinct line + body; anything
-- smaller (or any non-circuit mode) falls back to the sprint plan. `count` equals the number of
-- scored crossings: N for sprint, laps * N for circuit.
function M.plan(checkpoints, mode, laps)
    local n = #checkpoints
    local entries = {}

    if mode == "circuit" and n >= 2 then
        local lap_count = math.max(1, laps or 1)
        for lap = 1, lap_count do
            for cursor = 2, n do
                entries[#entries + 1] = {cursor = cursor, lap = lap}
            end
            entries[#entries + 1] = {cursor = 1, lap = lap}
        end
    else
        for cursor = 1, n do
            entries[#entries + 1] = {cursor = cursor, lap = 1}
        end
    end

    return {entries = entries, count = #entries}
end

-- The checkpoints for a reverse-direction race (ADR-0018): the forward list driven backward. Pure --
-- no engine calls -- so it matches what BeamNG's own path:reverse() + autoConfig() would emit for the
-- linear/closed shapes we support: a closed loop keeps CP0 (the start/finish line at array index 1)
-- in front and reverses the body, an open path reverses wholesale. Each gate normal is negated so the
-- detector's half-space test (segment_hits_checkpoint) fires when the car crosses from the reverse
-- side. The stable `index` stays each checkpoint's id (display metadata); only the order changes.
function M.reverse(checkpoints, closed)
    local n = #checkpoints
    local reversed = {}

    -- Closed: CP0 stays the scored lap/finish line, so keep it first and reverse CP1..CP(N-1). Open:
    -- reverse the whole array. A degenerate (<2) list reverses wholesale either way.
    local head = (closed and n >= 2) and 1 or 0
    for i = 1, head do
        reversed[#reversed + 1] = checkpoints[i]
    end
    for i = n, head + 1, -1 do
        reversed[#reversed + 1] = checkpoints[i]
    end

    local out = {}
    for i, checkpoint in ipairs(reversed) do
        local copy = {
            index = checkpoint.index,
            name = checkpoint.name,
            pos = checkpoint.pos,
            radius = checkpoint.radius,
            useAsSplit = checkpoint.useAsSplit,
        }
        local normal = checkpoint.normal
        if normal then
            copy.normal = {x = -normal.x, y = -normal.y, z = -normal.z}
        end
        out[i] = copy
    end
    return out
end

-- A fresh detection-state table for a traversal plan, armed before the first plan entry with no
-- elapsed time. Held in the caller's reload-surviving M.state; all fields are plain serializable
-- values.
function M.new(plan)
    return {
        plan = plan,     -- the traversal plan from M.plan ({entries, count}; ADR-0013)
        seq = 0,         -- count of scored crossings so far; also the index of the next plan entry
        elapsed = 0,     -- sim-seconds since arming; the provisional passage time (ADR-0010)
        prev_pos = nil,  -- {x, y, z} previous-frame car position, or nil to (re)seed without testing
        done = false,    -- true once the final plan entry has been passed
    }
end

-- Advance the detector by one frame. Accumulates `dt` into elapsed, then -- given the local car's
-- world position `veh_pos` ({x,y,z} or a vec3) -- runs the swept test against the checkpoint named
-- by the next plan entry. Returns a passage event {seq, index, name, lap, time} on a crossing (seq
-- is the 0-based plan ordinal, the server's ordering key; index is the checkpoint's stable 0-based
-- index, ADR-0005), or nil. At most one passage per frame.
--
-- A nil `veh_pos` (car momentarily unresolved) drops prev_pos so re-acquisition reseeds rather than
-- spanning the gap with a spurious segment; the first armed frame likewise only seeds.
function M.step(state, checkpoints, veh_pos, dt)
    state.elapsed = state.elapsed + (dt or 0)

    if not veh_pos then
        state.prev_pos = nil
        return nil
    end

    local cur = {x = veh_pos.x, y = veh_pos.y, z = veh_pos.z}

    if not state.prev_pos then
        state.prev_pos = cur
        return nil
    end

    local event = nil
    if not state.done then
        local entry = state.plan.entries[state.seq + 1]
        local checkpoint = entry and checkpoints[entry.cursor]
        if checkpoint and segment_hits_checkpoint(state.prev_pos, cur, checkpoint) then
            event = {
                seq = state.seq,
                index = checkpoint.index,
                name = checkpoint.name,
                lap = entry.lap,
                time = state.elapsed,
            }
            state.seq = state.seq + 1
            if state.seq >= #state.plan.entries then
                state.done = true
            end
        end
    end

    state.prev_pos = cur
    return event
end

-- The swept crossing predicate, exposed for non-scoring reuse (the HUD lap timer watches the
-- start/finish line with it; ADR-0022). Detection/scoring still go through M.step -- this only
-- shares the geometry, it does not advance any plan.
M.segment_hits = segment_hits_checkpoint

return M
