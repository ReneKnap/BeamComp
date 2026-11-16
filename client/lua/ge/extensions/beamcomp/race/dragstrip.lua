-- BeamComp -- the game's drag strips as a race source (ADR-0067).
--
-- Lives at lua/ge/extensions/beamcomp/race/dragstrip.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Stateless.
--
-- The game ships its drag strips as plain JSON under /levels/<map>/dragstrips/: <id>.dragSettings.json names
-- the strip file, the timers and the tree, <id>_main.strip.json holds the lanes with their stage and endLine
-- waypoints, and <id>.facility.json the strip's title. The engine's race-path loader (ADR-0005) cannot read
-- them, so this module builds the SAME normalized race model the parser builds for a mission race:
--   startPositions -- one pose at the stage-line midpoint, facing down the strip;
--   checkpoints    -- CP0 the start line, CP1 the finish, both with the strip axis as their gate normal;
--   routePoints    -- the two of them;
--   props          -- none (the strip is level geometry);
--   meta.strip     -- the strip facts (lanes, axis, timers, tree, waypoint names, default grid), plain tables,
--                     so the ADR-0039 relay carries them unchanged.
-- M.locators finds the strips on one map, M.parse reads one, M.build is the pure part of M.parse. A strip is a
-- race like any other (ADR-0067 amendments 2026-11-15 and 2026-11-16): it is listed as one and runs in the Drag
-- mode, which every race offers, or as a sprint from its stage line to its 1/4 mile line over the two gates
-- below. The timers and the queue below also serve a drag race on a normal race (race/start.lua).

local M = {}

local LOG_TAG = "beamcomp.race"

-- The finish is the farthest distance timer (the game's own rule, gameplay/drag/phaseHandlers.lua
-- getRaceEndTimerId); this and the reaction beam are only the fallbacks for a settings file without timers.
local QUARTER_MILE = 402.336
local REACTION_BEAM = 0.178

-- The timers the game falls back to when a settings file carries none (gameplay/drag/saveSystem.lua
-- DEFAULT_TIMERS), in the order the timeslip lists them.
local DEFAULT_TIMERS = {
    {id = "reactionTime", label = "Reaction Time", shortLabel = "R/T", type = "distanceTimer",
        distance = REACTION_BEAM},
    {id = "time_60", label = "60 ft", shortLabel = "60'", type = "distanceTimer", distance = 18.288},
    {id = "time_330", label = "330 ft", shortLabel = "330'", type = "distanceTimer", distance = 100.584},
    {id = "time_1_8", label = "1/8 mile", shortLabel = "1/8", type = "distanceTimer", distance = 201.168},
    {id = "time_1000", label = "1000 ft", shortLabel = "1000'", type = "distanceTimer", distance = 304.8},
    {id = "time_1_4", label = "1/4 mile", shortLabel = "1/4", type = "distanceTimer", distance = QUARTER_MILE},
    {id = "velAt_1_8", label = "Speed at 1/8 mile", type = "velocity", distance = 201.168},
    {id = "velAt_1_4", label = "Speed at 1/4 mile", type = "velocity", distance = QUARTER_MILE},
}

-- The lane gap of a strip whose lanes cannot be measured (a single lane). The three shipped strips measure
-- 7.66 to 8.86 m.
local DEFAULT_LANE_GAP = 8.0

-- The checkpoint radius beyond the outer lanes, so the two gates span the whole strip in the editor preview.
local GATE_MARGIN = 4.0

-- The waiting queue behind the start line (ADR-0067 §2): its first row this far behind the deepest lane slot,
-- the rows this far apart, two columns one lane gap apart. Not part of the grid and not editable. The same on
-- every drag race, strip or not (race/start.lua).
M.QUEUE_SETBACK = 20.0
M.QUEUE_ROW_GAP = 10.0

-- The source string, the name prefix and the locator format every other module branches on.
M.SOURCE = "strip"
M.FORMAT = "dragStrip"

local SETTINGS_SUFFIX = ".dragSettings.json"

-- A {x, y, z} table from a strip transform position, or nil.
local function position_of(waypoint)
    local transform = type(waypoint) == "table" and waypoint.transform
    local pos = type(transform) == "table" and transform.position
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return nil
    end
    return {x = pos.x, y = pos.y, z = tonumber(pos.z) or 0}
end

-- The first waypoint of `kind` in a lane, or nil.
local function waypoint_of(lane, kind)
    if type(lane.waypoints) ~= "table" then
        return nil
    end
    for _, waypoint in ipairs(lane.waypoints) do
        if type(waypoint) == "table" and waypoint.type == kind then
            return waypoint
        end
    end
    return nil
end

local function lane_points(lanes, field)
    local points = {}
    for _, lane in ipairs(lanes) do
        points[#points + 1] = lane[field]
    end
    return points
end

local function mean(points)
    local x, y, z = 0, 0, 0
    for _, p in ipairs(points) do
        x, y, z = x + p.x, y + p.y, z + p.z
    end
    local n = #points
    return {x = x / n, y = y / n, z = z / n}
end

local function horizontal_unit(dx, dy)
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-6 then
        return nil
    end
    return {x = dx / length, y = dy / length, z = 0}
end

local function dot2(a, b)
    return a.x * b.x + a.y * b.y
end

-- The quaternion about vertical whose +Y the ENGINE turns onto `axis` (grid.lua engine_rotate: BeamNG's
-- q * v applies the conjugate rotation). Only carried on the start pose; every grid pose orients from the
-- gate normal (ADR-0023 amendment 2026-10-24), which is the same axis.
local function rotation_onto(axis)
    local angle = math.atan2(axis.x, axis.y)
    return {x = 0, y = 0, z = math.sin(angle / 2), w = math.cos(angle / 2)}
end

-- The timers of a settings file as {id, label, short, kind = "distance"|"speed", distance}, in file order.
local function build_timers(settings)
    local source = type(settings.timers) == "table" and #settings.timers > 0 and settings.timers
        or DEFAULT_TIMERS
    local timers = {}
    for _, timer in ipairs(source) do
        local distance = type(timer) == "table" and tonumber(timer.distance)
        local kind = (timer.type == "distanceTimer" and "distance")
            or (timer.type == "velocity" and "speed") or nil
        if distance and kind and type(timer.id) == "string" then
            timers[#timers + 1] = {
                id = timer.id,
                label = type(timer.label) == "string" and timer.label or timer.id,
                short = type(timer.shortLabel) == "string" and timer.shortLabel or nil,
                kind = kind,
                distance = distance,
            }
        end
    end
    return timers
end

-- The reaction beam (the shortest distance timer under half a metre) and the finish (the farthest one), as
-- {distance, id}. The game reads both the same way (times.lua, phaseHandlers.lua getRaceEndTimerId).
local function beam_and_finish(timers)
    local beam, finish
    for _, timer in ipairs(timers) do
        if timer.kind == "distance" then
            if timer.distance < 0.5 and (not beam or timer.distance < beam.distance) then
                beam = timer
            end
            if not finish or timer.distance > finish.distance then
                finish = timer
            end
        end
    end
    return {distance = beam and beam.distance or REACTION_BEAM, id = beam and beam.id or "reactionTime"},
        {distance = (finish and finish.distance > 1) and finish.distance or QUARTER_MILE,
            id = finish and finish.id or "time_1_4"}
end

-- (public) The game's default timers, parsed: what a drag race on a normal race measures (it has no settings
-- file). The beam and the 1/4 mile come first and last, like on a strip.
M.DEFAULT_TIMERS = build_timers({})
M.REACTION_BEAM = REACTION_BEAM

-- (public) Build the race model from decoded settings + strip tables. `settings_id` is the strip's own id
-- ("hirochiStrip"), `title` its display title. Returns the race table, or nil plus a reason.
function M.build(settings, strip, settings_id, title)
    if type(settings) ~= "table" or type(strip) ~= "table" or type(strip.lanes) ~= "table" then
        return nil, "drag strip data unreadable"
    end
    local scene_id = type(strip.id) == "string" and strip.id or settings_id

    local lanes = {}
    for index, lane in ipairs(strip.lanes) do
        local stage = type(lane) == "table" and position_of(waypoint_of(lane, "stage"))
        local finish_line = type(lane) == "table" and position_of(waypoint_of(lane, "endLine"))
        if stage and finish_line then
            lanes[#lanes + 1] = {
                index = index,
                name = type(lane.shortName) == "string" and lane.shortName or ("Lane " .. index),
                color = type(lane.color) == "string" and lane.color or nil,
                stage = stage,
                endLine = finish_line,
                -- The scene name of the lane's endLine waypoint: the AI's target (saveSystem.lua
                -- laneWaypointSceneName; the lane index is the strip file's lane order).
                target = scene_id .. "_wp_endLine_" .. index,
            }
        end
    end
    if #lanes == 0 then
        return nil, "drag strip has no lane with a stage and an endLine waypoint"
    end

    local origin = mean(lane_points(lanes, "stage"))
    local far = mean(lane_points(lanes, "endLine"))
    local axis = horizontal_unit(far.x - origin.x, far.y - origin.y)
    if not axis then
        return nil, "drag strip has no direction (stage and endLine coincide)"
    end
    local right = {x = axis.y, y = -axis.x, z = 0}

    local min_lateral, max_lateral = math.huge, -math.huge
    for _, lane in ipairs(lanes) do
        local offset = {x = lane.stage.x - origin.x, y = lane.stage.y - origin.y}
        lane.lateral = dot2(offset, right)
        lane.along = dot2(offset, axis)
        min_lateral = math.min(min_lateral, lane.lateral)
        max_lateral = math.max(max_lateral, lane.lateral)
        lane.endLine = nil
    end
    local lane_gap = (#lanes > 1) and (max_lateral - min_lateral) / (#lanes - 1) or DEFAULT_LANE_GAP

    local timers = build_timers(settings)
    local beam, finish = beam_and_finish(timers)
    local tree = type(settings.prefabs) == "table" and type(settings.prefabs.christmasTree) == "table"
        and settings.prefabs.christmasTree.treeType or nil

    local half_width = (max_lateral - min_lateral) / 2 + GATE_MARGIN
    local finish_pos = {x = origin.x + axis.x * finish.distance, y = origin.y + axis.y * finish.distance,
        z = origin.z}
    local name = (type(title) == "string" and title ~= "") and title or settings_id

    local facts = {
        stripId = scene_id,
        settingsId = settings_id,
        title = name,
        lanes = lanes,
        origin = origin,
        axis = axis,
        laneGap = lane_gap,
        beam = beam.distance,
        finish = finish.distance,
        finishTimer = finish.id,
        timers = timers,
        treeType = type(tree) == "string" and tree or nil,
        -- The procedural default grid (ADR-0067 §2): one slot per lane, on the stage waypoints, no stagger.
        -- Column 1 is the left of the travel direction, which is the lane the better seed takes.
        defaultParams = {
            offsetForward = 0,
            offsetLateral = (max_lateral + min_lateral) / 2,
            offsetHeight = 0,
            castHeight = 0,
            headingDeg = 0,
            rowGap = 0,
            colGap = lane_gap,
            columns = #lanes,
            mirror = false,
            noDowncast = false,
            noSlope = false,
        },
        defaultSlots = #lanes,
    }

    return {
        meta = {
            name = name,
            defaultLaps = 1,
            closed = false,
            branching = false,
            reversible = false,
            strip = facts,
        },
        startPositions = {
            list = {{id = "drag", name = "drag start", pos = origin, rot = rotation_onto(axis)}},
            selectors = {default = "drag"},
        },
        checkpoints = {
            {index = 0, name = "start", pos = origin, radius = half_width, useAsSplit = false,
                normal = {x = axis.x, y = axis.y, z = 0}},
            {index = 1, name = "finish", pos = finish_pos, radius = half_width, useAsSplit = false,
                normal = {x = axis.x, y = axis.y, z = 0}},
        },
        routePoints = {{pos = origin, radius = half_width}, {pos = finish_pos, radius = half_width}},
        props = {prefabFiles = {}, coneFiles = {}},
    }
end

-- The facility title next to a settings file, or nil.
local function read_title(folder, settings_id)
    local ok, facility = pcall(jsonReadFile, folder .. settings_id .. ".facility.json")
    if ok and type(facility) == "table" and type(facility.name) == "string" and facility.name ~= "" then
        return facility.name
    end
    return nil
end

-- (public) The drag strips on one map as discovery locators (ADR-0024 shape): id "<map>/strip/<settingsId>",
-- source "strip", format "dragStrip". One small folder listing per map; the title is read now so the race
-- lists can show it without parsing the strip.
function M.locators(map)
    local folder = "/levels/" .. map .. "/dragstrips/"
    local ok, files = pcall(function()
        return FS:findFiles(folder, "*" .. SETTINGS_SUFFIX, 0, true, false)
    end)
    local locators = {}
    if not ok or type(files) ~= "table" then
        return locators
    end
    for _, file in ipairs(files) do
        local settings_id = file:match("([^/]+)%.dragSettings%.json$")
        if settings_id then
            locators[#locators + 1] = {
                id = map .. "/" .. M.SOURCE .. "/" .. settings_id,
                displayName = settings_id,
                title = read_title(folder, settings_id) or settings_id,
                map = map,
                source = M.SOURCE,
                format = M.FORMAT,
                folder = folder,
                raceFile = file,
            }
        end
    end
    return locators
end

-- (public) Parse one strip locator into the race model, or nil plus a reason.
function M.parse(locator)
    local ok, settings = pcall(jsonReadFile, locator.raceFile)
    if not ok or type(settings) ~= "table" then
        return nil, "could not read " .. tostring(locator.raceFile)
    end
    if type(settings.stripId) ~= "string" then
        return nil, "drag settings name no strip file"
    end
    local strip_ok, strip = pcall(jsonReadFile, settings.stripId)
    if not strip_ok or type(strip) ~= "table" then
        return nil, "could not read " .. settings.stripId
    end
    local race, err = M.build(settings, strip, locator.displayName, locator.title)
    if not race then
        log("W", LOG_TAG, "drag strip '" .. tostring(locator.id) .. "': " .. tostring(err))
        return nil, err
    end
    race.raceFile = locator.raceFile
    race.folder = locator.folder
    local facts = race.meta.strip
    -- The level the game's own drag facility is looked up on (race/dragworld.lua block_game_drag).
    facts.map = locator.map
    log("I", LOG_TAG, string.format(
        "parsed drag strip '%s': %d lane(s) %.2f m apart, finish %.3f m, %d timer(s), tree %s",
        tostring(locator.id), #facts.lanes, facts.laneGap, facts.finish, #facts.timers,
        tostring(facts.treeType)))
    return race
end

return M
