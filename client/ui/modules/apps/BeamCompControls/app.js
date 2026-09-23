// BeamComp Controls -- AngularJS directive (ADR-0061).
// The window /keys opens: where BeamComp's two in-race assists are bound, on EVERY device, drawn with
// the game's own binding glyphs -- and every chip is the button that jumps into BeamNG's binding dialog
// for exactly that action. Nothing here writes a binding; the dialog does, and what the player saves
// there applies to the whole game immediately.
//
// This is the first place BeamComp uses foreign UI code of the game rather than only its data channels,
// and BOTH touchpoints are version-coupled and fail SILENTLY:
//
//   * an Angular directive that does not exist renders as an unknown element -- an empty node, no error,
//     no warning, nothing on screen but a caption with a gap beside it;
//   * a $state.go onto an unknown state simply does nothing when clicked.
//
// That is the same trap the node-grabber block sat in for months (core_input_actionFilter accepts any
// action name, ADR-0017 / CLAUDE.md). So neither is assumed: each is PROBED at link, each degrades to
// something readable, and ONE log line into the client log names which case happened. The line names the
// SOURCE, not a count -- "2 of 2 rows rendered" would be just as happy with two empty <binding> nodes.
//
// Data: the window draws from BeamNG's own InputBindingsChanged broadcast and asks for it once at link
// (core_input_bindings.notifyUI), exactly as the game's Keys app does. It keeps drawing live, so a player
// who rebinds in the dialog and comes back sees the new key without reopening.
//
// Kept in ES5 to match the surrounding CEF/AngularJS files. The three BeamComp apps share no code by
// design; keyLabel below is the third copy of a formatter that exists in BeamCompSetup/app.js and (as
// key_label) in race/lock.lua -- see its own comment.
angular.module('beamng.apps')
.directive('beamCompControls', ['$injector', function ($injector) {
  // BeamNG's own binding-edit dialog, defined in ui/entrypoints/main/main.js:393 with
  // params: {action: "", oldBinding: {}}. We jump into it; we never rebuild it.
  var EDIT_ROUTE = 'menu.options.controls.bindings.edit';

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

  // PROBE 2 -- how do we get into the binding dialog? Returns {source, go}, where a null `go` means
  // "no button": the rows stay readable and nothing is clickable.
  //
  // $state is resolved through $injector.get rather than injected, for the same reason bngApi is never
  // injected: a dependency that fails to resolve takes the whole directive down, and then the window is
  // gone instead of merely un-clickable. $state.get() is the actual existence question -- a $state.go onto
  // an unknown state is a silent no-op, which is the failure this whole construction exists to avoid.
  function resolveRoute() {
    var state = null;
    if ($injector.has('$state')) {
      try {
        state = $injector.get('$state');
      } catch (e) {
        state = null;
      }
    }
    if (state && typeof state.get === 'function' && typeof state.go === 'function') {
      var known = null;
      try {
        known = state.get(EDIT_ROUTE);
      } catch (e2) {
        known = null;
      }
      if (known) {
        return {
          source: 'angular ui-router',
          go: function (params) { state.go(EDIT_ROUTE, params); }
        };
      }
    }
    // The Vue half of the 0.39 hybrid takes the same route name (Keys/app.keyList.vue:75 ->
    // ui-vue/src/App.vue:212 -> lua extensions.ui_router.navigate).
    if (window.bngVue && typeof window.bngVue.gotoGameState === 'function') {
      return {
        source: 'vue gotoGameState',
        go: function (params) { window.bngVue.gotoGameState(EDIT_ROUTE, {params: params}); }
      };
    }
    return {source: 'none', go: null};
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
      var route = resolveRoute();
      scope.useDirective = !unusable;
      scope.canEdit = !!route.go;
      // Deliberately null, not the two empty rows: an early '[N/A]' would tell a correctly bound player
      // that he has no key bound, and a wrong 'you have none' is exactly as bad as a wrong key.
      scope.rows = null;

      // The tripwire. Both halves in one line, each naming its source -- a rename in the next engine
      // version is then one grep in beamng.log away instead of a window nobody can explain.
      geNote('bindings drawn by ' + (unusable ? ('the built-in fallback (' + unusable + ')')
        : "the game's own directive") + '; route source: ' + route.source);

      // Close from the window's own X. GE owns the toggle state, so the X and a second /keys agree.
      scope.close = function () {
        geLua('if beamcomp_init then beamcomp_init.close_controls() end');
      };

      // Jump into the binding dialog for this row. `control` is the chip that was clicked, or null for
      // the unassigned chip -- which sends an EMPTY oldBinding, the shape the options UI itself uses to
      // ADD a binding (ControlsEditCtrl reads $stateParams.oldBinding.sel || {} and only fills device +
      // control when both are set, options.js:2229). Always allowed, race or not.
      scope.edit = function (row, control) {
        if (!route.go) {
          return;
        }
        // Take the in-game menu down first, exactly as the game's own Keys app does before the jump
        // (ui/modules/apps/Keys/app.js:42).
        scope.$emit('MenuHide', false);
        var params = {action: row.action, oldBinding: {}};
        if (control) {
          params.oldBinding = {control: control.key, device: control.device};
        }
        try {
          route.go(params);
        } catch (e) {
          // A throw is the loud failure and is fine to report; the silent one is what the probe covers.
          geNote('the jump into ' + EDIT_ROUTE + ' threw: ' + e);
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
    }
  };
}]);
