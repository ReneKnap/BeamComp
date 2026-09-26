-- BeamComp -- who carries a name over his car: the ONE seam to BeamMP's floating nametags (ADR-0062).
--
-- Lives at lua/ge/extensions/beamcomp/race/nametags.lua inside the client mod zip. Stateless apart from
-- one log latch (M.name_source, see write_name): the caller owns the policy AND the record of what this
-- client has already written, and passes both in. Target: client GE (LuaJIT 5.1).
--
-- BeamMP draws one tag per SYNCED vehicle and skips its own (`if v.isLocal or not owner then goto
-- skip_vehicle`), which is why the host can never see what this module does -- every race prop belongs
-- to him. Two fields on the MPVehicleGE entry decide the outcome, and neither is in
-- `Vehicle:onSerialized()`: `hideNametag` takes the tag away (checked above both the main and the
-- spectator tag), `customName` replaces the owner's name in it. A rebuilt entry therefore starts tagged
-- again with the owner's name -- so this is a RECONCILER that is re-run, never a one-shot that is
-- believed (the one-shot with a 10-second give-up is what ADR-0020 finding #4 accepted, and what this
-- replaces).
--
-- M.apply decides per entry, in this order:
--   * a race prop         -> no name, in BOTH settings of the policy. Not negotiable: a prop is never
--                            a driver, and the prop set is a derivation of the host's own prefab load
--                            (race/props.lua M.live_prop_ids), never a jbeam name.
--   * an AI car           -> the label the aiMap already relays, which IS the standings name (ADR-0036)
--   * anybody's car       -> his race name (identity.player_list), or no tag when names are switched off
--
-- Three rules keep it from doing damage:
--   1. It writes only on a difference, so a sweep over an unchanged scene performs no writes at all.
--   2. It undoes only its OWN writes -- `written.hidden` / `written.named` record them, and an entry
--      hidden or named by something else is left exactly as it is.
--   3. Every BeamMP touch is pcall-guarded and degrades to a no-op; a tag that stays is a visible
--      failure, a thrown error inside onUpdate is not.

local M = {}

local LOG_TAG = "beamcomp.nametags"

-- Candidate MPVehicleGE entry fields carrying a vehicle's cross-client BeamMP id, tried in order. The
-- ONE copy of this list: race/ai.lua's M.server_id_of reads it through M.id_of rather than keeping a
-- second one, because two lists that drift are two different answers to "which vehicle is this".
local SERVER_ID_FIELDS = {"serverVehicleString", "serverVehicleID", "remoteVehID", "gameVehicleID"}

-- The whole MPVehicleGE entry table (cross-client id -> entry), or nil outside a BeamMP session / when
-- the export is missing. RAW: read it, never mutate the table itself -- the entries inside it are what
-- this module writes to.
function M.entries()
    if type(MPVehicleGE) ~= "table" or type(MPVehicleGE.getVehicles) ~= "function" then
        return nil
    end
    local ok, entries = pcall(MPVehicleGE.getVehicles)
    if not ok or type(entries) ~= "table" then
        return nil
    end
    return entries
end

-- The MPVehicleGE entry for a local game vehicle id, or nil when BeamMP has not registered it (yet).
-- "Not yet" is the normal state for the first frames after a spawn and is what the prop derivation
-- counts as unresolved rather than as done.
function M.entry_for(game_id)
    if game_id == nil then
        return nil
    end
    if type(MPVehicleGE) ~= "table" or type(MPVehicleGE.getVehicleByGameID) ~= "function" then
        return nil
    end
    local ok, entry = pcall(MPVehicleGE.getVehicleByGameID, game_id)
    if not ok or type(entry) ~= "table" then
        return nil
    end
    return entry
end

-- An entry's cross-client BeamMP id, or nil when no candidate field carries one.
function M.id_of(entry)
    if type(entry) ~= "table" then
        return nil
    end
    for _, field in ipairs(SERVER_ID_FIELDS) do
        local value = entry[field]
        if value ~= nil and value ~= "" then
            return value
        end
    end
    return nil
end

-- Set (or clear, with nil) the name drawn over a vehicle.
--
-- Through setDisplayName, never by assigning nameTag: the newer BeamMP draws a CACHED string
-- (updateNameTagCache, built from `customName or ownerName`) and the setter is what rebuilds it, so a
-- direct write to the cache is gone the next time anything touches that vehicle. The fallback covers a
-- build without the setter; it is named in the log rather than silently assumed, the house rule for
-- every BeamMP/engine touchpoint here. The latch is a log-noise guard only -- losing it on a reload
-- costs one extra line.
local function write_name(entry, name)
    local ok, source = pcall(function()
        if type(entry.setDisplayName) == "function" then
            entry:setDisplayName(name)
            return "setDisplayName"
        end
        entry.customName = name
        if type(entry.updateNameTagCache) == "function" then
            entry:updateNameTagCache()
            return "customName + updateNameTagCache"
        end
        return "customName"
    end)
    if not ok then
        log("W", LOG_TAG, "could not set a display name: " .. tostring(source))
        return false
    end
    if M.name_source ~= source then
        M.name_source = source
        log("I", LOG_TAG, "display names go through " .. source)
    end
    return true
end

-- The race name for the player who owns this vehicle, or nil when we have no list / no row for him.
local function owner_name(names, owner_id)
    if type(names) ~= "table" or owner_id == nil then
        return nil
    end
    return names[tostring(owner_id)]
end

local function hide_entry(entry, key, written)
    if entry.hideNametag == true then
        return 0
    end
    entry.hideNametag = true
    written.hidden[key] = true
    return 1
end

-- Give the tag back -- but only if WE took it away.
local function show_entry(entry, key, written)
    if entry.hideNametag ~= true or not written.hidden[key] then
        return 0
    end
    entry.hideNametag = false
    written.hidden[key] = nil
    return 1
end

-- Put `name` on the tag, or take our own override back off it when the name to show is the one BeamMP
-- already draws. Overriding an identical name would also defeat the reader's own "shorten nametags"
-- setting, which reads the owner's short name whenever there is no customName.
local function name_entry(entry, key, name, written)
    if name == entry.ownerName then
        name = nil
    end
    if name ~= nil then
        if entry.customName == name then
            return 0
        end
        if not write_name(entry, name) then
            return 0
        end
        written.named[key] = true
        return 1
    end
    if not written.named[key] or entry.customName == nil then
        return 0
    end
    if not write_name(entry, nil) then
        return 0
    end
    written.named[key] = nil
    return 1
end

local function ensure_written(policy)
    local written = policy.written
    if type(written) ~= "table" then
        written = {}
        policy.written = written
    end
    written.hidden = written.hidden or {}
    written.named = written.named or {}
    return written
end

-- Apply the policy to every vehicle BeamMP knows about. Returns the number of entries changed, which is
-- 0 for the overwhelming majority of calls -- that is what makes this affordable on a tick.
--
-- policy = {
--   props   = {[cross-client id] = true},    -- the race's props; no name, whatever `show` says
--   ai      = {[cross-client id] = label},   -- AI cars and the name they race under
--   names   = {[player id] = race name},     -- from the server's playerList (ADR-0054)
--   show    = boolean,                       -- whether DRIVERS carry a name at all (ADR-0062); only an
--                                            -- explicit false hides them, so an unknown policy leaves
--                                            -- the session looking exactly like plain BeamMP
--   written = {hidden = {}, named = {}},     -- what this client changed; owned by the caller, mutated here
-- }
function M.apply(policy)
    local entries = M.entries()
    if not entries then
        return 0
    end
    local written = ensure_written(policy)
    local changed = 0
    for server_id, entry in pairs(entries) do
        if type(entry) == "table" then
            local key = tostring(server_id)
            if (policy.props and policy.props[key]) or policy.show == false then
                changed = changed + hide_entry(entry, key, written)
            else
                changed = changed + show_entry(entry, key, written)
                local name = (policy.ai and policy.ai[key]) or owner_name(policy.names, entry.ownerID)
                changed = changed + name_entry(entry, key, name, written)
            end
        end
    end
    return changed
end

return M
