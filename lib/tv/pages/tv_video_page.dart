import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/danmaku/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/tv/widgets/tv_up_next_card.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_player_options.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// TV (D-pad) video page: the same playback session as the mobile
/// `VideoDetailPageV` — [VideoDetailController] + [PlPlayerController] +
/// [PLVideoPlayer] wired identically — presented fullscreen with TV chrome.
///
/// The mobile in-player chrome stays dormant because
/// `PlPlayerController.showControls` is never raised (its bars live offscreen
/// behind a SlideTransition); this page draws its own overlay instead:
/// * a small always-visible back/title pill (top-left), and
/// * a bottom control bar (title, play state, buffered progress bar,
///   position/duration) that auto-hides while playing.
///
/// D-pad, handled by the page's root [Focus] node (never by the mobile
/// `PlayerFocus`): OK toggles play/pause. Left/Right enter an Apple-TV-style
/// scrubber — each tap nudges a VISUAL target ±10s (holding accelerates the
/// step), a scrub bar with a Bilibili-videoshot thumbnail preview + target
/// time/delta tracks it, and exactly ONE native seek commits on OK or after a
/// ~1s idle; Back cancels with zero seeks. (Per-keypress native seeks used to
/// race AVPlay to the end — the scrubber fires at most one seek per gesture.)
/// Up (or the remote's menu key) opens the options panel (弹幕/清晰度/音质/
/// 播放速度/画面比例/播放顺序 via [TvPlayerOptions]), Down peeks the controls,
/// Back hides the controls or
/// pops back to the TV grid (the app-level `BackDetector` performs the pop
/// when the event is left unhandled). While the panel is open its own focus
/// scope handles the keys; this node only backstops Back.
class TvVideoPage extends StatefulWidget {
  const TvVideoPage({super.key});

  @override
  State<TvVideoPage> createState() => _TvVideoPageState();
}

class _TvVideoPageState extends State<TvVideoPage> {
  late final String heroTag;
  late final String _argTitle;

  late final VideoDetailController videoDetailController;
  late final CommonIntroController introController;

  /// Always-available shared player instance (created by
  /// [VideoDetailController]); used for reactive reads and commands.
  late final PlPlayerController playerCtr =
      videoDetailController.plPlayerController;

  /// Non-null once a playback session started. Mirrors the mobile page's
  /// nullable field: on dispose it decides between a full player dispose
  /// (session ran) and a plain play-count decrement (it never did).
  PlPlayerController? plPlayerController;

  final RxBool _controlsVisible = false.obs;
  final RxBool _optionsVisible = false.obs;

  /// The "接下来" (up-next) auto-play card shown on completion, or null.
  final Rxn<TvUpNextInfo> _upNext = Rxn<TvUpNextInfo>();
  BaseEpisodeItem? _pendingNext;

  Timer? _hideTimer;
  final FocusNode _focusNode = FocusNode(debugLabel: 'TvVideoPage');

  // ---- Apple-TV-style scrubber state (all pure-Dart; no native calls until
  // commit). Left/Right move a VISUAL target; exactly one native seek fires
  // per gesture. This is the fix for the per-keypress-seek AVPlay race.
  final RxBool _scrubbing = false.obs; // drives the scrubber overlay
  final RxInt _scrubTargetMs = 0.obs; // ms-precise visual target
  int _scrubOriginMs = 0; // playhead at gesture start (per-gesture const)
  DateTime _holdStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRepeatStep = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _scrubCommitTimer; // idle auto-commit
  // ---- landing: hold isSeeking=true after commit until the engine arrives ----
  int? _pendingLandMs; // committed target awaiting stream confirmation
  Timer? _landingTimer;
  int _landingWaits = 0; // re-arm count for the landing timeout on slow seeks
  bool _wasPlayingAtScrubStart = true; // only auto-resume if playing pre-scrub
  DateTime _lastNativeSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  int? _videoShotCid; // invalidate videoShot on episode change

  /// Buffering watchdog: nudges the user toward a faster CDN line when playback
  /// stalls for a sustained stretch (see [_watchBufferingForLag]).
  Timer? _lagPollTimer;
  DateTime? _bufferingSince;
  DateTime _lastLagToast = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _seekStep = Duration(seconds: 10);
  static const Duration _autoHideDelay = Duration(seconds: 4);

  // ---- scrubber tuning ----
  static const Duration _scrubIdleCommit = Duration(milliseconds: 1000);
  static const Duration _scrubRepeatThrottle = Duration(milliseconds: 200);
  static const Duration _minNativeSeekGap = Duration(milliseconds: 500);
  static const Duration _landingTimeout = Duration(milliseconds: 1500);
  static const int _landingToleranceMs = 3000;
  static const int _maxLandingWaits = 6; // 6 × _landingTimeout = 9s hard cap
  static const int _commitEndGuardMs = 1000; // never commit into the last second
  static const int _noopThresholdMs = 1000; // |target-origin| below ⇒ no seek

  /// How long playback must stay buffering before the slow-line nudge, and the
  /// minimum gap between nudges.
  static const Duration _lagGrace = Duration(seconds: 8);
  static const Duration _lagToastCooldown = Duration(seconds: 30);

  bool get _hasPlayer => playerCtr.videoPlayerController != null;

  @override
  void initState() {
    super.initState();

    final arguments = Get.arguments;
    final heroTagArgument = arguments is Map ? arguments['heroTag'] : null;
    final titleArgument = arguments is Map ? arguments['title'] : null;
    heroTag = heroTagArgument is String
        ? heroTagArgument
        : 'tv-video-${identityHashCode(this)}';
    _argTitle = titleArgument is String ? titleArgument : '';

    // Same controller graph as the mobile page (all tagged with heroTag and
    // route-scoped, so GetX deletes them when this route is popped).
    videoDetailController = Get.put(VideoDetailController(), tag: heroTag);

    if (videoDetailController.showReply) {
      // Not rendered on TV, but the intro controller resolves it by tag when
      // the intro request returns (reply count); it does not query by itself.
      Get.put(
        VideoReplyController(
          aid: videoDetailController.aid,
          videoType: videoDetailController.videoType,
          heroTag: heroTag,
        ),
        tag: heroTag,
      );
    }

    introController = videoDetailController.isFileSource
        ? Get.put(LocalIntroController(), tag: heroTag)
        : videoDetailController.isUgc
        ? Get.put(UgcIntroController(), tag: heroTag)
        : Get.put(PgcIntroController(), tag: heroTag);

    // Autoplay defaults ON for TV. VideoDetailController seeds autoPlay from
    // Pref.autoPlayEnable, whose mobile default is off — which left TV videos
    // paused at 00:00. Read the same key the 自动播放 toggle in TvSettings
    // writes, with a TV default of true, so an explicit "off" is respected.
    // Must precede queryVideoUrl(): its completion gates playerInit on
    // autoPlay.
    if (GStorage.setting.get(
      SettingBoxKey.autoPlayEnable,
      defaultValue: true,
    )) {
      videoDetailController.autoPlay = true;
    }

    // Autoplay is triggered by PlPlayerController._initializePlayer calling
    // playIfExists(), which invokes the static _playCallBack. The mobile video
    // view registers that callback (setPlayCallBack); this TV page must too, or
    // autoplay silently no-ops and the video loads paused. Register it BEFORE
    // queryVideoUrl() so the callback exists when playerInit runs.
    PlPlayerController.setPlayCallBack(playerCtr.play);

    videoDetailController.queryVideoUrl();
    if (videoDetailController.autoPlay) {
      plPlayerController = playerCtr
        ..addStatusLister(_statusListener)
        ..addPositionListener(_positionListener);
    }
    _watchBufferingForLag();
  }

  /// Nudge the user toward a faster CDN line when the stream stalls for a
  /// sustained stretch — whether it can't even start (a stuck initial load) or
  /// re-buffers mid-playback. The common cause on this port is Bilibili placing
  /// a video's stream on a slow per-object mirror while the CDN speed test (a
  /// different sample) reads fast — so "check your wifi" is misleading; the
  /// actionable fix is switching the line.
  ///
  /// Polls rather than reacting to [PlPlayerController.isBuffering] edges,
  /// because a stuck load leaves it `true` from the start (no edge fires) and we
  /// still want to catch it once it's abnormal (> [_lagGrace]).
  void _watchBufferingForLag() {
    _lagPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final ds = playerCtr.dataStatus.value;
      final stalling = playerCtr.isBuffering.value &&
          (ds == DataStatus.loading || ds == DataStatus.loaded);
      if (!stalling) {
        _bufferingSince = null;
        return;
      }
      final now = DateTime.now();
      _bufferingSince ??= now;
      if (now.difference(_bufferingSince!) >= _lagGrace &&
          now.difference(_lastLagToast) >= _lagToastCooldown) {
        _lastLagToast = now;
        SmartDialog.showToast(
          '当前 CDN 线路较慢导致卡顿，按 ▲ 打开播放选项 → CDN 线路 可切换更快线路',
          displayTime: const Duration(seconds: 4),
        );
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _lagPollTimer?.cancel();
    _scrubCommitTimer?.cancel();
    _landingTimer?.cancel();
    _focusNode.dispose();
    _controlsVisible.close();
    _upNext.close();
    _optionsVisible.close();
    _scrubbing.close();
    _scrubTargetMs.close();

    plPlayerController
      ?..removeStatusLister(_statusListener)
      ..removePositionListener(_positionListener);
    // Clear the play callback registered in initState so it can't fire on a
    // disposed controller after this page is popped.
    PlPlayerController.setPlayCallBack(null);

    introController.cancelTimer();
    if (!videoDetailController.isFileSource && videoDetailController.isUgc) {
      introController.videoDetail.close();
    }

    // Same session teardown as the mobile page.
    if (!playerCtr.isCloseAll) {
      videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
      if (plPlayerController != null) {
        videoDetailController.makeHeartBeat();
        plPlayerController!.dispose();
      } else {
        PlPlayerController.updatePlayCount();
      }
    }

    super.dispose();
  }

  /// Keeps watch-progress current for the heartbeat on dispose, and — while a
  /// committed seek is in flight — releases the scrubber's `isSeeking` hold once
  /// the engine's real position lands within tolerance of the target (or the
  /// [_landingTimeout] fallback fires). Holding `isSeeking` through this window
  /// stops the stale position stream from snapping the bar back, since
  /// [PlPlayerController.seekTo] does not await the native seek.
  void _positionListener(Duration position) {
    videoDetailController.playedTime = position;
    final land = _pendingLandMs;
    if (land != null) {
      final int posMs = position.inMilliseconds;
      final int toTarget = (posMs - land).abs();
      // Confirm only when the engine's real position is within tolerance of the
      // committed target AND closer to it than to the scrub origin. A stale
      // pre-seek tick sits near the origin, so it can't prematurely "confirm" a
      // small edge-clamped jump (delta 1–3s); the post-seek tick still confirms.
      if (toTarget < _landingToleranceMs &&
          toTarget < (posMs - _scrubOriginMs).abs()) {
        playerCtr.position.value = position.inSeconds; // truth from the engine
        _releaseLanding();
      }
    }
  }

  /// Pins the control bar while paused/completed; re-arms auto-hide on play.
  /// On completion, hands off to [_handleCompletion] (播放顺序 → replay / 接下来
  /// / stop).
  void _statusListener(PlayerStatus status) {
    if (status.isCompleted) {
      _handleCompletion();
    }
    if (status.isPlaying) {
      _dismissUpNext(); // a new video started — clear any lingering card
      if (_controlsVisible.value) {
        _scheduleHide();
      }
    } else {
      _hideTimer?.cancel();
      _controlsVisible.value = true;
    }
  }

  /// Video finished: honor the 播放顺序 ([PlayRepeat]) setting. Single-cycle
  /// replays; the autoplay modes show the 接下来 card for the next 分P/合集
  /// episode (or advance silently via the engine when there's no rich
  /// preview); 播完暂停 stays on the finished frame with the control bar pinned.
  void _handleCompletion() {
    final player = plPlayerController;
    if (player == null) return;
    switch (player.playRepeat) {
      case PlayRepeat.singleCycle:
        player.play(repeat: true);
      case PlayRepeat.pause:
        break;
      case PlayRepeat.listOrder:
      case PlayRepeat.listCycle:
      case PlayRepeat.autoPlayRelated:
        final intro = introController;
        final next = intro is UgcIntroController ? intro.peekNext() : null;
        if (next != null) {
          _pendingNext = next;
          _upNext.value = TvUpNextInfo.from(next);
        } else if (intro is UgcIntroController) {
          intro.nextPlay();
        }
    }
  }

  /// Plays the previewed next item (OK or countdown end).
  void _playPendingNext() {
    final item = _pendingNext;
    _dismissUpNext();
    if (item != null && introController is UgcIntroController) {
      (introController as UgcIntroController).onChangeEpisode(item);
    }
  }

  void _dismissUpNext() {
    _pendingNext = null;
    if (_upNext.value != null) _upNext.value = null;
  }

  void _showControls() {
    _controlsVisible.value = true;
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    _controlsVisible.value = false;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (playerCtr.playerStatus.isPlaying) {
        _controlsVisible.value = false;
      }
    });
  }

  /// Opens the options panel ([TvPlayerOptions]). Requires a playback
  /// session: before one exists there is nothing to configure, so just peek
  /// the controls instead.
  void _openOptions() {
    if (plPlayerController == null) {
      _showControls();
      return;
    }
    _hideControls();
    _optionsVisible.value = true;
  }

  void _closeOptions() {
    if (!_optionsVisible.value) return;
    _optionsVisible.value = false;
    // Hand the D-pad back to the page.
    _focusNode.requestFocus();
  }

  /// OK: toggle play/pause; if autoplay is off and no session exists yet,
  /// start one (mirrors the mobile `handlePlay`).
  void _togglePlayPause() {
    if (videoDetailController.autoPlay) {
      if (_hasPlayer) {
        playerCtr.onDoubleTapCenter();
      }
    } else {
      _startPlaySession();
    }
  }

  Future<void>? _startPlaySession() {
    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isQuerying) {
        return null;
      }
      if (videoDetailController.videoUrl == null ||
          videoDetailController.audioUrl == null) {
        videoDetailController.queryVideoUrl();
        return null;
      }
    }
    final ctr = plPlayerController = playerCtr;
    videoDetailController.autoPlay = true;
    ctr
      ..addStatusLister(_statusListener)
      ..addPositionListener(_positionListener);
    if (ctr.preInitPlayer) {
      return ctr.play();
    }
    return videoDetailController.playerInit(autoplay: true);
  }

  /// Left/Right handler: enter scrub mode on the first press, then nudge the
  /// VISUAL target. Fires ZERO native seeks — the target is pure Dart state;
  /// [_commitScrub] issues the single seek later.
  void _scrubBy({required bool forward, required bool isRepeat}) {
    if (!_hasPlayer) return;
    final int durMs = playerCtr.durationInMilliseconds;
    if (durMs <= 0 || playerCtr.isLive) return;
    final now = DateTime.now();

    if (!_scrubbing.value) {
      // Seed from the still-in-flight commit target if the user re-scrubs before
      // the last seek landed, else the true playhead — never the stale stream.
      _scrubOriginMs = _pendingLandMs ??
          playerCtr.videoPlayerController!.position.inMilliseconds;
      _scrubTargetMs.value = _scrubOriginMs;
      // Kill any still-live landing from the previous commit: otherwise its
      // stream-confirmation or timeout can fire mid-gesture and release
      // isSeeking, letting the position poll snap the bar back to the old
      // playhead — the exact regression the scrubber exists to prevent.
      _landingTimer?.cancel();
      _landingTimer = null;
      _pendingLandMs = null;
      _wasPlayingAtScrubStart = playerCtr.playerStatus.isPlaying;
      playerCtr.isSeeking.value = true; // freeze position.value vs the stream
      _scrubbing.value = true;
      _controlsVisible.value = true;
      _hideTimer?.cancel();
      _warmVideoShot();
      _holdStartedAt = now;
    }

    int stepSec;
    if (isRepeat) {
      if (now.difference(_lastRepeatStep) < _scrubRepeatThrottle) return;
      _lastRepeatStep = now;
      stepSec = _stepSecondsForHold(now.difference(_holdStartedAt));
    } else {
      // A fresh tap always resets the acceleration to the base 10s step.
      _holdStartedAt = now;
      _lastRepeatStep = now;
      stepSec = _seekStep.inSeconds;
    }

    final int deltaMs = stepSec * 1000 * (forward ? 1 : -1);
    _scrubTargetMs.value =
        (_scrubTargetMs.value + deltaMs).clamp(0, durMs).toInt();
    // The pink fill + left time label read position.value (seconds) — sync it
    // so they follow the target for free while isSeeking gates the stream.
    playerCtr.position.value = _scrubTargetMs.value ~/ 1000;
    _armIdleCommit();
  }

  /// Acceleration curve for a held key (time-based, so it is independent of the
  /// unknown Tizen key-repeat rate): 10s → 30s → 60s, and up to duration/20 for
  /// very long videos once held a while.
  int _stepSecondsForHold(Duration held) {
    if (held < const Duration(milliseconds: 1600)) return 10;
    if (held < const Duration(seconds: 4)) return 30;
    final int durSec = playerCtr.durationInMilliseconds ~/ 1000;
    if (held >= const Duration(seconds: 7) && durSec > 2400) {
      return (durSec ~/ 20).clamp(60, 300).toInt();
    }
    return 60;
  }

  void _armIdleCommit() {
    _scrubCommitTimer?.cancel();
    _scrubCommitTimer = Timer(_scrubIdleCommit, _commitScrub);
  }

  /// Commit the scrub with EXACTLY ONE native seek (on OK or idle). Enforces a
  /// wall-clock floor between native seeks (they cannot be serialized via the
  /// future — [PlPlayerController.seekTo] does not await the native op).
  void _commitScrub() {
    _scrubCommitTimer?.cancel();
    if (!_scrubbing.value) return; // already committed/cancelled (OK-spam guard)

    final sinceLast = DateTime.now().difference(_lastNativeSeekAt);
    if (sinceLast < _minNativeSeekGap) {
      _scrubCommitTimer = Timer(_minNativeSeekGap - sinceLast, _commitScrub);
      return;
    }

    final int durMs = playerCtr.durationInMilliseconds;
    final int targetMs = _scrubTargetMs.value
        .clamp(0, math.max(0, durMs - _commitEndGuardMs))
        .toInt();
    _scrubbing.value = false;

    if ((targetMs - _scrubOriginMs).abs() < _noopThresholdMs || !_hasPlayer) {
      _cancelScrubInternal(); // restore true position, isSeeking=false, 0 seeks
      return;
    }

    // LANDING: hold isSeeking until the engine arrives so the stale stream can't
    // snap the bar back before the seek takes effect. Re-assert it here (not just
    // at gesture start) so a commit that follows a re-scrub is self-protecting.
    playerCtr.isSeeking.value = true;
    _pendingLandMs = targetMs;
    _landingWaits = 0;
    _lastNativeSeekAt = DateTime.now();
    final seekFuture =
        playerCtr.seekTo(Duration(milliseconds: targetMs), isSeek: false);
    // Only auto-resume if the video was playing before the scrub — committing a
    // scrub started while paused must not force it back into playback.
    if (_wasPlayingAtScrubStart) {
      seekFuture.whenComplete(playerCtr.play);
    }
    _landingTimer?.cancel();
    _landingTimer = Timer(_landingTimeout, _onLandingTimeout);
    _showControls();
  }

  /// The landing timeout is a *backstop*, not a hard deadline: on a slow CDN the
  /// native seek can outlive one [_landingTimeout], so re-arm while the commit is
  /// still unconfirmed — up to [_maxLandingWaits] (a ~9s hard cap that preserves
  /// the "isSeeking can never stick forever" guarantee). The real release happens
  /// in [_positionListener] the moment the engine reports arrival.
  void _onLandingTimeout() {
    if (_pendingLandMs != null && ++_landingWaits < _maxLandingWaits) {
      _landingTimer = Timer(_landingTimeout, _onLandingTimeout);
      return;
    }
    _releaseLanding();
  }

  /// Back while scrubbing: abandon the target, snap the bar to the true
  /// playhead, issue ZERO native seeks.
  void _cancelScrub() {
    _cancelScrubInternal();
    _showControls();
  }

  void _cancelScrubInternal() {
    _scrubCommitTimer?.cancel();
    _scrubbing.value = false;
    playerCtr.isSeeking.value = false;
    final int realSec = playerCtr.videoPlayerController?.position.inSeconds ??
        _scrubOriginMs ~/ 1000;
    playerCtr.position.value = realSec;
  }

  void _releaseLanding() {
    _landingTimer?.cancel();
    _landingTimer = null;
    _pendingLandMs = null;
    playerCtr.isSeeking.value = false; // stream resumes driving position.value
  }

  /// Kick off the Bilibili videoshot sprite fetch when scrubbing starts (reuses
  /// the mobile machinery). Unlike [PlPlayerController.updatePreviewIndex] it
  /// does NOT raise `showPreview`, so the mobile centered preview stays hidden —
  /// the TV scrubber draws its own thumbnail above the bar instead.
  void _warmVideoShot() {
    if (videoDetailController.isFileSource || !playerCtr.showSeekPreview) return;
    final int cid = videoDetailController.cid.value;
    if (_videoShotCid != cid) {
      _videoShotCid = cid; // episode changed → refetch for the new cid
      playerCtr.videoShot = null;
    }
    if (playerCtr.videoShot == null) {
      playerCtr.videoShot = LoadingState.loading();
      playerCtr.getVideoShot().whenComplete(() {
        // videoShot is not reactive; nudge the bubble to repaint when it lands.
        if (mounted && _scrubbing.value) _scrubTargetMs.refresh();
      });
    }
  }

  /// The bubble above the scrub thumb: a Bilibili-videoshot preview frame at the
  /// target time (when the sprite sheet is available) over the target time and a
  /// signed delta. Degrades to time+delta only when there is no preview data
  /// (file source, pref off, fetch pending/failed, or a shot-less video).
  Widget _buildScrubBubble() {
    const double ds = TvTheme.designScale;
    final int targetMs = _scrubTargetMs.value;
    final int targetSec = targetMs ~/ 1000;
    final int deltaSec = (targetMs - _scrubOriginMs) ~/ 1000;

    Widget? thumb;
    if (playerCtr.videoShot case Success(:final VideoShotData response)
        when response.index.isNotEmpty &&
            response.image.isNotEmpty &&
            response.imgXLen > 0 &&
            response.imgYLen > 0) {
      final int idx =
          math.max(0, response.index.where((t) => t <= targetSec).length - 1);
      final int page =
          (idx ~/ response.totalPerImage).clamp(0, response.image.length - 1);
      final int a = idx % response.totalPerImage;
      thumb = VideoShotImage(
        url: response.image[page],
        x: a % response.imgXLen,
        y: a ~/ response.imgXLen,
        imgXSize: response.imgXSize,
        imgYSize: response.imgYSize,
        height: 214 * ds,
        imageCache: playerCtr.previewCache,
        onSetSize: (xs, ys) {
          response
            ..imgXSize = xs
            ..imgYSize = ys;
        },
        isMounted: () => mounted,
      );
    }

    final String sign = deltaSec > 0 ? '+' : (deltaSec < 0 ? '−' : '');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (thumb != null)
          Container(
            width: 380 * ds,
            height: 214 * ds,
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: TvTheme.surface,
              borderRadius: BorderRadius.circular(12 * ds),
              border: Border.all(color: Colors.white24, width: 2),
            ),
            child: thumb,
          ),
        const SizedBox(height: 8 * ds),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(8 * ds),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14 * ds,
              vertical: 6 * ds,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DurationUtils.formatDuration(targetSec),
                  style: TvTheme.cardMeta.copyWith(
                    fontSize: 30 * ds,
                    fontWeight: FontWeight.w600,
                    color: TvTheme.textPrimary,
                  ),
                ),
                if (deltaSec != 0) ...[
                  const SizedBox(width: 10 * ds),
                  Text(
                    '$sign${DurationUtils.formatDuration(deltaSec.abs())}',
                    style: TvTheme.cardMeta.copyWith(
                      fontSize: 24 * ds,
                      color: TvTheme.brandPink,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;
    final isDownOrRepeat = isDown || event is KeyRepeatEvent;

    if (_upNext.value != null) {
      // The card (a focused TvFocusable) handles OK / arrows itself; backstop
      // Back here to dismiss the up-next overlay.
      if (key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.browserBack ||
          key == LogicalKeyboardKey.escape) {
        if (isDown) _dismissUpNext();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (_optionsVisible.value) {
      // The options panel's own Focus handles navigation before events reach
      // this node; backstop Back here (e.g. for the frame before the panel
      // takes focus) and let everything else fall through to the app-level
      // handlers (select -> ActivateIntent on the focused row).
      if (key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.browserBack ||
          key == LogicalKeyboardKey.escape) {
        if (isDown) {
          _closeOptions();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // While scrubbing, the D-pad drives the scrubber. Back cancels (0 seeks),
    // OK commits the single seek, Up/Down are consumed (no menu/controls
    // mid-gesture), and Left/Right fall through to the arrow branch to adjust
    // the target.
    if (_scrubbing.value) {
      if (key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.browserBack ||
          key == LogicalKeyboardKey.escape) {
        if (isDown) _cancelScrub();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.mediaPlayPause ||
          key == LogicalKeyboardKey.mediaPlay ||
          key == LogicalKeyboardKey.mediaPause) {
        if (isDown) _commitScrub();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.contextMenu) {
        return KeyEventResult.handled;
      }
    }

    // Back: hide the control bar if it is showing during playback; otherwise
    // leave the event unhandled so the app-level BackDetector pops the route.
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (isDown &&
          _controlsVisible.value &&
          playerCtr.playerStatus.isPlaying) {
        _hideControls();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final isBackwardKey =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind;
    if (isBackwardKey ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      if (isDownOrRepeat) {
        _scrubBy(
          forward: !isBackwardKey,
          isRepeat: event is KeyRepeatEvent,
        );
      }
      return KeyEventResult.handled;
    }

    // Up (or the remote's menu key): open the options panel.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.contextMenu) {
      if (isDown) {
        _openOptions();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (isDown) {
        _showControls();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (isDown) {
        _togglePlayPause();
        _showControls();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaPlay) {
      if (isDown && _hasPlayer && !playerCtr.playerStatus.isPlaying) {
        playerCtr.play();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaPause) {
      if (isDown && _hasPlayer && playerCtr.playerStatus.isPlaying) {
        playerCtr.pause();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // Always dark/cinematic, matching the rest of the TV UI.
    return Theme(
      data: ThemeUtils.darkTheme,
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Same gate as the mobile page uses on Tizen: build the player
              // once the source is loaded; PLVideoPlayer then reveals the
              // AVPlay hole-punch surface itself. A fullscreen widget rect
              // means a fullscreen native video ROI.
              Obx(
                () => videoDetailController.videoState.value
                    ? _buildPlayer(size)
                    : _buildLoading(size),
              ),
              _buildTopBar(),
              _buildControlBar(),
              // In-player options panel, opened with Up.
              Obx(
                () => _optionsVisible.value
                    ? TvPlayerOptions(
                        plPlayerController: playerCtr,
                        videoDetailController: videoDetailController,
                        introController: introController,
                        onClose: _closeOptions,
                      )
                    : const SizedBox.shrink(),
              ),
              // "接下来" (up-next) auto-play overlay over the dimmed final frame.
              Obx(() {
                final info = _upNext.value;
                if (info == null) return const SizedBox.shrink();
                return Positioned.fill(
                  child: ColoredBox(
                    color: TvTheme.overlayScrim,
                    child: Stack(
                      children: [
                        Positioned(
                          right: TvTheme.upNextInset,
                          bottom: TvTheme.upNextInset,
                          child: TvUpNextCard(
                            info: info,
                            onPlayNow: _playPendingNext,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// The exact widget the mobile page embeds (see its `plPlayer()`), minus the
  /// mobile Scaffold around it. `plPlayerController!` is safe here: videoState
  /// only turns true after a session set it (autoplay or [_startPlaySession]).
  Widget _buildPlayer(Size size) {
    return PLVideoPlayer(
      maxWidth: size.width,
      maxHeight: size.height,
      plPlayerController: plPlayerController!,
      videoDetailController: videoDetailController,
      introController: introController,
      headerControl: HeaderControl(
        key: videoDetailController.headerCtrKey,
        isPortrait: false,
        controller: playerCtr,
        videoDetailCtr: videoDetailController,
        heroTag: heroTag,
      ),
      danmuWidget: Obx(
        () => PlDanmaku(
          key: ValueKey(videoDetailController.cid.value),
          cid: videoDetailController.cid.value,
          playerController: plPlayerController!,
          isFullScreen: plPlayerController!.isFullScreen.value,
          isFileSource: videoDetailController.isFileSource,
          size: size,
        ),
      ),
    );
  }

  /// Cover + spinner while the play-url request / player prepare runs.
  Widget _buildLoading(Size size) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Obx(() {
          final cover = videoDetailController.cover.value;
          if (cover.isEmpty) {
            return const ColoredBox(color: Colors.black);
          }
          return NetworkImgLayer(
            src: cover,
            width: size.width,
            height: size.height,
            borderRadius: BorderRadius.zero,
          );
        }),
        const ColoredBox(color: Color(0x99000000)),
        const Center(
          child: SizedBox(
            width: TvTheme.spinnerSize,
            height: TvTheme.spinnerSize,
            child: CircularProgressIndicator(
              strokeWidth: TvTheme.spinnerStroke,
              color: TvTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  String get _title {
    final title = introController.videoDetail.value.title;
    return title?.isNotEmpty == true ? title! : _argTitle;
  }

  /// Live "now playing" readout, e.g. "1080P 高清 · H.265 · 1920×1080".
  /// Quality and codec come from the resolved play-url (the reactive
  /// `currentVideoQa` also guards the late `currentDecodeFormats`; both are
  /// assigned together); the frame size is appended once the engine reports
  /// it. Empty until the play-url resolved.
  String get _formatReadout {
    final qa = videoDetailController.currentVideoQa.value;
    if (qa == null) {
      return '';
    }
    final buffer = StringBuffer(qa.desc)
      ..write(' · ')
      ..write(
        TvPlayerOptions.codecLabel(videoDetailController.currentDecodeFormats),
      );
    final player = playerCtr.videoPlayerController;
    if (player != null && player.videoWidth > 0 && player.videoHeight > 0) {
      buffer.write(' · ${player.videoWidth}×${player.videoHeight}');
    }
    // Nominal video bitrate of the selected DASH stream (bits/s → Mbps).
    final bw = videoDetailController.firstVideo.bandWidth;
    if (bw != null && bw > 0) {
      buffer.write(' · ${(bw / 1000000).toStringAsFixed(1)} Mbps');
    }
    return buffer.toString();
  }

  /// Back/title pill (top-left). Fades in/out with the controls so the video
  /// plays uncluttered; any key press reveals the controls (and this title).
  Widget _buildTopBar() {
    return Positioned(
      top: 28 * TvTheme.designScale,
      left: 36 * TvTheme.designScale,
      child: Obx(
        () => IgnorePointer(
          child: AnimatedOpacity(
            opacity: _controlsVisible.value ? 1 : 0,
            duration: TvTheme.focusDuration,
            curve: Curves.easeOutCubic,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Color(0x66000000),
                borderRadius: TvTheme.tabRadius,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20 * TvTheme.designScale,
                  vertical: 10 * TvTheme.designScale,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.arrow_back_rounded,
                      size: 26 * TvTheme.designScale,
                      color: TvTheme.textSecondary,
                    ),
                    const SizedBox(width: 10 * TvTheme.designScale),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: 720 * TvTheme.designScale,
                      ),
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TvTheme.cardMeta,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Bottom control bar: play state + title, buffered progress, times, and a
  /// key hint. Slides/fades away after [_autoHideDelay] of no input.
  Widget _buildControlBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Obx(() {
        final visible = _controlsVisible.value && _upNext.value == null;
        return IgnorePointer(
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.2),
            duration: TvTheme.focusDuration,
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: TvTheme.focusDuration,
              curve: Curves.easeOutCubic,
              child: _buildControlBarContent(),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildControlBarContent() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xE6000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          TvTheme.screenPadding,
          96 * TvTheme.designScale,
          TvTheme.screenPadding,
          40 * TvTheme.designScale,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Obx(() {
                  final status = playerCtr.playerStatus.value;
                  return Icon(
                    status.isPlaying
                        ? Icons.pause_rounded
                        : status.isCompleted
                        ? Icons.replay_rounded
                        : Icons.play_arrow_rounded,
                    size: 52 * TvTheme.designScale,
                    color: TvTheme.textPrimary,
                  );
                }),
                const SizedBox(width: 20 * TvTheme.designScale),
                Expanded(
                  child: Obx(
                    () => Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvTheme.cardTitle.copyWith(
                        fontSize: 30 * TvTheme.designScale,
                      ),
                    ),
                  ),
                ),
                // What's playing: quality · codec · resolution.
                Obx(() {
                  final readout = _formatReadout;
                  if (readout.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(
                      left: 24 * TvTheme.designScale,
                    ),
                    child: Text(readout, style: TvTheme.cardMeta),
                  );
                }),
              ],
            ),
            const SizedBox(height: 20 * TvTheme.designScale),
            Obx(() {
              final int duration = playerCtr.duration.value;
              final int position = playerCtr.position.value;
              final int buffered = playerCtr.buffered.value;
              final bool scrubbing = _scrubbing.value;
              final int targetMs = _scrubTargetMs.value;
              final int durMs = playerCtr.durationInMilliseconds;
              final double playedFactor = duration > 0
                  ? (position / duration).clamp(0.0, 1.0)
                  : 0.0;
              final double bufferedFactor = duration > 0
                  ? (buffered / duration).clamp(0.0, 1.0)
                  : 0.0;
              final double targetFrac =
                  durMs > 0 ? (targetMs / durMs).clamp(0.0, 1.0) : 0.0;
              final double originFrac =
                  durMs > 0 ? (_scrubOriginMs / durMs).clamp(0.0, 1.0) : 0.0;
              const double ds = TvTheme.designScale;
              const double bubbleW = 380 * ds;
              return Column(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final double w = constraints.maxWidth;
                      return SizedBox(
                        height: 8 * ds,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ClipRRect(
                              borderRadius: const BorderRadius.all(
                                Radius.circular(4 * ds),
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  const ColoredBox(color: Color(0x38FFFFFF)),
                                  FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: bufferedFactor,
                                    child: const ColoredBox(
                                      color: Color(0x59FFFFFF),
                                    ),
                                  ),
                                  FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: playedFactor,
                                    child: const ColoredBox(
                                      color: TvTheme.brandPink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (scrubbing) ...[
                              // Origin tick: where playback actually still is.
                              Positioned(
                                left: originFrac * w - 2 * ds,
                                top: -4 * ds,
                                bottom: -4 * ds,
                                child: const SizedBox(
                                  width: 4 * ds,
                                  child: ColoredBox(color: Color(0xE6FFFFFF)),
                                ),
                              ),
                              // Bright target thumb.
                              Positioned(
                                left: targetFrac * w - 10 * ds,
                                top: -6 * ds,
                                child: Container(
                                  width: 20 * ds,
                                  height: 20 * ds,
                                  decoration: BoxDecoration(
                                    color: TvTheme.brandPink,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                              // Thumbnail + target-time/delta bubble.
                              Positioned(
                                bottom: 28 * ds,
                                left: (targetFrac * w - bubbleW / 2).clamp(
                                  0.0,
                                  math.max(0.0, w - bubbleW),
                                ),
                                child: SizedBox(
                                  width: bubbleW,
                                  child: _buildScrubBubble(),
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14 * ds),
                  Row(
                    children: [
                      Text(
                        DurationUtils.formatDuration(position),
                        style: TvTheme.cardMeta,
                      ),
                      const Spacer(),
                      Text(
                        scrubbing
                            ? 'OK 跳转 · ◀ ▶ 调整 · 返回 取消'
                            : '▲ 选项 · ◀ ▶ 快退/快进 · OK 播放/暂停 · 返回 退出',
                        style: TvTheme.cardMeta,
                      ),
                      const Spacer(),
                      Text(
                        DurationUtils.formatDuration(duration),
                        style: TvTheme.cardMeta,
                      ),
                    ],
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
