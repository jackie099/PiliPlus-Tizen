import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'package:video_player_avplay/video_player.dart';
import 'package:video_player_avplay/video_player_platform_interface.dart'
    show VideoFormat, PlayerEngine, StreamingPropertyType;

import 'abstract_media_player.dart';
import 'bili_dash_proxy.dart';

/// [AbstractMediaPlayer] implementation backed by the `video_player_avplay`
/// plugin's general-purpose CAPI `MediaPlayer` engine (Samsung Tizen TV / AVPlay).
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
  /// hole-punch display window) is mounted while the engine's async prepare runs.
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

    // Dual-stream (separate video + audio) plays natively as ZERO-BYTE DASH: the
    // proxy serves only a ~2KB synthetic MPD with real CDN `<BaseURL>`s and the
    // adaptive (PlusPlayer) engine fetches the segments directly — the Referer
    // comes from the patched `libdash`.
    final bool nativeDash = effective.hasSeparateAudio;

    // Live plays as a PROGRESSIVE concat on the CAPI (general) engine. Bilibili's
    // live fMP4 (`.../index.m3u8`) is a single MUXED stream; the proxy welds its
    // fragments into ONE continuous fMP4 byte stream that the general engine
    // plays like a durl mp4. This is the ONE path where live video actually
    // renders — the adaptive/GstDashSrc DASH remux decodes but re-prepares its
    // pipeline at the live edge and the video caps come up broken on this closed
    // firmware. Only live produces an `.m3u8` uri here (VOD is dual-stream DASH or
    // a durl MP4); remaining single-url sources fall to the `/direct` byte-pump.
    final bool liveHls = !nativeDash && effective.videoUri.contains('.m3u8');

    // Only native dual-stream DASH runs on the adaptive engine; live-progressive
    // and single-url byte-pump sources use the CAPI (general) engine.
    final bool adaptive = nativeDash;

    // A 127.0.0.1 proxy url in every case: a synthetic DASH manifest (`/mpd`) for
    // the dual-stream native case, a progressive fMP4 concat (`/live-prog`) for
    // live, or a header-injecting passthrough (`/direct`) for the remaining
    // single-url byte-pump sources.
    final String url = liveHls
        ? await _proxy.urlForLiveProgressive(
            effective.videoUri,
            referer: _referer,
            userAgent: _userAgent,
          )
        : await _proxy.urlFor(
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

    // Only dual-stream VOD is DASH. Live is a welded progressive fMP4 and durl
    // sources are plain files — both are `other` on the CAPI (general) engine.
    final VideoFormat format =
        adaptive ? VideoFormat.dash : VideoFormat.other;

    final Map<String, String> httpHeaders = <String, String>{};
    if (_userAgent != null && _userAgent!.isNotEmpty) {
      httpHeaders['User-Agent'] = _userAgent!;
    }
    final String? cookie = _extraHeaders?['Cookie'] ?? _extraHeaders?['cookie'];
    if (cookie != null && cookie.isNotEmpty) {
      httpHeaders['Cookie'] = cookie;
    }

    // The adaptive-streaming (PlusPlayer) engine ignores httpHeaders and honors
    // only Cookie / User-Agent, and only via streamingProperty; for VOD DASH the
    // Referer is injected by the patched libdash. Everything on the general
    // engine (live-progressive, `/direct` byte-pump) gets its headers from the
    // proxy relay instead, so it needs no streamingProperty at all.
    final Map<StreamingPropertyType, String>? streamingProperty = adaptive
        ? <StreamingPropertyType, String>{
            if (_userAgent != null && _userAgent!.isNotEmpty)
              StreamingPropertyType.userAgent: _userAgent!,
            if (cookie != null && cookie.isNotEmpty)
              StreamingPropertyType.cookie: cookie,
          }
        : null;

    final VideoPlayerController controller = VideoPlayerController.network(
      url,
      formatHint: format,
      httpHeaders: httpHeaders,
      streamingProperty: streamingProperty,
      // Only dual-stream native DASH runs on the adaptive-streaming (PlusPlayer)
      // engine (patched-libdash injects the Referer). Live-progressive concat and
      // single-url byte-pump sources use the CAPI (general) engine fed by the
      // loopback relay.
      playerEngine:
          adaptive ? PlayerEngine.adaptiveStreaming : PlayerEngine.general,
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

    // Post-initialize control tail (seek/volume/rate/play). On the adaptive
    // (PlusPlayer) engine any of these can throw PlatformException during the
    // brief preroll window right after initialize() — e.g. SetVolume before the
    // pipeline is fully Ready. That throw must NOT escape open(): it would hit
    // PlPlayerController._createVideoController's catch, set dataStatus=error,
    // and skip the success tail (dataStatus=loaded / onInit), so videoState
    // never flips true and the view keeps showing the cover+spinner instead of
    // mounting the native video overlay — video decodes but is never displayed.
    // These calls are best-effort; a genuine load failure already surfaced via
    // the initialize() rethrow above, and the plugin re-applies volume/pause
    // from its own `initialized` handler. So swallow (publish for observability).
    try {
      final Duration? start = source.start;
      if (start != null && start > Duration.zero) {
        await controller.seekTo(start);
      }

      // Re-apply persisted rate/volume onto the fresh controller.
      if (_volumePercent != 100.0) {
        await controller.setVolume((_volumePercent / 100).clamp(0.0, 1.0));
      }
      if (_rate > 0 && _rate != 1.0) {
        await controller.setPlaybackSpeed(_rate);
      }

      // A freshly-prepared controller is already paused (Ready, not Playing), so
      // only an explicit play() is needed.
      if (play) {
        await controller.play();
      }
    } on PlatformException catch (e) {
      _emit(_errorSC, e.toString());
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
