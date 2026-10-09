-- BeamComp -- who carries a name over his car: the ONE seam to BeamMP's floating nametags (ADR-0062).
--
-- Lives at lua/ge/extensions/beamcomp/race/nametags.lua inside the client mod zip. The caller owns the
-- policy AND the record of what this client has already written, and passes both in. What this module
-- keeps itself is a mirror of BeamMP's two nametag switches (M.toggles) and log latches -- all of it safe
-- to lose. Target: client GE (LuaJIT 5.1).
--
-- BeamMP draws one tag per SYNCED vehicle and skips its own (`if v.isLocal or not owner then goto
-- skip_vehicle`), which is why the host can never see what M.apply does to the props -- every race prop
-- belongs to him. His AI cars belong to him too, and those he should see named: M.draw_local_ai draws
-- that tag itself (ADR-0062 amendment 2026-10-08). Two fields on the MPVehicleGE entry decide the
-- outcome of M.apply, and neither is in
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


-- ===== The host's own AI cars: BeamComp draws their tag (ADR-0062 amendment 2026-10-08) =============
--
-- BeamMP skips every vehicle this client owns before it draws a tag, and only the owner spawns AI
-- (ADR-0036): every player but the host sees a name over each AI car, the host none. This draws the
-- host's half, as a copy of BeamMP's own draw block (MPVehicleGE.lua onPreRender) rather than a style of
-- its own: the entry's cached nameTag (which M.apply has already built from the AI's label), white text on
-- the owner's role colour, the same height above the car, the same fade, the same distance suffix -- and
-- the same switches: the host's BeamMP nametag settings and BeamMP's two toggles (M.toggles above).
--
-- Not copied, on purpose: the spectator line (nobody spectates an AI), fadeVehicles (a mesh effect on
-- REMOTE cars, not a tag), BeamMP's distance map and the queue blobs (unspawned remote cars).

-- BeamMP's roleToInfo.USER background, used when a role carries no readable colour.
local USER_BACKCOLOR = {r = 0, g = 0, b = 0}

-- The draw path's own bookkeeping. All of it may be lost on a reload: it resolves and logs again.
local draw = {
    kit = nil,           -- the resolved draw call {text = fn, source = name}; false once found missing
    first_logged = false,
    warned = false,      -- a frame threw; said once
    role_warned = false,
    owner_warned = false,
    premise_policy = nil,  -- the policy object the premise line was last evaluated for
    premise = nil,       -- the counts it last logged
}

-- The settings and the camera of the current frame, refilled every frame: nothing is allocated per frame.
local frame = {}

-- Whether `owner[name]` resolves. Engine objects are userdata whose missing members may raise rather than
-- answer nil, hence the pcall; only ever run while resolving, never per frame.
local function has_member(owner, name)
    if owner == nil then
        return false
    end
    local ok, member = pcall(function() return owner[name] end)
    return ok and member ~= nil
end

-- BeamMP's own call first: the FFI text draw it binds at load (cdefDebugDraw.lua), garbage-free, packed
-- colours through the engine's color(). debugDrawer's method is the named fallback, with colour objects.
local function resolve_text_draw()
    local ok, ffi_lib = pcall(require, "ffi")
    if ok and type(ffi_lib) == "table" and type(color) == "function" then
        local found, ffi_draw = pcall(function() return ffi_lib.C.BNG_DBG_DRAW_TextAdvanced end)
        if found and ffi_draw ~= nil then
            return function(x, y, z, text, alpha, r, g, b, use_z)
                ffi_draw(x, y, z, text, color(255, 255, 255, alpha * 254), true, false,
                    color(r, g, b, math.floor(alpha * 127)), false, use_z)
            end, "ffi.C.BNG_DBG_DRAW_TextAdvanced"
        end
    end
    if has_member(debugDrawer, "drawTextAdvanced") and vec3 and ColorF and ColorI then
        return function(x, y, z, text, alpha, r, g, b, use_z)
            debugDrawer:drawTextAdvanced(vec3(x, y, z), text, ColorF(1, 1, 1, alpha * 254 / 255), true,
                false, ColorI(r, g, b, math.floor(alpha * 127)), false, use_z)
        end, "debugDrawer:drawTextAdvanced"
    end
    return nil
end

-- Every engine touchpoint the draw needs, looked up once (ADR-0017). Anything missing is named in ONE W
-- line and no tag is drawn for the rest of this module's life; the engine surface does not change at run
-- time, so a per-frame retry would only cost every frame.
local function resolve_kit()
    if draw.kit ~= nil then
        return draw.kit or nil
    end
    local absent = {}
    local function need(present, name)
        if not present then
            absent[#absent + 1] = name
        end
    end
    need(has_member(settings, "getValue"), "settings.getValue")
    need(has_member(core_camera, "getPositionXYZ"), "core_camera.getPositionXYZ")
    need(has_member(commands, "isFreeCamera"), "commands.isFreeCamera")
    need(has_member(be, "getPlayerVehicle"), "be:getPlayerVehicle")
    need(has_member(be, "getObjectByID"), "be:getObjectByID")
    need(has_member(be, "getObjectOOBBCenterXYZ"), "be:getObjectOOBBCenterXYZ")
    local text, source = resolve_text_draw()
    need(text, "a text draw (ffi.C.BNG_DBG_DRAW_TextAdvanced, debugDrawer:drawTextAdvanced)")
    if #absent > 0 then
        draw.kit = false
        log("W", LOG_TAG, "the host's AI tags are not drawn: missing " .. table.concat(absent, ", "))
        return nil
    end
    draw.kit = {text = text, source = source}
    return draw.kit
end

-- Read this frame's settings and camera into `frame`, exactly where BeamMP reads them. False when the host
-- has nametags switched off in BeamMP's settings.
local function read_frame()
    local get = settings.getValue
    if get("hideNameTags") then
        return false
    end
    frame.fade_enabled = get("nameTagFadeEnabled") and true or false
    frame.fade_distance = tonumber(get("nameTagFadeDistance", 40)) or 40
    frame.fade_invert = get("nameTagFadeInvert") and true or false
    frame.dont_fully_hide = get("nameTagDontFullyHide") and true or false
    frame.show_distance = get("nameTagShowDistance") and true or false
    frame.imperial = get("uiUnitLength") == "imperial"
    frame.use_z = get("nameTagsHideBehindObjects") and true or false
    -- The reference point: the camera, or the seated car while not in the free camera.
    frame.free_camera = commands.isFreeCamera() and true or false
    local x, y, z = core_camera.getPositionXYZ()
    local seated = be:getPlayerVehicle(0)
    if seated and not frame.free_camera then
        x, y, z = seated:getPositionXYZ()
    end
    frame.x, frame.y, frame.z = x, y, z
    return true
end

-- BeamMP's fade, operation for operation: clamp(linearScale(distance, fadeDistance, 0, 0, 1), 0, 1)
-- (lua/common/mathlib.lua), inverted only while fading outside the free camera, 1 with fading off, and
-- never below 0.3 with "don't fully hide".
local function tag_alpha(distance)
    local fade = frame.fade_distance
    local alpha = math.min(math.max((distance - fade) / (0 - fade), 0), 1)
    alpha = math.min(math.max(alpha, 0), 1)
    if frame.fade_enabled and not frame.free_camera and frame.fade_invert then
        alpha = 1 - alpha
    end
    if not frame.fade_enabled then
        alpha = 1
    end
    if frame.dont_fully_hide then
        alpha = math.max(0.3, alpha)
    end
    return alpha
end

-- BeamMP's distance suffix, beyond 10 m and only with "show distance", metric or imperial.
local function distance_suffix(distance)
    if distance <= 10 or not frame.show_distance then
        return ""
    end
    if frame.imperial then
        local feet = distance * 3.28084
        if feet > 5280 then
            return string.format("%.2f mi ", math.floor((feet / 5280 * 100) + 0.5) / 100)
        end
        return string.format("%.f ft ", math.floor(feet))
    end
    if distance >= 1000 then
        return string.format("%.2f km ", math.floor((distance / 10) + 0.5) / 100)
    end
    return string.format("%.f m ", math.floor(distance))
end

-- The background colour of the owner's role, BeamMP's precedence: the vehicle's custom role, the owner's
-- custom role, the owner's role. A role without a readable colour is drawn on BeamMP's USER black, once
-- said in the log.
local function role_backcolor(entry, owner)
    local role = entry.customRole or owner.customRole or owner.role
    local back = type(role) == "table" and role.backcolor or nil
    if type(back) == "table" and type(back.r) == "number" and type(back.g) == "number"
            and type(back.b) == "number" then
        return back.r, back.g, back.b
    end
    if not draw.role_warned then
        draw.role_warned = true
        log("W", LOG_TAG, "an AI tag's owner role has no readable colour; drawn on BeamMP's USER black")
    end
    return USER_BACKCOLOR.r, USER_BACKCOLOR.g, USER_BACKCOLOR.b
end

-- One entry, as BeamMP draws a remote one. False when it carries no tag: no owner, a tag hidden on the
-- vehicle or its owner, no cached text yet, or a car that is not in the world (BeamMP would fall back to a
-- stored position it never keeps for a local entry).
local function draw_entry(entry, text_draw)
    if type(entry.getOwner) ~= "function" then
        if not draw.owner_warned then
            draw.owner_warned = true
            log("W", LOG_TAG, "an MPVehicleGE entry has no getOwner(); its AI tag is not drawn")
        end
        return false
    end
    local owner = entry:getOwner()
    if type(owner) ~= "table" or entry.hideNametag or owner.hideNametag or entry.nameTag == nil
            or entry.isSpawned == false then
        return false
    end
    local game_id = entry.gameVehicleID
    local veh = be:getObjectByID(game_id)
    if not veh or not veh:getActive() then
        return false
    end
    local x, y, z = be:getObjectOOBBCenterXYZ(game_id)
    z = z + veh:getInitialHeight() * 0.5 + 0.2
    local dx, dy, dz = x - frame.x, y - frame.y, z - frame.z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local r, g, b = role_backcolor(entry, owner)
    -- Concatenated even with no suffix, exactly like BeamMP: that is what turns the cached String into the
    -- text the draw call takes.
    text_draw(x, y, z, entry.nameTag .. distance_suffix(distance), tag_alpha(distance), r, g, b,
        frame.use_z)
    return true
end

-- Whether an entry carries the AI's label: M.apply sets it as customName, except when the label already IS
-- the owner's name and nothing needs overriding.
local function carries_label(entry, label)
    return entry.customName == label or (entry.customName == nil and entry.ownerName == label)
end

-- The premise this draw stands on, measured where it runs: the host's AI entries are local to it (so
-- BeamMP skips them) and carry the label in a cached nameTag. Evaluated once per policy object -- a new one
-- comes with every sweep, so at most twice a second -- and logged only when the counts change; W when they
-- disagree, because then either BeamMP draws these tags itself or there is nothing right to draw.
local function note_premise(policy, entries)
    if policy == draw.premise_policy then
        return
    end
    draw.premise_policy = policy
    local total, is_local, named, tagged = 0, 0, 0, 0
    for key, label in pairs(policy.ai) do
        total = total + 1
        local entry = entries[key]
        if type(entry) == "table" then
            is_local = is_local + (entry.isLocal == true and 1 or 0)
            named = named + (carries_label(entry, label) and 1 or 0)
            tagged = tagged + ((entry.nameTag ~= nil and entry.nameTag ~= "") and 1 or 0)
        end
    end
    local counts = string.format("%d AI in the policy, %d local to this client, %d named after their "
        .. "label, %d with a cached nameTag", total, is_local, named, tagged)
    if counts == draw.premise then
        return
    end
    draw.premise = counts
    local agree = is_local == total and named == total and tagged == total
    log(agree and "I" or "W", LOG_TAG, "host AI tags: " .. counts)
end

local function draw_frame(policy)
    if type(policy) ~= "table" or type(policy.ai) ~= "table" then
        return 0
    end
    local entries = M.entries()
    if not entries then
        return 0
    end
    note_premise(policy, entries)
    -- Only an explicit false hides drivers -- the same reading M.apply hides them on.
    if policy.show == false or not M.toggles.allowed or M.toggles.toggled_off then
        return 0
    end
    local kit = resolve_kit()
    if not kit or not read_frame() then
        return 0
    end
    local drawn = 0
    for key in pairs(policy.ai) do
        -- The prop branch stays first and unconditional, as in M.apply: a prop is never a driver.
        if not (policy.props and policy.props[key]) then
            local entry = entries[key]
            -- Local entries only: BeamMP draws every other one itself, so a tag of ours there is a second.
            if type(entry) == "table" and entry.isLocal == true and draw_entry(entry, kit.text) then
                drawn = drawn + 1
            end
        end
    end
    if drawn > 0 and not draw.first_logged then
        draw.first_logged = true
        log("I", LOG_TAG, string.format("drawing the host's own AI tags through %s (%d this frame)",
            kit.source, drawn))
    end
    return drawn
end

-- Draw the tag over every AI car in `policy.ai` that BeamMP skips because this client owns it. Called every
-- frame on the host with the policy identity.apply_tags last handed to M.apply. Returns the number drawn.
-- A frame that throws is said once and then quietly retried every frame -- the marker draw's pattern.
function M.draw_local_ai(policy)
    local ok, result = pcall(draw_frame, policy)
    if ok then
        return result
    end
    if not draw.warned then
        draw.warned = true
        log("W", LOG_TAG, "drawing the host's AI tags failed: " .. tostring(result))
    end
    return 0
end

return M
