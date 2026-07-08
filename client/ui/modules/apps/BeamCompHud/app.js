// BeamComp HUD -- AngularJS directive.
// Registers the <beam-comp-hud> directive referenced by app.json. Renders the live race state
// during racing and the final results card during the finished phase (ADR-0012). Render-only: the
// GE extension (race/hud.lua) pushes a snapshot via guihooks.trigger("BeamCompHudUpdate", ...)
// every racing and finished frame; we receive it with scope.$on and format it for the template.
// No GE round-trip on load -- the per-frame push covers a mid-race add.
angular.module('beamng.apps')
.directive('beamCompHud', ['$timeout', '$interval', function ($timeout, $interval) {
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

  // F1 start reaction (ADR-0043): seconds from lights-out to first movement, signed -- "+0.31s" = launch
  // reaction, "-0.80s" = jumped that early. "--" until the car has moved (not measured yet) / non-F1.
  function formatReaction(s) {
    if (typeof s !== 'number') {
      return '--';
    }
    return (s >= 0 ? '+' : '') + s.toFixed(2) + 's';
  }

  // Live-standings interval cell: the time gap to the row's reference (the selected mode -- self,
  // car ahead, or leader), prefixed with the checkpoint gap when the two are more than one completed
  // checkpoint apart -> "+2 CP (+12.3)" (the frozen shared-crossing time gap, ADR-0015, is then
  // misleadingly small, so the CP gap leads). Both are signed: a reference ahead reads negative. At
  // <=1 CP apart it is just the time.
  function formatInterval(e) {
    if (typeof e.cpInterval === 'number' && Math.abs(e.cpInterval) >= 2) {
      var cp = (e.cpInterval < 0 ? '-' : '+') + Math.abs(e.cpInterval) + ' CP';
      return typeof e.interval === 'number' ? cp + ' (' + formatDelta(e.interval) + ')' : cp;
    }
    return formatDelta(e.interval);
  }

  // Provisional-card gap cell: the time gap to the leader, prefixed with the checkpoint gap when the row
  // is more than one completed checkpoint behind the leader -> "+2 CP (+12.3)". P1 (no leader gap) and
  // <=1 CP behind fall back to the plain leader time.
  function formatLeaderGap(e) {
    if (typeof e.cpGap === 'number' && Math.abs(e.cpGap) >= 2) {
      var cp = (e.cpGap < 0 ? '-' : '+') + Math.abs(e.cpGap) + ' CP';
      return typeof e.gap === 'number' ? cp + ' (' + formatDelta(e.gap) + ')' : cp;
    }
    return formatDelta(e.gap);
  }

  // Short label for the live-standings interval reference mode, shown on the REL toggle.
  function intervalLabel(mode) {
    if (mode === 'leader') {
      return 'LEADER';
    }
    if (mode === 'ahead') {
      return 'AHEAD';
    }
    return 'SELF';
  }

  // Unsigned race time in seconds for the analysis matrix/metrics: "S.cs" under 60 s, "M:SS.cs" from
  // 60 s (segments are usually a handful of seconds, but a long lap segment can exceed a minute).
  // Placeholder when not a number.
  function formatSeconds(s) {
    if (typeof s !== 'number') {
      return '--';
    }
    if (s < 60) {
      return s.toFixed(2);
    }
    var m = Math.floor(s / 60);
    var rest = s - m * 60;
    return m + ':' + (rest < 10 ? '0' : '') + rest.toFixed(2);
  }

  // Accumulated raced time (seconds) -> "h:mm:ss" past an hour, else "m:ss"; placeholder when not a
  // positive number. Used for the Driver/Track time_sum totals, which can span many runs.
  function formatDuration(t) {
    if (typeof t !== 'number' || t <= 0) {
      return '--';
    }
    var total = Math.floor(t);
    var h = Math.floor(total / 3600);
    var m = Math.floor((total % 3600) / 60);
    var s = total % 60;
    var ss = (s < 10 ? '0' : '') + s;
    if (h > 0) {
      var mm = (m < 10 ? '0' : '') + m;
      return h + ':' + mm + ':' + ss;
    }
    return m + ':' + ss;
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

  // Qualifying board (ADR-0041): the live classification during the qualifying session, ranked by best
  // lap (fastest on pole); drivers with no valid time fall to the back in their current order. Display
  // only -- the server sets the actual grid from the same metric when qualifying ends.
  function qualiBoard(entries) {
    var list = (entries || []).slice();
    list.sort(function (a, b) {
      var at = typeof a.bestLap === 'number';
      var bt = typeof b.bestLap === 'number';
      if (at && bt) {
        return a.bestLap - b.bestLap;
      }
      if (at !== bt) {
        return at ? -1 : 1;
      }
      return (a.position || 0) - (b.position || 0);
    });
    return list;
  }

  // Staged sprint quali holding-queue board (ADR-0044): order by the server-assigned position (the staged/
  // running driver first, then the holding queue), with the already-done drivers (no position) at the back
  // by slot. Display only -- the server owns the queue + the grid it sets from the best complete run times.
  function qualiQueueSorted(rows) {
    var list = (rows || []).slice();
    list.sort(function (a, b) {
      var ap = typeof a.position === 'number';
      var bp = typeof b.position === 'number';
      if (ap && bp) {
        return a.position - b.position;
      }
      if (ap !== bp) {
        return ap ? -1 : 1;
      }
      return (a.slot || 0) - (b.slot || 0);
    });
    return list;
  }

  // The local driver's staged-quali status line (ADR-0044) from their own queue row {status, position}.
  // "You're next" is the front of the holding queue (position 2 -- position 1 is the car currently at P1).
  function qualiStatusText(mine) {
    if (!mine) {
      return '';
    }
    if (mine.status === 'running') {
      return 'On your run';
    }
    if (mine.status === 'staged') {
      return 'Staging - get ready';
    }
    if (mine.status === 'done') {
      return 'Run complete';
    }
    if (typeof mine.position === 'number' && mine.position <= 2) {
      return "You're next";
    }
    if (typeof mine.position === 'number') {
      return 'Queued - ' + (mine.position - 1) + ' ahead';
    }
    return 'Queued';
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
      scope.finishBanner = {active: false, position: null};
      scope.jumpBanner = {active: false, penalty: null};
      scope.winnerBanner = {active: false, local: false, name: null};
      // While the champion banner is owed/showing, the Final Standings card stays collapsed to its restore
      // bar, then expands once the banner fades -- and it starts collapsed on the first finished frame so the
      // full card never flashes behind the banner (no flicker).
      scope.winnerCardCollapsed = false;
      scope.formatTime = formatTime;
      scope.formatDelta = formatDelta;
      scope.formatReaction = formatReaction;
      scope.formatInterval = formatInterval;
      scope.formatStaging = formatStaging;
      scope.formatSeconds = formatSeconds;
      scope.formatDuration = formatDuration;
      // Staged sprint quali status line (ADR-0044).
      scope.qualiStatusText = qualiStatusText;

      // UI-presence heartbeat (self-healing HUD: race/hud.lua + the init.lua watchdog). Tell GE this app
      // is alive on link and once a second after. If GE stops hearing it while a race wants the HUD up --
      // e.g. an engine/BeamMP UI reload during the spawn churn dropped our late-mounted app (ADR-0008) --
      // it re-shows the app and, failing that, reloads the UI. bngApi is the core UI global (not an
      // injected service, which would not resolve for this late-loaded mod app -- ADR-0012) and
      // typeof-guarded so a miss is inert.
      function noteAlive() {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.note_hud_alive() end');
        }
      }
      noteAlive();
      var heartbeat = $interval(noteAlive, 1000);

      // Position-gain flash state (live HUD only): the previous rank per stable row id, the rows
      // currently flashing, and their clear timers. Tracked across the per-frame snapshots over the
      // full field (not the windowed rows) so a row scrolling in and out of view never false-flashes.
      var prevPos = {};
      var flashing = {};
      var flashTimers = {};

      // Personal finish-banner state (local player only, so a single boolean, not a map). null means the
      // local finished status has not been seen yet -> the first racing frame only establishes it, so an
      // app/UI reload while already finished does not re-fire the banner (mirrors trackPositionGains).
      var prevLocalFinished = null;
      var finishBannerTimer = null;

      // Personal jump-start banner state (ADR-0043): null sentinel like prevLocalFinished -- the first
      // racing frame only establishes whether our row already carries a penalty (reload-safe), so the
      // banner fires only on a genuine no-penalty -> penalized transition.
      var prevLocalJumped = null;
      var jumpBannerTimer = null;

      // Class-drop champion-banner state (ADR-0042): prevTournamentEnded mirrors the prevLocalFinished
      // sentinel -- null means the ended flag has not been seen yet, so a reload mid-celebration does not
      // re-fire. winnerBannerPending holds the resolved {local, name} while the personal finish banner is
      // still up, so the champion banner waits its turn before showing.
      var prevTournamentEnded = null;
      var winnerBannerTimer = null;
      var winnerBannerPending = null;

      function clearFlashTimers() {
        for (var id in flashTimers) {
          $timeout.cancel(flashTimers[id]);
        }
        flashTimers = {};
      }

      function resetFlashState() {
        clearFlashTimers();
        prevPos = {};
        flashing = {};
      }

      // Hide the finish banner and cancel its self-hide timer. Phase handling owns prevLocalFinished, so
      // this only clears the visible banner (used on teardown and on every non-racing phase).
      function resetFinishBanner() {
        if (finishBannerTimer) {
          $timeout.cancel(finishBannerTimer);
          finishBannerTimer = null;
        }
        scope.finishBanner.active = false;
      }

      // Hide the jump-start banner and cancel its self-hide timer. Phase handling owns prevLocalJumped.
      function resetJumpBanner() {
        if (jumpBannerTimer) {
          $timeout.cancel(jumpBannerTimer);
          jumpBannerTimer = null;
        }
        scope.jumpBanner.active = false;
      }

      // Hide the champion banner, cancel its self-hide timer, and drop any pending show. The once-only latch
      // prevTournamentEnded is owned by trackTournamentWin and deliberately left untouched here.
      function resetWinnerBanner() {
        if (winnerBannerTimer) {
          $timeout.cancel(winnerBannerTimer);
          winnerBannerTimer = null;
        }
        winnerBannerPending = null;
        scope.winnerBanner.active = false;
        scope.winnerCardCollapsed = false;
      }

      // Compare each entry's rank to the last frame; a row that improved its position flashes for ~1 s.
      // A row with no prior known rank (mid-race join, first frame) only establishes its rank.
      function trackPositionGains(entries) {
        for (var i = 0; i < entries.length; i++) {
          var e = entries[i];
          if (!e.id) {
            continue;
          }
          var last = prevPos[e.id];
          if (last != null && e.position < last) {
            flashing[e.id] = true;
            if (flashTimers[e.id]) {
              $timeout.cancel(flashTimers[e.id]);
            }
            flashTimers[e.id] = $timeout((function (id) {
              return function () {
                flashing[id] = false;
                delete flashTimers[id];
              };
            })(e.id), 2000);
          }
          prevPos[e.id] = e.position;
        }
      }

      scope.$on('$destroy', function () {
        $interval.cancel(heartbeat);
        clearFlashTimers();
        resetFinishBanner();
        resetJumpBanner();
        resetWinnerBanner();
      });

      // Announce the local player's own race finish: a one-shot "FINISHED" + reached position banner the
      // moment our row crosses the line during racing (while others may still be driving), held ~3 s. Only
      // a genuine not-finished -> finished transition fires; the null sentinel means the first racing frame
      // we see merely establishes the status (reload-safe). A non-racing phase re-arms (lobby/staging set
      // false so a fresh race fires again) or clears (finished). DNF never fires (localFinished excludes it).
      function trackLocalFinish() {
        var phase = scope.hud.phase;
        if (phase !== 'racing') {
          prevLocalFinished = false;
          resetFinishBanner();
          return;
        }
        var localEntry = scope.hud.localEntry;
        var localFinished = !!localEntry && !!localEntry.finished && !localEntry.dnf;
        if (prevLocalFinished === null) {
          prevLocalFinished = localFinished;
          return;
        }
        if (localFinished && !prevLocalFinished) {
          scope.finishBanner = {active: true, position: localEntry.position};
          if (finishBannerTimer) {
            $timeout.cancel(finishBannerTimer);
          }
          finishBannerTimer = $timeout(function () {
            scope.finishBanner.active = false;
            finishBannerTimer = null;
          }, 3000);
        }
        prevLocalFinished = localFinished;
      }

      // Announce the local player's own jump start (ADR-0043): a one-shot "JUMP START -- +Ns" banner the
      // moment our row gains a jump penalty during racing (the server applies it ~a tick after lights-out
      // and relays it on the standings). Mirrors trackLocalFinish -- the null sentinel makes the first
      // racing frame establish state (reload-safe), and a non-racing phase re-arms/clears the banner.
      function trackLocalJump() {
        var phase = scope.hud.phase;
        if (phase !== 'racing') {
          prevLocalJumped = false;
          resetJumpBanner();
          return;
        }
        var localEntry = scope.hud.localEntry;
        var penalty = localEntry && localEntry.jumpPenalty;
        var jumped = !!(penalty && penalty > 0);
        if (prevLocalJumped === null) {
          prevLocalJumped = jumped;
          return;
        }
        if (jumped && !prevLocalJumped) {
          scope.jumpBanner = {active: true, penalty: penalty};
          if (jumpBannerTimer) {
            $timeout.cancel(jumpBannerTimer);
          }
          jumpBannerTimer = $timeout(function () {
            scope.jumpBanner.active = false;
            jumpBannerTimer = null;
          }, 3500);
        }
        prevLocalJumped = jumped;
      }

      // Promote a queued champion banner once the personal finish banner has cleared, then hold it ~5 s.
      // Called every finished-phase frame (the phase pushes per frame, GE init.lua), so a banner queued while
      // "FINISHED" is still up appears the moment that fades.
      function promoteWinnerBannerIfReady() {
        if (!winnerBannerPending || scope.finishBanner.active) {
          return;
        }
        scope.winnerBanner = {active: true, local: winnerBannerPending.local, name: winnerBannerPending.name};
        winnerBannerPending = null;
        if (winnerBannerTimer) {
          $timeout.cancel(winnerBannerTimer);
        }
        winnerBannerTimer = $timeout(function () {
          scope.winnerBanner.active = false;
          winnerBannerTimer = null;
        }, 5000);
      }

      // Announce the class-drop tournament champion (ADR-0042): a big centered banner shown once, in the
      // finished phase of the race that decides the tournament (the ended false->true transition). The winner
      // sees a personalized line, everyone else the winner's identity. Reuses the personal finish banner's
      // slot and waits for it to clear, then auto-fades. The null sentinel makes a reload mid-celebration
      // inert; it re-arms only after the tournament is reset (no ended snapshot is loaded).
      function trackTournamentWin() {
        var t = scope.hud.tournament;
        var ended = !!(t && t.active && t.ended);
        if (!ended) {
          prevTournamentEnded = false;
          resetWinnerBanner();
          return;
        }
        if (prevTournamentEnded === null) {
          prevTournamentEnded = true;
          return;
        }
        if (!prevTournamentEnded) {
          // ended just flipped true -> the deciding race. Queue the banner now, resolving the personalized
          // line from the deciding-race standings. Display is phase-gated at promote time, so this stays
          // correct even when the ended snapshot and the finished-phase change land on different frames
          // (they are separate server messages -- tournament broadcast then racePhase).
          prevTournamentEnded = true;
          var localWin = !!(scope.hud.localEntry && scope.hud.localEntry.name === t.winner);
          winnerBannerPending = {local: localWin, name: t.winner};
        }
        // Show only in the finished results window, once the personal finish banner has cleared. Outside it
        // the template's phase gate keeps the banner hidden and the self-hide timer clears the state.
        if (scope.hud.phase === 'finished') {
          promoteWinnerBannerIfReady();
          // Collapse the Final Standings while the banner is owed or up, expand it once the banner is gone.
          scope.winnerCardCollapsed = !!(winnerBannerPending || scope.winnerBanner.active);
        }
      }

      // Open/close the post-race analysis overlay via the GE flag (single source of truth, ADR-0028):
      // the results-card button and the /analysis command both route through M.toggle_analysis. bngApi is
      // referenced as the core UI global (not an injected service, which would fail to resolve for this
      // late-loaded mod app and take the whole directive down) and typeof-guarded so a miss is inert --
      // the /analysis chat command remains the reliable trigger either way.
      scope.toggleAnalysis = function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.toggle_analysis() end');
        }
      };

      // Cycle the live-standings interval reference (self -> ahead -> leader) via the GE flag (single
      // source of truth): the REL toggle on the standings panel routes here. bngApi is the typeof-guarded
      // core UI global (not an injected service -- ADR-0012), so a miss is inert.
      scope.cycleIntervalMode = function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.cycle_interval_mode() end');
        }
      };
      scope.intervalLabel = intervalLabel;
      scope.formatLeaderGap = formatLeaderGap;

      // Show/hide the provisional results card (GE flag, single source of truth): the card's Close
      // button and the live HUD's Results button both route here, as does the racing-phase /results.
      // bngApi is the typeof-guarded core UI global (ADR-0012), so a miss is inert.
      scope.toggleProvisional = function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.toggle_provisional_results() end');
        }
      };

      // Minimize/restore the finished final-standings card (ADR-0012/0041 pattern): routes to the GE flag, so
      // these buttons and the /results command share one state. Inert if bngApi is unavailable (ADR-0012).
      scope.toggleResultsMin = function () {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('if beamcomp_init then beamcomp_init.toggle_results_min() end');
        }
      };

      // Minimize/maximize the quali-results card (ADR-0041): client-local, no GE round-trip. Methods (not
      // inline ng-click assignments) so they set the flag on this scope, not an ng-if child scope. Minimize
      // collapses to a small bar rather than hiding the results outright.
      scope.minimizeQualiResults = function () {
        scope.qualiResultsMin = true;
      };
      scope.maximizeQualiResults = function () {
        scope.qualiResultsMin = false;
      };

      // Analysis delta cell: signed delta or a placeholder, with a faster/slower colour class (ADR-0028).
      scope.deltaCell = function (d) {
        return typeof d === 'number' ? formatDelta(d) : '--';
      };
      scope.deltaClass = function (d) {
        if (typeof d !== 'number' || d === 0) {
          return '';
        }
        return d < 0 ? 'bc-delta-neg' : 'bc-delta-pos';
      };

      // Format a Driver-table cell by its row kind (ADR-0030): plain count, accumulated duration, or a
      // lap/total time. A nil time renders a placeholder; a nil count renders 0.
      scope.metricCell = function (value, kind) {
        if (kind === 'count') {
          return value != null ? value : 0;
        }
        if (kind === 'duration') {
          return formatDuration(value);
        }
        return value != null ? formatTime(value) : '--';
      };

      scope.$on('BeamCompHudUpdate', function (event, data) {
        scope.$evalAsync(function () {
          scope.hud = data || {active: false, entries: []};
          if (scope.hud.phase === 'finished') {
            resetFlashState();
          } else {
            trackPositionGains(scope.hud.entries || []);
          }
          scope.hud.liveEntries = windowLiveEntries(scope.hud.entries);
          for (var i = 0; i < scope.hud.liveEntries.length; i++) {
            scope.hud.liveEntries[i].flash = !!flashing[scope.hud.liveEntries[i].id];
          }
          scope.hud.localEntry = findLocalEntry(scope.hud.entries);
          // Qualifying live board (ADR-0041): rank the field by best lap for the quali session view.
          // Staged sprint quali (ADR-0044) uses the holding-queue board instead (own position/status/best).
          if (scope.hud.phase === 'qualifying') {
            if (scope.hud.qualiStaged) {
              scope.hud.qualiQueueSorted = qualiQueueSorted(scope.hud.qualiQueue);
            } else {
              scope.hud.qualiBoard = qualiBoard(scope.hud.entries);
            }
          }
          // The quali-results minimize is per-event: clear it outside the results pause so the next
          // qualifying shows the card again (ADR-0041).
          if (scope.hud.phase !== 'qualiResults') {
            scope.qualiResultsMin = false;
          }
          trackLocalFinish();
          trackLocalJump();
          trackTournamentWin();
          // Provisional results card: a finished/DNF'd player viewing standings while the race runs. While
          // it is up the live corner regions hide (template), so this one flag drives both ng-ifs. The
          // finish banner holds it back until it fades, so a finisher first sees "FINISHED", then the card.
          scope.hud.provisionalShown = !!(scope.hud.provisionalAvailable && scope.hud.provisionalOpen &&
            !scope.hud.analysisOpen && !scope.finishBanner.active);
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
