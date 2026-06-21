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
      { v: 'last', label: 'last result' }, { v: 'pwr', label: 'power/weight' }],
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
      orderMode: 'entry', orderRev: false, grid: '',
      recover: true, recoverSecs: '', repair: true, repairSecs: '',
      aiEnabled: false, aiCount: 1, aiPreset: '', aiCar: '', aiRoute: '', aiAdvanced: false,
      aiAggr: '', aiSkill: '', aiRubber: '', aiAvoid: false,
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

      // GE pushes the dynamic lists when the panel opens; reset the form to defaults each open.
      scope.$on('BeamCompSetupData', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.races = (payload && payload.races) || [];
          scope.data.cars = (payload && payload.cars) || [];
          scope.data.configs = [];
          scope.data.grids = [];
          scope.form = freshForm();
          scope.open = null;
          scope.prepared = false;
          rebuildRaceCarOpts();
          rebuildGridOpts();
          rebuildConfigOpts();
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

      // Prepare Race: send the structured request -- the race spawns + enters staging. Reveals Start Race.
      scope.prepareRace = function () {
        if (!scope.form.race) {
          return;
        }
        var request = { race: scope.form.race, overrides: buildOverrides(scope.form) };
        geLuaArg('start_race_from_ui', JSON.stringify(request));
        scope.prepared = true;
      };

      // Start Race: end staging -> countdown (the /go equivalent) and close the panel.
      scope.startRaceGo = function () {
        geCall('go_race_from_ui');
        scope.close();
      };

      scope.close = function () {
        geCall('close_setup');
      };

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (BeamCompSetupData arrives back via the $on above).
      scope.refresh();
    },
  };
}]);
