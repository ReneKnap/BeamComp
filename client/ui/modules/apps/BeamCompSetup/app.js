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
    // Tournament mode (ADR-0042): the two multi-race formats are mutually exclusive, picked here.
    tourMode: [{ v: 'off', label: 'off' }, { v: 'championship', label: 'Points Championship' },
      { v: 'classdrop', label: 'Class-Drop' }],
    // Class-drop per-round grid order: the car class is the handicap, so it defaults to random (no quali).
    tourOrder: [{ v: 'entry', label: 'entry' }, { v: 'random', label: 'random' },
      { v: 'last', label: 'last result' }, { v: 'pwr', label: 'power/weight' }],
    aiPreset: [{ v: '', label: 'default' }, { v: 'easy', label: 'easy' }, { v: 'medium', label: 'medium' },
      { v: 'hard', label: 'hard' }],
    aiRoute: [{ v: '', label: 'default' }, { v: 'snap', label: 'snap (road)' },
      { v: 'direct', label: 'direct (exact)' }],
  };

  // One class-drop class row in the panel (ADR-0042): either a fixed car (kind 'car' + model[:config]) or a
  // power cap (kind 'cap' + maxhp/maxpwr). The Add-class button defaults to a cap row -- a cap needs no car
  // lookup, so growing a ladder by hand stays simplest there.
  function defaultClass() {
    return { kind: 'cap', car: '', config: '', maxhp: '', maxpwr: '' };
  }
  // A fixed-car class row (kind 'car'); same shape as defaultClass, used to build the curated default ladder.
  function carClass(model, config) {
    return { kind: 'car', car: model, config: config, maxhp: '', maxpwr: '' };
  }
  // Curated default class ladder for a fresh form (ADR-0037 defaults): three etk800 power steps ordered
  // fast->slow -- class 1 is the quickest, winning the slowest is the tournament win (ADR-0042). Fully
  // editable like any class row; the session form-restore (BeamCompSetupForm) overrides it once a
  // tournament has been configured within the session.
  function defaultTourClasses() {
    return [
      carClass('etk800', '846_340_A'),
      carClass('etk800', '844_250_A'),
      carClass('etk800', '844_150_A'),
    ];
  }

  // Curated panel defaults (ADR-0037): a fresh form opens at opinionated race settings -- random start
  // order, plus (once AI is toggled on) 4 hard AI on random stock cars that avoid each other. These differ
  // from bare /race (entry order, no AI car); the session form-restore (BeamCompSetupForm) overrides them
  // after a race has been set up.
  function freshForm() {
    return {
      race: '', mode: '', laps: '', reverse: false, force: false, includeDeprecated: false,
      carModel: '', carConfig: '', maxhp: '', maxpwr: '', maxkg: '', minkg: '', restrictVehicles: false,
      // Composable player random-car axes (carModel='random'): a random compliant trim, and exclude
      // big/heavy vehicles. Both default ON (parity with the AI freshForm defaults), sent as explicit
      // booleans so a saved preset round-trips the admin's choice.
      carRandomTrim: true, carNoBigCars: true,
      orderMode: 'random', orderRev: false, qualiMinutes: 5, grid: '',
      f1Start: false, jumpPenalty: 15,
      recover: true, recoverSecs: '', repair: true, repairSecs: '',
      aiEnabled: false, aiCount: 4, aiPreset: 'hard', aiCar: 'random', aiRoute: '', aiAdvanced: false,
      aiAggr: '', aiSkill: '', aiRubber: '', aiAvoid: true,
      // Named AI roster (ADR-0047): [{name, car, carLabel}] created via the Create button. THE gate for
      // panel-spawned AI -- buildOverrides sends `ai` only when this is non-empty. Session-restored with
      // the form AND saved in a preset (ADR-0047 amendment 2026-07-18): a loaded non-empty roster restores
      // the "created" state (pre-fill only -- restoring the roster never rolls or spawns).
      aiRoster: [],
      // Composable random-AI axes (aiCar='random'): stock vs random trim, and exclude big/heavy vehicles.
      // Both default ON (sensible-defaults, like the curated race settings): a random compliant trim plus a
      // curb-weight ceiling that keeps oversized/heavy vehicles out. Existing saved presets keep their stored
      // values -- presets serialise these as explicit booleans, so the new default only affects fresh forms
      // and presets saved after this change.
      aiRandomTrim: true, aiNoBigCars: true,
      champPreset: 'f1', champOrder: 'reversed', champQualiMinutes: 5,
      tourMode: 'off', tourClasses: defaultTourClasses(), tourOrder: 'random',
    };
  }

  // A saved preset persists the ENTIRE form -- nothing is excluded anymore (ADR-0037 amendment 2026-07-18,
  // R2). This covers the multi-race-format choice + its settings (tourMode, champPreset/champOrder/
  // champQualiMinutes, tourClasses/tourOrder) AND the full AI setup including the named roster
  // (aiRoster = [{name, car, carLabel, color, ...}]; the ai* scalars were already saved). Load is
  // PRE-FILL ONLY -- applyStoredForm sets scope.form directly (angular.extend), so it restores the format
  // fields and the roster verbatim WITHOUT firing any live command (championshipCmd/tournamentCmd) or roll/
  // spawn: a loaded non-empty roster is simply in the "created" state (ADR-0047: buildOverrides gates `ai`
  // on a non-empty roster) and spawns at race start like any created roster. The live .active state stays
  // server-driven. Kept as a (currently empty) list so a future must-exclude field has an obvious home.
  var PRESET_EXCLUDE_KEYS = [];

  // Reduce a roster to only its meaningful, persistable fields. Once the roster list has RENDERED, Angular's
  // ng-repeat stamps a tracking id ($$hashKey) onto every entry, and the per-AI editor sets a transient
  // _open flag -- neither belongs in stored/transported data. This is the R2-load bug (bug preset-multirace-
  // roster-not-created): the R2 harness set aiRoster directly (never rendered, so no $$hashKey) and passed,
  // but the live panel renders the roster before Save, baking a $$hashKey into the preset blob; on load that
  // FOREIGN tracking id rides back into the reopened panel's ng-repeat and breaks the roster's re-creation.
  // Persist/restore the clean shape {name, car, carLabel, color} so a loaded roster gets fresh Angular
  // tracking, and _open never reopens editors against the default-collapsed rule.
  function cleanRoster(roster) {
    return (roster || []).map(function (e) {
      return { name: e.name, car: e.car, carLabel: e.carLabel, color: e.color };
    });
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

  // Copy the form's set vehicle caps (hp / hp-per-kg / weight range) onto a target object, blanks
  // omitted. Shared by buildOverrides (the race payload) and buildRosterPolicy (the roster rolls), so
  // the two can never relay different caps.
  function capsInto(form, target) {
    if (num(form.maxhp) !== undefined) { target.maxhp = num(form.maxhp); }
    if (num(form.maxpwr) !== undefined) { target.maxpwr = num(form.maxpwr); }
    if (num(form.maxkg) !== undefined) { target.maxkg = num(form.maxkg); }
    if (num(form.minkg) !== undefined) { target.minkg = num(form.minkg); }
  }

  // The player vehicle-policy slice the GE roster roll expects (ADR-0047): mirrors buildOverrides'
  // car/caps relay exactly, so a rolled roster car obeys precisely what the race would send (fixed car
  // wins and drops the caps; car=random composes them; the restriction toggle gates the caps).
  function buildRosterPolicy(form) {
    var policy = {};
    if (form.carModel === 'random') {
      policy.car = 'random';
      policy.randomTrim = !!form.carRandomTrim;
      policy.noBigCars = !!form.carNoBigCars;
      if (form.restrictVehicles) { capsInto(form, policy); }
    } else if (form.carModel) {
      policy.car = form.carConfig ? (form.carModel + ':' + form.carConfig) : form.carModel;
    } else if (form.restrictVehicles) {
      capsInto(form, policy);
    }
    return policy;
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

    // F1 light start (ADR-0043): off = the default lock countdown; on relays startMode + the configurable
    // jump-start penalty seconds (a blank lets the server default it).
    if (form.f1Start) {
      o.startMode = 'f1';
      if (num(form.jumpPenalty) !== undefined) { o.jumpPenaltySeconds = num(form.jumpPenalty); }
    }

    if (form.recover && num(form.recoverSecs) !== undefined) { o.assists.recoverHoldSeconds = num(form.recoverSecs); }
    if (form.repair && num(form.repairSecs) !== undefined) { o.assists.repairHoldSeconds = num(form.repairSecs); }

    // Vehicle policy (ADR-0032/0037). A FIXED car wins and drops the caps; car=random is the exception -- it
    // composes with the caps (the client draws from the cap-compliant pool), so relay them too. Otherwise the
    // optional power/weight caps apply on their own. The "Vehicle restrictions" toggle gates whether the caps
    // apply, so an unchecked restriction sends nothing even if a stale value lingers in a field.
    if (form.carModel === 'random') {
      o.car = 'random';
      if (form.restrictVehicles) { capsInto(form, o); }
      // The two composable axes, explicit booleans (like the AI axes): randomTrim false = stock/default trim,
      // true = a random compliant trim; noBigCars true excludes big/heavy vehicles (curb-weight ceiling).
      o.randomTrim = !!form.carRandomTrim;
      o.noBigCars = !!form.carNoBigCars;
    } else if (form.carModel) {
      o.car = form.carConfig ? (form.carModel + ':' + form.carConfig) : form.carModel;
    } else if (form.restrictVehicles) {
      capsInto(form, o);
    }

    // AI roster gate (ADR-0047): the panel fields AI only from a created roster -- aiEnabled + count alone
    // send NO `ai` at all, so no AI spawns. The typed /race chat path is unaffected. The roster length IS
    // the AI count; each entry's pre-picked {name, car, color} rides opaquely to the server (race-blind) --
    // the car lands on the per-slot spawn policy and the colour (round 3) becomes the AI's PRIMARY paint
    // layer at spawn (nil = stock). ai.car stays relayed as the chain fallback for an entry without a car
    // token.
    var roster = form.aiRoster || [];
    if (form.aiEnabled && roster.length) {
      var ai = { count: roster.length, explicit: true };
      ai.roster = roster.map(function (e) { return { name: e.name, car: e.car, color: e.color }; });
      if (form.aiPreset) { ai.preset = form.aiPreset; }
      if (form.aiCar) { ai.car = form.aiCar; }
      // Composable random-AI axes (resolved client-side in race/ai.lua): sent explicitly as booleans so the
      // resolver decouples trim from the cap. randomTrim false = stock/default config, true = random trim
      // variant; noBigCars true excludes big/heavy vehicles (curb-weight ceiling).
      ai.randomTrim = !!form.aiRandomTrim;
      ai.noBigCars = !!form.aiNoBigCars;
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
    link: function (scope, element) {
      scope.data = { races: [], cars: [], grids: [], configs: [], presets: [], aiPalette: [], aiPoolNames: [] };
      scope.form = freshForm();
      scope.open = null;       // name of the currently open dropdown, or null
      scope.prepared = false;  // true after Prepare Race: the race is staging, so reveal Start Race
      scope.presetName = '';       // the name field for Save (ADR-0037 amendment)
      scope.selectedPreset = '';   // the saved preset chosen in the dropdown, for Load / Delete
      scope.opts = angular.extend({ race: [], carModel: [], carConfig: [], grid: [], aiCar: [],
        rosterCar: [], preset: [] }, STATIC_OPTS);
      scope.rosterOpen = false;  // the roster list is collapsed by default (ADR-0047)
      scope.rosterHint = '';     // transient roster feedback line (pool save, ...)
      scope.championship = { active: false };  // latest server-broadcast championship state (ADR-0040)
      scope.tournament = { active: false };    // latest server-broadcast class-drop tournament state (ADR-0042)
      scope.configsByModel = {};               // model -> configs cache for the per-class config dropdowns (ADR-0042)
      scope.phase = 'lobby';                   // latest GE-pushed race phase, gates the race-stop controls (ADR-0038)

      // Rebuild the dynamic dropdown lists ({v, label}) from the latest GE-pushed data.
      function rebuildRaceCarOpts() {
        scope.opts.race = (scope.data.races || []).map(function (r) { return { v: r.id, label: r.label }; });
        // GE pushes each car as { model: key, label: displayName } (ADR-0037 carlist.options): the option
        // VALUE stays the model key so every consumer (car= token, AI car) is unchanged, only the shown
        // text is the human name. A bare-string entry (a stale GE/UI hot-reload mismatch) is tolerated so
        // the dropdown never renders "[object Object]".
        var cars = (scope.data.cars || []).map(function (m) {
          if (typeof m === 'string') {
            return { v: m, label: m };
          }
          return { v: m.model, label: m.label || m.model };
        });
        scope.opts.carModel = [{ v: '', label: 'keep own' }, { v: 'random', label: 'random' }].concat(cars);
        scope.opts.aiCar = [{ v: '', label: 'default' }, { v: 'random', label: 'random' },
          { v: 'host', label: 'same as host' }].concat(cars);
        // Roster rows pick a CONCRETE car (ADR-0047), so no ''/random sentinels here -- only the host
        // sentinel (resolved at spawn) plus the installed models.
        scope.opts.rosterCar = [{ v: 'host', label: "host's car" }].concat(cars);
      }
      function rebuildGridOpts() {
        scope.opts.grid = [{ v: '', label: 'default' }].concat(
          (scope.data.grids || []).map(function (g) { return { v: g, label: g }; }));
      }
      function rebuildConfigOpts() {
        scope.opts.carConfig = [{ v: '', label: 'default' }].concat(
          (scope.data.configs || []).map(function (c) { return { v: c.config, label: c.name }; }));
      }
      function rebuildPresetOpts() {
        scope.opts.preset = (scope.data.presets || []).map(function (p) { return { v: p, label: p }; });
      }

      // Apply a stored form JSON string (the session-restore blob OR a loaded preset) over a fresh form,
      // then re-sync the option lists and prefetch the configs the restored cars need. Shared by
      // BeamCompSetupForm and BeamCompSetupPresetData so a loaded preset restores EXACTLY like the session
      // form (ADR-0037 amendment). The merge over freshForm is a plain assignment -- it sets the format
      // fields (tourMode/champ*/tour*) and the AI roster verbatim but never fires championshipCmd/
      // tournamentCmd or a roster roll/spawn, so a loaded preset pre-fills everything (the format AND the
      // "created" roster) without auto-starting or spawning it (ADR-0037/0047 amendments 2026-07-18). An
      // OLDER preset that predates this simply lacks those keys, so they fall back to freshForm defaults
      // (tourMode 'off', empty roster).
      function applyStoredForm(formJson) {
        if (!formJson) {
          return;
        }
        var parsed;
        try {
          parsed = JSON.parse(formJson);
        } catch (e) {
          return;
        }
        scope.form = angular.extend(freshForm(), parsed);
        // Drop any Angular ng-repeat tracking id ($$hashKey) / editor flag (_open) a preset saved before the
        // fix baked into its roster entries, so the restored roster renders with fresh tracking instead of a
        // foreign id (bug preset-multirace-roster-not-created). New presets are already clean (savePreset).
        scope.form.aiRoster = cleanRoster(scope.form.aiRoster);
        // Auto-reveal the vehicle-restriction fields when a restored form or loaded preset carries any cap
        // value, so a saved restriction is never silently hidden-but-inactive (and older presets that predate
        // the restrictVehicles flag still show their caps).
        if (num(scope.form.maxhp) !== undefined || num(scope.form.maxpwr) !== undefined
            || num(scope.form.maxkg) !== undefined || num(scope.form.minkg) !== undefined) {
          scope.form.restrictVehicles = true;
        }
        // Re-sync the race list to the restored include-deprecated flag, and fetch the restored model's
        // configs so the config dropdown + label resolve (without clearing the stored config).
        scope.refresh();
        if (scope.form.carModel && scope.form.carModel !== 'random') {
          geLuaArg('request_car_configs', scope.form.carModel);
        }
        // Re-fetch configs for each restored class car so the per-class config dropdowns repopulate (ADR-0042).
        (scope.form.tourClasses || []).forEach(function (c) {
          if (c.car) {
            geLuaArg('request_car_configs', c.car);
          }
        });
        // Same for the restored roster entries' cars (ADR-0047), so each row's config dropdown has its
        // options without re-picking the model. UX only -- the stored token spawns regardless.
        (scope.form.aiRoster || []).forEach(function (e) {
          var model = (e.car && e.car !== 'host') ? String(e.car).split(':')[0] : '';
          if (model) {
            geLuaArg('request_car_configs', model);
          }
        });
      }

      // GE pushes the dynamic lists on open AND on every refresh (the include-deprecated toggle, the Refresh
      // button). It must update only the option lists -- NOT the form: resetting the form here made the
      // include-deprecated toggle (which triggers a refresh) snap back instantly, and wiped settings between
      // refreshes. The form is seeded once on link and restored from GE via BeamCompSetupForm.
      scope.$on('BeamCompSetupData', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.races = (payload && payload.races) || [];
          scope.data.cars = (payload && payload.cars) || [];
          // The AI roster colour palette (ADR-0047 round 3): the swatch picker + the JS-side colour reroll
          // draw from this. Static, pushed with the setup data so it is present on link and after restore.
          scope.data.aiPalette = (payload && payload.aiPalette) || scope.data.aiPalette || [];
          rebuildRaceCarOpts();
          // Keep the grid/config lists if the selected race/car still needs them; a stale config list is
          // harmless (labelFor falls back) and re-fetched on the next model change.
          rebuildGridOpts();
          rebuildConfigOpts();
        });
      });

      // The AI roster name pool (ADR-0047 amendment R2): GE pushes the pickable names (custom + built-ins)
      // with the setup data and again after a pool save, so the per-AI name dropdown reflects the pool.
      scope.$on('BeamCompAiPool', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.aiPoolNames = (payload && payload.names) || scope.data.aiPoolNames || [];
        });
      });

      // Restore the last race's form, remembered by GE across panel close/reopen within the session
      // (ADR-0037). Merge over freshForm so any field absent from an older stored form keeps its default.
      scope.$on('BeamCompSetupForm', function (event, payload) {
        scope.$evalAsync(function () {
          applyStoredForm(payload && payload.form);
        });
      });

      // Apply a loaded preset's form (ADR-0037 amendment): the same restore path as the session form, so a
      // loaded preset behaves identically -- pre-filling the format selector + settings without auto-starting
      // (applyStoredForm never fires a championship/tournament command). Old presets predating format
      // persistence lack those keys and fall back to freshForm defaults (tourMode 'off').
      scope.$on('BeamCompSetupPresetData', function (event, payload) {
        scope.$evalAsync(function () {
          applyStoredForm(payload && payload.form);
        });
      });

      scope.$on('BeamCompSetupGrids', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.grids = (payload && payload.names) || [];
          rebuildGridOpts();
        });
      });

      // Authoritative saved-preset list from the server (ADR-0037 amendment): the panel reflects it as
      // truth, not local state. Drop the current selection if it is gone (e.g. just deleted by anyone).
      scope.$on('BeamCompSetupPresets', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.presets = (payload && payload.names) || [];
          rebuildPresetOpts();
          if (scope.selectedPreset && scope.data.presets.indexOf(scope.selectedPreset) === -1) {
            scope.selectedPreset = '';
          }
        });
      });

      scope.$on('BeamCompSetupCars', function (event, payload) {
        scope.$evalAsync(function () {
          if (!payload || !payload.model) {
            return;
          }
          // Cache by model so each class row's config dropdown can resolve its own model (ADR-0042).
          scope.configsByModel[payload.model] = payload.configs || [];
          // The per-race vehicle-policy picker tracks the single selected model.
          if (payload.model === scope.form.carModel) {
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

      // Car model changed: clear the stale config and lazily fetch this model's configs from GE. The
      // 'random' sentinel is not a real model (no configs to fetch, no Config row), so skip the fetch.
      function onModelChange() {
        scope.form.carConfig = '';
        scope.data.configs = [];
        rebuildConfigOpts();
        if (scope.form.carModel && scope.form.carModel !== 'random') {
          geLuaArg('request_car_configs', scope.form.carModel);
        }
      }

      // Whether the vehicle-restriction toggle + caps are shown: for "keep own" and for car=random (which
      // composes with the caps), but not for a fixed car (its caps are dropped by the car-wins precedence).
      scope.showRestrictions = function () {
        return !scope.form.carModel || scope.form.carModel === 'random';
      };

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

      // Presets (ADR-0037 amendment): save the current form under a name, or load / delete a saved one.
      // Save sends the WHOLE form -- the selected race, the multi-race-format choice + its settings, and the
      // full AI setup incl. the named roster (ADR-0037/0047 amendments 2026-07-18; PRESET_EXCLUDE_KEYS is
      // now empty) -- as an opaque JSON blob GE relays to the server with the map. The server echoes the
      // updated name list (BeamCompSetupPresets), so the dropdown reflects server truth.
      scope.presetLabel = function () {
        return scope.selectedPreset || 'select preset…';
      };
      scope.pickPreset = function (value) {
        scope.selectedPreset = value;
        scope.open = null;
      };
      scope.savePreset = function () {
        var name = (scope.presetName || '').trim();
        if (!name) {
          return;
        }
        var formCopy = angular.extend({}, scope.form);
        PRESET_EXCLUDE_KEYS.forEach(function (k) { delete formCopy[k]; });
        // Strip Angular's ng-repeat internals from the roster before it is stored/transported (see
        // cleanRoster). angular.toJson (not JSON.stringify) drops any remaining $$-prefixed keys elsewhere
        // too -- e.g. the tournament class rows once they have rendered -- so no tracking ids leak into the
        // opaque preset blob.
        formCopy.aiRoster = cleanRoster(formCopy.aiRoster);
        geLuaArg('save_preset', JSON.stringify({ name: name, form: angular.toJson(formCopy) }));
      };
      scope.loadPreset = function () {
        if (scope.selectedPreset) {
          geLuaArg('load_preset', scope.selectedPreset);
        }
      };
      scope.deletePreset = function () {
        if (scope.selectedPreset) {
          geLuaArg('delete_preset', scope.selectedPreset);
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
        // A championship (ADR-0040) or a class-drop tournament (ADR-0042) drives the grid order server-side,
        // so omit the per-race order= and let the active format apply its own.
        if (scope.championship.active || scope.tournament.active) {
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

      // Race-stop controls (ADR-0038 amendment): one-click, no confirm; the server still admin-gates and
      // guards the phase, so this gate is UX. Cancel works in any non-lobby phase -- including finished, to
      // clear the lingering results window + despawn everything; End & score only during racing (gated in
      // the HTML on phase).
      scope.canCancel = function () {
        return scope.phase && scope.phase !== 'lobby';
      };
      scope.cancelRace = function () { geCall('cancel_race_from_ui'); };  // /raceclear: discard + despawn
      scope.endRace = function () { geCall('end_race_from_ui'); };        // /raceend: force finish + score

      scope.close = function () {
        // Remember the current form so the next open restores it within the session (ADR-0037).
        geLuaArg('store_setup_form', JSON.stringify(scope.form));
        geCall('close_setup');
      };

      // Championship state (ADR-0040): GE pushes the current table + settings on open and on every change.
      // Sync the section's dropdowns to the active settings so the controls reflect reality, not stale form.
      // GE pushes the race phase on every transition and on request (request_race_phase). Gates the
      // race-stop controls so they appear only while a race is active (ADR-0038 amendment).
      scope.$on('BeamCompSetupPhase', function (event, payload) {
        scope.$evalAsync(function () {
          scope.phase = (payload && payload.phase) || 'lobby';
        });
      });

      scope.$on('BeamCompChampionship', function (event, payload) {
        scope.$evalAsync(function () {
          scope.championship = payload || { active: false };
          if (scope.championship.active) {
            scope.form.tourMode = 'championship';  // reflect the active format in the mode selector (ADR-0042)
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
      // Live-apply: every championship option change applies at once. Sends 'start' if not yet active (which
      // also captures a change made in the brief window before the activate broadcast returns -- harmless
      // pre-race, it overwrites empty standings), else 'set'. The Mode selector + live-apply replace the old
      // Start/Apply buttons.
      scope.championshipLive = function () {
        championshipCmd(scope.championship.active ? 'set' : 'start');
      };
      // Preset/grid dropdown pick: set the field, close the dropdown, live-apply.
      scope.pickChamp = function (field, value) {
        scope.form[field] = value;
        scope.open = null;
        scope.championshipLive();
      };
      // "Reset points": clear the standings but keep the championship active -- re-sending 'start' overwrites
      // with a fresh empty table while it stays on. Distinct from Mode=off, which fully stops it.
      scope.championshipRestart = function () { championshipCmd('start'); };
      // Full stop -- used by Mode=off (pickTourMode).
      scope.championshipReset = function () {
        geLuaArg('championship_cmd', JSON.stringify({ action: 'reset' }));
      };

      // Class-drop tournament state (ADR-0042): GE pushes the table + classes on open and on every change.
      // When a tournament is active, reflect it in the mode selector so the panel opens on the right section.
      scope.$on('BeamCompTournament', function (event, payload) {
        scope.$evalAsync(function () {
          scope.tournament = payload || { active: false };
          if (scope.tournament.active) {
            scope.form.tourMode = 'classdrop';
          }
        });
      });

      // Class-list editing (ADR-0042): the admin builds an ordered fast->slow list, each row a fixed car or a
      // power cap. Bounds mirror the server (2..6 classes; the server re-validates and ignores the rest).
      scope.addClass = function () {
        if (!scope.form.tourClasses) {
          scope.form.tourClasses = [];
        }
        if (scope.form.tourClasses.length < 6) {
          scope.form.tourClasses.push(defaultClass());
        }
        scope.tournamentLive();
      };
      scope.removeClass = function (i) {
        if (scope.form.tourClasses.length > 2) {
          scope.form.tourClasses.splice(i, 1);
        }
        scope.tournamentLive();
      };
      scope.setClassKind = function (i, kind) {
        scope.form.tourClasses[i].kind = kind;
        scope.tournamentLive();
      };
      // Takes the class object (not an index): the car/config options are NESTED ng-repeats, so $index there
      // is the option index, not the class row -- passing `cls` directly avoids the shadowing bug.
      scope.pickClassCar = function (cls, model) {
        cls.car = model;
        cls.config = '';  // a new model invalidates the old config; fetch the new model's configs lazily
        scope.open = null;
        if (model) {
          geLuaArg('request_car_configs', model);
        }
        scope.tournamentLive();
      };
      scope.pickClassConfig = function (cls, config) {
        cls.config = config;
        scope.open = null;
        scope.tournamentLive();
      };
      // Config dropdown options for one class's selected car model, from the per-model cache (ADR-0042).
      scope.classConfigOpts = function (cls) {
        var list = (cls.car && scope.configsByModel[cls.car]) || [];
        return [{ v: '', label: 'stock' }].concat(list.map(function (c) {
          return { v: c.config, label: c.name };
        }));
      };
      // The display name of a class row's selected config, resolved from the same options classConfigOpts
      // builds so the collapsed head matches the list -- 'stock' for the empty default, the key as fallback.
      scope.classConfigLabel = function (cls) {
        var list = scope.classConfigOpts(cls);
        var value = cls.config || '';
        for (var i = 0; i < list.length; i++) {
          if (list[i].v === value) {
            return list[i].label;
          }
        }
        return cls.config || 'stock';
      };
      // Tournament mode selector (ADR-0042): picking "off" actually stops the active format (a real off
      // switch), not just hides the section -- otherwise the next broadcast would flip the mode back.
      scope.pickTourMode = function (mode) {
        scope.form.tourMode = mode;
        scope.open = null;
        if (mode === 'off') {
          if (scope.tournament.active) { scope.tournamentReset(); }
          if (scope.championship.active) { scope.championshipReset(); }
        } else if (mode === 'championship') {
          if (!scope.championship.active) { championshipCmd('start'); }
        } else if (mode === 'classdrop') {
          // Class-drop needs >=2 valid classes to start; start now if the config already qualifies, else the
          // editor is armed and the first valid live-apply (a class edit) starts it.
          if (!scope.tournament.active && tourConfigValid()) { tournamentCmd('start'); }
        }
      };
      // Resolve a model key to its dropdown display name (Brand + Name) from the option list
      // rebuildRaceCarOpts builds; falls back to the raw key so a not-yet-loaded model still shows text.
      function modelLabel(model) {
        var list = scope.opts.carModel || [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].v === model) {
            return list[i].label;
          }
        }
        return model;
      }
      scope.classCarLabel = function (cls) {
        return cls.car ? modelLabel(cls.car) : 'select car…';
      };

      // Serialise the class rows into the opaque server specs (ADR-0042): a fixed car becomes {car} (a config
      // appended as model:config), a cap becomes {maxhp} or {maxpwr}. Empty rows pass through as {} -- the
      // server buckets them as keep-own and re-validates the overall count.
      function buildTourClasses(form) {
        return (form.tourClasses || []).map(function (c) {
          if (c.kind === 'cap') {
            if (num(c.maxhp) !== undefined) {
              return { maxhp: num(c.maxhp) };
            }
            if (num(c.maxpwr) !== undefined) {
              return { maxpwr: num(c.maxpwr) };
            }
            return {};
          }
          if (c.car) {
            return { car: c.config ? (c.car + ':' + c.config) : c.car };
          }
          return {};
        });
      }

      // Tournament controls (ADR-0042): relay a structured command through GE -> server, routed through the
      // same admin-gated handler. start begins one (ending any championship); set changes classes/order live;
      // reset ends it + announces the winner.
      function tournamentCmd(action) {
        geLuaArg('tournament_cmd', JSON.stringify({
          action: action,
          classes: buildTourClasses(scope.form),
          order: scope.form.tourOrder,
        }));
      }
      // True when the class list has >=2 configured classes (mirrors the server's sanitize threshold), so a
      // class-drop tournament can actually start.
      function tourConfigValid() {
        var n = 0;
        (scope.form.tourClasses || []).forEach(function (c) {
          if (c.kind === 'cap') {
            if (num(c.maxhp) !== undefined || num(c.maxpwr) !== undefined) { n++; }
          } else if (c.car) {
            n++;
          }
        });
        return n >= 2;
      }
      // Live-apply: a class/order change applies at once -- 'set' on an active tournament, else 'start' once
      // the config is valid, so class-drop activates as soon as >=2 classes are configured.
      scope.tournamentLive = function () {
        if (scope.tournament.active) {
          tournamentCmd('set');
        } else if (tourConfigValid()) {
          tournamentCmd('start');
        }
      };
      // Order dropdown pick: set the field, close the dropdown, live-apply.
      scope.pickTour = function (field, value) {
        scope.form[field] = value;
        scope.open = null;
        scope.tournamentLive();
      };
      // "Reset progress": everyone back to class 1 but the tournament stays on -- re-send 'start' with the
      // current classes (fresh progression, still active). Distinct from Mode=off, which fully stops it.
      scope.tournamentRestart = function () { tournamentCmd('start'); };
      // Full stop -- used by Mode=off (pickTourMode).
      scope.tournamentReset = function () {
        geLuaArg('tournament_cmd', JSON.stringify({ action: 'reset' }));
      };

      // ----- Named AI roster (ADR-0047) -----------------------------------------------------------
      // The Create button rolls a named roster GE-side (names from the pool, cars through the SAME
      // resolution chain the spawn uses), the list edits it per entry, and buildOverrides sends AI only
      // when a roster exists. Rolls are async: the GE replies via the BeamCompAiRoster* events below.

      function rosterNames() {
        return (scope.form.aiRoster || []).map(function (e) { return e.name; });
      }
      function rosterColors() {
        return (scope.form.aiRoster || []).map(function (e) { return e.color; })
          .filter(function (c) { return !!c; });
      }

      // The roll request's shared slice: the AI car mode + axes and the player policy, mirroring what
      // the race payload would relay (buildRosterPolicy) so panel rolls and spawn cannot drift.
      function rosterRollSpec() {
        var spec = { ai: { randomTrim: !!scope.form.aiRandomTrim, noBigCars: !!scope.form.aiNoBigCars } };
        if (scope.form.aiCar) { spec.ai.car = scope.form.aiCar; }
        spec.policy = buildRosterPolicy(scope.form);
        return spec;
      }

      // Clamp the count field into the panel's AI range and write it back, so a blank or wild value
      // never sizes a roll.
      function clampAiCount() {
        var count = Math.floor(num(scope.form.aiCount) || 0);
        count = Math.max(1, Math.min(16, count || 4));
        scope.form.aiCount = count;
        return count;
      }

      // The model key of a roster entry's car token ('host' for the host sentinel, '' when unset).
      scope.rosterModelOf = function (e) {
        if (!e || !e.car) { return ''; }
        return e.car === 'host' ? 'host' : String(e.car).split(':')[0];
      };
      // The config key of a roster entry's car token ('' for stock/host/unset).
      scope.rosterConfigOf = function (e) {
        if (!e || !e.car || e.car === 'host') { return ''; }
        var parts = String(e.car).split(':');
        return parts.length > 1 ? parts.slice(1).join(':') : '';
      };
      // The car field shows the MODEL only (ADR-0047 amendment, change D): the config has its own field, so
      // the old "Model - Config" (from e.carLabel) was redundant. Derived straight from the entry's model
      // token via modelLabel, independent of e.carLabel (other paths still set it, but nothing renders it now).
      scope.rosterCarLabel = function (e) {
        var model = scope.rosterModelOf(e);
        if (!model) { return 'select car…'; }
        if (model === 'host') { return "host's car"; }
        return modelLabel(model);
      };

      // Toggle the expandable roster list. A scope METHOD, not an inline `rosterOpen = !rosterOpen` on
      // the button: the Edit button lives under an ng-if (own child scope), where an inline primitive
      // write would shadow rosterOpen onto that child scope -- the sibling list reads the directive
      // scope's rosterOpen (still false) and never renders. A method resolves rosterOpen on the
      // directive scope through the closure regardless of the calling child scope.
      scope.toggleRoster = function () {
        scope.rosterOpen = !scope.rosterOpen;
      };

      // ----- Compact all-AI editor (ADR-0047 amendment R2) --------------------------------------------
      // Every AI is listed at once; each row expands its own Car/Type/Colour panel. The per-entry open flag
      // is an OBJECT property (e._open) -- an object-property write across a scope boundary is safe (unlike a
      // primitive scope write, which would shadow onto an ng-repeat child scope: the round-2 trap). The
      // dropdown-picks below stay scope methods that mutate the passed entry object.

      // Expand / collapse one AI's edit panel. e._open is an object property, so this write is safe from an
      // ng-repeat child; closing any open dropdown keeps the panel tidy.
      scope.toggleRosterEntry = function (e) {
        if (!e) { return; }
        e._open = !e._open;
        scope.open = null;
      };

      // The pool names pickable for one entry's name dropdown: the pushed pool (custom + built-ins) minus the
      // names already taken by OTHER entries, so a pick can never collide (names are identity keys). The
      // entry's own current name stays listed (shown selected).
      scope.rosterNameOpts = function (e) {
        var taken = {};
        (scope.form.aiRoster || []).forEach(function (other) {
          if (other !== e && other.name) { taken[other.name] = true; }
        });
        return (scope.data.aiPoolNames || []).filter(function (name) { return !taken[name]; });
      };
      // Pick a roster name from the pool (object-property write). Options already exclude names taken by
      // other entries, so no duplicate is possible.
      scope.pickRosterName = function (e, name) {
        scope.open = null;
        if (e) { e.name = name; }
      };

      // The DATA index of an entry in form.aiRoster. The list is displayed alphabetically (orderBy in the
      // ng-repeat, R3) so the repeat's $index is the sorted position, NOT the data slot -- but the roll/save
      // GE calls and the "#n" slot label need the real array index (it maps to spawn/grid slots), so they go
      // through this instead of $index.
      scope.rosterIndexOf = function (e) {
        return (scope.form.aiRoster || []).indexOf(e);
      };
      // orderBy key for the alphabetical DISPLAY sort (R3): case-insensitive by name. Display only -- orderBy
      // returns a sorted view, the underlying form.aiRoster order (and the sent roster) is untouched.
      scope.nameSortKey = function (e) {
        return (e && e.name ? e.name : '').toLowerCase();
      };

      // Create (or completely re-roll) the roster: aiCount fresh entries, nothing excluded.
      scope.createRoster = function () {
        var spec = rosterRollSpec();
        spec.count = clampAiCount();
        spec.mode = 'create';
        spec.exclude = [];
        geLuaArg('roll_ai_roster', JSON.stringify(spec));
      };

      // Count changed with an existing roster (applied on blur/Enter, the panel's number-field
      // convention): fewer -> tail entries drop; more -> new entries are rolled in, names unique against
      // the kept ones. Existing entries stay untouched (decision 7). Without a roster the count only
      // sizes the next Create.
      scope.applyRosterCount = function () {
        var count = clampAiCount();
        var roster = scope.form.aiRoster || [];
        if (!roster.length || roster.length === count) { return; }
        if (count < roster.length) {
          roster.splice(count);
          return;
        }
        var spec = rosterRollSpec();
        spec.count = count - roster.length;
        spec.mode = 'extend';
        spec.exclude = rosterNames();
        // Keep the new entries' colours distinct from the kept ones too (ADR-0047 round 3).
        spec.excludeColors = rosterColors();
        geLuaArg('roll_ai_roster', JSON.stringify(spec));
      };

      scope.$on('BeamCompAiRoster', function (event, payload) {
        scope.$evalAsync(function () {
          var entries = ((payload && payload.entries) || []).map(function (e) {
            return { name: e.name, car: e.car, carLabel: e.carLabel, color: e.color };
          });
          if (payload && payload.mode === 'extend') {
            scope.form.aiRoster = (scope.form.aiRoster || []).concat(entries);
          } else {
            scope.form.aiRoster = entries;
            // Auto-expand the list on a fresh Create so the generated AI are visible at once (ADR-0047
            // round 3); the Hide toggle still collapses it. Not on extend -- the list is already open.
            scope.rosterOpen = true;
          }
          scope.form.aiCount = scope.form.aiRoster.length || scope.form.aiCount;
          scope.rosterHint = '';
        });
      });

      // Re-draw one entry's name from the pool (unique against the rest). If the drawn name carries a
      // preferred car that applies under the current settings, the GE sends the car along (decision 4).
      // Takes the entry object (the list is sorted for display, so $index is not the data slot).
      scope.rerollRosterName = function (e) {
        var i = scope.rosterIndexOf(e);
        if (i < 0) { return; }
        var spec = rosterRollSpec();
        spec.index = i;
        spec.exclude = rosterNames();
        geLuaArg('reroll_ai_name', JSON.stringify(spec));
      };
      scope.$on('BeamCompAiRosterName', function (event, payload) {
        scope.$evalAsync(function () {
          var e = payload && (scope.form.aiRoster || [])[payload.index];
          if (!e) { return; }
          e.name = payload.name;
          if (payload.car) {
            e.car = payload.car;
            e.carLabel = payload.carLabel;
          }
          // A drawn pool name's preferred colour always applies (ADR-0047 round 3, no compliance gate).
          if (payload.color) { e.color = payload.color; }
        });
      });

      // Re-roll one entry's car through the spawn chain. A manual override by intent, so the GE bypasses
      // the name's preferred car here (it would pin the button to a single result). Takes the entry object
      // (the list is sorted for display, so $index is not the data slot).
      scope.rerollRosterCar = function (e) {
        var i = scope.rosterIndexOf(e);
        if (i < 0) { return; }
        var spec = rosterRollSpec();
        spec.index = i;
        geLuaArg('reroll_ai_car', JSON.stringify(spec));
      };
      scope.$on('BeamCompAiRosterCar', function (event, payload) {
        scope.$evalAsync(function () {
          var e = payload && (scope.form.aiRoster || [])[payload.index];
          if (!e || !payload.car) { return; }
          e.car = payload.car;
          e.carLabel = payload.carLabel;
        });
      });

      // Manual car pick per row (the tourClasses per-row dropdown pattern: pass the entry object -- the
      // option list is a NESTED ng-repeat, so $index there is the option index).
      scope.pickRosterCar = function (e, model) {
        scope.open = null;
        if (model === 'host') {
          e.car = 'host';
          e.carLabel = "host's car";
          return;
        }
        e.car = model;
        e.carLabel = modelLabel(model);
        if (model) { geLuaArg('request_car_configs', model); }
      };
      scope.pickRosterConfig = function (e, config) {
        scope.open = null;
        var model = scope.rosterModelOf(e);
        if (!model || model === 'host') { return; }
        e.car = config ? (model + ':' + config) : model;
        var configName = '';
        (scope.configsByModel[model] || []).some(function (c) {
          if (c.config === config) { configName = c.name; return true; }
          return false;
        });
        e.carLabel = modelLabel(model) + (config ? ' - ' + (configName || config) : '');
      };
      scope.rosterConfigOpts = function (e) {
        var model = scope.rosterModelOf(e);
        var list = (model && model !== 'host' && scope.configsByModel[model]) || [];
        return [{ v: '', label: 'stock' }].concat(list.map(function (c) {
          return { v: c.config, label: c.name };
        }));
      };
      // Reroll one entry's config/type (ADR-0047 amendment R2): a manual per-field roll, so it is a fresh
      // random pick from this model's known configs (incl. stock), distinct from the current when possible.
      // Pure JS on the loaded config list -- the model is fixed, so no compliance/GE round-trip is needed.
      scope.rerollRosterConfig = function (e) {
        var opts = scope.rosterConfigOpts(e);
        if (!opts.length) { return; }
        var current = scope.rosterConfigOf(e);
        var pick = opts[Math.floor(Math.random() * opts.length)].v;
        if (opts.length > 1) {
          while (pick === current) {
            pick = opts[Math.floor(Math.random() * opts.length)].v;
          }
        }
        scope.pickRosterConfig(e, pick);
      };
      // The display name of a roster entry's config, resolved from the same options the dropdown shows
      // (mirrors classConfigLabel) -- 'stock' for none, the raw key as fallback.
      scope.rosterConfigLabel = function (e) {
        var value = scope.rosterConfigOf(e);
        var list = scope.rosterConfigOpts(e);
        for (var i = 0; i < list.length; i++) {
          if (list[i].v === value) {
            return list[i].label;
          }
        }
        return value || 'stock';
      };

      // Colour is an opaque, unrestricted token from the client-known palette, so the swatch pick and the
      // reroll are pure JS (no GE round-trip, unlike the car which needs the vehiclespecs chain). The
      // '#'-prefixed CSS value for a swatch / the row's current colour.
      scope.rosterSwatchStyle = function (hex) {
        return { 'background-color': '#' + hex };
      };
      scope.pickRosterColor = function (e, hex) {
        if (e) { e.color = hex; }
      };
      // Reroll one entry's colour: a random palette colour distinct from the current one when possible.
      // A manual override, so -- like the car reroll -- it deliberately ignores any preferred colour.
      scope.rerollRosterColor = function (e) {
        var palette = scope.data.aiPalette || [];
        if (!palette.length) { return; }
        var pick = palette[Math.floor(Math.random() * palette.length)];
        if (palette.length > 1) {
          while (pick === e.color) {
            pick = palette[Math.floor(Math.random() * palette.length)];
          }
        }
        e.color = pick;
      };

      // Done (ADR-0048): the Change-panel's close button just collapses the per-entry editor. The pool is a
      // dev-authored, ship-fixed file now -- there is no save-to-pool path (the transient car/type/colour
      // edits apply to this race only and never write back). e._open is an object-property write.
      scope.doneRosterEntry = function (e) {
        if (!e) { return; }
        e._open = false;
      };

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (BeamCompSetupData arrives back via the $on above). Also pull the
      // remembered form (BeamCompSetupForm) so a reopen restores the last race's settings.
      scope.refresh();
      geCall('request_setup_form');
      geCall('request_championship');
      geCall('request_tournament');
      geCall('request_race_phase');
      // Prefetch configs for the fresh-form default tournament classes (ADR-0042): the per-class config
      // dropdown options resolve from configsByModel, so without this the default etk800 rows show an empty
      // option list until their model is re-picked. UX only -- the tournament still starts with these cars
      // regardless (buildTourClasses reads cls.config directly). Mirrors the form-restore prefetch above.
      (scope.form.tourClasses || []).forEach(function (c) {
        if (c.car) {
          geLuaArg('request_car_configs', c.car);
        }
      });
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
// module, so a shared directive name would double-fire (and could reach other apps' markup). BeamCompGridEditor
// carries the same logic under bcGridFit; the two apps share no code by design (kept in ES5 to match the
// surrounding CEF/AngularJS file).
angular.module('beamng.apps').directive('bcSetupFit', [function () {
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
