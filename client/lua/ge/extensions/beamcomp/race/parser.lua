-- BeamComp -- GE-side time-trial race parser.
--
-- Lives at lua/ge/extensions/beamcomp/race/parser.lua inside the client mod zip.
-- Stateless: require it and call M.parse(locator). It holds no state and registers
-- nothing, so it needs no extension lifecycle (cf. the race-format reference note s9).
--
-- Reuses BeamNG's own race loaders rather than reparsing by hand: path:onDeserialized for a
-- race.race.json (missions + level .race.json), and the quickrace importer (race/quickrace ->
-- path:fromTrack) for the legacy level quickrace tracks the Time Trial menu uses (ADR-0024). The
-- loaders handle oldId remapping, segment ordering, and classification. M.parse dispatches by
-- locator.format and normalizes the loaded path object into a plain-Lua, engine-handle-free table
-- (ADR-0005): start positions, ordered visible checkpoints with a stable 0-based index, prefab file
-- references, and meta (a mission's defaultLaps coming from its sibling info.json). The data-model
-- contract lives in .claude/features/race-parser/2-architecture.md.

local M = {}

local quickrace = require("beamcomp/race/quickrace")

local LOG_TAG = "beamcomp.race"
local RACE_PATH_MODULE = "/lua/ge/extensions/gameplay/race/path"

-- Locator sources whose races are normalized to Sprint output (point-to-point, meta.closed = false)
-- regardless of the loaded path's own classification. rallyStage and crawl author point-to-point stages
-- already, but BeamComp lists both as Sprint by contract (feature: parse-rally-and-crawl-stages), so the
-- normalization is explicit rather than relying on the source geometry happening to be open. Keyed on
-- locator.source, which for these two equals the mission-type name (discovery MISSION_SOURCES).
local SPRINT_NORMALIZED_SOURCES = {
    rallyStage = true,
    crawl = true,
}

-- Flatten an engine vec3 to a plain {x, y, z} table.
local function vec3_to_table(v)
    return {x = v.x, y = v.y, z = v.z}
end

-- Flatten an engine quaternion to a plain {x, y, z, w} table.
local function quat_to_table(q)
    return {x = q.x, y = q.y, z = q.z, w = q.w}
end

-- The folder a race file sits in, with trailing slash (for sibling prefab lookup).
local function folder_of(race_file)
    return race_file:match("^(.*/)[^/]*$") or ""
end

-- Whether a start-position id resolves to a real pose. The engine's sortedList returns
-- a truthy "Missing!" placeholder (missing = true) for absent ids, so a nil check is not
-- enough; absent selector fields default to -1.
local function start_position_exists(path, id)
    return not path.startPositions.objects[id].missing
end

-- A reverse race is one whose reverse start position resolves to a real pose.
local function is_reversible(path)
    return start_position_exists(path, path.reverseStartPosition)
end

-- The engine's ordered traversal node-id list built by autoConfig. BeamNG 0.39 renamed the field
-- (config.linearSegments -> config.linearPathnodes, gameplay/race/path.lua) with identical
-- content: the start node id first, then each jump's target node, a closed loop repeating the
-- start node at the end. The legacy name stays as a fallback read for older engine builds. nil
-- when autoConfig bailed out (start node missing) -- the parse gate below rejects that.
local function linear_pathnodes(path)
    return path.config.linearPathnodes or path.config.linearSegments
end

-- Load and graph-configure a race file via the engine loader. Wrapped in pcall so a
-- malformed file never throws into the engine. Returns the configured path or nil.
local function load_race_path(race_file)
    local json = jsonReadFile(race_file)
    if not json then
        log("E", LOG_TAG, "race file not found or unreadable: " .. tostring(race_file))
        return nil
    end

    local ok, path_or_err = pcall(function()
        local path = require(RACE_PATH_MODULE)("beamcomp_parse")
        path:onDeserialized(json)
        path:autoConfig()
        return path
    end)
    if not ok then
        log("E", LOG_TAG, "failed to load race '" .. tostring(race_file) .. "': "
            .. tostring(path_or_err))
        return nil
    end
    return path_or_err
end

-- The selector ids (default/reverse/rolling/rollingReverse) that resolve to a real
-- start position. The engine remaps these to runtime ids on load, so they index
-- straight into path.startPositions.objects.
local function build_selectors(path)
    local selectors = {}
    local roles = {
        default = path.defaultStartPosition,
        reverse = path.reverseStartPosition,
        rolling = path.rollingStartPosition,
        rollingReverse = path.rollingReverseStartPosition,
    }
    for role, id in pairs(roles) do
        if start_position_exists(path, id) then
            selectors[role] = id
        end
    end
    return selectors
end

-- All start poses, in the engine's sorted order, plus the selector map.
local function build_start_positions(path)
    local list = {}
    for _, sp in ipairs(path.startPositions.sorted) do
        list[#list + 1] = {
            id = sp.id,
            name = sp.name,
            pos = vec3_to_table(sp.pos),
            rot = quat_to_table(sp.rot),
        }
    end
    return {list = list, selectors = build_selectors(path)}
end

-- Visible checkpoints in traversal order, each with a stable 0-based index. Order comes
-- from the engine's linear path (path.lua autoConfig). A closed loop repeats the start
-- node at the end, so node ids already emitted are skipped.
local function build_checkpoints(path)
    local checkpoints = {}
    local seen = {}
    local nodes = path.pathnodes.objects
    for _, node_id in ipairs(linear_pathnodes(path)) do
        local node = nodes[node_id]
        if node and node.visible and not seen[node_id] then
            seen[node_id] = true
            local checkpoint = {
                index = #checkpoints,
                name = node.name,
                pos = vec3_to_table(node.pos),
                radius = node.radius,
                useAsSplit = node.useAsSplit and true or false,
            }
            if node.hasNormal then
                checkpoint.normal = vec3_to_table(node.normal)
            end
            checkpoints[#checkpoints + 1] = checkpoint
        end
    end
    return checkpoints
end

-- The full ordered race line as {pos = {x,y,z}, radius = n} points -- every path node in traversal order,
-- visible AND invisible, deduped against the immediately preceding node (a closed loop repeats the start
-- node). This is the authored racing line (ADR-0036): denser than the visible checkpoints, so the AI hugs
-- the line instead of cutting between sparse checkpoints. The per-node radius is the corridor half-width
-- the AI may use (the `r` of the driveUsingPath script, ADR-0036 Step-3b). Display + scoring still use
-- build_checkpoints (visible only); this list only drives the AI opponents. Same `.pos` shape as a
-- checkpoint so the AI driver consumes either.
local function build_route_points(path)
    local points = {}
    local nodes = path.pathnodes.objects
    local last_id = nil
    for _, node_id in ipairs(linear_pathnodes(path)) do
        local node = nodes[node_id]
        if node and node_id ~= last_id then
            points[#points + 1] = {pos = vec3_to_table(node.pos), radius = node.radius}
            last_id = node_id
        end
    end
    return points
end

-- Every prefab file shipped in the race folder, as the race props. A mission's props live in its
-- sibling *.prefab.json files (the path object's own prefab lists are usually empty -- ADR-0024/
-- format ref s8.9), and mission types name them differently (timeTrial: mainPrefab.prefab.json;
-- aiRace: its own names, ADR-0035), so the folder is globbed rather than probing fixed names. Sorted
-- for a deterministic spawn order across clients. coneFiles is empty: a mission prefab is JSONL with
-- its cones as sibling lines of the statics, so the host's full-prefab spawn already instantiates them
-- (ADR-0020) -- the separate coneFiles source is only for the quickrace format (ADR-0025).
local function build_prop_refs(folder)
    local prefab_files = FS:findFiles(folder, "*.prefab.json", -1, true, false)
    table.sort(prefab_files)
    return {prefabFiles = prefab_files, coneFiles = {}}
end

-- A mission's missionTypeData from its sibling info.json (ADR-0024), or nil when there is no info.json
-- or no missionTypeData. The single source for both the default lap count and the aiRace AI defaults, so
-- the file is read once per parse.
local function read_mission_type_data(folder)
    if not folder then
        return nil
    end
    local info_file = folder .. "info.json"
    if not FS:fileExists(info_file) then
        return nil
    end
    local info = jsonReadFile(info_file)
    if type(info) ~= "table" or type(info.missionTypeData) ~= "table" then
        return nil
    end
    return info.missionTypeData
end

-- A mission's authoritative default lap count, from its missionTypeData (ADR-0024). BeamNG stores a
-- mission's real default there; the race.race.json's own defaultLaps is an editor value that disagrees
-- for stock closed circuits (e.g. 004-mediumcourse: info 1 vs race 2). The field name is mission-type-
-- specific: timeTrial and rallyStage use "defaultLaps", aiRace uses "lapCount" (ADR-0035; its goalLaps/
-- goalTime are challenge targets, not the race length). crawl is a points/recoveries type with no lap
-- field, so this returns nil there -- moot anyway, since crawl (like rallyStage) is Sprint-normalized and
-- laps are ignored for point-to-point races. Returns the number, or nil -- the caller then keeps the
-- path object's value (mod races that ship only a race.race.json).
local function mission_default_laps(mission_type_data)
    if type(mission_type_data) ~= "table" then
        return nil
    end
    return tonumber(mission_type_data.defaultLaps or mission_type_data.lapCount)
end

-- An aiRace's authored AI defaults from its missionTypeData (ADR-0036 Etappe B): the racer count and the
-- defensive driving params the content ships, plus any content-specified racer vehicle(s). These fill the
-- gaps when /race omits an explicit count/preset/aicar. Returns a table with whichever fields were found,
-- or nil when none are -- so meta.aiDefaults stays nil for non-aiRace content.
local function mission_ai_defaults(mission_type_data)
    if type(mission_type_data) ~= "table" then
        return nil
    end
    local defaults = {
        count = tonumber(mission_type_data.racerCount),
        skill = tonumber(mission_type_data.racerSkill),
        aggression = tonumber(mission_type_data.racerAggression),
    }
    if type(mission_type_data.racerVehicle) == "string" then
        defaults.vehicles = {mission_type_data.racerVehicle}
    elseif type(mission_type_data.racerVehicles) == "table" then
        defaults.vehicles = mission_type_data.racerVehicles
    end
    if defaults.count or defaults.skill or defaults.aggression or defaults.vehicles then
        return defaults
    end
    return nil
end

-- defaultLaps is the override (from the mission info.json) when given, else the path object's own value;
-- branching/reversible always come from the loaded path so meta stays consistent with the checkpoints/
-- segments the path produced. closed likewise follows the path, EXCEPT when force_open is set: the
-- Sprint-normalized sources (rallyStage/crawl) always list as point-to-point (closed = false) by
-- contract, independent of their authored geometry. aiDefaults carries the aiRace content AI defaults
-- (ADR-0036 Etappe B), nil for non-aiRace content.
local function build_meta(path, default_laps_override, ai_defaults, force_open)
    local closed = path.config.closed and true or false
    if force_open then
        closed = false
    end
    return {
        name = path.name,
        defaultLaps = default_laps_override or path.defaultLaps,
        closed = closed,
        branching = path.config.branching and true or false,
        reversible = is_reversible(path),
        aiDefaults = ai_defaults,
    }
end

-- Parse a discovery locator into the normalized BeamComp race-content table (ADR-0005). Dispatches by
-- locator.format: a "quickrace" track is loaded via the engine quickrace importer (race/quickrace), any
-- other locator (a race.race.json -- mission or level .race.json) via path:onDeserialized; both reduce
-- to the same model. A mission's default lap count is taken from its sibling info.json (ADR-0024). The
-- Sprint-normalized sources (rallyStage/crawl) are pinned to meta.closed = false regardless of their
-- authored geometry (feature: parse-rally-and-crawl-stages). Quickrace props are the track's nested
-- barrier prefabs (statics, all clients) plus the track prefab itself as a host-only cone source
-- (coneFiles, ADR-0025). Returns the table, or nil plus a reason string on failure.
function M.parse(locator)
    if type(locator) ~= "table" or not locator.raceFile or locator.raceFile == "" then
        return nil, "no race file given"
    end

    local race_file = locator.raceFile
    local folder = locator.folder or folder_of(race_file)

    local path, default_laps, ai_defaults
    if locator.format == "quickrace" then
        local err
        path, err = quickrace.load_path(locator)
        if not path then
            return nil, err
        end
    else
        path = load_race_path(race_file)
        if not path then
            return nil, "could not load race file"
        end
        local mission_type_data = read_mission_type_data(folder)
        default_laps = mission_default_laps(mission_type_data)
        ai_defaults = mission_ai_defaults(mission_type_data)
    end

    if path.config.branching then
        log("W", LOG_TAG, "branching race unsupported: " .. race_file)
        return nil, "branching unsupported"
    end

    -- autoConfig leaves config empty (no traversal node list) when the start node is missing.
    if not linear_pathnodes(path) then
        log("W", LOG_TAG, "race has no traversable path: " .. race_file)
        return nil, "race has no traversable path"
    end

    local props = (locator.source == "quickrace") and quickrace.prop_refs(locator)
        or build_prop_refs(folder)
    local force_open = SPRINT_NORMALIZED_SOURCES[locator.source]
    local race = {
        raceFile = race_file,
        folder = folder,
        meta = build_meta(path, default_laps, ai_defaults, force_open),
        startPositions = build_start_positions(path),
        checkpoints = build_checkpoints(path),
        -- The dense authored race line for AI driving (ADR-0036); display/scoring use checkpoints.
        routePoints = build_route_points(path),
        props = props,
    }

    log("I", LOG_TAG, string.format(
        "parsed race '%s': %d checkpoints, %d route points, %d start positions, %d prefab(s)",
        tostring(race.meta.name), #race.checkpoints, #race.routePoints, #race.startPositions.list,
        #race.props.prefabFiles))
    return race
end

return M
