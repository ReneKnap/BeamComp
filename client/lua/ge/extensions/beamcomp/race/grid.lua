-- BeamComp -- staggered start-grid pose math.
--
-- Lives at lua/ge/extensions/beamcomp/race/grid.lua inside the client mod zip. Stateless
-- and engine-independent: plain {x, y, z} / {x, y, z, w} tables in and out, no engine
-- handles, so it is trivially reload-safe. Target: client GE (LuaJIT 5.1).
--
-- Lays N players out in a two-column staggered grid behind a single base start pose
-- (the race-start-sequence feature). All cars keep the base heading; only position varies.
--
-- Local-frame assumption: +Y is forward, so "behind the line" is -Y (LONGITUDINAL_SIGN).
-- This is the one runtime-verified guess (see 2-architecture.md): if the in-world markers
-- render in front of the start line, flip LONGITUDINAL_SIGN.

local M = {}

local COLUMNS = 2
local HALF_WIDTH = 2.0        -- lateral offset of each column from centre (metres)
local ROW_GAP = 6.0           -- longitudinal gap between rows (metres)
local STAGGER = 3.0           -- extra setback applied to the right column (metres)
local LONGITUDINAL_SIGN = -1  -- -1 places the grid behind the start (local -Y)

-- Rotate a plain {x, y, z} vector by a plain {x, y, z, w} quaternion:
--   v' = v + 2w(q x v) + 2 q x (q x v)
local function rotate_vector(q, v)
    local first = {
        x = q.y * v.z - q.z * v.y,
        y = q.z * v.x - q.x * v.z,
        z = q.x * v.y - q.y * v.x,
    }
    local second = {
        x = q.y * first.z - q.z * first.y,
        y = q.z * first.x - q.x * first.z,
        z = q.x * first.y - q.y * first.x,
    }
    return {
        x = v.x + 2 * (q.w * first.x + second.x),
        y = v.y + 2 * (q.w * first.y + second.y),
        z = v.z + 2 * (q.w * first.z + second.z),
    }
end

-- Local-frame offset for a 0-based slot: column from i % 2, row from floor(i / 2). Right
-- column (column 1) is set back by an extra STAGGER for the classic grid look. `start_setback`
-- shifts every slot back by the same extra distance along the grid's own longitudinal axis -- the
-- exact axis the rows already use -- so the whole field keeps its layout and just sits further behind
-- the line (clearing the start/finish volume; ADR-0022).
local function slot_offset(slot, start_setback)
    local column = slot % COLUMNS
    local row = math.floor(slot / COLUMNS)
    local lateral = (column == 0) and -HALF_WIDTH or HALF_WIDTH
    local setback = row * ROW_GAP + ((column == 1) and STAGGER or 0) + (start_setback or 0)
    return {x = lateral, y = LONGITUDINAL_SIGN * setback, z = 0}
end

-- Grid poses for `count` players behind base_pos/base_rot. Returns a list of
-- { pos = {x, y, z}, rot = {x, y, z, w} } in slot order; every pose keeps the base heading.
-- `start_setback` (optional, default 0) pushes the whole grid further back along the row axis.
function M.poses(base_pos, base_rot, count, start_setback)
    local poses = {}
    for slot = 0, count - 1 do
        local world_offset = rotate_vector(base_rot, slot_offset(slot, start_setback))
        poses[#poses + 1] = {
            pos = {
                x = base_pos.x + world_offset.x,
                y = base_pos.y + world_offset.y,
                z = base_pos.z + world_offset.z,
            },
            rot = {x = base_rot.x, y = base_rot.y, z = base_rot.z, w = base_rot.w},
        }
    end
    return poses
end

return M
