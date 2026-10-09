// BeamComp Controls -- AngularJS directive (ADR-0061).
// The window /keys opens: where BeamComp's two in-race assists are bound, on EVERY device, drawn with
// the game's own binding glyphs -- and every chip is the button that opens BeamNG's controls settings.
// Nothing here writes a binding; the game's own page does, and what the player saves there applies to
// the whole game immediately.
//
// This is the first place BeamComp uses foreign UI code of the game rather than only its data channels,
// and BOTH touchpoints are version-coupled and fail SILENTLY:
//
//   * an Angular directive that does not exist renders as an unknown element -- an empty node, no error,
//     no warning, nothing on screen but a caption with a gap beside it;
//   * a route name neither router knows simply does nothing when clicked.
//
// That is the same trap the node-grabber block sat in for months (core_input_actionFilter accepts any
// action name, ADR-0017 / CLAUDE.md). So neither is assumed: each is PROBED, each degrades to something
// readable, and ONE log line into the client log names which case happened. The line names the SOURCE,
// not a count -- "2 of 2 rows rendered" would be just as happy with two empty <binding> nodes.
//
// THE JUMP HAS FOUR RUNGS (round 2, 2026-09-24). Round 1 took the route BeamNG's own Keys app takes and
// landed in the OLD Angular dialog, while a player walking there himself gets the NEW options UI. The new
// UI is reached through the Lua router, which lives on the GE side -- so rungs 1 and 2 are asked for
// there (beamcomp_init.controls_route / open_controls_bindings), where the route table can actually be
// read. Rung 3 is the legacy jump this app made in round 1; it is kept because it lands exactly on the
// action, so it is the old-fashioned fallback rather than a worse one. Rung 4 is no button at all.
//
// Data: the window draws from BeamNG's own InputBindingsChanged broadcast and asks for it once at link
// (core_input_bindings.notifyUI), exactly as the game's Keys app does. It keeps drawing live, so a player
// who rebinds and comes back sees the new key without reopening.
//
// Kept in ES5 to match the surrounding CEF/AngularJS files. The three BeamComp apps share no code by
// design; keyLabel below is the third copy of a formatter that exists in BeamCompSetup/app.js and (as
// key_label) in race/lock.lua -- see its own comment.
angular.module('beamng.apps')
.directive('beamCompControls', ['$injector', '$timeout', function ($injector, $timeout) {
  // BeamNG's LEGACY binding-edit dialog, defined in ui/entrypoints/main/main.js:393 with
  // params: {action: "", oldBinding: {}}. The last rung, not the first (see the header).
  var EDIT_ROUTE = 'menu.options.controls.bindings.edit';

  // How long to wait for GE's answer about the new UI's route before settling the one log line (ms).
  // The answer is a local guihook round-trip and arrives in a frame or two; this only bounds the case
  // where it never comes, so the line still says something instead of never being written.
  var ROUTE_ANSWER_TIMEOUT = 2000;

  // How long a capture may hold the player's controls hostage (ms). THE BACKSTOP, not the normal exit:
  // the normal exit is pressing a key (the capture ends itself) or right-clicking (see CANCEL_CONTROL).
  // This is what saves a player who armed a capture and then looked away -- BeamNG's own capture has no
  // limit at all, because it runs in a modal popup in a paused menu; ours runs over a moving car.
  // Long enough to reach for a wheel button, short enough not to strand anyone.
  var CAPTURE_TIMEOUT = 8000;

  // The cancel input: the RIGHT mouse button, and it is the only choice that costs nothing.
  // captureBinding blacklists exactly one input -- `mouse*` + `button1` (ui-vue/src/services/
  // controls.js:485) -- so it can never be recorded as a binding, which means using it to cancel takes
  // no key away from the player. Every other candidate (ESC and friends) IS capturable, so reserving it
  // would make that key unbindable through this window; a Cancel BUTTON is worse still, because the left
  // click that presses it is itself a capturable control.
  var CANCEL_DEVICE = 'mouse';
  var CANCEL_CONTROL = 'button1';

  // THE TWO ASSISTS, AND THE ONE PLACE THE CROSSING LIVES IN THIS APP.
  //
  // BeamComp's REPAIR sits on the game's plain `recover_vehicle`, BeamComp's RECOVER on
  // `recover_vehicle_alt` -- ADR-0017 decision 3, implemented in the VE forwarder
  // (lua/vehicle/extensions/beamcomp/init.lua on_recover_down) and crossed again in race/lock.lua and
  // server/main.lua. PAIRING `recover` WITH `recover_vehicle` BECAUSE IT READS MORE SENSIBLY SHOWS EVERY
  // PLAYER THE WRONG KEY. Do not "straighten" this table.
  //
  // `does` says what the assist does, in the same words the server's chat lines use, so the two surfaces
  // cannot drift into two different answers about the same key.
  var ASSISTS = [
    { label: 'Repair', does: 'Repairs your car.', action: 'recover_vehicle' },
    { label: 'Recover', does: 'Back to the last checkpoint.', action: 'recover_vehicle_alt' }
  ];

  // A BeamNG input control as a person would write it: the engine stores bindings lower-cased and
  // space-separated ('insert', 'ctrl insert'), which reads as a key once capitalised and joined with '+'.
  // Only the FALLBACK rendering uses this -- the game's own directive formats the control itself.
  // Same formatter as BeamCompSetup/app.js keyLabel() and race/lock.lua key_label(); a shared copy would
  // mean one app loading another app's file, which BeamNG's app loader does not do.
  function keyLabel(control) {
    if (typeof control !== 'string' || !control) {
      return '';
    }
    return control.trim().split(/\s+/).map(function (part) {
      return part.charAt(0).toUpperCase() + part.slice(1);
    }).join('+');
  }

  // Run one line of Lua on the GE side. bngApi is referenced as the core UI global and typeof-guarded,
  // NOT injected -- an injected BeamNG service that fails to resolve takes the whole late-loaded
  // directive down with it (same rule as the other two panels). Inert without it; never throws.
  function geLua(code) {
    if (typeof bngApi === 'undefined' || !bngApi.engineLua) {
      return;
    }
    bngApi.engineLua(code);
  }

  // Say something into the client log (UI -> GE), where every other BeamComp line lands. Routed through a
  // named GE function rather than a hand-built log() call so the tag lives on the Lua side and this app
  // cannot inject arbitrary Lua.
  //
  // Line breaks are STRIPPED, not escaped: the message rides inside a single-quoted Lua string, and Lua
  // refuses a literal line break inside one ("unfinished string") -- the whole chunk would be a syntax
  // error and the diagnostic would fail exactly where it is needed. The one message that is not a literal
  // of ours is an exception's text, which is where a line break would come from.
  function geNote(msg) {
    var flat = String(msg).replace(/[\r\n]+/g, ' ');
    var escaped = flat.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    geLua("if beamcomp_init then beamcomp_init.note_controls('" + escaped + "') end");
  }

  // PROBE 1 -- can we draw with the game's own <binding>? Returns null when yes, else the reason.
  //
  // Two conditions, not one, and the second is what makes this a probe rather than a gesture: Angular
  // registers a directive as the service '<name>Directive' (angular 1.5.8, $injector.has checks the
  // provider cache -- ui/lib/ext/angular/angular.js:4741), so the first answers whether it EXISTS. But the
  // directive's getBinding reads window.bngVue.controls on every repaint (options.js:974) and throws
  // without it, so a directive that exists is not yet a directive that can draw. Checking only the first
  // would wave through exactly the silent half of the failure.
  function directiveUnusable() {
    if (!$injector.has('bindingDirective')) {
      return "angular has no 'binding' directive";
    }
    if (!controlsStore() || typeof controlsStore().makeViewerObj !== 'function') {
      return 'window.bngVue.controls.makeViewerObj is missing';
    }
    return null;
  }

  // The game's own controls store, which it puts on `window` itself (ui-vue/src/main.js:209 ->
  // exposeControlsStore at :244). Read at call time, never cached: the Vue app assigns it during its own
  // startup, and a reference taken too early would be a permanent nil.
  function controlsStore() {
    return (window.bngVue && window.bngVue.controls) || null;
  }

  // PROBE 3 -- may we rebind here, or only show? Returns null when yes, else the reason.
  //
  // The four calls we need are all on the exposed store and all measured (ui-vue/src/main.js:244). They
  // are an UNDOCUMENTED surface the game exposes for its own UI, so every one of them is checked rather
  // than assumed -- when one disappears, this window degrades to what round 2 shipped (the chips open
  // the settings) instead of throwing on a click.
  function rebindUnusable() {
    var controls = controlsStore();
    if (!controls) {
      return 'window.bngVue.controls is missing';
    }
    var needed = ['captureBinding', 'addNewBinding', 'updateBinding', 'deleteBinding'];
    for (var i = 0; i < needed.length; i++) {
      if (typeof controls[needed[i]] !== 'function') {
        return 'window.bngVue.controls.' + needed[i] + ' is missing';
      }
    }
    return null;
  }

  // PROBE 2, RUNG 3 -- the LEGACY Angular dialog. Returns a rung or null.
  //
  // This is the jump round 1 shipped, demoted to last resort: measured in-game it lands in the old
  // Angular UI while the new one is what the player otherwise sees. It is kept rather than deleted
  // because it lands exactly on the clicked action, which the new UI cannot do at all -- so on a build
  // without the new router this is not a degraded jump, only an old-fashioned one.
  //
  // $state is resolved through $injector.get rather than injected, for the same reason bngApi is never
  // injected: a dependency that fails to resolve takes the whole directive down, and then the window is
  // gone instead of merely un-clickable. $state.get() is the actual existence question -- a $state.go onto
  // an unknown state is a silent no-op, which is the failure this whole construction exists to avoid.
  function legacyRung() {
    var state = null;
    if ($injector.has('$state')) {
      try {
        state = $injector.get('$state');
      } catch (e) {
        state = null;
      }
    }
    if (!state || typeof state.get !== 'function' || typeof state.go !== 'function') {
      return null;
    }
    var known = null;
    try {
      known = state.get(EDIT_ROUTE);
    } catch (e2) {
      known = null;
    }
    if (!known) {
      return null;
    }
    return {
      source: "the legacy angular dialog ('" + EDIT_ROUTE + "')",
      // Only this rung takes the in-game menu down first, exactly as the game's own Keys app does
      // (ui/modules/apps/Keys/app.js:42). The new-UI rung deliberately does NOT: MenuHide travels to
      // ui_menuManager.menuHide (main.js:1900 -> menuManager.lua:317), which NAVIGATES THE SAME LUA
      // ROUTER to the gameplay route -- a second transition in the opposite direction, fired a moment
      // before ours. The legacy dialog hangs off the other router, so there the two do not meet.
      go: function (scope, row, control) {
        scope.$emit('MenuHide', false);
        var params = {action: row.action, oldBinding: {}};
        if (control) {
          params.oldBinding = {control: control.key, device: control.device};
        }
        state.go(EDIT_ROUTE, params);
      }
    };
  }

  // RUNGS 1+2 -- the new options UI, reached through GE. `route` is the name GE resolved against the
  // router's own table, or '' when this build has none.
  //
  // No action and no oldBinding travel: the new UI has no deep link onto a single binding (its edit
  // dialog is a popup inside the bindings list, opened from that list's own handlers), so the honest
  // target is the controls category -- whose only subpage IS the bindings list. Owner's decision.
  function routerRung(route) {
    if (typeof route !== 'string' || route === '') {
      return null;
    }
    return {
      source: "the new options ui ('" + route + "')",
      go: function () {
        geLua('if beamcomp_init then beamcomp_init.open_controls_bindings() end');
      }
    };
  }

  // The two rows from one InputBindingsChanged payload (core/input/bindings.lua:686): one device entry per
  // connected device, each with contents.devicetype and contents.bindings = {{action, control, unused,
  // active}, ...}.
  function buildRows(data) {
    var devices = (data && data.bindings) || [];
    return ASSISTS.map(function (assist) {
      return {
        label: assist.label,
        does: assist.does,
        action: assist.action,
        controls: chipsFor(devices, assist.action)
      };
    });
  }

  // One chip per (device, control) pair the action holds -- ONE, however often the pair is stored.
  // Neither BeamNG's controls store nor its settings page refuses a second identical entry
  // (ui-vue/src/services/controls.js addNewBinding / updateBinding), so a player can own a duplicate this
  // window did not write. Showing it twice would offer two x buttons for what is one key; `copies` carries
  // the real number instead, so the one x can take every entry away (see scope.remove).
  //
  // The skip rule is race/lock.lua binding_for's, verbatim: `unused` marks a binding the engine disabled
  // for the seated vehicle, `active === false` one that is switched off -- showing either would name a key
  // that does nothing. A hidden entry still COUNTS towards `copies`: the x has to leave the pair really
  // gone. Unlike binding_for this keeps EVERY device rather than preferring the keyboard: that preference
  // exists because a chat line can only carry one key, and this window is the surface where the other
  // devices were the point.
  function chipsFor(devices, action) {
    var chips = [];
    var byPair = {};
    for (var d = 0; d < devices.length; d++) {
      var device = devices[d] || {};
      var list = (device.contents || {}).bindings || [];
      for (var b = 0; b < list.length; b++) {
        var bind = list[b] || {};
        if (bind.action !== action) { continue; }
        if (typeof bind.control !== 'string' || bind.control === '') { continue; }
        var pair = device.devname + '\0' + bind.control;
        var chip = byPair[pair];
        if (!chip) {
          chip = byPair[pair] = {
            // The devname ('keyboard0', 'xinput0'), not the devicetype: the controls store looks its
            // image pack up by devname (ui-vue/src/services/controls.js:1056) and falls back to the type
            // on its own, so this is the more precise of the two and never the worse one.
            device: device.devname,
            key: bind.control,
            label: keyLabel(bind.control),
            copies: 0
          };
        }
        chip.copies++;
        if (bind.unused !== true && bind.active !== false && chips.indexOf(chip) === -1) {
          chips.push(chip);
        }
      }
    }
    return chips;
  }

  // The tripwire for duplicates: every chip that stands for more than one stored entry, with its action,
  // device, control and count, verbatim. Null when there is none. This window refuses to write one (see
  // alreadyBound), so a line here names a pair from elsewhere: the game's own settings page, an edited
  // inputmap file, or this window before it checked.
  function duplicateNote(rows) {
    var found = [];
    for (var r = 0; r < rows.length; r++) {
      var chips = rows[r].controls;
      for (var c = 0; c < chips.length; c++) {
        if (chips[c].copies > 1) {
          found.push(rows[r].action + ' ' + pairText(chips[c].device, chips[c].key) + ' x' + chips[c].copies);
        }
      }
    }
    return found.length ? 'duplicate bindings, each shown once: ' + found.join('; ') : null;
  }

  // A (device, control) pair for the client log, VERBATIM: quoted, so a trailing space, a case difference
  // or a modifier spelt another way ('lshift insert' vs 'shift insert') is visible instead of being
  // smoothed over the way the game's glyph rendering smooths it.
  function pairText(devname, control) {
    return JSON.stringify(String(devname)) + ' ' + JSON.stringify(String(control));
  }

  // Every control `action` holds on device `devname`, verbatim and in payload order. Hidden entries
  // (`unused`, `active === false`) are included on purpose: writing next to a hidden copy is still a
  // duplicate, and the write log line names this list so a near-miss is readable.
  function boundControls(data, devname, action) {
    var devices = (data && data.bindings) || [];
    var out = [];
    for (var d = 0; d < devices.length; d++) {
      var device = devices[d] || {};
      if (device.devname !== devname) { continue; }
      var list = (device.contents || {}).bindings || [];
      for (var b = 0; b < list.length; b++) {
        var bind = list[b] || {};
        if (bind.action === action && typeof bind.control === 'string') {
          out.push(bind.control);
        }
      }
    }
    return out;
  }

  // Does `action` already hold exactly this (device, control) pair? The ONE case conflictsFor skips by
  // design, and the one neither the controls store nor the engine refuses on a write. Exact string
  // compare, the engine's own notion of "the same binding" (core/input/bindings.lua bindingListToDict
  // keys on control.."\0"..action). The same control on ANOTHER device is a different pair.
  function alreadyBound(data, devname, control, action) {
    return boundControls(data, devname, action).indexOf(control) !== -1;
  }

  // Which OTHER actions the captured control already runs, from the same payload the window draws from.
  // Read locally rather than through the store because it is the identical data (the store fills from
  // this broadcast) and because a window that shows a key must be able to say what else it does without
  // a second source that could disagree.
  //
  // Reported, never resolved: taking somebody's other binding away because it was in the way is exactly
  // the kind of silent damage this window must not do.
  function conflictsFor(data, devname, control, action) {
    var devices = (data && data.bindings) || [];
    var out = [];
    for (var d = 0; d < devices.length; d++) {
      var device = devices[d] || {};
      if (device.devname !== devname) { continue; }
      var list = (device.contents || {}).bindings || [];
      for (var b = 0; b < list.length; b++) {
        var bind = list[b] || {};
        if (bind.control !== control || bind.action === action) { continue; }
        if (bind.unused === true) { continue; }
        out.push(actionLabel(data, bind.action));
      }
    }
    return out;
  }

  // A readable name for an action. The payload carries a TRANSLATION KEY in actions[name].title, so the
  // translate filter is asked for the text -- through $injector, like everything else that might not be
  // there. A filter that is missing, or a key it does not know (it returns the key itself), falls back
  // to the raw action name: unlovely, but never a lie about which action is meant.
  function actionLabel(data, action) {
    var meta = (data && data.actions && data.actions[action]) || null;
    var key = meta && meta.title;
    if (typeof key === 'string' && key !== '' && $injector.has('translateFilter')) {
      try {
        var text = $injector.get('translateFilter')(key);
        if (typeof text === 'string' && text !== '' && text !== key) {
          return text;
        }
      } catch (e) {
        // fall through to the raw name
      }
    }
    return action;
  }

  // The entry to write, built from the payload's own bindingTemplate (core/input/bindings.lua:703 puts
  // it in every InputBindingsChanged), exactly as addNewBinding does with its copy
  // (ui-vue/src/services/controls.js:664). A template-shaped entry rather than the old one carried over:
  // updateBinding REPLACES the entry wholesale, and the stored one carries engine-computed fields
  // (`unused`, `active`, `player`) that have no business being written back to disk.
  function bindingEntry(data, devname, control, action) {
    var entry = {};
    var template = (data && data.bindingTemplate) || {};
    for (var k in template) {
      if (Object.prototype.hasOwnProperty.call(template, k)) {
        entry[k] = template[k];
      }
    }
    entry.devname = devname;
    entry.control = control;
    entry.action = action;
    return entry;
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompControls/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope) {
      var unusable = directiveUnusable();
      // Seeded with the legacy rung, which is answerable here and now, and upgraded to the new UI when
      // GE answers. The seed is what makes the in-flight window safe: a click before the answer lands
      // behaves exactly as round 1 did -- the old dialog, on the right action -- rather than doing
      // nothing. GE's answer is a local guihook round-trip and arrives within a frame or two, while the
      // player still has to move the mouse onto a chip.
      var rung = legacyRung();
      var settled = false;
      var noRebind = rebindUnusable();
      var payload = null;       // the last InputBindingsChanged, kept for the template and conflicts
      var capture = null;       // {gen, row, control} while a capture holds the player's input
      var captureGen = 0;       // every started capture takes the next number; see endCapture
      var captureWait = null;   // the CAPTURE_TIMEOUT handle
      var duplicatesNoted = false;   // the duplicate line is written once per mount; see noteDuplicates
      scope.useDirective = !unusable;
      scope.canEdit = !!rung;
      scope.canBind = !noRebind;
      scope.prompt = null;      // the "press a key" line while a capture runs
      scope.status = null;      // the one-line outcome of the last action
      // Deliberately null, not the two empty rows: an early '[N/A]' would tell a correctly bound player
      // that he has no key bound, and a wrong 'you have none' is exactly as bad as a wrong key.
      scope.rows = null;

      // The tripwire, written ONCE per mount and only when the jump is settled -- a line naming a rung
      // that is about to be replaced would be worse than none. Both halves name their SOURCE; a rename
      // in the next engine version is then one grep in beamng.log away instead of a window nobody can
      // explain.
      function settle(note) {
        if (settled) {
          return;
        }
        settled = true;
        scope.canEdit = !!rung;
        geNote('bindings drawn by ' + (unusable ? ('the built-in fallback (' + unusable + ')')
          : "the game's own directive")
          + '; rebinding ' + (noRebind ? ('unavailable (' + noRebind + ')') : 'in the window')
          + '; settings open ' + (rung ? rung.source : 'nothing (no route in this build)') + note);
      }

      // GE's answer about the new options UI (see the header): a name upgrades the rung, an empty string
      // leaves the legacy seed standing.
      scope.$on('BeamCompControlsRoute', function (event, data) {
        scope.$evalAsync(function () {
          var better = routerRung(data && data.route);
          if (better) {
            rung = better;
          }
          settle('');
        });
      });
      // If that answer never comes, say so rather than never writing the line at all. Cancelled with the
      // window: a player who closes it within the two seconds would otherwise get a "no answer" line for
      // a window that no longer exists, and the client log stops recording after ~15k lines.
      var answerWait = $timeout(function () {
        settle(' (asked GE for the new options route, no answer)');
      }, ROUTE_ANSWER_TIMEOUT);
      // The app can go away under a running capture -- a UI reload during the spawn churn, the HUD-apps
      // layer unmounting on a menu route, the window being removed from the layout. Nobody would be left
      // to end it, so end it here. endCapture bumps the generation first, so the promise this leaves
      // behind resolves into nothing, and it asks GE for the release, which is the side that outlives us.
      scope.$on('$destroy', function () {
        $timeout.cancel(answerWait);
        if (capture) {
          endCapture(null);
        }
      });

      // Close from the window's own X. GE owns the toggle state, so the X and a second /keys agree --
      // and GE's close_controls also releases a capture this window may still be holding.
      scope.close = function () {
        geLua('if beamcomp_init then beamcomp_init.close_controls() end');
      };

      // ----- the capture cycle ---------------------------------------------------------------------
      // END A CAPTURE, from wherever. This is the single exit, and everything about the safety promise
      // hangs on two lines of it: `capture = null` before anything else, and the generation number.
      //
      // captureBinding's promise CANNOT be cancelled -- the game keeps no handle to it, and the promise
      // never rejects (ui-vue/src/services/controls.js:393). An aborted capture therefore stays pending
      // and will resolve later, whenever some input happens to satisfy it. Nulling `capture` and bumping
      // the generation is what makes that late resolution land on a closed door: onCaptured compares the
      // number it was started with against the current one and returns. A flag alone would not do -- a
      // second capture started in between would clear it and the stale promise would write into the new
      // one's row.
      //
      // The three input switches are restored through GE, not from here, because GE is also the side
      // that can do it when this app is gone (close_controls, onExtensionUnloaded). One seam, every case.
      function endCapture(status) {
        capture = null;
        captureGen++;
        scope.prompt = null;
        if (captureWait) {
          $timeout.cancel(captureWait);
          captureWait = null;
        }
        scope.status = status || null;
        geLua('if beamcomp_init then beamcomp_init.release_input_capture() end');
      }

      // START a capture for `row`. `control` is the chip being changed, or null when adding one.
      function beginCapture(row, control) {
        var controls = controlsStore();
        if (!controls || capture) {
          return;
        }
        captureGen++;
        var gen = captureGen;
        capture = {gen: gen, row: row, control: control};
        scope.status = null;
        scope.prompt = control
          ? 'Press a new key for ' + row.label + '. Right-click to cancel.'
          : 'Press a key for ' + row.label + '. Right-click to cancel.';

        // Tell GE the switches are about to go on, BEFORE they do: if anything below throws, the release
        // path is already armed and the player still gets his controls back.
        geLua('if beamcomp_init then beamcomp_init.arm_input_capture() end');

        // The backstop. Not the normal way out -- see CAPTURE_TIMEOUT.
        captureWait = $timeout(function () {
          if (capture && capture.gen === gen) {
            endCapture('Timed out.');
          }
        }, CAPTURE_TIMEOUT);

        try {
          controls.captureBinding(true).then(function (result) {
            scope.$evalAsync(function () { onCaptured(gen, result); });
          }, function () {
            scope.$evalAsync(function () {
              if (capture && capture.gen === gen) { endCapture(null); }
            });
          });
        } catch (e) {
          endCapture('Could not start.');
          geNote('captureBinding threw: ' + e);
        }
      }

      // A capture resolved. `gen` is the number it was started with.
      function onCaptured(gen, result) {
        // THE GUARD. A capture that was cancelled, timed out, or belongs to a window that has since been
        // torn down resolves here too, late, with a perfectly valid key -- and must write nothing.
        if (!capture || capture.gen !== gen) {
          return;
        }
        var row = capture.row;
        var old = capture.control;
        var devname = result && result.devName;
        var control = result && result.control;

        // An axis is a real capture but not a usable one: both assists are hold-a-button actions, and a
        // binding written as an axis would simply never fire.
        if (result && result.controlType === 'axis') {
          endCapture('An axis cannot be used here.');
          return;
        }
        if (typeof devname !== 'string' || typeof control !== 'string' || control === '') {
          endCapture('Nothing was captured.');
          return;
        }

        // One line per write attempt, whatever its outcome. It names the captured pair VERBATIM next to
        // what the action already held on that device: if a key ever lands twice again, this line shows
        // whether the two strings really were equal.
        var attempt = 'write ' + row.action + ' via ' + (old ? 'updateBinding' : 'addNewBinding')
          + ', captured ' + pairText(devname, control)
          + (old ? ', replacing ' + pairText(old.device, old.key) : '')
          + ', held ' + JSON.stringify(boundControls(payload, devname, row.action));

        // The action already has this key: a second identical entry is all a write could add. Covers the
        // '+', the [N/A] chip and a chip edit onto its own key or onto a sibling chip's key alike.
        if (alreadyBound(payload, devname, control, row.action)) {
          endCapture('Already bound to ' + row.label + '.');
          geNote(attempt + ': refused, already bound');
          return;
        }

        var clash = conflictsFor(payload, devname, control, row.action);
        var entry = bindingEntry(payload, devname, control, row.action);
        try {
          if (old) {
            entry.oldDevname = old.device;
            entry.oldControl = old.key;
            controlsStore().updateBinding(entry);
          } else {
            controlsStore().addNewBinding(entry);
          }
        } catch (e) {
          endCapture('Could not save.');
          geNote(attempt + ': threw ' + e);
          return;
        }
        // Reported, not resolved -- the other binding stays exactly where it was.
        endCapture(clash.length ? ('Also bound to ' + clash.join(', ') + '.') : null);
        geNote(attempt + ': written' + (clash.length ? ', also bound to ' + clash.join(', ') : ''));
        refreshBindings();
      }

      // Right mouse button = cancel (see CANCEL_CONTROL). Heard on the Angular side because the engine
      // broadcasts RawInputChanged to both realms -- BeamNG's own old options UI listens to exactly this
      // ($rootScope.$on('RawInputChanged'), options.js:1884).
      //
      // This is the FAST exit, never the guaranteed one: if the event stopped reaching Angular the
      // timeout above still frees the player. Nothing here depends on it arriving.
      scope.$on('RawInputChanged', function (event, data) {
        if (!capture || !data) {
          return;
        }
        if (String(data.devName || '').indexOf(CANCEL_DEVICE) !== 0 || data.control !== CANCEL_CONTROL) {
          return;
        }
        scope.$evalAsync(function () {
          if (capture) { endCapture(null); }
        });
      });

      // Clicking a chip: rebind it when we can, otherwise do what round 2 did and open the settings.
      scope.edit = function (row, control) {
        if (capture) {
          return;
        }
        if (scope.canBind) {
          beginCapture(row, control);
          return;
        }
        scope.openSettings(row, control);
      };

      // The [N/A] chip and the per-row '+': the same capture, written as a new binding.
      scope.add = function (row) {
        if (capture) {
          return;
        }
        if (scope.canBind) {
          beginCapture(row, null);
          return;
        }
        scope.openSettings(row, null);
      };

      // The small x on a chip. No confirmation dialog: the row shows the result immediately and the same
      // row can put it straight back, which is a cheaper undo than a prompt nobody reads.
      //
      // A chip can stand for several identical entries (see chipsFor), and the x takes ALL of them -- a
      // key that is still there after its x was pressed would be the same bug the other way round.
      // deleteBindings splices one match per item and saves once per device, so N copies are N items in
      // one save. It is optional on purpose and NOT in rebindUnusable's list: a build without it keeps
      // the whole rebind feature and only loses this, removing one copy per click as before.
      scope.remove = function (row, control, $event) {
        if ($event && $event.stopPropagation) {
          $event.stopPropagation();   // the x sits inside the chip, which would start a capture
        }
        if (capture || !scope.canBind) {
          return;
        }
        var target = {devname: control.device, control: control.key, action: row.action};
        var copies = control.copies;
        var store = controlsStore();
        var attempt = 'remove ' + row.action + ' ' + pairText(control.device, control.key);
        var outcome;
        try {
          if (copies > 1 && typeof store.deleteBindings === 'function') {
            var items = [];
            for (var i = 0; i < copies; i++) {
              items.push({devname: target.devname, control: target.control, action: target.action});
            }
            store.deleteBindings(items);
            outcome = copies + ' entries via deleteBindings';
          } else {
            store.deleteBinding(target);
            outcome = copies > 1
              ? '1 of ' + copies + ' entries via deleteBinding (deleteBindings is missing)'
              : '1 entry via deleteBinding';
          }
        } catch (e) {
          scope.status = 'Could not remove.';
          geNote(attempt + ': threw ' + e);
          return;
        }
        geNote(attempt + ': ' + outcome);
        scope.status = null;
        refreshBindings();
      };

      // Open the controls settings for this row -- the four-rung chain from round 2, unchanged. Its
      // trigger moved to the footer button; it is still what a chip click does when rebinding is not
      // available on this build. `control` is the chip that was clicked, or null. What reaches the rung
      // differs by rung and that is deliberate: the new UI has no deep link onto one binding and gets
      // neither, while the legacy dialog lands on the action and gets both -- an EMPTY oldBinding for
      // the unassigned chip, which is the shape the options UI itself uses to ADD a binding
      // (ControlsEditCtrl reads $stateParams.oldBinding.sel || {}, options.js:2229).
      scope.openSettings = function (row, control) {
        if (capture || !rung) {
          return;
        }
        try {
          // The footer button passes no row. The new-UI rung ignores both arguments anyway (it opens
          // the controls page, not an action); the legacy rung needs one, and the first assist is as
          // good a landing as any -- both are on the same page there.
          rung.go(scope, row || {action: ASSISTS[0].action}, control || null);
        } catch (e) {
          // A throw is the loud failure and is fine to report; the silent one is what the probes cover.
          geNote('opening ' + rung.source + ' threw: ' + e);
        }
      };

      // Ask the engine to re-broadcast the bindings after a write. saveBindingsToDisk is the game's own
      // save path, but nothing promises it notifies the UI, and a window showing the key the player just
      // replaced would be the one wrong thing this window must never show.
      function refreshBindings() {
        geLua('extensions.core_input_bindings.notifyUI("beamcomp controls window")');
      }

      scope.$on('InputBindingsChanged', function (event, data) {
        scope.$evalAsync(function () {
          // Kept whole: the rows are drawn from it, and a write needs its bindingTemplate and its
          // actions table (the conflict line). One source, so the two can never disagree.
          payload = data || null;
          scope.rows = buildRows(data);
          noteDuplicates(scope.rows);
        });
      });

      // The duplicate tripwire, ONCE per mount: the engine re-broadcasts after every write and on
      // unrelated changes, and the same pair would otherwise be reported each time.
      function noteDuplicates(rows) {
        if (duplicatesNoted) {
          return;
        }
        var note = duplicateNote(rows);
        if (note) {
          duplicatesNoted = true;
          geNote(note);
        }
      }

      // Ask for the current bindings right away: a window opened between two changes would otherwise wait
      // for the next one and stay empty. The game's own Keys app asks the same way at link
      // (ui/modules/apps/Keys/app.js:120).
      geLua('extensions.core_input_bindings.notifyUI("beamcomp controls window")');
      // And ask GE which route reaches the new options UI. Answered on BeamCompControlsRoute above.
      geLua('if beamcomp_init then beamcomp_init.request_controls_route() end');
    }
  };
}]);
