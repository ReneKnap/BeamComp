-- BeamComp -- who carries a name over his car: the ONE seam to BeamMP's floating nametags (ADR-0062).
--
-- Lives at lua/ge/extensions/beamcomp/race/nametags.lua inside the client mod zip. The caller owns the
-- policy AND the record of what this client has already written, and passes both in. What this module
-- keeps itself is a mirror of BeamMP's two nametag switches (M.toggles) and log latches -- all of it safe
-- to lose. Target: client GE (LuaJIT 5.1).
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
--   * an AI car           -> the label the aiMap already relays, which IS the standings name (ADR-0036);
--                            the host, who sends that map, names his own AI from the cars he spawned
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


-- ===== BeamMP's two nametag switches, mirrored (ADR-0062 amendment 2026-10-08) ======================
--
-- BeamMP keeps whether it draws nametags in two FILE LOCALS of MPVehicleGE.lua that nothing outside can
-- read: `nicknamesAllowed` (set by hideNicknames(hide)) and `hideNicknamesToggle` (flipped by
-- toggleNicknames(), which is what the "Player Nametags" key runs by name). A tag BeamComp draws itself
-- has to follow both, so every door to them is wrapped: each wrapper notes the call here and then hands
-- it to BeamMP's original unchanged. The wrap only listens.
--
-- The mirror starts at BeamMP's own defaults and only the wrappers move it. It describes BeamMP's state,
-- which outlives ours, so installing or removing the wrap leaves it alone. An extension reload keeps this
-- module cached (lua/common/extensions.lua clears package.loaded for the extension file alone), and a
-- full GE Lua reload resets BeamMP's locals together with this table. What it cannot see is a switch
-- thrown before this module first ran -- the key pressed before joining the server: the mirror then
-- starts at "shown" while BeamMP stands at "hidden", every later press flips both, and the two stay
-- opposite until the next GE Lua reload. Accepted (ADR-0062 amendment).
M.toggles = {
    allowed = true,       -- BeamMP's nicknamesAllowed: false after hideNicknames(true)
    toggled_off = false,  -- BeamMP's hideNicknamesToggle: flipped by every toggleNicknames()
}

-- Our wrappers are marked on BeamMP's own module table, never in this module, so a mark is found whatever
-- this module's state says -- the stash-on-the-foreign-table rule of race/lock.lua. Shape:
-- {[wrapper] = {original = the function it wraps, live = whether it still notes calls}}.
local TOGGLE_MARKS_KEY = "beamcomp_nametag_toggle_marks"

local function note_hide(hide)
    M.toggles.allowed = not hide
end

local function note_toggle()
    M.toggles.toggled_off = not M.toggles.toggled_off
end

-- The doors, in log order: a global (no `module`) or a field of a BeamMP module. MPVehicleGE exports each
-- global as the same function object, and MPHelpers re-exports hideNicknames as a COPY taken when it loads
-- (MPHelpers.lua onExtensionLoaded) -- wrapping the other doors never reaches that one, so it is a door of
-- its own. No body calls another, so a call through any door is noted exactly once.
local TOGGLE_TARGETS = {
    {field = "hideNicknames", note = note_hide},
    {field = "toggleNicknames", note = note_toggle},
    {module = "MPVehicleGE", field = "hideNicknames", note = note_hide},
    {module = "MPVehicleGE", field = "toggleNicknames", note = note_toggle},
    {module = "MPHelpers", field = "hideNicknames", note = note_hide},
}

local function door_label(target)
    return target.module and (target.module .. "." .. target.field) or target.field
end

-- The table a door lives on, or nil when its module is not loaded. Everything goes through rawget/rawset:
-- BeamMP switches global-write detection back on after defining its globals (detectGlobalWrites), and no
-- direction may create a global or a field that is not there already.
local function door_table(target)
    if target.module == nil then
        return _G
    end
    local module = rawget(_G, target.module)
    return type(module) == "table" and module or nil
end

local function read_target(target)
    local tbl = door_table(target)
    return tbl and rawget(tbl, target.field)
end

local function write_target(target, value)
    rawset(door_table(target), target.field, value)
end

-- A wrapper that is no longer live passes every call straight through. That is what a wrapper of ours
-- becomes when something else has wrapped over it and it cannot be taken out of the chain.
local function retire(marks)
    for _, mark in pairs(marks) do
        mark.live = false
    end
end

-- Wrap one door. A door still holding one of our wrappers from an earlier load (an unload that never got
-- as far as giving it back) is unwrapped to what THAT wraps first: never a wrapper around a wrapper.
local function wrap_target(target, stale, marks)
    local current = read_target(target)
    if type(current) ~= "function" then
        return false
    end
    local original = stale[current] and stale[current].original or current
    local mark = {original = original, live = true}
    local note = target.note
    local function wrapper(...)
        if mark.live then
            note(...)
        end
        return original(...)
    end
    marks[wrapper] = mark
    write_target(target, wrapper)
    return true
end

-- Give one door its original back, if it still holds our wrapper.
local function unwrap_target(target, marks)
    local current = read_target(target)
    local mark = current and marks[current]
    if not mark then
        return false
    end
    write_target(target, mark.original)
    return true
end

-- Install the mirror. One I line naming what is wrapped -- the tripwire after a BeamMP update, the same
-- rule as the parts lock's "wrapped N of 8" -- and a W line naming every door that is missing. A door that
-- is not wrapped never moves the mirror off its default, so whatever is missing leaves the tags visible,
-- which is the fallback the owner asked for. The marks live on MPVehicleGE, so without it nothing is
-- wrapped at all. Never throws.
function M.install_toggle_mirror()
    local module = rawget(_G, "MPVehicleGE")
    if type(module) ~= "table" then
        log("W", LOG_TAG, "nametag toggles not mirrored: MPVehicleGE is not loaded -- BeamMP's nametag key "
            .. "does not switch the AI tags BeamComp draws, they stay visible")
        return
    end
    local stale = rawget(module, TOGGLE_MARKS_KEY)
    stale = type(stale) == "table" and stale or {}
    local marks, wrapped, missing = {}, {}, {}
    for _, target in ipairs(TOGGLE_TARGETS) do
        local ok, result = pcall(wrap_target, target, stale, marks)
        local label = door_label(target)
        if ok and result then
            wrapped[#wrapped + 1] = label
        else
            missing[#missing + 1] = ok and label or (label .. " (" .. tostring(result) .. ")")
        end
    end
    retire(stale)
    rawset(module, TOGGLE_MARKS_KEY, next(marks) ~= nil and marks or nil)
    local summary = string.format("nametag toggles mirrored: wrapped %d of %d (%s)", #wrapped,
        #TOGGLE_TARGETS, table.concat(wrapped, ", "))
    if #missing == 0 then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; not found: " .. table.concat(missing, ", ") .. " -- BeamMP's "
            .. "nametag switches do not reach the AI tags BeamComp draws through those, they stay visible")
    end
end

-- Give BeamMP its functions back. A door something else has wrapped over in the meantime keeps that
-- wrapper; ours underneath it is retired to a pass-through rather than pulled out of somebody's chain.
-- Never throws -- it runs from onExtensionUnloaded, which has no pcall around it.
function M.uninstall_toggle_mirror()
    local module = rawget(_G, "MPVehicleGE")
    local marks = type(module) == "table" and rawget(module, TOGGLE_MARKS_KEY) or nil
    if type(marks) ~= "table" then
        return
    end
    local wrapped, restored = 0, 0
    for _ in pairs(marks) do
        wrapped = wrapped + 1
    end
    for _, target in ipairs(TOGGLE_TARGETS) do
        local ok, result = pcall(unwrap_target, target, marks)
        if ok and result then
            restored = restored + 1
        end
    end
    retire(marks)
    rawset(module, TOGGLE_MARKS_KEY, nil)
    local summary = string.format("nametag toggles: gave BeamMP back %d of %d wrapped", restored, wrapped)
    if restored == wrapped then
        log("I", LOG_TAG, summary)
    else
        log("W", LOG_TAG, summary .. "; the rest are wrapped over by something else and now pass every "
            .. "call straight through")
    end
end

return M
