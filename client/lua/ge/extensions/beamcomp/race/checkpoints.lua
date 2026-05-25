-- BeamComp -- client-side race checkpoint detector (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/checkpoints.lua inside the client mod zip. Target:
-- client GE (LuaJIT 5.1). Stateless module: the per-race detection progress lives in the caller's
-- reload-surviving M.state (init.lua), and is stepped here one frame at a time.
--
-- Detects when the local player's car passes the next expected checkpoint, using an own lightweight
-- swept test against the parser's normalized checkpoints (stable 0-based index, ADR-0005) rather than
-- driving BeamNG's gameplay/race/race.lua (ADR-0010). Single linear pass: only the next expected
-- checkpoint is tested, so out-of-order / skipped checkpoints never advance; the sequence ends once
-- the last checkpoint is passed. Multi-lap, finish, and the client->server send are deferred.

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

-- A fresh detection-state table, armed at index 0 with no elapsed time. Held in the caller's
-- reload-surviving M.state; all fields are plain serializable values.
function M.new()
    return {
        cursor = 1,      -- 1-based index into the checkpoints array; the next expected checkpoint
        elapsed = 0,     -- sim-seconds since arming; the provisional passage time (ADR-0010)
        prev_pos = nil,  -- {x, y, z} previous-frame car position, or nil to (re)seed without testing
        done = false,    -- true once the last checkpoint has been passed
    }
end

-- Advance the detector by one frame. Accumulates `dt` into elapsed, then -- given the local car's
-- world position `veh_pos` ({x,y,z} or a vec3) -- runs the swept test against the next expected
-- checkpoint. Returns a passage event {index, name, time} on a crossing (reporting the checkpoint's
-- stable 0-based index, ADR-0005), or nil. At most one passage per frame.
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
        local checkpoint = checkpoints[state.cursor]
        if checkpoint and segment_hits_checkpoint(state.prev_pos, cur, checkpoint) then
            event = {
                index = checkpoint.index,
                name = checkpoint.name,
                time = state.elapsed,
            }
            state.cursor = state.cursor + 1
            if state.cursor > #checkpoints then
                state.done = true
            end
        end
    end

    state.prev_pos = cur
    return event
end

return M
