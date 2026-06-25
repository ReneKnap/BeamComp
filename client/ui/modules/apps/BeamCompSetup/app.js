// BeamComp Setup -- AngularJS directive (ADR-0037).
// An on-demand, admin-only panel that sets every /race option and starts the race. Opened by the
// server-gated /raceui relay: the GE extension (init.lua handle_setup_open) pushes the dynamic option
// lists here via guihooks and ensures this app is visible. Data flows GE -> UI via scope.$on
// (BeamCompSetupData / BeamCompSetupGrids / BeamCompSetupCars). Start submits UI -> GE by serialising the
// form to JSON and calling beamcomp_init.start_race_from_ui via bngApi -- referenced as the core UI global
// (NOT an injected service, which would fail to resolve for this late-loaded mod app and take the whole
// directive down) and typeof-guarded so a miss is inert.
//
// Dropdowns are custom (a button + a div list driven by ng-click), not native <select>: native selects do
// not open in the BeamNG CEF overlay. ng-click works (checkboxes/number inputs do too), so the custom
// list is the robust path.
angular.module('beamng.apps')
.directive('beamCompSetup', [function () {
  // Static enum options (value + label). Dynamic lists (race/car/grid/config) are built from GE pushes.
  var STATIC_OPTS = {
    mode: [{ v: '', label: 'auto' }, { v: 'sprint', label: 'sprint' }, { v: 'circuit', label: 'circuit' }],
    orderMode: [{ v: 'entry', label: 'entry' }, { v: 'random', label: 'random' },
      { v: 'last', label: 'last result' }, { v: 'pwr', label: 'power/weight' },
      { v: 'quali', label: 'qualifying' }],
    qualiPresets: [5, 8, 12, 15],
    champPreset: [{ v: 'f1', label: 'F1 (25-18-15…)' }, { v: 'linear', label: 'linear (per starter)' },
      { v: 'quadratic', label: 'quadratic (64-32-16…)' }],
    champOrder: [{ v: 'reversed', label: 'reversed (handicap)' }, { v: 'normal', label: 'normal' },
      { v: 'quali', label: 'qualifying' }],
    aiPreset: [{ v: '', label: 'default' }, { v: 'easy', label: 'easy' }, { v: 'medium', label: 'medium' },
      { v: 'hard', label: 'hard' }],
    aiRoute: [{ v: '', label: 'default' }, { v: 'snap', label: 'snap (road)' },
      { v: 'direct', label: 'direct (exact)' }],
  };

  // Defaults mirror /race with no arguments (ADR-0037 v1: always opens at defaults, no persistence).
  function freshForm() {
    return {
      race: '', mode: '', laps: '', reverse: false, force: false, includeDeprecated: false,
      carModel: '', carConfig: '', maxhp: '', maxpwr: '',
      orderMode: 'entry', orderRev: false, qualiMinutes: 5, grid: '',
      recover: true, recoverSecs: '', repair: true, repairSecs: '',
      aiEnabled: false, aiCount: 1, aiPreset: '', aiCar: '', aiRoute: '', aiAdvanced: false,
      aiAggr: '', aiSkill: '', aiRubber: '', aiAvoid: false,
      champPreset: 'f1', champOrder: 'reversed', champQualiMinutes: 5,
    };
  }

  // Run a Lua command on the GE side, with the single string argument safely embedded (single-quoted, so
  // the JSON's double quotes pass through; backslashes and single quotes are escaped). Inert when bngApi
  // is unavailable (see header) -- the panel simply cannot submit, never throws.
  function geLuaArg(fn, arg) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    var escaped = String(arg).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    bngApi.engineLua('beamcomp_init.' + fn + "('" + escaped + "')");
  }

  // Call a no-argument GE function, same typeof guard as geLuaArg.
  function geCall(fn) {
    if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
      bngApi.engineLua('beamcomp_init.' + fn + '()');
    }
  }

  // A numeric field value or undefined when blank/non-numeric, so optional numbers are omitted from the
  // payload (the server then applies its default) rather than sent as 0 or NaN.
  function num(value) {
    if (value === '' || value === null || value === undefined) {
      return undefined;
    }
    var n = Number(value);
    return isNaN(n) ? undefined : n;
  }

  // Build the overrides object in the exact shape parse_race_args produces server-side (ADR-0037), so the
  // structured start joins the same path as a typed /race. nil/omitted = auto/off, matching the parser.
  function buildOverrides(form) {
    var o = {
      force: !!form.force,
      all: !!form.includeDeprecated,
      assists: {
        recoverEnabled: !!form.recover,
        repairEnabled: !!form.repair,
      },
      order: { mode: form.orderMode, rev: !!form.orderRev },
    };
    // Qualifying length (ADR-0041): only meaningful for order=quali; sent as minutes, the server clamps.
    if (form.orderMode === 'quali' && num(form.qualiMinutes) !== undefined) {
      o.qualiMinutes = num(form.qualiMinutes);
    }
    if (form.mode) { o.mode = form.mode; }
    if (num(form.laps) !== undefined) { o.laps = num(form.laps); }
    if (form.reverse) { o.direction = 'reverse'; }
    if (form.grid) { o.grid = form.grid; }

    if (form.recover && num(form.recoverSecs) !== undefined) { o.assists.recoverHoldSeconds = num(form.recoverSecs); }
    if (form.repair && num(form.repairSecs) !== undefined) { o.assists.repairHoldSeconds = num(form.repairSecs); }

    // Vehicle policy: a fixed car wins; otherwise the optional power caps apply (ADR-0032). The server
    // enforces the same precedence, but keep the payload clean.
    if (form.carModel) {
      o.car = form.carConfig ? (form.carModel + ':' + form.carConfig) : form.carModel;
    } else {
      if (num(form.maxhp) !== undefined) { o.maxhp = num(form.maxhp); }
      if (num(form.maxpwr) !== undefined) { o.maxpwr = num(form.maxpwr); }
    }

    if (form.aiEnabled) {
      var ai = { count: num(form.aiCount) || 1, explicit: true };
      if (form.aiPreset) { ai.preset = form.aiPreset; }
      if (form.aiCar) { ai.car = form.aiCar; }
      var params = {};
      if (num(form.aiAggr) !== undefined) { params.aggr = num(form.aiAggr); }
      if (num(form.aiSkill) !== undefined) { params.skill = num(form.aiSkill); }
      if (num(form.aiRubber) !== undefined) { params.rubber = num(form.aiRubber); }
      if (form.aiAvoid) { params.avoid = true; }
      if (form.aiRoute) { params.route = form.aiRoute; }
      if (Object.keys(params).length) { ai.params = params; }
      o.ai = ai;
    }
    return o;
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompSetup/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope) {
      scope.data = { races: [], cars: [], grids: [], configs: [] };
      scope.form = freshForm();
      scope.open = null;       // name of the currently open dropdown, or null
      scope.prepared = false;  // true after Prepare Race: the race is staging, so reveal Start Race
      scope.opts = angular.extend({ race: [], carModel: [], carConfig: [], grid: [], aiCar: [] }, STATIC_OPTS);
      scope.championship = { active: false };  // latest server-broadcast championship state (ADR-0040)

      // Rebuild the dynamic dropdown lists ({v, label}) from the latest GE-pushed data.
      function rebuildRaceCarOpts() {
        scope.opts.race = (scope.data.races || []).map(function (r) { return { v: r.id, label: r.label }; });
        var cars = (scope.data.cars || []).map(function (m) { return { v: m, label: m }; });
        scope.opts.carModel = [{ v: '', label: 'keep own' }].concat(cars);
        scope.opts.aiCar = [{ v: '', label: 'default' }, { v: 'random', label: 'random' }].concat(cars);
      }
      function rebuildGridOpts() {
        scope.opts.grid = [{ v: '', label: 'default' }].concat(
          (scope.data.grids || []).map(function (g) { return { v: g, label: g }; }));
      }
      function rebuildConfigOpts() {
        scope.opts.carConfig = [{ v: '', label: 'default' }].concat(
          (scope.data.configs || []).map(function (c) { return { v: c.config, label: c.name }; }));
      }

      // GE pushes the dynamic lists on open AND on every refresh (the include-deprecated toggle, the Refresh
      // button). It must update only the option lists -- NOT the form: resetting the form here made the
      // include-deprecated toggle (which triggers a refresh) snap back instantly, and wiped settings between
      // refreshes. The form is seeded once on link and restored from GE via BeamCompSetupForm.
      scope.$on('BeamCompSetupData', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.races = (payload && payload.races) || [];
          scope.data.cars = (payload && payload.cars) || [];
          rebuildRaceCarOpts();
          // Keep the grid/config lists if the selected race/car still needs them; a stale config list is
          // harmless (labelFor falls back) and re-fetched on the next model change.
          rebuildGridOpts();
          rebuildConfigOpts();
        });
      });

      // Restore the last race's form, remembered by GE across panel close/reopen within the session
      // (ADR-0037). Merge over freshForm so any field absent from an older stored form keeps its default.
      scope.$on('BeamCompSetupForm', function (event, payload) {
        scope.$evalAsync(function () {
          if (!payload || !payload.form) {
            return;
          }
          var parsed;
          try {
            parsed = JSON.parse(payload.form);
          } catch (e) {
            return;
          }
          scope.form = angular.extend(freshForm(), parsed);
          // Re-sync the race list to the restored include-deprecated flag, and fetch the restored model's
          // configs so the config dropdown + label resolve (without clearing the stored config).
          scope.refresh();
          if (scope.form.carModel) {
            geLuaArg('request_car_configs', scope.form.carModel);
          }
        });
      });

      scope.$on('BeamCompSetupGrids', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.grids = (payload && payload.names) || [];
          rebuildGridOpts();
        });
      });

      scope.$on('BeamCompSetupCars', function (event, payload) {
        scope.$evalAsync(function () {
          // Only the configs for the currently selected model are relevant.
          if (payload && payload.model === scope.form.carModel) {
            scope.data.configs = payload.configs || [];
            rebuildConfigOpts();
          }
        });
      });

      // Custom-dropdown plumbing (native <select> does not open in the CEF overlay).
      scope.toggle = function (field) {
        scope.open = (scope.open === field) ? null : field;
      };

      scope.labelFor = function (field) {
        var list = scope.opts[field] || [];
        var value = scope.form[field];
        for (var i = 0; i < list.length; i++) {
          if (list[i].v === value) {
            return list[i].label;
          }
        }
        return field === 'race' ? 'select…' : value;
      };

      scope.pick = function (field, value) {
        scope.form[field] = value;
        scope.open = null;
        if (field === 'carModel') {
          onModelChange();
        }
      };

      // Car model changed: clear the stale config and lazily fetch this model's configs from GE.
      function onModelChange() {
        scope.form.carConfig = '';
        scope.data.configs = [];
        rebuildConfigOpts();
        if (scope.form.carModel) {
          geLuaArg('request_car_configs', scope.form.carModel);
        }
      }

      // Re-pull the option lists from GE (Refresh button, the include-deprecated toggle, and on link). The
      // flag tells GE whether to include deprecated races in the list.
      scope.refresh = function () {
        geLuaArg('request_setup_data', scope.form.includeDeprecated ? '1' : '');
      };

      // Open the grid editor for the currently selected race (ADR-0037 amendment). This panel stays open;
      // GE opens BeamCompGridEditor client-side with the race carried over.
      scope.editGrid = function () {
        if (scope.form.race) {
          geLuaArg('open_grid_editor_with_race', scope.form.race);
        }
      };

      // Prepare Race: send the structured request -- the race spawns + enters staging. Reveals Start Race.
      // While a championship is active, omit order= so the server applies the championship's grid order
      // (ADR-0040) instead of this panel's default; an explicit per-race order would otherwise win.
      scope.prepareRace = function () {
        if (!scope.form.race) {
          return;
        }
        var overrides = buildOverrides(scope.form);
        if (scope.championship.active) {
          delete overrides.order;
        }
        var request = { race: scope.form.race, overrides: overrides };
        geLuaArg('start_race_from_ui', JSON.stringify(request));
        scope.prepared = true;
      };

      // Start Race: end staging -> countdown (the /go equivalent) and close the panel.
      scope.startRaceGo = function () {
        geCall('go_race_from_ui');
        scope.close();
      };

      scope.close = function () {
        // Remember the current form so the next open restores it within the session (ADR-0037).
        geLuaArg('store_setup_form', JSON.stringify(scope.form));
        geCall('close_setup');
      };

      // Championship state (ADR-0040): GE pushes the current table + settings on open and on every change.
      // Sync the section's dropdowns to the active settings so the controls reflect reality, not stale form.
      scope.$on('BeamCompChampionship', function (event, payload) {
        scope.$evalAsync(function () {
          scope.championship = payload || { active: false };
          if (scope.championship.active) {
            scope.form.champPreset = scope.championship.preset || scope.form.champPreset;
            scope.form.champOrder = scope.championship.order || scope.form.champOrder;
            // champQualiMinutes is UI-owned and kept session-long -- do NOT overwrite it from the snapshot
            // (which would reset the admin's chosen length to the server default each broadcast). The value
            // is sent on Start/Apply; the field persists for the directive's life.
          }
        });
      });

      // Championship controls (ADR-0040): relay a structured command through GE -> server, which routes it
      // through the same admin-gated handler as /championship. start begins one; set changes settings live
      // on an active championship; reset ends it + announces the winner.
      function championshipCmd(action) {
        geLuaArg('championship_cmd', JSON.stringify({
          action: action, preset: scope.form.champPreset, order: scope.form.champOrder,
          // Qualifying length (minutes) used when the championship grid is "quali" (ADR-0041).
          qualiMinutes: num(scope.form.champQualiMinutes),
        }));
      }
      scope.championshipStart = function () { championshipCmd('start'); };
      scope.championshipApply = function () { championshipCmd('set'); };
      scope.championshipReset = function () {
        geLuaArg('championship_cmd', JSON.stringify({ action: 'reset' }));
      };

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (BeamCompSetupData arrives back via the $on above). Also pull the
      // remembered form (BeamCompSetupForm) so a reopen restores the last race's settings.
      scope.refresh();
      geCall('request_setup_form');
      geCall('request_championship');
    },
  };
}]);
