-- BeamComp -- client-side circuit lap timer (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/laptimer.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless module: the per-race lap-timing progress lives in the caller's M.state
-- (init.lua) and is stepped here one frame at a time. (M.state does not survive a GE Lua reload -- see
-- its header in init.lua; holding no state of its own is what makes this module reload-safe.)
--
-- Circuit races only. A racing-style lap clock runs line->line: the current lap's time is measured
-- from the last start/finish-line crossing. The detector (race/checkpoints.lua) already scores a
-- start/finish (CP0) crossing at the end of every lap; those are the lap boundaries for laps 2..L,
-- fed in via complete_lap. The one boundary the scored plan omits is lap 1's start -- the very first
-- line crossing after the gun (ADR-0013 starts the plan at CP1) -- so this module watches that line
-- itself with a one-shot, non-scoring swept test (checkpoints.segment_hits). It never reports to the
-- server and never advances any plan; it only derives a display time (ADR-0022).
--
-- The grid is placed behind the start/finish line for circuits (race/start.lua, ADR-0022), so the
-- first crossing is a real line pass rather than a t=0 hit inside the start volume.

local M = {}

local checkpoints = require("beamcomp/race/checkpoints")

-- A fresh lap-timer state for a circuit, watching `start_cp` (the start/finish checkpoint). Held in
-- the caller's M.state; all fields are plain values -- no closures, no engine handles, so nothing in it
-- can go stale.
function M.new(start_cp)
    return {
        start_cp = start_cp,  -- the start/finish checkpoint to watch (pos/radius/normal; reversed-safe)
        started = false,      -- true once the first line crossing has armed the lap clock
        prev_pos = nil,       -- {x, y, z} previous-frame car position for the pre-start swept test
        lap_start = 0,        -- elapsed (sim-seconds) at the current lap's start
        run_up = nil,         -- elapsed at the first line crossing: the run-up from the grid to the
                              -- start/finish line (the gun -> real start of lap 1). Set once, kept for
                              -- the analysis overlay's S0 column / clean lap-1 time (ADR-0022/0028).
        best = nil,           -- best completed lap time, or nil before the first completion
        last_lap = nil,       -- the most recently completed lap time, or nil
    }
end

-- Advance the timer by one frame. Until the clock is armed, run the swept test against the
-- start/finish line; the first crossing arms it (lap_start = elapsed). A nil `car_pos` (car
-- momentarily unresolved) drops prev_pos so re-acquisition reseeds rather than spanning the gap --
-- mirrors checkpoints.step. Once armed there is nothing to watch per frame; lap boundaries arrive
-- through complete_lap.
function M.step(state, car_pos, elapsed)
    if not state or not state.start_cp or state.started then
        return
    end

    if not car_pos then
        state.prev_pos = nil
        return
    end

    if state.prev_pos and checkpoints.segment_hits(state.prev_pos, car_pos, state.start_cp) then
        state.started = true
        state.lap_start = elapsed
        -- The first crossing is the real start of lap 1; `elapsed` here (gun-relative) is the run-up
        -- from the grid to the line. Captured once, before lap_start gets reused by complete_lap.
        state.run_up = elapsed
        return
    end

    state.prev_pos = {x = car_pos.x, y = car_pos.y, z = car_pos.z}
end

-- Close the current lap at `elapsed` (called on each scored start/finish crossing): record its time,
-- update the best, and start the next lap's clock. No-op until the clock has been armed.
function M.complete_lap(state, elapsed)
    if not state or not state.started then
        return
    end
    local lap = elapsed - state.lap_start
    state.last_lap = lap
    if state.best == nil or lap < state.best then
        state.best = lap
    end
    state.lap_start = elapsed
end

-- The current lap's elapsed time, or nil before the clock is armed (the HUD shows a placeholder).
function M.current(state, elapsed)
    if not state or not state.started then
        return nil
    end
    return elapsed - state.lap_start
end

return M
