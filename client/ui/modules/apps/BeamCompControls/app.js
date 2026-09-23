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
    var controls = window.bngVue && window.bngVue.controls;
    if (!controls || typeof controls.makeViewerObj !== 'function') {
      return 'window.bngVue.controls.makeViewerObj is missing';
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
  //
  // The skip rule is race/lock.lua binding_for's, verbatim: `unused` marks a binding the engine disabled
  // for the seated vehicle, `active === false` one that is switched off -- showing either would name a key
  // that does nothing. Unlike binding_for this keeps EVERY device rather than preferring the keyboard:
  // that preference exists because a chat line can only carry one key, and this window is the surface
  // where the other devices were the point.
  function buildRows(data) {
    var devices = (data && data.bindings) || [];
    var rows = [];
    for (var a = 0; a < ASSISTS.length; a++) {
      var assist = ASSISTS[a];
      var controls = [];
      for (var d = 0; d < devices.length; d++) {
        var device = devices[d] || {};
        var contents = device.contents || {};
        var list = contents.bindings || [];
        for (var b = 0; b < list.length; b++) {
          var bind = list[b] || {};
          if (bind.action !== assist.action) { continue; }
          if (bind.unused === true || bind.active === false) { continue; }
          if (typeof bind.control !== 'string' || bind.control === '') { continue; }
          controls.push({
            // The devname ('keyboard0', 'xinput0'), not the devicetype: the controls store looks its
            // image pack up by devname (ui-vue/src/services/controls.js:1056) and falls back to the type
            // on its own, so this is the more precise of the two and never the worse one.
            device: device.devname,
            key: bind.control,
            label: keyLabel(bind.control)
          });
        }
      }
      rows.push({
        label: assist.label,
        does: assist.does,
        action: assist.action,
        controls: controls
      });
    }
    return rows;
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
      scope.useDirective = !unusable;
      scope.canEdit = !!rung;
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
          : "the game's own directive") + '; clicks open '
          + (rung ? rung.source : 'nothing (no route in this build)') + note);
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
      scope.$on('$destroy', function () {
        $timeout.cancel(answerWait);
      });

      // Close from the window's own X. GE owns the toggle state, so the X and a second /keys agree.
      scope.close = function () {
        geLua('if beamcomp_init then beamcomp_init.close_controls() end');
      };

      // Open the controls settings for this row. `control` is the chip that was clicked, or null for the
      // unassigned chip. What reaches the rung differs by rung and that is deliberate: the new UI has no
      // deep link onto one binding and gets neither, while the legacy dialog lands on the action and
      // gets both -- an EMPTY oldBinding for the unassigned chip, which is the shape the options UI
      // itself uses to ADD a binding (ControlsEditCtrl reads $stateParams.oldBinding.sel || {} and only
      // fills device + control when both are set, options.js:2229). Always allowed, race or not.
      scope.edit = function (row, control) {
        if (!rung) {
          return;
        }
        try {
          rung.go(scope, row, control);
        } catch (e) {
          // A throw is the loud failure and is fine to report; the silent one is what the probes cover.
          geNote('opening ' + rung.source + ' threw: ' + e);
        }
      };

      scope.$on('InputBindingsChanged', function (event, data) {
        scope.$evalAsync(function () {
          scope.rows = buildRows(data);
        });
      });

      // Ask for the current bindings right away: a window opened between two changes would otherwise wait
      // for the next one and stay empty. The game's own Keys app asks the same way at link
      // (ui/modules/apps/Keys/app.js:120).
      geLua('extensions.core_input_bindings.notifyUI("beamcomp controls window")');
      // And ask GE which route reaches the new options UI. Answered on BeamCompControlsRoute above.
      geLua('if beamcomp_init then beamcomp_init.request_controls_route() end');
    }
  };
}]);
