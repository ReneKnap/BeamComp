// BeamComp HUD -- AngularJS directive (placeholder).
// Registers the <beam-comp-hud> directive referenced by app.json.
//
// Phase 4 wires this up: bngApi.engineLua(...) to talk to the GE extension on
// load, and scope.$on("BeamCompHudUpdate", ...) to receive guihooks.trigger
// pushes (checkpoint / position / time). No logic yet.
angular.module('beamng.apps')
.directive('beamCompHud', [function () {
  return {
    templateUrl: '/ui/modules/apps/BeamCompHud/app.html',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      // Phase 4: subscribe to BeamComp HUD updates here.
    }
  };
}]);
