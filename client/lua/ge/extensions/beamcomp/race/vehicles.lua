-- BeamComp -- race vehicle lifecycle (despawn + own-car respawn on a race start).
--
-- Lives at lua/ge/extensions/beamcomp/race/vehicles.lua inside the client mod zip. Stateless and
-- reload-safe: no M.state, and the one piece of file-scope mutable state (bbox_report, a per-race
-- diagnostic counter) is reset at every race start and carries nothing a reload could corrupt.
-- Target: client GE (LuaJIT 5.1).
--
-- On a race start each client places its own car at the grid pose the server assigned it
-- (M.respawn_own_at, ADR-0007). Primary path: if the player is already in a real owned car, keep
-- it -- repair + teleport it in place and despawn only the OTHER owned cars -- so its runtime state
-- (ESC / drive-mode, customization) survives. Fallback (no real own car): despawn all and spawn a
-- fresh one. Owned-only is deliberate: getOwnMap() (BeamMP's MPVehicleGE) lists vehicles whose
-- isLocal == true, and deleting / spawning / teleporting an owned vehicle is propagated to every
-- client by BeamMP (delete -> 'Od:', spawn -> 'Os:', teleport via normal position sync). Touching a
-- non-owned (synced) vehicle would desync, so we never do; each client handles only its own car and
-- the full grid fills in as all do the same.

local M = {}

local vehiclespecs = require("beamcomp/race/vehiclespecs")
-- Supplies the pose's measured surface normal semantics: placement.plane_axis is the single recipe for
-- tilting a travel axis into the surface plane, shared with the grid editor's preview (ADR-0034).
local placement = require("beamcomp/race/placement")

local LOG_TAG = "beamcomp.spawn"

-- The car spawned when the player starts a race without a real own car to copy (on foot, free-cam, or
-- nothing). Stock config -- model only. Without this the fresh-spawn fallback would copy whatever
-- getPlayerVehicle(0) is (the walking unicycle, or a prop), so the player landed in a non-car.
local DEFAULT_VEHICLE_MODEL = "etk800"

-- Max length of a real partConfig PRESET NAME (bug partconfig-blob-bloats-standings). Named .pc presets are
-- short (e.g. "etk800_300d"); an inline-customized car can instead expose its FULL serialized partsTree as
-- veh.partConfig -- a ~74 KB string. That blob must never be reported as a records `variant` (it keyed the
-- per-race records AND, pre-fix, bloated every ~1 Hz standings broadcast to ~150 KB, freezing the host). 64
-- is comfortably above any real preset name and far below a serialized blob. Kept in sync with the server
-- gate (main.lua net.safe_variant).
local VARIANT_MAX_LEN = 64

-- True when `s` is a plausible partConfig PRESET NAME: a short, single-line string with no serialized-table
-- markers ("{" / "partsTree"), as opposed to an inline-customized car's serialized partsTree blob. Gates
-- what may be reported as a records `variant` and what may ride a spec's `config` onto a spawn. A rejected
-- value buckets the car under model-only for records (ADR-0029), the documented intent for a customized car.
local function is_preset_variant(s)
    if type(s) ~= "string" or s == "" or #s > VARIANT_MAX_LEN then
        return false
    end
    if s:find("[{\r\n]") or s:find("partsTree", 1, true) then
        return false
    end
    return true
end

-- Guard a captured spec `config` (bug partconfig-blob-bloats-standings). A config that reproduces a car for a
-- local spawn is legitimately either an inline parts TABLE (a tuned car) or a named preset STRING -- both are
-- kept unchanged. But an inline-customized car can expose its serialized partsTree as a ~74 KB STRING; that
-- blob is neither a real preset nor a parts table, so it is dropped (-> nil -> the model's default trim)
-- rather than copied onto a spawn or onto any spec that could leave this client. A table is never the blob.
local function safe_config(config)
    if type(config) == "table" then
        return config
    end
    if is_preset_variant(config) then
        return config
    end
    return nil
end

-- Delete every owned vehicle except `keep_id` (pass nil to delete all). Returns the count deleted
-- (0 is valid), or nil plus a reason when there is no MP session to act in. Shared by despawn_own
-- and despawn_owned_except. getOwnMap is a BeamMP GE global that exists only inside an MP session;
-- the delete is propagated to all clients by BeamMP (onVehicleDestroyed -> 'Od:').
local function delete_owned_except(keep_id)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end

    local own = getOwnMap()
    if type(own) ~= "table" then
        return nil, "owned-vehicle list unavailable"
    end

    local removed = 0
    for game_vehicle_id in pairs(own) do
        -- Compare as strings: own-map keys and getId() may differ in number/string type.
        if tostring(game_vehicle_id) ~= tostring(keep_id) then
            local veh = be:getObjectByID(game_vehicle_id)
            if veh then
                local ok, err = pcall(function() veh:delete() end)
                if ok then
                    removed = removed + 1
                else
                    log("W", LOG_TAG, "failed to delete vehicle " .. tostring(game_vehicle_id)
                        .. ": " .. tostring(err))
                end
            end
        end
    end

    return removed
end

-- Remove every vehicle this client owns in the current multiplayer session. Returns the
-- number deleted (0 is valid), or nil plus a reason when there is no MP session to act in.
function M.despawn_own()
    local removed, reason = delete_owned_except(nil)
    if not removed then
        return nil, reason
    end

    -- Our camera may be left on a now-deleted vehicle; drop to free-cam when we removed our
    -- car and none of ours remains (the fresh-spawn fallback will spawn one to enter).
    if removed > 0 and type(getPlayerVehicle) == "function" and not getPlayerVehicle(0)
            and commands and commands.setFreeCamera then
        pcall(commands.setFreeCamera)
    end

    log("I", LOG_TAG, string.format("despawned %d own vehicle(s)", removed))
    return removed
end

-- Remove every owned vehicle EXCEPT `keep_id` -- used by the keep+repair+teleport path to clear the
-- player's other cars while leaving the one they sit in untouched (no free-cam drop: the seated car
-- stays). Returns the count deleted, or nil plus a reason.
function M.despawn_owned_except(keep_id)
    local removed, reason = delete_owned_except(keep_id)
    if not removed then
        return nil, reason
    end

    log("I", LOG_TAG, string.format("despawned %d other own vehicle(s)", removed))
    return removed
end

-- True when `veh` is a real, race-eligible owned car: present in this client's owned-vehicle map
-- (so BeamMP-safe to touch), not the walking unicycle, and not a known non-car prop/trailer. The single
-- definition of "a real own car", shared by resolve_own_car (which car to keep) and capture_own_spec (which
-- spec is worth copying) -- it also keeps the shared prop cones out, since they are not owned (ADR-0009).
-- The non-car guard (ADR-0032 amendment) closes the prop/"Stange" leak: a player focused on an OWNED prop
-- (a barrier/trailer they spawned) must not have it copied and re-spawned as their race car -- they fall
-- through to a fresh default car instead. An unreadable Type still counts as a car (is_known_non_car drops
-- only a KNOWN non-car), so a car with missing metadata is never wrongly rejected.
local function is_owned_race_car(veh)
    if not veh or type(getOwnMap) ~= "function" or not be then
        return false
    end
    if veh.JBeam == "unicycle" then
        return false
    end
    if vehiclespecs.is_known_non_car(veh.JBeam) then
        return false
    end
    local own = getOwnMap()
    if type(own) ~= "table" then
        return false
    end
    local veh_id = veh:getId()
    for game_vehicle_id in pairs(own) do
        -- Compare as strings: own-map keys and getId() may differ in number/string type.
        if tostring(game_vehicle_id) == tostring(veh_id) then
            return true
        end
    end
    return false
end

-- (public) Snapshot a spawned car as a spec table -- model + part config + all three paint layers (mirrors
-- core_vehicles.cloneCurrent) -- the shape spawn_vehicle_at and replace_spec consume. Returns the spec, or
-- nil when the read fails. pcall-guarded (the paint/handle reads are engine-boundary). Used by the staging
-- compliance gate (init.lua) to remember the last compliant car to revert an over-cap swap back to;
-- capture_own_spec wraps it with the owned-car guard.
function M.capture_spec(veh)
    if not veh then
        return nil
    end
    local ok, spec = pcall(function()
        local paints = veh:getMetallicPaintData()
        return {
            model = veh.JBeam,
            -- Gate a serialized-partsTree blob out of the copied config (bug partconfig-blob-bloats-standings):
            -- a legitimate parts table or short preset name is kept; a ~74 KB blob-string is dropped to nil.
            config = safe_config(veh.partConfig),
            paint = createVehiclePaint(veh.color, paints[1]),
            paint2 = createVehiclePaint(veh.colorPalette0, paints[2]),
            paint3 = createVehiclePaint(veh.colorPalette1, paints[3]),
        }
    end)
    if not ok then
        log("W", LOG_TAG, "could not read vehicle spec: " .. tostring(spec))
        return nil
    end
    return spec
end

-- (public) Snapshot a spawned car's model + part config as the {model, config} the "same as host" AI mode
-- inherits (aicar=host, ADR-0036). Unlike capture_spec this skips paint: the AI spawn seam (M.spawn_at)
-- takes only model+config -- stock paint, like every other AI car -- so a paint-read failure must never
-- block the inherit. `config` may be a string (a named .pc preset, e.g. "846_340_A") or an inline parts
-- table (a tuned car); either rides straight into spawn_at. pcall-guarded (the field reads are the
-- engine-boundary reads capture_spec uses). Returns the spec, or nil when there is no vehicle or the model
-- is unreadable -- the caller then falls through the normal AI-car chain so the AI still races.
function M.host_car_spec(veh)
    if not veh then
        return nil
    end
    local ok, spec = pcall(function()
        -- Gate a serialized-partsTree blob out of the "same as host" config (bug partconfig-blob-bloats-
        -- standings): a legit parts table / short preset is kept; a ~74 KB blob-string is dropped to nil.
        return {model = veh.JBeam, config = safe_config(veh.partConfig)}
    end)
    if not ok or type(spec.model) ~= "string" or spec.model == "" then
        return nil
    end
    return spec
end

-- Snapshot the player's active vehicle so it can be respawned fresh after the despawn deletes it.
-- Returns the spec table, or nil when the player is not in a real own car worth copying (on foot,
-- free-cam, a prop, or nothing) -- the caller then spawns DEFAULT_VEHICLE_MODEL instead.
local function capture_own_spec()
    if type(getPlayerVehicle) ~= "function" then
        return nil
    end
    local veh = getPlayerVehicle(0)
    if not is_owned_race_car(veh) then
        return nil
    end
    return M.capture_spec(veh)
end

-- (public) Replace a SPAWNED car in place with a captured spec (same vehicle id) -- restoring model +
-- config + paint -- via core_vehicles.replaceVehicle. Unlike respawn_own_at this touches NO other owned
-- vehicle (respawn_own_at -> keep_own despawns the player's other cars, which on the host include the AI
-- field), so it is the safe primitive for reverting an over-cap staging swap (ADR-0032). During staging the
-- replaceVehicle it calls is the lock's swap-allowed pass-through, so the normal restage re-freezes +
-- re-places the reverted car. pcall-guarded (replaceVehicle is engine-version-coupled). Returns true, or
-- nil plus a reason.
function M.replace_spec(veh, spec)
    if not veh then
        return nil, "no vehicle"
    end
    if type(spec) ~= "table" or not spec.model then
        return nil, "no spec to apply"
    end
    if type(core_vehicles) ~= "table" or type(core_vehicles.replaceVehicle) ~= "function" then
        return nil, "core_vehicles.replaceVehicle unavailable"
    end
    local opt = {
        config = spec.config,
        paint = spec.paint,
        paint2 = spec.paint2,
        paint3 = spec.paint3,
    }
    local ok, err = pcall(core_vehicles.replaceVehicle, spec.model, opt)
    if not ok then
        return nil, "replaceVehicle failed: " .. tostring(err)
    end
    return true
end

-- Below this length a derived placement axis is degenerate (a zero-length travel axis) and the pose has
-- no usable frame at all.
local MIN_AXIS_LENGTH = 1e-6

-- The three world axes a pose places a car on: forward (lying IN the surface), right, up. Returns nil
-- exactly when the pose carries no `forward` -- the same condition under which pose_orientation keeps
-- the authored start quaternion -- so the orientation and the anchor can never disagree about which
-- frame the car ends up in. That is the whole reason this is one function and not three.
--
-- `pose.up` is the measured surface normal: placement.ground_all for a grid pose (ADR-0034 amendment
-- 2026-08-30), placement.clear_pose for the recover assist's single-pose pass, which reads it since the
-- 2026-09-01 recover-follows-surface-slope amendment -- before that it was measured and thrown away.
-- Without it the frame is the historical flat one (horizontal forward, world up) and every caller
-- reproduces its pre-slope result bit for bit -- the horizontal terms carry no z, so the Z anchor below
-- collapses back to "subtract bottom_offset from base.z".
--
-- The tilted forward comes from placement.plane_axis and NOT from handing quatFromDir the horizontal
-- axis plus the normal: setFromDir keeps `dir` verbatim and only orthogonalises `up` against it, so that
-- would produce roll with exactly zero pitch (see placement.plane_axis).
local function pose_frame(pose)
    local forward = pose.forward
    if not forward then
        return nil
    end
    -- An unusable normal (a vertical surface, no horizontal heading) falls back to the flat frame as a
    -- PAIR -- never a tilted up next to an untilted forward, which would be a skewed, non-orthogonal
    -- frame and worse than no slope at all.
    local axis = pose.up and placement.plane_axis(forward, pose.up)
    local f = axis and vec3(axis.x, axis.y, axis.z) or vec3(forward.x, forward.y, 0)
    f:normalize()
    local u = axis and vec3(pose.up.x, pose.up.y, pose.up.z) or vec3(0, 0, 1)
    u:normalize()
    -- Right-hand perpendicular, the same handedness the flat path used (right = forward x up gives
    -- (forward.y, -forward.x, 0) for a world-up frame, which is what race/grid.lua lays columns out on).
    local r = f:cross(u)
    if r:length() < MIN_AXIS_LENGTH then
        return nil
    end
    r:normalize()
    return f, r, u
end

-- The orientation quaternion for a pose, BEFORE the 180-degree Z flip each placement path applies.
-- Prefer the pose's `forward` travel axis -- face the car along it via quatFromDir -- so the car is
-- oriented to the grid (or, on the recover path, to the next checkpoint) rather than to the authored
-- start quaternion, and tilt it into the measured surface (pose_frame). Fall back to the start rotation
-- (`rot`) when the pose carries no forward (no gate normal); recover_to reaches this only with a
-- forward, so its poses carry no `rot` at all. quatFromDir/vec3/quat are engine globals, kept here
-- rather than in the pure grid module.
--
-- The `rot` fallback stays FLAT on purpose (ADR-0034 amendment 2026-08-30). That quaternion is the
-- track's own start-position transform (race/start.lua start_pose), i.e. a full 3-D orientation an
-- author placed ON the surface -- it already carries whatever pitch and roll that spot has. Composing a
-- measured normal onto it would double-count an authored tilt, and every way of doing so either needs a
-- second rotation recipe with no verified precedent here or rebuilds the quaternion from a derived
-- heading, which would throw the authored pitch/roll away even on flat ground. The tilt is therefore
-- applied only where we SYNTHESISE the orientation from a horizontal gate normal and so genuinely hold
-- no tilt information of our own.
--
-- The 180-degree flip composes correctly with a tilted pose and needs no change: `quat(0,0,1,0) * rot`
-- reads as "flip first, then rot" under BeamNG's quaternion convention (LuaQuat.__mul is the Hamilton
-- product while `q * v` applies the CONJUGATE rotation, so a*b applies a first), i.e. it is a turn about
-- the body's own Z, not about world Z. The engine's own spawn does the same (lua/ge/spawn.lua:605).
local function pose_orientation(pose)
    local forward, _, up = pose_frame(pose)
    if forward then
        return quatFromDir(forward, up)
    end
    return quat(pose.rot.x, pose.rot.y, pose.rot.z, pose.rot.w)
end

-- The config KEY out of whatever a caller was handed: a plain preset name, a .pc path, or a table
-- carrying linkedPCFile -- core_vehicles accepts all three. nil for anything else, which resolves to the
-- model's default config downstream (the right answer: that is what would spawn).
--
-- With `model` known this applies the ENGINE'S OWN rule, taken verbatim from core/vehicles.lua
-- getVehicleDetails: `config_key = pc_file:match("vehicles/<model>/(.*).pc")` -- the path RELATIVE to the
-- model folder, which keeps a config living in a SUBFOLDER keyed the way core_vehicles keys it. The
-- basename fallback below is for a caller that has no model to match against.
--
-- Plain find rather than a pattern, so a model key never has to be escaped.
local function config_key(config, model)
    if type(config) == "table" then
        config = config.linkedPCFile
    end
    if type(config) ~= "string" or config == "" then
        return nil
    end
    if type(model) == "string" and model ~= "" then
        local prefix = "vehicles/" .. model .. "/"
        local at = config:find(prefix, 1, true)
        if at then
            local relative = config:sub(at + #prefix):gsub("%.pc$", "")
            if relative ~= "" then
                return relative
            end
        end
    end
    -- The VFS uses forward slashes throughout, so stripping those is enough to get from a .pc path to
    -- the config key core_vehicles indexes its configs by.
    local key = config:match("([^/]+)$") or config
    key = key:gsub("%.pc$", "")
    if key == "" then
        return nil
    end
    return key
end

-- The (model, config-key) pair identifying which stock config's metadata box describes `veh`, read off
-- the vehicle itself the way capture_spec does -- so a placement path can reach the box without a new
-- parameter threaded through every caller. `config` is a NAMED preset only: an inline parts table (a
-- tuned car) and a serialized partsTree blob both come back nil, which vehiclespecs resolves to the
-- model's stock config. pcall-guarded; nil model when the read fails.
--
-- The key is NORMALIZED, and that is not cosmetic. veh.partConfig holds the full .pc PATH --
-- "vehicles/md_series/md_70_prisonbus.pc" -- while core_vehicles keys its configs by "md_70_prisonbus",
-- so handing the raw string on missed EVERY lookup: config_bbox then silently substituted the model's
-- DEFAULT config, and config_bbox_exact (the footprint reader's fallback) could never resolve at all.
-- Measured in-game on a staging swap into an md_series prison bus: the anchor was computed from the
-- 6.39 m default dump truck instead of the 10.91 m bus. The replace path already normalized
-- (preplace_for_replacement); this brings the read-off-the-vehicle path in line, so the two metadata
-- paths can no longer answer the same question with two different boxes.
local function model_config_of(veh)
    if not veh then
        return nil
    end
    local ok, model, config = pcall(function()
        local part_config = veh.partConfig
        return veh.JBeam, is_preset_variant(part_config) and part_config or nil
    end)
    if not ok or type(model) ~= "string" or model == "" then
        return nil
    end
    return model, config_key(config, model)
end

-- WHICH point of the car's box a pose names -- the anchor convention (ADR-0034 amendment 2026-10-07,
-- recover-anchors-the-box). Both conventions put that point on the box's BOTTOM face and on its centre
-- line, so the wheels meet the surface however high the reference node sits; they differ only in how far
-- behind the box's FRONT face the point lies, counted in half box-lengths:
--
--   ANCHOR_FRONT  (0) -- a GRID pose is the car's front edge: its front-centre lands on the pose
--                        (ADR-0034 amendments 2026-07-06 and 2026-08-29).
--   ANCHOR_MIDDLE (1) -- a RECOVER target is the car's middle: its box centre lands on the target.
--
-- The vehicle-side twin of placement.lua's NORMAL_SET_BACK / NORMAL_NO_SET_BACK -- one pose, two meanings
-- -- and handled the same way: every caller states its convention and nothing defaults it, so a caller
-- that forgot raises (require_anchor) instead of silently landing a car half a length off. A wrong number
-- is invisible in-game; a missing one is not.
local ANCHOR_FRONT = 0
local ANCHOR_MIDDLE = 1

-- Raise unless `anchor` is one of the two conventions. Each anchoring function calls it BEFORE its own
-- pcall, so a forgotten convention surfaces as an error instead of quietly degrading into the metadata or
-- reference-node fallback.
local function require_anchor(anchor)
    if anchor ~= ANCHOR_FRONT and anchor ~= ANCHOR_MIDDLE then
        error("no anchor convention given (ANCHOR_FRONT or ANCHOR_MIDDLE): " .. tostring(anchor), 3)
    end
end

-- A car's box as seen from its REFERENCE POINT (the point veh:getPosition() returns and
-- setPositionRotation places), in the car's OWN axes:
--   front       -- reference -> the box's FRONT face, along the car's forward (metres)
--   lateral     -- reference -> the box centre, along the car's right (signed)
--   bottom      -- reference -> the box BOTTOM, along the car's up (signed, normally negative)
--   half_length -- half the box's length
-- Exactly two sources fill it -- the LIVE spawn box (measure_box) and the config METADATA box
-- (metadata_box) -- and everything after that, the anchor convention and the target frame, is shared by
-- the grid and the recover alike.

-- The LIVE box, measured off the car's CURRENT transform. Read it BEFORE moving the car: a
-- getSpawnWorldOOBB read right after setPositionRotation still reflects the old transform. Raises when an
-- engine read fails; the caller owns the pcall and the fallback.
--
-- The car is decomposed along its OWN forward/right/up (getDirectionVectorUp), not along a flattened
-- forward plus world Z: getHalfExtents is body-local, so mixing it with a world-Z offset was only correct
-- while the car stood level (ADR-0034 amendment 2026-08-30) -- and cars stand tilted on a slope, which is
-- exactly when every restage, quali hold and staging repair re-measures one, and a car waiting to be
-- RECOVERED may be lying on its side. This needs no vehicle-local axis or quaternion-flip assumption: it
-- reads the real geometry.
local function measure_box(veh)
    local bb = veh:getSpawnWorldOOBB()
    local half = bb:getHalfExtents()
    local to_centre = bb:getCenter() - veh:getPosition()
    local fwd = veh:getDirectionVector()
    fwd = vec3(fwd.x, fwd.y, fwd.z)
    fwd:normalize()
    -- getDirectionVectorUp is a core vehicle method (lua/ge/spawn.lua:685, :780) but has never been
    -- read under BeamMP from here. Guarded on its own so a missing one costs the car's up axis and
    -- nothing else: world up reproduces exactly the pre-amendment decomposition, which beats failing
    -- the whole measurement and dropping to the coarser metadata box.
    local ok_up, raw_up = pcall(function() return veh:getDirectionVectorUp() end)
    local up = (ok_up and raw_up) and vec3(raw_up.x, raw_up.y, raw_up.z) or vec3(0, 0, 1)
    up:normalize()
    local right = fwd:cross(up)
    right:normalize()
    return {
        front = to_centre:dot(fwd) + half.y,
        lateral = to_centre:dot(right),
        bottom = to_centre:dot(up) - half.z,
        half_length = half.y,
    }
end

-- The config METADATA box (vehiclespecs.config_anchor, which has already resolved the jbeam frame into
-- these axes), or nil when no box is known. Usable BEFORE the car exists -- the spawn pre-position -- and
-- as the stand-in when the live read fails.
local function metadata_box(model, config)
    local anchor = vehiclespecs.config_anchor(model, config)
    if not anchor then
        return nil
    end
    return {
        front = anchor.forward,
        lateral = anchor.lateral,
        bottom = anchor.bottom,
        half_length = anchor.half.y,
    }
end

-- Where the REFERENCE POINT goes so that the point `anchor` names on `box` lands on `base`, with the car
-- standing in the target frame (forward, right, up) that pose_frame built. On a tilted pose that frame is
-- tilted too -- `bottom` included, so the box bottom meets the surface along the surface's own normal and
-- not along world Z (ADR-0034 amendment 2026-08-30). On level ground it reduces to "subtract the offsets,
-- the bottom one from z", and ANCHOR_FRONT reproduces the pre-convention arithmetic bit for bit
-- (front - 0 * half_length is front).
local function place_box(base, forward, right, up, box, anchor)
    local reach = box.front - anchor * box.half_length
    return base - (forward * reach + right * box.lateral + up * box.bottom)
end

-- The world position to put a vehicle's REFERENCE POINT at so the point `anchor` names lands on `pose`,
-- derived from the config's METADATA box instead of a live getSpawnWorldOOBB read -- plus that box, so a
-- caller can say what it placed. The same anchor anchored_target computes from the live box, so the two
-- aim at the same point and can be compared (report_prediction_gap does).
--
-- Returns nil -- never a guess -- when the pose carries no forward axis, no box is known, or the
-- arithmetic degenerates; the caller then keeps its previous behaviour.
local function metadata_anchored_target(pose, model, config, anchor)
    require_anchor(anchor)
    if type(pose) ~= "table" or type(pose.pos) ~= "table" or not pose.forward then
        return nil
    end
    local box = metadata_box(model, config)
    if not box then
        return nil
    end
    local ok, target = pcall(function()
        local target_fwd, target_right, target_up = pose_frame(pose)
        if not target_fwd then
            return nil
        end
        local base = vec3(pose.pos.x, pose.pos.y, pose.pos.z)
        return place_box(base, target_fwd, target_right, target_up, box, anchor)
    end)
    -- A degenerate forward axis normalizes to NaN instead of raising, and a NaN spawn position would lose
    -- the car entirely -- so validate the value, not just the pcall.
    if not ok or not target or target.x ~= target.x or target.y ~= target.y or target.z ~= target.z then
        return nil
    end
    return target, box
end

-- THE placement measurement behind every anchored teleport, grid and recover alike: the world position
-- to put `veh`'s REFERENCE POINT at so the point `anchor` names lands on `pose` -- horizontally on the
-- pose, and with the box BOTTOM on the grounded surface rather than the reference point, which sits
-- anywhere from 0.12 m (a bolide) to 0.81 m (a race truck) above it on the stock default configs.
--
-- Returns the position plus `info` = {source, box, reason}: where the box came from ("live box", "config
-- box", "reference node"), the box itself when there was one, and why the better source failed. It logs
-- nothing -- the grid (front_anchored_target) and the recover (M.recover_to) each report it in their own
-- words.
--
-- Three sources, best first: the LIVE box measured off the car -- so the car must not have been moved
-- yet -- then the config METADATA box (a real footprint, just not this car's deformed one), and last the
-- raw pose: the reference point itself on it, which is exactly the behaviour before any anchoring existed.
-- A pose with no forward axis has no frame to anchor in and gets the raw pose straight away, silently
-- ("no frame") -- for a grid that is the normal case of a pure-radius CP0.
local function anchored_target(veh, pose, anchor)
    require_anchor(anchor)
    local base = vec3(pose.pos.x, pose.pos.y, pose.pos.z)
    local target_fwd, target_right, target_up = pose_frame(pose)
    if not target_fwd then
        return base, {source = "no frame"}
    end
    local box = nil
    local ok, target = pcall(function()
        box = measure_box(veh)
        return place_box(base, target_fwd, target_right, target_up, box, anchor)
    end)
    if ok and target then
        return target, {source = "live box", box = box}
    end
    -- Measurement failed (bbox API gone / vehicle handle unusable): stand in with the config box before
    -- giving up on the anchor entirely.
    local model, config = model_config_of(veh)
    local predicted, predicted_box = nil, nil
    if model then
        predicted, predicted_box = metadata_anchored_target(pose, model, config, anchor)
    end
    if predicted then
        return predicted, {source = "config box", box = predicted_box, reason = tostring(target)}
    end
    return base, {source = "reference node", reason = tostring(target)}
end

-- The world position to place the reference point at so the car's FRONT-centre lands on the grid pose
-- (horizontally) and its wheels sit ON the surface (vertically) -- anchored_target under the grid's
-- convention (ANCHOR_FRONT), with the grid's own two fallback warnings. Every grid placement path reaches
-- this -- the deferred restage, the staged-quali hold and requeue, the staging repair and the quali
-- re-grid. Without a box the car is centre-anchored, i.e. stands roughly half its length too far forward;
-- without a forward axis it gets the grid pose unchanged.
local function front_anchored_target(veh, pose)
    local target, info = anchored_target(veh, pose, ANCHOR_FRONT)
    if info.source == "config box" then
        local model = model_config_of(veh)
        log("W", LOG_TAG, string.format(
            "front-anchor measurement unavailable for '%s' (%s); using its config box",
            tostring(model), info.reason))
    elseif info.source == "reference node" then
        log("W", LOG_TAG, "front-anchor unavailable; centre-anchoring: " .. info.reason)
    end
    return target
end

-- Race-scoped tally of the pre-spawn bounding-box lookup: how many of the cars this client puts on the
-- grid could be front-anchored from metadata. Module-scope and reset per race start, mirroring the
-- one-shot flags in vehiclespecs.lua; a Lua reload just restarts the count.
--
-- It exists for the ONE question that cannot be answered headless: does BeamMP -- which replaces parts of
-- the spawn/vehicle stack -- still hand core_vehicles' config metadata through? The single line
-- log_bbox_report writes after a race start is the answer, and the trigger for adding a second source
-- behind vehiclespecs.config_bbox if it reads zero.
local bbox_report = {attempted = 0, resolved = 0}

-- (public) Start a fresh bounding-box tally, before the first grid spawn of a race.
function M.begin_bbox_report()
    bbox_report.attempted = 0
    bbox_report.resolved = 0
end

-- (public) Write the one-line verdict on the tally and reset it. Silent when this client spawned no car
-- onto the grid at all (a kept own car and no AI) -- there was nothing to pre-position, so there is
-- nothing to report.
function M.log_bbox_report()
    local attempted, resolved = bbox_report.attempted, bbox_report.resolved
    M.begin_bbox_report()
    if attempted == 0 then
        return
    end
    log("I", LOG_TAG, string.format("bbox lookup: %d of %d cars resolved%s", resolved, attempted,
        resolved == 0 and " (metadata unavailable)" or ""))
end

-- Metres the engine may move a car away from the position we asked it to spawn at before it is worth a
-- line. Above the float noise and the ground snap's horizontal drift, far below a real avoidance shove.
--
-- Declared HERE, above its only use. It used to sit with the size constants far below, where it was
-- invisible to the check that reads it: a Lua chunk binds names lexically, so the read resolved to the
-- GLOBAL of that name -- nil -- and `gap > nil` raised inside the pcall around it. The instrument
-- therefore reported its failure branch for every single car and never once measured anything, which is
-- what left this bug undiagnosed across three rounds (bug staging-swap-into-bigger-car-still-jumps).
local SPAWN_NUDGE_TOLERANCE = 0.25

-- Spawn one vehicle at a grid pose (plain {pos, rot, forward?} tables). Uses the captured spec when
-- present, else the engine's default model. Returns the new vehicle, or nil plus a reason.
local function spawn_vehicle_at(pose, spec)
    if type(core_vehicles) ~= "table" or type(core_vehicles.spawnNewVehicle) ~= "function" then
        return nil, "core_vehicles.spawnNewVehicle unavailable"
    end
    local model = (spec and spec.model) or DEFAULT_VEHICLE_MODEL
    if not model then
        return nil, "no vehicle model to spawn"
    end

    -- safeSpawn is left ON for the race spawn, unlike the staging swap (race/lock.lua turns it off there).
    -- The reasons are specific to this path and were checked in the engine source, not assumed:
    --   * the end position is the grid slot either way. Every car spawned here is re-placed onto its slot
    --     by the deferred restage (restage_at_grid / ai.restage), which is a direct setPositionRotation
    --     and never goes through safeSpawn -- so the nudge costs a brief displacement, not a wrong
    --     result. The staging swap has no such correction ahead of the car becoming visible, which is
    --     why it needs the flag and this does not.
    --   * turning it off also turns off the GROUND SNAP (setSafePositionRec -> getBBOnGround). Here that
    --     is the only net under a failed terrain raycast in placement.ground_all; the swap does not need
    --     it, because the car is already standing on a grounded slot.
    -- It is not free: for spawnNewVehicle removeWhenNoPositionFound defaults to TRUE (spawn.lua), so a
    -- car the engine cannot place is DELETED rather than nudged -- which is what an "AI spawn failed for
    -- slot N" line can mean on a tight grid. That is a separate symptom with its own evidence, and
    -- trading it for cars that may spawn inside each other or underground is not a call to make without
    -- an in-game test. The log line below is what will provide that evidence.

    -- Front-anchor the spawn ITSELF from the config's metadata box. A fresh car cannot be measured (its
    -- jbeam is still loading), so the grid pose used to be applied centre-anchored and the deferred
    -- restage shoved the car forward by half its length up to 3 s later -- the visible twitch this
    -- replaces. With the box that correction is known up front and the car lands right the first time.
    -- No box (unknown config, unreadable field, metadata not reaching us under BeamMP) -> the raw pose,
    -- byte-for-byte the previous behaviour; the restage still corrects it.
    local anchored = metadata_anchored_target(pose, model, spec and spec.config, ANCHOR_FRONT)
    bbox_report.attempted = bbox_report.attempted + 1
    if anchored then
        bbox_report.resolved = bbox_report.resolved + 1
    end

    -- spawnNewVehicle wants vec3/quat userdata, not the plain tables myPose carries. Heading caveat:
    -- spawn.setVehicleObject applies a built-in 180-degree Z flip (rot = quat(0,0,1,0) * rot), so we
    -- pass pose_orientation straight through -- the internal flip then turns a forward-derived
    -- quatFromDir into a car facing down the grid, matching repair_and_place's explicit flip.
    local opt = {
        pos = anchored or vec3(pose.pos.x, pose.pos.y, pose.pos.z),
        rot = pose_orientation(pose),
    }
    if spec then
        opt.config = spec.config
        opt.paint = spec.paint
        opt.paint2 = spec.paint2
        opt.paint3 = spec.paint3
    end

    -- In an MP session core_vehicles.spawnNewVehicle is BeamMP's spawnRequest, which forwards
    -- this options table unchanged to the original; the spawn then fires onVehicleSpawned,
    -- which BeamMP sends to all clients ('Os:'). No extra call is needed to propagate.
    local ok, veh = pcall(core_vehicles.spawnNewVehicle, model, opt)
    if not ok then
        return nil, "spawn failed: " .. tostring(veh)
    end
    if not veh then
        return nil, "spawn returned no vehicle"
    end

    -- Say so when the ENGINE moved the car after we placed it.
    --
    -- safeSpawn is on for this path (deliberately -- see the note below), so spawn.lua's setSafePosition
    -- both drops the car onto the ground and pushes it around until it intersects no other vehicle. The
    -- second half can silently take a car off the slot we just computed for it, and a silent correction
    -- by the engine is exactly the class of event that cost a whole round on this feature. So measure it:
    -- the horizontal distance from where we asked for the reference point to where it actually is. Z is
    -- deliberately excluded -- the ground snap legitimately changes it.
    local checked, check_err = pcall(function()
        local landed = veh:getPosition()
        local dx, dy = landed.x - opt.pos.x, landed.y - opt.pos.y
        local gap = math.sqrt(dx * dx + dy * dy)
        if gap > SPAWN_NUDGE_TOLERANCE then
            log("W", LOG_TAG, string.format(
                "engine moved '%s' %.2f m off its spawn position (safeSpawn avoidance); "
                .. "the grid restage will pull it back", tostring(model), gap))
        end
    end)
    if not checked then
        -- With the reason, not without: the reason-less version of this line fired on 5 of 5 cars for
        -- three rounds and nobody could tell it apart from a genuinely unreadable vehicle handle.
        log("W", LOG_TAG, "could not check the spawn position of '" .. tostring(model) .. "': "
            .. tostring(check_err))
    end
    return veh
end

-- Build a PRIMARY vehicle paint layer from an opaque roster colour token (ADR-0047, round 3): a hex
-- string "rrggbb" (optionally #-prefixed) -> createVehiclePaint({x = r, y = g, z = b, w = 1}). Only the
-- primary layer is built; the caller leaves paint2/paint3 nil so those stay stock. Returns the paint
-- object, or nil for a nil/blank/invalid colour or when the paint API is unavailable -- the spawn then
-- uses stock paint. Fully guarded: a paint failure must never block an AI spawn (degrade to stock + log).
-- A bad hex is logged; a simply-absent createVehiclePaint API degrades silently (nothing to paint with).
--
-- The colour MUST be field-addressable ({x, y, z, w}), NOT an array {r, g, b, 1}: engine createVehiclePaint
-- (ge_utils.lua) reads color.x/.y/.z/.w and silently falls back to WHITE when color.x is nil, so an array
-- token would paint every AI white. This mirrors the proven player-paint path, which passes veh.color (a
-- field-addressable engine colour) into the same createVehiclePaint.
local function paint_from_color(color)
    if type(color) ~= "string" or color == "" then
        return nil
    end
    local hex = color:gsub("^#", "")
    if not hex:match("^%x%x%x%x%x%x$") then
        log("W", LOG_TAG, "invalid roster colour '" .. color .. "'; spawning stock paint")
        return nil
    end
    if type(createVehiclePaint) ~= "function" then
        return nil
    end
    local r = tonumber(hex:sub(1, 2), 16) / 255
    local g = tonumber(hex:sub(3, 4), 16) / 255
    local b = tonumber(hex:sub(5, 6), 16) / 255
    local ok, paint = pcall(createVehiclePaint, {x = r, y = g, z = b, w = 1})
    if not ok or not paint then
        log("W", LOG_TAG, "createVehiclePaint failed for '" .. color .. "'; spawning stock paint")
        return nil
    end
    return paint
end

-- Spawn one vehicle at a grid pose with a chosen model[:config], returning the new vehicle (or nil +
-- reason). The public seam over the internal spawn_vehicle_at so the AI module (race/ai, ADR-0036) spawns
-- host-owned AI cars through the exact front-anchored / grid-oriented path a player car uses, and BeamMP
-- propagates them the same way ('Os:'). Owned by the spawning client. `color` (ADR-0047) is an optional
-- opaque roster colour applied as the PRIMARY paint layer only (paint2/paint3 stay stock); nil = stock
-- paint, byte-identical to the pre-colour behaviour.
function M.spawn_at(pose, model, config, color)
    return spawn_vehicle_at(pose, {model = model, config = config, paint = paint_from_color(color)})
end

-- Return the car the player is currently in, iff it is a real owned car worth keeping for the race
-- (in the owned-vehicle map and not the walking unicycle); else nil (which selects the fresh-spawn
-- fallback). Owned membership is what makes it BeamMP-safe to touch.
--
-- `preferred_id` is the vehicle the player last switched into, tracked GE-side via onVehicleSwitched
-- (see init.lua). This is REQUIRED in BeamMP: the polling APIs (getPlayerVehicle(0) /
-- be:getPlayerVehicle(0)) stick to the FIRST owned car and do not follow later spawns/switches, so
-- without the tracked id the race start keeps the wrong car when several are spawned (confirmed
-- in-game: only the tracked-id version works). Falls back to be:getPlayerVehicle(0) when no tracked
-- id is owned/valid (single car, or right after load).
function M.resolve_own_car(preferred_id)
    if not be or type(getOwnMap) ~= "function" then
        return nil
    end

    -- The owned, non-unicycle vehicle object for `id`, or nil.
    local function owned_car(id)
        if id == nil then
            return nil
        end
        local veh = be:getObjectByID(tonumber(id) or id)
        if is_owned_race_car(veh) then
            return veh
        end
        return nil
    end

    local seated = owned_car(preferred_id)
    if seated then
        return seated
    end
    local pv = be:getPlayerVehicle(0)
    return owned_car(pv and pv:getId())
end

-- Repair + teleport a vehicle to a grid pose. veh:setPositionRotation resets the vehicle to its
-- undamaged rest state at the new pose -- BeamNG's own race-start repair path
-- (gameplay/race/startPosition.lua). The 180-degree Z flip (quat(0,0,1,0) * rot) matches the flip
-- the spawn path applies internally and the engine's repair branch applies explicitly; verified
-- in-game at handover.
local function repair_and_place(veh, pose, target)
    local rot = quat(0, 0, 1, 0) * pose_orientation(pose)
    -- Front-anchor the car: measure the target from its current transform BEFORE teleporting (the
    -- world bbox is stale right after setPositionRotation), then place once. `target` lets a caller that
    -- already measured -- restage_at_grid, which needs the number to decide whether to move at all --
    -- reuse its reading instead of measuring the same untouched car twice.
    local pos = target or front_anchored_target(veh, pose)
    veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

-- Front-anchored, grounded placement of ANY vehicle at a grid pose -- the same repair+teleport
-- (front-anchor, ADR-0034) the player's restage uses, but WITHOUT touching other owned cars (unlike
-- respawn_own_at, which despawns the player's other vehicles). The AI module (race/ai, ADR-0036)
-- re-places each host-owned AI car here once its jbeam has loaded, so the AI cars sit on the grid exactly
-- like the players' cars instead of the center-anchored spawn pose. Returns true, or nil plus a reason.
function M.place_at_grid(veh, pose)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return nil, "invalid grid pose"
    end
    local ok, err = pcall(repair_and_place, veh, pose)
    if not ok then
        return nil, "place_at_grid failed: " .. tostring(err)
    end
    return true
end

-- Deviation (metres, horizontal) below which the deferred restage leaves a car alone. The whole point of
-- front-anchoring the spawn is that the restage becomes a no-op; teleporting a car that already stands
-- within 5 cm of its slot would put the visible twitch back for a correction nobody can see.
--
-- HORIZONTAL on purpose. The grid pose sits placement.GROUND_CLEARANCE above the surface and the car
-- settles onto its suspension during the up-to-3 s restage wait, so its Z legitimately drifts a few
-- centimetres away from the rest-pose target. Comparing in 3D would read that settling as an error and
-- lift every car back up -- exactly the shuffle being removed here. A genuine Z prediction error surfaces
-- through the prediction check below instead, and any car that does get placed is re-anchored in Z anyway.
local RESTAGE_TOLERANCE = 0.05

-- Gap (metres) between the metadata prediction and the live measurement past which the restage says so.
-- This is the in-game verification of the box's axis convention: the prediction is what the spawn aimed
-- at, the measurement is the truth once the jbeam has loaded. Silent when they agree -- a quiet log is a
-- scarce resource in this project.
local PREDICTION_TOLERANCE = 0.10

-- Horizontal distance (metres) from where `veh` stands to `target`, or nil when the position is
-- unreadable -- which makes the caller place unconditionally rather than guess.
local function horizontal_gap(veh, target)
    local ok, pos = pcall(function() return veh:getPosition() end)
    if not ok or not pos then
        return nil
    end
    local dx, dy = pos.x - target.x, pos.y - target.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Put the metadata prediction (what the spawn aimed at) next to the live measurement (the truth, now that
-- the jbeam has loaded) and log ONLY when they disagree by more than PREDICTION_TOLERANCE. This is the
-- self-check for the box's axis convention: it can only be confirmed in a real race, and a wrong sign
-- would show here as a car-length-sized gap naming the exact model and config. No log when they match.
local function report_prediction_gap(veh, pose, measured)
    local model, config = model_config_of(veh)
    local predicted = model and metadata_anchored_target(pose, model, config, ANCHOR_FRONT) or nil
    if not predicted then
        return
    end
    local dx, dy, dz = predicted.x - measured.x, predicted.y - measured.y, predicted.z - measured.z
    local gap = math.sqrt(dx * dx + dy * dy + dz * dz)
    if gap <= PREDICTION_TOLERANCE then
        return
    end
    log("W", LOG_TAG, string.format(
        "bbox prediction off by %.2f m for '%s%s': predicted (%.2f, %.2f, %.2f), "
        .. "measured (%.2f, %.2f, %.2f)",
        gap, tostring(model), config and (":" .. config) or "",
        predicted.x, predicted.y, predicted.z, measured.x, measured.y, measured.z))
end

-- (public) The deferred restage's placement: work out where the car really belongs now that its jbeam has
-- loaded, and teleport it only when it is actually off that spot.
--
-- Before the spawn was front-anchored this was an unconditional re-place, and the half-car-length
-- correction it applied is the shuffle players saw a second or two after every race start. The spawn now
-- aims at the same point, so for a correctly predicted car this resolves to "nothing to do", while a car
-- the prediction missed -- a body kit, an unknown config, a staging swap into a differently sized car --
-- is still corrected exactly as before. Everything else the restage guarantees is untouched; only the
-- setPositionRotation became conditional.
--
-- Accepted consequence: setPositionRotation also RESETS a car to its undamaged rest state, so a skipped
-- restage skips that repair too. Skipping only happens when the car is standing within a few centimetres
-- of its slot, i.e. it has not moved in the seconds since it spawned frozen, so there is nothing to
-- repair. The on-demand staging repair (init.lua) still places unconditionally for the case where there is.
--
-- Returns `moved` (true = teleported, false = already in place) plus the measured horizontal deviation in
-- metres, or nil plus a reason. A nil deviation alongside a true `moved` means the car's position could
-- not be read and it was placed unconditionally.
function M.restage_at_grid(veh, pose)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return nil, "invalid grid pose"
    end

    -- Measure here rather than inside repair_and_place: the target is needed to DECIDE, and the placement
    -- then reuses it -- the car cannot move between the two.
    local ok_target, target = pcall(front_anchored_target, veh, pose)
    if not ok_target or not target then
        -- No usable target: fall back to the unconditional re-place, i.e. exactly what this replaced.
        local placed, err = M.place_at_grid(veh, pose)
        if not placed then
            return nil, err
        end
        return true, nil
    end

    report_prediction_gap(veh, pose, target)

    local delta = horizontal_gap(veh, target)
    if delta and delta <= RESTAGE_TOLERANCE then
        return false, delta
    end
    local ok, err = pcall(repair_and_place, veh, pose, target)
    if not ok then
        return nil, "restage_at_grid failed: " .. tostring(err)
    end
    return true, delta
end

-- How many early placements one restage cycle may make (see M.preplace_at_grid). Only an actual teleport
-- counts, so the normal swap spends exactly one: the second frame finds the car in place and stops. The
-- cap only bites if a setPositionRotation on a still-loading vehicle does NOT hold -- then we try a couple
-- of frames, give up, and the car falls back to the load wait plus restage_at_grid, i.e. exactly the
-- behaviour before this existed. Without the cap that case would teleport once per frame for 3 seconds.
M.PREPLACE_MAX_TRIES = 3

-- (public) Front-anchor a car onto its grid pose from METADATA ALONE -- no getSpawnWorldOOBB read, and
-- therefore no waiting for its jbeam to load.
--
-- This exists for the vehicle SWAP, the one grid path that never goes through spawn_vehicle_at. BeamNG's
-- core/vehicles.lua `_replaceVehicle` does `localOptions.pos = veh:getPosition()`, so the replacement
-- inherits the OLD car's reference point. Because the old car stood correctly front-anchored -- its own
-- anchor baked into that very point -- the new one lands off by exactly the difference between the two
-- anchors, i.e. by the size difference of the two cars. That was only corrected once the jbeam had
-- loaded, up to RESTAGE_MAX_WAIT later: the shuffle players still saw after swapping on the grid.
--
-- The load wait only ever existed because MEASURING needs a loaded jbeam. The metadata box needs no
-- measurement, so the correction can land in the frame the new identity becomes readable -- which is at
-- once: spawn.setVehicleObject assigns veh.JBeam and veh.partConfig synchronously inside the replace,
-- before the jbeam starts loading, and the engine's own positioning (including its safeSpawn nudge) has
-- finished by then too, so nothing re-applies a position behind us afterwards.
--
-- Should the identity still read as the OLD car on an early frame, the prediction is the old car's -- and
-- the old car was already standing correctly, so the tolerance gate finds nothing to do and we simply try
-- again next frame. Idempotent by that same gate, so calling this every frame of the wait costs one
-- teleport, not one per frame.
--
-- Deliberately gives up (nil) rather than guessing whenever anything is unreadable: this is the
-- optimistic path, and the deferred restage behind it is the safety net.
--
-- Returns `moved` (true = teleported, false = already in place) plus the horizontal deviation in metres
-- and the model it predicted for, or nil plus a reason.
function M.preplace_at_grid(veh, pose)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return nil, "invalid grid pose"
    end
    local model, config = model_config_of(veh)
    if not model then
        return nil, "vehicle model unreadable"
    end
    local target = metadata_anchored_target(pose, model, config, ANCHOR_FRONT)
    if not target then
        return nil, "no config box for '" .. tostring(model) .. "'"
    end
    local delta = horizontal_gap(veh, target)
    if not delta then
        return nil, "vehicle position unreadable"
    end
    if delta <= RESTAGE_TOLERANCE then
        return false, delta, model
    end
    local ok, err = pcall(repair_and_place, veh, pose, target)
    if not ok then
        return nil, "preplace_at_grid failed: " .. tostring(err)
    end
    return true, delta, model
end

-- (public) Put `veh` exactly where a REPLACEMENT of it by `model`/`config` has to start from, so the new
-- car comes up already front-anchored on `pose` -- with no correction afterwards, and therefore no jump.
--
-- BeamNG's _replaceVehicle takes the replacement's spawn position from the OUTGOING car
-- (`localOptions.pos = veh:getPosition()`), so a swap inherits the old car's reference point and a
-- differently sized car lands offset by the difference -- the ~1 m nudge players saw a frame later.
-- Moving the outgoing car first costs nothing visually: it is deleted inside the same replaceVehicle
-- call, so it is never rendered where it was moved to.
--
-- Uses the SUBSTITUTING config box (metadata_anchored_target), deliberately unlike the footprint reader:
-- for placement an unknown config key resolving to the model default is a few centimetres of error, which
-- beats not placing at all. Returns true, or nil plus a reason -- every failure path means "leave the car
-- alone", and the deferred restage stays the safety net behind this.
function M.preplace_for_replacement(veh, pose, model, config)
    if not veh then
        return nil, "no vehicle"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" then
        return nil, "invalid grid pose"
    end
    if type(model) ~= "string" or model == "" then
        return nil, "no replacement model"
    end
    local target = metadata_anchored_target(pose, model, config_key(config, model), ANCHOR_FRONT)
    if not target then
        return nil, "no config box for '" .. model .. "'"
    end
    local ok, err = pcall(function()
        local rot = quat(0, 0, 1, 0) * pose_orientation(pose)
        veh:setPositionRotation(target.x, target.y, target.z, rot.x, rot.y, rot.z, rot.w)
    end)
    if not ok then
        return nil, "pre-position failed: " .. tostring(err)
    end
    return true
end

-- (public) Read a vehicle's current license-plate text, so the race-start path can capture the player's
-- plate BEFORE a forced/substitute spawn despawns their car, then re-apply it to the new car once its
-- jbeam has loaded (M.apply_plate). pcall-guarded -- core_vehicles.getVehicleLicenseText is unverified
-- under BeamMP. This is now the ONLY plate read left in the mod: the plate stopped being the player's
-- identity with ADR-0054, and what survives here is purely cosmetic plate preservation across a
-- respawn. Returns a non-empty string, or nil when there is no vehicle, no plate set, or the read
-- fails (nil -> keep the generated plate).
function M.read_plate(veh)
    if not veh then
        return nil
    end
    local ok, plate = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleLicenseText) == "function" then
            return core_vehicles.getVehicleLicenseText(veh)
        end
        return nil
    end)
    if ok and type(plate) == "string" and plate ~= "" then
        return plate
    end
    return nil
end

-- (public) Render a license-plate text onto an already-spawned vehicle via BeamNG's setPlateText. This
-- is the ONLY reliable way to set a forced car's plate: spawnNewVehicle ignores a spawn-time licenseText
-- (BeamNG's own techCore notes "licenseText not respected in spawnNewVehicle"), and the jbeam's
-- licenseplate init (licenseplatesSkins.lua) regenerates the plate from config.licenseName -- absent on a
-- forced spawn, so it generates a fresh random one. The jbeam init runs AFTER the GE spawn, so the plate
-- must be applied on the deferred restage (once the jbeam has loaded) or the regeneration overrides it.
-- No-op for an empty/nil plate (keeps the generated one). pcall-guarded (setPlateText is unverified under
-- BeamMP). Returns true, or nil plus a reason.
function M.apply_plate(veh, plate)
    if not veh then
        return nil, "no vehicle"
    end
    if type(plate) ~= "string" or plate == "" then
        return nil, "no plate to apply"
    end
    if type(core_vehicles) ~= "table" or type(core_vehicles.setPlateText) ~= "function" then
        return nil, "setPlateText unavailable"
    end
    local ok, err = pcall(core_vehicles.setPlateText, plate, veh:getId())
    if not ok then
        return nil, "setPlateText failed: " .. tostring(err)
    end
    return true
end

-- Split a car= token "model" or "model:config" into (model, config); config is nil when absent. Returns
-- nil when there is no model part. Shared by the Mode-2 fixed car and the Mode-3 substitute (ADR-0032).
local function parse_car_token(token)
    if type(token) ~= "string" or token == "" then
        return nil
    end
    local colon = token:find(":", 1, true)
    if not colon then
        return token, nil
    end
    local model = token:sub(1, colon - 1)
    if model == "" then
        return nil
    end
    local config = token:sub(colon + 1)
    if config == "" then
        config = nil
    end
    return model, config
end

-- Keep the player's seated owned car: despawn their other cars, then repair + teleport it onto the grid
-- (ADR-0007 primary path). Returns the kept car, or nil plus a reason.
local function keep_own(pose, own_car)
    M.despawn_owned_except(own_car:getId())
    local ok, err = pcall(repair_and_place, own_car, pose)
    if not ok then
        log("W", LOG_TAG, "repair+teleport failed: " .. tostring(err))
        return nil, "repair+teleport failed: " .. tostring(err)
    end
    log("I", LOG_TAG, string.format("kept + placed own car id=%s at grid (%.1f, %.1f, %.1f)",
        tostring(own_car:getId()), pose.pos.x, pose.pos.y, pose.pos.z))
    return own_car
end

-- Despawn the player's cars and fresh-spawn a chosen {model, config} at the grid pose. Stock paint by
-- default; when `paint_from` (a captured spec) is given, its three paint layers ride onto the new car --
-- the Mode-2 "you already own this model in your own colours" case (spawn the forced trim, keep the
-- player's paint). Shared by Mode 2 (fixed car) and the Mode-3 substitute (ADR-0032). A fresh spawn
-- either way, so the caller's deferred restage + plate re-apply (keyed on the new vehicle id) still run.
-- Returns the new car, or nil + reason.
local function spawn_fixed(pose, model, config, paint_from)
    M.despawn_own()
    local spec = {model = model, config = config}
    if paint_from then
        spec.paint = paint_from.paint
        spec.paint2 = paint_from.paint2
        spec.paint3 = paint_from.paint3
    end
    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "policy spawn failed: " .. tostring(reason))
        return nil, reason
    end
    log("I", LOG_TAG, string.format("policy spawned '%s%s'%s at grid (%.1f, %.1f, %.1f)",
        tostring(model), config and (":" .. config) or "",
        paint_from and " in own paint" or "", pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

-- Mode 2 (ADR-0032): resolve the forced model[:config] against what the player already drives. The base
-- behaviour is a stock forced car for everyone (spawn_fixed). But when the player ALREADY owns the forced
-- MODEL, don't throw away their look:
--   * exact match -- forced config absent (model-only), or equal to their current config -> keep the
--     seated car untouched via keep_own: colours, licence plate and tuning preserved, no respawn (their
--     car already IS the forced car).
--   * model matches but the forced config differs -> fresh-spawn the DEMANDED config carrying the
--     player's own paint layers (the forced trim in their colours).
-- Any gap -- no own car, a different model, or an unreadable own spec -> stock forced car, exactly as
-- before (degrade, don't crash). The config compare is deliberately conservative: only an equal (string
-- ==) or absent forced config keeps the car, so a config the admin explicitly asked for is never skipped;
-- an inline-customized own config (a table, never == a config string) falls to the config-differs branch,
-- which still yields the correct forced config in the player's colours. capture_spec is pcall-guarded and
-- returns nil on any read failure, which selects the stock fall-through. Returns the race car, or nil +
-- reason.
local function spawn_forced(pose, model, config, own_car)
    if own_car then
        local own_spec = M.capture_spec(own_car)
        if own_spec and own_spec.model == model then
            if config == nil or config == own_spec.config then
                return keep_own(pose, own_car)
            end
            return spawn_fixed(pose, model, config, own_spec)
        end
    end
    return spawn_fixed(pose, model, config)
end

-- Fallback for Mode 1 when there is no real own car (free-cam / walking / none): copy the current car's
-- spec if any, else the default model, and fresh-spawn it (ADR-0007 §2). Returns the new car, or nil +
-- reason. Capturing before the despawn is required, since the despawn deletes the car we copy.
local function fresh_spawn_own(pose)
    local spec = capture_own_spec()
    if not spec then
        log("I", LOG_TAG, "no own car to copy; spawning default vehicle '" .. DEFAULT_VEHICLE_MODEL
            .. "' at grid")
    end
    M.despawn_own()
    local veh, reason = spawn_vehicle_at(pose, spec)
    if not veh then
        log("W", LOG_TAG, "respawn failed: " .. tostring(reason))
        return nil, reason
    end
    local model_name = (spec and spec.model) or DEFAULT_VEHICLE_MODEL
    log("I", LOG_TAG, string.format("spawned fresh own '%s' at grid (%.1f, %.1f, %.1f)",
        tostring(model_name), pose.pos.x, pose.pos.y, pose.pos.z))
    return veh
end

-- Spawn the fixed default car and flag it as a "no suitable car" degrade (ADR-0032 amendment): the shared
-- best-effort fallback for the paths where no cap-compliant / random-pool car was available (the Mode-3 cap
-- with no compliant car, and car=random with an empty cap-composed pool). Always a real car (never a prop),
-- even if it violates the active cap. Returns (car, nil, true) so the caller raises the no-suitable-car
-- warning and STILL races, or (nil, reason) on a spawn failure. Distinct from fresh_spawn_own, whose default
-- spawn (on-foot Mode 1) is NOT a no-suitable-car case and stays silent.
local function spawn_default_degraded(pose)
    local veh, reason = spawn_fixed(pose, DEFAULT_VEHICLE_MODEL, nil)
    if not veh then
        return nil, reason
    end
    return veh, nil, true
end

-- (public) Live Mode-3 compliance check for a SPAWNED car (ADR-0032): read the car's live power/weight --
-- reliable, unlike pre-spawn config metadata (see the POWER-READ RISK note) -- and apply is_compliant,
-- returning (compliant, power, weight) so a caller can both gate and build a warning from the readings. A
-- nil cap is "no limit on that axis"; an unreadable input under a set cap is non-compliant (cannot verify
-- => blocked). maxkg/minkg (kg) are the STRICT player weight range, exclude-on-unreadable like the power
-- caps (distinct from the AI's lenient big-car nicety). Shared by the race-start cap resolve
-- (respawn_for_cap) and the staging swap gate (init.lua).
function M.car_compliant(veh, maxhp, maxpwr, minkg, maxkg)
    local power = vehiclespecs.vehicle_power(veh)
    local weight = vehiclespecs.vehicle_weight(veh)
    local range = vehiclespecs.weight_range(minkg, maxkg)
    return vehiclespecs.is_compliant(power, weight, maxhp, maxpwr, nil, range), power, weight
end

-- Mode 3 (ADR-0032, §5 superseded by the 2026-07-07 amendment): keep the own car when it meets the power /
-- power-to-weight / weight-range cap, else substitute the first compliant car (own model's strongest legal
-- trim first, then other models -- find_compliant), else -- when NO installed car meets the cap -- spawn the
-- fixed default car (even though it violates the cap) so the player still races (best-effort cap), instead of
-- the old abort. Own-car power + weight are read from the spawned vehicle (reliable); candidates from config
-- metadata. Returns the kept/spawned car, (nil, reason) on a spawn failure, or (car, nil, true) where the
-- third value flags "degraded to the default because no suitable car" so the caller warns, then races.
local function respawn_for_cap(pose, own_car, policy)
    local own_model = own_car and own_car.JBeam or nil
    local compliant, own_power, own_weight = false, nil, nil
    if own_car then
        compliant, own_power, own_weight =
            M.car_compliant(own_car, policy.maxhp, policy.maxpwr, policy.minkg, policy.maxkg)
    end

    if compliant then
        log("I", LOG_TAG, string.format("own car '%s' meets the cap (power=%s, weight=%s) -- kept",
            tostring(own_model), tostring(own_power), tostring(own_weight)))
        return keep_own(pose, own_car)
    end

    local range = vehiclespecs.weight_range(policy.minkg, policy.maxkg)
    local pick = vehiclespecs.find_compliant(own_model, policy.maxhp, policy.maxpwr, nil, range)
    if pick then
        log("I", LOG_TAG, string.format("own car over the cap -- substituting '%s:%s'",
            tostring(pick.model), tostring(pick.config)))
        return spawn_fixed(pose, pick.model, pick.config)
    end

    -- No installed car meets the cap: best-effort default (ADR-0032 §5 superseded) -- spawn etk800 even
    -- over the cap and signal the caller to warn; the player races rather than sitting out.
    log("W", LOG_TAG, "no car meets the cap -- spawning default '" .. DEFAULT_VEHICLE_MODEL .. "'")
    return spawn_default_degraded(pose)
end

-- car=random (ADR-0032 amendment): roll a per-player random car locally at race start, composing with the
-- active caps (the deliberate exception to the car-wins precedence -- unlike a FIXED car=, the caps still
-- apply here). The pool pick is the SHARED composition vehiclespecs.random_vehicle, identical to the AI
-- random path (random_ai_vehicle), so the two never drift. Two composable axes, defaults ON when the field
-- is nil (a typed /race car=random; the panel sends explicit booleans): randomTrim (a random compliant trim
-- vs. the stock/default trim) and noBigCars (the BIG_CAR_MAX_WEIGHT curb-weight ceiling). An empty
-- cap-composed pool degrades to the fixed default car (never a prop) and signals the caller to warn; the
-- player still races. Returns the spawned car, (nil, reason) on a spawn failure, or (car, nil, true) when it
-- degraded to the default because no suitable car was available.
local function respawn_random(pose, policy)
    local pick = vehiclespecs.random_vehicle(vehiclespecs.random_spec_from_policy(policy))
    if pick then
        log("I", LOG_TAG, string.format("car=random -> '%s%s'",
            tostring(pick.model), pick.config and (":" .. pick.config) or ""))
        return spawn_fixed(pose, pick.model, pick.config)
    end

    -- Empty compliant pool (impossible cap, or no installed car): best-effort default + warn, never a prop.
    log("W", LOG_TAG, "car=random: no compliant car -- spawning default '" .. DEFAULT_VEHICLE_MODEL .. "'")
    return spawn_default_degraded(pose)
end

-- car=host (ADR-0032 amendment): everyone races the car the ISSUER was sitting in when the race was
-- validated. That spec cannot be resolved locally -- a foreign client has never seen the host's car -- so
-- it travelled with the race start as policy.hostCar, and spawning it from here is the ordinary Mode-2
-- forced-car path: a player already in that model keeps their own paint exactly as for a typed
-- car=<model>. Returns the race car, or nil plus a reason.
--
-- THE HOST ITSELF IS DECIDED ON IDENTITY, never on a value compare. policy.hostCarIsOwn marks the client
-- whose car was captured, and that car IS the one to race -- spawn_forced would compare the relayed config
-- against a fresh capture, which for a tuned car is table == table on two separate partConfig reads (always
-- false), and would respawn the host into a stock copy. The model check beside it is a string compare and a
-- different question: the spec is read ONCE, at the verdict, so a race queued behind a running one can
-- start long after -- a host who swapped cars meanwhile is not in the captured car any more and takes the
-- ordinary forced path like everybody else, rather than racing something nobody else has.
local function respawn_host_car(pose, own_car, policy)
    local spec = type(policy.hostCar) == "table" and policy.hostCar or nil
    local model = (spec and type(spec.model) == "string" and spec.model ~= "") and spec.model or nil
    if not model then
        -- An unusable relay (an older server, a host whose capture failed) degrades to the Mode-1 paths
        -- and says so. It must never reach parse_car_token: there is no car model called "host".
        log("W", LOG_TAG, "car=host: no host car in the race start -- keeping own car")
        if own_car then
            return keep_own(pose, own_car)
        end
        return fresh_spawn_own(pose)
    end
    if policy.hostCarIsOwn and own_car and own_car.JBeam == model then
        log("I", LOG_TAG, "car=host: this is the captured car -- kept untouched")
        return keep_own(pose, own_car)
    end
    -- safe_config again, and it is the SAME gate, not a second one: this value has crossed two process
    -- boundaries since host_car_spec applied it. Idempotent for everything legitimate -- a parts table and
    -- a preset name pass through unchanged, only a serialized blob-string is dropped.
    return spawn_forced(pose, model, safe_config(spec.config), own_car)
end

-- Place this client's own car at `pose` (the grid start the server assigned), per the relayed vehicle
-- policy (ADR-0032; `policy` = {car, maxhp, maxpwr, maxkg, minkg, randomTrim, noBigCars, hostCar,
-- hostCarIsOwn}, all nil = Mode 1).
-- Modes:
--   * Mode 1 (no policy) -- ADR-0007: keep the seated owned car (repair + teleport), else fresh-spawn one.
--   * car=random -- a per-player random car composing with the active caps (ADR-0032 amendment); the two
--     random axes ride randomTrim/noBigCars. Branched BEFORE parse_car_token so "random" is not treated as
--     a model name.
--   * car=host -- the car the race's issuer was sitting in, relayed as policy.hostCar (ADR-0032
--     amendment). Branched BEFORE parse_car_token for the same reason as "random": there is no model
--     called "host".
--   * Mode 2 (car=<model>) -- fixed model[:config] for everyone; but keep the own car when it already IS the
--     forced car (colours/plate/tuning preserved), or spawn the forced config in the player's paint when
--     only the config differs.
--   * Mode 3 (maxhp/maxpwr/maxkg/minkg) -- keep the own car if compliant, else substitute, else the
--     best-effort default car (ADR-0032 §5 superseded -- no more abort).
-- Returns the resolved race car (the caller enters + freezes it), (nil, reason) on a failure, or
-- (car, nil, true) where the third value flags "degraded to the default because no suitable car was
-- available" (car=random empty pool, or the Mode-3 no-compliant-car case) so the caller warns then races.
-- BeamMP propagates the despawn ('Od:'), spawn ('Os:'), and a kept car's teleport (owned-vehicle sync).
function M.respawn_own_at(pose, own_car, policy)
    if type(getOwnMap) ~= "function" or not be then
        return nil, "not in a multiplayer session"
    end
    if type(pose) ~= "table" or type(pose.pos) ~= "table" or type(pose.rot) ~= "table" then
        return nil, "invalid grid pose"
    end
    policy = policy or {}

    if policy.car == "random" then
        return respawn_random(pose, policy)
    end

    if policy.car == "host" then
        return respawn_host_car(pose, own_car, policy)
    end

    if policy.car then
        local model, config = parse_car_token(policy.car)
        if not model then
            return nil, "invalid car= '" .. tostring(policy.car) .. "'"
        end
        return spawn_forced(pose, model, config, own_car)
    end

    if policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg then
        return respawn_for_cap(pose, own_car, policy)
    end

    if own_car then
        return keep_own(pose, own_car)
    end
    return fresh_spawn_own(pose)
end

-- Teleport + repair a vehicle to a recover target: {pos, dir, up} as init.recover_target builds it
-- from placement.resolve. The car faces along `dir` and lies in the surface whose normal is `up`
-- -- placement measured that normal at exactly this spot, and a nil one means nothing was measured, so the
-- car stands level (ADR-0034 amendment 2026-09-01, recover-follows-surface-slope). Like repair_and_place,
-- veh:setPositionRotation resets the car to its undamaged rest state at the pose, and the same 180-degree
-- Z-flip (quat(0,0,1,0) * ...) matches the engine's repair branch (verified in-game for grid placement).
-- Used by the recover-to-last-checkpoint assist (ADR-0017). Returns true, or nil plus a reason.
--
-- WHERE the car goes is the grid's own anchoring, under the recover's convention (ADR-0034 amendment
-- 2026-10-07, recover-anchors-the-box): the car's BOX CENTRE lands on the target horizontally and its box
-- BOTTOM on the grounded surface along the measured normal -- anchored_target with ANCHOR_MIDDLE, live box
-- first, measured BEFORE the teleport. Until then the REFERENCE POINT went onto the target, a clearance
-- above the surface: the box bottom ended up below the road by however high that point sits in the car
-- (a few centimetres for most cars, half a metre for a truck or an off-roader), and off-centre by the
-- reference's own offset in the box.
--
-- The orientation is built by pose_orientation, the grid's own recipe, rather than by a second
-- hand-rolled quaternion here: quatFromDir keeps `dir` VERBATIM and only orthogonalises `up` against it,
-- so handing it a heading plus a surface normal yields roll and exactly zero pitch. That trap is
-- answered once, in pose_frame/plane_axis, and this path shares the answer -- `dir`'s own z is read as
-- nothing but a heading there. The pose deliberately carries no `rot`: pose_orientation's
-- authored-start-quaternion fallback is unreachable from here, because a `forward` with a compass heading
-- always produces a frame.
--
-- A dir with NO compass heading (straight up or down -- two checkpoints stacked exactly above each
-- other) says nothing about where to point the car and would normalize to NaN, so it counts as no dir
-- at all: keep the car's current rotation, untouched by the flip, with the reference point on the target
-- exactly as before -- there is no target frame to anchor a box in.
function M.recover_to(veh, target)
    if not veh then
        return nil, "no vehicle"
    end
    if type(target) ~= "table" or type(target.pos) ~= "table" then
        return nil, "invalid recover pose"
    end
    local pos, dir = target.pos, target.dir
    local ok, err = pcall(function()
        local heading_length = dir and math.sqrt(dir.x * dir.x + dir.y * dir.y) or 0
        if heading_length < MIN_AXIS_LENGTH then
            local rot = quat(veh:getRotation())
            veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
            return
        end
        local pose = {pos = pos, forward = dir, up = target.up}
        -- Anchor FIRST: the live box is read off the car's current transform, which the teleport replaces.
        local anchored = anchored_target(veh, pose, ANCHOR_MIDDLE)
        local rot = quat(0, 0, 1, 0) * pose_orientation(pose)
        veh:setPositionRotation(anchored.x, anchored.y, anchored.z, rot.x, rot.y, rot.z, rot.w)
    end)
    if not ok then
        return nil, "recover_to failed: " .. tostring(err)
    end
    return true
end

-- Best-effort "has this car been modified from stock parts" check for the records vehicle field
-- (ADR-0027). Reads veh.partConfig (the same field capture_own_spec copies, so it is known to work
-- under BeamMP): a string is a named preset config (.pc file) -> stock/preset, a table is an inline,
-- customized parts blob -> modified. Returns nil (unknown) when the field is absent or any other type,
-- so the server stores "unknown" rather than a guess. Heuristic -- confirm the string/table split
-- in-game at handover.
local function detect_modified(veh)
    local ok, part_config = pcall(function() return veh.partConfig end)
    if not ok or part_config == nil then
        return nil
    end
    if type(part_config) == "table" then
        return true
    end
    if type(part_config) == "string" then
        -- A real preset name -> stock/preset (not modified). A serialized partsTree blob string (an inline-
        -- customized car whose partConfig came through as text, bug partconfig-blob-bloats-standings) is NOT
        -- a clean preset -> modified. This corrects the prior type-only check that mislabeled such a car.
        return not is_preset_variant(part_config)
    end
    return nil
end

-- Metres of footprint change below which a re-report is not worth sending.
local SIZE_REPORT_EPSILON = 0.01

-- Metres by which a live measurement may differ from the car's own config metadata before it is worth a
-- warning. Generous: a deformed or slightly settled car reads a few centimetres off, a substituted config
-- box is metres off.
local SIZE_CROSSCHECK_TOLERANCE = 0.25

-- A footprint pair that is safe to report, or nil, nil. Rejects a non-number, a NaN (which survives
-- every comparison and would poison the server's reservation arithmetic) and a non-positive extent.
local function usable_size(length, width)
    if type(length) ~= "number" or type(width) ~= "number" then
        return nil, nil
    end
    if length ~= length or width ~= width then
        return nil, nil
    end
    if length <= 0 or width <= 0 then
        return nil, nil
    end
    return length, width
end

-- (public) One config's grid footprint from BeamNG's own metadata, WITHOUT spawning the car: length and
-- width in metres, or nil, nil.
--
-- Uses the STRICT lookup (config_bbox_exact): a config key the model does not ship yields nothing rather
-- than the model default's box. That substitution is fine when it only shifts a car by centimetres at
-- placement time, but as a footprint it is a wrong number that looks right -- it is what let a 10.9 m
-- school bus report itself as the 6.39 m default dump truck and reserve nothing.
--
-- Being readable before the car exists is what makes the early report possible: the size has to reach the
-- server BEFORE it assigns slots. config_bbox_exact publishes the box in the vehicle-local frame that
-- vehiclespecs verified against the shipped jbeam data -- y longitudinal, x lateral.
function M.spec_size(model, config)
    if type(model) ~= "string" or model == "" then
        return nil, nil
    end
    local box = vehiclespecs.config_bbox_exact(model, config)
    if not box then
        return nil, nil
    end
    return usable_size(box.max.y - box.min.y, box.max.x - box.min.x)
end

-- (public) The grid footprint of a CAPTURED spec ({model, config} from host_car_spec / capture_spec), or
-- nil, nil. spec_size above takes the engine's config KEY; a captured config is whatever the vehicle
-- reported -- a .pc PATH, a named preset, or an inline parts table -- so it is normalized here first (see
-- config_key: a path handed on raw misses every lookup). A tuned car's parts table carries no key and
-- falls back to the model's stock box, which is best-effort by nature and corrected by the post-spawn
-- report like every other car.
function M.spec_size_of(spec)
    if type(spec) ~= "table" or type(spec.model) ~= "string" or spec.model == "" then
        return nil, nil
    end
    return M.spec_size(spec.model, config_key(spec.config, spec.model))
end

-- (public) A captured spec as one human line for a chat message: "ETK 800-Series (300d)", "ETK
-- 800-Series (custom)" for an inline-tuned car, or the bare model name for a stock one. DISPLAY ONLY --
-- nothing parses this back, which is why the model shows its in-game name rather than its key. Built
-- here, on the client that captured the spec, so the vehicle-blind server (ADR-0005) can put the car's
-- name in a chat line without ever reading `model` itself.
function M.spec_label(spec)
    if type(spec) ~= "table" or type(spec.model) ~= "string" or spec.model == "" then
        return "unknown car"
    end
    local label = vehiclespecs.model_label(spec.model)
    if type(spec.config) == "table" then
        return label .. " (custom)"
    end
    local key = config_key(spec.config, spec.model)
    return key and (label .. " (" .. key .. ")") or label
end

-- (public) Forward half-length (metres) of a vehicle's spawn bounding box, or nil when the box cannot be
-- read (no vehicle, jbeam not up yet, bbox API gone). The same measurement front_anchored_target anchors
-- the car's front from, and the same box car_size measures -- which is why it lives here with them rather
-- than in the caller.
--
-- The deferred restage uses it as a JBEAM-LOADED PROBE: the value changes the moment a replaced car's own
-- jbeam comes up, so a caller that took a reading BEFORE the replace can tell the new car from the old.
-- pcall: the bbox API is engine-version-coupled, so a mismatch reads as "unknown" rather than erroring.
function M.spawn_oobb_forward(veh)
    if not veh then
        return nil
    end
    local ok, half_y = pcall(function()
        return veh:getSpawnWorldOOBB():getHalfExtents().y
    end)
    if ok and type(half_y) == "number" then
        return half_y
    end
    return nil
end

-- (public) A LIVE car's grid footprint (length, width in metres) plus where the number came from, or
-- nil when neither source reads.
--
-- MEASURED FIRST, metadata second -- the opposite of the placement path, and deliberately. A live car is
-- ground truth: it is immune to a config key the model does not ship, to a player-saved config, and to a
-- mod vehicle with no metadata at all. The measured extents come from the same oriented spawn box
-- front_anchored_target already reads getHalfExtents().y from, so the axis convention is the verified one.
--
-- The cost of measuring is that a car whose jbeam is still loading can read wrong; that is covered, because
-- the deferred restage re-reports the car once its jbeam is up (init.lua restage_swapped_car).
function M.car_size(veh)
    if not veh then
        return nil, nil
    end
    local ok, measured = pcall(function()
        local half = veh:getSpawnWorldOOBB():getHalfExtents()
        return {length = half.y * 2, width = half.x * 2}
    end)
    if ok and measured then
        local length, width = usable_size(measured.length, measured.width)
        if length then
            return length, width, "measured"
        end
    end
    local model, config = model_config_of(veh)
    local length, width = M.spec_size(model, config)
    if length then
        return length, width, "config"
    end
    return nil, nil, nil
end

-- (public) The footprint of a "model[:config]" car token, or nil, nil. Both sentinels are branched out
-- ahead of the parse exactly as respawn_own_at does: a random car is only known once it has been rolled,
-- and "host" is not a model at all -- the host's car travels as its own spec, resolved at the pre-flight
-- verdict (spec_size_of), which is where its footprint is reported from instead.
function M.token_size(token)
    if type(token) ~= "string" or token == "" or token == "random" or token == "host" then
        return nil, nil
    end
    local model, config = parse_car_token(token)
    return M.spec_size(model, config)
end

-- (public) The footprint of the car this client is about to put on the grid, as far as it is knowable
-- BEFORE the spawn (ADR-0051 §6). Two cases are knowable, and they are the ones that matter:
--   * a FIXED car (car=model[:config], Mode 2, or a class-drop class car, ADR-0042) -- exactly that
--     config's metadata box;
--   * KEEP-OWN (Mode 1: no fixed car and no caps) -- the car the player is already sitting in.
-- A cap-driven substitute (Mode 3) and car=random are only decided at spawn time, so they come back
-- nil, nil and are reported after the spawn like every other car.
function M.planned_size(policy, own_car)
    policy = policy or {}
    if policy.car then
        return M.token_size(policy.car)
    end
    if policy.maxhp or policy.maxpwr or policy.maxkg or policy.minkg then
        return nil, nil
    end
    return M.car_size(own_car)
end

-- (public) Resolve the footprints of the cars a race has ALREADY pinned, from the tokens the server
-- relays with its pre-flight check (ADR-0051 round 2): the fixed car= policy, the uniform aicar, and the
-- roster's per-AI picks. Answering with these is what lets the very first slot assignment reserve for a
-- bus, instead of only correcting after it has spawned.
--
-- Pure token resolution, so it lives here rather than in the message handler: every miss is silent, and
-- "random", an unpinned car and a model without a metadata box all simply report nothing. Returns a table
-- with the wire fields the verdict carries; absent keys mean "not knowable yet".
function M.resolve_pinned_sizes(relayed)
    local sizes = {}
    if type(relayed) ~= "table" then
        return sizes
    end
    local length, width = M.token_size(relayed.car)
    if length then
        sizes.carSize = {carLength = length, carWidth = width}
    end
    length, width = M.token_size(relayed.aiCar)
    if length then
        sizes.aiCarSize = {carLength = length, carWidth = width}
    end
    if type(relayed.aiRoster) == "table" then
        local roster = {}
        for _, entry in ipairs(relayed.aiRoster) do
            if type(entry) == "table" and tonumber(entry.index) then
                local roster_length, roster_width = M.token_size(entry.car)
                if roster_length then
                    roster[#roster + 1] = {
                        index = tonumber(entry.index),
                        carLength = roster_length,
                        carWidth = roster_width,
                    }
                end
            end
        end
        if #roster > 0 then
            sizes.aiRosterSizes = roster
        end
    end
    return sizes
end

-- Seconds between lobby footprint checks (ADR-0051 round 2). Slow on purpose: it only has to be current
-- by the time somebody types /race, and nothing is sent unless the number changed.
M.SIZE_REPORT_INTERVAL = 2.0

-- (public) Poll the seated car's footprint on a slow timer and return it ONLY when it is new; nil
-- otherwise, which is the normal answer.
--
-- POLLED rather than hooked on the vehicle switch: a car just switched into (or just spawned) may still
-- be loading its jbeam, so a one-shot read at that moment can be wrong and stays wrong -- a poll notices
-- when the number settles. `tracker` is the caller's own little state table {wait, reported}; keeping it
-- outside means this stays a plain function and costs the caller no module-level state.
function M.poll_own_size(tracker, vehicle_id, dt_real)
    if type(tracker) ~= "table" then
        return nil
    end
    tracker.wait = (tracker.wait or 0) - (dt_real or 0)
    if tracker.wait > 0 then
        return nil
    end
    tracker.wait = M.SIZE_REPORT_INTERVAL
    local length, width = M.car_size(M.resolve_own_car(vehicle_id))
    if not length then
        return nil
    end
    local last = tracker.reported
    if last and math.abs(last.length - length) < SIZE_REPORT_EPSILON
        and math.abs(last.width - width) < SIZE_REPORT_EPSILON then
        return nil
    end
    tracker.reported = {length = length, width = width}
    return tracker.reported
end

-- Collect this client's vehicle metadata for the server's best-times records (ADR-0027). `veh` is the
-- resolved race car (the caller already holds it). Every engine read is pcall-guarded and degrades to
-- nil: the BeamNG globals for vehicle details are UNVERIFIED under BeamMP, so any gap yields a nil field
-- rather than an error -- the server stores nil vehicle fields. Player identity is no longer collected
-- here -- it is reported separately on connect (ADR-0054). Returns {vehicle = {model, type, variant,
-- modified}}.
function M.collect_client_info(veh)
    local info = {vehicle = {model = nil, type = nil, variant = nil, modified = nil}}
    if not veh then
        return info
    end

    -- Vehicle model: the JBeam name (e.g. "etk800"), read straight off the handle like elsewhere here.
    local ok_model, model = pcall(function() return veh.JBeam end)
    if ok_model and type(model) == "string" and model ~= "" then
        info.vehicle.model = model
    end

    -- Vehicle type/class: the model's body style / type from its details, keyed by the vehicle id.
    local ok_type, vtype = pcall(function()
        if type(core_vehicles) == "table"
                and type(core_vehicles.getVehicleDetails) == "function" then
            local details = core_vehicles.getVehicleDetails(veh:getId())
            local model_info = details and details.model
            if type(model_info) == "table" then
                return model_info.Type or model_info["Body Style"]
            end
        end
        return nil
    end)
    if ok_type and type(vtype) == "string" and vtype ~= "" then
        info.vehicle.type = vtype
    end

    -- Vehicle variant: the named partConfig preset (e.g. "etk800_300d") when the car is a stock/preset
    -- config, nil otherwise -- an inline-customized car buckets under the model alone for records (ADR-0029).
    -- Only a SHORT, non-serialized preset name is accepted (is_preset_variant): an inline-customized car can
    -- expose its full serialized partsTree as a ~74 KB string here, which must never be reported -- pre-fix
    -- it leaked into the per-second standings car.key and froze the host (bug partconfig-blob-bloats-standings).
    local ok_variant, part_config = pcall(function() return veh.partConfig end)
    if ok_variant and is_preset_variant(part_config) then
        info.vehicle.variant = part_config
    end

    info.vehicle.modified = detect_modified(veh)

    -- Power-to-weight (hp/kg) of the race car, for the start-order pwr mode (ADR-0033). Read client-side
    -- here so the server stays vehicle-blind (ADR-0005); nil when power or weight is unreadable, in which
    -- case the player sorts to the back of a pwr grid.
    local power = vehiclespecs.vehicle_power(veh)
    local weight = vehiclespecs.vehicle_weight(veh)
    if type(power) == "number" and type(weight) == "number" and weight > 0 then
        info.pwr = power / weight
    end

    -- Grid footprint (metres) for the size-aware slot reservation (ADR-0051). Two plain numbers with
    -- exactly pwr's shape: the server reserves slots by arithmetic on them and never reads the vehicle
    -- (race-blind, ADR-0005). nil when no box is known -- that car then reserves nothing.
    --
    -- Logged with its SOURCE. Round 1 shipped a footprint that was silently the model default's, and
    -- nothing in either log said so; this line is what makes the next such case one grep away.
    local source
    info.car_length, info.car_width, source = M.car_size(veh)
    if not info.car_length then
        log("W", LOG_TAG, string.format("grid footprint unreadable for '%s' -- it will reserve nothing",
            tostring(info.vehicle.model)))
        return info
    end
    log("I", LOG_TAG, string.format("grid footprint %.2f x %.2f m (%s) for '%s'",
        info.car_length, info.car_width, tostring(source), tostring(info.vehicle.model)))
    -- Cross-check the measured car against its own config metadata and say so loudly when they disagree.
    -- The two must agree to within a few centimetres. A large gap means one of exactly two things, and
    -- both are invisible otherwise: the config box is not this car's (round 1 -- an md_series reporting a
    -- config key the model does not ship silently got the DEFAULT config's 6.39 m instead of its real
    -- 10.91 m, so nothing reserved and the field spawned into it), or the box axes are not what this file
    -- reads them as. One line here is what makes either one a grep instead of an in-game mystery.
    if source == "measured" then
        local spec_length, spec_width = M.spec_size(model_config_of(veh))
        if spec_length and (math.abs(spec_length - info.car_length) > SIZE_CROSSCHECK_TOLERANCE
                or math.abs(spec_width - info.car_width) > SIZE_CROSSCHECK_TOLERANCE) then
            log("W", LOG_TAG, string.format(
                "footprint mismatch for '%s': measured %.2f x %.2f m, config metadata says %.2f x %.2f m"
                .. " -- using the measurement",
                tostring(info.vehicle.model), info.car_length, info.car_width, spec_length, spec_width))
        end
    end

    return info
end

-- Freeze or release a vehicle in place using BeamNG's built-in controller.setFreeze -- the same
-- lock the base game's quickrace / scenario countdowns use (e.g. scenario/quickRace.lua,
-- gameplay/race/race.lua). It holds the car put while still letting the player rev and steer. The
-- command is queued to the vehicle's VE VM, so it applies even when the car was just spawned and
-- its VE is still coming up. Owned-only by construction: the caller passes its own vehicle (the
-- freshly spawned handle, or getPlayerVehicle(0)), so no remote car is ever touched. Returns true,
-- or nil plus a reason.
function M.set_vehicle_frozen(veh, frozen)
    if not veh then
        return nil, "no vehicle"
    end
    local mode = frozen and 1 or 0
    local ok, err = pcall(function()
        veh:queueLuaCommand("controller.setFreeze(" .. mode .. ")")
    end)
    if not ok then
        return nil, "setFreeze failed: " .. tostring(err)
    end
    return true
end

return M
