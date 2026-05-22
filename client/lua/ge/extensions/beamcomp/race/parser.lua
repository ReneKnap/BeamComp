-- BeamComp -- GE-side time-trial race parser.
--
-- Lives at lua/ge/extensions/beamcomp/race/parser.lua inside the client mod zip.
-- Stateless: require it and call M.parse(raceFile). It holds no state and registers
-- nothing, so it needs no extension lifecycle (cf. the race-format reference note s9).
--
-- Reuses BeamNG's own race loader (gameplay/race/path.lua) rather than reparsing the
-- race.race.json by hand -- the loader handles oldId remapping, segment ordering, and
-- classification. M.parse normalizes the loaded path object into a plain-Lua,
-- engine-handle-free table (ADR-0005): start positions, ordered visible checkpoints
-- with a stable 0-based index, prefab file references, and meta. The data-model
-- contract lives in .claude/features/race-parser/2-architecture.md.

local M = {}

local LOG_TAG = "beamcomp.race"
local RACE_PATH_MODULE = "/lua/ge/extensions/gameplay/race/path"
local PREFAB_FILENAMES = {
    "mainPrefab.prefab.json",
    "forwardPrefab.prefab.json",
    "reversePrefab.prefab.json",
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
    for _, node_id in ipairs(path.config.linearSegments) do
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

-- The prefab files that actually ship in the race folder (main + optional fwd/rev).
local function build_prop_refs(folder)
    local prefab_files = {}
    for _, name in ipairs(PREFAB_FILENAMES) do
        local file = folder .. name
        if FS:fileExists(file) then
            prefab_files[#prefab_files + 1] = file
        end
    end
    return {prefabFiles = prefab_files}
end

local function build_meta(path)
    return {
        name = path.name,
        defaultLaps = path.defaultLaps,
        closed = path.config.closed and true or false,
        branching = path.config.branching and true or false,
        reversible = is_reversible(path),
    }
end

-- Parse a time-trial race.race.json into the normalized BeamComp race-content table
-- (ADR-0005). Returns the table, or nil plus a reason string on failure.
function M.parse(race_file)
    if not race_file or race_file == "" then
        return nil, "no race file given"
    end

    local path = load_race_path(race_file)
    if not path then
        return nil, "could not load race file"
    end

    if path.config.branching then
        log("W", LOG_TAG, "branching race unsupported: " .. race_file)
        return nil, "branching unsupported"
    end

    -- autoConfig leaves config empty (no linearSegments) when the start node is missing.
    if not path.config.linearSegments then
        log("W", LOG_TAG, "race has no traversable path: " .. race_file)
        return nil, "race has no traversable path"
    end

    local folder = folder_of(race_file)
    local race = {
        raceFile = race_file,
        folder = folder,
        meta = build_meta(path),
        startPositions = build_start_positions(path),
        checkpoints = build_checkpoints(path),
        props = build_prop_refs(folder),
    }

    log("I", LOG_TAG, string.format(
        "parsed race '%s': %d checkpoints, %d start positions, %d prefab(s)",
        tostring(race.meta.name), #race.checkpoints, #race.startPositions.list,
        #race.props.prefabFiles))
    return race
end

return M
