// BeamComp HUD -- AngularJS directive.
// Registers the <beam-comp-hud> directive referenced by app.json. Renders the live race state
// during racing and the final results card during the finished phase (ADR-0012). Render-only: the
// GE extension (race/hud.lua) pushes a snapshot via guihooks.trigger("BeamCompHudUpdate", ...)
// every racing and finished frame; we receive it with scope.$on and format it for the template.
// No GE round-trip on load -- the per-frame push covers a mid-race add.
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

  // Signed delta in seconds -> "+S.cs" under 60 s, "+M:SS.cs" from 60 s; placeholder when not a
  // number. Negative deltas are not expected from the server sort order, but the formatter keeps
  // the sign if any do appear.
  function formatDelta(s) {
    if (typeof s !== 'number') {
      return '--';
    }
    var sign = s < 0 ? '-' : '+';
    var abs = Math.abs(s);
    if (abs < 60) {
      return sign + abs.toFixed(2);
    }
    var m = Math.floor(abs / 60);
    var rest = abs - m * 60;
    return sign + m + ':' + (rest < 10 ? '0' : '') + rest.toFixed(2);
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompHud/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.hud = {active: false, entries: []};
      scope.formatTime = formatTime;
      scope.formatDelta = formatDelta;

      scope.$on('BeamCompHudUpdate', function (event, data) {
        scope.$evalAsync(function () {
          scope.hud = data || {active: false, entries: []};
        });
      });
    }
  };
}]);
