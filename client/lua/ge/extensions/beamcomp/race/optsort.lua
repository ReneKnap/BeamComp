-- BeamComp -- GE-side display order for the settings panel's option lists (ADR-0037).
--
-- Lives at lua/ge/extensions/beamcomp/race/optsort.lua inside the client mod zip. Stateless and pure:
-- require it and call M.by_display. Target: client GE (LuaJIT 5.1).
--
-- One rule for the whole panel: a dropdown is ordered by the text it SHOWS, not by the key it submits.
-- The option builders own that rule for their own list (carlist.options for models and configs,
-- racelist.options for races), and this module holds the comparator once so those three call sites
-- cannot drift apart on case handling or tiebreaks.
--
-- Deliberately NOT applied to the sources those builders read -- vehiclespecs.list_car_models /
-- list_configs and discovery.list keep their key/id order, because the random AI pool, the
-- compliant-substitute search and the /cars + /races chat listings all read it and would silently change
-- with it. Sorting happens on the builders' own copies only.

local M = {}

-- One entry's display text, lowercased for a case-insensitive compare. A non-string label degrades to ""
-- rather than raising, so a vehicle whose metadata never yielded a label cannot take a whole dropdown
-- down (the degrade-don't-crash rule of ADR-0032). string.lower is locale-dependent for non-ASCII, and
-- mod vehicles do carry umlauts/accents -- that only affects WHERE such an entry lands, never whether the
-- comparison is well-defined.
local function display_text(entry, label_field)
    local label = entry[label_field]
    return type(label) == "string" and label:lower() or ""
end

-- Sort `list` in place by its displayed text and return it. `label_field` names the shown text
-- ("label"/"name"), `key_field` the unique selection value ("model"/"config"/"id").
--
-- The key tiebreak is what makes the order TOTAL, and that matters: table.sort is not stable in LuaJIT,
-- so two vehicles sharing a display name would otherwise swap places between pushes and the dropdown
-- would visibly reshuffle. With unique keys the comparator is a strict weak ordering, so the result is
-- identical on every call and table.sort can never reject it as an invalid order function.
function M.by_display(list, label_field, key_field)
    table.sort(list, function(a, b)
        local text_a, text_b = display_text(a, label_field), display_text(b, label_field)
        if text_a ~= text_b then
            return text_a < text_b
        end
        return tostring(a[key_field]) < tostring(b[key_field])
    end)
    return list
end

return M
