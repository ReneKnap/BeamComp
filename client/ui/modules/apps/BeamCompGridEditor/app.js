// BeamComp Grid Editor -- AngularJS directive (ADR-0037 amendment, fronting ADR-0023).
// An on-demand, admin-only panel that tunes, previews, saves and assigns parametric start grids. Opened by
// the server-gated /gridui relay (or the race-setup panel's "Grid bearbeiten" button): the GE extension
// (init.lua) pushes the race list + saved-grid names here via guihooks and ensures this app is visible.
//
// GE owns the live edit session (race/grideditor.lua) -- this panel is render + input only. It reflects
// BeamCompGridState (the authoritative, clamped knob values) and calls the knob setters back via
// beamcomp_init.* . bngApi is referenced as the core UI global (NOT injected -- a DI miss takes the whole
// late-loaded directive down) and typeof-guarded so a miss is inert. Dropdowns are custom (button + div
// list, ng-click): native <select> does not open in the BeamNG CEF overlay.
angular.module('beamng.apps')
.directive('beamCompGridEditor', [function () {
  // The seven tunable knobs (ADR-0023) in display order. Each continuous knob has a fine (0.05) and a
  // coarse (1.0) stepper pair; integer knobs (rows/columns) step by 1 only. rows and columns are mutually
  // exclusive width pins: pinning one drops the other (GE clears it), which then shows blank ("auto") and
  // is derived from the field at spawn. Both carry `auto: true` so whichever is unpinned reads "auto".
  var KNOBS = [
    { key: 'offsetForward', label: 'Offset forward (m)' },
    { key: 'offsetLateral', label: 'Offset lateral (m)' },
    { key: 'headingDeg', label: 'Heading (deg)' },
    { key: 'rowGap', label: 'Row gap (m)' },
    { key: 'colGap', label: 'Col gap (m)' },
    { key: 'rows', label: 'Rows', integer: true, auto: true },
    { key: 'columns', label: 'Columns', integer: true, auto: true },
  ];

  var PREVIEW_MIN = 1;
  var PREVIEW_MAX = 32;

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

  // Run a GE command with two string arguments, each single-quoted + escaped.
  function geLuaArg2(fn, a, b) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var ea = String(a).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    var eb = String(b).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua('beamcomp_init.' + fn + "('" + ea + "', '" + eb + "')");
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

  // Assign a saved grid as a race default: grid_assign(race, name), both single-quoted.
  function geAssign(race, name) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var r = String(race).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    var n = String(name).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua("beamcomp_init.grid_assign('" + r + "', '" + n + "')");
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompGridEditor/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      scope.knobs = KNOBS;
      scope.data = { races: [], grids: [] };
      scope.form = { race: '', loadName: '', saveName: '', assignRace: '' };
      // The authoritative live session as last reflected by GE (BeamCompGridState).
      scope.state = { active: false, race: null, direction: 'forward', hasReverse: false,
        previewCount: 8, knobs: null };
      scope.edit = {};          // editable mirror of the knob number fields, synced from state on each push
      scope.savedName = null;   // set after a save/load; gates Assign (you assign an existing grid)
      scope.open = null;        // name of the currently open dropdown, or null
      scope.opts = { race: [], loadName: [], assignRace: [] };

      function rebuildRaceOpts() {
        var races = (scope.data.races || []).map(function (r) { return { v: r.id, label: r.label }; });
        scope.opts.race = races;
        scope.opts.assignRace = races;
      }
      function rebuildGridOpts() {
        scope.opts.loadName = (scope.data.grids || []).map(function (g) { return { v: g, label: g }; });
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
        });
      });

      scope.$on('BeamCompGridList', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.grids = (payload && payload.names) || [];
          rebuildGridOpts();
        });
      });

      scope.$on('BeamCompGridState', function (event, payload) {
        scope.$evalAsync(function () {
          scope.state = payload || scope.state;
          // savedName tracks the active grid's persisted name (gates Assign, marks the overwrite target).
          scope.savedName = scope.state.name || null;
          if (scope.state.active && scope.state.race) {
            // Restore the anchor + assign targets after a panel reopen (fresh scope), without clobbering a
            // choice the admin has already made this open.
            if (!scope.form.race) {
              scope.form.race = scope.state.race;
            }
            if (!scope.form.assignRace) {
              scope.form.assignRace = scope.state.race;
            }
          }
          // Restore the overwrite name only when the field is empty (reopen) -- loadGrid/newGrid set it
          // explicitly, and a knob push must not wipe a save-as name the admin is typing.
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
      };

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
      // clear the overwrite target until the admin saves it.
      scope.newGrid = function () {
        if (!scope.form.race) {
          return;
        }
        scope.savedName = null;
        scope.form.saveName = '';
        geLuaArg('grid_open_new', scope.form.race);
      };

      // Load a saved grid for editing, re-anchored onto the currently selected race (grid params are
      // relative to a start line, so a grid keeps its layout against whatever race is being edited).
      // Pre-fill its name so a later Save overwrites it without retyping.
      scope.loadGrid = function () {
        if (!scope.form.loadName) {
          return;
        }
        scope.savedName = scope.form.loadName;
        scope.form.saveName = scope.form.loadName;
        geLuaArg2('grid_open_saved', scope.form.loadName, scope.form.race || '');
      };

      // Delete the selected saved grid; the server echoes the updated list, refreshing the dropdown.
      scope.deleteGrid = function () {
        if (!scope.form.loadName) {
          return;
        }
        geLuaArg('grid_delete', scope.form.loadName);
        scope.form.loadName = '';
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

      scope.canSave = function () {
        return scope.state.active && scope.form.saveName && !/\s/.test(scope.form.saveName);
      };
      scope.saveGrid = function () {
        if (!scope.canSave()) {
          return;
        }
        geLuaArg('grid_save', scope.form.saveName);
        scope.savedName = scope.form.saveName;
      };

      scope.assignGrid = function () {
        if (!scope.savedName || !scope.form.assignRace) {
          return;
        }
        geAssign(scope.form.assignRace, scope.savedName);
      };

      // Clear ends the edit session (pillars vanish, panel returns to "pick a race"); the session is kept
      // alive by Close so a reopen restores it.
      scope.clearEditor = function () {
        scope.savedName = null;
        scope.form.saveName = '';
        geCall('clear_grid_editor');
      };

      scope.close = function () {
        geCall('close_grid_editor');
      };

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (data arrives back via the $on handlers above).
      scope.refresh();
    },
  };
}]);
