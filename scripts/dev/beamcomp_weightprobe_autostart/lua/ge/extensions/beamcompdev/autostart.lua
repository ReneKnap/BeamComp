-- BeamComp dev tool, NOT SHIPPED -- starts the weight probe by itself
-- (bug caps-live-weight-differs-from-metadata).
--
-- Lives in its own unpacked dev mod, scripts/dev/beamcomp_weightprobe_autostart, next to the probe's mod
-- scripts/dev/beamcomp_weightprobe; neither scripts/deploy.ps1 nor scripts/package.ps1 copies either. With
-- both installed, a singleplayer free roam session runs the probe once: as soon as the player's own car has
-- run AUTOSTART_AFTER seconds of sim time, with the presets from
-- <user folder>/beamcomp_weightprobe_presets.json (a JSON list of "model:config", or {"presets": [...]} /
-- {"models": [...]}), or the probe's default list when the file is missing. The probe puts the player back
-- into his car when it is done.
--
-- It never runs in a BeamMP session, so a forgotten install cannot spawn a dozen cars on a server. Target:
-- client GE (LuaJIT 2.1).

local M = {}

local LOG_TAG = "beamcomp.weightprobe"
local PRESET_FILE = "/beamcomp_weightprobe_presets.json"
local AUTOSTART_AFTER = 5.0
local DT_CLAMP = 0.1

-- Once per game session: `done` is set when the probe was started or the session ruled it out.
local state = {done = false, vehicle_id = nil, settled = 0}

local function in_multiplayer()
    local network = rawget(_G, "MPCoreNetwork")
    if type(network) ~= "table" or type(network.isMPSession) ~= "function" then
        return false
    end
    local ok, is_session = pcall(network.isMPSession)
    return ok and is_session == true
end

-- The player's own car, or nil while he has none or walks.
local function player_car()
    if not be or type(be.getPlayerVehicle) ~= "function" then
        return nil
    end
    local ok, veh = pcall(be.getPlayerVehicle, be, 0)
    if not ok or not veh then
        return nil
    end
    local named, jbeam = pcall(function() return veh:getJBeamFilename() end)
    if not named or jbeam == "unicycle" then
        return nil
    end
    return veh
end

-- The run's options from the preset file, plus where they came from for the log line.
local function read_options()
    if type(jsonReadFile) ~= "function" then
        return {}, "the probe's default list (jsonReadFile unavailable)"
    end
    local ok, data = pcall(jsonReadFile, PRESET_FILE)
    if not ok or data == nil then
        return {}, "the probe's default list (no " .. PRESET_FILE:sub(2) .. " in the user folder)"
    end
    if type(data) == "table" and data[1] ~= nil then
        return {presets = data}, PRESET_FILE:sub(2)
    end
    if type(data) == "table" and (type(data.presets) == "table" or type(data.models) == "table") then
        return data, PRESET_FILE:sub(2)
    end
    log("W", LOG_TAG, "autostart: " .. PRESET_FILE:sub(2) .. " is neither a list nor {presets} / {models}")
    return {}, "the probe's default list (" .. PRESET_FILE:sub(2) .. " unreadable)"
end

local function start_probe()
    state.done = true
    extensions.load("beamcompdev_weightprobe")
    local probe = rawget(_G, "beamcompdev_weightprobe")
    if type(probe) ~= "table" or type(probe.run) ~= "function" then
        log("E", LOG_TAG, "autostart: the probe (beamcompdev_weightprobe) is not installed; copy "
            .. "scripts/dev/beamcomp_weightprobe into mods/unpacked as well")
        return
    end
    local options, source = read_options()
    log("I", LOG_TAG, "autostart: starting the probe with " .. source)
    probe.run(options)
end

function M.onUpdate(_, dt_sim)
    if state.done then
        return
    end
    if in_multiplayer() then
        state.done = true
        log("W", LOG_TAG, "autostart: this is a multiplayer session; the probe only runs in singleplayer")
        return
    end
    local veh = player_car()
    if not veh then
        state.vehicle_id, state.settled = nil, 0
        return
    end
    local vehicle_id = veh:getId()
    if vehicle_id ~= state.vehicle_id then
        state.vehicle_id, state.settled = vehicle_id, 0
    end
    state.settled = state.settled + math.min(dt_sim or 0, DT_CLAMP)
    if state.settled >= AUTOSTART_AFTER then
        start_probe()
    end
end

function M.onExtensionLoaded()
    setExtensionUnloadMode(M, "manual")
    log("I", LOG_TAG, string.format("autostart armed: the probe starts once the player's car has run %.0f s",
        AUTOSTART_AFTER))
end

return M
