// BeamComp HUD -- AngularJS directive.
// Registers the <beam-comp-hud> directive referenced by app.json. Renders the live race state
// during racing and the final results card during the finished phase (ADR-0012). Render-only: the
// GE extension (race/hud.lua) pushes a snapshot via guihooks.trigger("BeamCompHudUpdate", ...)
// every racing and finished frame; we receive it with scope.$on and format it for the template.
// No GE round-trip on load -- the per-frame push covers a mid-race add.
angular.module('beamng.apps')
.directive('beamCompHud', ['$timeout', function ($timeout) {
  // Live HUD row cap: the leader plus a slice around the local player (see windowLiveEntries). The
  // finished results card is exempt -- it renders the whole field.
  var MAX_LIVE_ROWS = 7;

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

  // Staging-countdown remaining (seconds) -> "M:SS" in whole seconds (the GE side pushes ceil'd
  // seconds, so centiseconds would only ever read .00). Placeholder when not a number.
  function formatStaging(t) {
    if (typeof t !== 'number') {
      return '';
    }
    var total = Math.max(0, Math.ceil(t));
    var m = Math.floor(total / 60);
    var s = total - m * 60;
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  // Content-density bucket for the rows actually on screen. The app frame is owned by the BeamNG
  // layout system and does not grow with content, so the template shrinks font and padding as the
  // shown field, lap count, or checkpoint count climbs. A tier is chosen only when every dimension
  // fits its limits, otherwise we fall through to the denser tier.
  function computeSizeBucket(entries) {
    entries = entries || [];
    var maxLap = 0;
    var maxCount = 0;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].lapCount > maxLap) {
        maxLap = entries[i].lapCount;
      }
      if (entries[i].count > maxCount) {
        maxCount = entries[i].count;
      }
    }
    if (entries.length <= 4 && maxLap <= 3 && maxCount <= 10) {
      return 'normal';
    }
    if (entries.length <= 8 && maxLap <= 10 && maxCount <= 20) {
      return 'compact';
    }
    return 'dense';
  }

  // The local player's full entry (the one flagged isLocal), or null. Resolved from the full field
  // -- not the windowed live rows -- so the header, time block, and results best-lap bind to it even
  // when the local player is scrolled out of the live row window.
  function findLocalEntry(entries) {
    if (!entries) {
      return null;
    }
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isLocal) {
        return entries[i];
      }
    }
    return null;
  }

  // Window the live standings to a fixed height: the leader pinned on the top row plus a slice
  // around the local player (2 ahead, self, 3 behind). Near an edge the slice slides to stay full,
  // so a front-runner still sees a full board (P1..P7). Fields up to MAX_LIVE_ROWS are shown whole.
  // The finished results card does not call this -- it renders the full field.
  function windowLiveEntries(entries) {
    if (!entries || entries.length <= MAX_LIVE_ROWS) {
      return entries || [];
    }
    var localIndex = 0;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isLocal) {
        localIndex = i;
        break;
      }
    }
    var rowsBehind = 3;
    var start = localIndex - (MAX_LIVE_ROWS - 1 - rowsBehind);
    var maxStart = entries.length - MAX_LIVE_ROWS;
    if (start < 0) {
      start = 0;
    }
    if (start > maxStart) {
      start = maxStart;
    }
    var slice = entries.slice(start, start + MAX_LIVE_ROWS);
    if (start > 0) {
      slice[0] = entries[0];
    }
    return slice;
  }

  return {
    templateUrl: '/ui/modules/apps/BeamCompHud/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element, attrs) {
      scope.hud = {active: false, entries: []};
      scope.countdown = {active: false};
      scope.formatTime = formatTime;
      scope.formatDelta = formatDelta;
      scope.formatStaging = formatStaging;

      scope.$on('BeamCompHudUpdate', function (event, data) {
        scope.$evalAsync(function () {
          scope.hud = data || {active: false, entries: []};
          scope.hud.liveEntries = windowLiveEntries(scope.hud.entries);
          scope.hud.localEntry = findLocalEntry(scope.hud.entries);
          var shown = scope.hud.phase === 'finished' ? (scope.hud.entries || []) : scope.hud.liveEntries;
          scope.hud.sizeBucket = computeSizeBucket(shown);
        });
      });

      // Centered countdown overlay (ADR-0021): the GE side (race/countdown.lua) pushes the staging
      // indicator, the start count, the GO!, and the recover/repair assist count through this hook.
      var goHideTimer = null;
      scope.$on('BeamCompCountdown', function (event, data) {
        scope.$evalAsync(function () {
          scope.countdown = data || {active: false};
          if (goHideTimer) {
            $timeout.cancel(goHideTimer);
            goHideTimer = null;
          }
          // GO! self-hides: the racing phase sends no clear, so fade it after a short beat.
          if (scope.countdown.active && scope.countdown.kind === 'go') {
            goHideTimer = $timeout(function () {
              if (scope.countdown && scope.countdown.kind === 'go') {
                scope.countdown.active = false;
              }
            }, 1200);
          }
        });
      });
    }
  };
}]);
