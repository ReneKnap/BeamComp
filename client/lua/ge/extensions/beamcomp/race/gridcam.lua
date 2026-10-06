-- BeamComp -- the grid editor's camera (ADR-0063).
--
-- Lives at lua/ge/extensions/beamcomp/race/gridcam.lua inside the client mod zip. Target: client GE
-- (LuaJIT 5.1).
--
-- Puts the free camera above slot 1 of the grid being edited, and puts the camera back where it was
-- when the editing is over. Three entry points, each answering one question exactly once:
--
--   M.step(editor, in_race)  every frame: did a session start, or did a direction switch move slot 1
--                            further than FOLLOW_DISTANCE? It WATCHES grideditor.state instead of being
--                            called by each place that starts a session: grideditor.enter bumps
--                            state.session whoever called it, so a session start nobody here has heard
--                            of still moves the camera.
--   M.to_grid(...)           the jump itself, for step and for the panel's Camera to grid button.
--   M.leave(exit)            the ONE way out. EXITS states for every exit what happens to the camera;
--                            a call site only names itself.
--
-- The remembered camera (M.state.saved) is written by the FIRST jump of a visit and by nothing else, and
-- it is written BEFORE anything moves: no jump without a way back. A later jump -- another grid loaded, a
-- direction switch, the button -- never overwrites it, or Close would return to the first grid instead of
-- to where the player started. A visit is wider than one editor session on purpose: New and Load replace
-- the session in the middle of it.
--
-- Every engine call is probed and pcall-guarded (ADR-0017). The path is the engine's own recovery camera
-- (core/recoveryCamera.lua): commands.setFreeCamera + core_camera.setPosRot in, commands.setGameCamera
-- back out. M.state holds plain data only and a GE Lua reload rebuilds it, which is why the `reload` exit
-- restores first, from init.lua's onExtensionUnloaded (ADR-0052).

local M = {}

local maps = require("beamcomp/race/maps")

local LOG_TAG = "beamcomp.grid"

-- The pose above slot 1. HEIGHT is the owner's number ("vllt ca 10"); BACK_OFFSET, PITCH_DEG and the
-- view direction are assumptions for him to accept or change in game. Fields, not locals, so they can be
-- tuned live from the GE console (beamcomp_init.gridcam.PITCH_DEG = 45) and the next jump uses them.
M.HEIGHT = 10.0        -- meters above slot 1
M.BACK_OFFSET = 6.0    -- meters the camera is pulled back from slot 1, along its own view
M.PITCH_DEG = 35.0     -- degrees the view points below the horizon
-- Slot 1 is the FRONT slot and the field lies behind it, against the direction of travel. false looks
-- back down the field: the front slots near, the rear ones in the depth. true looks the way the cars face:
-- slot 1 and the start line, with the rest of the field behind the camera.
M.LOOK_ALONG_TRAVEL = false

-- A direction switch moves the camera only when slot 1 moved further than this, in meters.
M.FOLLOW_DISTANCE = 100.0

-- The three things an exit can do. Every one of them forgets the remembered camera.
local RESTORE = "restore"        -- put the camera back exactly as it was before the first jump
local TO_VEHICLE = "to_vehicle"  -- no old pose: a camera still free from our jump goes into the car
local DROP = "drop"              -- leave the camera where it is

-- What every way out of an edit visit does with the camera. The whole answer, in one place.
-- NOT an exit, on purpose: init.lua's M.clear_grid_editor on its own. It looks like the end of a session
-- and is not one -- it is the teardown primitive Close is built from, and it leaves the remembered camera
-- standing for the Close that follows. An exit missing from this table is reported and dropped, so the
-- camera never moves on a path nobody decided.
local EXITS = {
    close = RESTORE,      -- the panel's Close (M.close_grid_editor)
    cancel = RESTORE,     -- the beamcomp_grid_cancel console command
    reload = RESTORE,     -- a GE Lua reload: afterwards nothing knows where the camera was
    -- raceStart: an old pose would fight the race placement, so none comes back. But a start that only
    -- teleports the car spawns nothing, BeamMP then never switches to the vehicle camera, and the driver
    -- would sit in our free camera above some grid (owner's decision 2026-10-06).
    race = TO_VEHICLE,
    level = DROP,         -- onClientEndMission: a pose on the old level means nothing on the next one
}

M.state = {
    -- The camera from before the first jump of this visit, or nil. Written once by M.to_grid, cleared
    -- only by M.leave. {map, kind = "vehicle"|"global", source} plus, for a global camera, its name,
    -- pos, rot and fov.
    saved = nil,
}

-- What M.step saw last frame: which session, which direction, and where slot 1 stood. Plain
-- bookkeeping, never a reason to move the camera by itself.
local watch = {session = nil, direction = nil, x = nil, y = nil, z = nil}

-- The grounded first preview pose of the session, or nil when there is none to fly to.
local function first_slot(editor)
    local slot = editor.poses and editor.poses[1]
    if slot and slot.pos and slot.faceDir then
        return slot
    end
    return nil
end

local function describe_target(editor)
    return "'" .. tostring(editor.race) .. "' (" .. tostring(editor.direction) .. ")"
end

local function describe_camera(saved)
    if saved.kind == "vehicle" then
        return "the vehicle camera"
    end
    if saved.name == "free" then
        return "the free camera at its pose"
    end
    return "the '" .. saved.name .. "' camera at its pose"
end

-- The engine names a jump and its way back depend on. A name this game version does not have is
-- reported by name, not discovered as a camera that silently never moves (ADR-0017).
local function missing_engine_names()
    local missing = {}
    local function expect(is_present, name)
        if not is_present then
            missing[#missing + 1] = name
        end
    end
    local has_commands = type(commands) == "table"
    local has_camera = type(core_camera) == "table"
    expect(has_commands and type(commands.setFreeCamera) == "function", "commands.setFreeCamera")
    expect(has_commands and type(commands.setGameCamera) == "function", "commands.setGameCamera")
    expect(has_camera and type(core_camera.setPosRot) == "function", "core_camera.setPosRot")
    expect(has_camera and type(core_camera.getPosition) == "function", "core_camera.getPosition")
    expect(has_camera and type(core_camera.getQuat) == "function", "core_camera.getQuat")
    expect(type(quatFromDir) == "function", "quatFromDir")
    expect(type(vec3) == "function", "vec3")
    expect((has_camera and type(core_camera.getActiveGlobalCameraName) == "function")
        or (has_commands and type(commands.isFreeCamera) == "function"),
        "core_camera.getActiveGlobalCameraName or commands.isFreeCamera")
    return missing
end

-- The active global camera's name (nil = a vehicle camera), and the engine call that answered.
local function read_active_camera()
    if type(core_camera.getActiveGlobalCameraName) == "function" then
        return core_camera.getActiveGlobalCameraName(0), "core_camera.getActiveGlobalCameraName"
    end
    return commands.isFreeCamera() and "free" or nil, "commands.isFreeCamera"
end

-- The camera as it is now, as plain data. A vehicle camera needs nothing more: vehicle cameras do not
-- run while a global one is active, so it resumes exactly as it was. A global camera keeps its pose and
-- its FOV, because entering the free camera resets the FOV.
local function capture_camera()
    local name, source = read_active_camera()
    local saved = {map = maps.current(), source = source}
    if name == nil then
        saved.kind = "vehicle"
        return saved
    end
    local pos = core_camera.getPosition()
    local rot = core_camera.getQuat()
    saved.kind = "global"
    saved.name = tostring(name)
    saved.pos = {x = pos.x, y = pos.y, z = pos.z}
    saved.rot = {x = rot.x, y = rot.y, z = rot.z, w = rot.w}
    if type(core_camera.getFovDeg) == "function" then
        saved.fov = core_camera.getFovDeg()
    end
    return saved
end

-- Enter the free camera and put it at pos/rot: the engine's own two steps (core/recoveryCamera.lua,
-- core/snapshot.lua). A fov is only passed on a restore, to undo the reset that entering does.
local function place_free_camera(pos, rot, fov)
    commands.setFreeCamera()
    core_camera.setPosRot(0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    if fov and type(core_camera.setFOV) == "function" then
        core_camera.setFOV(0, fov)
    end
end

-- The pose over `slot`: HEIGHT above it, BACK_OFFSET back along the view, PITCH_DEG down. The rotation is
-- the engine's quatFromDir, the call core_camera's own setFreeCameraYawPitchRollDeg builds a camera
-- rotation with. Deliberately not hand-rolled: BeamNG's quaternions turn the other way round from a
-- textbook Hamilton rotation (measured against common/mathlib.lua), so a hand-built one pitches UP.
local function overhead_pose(slot)
    local sign = M.LOOK_ALONG_TRAVEL and 1 or -1
    local look_x = slot.faceDir.x * sign
    local look_y = slot.faceDir.y * sign
    local pitch = math.rad(M.PITCH_DEG)
    local pos = {
        x = slot.pos.x - look_x * M.BACK_OFFSET,
        y = slot.pos.y - look_y * M.BACK_OFFSET,
        z = slot.pos.z + M.HEIGHT,
    }
    local dir = vec3(look_x * math.cos(pitch), look_y * math.cos(pitch), -math.sin(pitch))
    return pos, quatFromDir(dir, vec3(0, 0, 1))
end

-- Remember the camera if this is the visit's first jump, then move. Returns what was remembered, or nil
-- when an earlier jump already did.
local function jump(slot)
    local remembered = nil
    if not M.state.saved then
        M.state.saved = capture_camera()
        remembered = describe_camera(M.state.saved) .. " (" .. M.state.saved.source .. ")"
    end
    local pos, rot = overhead_pose(slot)
    place_free_camera(pos, rot)
    return remembered
end

-- commands.setGameCamera ends in setGlobalCameraByName(nil), which silently refuses without a player
-- vehicle -- so the callers ask first and say it instead.
local function has_player_vehicle()
    return type(getPlayerVehicle) ~= "function" or getPlayerVehicle(0) ~= nil
end

-- Put the camera back as `saved` describes it. Returns the log text for what happened.
local function restore(saved)
    if saved.map ~= maps.current() then
        return "stays where it is, " .. describe_camera(saved) .. " was remembered on another level"
    end
    if saved.kind == "vehicle" then
        if not has_player_vehicle() then
            return "stays free, there is no vehicle to go back to"
        end
        commands.setGameCamera()
        return "back to the vehicle camera via commands.setGameCamera"
    end
    place_free_camera(saved.pos, saved.rot, saved.fov)
    if saved.name ~= "free" then
        return "back to the old pose in the free camera (it was the '" .. saved.name .. "' camera)"
    end
    return "back to the free camera at its old pose via commands.setFreeCamera + core_camera.setPosRot"
end

local function is_free_camera()
    if type(commands.isFreeCamera) == "function" then
        return commands.isFreeCamera()
    end
    return core_camera.getActiveGlobalCameraName(0) == "free"
end

-- Hand a camera that is still free from our jump to the car, without any old pose (`_saved` is not
-- needed: whatever was remembered, the car is where the camera goes). A player who already went back to
-- his car himself is left alone. Returns the log text for what happened.
local function to_vehicle_camera(_saved)
    if not is_free_camera() then
        return "stays, the player is already back in the vehicle camera"
    end
    if not has_player_vehicle() then
        return "stays free, there is no vehicle to go to"
    end
    commands.setGameCamera()
    return "to the vehicle camera via commands.setGameCamera, the old pose is not given back"
end

-- Put the camera above slot 1 of `editor`'s session. `in_race` refuses it (no jump while a race runs);
-- `trigger` names the cause in the one log line every call writes. Returns true, or nil + a reason fit
-- for the player (the panel button shows it).
function M.to_grid(editor, in_race, trigger)
    if in_race then
        log("I", LOG_TAG, "camera stays, a race is running (" .. trigger .. ")")
        return nil, "the camera does not move during a race"
    end
    local slot = first_slot(editor)
    if not slot then
        return nil, "not editing -- start or load a grid first"
    end
    local missing = missing_engine_names()
    if #missing > 0 then
        log("W", LOG_TAG, "camera not moved (" .. trigger .. "): this game version has no "
            .. table.concat(missing, ", "))
        return nil, "the camera cannot be moved in this game version"
    end
    local ok, remembered = pcall(jump, slot)
    if not ok then
        log("W", LOG_TAG, "camera not moved (" .. trigger .. "): " .. tostring(remembered))
        return nil, "the camera could not be moved"
    end
    local line = "camera over slot 1 of " .. describe_target(editor)
        .. " via commands.setFreeCamera + core_camera.setPosRot (" .. trigger .. ")"
    if remembered then
        line = line .. "; remembered " .. remembered
    end
    log("I", LOG_TAG, line)
    return true
end

-- The one way out of an edit visit. Clears the remembered camera on every path -- first, so a camera call
-- that throws can never leave it armed for the next exit -- and lets EXITS decide what the camera does.
-- Nothing at all happens without a memory: then this visit never moved the camera.
function M.leave(exit)
    local saved = M.state.saved
    M.state.saved = nil
    local answer = EXITS[exit]
    if not answer then
        log("E", LOG_TAG, "camera: unknown exit '" .. tostring(exit)
            .. "', the remembered camera is dropped, not restored")
        return
    end
    if not saved then
        return
    end
    if answer == DROP then
        log("I", LOG_TAG, "camera stays where it is (" .. exit .. "), " .. describe_camera(saved)
            .. " is forgotten, not given back")
        return
    end
    local action = (answer == TO_VEHICLE) and to_vehicle_camera or restore
    local ok, result = pcall(action, saved)
    if ok then
        log("I", LOG_TAG, "camera " .. result .. " (" .. exit .. ")")
    else
        log("W", LOG_TAG, "camera left as it is (" .. exit .. ", " .. answer .. " failed): "
            .. tostring(result))
    end
end

local function remember_slot(slot)
    if slot then
        watch.x, watch.y, watch.z = slot.pos.x, slot.pos.y, slot.pos.z
    else
        watch.x, watch.y, watch.z = nil, nil, nil
    end
end

-- Slot 1 against the one on screen last frame: the new direction's grid hangs off the reversed start
-- line, which on a circuit is the same place and on a sprint the other end of the track.
local function follow_direction_switch(editor, in_race, slot)
    if not (slot and watch.x) then
        return
    end
    local dx, dy, dz = slot.pos.x - watch.x, slot.pos.y - watch.y, slot.pos.z - watch.z
    local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
    local trigger = string.format("direction switch, slot 1 moved %.0f m", moved)
    if moved > M.FOLLOW_DISTANCE then
        M.to_grid(editor, in_race, trigger)
    else
        log("I", LOG_TAG, string.format("camera stays (%s, not more than %.0f m) on %s", trigger,
            M.FOLLOW_DISTANCE, describe_target(editor)))
    end
end

-- Every frame (init.lua onUpdate). One boolean read while nobody is editing. A watched edge is consumed
-- even when nothing moves -- during a race, say -- so a session started in a race does not jump the
-- moment that race ends.
function M.step(editor, in_race)
    if not editor.active then
        return
    end
    local slot = first_slot(editor)
    if editor.session ~= watch.session then
        watch.session = editor.session
        watch.direction = editor.direction
        remember_slot(slot)
        M.to_grid(editor, in_race, "session start")
        return
    end
    if editor.direction ~= watch.direction then
        watch.direction = editor.direction
        follow_direction_switch(editor, in_race, slot)
    end
    remember_slot(slot)
end

return M
