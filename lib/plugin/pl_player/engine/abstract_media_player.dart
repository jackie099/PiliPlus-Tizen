import 'dart:async';
import 'dart:ui' as ui;

/// Engine-agnostic media source.
///
/// media_kit collapsed this into `Media(uri, extras: {'audio-files': ...})`.
/// Bilibili DASH ships video and audio as SEPARATE urls; [audioUri] carries the
/// second stream. The Tizen (AVPlay) backend cannot take two urls, so it builds
/// a synthetic DASH manifest (served by a localhost proxy) for the dual-stream
/// case; single-url sources (durl MP4/FLV, live HLS/FLV, audio-only) play直接.
class MediaSource {
  const MediaSource({
    required this.videoUri,
    this.audioUri,
    this.start,
    this.disableCache = false,
    this.engineOptions,
    this.videoMeta,
    this.audioMeta,
    this.totalDuration,
  });

  final String videoUri;

  /// Separate DASH audio stream. null/empty ⇒ muxed single stream or audio-only.
  final String? audioUri;

  /// Seek-on-open position (media_kit `Media(start:)`).
  final Duration? start;

  final bool disableCache;

  /// Real DASH metadata for the video/audio stream, as supplied by Bilibili's
  /// play-url response. Consumed ONLY by the AVPlay backend, which threads it
  /// into [BiliDashProxy] so the synthesized MPD describes the actual codec /
  /// dimensions instead of a hardcoded AVC/AAC placeholder. null on non-DASH /
  /// non-proxy paths; the media_kit backend ignores it entirely.
  final DashStreamMeta? videoMeta;
  final DashStreamMeta? audioMeta;

  /// Total media duration (from Bilibili's `timelength`), used by the AVPlay
  /// proxy to declare `mediaPresentationDuration` when it does not probe the
  /// stream's `sidx` for a duration. null ⇒ fall back to the probed value.
  final Duration? totalDuration;

  /// Engine-specific open options.
  ///
  /// On the media_kit backend these are merged verbatim into the mpv
  /// `Media(extras:)` map (buffer sizes, `audio-files`, `lavfi-complex`
  /// audio-normalization, `cache`, ...). When non-null this map is treated as
  /// the authoritative, already-computed extras and the media_kit adapter does
  /// NOT re-derive `audio-files`/`cache` from [audioUri]/[disableCache].
  ///
  /// The AVPlay backend ignores this entirely.
  final Map<String, String>? engineOptions;

  bool get hasSeparateAudio => audioUri != null && audioUri!.isNotEmpty;
}

/// Real, per-stream DASH metadata carried from Bilibili's play-url response down
/// to [BiliDashProxy] so the synthesized MPD can describe the ACTUAL stream
/// instead of a hardcoded `avc1.640028` / `mp4a.40.2` placeholder.
///
/// Historically the proxy lied — it advertised AVC/AAC for every stream — so an
/// HEVC/AV1 (or FLAC/Dolby) selection was handed to the CAPI MediaPlayer backend
/// described as AVC and rejected with `PLAYER_ERROR_NOT_SUPPORTED_FORMAT`. This
/// value type lets the manifest tell the truth.
///
/// Every field is optional: the proxy falls back to a sane default for anything
/// missing so it never emits an invalid manifest. Purely additive — only the
/// AVPlay backend reads it; the media_kit (mobile) path ignores it.
class DashStreamMeta {
  const DashStreamMeta({
    this.codecs,
    this.mimeType,
    this.bandwidth,
    this.width,
    this.height,
    this.frameRate,
    this.sar,
    this.audioSamplingRate,
    this.channels,
    this.initializationRange,
    this.indexRange,
  });

  /// DASH `codecs`, e.g. `avc1.640028`, `hev1.1.6.L153.90`, `av01.0.08M.08`,
  /// `mp4a.40.2`, `fLaC`, `ec-3`.
  final String? codecs;

  /// DASH `mimeType`, e.g. `video/mp4` or `audio/mp4`.
  final String? mimeType;

  /// DASH `bandwidth`, bits/s.
  final int? bandwidth;

  /// Video pixel dimensions (video streams only).
  final int? width;
  final int? height;

  /// Frame rate in DASH form: an integer (`"30"`) or a rational (`"30000/1001"`).
  /// Bilibili already supplies it in this exact form; emitted verbatim.
  final String? frameRate;

  /// Sample aspect ratio in DASH form, `"x:y"` (e.g. `"1:1"`).
  final String? sar;

  /// Audio sampling rate, Hz (audio streams only). Not supplied by Bilibili's
  /// play-url DASH model today, so usually null ⇒ proxy default.
  final int? audioSamplingRate;

  /// Audio channel count (audio streams only). Usually null ⇒ proxy default.
  final int? channels;

  /// Bilibili-supplied initialization byte range, inclusive `"first-last"`
  /// (e.g. `"0-822"`). Preferred over byte-probing when present.
  final String? initializationRange;

  /// Bilibili-supplied index (`sidx`) byte range, inclusive `"first-last"`
  /// (e.g. `"823-1381"`). Preferred over byte-probing when present.
  final String? indexRange;
}

/// An external or embedded subtitle track.
class MediaSubtitle {
  const MediaSubtitle(this.uri, this.label, this.language);

  /// On media_kit this may be a `memory://<vtt-data>` data uri.
  final String uri;
  final String label;
  final String language;
}

/// Minimal cross-engine player surface, distilled from the media_kit usage
/// across [PlPlayerController] and the six files that borrow its player.
///
/// Two implementations exist:
///  * `MediaKitMediaPlayer` — wraps the vendored media_kit `Player` (phone/desktop).
///  * `AvplayMediaPlayer` — wraps `video_player_avplay` (Samsung TV).
///
/// mpv-only capabilities (screenshot, super-resolution shaders, raw property
/// access) default to no-op/null so the AVPlay backend can ignore them.
///
/// Volume convention: [volume] is 0..100+ (percent) to match the media_kit
/// `setVolume(v * 100)` call sites throughout the app.
abstract class AbstractMediaPlayer {
  // ---- Synchronous state snapshot (was Player.state.*) ----
  Duration get position;
  Duration get duration;
  Duration get buffer;
  bool get playing;
  bool get completed;
  bool get buffering;
  double get rate;
  double get volume; // percent (0..100+)
  int get videoWidth;
  int get videoHeight;

  // ---- Reactive event streams (were Player.stream.*) ----
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferStream;
  Stream<bool> get bufferingStream;

  /// Normalized error text. The auto-retry logic in PlPlayerController string-
  /// matches these, so both backends must emit comparable messages.
  Stream<String> get errorStream;

  // ---- Lifecycle / source ----

  /// Set request headers BEFORE [open]. Referer + User-Agent are mandatory for
  /// the Bilibili CDN (403 otherwise). media_kit maps to mpv user-agent/referrer;
  /// the AVPlay backend routes them through its localhost header proxy.
  void setMediaHeader({String? userAgent, String? referer, Map<String, String>? headers});

  Future<void> open(MediaSource source, {bool play = true});

  /// Re-open the current source at the current position (was refreshPlayer).
  Future<void> reopenAtCurrentPosition({bool play = true});

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume); // percent
  Future<void> dispose();

  // ---- Tracks ----

  /// Audio-only toggle (media_kit VideoTrack.no()/auto()).
  Future<void> setVideoEnabled(bool enabled);

  /// External/embedded subtitle. On the AVPlay backend this is rendered by a
  /// Flutter overlay driven by [positionStream], not by the native decoder.
  Future<void> setSubtitle(MediaSubtitle? subtitle);

  // ---- mpv-only capabilities (no-op on AVPlay) ----
  bool get supportsScreenshot => false;
  Future<ui.Image?> screenshot() async => null;

  bool get supportsSuperResolution => false;
  Future<void> setSuperResolutionShaders(List<String> shaderPaths) async {}
}
