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
//
// The form is autosaved to GE on every change (debounced), not just on Close: a UI timeout/reload
// destroys this scope without ever running close(), which used to throw away the whole race setup. The
// panel also heartbeats to GE once a second, so GE can put it back after such a reload dropped the app
// (bug setup-panel-settings-survive-ui-reload).
angular.module('beamng.apps')
.directive('beamCompSetup', ['$interval', '$timeout', function ($interval, $timeout) {
  // How long after the last form change the panel pushes the form to GE (ms). Each save serialises the
  // whole form and costs a bngApi round-trip, so it is slow enough to collapse a burst of typing or
  // clicking into one write, and fast enough that a UI reload can lose nothing that matters.
  var AUTOSAVE_DELAY = 700;

  // How long after the last keystroke in the AI Count field the new count applies to the roster (ms).
  // A debounce, NOT a per-keystroke apply: typing your way from 4 to 12 passes through "1", and acting on
  // that would splice eight entries away for good and then roll eleven fresh ones. Blur and Enter still
  // apply immediately, so this only bounds how long a purely typed change waits.
  var ROSTER_COUNT_DELAY = 500;

  // The two race modes (ADR-0013). There is no 'auto' entry any more: the panel learns the track's own
  // type (BeamCompRaceMeta) and preselects the matching mode, marked '(recommended)' by rebuildModeOpts.
  // A preselection, not a lock -- the other mode stays pickable, which is the only thing that makes the
  // word "recommended" mean anything.
  var MODE_OPTS = [{ v: 'sprint', label: 'sprint' }, { v: 'circuit', label: 'circuit' }];

  // What a dropdown head shows when the form holds a value no option carries. 'race' has never been
  // picked yet; 'mode' is the deliberate unknown-track fallback, where the empty value still means what
  // it has always meant on the wire -- send no mode and let the client derive it at start.
  var HEAD_FALLBACK = { race: 'select…', mode: 'track default' };

  // Static enum options (value + label). Dynamic lists (race/car/grid/config) are built from GE pushes.
  var STATIC_OPTS = {
    mode: MODE_OPTS,
    orderMode: [{ v: 'entry', label: 'entry' }, { v: 'random', label: 'random' },
      { v: 'last', label: 'last result' }, { v: 'pwr', label: 'power/weight' },
      { v: 'quali', label: 'qualifying' }],
    // The qualifying's OWN start order (ADR-0044 amendment): the base order used INSIDE a quali, shown only
    // for order=quali. random (default = today) or the previous race's finishing order.
    qualiStart: [{ v: 'random', label: 'random' }, { v: 'last', label: 'last result' }],
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

  // The name of `raceId`'s default grid in a {name, race, isDefault} list, or '' when it has none. The
  // server holds the one-default-per-race invariant (grid_store.ensure_default), so at most one matches.
  // Shared by the grid dropdown and by the hover help that names the grid a race starts on.
  function defaultGridName(grids, raceId) {
    var list = grids || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].race === raceId && list[i].isDefault) {
        return list[i].name;
      }
    }
    return '';
  }

  // A BeamNG input control as a person would write it: the engine stores bindings lower-cased and
  // space-separated ('insert', 'ctrl insert'), which reads as a key on a keyboard once capitalised and
  // joined with '+'. Empty for an unbound action, and every caller must treat that as "say no key at all"
  // -- a guessed key in a tooltip is worse than none, because people believe it.
  function keyLabel(control) {
    if (typeof control !== 'string' || !control) {
      return '';
    }
    return control.trim().split(/\s+/).map(function (part) {
      return part.charAt(0).toUpperCase() + part.slice(1);
    }).join('+');
  }

  // ----- Hover help copy (ADR-0049) -----------------------------------------------------------------
  // One entry per control, rendered by bcSetupTip at the bottom of this file after a deliberate hover.
  // The markup carries only the key (bc-setup-tip="tip('orderMode')"), so these read as a set and can be
  // proof-read as one.
  //
  // STYLE, tightened after the first in-game round: short everyday words; say what the control does and
  // what changes if you touch it; then stop. No mechanism (when a list is built, how a value is resolved),
  // no sentence whose job is to justify a design decision, and nothing about the reader's likely intent --
  // this is read by an admin standing in the game, not by the next developer.
  //
  // Every line is still written from the code that implements it (buildOverrides here, race/*.lua,
  // server/main.lua). Where behaviour could not be pinned down with confidence the narrower true sentence
  // is written instead of the helpful guess, because a tooltip that asserts something false is worse than
  // none -- people believe it.
  //
  // An entry may be a FUNCTION of the scope where the useful answer depends on live state (see scope.tip).
  var TIPS = {
    // --- Toolbar ---
    settings: 'Settings for this panel. They are not part of the race.',
    includeDeprecated: 'Also list races from the old quickrace source. They still work, but they are no '
      + 'longer maintained, so they are hidden by default.',
    force: 'Start the race even when the check says the track cannot do it. The race may behave oddly.',
    tooltips: 'Show these help boxes when the mouse rests on a control. Applies to the grid editor too, '
      + 'and is remembered between sessions.',

    // --- Basics ---
    race: 'The track this race runs on. Pick it first -- everything below applies to it.',
    // The track's own type is knowable here, so it is shown rather than hidden behind a word. When it is
    // not known (no race picked, still being looked up, or a race that cannot be parsed) the panel sends
    // no mode at all and the game decides at the start -- which is what this says.
    mode: function (scope) {
      var base = 'Sprint runs the route once and finishes at the end. Circuit runs laps and finishes back '
        + 'at the start line. ';
      if (!scope.form.race) {
        return base + 'Pick a race and the one it is built as is filled in for you.';
      }
      var recommended = scope.recommendedMode();
      if (!recommended) {
        return base + 'This track has not said which it is, so the game decides when the race starts.';
      }
      return base + 'This track is built as a ' + recommended + ', so that is preselected. You can still '
        + 'pick the other one.';
    },
    laps: 'How many laps the race runs. Leave it empty to use the track\'s own lap count.',
    reverse: 'Drive the route backwards. Only tracks that come with a reverse route accept this; the rest '
      + 'are refused unless you also set Force.',

    // --- Vehicles ---
    carModel: 'The car everyone drives. "keep own" leaves each player in the car they are already in. '
      + 'Picking one car ignores the power and weight limits below.',
    carConfig: 'Which factory version of that car to spawn.',
    carRandomTrim: 'Give each drawn car a random factory version instead of the standard one.',
    carNoBigCars: 'Leave buses, trucks and vans out of the draw, going by weight.',
    restrictVehicles: 'Limit which cars may race, by power and weight. Does nothing when everyone drives '
      + 'the same fixed car.',
    maxhp: 'Turn away cars with more power than this. Empty means no limit.',
    maxpwr: 'Turn away cars with more horsepower per kilo than this. It catches light quick cars that a '
      + 'plain power limit lets through. Empty means no limit.',
    minkg: 'Turn away cars lighter than this. Empty means no limit.',
    maxkg: 'Turn away cars heavier than this. Empty means no limit.',
    orderMode: 'Who starts where on the grid. A running championship or class-drop sets this itself.',
    orderLockedChampionship: 'The running championship builds the grid from its points table, so this '
      + 'picker does nothing. Set Tournament mode to off to get it back.',
    orderLockedTournament: 'The running class-drop builds the grid from each driver\'s class, so this '
      + 'picker does nothing. Set Tournament mode to off to get it back.',
    qualiStart: 'The order drivers go out in for qualifying. The race grid comes from the qualifying '
      + 'result, not from this.',
    qualiMinutes: 'How long qualifying runs. Very short or very long values are pulled back into range.',
    qualiPreset: 'A common qualifying length.',
    orderRev: 'Flip the order, so the fastest start at the back.',
    // Names the grid this race actually starts on. The Edit button next to it is how that is changed, so
    // the sentence points at it instead of explaining what a default grid is.
    grid: function (scope) {
      var name = defaultGridName(scope.data.grids, scope.form.race);
      if (!name) {
        return 'Which saved grid the cars line up on. This race has none yet, so the game lines them up '
          + 'by itself. Edit builds one.';
      }
      return 'Which saved grid the cars line up on. This race normally uses "' + name + '". Edit builds '
        + 'or changes one.';
    },
    editGrid: 'Open the grid editor for the selected race. This panel stays open.',

    // --- Assists ---
    // These four name the key the assist really sits on, read from the game's own bindings. When nothing
    // is bound the key is left out and the game's own name for the control is given instead -- a guessed
    // key would be worse than none.
    recover: function (scope) {
      var key = keyLabel((scope.data.assistKeys || {}).recover);
      return 'Lets drivers put a stuck or flipped car back on the track during the race. They hold '
        + (key || 'the game\'s "Repair / Rewind (alternate version)" key') + ' to do it.';
    },
    recoverSecs: function (scope) {
      var key = keyLabel((scope.data.assistKeys || {}).recover);
      return 'How long ' + (key || 'the key') + ' has to be held before the car is moved, so a stray tap '
        + 'costs nothing.';
    },
    repair: function (scope) {
      var key = keyLabel((scope.data.assistKeys || {}).repair);
      return 'Lets drivers fix a damaged car during the race, where it stands. They hold '
        + (key || 'the game\'s "Repair / Rewind" key') + ' to do it.';
    },
    repairSecs: function (scope) {
      var key = keyLabel((scope.data.assistKeys || {}).repair);
      return 'How long ' + (key || 'the key') + ' has to be held before the car is fixed, so a stray tap '
        + 'costs nothing.';
    },

    // --- Start ---
    f1Start: 'Start the race on five red lights instead of a plain countdown. They go out after a short '
      + 'random wait, and moving before they do costs the penalty below.',
    jumpPenalty: 'Seconds added to the final time of anyone who moves before the lights go out.',

    // --- AI ---
    aiEnabled: 'Add computer drivers to the race. They line up with everyone else and drive against you.',
    aiCount: 'How many computer drivers race, 1 to 16. Lowering it drops the last ones and leaves the rest '
      + 'alone.',
    aiPreset: 'How good the computer drivers are. It fills in the values under Advanced.',
    aiCar: 'What the computer drivers drive. "default" gives each of them the car that suits them. '
      + 'Changing this gives the whole field new cars but keeps their names and colours.',
    aiRandomTrim: 'Give each AI car a random factory version instead of the standard one.',
    aiNoBigCars: 'Leave buses, trucks and vans out of the AI draw, going by weight.',
    rosterToggle: 'Show the drivers, so you can change them one by one.',
    rollAll: 'Draw a whole new set of drivers -- new names, cars and colours. This also changes who starts '
      + 'where.',
    rosterName: 'Pick this driver from the name list. A name brings its own car and colour with it. Names '
      + 'already taken are not offered.',
    rosterNameRoll: 'Draw another free name, with the car and colour that belong to it.',
    rosterCarShown: 'The car this driver spawns in. Use Change to pick another.',
    rosterChange: 'Open this driver\'s car, version and colour. What you set here counts for this race '
      + 'only.',
    rosterTypeShown: 'The factory version this car spawns as.',
    rosterCar: 'The car for this one driver.',
    rosterCarRoll: 'Draw a different car for this driver.',
    rosterConfig: 'The factory version of this driver\'s car.',
    rosterConfigRoll: 'Draw a different version of the car this driver already has.',
    rosterColor: 'The paint this driver spawns in, so you can tell them apart on track and in the '
      + 'standings.',
    rosterColorRoll: 'Draw another colour.',
    rosterDone: 'Fold this driver away again. Nothing is thrown away.',
    aiAdvanced: 'Show the driving values behind the difficulty setting.',
    aiRoute: 'How the computer drivers find their way. "snap" keeps them on the road network, "direct" '
      + 'follows the race line exactly -- useful where a track has no roads to follow.',
    aiAggr: 'How hard they fight for position, 0 to 1. Empty uses the value from the difficulty setting, '
      + 'shown greyed out in the field.',
    aiSkill: 'How cleanly and quickly they drive, 0 to 1. Empty uses the value from the difficulty '
      + 'setting.',
    aiRubber: 'How much they speed up when behind and ease off when ahead, 0 to 1. Higher keeps the field '
      + 'together.',
    aiAvoid: 'Let them steer around other cars instead of driving through them.',

    // --- Tournament ---
    tourMode: 'Run several races as one contest. Only one format at a time -- and picking off really ENDS '
      + 'the one that is running, it does not just hide it.',
    champStatus: 'The championship running on the server right now.',
    champPreset: 'How finishing places turn into points.',
    champOrder: 'How the next grid is built from the points table. It takes effect at once and overrides '
      + 'Start order.',
    champQualiMinutes: 'How long qualifying runs before each championship race.',
    champReset: 'Set every score back to zero. The championship keeps running -- to stop it, set Mode to '
      + 'off.',
    tourStatus: 'The class-drop tournament running on the server right now.',
    classHead: 'One step of the ladder, fastest at the top. Win a race and you drop a step; win in the '
      + 'slowest class and you win the tournament.',
    classKindCar: 'Make this class one fixed car that everyone in it drives.',
    classKindCap: 'Make this class a power limit instead, so drivers keep different cars.',
    classRemove: 'Remove this step. The ladder needs at least two.',
    classCar: 'The car everyone in this class drives.',
    classConfig: 'Which factory version of that car.',
    classMaxhp: 'Power limit for this class. Empty falls back to the horsepower-per-kilo limit.',
    classMaxpwr: 'Horsepower-per-kilo limit for this class.',
    addClass: 'Add another step below the current ones, up to six.',
    tourOrder: 'How the grid is built for each tournament race.',
    tourReset: 'Put everyone back in the fastest class and start the ladder again. The tournament keeps '
      + 'running -- to stop it, set Mode to off.',

    // --- Presets ---
    presetSave: 'Save everything on this panel under a name you can load again later.',
    presetLoad: 'Show the setups saved for this map.',
    presetName: 'What to call this setup. A name that already exists is overwritten.',
    presetConfirm: 'Save the setup under this name.',
    presetRow: 'Load this setup. It fills in the fields but starts nothing.',
    presetDelete: 'Delete this saved setup. Click twice -- there is no undo.',

    // --- Footer ---
    prepare: 'Apply every setting and put the cars on the grid. Drivers are held there until you press '
      + 'Start Race.',
    startRace: 'Let them go -- the countdown runs and the race starts. Closes this panel.',
    close: 'Hide this panel. Your settings stay and come back when you open it again.',
    cancelRace: 'Throw the race away: nobody is scored, and the cars and props are removed. Use this when '
      + 'a race has gone wrong.',
    endRace: 'End the race now and score it as it stands. The final standings are shown and the cars stay '
      + 'on the map.',
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
  // order, plus (once AI is toggled on) 4 hard AI on their file-preferred car + colour (ADR-0048) that
  // avoid each other. These differ from bare /race (entry order, no AI car); the session form-restore
  // (BeamCompSetupForm) overrides them after a race has been set up.
  function freshForm() {
    return {
      race: '', mode: '', laps: '', reverse: false, force: false, includeDeprecated: false,
      carModel: '', carConfig: '', maxhp: '', maxpwr: '', maxkg: '', minkg: '', restrictVehicles: false,
      // Composable player random-car axes (carModel='random'): a random compliant trim, and exclude
      // big/heavy vehicles. Both default ON (parity with the AI freshForm defaults), sent as explicit
      // booleans so a saved preset round-trips the admin's choice.
      carRandomTrim: true, carNoBigCars: true,
      orderMode: 'random', orderRev: false, qualiStart: 'random', qualiMinutes: 5, grid: '',
      f1Start: false, jumpPenalty: 15,
      recover: true, recoverSecs: '', repair: true, repairSecs: '',
      aiEnabled: false, aiCount: 4, aiPreset: 'hard', aiCar: '', aiRoute: '', aiAdvanced: false,
      aiAggr: '', aiSkill: '', aiRubber: '', aiAvoid: true,
      // Named AI roster (ADR-0047): [{name, car, carLabel, color}]. LIVE since the 2026-07-29 amendment --
      // ticking aiEnabled fields it and the three AI-car settings re-roll its cars, so there is no Create
      // button and no "ticked but empty" state to fall into. Session-restored with the form AND saved in a
      // preset (ADR-0047 amendment 2026-07-18): a stored non-empty roster is restored verbatim, never
      // re-rolled and never spawned by the restore itself.
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
  // fields and the roster verbatim WITHOUT firing any live command (championshipCmd/tournamentCmd), roll or
  // spawn: a loaded non-empty roster is the saved field itself and spawns at race start exactly as saved.
  // The live .active state stays server-driven. Kept as a (currently empty) list so a future must-exclude
  // field has an obvious home.
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

  // The model key inside a roster entry's car token: 'host' for the host sentinel, '' when unset, else
  // the part before the first ':' (the token is model[:config]). One reader for the token shape, shared
  // by the scope accessor and the config prefetch below.
  function modelOfCarToken(car) {
    if (!car) {
      return '';
    }
    return car === 'host' ? 'host' : String(car).split(':')[0];
  }

  // The car models of a roster ([{car}] entries) and of the class-drop class rows ([{car}]), as plain
  // model keys for prefetchConfigs.
  function rosterModels(entries) {
    return (entries || []).map(function (e) { return modelOfCarToken(e && e.car); });
  }
  function classModels(classes) {
    return (classes || []).map(function (c) { return c && c.car; });
  }

  // ----- The tooltip help switch (ADR-0049) --------------------------------------------------------
  // Persisted in localStorage rather than through GE, and that choice was verified before it was made:
  // BeamNG's CEF keeps a disk-backed leveldb for the local:// origin (BeamMP's own chat history lives
  // there across restarts), and the engine's own UI apps in this very Angular module -- SimpleTrip,
  // IndicatedAirspeed -- persist their preferences exactly this way, under exactly this key shape.
  //
  // Both BeamComp panels run at the same origin, so this ONE key governs both and the grid editor needs
  // no relay, no message channel and no GE state. This key MUST stay in step with STORAGE_KEY in
  // bcSetupTip at the bottom of this file and in the grid editor's bcGridTip.
  //
  // Known limit, accepted: the CEF profile lives under the user folder's temp/, which the game's own
  // userFolderCleanupFilters.json marks deleteDuringCleanup, and each game version gets a fresh folder.
  // A cache clear or a version bump therefore forgets the choice -- and lands on ON, the helpful state.
  var TOOLTIP_KEY = 'apps:beamComp.tooltips';

  // Absent means ON: a fresh profile, or one whose CEF cache was just cleared, gets help rather than
  // silence. Only the explicit '0' turns it off.
  function readTooltipPref() {
    try {
      return window.localStorage.getItem(TOOLTIP_KEY) !== '0';
    } catch (e) {
      return true;
    }
  }

  function writeTooltipPref(enabled) {
    try {
      window.localStorage.setItem(TOOLTIP_KEY, enabled ? '1' : '0');
    } catch (e) {
      // A CEF without usable storage just does not remember the choice; everything else still works.
    }
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

  // Ask GE for the configs of each given car model, so everything that resolves out of the configsByModel
  // cache -- the per-race, per-class and per-roster-row Type dropdowns and their labels -- has real
  // options instead of a lone 'stock' and a raw config key. Blanks and the 'host'/'random' sentinels are
  // not models, and a model repeated across the list is requested once, so a full roster of 16 AI on one
  // model costs one round-trip rather than 16.
  //
  // Cached models are deliberately re-requested: a reply for the CURRENTLY selected car model also
  // refreshes scope.data.configs, which the per-race Config dropdown reads, so skipping a warm model
  // would leave that dropdown empty on a restore.
  function prefetchConfigs(models) {
    var requested = {};
    (models || []).forEach(function (model) {
      if (!model || model === 'host' || model === 'random' || requested[model]) {
        return;
      }
      requested[model] = true;
      geLuaArg('request_car_configs', model);
    });
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

  // The grey placeholder of an OPTIONAL number field: "<value> (default)" (e.g. "5 (default)"), so an
  // empty field names the value that actually applies instead of just saying "default". CEF renders a
  // placeholder grey by itself -- no CSS involved.
  //
  // The numbers are pushed by GE (BeamCompSetupData), so `fallback` -- the field's original placeholder
  // text -- covers the window before that push lands and any value GE does not carry. The panel never
  // invents a default it was not told.
  function defaultHint(value, fallback) {
    var n = num(value);
    return n === undefined ? fallback : n + ' (default)';
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
    // The qualifying's own start order (ADR-0044 amendment): only for order=quali; nested in the order
    // block, known value only. The server defaults an absent/unknown value to random (byte-identical to the
    // chat path), so this is safe to always send when quali is chosen.
    if (form.orderMode === 'quali') {
      o.order.qualiStart = form.qualiStart;
    }
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

    // AI gate (ADR-0047 + the 2026-07-29 live amendment): the "AI opponents" checkbox is the gate. An `ai`
    // block still needs a non-empty roster, but the panel now keeps the roster filled by itself (ticking
    // rolls one), so "ticked yet nothing spawns" -- the footgun that cost the Create button its job -- is
    // no longer reachable. The typed /race chat path is unaffected. The roster length IS
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
      // aiDefaults / assistHoldDefault carry the GE-side default values behind the optional number fields
      // (see defaultHint): aiDefaults = {presets: {<preset>: {aggr, skill, rubber}}, fallback: '<preset>'}
      // from race/ai.lua, assistHoldDefault = the recover/repair hold seconds from race/start.lua.
      // assistKeys = {repair, recover} -- the KEYBOARD keys BeamNG's two recovery actions are bound to on
      // this machine (race/lock.lua assist_controls). Either field may be missing, in which case the help
      // names the command and no key: a guessed key would be worse than none.
      scope.data = { races: [], cars: [], grids: [], configs: [], presets: [], aiPalette: [], aiPoolNames: [],
        aiDefaults: null, assistHoldDefault: null, assistKeys: {} };
      // raceId -> {closed} for races GE has described, filled lazily as races are selected (see raceMeta
      // below). A race that is absent here has NOT been reported as open -- it has not been asked about
      // yet, or GE could not parse it -- and the panel must not act as if it knew.
      scope.raceMetaById = {};
      scope.form = freshForm();
      scope.open = null;       // name of the currently open dropdown, or null
      scope.prepared = false;  // true after Confirm & Build Grid: the race is staging, so reveal Start Race
      scope.presetName = '';       // the name field of the revealed Save row (ADR-0037 amendment)
      scope.selectedPreset = '';   // the preset last loaded: marks its row and prefills the save name
      // The Presets section is collapsed to its two buttons and reveals what each action needs (ADR-0037
      // amendment 2026-07-30). The LOAD reveal is just `open === 'preset'` and needs no field of its own;
      // the save row is not a dropdown, so it gets one. Neither flag lives in `form`, so no session
      // restore and no loaded preset can ever open this section by itself.
      scope.presetSaveOpen = false;  // the Save name row is revealed
      scope.armedPreset = '';        // name of the preset whose row delete is armed for its confirming click
      scope.opts = angular.extend({ race: [], carModel: [], carConfig: [], grid: [], aiCar: [],
        rosterCar: [], preset: [] }, STATIC_OPTS);
      scope.rosterOpen = false;  // the roster list is collapsed by default (ADR-0047)
      scope.championship = { active: false };  // latest server-broadcast championship state (ADR-0040)
      scope.tournament = { active: false };    // latest server-broadcast class-drop tournament state (ADR-0042)
      scope.configsByModel = {};               // model -> configs cache for the per-class config dropdowns (ADR-0042)
      scope.phase = 'lobby';                   // latest GE-pushed race phase, gates the race-stop controls (ADR-0038)
      // The hover-help switch (ADR-0049), restored from localStorage so it survives a game restart.
      //
      // An OBJECT property, and that is load-bearing rather than stylistic: the gear menu's contents sit
      // inside an ng-if (open === 'settings'), which gives them their own CHILD SCOPE. An ng-model on a
      // bare primitive would be written onto that child scope, shadow this one, and be thrown away with
      // the menu on every close -- the same trap app.html documents for the preset name row and
      // toggleRoster documents below. The two toggles beside it are safe only because form.* is a path.
      //
      // Deliberately NOT in `form`: that object is serialised into the session blob and into
      // server-persisted race presets, and a per-player display preference does not belong in a per-race
      // payload (and must not join the $$hashKey-sensitive blob).
      scope.ui = { tooltips: readTooltipPref() };

      // Session-autosave state. The panel links with freshForm() and only THEN pulls the remembered blob
      // (request_setup_form -> BeamCompSetupForm, async), so the form watcher must stay muted until that
      // reply has been applied: a save inside that window would write these DEFAULTS over the good stored
      // blob and lose the settings for good -- worse than the bug it fixes.
      var autosaveArmed = false;   // true once the initial restore (or its confirmed absence) has landed
      var autosaveTimer = null;    // pending debounced save, re-armed on every change
      var lastStoredJson = null;   // last blob handed to GE, so an unchanged form is never re-sent
      var phaseSeeded = false;     // the first phase push has run, so it can no longer touch `prepared`
      var gridsLoaded = false;     // a saved-grid list has arrived, so `data.grids` may be trusted as truth

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
      // Grids belong to a race, so the dropdown shows only the SELECTED race's grids (the GE push carries
      // the whole map as {name, race, isDefault}, so a race change re-filters locally -- no round-trip).
      //
      // There is no 'default' entry any more. It was a second way of saying the same thing: the server
      // resolves an omitted grid through defaults[map][race], which is exactly the grid already listed and
      // labelled '(default)', so both selections ended at the identical record. Now the default grid is
      // simply PRESELECTED and reads "<name> (default)"; a race with no saved grid at all offers the one
      // honest entry, "auto generated grid", which submits nothing and lands on the procedural layout.
      // The submitted grid= is therefore unchanged for every selection that still exists.
      //
      // A selection the new race does not have falls back to that race's default rather than being
      // dropped, otherwise a grid of the previously selected race would be submitted. An explicit pick is
      // never overwritten -- which does mean a pick is now a pin: re-pointing the race's default in the
      // editor no longer moves a panel that already holds a name.
      //
      // Only prune or preselect once a list has actually arrived: before that, `data.grids` is empty for
      // want of data, not because the race has no grids, and acting would wipe a restored form's choice.
      function rebuildGridOpts() {
        var raceGrids = (scope.data.grids || []).filter(function (g) {
          return g && g.race === scope.form.race;
        });
        scope.opts.grid = raceGrids.length
          ? raceGrids.map(function (g) {
            return { v: g.name, label: g.isDefault ? g.name + ' (default)' : g.name };
          })
          : [{ v: '', label: 'auto generated grid' }];
        if (!gridsLoaded) {
          return;
        }
        if (!raceGrids.length) {
          scope.form.grid = '';
          return;
        }
        var stillValid = raceGrids.some(function (g) { return g.name === scope.form.grid; });
        if (!stillValid) {
          scope.form.grid = defaultGridName(scope.data.grids, scope.form.race) || raceGrids[0].name;
        }
      }
      // The mode the SELECTED track itself declares (ADR-0013): a closed loop is a circuit, anything else
      // a sprint. Empty while the track type is unknown -- no race picked, its description still in
      // flight, or a race GE could not parse. Never guessed: calling an unknown track a sprint would turn
      // a lap race into a single pass without anyone noticing.
      scope.recommendedMode = function () {
        var meta = scope.raceMetaById[scope.form.race];
        if (!meta) {
          return '';
        }
        return meta.closed ? 'circuit' : 'sprint';
      };

      // Mark the track's own mode in the dropdown. Rebuilt rather than watched, so the label is a plain
      // string the existing labelFor renders in the head for free.
      function rebuildModeOpts() {
        var recommended = scope.recommendedMode();
        scope.opts.mode = MODE_OPTS.map(function (o) {
          return { v: o.v, label: o.v === recommended ? o.label + ' (recommended)' : o.label };
        });
      }

      // Preselect the track's own mode, but only into an EMPTY choice: an explicit pick -- or one restored
      // from the session or a preset -- is the admin's and is never overwritten. Picking a different race
      // clears the field (see pick), which is what lets the new track's own mode land.
      function applyRecommendedMode() {
        rebuildModeOpts();
        if (!scope.form.mode) {
          scope.form.mode = scope.recommendedMode();
        }
      }

      function rebuildConfigOpts() {
        scope.opts.carConfig = [{ v: '', label: 'default' }].concat(
          (scope.data.configs || []).map(function (c) { return { v: c.config, label: c.name }; }));
      }
      function rebuildPresetOpts() {
        scope.opts.preset = (scope.data.presets || []).map(function (p) { return { v: p, label: p }; });
      }

      // Serialise the current form into the JSON blob GE remembers for the session (store_setup_form) or
      // the server persists as a preset -- the write counterpart of applyStoredForm below. angular.toJson
      // (not JSON.stringify) drops every $$-prefixed key at any depth, so ng-repeat's $$hashKey tracking
      // ids on the roster and the tournament class rows never reach the blob, and cleanRoster strips the
      // transient _open editor flag on top. That hygiene matters far more now than it did for the old
      // close-only save: an autosave almost always runs while those lists are rendered, and a foreign
      // tracking id riding back into a restored roster is a known breakage (bug
      // preset-multirace-roster-not-created).
      function formJson(excludeKeys) {
        var copy = angular.extend({}, scope.form);
        (excludeKeys || []).forEach(function (k) { delete copy[k]; });
        copy.aiRoster = cleanRoster(copy.aiRoster);
        return angular.toJson(copy);
      }

      // Apply a stored form JSON string (the session-restore blob OR a loaded preset) over a fresh form,
      // then re-sync the option lists and prefetch the configs the restored cars need. Shared by
      // BeamCompSetupForm and BeamCompSetupPresetData so a loaded preset restores EXACTLY like the session
      // form (ADR-0037 amendment). The merge over freshForm is a plain assignment -- it sets the format
      // fields (tourMode/champ*/tour*) and the AI roster verbatim but never fires championshipCmd/
      // tournamentCmd or a spawn, so a loaded preset pre-fills everything without auto-starting it
      // (ADR-0037/0047 amendments 2026-07-18). An OLDER preset that predates this simply lacks those keys,
      // so they fall back to freshForm defaults (tourMode 'off', empty roster).
      //
      // It is also the one path that must NOT wake the live AI watchers (ADR-0047 amendment 2026-07-29):
      // it replaces scope.form wholesale, so every restored AI setting would look like a change the admin
      // just made and re-roll the roster the restore had just brought back -- on every preset load and
      // every UI reload. The tail below settles that explicitly.
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
        // The restored race decides which grids are offered, and a stored grid of another race (or one
        // deleted meanwhile) has to go -- but only once a grid list is actually on hand (see
        // rebuildGridOpts); otherwise the pending list push does it.
        rebuildGridOpts();
        // The restored race needs describing too, or the Mode row would sit on its unknown fallback for
        // the whole session after a panel reopen. A restored mode is kept as it stands -- applyRecommended
        // Mode only fills an empty one, which is what upgrades a form stored before this panel derived
        // the mode itself.
        requestRaceMeta(scope.form.race);
        applyRecommendedMode();
        // Re-sync the race list to the restored include-deprecated flag, then fetch, as one deduplicated
        // batch, the configs every restored car needs: the race's own model (so its config dropdown +
        // label resolve without clearing the stored config), each class row's car (ADR-0042) and each
        // roster entry's car (ADR-0047). UX only -- the stored tokens spawn regardless.
        scope.refresh();
        prefetchConfigs([scope.form.carModel].concat(
          classModels(scope.form.tourClasses), rosterModels(scope.form.aiRoster)));
        // Record the restored AI settings as already-acted-on before the digest reaches the live watcher
        // (see aiLive), so the restore itself can never re-roll. Then run the TWO deliberate exceptions by
        // hand: a form that enables AI but carries no roster -- an old preset saved before the roster
        // existed, or before Create was ever pressed -- gets one rolled now, so "AI opponents ticked"
        // means the same thing after a load as it does after a click; and a restored roster whose car is
        // no longer a race car gets that ONE car re-rolled (see repairRosterCars).
        syncAiLive();
        fieldRosterIfEmpty();
        repairRosterCars();
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
          // The default values behind the optional number fields (see defaultHint). Kept on a miss like
          // the palette above, so a partial/older GE push never blanks a hint the panel already has. The
          // hold is tested explicitly rather than with `||`, because a numeric default may legitimately be
          // falsy (0) and would otherwise be thrown away.
          scope.data.aiDefaults = (payload && payload.aiDefaults) || scope.data.aiDefaults;
          if (payload && payload.assistHoldDefault !== undefined && payload.assistHoldDefault !== null) {
            scope.data.assistHoldDefault = payload.assistHoldDefault;
          }
          // Kept on a miss like the palette above: an older GE that does not send the keys must leave the
          // ones we already have alone rather than blanking them back to "no key known".
          scope.data.assistKeys = (payload && payload.assistKeys) || scope.data.assistKeys || {};
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
          // The restore has landed -- or GE confirmed it has nothing stored (payload.form nil, which
          // applyStoredForm returns on). Either way the form on screen is now the session's truth, so the
          // autosave may write from here on. Arming inside the same digest task means the watcher's first
          // real fire is that restored form: a harmless write-back of exactly what GE just handed us,
          // normalised over freshForm.
          autosaveArmed = true;
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

      // The map's saved grids as {name, race, isDefault} (ADR-0023 amendment): server truth, kept whole so
      // the dropdown can re-filter on a race change without asking again.
      scope.$on('BeamCompSetupGrids', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.grids = (payload && payload.grids) || [];
          gridsLoaded = true;
          rebuildGridOpts();
        });
      });

      // Authoritative saved-preset list from the server (ADR-0037 amendment): the panel reflects it as
      // truth, not local state. Drop the current selection if it is gone (e.g. just deleted by anyone) --
      // and an armed row delete with it: a name that vanished and came back (deleted and re-saved by another
      // admin while this list stayed open) would otherwise render already-armed and delete on ONE click.
      scope.$on('BeamCompSetupPresets', function (event, payload) {
        scope.$evalAsync(function () {
          scope.data.presets = (payload && payload.names) || [];
          rebuildPresetOpts();
          if (scope.selectedPreset && scope.data.presets.indexOf(scope.selectedPreset) === -1) {
            scope.selectedPreset = '';
          }
          if (scope.armedPreset && scope.data.presets.indexOf(scope.armedPreset) === -1) {
            scope.armedPreset = '';
          }
        });
      });

      // One race's track metadata, answering a requestRaceMeta (ADR-0013 amendment). `closed` decides
      // sprint vs circuit, so it is only cached when GE actually reported a boolean -- a race GE could not
      // parse leaves the entry absent, and "absent" means unknown, never "open".
      scope.$on('BeamCompRaceMeta', function (event, payload) {
        scope.$evalAsync(function () {
          if (!payload || !payload.id || typeof payload.closed !== 'boolean') {
            return;
          }
          scope.raceMetaById[payload.id] = { closed: payload.closed };
          if (payload.id === scope.form.race) {
            applyRecommendedMode();
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
        return HEAD_FALLBACK[field] || value;
      };

      scope.pick = function (field, value) {
        scope.form[field] = value;
        scope.open = null;
        if (field === 'carModel') {
          onModelChange();
        }
        if (field === 'race') {
          // Grids are per race: the new race has its own set, and the old race's pick is no longer valid.
          rebuildGridOpts();
          // A mode chosen for the previous track says nothing about this one, so hand the choice back to
          // the new track. Its own mode lands here if it is already known, otherwise when GE answers.
          scope.form.mode = '';
          requestRaceMeta(value);
          applyRecommendedMode();
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

      // Ask GE to describe one race's track, unless it already has. Lazy per race, exactly like the
      // per-model config fetch below: the race list carries no geometry on purpose, and parsing a whole
      // map of races to learn one flag about one of them would be absurd.
      function requestRaceMeta(raceId) {
        if (raceId && !scope.raceMetaById[raceId]) {
          geLuaArg('request_race_meta', raceId);
        }
      }

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

      // ----- Placeholder hints for the optional number fields ---------------------------------------
      // Each of these fields may be left empty, and the value that then applies is decided GE-side. The
      // placeholder names it ("5 (default)") instead of the old useless "default" / "-"; the numbers ride
      // in with the setup data (see scope.data above), so nothing here duplicates a Lua constant.

      // Recover / repair hold: race/start.lua's ASSIST_DEFAULT_HOLD_SECONDS. One constant for both fields.
      scope.holdHint = function () {
        return defaultHint(scope.data.assistHoldDefault, 'default');
      };

      // Aggression / skill / rubberband: race/ai.lua's PRESETS, so the hint FOLLOWS the Preset dropdown --
      // `key` is 'aggr', 'skill' or 'rubber'.
      //
      // The dropdown's empty option ("default") sends no preset at all, and GE then resolves the fallback
      // preset -- but that is also the one branch where an aiRace track's own authored defaults can
      // override aggression and skill (race/ai.lua resolve_params). Those are per-race data the panel has
      // no view of, so it shows the fallback preset's numbers: exact whenever the track authors none (the
      // common case), indicative otherwise.
      scope.aiParamHint = function (key) {
        var defaults = scope.data.aiDefaults || {};
        var presets = defaults.presets || {};
        var preset = presets[scope.form.aiPreset || defaults.fallback] || {};
        return defaultHint(preset[key], '-');
      };

      // The gear menu's hover-help switch. Writing straight through on change (rather than on close) is
      // what makes it reach an already-open grid editor at once: that panel re-reads the stored flag on
      // every hover, so there is nothing to notify.
      scope.setTooltips = function () {
        writeTooltipPref(scope.ui.tooltips);
      };

      // Hover help text by key (ADR-0049), read by bc-setup-tip. An unknown key yields '' and the
      // directive then shows nothing at all -- a missing tooltip is a far better failure than an empty
      // box hanging off a control.
      //
      // A TIPS entry may be a FUNCTION of the scope instead of a fixed string (ADR-0049 amendment): some
      // help only makes sense against live state -- which mode the track recommends, which grid the race
      // currently starts on, which key the assists are actually bound to. The directive evaluates its
      // expression inside the hover delay, not at link time, so a function entry is re-read on every
      // hover and can never go stale. No watcher is involved, so an idle panel still costs nothing.
      scope.tip = function (key) {
        var entry = TIPS[key];
        if (typeof entry === 'function') {
          entry = entry(scope);
        }
        return entry || '';
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
      //
      // Reveal-on-demand (amendment 2026-07-30): the section shows only Save + Load until one of them is
      // pressed, because a name field matters only for a save and the list only for a load. The three
      // actions, their GE entry points and their payloads are unchanged -- this is a rearrangement of the
      // controls over them.

      // Reveal (or cancel) the Save name row. The name is prefilled with the loaded preset's at REVEAL time
      // only, not as a binding: updating the preset you just loaded is then one click on the confirm instead
      // of retyping its name exactly, while typing over it stays free and no watcher can fight it.
      scope.togglePresetSave = function () {
        scope.presetSaveOpen = !scope.presetSaveOpen;
        if (scope.presetSaveOpen) {
          scope.presetName = scope.selectedPreset || '';
        }
      };

      // Write the preset, then collapse the row and clear the name. Optimistic on purpose: save_preset is
      // fire-and-forget like every other action in this panel, so there is no ack to wait for -- and the
      // feedback exists anyway (the server chats "saved preset '<name>'" and echoes the name list, so the
      // new name shows up in the Load list by itself). The trim guard is the backstop behind the confirm
      // button's ng-disabled, and it is what makes Enter on an empty field inert.
      scope.savePreset = function () {
        var name = (scope.presetName || '').trim();
        if (!name) {
          return;
        }
        geLuaArg('save_preset', JSON.stringify({ name: name, form: formJson(PRESET_EXCLUDE_KEYS) }));
        scope.presetSaveOpen = false;
        scope.presetName = '';
      };

      // Clicking a name in the list loads it: select + dispatch + close, so a load is two clicks from
      // collapsed (Load, then the name). There is no separate Load-the-selection step any more; the
      // selection survives only to mark the row and to prefill the save name. The guard covers the
      // 'no saved presets' placeholder row.
      scope.pickPreset = function (value) {
        if (!value) {
          return;
        }
        scope.selectedPreset = value;
        scope.open = null;
        geLuaArg('load_preset', value);
      };

      // Two-step delete on the row's own button: the first click ARMS that row (the button becomes "sure?"
      // in the danger colour), only a second click on the armed button deletes. Deliberately unlike the
      // one-click × on a tournament class -- that drops a form row you can re-add, this destroys a saved
      // setup on the server with no undo, and it sits on a row that LOADS when clicked. Both clicks must
      // stop the event, or the row's own ng-click would load the very preset being deleted. Arming a row
      // disarms every other one for free, because the state is the armed NAME, not a flag per row.
      scope.deletePreset = function (name, ev) {
        if (ev) {
          ev.stopPropagation();
        }
        if (!name) {
          return;
        }
        if (scope.armedPreset !== name) {
          scope.armedPreset = name;
          return;
        }
        scope.armedPreset = '';
        geLuaArg('delete_preset', name);
      };

      // Closing the list disarms every row: an armed delete left behind would fire on the FIRST click the
      // next time the list opened. The list is closed from three places (toggle, pickPreset and the
      // outside-click handler), so watch the state they all end up in instead of patching each one.
      scope.$watch(function () { return scope.open; }, function (now) {
        if (now !== 'preset') {
          scope.armedPreset = '';
        }
      });

      // Confirm & Build Grid (the button; this handler keeps the `prepare` name, see the label comment in
      // app.html): send the structured request -- the race spawns + enters staging. Reveals Start Race.
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
        // Remember the current form so the next open restores it within the session (ADR-0037). The
        // autosave below already keeps GE current; this stays the explicit, immediate end point.
        storeForm();
        geCall('close_setup');
      };

      // ----- Session autosave (bug setup-panel-settings-survive-ui-reload) ---------------------------
      // GE remembers the form for the session (ADR-0037), but the ONLY save used to be the Close button
      // above -- so a UI timeout/reload, which destroys this scope without ever running close(), threw
      // away everything configured since the panel was opened (only the tournament fields came back,
      // rebuilt from live server state). Every form change now saves itself, debounced, so GE's copy is
      // at most AUTOSAVE_DELAY behind what is on screen.

      function storeForm() {
        var json = formJson();
        if (json === lastStoredJson) {
          return;  // nothing GE does not already have (e.g. a change that vanishes in the clean shape)
        }
        lastStoredJson = json;
        geLuaArg('store_setup_form', json);
      }

      function scheduleStore() {
        if (autosaveTimer) {
          $timeout.cancel(autosaveTimer);
        }
        // invokeApply false: the save is a pure side effect (a GE call), so it must not kick off another
        // digest -- it is the digest that feeds the watcher below.
        autosaveTimer = $timeout(function () {
          autosaveTimer = null;
          storeForm();
        }, AUTOSAVE_DELAY, false);
      }

      // Deep watch, because the nested rows (AI roster, class ladder) are edited in place and a shallow
      // watch would miss them. angular.equals ignores $$-prefixed keys, so ng-repeat merely rendering
      // those lists never counts as a change. A loaded preset (applyStoredForm) is a legitimate change
      // and is saved like any other; the arm gate only bars the pre-restore window.
      scope.$watch(function () { return scope.form; }, function () {
        if (!autosaveArmed) {
          return;
        }
        scheduleStore();
      }, true);

      scope.$on('$destroy', function () {
        // Flush a pending save, so a clean removal (Close, or BeamNG's own app-container X) loses
        // nothing. A hard UI reload kills the page without ever firing $destroy -- that case is what the
        // debounce window bounds.
        if (autosaveTimer) {
          $timeout.cancel(autosaveTimer);
          autosaveTimer = null;
          storeForm();
        }
      });

      // Championship state (ADR-0040): GE pushes the current table + settings on open and on every change.
      // Sync the section's dropdowns to the active settings so the controls reflect reality, not stale form.
      // GE pushes the race phase on every transition and on request (request_race_phase). Gates the
      // race-stop controls so they appear only while a race is active (ADR-0038 amendment).
      scope.$on('BeamCompSetupPhase', function (event, payload) {
        scope.$evalAsync(function () {
          scope.phase = (payload && payload.phase) || 'lobby';
          // The Start Race button is revealed by Confirm & Build Grid (scope.prepared), which is link-time
          // state -- so a panel restored after a UI reload would show a staged race with no way to start it.
          // The FIRST phase push after link (request_race_phase, pulled below) therefore seeds prepared
          // from server truth: a race already in staging IS prepared. One-shot, so a live panel behaves
          // exactly as before -- someone else's later prepare changes nothing here.
          if (!phaseSeeded) {
            phaseSeeded = true;
            scope.prepared = scope.prepared || scope.phase === 'staging';
          }
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

      // ----- Named AI roster (ADR-0047; live since the 2026-07-29 amendment) ------------------------
      // The roster is a LIVE artefact, not something the admin creates: ticking "AI opponents" fields one,
      // the three AI-car settings re-roll the CARS of the entries that are there, the Count field resizes
      // it on a debounce (round 2), and "Roll all" inside the expanded editor is the deliberate fresh-field
      // action. Names -- and with them the spawn/grid slots and every identity keyed off them -- change
      // only through Roll all, a per-entry pick/roll, or the tail a lower count drops.
      // Every roll happens GE-side through the SAME resolution chain the spawn uses, so the shown car is
      // the spawned car. Rolls are async: the GE replies via the BeamCompAiRoster* events below.

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

      // The panel's AI-count range applied to a READABLE field value: 1..16, with anything that floors to 0
      // falling back to the fresh-form default of 4. Pure -- writing the result back into the field is the
      // caller's call, and the debounced live path deliberately does not (see applyTypedRosterCount).
      function clampedAiCount(value) {
        var count = Math.floor(value || 0);
        return Math.max(1, Math.min(16, count || 4));
      }

      // Resolve the count field to the number that applies, and write it back so the field shows what
      // actually happened. For the paths where a write-back is right: the blur/Enter apply and the
      // fresh-roster rolls.
      //
      // An UNREADABLE field answers with the roster's current length. Blank is the common case -- clearing
      // the box to type a new number is a natural gesture now that the count is live -- but the input's own
      // min="1"/max="16" validators also hand us undefined for 0, 99 or -3, so the panel genuinely cannot
      // tell what was meant. It must therefore not act, and answering with the length the roster already
      // has makes every caller a no-op by construction: resizeRosterTo sees no difference and does nothing
      // (an 8-AI field stays 8 instead of being cut to 4), and Roll all re-rolls the field at its own size.
      // Only with no roster at all is there nothing to preserve, and the fresh-form default of 4 applies.
      function clampAiCount() {
        var typed = num(scope.form.aiCount);
        scope.form.aiCount = typed === undefined
          ? ((scope.form.aiRoster || []).length || 4)
          : clampedAiCount(typed);
        return scope.form.aiCount;
      }

      // The model key of a roster entry's car token ('host' for the host sentinel, '' when unset).
      scope.rosterModelOf = function (e) {
        return modelOfCarToken(e && e.car);
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
      // Pick a roster name from the pool (ADR-0048): set the name immediately for instant feedback, then load
      // that driver's car + colour from the file via the GE pinned resolve (pick_ai_name). The reply
      // (BeamCompAiRosterName) always overwrites this row's car/carLabel/colour with the pinned driver's --
      // default AI-car mode -> preferred car + colour; random mode -> a rolled car + the preferred colour --
      // so the name determines car+colour on pick (Q2/Q3). The DATA index rides along (the list is
      // display-sorted, so $index is not the data slot), like the reroll calls. Options already exclude names
      // taken by other entries, so no duplicate is possible.
      scope.pickRosterName = function (e, name) {
        scope.open = null;
        if (!e) { return; }
        e.name = name;
        var i = scope.rosterIndexOf(e);
        if (i < 0) { return; }
        var spec = rosterRollSpec();
        spec.index = i;
        spec.name = name;
        geLuaArg('pick_ai_name', JSON.stringify(spec));
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

      // Every roster roll carries a monotonic token that GE echoes back untouched. The replies arrive
      // through guihooks with NO request correlation, and the panel now rolls by ITSELF on a settings
      // change -- so two rolls really can be in flight at once and land out of order, and one can still be
      // in flight when the admin unticks the box. Only the newest request's reply may write: last request
      // wins. (Trade-off: a count-driven extend that is still in flight when a car setting changes is
      // dropped, so the count field may briefly read higher than the roster until the next blur/Enter.)
      var rosterRollToken = 0;

      function sendRosterRoll(spec) {
        rosterRollToken += 1;
        spec.token = rosterRollToken;
        geLuaArg('roll_ai_roster', JSON.stringify(spec));
      }

      // A completely fresh roster: aiCount new entries with new names, cars and colours, replacing
      // whatever is there. Nothing excluded -- this IS the reset.
      function rollFreshRoster() {
        var spec = rosterRollSpec();
        spec.count = clampAiCount();
        spec.mode = 'create';
        spec.exclude = [];
        sendRosterRoll(spec);
      }

      // Re-roll the CARS of the existing entries, keeping their names (and with them their spawn/grid
      // slots) and their colours. One GE call for the whole set, resolved per name through the same chain
      // a fresh roll uses -- so switching the AI car back to "default" hands every driver their preferred
      // car again (ADR-0048), which a per-entry re-roll (a manual override by definition) would not.
      // Cars set by hand via Change… are NOT protected: a live re-roll overwrites them, by decision.
      function rerollRosterCars() {
        var names = rosterNames();
        if (!names.length) {
          return;
        }
        var spec = rosterRollSpec();
        spec.mode = 'cars';
        spec.names = names;
        sendRosterRoll(spec);
      }

      // Field a roster because AI was just enabled (by a tick or by a restored form) -- but ONLY when
      // there is none. An existing roster is a possibly hand-tuned field that a mis-click on the checkbox
      // must not destroy; Roll all is the deliberate way to replace it.
      function fieldRosterIfEmpty() {
        if (!scope.form.aiEnabled || (scope.form.aiRoster || []).length) {
          return;
        }
        rollFreshRoster();
      }

      // Roll all: the former Create/Re-create, now living inside the expanded editor as the explicit
      // "give me a new field" action. A scope METHOD for the same reason toggleRoster is one -- the button
      // renders under an ng-if, i.e. on a child scope.
      scope.rollAllRoster = function () {
        rollFreshRoster();
      };

      // ----- The live settings ------------------------------------------------------------------------
      // Exactly four form fields drive a ROLL on their own: the enable checkbox and the three AI-CAR axes.
      // The omissions are deliberate. The player restriction fields (carModel/maxhp/maxkg/
      // restrictVehicles…) feed a roll too, through buildRosterPolicy -- but re-rolling on every keystroke
      // in a caps field would be churn, and "the roster was rolled before the caps changed" is exactly
      // what the panel did before, so nothing regresses. The AI difficulty Preset is not a roll input at
      // all (rosterRollSpec never reads it). The Count field IS live too (round 2) but stays out of this
      // watcher on purpose: it resizes the roster instead of re-rolling its cars, and it needs a debounce
      // that a digest-driven watcher cannot give it -- see resizeRosterTo below.
      function aiLiveState() {
        return {
          enabled: !!scope.form.aiEnabled,
          car: scope.form.aiCar || '',
          randomTrim: !!scope.form.aiRandomTrim,
          noBigCars: !!scope.form.aiNoBigCars,
        };
      }

      // The state the panel has already acted on. Comparing against THIS instead of against the watcher's
      // own previous value is what makes the restore path safe: applyStoredForm records the restored
      // settings here (syncAiLive) before the digest reaches the watcher, so they arrive already handled
      // and no preset load or UI reload can re-roll the roster it just restored. A value-level
      // suppression rather than a timing flag -- it cannot leak and cannot be left set.
      var aiLive = null;
      function syncAiLive() {
        aiLive = aiLiveState();
      }

      scope.$watch(aiLiveState, function (now) {
        var prev = aiLive;
        aiLive = now;
        if (!prev) {
          return;  // the watcher's registration run (oldVal === newVal): nothing has changed yet
        }
        if (now.enabled && !prev.enabled) {
          fieldRosterIfEmpty();
          return;
        }
        if (!now.enabled) {
          return;  // AI off: the checkbox gates the spawn, the roster is simply left alone
        }
        if (now.car !== prev.car || now.randomTrim !== prev.randomTrim
            || now.noBigCars !== prev.noBigCars) {
          rerollRosterCars();
        }
      }, true);

      // ----- The AI count, live on a debounce (round 2) -----------------------------------------------
      // Resize the roster to `count` entries. Fewer -> the TAIL drops and every kept entry stays exactly as
      // it was (name, car AND colour); more -> only the missing entries are rolled in, unique against the
      // kept names and colours. Without a roster the count only sizes the next roll. These semantics are
      // the user's own words and do not change -- round 2 changed nothing here but the trigger.
      function resizeRosterTo(count) {
        var roster = scope.form.aiRoster || [];
        if (!roster.length || roster.length === count) {
          return;
        }
        if (count < roster.length) {
          roster.splice(count);
          // A shrink talks to nobody, so it has to retire what is in flight by hand: an extend whose reply
          // landed afterwards would concat its entries onto the roster we just shortened. Bumping the token
          // is the same "last action wins" rule sendRosterRoll applies, minus the request.
          rosterRollToken += 1;
          return;
        }
        var spec = rosterRollSpec();
        spec.count = count - roster.length;
        spec.mode = 'extend';
        spec.exclude = rosterNames();
        // Keep the new entries' colours distinct from the kept ones too (ADR-0047 round 3).
        spec.excludeColors = rosterColors();
        sendRosterRoll(spec);
      }

      var rosterCountTimer = null;

      function cancelRosterCountApply() {
        if (rosterCountTimer) {
          $timeout.cancel(rosterCountTimer);
          rosterCountTimer = null;
        }
      }

      // The debounced apply. Two things it must NOT do, both of which would fight the user mid-edit:
      //   * act on an unreadable field. Clearing the box to type a new number leaves ng-model undefined
      //     (as do 0/99/-3, which the input's own min/max reject), and a count the panel cannot read is
      //     not a count the admin asked for. Nothing applies -- and unlike the blur path there is nothing
      //     to write back either, because the user is still typing.
      //   * write the clamped value back into the field. That belongs on blur/Enter (clampAiCount), where
      //     the user has finished typing; doing it here would rewrite the digits under the cursor.
      // Also inert once AI is off: the checkbox hides the field but a keystroke from just before the untick
      // can still have a timer pending, and unticking leaves the roster alone by decision.
      function applyTypedRosterCount() {
        var typed = num(scope.form.aiCount);
        if (typed === undefined || !scope.form.aiEnabled) {
          return;
        }
        resizeRosterTo(clampedAiCount(typed));
      }

      // Typing in the Count field: apply after a short pause, re-armed on every keystroke, so only the
      // number the user stopped on ever resizes the field.
      scope.rosterCountTyped = function () {
        cancelRosterCountApply();
        // No invokeApply:false here (unlike the autosave): this callback mutates the roster, so it needs
        // the digest that $timeout runs by default or a shrink would not reach the rendered list.
        rosterCountTimer = $timeout(function () {
          rosterCountTimer = null;
          applyTypedRosterCount();
        }, ROSTER_COUNT_DELAY);
      };

      // Blur / Enter: apply at once, and settle the field itself now that the user has finished typing.
      // Cancels any pending debounce so tabbing out cannot apply the same change a second time. An
      // unreadable field resizes nothing here either -- clampAiCount answers with the roster's own length,
      // which makes the resize a no-op and puts the real number back in the box.
      scope.applyRosterCount = function () {
        cancelRosterCountApply();
        resizeRosterTo(clampAiCount());
      };

      scope.$on('$destroy', function () {
        cancelRosterCountApply();  // a pending apply must not fire into a dead scope
      });

      // Apply a 'cars' reply: one {name, car, carLabel} per name the request carried. Matched by NAME, not
      // by position -- the request was built from a snapshot, and a per-entry name pick or roll landing in
      // between would otherwise paint a car onto the wrong AI. An entry the reply does not mention keeps
      // its car, and no colour is touched: a colour belongs to the driver, not to the AI-car settings.
      function applyRosterCars(entries) {
        var rolledByName = {};
        entries.forEach(function (e) {
          if (e.name) {
            rolledByName[e.name] = e;
          }
        });
        (scope.form.aiRoster || []).forEach(function (entry) {
          var rolled = entry.name && rolledByName[entry.name];
          if (!rolled || !rolled.car) {
            return;
          }
          entry.car = rolled.car;
          entry.carLabel = rolled.carLabel;
        });
        prefetchConfigs(rosterModels(entries));
      }

      scope.$on('BeamCompAiRoster', function (event, payload) {
        scope.$evalAsync(function () {
          // A stale reply -- an older roll answering a question the panel no longer asks (see
          // rosterRollToken) -- or one that landed after the box was unticked, which for a create would
          // resurrect the field the admin just switched off.
          if (!payload || payload.token !== rosterRollToken || !scope.form.aiEnabled) {
            return;
          }
          var entries = (payload.entries || []).map(function (e) {
            return { name: e.name, car: e.car, carLabel: e.carLabel, color: e.color };
          });
          if (payload.mode === 'cars') {
            applyRosterCars(entries);
            return;
          }
          if (payload.mode === 'extend') {
            scope.form.aiRoster = (scope.form.aiRoster || []).concat(entries);
          } else {
            scope.form.aiRoster = entries;
          }
          scope.form.aiCount = scope.form.aiRoster.length || scope.form.aiCount;
          // The rolled cars are models the panel may never have probed. Without their configs each row's
          // Type field falls back to the raw config key and its Type dropdown holds nothing but 'stock',
          // so the type cannot be changed at all (bug setup-dropdowns-sort-by-display-name). On 'extend'
          // only the new entries need it -- the kept ones were fetched when they were rolled.
          prefetchConfigs(rosterModels(entries));
        });
      });

      // ----- Restored rosters: re-roll a car that is no longer offered (ADR-0047 amendment 2026-08-09) --
      // A preset (or the session blob) saved before the vehicle filter can carry a roster car BeamComp no
      // longer offers -- a simplified-traffic model is the case that prompted this. ADR-0047's rule is that
      // a stored roster is restored VERBATIM and never rolled; this is the one carved-out exception to it,
      // and it is as narrow as it can be: only a token GE reports as a KNOWN non-race model is replaced,
      // through the same roll chain a normal roll uses, so the repaired row is an ordinary rolled row.
      //
      // GE decides, not the panel, and that is the whole design. scope.opts.rosterCar arrives
      // asynchronously from the carlist.options reply, so a membership test here could run against a list
      // that has not landed yet and "repair" every entry of a hand-tuned roster. GE reads the engine
      // synchronously, so there is no window in which the answer can be wrong and nothing to sequence.
      //
      // Runs on EVERY applyStoredForm, and deliberately regardless of aiEnabled: an unticked roster is
      // still persisted and still spawns the moment the box is ticked again (ticking never re-rolls a
      // non-empty roster), so a stale token there is just as live. In memory only -- the stored preset is
      // left alone and the fix persists on the admin's next Save.
      var rosterRepairToken = 0;

      function repairRosterCars() {
        var entries = (scope.form.aiRoster || [])
          .filter(function (e) { return e && e.name && e.car; })
          .map(function (e) { return { name: e.name, car: e.car }; });
        if (!entries.length) {
          return;
        }
        rosterRepairToken += 1;
        var spec = rosterRollSpec();
        spec.token = rosterRepairToken;
        spec.entries = entries;
        geLuaArg('repair_ai_roster', JSON.stringify(spec));
      }

      // Apply a repair reply: it carries ONLY the rows GE actually replaced. Matched by NAME like
      // applyRosterCars, and applied only while the row still holds the exact token GE vetted (`from`) --
      // a manual pick or a per-row roll that landed in between owns the row now. Names and colours are
      // never touched: this fixes a car, it does not re-field the roster.
      scope.$on('BeamCompAiRosterRepair', function (event, payload) {
        scope.$evalAsync(function () {
          if (!payload || payload.token !== rosterRepairToken) {
            return;
          }
          // GE sends this event only when it has repairs, so a list is expected -- but an empty Lua table
          // would cross the bridge as {} rather than [], and asking is cheaper than trusting that.
          if (!angular.isArray(payload.entries)) {
            return;
          }
          var fixByName = {};
          payload.entries.forEach(function (e) {
            if (e && e.name) { fixByName[e.name] = e; }
          });
          var changed = [];
          (scope.form.aiRoster || []).forEach(function (entry) {
            var fix = entry.name && fixByName[entry.name];
            if (!fix || !fix.car || fix.from !== entry.car) {
              return;
            }
            entry.car = fix.car;
            entry.carLabel = fix.carLabel;
            changed.push(entry);
          });
          if (changed.length) {
            // The replacement is a model this panel may never have probed -- same rule as every other
            // car-changing path (bug setup-dropdowns-sort-by-display-name).
            prefetchConfigs(rosterModels(changed));
          }
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
            // A drawn/pinned name brings its own preferred car, so this row's model can change here too
            // -- fetch its configs like a manual pick does (bug setup-dropdowns-sort-by-display-name).
            prefetchConfigs(rosterModels([e]));
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
          // The re-rolled car is a fresh model, so its configs are fetched exactly like a manual pick's
          // (bug setup-dropdowns-sort-by-display-name).
          prefetchConfigs(rosterModels([e]));
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

      // UI-presence heartbeat (the init.lua setup watchdog, bug setup-panel-settings-survive-ui-reload).
      // Tell GE this panel is alive on link and once a second after. If GE stops hearing it while the
      // panel is meant to be open -- an engine/BeamMP UI reload dropped our late-mounted app
      // (ADR-0008/0012) -- GE re-adds the app once, and its fresh link restores the form via the pull
      // below. Mirrors the HUD's note_hud_alive: bngApi is the core UI global (not an injected service,
      // see the header) and typeof-guarded so a miss is inert.
      function noteAlive() {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.note_setup_alive() end');
        }
      }
      noteAlive();
      // count 0 (run forever), invokeApply false -- same reasoning as the autosave's $timeout: noteAlive
      // only talks to GE and touches no scope state, so it must not force a digest every second. With
      // the deep form watcher registered above, that digest would deep-compare the whole form (roster +
      // class rows) once a second for nothing.
      var heartbeat = $interval(noteAlive, 1000, 0, false);
      scope.$on('$destroy', function () {
        $interval.cancel(heartbeat);
      });

      // Pull the dataset now the directive is linked: a freshly-added app misses the open-time push, so it
      // asks GE for the lists itself (BeamCompSetupData arrives back via the $on above). Also pull the
      // remembered form (BeamCompSetupForm) so a reopen restores the last race's settings.
      // Own the mode option list from link on, so nothing ever reads the shared MODE_OPTS array. A fresh
      // form has no race yet, so this simply renders the two modes unmarked.
      rebuildModeOpts();
      scope.refresh();
      geCall('request_setup_form');
      geCall('request_championship');
      geCall('request_tournament');
      geCall('request_race_phase');
      // Prefetch configs for the fresh-form default tournament classes (ADR-0042): the per-class config
      // dropdown options resolve from configsByModel, so without this the default etk800 rows show an empty
      // option list until their model is re-picked. UX only -- the tournament still starts with these cars
      // regardless (buildTourClasses reads cls.config directly). Mirrors the form-restore prefetch above.
      prefetchConfigs(classModels(scope.form.tourClasses));
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

// Hover help: a delayed, in-DOM tooltip for one control (ADR-0049).
//
//   bc-setup-tip="tip('startOrder')"    an Angular expression that yields the help text
//
// NATIVE title= IS DEAD IN BEAMNG. The UI renders in an off-screen CEF and native tooltips are painted by
// the browser chrome, which an off-screen renderer does not have -- the same reason native <select> does
// not open here. This panel and the grid editor together carried 33 title= attributes with careful copy;
// not one was ever visible to a player. Do not reintroduce them: their existence proved nothing.
//
// The attribute is an EXPRESSION, parsed once and evaluated only on hover, so no watcher is created and an
// idle panel costs nothing (the bcSetupFit cost model). The copy itself lives in the TIPS table at the top
// of this file rather than in the markup, where ~70 multi-sentence strings would bury the template and
// could not be proof-read as a set.
//
// The name is app-unique for the reason bcSetupFit's and bcGridHold's are (see their headers): the two
// panels share the 'beamng.apps' module, so a generically named attribute directive would also claim the
// other panel's markup -- and being registered twice on one module, Angular would apply BOTH definitions
// to every match. BeamCompGridEditor carries the same logic under bcGridTip; the two apps share no code by
// design (kept in ES5 to match the surrounding CEF/AngularJS file).
//
// $parse and $timeout are INJECTED -- core services that cannot be missing, exactly like bcGridHold's.
// That is not in tension with this file's header: the never-inject rule is about bngApi specifically, a
// BeamNG-registered service whose absence would take the whole late-loaded directive down.
angular.module('beamng.apps').directive('bcSetupTip', ['$parse', '$timeout', function ($parse, $timeout) {
  var SHOW_DELAY = 1200;   // ms of DELIBERATE rest before help appears; crossing the panel shows nothing
  var GAP = 6;             // px between the control and its tooltip
  var EDGE_PAD = 8;        // px of clearance the tooltip keeps from the panel edge
  var ROOT_CLASS = 'bc-setup';
  // Shared with the grid editor: both apps run at the same local:// origin, so ONE key governs both
  // panels with no relay. Naming follows the engine's own UI apps (ui/modules/apps/SimpleTrip/app.js,
  // IndicatedAirspeed/app.js), which persist their preferences as 'apps:<appName>.<pref>'.
  var STORAGE_KEY = 'apps:beamComp.tooltips';

  // The tooltip currently on screen ({root, el, anchor}), or null. Shared across every instance of this
  // directive, which is what makes "only one at a time" true by construction rather than by bookkeeping:
  // every show hides whatever was up, so moving to a neighbouring control restarts the delay cleanly.
  var visible = null;

  // Read at SHOW time, deliberately not cached at link time: that is what lets the gear-menu switch reach
  // an already-open grid editor instantly, with no message channel. A getItem costs nanoseconds and only
  // runs on a real hover. Guarded and defaulting to ON -- if storage is unavailable, help is the safe way
  // to fail.
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
  // start off the left edge either. This is functional, not cosmetic -- .bc-setup clips with
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
    // The panel body scrolls (.bc-setup-scroll) while the box is anchored to the non-scrolling root, so a
    // scroll would leave the tooltip pointing at nothing. Capture phase: the scroll fires on that inner
    // element and does not bubble to document.
    document.addEventListener('scroll', hideTip, true);
  }

  return {
    restrict: 'A',
    link: function (scope, element, attrs) {
      var textOf = $parse(attrs.bcSetupTip);
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
        // must not kick off a digest -- this panel carries a deep watcher over the whole form, and paying
        // for it on every hover would be absurd.
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
      // control), which is what lets a greyed-out Cancel race / Start Race explain why it is locked --
      // the case where help matters most.
      element.on('mouseenter', arm);
      element.on('mouseleave', dismiss);
      element.on('mousedown', dismiss);
      element.on('click', dismiss);

      // jqLite drops this element's own listeners with it; the pending timer is ours to clear. The
      // tooltip is only taken down if THIS element is the one it describes -- the panel churns ng-if
      // rows constantly, and an unrelated row disappearing must not dismiss the help someone is reading.
      scope.$on('$destroy', function () {
        cancel();
        if (visible && visible.anchor === element[0]) {
          hideTip();
        }
      });
    },
  };
}]);
