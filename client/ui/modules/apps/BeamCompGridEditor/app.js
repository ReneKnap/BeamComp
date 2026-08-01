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
// late-loaded directive down) and typeof-guarded so a miss is inert. Dropdowns are custom (button + div
// list, ng-click): native <select> does not open in the BeamNG CEF overlay.
angular.module('beamng.apps')
.directive('beamCompGridEditor', [function () {
  // The eight NUMERIC tunable knobs (ADR-0023) in display order. Each continuous knob has a fine (0.05)
  // and a coarse (1.0) stepper pair; integer knobs (rows/columns) step by 1 only. rows and columns are
  // mutually exclusive width pins: pinning one drops the other (GE clears it), which then shows blank
  // ("auto") and is derived from the field at spawn. Both carry `auto: true` so whichever is unpinned
  // reads "auto". The boolean `mirror` param is not in this list -- it renders as its own On/Off toggle
  // (the first Layout row, see app.html + scope.setMirror), not a numeric stepper. offsetHeight is the
  // segment's POST-grounding lift: GE adds it after the surface snap at spawn and in the preview, so
  // +1 hovers the cars exactly 1 m above the ground; per segment, it does not chain into later
  // segments (blank on an older saved grid, which GE treats as 0). The internal split height anchor
  // (anchorHeight, auto-seeded on breakpoint creation) is deliberately NOT a knob.
  var KNOBS = [
    { key: 'offsetForward', label: 'Offset forward (m)' },
    { key: 'offsetLateral', label: 'Offset lateral (m)' },
    { key: 'headingDeg', label: 'Heading (deg)' },
    { key: 'rowGap', label: 'Row gap (m)' },
    { key: 'colGap', label: 'Col gap (m)' },
    { key: 'rows', label: 'Rows', integer: true, auto: true },
    { key: 'columns', label: 'Columns', integer: true, auto: true },
    { key: 'offsetHeight', label: 'Height lift (m)' },
  ];

  var PREVIEW_MIN = 1;
  var PREVIEW_MAX = 32;

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

  // Set the boolean mirror knob: grid_set('mirror', <bool>). Sent as a Lua boolean literal (no quoting,
  // no Number coercion) so grideditor stores a genuine true/false, matching grid.lua's boolean contract.
  function geSetMirror(on) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    bngApi.engineLua("beamcomp_init.grid_set('mirror', " + (on ? 'true' : 'false') + ')');
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
      scope.knobs = KNOBS;
      scope.data = { races: [], grids: [] };
      // `loadName` holds a gridKey (race + name), not a bare name: the list spans several races.
      scope.form = { race: '', loadName: '', saveName: '' };
      // The authoritative live session as last reflected by GE (BeamCompGridState). `segments` is the
      // ordered breakpoint boundaries ([{startSlot}]), `activeSegment` the 1-based index the knobs edit,
      // `activeStartSlot` that segment's start slot (ADR-0023 amendment).
      // `knobDefaults` are the layout defaults GE falls back to for a knob a loaded block omits -- shown as
      // that field's placeholder (see scope.knobHint).
      scope.state = { active: false, race: null, direction: 'forward', hasReverse: false,
        previewCount: 16, segments: [], activeSegment: 1, activeStartSlot: 0, knobs: null,
        knobDefaults: null };
      scope.edit = {};          // editable mirror of the knob number fields, synced from state on each push
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

      // Sync the editable number fields from the authoritative state, so the inputs show GE's clamped values
      // (and `columns` shows blank when auto/derived). The fields commit on blur, not per keystroke, so a
      // state push never lands mid-type to fight the cursor.
      function syncEditFromState() {
        var knobs = scope.state.knobs || {};
        KNOBS.forEach(function (k) {
          var value = knobs[k.key];
          scope.edit[k.key] = (value === undefined || value === null) ? '' : value;
        });
        scope.edit.previewCount = scope.state.previewCount;
        // The breakpoint field baselines on the active segment's start slot (a state push resets it, like
        // the knob fields); the admin retypes it to add/select a different breakpoint.
        scope.edit.breakpointSlot = scope.state.activeStartSlot;
      }

      scope.$on('BeamCompGridData', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.races = (payload && payload.races) || [];
          rebuildRaceOpts();
          // Pre-select the carried race only while no choice has been made, so a later Refresh that still
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
          scope.data.grids = (payload && payload.grids) || [];
          rebuildGridOpts();
        });
      });

      scope.$on('BeamCompGridState', function (event, payload) {
        scope.$evalAsync(function () {
          scope.state = payload || scope.state;
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
          syncEditFromState();
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

      // Close any open dropdown on a click outside it (standard dropdown UX). No DI here: injected
      // services fail to resolve for this late-loaded mod directive, so use the document global. A click
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

      // Re-pull races + saved grids from GE (Refresh button and on link).
      scope.refresh = function () {
        geCall('request_grid_data');
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
      scope.newGrid = function () {
        if (!scope.form.race) {
          return;
        }
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
      // Load-the-selection button any more (ADR-0023 amendment 2026-07-30).
      scope.loadGrid = function () {
        var grid = selectedGrid();
        if (!grid) {
          return;
        }
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

      // Stepper: nudge a knob by `delta` (a fine ±0.05 or coarse ±1.0 from the buttons) off the current
      // value (auto/blank starts at 0). Continuous values round to 2 decimals so repeated 0.05 steps don't
      // accumulate float noise; integer knobs clamp to >= 1.
      scope.stepKnob = function (knob, delta) {
        if (!scope.state.active) {
          return;
        }
        var current = scope.state.knobs ? scope.state.knobs[knob.key] : undefined;
        var base = (current === undefined || current === null) ? 0 : Number(current);
        var next = base + delta;
        if (knob.integer) {
          if (next < 1) {
            next = 1;
          }
        } else {
          next = Math.round(next * 100) / 100;
        }
        geSetKnob(knob.key, next);
      };

      // Mirror toggle: send the boolean to GE, which echoes it back through BeamCompGridState so the
      // On/Off highlight reflects the authoritative value (not local state).
      scope.setMirror = function (on) {
        if (!scope.state.active) {
          return;
        }
        geSetMirror(on);
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

      // Number-field commit: send the typed value to GE (which clamps and reflects it back).
      scope.commitKnob = function (knob) {
        if (!scope.state.active) {
          return;
        }
        var value = scope.edit[knob.key];
        if (value === '' || value === null || value === undefined) {
          return;
        }
        geSetKnob(knob.key, value);
      };

      scope.stepPreview = function (direction) {
        if (!scope.state.active) {
          return;
        }
        var next = Number(scope.state.previewCount || PREVIEW_MIN) + direction;
        next = Math.max(PREVIEW_MIN, Math.min(PREVIEW_MAX, next));
        geLuaNum('grid_set_preview', next);
      };
      scope.commitPreview = function () {
        if (!scope.state.active || scope.edit.previewCount === '' || scope.edit.previewCount === null) {
          return;
        }
        geLuaNum('grid_set_preview', scope.edit.previewCount);
      };

      // Breakpoint / segment editing (ADR-0023 amendment). The GE session owns the segment list; the
      // panel only asks it to select/create/remove and reflects the echoed state.

      // Nudge the breakpoint-slot field (does not apply -- the admin then presses Select / add). Clamped
      // to >= 0 (slot 0 is the base segment).
      scope.stepBreakpoint = function (delta) {
        var base = Number(scope.edit.breakpointSlot);
        if (!isFinite(base)) {
          base = scope.state.activeStartSlot || 0;
        }
        var next = base + delta;
        if (next < 0) {
          next = 0;
        }
        scope.edit.breakpointSlot = next;
      };

      // Select the segment starting at `slot`, or create one there seeded from the covering segment.
      scope.selectSegment = function (slot) {
        if (!scope.state.active) {
          return;
        }
        geLuaNum('grid_select_segment', slot);
      };

      // Remove the active breakpoint (merges its slots into the previous segment). GE rejects segment 0.
      scope.removeSegment = function () {
        if (!scope.state.active) {
          return;
        }
        geCall('grid_remove_segment');
      };

      // Reveal (or cancel) the Save name row. It deliberately does NOT touch form.saveName -- the opposite
      // of the setup panel's preset row, which prefills at reveal time. Here the field is already seeded
      // where the save target is decided: newGrid() puts a suggestion in it and loadGrid() the loaded grid's
      // own name, and savedName plus the "Overwrites '<name>'" hint hang off it. Revealing shows what is
      // already there; overwriting it on every reveal would destroy a name the admin typed and collapsed.
      scope.toggleSave = function () {
        scope.saveOpen = !scope.saveOpen;
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
      // is fire-and-forget and the feedback already exists (the server chats the save and echoes the list).
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
      // asks GE for the lists itself (data arrives back via the $on handlers above).
      scope.refresh();
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
