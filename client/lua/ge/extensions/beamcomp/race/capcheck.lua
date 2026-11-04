-- BeamComp -- the vehicle limit check of the player's own race car (GE side).
--
-- Lives at lua/ge/extensions/beamcomp/race/capcheck.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Pure: no engine call and no M.state of its own. init.lua keeps one state table per race
-- (M.state.caps_check, built by M.new) and does everything engine-facing itself (its `caps` glue): it
-- sends the requests this module asks for, hands it the answers and carries out its decisions.
--
-- Under a Mode-3 limit (maxhp / maxpwr / minkg / maxkg, ADR-0032) every check reads the car as it really
-- is: the VE extension measures power and weight the way the engine generated the shipped metadata
-- (lua/vehicle/extensions/beamcomp/init.lua read_live_spec). The metadata itself describes the preset a car
-- was spawned from and never sees a parts or tuning change (ADR-0032 amendment 2026-11-04). Three purposes
-- arm a measurement:
--   start  -- the own car kept at race start (race/vehicles.lua respawn_for_cap keeps it for now);
--   swap   -- a staging car swap, at the restage once the new jbeam has loaded;
--   config -- a parts or tuning respawn of the race car, told apart from a plain reset by its setup
--             fingerprint.
-- A reading that cannot answer what the limit needs counts as over the limit (user decision 2026-11-04).
--
-- Two loop guards, both needed because "no answer = over" would otherwise cycle on a broken read: our own
-- car replace rides init.lua's one-cycle revert skip (revert_pending), and after our own setup revert the
-- next reload that is neither the snapshot nor the rejected setup is adopted without a check ("own").

local M = {}

local vehiclespecs = require("beamcomp/race/vehiclespecs")

-- One measurement's clock, in seconds of sim time clamped per frame (M.step): the request goes out after
-- `send_after`, again every RESEND_AFTER up to MAX_SENDS times, and is given up GIVE_UP_AFTER after the first
-- send. Clamped sim time, because a respawn stalls the game for about 2 s while it loads the jbeam and a
-- paused game runs no VE: neither may count as the vehicle not answering.
M.RESEND_AFTER = 1.0
M.MAX_SENDS = 3
M.GIVE_UP_AFTER = 4.0
M.DT_CLAMP = 0.1

-- The race-start measurement waits this long before its first request, so the keep-own repair at race start
-- (setPositionRotation) has reset the car first; a damaged engine reads lower power.
M.START_SETTLE = 0.5

-- How long our own setup revert may take to raise its reload before the car is looked at again.
M.OWN_RESPAWN_WAIT = 10.0

-- The phases in which a start or config verdict is carried out. Earlier (the raceStart window and spawning)
-- the verdict waits: a car replace only goes through the restage pipeline under the staging lock, and a
-- respawn before staging would lose the freeze nothing re-asserts there.
M.ACTING_PHASES = {staging = true, countdown = true, racing = true, qualifying = true, qualiResults = true}

-- Config keys that change neither power nor weight. Everything else is part of the setup fingerprint -- a
-- blacklist on purpose, so a key this file has never heard of is measured rather than waved through.
local SETUP_IGNORED_KEYS = {
    paints = true,
    licenseName = true,
    partConfigFilename = true,
    additionalVehicleData = true,
    format = true,
}

-- A fresh state for one race. `token_seed` starts the request numbering; the caller seeds it from the clock
-- so a late answer to the previous race can never carry a token this race is waiting for.
function M.new(token_seed)
    return {
        snapshot = nil,      -- the last setup within the limit: {spec, fingerprint}, the revert target
        pending = nil,       -- the one measurement in flight or finished and not yet taken
        own_respawn = nil,   -- our setup revert, until its reload lands: {rejected, wait}
        reload_due = false,  -- the race car was respawned or reset; init.lua looks at it next frame
        next_token = token_seed or 1,
    }
end

-- Start measuring vehicle `veh_id` for `purpose`, replacing whatever was pending. `spec` and `fingerprint`
-- describe the setup measured: a verdict within the limit makes exactly that setup the new snapshot, so a
-- change made while the answer is on its way is measured again instead of slipping in with it.
function M.begin(state, veh_id, purpose, spec, fingerprint)
    local token = state.next_token
    state.next_token = token + 1
    state.pending = {
        token = token,
        veh_id = veh_id,
        purpose = purpose,
        spec = spec,
        fingerprint = fingerprint,
        send_after = purpose == "start" and M.START_SETTLE or 0,
        elapsed = 0,
        sends = 0,
        done = false,
        reading = nil,
    }
    return token
end

-- Drop the pending measurement and any revert we were waiting on: the car was replaced, so neither is about
-- the car standing there any more.
function M.cancel(state)
    state.pending = nil
    state.own_respawn = nil
end

local function clamped(dt)
    return math.min(math.max(dt or 0, 0), M.DT_CLAMP)
end

-- Advance the pending measurement by one frame. Returns the token to send now (first request or a resend),
-- else nil. Past GIVE_UP_AFTER the measurement finishes with a reading that carries no values.
function M.step(state, dt)
    local pending = state.pending
    if not pending or pending.done then
        return nil
    end
    pending.elapsed = pending.elapsed + clamped(dt)
    local since_first = pending.elapsed - pending.send_after
    if since_first < 0 then
        return nil
    end
    if pending.sends < M.MAX_SENDS and since_first >= pending.sends * M.RESEND_AFTER then
        pending.sends = pending.sends + 1
        return pending.token
    end
    if since_first >= M.GIVE_UP_AFTER then
        pending.done = true
        pending.reading = {
            engines = 0,
            reason = string.format("no answer from the vehicle after %d requests", pending.sends),
        }
    end
    return nil
end

-- Record a VE answer. Accepted only for the pending request it answers (same vehicle and token); anything
-- else is a late answer to a request that was replaced or given up. Returns whether it was accepted.
function M.on_answer(state, veh_id, token, reading)
    local pending = state.pending
    if not pending or pending.done or pending.token ~= token
            or tostring(pending.veh_id) ~= tostring(veh_id) then
        return false
    end
    pending.done = true
    pending.reading = reading
    return true
end

-- The pending measurement once it has an answer (or gave up), still in place; nil while it is out.
function M.finished(state)
    local pending = state.pending
    if pending and pending.done then
        return pending
    end
    return nil
end

-- The finished measurement, removed from the state; nil while it is still out.
function M.take(state)
    local pending = M.finished(state)
    if pending then
        state.pending = nil
    end
    return pending
end

-- Whether `reading` is within `caps`, plus which value the caps needed and the reading lacks ("power" or
-- "weight") when that is what failed it. A missing value is over the limit, never a pass: the user chose
-- this over a metadata fallback knowing that a read broken by a game update fails every capped driver, which
-- is why init.lua logs it at W every time.
function M.verdict(reading, caps)
    reading = reading or {}
    local range = vehiclespecs.weight_range(caps.minkg, caps.maxkg)
    local compliant = vehiclespecs.is_compliant(reading.power, reading.weight, caps.maxhp, caps.maxpwr,
        nil, range)
    if compliant then
        return true, nil
    end
    local needs_power = caps.maxhp ~= nil or caps.maxpwr ~= nil
    local needs_weight = caps.maxpwr ~= nil or range ~= nil
    if needs_power and type(reading.power) ~= "number" then
        return false, "power"
    end
    if needs_weight and type(reading.weight) ~= "number" then
        return false, "weight"
    end
    return false, nil
end

-- The part of a car's setup that decides power and weight: every key but paint, plate and file
-- bookkeeping. `setup` must be this client's own copy of the config (vehicles.capture_setup), never the
-- engine's live table -- the engine merges the next change into that one before it respawns, and the
-- fingerprint shares the copy's sub-tables. nil when there is no setup to read.
function M.fingerprint(setup)
    if type(setup) ~= "table" then
        return nil
    end
    local fingerprint = {}
    for key, value in pairs(setup) do
        if not SETUP_IGNORED_KEYS[key] then
            fingerprint[key] = value
        end
    end
    return fingerprint
end

-- Relative difference below which two numbers are the same setting. A respawn hands the engine
-- serialize(config), which writes numbers with %.10g (lua/common/utils.lua serialize_rec), so a preset's
-- tuning value read from its .pc at full precision comes back 10 digits long after a paint respawn.
local SAME_NUMBER_TOLERANCE = 1e-9

local function same_number(a, b)
    return a == b or math.abs(a - b) <= SAME_NUMBER_TOLERANCE * math.max(math.abs(a), math.abs(b))
end

-- Deep equality of two fingerprints (or of any two plain values), numbers to the engine's own precision.
function M.same(a, b)
    if type(a) == "number" and type(b) == "number" then
        return same_number(a, b)
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not M.same(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- The top-level keys in which two fingerprints differ, sorted, for the log ("partsTree", "vars").
function M.changed_keys(a, b)
    a, b = a or {}, b or {}
    local keys = {}
    for key, value in pairs(a) do
        if not M.same(value, b[key]) then
            keys[#keys + 1] = tostring(key)
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            keys[#keys + 1] = tostring(key)
        end
    end
    table.sort(keys)
    return keys
end

-- What a reload of the race car means for the check, from its live setup fingerprint:
--   pending_same    the setup a measurement is already out for (a duplicate event, a teleport)
--   pending_changed a measurement is out but the setup moved on: measure again
--   restaging       a car replace is being re-staged; its gate measures the car as it then is, and a start
--                   or config measurement still out is dropped when the restage takes the replace
--   unchanged       the last setup within the limit (a reset, a repair, a paint change, our revert landing)
--   not_landed      still the setup our revert rejected; the revert raises its own reload when it lands
--   own             our revert landed as a setup that does not compare equal (a normalised round trip):
--                   adopted without a check, so a broken read cannot cycle
--   changed         anything else: measure it
-- An unreadable fingerprint (nil) never compares equal, so it is measured.
function M.classify_reload(state, fingerprint, restaging)
    local readable = fingerprint ~= nil
    local pending = state.pending
    if pending and (pending.purpose == "swap" or not restaging) then
        if readable and M.same(fingerprint, pending.fingerprint) then
            return "pending_same"
        end
        return "pending_changed"
    end
    if restaging then
        return "restaging"
    end
    local snapshot = state.snapshot
    if readable and snapshot and M.same(fingerprint, snapshot.fingerprint) then
        return "unchanged"
    end
    local own = state.own_respawn
    if own then
        if readable and M.same(fingerprint, own.rejected) then
            return "not_landed"
        end
        return "own"
    end
    return "changed"
end

-- Make `spec` / `fingerprint` the setup a later over-limit verdict goes back to.
function M.remember(state, spec, fingerprint)
    state.snapshot = {spec = spec, fingerprint = fingerprint}
end

-- Our setup revert is on its way. `rejected` is the fingerprint it replaces, so a reload that still shows
-- it is recognised as the revert not having landed yet.
function M.expect_own_respawn(state, rejected)
    state.own_respawn = {rejected = rejected, wait = M.OWN_RESPAWN_WAIT}
end

-- Whether our setup revert is still to land. init.lua's re-arm after a reload asks this to skip its
-- throttle: the revert lands inside the throttle window of the player's own respawn and must re-arm too.
function M.awaits_own_respawn(state)
    return state ~= nil and state.own_respawn ~= nil
end

-- Clear the revert we were waiting on. Returns whether one was waiting.
function M.land_own_respawn(state)
    local was_waiting = state.own_respawn ~= nil
    state.own_respawn = nil
    return was_waiting
end

-- Count our revert's wait down. Returns true once, when it ran out (the caller then looks at the car again).
function M.step_own_respawn(state, dt)
    local own = state.own_respawn
    if not own then
        return false
    end
    own.wait = own.wait - clamped(dt)
    if own.wait > 0 then
        return false
    end
    state.own_respawn = nil
    return true
end

-- What to do with a verdict:
--   adopt         within the limit
--   revert_setup  respawn the car in place on the last setup within the limit (same model, any race phase)
--   revert_car    replace the car with the last one within the limit (staging: the swap-allowed lock)
--   substitute    replace it with the first car within the limit (staging, nothing within it known yet)
--   keep          nothing left that could be done: past staging, and no setup to respawn into
function M.decide(purpose, compliant, phase, snapshot, model)
    if compliant then
        return "adopt"
    end
    local spec = snapshot and snapshot.spec
    local can_respawn = spec and (type(spec.setup) == "table" or type(spec.config) == "string")
    if purpose == "config" and can_respawn and spec.model == model then
        return "revert_setup"
    end
    if phase ~= "staging" then
        return "keep"
    end
    if purpose ~= "start" and spec then
        return "revert_car"
    end
    return "substitute"
end

-- English label for the active strict weight range: "1200-1800 kg", "<=1500 kg", or ">=1200 kg".
local function weight_limit_label(caps)
    if caps.minkg and caps.maxkg then
        return string.format("%d-%d kg", math.floor(caps.minkg + 0.5), math.floor(caps.maxkg + 0.5))
    elseif caps.maxkg then
        return string.format("<=%d kg", math.floor(caps.maxkg + 0.5))
    end
    return string.format(">=%d kg", math.floor(caps.minkg + 0.5))
end

-- True when the weight breaks the strict range: an unreadable weight under a set bound fails (cannot verify
-- means blocked, ADR-0032), else a readable weight below minkg or above maxkg fails.
local function breaks_weight_range(weight, caps)
    if not (caps.maxkg or caps.minkg) then
        return false
    end
    if type(weight) ~= "number" then
        return true
    end
    return (caps.minkg and weight < caps.minkg) or (caps.maxkg and weight > caps.maxkg) or false
end

-- Why `name` is over the limit, in the player's words: the first axis that fails, in is_compliant order
-- (max hp, then power-to-weight, then the weight range), e.g. "etk800 has 450 hp, the limit is 300 hp". An
-- unreadable value says that it could not be verified.
function M.limit_detail(name, power, weight, caps)
    local pwr_ok = caps.maxpwr == nil
        or (type(power) == "number" and type(weight) == "number" and weight > 0
            and power / weight <= caps.maxpwr)
    if caps.maxhp and not (type(power) == "number" and power <= caps.maxhp) then
        if type(power) == "number" then
            return string.format("%s has %d hp, the limit is %d hp", name, math.floor(power + 0.5),
                caps.maxhp)
        end
        return string.format("%s: engine power couldn't be verified, the limit is %d hp", name, caps.maxhp)
    end
    if caps.maxpwr and not pwr_ok then
        if type(power) == "number" and type(weight) == "number" and weight > 0 then
            return string.format("%s has %.2f hp/kg, the limit is %.2f hp/kg", name, power / weight,
                caps.maxpwr)
        end
        return string.format("%s: power-to-weight couldn't be verified, the limit is %.2f hp/kg", name,
            caps.maxpwr)
    end
    if breaks_weight_range(weight, caps) then
        if type(weight) == "number" then
            return string.format("%s weighs %d kg, the limit is %s", name, math.floor(weight + 0.5),
                weight_limit_label(caps))
        end
        return string.format("%s: curb weight couldn't be verified, the limit is %s", name,
            weight_limit_label(caps))
    end
    return name .. " exceeds the vehicle limit"
end

local function amount(value, unit)
    if type(value) ~= "number" then
        return "n/a " .. unit
    end
    return string.format("%d %s", math.floor(value + 0.5), unit)
end

-- The one log line per measurement, as (level, text): what the car measures live beside what its metadata
-- says, and the verdict. For an unmodified stock preset (`stock`) the two readings must agree -- the shipped
-- metadata was generated by the same arithmetic on the same car -- so a disagreement there is a W: the
-- tripwire for a measurement that drifted from the engine's own after a game update. A value the limit
-- needed and did not get is a W every time (decision 5).
function M.describe(label, purpose, reading, meta_power, meta_weight, stock, compliant, missing)
    reading = reading or {}
    local parts = {
        string.format("live spec for '%s' (%s): live %s, %s; metadata %s, %s; %d engine(s)",
            tostring(label), tostring(purpose), amount(reading.power, "hp"), amount(reading.weight, "kg"),
            amount(meta_power, "hp"), amount(meta_weight, "kg"), tonumber(reading.engines) or 0),
    }
    local level = "I"
    if reading.reason then
        parts[#parts + 1] = "read: " .. reading.reason
    end
    local metadata_known = type(meta_power) == "number" and type(meta_weight) == "number"
    if stock and metadata_known and (reading.power ~= meta_power or reading.weight ~= meta_weight) then
        level = "W"
        parts[#parts + 1] = "differs from the metadata of this stock preset"
    end
    if compliant then
        parts[#parts + 1] = "within the limit"
    elseif missing then
        level = "W"
        parts[#parts + 1] = missing .. " unreadable, counted as over the limit"
    else
        parts[#parts + 1] = "over the limit"
    end
    return level, table.concat(parts, "; ")
end

return M
