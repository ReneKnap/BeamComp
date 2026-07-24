-- BeamComp -- race prefab partition (split a race prefab's static scenery from its cone vehicles).
--
-- Lives at lua/ge/extensions/beamcomp/race/prefab.lua inside the client mod zip. Stateless and
-- reload-safe (no M.state, no file-scope mutable state). Target: client GE (LuaJIT 5.1).
--
-- A race prefab mixes two kinds of object:
--   * static scenery -- `class == "TSStatic"` (the plastic barriers/markers), client-local, NOT
--     BeamMP-propagated.
--   * knockable cone prop-vehicles -- `class == "BeamNGVehicle"` (jbeam "cones", autoEnterVehicle),
--     which spawn as real vehicles and ARE BeamMP-propagated.
--
-- ADR-0020: only the host instantiates the cones (BeamMP syncs them to everyone); non-hosts must
-- NEVER instantiate them -- spawning N cones on every client only to despawn them does not scale.
-- Two filtered copies serve the two roles:
--   * write_statics_only -- the cone-vehicle lines dropped, everything else kept. Non-hosts spawn this
--     instead of the full mission prefab, so no cone vehicle is ever created on a non-host.
--   * write_cones_only -- only the cone-vehicle objects kept (plus the SimGroup wrapper), everything
--     else dropped. The host spawns this for the quickrace source, whose cones live in a separate
--     legacy track prefab from its statics (ADR-0025) -- so the host gets the cones without re-spawning
--     the barriers/spawn-spheres/waypoints that prefab also contains.
--
-- Two on-disk formats are handled (ADR-0025):
--   * JSONL `.prefab.json` -- newline-delimited JSON, one scene object per line, plus a SimGroup
--     container line the objects parent to (references/time-trial-race-format.md s4). The SimGroup line
--     is NOT necessarily first (in hirochi_raceway/004-mediumcourse the cones precede it), so it is
--     found by class, not position. Kept lines are written back verbatim -- already valid prefab JSONL.
--   * legacy `.prefab` (TorqueScript) -- a `$ThisPrefab = new SimGroup() { ... }` wrapper whose body is
--     `new <Class>(<name>) { ... };` child blocks. The quickrace track prefabs use this. Block bounds
--     are found by brace depth; BeamNG-generated prefabs are machine-formatted (one structural brace per
--     line), so brace counting is reliable for this data. Kept blocks are written back verbatim.

local M = {}

local LOG_TAG = "beamcomp.prefab"

-- The scene-object class of the prefab's knockable cone prop-vehicles. Confirmed against the real
-- hirochi_raceway/004-mediumcourse mainPrefab.prefab.json (JSONL, 14 cone lines) and the quickrace
-- track prefabs (legacy, e.g. mediumcircuit1.prefab: `new BeamNGVehicle(cone1) { JBeam = "cones"; }`).
local CONE_OBJECT_CLASS = "BeamNGVehicle"

-- The JSONL scene-object class of the prefab's SimGroup container, kept by both filters so the written
-- copy stays a self-contained prefab.
local SIMGROUP_OBJECT_CLASS = "SimGroup"

-- Whether a decoded prefab object line is one of the cone prop-vehicles (the only thing non-hosts
-- must not spawn). Anything that is not a cone -- TSStatic scenery, the SimGroup, decals -- is kept.
local function is_cone_object(obj)
    return type(obj) == "table" and obj.class == CONE_OBJECT_CLASS
end

-- The number of `ch` (a single literal char) in `line`. gsub returns the substituted string plus a
-- replacement count; the count is what we want (the string is discarded).
local function char_count(line, ch)
    local _, count = line:gsub(ch, "")
    return count
end

-- Split a JSONL prefab's lines into a statics-only list (the cone prop-vehicle lines dropped) plus the
-- dropped-cone count. Keeps anything not positively identified as a cone -- safer to keep an unexpected
-- line than to drop scenery; a bad line decodes to nil (pcall is the boundary) and is kept. Shared by
-- write_statics_only (writes to disk) and statics_content (ships the string, ADR-0039).
local function filter_statics(raw)
    local kept = {}
    local dropped = 0
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("\r$", "")
        if trimmed ~= "" then
            local ok, obj = pcall(jsonDecode, trimmed)
            if ok and is_cone_object(obj) then
                dropped = dropped + 1
            else
                kept[#kept + 1] = trimmed
            end
        end
    end
    return kept, dropped
end

-- Write a statics-only copy of `prefab_file` to `dest_file`: every line except the cone prop-vehicle
-- lines, kept verbatim. Returns true on success, false (logged) if the file cannot be read/written or
-- has no static objects to keep. The caller spawns `dest_file` on non-hosts so cones never instantiate.
function M.write_statics_only(prefab_file, dest_file)
    if type(readFile) ~= "function" or type(writeFile) ~= "function" then
        log("W", LOG_TAG, "readFile/writeFile unavailable -- cannot filter prefab")
        return false
    end

    local raw = readFile(prefab_file)
    if not raw then
        log("W", LOG_TAG, "could not read prefab '" .. tostring(prefab_file) .. "'")
        return false
    end

    local kept, dropped = filter_statics(raw)
    if #kept == 0 then
        log("W", LOG_TAG, "prefab '" .. tostring(prefab_file) .. "' had no static objects to keep")
        return false
    end

    if not writeFile(dest_file, table.concat(kept, "\n")) then
        log("W", LOG_TAG, "could not write filtered prefab '" .. tostring(dest_file) .. "'")
        return false
    end

    log("I", LOG_TAG, string.format(
        "statics-only prefab: kept %d line(s), dropped %d cone(s) -> %s", #kept, dropped, dest_file))
    return true
end

-- Split a JSONL prefab's lines into a capped list -- every non-cone line PLUS the first `max_cones`
-- cone prop-vehicle lines, in file order -- along with the kept-cone and dropped-cone counts. The host
-- spawns this instead of the full mission prefab so a cone-rich track cannot instantiate 70+ cone
-- vehicles synchronously and hang the BeamMP race start (ADR-0020 amendment). Keeps anything not
-- positively identified as a cone (statics/decals/SimGroup) -- a bad line decodes to nil (pcall is the
-- boundary) and is kept, exactly like filter_statics. Same class match as filter_statics, so a grinder
-- prop-vehicle counts toward the cap too.
local function filter_capped(raw, max_cones)
    local kept = {}
    local kept_cones = 0
    local dropped = 0
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("\r$", "")
        if trimmed ~= "" then
            local ok, obj = pcall(jsonDecode, trimmed)
            if ok and is_cone_object(obj) then
                if kept_cones < max_cones then
                    kept[#kept + 1] = trimmed
                    kept_cones = kept_cones + 1
                else
                    dropped = dropped + 1
                end
            else
                kept[#kept + 1] = trimmed
            end
        end
    end
    return kept, kept_cones, dropped
end

-- Write a cone-capped copy of `prefab_file` to `dest_file`: every non-cone line plus at most
-- `max_cones` cone prop-vehicle lines, kept verbatim, the overflow cones dropped. Returns true on
-- success, false (logged) if the file cannot be read/written or has no objects to keep. The host spawns
-- `dest_file` instead of the full mission prefab so a cone-rich track cannot hang the race start with a
-- burst of synchronous cone-vehicle spawns (ADR-0020 amendment); under the cap the copy is
-- content-identical to the full prefab. JSONL-only (mission prefabs are `.prefab.json`).
function M.write_capped(prefab_file, dest_file, max_cones)
    if type(readFile) ~= "function" or type(writeFile) ~= "function" then
        log("W", LOG_TAG, "readFile/writeFile unavailable -- cannot filter prefab")
        return false
    end

    local raw = readFile(prefab_file)
    if not raw then
        log("W", LOG_TAG, "could not read prefab '" .. tostring(prefab_file) .. "'")
        return false
    end

    local kept, kept_cones, dropped = filter_capped(raw, max_cones)
    if #kept == 0 then
        log("W", LOG_TAG, "prefab '" .. tostring(prefab_file) .. "' had no objects to keep")
        return false
    end

    if not writeFile(dest_file, table.concat(kept, "\n")) then
        log("W", LOG_TAG, "could not write filtered prefab '" .. tostring(dest_file) .. "'")
        return false
    end

    if dropped > 0 then
        log("I", LOG_TAG, string.format(
            "capped race cones: spawned %d of %d (dropped %d to avoid the BeamMP mass-spawn "
                .. "race-start hang) -> %s", kept_cones, kept_cones + dropped, dropped, dest_file))
    else
        log("I", LOG_TAG, string.format(
            "capped race cones: kept all %d cone(s) (under the cap of %d) -> %s",
            kept_cones, max_cones, dest_file))
    end
    return true
end

-- The static-scenery content to ship to a file-less client so it can spawn this race's barriers/signs
-- without the local file (ADR-0039). For a JSONL mission prefab the statics-only string (cone vehicles
-- dropped, like write_statics_only -- a file-less client must never instantiate a cone, ADR-0020); for
-- a legacy quickrace prefab the raw text (already cone-free; its cones live in the host-only cone source,
-- ADR-0024/0025). Returns {format = "json"|"legacy", content = string} or nil (logged) on a read failure
-- or a JSONL prefab with no statics to keep. The host calls this; the consumer materializes it back.
function M.statics_content(prefab_file)
    if type(readFile) ~= "function" then
        log("W", LOG_TAG, "readFile unavailable -- cannot read prefab for distribution")
        return nil
    end

    local raw = readFile(prefab_file)
    if not raw then
        log("W", LOG_TAG, "could not read prefab '" .. tostring(prefab_file) .. "'")
        return nil
    end

    if prefab_file:find("%.prefab%.json$") then
        local kept = filter_statics(raw)
        if #kept == 0 then
            log("W", LOG_TAG, "prefab '" .. tostring(prefab_file) .. "' had no statics to distribute")
            return nil
        end
        return {format = "json", content = table.concat(kept, "\n")}
    end

    return {format = "legacy", content = raw}
end

-- Keep only the SimGroup container line and the cone-vehicle lines of a JSONL prefab; drop the
-- statics/decals/everything else. The inverse of write_statics_only. Returns the kept lines and the
-- cone count. A bad line decodes to nil and is dropped (pcall is the boundary).
local function filter_jsonl_cones(raw)
    local kept = {}
    local cones = 0
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("\r$", "")
        if trimmed ~= "" then
            local ok, obj = pcall(jsonDecode, trimmed)
            if ok and type(obj) == "table" then
                if obj.class == SIMGROUP_OBJECT_CLASS then
                    kept[#kept + 1] = trimmed
                elseif is_cone_object(obj) then
                    kept[#kept + 1] = trimmed
                    cones = cones + 1
                end
            end
        end
    end
    return kept, cones
end

-- Keep only the cone-vehicle child blocks of a legacy TorqueScript prefab, plus the enclosing SimGroup
-- wrapper and its own scalar fields; drop every other child block (SpawnSphere, nested Prefab,
-- BeamNGWaypoint, ...). Child blocks open with `new <Class>(...) {` at SimGroup body depth and close
-- when brace depth returns to that level. Returns the kept lines and the cone count.
local function filter_legacy_cones(raw)
    local kept = {}
    local cones = 0
    local depth = 0
    local in_child = false
    local child_keep = false
    local child_start_depth = 0
    local child_lines = {}

    local function close_child()
        if child_keep then
            for _, child_line in ipairs(child_lines) do
                kept[#kept + 1] = child_line
            end
            cones = cones + 1
        end
        in_child = false
        child_lines = {}
    end

    for line in (raw .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("\r$", "")
        local net = char_count(trimmed, "%{") - char_count(trimmed, "%}")

        if in_child then
            child_lines[#child_lines + 1] = trimmed
            depth = depth + net
            if depth <= child_start_depth then
                close_child()
            end
        else
            local class = trimmed:match("^%s*new%s+(%w+)%s*%(")
            if class and depth >= 1 then
                in_child = true
                child_keep = (class == CONE_OBJECT_CLASS)
                child_start_depth = depth
                child_lines = {trimmed}
                depth = depth + net
                -- A single-line child block (`new X(){...};`) closes on its own opening line.
                if depth <= child_start_depth then
                    close_child()
                end
            else
                -- SimGroup wrapper/opening, its scalar fields, the closing `};`, and file comments.
                kept[#kept + 1] = trimmed
                depth = depth + net
            end
        end
    end

    return kept, cones
end

-- Where shipped statics content is written on a file-less client before spawning (ADR-0039). BeamNG temp
-- vpaths, overwritten each load -- no cleanup needed (mirrors the STATICS/CONES temp prefixes in props.lua).
local DIST_TMP_PREFIX = "/temp/beamcomp_dist_"

-- Materialize the host's shipped statics content to temp vpaths so a file-less client can spawn the
-- race's barriers/signs without the local files (ADR-0039). `content_list` is the relayed prefabContent:
-- {name, format, content} per prefab. Writes each under the source basename (so the caller's direction
-- filter still selects the forward/reverse copy) and returns the written vpaths. Best-effort: an entry
-- that cannot be written is skipped and logged -- geometry is independent, so a missing barrier never
-- blocks the race. The caller spawns these via props.load exactly like local prefab paths.
--
-- Trust model: the content is written verbatim and then spawned, so the host could ship arbitrary prefab
-- objects. This is within BeamComp's threat model -- the issuer is an admin-gated /race owner on a private
-- friend server who can already spawn arbitrary synced vehicles (cones). `name` is the source basename
-- with no path separators (build_prefab_content uses `[^/]+$`), so the temp path cannot be traversed out.
function M.materialize(content_list)
    if type(writeFile) ~= "function" then
        log("W", LOG_TAG, "writeFile unavailable -- cannot materialize distributed prefabs")
        return {}
    end
    if type(content_list) ~= "table" then
        return {}
    end

    local paths = {}
    for _, entry in ipairs(content_list) do
        if type(entry) == "table" and type(entry.name) == "string"
            and type(entry.content) == "string" then
            local dest = DIST_TMP_PREFIX .. entry.name
            if writeFile(dest, entry.content) then
                paths[#paths + 1] = dest
            else
                log("W", LOG_TAG, "could not write distributed prefab '" .. dest .. "'")
            end
        end
    end

    log("I", LOG_TAG, string.format("materialized %d distributed prefab(s)", #paths))
    return paths
end

-- Write a cones-only copy of `prefab_file` to `dest_file`: only the cone prop-vehicle objects (plus
-- the SimGroup wrapper), everything else dropped. Format is chosen by extension -- JSONL for
-- `.prefab.json`, legacy TorqueScript otherwise (ADR-0025). Returns true on success, false (logged) if
-- the file cannot be read/written or has no cones to keep. The host spawns `dest_file` so the
-- quickrace cones exist once and BeamMP syncs them, without re-spawning the track's statics.
function M.write_cones_only(prefab_file, dest_file)
    if type(readFile) ~= "function" or type(writeFile) ~= "function" then
        log("W", LOG_TAG, "readFile/writeFile unavailable -- cannot filter prefab")
        return false
    end

    local raw = readFile(prefab_file)
    if not raw then
        log("W", LOG_TAG, "could not read prefab '" .. tostring(prefab_file) .. "'")
        return false
    end

    local kept, cones
    if prefab_file:find("%.prefab%.json$") then
        kept, cones = filter_jsonl_cones(raw)
    else
        kept, cones = filter_legacy_cones(raw)
    end

    if cones == 0 then
        log("W", LOG_TAG, "prefab '" .. tostring(prefab_file) .. "' had no cone vehicles to keep")
        return false
    end

    if not writeFile(dest_file, table.concat(kept, "\n")) then
        log("W", LOG_TAG, "could not write filtered prefab '" .. tostring(dest_file) .. "'")
        return false
    end

    log("I", LOG_TAG, string.format(
        "cones-only prefab: kept %d cone(s) -> %s", cones, dest_file))
    return true
end

return M
