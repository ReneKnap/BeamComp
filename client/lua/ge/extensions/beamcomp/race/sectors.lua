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
--   * a cumulative delta vs your FASTEST LAP (personal_reference sections),
--   * the just-completed sector's split time + a per-segment delta vs your PER-SECTOR personal best,
--     record-coloured purple (session best across the field) / green (your personal best) / yellow
--     (slower, <= OFF_THRESHOLD x your best) / red ("off", beyond it) / grey (no reference), and
--   * the bottom progress bar: every sector of the current lap/run in the same colours, re-evaluated
--     per HUD push so a purple degrades live (M.run_states).
-- The session best per sector comes from the standings broadcast `splits` (ADR-0015) on a circuit; a
-- staged sprint reads the server-relayed field bests (`sectorBests` + `sectorCounts`, ADR-0044)
-- instead. Both fold every crossing -- including the own one, once relayed back -- so classification
-- anchors on the references frozen AT crossing time; the live field best applies when strictly
-- faster (round 3), and once a SECOND scoring of the sector exists a still-fastest no-reference
-- split upgrades to purple live (round 4) -- but the first-ever time alone stays plain white, never
-- a record against itself (effective_session_best). No persistence (all session-live).

local M = {}

-- Record-class threshold (feature quali-sector-progress-bar): a split MORE than 16 % over the
-- driver's per-sector personal best classifies "off" (red) instead of "slower" (yellow). Exactly
-- 1.16 x PB is still "slower".
M.OFF_THRESHOLD = 1.16

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
        run = {},             -- [sector] = {split, prev_personal_best} of the CURRENT lap/run (feature
                              -- quali-sector-progress-bar): the reference frozen at crossing time, so
                              -- M.run_states can re-classify live against a moving session best
    }
end

-- Reset the per-run progress of a tracker for a new run, keeping the accumulated per-sector personal best
-- (Round 6, staged sprint quali). A circuit quali laps one continuous detector, so a tracker lives one
-- run; a staged sprint re-arms a fresh detector on every launch (crossing_seq restarts at 0, detector time
-- restarts at 0), so the sector splits must base from 0 again -- but `personal_best` (and thus the record
-- colouring vs your own sector bests) is kept across the driver's runs. No-op on a nil tracker.
function M.reset_run(state)
    if not state then
        return
    end
    state.prev_time = nil
    state.lap_start = nil
    state.seq = 0
    state.last = nil
    state.run = {}
end

-- Record a scored crossing at 0-based plan ordinal `crossing_seq` and detector time `time`. Computes
-- the just-completed sector into `state.last`:
--   sector               -- its 1-based index within the lap,
--   split                -- its time (this crossing's elapsed minus the previous crossing's),
--   lap_cumulative       -- the current lap's elapsed through this crossing (line-relative, clean),
--   prev_personal_best   -- the fastest split for this sector BEFORE this crossing (nil the first time),
--   prev_session_best    -- the field's best for this sector BEFORE this crossing (round 3): frozen
--                           from `session_reference` (the caller's current view), which cannot yet
--                           contain THIS split -- the crossing is recorded synchronously before its
--                           report is even sent, so no relay/row round-trip can leak it in. nil when
--                           nobody (own earlier laps/runs included) has set a time for this sector.
-- and folds `split` into the running per-sector personal best. `run_up` (circuit; ADR-0022) is used
-- only as the base for the very first crossing, so lap 1's first sector reads clean line-to-line (lap
-- 1's real start is the start/finish line, behind the grid). No-op on a degenerate tracker / bad time.
function M.on_crossing(state, crossing_seq, time, run_up, session_reference)
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
    -- lap 1); later sectors keep that lap start for the cumulative time. The per-lap sector statuses
    -- (the progress bar) reset with it -- the previous lap stays visible until the new lap's first
    -- sector completes (feature quali-sector-progress-bar, decision 3/4).
    if sector == 1 then
        state.lap_start = base
        state.run = {}
    end
    local split = time - base
    local prev_pb = state.personal_best[sector]
    if prev_pb == nil or split < prev_pb then
        state.personal_best[sector] = split
    end
    local prev_sb = session_reference and session_reference[sector] or nil
    if type(prev_sb) ~= "number" then
        prev_sb = nil
    end
    state.run = state.run or {}  -- tolerate a tracker that survived a hot reload of an older shape
    state.run[sector] = {split = split, prev_personal_best = prev_pb, prev_session_best = prev_sb}
    state.last = {
        sector = sector,
        split = split,
        lap_cumulative = time - (state.lap_start or base),
        prev_personal_best = prev_pb,
        prev_session_best = prev_sb,
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
-- crossings this session (ADR-0015 broadcast splits). Folded per crossing -- partial laps included --
-- so a rival bettering a sector mid-lap degrades a purple the moment their crossing is broadcast
-- (feature quali-sector-progress-bar; previously only completed laps counted). The per-crossing
-- subtraction reproduces laps_from_splits' sections exactly: crossing i closes sector ((i-1) % cps)+1,
-- based on the previous crossing (run_up/0 for the very first, ADR-0022's clean lap-1). `entries` is
-- the standings list, each entry carrying `.splits` and `.run_up`. Returns TWO values (r4): a 1-based
-- array where [s] is the minimum sector-s time over every driver and lap (nil for sectors nobody has
-- completed; the whole array nil when nobody has crossed anything yet), and the companion counter
-- array where [s] is how many valid crossings folded into sector s -- the circuit-side twin of the
-- staged `sectorCounts` relay, feeding the white->purple upgrade branch (effective_session_best).
function M.session_reference(entries, cps)
    if type(cps) ~= "number" or cps < 1 then
        return nil
    end
    local best = {}
    local counts = {}
    local has_any = false
    for _, entry in ipairs(entries or {}) do
        local splits = entry.splits
        if type(splits) == "table" then
            for i = 1, #splits do
                local previous = (i == 1)
                    and (type(entry.run_up) == "number" and entry.run_up or 0)
                    or splits[i - 1]
                local cumulative = splits[i]
                if type(cumulative) ~= "number" or type(previous) ~= "number" then
                    break  -- broken cumulative chain; later diffs would be garbage
                end
                local s = ((i - 1) % cps) + 1
                local value = cumulative - previous
                counts[s] = (counts[s] or 0) + 1
                if best[s] == nil or value < best[s] then
                    best[s] = value
                    has_any = true
                end
            end
        end
    end
    return has_any and best or nil, counts
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

-- The motorsport record class for a just-completed sector `split`, checked best-first: "session"
-- (purple) when it is the fastest that sector by anyone (<= the field's known best, which excludes this
-- fresh split) -- possible even on your first run through the sector; else "personal" (green) when it
-- matched/beat your own best for that sector; else "slower" (yellow) when it is at most
-- OFF_THRESHOLD x your best; else "off" (red, clearly off the pace). The session-best check runs
-- before the first-run guard, so beating the field is purple even without a personal reference yet.
-- "normal" only when there is nothing to compare against -- the split is not a number, or there is no
-- session best to beat and no personal reference yet (your first time through this sector).
-- `session_best` / `prev_personal_best` may be nil (no data yet).
function M.record_class(split, prev_personal_best, session_best)
    if type(split) ~= "number" then
        return "normal"
    end
    if type(session_best) == "number" and split <= session_best then
        return "session"
    end
    if prev_personal_best == nil then
        return "normal"
    end
    if split <= prev_personal_best then
        return "personal"
    end
    if split > prev_personal_best * M.OFF_THRESHOLD then
        return "off"
    end
    return "slower"
end

-- The session reference a stored split is re-evaluated against on a HUD push (round 3, upgrade
-- branch round 4). Three branches, first match wins:
--   1. The CURRENT field best STRICTLY beats the stored split -- someone genuinely undercut it, so
--      the purple falls (and a no-reference sector goes back to white via record_class).
--   2. At least one FURTHER scoring of this sector exists (`session_count_now >= 2` -- the stored
--      split's own fold is one of them) and nobody is strictly faster -- the split IS the field
--      best against real competition, so it upgrades to purple live (an exact tie counts as still
--      fastest, consistent with 3.2). A solo first-ever time stays white: its own relay makes
--      count 1, so the round-3 self-purple bug cannot return by construction.
--   3. Otherwise the reference frozen at crossing time stands, so a class can never be won or lost
--      against the split itself.
-- This is the one seam the bar (run_states) and the centred readout share, per the round-3
-- contract: the readout must never show purple where the bar is white.
function M.effective_session_best(split, prev_session_best, session_best_now, session_count_now)
    if type(split) ~= "number" then
        return prev_session_best
    end
    if type(session_best_now) == "number" and session_best_now < split then
        return session_best_now
    end
    if type(session_count_now) == "number" and session_count_now >= 2 then
        return split
    end
    return prev_session_best
end

-- The record class of every sector of the current lap/run, for the bottom progress bar (feature
-- quali-sector-progress-bar): a dense 1..cps array of class strings -- "none" for sectors not driven
-- this lap/run (grey segment), else record_class re-evaluated NOW while both references stay
-- anchored at crossing time: the personal best as frozen then, and the session best through
-- effective_session_best (round 3, upgrade branch round 4) -- the live field best applies when
-- strictly faster (degradation), a second scoring of the sector upgrades a still-fastest white to
-- purple (`session_counts`, round 4), and the own relayed-back split alone can never turn itself
-- purple. A DRIVEN sector without any comparison keeps record_class's "normal" (white segment,
-- round 2) -- visibly distinct from undriven grey. nil on a degenerate tracker.
function M.run_states(state, session_reference, session_counts)
    if not state or not state.cps or state.cps < 1 then
        return nil
    end
    local run = state.run or {}
    local states = {}
    for s = 1, state.cps do
        local crossed = run[s]
        if crossed then
            local session_best = M.effective_session_best(crossed.split,
                crossed.prev_session_best, session_reference and session_reference[s] or nil,
                session_counts and session_counts[s] or nil)
            states[s] = M.record_class(crossed.split, crossed.prev_personal_best, session_best)
        else
            states[s] = "none"
        end
    end
    return states
end

return M
