-- BeamComp -- the drag race's engine touchpoints (ADR-0067).
--
-- Lives at lua/ge/extensions/beamcomp/race/dragworld.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1). Every call here touches the engine and is probed and guarded (ADR-0017): a missing object or
-- function degrades to doing nothing, with one log line naming it.
--
-- Three things live here:
--   * the strip's Christmas tree: TSStatic objects in the level, hidden by default, named
--     <strip.id>_<light>_<lane> (gameplay/drag/display.lua resolveSceneObject), with optional light sources
--     <name>_light_forward / _light_backward. A lamp is lit by showing the object and enabling its sources.
--     Each client sets its own copy; the server only sends the timing.
--   * the game's own freeroam drag start: a 6 m trigger on every stage waypoint (gameplay/drag/poi.lua) starts
--     the game's drag race the moment a player's car stands there -- which is where ours stage. It returns
--     early when the lane's POI join is already marked as sent, so we mark it for the event through the
--     public setter and take back only the marks we set.
--   * a car's position and speed along the strip.

local M = {}

local LOG_TAG = "beamcomp.race"

-- The lamps of one lane BeamComp drives. The pre-stage and stage bulbs stay dark: staging is direct
-- (Fragerunde answer 10).
M.LAMPS = {"amber1", "amber2", "amber3", "green", "red"}

local function find(name)
    if not scenetree or type(scenetree.findObject) ~= "function" then
        return nil
    end
    local ok, obj = pcall(scenetree.findObject, name)
    return ok and obj or nil
end

local function set_lamp(lamp, lit)
    if lamp.lit == lit then
        return
    end
    lamp.lit = lit
    if lamp.obj then
        pcall(function() lamp.obj:setHidden(not lit) end)
    end
    for _, source in ipairs(lamp.sources) do
        pcall(function() source:setLightEnabled(lit) end)
    end
end

-- (public) Resolve the tree of a strip: {lanes = {[lane] = {[lamp] = {obj, sources, lit}}}, found, total}.
-- Logs once how many lamps were found; with none the HUD tree is the only one.
function M.bind_tree(strip_id, lane_count)
    local tree = {lanes = {}, found = 0, total = 0}
    for lane = 1, lane_count do
        local lamps = {}
        for _, name in ipairs(M.LAMPS) do
            local base = strip_id .. "_" .. name .. "_" .. lane
            local sources = {}
            for _, suffix in ipairs({"_light_forward", "_light_backward"}) do
                local source = find(base .. suffix)
                if source then
                    sources[#sources + 1] = source
                end
            end
            local obj = find(base)
            lamps[name] = {obj = obj, sources = sources, lit = nil}
            tree.total = tree.total + 1
            if obj then
                tree.found = tree.found + 1
            end
        end
        tree.lanes[lane] = lamps
    end
    log(tree.found > 0 and "I" or "W", LOG_TAG, string.format(
        "drag tree '%s': %d of %d lamps found%s", tostring(strip_id), tree.found, tree.total,
        tree.found > 0 and "" or ", only the HUD tree shows"))
    return tree
end

-- (public) Light one lane: `state` = {amber = bool, green = bool, red = bool}.
function M.set_lane(tree, lane, state)
    local lamps = tree and tree.lanes[lane]
    if not lamps then
        return
    end
    set_lamp(lamps.amber1, state.amber == true)
    set_lamp(lamps.amber2, state.amber == true)
    set_lamp(lamps.amber3, state.amber == true)
    set_lamp(lamps.green, state.green == true)
    set_lamp(lamps.red, state.red == true)
end

-- (public) Every lamp of the tree dark.
function M.dark(tree)
    if not tree then
        return
    end
    for lane in pairs(tree.lanes) do
        M.set_lane(tree, lane, {})
    end
end

-- The game's drag core, or nil plus why not.
local function drag_core()
    local core = rawget(_G, "gameplay_drag_core")
    if type(core) ~= "table" then
        return nil, "the game's drag system is not loaded"
    end
    if type(core.getDragDataForLevel) ~= "function" or type(core.setPoiJoinRequestSent) ~= "function"
        or type(core.isPoiJoinRequestSent) ~= "function" then
        return nil, "the game's drag system has no POI join setter"
    end
    return core
end

-- (public) Keep the game's freeroam drag race from starting on this strip while our event runs. `block` is
-- the record of an earlier call (or nil): this is re-asserted at every heat, because the game's drag system
-- may load after the race started, and only the change is logged. Returns the updated record
-- {keys = {key = true}, state = "blocked"|<reason>}.
function M.block_game_drag(block, map, settings_id, lane_count)
    block = block or {keys = {}, state = nil}
    local core, reason = drag_core()
    local state = reason
    if core then
        local ok, list = pcall(core.getDragDataForLevel, map)
        local file_id
        for _, data in ipairs(ok and type(list) == "table" and list or {}) do
            if type(data) == "table" and data.id == settings_id then
                file_id = data._fnWithoutExt
            end
        end
        if type(file_id) ~= "string" then
            state = "no drag data for '" .. tostring(settings_id) .. "' on '" .. tostring(map) .. "'"
        else
            for lane = 1, lane_count do
                local key = file_id .. "-" .. lane
                if not block.keys[key] and not core.isPoiJoinRequestSent(key) then
                    core.setPoiJoinRequestSent(key, true)
                    block.keys[key] = true
                end
            end
            state = "blocked"
        end
    end
    if state ~= block.state then
        block.state = state
        if state == "blocked" then
            log("I", LOG_TAG, "drag: the game's own drag start on '" .. tostring(settings_id) .. "' is blocked")
        else
            log("W", LOG_TAG, "drag: the game's own drag start on '" .. tostring(settings_id)
                .. "' is NOT blocked (" .. tostring(state) .. ")")
        end
    end
    return block
end

-- (public) Take back the POI marks `block` set; marks the game set itself stay.
function M.unblock_game_drag(block)
    if not block then
        return
    end
    local core = drag_core()
    if core then
        for key in pairs(block.keys) do
            pcall(core.setPoiJoinRequestSent, key, false)
        end
    end
    block.keys = {}
end

-- (public) Whether the game's own drag race is running on this client: the tripwire for a block that did
-- not hold.
function M.game_drag_started()
    local core = drag_core()
    if not core or type(core.getDragIsStarted) ~= "function" then
        return false
    end
    local ok, started = pcall(core.getDragIsStarted)
    return ok and started == true
end

-- (public) A vehicle's position {x, y, z}, its speed along `axis` (m/s) and its nose pitch (the forward
-- vector's z), or nil when it cannot be read.
function M.motion(veh, axis)
    if not veh then
        return nil
    end
    local ok, pos, vel, dir = pcall(function()
        return veh:getPosition(), veh:getVelocity(), veh:getDirectionVector()
    end)
    if not ok or not pos or not vel then
        return nil
    end
    return {x = pos.x, y = pos.y, z = pos.z}, vel.x * axis.x + vel.y * axis.y, dir and dir.z or 0
end

return M
