-- BeamComp -- race-start resolution.
--
-- Lives at lua/ge/extensions/beamcomp/race/start.lua inside the client mod zip. Stateless:
-- require it and call M.prepare(payload). Target: client GE (LuaJIT 5.1).
--
-- Given a raceStart payload from the server, resolves the race name locally (ADR-0005: the
-- server passes the name through, the client resolves), parses it, picks the default start
-- pose, and lays the grid out via race/grid for `count` players. Returns a plain race-start
-- state table the GE extension stores and renders, or nil plus a human-readable reason.

local M = {}

local discovery = require("beamcomp/race/discovery")
local parser = require("beamcomp/race/parser")
local grid = require("beamcomp/race/grid")
local placement = require("beamcomp/race/placement")
local checkpoints = require("beamcomp/race/checkpoints")
local maps = require("beamcomp/race/maps")
local prefab = require("beamcomp/race/prefab")

local LOG_TAG = "beamcomp.race"

-- Upper bound on circuit laps, so a typo'd /race lap count can't build a runaway traversal plan.
local MAX_LAPS = 1000

-- Metres within which two grid poses count as the same place (M.pose_matches).
local POSE_MATCH_TOLERANCE = 1e-3

-- The start grid's default 15 m setback behind the line (it clears CP0's volume so a circuit's lap-1
-- clock starts on a real line crossing, ADR-0022) now lives in race/grid as the default offsetForward.
-- A race with a server-stored custom grid relays its own params in raceStart.gridParams (ADR-0023);
-- absent that, grid.poses falls back to the historical staggered two-column layout.

-- Recover/repair assist hold-time bounds (ADR-0017). The server already clamps, but this is a trust
-- boundary (ADR-0005), so the client re-clamps and defaults a missing/garbage value.
local ASSIST_DEFAULT_HOLD_SECONDS = 5
local ASSIST_MIN_HOLD_SECONDS = 1
local ASSIST_MAX_HOLD_SECONDS = 30

-- The farthest a synthesized reverse start stands behind the forward finish, in metres (ADR-0019
-- amendment 2026-10-11). The setback is the forward start's own, measured per race; this only stops a
-- straight-line extrapolation from running off the end of the road on a race whose forward start sits
-- far from its line. No shipped open route without a reverse start comes near it (measured 2026-10-11:
-- the largest is 26.4 m).
local MAX_MIRRORED_SETBACK = 50.0

-- Below this horizontal length a gate normal is treated as vertical: it names no travel direction.
local HORIZONTAL_EPSILON = 1e-6

-- The pose the race itself authored for `direction`: the matching start selector (reverse ->
-- selectors.reverse, forward -> selectors.default), else the first listed start position. A race without
-- a reverse selector therefore gets its FORWARD start back for reverse -- start_pose decides what to do
-- with that. Returns {pos, rot} (plain tables) or nil plus a reason.
local function authored_start_pose(race, direction)
    local start_positions = race.startPositions
    local selector = (direction == "reverse") and start_positions.selectors.reverse
        or start_positions.selectors.default
    if selector then
        for _, sp in ipairs(start_positions.list) do
            if sp.id == selector then
                return {pos = sp.pos, rot = sp.rot}
            end
        end
    end

    local first = start_positions.list[1]
    if first then
        return {pos = first.pos, rot = first.rot}
    end
    return nil, "race has no start position"
end

-- A {x, y, z} vector flattened and unit-normalized, or nil when it is missing or (near) vertical.
local function horizontal_unit(v)
    if type(v) ~= "table" or type(v.x) ~= "number" or type(v.y) ~= "number" then
        return nil
    end
    local length = math.sqrt(v.x * v.x + v.y * v.y)
    if length < HORIZONTAL_EPSILON then
        return nil
    end
    return {x = v.x / length, y = v.y / length, z = 0}
end

-- The way a reversed open route leaves its first line when that line has no normal of its own: from
-- reverse CP0 (the forward finish) toward route[2], the checkpoint before the finish -- the route itself
-- at the finish, never a normal the finish does not have (ADR-0019 amendment 2026-10-24). Returns the
-- horizontal unit axis and the checkpoint it points at, or nil when there is no such checkpoint or it
-- stands on the finish.
local function route_reverse_axis(route)
    local finish, before = route[1], route[2]
    if type(before) ~= "table" or type(before.pos) ~= "table" or type(finish.pos) ~= "table" then
        return nil
    end
    local axis = horizontal_unit({x = before.pos.x - finish.pos.x, y = before.pos.y - finish.pos.y})
    return axis, axis and before or nil
end

-- The reverse start of an OPEN route that authored none (ADR-0019 amendment 2026-10-11): behind reverse
-- CP0 -- the forward finish -- facing back along the route, as far behind that line as the forward start
-- stands behind its own. `forward_start` is the race's forward start pose, `route` the checkpoints in
-- reverse order (route[1] is reverse CP0, normal already negated).
--
--   setback  -- measured along the FORWARD axis, clamped to [0, MAX_MIRRORED_SETBACK]: a forward start
--               AHEAD of its line would otherwise put the reverse field past the first line it has to
--               cross. The grid's own offsetForward still sets the field back from this pose.
--   lateral  -- none: centred on the gate. Which side the pole sits on means nothing reversed.
--   height   -- reverse CP0's own; the ground pass drops every slot onto the surface from there.
--   rotation -- quatFromDir along the REVERSE axis, the convention authored start poses follow (their +Y
--               is the travel direction). The grid reads it back through grid.travel_axis when reverse CP0
--               has no normal, so the reversed field faces exactly this way.
--
-- The two axes, each from the normal when there is one -- the path of every shipped race that has both,
-- bit for bit -- and otherwise derived (ADR-0019 amendment 2026-10-24; the Utah crawls 006-Leap, 007-Dried
-- and 008-Around have neither):
--   forward axis -- grid.travel_axis on the forward start: forward CP0's normal, else the forward start's
--                   rotation read the engine's way. The same answer the forward grid is laid out along.
--   reverse axis -- reverse CP0's normal, else route_reverse_axis: the route at the finish.
--
-- Returns pose, details ({checkpoint, measured, setback, forward_source, toward}) -- `toward` is the
-- checkpoint the reverse axis points at when the route answered, nil when the normal did -- or nil plus
-- the reason the pose cannot be built.
local function open_route_reverse_pose(race, forward_start, route)
    local forward_cp0 = type(race.checkpoints) == "table" and race.checkpoints[1] or nil
    local reverse_cp0 = type(route) == "table" and route[1] or nil
    if not forward_cp0 or not reverse_cp0 then
        return nil, "the route has no checkpoints"
    end
    local forward_axis, forward_source = grid.travel_axis(forward_start.rot, forward_cp0.normal)
    if not forward_axis then
        return nil, "neither forward CP0's normal nor the forward start's rotation names a direction"
    end
    local reverse_axis, toward = horizontal_unit(reverse_cp0.normal), nil
    if not reverse_axis then
        reverse_axis, toward = route_reverse_axis(route)
    end
    if not reverse_axis then
        return nil, "reverse CP0 has no usable normal and no checkpoint before it to face"
    end
    if type(forward_start.pos) ~= "table" or type(forward_cp0.pos) ~= "table"
        or type(reverse_cp0.pos) ~= "table" then
        return nil, "a start or checkpoint position is missing"
    end
    if type(quatFromDir) ~= "function" or type(vec3) ~= "function" then
        return nil, "this game version has no quatFromDir"
    end

    local measured = (forward_cp0.pos.x - forward_start.pos.x) * forward_axis.x
        + (forward_cp0.pos.y - forward_start.pos.y) * forward_axis.y
    local setback = math.max(0, math.min(MAX_MIRRORED_SETBACK, measured))
    local rot = quatFromDir(vec3(reverse_axis.x, reverse_axis.y, 0), vec3(0, 0, 1))
    local pose = {
        pos = {
            x = reverse_cp0.pos.x - reverse_axis.x * setback,
            y = reverse_cp0.pos.y - reverse_axis.y * setback,
            z = reverse_cp0.pos.z,
        },
        rot = {x = rot.x, y = rot.y, z = rot.z, w = rot.w},
    }
    return pose, {checkpoint = reverse_cp0, measured = measured, setback = setback,
        forward_source = forward_source, toward = toward}
end

-- How the synthesized setback relates to the measured one, for the anchor's log line: empty when they
-- agree, else the clamp that moved it.
local function setback_note(details)
    if details.measured < 0 then
        return string.format(" (the forward start stands %.1f m ahead of its own line)",
            -details.measured)
    end
    if details.measured > details.setback then
        return string.format(" (the forward start stands %.1f m behind its line, capped)",
            details.measured)
    end
    return ""
end

-- Which sources the synthesized pose's two axes came from, for the same line: empty when both were the
-- gate normals -- the line every race with both normals has always written -- else both named, so a
-- reverse start built without a normal says so (ADR-0019 amendment 2026-10-24).
local function axes_note(details)
    if details.forward_source == "gate normal" and not details.toward then
        return ""
    end
    local measured_along = details.forward_source == "gate normal" and "forward CP0's normal"
        or "the forward start's rotation"
    local facing = "the reverse CP0 normal"
    if details.toward then
        facing = string.format("the route toward CP%s '%s'", tostring(details.toward.index),
            tostring(details.toward.name))
    end
    return " -- setback measured along " .. measured_along .. ", facing along " .. facing
end

-- The pose the grid anchors on for `direction`. `route` is this direction's checkpoint list (CP0 first,
-- already reversed for reverse) and `race_label` names the race in the log.
--
-- Forward, and reverse on a race with its own reverse start, use what the race authored. A reverse
-- WITHOUT one (a forced reverse, or any reverse in the grid editor) depends on the route (ADR-0019 and its
-- amendment 2026-10-11):
--   closed  -- the forward start: reverse CP0 IS the forward start line, so the field stands on the same
--              line, turned around by the reversed gate normal;
--   open    -- behind the forward finish (open_route_reverse_pose), where the reversed race starts;
--   unknown -- treated as closed.
-- An open route whose pose cannot be built keeps the forward start, with a W line saying why. The open and
-- unknown cases log one line per call -- once per race start, once per grid-editor anchor, never per
-- frame. Returns {pos, rot} (plain tables) or nil plus a reason.
local function start_pose(race, direction, route, race_label)
    local authored, err = authored_start_pose(race, direction)
    if direction ~= "reverse" or not authored or race.startPositions.selectors.reverse then
        return authored, err
    end
    -- From here on there is no reverse selector, so `authored` IS the forward start (selectors.default,
    -- else the first listed position).

    local label = tostring(race_label)
    local closed = race.meta and race.meta.closed
    if closed == true then
        return authored
    end
    if closed ~= false then
        log("I", LOG_TAG, "reverse start for '" .. label .. "': route type unknown, treated as a "
            .. "circuit -- the grid stays on the forward start line")
        return authored
    end

    local pose, details = open_route_reverse_pose(race, authored, route)
    if not pose then
        local reason = details
        log("W", LOG_TAG, "reverse start for '" .. label .. "': open route without a reverse start, but "
            .. reason .. " -- the grid stays on the forward start")
        return authored
    end
    local checkpoint = details.checkpoint
    log("I", LOG_TAG, string.format(
        "reverse start for '%s': open route without a reverse start -- grid anchored %.1f m behind "
        .. "CP%s '%s' (the forward finish)%s%s",
        label, details.setback, tostring(checkpoint.index), tostring(checkpoint.name),
        setback_note(details), axes_note(details)))
    return pose
end

-- Say in the log when the grid's direction did NOT come from CP0's gate normal (ADR-0023 amendment
-- 2026-10-24). The direction itself is grid.travel_axis's answer, and both consumers lay out through it
-- (grid.lua make_frame) with exactly these inputs -- the anchor's start pose and its direction's CP0 --
-- so the editor preview IS the spawn. This only asks the same question again to name the source: once per
-- race start (M.prepare) and once per grid-editor anchor (M.anchor), never per frame, and nothing at all
-- for a race whose CP0 has a normal. `route` is the direction's checkpoint list, CP0 first.
--
-- The line is the tripwire for a start line without a normal, the way `reverse start for '<id>': ...`
-- is for a reverse without a start position: it names the direction as a vector, so a field that stands
-- the wrong way shows as a number.
local function report_travel_axis(route, base_pose, direction, race_label)
    local cp0 = type(route) == "table" and route[1] or nil
    local axis, source = grid.travel_axis(base_pose.rot, cp0 and cp0.normal)
    if source == "gate normal" then
        return
    end
    local label = tostring(race_label)
    if not axis then
        log("W", LOG_TAG, string.format("grid direction for '%s' (%s): CP0 has no usable normal and the "
            .. "start pose's rotation names no horizontal direction -- the field lies along world X",
            label, direction))
        return
    end
    log("I", LOG_TAG, string.format("grid direction for '%s' (%s): CP0 has no usable gate normal -- the "
        .. "field and its cars face along the start pose's rotation, (%.3f, %.3f)",
        label, direction, axis.x, axis.y))
end

local FORWARD_PREFAB = "forwardPrefab.prefab.json"
local REVERSE_PREFAB = "reversePrefab.prefab.json"

-- The prefab files to load for `direction`: every shipped prefab except the opposite direction's one
-- (the parser's fixed set is {main, forward, reverse}). Forward keeps main + forward and skips
-- reverse; reverse keeps main + reverse and skips forward (ADR-0018).
local function direction_prefabs(prefab_files, direction)
    local skip = (direction == "reverse") and FORWARD_PREFAB or REVERSE_PREFAB
    local kept = {}
    for _, file in ipairs(prefab_files or {}) do
        if file:sub(-#skip) ~= skip then
            kept[#kept + 1] = file
        end
    end
    return kept
end

-- Resolve the effective travel direction for this start (ADR-0018/0019). The pre-flight check already
-- gated a reverse request against meta.reversible (and `force` overrides it), so a raceStart that
-- reaches here is committed: reverse when asked, forward otherwise. A forced reverse on a non-reversible
-- track still works -- start_pose anchors it without a reverse start position, and the checkpoint
-- transform is purely computed.
local function resolve_direction(payload)
    return payload.direction == "reverse" and "reverse" or "forward"
end

-- The checkpoints in `direction`'s traversal order (ADR-0018): the parser's list as-is, or reversed --
-- order and gate normals -- for a reverse race. CP0 is always element 1.
local function direction_checkpoints(race, direction)
    if direction == "reverse" then
        return checkpoints.reverse(race.checkpoints, race.meta and race.meta.closed)
    end
    return race.checkpoints
end

-- The lap count a CIRCUIT actually runs: the requested number when one was asked for, else the track's
-- own default, else a single lap -- clamped to [1, MAX_LAPS] (ADR-0013). Both arguments are raw and may
-- be nil or garbage; tonumber decides.
--
-- Public because the race-setup panel asks the same question with `requested = nil` -- "what does this
-- race run if I leave Laps empty?" -- to fill its grey "3 (default)" placeholder (init.lua
-- request_race_meta, ADR-0037/0049). Exposed rather than reimplemented there, exactly like
-- M.assist_hold_default below: the single-lap fallback and the clamp live here once, so a number the
-- panel shows can never differ from the number this start would use.
function M.resolve_laps(requested, track_default)
    local laps = tonumber(requested) or tonumber(track_default) or 1
    return math.max(1, math.min(MAX_LAPS, math.floor(laps)))
end

-- Resolve the effective race mode + lap count for this start (ADR-0013/0018/0019):
--   mode -- the payload override ("sprint"/"circuit") if given, else auto from meta.closed.
--   laps -- circuit only: M.resolve_laps of the payload override and meta.defaultLaps; sprint is always
--           a single pass (laps = 1).
-- The pre-flight check (ADR-0019) refuses a circuit on an open race unless forced, so circuit here is
-- either valid or a deliberate force -- kept as-is. The sprint fallback is defensive only. Returns
-- mode, laps.
local function resolve_mode(race, payload)
    local closed = race.meta and race.meta.closed
    local requested = payload.mode

    local mode
    if requested == "sprint" or requested == "circuit" then
        mode = requested
    else
        mode = closed and "circuit" or "sprint"
    end

    -- Defensive: a circuit on an open race only reaches here when forced; if some non-forced path ever
    -- did, fall back to sprint rather than build an unloopable plan.
    if mode == "circuit" and not closed and not payload.force then
        mode = "sprint"
    end

    local laps = 1
    if mode == "circuit" then
        laps = M.resolve_laps(payload.laps, race.meta and race.meta.defaultLaps)
    end

    return mode, laps
end

-- A valid hold time from the payload, defaulted + clamped (ADR-0017).
local function resolve_hold(seconds)
    local value = tonumber(seconds) or ASSIST_DEFAULT_HOLD_SECONDS
    return math.max(ASSIST_MIN_HOLD_SECONDS, math.min(ASSIST_MAX_HOLD_SECONDS, value))
end

-- The hold-time default, for the setup panel's placeholder hint (ADR-0037): the grey "5 (default)" an
-- empty Recover/Repair hold field shows. Exposed rather than duplicated in the panel so the shown number
-- always is the one resolve_hold above would apply.
function M.assist_hold_default()
    return ASSIST_DEFAULT_HOLD_SECONDS
end

-- The opt-in recover/repair assist config for this race, read from the relayed raceStart fields
-- (ADR-0017). Both are off unless the payload explicitly enables them; the hold time only matters
-- when enabled but is resolved either way so the VE never reads a nil.
local function resolve_assists(payload)
    return {
        recoverEnabled = payload.recoverEnabled == true,
        recoverHoldSeconds = resolve_hold(payload.recoverHoldSeconds),
        repairEnabled = payload.repairEnabled == true,
        repairHoldSeconds = resolve_hold(payload.repairHoldSeconds),
    }
end

-- The F1 jump-start penalty (seconds) as relayed by the server (ADR-0043), floored defensively at the
-- trust boundary (ADR-0005). Its one reader is the staging heads-up in init.lua step_staging; the
-- authoritative penalty is the server's, folded into the standings, and never this copy.
--
-- Returns nil when the server named no number, rather than a default: the client has no second source
-- for this figure, and a guessed one reads to a driver as the penalty he is about to take. The server
-- fills it on every F1 start (it sets jump_penalty_seconds alongside start_mode), so nil is the
-- impossible case, and the reader drops the number from its sentence instead of inventing one.
local function resolve_jump_penalty(seconds)
    local value = tonumber(seconds)
    if not value then
        return nil
    end
    return math.max(0, value)
end

-- The grid param block to apply for `direction`, picked from a relayed raceStart.gridParams (ADR-0023).
-- Forward uses the `forward` block; reverse uses the `reverse` block and, when a grid has none, returns
-- nil so grid.poses falls back to the default layout for the reverse run. A nil gridParams (no custom
-- grid for this race) returns nil too -- the historical procedural layout.
local function grid_params_for(grid_params, direction)
    if type(grid_params) ~= "table" then
        return nil
    end
    if direction == "reverse" then
        return grid_params.reverse
    end
    return grid_params.forward
end

-- (public) How many grid poses a roster needs: one past its HIGHEST slot, not one per entry.
--
-- The server may leave slots empty behind an oversized car (ADR-0051), so the slot map is sparse and
-- the layout has to be long enough to cover its holes. Nothing is ever reserved behind the LAST
-- participant, so the highest slot is the exact extent -- no count has to ride the wire. `my_slot` is
-- folded in so a short/inconsistent roster still covers our own slot (the guard that used to sit on
-- #roster). A contiguous roster yields exactly #roster, i.e. today's layout bit-for-bit.
function M.layout_extent(roster, my_slot)
    local highest = tonumber(my_slot) or 0
    if type(roster) == "table" then
        for _, entry in ipairs(roster) do
            local slot = type(entry) == "table" and tonumber(entry.slot) or nil
            if slot and slot > highest then
                highest = slot
            end
        end
    end
    return math.floor(highest) + 1
end

-- (public) Whether two grid poses put a car in the same place. Compared by VALUE, not by identity: a
-- re-layout (M.layout_for) builds fresh pose tables even where the numbers did not move, and a re-grid
-- that only moved other cars must not teleport a car that is already standing right. The tolerance is
-- far below anything a real re-grid shifts and far above the float noise of a recomputation.
function M.pose_matches(one, two)
    if type(one) ~= "table" or type(two) ~= "table"
        or type(one.pos) ~= "table" or type(two.pos) ~= "table" then
        return false
    end
    return math.abs(one.pos.x - two.pos.x) < POSE_MATCH_TOLERANCE
        and math.abs(one.pos.y - two.pos.y) < POSE_MATCH_TOLERANCE
        and math.abs(one.pos.z - two.pos.z) < POSE_MATCH_TOLERANCE
end

-- (public) Lay the field out on a captured grid layout and return (poses, ramp_pose).
--
-- `layout` is the frozen input set M.prepare captured for this race -- base pose, gate normal, the
-- ordered segment list, and whether a staged-quali start ramp is split off the front. It holds
-- everything grid.poses_segmented needs and nothing that changes when the field is re-gridded, so a
-- re-grid onto a LONGER layout (ADR-0051) can lay the field out again without re-resolving the race.
-- Recomputing rather than extending is required, not just convenient: a rows-pinned grid derives its
-- column count from the number of poses laid out (race/grid.lua), so every pose can move.
function M.layout_for(layout, count)
    if type(layout) ~= "table" or type(count) ~= "number" or count < 1 then
        return nil, nil
    end
    -- Rally staged sprint quali (ADR-0044/Round4): P1 is a dedicated, initially-EMPTY start ramp. Lay
    -- out ONE extra pose and split the front one off as the ramp; the field holds on the rest (grid
    -- positions 2..N+1), so P1 is never occupied at the start. The active driver is teleported onto the
    -- ramp for their run and returns to their own holding slot after. The returned holding list is
    -- re-indexed (slot k -> poses[k+1]), so spawn / AI / regrid keep their usual mapping.
    local poses = placement.ground_all(grid.poses_segmented(layout.pos, layout.rot,
        layout.ramp and (count + 1) or count, layout.segments, layout.gateNormal))
    if not layout.ramp then
        return poses, nil
    end
    local holding = {}
    for index = 2, #poses do
        holding[#holding + 1] = poses[index]
    end
    return holding, poses[1]
end

-- The AI race line for `direction` (ADR-0036): the parser's forward route as-is, or a plain order
-- reversal for a reverse race (driving needs only the order, not the checkpoint CP0-first semantics).
-- Returns a new list; tolerant of a nil route.
local function reverse_route(route_points, direction)
    if type(route_points) ~= "table" then
        return {}
    end
    if direction ~= "reverse" then
        return route_points
    end
    local reversed = {}
    for i = #route_points, 1, -1 do
        reversed[#reversed + 1] = route_points[i]
    end
    return reversed
end

-- Resolve a race payload to its parsed model + locator, or nil plus a reason. Shared by the pre-flight
-- check (M.validate) and the actual start (M.prepare): both need the same map-scoped discovery + parse
-- (ADR-0005) and the same not-found / wrong-map / ambiguous / parse-error reasons.
local function resolve_race(payload)
    -- Resolve against this map's races only (only the client knows a race's map, and a race only
    -- starts on its own map). Skip the map filter if the level is undetectable. The relayed "all" flag
    -- (ADR-0026) opts the deprecated quickrace source back into the match set.
    local loaded = maps.current()
    local include_deprecated = payload.all == true
    local locator, miss = discovery.resolve(payload.race, loaded, include_deprecated)
    if not locator then
        if miss and miss.code == "ambiguous" then
            return nil, nil, "ambiguous race name '" .. payload.race .. "'"
        end
        -- Not on this map: if the name does pick out a race elsewhere, say so -- more helpful
        -- than a bare "not found" on a multi-map server.
        if loaded then
            local elsewhere = discovery.resolve(payload.race, nil, include_deprecated)
            if elsewhere and elsewhere.map and not maps.matches(loaded, elsewhere.map) then
                return nil, nil, "race is on map '" .. elsewhere.map .. "' -- you are on '"
                    .. loaded .. "'"
            end
        end
        return nil, nil, "race not found: '" .. payload.race .. "'"
    end

    log("I", LOG_TAG, "race map '" .. tostring(locator.map) .. "', loaded map '"
        .. tostring(loaded) .. "'")

    local race, parse_err = parser.parse(locator)
    if not race then
        return nil, nil, "could not parse race: " .. tostring(parse_err)
    end
    return race, locator, nil
end

-- ===== race distribution (ADR-0039 / ADR-0046) ===========================================
-- A client without the race installed still races it: the issuer serializes the race and the race-blind
-- server relays it. The GEOMETRY (raceData) rides the raceStart -- it is small and needed the moment
-- M.prepare runs. The SCENERY is tens of KB and is pulled separately, on demand and ahead of the start
-- (ADR-0046), so it never bloats the race-start seam and is only ever sent to clients that lack the files.

-- ADR-0039 decision 6: with the file installed a client parses locally (no behavior change); a file-less
-- client builds from the host's relayed definition. Flip this to true to make the relayed model the
-- PRIMARY source (local parse becomes the fallback), once the 2-client perf/size check clears it.
local PREFER_RELAYED_RACE_DATA = false

-- Scenery this client pulled from the server, per race: raceId -> the temp vpaths it was materialized to.
-- Kept for the session, so a track is fetched ONCE however often it is raced. Cleared by an extension
-- reload, which just means the next race re-pulls it (the server serves it straight from its cache).
local track_cache = {}

-- The encoded size of a blob, in bytes -- for the payload-size log points. Size only, never content.
-- pcall-guarded and non-fatal (-1 = could not encode): a measurement must never break a race start.
local function encoded_size(value)
    if value == nil then
        return 0
    end
    local ok, encoded = pcall(jsonEncode, value)
    if not ok or type(encoded) ~= "string" then
        return -1
    end
    return #encoded
end
-- ===== end race distribution =============================================================

-- The host's serialized race definition for a file-less client (ADR-0039): only the normalized model a
-- relayed M.prepare needs -- start positions, checkpoints, meta. routePoints and the local prop paths are
-- omitted (the AI owner is always the host and parses locally; the prop content ships separately and the
-- consumer rebuilds race.props). Paired with the canonical locator the consumer keys its map guard +
-- display on. Plain serializable tables (ADR-0005); the race-blind server relays this verbatim.
local function build_race_data(race, locator)
    return {
        race = {
            startPositions = race.startPositions,
            checkpoints = race.checkpoints,
            meta = race.meta,
        },
        locator = {
            id = locator.id,
            displayName = locator.displayName,
            map = locator.map,
        },
    }
end

-- The static-scenery content for each of this race's prefab files (ADR-0039), so a file-less client can
-- spawn the barriers/signs without the local files. Built on every verdict (it is measured), but only
-- SHIPPED when the distribution policy above allows it -- it is by far the heaviest thing on the wire
-- (ADR-0046). Cones are not shipped -- the host spawns them and BeamMP syncs them to everyone
-- (ADR-0020/0025). Each entry keeps the file's basename so the consumer's direction filter still selects
-- the forward/reverse copy. A prefab that cannot be read/filtered is skipped (best-effort: geometry is
-- independent, so a missing barrier never blocks the race).
local function build_prefab_content(race)
    local files = (race.props and race.props.prefabFiles) or {}
    local content = {}
    for _, file in ipairs(files) do
        local shipped = prefab.statics_content(file)
        if shipped then
            content[#content + 1] = {
                name = file:match("[^/]+$") or file,
                format = shipped.format,
                content = shipped.content,
            }
        end
    end
    return content
end

-- The issuing client's pre-flight verdict on a /race's options (ADR-0019). The race-blind server relays
-- the options here; we resolve + parse the race locally and report whether it can run as asked. A bad
-- name / wrong map / ambiguous name, or a geometry mismatch the admin did not `force` (circuit on an
-- open race, reverse on a non-reversible one), is refused with a reason; otherwise -- or with `force` --
-- it is ok. Returns {ok = bool, reason = string?, raceId = string?}. raceId is the canonical map-scoped
-- id (ADR-0005) the server keys the default-grid lookup on (ADR-0023), so the default resolves whatever
-- shorthand the admin typed for /race.
function M.validate(payload)
    if type(payload) ~= "table" or type(payload.race) ~= "string" then
        return {ok = false, reason = "malformed race request"}
    end
    local race, locator, err = resolve_race(payload)
    if not race then
        return {ok = false, reason = err}
    end
    if not payload.force then
        if payload.direction == "reverse" and not (race.meta and race.meta.reversible) then
            return {ok = false, reason = "not reversible -- add 'force' to reverse it anyway"}
        end
        if payload.mode == "circuit" and not (race.meta and race.meta.closed) then
            return {ok = false, reason = "not a loop -- add 'force' to run as circuit anyway"}
        end
    end
    -- Hand the server the aiRace content AI defaults (ADR-0036 Etappe B): the race-blind server uses
    -- aiDefaults.count to seed the AI slots when /race opted into AI without an explicit count. nil for
    -- non-aiRace content. The owner reads the same defaults locally via M.prepare for difficulty/vehicle.
    --
    -- raceData (+ prefabContent, when the policy above ships it) serialize the race for distribution
    -- (ADR-0039/0046): the race-blind server relays them verbatim in raceStart so a client without the
    -- local race file can still build + spawn it.
    -- Staged sprint quali activation (ADR-0044): the race-blind server cannot read meta.closed, so tell it
    -- whether an order=quali on this race is the rally staged sprint variant. Effective mode = the
    -- sprint|circuit override else meta.closed; a sprint means the staged single-car-from-P1 quali, a
    -- circuit keeps the ADR-0041 all-at-once best-lap quali. Reported on every verdict; only read when the
    -- race is order=quali (harmless otherwise).
    local closed = race.meta and race.meta.closed
    local staged_quali
    if payload.mode == "sprint" then
        staged_quali = true
    elseif payload.mode == "circuit" then
        staged_quali = false
    else
        staged_quali = not closed
    end

    -- Only the GEOMETRY goes with the verdict (ADR-0046). The scenery used to ride along here and be
    -- relayed into every player's raceStart -- tens of KB, on every start, thrown away by everyone who has
    -- the track. It is now pulled on demand instead (M.track_content, answering a trackFetch), so the host
    -- does not even read the prefab files unless somebody actually needs them.
    local race_data = build_race_data(race, locator)
    log("I", LOG_TAG, string.format("distribution '%s': raceData=%d B (scenery on demand)",
        tostring(locator.id), encoded_size(race_data)))

    return {
        ok = true,
        raceId = locator.id,
        aiDefaults = race.meta and race.meta.aiDefaults,
        raceData = race_data,
        stagedQuali = staged_quali,
    }
end

-- Reconstruct the parsed race model + locator from the host's relayed definition (ADR-0039). The relay
-- carries geometry only, so the prop side the consumer owns is rebuilt here from whatever scenery this
-- client has already pulled for the race (ADR-0046); an empty list is fine and expected when the pull is
-- still in flight -- the props are loaded the moment it lands (init.handle_track_data). Cones stay
-- host-only (BeamMP-synced, never spawned here). Guards the map -- the relayed coordinates are
-- world-absolute and valid only on the race's own map, so a client elsewhere refuses rather than spawn at
-- alien coordinates. Returns race, locator on success, or nil plus a reason.
local function race_from_distribution(race_data)
    if type(race_data) ~= "table" or type(race_data.race) ~= "table"
        or type(race_data.locator) ~= "table" then
        return nil, "no relayed race definition"
    end

    local locator = race_data.locator
    local loaded = maps.current()
    if loaded and locator.map and not maps.matches(loaded, locator.map) then
        return nil, "race is on map '" .. tostring(locator.map) .. "' -- you are on '"
            .. tostring(loaded) .. "'"
    end

    local race = race_data.race
    race.props = {
        prefabFiles = track_cache[locator.id] or {},
        coneFiles = {},
    }
    return race, locator
end

-- Resolve a raceStart payload to its parsed race model + locator (ADR-0039): a client with the file
-- parses locally (unchanged), a file-less client falls back to the host's relayed definition. The flag
-- above flips the order so the relayed model can become primary. Returns race, locator, reason, relayed --
-- the last one telling the caller this race was built from the relay, so it knows to make sure the scenery
-- has been pulled (ADR-0046) without re-parsing anything to find out.
local function resolve_race_for_prepare(payload)
    local has_relayed = type(payload.raceData) == "table"

    if PREFER_RELAYED_RACE_DATA and has_relayed then
        local race, locator = race_from_distribution(payload.raceData)
        if race then
            return race, locator, nil, true
        end
    end

    local race, locator, err = resolve_race(payload)
    if race then
        return race, locator, nil, false
    end

    if has_relayed then
        local relayed_race, relayed_locator_or_err = race_from_distribution(payload.raceData)
        if relayed_race then
            return relayed_race, relayed_locator_or_err, nil, true
        end
        return nil, nil, relayed_locator_or_err
    end

    return nil, nil, err
end

-- Build the race-start state for a raceStart payload, or return nil plus a reason.
-- Build the qualifying descriptor for a quali event (ADR-0041), or nil for a normal race. The quali plan
-- is an unbounded-lap circuit plan (sized to the window so a driver can't run it out) so they keep lapping
-- and setting lap times for the whole session; the real race plan drives the actual race after qualifying.
-- A sprint reuses the single-run race plan -- a degraded single timed run until the rally-staged sprint
-- quali ships as its own item. `duration` feeds the HUD quali clock.
local function quali_for(payload, race_checkpoints, mode, race_plan)
    if type(payload.quali) ~= "table" then
        return nil
    end
    local duration = tonumber(payload.quali.duration) or 480
    local plan = race_plan
    local laps = 1
    -- Rally staged sprint quali (ADR-0044): on a sprint, drivers run one at a time from P1 and the plan is
    -- the single Start->Ziel race plan (each staged run drives it once). The client decides staged from its
    -- own resolved mode, consistent with the server activation (both derive from the same meta.closed /
    -- mode-override, ADR-0044). A circuit keeps the ADR-0041 all-at-once best-lap quali below.
    local staged = (mode == "sprint")
    if mode == "circuit" then
        -- Size the lap count to the window so neither a player nor the AI can run the plan out before the
        -- clock ends (~8 s/lap floor is far quicker than any real lap).
        laps = math.max(10, math.min(MAX_LAPS, math.ceil(duration / 8)))
        plan = checkpoints.plan(race_checkpoints, mode, laps)
    end
    return {duration = duration, plan = plan, laps = laps, mode = mode, staged = staged}
end

function M.prepare(payload)
    if type(payload) ~= "table" or type(payload.race) ~= "string" then
        return nil, "malformed raceStart payload"
    end

    local race, locator, err, relayed = resolve_race_for_prepare(payload)
    if not race then
        return nil, err
    end

    local direction = resolve_direction(payload)

    -- Reverse drives the checkpoints backward (ADR-0018): derive the reversed list (order + negated
    -- gate normals) before anything else, so the start pose, the plan, the detector and the in-world
    -- markers all use it -- an open route's reverse start is anchored on its reverse CP0.
    local race_checkpoints = direction_checkpoints(race, direction)

    local base_pose, pose_err = start_pose(race, direction, race_checkpoints, locator.id)
    if not base_pose then
        return nil, pose_err
    end

    local roster = payload.grid or {}
    local my_slot = payload.slot or 0

    local mode, laps = resolve_mode(race, payload)

    -- Lay the grid out behind the line along the travel axis taken from the start/finish gate normal
    -- (CP0 = race_checkpoints[1], already reversed for a reverse race) so the field sits behind the line
    -- and a circuit's lap-1 clock starts on a real line crossing (ADR-0022). Without a usable normal the
    -- grid takes the start pose's rotation instead (grid.travel_axis, ADR-0023 amendment 2026-10-24) and
    -- report_travel_axis says so; the normal itself stays what the checkpoint has, nil included, because
    -- the detector, the markers and the lap timer read it from there. A server-stored custom grid relays
    -- its params per direction in raceStart.gridParams (ADR-0023): use the matching block, and for a reverse
    -- race with no reverse block fall back to the default layout (nil -> grid.poses defaults).
    local gate_normal = race_checkpoints[1] and race_checkpoints[1].normal
    report_travel_axis(race_checkpoints, base_pose, direction, locator.id)
    local grid_params = grid_params_for(payload.gridParams, direction)
    -- Drop every pose onto the real surface before anyone spawns on it (ADR-0034): grid.poses is pure
    -- math at the chain Z, so on undulating tracks the rear rows would bury or float. front-anchoring
    -- (vehicles.lua) preserves Z, so grounding here flows through every placement path (fresh/fixed/
    -- substitute spawn, keep+teleport, regrid, restage, recover-before-CP1). HEIGHT-ONLY on purpose
    -- (ADR-0034 amendment): the wall-nudge misfired on steep slopes (its horizontal ray hits the rising
    -- ground itself and shoved a holding slot onto the staged-quali ramp), so the grid keeps the authored
    -- X/Y exactly as the editor preview shows them; only the recover assist still nudges. The block is
    -- expanded into its ordered segment list (ADR-0023 amendment) and laid out via poses_segmented, so
    -- the spawned field matches the editor's stacked preview exactly; a plain single-param block (or nil)
    -- expands to one segment and reproduces today's layout bit-for-bit.
    -- The layout inputs are kept on the race state so a re-grid can lay the field out again: the server
    -- may hand out SPARSE slots to keep the space behind an oversized car free (ADR-0051), and which
    -- slots those are can change with the start order (order=pwr, quali) or with a staging car swap.
    local grid_layout = {
        pos = base_pose.pos,
        rot = base_pose.rot,
        gateNormal = gate_normal,
        segments = grid.block_to_segments(grid_params),
        -- Rally staged sprint quali (ADR-0044/Round4): split a dedicated, initially-EMPTY P1 start ramp
        -- off the front of the layout.
        ramp = ((mode == "sprint") and (type(payload.quali) == "table")) or nil,
    }
    local layout_count = M.layout_extent(roster, my_slot)
    local poses, ramp_pose = M.layout_for(grid_layout, layout_count)
    local my_pose = poses and poses[my_slot + 1]
    if not my_pose then
        return nil, "invalid slot " .. tostring(my_slot)
    end

    local plan = checkpoints.plan(race_checkpoints, mode, laps)

    log("I", LOG_TAG, string.format(
        "race '%s' ready: slot %d of %d (%d grid poses), mode=%s laps=%d dir=%s (%d crossings) "
        .. "at (%.1f, %.1f, %.1f)",
        race.meta.name, my_slot, #roster, layout_count, mode, laps, direction, plan.count,
        my_pose.pos.x, my_pose.pos.y, my_pose.pos.z))

    return {
        name = race.meta.name,
        -- The race name the server relayed, kept verbatim. Every message the server race-guards has to
        -- echo THIS, not the resolved meta name -- they differ whenever /race was given a shorthand. The
        -- handlers that answer a raceStart still echo payload.race directly; this is for the later
        -- reports that no longer have the payload in hand (a staging swap re-reporting its car).
        serverName = payload.race,
        -- The discovered track name (slug / quickrace file), for the analysis overlay's Track header. The
        -- parsed race path's own name is often the generic "Path", so prefer this human-facing label.
        displayName = locator.displayName,
        raceId = locator.id,
        mySlot = my_slot,
        myPose = my_pose,
        gridPoses = poses,
        -- The frozen layout inputs + how many poses they were laid out for (ADR-0051), so a re-grid onto a
        -- sparser/longer slot map can re-run M.layout_for without re-resolving the race.
        gridLayout = grid_layout,
        layoutCount = layout_count,
        -- Rally staged sprint quali (ADR-0044/Round4): the dedicated P1 start ramp, split off the front of the
        -- grid so P1 stays empty at the start. The active driver is teleported here for their run; nil for a
        -- normal race / circuit quali (no separate ramp).
        rampPose = ramp_pose,
        roster = roster,
        -- This race was built from the host's relayed definition, i.e. we do NOT have the track installed
        -- (ADR-0039). The caller uses it to make sure the scenery has actually been pulled (ADR-0046):
        -- with an empty prefabFiles the pull is still in flight (or was missed), and the props are loaded
        -- as soon as it lands. A client that parsed locally never needs any of that.
        relayed = relayed or nil,
        prefabFiles = direction_prefabs(race.props.prefabFiles, direction),
        -- The host-only cone source (ADR-0025): the quickrace track prefab whose cone vehicles the host
        -- spawns once for BeamMP to sync. Empty for missions (their cones ride in prefabFiles). Not run
        -- through direction_prefabs -- track prefabs are not forward/reverse-named.
        coneFiles = race.props.coneFiles or {},
        -- Ordered, visible-only checkpoints with a stable 0-based index (ADR-0005); consumed by
        -- the racing-phase checkpoint detector (race/checkpoints.lua). Reversed for a reverse race.
        checkpoints = race_checkpoints,
        -- The authored race line for the host-driven AI (ADR-0036 Step-3b): every path node with its
        -- corridor radius, reversed in lock-step for a reverse race. The AI driver builds its drive script
        -- (or navgraph snap) from these at drive time. Display/scoring keep using `checkpoints`.
        routePoints = reverse_route(race.routePoints, direction),
        -- Resolved race mode + lap count, travel direction, and the detector's plan (ADR-0013/0018).
        mode = mode,
        laps = laps,
        direction = direction,
        plan = plan,
        -- F1 light start (ADR-0043): "f1" = lights + free car + jump-start penalty; nil = lock countdown.
        -- jumpPenaltySeconds names the penalty in the staging heads-up; the server applies the real one.
        startMode = payload.startMode == "f1" and "f1" or nil,
        jumpPenaltySeconds = resolve_jump_penalty(payload.jumpPenaltySeconds),
        -- Opt-in recover/repair assists relayed from /race (ADR-0017); enforced VE-side.
        assists = resolve_assists(payload),
        -- The aiRace authored AI defaults (ADR-0036 Etappe B): the owner fills any difficulty/vehicle
        -- gaps from these when /race omitted an explicit preset/aicar. nil for non-aiRace content.
        aiDefaults = race.meta and race.meta.aiDefaults,
        -- Qualifying event descriptor (ADR-0041): {duration, plan, mode} for order=quali, else nil. The
        -- quali plan loops the circuit for the window; the real `plan` above drives the race afterwards.
        quali = quali_for(payload, race_checkpoints, mode, plan),
    }
end

-- Resolve just the grid anchor for a race on this map: the base start pose + the start/finish gate
-- normal the grid lays out behind, for `direction` ("forward"/"reverse"). Used by the in-game grid
-- editor (race/grideditor) to preview poses against the same geometry a real race start uses. Also returns
-- the reference scene the editor can spawn/draw alongside the preview (so the grid is positioned against
-- the real start area): `prefabFiles` -- the track's static-scenery prefabs for this direction (the same
-- set a real start loads) -- and `checkpoints` -- every checkpoint {index, pos, normal, radius} in this
-- direction's traversal order, CP0 (the start line) first. Returns {base_pose = {pos, rot}, gate_normal =
-- {x,y,z}|nil, raceId = string, prefabFiles = {...}, checkpoints = {...}} or nil plus a reason.
-- `gate_normal` is CP0's own normal, nil included -- the grid derives the direction from base_pose when it
-- is nil, exactly as the race start does. raceId is the canonical id the default-grid assignment is keyed
-- on (ADR-0023).
function M.anchor(race_name, direction)
    if type(race_name) ~= "string" then
        return nil, "no race name"
    end
    -- The grid editor resolves any installed race, including the deprecated quickrace source (ADR-0026),
    -- so an admin can configure grids for it -- pass all = true.
    local race, locator, err = resolve_race({race = race_name, all = true})
    if not race then
        return nil, err
    end

    direction = (direction == "reverse") and "reverse" or "forward"
    local race_checkpoints = direction_checkpoints(race, direction)
    local base_pose, pose_err = start_pose(race, direction, race_checkpoints, locator.id)
    if not base_pose then
        return nil, pose_err
    end

    local first_checkpoint = race_checkpoints[1]
    -- The grid editor lays its preview out with exactly this normal and base_pose (grideditor recompute ->
    -- grid.poses_segmented_with_frames), which is what M.prepare hands the spawn: without a normal both
    -- take the start pose's rotation through grid.travel_axis, and the line below says so once per anchor.
    local gate_normal = first_checkpoint and first_checkpoint.normal
    report_travel_axis(race_checkpoints, base_pose, direction, locator.id)

    -- The editor draws the whole route (CP0 red, CP1 yellow, the rest grey), so the ordered list travels,
    -- not just its head. Already in this direction's order: the reversed list is the one CP0 came from.
    -- A closed loop never lists CP0 twice (the parser skips node ids it has emitted); the index check
    -- keeps that true for any source, so the start line is never drawn a second time in grey.
    local route = {}
    for i, checkpoint in ipairs(race_checkpoints) do
        local is_cp0_again = i > 1 and checkpoint.index ~= nil
            and checkpoint.index == first_checkpoint.index
        if not is_cp0_again then
            route[#route + 1] = {
                index = checkpoint.index,
                pos = checkpoint.pos,
                normal = checkpoint.normal,
                radius = checkpoint.radius,
            }
        end
    end

    return {
        base_pose = base_pose,
        gate_normal = gate_normal,
        raceId = locator.id,
        prefabFiles = direction_prefabs(race.props.prefabFiles, direction),
        checkpoints = route,
    }
end

-- Resolve a race name/shorthand to its canonical map-scoped id without parsing it, for the grid
-- editor's explicit assign (ADR-0023): it needs the id the server keys defaults on, even when not in an
-- edit session. Discovery-only (no parser), scoped to the current map. Returns the id or nil + a reason.
function M.resolve_id(race_name)
    if type(race_name) ~= "string" or race_name == "" then
        return nil, "no race name"
    end
    -- Editor path (ADR-0023): resolve any installed race, including the deprecated source (ADR-0026).
    local locator, miss = discovery.resolve(race_name, maps.current(), true)
    if not locator then
        if miss and miss.code == "ambiguous" then
            return nil, "ambiguous race name '" .. race_name .. "'"
        end
        return nil, "race not found: '" .. race_name .. "'"
    end
    return locator.id
end

-- ===== the on-demand scenery pull (ADR-0046) =============================================
-- Four seams, all driven from init.lua's message handlers:
--   needs_track   -- answer the server's trackProbe: do I have to pull this race's scenery?
--   track_content -- the issuer answers a trackFetch: serialize the scenery it alone has on disk.
--   absorb_track  -- a trackData landed: write it out and remember it for the rest of the session.
--   track_prefabs -- the materialized paths for a race + direction, to hand to props.load.

-- Whether this client must pull the scenery for `race_id`: only when it cannot find the race locally
-- (then it has no prefab files to spawn) and has not already pulled it this session. Discovery-only --
-- no parse -- so answering a probe stays cheap on the clients that DO have the track, which is everyone,
-- normally. A local file that exists but fails to parse slips through here; the backstop at race start
-- (state.relayed with no prefabFiles, init.lua) catches exactly that case.
function M.needs_track(race_id)
    if type(race_id) ~= "string" or race_id == "" then
        return false
    end
    if track_cache[race_id] then
        return false
    end
    return M.resolve_id(race_id) == nil
end

-- The scenery for `race_id`, serialized for a client that lacks it (ADR-0039 decision 2: statics only --
-- the cone VEHICLES are dropped, because the host spawns those and BeamMP syncs them to everyone, so
-- relaying them would spawn them twice, ADR-0020). Only the race's issuer is ever asked for this, and it
-- provably holds the files: it just parsed the race for its pre-flight verdict. Returns the content list
-- (possibly empty) or nil if the race cannot be resolved here after all.
function M.track_content(race_id)
    local race = resolve_race({race = race_id, all = true})
    if not race then
        log("W", LOG_TAG, "asked for track '" .. tostring(race_id) .. "' but cannot resolve it locally")
        return nil
    end
    local content = build_prefab_content(race)
    log("I", LOG_TAG, string.format("track '%s': serialized %d prefab(s), %d B",
        tostring(race_id), #content, encoded_size(content)))
    return content
end

-- Materialize a pulled scenery blob to temp vpaths and remember them for the session, so this track is
-- only ever pulled once however often it is raced. Returns the written paths (best-effort: an entry that
-- cannot be written is skipped -- geometry is independent, so a missing barrier never blocks the race).
function M.absorb_track(race_id, content)
    if type(race_id) ~= "string" or race_id == "" or type(content) ~= "table" then
        return {}
    end
    local paths = prefab.materialize(content)
    track_cache[race_id] = paths
    log("I", LOG_TAG, string.format("track '%s': pulled %d prefab(s), %d B",
        race_id, #content, encoded_size(content)))
    return paths
end

-- The pulled prefabs for a race, filtered to the ones this direction spawns (the same filter a locally
-- parsed race goes through). Empty when nothing has been pulled for it.
function M.track_prefabs(race_id, direction)
    if type(race_id) ~= "string" then
        return {}
    end
    return direction_prefabs(track_cache[race_id] or {}, direction)
end

return M
