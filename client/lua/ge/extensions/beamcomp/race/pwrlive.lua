-- BeamComp -- the live power-to-weight the pwr start order sorts by (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/pwrlive.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Pure: no engine call and no M.state of its own. init.lua keeps one state table per race
-- (M.state.pwr_check, built by M.new) and does everything engine-facing itself (its `pwr` glue): it sends
-- the reports and the requests, hands this module the VE's answers and writes the lines built here.
--
-- order=pwr sorts the grid once, on the server, at the staging -> countdown seam, by the last pwr each car
-- reported (ADR-0033). A preset's metadata never sees a parts or tuning change, so every car this client
-- reports (its own race car and, on the race owner, every AI car) is measured live with the vehicle limit's
-- own reading: live power, tuning included, over the weight with every fuel tank full and nobody on board
-- (ADR-0032 amendments 2026-11-04 and 2026-11-08, ADR-0033 amendment 2026-11-11). A measurement
--   1. starts from the clientInfo just sent with the metadata pwr, the STAND-IN: what stands when no live
--      value comes (a timeout, an older vehicle extension, a broken read, an answer after the grid was set),
--      with a W line naming the car and the reason;
--   2. ends, when the answer lands while the grid can still change, in that same report sent again with only
--      its pwr replaced, so the server's rebuild of the record keeps the vehicle and the footprint.
--
-- The request and the answer are the vehicle limit's (vehicles.request_live_spec -> VE measure_spec ->
-- beamcomp_init.on_live_spec), told apart by token: these are negative, the limit's never are. Each car's
-- pending measurement is a capcheck measurement state, so both run on one clock (resends, give-up, clamped
-- sim time, the race-start settle).

local M = {}

local capcheck = require("beamcomp/race/capcheck")

-- The phases of a race in which a report can still move its grid. The first phase past them (the countdown,
-- or anything later) means the order is set for the rest of the race.
local GRID_OPEN_PHASES = {lobby = true, spawning = true, staging = true}

-- A fresh state for one race, built at its raceStart: the grid is open then, whatever phase the previous race
-- left behind (an abort-restart goes finished -> spawning, so the phase can still read finished there).
-- `token_seed` (a non-negative integer, from the clock) starts the numbering below zero and counts down, so
-- an answer to the previous race's last request can never carry a token this race is waiting for.
function M.new(token_seed)
    return {
        next_token = -1 - math.max(math.floor(tonumber(token_seed) or 0), 0),
        cars = {},           -- tostring(vehicle id) -> its stand-in report, setup and pending measurement
        reload_due = false,  -- the race car was respawned or reset; init.lua looks at it next frame
        grid_set = false,    -- this race's phase has moved past staging: no report moves the grid any more
    }
end

-- Whether a VE answer carrying `token` belongs here rather than to the vehicle limit check.
function M.owns_token(token)
    return type(token) == "number" and token < 0
end

-- Note a phase this race entered (this client's view of the server's phase). Past staging the grid is set,
-- and it stays set: the order is sorted once per race.
function M.note_phase(state, phase)
    if not GRID_OPEN_PHASES[phase] then
        state.grid_set = true
    end
end

-- Whether a report sent now can still move this race's grid.
function M.grid_open(state)
    return not state.grid_set
end

-- Start measuring vehicle `veh_id` for the stand-in `report`, replacing whatever it had pending. `purpose`
-- names the trigger in the log ("start" waits capcheck.START_SETTLE first, like the limit's race-start
-- measurement), `fingerprint` is the setup measured (nil for an AI car), `label` the car's name for the log.
-- Returns the token.
function M.begin(state, veh_id, purpose, report, fingerprint, label)
    local token = state.next_token
    state.next_token = token - 1
    local check = capcheck.new(token)
    capcheck.begin(check, veh_id, purpose, nil, fingerprint)
    state.cars[tostring(veh_id)] = {
        veh_id = veh_id,
        purpose = purpose,
        report = report,
        fingerprint = fingerprint,
        label = label,
        check = check,
    }
    return token
end

-- Forget vehicle `veh_id`: a replace put another car on that id, and its restage measures that one.
function M.cancel(state, veh_id)
    state.cars[tostring(veh_id)] = nil
end

-- Advance every pending measurement by one frame. Returns the requests due now (first ones and resends) as
-- a list of {veh_id, token}.
function M.step(state, dt)
    local due = {}
    for _, car in pairs(state.cars) do
        local token = car.check and capcheck.step(car.check, dt)
        if token then
            due[#due + 1] = {veh_id = car.veh_id, token = token}
        end
    end
    return due
end

-- Record a VE answer. Accepted only for the measurement it answers (same vehicle, same token); anything else
-- answers a request that was replaced, cancelled, given up or belongs to an earlier race. Returns whether
-- it was accepted.
function M.on_answer(state, veh_id, token, reading)
    local car = state.cars[tostring(veh_id)]
    return car ~= nil and car.check ~= nil and capcheck.on_answer(car.check, veh_id, token, reading)
end

-- The measurements that finished since the last call (answered or given up), each taken off its car, as a
-- list of {car, reading}. The car keeps its report and setup for the next reload.
function M.take_finished(state)
    local finished = {}
    for _, car in pairs(state.cars) do
        local taken = car.check and capcheck.take(car.check)
        if taken then
            car.check = nil
            finished[#finished + 1] = {car = car, reading = taken.reading}
        end
    end
    return finished
end

-- Whether a reload of vehicle `veh_id` showing setup `fingerprint` is a parts or tuning change against the
-- setup last reported for it. An unreadable fingerprint, or a car nothing was reported for, counts as one.
function M.setup_changed(state, veh_id, fingerprint)
    local car = state.cars[tostring(veh_id)]
    return fingerprint == nil or car == nil or not capcheck.same(fingerprint, car.fingerprint)
end

-- The power-to-weight (hp/kg) out of a reading (capcheck.reading_from_answer), or nil plus why not. The plain
-- ratio: the vehicle limit's WEIGHT_STEP_KG is a tolerance on a bound, and a sort has none.
function M.pwr_of(reading)
    reading = reading or {}
    local power, weight = reading.power, reading.weight
    local has_power = type(power) == "number" and power > 0
    if has_power and type(weight) == "number" and weight > 0 then
        return power / weight
    end
    return nil, reading.reason or (has_power and "no live weight" or "no live power")
end

-- The stand-in `report` with its pwr replaced by the live one. A copy: the stand-in stays what was sent.
function M.live_report(report, pwr)
    local live = {}
    for key, value in pairs(report or {}) do
        live[key] = value
    end
    live.pwr = pwr
    return live
end

local function ratio(pwr)
    if type(pwr) ~= "number" then
        return "n/a"
    end
    return string.format("%.4f hp/kg", pwr)
end

-- "pwr for 'etk800:custom' (config)", an AI car with its id in front: "pwr for ai:2 'pessima:base' (spawn)".
local function subject(label, purpose, report)
    local ai_id = type(report) == "table" and report.aiId or nil
    return string.format("pwr for %s'%s' (%s)", ai_id ~= nil and (tostring(ai_id) .. " ") or "",
        tostring(label), tostring(purpose))
end

-- What the server keeps when no live value replaces the stand-in.
local function standing(report)
    local listed = type(report) == "table" and report.pwr or nil
    if type(listed) ~= "number" then
        return "no listed value either, the car sorts to the back"
    end
    return "the listed " .. ratio(listed) .. " stands"
end

-- The I line of a live report: the live value with what it is made of, beside the stand-in it replaces.
function M.describe_live(car, reading, pwr)
    return string.format("%s: live %s (%d hp / %d kg), listed %s; reported",
        subject(car.label, car.purpose, car.report), ratio(pwr), math.floor(reading.power + 0.5),
        math.floor(reading.weight + 0.5), ratio(car.report and car.report.pwr))
end

-- The W line when no live value came: the reason, and what stands instead.
function M.describe_fallback(car, why)
    return string.format("%s: no live reading (%s); %s", subject(car.label, car.purpose, car.report),
        tostring(why), standing(car.report))
end

-- The W line when the live value came after the grid was set: it is not reported.
function M.describe_late(car, pwr, phase)
    return string.format("%s: the live %s came in %s, after the grid was set; %s",
        subject(car.label, car.purpose, car.report), ratio(pwr), tostring(phase), standing(car.report))
end

-- The I line when a car is not measured at all because the grid is already set.
function M.describe_unmeasured(label, purpose, report, phase)
    return string.format("%s: not measured, the grid is already set (%s)", subject(label, purpose, report),
        tostring(phase))
end

return M
