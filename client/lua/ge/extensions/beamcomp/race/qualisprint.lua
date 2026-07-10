-- BeamComp -- rally staged sprint qualifying: per-driver run state machine (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/qualisprint.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Pure timing/state helpers only -- NO engine calls: init.lua owns the actions (teleport to
-- P1, freeze/release, drive, checkpoint detector) and drives this module for the per-driver
-- "spawn-to-P1 -> countdown -> GO" sequence. Keeping it pure makes it trivial to reason about and
-- reload-safe (no engine handles held). ADR-0044 (extends the ADR-0041 quali framework for sprints).
--
-- The server owns the authoritative release cadence (quali.STAGE_* on the server): it tells a client
-- "you're up" (qualiStage), waits STAGE_INTERVAL, then flips the driver to running and releases the next.
-- This module renders the LOCAL per-driver count in that window and reports when the run crosses into GO.

local M = {}

-- Per-driver timing defaults (ADR-0044), mirrored from the server (quali.STAGE_SPAWN / STAGE_COUNTDOWN).
-- The qualiStage payload carries the server's values, which override these; the defaults are the fallback.
M.SPAWN = 3.0      -- settle-at-P1 window (car teleported to P1 + frozen), "get ready", before the count
M.COUNTDOWN = 8.0  -- per-driver 8..1 start count at P1, then GO (Round 3: 8 s, was 5)

-- Start a per-driver run at wall-clock `now` (os.clockhp, like the ADR-0041 self-rendered counts).
-- `spawn` / `countdown` override the defaults from the server qualiStage payload. Returns a run table
-- that M.step advances; init.lua stores it in M.state.quali_run (own car) / M.state.quali_ai_runs[id] (AI).
function M.new_run(now, spawn, countdown)
    return {
        anchor = tonumber(now) or 0,
        spawn = tonumber(spawn) or M.SPAWN,
        countdown = tonumber(countdown) or M.COUNTDOWN,
        launched = false,   -- flips true on the frame M.step first returns stage "go"
        last_count = nil,   -- last whole-second shown, so the caller beeps once per number
    }
end

-- Advance a run at wall-clock `now`. Returns a status table:
--   stage     = "spawn" (at P1, settling, stay frozen) | "count" (numeric countdown) | "go" (launch/racing)
--   remaining = seconds left in the current stage (spawn / count); nil for "go"
--   count     = the whole-second number to show + beep during "count" (5..1); nil otherwise
--   launch    = true only on the single frame the run first reaches "go" -- the caller releases the car then
-- Pure: the only mutation is latching run.launched so `launch` fires exactly once.
function M.step(run, now)
    if type(run) ~= "table" then
        return {stage = "spawn", remaining = 0}
    end
    local elapsed = (tonumber(now) or 0) - (run.anchor or 0)
    if elapsed < run.spawn then
        return {stage = "spawn", remaining = run.spawn - elapsed}
    end
    local count_elapsed = elapsed - run.spawn
    if count_elapsed < run.countdown then
        local remaining = run.countdown - count_elapsed
        return {stage = "count", remaining = remaining, count = math.max(1, math.ceil(remaining))}
    end
    local launch = not run.launched
    run.launched = true
    return {stage = "go", launch = launch}
end

return M
