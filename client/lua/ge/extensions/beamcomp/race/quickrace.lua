-- BeamComp -- GE-side loader for legacy level "quickrace" tracks (the in-game Time Trial menu set).
--
-- Lives at lua/ge/extensions/beamcomp/race/quickrace.lua inside the client mod zip. Stateless:
-- require it and call M.load_path(locator). Target: client GE (LuaJIT 5.1).
--
-- A level's quickrace tracks (/levels/<map>/quickrace/<track>.json) are a different on-disk format
-- from the missions race.race.json: a `lapConfig` of waypoint *names* plus a sibling `.prefab` holding
-- the spawn spheres, with the checkpoint waypoints living as permanent level objects in the level's
-- MissionGroup (ADR-0024). They cannot be read by path:onDeserialized. Instead we reuse the engine's
-- own quickrace importer: assemble the small trackInfo table that gameplay/race/path.lua:fromTrack
-- expects (mirroring scenario/quickRaceLoader.lua:getTracks) and let it build the path -- it spawns the
-- track prefab to read the spawn spheres, resolves the lapConfig waypoints from the scene, builds
-- pathnodes + segments, then deletes the spawned prefab. We then autoConfig so the result is the same
-- configured path object the parser normalizes for a race.race.json (ADR-0005).

local M = {}

local LOG_TAG = "beamcomp.race"
local RACE_PATH_MODULE = "/lua/ge/extensions/gameplay/race/path"

-- The spawn-sphere object-name convention quickRaceLoader.getTracks applies when a track does not name
-- its own spawn spheres: "<trackName>_<role>_spawn" for each start role. fromTrack reads these from the
-- scene (the track prefab it spawns) to build the start positions.
local SPAWN_SPHERE_ROLES = {
    standing = "_standing_spawn",
    standingReverse = "_standingReverse_spawn",
    rolling = "_rolling_spawn",
    rollingReverse = "_rollingReverse_spawn",
}

-- Build the trackInfo table fromTrack consumes from a raw quickrace json + its locator. Mirrors the
-- subset of scenario/quickRaceLoader.lua:getTracks that fromTrack actually reads. prefabs is left empty
-- on purpose: the checkpoint waypoints are permanent level objects (MissionGroup), so they resolve
-- without spawning the track's barrier prefabs; fromTrack still auto-spawns "<dir><trackName>.prefab"
-- for the spawn spheres.
local function build_track_info(info, locator)
    local spawn_spheres = {}
    for role, suffix in pairs(SPAWN_SPHERE_ROLES) do
        spawn_spheres[role] = locator.trackName .. suffix
    end

    return {
        originalInfo = info,
        trackName = locator.trackName,
        directory = locator.folder,
        prefabs = {},
        startLineCheckpoint = info.startLineCheckpoint,
        finishLineCheckpoint = info.finishLineCheckpoint,
        closed = info.closed and true or false,
        lapCount = tonumber(info.lapCount) or 1,
        spawnSpheres = spawn_spheres,
    }
end

-- Load a quickrace track locator into a configured engine path, or nil plus a reason. Wrapped in pcall
-- so a malformed track or a missing scene waypoint never throws into the engine. The returned path is
-- autoConfig'd, so it carries the same traversal node list (config.linearPathnodes since BeamNG
-- 0.39, linearSegments before) the parser's build_checkpoints reads.
function M.load_path(locator)
    local info = jsonReadFile(locator.raceFile)
    if type(info) ~= "table" then
        log("E", LOG_TAG, "quickrace file not found or unreadable: " .. tostring(locator.raceFile))
        return nil, "could not read quickrace file"
    end
    if type(info.lapConfig) ~= "table" or #info.lapConfig == 0 then
        log("W", LOG_TAG, "quickrace file has no lapConfig: " .. tostring(locator.raceFile))
        return nil, "not a quickrace track"
    end

    local track_info = build_track_info(info, locator)

    local ok, path_or_err = pcall(function()
        local path = require(RACE_PATH_MODULE)("beamcomp_quickrace")
        if not path:fromTrack(track_info, true) then
            error("fromTrack failed (a lapConfig waypoint is missing from the scene)")
        end
        path:autoConfig()
        return path
    end)
    if not ok then
        log("E", LOG_TAG, "failed to load quickrace '" .. tostring(locator.raceFile) .. "': "
            .. tostring(path_or_err))
        return nil, "could not load quickrace track"
    end
    return path_or_err
end

-- The prop references a quickrace track places (ADR-0024/0025), as a {prefabFiles, coneFiles} table
-- matching the parser's prop-ref shape:
--   * prefabFiles -- the track's static barriers, spawned on every client. A legacy quickrace .prefab
--     nests its barriers as `new Prefab() { FileName = "<path>"; }` blocks; we pull those paths out.
--     They are cone-free TSStatic, so they spawn safely on every client.
--   * coneFiles -- the track prefab itself, whose cone prop-vehicles (BeamNGVehicle, NOT
--     FileName-referenced) live as direct child blocks. The host spawns a cones-only copy of it so the
--     cones exist once and BeamMP syncs them (ADR-0025); non-hosts never spawn it.
-- A track with no readable prefab simply gets no props.
function M.prop_refs(locator)
    local files = {}
    local cone_files = {}
    if type(readFile) ~= "function" then
        return {prefabFiles = files, coneFiles = cone_files}
    end
    for _, ext in ipairs({".prefab", ".prefab.json"}) do
        local track_prefab = locator.folder .. locator.trackName .. ext
        if FS:fileExists(track_prefab) then
            cone_files[#cone_files + 1] = track_prefab
            local raw = readFile(track_prefab)
            if raw then
                for nested in raw:gmatch('FileName%s*=%s*"([^"]+)"') do
                    if nested:find("%.prefab$") or nested:find("%.prefab%.json$") then
                        files[#files + 1] = nested
                    end
                end
            end
        end
    end
    return {prefabFiles = files, coneFiles = cone_files}
end

return M
