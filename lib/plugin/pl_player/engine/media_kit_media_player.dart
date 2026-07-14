import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/engine/abstract_media_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// [AbstractMediaPlayer] backed by the vendored media_kit (mpv) [Player].
///
/// This is the phone/desktop engine. It is a thin adapter: nearly every method
/// forwards straight to the underlying [Player] (which the fork aliases to
/// `NativePlayer`), so behaviour is identical to the pre-abstraction
/// `PlPlayerController` that spoke to media_kit directly.
///
/// The [Player] and its [VideoController] are created by the controller (which
/// owns all the mpv option / hwdec configuration logic) and handed in via
/// [MediaKitMediaPlayer.fromPlayer]. The controller keeps a reference to the
/// same objects through [rawPlayer] / [videoController] so the existing
/// media_kit render widgets (`SimpleVideo`, `SubtitleView`) keep working
/// unchanged on non-Tizen platforms.
class MediaKitMediaPlayer implements AbstractMediaPlayer {
  /// Wraps a pre-built [Player] (and optional [VideoController]).
  ///
  /// Prefer this over letting the adapter build the player itself: the
  /// controller needs full control over [PlayerConfiguration] (mpv options,
  /// volume, autosync, ...) and [VideoControllerConfiguration] (hwdec).
  MediaKitMediaPlayer(this._player, [this._videoController]);

  /// Convenience factory mirroring [MediaKitMediaPlayer.new], kept for call
  /// sites that want an explicitly named constructor.
  factory MediaKitMediaPlayer.fromPlayer(
    Player player, [
    VideoController? videoController,
  ]) => MediaKitMediaPlayer(player, videoController);

  final Player _player;
  VideoController? _videoController;

  /// The underlying media_kit [Player]. Exposed so the existing render widgets
  /// and mpv-specific UI (player-info dialog via [Player.getProperty]) keep
  /// working on non-Tizen backends.
  Player get rawPlayer => _player;

  /// The media_kit [VideoController], if one was attached. Consumed by
  /// `SimpleVideo` and `SubtitleView`.
  VideoController? get videoController => _videoController;

  /// Attach (or replace) the [VideoController] after construction, should the
  /// controller create it lazily.
  set videoController(VideoController? controller) =>
      _videoController = controller;

  // ---- Synchronous state snapshot ----

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  Duration get buffer => _player.state.buffer;

  @override
  bool get playing => _player.state.playing;

  @override
  bool get completed => _player.state.completed;

  @override
  bool get buffering => _player.state.buffering;

  @override
  double get rate => _player.state.rate;

  @override
  double get volume => _player.state.volume;

  @override
  int get videoWidth => _player.state.width;

  @override
  int get videoHeight => _player.state.height;

  // ---- Reactive event streams ----

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<Duration> get bufferStream => _player.stream.buffer;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<String> get errorStream => _player.stream.error;

  // ---- Lifecycle / source ----

  @override
  void setMediaHeader({
    String? userAgent,
    String? referer,
    Map<String, String>? headers,
  }) {
    // Fork-only addition: pushes user-agent/referrer/http-header-fields onto
    // the mpv context before the next [open].
    _player.setMediaHeader(
      userAgent: userAgent,
      referer: referer,
      headers: headers,
    );
  }

  @override
  Future<void> open(MediaSource source, {bool play = true}) {
    final Map<String, String> extras;

    if (source.engineOptions != null) {
      // The caller (PlPlayerController) has already computed the full, correct
      // mpv extras map (buffer / audio-files / lavfi-complex / cache), so use it
      // verbatim — deriving them again here would double up (or clash with the
      // audio-only `听视频` case, where videoUri already IS the audio url).
      extras = Map<String, String>.from(source.engineOptions!);
    } else {
      extras = {};
      if (source.hasSeparateAudio) {
        // mpv `--audio-files` wants a quoted, path-separator-escaped value:
        // ';' on Windows, ':' elsewhere (the mpv list separator per platform).
        final String audio = source.audioUri!;
        final String escaped = Platform.isWindows
            ? audio.replaceAll(';', r'\;')
            : audio.replaceAll(':', r'\:');
        extras['audio-files'] = '"$escaped"';
      }
      if (source.disableCache) {
        extras['cache'] = 'no';
      }
    }

    return _player.open(
      Media(
        source.videoUri,
        start: source.start,
        extras: extras.isEmpty ? null : extras,
      ),
      play: play,
    );
  }

  @override
  Future<void> reopenAtCurrentPosition({bool play = true}) {
    // Mirrors the old `refreshPlayer`: re-open the last-played media seeked to
    // the live position. No-op if nothing has been opened yet.
    if (_player.current.isEmpty) {
      return Future<void>.value();
    }
    return _player.open(
      _player.current.last.copyWith(start: _player.state.position),
      play: play,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() async {
    _videoController = null;
    await _player.dispose();
  }

  // ---- Tracks ----

  @override
  Future<void> setVideoEnabled(bool enabled) => _player.setVideoTrack(
    enabled ? VideoTrack.auto() : VideoTrack.no(),
  );

  @override
  Future<void> setSubtitle(MediaSubtitle? subtitle) {
    if (subtitle == null) {
      return _player.setSubtitleTrack(SubtitleTrack.no());
    }
    // `uri: true` tells mpv the id is an external subtitle uri (which may be a
    // `memory://<vtt-data>` data uri) rather than an embedded track id.
    return _player.setSubtitleTrack(
      SubtitleTrack(
        subtitle.uri,
        subtitle.label,
        subtitle.language,
        uri: true,
      ),
    );
  }

  // ---- mpv-only capabilities ----

  @override
  bool get supportsScreenshot => true;

  @override
  Future<ui.Image?> screenshot() => _player.screenshot();

  @override
  bool get supportsSuperResolution => true;

  @override
  Future<void> setSuperResolutionShaders(List<String> shaderPaths) {
    // Maps to mpv's runtime `glsl-shaders` list: clear when empty, otherwise
    // set the (platform-separator joined) shader path list.
    if (shaderPaths.isEmpty) {
      return _player.command(const ['change-list', 'glsl-shaders', 'clr', '']);
    }
    final String value = shaderPaths.join(Platform.isWindows ? ';' : ':');
    return _player.command(['change-list', 'glsl-shaders', 'set', value]);
  }
}
