-- BeamComp -- client-side qualifying sector-split delta (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/sectors.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless module: the per-lap sector-tracking progress lives in the caller's
-- reload-surviving M.state (init.lua) and is stepped here one crossing at a time.
--
-- Qualifying only (ADR-0041). Each checkpoint crossing closes a "sector" -- the segment from the
-- previous checkpoint to this one (ADR-0010 detector; each CP is a sector boundary). The live sector
-- time is the difference of consecutive crossing `elapsed` times, which reproduces the analysis
-- overlay's per-lap sections exactly (splits[k] - splits[k-1]; ADR-0015/0030) -- same source, same
-- subtraction. The tracker also keeps the current lap's cumulative time and a per-sector personal best.
-- The HUD reads these to show, on each crossing:
--   * a cumulative delta vs your FASTEST LAP (personal_reference sections), and
--   * the just-completed sector's split time + a per-segment delta vs your PER-SECTOR personal best,
--     record-coloured purple (session best across the field) / green (your personal best) / normal.
-- The session best per sector comes from the standings broadcast `splits` (ADR-0015), so every client
-- derives the same numbers with no server change and no persistence (all session-live).

local M = {}

-- Per-lap section arrays from a cumulative splits array (ADR-0015/0030): lap l section s =
-- splits[(l-1)*cps + s] - splits[(l-1)*cps + s - 1], total = splits[l*cps] - splits[(l-1)*cps]. Only
-- fully-completed laps are returned (a partial current lap is dropped). `run_up` (optional, circuit;
-- ADR-0022) is the gun -> start/finish-line time baked into lap 1: subtracted from lap 1's first
-- section (and only lap 1) so every lap reads as a clean line-to-line lap. Mirrors init.lua's
-- laps_from_splits and the server's twin (server/main.lua) -- kept a local copy so all sector math
-- lives in this one module (the codebase already mirrors this derivation client <-> server).
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

-- A fresh sector tracker for a circuit qualifying session. `cps` is the number of checkpoints per lap
-- (the sector count). Held in the caller's reload-surviving M.state; all fields are plain serializable
-- values.
function M.new(cps)
    return {
        cps = cps,            -- checkpoints per lap == sectors per lap (ADR-0013 circuit plan)
        prev_time = nil,      -- detector `elapsed` at the previous scored crossing, or nil before the first
        lap_start = nil,      -- detector `elapsed` at the start of the current lap (its sector-1 base)
        seq = 0,              -- monotonic count of completed sectors this session
        personal_best = {},   -- [sector] = the fastest split seen for that sector across the session
        last = nil,           -- the just-completed sector, see M.on_crossing, or nil
    }
end

-- Record a scored crossing at 0-based plan ordinal `crossing_seq` and detector time `time`. Computes
-- the just-completed sector into `state.last`:
--   sector               -- its 1-based index within the lap,
--   split                -- its time (this crossing's elapsed minus the previous crossing's),
--   lap_cumulative       -- the current lap's elapsed through this crossing (line-relative, clean),
--   prev_personal_best   -- the fastest split for this sector BEFORE this crossing (nil the first time),
-- and folds `split` into the running per-sector personal best. `run_up` (circuit; ADR-0022) is used
-- only as the base for the very first crossing, so lap 1's first sector reads clean line-to-line (lap
-- 1's real start is the start/finish line, behind the grid). No-op on a degenerate tracker / bad time.
function M.on_crossing(state, crossing_seq, time, run_up)
    if not state or not state.cps or state.cps < 1 or type(time) ~= "number" then
        return
    end
    local base
    if state.prev_time ~= nil then
        base = state.prev_time
    elseif type(run_up) == "number" then
        base = run_up
    else
        base = 0
    end
    local sector = (crossing_seq % state.cps) + 1
    -- Sector 1 opens a new lap, so its base is the lap start (the previous CP0 crossing, or run_up/0 for
    -- lap 1); later sectors keep that lap start for the cumulative time.
    if sector == 1 then
        state.lap_start = base
    end
    local split = time - base
    local prev_pb = state.personal_best[sector]
    if prev_pb == nil or split < prev_pb then
        state.personal_best[sector] = split
    end
    state.last = {
        sector = sector,
        split = split,
        lap_cumulative = time - (state.lap_start or base),
        prev_personal_best = prev_pb,
    }
    state.seq = state.seq + 1
    state.prev_time = time
end

-- The personal reference sectors: the per-section times of the fastest completed lap in `splits`
-- (ADR-0022 fastest-lap), used for the cumulative delta. Returns a 1-based array of section times, or
-- nil when no lap is complete yet.
function M.personal_reference(splits, run_up, cps)
    local best = nil
    for _, lap in ipairs(laps_from_splits(splits, cps, run_up)) do
        if type(lap.total) == "number" and (best == nil or lap.total < best.total) then
            best = lap
        end
    end
    return best and best.sections or nil
end

-- The session-best reference sectors: the fastest time seen for each sector index across ALL drivers'
-- completed laps this session (ADR-0015 broadcast splits). `entries` is the standings list, each entry
-- carrying `.splits` and `.run_up`. Returns a 1-based array where [s] is the minimum sector-s time over
-- every driver and lap (nil for sectors nobody has completed), or nil when the field has no completed
-- lap at all.
function M.session_reference(entries, cps)
    if type(cps) ~= "number" or cps < 1 then
        return nil
    end
    local best = {}
    local has_any = false
    for _, entry in ipairs(entries or {}) do
        for _, lap in ipairs(laps_from_splits(entry.splits, cps, entry.run_up)) do
            for s = 1, cps do
                local value = lap.sections[s]
                if type(value) == "number" and (best[s] == nil or value < best[s]) then
                    best[s] = value
                    has_any = true
                end
            end
        end
    end
    return has_any and best or nil
end

-- Cumulative time through `sector` of a per-section array (sum of sections 1..sector), or nil when any
-- needed section is missing. Used to diff the current lap's cumulative against the fastest lap's.
function M.cumulative_through(sections, sector)
    if type(sections) ~= "table" then
        return nil
    end
    local total = 0
    for s = 1, sector do
        if type(sections[s]) ~= "number" then
            return nil
        end
        total = total + sections[s]
    end
    return total
end

-- The motorsport record class for a just-completed sector `split`: "session" (purple) when it is the
-- fastest that sector by anyone (<= the field's known best, which excludes this fresh split), else
-- "personal" (green) when it is your own best for that sector (the first time counts, or it beat your
-- prior best), else "normal". `session_best` / `prev_personal_best` may be nil (no data yet).
function M.record_class(split, prev_personal_best, session_best)
    if type(split) ~= "number" then
        return "normal"
    end
    if type(session_best) == "number" and split <= session_best then
        return "session"
    end
    if prev_personal_best == nil or split <= prev_personal_best then
        return "personal"
    end
    return "normal"
end

return M
