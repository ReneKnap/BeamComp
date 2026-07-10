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

-- The start grid's default 15 m setback behind the line (it clears CP0's volume so a circuit's lap-1
-- clock starts on a real line crossing, ADR-0022) now lives in race/grid as the default offsetForward.
-- A race with a server-stored custom grid relays its own params in raceStart.gridParams (ADR-0023);
-- absent that, grid.poses falls back to the historical staggered two-column layout.

-- Recover/repair assist hold-time bounds (ADR-0017). The server already clamps, but this is a trust
-- boundary (ADR-0005), so the client re-clamps and defaults a missing/garbage value.
local ASSIST_DEFAULT_HOLD_SECONDS = 5
local ASSIST_MIN_HOLD_SECONDS = 1
local ASSIST_MAX_HOLD_SECONDS = 30

-- The pose the grid anchors on for `direction`: the race's matching start selector (reverse ->
-- selectors.reverse, forward -> selectors.default), else the first listed start position. A reversible
-- race resolves selectors.reverse; a *forced* reverse on a track without one (ADR-0019) falls back to
-- the default start here -- the checkpoint transform is purely computed, so reverse still works.
-- Returns {pos, rot} (plain tables) or nil plus a reason.
local function start_pose(race, direction)
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
-- track still works -- start_pose falls back to the default selector when reverse is absent, and the
-- checkpoint transform is purely computed.
local function resolve_direction(payload)
    return payload.direction == "reverse" and "reverse" or "forward"
end

-- Resolve the effective race mode + lap count for this start (ADR-0013/0018/0019):
--   mode -- the payload override ("sprint"/"circuit") if given, else auto from meta.closed.
--   laps -- circuit only: the payload override else meta.defaultLaps, clamped >= 1; sprint is always
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
        local requested_laps = tonumber(payload.laps) or (race.meta and race.meta.defaultLaps) or 1
        laps = math.max(1, math.min(MAX_LAPS, math.floor(requested_laps)))
    end

    return mode, laps
end

-- A valid hold time from the payload, defaulted + clamped (ADR-0017).
local function resolve_hold(seconds)
    local value = tonumber(seconds) or ASSIST_DEFAULT_HOLD_SECONDS
    return math.max(ASSIST_MIN_HOLD_SECONDS, math.min(ASSIST_MAX_HOLD_SECONDS, value))
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

-- The F1 jump-start penalty (seconds) for the offender's HUD banner (ADR-0043). The server owns the
-- authoritative penalty folded into the standings; this copy is display-only, so it is defaulted +
-- floored defensively (trust boundary, ADR-0005). nil startMode races never read it.
local JUMP_PENALTY_DEFAULT_SECONDS = 15
local function resolve_jump_penalty(seconds)
    return math.max(0, tonumber(seconds) or JUMP_PENALTY_DEFAULT_SECONDS)
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
-- spawn the barriers/signs without the local files. Cones are not shipped -- the host spawns them and
-- BeamMP syncs them to everyone (ADR-0020/0025). Each entry keeps the file's basename so the consumer's
-- direction filter still selects the forward/reverse copy. A prefab that cannot be read/filtered is
-- skipped (best-effort: geometry is independent, so a missing barrier never blocks the race).
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
    -- raceData + prefabContent serialize the race for distribution (ADR-0039): the server relays them
    -- verbatim in raceStart so a client without the local race file can still build + spawn it.
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

    return {
        ok = true,
        raceId = locator.id,
        aiDefaults = race.meta and race.meta.aiDefaults,
        raceData = build_race_data(race, locator),
        prefabContent = build_prefab_content(race),
        stagedQuali = staged_quali,
    }
end

-- ADR-0039 decision 6: with the file installed a client parses locally (no behavior change); a file-less
-- client builds from the host's relayed definition. Flip this to true to make the relayed model the
-- PRIMARY source (local parse becomes the fallback), once the 2-client perf/size check clears it.
local PREFER_RELAYED_RACE_DATA = false

-- Reconstruct the parsed race model + locator from the host's relayed definition (ADR-0039). The host
-- ships only the geometry, so the prop side the consumer owns is rebuilt here: the shipped statics are
-- materialized to temp vpaths (best-effort), and cones stay host-only (BeamMP-synced, never spawned
-- here). Guards the map -- the relayed coordinates are world-absolute and valid only on the race's own
-- map, so a client elsewhere refuses rather than spawn at alien coordinates. Returns race, locator on
-- success, or nil plus a reason.
local function race_from_distribution(race_data, prefab_content)
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
        prefabFiles = prefab.materialize(prefab_content),
        coneFiles = {},
    }
    return race, locator
end

-- Resolve a raceStart payload to its parsed race model + locator (ADR-0039): a client with the file
-- parses locally (unchanged), a file-less client falls back to the host's relayed definition. The flag
-- above flips the order so the relayed model can become primary. Returns race, locator or nil + reason.
local function resolve_race_for_prepare(payload)
    local has_relayed = type(payload.raceData) == "table"

    if PREFER_RELAYED_RACE_DATA and has_relayed then
        local race, locator = race_from_distribution(payload.raceData, payload.prefabContent)
        if race then
            return race, locator
        end
    end

    local race, locator, err = resolve_race(payload)
    if race then
        return race, locator
    end

    if has_relayed then
        local relayed_race, relayed_locator_or_err = race_from_distribution(payload.raceData,
            payload.prefabContent)
        if relayed_race then
            return relayed_race, relayed_locator_or_err
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

    local race, locator, err = resolve_race_for_prepare(payload)
    if not race then
        return nil, err
    end

    local direction = resolve_direction(payload)

    local base_pose, pose_err = start_pose(race, direction)
    if not base_pose then
        return nil, pose_err
    end

    local roster = payload.grid or {}
    local my_slot = payload.slot or 0
    -- Cover my own slot even if the roster is shorter than expected (server inconsistency).
    local count = #roster
    if my_slot + 1 > count then
        count = my_slot + 1
    end

    local mode, laps = resolve_mode(race, payload)

    -- Reverse drives the checkpoints backward (ADR-0018): derive the reversed list (order + negated
    -- gate normals) before planning, so the plan, detector, and in-world markers all use it.
    local race_checkpoints = race.checkpoints
    if direction == "reverse" then
        race_checkpoints = checkpoints.reverse(race.checkpoints, race.meta and race.meta.closed)
    end

    -- Lay the grid out behind the line along the travel axis taken from the start/finish gate normal
    -- (CP0 = race_checkpoints[1], already reversed for a reverse race) so the field sits behind the line
    -- and a circuit's lap-1 clock starts on a real line crossing (ADR-0022). A server-stored custom grid
    -- relays its params per direction in raceStart.gridParams (ADR-0023): use the matching block, and for
    -- a reverse race with no reverse block fall back to the default layout (nil -> grid.poses defaults).
    local gate_normal = race_checkpoints[1] and race_checkpoints[1].normal
    local grid_params = grid_params_for(payload.gridParams, direction)
    -- Drop every pose onto the real surface and clear of walls before anyone spawns on it (ADR-0034):
    -- grid.poses is pure math at the start-line Z, so on undulating tracks the rear rows would bury or
    -- float. front-anchoring (vehicles.lua) preserves Z, so grounding here flows through every placement
    -- path (fresh/fixed/substitute spawn, keep+teleport, regrid, restage, recover-before-CP1). The block
    -- is expanded into its ordered segment list (ADR-0023 amendment) and laid out via poses_segmented, so
    -- the spawned field matches the editor's stacked preview exactly; a plain single-param block (or nil)
    -- expands to one segment and reproduces today's layout bit-for-bit.
    -- Rally staged sprint quali (ADR-0044/Round4): P1 is a dedicated, initially-EMPTY start ramp. Lay out
    -- ONE extra grid pose and split the front one off as the ramp; the field spawns + holds on the remaining
    -- poses (grid positions 2..N+1), so P1 is never occupied at the start. The active driver is teleported
    -- onto the ramp (rampPose) for their run and returns to their own holding slot after. gridPoses stays the
    -- holding poses re-indexed (slot k -> gridPoses[k+1]), so spawn / AI / regrid keep their usual mapping.
    local staged_quali = (mode == "sprint") and (type(payload.quali) == "table")
    local layout_count = staged_quali and (count + 1) or count
    local poses = placement.resolve_all(grid.poses_segmented(base_pose.pos, base_pose.rot, layout_count,
        grid.block_to_segments(grid_params), gate_normal))
    local ramp_pose = nil
    if staged_quali then
        ramp_pose = poses[1]
        local holding = {}
        for i = 2, #poses do
            holding[#holding + 1] = poses[i]
        end
        poses = holding
    end
    local my_pose = poses[my_slot + 1]
    if not my_pose then
        return nil, "invalid slot " .. tostring(my_slot)
    end

    local plan = checkpoints.plan(race_checkpoints, mode, laps)

    log("I", LOG_TAG, string.format(
        "race '%s' ready: slot %d of %d, mode=%s laps=%d dir=%s (%d crossings) at (%.1f, %.1f, %.1f)",
        race.meta.name, my_slot, count, mode, laps, direction, plan.count,
        my_pose.pos.x, my_pose.pos.y, my_pose.pos.z))

    return {
        name = race.meta.name,
        -- The discovered track name (slug / quickrace file), for the analysis overlay's Track header. The
        -- parsed race path's own name is often the generic "Path", so prefer this human-facing label.
        displayName = locator.displayName,
        raceId = locator.id,
        mySlot = my_slot,
        myPose = my_pose,
        gridPoses = poses,
        -- Rally staged sprint quali (ADR-0044/Round4): the dedicated P1 start ramp, split off the front of the
        -- grid so P1 stays empty at the start. The active driver is teleported here for their run; nil for a
        -- normal race / circuit quali (no separate ramp).
        rampPose = ramp_pose,
        roster = roster,
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
        -- jumpPenaltySeconds labels the offender's local banner; the server applies the real penalty.
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
-- set a real start loads) -- and `checkpoint` -- the first checkpoint {pos, normal, radius} for this
-- direction. Returns {base_pose = {pos, rot}, gate_normal = {x,y,z}|nil, raceId = string, prefabFiles =
-- {...}, checkpoint = {pos, normal, radius}|nil} or nil plus a reason. raceId is the canonical id the
-- default-grid assignment is keyed on (ADR-0023).
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
    local base_pose, pose_err = start_pose(race, direction)
    if not base_pose then
        return nil, pose_err
    end

    local race_checkpoints = race.checkpoints
    if direction == "reverse" then
        race_checkpoints = checkpoints.reverse(race.checkpoints, race.meta and race.meta.closed)
    end
    local first_checkpoint = race_checkpoints[1]
    local gate_normal = first_checkpoint and first_checkpoint.normal
    local checkpoint = first_checkpoint and {
        pos = first_checkpoint.pos,
        normal = first_checkpoint.normal,
        radius = first_checkpoint.radius,
    } or nil

    return {
        base_pose = base_pose,
        gate_normal = gate_normal,
        raceId = locator.id,
        prefabFiles = direction_prefabs(race.props.prefabFiles, direction),
        checkpoint = checkpoint,
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

return M
