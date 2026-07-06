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
-- subtraction. The HUD diffs that live time against a reference sector, both derived here:
--   personal -- the sector times of the local player's fastest completed lap this session.
--   session  -- the fastest time seen for each sector across every driver's completed laps.
-- Both references come from the standings broadcast `splits` (ADR-0015), so every client derives the
-- same numbers with no server change and no records/persistence (the reference is session-live).

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
        cps = cps,       -- checkpoints per lap == sectors per lap (ADR-0013 circuit plan)
        prev_time = nil, -- detector `elapsed` at the previous scored crossing, or nil before the first
        seq = 0,         -- monotonic count of completed sectors this session; the HUD's fresh-crossing key
        last = nil,      -- the just-completed sector {sector, time} (1-based sector-in-lap index), or nil
    }
end

-- Record a scored crossing at 0-based plan ordinal `crossing_seq` and detector time `time`. Computes
-- the just-completed sector (its 1-based index within the lap and its time) into `state.last` and bumps
-- `state.seq` so the HUD can tell a fresh crossing from a repeated snapshot. `run_up` (circuit;
-- ADR-0022) is used only as the base for the very first crossing, so lap 1's first sector reads clean
-- line-to-line (lap 1's real start is the start/finish line, behind the grid). No-op on a degenerate
-- tracker or a non-numeric time.
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
    state.last = {sector = (crossing_seq % state.cps) + 1, time = time - base}
    state.seq = state.seq + 1
    state.prev_time = time
end

-- The personal reference sectors: the per-section times of the fastest completed lap in `splits`
-- (ADR-0022 fastest-lap). Returns a 1-based array of section times, or nil when no lap is complete yet.
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

return M
