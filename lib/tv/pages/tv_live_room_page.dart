import 'dart:async';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/superchat/superchat_card.dart';
import 'package:PiliPlus/pages/live_room/view.dart' show LiveDanmaku;
import 'package:PiliPlus/pages/live_room/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_chip.dart';
import 'package:PiliPlus/tv/widgets/tv_live_chat_panel.dart';
import 'package:PiliPlus/tv/widgets/tv_live_options.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// TV (D-pad) live-room page: the same live session as the mobile
/// [LiveRoomPage] — [LiveRoomController] + [PlPlayerController] +
/// [PLVideoPlayer] wired identically — presented fullscreen with TV chrome.
///
/// A [TvVideoPage] clone with the VOD-only layers removed (scrubber, related
/// row, up-next / end card, completion handling): live is a single unbounded
/// stream, so there is nothing to scrub or "finish". The mobile in-player
/// chrome stays dormant ([PlPlayerController.showControls] never rises); this
/// page draws its own overlay:
/// * an always-on back / 直播 / title pill (top-left), and
/// * an auto-hiding bottom INFO bar (play state, anchor, watched count,
///   开播-elapsed time, current-quality chip — no progress bar).
///
/// D-pad, handled by the root [Focus] node: OK toggles play/pause, Up (or the
/// remote menu key) opens the options panel ([TvLiveOptions]), Down toggles the
/// chat rail (Phase 3; the flag is wired here), Right quick-toggles the danmaku
/// bullets with a feedback pill, Left peeks the chrome (never scrubs / switches
/// quality — accidental-reinit guard), Back dismisses the rail → chrome → pops.
class TvLiveRoomPage extends StatefulWidget {
  const TvLiveRoomPage({super.key});

  @override
  State<TvLiveRoomPage> createState() => _TvLiveRoomPageState();
}

class _TvLiveRoomPageState extends State<TvLiveRoomPage> {
  final String heroTag = Utils.generateRandomString(6);

  late final LiveRoomController liveCtr;

  /// The shared live player instance (created eagerly by the controller via
  /// `PlPlayerController.getInstance(isLive: true)`); used for reactive reads
  /// and commands.
  PlPlayerController get playerCtr => liveCtr.plPlayerController;

  final RxBool _controlsVisible = false.obs;
  final RxBool _optionsVisible = false.obs;

  /// Chat rail toggle. Wired here so Down/Back behave; the passive rail panel
  /// itself lands in Phase 3.
  final RxBool _chatVisible = false.obs;

  /// Transient "弹幕 开/关" feedback pill, cleared after [_feedbackDelay].
  final RxnString _danmakuFeedback = RxnString();
  Timer? _feedbackTimer;

  Timer? _hideTimer;
  final FocusNode _focusNode = FocusNode(debugLabel: 'TvLiveRoomPage');

  /// Buffering watchdog: nudges the user toward 刷新 / 清晰度 when the live CDN
  /// stalls for a sustained stretch (see [_watchBufferingForLag]).
  Timer? _lagPollTimer;
  DateTime? _bufferingSince;
  DateTime _lastLagToast = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _autoHideDelay = Duration(seconds: 4);
  static const Duration _feedbackDelay = Duration(seconds: 2);

  /// How long playback must stay buffering before the slow-line nudge, and the
  /// minimum gap between nudges.
  static const Duration _lagGrace = Duration(seconds: 8);
  static const Duration _lagToastCooldown = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();

    // Same controller graph as the mobile live page (tagged with heroTag and
    // route-scoped, so GetX deletes it when this route is popped). Its onInit
    // resolves the play-url and autoplays; the socket does NOT self-start —
    // the status listener below drives it (mandatory port of the mobile
    // playerListener at live_room/view.dart:160-170).
    liveCtr = Get.put(LiveRoomController(heroTag), tag: heroTag);
    // This page always presents the stream fullscreen, so mirror the mobile
    // view's `isFullScreen` flag (live_room/view.dart:256). The controller gates
    // the fullscreen SuperChat toast (`fsSC`) on it — without this it stays
    // false here and the toast would never populate.
    liveCtr.isFullScreen = true;
    playerCtr.addStatusLister(_statusListener);
    // Autoplay is triggered by PlPlayerController.playIfExists calling the
    // static _playCallBack; register it (mirrors the mobile live view) or the
    // stream loads paused.
    PlPlayerController.setPlayCallBack(playerCtr.play);

    // Live danmaku bullets default ON — the live-culture decision. The pref
    // (`Pref.enableShowLiveDanmaku`) already defaults true, so nothing to force
    // here; Right toggles it off.

    _watchBufferingForLag();
  }

  /// Nudge the user toward a recovery action when the live stream stalls for a
  /// sustained stretch — whether it can't start (a stuck initial load) or
  /// re-buffers mid-playback. Unlike VOD there is no CDN-line switch here, so
  /// point at 刷新直播 / 清晰度 instead. Polls rather than reacting to
  /// [PlPlayerController.isBuffering] edges, because a stuck load leaves it
  /// `true` from the start (no edge fires).
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
          '直播卡顿，按 ▲ 打开选项 → 刷新直播 或降低 清晰度',
          displayTime: const Duration(seconds: 4),
        );
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _lagPollTimer?.cancel();
    _feedbackTimer?.cancel();
    _focusNode.dispose();
    _controlsVisible.close();
    _optionsVisible.close();
    _chatVisible.close();
    _danmakuFeedback.close();

    // Same session teardown as the mobile live page: unwire the callback and
    // dispose the player (the controller's own onClose closes the socket /
    // timers when GetX deletes it on pop).
    videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
    PlPlayerController.setPlayCallBack(null);
    playerCtr
      ..removeStatusLister(_statusListener)
      ..dispose();

    super.dispose();
  }

  /// Ported live playerListener + chrome pinning. Playing → resume danmaku,
  /// start the 开播 timer, open the message socket; paused → pause danmaku,
  /// cancel the timer, close the socket, and pin the INFO bar.
  void _statusListener(PlayerStatus status) {
    if (status.isPlaying) {
      liveCtr
        ..danmakuController?.resume()
        ..startLiveTimer()
        ..startLiveMsg();
      if (_controlsVisible.value) _scheduleHide();
    } else {
      liveCtr
        ..danmakuController?.pause()
        ..cancelLiveTimer()
        ..closeLiveMsg();
      _hideTimer?.cancel();
      _controlsVisible.value = true;
    }
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

  /// Opens the options panel ([TvLiveOptions]). Requires a resolved stream:
  /// before one exists there is nothing to configure, so just peek the chrome.
  void _openOptions() {
    if (!liveCtr.isLoaded.value) {
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

  /// OK: toggle play/pause via the shared gesture path (pausing also closes the
  /// socket through the status listener).
  void _togglePlayPause() {
    if (playerCtr.videoPlayerController != null) {
      playerCtr.onDoubleTapCenter();
    }
  }

  /// Right: quick-toggle the danmaku bullets (same flag + persistence as the
  /// mobile switch) and flash the feedback pill.
  void _toggleLiveDanmaku() {
    final newVal = !playerCtr.enableShowLiveDanmaku.value;
    playerCtr.enableShowLiveDanmaku.value = newVal;
    if (!playerCtr.tempPlayerConf) {
      GStorage.setting.put(SettingBoxKey.enableShowLiveDanmaku, newVal);
    }
    _danmakuFeedback.value = newVal ? '弹幕 开' : '弹幕 关';
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(_feedbackDelay, () {
      if (mounted) _danmakuFeedback.value = null;
    });
  }

  void _toggleChat() {
    _chatVisible.value = !_chatVisible.value;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;

    final isBack = key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape;

    if (_optionsVisible.value) {
      // The options panel's own Focus handles navigation before events reach
      // this node; backstop Back here (the frame before it takes focus) and let
      // everything else fall through to the app-level handlers (OK ->
      // ActivateIntent on the focused row).
      if (isBack) {
        if (isDown) _closeOptions();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Back: dismiss the chat rail, then the chrome; otherwise leave it
    // unhandled so the app-level BackDetector pops the route.
    if (isBack) {
      if (isDown) {
        if (_chatVisible.value) {
          _chatVisible.value = false;
          return KeyEventResult.handled;
        }
        if (_controlsVisible.value && playerCtr.playerStatus.isPlaying) {
          _hideControls();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // Up (or the remote's menu key): open the options panel.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.contextMenu) {
      if (isDown) _openOptions();
      return KeyEventResult.handled;
    }

    // Down: toggle the chat rail (Phase 3 panel; flag wired now).
    if (key == LogicalKeyboardKey.arrowDown) {
      if (isDown) _toggleChat();
      return KeyEventResult.handled;
    }

    // Right: danmaku bullets quick-toggle + feedback pill. Never switches
    // quality (that would re-init the stream) — that lives in the options.
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward) {
      if (isDown) _toggleLiveDanmaku();
      return KeyEventResult.handled;
    }

    // Left: peek the chrome only (live has nothing to scrub).
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind) {
      if (isDown) _showControls();
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
      if (isDown &&
          playerCtr.videoPlayerController != null &&
          !playerCtr.playerStatus.isPlaying) {
        playerCtr.play();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaPause) {
      if (isDown &&
          playerCtr.videoPlayerController != null &&
          playerCtr.playerStatus.isPlaying) {
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
              // Build the player once the play-url is resolved; PLVideoPlayer
              // reveals the AVPlay hole-punch surface itself. A fullscreen
              // widget rect means a fullscreen native video ROI.
              Obx(
                () => liveCtr.isLoaded.value
                    ? _buildPlayer(size)
                    : _buildLoading(size),
              ),
              _buildTopBar(),
              _buildInfoBar(),
              // Self-expiring SuperChat toast (top-left, clear of the info bar
              // and the right-hand chat rail). Reuses the mobile SuperChatCard
              // verbatim; the controller auto-expires fsSC via the card's timer.
              _buildSuperChatToast(),
              // Read-only chat rail, slid in from the right with Down. An
              // overlay over the video — the player is never resized and the
              // danmaku bullets keep drawing beneath it.
              Obx(
                () => _chatVisible.value
                    ? TvLiveChatPanel(liveController: liveCtr)
                    : const SizedBox.shrink(),
              ),
              // In-player options panel, opened with Up.
              Obx(
                () => _optionsVisible.value
                    ? TvLiveOptions(
                        liveController: liveCtr,
                        onClose: _closeOptions,
                      )
                    : const SizedBox.shrink(),
              ),
              // Transient danmaku on/off feedback pill.
              _buildDanmakuFeedback(),
            ],
          ),
        ),
      ),
    );
  }

  /// The exact widget the mobile live page embeds, minus its Scaffold. The
  /// [LiveHeaderControl] is constructed but dormant (never raised), matching how
  /// [TvVideoPage] mounts a dormant VOD `HeaderControl`. `videoDetailController`
  /// / `introController` are omitted (both optional on [PLVideoPlayer]).
  Widget _buildPlayer(Size size) {
    final roomInfoH5 = liveCtr.roomInfoH5.value;
    return PLVideoPlayer(
      maxWidth: size.width,
      maxHeight: size.height,
      plPlayerController: playerCtr,
      headerControl: LiveHeaderControl(
        key: liveCtr.headerKey,
        title: roomInfoH5?.roomInfo?.title,
        upName: roomInfoH5?.anchorInfo?.baseInfo?.uname,
        plPlayerController: playerCtr,
        onSendDanmaku: liveCtr.onSendDanmaku,
        onPlayAudio: liveCtr.queryLiveUrl,
        isPortrait: liveCtr.isPortrait.value,
        liveController: liveCtr,
        onlineWidget: const SizedBox.shrink(),
      ),
      danmuWidget: LiveDanmaku(
        liveRoomController: liveCtr,
        plPlayerController: playerCtr,
        isFullScreen: true,
        size: size,
      ),
    );
  }

  /// Cover + scrim + spinner while the live-url request / player prepare runs.
  Widget _buildLoading(Size size) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Obx(() {
          final cover = liveCtr.roomInfoH5.value?.roomInfo?.cover;
          if (cover == null || cover.isEmpty) {
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

  /// Always-on back / 直播 / title pill (top-left). Unlike the VOD page's pill
  /// this stays visible: a live room has no "resume" affordance, so the room
  /// identity is always on screen.
  Widget _buildTopBar() {
    return Positioned(
      top: 28 * TvTheme.designScale,
      left: 36 * TvTheme.designScale,
      child: IgnorePointer(
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
                const SizedBox(width: 14 * TvTheme.designScale),
                _liveBadge(),
                const SizedBox(width: 12 * TvTheme.designScale),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 720 * TvTheme.designScale,
                  ),
                  child: Obx(
                    () => Text(
                      liveCtr.title.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvTheme.cardMeta,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Red "直播" (on-air) badge for the top pill.
  Widget _liveBadge() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: TvTheme.liveBadge,
        borderRadius: TvTheme.badgeRadius,
      ),
      child: Padding(
        padding: TvTheme.badgePadding,
        child: Text(
          '直播',
          style: TvTheme.durationBadge.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  /// Bottom INFO bar: play state + anchor + current-quality chip, then watched
  /// count + 开播-elapsed time and a key hint. Auto-hides while playing (pinned
  /// while paused). No progress bar — nothing to scrub on a live stream.
  Widget _buildInfoBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Obx(() {
        final visible = _controlsVisible.value;
        return IgnorePointer(
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.2),
            duration: TvTheme.focusDuration,
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: TvTheme.focusDuration,
              curve: Curves.easeOutCubic,
              child: _buildInfoBarContent(),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildInfoBarContent() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: TvTheme.playerBottomGradient,
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
                  final playing = playerCtr.playerStatus.value.isPlaying;
                  return Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 52 * TvTheme.designScale,
                    color: TvTheme.textPrimary,
                  );
                }),
                const SizedBox(width: 20 * TvTheme.designScale),
                Expanded(
                  child: Obx(() {
                    final uname = liveCtr
                        .roomInfoH5.value?.anchorInfo?.baseInfo?.uname;
                    return Text(
                      uname ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvTheme.playerTitle,
                    );
                  }),
                ),
                // Current quality tier.
                Obx(() {
                  final desc = liveCtr.currentQnDesc.value;
                  if (desc.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(
                      left: 24 * TvTheme.designScale,
                    ),
                    child: TvChip(desc),
                  );
                }),
              ],
            ),
            const SizedBox(height: 16 * TvTheme.designScale),
            Row(
              children: [
                liveCtr.watchedWidget,
                const SizedBox(width: TvTheme.metaGap),
                liveCtr.timeWidget,
                const Spacer(),
                const Text(
                  '▲ 选项 · ◀ 显示信息 · ▶ 弹幕 · OK 播放/暂停 · 返回 退出',
                  style: TvTheme.cardMeta,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Fullscreen SuperChat toast: the mobile [SuperChatCard] verbatim, anchored
  /// top-left below the room pill. The card owns its own countdown and clears
  /// itself by nulling [LiveRoomController.fsSC]; that reactive null hides this.
  Widget _buildSuperChatToast() {
    return Obx(() {
      final item = liveCtr.fsSC.value;
      if (item == null) {
        return const SizedBox.shrink();
      }
      return Positioned(
        top: 120 * TvTheme.designScale,
        left: TvTheme.screenPadding,
        width: 620 * TvTheme.designScale,
        child: IgnorePointer(
          child: SuperChatCard(
            key: ValueKey(item.id),
            item: item,
            onRemove: () => liveCtr.fsSC.value = null,
          ),
        ),
      );
    });
  }

  Widget _buildDanmakuFeedback() {
    return Obx(() {
      final text = _danmakuFeedback.value;
      if (text == null) {
        return const SizedBox.shrink();
      }
      return IgnorePointer(
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCC000000),
              borderRadius: BorderRadius.circular(12 * TvTheme.designScale),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 36 * TvTheme.designScale,
                vertical: 20 * TvTheme.designScale,
              ),
              child: Text(text, style: TvTheme.playerTitle),
            ),
          ),
        ),
      );
    });
  }
}
