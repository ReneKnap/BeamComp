"""Evaluate a beamcomp_weightprobe result (dev tool, not shipped).

Reads the JSON the in-game probe writes (scripts/dev/beamcomp_weightprobe) and answers the questions of bug
caps-live-weight-differs-from-metadata: what the live check's weight is made of (static jbeam mass, fuel,
seat occupants), whether the race-start check reads it mid-ramp, and which metadata field ("Weight" or
"Performance Data".weight) matches which live quantity on stock presets. It also lists live against
metadata power, which the start order by power-to-weight (pwr) reads.

Usage:  python evaluate_weightprobe.py [<path to beamcomp_weightprobe.json>]
Default path: %LOCALAPPDATA%\\BeamNG\\BeamNG.drive\\current\\beamcomp_weightprobe.json
"""

import json
import math
import os
import statistics
import sys

DEFAULT_RESULT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "BeamNG", "BeamNG.drive", "current",
                              "beamcomp_weightprobe.json")
WEIGHT_ROUND_KG = 5

# A preset's numbers agree with a metadata field when they are within one rounding step (the metadata
# "Weight" is rounded up to 5 kg, "Performance Data".weight is raw).
AGREE_KG = 5.0
# A measured effect "is" a quantity when the two are this close.
SAME_KG = 1.0


def ceil5(value):
    return math.ceil(value / WEIGHT_ROUND_KG) * WEIGHT_ROUND_KG


def number(row, key):
    value = row.get(key)
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def subtract(a, b):
    return None if a is None or b is None else a - b


def fmt(value, width=8, digits=1):
    if value is None:
        return "-".rjust(width)
    return ("%.*f" % (digits, value)).rjust(width)


def live_quantities(row):
    """The live numbers a weight limit could check, all raw kg."""
    settled = number(row, "settled_raw")
    return {
        "live (today's check)": settled,
        "live at the race-start check (0.5 s after reset)": number(row, "start_settle_raw"),
        "live - fuel": subtract(settled, number(row, "fuel_mass")),
        "live - occupants": subtract(settled, number(row, "occupant_effect")),
        "live - fuel - occupants (car only)": number(row, "car_only_raw"),
        "car only + a full tank": number(row, "car_full_tank_raw"),
        "static jbeam mass": number(row, "static_mass"),
    }


TABLE_COLUMNS = (
    ("Weight", "meta_weight", 0), ("PD", "meta_pd_weight", 1), ("live", "settled_raw", 1),
    ("@start", "start_settle_raw", 1), ("fuel", "fuel_mass", 1), ("occ", "occupant_effect", 1),
    ("car", "car_only_raw", 1), ("static", "static_mass", 1), ("resid", "residual", 1),
)


def preset_name(row):
    return "%s:%s" % (row.get("model"), row.get("config"))


def print_table(rows):
    print("Per preset (kg; 'occ' = measured occupant effect, 'fuel' = fuel on the nodes):")
    header = "%-30s %-8s " % ("preset", "fuel") + " ".join("%8s" % c[0] for c in TABLE_COLUMNS)
    header += "  power live/meta"
    print(header)
    print("-" * len(header))
    for row in rows:
        cells = " ".join(fmt(number(row, key), 8, digits) for _, key, digits in TABLE_COLUMNS)
        print("%-30s %-8s %s  %s/%s" % (preset_name(row)[:30], str(row.get("fuel_type") or "-")[:8], cells,
                                        row.get("live_power", "-"), row.get("meta_power", "-")))
        if row.get("reasons"):
            print("    reasons: %s" % row["reasons"][:300])


def compare(rows, field, rounded):
    """For every live quantity: how many presets agree with the metadata field, and how far off they are."""
    results = []
    for name in live_quantities(rows[0]) if rows else []:
        deviations = []
        for row in rows:
            meta = number(row, field)
            live = live_quantities(row)[name]
            if meta is None or live is None:
                continue
            deviations.append((ceil5(live) if rounded else live) - meta)
        if deviations:
            agree = sum(1 for d in deviations if abs(d) <= AGREE_KG)
            results.append((name, agree, len(deviations), statistics.median(deviations),
                            max(deviations, key=abs)))
    return results


METADATA_FIELDS = (
    ("meta_weight", '"Weight"', True),
    ("meta_pd_weight", '"Performance Data".weight', False),
)


def print_comparison(rows):
    for field, label, rounded in METADATA_FIELDS:
        rounding = ", live rounded up to 5 kg like the metadata" if rounded else ""
        print("\nWhich live quantity matches %s (agree = within %.0f kg%s):" % (label, AGREE_KG, rounding))
        for name, agree, count, median, worst in compare(rows, field, rounded):
            print("  %-50s agree %2d of %2d   median %+7.1f   worst %+7.1f" % (
                name, agree, count, median, worst))


def print_fuel(rows):
    pairs = [(number(r, "fuel_mass"), number(r, "fuel_effect")) for r in rows]
    pairs = [(a, b) for a, b in pairs if a is not None and b is not None]
    if not pairs:
        return
    worst = max(abs(a - b) for a, b in pairs)
    verdict = "the tank read is exact" if worst <= SAME_KG else "CHECK the tank read"
    print("  fuel read from the tanks vs measured by emptying them: worst gap %.2f kg over %d presets  -> %s"
          % (worst, len(pairs), verdict))


def print_occupants(rows):
    measured = [r for r in rows if number(r, "occupant_effect") is not None]
    if not measured:
        return
    effects = sorted(number(r, "occupant_effect") for r in measured)
    print("  occupant effect (live minus occupants off): min %.1f, median %.1f, max %.1f kg over %d presets"
          % (effects[0], statistics.median(effects), effects[-1], len(effects)))
    unseated = [r for r in measured if (r.get("seats") or 0) > 0 and not r.get("seated")]
    if unseated:
        print("    not seated at the settled sample: %s" % ", ".join(preset_name(r) for r in unseated))


def print_residual(rows):
    residuals = [number(r, "residual") for r in rows if number(r, "residual") is not None]
    if not residuals:
        return
    worst = max(residuals, key=abs)
    verdict = "fully explained" if abs(worst) <= SAME_KG else "something else carries mass"
    print("  residual (live - static - fuel - N2O - air - occupants): worst %+.2f kg  -> %s"
          % (worst, verdict))


def print_start_timing(rows):
    gaps = [(r, subtract(number(r, "settled_raw"), number(r, "start_settle_raw"))) for r in rows]
    gaps = [(r, d) for r, d in gaps if d is not None]
    if not gaps:
        return
    late = [(r, d) for r, d in gaps if abs(d) > SAME_KG]
    print("  race-start timing: 0.5 s after a reset the reading differs from the settled one on %d of %d"
          " presets" % (len(late), len(gaps)))
    for r, d in late:
        print("    %s  settled minus at-start %.1f kg" % (preset_name(r), d))
    back = [(r, subtract(number(r, "settled_raw"), number(r, "reset_settled_raw"))) for r in rows]
    back = [(r, d) for r, d in back if d is not None]
    stays_off = [(r, d) for r, d in back if abs(d) > SAME_KG]
    print("  3 s after the reset the car weighs what it weighed after spawning on %d of %d presets"
          % (len(back) - len(stays_off), len(back)))
    for r, d in stays_off:
        print("    %s  spawn-settled minus reset-settled %.1f kg" % (preset_name(r), d))


def print_effects(rows):
    print("\nWhat the live weight is made of:")
    print_fuel(rows)
    print_occupants(rows)
    print_residual(rows)
    print_start_timing(rows)


def print_power(rows):
    pairs = [(r, number(r, "live_power"), number(r, "meta_power")) for r in rows]
    pairs = [(r, live, meta) for r, live, meta in pairs if live is not None and meta is not None]
    if not pairs:
        return
    off = [(r, live, meta) for r, live, meta in pairs if live != meta]
    print("\nPower: live equals the metadata on %d of %d presets" % (len(pairs) - len(off), len(pairs)))
    for r, live, meta in off:
        print("  %s  live %s hp, metadata %s hp" % (preset_name(r), live, meta))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_RESULT
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    rows = [r for r in document.get("rows", []) if number(r, "settled_raw") is not None]
    skipped = [r for r in document.get("rows", []) if number(r, "settled_raw") is None]
    print("%s: game %s, started %s, %d presets measured, %d without a reading" % (
        path, document.get("game_version"), document.get("started"), len(rows), len(skipped)))
    for row in skipped:
        print("  no reading: %s  %s" % (preset_name(row), (row.get("reasons") or "")[:200]))
    if not rows:
        return 1
    print()
    print_table(rows)
    print_effects(rows)
    print_comparison(rows)
    print_power(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
