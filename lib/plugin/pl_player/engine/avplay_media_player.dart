import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:video_player_avplay/video_player.dart';
import 'package:video_player_avplay/video_player_platform_interface.dart'
    show VideoFormat, PlayerEngine;

import 'abstract_media_player.dart';
import 'bili_dash_proxy.dart';

/// [AbstractMediaPlayer] implementation backed by the `video_player_avplay`
/// plugin (Samsung Tizen TV / AVPlay + plusplayer).
///
/// The AVPlay [VideoPlayerController] exposes its whole state through a single
/// [VideoPlayerValue] carried by a [ValueNotifier]. This class bridges that
/// notifier into the discrete broadcast [Stream]s the rest of PiliPlus expects
/// (mirroring the media_kit `Player.stream.*` surface): on every value change it
/// diffs against the previous snapshot and emits the fields that actually moved.
///
/// Key differences that this adapter papers over:
///  * **Volume scale** — the interface speaks percent (0..100), AVPlay speaks
///    a 0..1 linear gain, so every crossing divides / multiplies by 100.
///  * **Dual-stream DASH** — Bilibili ships video and audio as two separate
///    urls, which AVPlay cannot consume. [BiliDashProxy] merges them into a
///    synthetic DASH manifest served from `127.0.0.1` (and injects the mandatory
///    `Referer`). We hand the proxy url to [VideoPlayerController.network].
///  * **Single-use controllers** — an AVPlay controller is bound to one source
///    for its whole lifetime, so [open] tears the old controller down and builds
///    a fresh one every time.
///  * **Subtitles** — rendered by a Flutter overlay (driven by [positionStream]),
///    never by the native decoder; [setSubtitle] just stores + broadcasts.
class AvplayMediaPlayer implements AbstractMediaPlayer {
  /// Creates an AVPlay-backed player. A custom [proxy] may be injected for
  /// testing; otherwise a default [BiliDashProxy] is used.
  AvplayMediaPlayer({BiliDashProxy? proxy})
      : _proxy = proxy ?? BiliDashProxy();

  final BiliDashProxy _proxy;

  // ---- Underlying native controller (recreated on every [open]) ----
  VideoPlayerController? _controller;

  /// Notifies the render layer the instant a new controller is created — BEFORE
  /// it finishes initializing — so the `VideoPlayer` widget (and thus the native
  /// hole-punch display window) is mounted while PlusPlayer's PrepareAsync runs.
  /// Without an existing display, prepare never completes and initialize() hangs.
  final ValueNotifier<VideoPlayerController?> controllerListenable =
      ValueNotifier<VideoPlayerController?>(null);

  /// Previous [VideoPlayerValue] snapshot, used to diff and emit only deltas.
  VideoPlayerValue? _prev;

  // ---- Request headers, set via [setMediaHeader] before [open] ----
  String? _userAgent;
  String? _referer;
  Map<String, String>? _extraHeaders;

  // ---- Local mirror of state that must survive controller recreation ----
  double _volumePercent = 100.0;
  double _rate = 1.0;
  bool _videoDisabled = false;
  MediaSubtitle? _currentSubtitle;
  MediaSource? _currentSource;
  bool _playRequested = true;
  bool _disposed = false;

  // ---- Broadcast event streams ----
  final StreamController<bool> _playingSC = StreamController<bool>.broadcast();
  final StreamController<bool> _completedSC = StreamController<bool>.broadcast();
  final StreamController<Duration> _positionSC =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationSC =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _bufferSC =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _bufferingSC =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorSC = StreamController<String>.broadcast();
  final StreamController<MediaSubtitle?> _subtitleSC =
      StreamController<MediaSubtitle?>.broadcast();

  /// The subtitle currently selected for the Flutter overlay, or null.
  MediaSubtitle? get currentSubtitle => _currentSubtitle;

  /// Fires whenever [setSubtitle] changes the active overlay subtitle.
  Stream<MediaSubtitle?> get subtitleStream => _subtitleSC.stream;

  // ---------------------------------------------------------------------------
  // Synchronous state snapshot
  // ---------------------------------------------------------------------------

  VideoPlayerValue? get _initializedValue {
    final VideoPlayerValue? v = _controller?.value;
    return (v != null && v.isInitialized) ? v : null;
  }

  @override
  Duration get position => _initializedValue?.position ?? Duration.zero;

  @override
  Duration get duration => _initializedValue?.duration.end ?? Duration.zero;

  @override
  Duration get buffer => _bufferOf(_controller?.value);

  @override
  bool get playing => _controller?.value.isPlaying ?? false;

  @override
  bool get completed => _controller?.value.isCompleted ?? false;

  @override
  bool get buffering => _controller?.value.isBuffering ?? false;

  @override
  double get rate => _initializedValue?.playbackSpeed ?? _rate;

  @override
  double get volume => _volumePercent;

  @override
  int get videoWidth => _initializedValue?.size.width.toInt() ?? 0;

  @override
  int get videoHeight => _initializedValue?.size.height.toInt() ?? 0;

  /// AVPlay reports buffered progress as a 0..100 percentage; project it onto
  /// the known duration to obtain the buffered [Duration] the interface wants.
  Duration _bufferOf(VideoPlayerValue? v) {
    if (v == null || !v.isInitialized) {
      return Duration.zero;
    }
    final int totalMs = v.duration.end.inMilliseconds;
    if (totalMs <= 0) {
      return Duration.zero;
    }
    final int pct = v.buffered.clamp(0, 100);
    return Duration(milliseconds: totalMs * pct ~/ 100);
  }

  // ---------------------------------------------------------------------------
  // Reactive event streams
  // ---------------------------------------------------------------------------

  @override
  Stream<bool> get playingStream => _playingSC.stream;

  @override
  Stream<bool> get completedStream => _completedSC.stream;

  @override
  Stream<Duration> get positionStream => _positionSC.stream;

  @override
  Stream<Duration> get durationStream => _durationSC.stream;

  @override
  Stream<Duration> get bufferStream => _bufferSC.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingSC.stream;

  @override
  Stream<String> get errorStream => _errorSC.stream;

  /// Listener wired onto the native [ValueNotifier]. Diffs [_prev] against the
  /// latest value and pushes only the changed fields onto the streams.
  void _onValueChanged() {
    final VideoPlayerController? c = _controller;
    if (c == null || _disposed) {
      return;
    }
    final VideoPlayerValue v = c.value;
    final VideoPlayerValue? p = _prev;

    if (p == null || v.isPlaying != p.isPlaying) {
      _emit(_playingSC, v.isPlaying);
    }
    if (p == null || v.isCompleted != p.isCompleted) {
      _emit(_completedSC, v.isCompleted);
    }
    if (p == null || v.position != p.position) {
      _emit(_positionSC, v.position);
    }
    if (p == null || v.duration.end != p.duration.end) {
      _emit(_durationSC, v.duration.end);
    }
    if (p == null || v.isBuffering != p.isBuffering) {
      _emit(_bufferingSC, v.isBuffering);
    }
    final Duration buf = _bufferOf(v);
    if (p == null || buf != _bufferOf(p)) {
      _emit(_bufferSC, buf);
    }
    if (v.hasError && v.errorDescription != p?.errorDescription) {
      _emit(_errorSC, v.errorDescription!);
    }

    _prev = v;
  }

  void _emit<T>(StreamController<T> sc, T value) {
    if (!sc.isClosed) {
      sc.add(value);
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle / source
  // ---------------------------------------------------------------------------

  @override
  void setMediaHeader({
    String? userAgent,
    String? referer,
    Map<String, String>? headers,
  }) {
    if (userAgent != null) {
      _userAgent = userAgent;
    }
    if (referer != null) {
      _referer = referer;
    }
    if (headers != null) {
      _extraHeaders = Map<String, String>.from(headers);
    }
  }

  @override
  Future<void> open(MediaSource source, {bool play = true}) async {
    if (_disposed) {
      return;
    }
    _currentSource = source;
    _playRequested = play;

    // AVPlay controllers are single-use: dispose the previous one first.
    await _teardownController();
    if (_disposed) {
      return;
    }

    // Audio-only (video disabled) collapses the source onto its audio url so the
    // proxy serves a single audio stream instead of a merged manifest.
    MediaSource effective = source;
    if (_videoDisabled && source.hasSeparateAudio) {
      effective = MediaSource(
        videoUri: source.audioUri!,
        start: source.start,
        disableCache: source.disableCache,
      );
    }

    // The proxy returns a 127.0.0.1 url — a synthetic DASH manifest for the
    // dual-stream case, a header-injecting passthrough otherwise — and folds in
    // the mandatory Referer.
    final String url = await _proxy.urlFor(
      effective,
      referer: _referer,
      userAgent: _userAgent,
      videoMeta: effective.videoMeta,
      audioMeta: effective.audioMeta,
      duration: effective.totalDuration,
    );
    if (_disposed) {
      return;
    }

    // A merged dual-stream source is DASH; everything else is left to native
    // format detection.
    final VideoFormat format =
        effective.hasSeparateAudio ? VideoFormat.dash : VideoFormat.other;

    final Map<String, String> httpHeaders = <String, String>{};
    if (_userAgent != null && _userAgent!.isNotEmpty) {
      httpHeaders['User-Agent'] = _userAgent!;
    }
    final String? cookie = _extraHeaders?['Cookie'] ?? _extraHeaders?['cookie'];
    if (cookie != null && cookie.isNotEmpty) {
      httpHeaders['Cookie'] = cookie;
    }

    final VideoPlayerController controller = VideoPlayerController.network(
      url,
      formatHint: format,
      httpHeaders: httpHeaders,
      // All our media is served through the localhost DASH proxy; the
      // adaptive-streaming engine fails to prepare those sources, so force the
      // general-purpose engine (previously a native plugin patch).
      playerEngine: PlayerEngine.general,
    );
    _controller = controller;
    _prev = null;
    controller.addListener(_onValueChanged);
    // Publish the controller before initialize() so the view mounts the
    // VideoPlayer (and thus the native overlay display) while prepare runs.
    controllerListenable.value = controller;

    try {
      await controller.initialize();
    } catch (e) {
      // AVPlay surfaces load failures by throwing from initialize(). Publish it
      // to errorStream for listeners, then RETHROW so the caller
      // (PlPlayerController._createVideoController) hits its catch and sets
      // dataStatus=error. Swallowing it here let a failed prepare fall through
      // to dataStatus=loaded and be shown as successful playback.
      _emit(_errorSC, e.toString());
      rethrow;
    }

    if (_disposed || _controller != controller) {
      return;
    }

    // Seek-on-open must happen AFTER initialize().
    final Duration? start = source.start;
    if (start != null && start > Duration.zero) {
      await controller.seekTo(start);
    }

    // Re-apply persisted rate/volume onto the fresh controller.
    await controller.setVolume((_volumePercent / 100).clamp(0.0, 1.0));
    if (_rate > 0 && _rate != 1.0) {
      await controller.setPlaybackSpeed(_rate);
    }

    // A freshly-prepared controller is already paused (Ready, not Playing), so
    // only an explicit play() is needed. Calling pause() here would throw
    // PlatformException(Pause) and abort open() before the widget can mount.
    if (play) {
      await controller.play();
    }
  }

  @override
  Future<void> reopenAtCurrentPosition({bool play = true}) async {
    final MediaSource? src = _currentSource;
    if (src == null) {
      return;
    }
    final Duration resumeAt = position;
    final MediaSource resumed = MediaSource(
      videoUri: src.videoUri,
      audioUri: src.audioUri,
      start: resumeAt > Duration.zero ? resumeAt : src.start,
      disableCache: src.disableCache,
      videoMeta: src.videoMeta,
      audioMeta: src.audioMeta,
      totalDuration: src.totalDuration,
    );
    try {
      await open(resumed, play: play);
    } catch (_) {
      // open() already published the failure to errorStream; swallow the rethrow
      // here so quality-switch / refreshPlayer callers (which don't await this)
      // don't raise an unhandled exception. The initial-load path keeps the
      // throw so it can set dataStatus=error.
    }
  }

  @override
  Future<void> play() async {
    _playRequested = true;
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    _playRequested = false;
    await _controller?.pause();
  }

  @override
  Future<void> playOrPause() async {
    if (playing) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  @override
  Future<void> setRate(double rate) async {
    if (rate <= 0) {
      return;
    }
    _rate = rate;
    await _controller?.setPlaybackSpeed(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    // Interface volume is a percent (0..100+); AVPlay wants 0..1.
    _volumePercent = volume;
    await _controller?.setVolume((volume / 100).clamp(0.0, 1.0));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _teardownController();
    await _playingSC.close();
    await _completedSC.close();
    await _positionSC.close();
    await _durationSC.close();
    await _bufferSC.close();
    await _bufferingSC.close();
    await _errorSC.close();
    await _subtitleSC.close();
  }

  /// Detaches the listener and disposes the current native controller, if any.
  Future<void> _teardownController() async {
    final VideoPlayerController? c = _controller;
    _controller = null;
    _prev = null;
    controllerListenable.value = null;
    if (c != null) {
      c.removeListener(_onValueChanged);
      try {
        await c.dispose();
      } catch (_) {
        // A controller that never finished initializing may throw on dispose;
        // there is nothing actionable to do here.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tracks
  // ---------------------------------------------------------------------------

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    final bool disabled = !enabled;
    if (disabled == _videoDisabled) {
      return;
    }
    _videoDisabled = disabled;
    // A live toggle requires reopening: the audio-only vs merged-dash decision
    // is baked into the source url handed to the native controller.
    if (_controller != null && _currentSource != null) {
      await reopenAtCurrentPosition(play: _playRequested);
    }
  }

  @override
  Future<void> setSubtitle(MediaSubtitle? subtitle) async {
    _currentSubtitle = subtitle;
    _emit(_subtitleSC, subtitle);
  }

  // ---------------------------------------------------------------------------
  // mpv-only capabilities — no-op on AVPlay (defaults from the interface)
  // ---------------------------------------------------------------------------

  @override
  bool get supportsScreenshot => false;

  @override
  Future<ui.Image?> screenshot() async => null;

  @override
  bool get supportsSuperResolution => false;

  @override
  Future<void> setSuperResolutionShaders(List<String> shaderPaths) async {}
}
