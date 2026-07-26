-- BeamComp -- GE-side car-list builder for the /cars command (ADR-0032).
--
-- Lives at lua/ge/extensions/beamcomp/race/carlist.lua inside the client mod zip. Stateless: require it
-- and call M.build(model). Target: client GE (LuaJIT 5.1).
--
-- Mirrors race/racelist.lua: the server is vehicle-blind (ADR-0005), so the client owns vehicle
-- knowledge and builds the chat lines, shipping them back for the server to post verbatim (ADR-0011).
-- M.build(nil) lists all installed models (packed several per line); M.build(model) lists that model's
-- configs with power, weight, and power-to-weight -- the values to feed car=/maxhp=/maxpwr=.

local M = {}

local vehiclespecs = require("beamcomp/race/vehiclespecs")
local optsort = require("beamcomp/race/optsort")

-- Models packed per line so a stock install's ~50+ models do not flood chat one-per-line.
local MODELS_PER_LINE = 8

-- Chat lines listing every installed model, packed MODELS_PER_LINE to a line.
local function list_all_models()
    local models = vehiclespecs.list_models()
    if #models == 0 then
        return {"BeamComp: no vehicles found"}
    end
    local lines = {string.format("BeamComp: %d vehicle(s) -- /cars <model> for configs:", #models)}
    local row = {}
    for _, model in ipairs(models) do
        row[#row + 1] = model
        if #row == MODELS_PER_LINE then
            lines[#lines + 1] = "  " .. table.concat(row, ", ")
            row = {}
        end
    end
    if #row > 0 then
        lines[#lines + 1] = "  " .. table.concat(row, ", ")
    end
    return lines
end

-- One config line: "  <config> - <n> hp, <n> kg, <n.nnn> hp/kg", with "power n/a" / weight dropped when
-- unreadable (the metadata gaps flagged in vehiclespecs -- shown so the admin knows maxhp/maxpwr can't
-- filter that config).
local function describe_config(entry)
    local detail
    if entry.power then
        detail = string.format("%d hp", math.floor(entry.power + 0.5))
    else
        detail = "power n/a"
    end
    if entry.weight then
        detail = detail .. string.format(", %d kg", math.floor(entry.weight + 0.5))
        if entry.power then
            detail = detail .. string.format(", %.3f hp/kg", entry.power / entry.weight)
        end
    end
    return string.format("  %s - %s", entry.config, detail)
end

-- Chat lines for one model's configs, or a not-found note when the model is unknown / has no configs.
local function list_model_configs(model)
    local configs = vehiclespecs.list_configs(model)
    if #configs == 0 then
        return {string.format("BeamComp: no configs for '%s' (unknown model?)", model)}
    end
    local lines = {string.format("BeamComp: %s -- %d config(s):", model, #configs)}
    for _, entry in ipairs(configs) do
        lines[#lines + 1] = describe_config(entry)
    end
    return lines
end

-- Build the /cars chat lines: a model name lists that model's configs; nil/empty lists all models.
function M.build(model)
    if type(model) == "string" and model ~= "" then
        return list_model_configs(model)
    end
    return list_all_models()
end

-- Structured vehicle options for the settings UI (ADR-0037), returned as data instead of chat lines. A
-- model lists that model's configs ({config, name} pairs for the car= dropdown -- power/weight are dropped
-- here, the panel only needs to pick); nil/empty lists the drivable models as {model, label} pairs
-- (props/trailers excluded, so a car= can't pick a cone). `model` is the selection key, `label` the human
-- display name (e.g. "Ibishu Pessima") the dropdown shows; a config's key is likewise the selection value
-- and its `name` the in-game label. Configs are probed lazily per selected model since an all-models probe
-- is heavy.
--
-- Both lists are ordered by the DISPLAYED text (optsort.by_display), not by the key the vehiclespecs
-- source sorts on: the panel shows "Ibishu Pessima", so that entry belongs under I, not under its
-- `pessima` key -- and the same for a config shown by its in-game name. The re-sort runs on the local
-- copies built here; the vehiclespecs order itself stays key-based on purpose, since the random AI pool,
-- the compliant-substitute search and the /cars chat listing all read it.
function M.options(model)
    if type(model) == "string" and model ~= "" then
        local configs = {}
        for _, entry in ipairs(vehiclespecs.list_configs(model)) do
            configs[#configs + 1] = {config = entry.config, name = entry.name}
        end
        return {configs = optsort.by_display(configs, "name", "config")}
    end
    local models = {}
    for _, key in ipairs(vehiclespecs.list_car_models()) do
        models[#models + 1] = {model = key, label = vehiclespecs.model_label(key)}
    end
    return {models = optsort.by_display(models, "label", "model")}
end

return M
