// BeamComp Grid Editor -- AngularJS directive (ADR-0037 amendment, fronting ADR-0023).
// An on-demand, admin-only panel that tunes, previews and saves parametric start grids. Opened by
// the server-gated /gridui relay (or the race-setup panel's "Grid bearbeiten" button): the GE extension
// (init.lua) pushes the race list + the map's saved grids here via guihooks and ensures this app is visible.
//
// A grid BELONGS to a race (ADR-0023 amendment 2026-07-27): the anchored race IS the assignment, so there
// is no "assign to race" picker -- saving writes the grid to the race being edited, and the Default button
// points that race's default at the active grid. The saved-grid list shows this race's grids first, then a
// non-selectable divider, then the map's other grids (loading one and saving copies it onto this race).
//
// The Load and Save areas are collapsed to their buttons and reveal what each action needs (ADR-0023
// amendment 2026-07-30, applying ADR-0037's 2026-07-30 amendment to this second panel): Load opens the
// saved-grid list and a row IS the load, Save grid reveals the name row, and a grid is deleted from the row
// it sits on, two-step. Because a load clears the running edit session, a row click is itself two-step while
// a session is active -- the one deliberate divergence from the setup panel's presets.
//
// GE owns the live edit session (race/grideditor.lua) -- this panel is render + input only. It reflects
// BeamCompGridState (the authoritative, clamped knob values) and calls the knob setters back via
// beamcomp_init.* . bngApi is referenced as the core UI global (NOT injected -- a DI miss takes the whole
// late-loaded directive down) and typeof-guarded so a miss is inert. $timeout IS injected (the typing
// pause): it is AngularJS core and cannot be missing, the way every sibling panel's main directive and this
// file's bcGridHold inject it. Dropdowns are custom (button + div list, ng-click): native <select> does not
// open in the BeamNG CEF overlay.
angular.module('beamng.apps')
.directive('beamCompGridEditor', ['$timeout', function ($timeout) {
  // A list pushed from GE, as a JavaScript array. Lua cannot tell an empty list from an empty map, so
  // every encoder sends an empty table as {} -- which is truthy and carries no .length. That defeats BOTH
  // shapes of guard this code uses: `x || []` keeps the {} (it is truthy), and `x.length <= n` lets it
  // straight through (undefined <= n is false). Applied in the push handlers, at the one point a field
  // enters the panel, so that "a list from GE is a list" is a property of the transition rather than a
  // claim about every call site that reads it -- including the call site added next week.
  //
  // What it cannot do: a NON-empty non-list also becomes [] and disappears without a sound. That is
  // acceptable because every list on this channel is built with t[#t+1] = ... and so is gap-free -- and
  // it is why this must NEVER be pointed at a map. The setup panel's configsByModel is model -> list:
  // the VALUES are lists, the map is not, and sending it through here would silently discard real data.
  //
  // One copy per app on purpose: the panels share no module space (client/ui/modules holds nothing but
  // the four app folders), the same reason keyLabel exists three times.
  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  // The upper bound of the two width pins (rows/columns), hand-mirrored from grid.MAX_AXIS_PIN in
  // race/grid.lua the way PREVIEW_MIN/PREVIEW_MAX mirror their GE constants. Deliberately its OWN
  // constant even where it holds the same number as PREVIEW_MAX: that one is how many cars the preview
  // draws, this one is how wide a grid may be authored, and one shared constant would chain the two
  // together the next time either moves. It has to be declared ABOVE LAYOUT_KNOBS, which reads it while
  // it is being built -- a `var` further down hoists as undefined, and an undefined bound is silently no
  // bound at all, which is the defect this closes.
  var AXIS_PIN_MAX = 32;

  // The NUMERIC tunable knobs (ADR-0023) in display order, split into the two sections that render them.
  // Each continuous knob has a fine (0.05) and a coarse (1.0) stepper pair; integer knobs (rows/columns)
  // step by 1 only. rows and columns are mutually exclusive width pins: pinning one drops the other (GE
  // clears it), which then shows blank ("auto") and is derived from the field at spawn. Both carry
  // `auto: true` so whichever is unpinned reads "auto". The boolean params are in neither list -- they
  // render as their own On/Off toggles (see BOOL_KNOBS below).
  //
  // `min` and `max` mirror the Lua constraints of the same name in race/grideditor.lua's own KNOBS table,
  // because a held stepper clamps locally now (see clampKnob) instead of letting GE clamp and echo back.
  // `tip` is the knob's hover help (ADR-0049), rendered by bc-grid-tip straight off this entry. It lives
  // here rather than in the ng-repeat markup for the same reason `label` and `min` do: a knob and its
  // explanation belong together, and the repeat then renders ONE text instead of one per row.
  var LAYOUT_KNOBS = [
    // `label` is display text and may be reworded -- but only within the label column's fixed width:
    // `.bc-row.bc-knob > span` in app.html pins it to min(30%, 126px), which is about 21 characters at
    // the panel's 13px, and a longer label wraps the row to two lines. 18 is the longest that ships.
    //
    // The UNIT is deliberately not in the label. Spelling it out ("Behind start line in meters") ran
    // 27 characters and wrapped every row; the cryptic "(m)" was what prompted the rewording in the
    // first place. So each tip names its unit instead, and the label stays a plain name. Putting a
    // unit back in a label means checking it against the width above.
    //
    // `key` is the PERSISTENCE CONTRACT and may not be reworded.
    // race/grid.lua resolved_params reads params.offsetForward / offsetLateral / headingDeg / rowGap /
    // colGap / rows / columns off every stored grid, and server/main.lua's grid_fit mirrors some again --
    // rename one and every saved grid silently loads with default values instead.
    //
    // 'Offset forward' was renamed because it said the opposite of what it does: a HIGHER value moves the
    // field further BACK (DEFAULT_OFFSET_FORWARD is "metres the whole grid trails behind the line").
    { key: 'offsetForward', label: 'Behind start line',
      tip: 'How far behind the start line the field sits, in meters.' },
    { key: 'offsetLateral', label: 'Shift sideways',
      tip: 'Plus moves the field to the right, minus to the left, in meters.' },
    // 'Heading' read as a compass bearing; the value is a rotation ADDED to the start line's own heading.
    { key: 'headingDeg', label: 'Rotate grid',
      tip: 'Turns the grid, and the cars turn with it, in degrees. Use it when the cars do not point along '
        + 'the road.' },
    { key: 'rowGap', label: 'Row gap', min: 0,
      tip: 'Distance from one row of cars to the next, in meters.' },
    { key: 'colGap', label: 'Column gap', min: 0,
      tip: 'Distance between two cars standing side by side, in meters.' },
    { key: 'rows', label: 'Number of rows', integer: true, auto: true, min: 1, max: AXIS_PIN_MAX,
      tip: 'Fix how many rows there are and let the width follow the number of cars.' },
    { key: 'columns', label: 'Number of columns', integer: true, auto: true, min: 1, max: AXIS_PIN_MAX,
      tip: 'Fix how many cars stand side by side and let the rows follow the number of cars.' },
  ];

  // The height section (ADR-0023 amendment 2026-09-01), revealed on demand and collapsed by default --
  // four controls that only matter where the ground is awkward, and that would otherwise crowd the
  // layout knobs every admin does use. Each car is dropped onto the ground from the height the car in
  // FRONT of it landed on, so these all describe that one drop: castHeight moves where the search
  // starts, offsetHeight where the car ends up, and the two switches turn the drop and the tilt off.
  // All four are per segment, like every other knob. The internal split height anchor is gone (the
  // chain does its job now) and was never a knob.
  // Both labels are worded in the section's OWN vocabulary -- the hint above these rows already says
  // "every car is dropped onto the ground starting from the height the car in front of it landed on", so
  // "the drop" is a word the panel has taught before either knob is read. 'Height before drop' read as
  // the height a car has before it falls (an absolute); the value raises where the drop BEGINS.
  // `key` unchanged, as above: race/grid.lua reads params.castHeight / params.offsetHeight.
  var HEIGHT_KNOBS = [
    { key: 'castHeight', label: 'Drop starts higher',
      tip: 'Begins the drop this much higher up, in meters. Raise it where the cars sit far below their real '
        + 'ground, a bank or a ramp the drop cannot reach.' },
    { key: 'offsetHeight', label: 'Lift above ground',
      tip: 'Applied after the drop, in meters, so +1 leaves the cars hovering a meter up. Use a little where '
        + 'cars sink into the terrain.' },
  ];

  // Every numeric knob, for the helpers that do not care which section a knob renders in (the edit-field
  // sync and the hold accumulator). One list so a knob can never be tuned but not synced.
  var KNOBS = LAYOUT_KNOBS.concat(HEIGHT_KNOBS);

  // Every scope.edit field the state push writes: the knobs, the preview count and the breakpoint field.
  var EDIT_FIELDS = KNOBS.map(function (k) { return k.key; }).concat(['previewCount', 'breakpointDisplay']);

  // The switch params, rendered as an Off/On pair each. They are named after what they SWITCH ON, so
  // nothing between this panel and the stored value has to invert anything: "Disable downcast: On"
  // stores noDowncast = true. `section` picks the block that renders the row.
  var BOOL_KNOBS = [
    { key: 'mirror', label: 'Mirror', section: 'layout',
      tip: 'Flip the grid to the other side of the road, so the front car swaps between left and '
        + 'right.' },
    // The label may not be reworded (it is named after what it switches ON, see above), so this tip is
    // the only place "downcast" can be put into the player's words -- hence a translation, not a repeat.
    { key: 'noDowncast', label: 'Disable downcast', section: 'height',
      tip: 'Switched on, the cars here are not dropped onto the ground at all: they keep the height of the '
        + 'car in front, plus the lift.' },
    { key: 'noSlope', label: 'Disable slope', section: 'height',
      tip: 'Keeps the cars in this part level instead of leaning them with the ground.' },
  ];

  // The switch rows of one section, in declaration order.
  function boolKnobsOf(section) {
    return BOOL_KNOBS.filter(function (k) { return k.section === section; });
  }

  // The name of `raceId`'s default grid in a {name, race, isDefault} list, or '' when it has none. The
  // server holds the one-default-per-race invariant (grid_store.ensure_default), so at most one matches.
  function defaultGridName(grids, raceId) {
    var list = grids || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].race === raceId && list[i].isDefault) {
        return list[i].name;
      }
    }
    return '';
  }

  // ----- Hover help copy (ADR-0049) -----------------------------------------------------------------
  // One entry per control that is not a knob (numeric knobs and switches carry their own text on their
  // entry above), rendered by bcGridTip at the bottom of this file after a deliberate hover. The markup
  // carries only the key.
  //
  // STYLE, tightened after the first in-game round: short everyday words; say what the control does and
  // what changes if you touch it; then stop. No mechanism, and no sentence whose job is to justify a
  // design decision -- this is read by an admin standing in the game.
  //
  // Every line is still written from the code that implements it (this file, race/grideditor.lua,
  // race/grid.lua). An entry may be a FUNCTION of the scope where the useful answer depends on live
  // state (see scope.tip).
  var TIPS = {
    race: 'The race this grid is for.',
    newGrid: 'Start a fresh grid from the track default. Needs a race picked.',
    load: 'Show the grids saved on this map.',
    gridRow: 'Load this grid for editing.',
    gridDelete: 'Delete this saved grid.',
    direction: 'Which way round the track this layout is for. Forward and reverse are stored separately.',
    cameraToGrid: 'Move the camera above P1 of this grid. Not during a race.',

    breakpoint: 'The position where a new part of the grid begins. While you type, the plan shows it as a '
      + 'dashed line.',
    addBreakpoint: 'Split the grid at the position on the left, so everything from there back gets its '
      + 'own layout. A line on the ground and in the plan marks where the new part begins.',
    plan: 'The grid seen from above, P1 at the start line on the left. Drag to look along it, click a '
      + 'position to edit its part.',
    removeSegment: 'Merge this part back into the one in front of it. The first part cannot be removed.',
    segmentChips: 'The parts this grid is split into, each labelled with the position it starts at. Click '
      + 'one to edit it with the settings below.',

    previewCount: 'Sets the recommended number of participants and determines how many cars the preview '
      + 'draws.',
    heightOptions: 'Show the settings for how the cars meet the ground. You only need them where the ground '
      + 'is unusual: under a bridge, on a bank.',
    saveGrid: 'Show the name field, to store this grid for the race you are editing.',
    saveName: 'What to call this grid. A name with a space in it cannot be saved.',
    saveConfirm: 'Save the grid under this name, replacing any grid of that name on this race.',
    // Says which grid this race starts on TODAY, which is the one thing the button's own label cannot.
    // All three answers come off the saved-grid list the panel already holds.
    //
    // Keyed on state.race -- the race the RUNNING SESSION belongs to -- because that is what makeDefault
    // assigns to. It is deliberately not form.race: re-picking the dropdown re-anchors which grids count
    // as "this race's" but does NOT move where the session saves or assigns (see scope.pick). Reading the
    // dropdown here would name the wrong race's grid in exactly that case.
    makeDefault: function (scope) {
      if (!scope.savedName || !scope.state.race) {
        // The hint under this button already says to save or load first, so this branch does not repeat
        // it -- it says what the button will do once there is something to point at.
        return 'Makes this race start on the grid you are editing.';
      }
      var current = defaultGridName(scope.data.grids, scope.state.race);
      if (current === scope.savedName) {
        return 'This race already starts on "' + current + '", so this changes nothing.';
      }
      if (!current) {
        return 'This race has no grid of its own yet, so the game lines the cars up by itself. This makes '
          + 'it start on "' + scope.savedName + '".';
      }
      return 'This race starts on "' + current + '" today. This makes it start on "' + scope.savedName
        + '" instead.';
    },
    close: 'Close the editor and clear the preview. Unsaved changes are lost.',
  };

  var PREVIEW_MIN = 1;
  var PREVIEW_MAX = 32;

  // A held stepper reaches GE at most this often (ms). Every send runs recompute() GE-side --
  // grid.poses_segmented plus up to 32 ground raycasts -- so the displayed number moves at the full
  // repeat rate while GE hears about it ~10x/s (plus the guaranteed final one, see scope.endHold).
  var SEND_INTERVAL = 100;

  // How long after the last keystroke a typed number applies on its own (ms). Enter and blur still apply
  // at once; this bounds how long a number that is simply left standing waits. It also has to outlast the
  // gap between two digits: typing 12 passes through 1, and every send is a full recompute() on GE's side.
  var TYPE_DELAY = 750;

  // A field value as a number, or undefined when it cannot be read as one. AngularJS hands a number input's
  // model over as null when the field is empty and as undefined when the browser or a validator rejects the
  // text ("-", "1.", or 40 against max="32"); the input's own text is "" whenever the browser cannot read
  // it. All of these mean "nothing to apply". The same shape as the setup panel's num(); one copy per app,
  // for the reason asArray above gives.
  function readNumber(value) {
    if (value === '' || value === null || value === undefined) {
      return undefined;
    }
    var n = Number(value);
    return isFinite(n) ? n : undefined;
  }

  // Clamp one accumulator tick exactly the way grideditor.set would clamp the same value (its KNOBS
  // table plus M.set): integer knobs floor, `min` and `max` mirror the Lua constraints of the same name,
  // and continuous knobs round to 2 decimals so 0.05 steps do not accumulate float noise at 25 steps/s.
  // This has to run PER TICK on the accumulator -- otherwise holding `-` on a gap runs it to -40 and
  // then takes 40 steps to come back to where the field actually stops.
  //
  // Only rows and columns carry a `max`. Offsets, gaps and heading are unbounded above on purpose and on
  // both sides, so a knob with no `max` has to stay unbounded here too rather than pick a bound up.
  function clampKnob(knob, value) {
    var next = knob.integer ? Math.floor(value) : Math.round(value * 100) / 100;
    if (knob.min !== undefined && next < knob.min) {
      next = knob.min;
    }
    if (knob.max !== undefined && next > knob.max) {
      next = knob.max;
    }
    return next;
  }

  // The preview count's clamp, mirroring grideditor.set_preview_count: floor, then [PREVIEW_MIN,
  // PREVIEW_MAX]. One function for the held stepper and the typed field, so a 40 typed and confirmed lands
  // exactly where holding + would have parked.
  function clampPreview(value) {
    return Math.max(PREVIEW_MIN, Math.min(PREVIEW_MAX, Math.floor(value)));
  }

  // ---- The panel's two slot NUMBER SPACES (ADR-0023 amendment 2026-08-01) ------------------------
  //
  // GE, the stored params, the wire and the spawn maths are 0-based end to end: SLOT 0 is the front of
  // the grid, and grideditor.lua / grid.lua / start.lua / beamcomp.grids.json never see anything else.
  // Everything the ADMIN reads is 1-based, so the front slot is labelled "P1" -- matching every other P
  // in this mod (the race HUD writes P{{position}} 1-based throughout). The grid editor used to be the
  // only surface where P started at zero, and it is exactly the surface where an admin decides who lines
  // up in front.
  //
  // These two functions are the ONLY conversion in the panel. No other site does its own + 1 / - 1, and
  // nothing in display space is ever handed to GE: the one function that talks to GE about a slot
  // (scope.selectSegment) stays in GE space, and the typed field gets its own entry point that converts
  // exactly once (scope.selectTypedSegment). Do not "fix" the pillar/panel numbers back to the slot
  // numbers -- the mismatch between them is the point.
  //
  // Both are plain arithmetic with no guards of their own -- the caller decides what an unusable value
  // means, because the two callers want different things (the field's hold seeds from a fallback, the
  // Add breakpoint path declines). Note especially that AngularJS parses an EMPTY number input to `null`,
  // not undefined, so displayToSlot(null) is a perfectly finite -1: whoever converts a field value has to
  // rule that out FIRST (see scope.selectTypedSegment) instead of trusting geLuaNum's isFinite check.
  function slotToDisplay(slot) {
    return Number(slot) + 1;
  }

  function displayToSlot(display) {
    return Number(display) - 1;
  }

  // The breakpoint field's floor. Slot 0 is the base segment, so the smallest number the admin can dial
  // is its label -- expressed through the conversion rather than hard-coded, so the two cannot drift.
  var SLOT_DISPLAY_MIN = slotToDisplay(0);

  // ---- The plan: the grid seen from above (ADR-0023 amendment 2026-10-16) ----------------------------
  // Display constants only. Every position, line and color in the plan comes from GE
  // (BeamCompGridState.plan); this panel lays nothing out and holds no grid constant.
  //
  // The scale is fixed, so a dot keeps its size whatever the field: at the default 4 m column stagger a
  // diagonal neighbour is 34 px away and a same-column one 48 px, and a ~600 px strip shows ~100 m, the
  // whole default 16-car field. A longer field is dragged.
  var PLAN_SCALE = 6;             // px per meter
  var PLAN_HEIGHT = 104;          // px
  var PLAN_DOT_RADIUS = 10;       // px; the P<n> label sits inside the dot
  var PLAN_NOSE = 6;              // px the facing tick reaches past the dot
  var PLAN_PAD = 18;              // px of room before the start line and after the last position
  var PLAN_LEAD = 0.25;           // share of the window that shows the part before the edited one
  var PLAN_FALLBACK_WIDTH = 560;  // px, until the strip has been laid out and measured
  var PLAN_START_SQUARE = 4;      // px, the start line's checkered mark
  var PLAN_START_ROWS = 10;
  // The panel background (.bc-grid), to decide whether a dot's label is dark or light.
  var PANEL_RGB = [20 / 255, 22 / 255, 26 / 255];

  // A GE color {r, g, b, a} (0..1) as CSS.
  function cssColor(color, alpha) {
    var a = alpha === undefined ? color.a : alpha;
    return 'rgba(' + Math.round(color.r * 255) + ',' + Math.round(color.g * 255) + ','
      + Math.round(color.b * 255) + ',' + a + ')';
  }

  // Dark text on a light dot, white on a dark one, judged on the dot as it shows over the panel.
  function labelColorOn(color) {
    var shown = [color.r, color.g, color.b].map(function (c, i) {
      return c * color.a + PANEL_RGB[i] * (1 - color.a);
    });
    var light = 0.2126 * shown[0] + 0.7152 * shown[1] + 0.0722 * shown[2];
    return light > 0.5 ? '#10131a' : '#ffffff';
  }

  // GE's plan with every list normalised (see asArray), or null when GE sent none.
  function planOf(plan) {
    if (!plan) {
      return null;
    }
    return { poses: asArray(plan.poses), boundaries: asArray(plan.boundaries), parts: asArray(plan.parts) };
  }

  // The checkered start-line mark at x = 0, centred on the start pose: two columns of small squares.
  function startMark() {
    var squares = [];
    var top = -(PLAN_START_ROWS * PLAN_START_SQUARE) / 2;
    for (var row = 0; row < PLAN_START_ROWS; row++) {
      for (var col = 0; col < 2; col++) {
        squares.push({ x: (col - 1) * PLAN_START_SQUARE, y: top + row * PLAN_START_SQUARE,
          size: PLAN_START_SQUARE, fill: (row + col) % 2 === 0 ? '#f0f0f0' : '#10131a' });
      }
    }
    return squares;
  }

  function emptyPlan() {
    return { height: PLAN_HEIGHT, tx: 0, ty: PLAN_HEIGHT / 2, left: 0, right: 0, fits: true, middle: 0,
      dots: [], lines: [], dashed: null, start: startMark() };
  }

  // Save-name suggestions for a freshly started grid: the first grid of a race gets MAIN_GRID_NAME,
  // every further one "<EXTRA_GRID_PREFIX><n>". Both are prefills only -- the field stays freely editable,
  // and nothing downstream depends on a grid actually carrying one of these names.
  // Neither may contain whitespace: a grid name has to survive canSave() below, grid_save's own guard in
  // init.lua, and above all `/race grid=<name>`, whose argument parser splits on whitespace -- a spaced
  // name is unsaveable AND unaddressable (ADR-0023 spells its example name `Main` for the same reason).
  var MAIN_GRID_NAME = 'MainGrid';
  var EXTRA_GRID_PREFIX = 'NewGrid';

  // Run a Lua command on the GE side with one string argument safely embedded (single-quoted, so the
  // value's own quotes pass through; backslashes and single quotes are escaped). Inert when bngApi is
  // unavailable -- the panel simply cannot submit, never throws.
  function geLuaArg(fn, arg) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var escaped = String(arg).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua('beamcomp_init.' + fn + "('" + escaped + "')");
  }

  // Run a GE command with N string arguments, each single-quoted + escaped.
  function geLuaArgs(fn) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var args = Array.prototype.slice.call(arguments, 1).map(function (a) {
      return "'" + String(a).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
    });
    bngApi.engineLua('beamcomp_init.' + fn + '(' + args.join(', ') + ')');
  }

  // Run a GE command with one numeric argument (no quoting needed; non-finite values are dropped).
  function geLuaNum(fn, value) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var n = Number(value);
    if (!isFinite(n)) {
      return;
    }
    bngApi.engineLua('beamcomp_init.' + fn + '(' + n + ')');
  }

  // Run a no-argument GE command, same typeof guard.
  function geCall(fn) {
    if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
      bngApi.engineLua('beamcomp_init.' + fn + '()');
    }
  }

  // Set one knob: GE wants the knob name and value as a single call. grid_set takes (knob, value); embed
  // both in one engineLua call with the knob single-quoted and the value numeric.
  function geSetKnob(knob, value) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var n = Number(value);
    if (!isFinite(n)) {
      return;
    }
    var escaped = String(knob).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua("beamcomp_init.grid_set('" + escaped + "', " + n + ')');
  }

  // Set a switch knob: grid_set('<knob>', <bool>). Sent as a Lua boolean literal (no quoting, no Number
  // coercion) so grideditor stores a genuine true/false, matching grid.lua's boolean contract -- it reads
  // all three switches as `== true`, where a quoted "false" or a 0 would read as ON (0 is truthy in Lua).
  function geSetBool(knob, on) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var escaped = String(knob).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua("beamcomp_init.grid_set('" + escaped + "', " + (on ? 'true' : 'false') + ')');
  }

  // The saved-grid dropdown lists grids of several races, and a name is unique only within one race, so an
  // option's value has to address the pair. The key is an opaque token -- never split, never rendered;
  // scope.gridsByKey maps it back to {race, name}. A grid name may not contain whitespace (both save
  // paths reject it), so a single space separates the two parts unambiguously.
  function gridKey(race, name) {
    return String(race) + ' ' + String(name);
  }

  // Does `race` already own a saved grid called `name`? The pushed list spans the WHOLE map, so the race
  // is part of the comparison -- the same name on another race is a different grid (ADR-0023).
  function raceHasGrid(grids, race, name) {
    var list = grids || [];
    for (var i = 0; i < list.length; i++) {
      var g = list[i];
      if (g && g.race === race && g.name === name) {
        return true;
      }
    }
    return false;
  }

  // The save name to prefill when a fresh grid is started for `race`: the main name while that race has
  // none, otherwise "<prefix><n>" with the smallest free n from 1 up. Scoped to ONE race on purpose -- a
  // grid name only has to be unique within its race (grids[map][race][name], ADR-0023), so the other
  // tracks' identically named grids must not push this race's suggestion up. A plain scan instead of a
  // lookup table: the list is short (one map's grids) and an object keyed by user-chosen names would
  // inherit Object.prototype ("constructor" would read as taken). The loop terminates because each step
  // consumes one of the finitely many existing names.
  function suggestGridName(grids, race) {
    if (!raceHasGrid(grids, race, MAIN_GRID_NAME)) {
      return MAIN_GRID_NAME;
    }
    var n = 1;
    while (raceHasGrid(grids, race, EXTRA_GRID_PREFIX + n)) {
      n++;
    }
    return EXTRA_GRID_PREFIX + n;
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompGridEditor/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      scope.layoutKnobs = LAYOUT_KNOBS;
      scope.heightKnobs = HEIGHT_KNOBS;
      scope.layoutFlags = boolKnobsOf('layout');
      scope.heightFlags = boolKnobsOf('height');
      scope.data = { races: [], grids: [] };
      // `loadName` holds a gridKey (race + name), not a bare name: the list spans several races.
      scope.form = { race: '', loadName: '', saveName: '' };
      // The authoritative live session as last reflected by GE (BeamCompGridState). `segments` is the
      // ordered breakpoint boundaries ([{startSlot}]), `activeSegment` the 1-based index the knobs edit,
      // `activeStartSlot` that segment's start slot (ADR-0023 amendment). Every slot in here is a GE SLOT
      // (0-based) -- this payload is GE's, unchanged; only what is rendered from it is 1-based.
      // `knobDefaults` are the layout defaults GE falls back to for a knob a loaded block omits -- shown as
      // that field's placeholder (see scope.knobHint). `setupDirection` is deliberately not seeded: absent
      // means no direction line (see scope.directionNote). `plan` is the field as GE lays it out, for the
      // plan strip (see planOf; ADR-0023 amendment 2026-10-16).
      scope.state = { active: false, race: null, direction: 'forward', hasReverse: false,
        previewCount: 16, segments: [], activeSegment: 1, activeStartSlot: 0, knobs: null,
        knobDefaults: null, plan: null };
      // Editable mirror of the number fields, synced from state on each push. The knob entries hold GE's own
      // values; `breakpointDisplay` alone is in DISPLAY space (see slotToDisplay above) -- which is why it
      // is not called breakpointSlot.
      scope.edit = {};
      scope.savedName = null;   // set after a save/load; gates the default button (it needs a saved grid)
      scope.open = null;        // name of the currently open dropdown, or null
      scope.opts = { race: [], loadName: [] };
      scope.gridsByKey = {};    // gridKey -> {name, race, isDefault}, rebuilt with the load options
      // The Load and Save areas are collapsed to their buttons and reveal what each action needs
      // (ADR-0023 amendment 2026-07-30, applying ADR-0037's 2026-07-30 amendment to this panel). The LOAD
      // reveal is just `open === 'loadName'` and needs no field of its own; the save row is not a dropdown,
      // so it gets one. The two armed keys are gridKeys, so arming one row disarms every other for free.
      // None of the three lives in `form`, so no GE push can open a section by itself.
      scope.saveOpen = false;   // the Save name row is revealed
      scope.armedLoad = '';     // gridKey of the row armed to REPLACE the running session with its grid
      scope.armedDelete = '';   // gridKey of the row whose delete is armed for its confirming click
      // The height options reveal the same way (ADR-0023 amendment 2026-09-01), collapsed to start with.
      // Plain scope state on purpose: it is not in `form`, not in the snapshot and never sent to GE, so
      // it CANNOT end up in a saved grid -- the grid file describes the grid, not the editor's state.
      scope.heightOpen = false;

      function rebuildRaceOpts() {
        scope.opts.race = (scope.data.races || []).map(function (r) { return { v: r.id, label: r.label }; });
      }

      // A race's display name, for labelling grids that belong to another race. Falls back to the id.
      function raceLabel(raceId) {
        var races = scope.data.races || [];
        for (var i = 0; i < races.length; i++) {
          if (races[i].id === raceId) {
            return races[i].label;
          }
        }
        return raceId;
      }

      // The saved-grid list in two blocks (ADR-0023 amendment): the anchored race's own grids first, then
      // a non-selectable separator, then the rest of the map's grids labelled with their race. The second
      // block is deliberately kept -- loading a finished layout from another track and saving it here is
      // how a grid is copied over. GE pushes the whole map sorted by race then name, so both blocks come
      // out alphabetical on their own.
      function rebuildGridOpts() {
        var own = [];
        var foreign = [];
        scope.gridsByKey = {};
        (scope.data.grids || []).forEach(function (g) {
          if (!g || !g.name) {
            return;
          }
          var key = gridKey(g.race, g.name);
          scope.gridsByKey[key] = g;
          if (g.race === scope.form.race) {
            own.push({ v: key, label: g.isDefault ? g.name + ' (default)' : g.name });
          } else {
            foreign.push({ v: key, label: g.name + ' — ' + raceLabel(g.race) });
          }
        });
        if (own.length && foreign.length) {
          own.push({ v: null, label: '— other races (copy) —', separator: true });
        }
        scope.opts.loadName = own.concat(foreign);
        // A key that is no longer in the map's grids must not survive as the marked row, and above all not
        // as an ARMED one: a grid deleted and re-created while this list stayed open would otherwise render
        // already armed and delete (or replace the session) on ONE click. This is the single owner of the
        // pruning -- deleteGrid deliberately does not clear the selection by hand, so a server-side write
        // failure (which echoes the list back WITH the grid) correctly leaves everything standing, and
        // another admin's delete is covered by the same code. Called from the race pick and the race-list
        // push too, where scope.data.grids is unchanged and no key can vanish, so it is a no-op there.
        // A gridKey always contains a space, so it can never collide with an Object.prototype name.
        if (scope.form.loadName && !scope.gridsByKey[scope.form.loadName]) {
          scope.form.loadName = '';
        }
        if (scope.armedLoad && !scope.gridsByKey[scope.armedLoad]) {
          scope.armedLoad = '';
        }
        if (scope.armedDelete && !scope.gridsByKey[scope.armedDelete]) {
          scope.armedDelete = '';
        }
      }

      // ---- Hold-to-repeat accumulator (bcGridHold at the bottom of this file drives it) --------------
      // Holding a ± button repeats its step, and every repeat tick has to advance a LOCAL value. It
      // cannot recompute base + delta from scope.state the way a single click does: those fields are
      // only written when GE echoes BeamCompGridState back, i.e. after an async round trip, so every
      // tick would read the same stale base and the number would jitter by one step instead of climbing.
      //
      // A press therefore opens a HOLD: an optimistic accumulator seeded from the same authoritative
      // source the single click read, advanced and clamped per tick, written into the bound field at the
      // full repeat rate, and pushed to GE at most every SEND_INTERVAL ms. One hold at a time -- there is
      // one mouse.
      var hold = null;

      // Is this scope.edit field currently owned by the accumulator instead of by the GE echo?
      function isHeld(field) {
        return hold !== null && hold.field === field;
      }

      // Open (or reuse) the hold on `field` and return it. `makeHold(arg)` runs only when a hold actually
      // opens -- a repeat tick allocates nothing -- and yields the seed value, the per-tick clamp and the
      // GE send (null for a field GE never sees). Stepping a different field finishes the previous hold
      // properly first, so no accumulator is ever left open behind another one.
      //
      // A field the admin has just typed into is committed first -- the same settle Enter runs -- and the
      // hold counts on from the typed number, clamped as a tick is: 3, type 5, press + and the field and GE
      // both end at 6. The number is read BEFORE the settle, which may put the echo back into the field. An
      // unreadable one (blank, "-", a preview count the input's validator refused) leaves the seed to
      // makeHold, the authority, as before. This runs on the stepper's mousedown, which comes before the
      // input's blur, so that blur finds nothing left to commit. Typing in ANOTHER field is left to that
      // field's own blur, the one place its text can still be read.
      function holdFor(field, makeHold, arg) {
        if (isHeld(field)) {
          return hold;
        }
        scope.endHold();
        var typed;
        if (isTyping(field)) {
          typed = readNumber(scope.edit[field]);
          settleTyping();
        }
        var opened = makeHold(arg);
        hold = { field: field, value: typed === undefined ? opened.base : opened.clamp(typed),
          clamp: opened.clamp, send: opened.send, sentValue: null, sentAt: 0 };
        return hold;
      }

      // One step: advance and clamp the accumulator, show it immediately, and let it through to GE at
      // most every SEND_INTERVAL ms (leading edge -- scope.endHold is the trailing one, so there is no
      // second timer to leak).
      function advanceHold(held, delta) {
        held.value = held.clamp(held.value + delta);
        scope.edit[held.field] = held.value;
        if (!held.send) {
          return;
        }
        var now = Date.now();
        if (now - held.sentAt >= SEND_INTERVAL) {
          held.sentAt = now;
          held.sentValue = held.value;
          held.send(held.value);
        }
      }

      // End the hold: the echo owns the field again from this instant, and GE ends up holding exactly
      // the value the admin was last looking at. On the scope because bc-grid-hold-end fires it --
      // bcGridHold owns every release path (mouseup anywhere, mouseleave, blur, $destroy).
      //
      // The final send is skipped when the throttle already sent this exact value. That is not an
      // optimisation but a requirement: sending unconditionally would make an ordinary 120 ms tap -- any
      // tap longer than SEND_INTERVAL -- cost two GE round trips for one step. Where it is skipped it is
      // provably a no-op, so "the last value the admin saw is the value GE holds" stays unconditional.
      scope.endHold = function () {
        var held = hold;
        if (held === null) {
          return;
        }
        hold = null;
        if (held.send && held.sentValue !== held.value) {
          held.send(held.value);
        }
      };

      // ---- Typing: a typed number applies on Enter, on blur, or after TYPE_DELAY without a keystroke ----
      // (ADR-0023 amendment 2026-10-15.) One record at a time, like the hold -- there is one keyboard. The
      // field's ng-change opens it, and it carries that field's own send, so a typed number can only ever
      // reach the knob it was typed for, whichever field the admin moves on to.
      //
      // While a record is open, its field shows what the admin typed, not the echo (see syncEditFromState).
      // Enter and blur end it and hand the field back to GE's value (see settleTyping).
      var typing = null;

      function isTyping(field) {
        return typing !== null && typing.field === field;
      }

      // What a typed number is ABOUT: the session's race, its direction and the active segment's start. A
      // push that moves any of them under an open record drops the record, because its number belongs to
      // the old target. Every control in this panel blurs the field before it acts, so this only catches
      // a change made from outside (a console command).
      function editTarget() {
        return [scope.state.race, scope.state.direction, scope.state.activeStartSlot].join('|');
      }

      // Open (or keep) the record on `field`. `makeTyping(arg)` runs only when one opens and yields the
      // field's clamp and its GE send. A record still open on another field is settled first -- a backstop,
      // since that field's own blur has normally settled it already.
      function typingFor(field, makeTyping, arg) {
        if (isTyping(field)) {
          return typing;
        }
        settleTyping();
        var opened = makeTyping(arg);
        typing = { field: field, clamp: opened.clamp, send: opened.send, timer: null, sentValue: null,
          target: editTarget() };
        return typing;
      }

      function cancelPause(entry) {
        if (entry.timer !== null) {
          $timeout.cancel(entry.timer);
          entry.timer = null;
        }
      }

      // (Re)start the pause, so only the number the admin stopped on is sent. It reads the MODEL only:
      // while the admin is typing, a number the browser or the input's own validator refused is not a
      // number he asked for. invokeApply false: the send writes nothing this panel renders, and the echo
      // brings its own digest.
      function armPause(entry) {
        cancelPause(entry);
        entry.timer = $timeout(function () {
          entry.timer = null;
          sendTyped(entry, readNumber(scope.edit[entry.field]));
        }, TYPE_DELAY, false);
      }

      // Send a typed number through its record and answer whether it went. Nothing goes without a session
      // (as before) or for a number this record already sent: a pause send followed by Enter costs GE one
      // recompute(), not two -- the pause's echo already carries GE's answer.
      function sendTyped(entry, value) {
        if (value === undefined || !scope.state.active) {
          return false;
        }
        var clamped = entry.clamp(value);
        if (clamped === entry.sentValue) {
          return false;
        }
        entry.sentValue = clamped;
        entry.send(clamped);
        return true;
      }

      // Enter / blur: end the record and apply what it holds. The value is the model, else the input's own
      // text -- the one way to reach a preview count the max="32" validator blanked, which is clamped here
      // and never while typing. When that sends, the echo of the send settles the field. When it does not
      // (unreadable, no session, or the number the pause already sent), the field is put back from
      // scope.state right here: a blanked field reads its value again, a 50 in Rows reads the 32 GE made of
      // it. Either way the field cannot go on showing a number GE does not hold.
      function settleTyping(rawText) {
        var entry = typing;
        if (entry === null) {
          return;
        }
        typing = null;
        cancelPause(entry);
        var value = readNumber(scope.edit[entry.field]);
        if (value === undefined) {
          value = readNumber(rawText);
        }
        if (!sendTyped(entry, value)) {
          scope.edit[entry.field] = echoOf(entry.field);
        }
      }

      // End the record WITHOUT sending: New, Load, the session ending, a moved target, the panel's
      // $destroy. Its number belongs to something that is going away, and the next push writes the field.
      function dropTyping() {
        if (typing === null) {
          return;
        }
        cancelPause(typing);
        typing = null;
      }

      scope.$on('$destroy', dropTyping);

      // ng-keydown on a typed field. Enter commits, and nothing here moves the focus, so the admin can type
      // straight on. Every other key restarts an open record's pause, because ng-change only hears a key
      // that changed the number: 5.0 -> 5.00, or "-" -> "-.", is still typing.
      scope.typingKey = function (field, ev) {
        if (ev.keyCode === 13) {
          scope.commitTyped(field, ev);
          return;
        }
        if (isTyping(field)) {
          armPause(typing);
        }
      };

      // ng-blur, and Enter: settle THIS field's record, with this input's own text at hand.
      scope.commitTyped = function (field, ev) {
        if (!isTyping(field)) {
          return;
        }
        settleTyping(ev && ev.target ? ev.target.value : undefined);
      };

      // The value the GE echo puts into one edit field: the knob's own value, blank for the unpinned width
      // axis ("auto") or a knob the block omits; the preview count; and for the breakpoint field the active
      // segment's start slot, which the admin retypes to add or select another breakpoint. That one is a GE
      // SLOT while the field is a DISPLAY number, so this is one of the two places that seed the field from
      // a slot (the other is breakpointHold's fallback).
      function echoOf(field) {
        if (field === 'previewCount') {
          return scope.state.previewCount;
        }
        if (field === 'breakpointDisplay') {
          return slotToDisplay(scope.state.activeStartSlot);
        }
        var value = (scope.state.knobs || {})[field];
        return (value === undefined || value === null) ? '' : value;
      }

      // Sync the editable number fields from the authoritative state, so the inputs show GE's clamped values
      // (and `columns` shows blank when auto/derived). Two kinds of field are skipped, each only while the
      // admin is working in it -- ADR-0023's two narrow exceptions to "the panel shows the echo":
      //
      //   * a field with a hold open on it: its accumulator is ahead of the throttled echo, so writing an
      //     older value here would visibly yank the number backwards mid-hold. Ends when the button comes up.
      //   * a field with typing open on it. The fields used to commit on blur only, so a push could never
      //     land mid-type; the pause sends mid-type now, and its echo (a clamped value, or rows set and the
      //     columns gone to auto) would rewrite the digits under the cursor. Ends at Enter or blur, which put
      //     GE's value back themselves when they send nothing -- so it restores itself.
      //
      // Every other part of the push still applies: scope.state stays the authority for every other field.
      function syncEditFromState() {
        EDIT_FIELDS.forEach(function (field) {
          if (!isHeld(field) && !isTyping(field)) {
            scope.edit[field] = echoOf(field);
          }
        });
      }

      scope.$on('BeamCompGridData', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.races = asArray(payload && payload.races);
          rebuildRaceOpts();
          // Pre-select the carried race only while no choice has been made, so a later push that still
          // carries the seed never overrides a manual pick.
          if (!scope.form.race && payload && payload.seedRace) {
            scope.form.race = payload.seedRace;
          }
          // The race labels and the anchored race both feed the saved-grid blocks.
          rebuildGridOpts();
        });
      });

      // The map's saved grids as {name, race, isDefault} (ADR-0023 amendment).
      scope.$on('BeamCompGridList', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.grids = asArray(payload && payload.grids);
          rebuildGridOpts();
        });
      });

      scope.$on('BeamCompGridState', function (event, payload) {
        scope.$evalAsync(function () {
          scope.state = payload || scope.state;
          // The breakpoint boundaries are a list, and GE.segment_bounds() returns an EMPTY one whenever
          // no edit session is running -- the case that crosses the bridge as {}. The template reads
          // state.segments.length, which would then be undefined: "Part 1 of " with nothing after it.
          // Normalised here, so the field matches the [] this scope was seeded with.
          scope.state.segments = asArray(scope.state.segments);
          // The plan's three lists, the same way: a one-part grid sends its boundaries as {}.
          scope.state.plan = planOf(scope.state.plan);
          // savedName tracks the active grid's persisted name (gates the default button, marks the
          // overwrite target).
          scope.savedName = scope.state.name || null;
          if (scope.state.active && scope.state.race && !scope.form.race) {
            // Restore the anchor after a panel reopen (fresh scope), without clobbering a choice the admin
            // has already made this open. The anchor decides which grids are "this race's", so re-block.
            scope.form.race = scope.state.race;
            rebuildGridOpts();
          }
          // Restore the overwrite name only when the field is empty (reopen) -- loadGrid/newGrid set it
          // explicitly, and a knob push must not wipe a save-as name the admin is typing. A reopen onto an
          // active but never-saved session leaves the field empty (there is no name to restore) and gets no
          // suggestion either: push_grid_data pushes this state SYNCHRONOUSLY but fetches the grid list
          // over the server, so scope.data.grids is still empty here and any suggestion computed now would
          // be the "race has nothing yet" one -- wrong, and frozen in place, since a suggestion must never
          // overwrite the field once the real list arrives. The admin gets one from the next New grid.
          if (!scope.form.saveName && scope.state.name) {
            scope.form.saveName = scope.state.name;
          }
          // A typed number belongs to the session and the segment it was typed for. The push that ends the
          // session is also the one whose ng-if removes the field, so the record cannot outlive its input.
          if (typing !== null && (!scope.state.active || typing.target !== editTarget())) {
            dropTyping();
          }
          syncEditFromState();
          planAfterPush();
        });
      });

      // Custom-dropdown plumbing (native <select> does not open in the CEF overlay).
      scope.toggle = function (field) {
        scope.open = (scope.open === field) ? null : field;
      };
      // The Race dropdown's head label. The saved-grid list lost its head with the 2026-07-30 reveal
      // amendment (the rows are the only labels now), so the loadName case -- never show that internal key
      // raw -- went with its last caller.
      scope.labelFor = function (field, emptyLabel) {
        var list = scope.opts[field] || [];
        var value = scope.form[field];
        for (var i = 0; i < list.length; i++) {
          if (list[i].v === value) {
            return list[i].label;
          }
        }
        return value || emptyLabel;
      };
      scope.pick = function (field, value) {
        scope.form[field] = value;
        scope.open = null;
        if (field === 'race') {
          // The anchored race splits the saved-grid list into "this race" and the rest.
          rebuildGridOpts();
          // No save-name re-suggestion here on purpose. Re-anchoring does NOT move where a running session
          // saves: grideditor owns the session's race (set by grid_open_new / grid_open_saved) and
          // snapshot() stores under THAT race -- which is why the hint below reads "Editing {{state.race}}".
          // A suggestion recomputed for the newly picked race would therefore describe a race the Save
          // never reaches. The save field instead follows the save target, and is set exactly where that
          // target is decided: newGrid() (a suggestion) and loadGrid() (the loaded grid's own name).
        }
      };
      // Clicking a row in the saved-grid list is the way IN: it loads that grid. The separator between the
      // two blocks is not a row you can click -- it must do nothing at all, not even close the list.
      //
      // This is the one place the panel deliberately diverges from the setup panel's presets, which load on
      // a single click: grid_open_saved CLEARS THE EDITOR FIRST, so while a session is running a mis-click
      // would throw away a hand-placed layout. So with no session the click loads at once (there is nothing
      // to lose and this is the normal way in), and with one running the first click only ARMS that row --
      // it grows a "replace?" chip -- and the second one loads. Arming a row for load disarms any armed
      // delete and vice versa: one armed thing at a time, on one row at a time.
      scope.pickGrid = function (option) {
        if (!option || option.separator) {
          return;
        }
        scope.armedDelete = '';
        if (scope.state.active && scope.armedLoad !== option.v) {
          scope.armedLoad = option.v;
          return;
        }
        scope.armedLoad = '';
        // pick() sets form.loadName (which marks the loaded row) and closes the list; loadGrid() then
        // resolves that key back to its {race, name} and dispatches. Unchanged, both of them.
        scope.pick('loadName', option.v);
        scope.loadGrid();
      };

      // Closing the saved-grid list disarms every row: an armed load or delete left behind would fire on
      // the FIRST click the next time the list opened. The list is closed from three places (toggle, the
      // pick inside pickGrid, and the outside-click handler) and opening the Race dropdown closes it too,
      // so watch the state they all end up in instead of patching each one.
      scope.$watch(function () { return scope.open; }, function (now) {
        if (now !== 'loadName') {
          scope.armedLoad = '';
          scope.armedDelete = '';
        }
      });

      // Close any open dropdown on a click outside it (standard dropdown UX). The document global, not an
      // injected $document -- the same choice the setup panel makes (see the header on DI). A click
      // on this app's own .bc-dd (head or list) is left to toggle()/pick(); anything else closes it.
      function closeOnOutsideClick(ev) {
        if (scope.open === null) { return; }
        var root = element[0];
        var node = ev.target;
        while (node && node !== document) {
          if (node.classList && node.classList.contains('bc-dd') && root.contains(node)) { return; }
          node = node.parentNode;
        }
        scope.$evalAsync(function () { scope.open = null; });
      }
      document.addEventListener('click', closeOnOutsideClick, false);
      scope.$on('$destroy', function () {
        document.removeEventListener('click', closeOnOutsideClick, false);
      });

      // Hover help text by key (ADR-0049), read by bc-grid-tip. The knobs do not come through here --
      // numeric knobs and switches carry their own text on their entry. An unknown key yields '' and the
      // directive then shows nothing at all, which is a far better failure than an empty box on a control.
      //
      // A TIPS entry may be a FUNCTION of the scope instead of a fixed string (ADR-0049 amendment), for
      // help that only makes sense against live state -- the Default button has to say which grid this
      // race starts on today. The directive evaluates its expression inside the hover delay, not at link
      // time, so a function entry is re-read on every hover and can never go stale.
      scope.tip = function (key) {
        var entry = TIPS[key];
        if (typeof entry === 'function') {
          entry = entry(scope);
        }
        return entry || '';
      };

      // Start a fresh grid from the track default for the chosen race. A new grid has no saved name, so
      // clear the overwrite target until the admin saves it, and prefill the save field with a suggestion
      // for the race this session will belong to -- the admin would otherwise retype the same name on
      // every track. The suggestion is computed for scope.form.race because that is exactly the race
      // grid_open_new anchors the new session to (and therefore the race a later Save writes to).
      // Deliberately after the early return: with no race picked, nothing is touched at all.
      // Closing the saved-grid list is part of the action: the button sits INSIDE the .bc-dd wrapper, so the
      // outside-click handler exempts it, and an absolutely positioned list would otherwise hang over the
      // Direction/Layout sections this very click just revealed.
      // A number still being typed belongs to the session this replaces, so it goes unsent (the click that
      // got here has normally blurred and settled it already).
      scope.newGrid = function () {
        if (!scope.form.race) {
          return;
        }
        dropTyping();
        planNewSession();
        scope.open = null;
        scope.savedName = null;
        scope.form.saveName = suggestGridName(scope.data.grids, scope.form.race);
        geLuaArg('grid_open_new', scope.form.race);
      };

      // The {name, race, isDefault} entry behind the selected saved-grid key, or null.
      function selectedGrid() {
        return scope.gridsByKey[scope.form.loadName] || null;
      }

      // Load a saved grid for editing, re-anchored onto the currently selected race (grid params are
      // relative to a start line, so a grid keeps its layout against whatever race is being edited). Load
      // addresses the grid by its OWN race; saving it afterwards writes it to the ANCHORED race, which is
      // how a layout is copied from one track to another. Pre-fill its name so a later Save overwrites it
      // without retyping. Its only caller is pickGrid (the row click) -- there is no separate
      // Load-the-selection button any more (ADR-0023 amendment 2026-07-30). A number still being typed is
      // dropped unsent, as in newGrid.
      scope.loadGrid = function () {
        var grid = selectedGrid();
        if (!grid) {
          return;
        }
        dropTyping();
        planNewSession();
        scope.savedName = grid.name;
        scope.form.saveName = grid.name;
        geLuaArgs('grid_open_saved', grid.race, grid.name, scope.form.race || '');
      };

      // Delete one saved grid from the row it sits on, two-step on the same button (ADR-0023 amendment
      // 2026-07-30): the first click ARMS that row (the button becomes "sure?" in the danger colour), only
      // a second click deletes. Both clicks must stop the event, or the row's own ng-click would load -- or
      // arm for load -- the very grid being deleted. Arming a delete disarms an armed load, and every row
      // disarms when the list closes (see the $watch on scope.open).
      //
      // `key` is the row's gridKey, not a name: a grid belongs to a race and the list also shows OTHER
      // races' grids, so the pair has to be resolved through gridsByKey before addressing the server
      // (ADR-0023 amendment 2026-07-27). The server echoes the updated list, which refreshes the rows and
      // prunes this key everywhere it was held (see rebuildGridOpts) -- hence no hand-clearing here.
      scope.deleteGrid = function (key, ev) {
        if (ev) {
          ev.stopPropagation();
        }
        var grid = scope.gridsByKey[key];
        if (!grid) {
          return;
        }
        scope.armedLoad = '';
        if (scope.armedDelete !== key) {
          scope.armedDelete = key;
          return;
        }
        scope.armedDelete = '';
        geLuaArgs('grid_delete', grid.race, grid.name);
      };

      scope.setDirection = function (direction) {
        geLuaArg('grid_set_direction', direction);
      };

      // The line under Forward/Reverse while the race setup runs this race the other way round (ADR-0037
      // amendment 2026-10-11). GE decides whether there is anything to compare: it sends setupDirection
      // only while the running session edits the race the setup panel's Edit… carried, so an absent field
      // is no line. Nothing is kept from an earlier push (the state handler replaces scope.state whole) and
      // nothing is inferred here -- the same rule as the setup panel's serverDefaults.
      scope.directionNote = function () {
        var carried = scope.state.setupDirection;
        if (!scope.state.active || !carried || carried === scope.state.direction) {
          return '';
        }
        if (carried === 'reverse') {
          return 'The race setup runs this race in reverse.';
        }
        if (carried === 'forward') {
          return 'The race setup runs this race forward.';
        }
        return '';
      };

      // Put the camera back above P1 of the grid being edited (ADR-0063). The camera already jumps on
      // every New and Load by itself; this button is for after the admin has flown somewhere else.
      scope.cameraToGrid = function () {
        geCall('grid_camera_to_grid');
      };

      // Where a knob's hold starts: the current authoritative value (auto/blank starts at 0) -- the GE
      // echo, deliberately NOT scope.edit. A number typed into the field but never committed must not
      // become the base a stepper counts from, which is the source the single click always used too.
      // A number typed and still open DOES become the base, but only through holdFor, which commits it
      // first (the settle Enter runs) and only then seeds from it -- so the rule still holds: a stepper
      // never counts from anything uncommitted.
      function knobHold(knob) {
        var current = scope.state.knobs ? scope.state.knobs[knob.key] : undefined;
        return {
          base: (current === undefined || current === null) ? 0 : Number(current),
          clamp: function (value) { return clampKnob(knob, value); },
          send: function (value) { geSetKnob(knob.key, value); },
        };
      }

      // Stepper: nudge a knob by `delta` (a fine ±0.05 or coarse ±1.0 from the buttons). A tap is one
      // step; holding the button repeats it against the accumulator instead of against the echo.
      scope.stepKnob = function (knob, delta) {
        if (!scope.state.active) {
          return;
        }
        advanceHold(holdFor(knob.key, knobHold, knob), delta);
      };

      // Switch toggle: send the boolean to GE, which echoes it back through BeamCompGridState so the
      // On/Off highlight reflects the authoritative value (not local state).
      scope.setFlag = function (knob, on) {
        if (!scope.state.active) {
          return;
        }
        geSetBool(knob.key, on);
      };

      // The grey placeholder of an empty knob field. A knob only reads empty when the loaded block carries
      // no value for it -- a grid saved before that knob existed (offsetHeight), or a breakpoint seeded
      // from such a block -- and GE then falls back to the layout default (grid.resolved_params). So name
      // that number, "0 (default)", instead of the old bare "-". The value is pushed with the knobs
      // (BeamCompGridState.knobDefaults), so nothing here duplicates a Lua constant; the original "-"
      // remains the fallback for a knob GE carries no default for.
      //
      // The two `auto` knobs never get here: rows and columns are mutually exclusive width pins and the
      // unpinned one is genuinely derived at spawn, so "auto" is the correct word for it (see app.html).
      scope.knobHint = function (knob) {
        var defaults = scope.state.knobDefaults || {};
        var value = defaults[knob.key];
        return (typeof value === 'number' && isFinite(value)) ? value + ' (default)' : '-';
      };

      // How a knob field's typed number goes out: as typed, the way the old blur commit sent it -- GE
      // clamps it and the echo says so (5.123 is not rounded on the way).
      function knobTyping(knob) {
        return {
          clamp: function (value) { return value; },
          send: function (value) { geSetKnob(knob.key, value); },
        };
      }

      // ng-change on a knob field: a keystroke that changed the number (re)starts the pause.
      scope.knobTyped = function (knob) {
        armPause(typingFor(knob.key, knobTyping, knob));
      };

      // Where the preview count's hold starts, and how a tick is clamped (clampPreview). Clamping per tick
      // is what makes a long hold park at 32 instead of running the accumulator to 900 and taking three
      // seconds to come back. The authority, as for knobHold, and for the same reason: a typed count
      // becomes the base only after holdFor has committed it.
      function previewHold() {
        return {
          base: Number(scope.state.previewCount || PREVIEW_MIN),
          clamp: clampPreview,
          send: function (value) { geLuaNum('grid_set_preview', value); },
        };
      }

      scope.stepPreview = function (direction) {
        if (!scope.state.active) {
          return;
        }
        advanceHold(holdFor('previewCount', previewHold), direction);
      };

      // How a typed preview count goes out: clamped like a held tick, so 40 confirmed with Enter lands on
      // 32, and the pause's send and the Enter that follows it compare like with like.
      function previewTyping() {
        return {
          clamp: clampPreview,
          send: function (value) { geLuaNum('grid_set_preview', value); },
        };
      }

      scope.previewTyped = function () {
        armPause(typingFor('previewCount', previewTyping));
      };

      // Breakpoint / segment editing (ADR-0023 amendment). The GE session owns the segment list; the
      // panel only asks it to select/create/remove and reflects the echoed state.

      // Where the breakpoint field's hold starts: the field is local and freely typed, so unlike the knobs
      // it seeds off the field itself -- already a DISPLAY number -- and falls back to the active segment's
      // start slot, which is a GE SLOT and therefore converted (the second of the two places that seed the
      // field from a slot). `send: null` -- the value never reaches GE (the admin presses Add breakpoint
      // for that), so a held button here costs nothing but the repaint.
      function breakpointHold() {
        var base = Number(scope.edit.breakpointDisplay);
        if (!isFinite(base)) {
          base = slotToDisplay(scope.state.activeStartSlot || 0);
        }
        return {
          base: base,
          clamp: function (value) { return value < SLOT_DISPLAY_MIN ? SLOT_DISPLAY_MIN : value; },
          send: null,
        };
      }

      // Nudge the breakpoint field (does not apply -- the admin then presses Add breakpoint). Clamped to
      // the display floor: holding `-` parks at P1, the label of the base segment's slot 0. The clamp
      // also has to hold that floor for a second reason -- the input's own min="1" validator blanks the
      // model on any smaller value, so an unclamped hold would empty the field instead of stopping in it.
      scope.stepBreakpoint = function (delta) {
        advanceHold(holdFor('breakpointDisplay', breakpointHold), delta);
        planDraftChanged('stepped');
      };

      // Select the segment starting at `slot`, or create one there seeded from the covering segment.
      // `slot` is a GE SLOT (0-based) and goes to GE untouched -- the chips pass state.segments[i].startSlot
      // straight through. Anything coming from the display side goes through selectTypedSegment instead.
      scope.selectSegment = function (slot) {
        if (!scope.state.active) {
          return;
        }
        geLuaNum('grid_select_segment', slot);
      };

      // The typed field's own way in. edit.breakpointDisplay is a DISPLAY number, so it is converted here,
      // once, and handed on in GE space. Two entry points rather than one shared function is the whole
      // point: feeding one function from two number spaces is precisely how an off-by-one ships.
      //
      // Add breakpoint and Enter in the field both land here. There is no pause: stopping at "1" on the
      // way to "12" must not create a segment.
      //
      // An unusable field does nothing at all, like an unreadable knob or count above. The guard is not
      // decoration: AngularJS's number parser turns an EMPTY input into `null`, not undefined, and
      // Number(null) is 0 -- so an unguarded conversion would quietly hand GE the slot -1. It is also
      // where "there is no P0" lives in JS rather than only in the input's min attribute; a value below
      // the floor is invalid there too and arrives here as undefined.
      //
      // Either way the number is settled now, so the plan's dashed line goes (planSettleDraft).
      scope.selectTypedSegment = function () {
        planSettleDraft();
        var display = Number(scope.edit.breakpointDisplay);
        if (!isFinite(display) || display < SLOT_DISPLAY_MIN) {
          return;
        }
        scope.selectSegment(displayToSlot(display));
      };

      // A slot's label as the admin reads it, and the panel's only formatter for one: the hint and the
      // breakpoint chips both render a GE slot through this, so they cannot drift apart or away from the
      // preview pillars (init.lua's draw_editor_grid writes the same label).
      scope.slotLabel = function (slot) {
        return 'P' + slotToDisplay(slot);
      };

      // Remove the active breakpoint (merges its slots into the previous segment). GE rejects segment 0.
      scope.removeSegment = function () {
        if (!scope.state.active) {
          return;
        }
        geCall('grid_remove_segment');
      };

      // The hint above the plan: which part the settings below edit, and which positions that is. The
      // admin reads segments as parts. Ranges come from GE's plan (the last PREVIEWED slot of a part), so
      // the last part ends at the preview count, and a part starting past the preview says so.
      scope.partHint = function () {
        var plan = scope.state.plan;
        var index = scope.state.activeSegment;
        var part = plan && plan.parts[index - 1];
        if (!part) {
          return '';
        }
        var head = 'Part ' + index + ' of ' + plan.parts.length;
        var first = scope.slotLabel(part.startSlot);
        if (part.lastSlot === undefined || part.lastSlot === null) {
          return head + ' starts at ' + first + ', which is not in the preview. '
            + 'The settings below change only its positions.';
        }
        if (part.lastSlot === part.startSlot) {
          return head + ': ' + first + '. The settings below change only this position.';
        }
        var range = head + ': ' + first + ' to ' + scope.slotLabel(part.lastSlot) + '.';
        if (plan.parts.length === 1) {
          return range + ' The settings below change every position.';
        }
        return range + ' The settings below change only these positions.';
      };

      // A part's color as GE draws it right now (bright for the edited part), for its chip.
      scope.partSwatch = function (index) {
        var part = scope.state.plan && scope.state.plan.parts[index];
        return part ? cssColor(part.color, 1) : 'transparent';
      };

      // ---- The plan strip (ADR-0023 amendment 2026-10-16) -------------------------------------------
      // Renders GE's plan (scope.state.plan) and nothing else: one dot per preview position, a line where
      // each part begins, a checkered start-line mark at x = 0. Plan meters x (behind the start line) and
      // y (right of travel) map to the strip as x -> right, y -> up, so P1 is on the left and the cars face
      // left, towards the mark -- a true top view, pole-left at the bottom.
      //
      // The strip is a WINDOW onto the field, moved by dragging (bcGridDrag) and by two triggers:
      //   * the edited part changes (editTarget(): race, direction, the part's start): the window jumps to
      //     that part's start, with the part before it in its first quarter, and FOLLOWS that start on
      //     every push from then on (a knob that moves the part moves the window with it);
      //   * the typed breakpoint moves the dashed line: the window centres on it and stops following.
      // A drag stops following too, and a push then never moves the window; only the clamp to the field
      // can, when the field itself got shorter.
      //
      // The dashed line is a DRAFT: the number in Breakpoint at P while it is the admin's own, typed
      // (`ng-change`) or stepped (its ± buttons) and not yet applied. The plan reads that field and never
      // writes it, and nothing of the draft reaches GE before Enter or Add breakpoint.
      scope.plan = emptyPlan();
      var planView = { pan: 0, follow: true, partKey: null, dashedSlot: null, width: 0, dragFrom: 0 };
      var planDraft = null;   // null (the field shows GE's echo), 'typed' or 'stepped'

      function planWidth() {
        return planView.width || PLAN_FALLBACK_WIDTH;
      }

      function planPoseAt(slot) {
        var poses = scope.state.plan ? scope.state.plan.poses : [];
        for (var i = 0; i < poses.length; i++) {
          if (poses[i].slot === slot) {
            return poses[i];
          }
        }
        return null;
      }

      // The part covering a GE slot, from GE's ranges.
      function planPartCovering(slot) {
        var parts = scope.state.plan ? scope.state.plan.parts : [];
        var covering = null;
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].startSlot <= slot) {
            covering = parts[i];
          }
        }
        return covering;
      }

      // The GE slot the dashed line stands in front of, or null. Only for a draft that reads as a number,
      // is not already where a part begins (P1 included: slot 0 is part 1's start) and has a position in
      // the preview to draw against. Floored like GE floors the number it is sent.
      function planDashedSlot() {
        if (planDraft === null || !scope.state.plan) {
          return null;
        }
        var display = readNumber(scope.edit.breakpointDisplay);
        if (display === undefined) {
          return null;
        }
        var slot = displayToSlot(Math.floor(display));
        var parts = scope.state.plan.parts;
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].startSlot === slot) {
            return null;
          }
        }
        return planPoseAt(slot) && planPoseAt(slot - 1) ? slot : null;
      }

      // The dashed line: halfway between the last position that would stay in the earlier part and the
      // first one of the new part, square to that position's facing, as tall as the strip.
      function planDashedLine(slot) {
        var before = planPoseAt(slot - 1);
        var after = planPoseAt(slot);
        var midX = (before.x + after.x) / 2 * PLAN_SCALE;
        var midY = -(before.y + after.y) / 2 * PLAN_SCALE;
        var acrossX = after.fy;
        var acrossY = after.fx;
        return { x: midX, x1: midX - acrossX * PLAN_HEIGHT, y1: midY - acrossY * PLAN_HEIGHT,
          x2: midX + acrossX * PLAN_HEIGHT, y2: midY + acrossY * PLAN_HEIGHT };
      }

      // Rebuild what the strip draws from GE's plan and the draft. The window position is placePlan's.
      function buildPlan() {
        var source = scope.state.plan;
        var built = emptyPlan();
        if (!source || !source.poses.length) {
          scope.plan = built;
          return;
        }
        var dashedSlot = planDashedSlot();
        var draftPart = dashedSlot === null ? null : planPartCovering(dashedSlot);
        var minX = 0;
        var maxX = 0;
        var minY = Infinity;
        var maxY = -Infinity;
        built.dots = source.poses.map(function (pose) {
          var part = source.parts[pose.part - 1];
          var color = part ? part.color : { r: 1, g: 1, b: 1, a: 1 };
          var isDraft = draftPart !== null && pose.slot >= dashedSlot && pose.slot <= draftPart.lastSlot;
          var isEdited = pose.part === scope.state.activeSegment;
          minX = Math.min(minX, pose.x);
          maxX = Math.max(maxX, pose.x);
          minY = Math.min(minY, pose.y);
          maxY = Math.max(maxY, pose.y);
          return {
            slot: pose.slot,
            start: part ? part.startSlot : 0,
            label: scope.slotLabel(pose.slot),
            cx: pose.x * PLAN_SCALE,
            cy: -pose.y * PLAN_SCALE,
            r: PLAN_DOT_RADIUS,
            nx: pose.fx * (PLAN_DOT_RADIUS + PLAN_NOSE),
            ny: -pose.fy * (PLAN_DOT_RADIUS + PLAN_NOSE),
            fill: isDraft ? 'rgba(20,22,26,0.6)' : cssColor(color),
            nose: cssColor(color),
            stroke: isDraft ? cssColor(color, 1) : (isEdited ? '#ffffff' : 'none'),
            dash: isDraft ? '3 2' : 'none',
            text: isDraft ? cssColor(color, 1) : labelColorOn(color),
          };
        });
        built.lines = source.boundaries.map(function (boundary) {
          minX = Math.min(minX, boundary.a.x, boundary.b.x);
          maxX = Math.max(maxX, boundary.a.x, boundary.b.x);
          return { part: boundary.part, x1: boundary.a.x * PLAN_SCALE, y1: -boundary.a.y * PLAN_SCALE,
            x2: boundary.b.x * PLAN_SCALE, y2: -boundary.b.y * PLAN_SCALE, color: cssColor(boundary.color) };
        });
        built.dashed = dashedSlot === null ? null : planDashedLine(dashedSlot);
        built.left = minX * PLAN_SCALE - PLAN_PAD;
        built.right = maxX * PLAN_SCALE + PLAN_PAD;
        built.middle = (minY + maxY) / 2;
        built.fits = (maxY - minY) * PLAN_SCALE + 2 * PLAN_DOT_RADIUS <= PLAN_HEIGHT - 8;
        scope.plan = built;
      }

      function clampPan(pan) {
        var max = Math.max(scope.plan.left, scope.plan.right - planWidth());
        return Math.min(Math.max(pan, scope.plan.left), max);
      }

      // The lateral middle the strip is centred on: the whole field's when it fits the strip's height,
      // else the middle of the positions inside the window, so a strong bend stays in view as it is dragged.
      function planMiddle() {
        if (scope.plan.fits) {
          return scope.plan.middle;
        }
        var from = planView.pan;
        var to = planView.pan + planWidth();
        var minY = Infinity;
        var maxY = -Infinity;
        scope.plan.dots.forEach(function (dot) {
          if (dot.cx >= from && dot.cx <= to) {
            minY = Math.min(minY, -dot.cy / PLAN_SCALE);
            maxY = Math.max(maxY, -dot.cy / PLAN_SCALE);
          }
        });
        return minY === Infinity ? scope.plan.middle : (minY + maxY) / 2;
      }

      // Put the window where planView.pan says, clamped to the field.
      function placePlan() {
        planView.pan = clampPan(planView.pan);
        scope.plan.tx = -planView.pan;
        scope.plan.ty = PLAN_HEIGHT / 2 + planMiddle() * PLAN_SCALE;
      }

      // Where the window shows the edited part's start: the start line for part 1, otherwise the line
      // where the part begins a quarter of the way in. A part past the preview has no line: the end of the
      // field, where it would begin.
      function partStartPan() {
        var index = scope.state.activeSegment;
        if (index <= 1) {
          return scope.plan.left;
        }
        for (var i = 0; i < scope.plan.lines.length; i++) {
          var line = scope.plan.lines[i];
          if (line.part === index) {
            return (line.x1 + line.x2) / 2 - planWidth() * PLAN_LEAD;
          }
        }
        return scope.plan.right - planWidth();
      }

      // Every push: the echo settles a draft (it has just rewritten the field), a changed edit target sends
      // the window back to following, and a following window goes to the edited part's start.
      function planAfterPush() {
        if (!isHeld('breakpointDisplay')) {
          planDraft = null;
          planView.dashedSlot = null;
        }
        if (!scope.state.active) {
          planView.partKey = null;
        }
        var key = editTarget();
        if (scope.state.active && key !== planView.partKey) {
          planView.partKey = key;
          planView.follow = true;
        }
        buildPlan();
        if (planView.follow) {
          planView.pan = partStartPan();
        }
        placePlan();
      }

      // New and Load start a field of their own, even on the same race, direction and part.
      function planNewSession() {
        planView.partKey = null;
        planDraft = null;
        planView.dashedSlot = null;
      }

      // The draft changed: redraw, and when the dashed line moved to a new place, centre the window on it.
      function planDraftChanged(source) {
        planDraft = source;
        buildPlan();
        var slot = planDashedSlot();
        if (slot !== null && slot !== planView.dashedSlot) {
          planView.pan = scope.plan.dashed.x - planWidth() / 2;
          planView.follow = false;
        }
        planView.dashedSlot = slot;
        placePlan();
      }

      // Enter / Add breakpoint: the number is settled, so the dashed line goes. The window stays.
      function planSettleDraft() {
        planDraft = null;
        planView.dashedSlot = null;
        buildPlan();
        placePlan();
      }

      // ng-change on Breakpoint at P. It only draws: there is no pause commit on this field.
      scope.planBreakpointTyped = function () {
        planDraftChanged('typed');
      };

      // ng-blur on Breakpoint at P settles a TYPED draft. A stepped one stays: a ± press blurs the field
      // AFTER its mousedown has stepped, and the step is exactly what the admin is looking at.
      scope.planBreakpointBlurred = function () {
        if (planDraft === 'typed') {
          planSettleDraft();
        }
      };

      // bcGridDrag: a press remembers where the window was, a drag moves it from there.
      scope.planPress = function () {
        planView.dragFrom = planView.pan;
      };

      scope.planDrag = function (dx) {
        planView.follow = false;
        planView.pan = planView.dragFrom - dx;
        placePlan();
      };

      // A click on a dot selects that dot's part, exactly like its chip: the part's start is a GE slot and
      // goes through selectSegment untouched. A click anywhere else in the strip does nothing.
      scope.planClick = function (start) {
        var slot = Number(start);
        if (start === null || start === undefined || start === '' || !isFinite(slot)) {
          return;
        }
        scope.selectSegment(slot);
      };

      // bcGridDrag reports the strip's real width once it is laid out (and when it changes).
      scope.planMeasure = function (width) {
        if (!(width > 0) || width === planView.width) {
          return;
        }
        planView.width = width;
        if (planView.follow) {
          planView.pan = partStartPan();
        }
        placePlan();
      };

      // Reveal (or cancel) the Save name row. It deliberately does NOT touch form.saveName -- the opposite
      // of the setup panel's preset row, which prefills at reveal time. Here the field is already seeded
      // where the save target is decided: newGrid() puts a suggestion in it and loadGrid() the loaded grid's
      // own name, and savedName plus the "Overwrites '<name>'" hint hang off it. Revealing shows what is
      // already there; overwriting it on every reveal would destroy a name the admin typed and collapsed.
      scope.toggleSave = function () {
        scope.saveOpen = !scope.saveOpen;
      };

      // Reveal (or hide) the height options. Pure panel state: nothing is sent to GE and nothing is
      // read back, so collapsing a section can never change a grid or lose an entered value.
      scope.toggleHeight = function () {
        scope.heightOpen = !scope.heightOpen;
      };

      // Non-empty AND no whitespace. A grid name has to survive `/race grid=<name>`, whose parser splits on
      // whitespace, plus grid_save's own guard server-side -- a spaced name is unsaveable AND unaddressable.
      // This now gates the revealed row's confirm (Save grid itself only reveals), and saveGrid re-checks it
      // as the backstop that makes Enter on an invalid name inert.
      scope.canSave = function () {
        return scope.state.active && scope.form.saveName && !/\s/.test(scope.form.saveName);
      };

      // Write the grid, then collapse the row -- but KEEP the name. It is the overwrite target from here on:
      // savedName mirrors it (gating the default button and the overwrite hint), and a second save of the
      // same session must not have to retype it. Optimistic like every other action in this panel: grid_save
      // is fire-and-forget and the feedback already exists -- the server chats the save and, since the
      // 2026-09-25 amendment, echoes the updated list back to both panels.
      scope.saveGrid = function () {
        if (!scope.canSave()) {
          return;
        }
        geLuaArg('grid_save', scope.form.saveName);
        scope.savedName = scope.form.saveName;
        scope.saveOpen = false;
      };

      // Make the active grid its race's default (ADR-0023 amendment): a grid belongs to the race it was
      // saved against, so there is no race to pick -- the target is always state.race.
      scope.makeDefault = function () {
        if (!scope.savedName || !scope.state.race) {
          return;
        }
        geLuaArgs('grid_assign', scope.state.race, scope.savedName);
      };

      // Close ends the edit session GE-side (grid + preview cleared) and hides the panel; a reopen starts
      // empty at "pick a race". A fresh scope on reopen resets savedName/saveName, so no UI reset here.
      scope.close = function () {
        geCall('close_grid_editor');
      };

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (data arrives back via the $on handlers above). The only pull the
      // panel does: GE pushes on open, and the server echoes the updated list after a save, an assign and
      // a delete alike (ADR-0023 amendment 2026-09-25), which together cover every timing.
      //
      // There is deliberately no manual refresh control, and that is a decision, not a consequence of the
      // line above: a button you have to press is this bug again in small, so the lists are kept correct
      // instead of being made refreshable.
      geCall('request_grid_data');
    },
  };
}]);

// Long dropdown-label fit: shrink-to-fit, then a calm marquee. Attribute directive placed (via the class
// -> attr in app.html) on every .bc-dd-head (the closed selected value) and .bc-dd-opt (each open option),
// which today clip long labels with an ellipsis. It wraps the label in an overflow-clipping box that
// RESPECTS the head's right chevron padding (so a scrolling label never slides under the ::after chevron),
// then, when the label is wider than its cell, first shrinks the font toward a floor so "only a little too
// long" names fit whole, and -- only if it STILL overflows -- runs a slow left/right CSS marquee. Pure CEF,
// no external assets. Measures once on link (after paint) and again whenever the label text changes, so an
// idle dropdown costs nothing.
//
// The name is app-unique on purpose: BeamCompSetup + BeamCompGridEditor share the 'beamng.apps' Angular
// module, so a shared directive name would double-fire (and could reach other apps' markup). BeamCompSetup
// carries the same logic under bcSetupFit; the two apps share no code by design (kept in ES5 to match the
// surrounding CEF/AngularJS file).
angular.module('beamng.apps').directive('bcGridFit', [function () {
  var FLOOR_PX = 10.5;   // shrink floor (from the 13px base, ~19% smaller); past this we scroll instead
  var SPEED = 32;        // marquee pace, px/s -- calm; the duration scales with the hidden distance
  var MIN_DUR = 3;       // s -- keep a short overflow from scrolling twitchy-fast
  var END_GAP = 6;       // px of trailing room so the last glyph is not flush at the scrolled end

  return {
    restrict: 'A',
    link: function (scope, element) {
      // Wrap the label: <cell> -> <cell><span.bc-fit-clip><span.bc-fit-text>{{label}}</span></span>.
      // Moving the interpolated text node(s) into .bc-fit-text keeps the {{}} binding live -- the
      // interpolation watcher updates the node by reference regardless of its new parent (verified with a
      // jsdom + AngularJS harness). .bc-fit-clip fills the cell content box and hides overflow; the
      // inline-block .bc-fit-text is what we measure, shrink and translate.
      var cell = element[0];
      var text = document.createElement('span');
      text.className = 'bc-fit-text';
      while (cell.firstChild) {
        text.appendChild(cell.firstChild);
      }
      var clip = document.createElement('span');
      clip.className = 'bc-fit-clip';
      clip.appendChild(text);
      cell.appendChild(clip);

      function measure() {
        // Reset to the natural size so every re-measure starts from a clean slate.
        text.classList.remove('bc-fit-scroll');
        text.style.fontSize = '';
        text.style.letterSpacing = '';
        text.style.removeProperty('--bc-fit-shift');
        text.style.removeProperty('--bc-fit-dur');
        var avail = clip.clientWidth;
        if (!avail) {
          return;                              // not laid out yet
        }
        var full = text.scrollWidth;
        if (full <= avail + 1) {
          return;                              // fits as-is
        }
        // Shrink stage: scale the font toward fitting, clamped to the floor, with a hair of tracking.
        var base = parseFloat(window.getComputedStyle(text).fontSize) || 13;
        var target = Math.max(FLOOR_PX, base * avail / full);
        if (target < base - 0.1) {
          text.style.fontSize = target.toFixed(2) + 'px';
          text.style.letterSpacing = '-0.2px';
          full = text.scrollWidth;
        }
        // Marquee stage: still wider than the cell after the floor -> scroll it.
        if (full > avail + 1) {
          var shift = Math.round(full - avail + END_GAP);
          text.style.setProperty('--bc-fit-shift', '-' + shift + 'px');
          text.style.setProperty('--bc-fit-dur', Math.max(MIN_DUR, shift / SPEED).toFixed(2) + 's');
          text.classList.add('bc-fit-scroll');
        }
      }

      // Measure after paint (the label is interpolated post-link) and again on any label change. rAF
      // coalesces bursts; the observer fires only on a real text change, so idle dropdowns cost nothing.
      var pending = null;
      function schedule() {
        if (pending !== null) {
          return;
        }
        if (window.requestAnimationFrame) {
          pending = window.requestAnimationFrame(function () { pending = null; measure(); });
        } else {
          pending = window.setTimeout(function () { pending = null; measure(); }, 16);
        }
      }
      var observer = null;
      if (typeof MutationObserver !== 'undefined') {
        observer = new MutationObserver(schedule);
        observer.observe(text, { childList: true, characterData: true, subtree: true });
      }
      schedule();
      scope.$on('$destroy', function () {
        if (observer) {
          observer.disconnect();
        }
        if (pending !== null) {
          if (window.cancelAnimationFrame) {
            window.cancelAnimationFrame(pending);
          } else {
            window.clearTimeout(pending);
          }
        }
      });
    },
  };
}]);

// Hold-to-repeat for the panel's ± stepper buttons: the gesture and nothing else. This directive owns
// the timing and the teardown and knows nothing about knobs, clamps or GE -- the accumulator that makes
// a repeat actually climb lives in the panel above (see holdFor / advanceHold / scope.endHold).
//
//   bc-grid-hold="stepKnob(k, -0.05)"    the per-press action, re-evaluated on every repeat tick
//   bc-grid-hold-end="endHold()"         run exactly once when the gesture ends
//
// A TAP IS EXACTLY ONE STEP: the press itself steps, and the repeat only starts HOLD_DELAY later. Which
// is why the buttons carry no ng-click any more -- one owner for the whole gesture, so the classic
// double step (ng-click fires AND the hold's first tick fires) cannot happen here by construction.
//
// The name is app-unique for the same reason bcGridFit's is (see its header): BeamCompSetup and
// BeamCompGridEditor share the 'beamng.apps' module, so a generically named attribute directive would
// also claim markup in the other panel.
//
// $parse and $timeout are INJECTED, unlike bngApi -- not an inconsistency with this file's header. That
// rule is about bngApi specifically, a BeamNG-registered service whose absence would take the whole
// late-loaded directive down. $parse and $timeout are AngularJS core and cannot be missing; both sibling
// panels inject core services exactly like this (BeamCompHud/app.js, BeamCompSetup/app.js).
angular.module('beamng.apps').directive('bcGridHold', ['$parse', '$timeout', function ($parse, $timeout) {
  var HOLD_DELAY = 400;   // ms the button must stay down before the repeat starts (a tap stays 1 step)
  var RAMP_MS = 2000;     // ms over which the repeat accelerates from RATE_MIN to RATE_MAX
  var RATE_MIN = 6;       // steps/s the moment the repeat starts
  var RATE_MAX = 25;      // steps/s once the ramp is done

  return {
    restrict: 'A',
    link: function (scope, element, attrs) {
      // Parsed once, not $eval'd per tick -- this runs up to RATE_MAX times a second.
      var step = $parse(attrs.bcGridHold);
      var endGesture = $parse(attrs.bcGridHoldEnd);
      var timer = null;
      var repeatStart = 0;
      // Is THIS button the one currently held? Not defensive noise -- see release().
      var isHolding = false;

      // The accelerating schedule. A rescheduling $timeout, not a fixed $interval: the delay is
      // recomputed from how long the repeat has been running, so the rate ramps instead of stepping.
      function nextDelay() {
        var ramp = Math.min(1, (Date.now() - repeatStart) / RAMP_MS);
        return 1000 / (RATE_MIN + (RATE_MAX - RATE_MIN) * ramp);
      }

      // Default invokeApply, deliberately NOT the sibling panels' invokeApply:false. Theirs is right
      // because their timer touches no scope state; every tick here writes the bound number field, and
      // repainting that number at the full repeat rate is the entire point of the feature.
      function tick() {
        step(scope);
        timer = $timeout(tick, nextDelay());
      }

      // A native listener is not wrapped the way ng-click wraps a click, so the model write has to be
      // applied by hand. The phase check is for a blur arriving from INSIDE a digest (anything that
      // moves focus while Angular is running): an unguarded $apply would throw there and, in the CEF
      // overlay, take the whole panel down.
      function applyHandler(fn) {
        if (scope.$root && scope.$root.$$phase) {
          fn();
        } else {
          scope.$apply(fn);
        }
      }

      function stopTimer() {
        if (timer !== null) {
          $timeout.cancel(timer);
          timer = null;
        }
      }

      // End the gesture. Idempotent, and a no-op unless THIS button is the one holding. That guard is
      // load-bearing: pressing another stepper blurs this one as part of that press's own default
      // action, so an unguarded blur handler would close the hold the new press had just opened. The
      // symptom is subtle rather than obvious -- the very next repeat tick reopens the accumulator, so
      // the number still climbs -- but it reopens it from the STALE echo, which costs one step and makes
      // GE receive the same value twice.
      function release() {
        if (!isHolding) {
          return;
        }
        isHolding = false;
        stopTimer();
        document.removeEventListener('mouseup', onDocumentUp, true);
        endGesture(scope);
      }

      // Release on a mouseup ANYWHERE: one that lands outside the button would otherwise leave the
      // repeat running forever. The listener exists only while a hold is open, so an idle panel carries
      // no document listener at all -- and one at a time, not one per rendered stepper.
      function onDocumentUp() {
        applyHandler(release);
      }

      function onMouseDown(ev) {
        if (ev.button !== 0 || isHolding) {
          return;                        // a right-click has no left mouseup to ever end the repeat
        }
        isHolding = true;
        repeatStart = Date.now() + HOLD_DELAY;
        document.addEventListener('mouseup', onDocumentUp, true);
        applyHandler(function () {
          step(scope);                   // the press itself is the first step
        });
        timer = $timeout(tick, HOLD_DELAY);
      }

      function onRelease() {
        applyHandler(release);
      }

      // Keyboard activation, restoring exactly what ng-click gave these buttons before the gesture took
      // them over: Space or Enter on a focused stepper steps ONCE. Without this, dropping ng-click would
      // have silently removed keyboard use of the panel altogether.
      //
      // Deliberately not a repeat -- the OS key-autorepeat (ev.repeat) is ignored, matching the brief's
      // mouse-only scope. The hold is closed in the same breath, because a step that opens an
      // accumulator nobody ever closes would leave that field frozen against the GE echo for good.
      // A mouse click cannot reach here (it produces no keydown), so this cannot double-step.
      // keyCode, not ev.key: the panel already reads keyCode for its Enter handling (app.html).
      function onKeyDown(ev) {
        if (isHolding || ev.repeat || (ev.keyCode !== 13 && ev.keyCode !== 32)) {
          return;
        }
        applyHandler(function () {
          step(scope);
          endGesture(scope);
        });
      }

      element.on('mousedown', onMouseDown);
      element.on('mouseleave', onRelease);
      element.on('blur', onRelease);
      element.on('keydown', onKeyDown);

      // $destroy is already inside a digest, so release() runs directly rather than through
      // applyHandler. jqLite drops this element's own listeners with it; the timer and the document
      // listener are ours to clear, and the final GE send still goes out through endGesture.
      scope.$on('$destroy', function () {
        release();
      });
    },
  };
}]);

// Drag-to-pan for the plan strip (ADR-0023 amendment 2026-10-16): the gesture and nothing else, the way
// bcGridHold is the hold and nothing else. The panel above owns the window position and what a click means.
//
//   bc-grid-drag-start="planPress()"        a left press on the strip
//   bc-grid-drag="planDrag($dx)"            every move once the press has moved past CLICK_SLOP; $dx is
//                                           the horizontal distance from the press, in px
//   bc-grid-drag-click="planClick($start)"  a release that never got past CLICK_SLOP; $start is the
//                                           data-start of the dot under the press (null off the dots)
//   bc-grid-drag-width="planMeasure($width)" the strip's laid-out width, after link and on every resize
//
// The press is preventDefault-ed: the strip must neither take the focus from a field being typed in (its
// draft is what the admin is looking at) nor start a text selection across the SVG labels.
//
// Every release path ends the drag, the set bcGridHold owns: mouseup anywhere, the pointer leaving the
// strip, the window losing focus, and $destroy. Only the mouseup can be a click. The document and window
// listeners exist only while a press is open. App-unique name for the reason bcGridFit's is.
angular.module('beamng.apps').directive('bcGridDrag', ['$parse', '$timeout', function ($parse, $timeout) {
  var CLICK_SLOP = 4;   // px a press may move and still count as a click

  return {
    restrict: 'A',
    link: function (scope, element, attrs) {
      var onStart = $parse(attrs.bcGridDragStart);
      var onDrag = $parse(attrs.bcGridDrag);
      var onClick = $parse(attrs.bcGridDragClick);
      var onWidth = $parse(attrs.bcGridDragWidth);
      var press = null;   // {x, y, moved, start} while the button is down
      var resizeObserver = null;

      // The same phase check as bcGridHold's: a blur can arrive from inside a digest.
      function applyHandler(fn) {
        if (scope.$root && scope.$root.$$phase) {
          fn();
        } else {
          scope.$apply(fn);
        }
      }

      // The data-start of the dot the press landed on, or null.
      function startUnder(node) {
        while (node && node !== element[0]) {
          if (node.getAttribute && node.getAttribute('data-start') !== null) {
            return node.getAttribute('data-start');
          }
          node = node.parentNode;
        }
        return null;
      }

      function reportWidth() {
        var width = element[0].getBoundingClientRect().width;
        if (width > 0) {
          applyHandler(function () {
            onWidth(scope, { $width: width });
          });
        }
      }

      function stopListening() {
        document.removeEventListener('mousemove', onMove, true);
        document.removeEventListener('mouseup', onUp, true);
        window.removeEventListener('blur', onCancel, false);
      }

      // End the press. Idempotent; a click only when the release is a mouseup and the press never moved.
      function release(isMouseUp) {
        if (press === null) {
          return;
        }
        var ended = press;
        press = null;
        stopListening();
        if (isMouseUp && !ended.moved) {
          onClick(scope, { $start: ended.start });
        }
      }

      function onMove(ev) {
        if (press === null) {
          return;
        }
        var dx = ev.clientX - press.x;
        var dy = ev.clientY - press.y;
        if (!press.moved && Math.sqrt(dx * dx + dy * dy) <= CLICK_SLOP) {
          return;
        }
        press.moved = true;
        applyHandler(function () {
          onDrag(scope, { $dx: dx });
        });
      }

      function onUp() {
        applyHandler(function () {
          release(true);
        });
      }

      function onCancel() {
        applyHandler(function () {
          release(false);
        });
      }

      function onDown(ev) {
        if (ev.button !== 0 || press !== null) {
          return;
        }
        ev.preventDefault();
        press = { x: ev.clientX, y: ev.clientY, moved: false, start: startUnder(ev.target) };
        document.addEventListener('mousemove', onMove, true);
        document.addEventListener('mouseup', onUp, true);
        window.addEventListener('blur', onCancel, false);
        reportWidth();
        applyHandler(function () {
          onStart(scope);
        });
      }

      element.on('mousedown', onDown);
      element.on('mouseleave', onCancel);

      // After the first layout, and whenever the panel is resized. invokeApply false: reportWidth applies.
      var firstLayout = $timeout(reportWidth, 0, false);
      if (typeof ResizeObserver !== 'undefined') {
        resizeObserver = new ResizeObserver(reportWidth);
        resizeObserver.observe(element[0]);
      }

      // Already inside a digest, so release runs directly; jqLite drops the element's own listeners.
      scope.$on('$destroy', function () {
        release(false);
        $timeout.cancel(firstLayout);
        if (resizeObserver) {
          resizeObserver.disconnect();
        }
      });
    },
  };
}]);

// Hover help: a delayed, in-DOM tooltip for one control (ADR-0049).
//
//   bc-grid-tip="tip('close')"    an Angular expression that yields the help text
//   bc-grid-tip="k.tip"           a knob carries its own, straight off its LAYOUT_/HEIGHT_/BOOL_KNOBS entry
//
// NATIVE title= IS DEAD IN BEAMNG. The UI renders in an off-screen CEF and native tooltips are painted by
// the browser chrome, which an off-screen renderer does not have -- the same reason native <select> does
// not open here. This panel and the setup panel together carried 33 title= attributes with careful copy;
// not one was ever visible to a player. Do not reintroduce them: their existence proved nothing.
//
// The attribute is an EXPRESSION, parsed once and evaluated only on hover, so no watcher is created and an
// idle panel costs nothing (the bcGridFit cost model). Static copy lives in the TIPS table at the top of
// this file; the eight layout knobs keep their text on the knob object beside key/label/min, so a knob and
// its explanation move together and the ng-repeat renders one text rather than one per row.
//
// The name is app-unique for the reason bcGridFit's and bcGridHold's are (see their headers): the two
// panels share the 'beamng.apps' module, so a generically named attribute directive would also claim the
// other panel's markup -- and being registered twice on one module, Angular would apply BOTH definitions
// to every match. BeamCompSetup carries the same logic under bcSetupTip; the two apps share no code by
// design (kept in ES5 to match the surrounding CEF/AngularJS file).
angular.module('beamng.apps').directive('bcGridTip', ['$parse', '$timeout', function ($parse, $timeout) {
  var SHOW_DELAY = 1200;   // ms of DELIBERATE rest before help appears; crossing the panel shows nothing
  var GAP = 6;             // px between the control and its tooltip
  var EDGE_PAD = 8;        // px of clearance the tooltip keeps from the panel edge
  var ROOT_CLASS = 'bc-grid';
  // Shared with the setup panel: both apps run at the same local:// origin, so ONE key governs both
  // panels and the setup gear menu's switch is the only writer. Naming follows the engine's own UI apps
  // (ui/modules/apps/SimpleTrip/app.js, IndicatedAirspeed/app.js): 'apps:<appName>.<pref>'.
  var STORAGE_KEY = 'apps:beamComp.tooltips';

  // The tooltip currently on screen ({root, el, anchor}), or null. Shared across every instance of this
  // directive, which is what makes "only one at a time" true by construction rather than by bookkeeping:
  // every show hides whatever was up, so moving to a neighbouring control restarts the delay cleanly.
  var visible = null;

  // Read at SHOW time, deliberately not cached at link time: the switch lives in the OTHER panel, so a
  // toggle there has to reach this one, and reading per hover is what achieves that with no message
  // channel. Guarded and defaulting to ON -- if storage is unavailable, help is the safe way to fail.
  function tooltipsEnabled() {
    try {
      return window.localStorage.getItem(STORAGE_KEY) !== '0';
    } catch (e) {
      return true;
    }
  }

  function panelRootOf(node) {
    while (node && node !== document) {
      if (node.classList && node.classList.contains(ROOT_CLASS)) {
        return node;
      }
      node = node.parentNode;
    }
    return null;
  }

  // The panel's single reused tooltip box, created on first use and parked on the root node. It is a
  // CHILD of the root, so it dies with the panel and needs no teardown of its own.
  function tipBoxOf(root) {
    if (!root.bcTipBox) {
      var box = document.createElement('div');
      box.className = 'bc-tip';
      root.appendChild(box);
      root.bcTipBox = box;
    }
    return root.bcTipBox;
  }

  function hideTip() {
    if (!visible) {
      return;
    }
    visible.el.style.display = 'none';
    document.removeEventListener('scroll', hideTip, true);
    visible = null;
  }

  // Put the box under the control, left edges aligned, then keep it INSIDE the panel: flip above when it
  // would cross the bottom edge, shift left when it would cross the right one, and clamp so it can never
  // start off the left edge either. This is functional, not cosmetic -- .bc-grid clips with
  // overflow: hidden, so an unclamped tooltip is not merely ugly, it is cut off and unreadable.
  function place(root, box, anchor) {
    var rootRect = root.getBoundingClientRect();
    var anchorRect = anchor.getBoundingClientRect();
    var width = box.offsetWidth;
    var height = box.offsetHeight;

    var left = anchorRect.left - rootRect.left;
    var maxLeft = root.clientWidth - width - EDGE_PAD;
    if (left > maxLeft) {
      left = maxLeft;
    }
    if (left < EDGE_PAD) {
      left = EDGE_PAD;
    }

    var top = anchorRect.bottom - rootRect.top + GAP;
    if (top + height + EDGE_PAD > root.clientHeight) {
      var above = anchorRect.top - rootRect.top - height - GAP;
      // Above only when it genuinely fits there; a tooltip taller than the space on both sides parks at
      // the bottom edge instead of hanging off the top.
      top = above >= EDGE_PAD ? above : Math.max(EDGE_PAD, root.clientHeight - height - EDGE_PAD);
    }

    box.style.left = Math.round(left) + 'px';
    box.style.top = Math.round(top) + 'px';
  }

  function showTip(anchor, text) {
    var root = panelRootOf(anchor);
    if (!root) {
      return;
    }
    hideTip();
    var box = tipBoxOf(root);
    // textContent, never innerHTML: the copy is plain prose and must stay unable to inject markup.
    box.textContent = text;
    // Lay it out invisibly first -- the box has to have a size before it can be measured, and its
    // measured size is exactly what the flip decision needs.
    box.style.visibility = 'hidden';
    box.style.display = 'block';
    place(root, box, anchor);
    box.style.visibility = 'visible';
    visible = { root: root, el: box, anchor: anchor };
    // The panel body scrolls (.bc-scroll) while the box is anchored to the non-scrolling root, so a
    // scroll would leave the tooltip pointing at nothing. Capture phase: the scroll fires on that inner
    // element and does not bubble to document.
    document.addEventListener('scroll', hideTip, true);
  }

  return {
    restrict: 'A',
    link: function (scope, element, attrs) {
      var textOf = $parse(attrs.bcGridTip);
      var timer = null;

      function cancel() {
        if (timer !== null) {
          $timeout.cancel(timer);
          timer = null;
        }
      }

      function dismiss() {
        cancel();
        hideTip();
      }

      function arm() {
        cancel();
        // invokeApply false: showing the box is a pure DOM side effect that touches no scope state, so it
        // must not kick off a digest on every hover.
        timer = $timeout(function () {
          timer = null;
          if (!tooltipsEnabled()) {
            return;
          }
          var text = textOf(scope);
          if (text) {
            showTip(element[0], String(text));
          }
        }, SHOW_DELAY, false);
      }

      // A DISABLED button still fires these (verified in Chrome: only click is suppressed on a disabled
      // control), which is what lets a greyed-out New grid / Remove explain why it is locked -- the case
      // where help matters most.
      element.on('mouseenter', arm);
      element.on('mouseleave', dismiss);
      element.on('mousedown', dismiss);
      element.on('click', dismiss);

      // jqLite drops this element's own listeners with it; the pending timer is ours to clear. The
      // tooltip is only taken down if THIS element is the one it describes -- the panel churns ng-if
      // sections constantly, and an unrelated one disappearing must not dismiss help someone is reading.
      scope.$on('$destroy', function () {
        cancel();
        if (visible && visible.anchor === element[0]) {
          hideTip();
        }
      });
    },
  };
}]);
