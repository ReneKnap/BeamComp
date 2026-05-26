// BeamComp HUD -- AngularJS directive.
// Registers the <beam-comp-hud> directive referenced by app.json and renders the local player's
// live race state. Render-only (ADR-0012): the GE extension (race/hud.lua) pushes a snapshot via
// guihooks.trigger("BeamCompHudUpdate", ...) every racing frame; we receive it with scope.$on and
// format it for the template. No GE round-trip on load -- the per-frame push covers a mid-race add.
angular.module('beamng.apps')
.directive('beamCompHud', [function () {
  // Race time in seconds -> "m:ss.cs" (e.g. 83.4 -> "1:23.40"); placeholder when not a number.
  function formatTime(t) {
    if (typeof t !== 'number') {
      return '--:--';
    }
    var m = Math.floor(t / 60);
    var s = t - m * 60;
    return m + ':' + (s < 10 ? '0' : '') + s.toFixed(2);
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompHud/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.hud = {active: false, entries: []};
      scope.formatTime = formatTime;

      scope.$on('BeamCompHudUpdate', function (event, data) {
        scope.$evalAsync(function () {
          scope.hud = data || {active: false, entries: []};
        });
      });
    }
  };
}]);
