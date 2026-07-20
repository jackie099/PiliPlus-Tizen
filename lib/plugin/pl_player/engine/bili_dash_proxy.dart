import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:PiliPlus/plugin/pl_player/engine/abstract_media_player.dart';

/// Debug/spike flag for the native-DASH smoke test.
///
/// When `true`, the AVPlay backend plays Bilibili dual-stream DASH through the
/// NATIVE adaptive-streaming engine fetching segments STRAIGHT FROM THE CDN: the
/// synthesized manifest's `<BaseURL>` is the real Bilibili CDN url, the file's
/// internal fragments are enumerated as a `<SegmentList>` of byte ranges parsed
/// from its `sidx` (see [_writeSegmentList]), and only the manifest is served
/// over loopback (no per-segment byte-pump). The CDN's mandatory
/// `Referer: https://www.bilibili.com` is supplied by a Referer-patched
/// `libdash.so`, not by Dart. When `false` (default) the historical byte-pump
/// path is used (loopback `<BaseURL>` + general engine), so a build without the
/// dart-define below behaves exactly as before.
///
/// Enable for a build with `--dart-define=BILI_NATIVE_DASH=true` (grep device
/// logs for `[BILI-NATIVE-DASH]` to confirm it engaged); or, if your build flow
/// drops dart-defines, change `defaultValue` to `true` here.
const bool kBiliNativeDash =
    bool.fromEnvironment('BILI_NATIVE_DASH', defaultValue: false);

/// Diagnostic (native mode only): emit a VIDEO-ONLY single-AdaptationSet
/// manifest — drop the audio track. Bilibili's separate video+audio forces
/// Samsung's `GstDashSrc` into a per-track branch that connects
/// `need-data-video`/`-audio` signals its own class never registered (a bug in
/// the bundled `libgstdash`), so prepare collapses. A single pad instead takes
/// the working generic `need-data` path. This isolates TOPOLOGY (dual-pad) from
/// ADDRESSING (byte ranges). Build with `--dart-define=BILI_NATIVE_VIDEO_ONLY=true`.
/// If it PLAYS, the dual-pad wiring is the sole wall and a native-video +
/// side-channel-audio hybrid is viable; it is a diagnostic, not a product.
const bool kBiliNativeVideoOnly =
    bool.fromEnvironment('BILI_NATIVE_VIDEO_ONLY', defaultValue: false);

/// Option B: play the Bilibili VIDEO m4s DIRECTLY from the CDN as a plain
/// PROGRESSIVE source (`formatHint: other` → Samsung's GstMmHttpSrc + qtdemux),
/// bypassing the whole DASH `GstDashSrc`/`dashplusdemuxer` pipeline (whose
/// closed ffdemux can't produce caps for Bilibili's split init/media fragments).
/// No loopback proxy, no synthesized manifest — the engine fetches the single
/// fragmented-MP4 straight from the CDN. The mandatory `Referer` comes from a
/// Referer-patched `libgstmmhttpsrc.so` (same technique as libdash); UA/Cookie
/// via streamingProperty. VIDEO-ONLY for now (Bilibili's audio is a separate
/// file — a small side-channel is the follow-up). Build with
/// `--dart-define=BILI_NATIVE_PROGRESSIVE=true`.
const bool kBiliNativeProgressive =
    bool.fromEnvironment('BILI_NATIVE_PROGRESSIVE', defaultValue: false);

/// Native MUXED progressive path ([kBiliNativeDurl]): request Bilibili's legacy
/// `durl` playurl (a single CONTIGUOUS mp4 carrying BOTH audio+video, moov-at-
/// front, no moof fragments) instead of split DASH, and play that one CDN url
/// directly on the adaptive engine via `GstHttpDemux`. Unlike
/// [kBiliNativeProgressive] (fragmented, video-only), a contiguous mp4 yields
/// stable caps at init with no mid-stream re-negotiation — the shape the
/// PlusPlayer core handoff→appsrc bridge needs — AND carries audio, so no
/// side-channel is required. Quality is capped (durl ≤1080p, no 4K/HDR). The
/// `Referer` still comes from the patched `libgstmmhttpsrc.so`. Build with
/// `--dart-define=BILI_NATIVE_DURL=true`.
const bool kBiliNativeDurl =
    bool.fromEnvironment('BILI_NATIVE_DURL', defaultValue: false);

/// A localhost reverse-proxy that adapts Bilibili media streams for the Samsung
/// TV video engine (`video_player_avplay`'s CAPI `MediaPlayer` backend).
///
/// It solves two problems the native player cannot handle on its own:
///
/// 1. **Missing Referer.** The Bilibili CDN returns `403` unless the request
///    carries a `Referer: https://www.bilibili.com` (and a browser-ish
///    `User-Agent`). The player drops custom request headers on the media
///    socket, so the player talks to this loopback server instead and the server
///    re-issues the upstream request with the headers attached.
///
/// 2. **Split DASH streams.** Bilibili DASH ships video and audio as two
///    independent URLs; the native player accepts a single source only. For
///    dual-stream sources we synthesize a `type="static"` DASH `.mpd` that
///    references both streams as two `AdaptationSet`s. In byte-pump mode each
///    `Representation` carries a `<SegmentBase>` whose `indexRange`/
///    `Initialization` come from Bilibili's supplied `segmentBase` when
///    present, or are otherwise derived by probing the leading MP4 boxes
///    ([_probeSegmentBase]) of the stream; in native-DASH mode it instead
///    carries a `<SegmentList>` enumerating the file's internal fragments as
///    byte ranges parsed from its `sidx` (see [_writeSegmentList] for why the
///    Samsung engine requires the enumerated shape). Either way the manifest
///    declares `mediaPresentationDuration` (from Bilibili's `timelength`, or
///    summed from the `sidx`); both are required for the native demuxer to
///    build a timeline instead of stalling. In byte-pump mode segment/`Range`
///    requests are proxied back through `/seg/*`.
///
/// Everything is served from `http://127.0.0.1:<ephemeral-port>/`; nothing
/// leaves the loopback interface. The `Representation`s advertise the SELECTED
/// stream's REAL codec / dimensions (threaded in from Bilibili's play-url DASH
/// metadata via [DashStreamMeta]) so the CAPI backend accepts HEVC/AV1/FLAC as
/// readily as AVC; a missing field falls back to an AVC/AAC-shaped default.
class BiliDashProxy {
  BiliDashProxy();

  /// Default browser-ish User-Agent used when a caller does not supply one.
  /// Bilibili's CDN rejects obviously-bot agents, so keep this plausible.
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  /// Default Referer expected by the Bilibili video CDN.
  static const String _defaultReferer = 'https://www.bilibili.com';

  /// DASH manifest MIME type.
  static const String _mpdContentType = 'application/dash+xml';

  final HttpClient _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15);

  final Map<String, _ProxyEntry> _registry = <String, _ProxyEntry>{};
  final Random _rng = Random.secure();

  HttpServer? _server;

  /// Loopback base URL (`http://127.0.0.1:<port>`), valid only after [start].
  String? _base;

  /// Whether the proxy is currently listening.
  bool get isRunning => _server != null;

  /// The bound port, or `null` before [start] / after [stop].
  int? get port => _server?.port;

  /// Bind the loopback server on an ephemeral port and begin serving.
  ///
  /// Idempotent: calling [start] twice keeps the first server.
  Future<void> start() async {
    if (_server != null) return;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    server.autoCompress = false;
    _server = server;
    _base = 'http://${InternetAddress.loopbackIPv4.address}:${server.port}';
    // Handle requests off the awaited path so [start] returns immediately.
    server.listen(
      _handle,
      onError: (Object _, StackTrace __) {},
      cancelOnError: false,
    );
  }

  /// Register [source] and return a loopback URL the player can open.
  ///
  /// * Dual-stream (`source.hasSeparateAudio`) ⇒ `/mpd/<token>.mpd`
  ///   (a synthetic DASH manifest, [formatHint] `dash`).
  /// * Single-url (durl MP4/FLV, live HLS/FLV, audio-only) ⇒ `/direct/<token>`
  ///   (a plain header-injecting reverse proxy, no manifest).
  ///
  /// [referer]/[userAgent] override the defaults for this source only; pass the
  /// values previously handed to [AbstractMediaPlayer.setMediaHeader].
  ///
  /// [videoMeta]/[audioMeta] carry the SELECTED stream's real DASH metadata
  /// (codec, dimensions, byte ranges) so the synthesized MPD describes the true
  /// stream instead of a hardcoded AVC/AAC placeholder; [duration] is the total
  /// media length used for `mediaPresentationDuration`. All are optional.
  ///
  /// Auto-[start]s the server if it is not already listening.
  Future<String> urlFor(
    MediaSource source, {
    String? referer,
    String? userAgent,
    DashStreamMeta? videoMeta,
    DashStreamMeta? audioMeta,
    Duration? duration,
  }) async {
    if (_server == null) await start();

    final bool hasAudio = source.hasSeparateAudio;
    final String token = _newToken();
    final _ProxyEntry entry = _ProxyEntry(
      videoUri: source.videoUri,
      audioUri: hasAudio ? source.audioUri : null,
      referer: (referer != null && referer.isNotEmpty)
          ? referer
          : _defaultReferer,
      userAgent: (userAgent != null && userAgent.isNotEmpty)
          ? userAgent
          : _defaultUserAgent,
      videoMeta: videoMeta,
      audioMeta: hasAudio ? audioMeta : null,
      durationSec: (duration != null && duration > Duration.zero)
          ? duration.inMilliseconds / 1000.0
          : null,
    );
    _registry[token] = entry;

    if (source.hasSeparateAudio) {
      return '$_base/mpd/$token.mpd';
    }
    // A .mp4 suffix helps PlusPlayer/GStreamer pick the demuxer for the single-
    // stream (durl / progressive) case — an extensionless url can stall prepare.
    return '$_base/direct/$token.mp4';
  }

  /// Stop serving, drop the registry, and close idle upstream connections.
  ///
  /// Safe to call when already stopped.
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    _base = null;
    _registry.clear();
    if (server != null) {
      await server.close(force: true);
    }
    _client.close(force: true);
  }

  // ---------------------------------------------------------------------------
  // Request routing
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      final List<String> segments = request.uri.pathSegments;
      // Routes:
      //   GET /mpd/<token>.mpd
      //   GET /seg/<token>/v   GET /seg/<token>/a
      //   GET /direct/<token>
      if (segments.length == 2 && segments[0] == 'mpd') {
        final String token = _stripSuffix(segments[1], '.mpd');
        await _serveMpd(request, token);
      } else if (segments.length == 3 && segments[0] == 'seg') {
        await _serveSegment(request, segments[1], segments[2]);
      } else if (segments.length == 2 && segments[0] == 'direct') {
        await _serveDirect(request, segments[1]);
      } else {
        await _respondStatus(request, HttpStatus.notFound);
      }
    } catch (_) {
      // The player treats a closed/failed socket as a load error; never rethrow
      // into the server's listen callback.
      await _respondStatus(request, HttpStatus.badGateway);
    }
  }

  /// `GET /mpd/<token>.mpd` — return the synthesized manifest.
  Future<void> _serveMpd(HttpRequest request, String token) async {
    final _ProxyEntry? entry = _registry[token];
    if (entry == null || entry.audioUri == null) {
      await _respondStatus(request, HttpStatus.notFound);
      return;
    }
    // Resolve each stream's init/index byte-ranges the first time the manifest
    // is requested. A BaseURL-only on-demand Representation makes the player
    // download the whole fragmented-MP4 without ever preparing (it cannot find
    // the moov/sidx); a proper <SegmentBase> lets it index and play. In
    // byte-pump mode PREFER Bilibili's supplied `segmentBase` ranges (no
    // round-trip, authoritative) and fall back to byte-probing the leading MP4
    // boxes only when they're absent.
    if (!entry.probed) {
      if (kBiliNativeDash) {
        // Native mode enumerates the internal fragments ([_writeSegmentList]),
        // so the sidx CONTENTS are required — Bilibili's supplied byte ranges
        // alone cannot enumerate anything. Always fetch and parse the leading
        // init+sidx region; the supplied `indexRange` merely bounds that fetch
        // to a few KB instead of the blind 256 KiB probe window.
        entry
          ..videoSeg =
              await _probeIndexed(entry.videoUri, entry, entry.videoMeta)
          ..audioSeg =
              await _probeIndexed(entry.audioUri!, entry, entry.audioMeta);
      } else {
        entry
          ..videoSeg = _segBaseFromMeta(entry.videoMeta) ??
              await _probeSegmentBase(entry.videoUri, entry)
          ..audioSeg = _segBaseFromMeta(entry.audioMeta) ??
              await _probeSegmentBase(entry.audioUri!, entry);
      }
      entry.probed = true;
    }
    final String mpd = _buildMpd(token);
    final HttpResponse res = request.response;
    res.statusCode = HttpStatus.ok;
    res.headers
      ..contentType = ContentType.parse(_mpdContentType)
      ..set(HttpHeaders.cacheControlHeader, 'no-cache')
      ..set(HttpHeaders.accessControlAllowOriginHeader, '*');
    res.write(mpd);
    await res.close();
  }

  /// `GET /seg/<token>/{v|a}` — reverse-proxy the video or audio stream.
  Future<void> _serveSegment(
    HttpRequest request,
    String token,
    String kind,
  ) async {
    final _ProxyEntry? entry = _registry[token];
    if (entry == null) {
      await _respondStatus(request, HttpStatus.notFound);
      return;
    }
    final String? target = switch (kind) {
      'v' => entry.videoUri,
      'a' => entry.audioUri,
      _ => null,
    };
    if (target == null) {
      await _respondStatus(request, HttpStatus.notFound);
      return;
    }
    await _proxy(request, target, entry);
  }

  /// `GET /direct/<token>` — plain header-injecting reverse proxy.
  Future<void> _serveDirect(HttpRequest request, String rawToken) async {
    final String token = _stripSuffix(rawToken, '.mp4');
    final _ProxyEntry? entry = _registry[token];
    if (entry == null) {
      await _respondStatus(request, HttpStatus.notFound);
      return;
    }
    await _proxy(request, entry.videoUri, entry);
  }

  // ---------------------------------------------------------------------------
  // Upstream reverse-proxy
  // ---------------------------------------------------------------------------

  /// Issue [targetUri] upstream with Referer/User-Agent injected and the
  /// client's `Range` copied through, then stream status + headers + bytes back.
  Future<void> _proxy(
    HttpRequest request,
    String targetUri,
    _ProxyEntry entry,
  ) async {
    final HttpResponse out = request.response;
    HttpClientResponse? upstream;
    try {
      final Uri uri = Uri.parse(targetUri);
      final HttpClientRequest up = await _client.getUrl(uri);
      up.followRedirects = true;
      up.maxRedirects = 8;

      // Inject the headers AVPlay drops.
      up.headers
        ..set(HttpHeaders.refererHeader, entry.referer)
        ..set(HttpHeaders.userAgentHeader, entry.userAgent)
        ..set(HttpHeaders.acceptHeader, '*/*');

      // Forward Range verbatim so the player can seek / probe.
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        up.headers.set(HttpHeaders.rangeHeader, range);
      }

      upstream = await up.close();

      // Present the player with clean, GStreamer/souphttpsrc-friendly responses:
      //  * an open-ended (`bytes=0-`) or range-less request -> 200 OK with a real
      //    Content-Length so the demuxer sees a definite body length and EOF and
      //    finishes preparing (mirroring the CDN's 206 here is what stalls
      //    VideoPlayerController.initialize());
      //  * a genuine sub-range request -> 206 with Content-Range passed through.
      // Content-Length is set via the RESPONSE PROPERTY (not a raw header) so
      // Dart emits a fixed-length body instead of chunked transfer-encoding.
      final bool openFromStart =
          range == null || range.trim().isEmpty || range.trim() == 'bytes=0-';
      final int upLen = upstream.headers.contentLength;
      if (openFromStart && upstream.statusCode == HttpStatus.partialContent) {
        out.statusCode = HttpStatus.ok;
      } else {
        out.statusCode = upstream.statusCode;
        _copyHeader(upstream, out, HttpHeaders.contentRangeHeader);
      }
      _copyHeader(upstream, out, HttpHeaders.contentTypeHeader);
      if (upLen >= 0) {
        out.contentLength = upLen;
      }
      out.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.accessControlAllowOriginHeader, '*');

      await out.addStream(upstream);
      await out.close();
    } catch (e) {
      // Ensure the upstream socket is drained/closed on failure.
      try {
        await upstream?.drain<void>();
      } catch (_) {}
      await _safeClose(out, HttpStatus.badGateway);
    }
  }

  // ---------------------------------------------------------------------------
  // SegmentBase probing
  // ---------------------------------------------------------------------------

  /// How many bytes to pull when probing a stream's leading boxes. `ftyp`+`moov`
  /// +`sidx` for a Bilibili fragmented-MP4 are comfortably within this; only the
  /// box *headers* (not full bodies) must land inside it.
  static const int _probeBytes = 262144; // 256 KiB

  /// NATIVE mode: resolve a stream's [_SegBase] WITH parsed sidx references.
  /// Bilibili's supplied `indexRange` bounds the fetch precisely (init+sidx,
  /// typically a few KB); when it is absent — or the hinted fetch parses to
  /// nothing — fall back to the blind [_probeBytes] window.
  Future<_SegBase?> _probeIndexed(
    String targetUri,
    _ProxyEntry entry,
    DashStreamMeta? meta,
  ) async {
    final List<int>? index = _parseRange(meta?.indexRange);
    if (index != null) {
      final _SegBase? seg =
          await _probeSegmentBase(targetUri, entry, probeEnd: index[1] + 1);
      if (seg != null) return seg;
    }
    return _probeSegmentBase(targetUri, entry);
  }

  /// Fetch the first [probeEnd] bytes of [targetUri] (with the CDN headers
  /// injected) and parse its MP4 box layout into a [_SegBase]. Returns null on
  /// any failure, leaving the caller to emit a BaseURL-only Representation.
  Future<_SegBase?> _probeSegmentBase(
    String targetUri,
    _ProxyEntry entry, {
    int probeEnd = _probeBytes,
  }) async {
    HttpClientResponse? up;
    try {
      final HttpClientRequest req = await _client.getUrl(Uri.parse(targetUri));
      req.followRedirects = true;
      req.maxRedirects = 8;
      req.headers
        ..set(HttpHeaders.refererHeader, entry.referer)
        ..set(HttpHeaders.userAgentHeader, entry.userAgent)
        ..set(HttpHeaders.acceptHeader, '*/*')
        ..set(HttpHeaders.rangeHeader, 'bytes=0-${probeEnd - 1}');
      up = await req.close();
      if (up.statusCode != HttpStatus.ok &&
          up.statusCode != HttpStatus.partialContent) {
        await up.drain<void>();
        return null;
      }
      final BytesBuilder bb = BytesBuilder(copy: false);
      await for (final List<int> chunk in up) {
        bb.add(chunk);
        if (bb.length >= probeEnd) break;
      }
      return _parseSegmentBase(bb.takeBytes());
    } catch (_) {
      try {
        await up?.drain<void>();
      } catch (_) {}
      return null;
    }
  }

  /// Walk the top-level MP4 boxes in [d] to locate the end of `moov` (the
  /// initialization segment) and the bounds of `sidx` (the segment index).
  /// Stops at the first media box (`moof`/`mdat`). Returns null if no `moov` is
  /// found within the probed bytes.
  static _SegBase? _parseSegmentBase(Uint8List d) {
    int offset = 0;
    int? moovEnd;
    int? sidxStart;
    int? sidxEnd;
    while (offset + 8 <= d.length) {
      final int size32 = (d[offset] << 24) |
          (d[offset + 1] << 16) |
          (d[offset + 2] << 8) |
          d[offset + 3];
      final String type = String.fromCharCodes(d, offset + 4, offset + 8);
      int boxSize = size32;
      if (size32 == 1) {
        // 64-bit `largesize` in the following 8 bytes.
        if (offset + 16 > d.length) break;
        final int hi = (d[offset + 8] << 24) |
            (d[offset + 9] << 16) |
            (d[offset + 10] << 8) |
            d[offset + 11];
        final int lo = (d[offset + 12] << 24) |
            (d[offset + 13] << 16) |
            (d[offset + 14] << 8) |
            d[offset + 15];
        boxSize = (hi << 32) | (lo & 0xFFFFFFFF);
      } else if (size32 == 0) {
        break; // Box runs to EOF; unindexable from a probe.
      }
      if (boxSize < 8) break; // Malformed.
      if (type == 'moov') {
        moovEnd = offset + boxSize;
      } else if (type == 'sidx') {
        sidxStart = offset;
        sidxEnd = offset + boxSize;
      } else if (type == 'moof' || type == 'mdat') {
        break; // Reached media; nothing more to index.
      }
      offset += boxSize;
    }
    if (moovEnd == null) return null;
    final _SidxIndex? idx =
        sidxStart != null ? _parseSidx(d, sidxStart, sidxEnd!) : null;
    return _SegBase(moovEnd, sidxStart, sidxEnd, idx?.durationSeconds, idx);
  }

  /// Parse the `sidx` at [sidxStart] into a [_SidxIndex]: its timescale, the
  /// absolute offset of the first indexed fragment (the anchor point — the
  /// first byte after the box, i.e. [sidxEnd] — plus `first_offset`), and every
  /// reference's `referenced_size` / `subsegment_duration`. This is both the
  /// manifest's duration source (the byte-pump path sums the durations, exactly
  /// as it always has) and, in native mode, the fragment enumeration behind
  /// [_writeSegmentList]. Returns null if the box is truncated within the probe
  /// or malformed.
  static _SidxIndex? _parseSidx(Uint8List d, int sidxStart, int sidxEnd) {
    try {
      int p = sidxStart + 8; // Skip box size(4) + type(4).
      final int version = d[p];
      p += 4; // version(1) + flags(3)
      p += 4; // reference_ID(4)
      final int timescale = _u32(d, p);
      p += 4;
      final int firstOffset;
      if (version == 0) {
        p += 4; // earliest_presentation_time(4)
        firstOffset = _u32(d, p);
        p += 4;
      } else {
        p += 8; // earliest_presentation_time(8)
        firstOffset = (_u32(d, p) << 32) | _u32(d, p + 4);
        p += 8;
      }
      p += 2; // reserved(2)
      final int refCount = (d[p] << 8) | d[p + 1];
      p += 2;
      final List<int> sizes = <int>[];
      final List<int> durations = <int>[];
      bool leaf = true;
      for (int i = 0; i < refCount; i++) {
        if (p + 12 > d.length) return null;
        // reference_type(1) + referenced_size(31). A type-1 reference points
        // at a child sidx, not media: its duration still counts toward the
        // total, but the sizes cannot enumerate fragments (Bilibili never
        // nests, but stay honest if one appears).
        final int sizeWord = _u32(d, p);
        if (sizeWord >>> 31 != 0) leaf = false;
        sizes.add(sizeWord & 0x7FFFFFFF);
        durations.add(_u32(d, p + 4)); // subsegment_duration
        p += 12; // + SAP fields(4)
      }
      if (timescale <= 0) return null;
      return _SidxIndex(
          timescale, sidxEnd + firstOffset, leaf, sizes, durations);
    } catch (_) {
      return null;
    }
  }

  static int _u32(Uint8List d, int p) =>
      (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];

  // ---------------------------------------------------------------------------
  // MPD synthesis
  // ---------------------------------------------------------------------------

  /// Build a minimal static DASH manifest referencing the two `/seg/<token>/*`
  /// endpoints via `BaseURL`. The `Representation`s carry the SELECTED stream's
  /// REAL codec / dimensions ([DashStreamMeta]); any field the metadata omits
  /// falls back to a safe AVC/AAC-shaped default so the manifest stays valid.
  String _buildMpd(String token) {
    final _ProxyEntry entry = _registry[token]!;
    // BaseURLs. Byte-pump mode: absolute loopback `/seg/*` endpoints this server
    // proxies to the CDN (Referer/UA injected in Dart). Native-DASH mode: the
    // REAL Bilibili CDN urls, so the native engine fetches every segment directly
    // and only this manifest travels over loopback (Referer comes from the
    // patched libdash). Segment addressing differs per mode: byte-pump keeps
    // the historical single-blob `<SegmentBase indexRange>`, native enumerates
    // the internal fragments as a `<SegmentList>` of byte ranges into the same
    // fragmented-MP4 (see _writeSegmentList for why the engine requires it).
    final String videoUrl =
        kBiliNativeDash ? entry.videoUri : '$_base/seg/$token/v';
    final String audioUrl = kBiliNativeDash
        ? (entry.audioUri ?? '$_base/seg/$token/a')
        : '$_base/seg/$token/a';
    final bool hasAudio = entry.audioUri != null && !kBiliNativeVideoOnly;
    if (kBiliNativeDash) {
      debugPrint(
        '[BILI-NATIVE-DASH] manifest BaseURLs'
        '${kBiliNativeVideoOnly ? ' (VIDEO-ONLY)' : ''} -> v=$videoUrl'
        '${hasAudio ? ' a=$audioUrl' : ''}',
      );
      debugPrint(
        '[BILI-NATIVE-DASH] segment lists -> '
        'v=${_describeIndex(entry.videoSeg)}'
        '${hasAudio ? ' a=${_describeIndex(entry.audioSeg)}' : ''}',
      );
    }

    // A `static` (on-demand) MPD needs an explicit presentation duration for the
    // player to build its timeline; without it some demuxers index the streams
    // then stall. Prefer a probed sidx duration, else Bilibili's `timelength`.
    final double? durSec = entry.videoSeg?.durationSec ??
        entry.audioSeg?.durationSec ??
        entry.durationSec;
    final String durAttr = durSec != null
        ? ' mediaPresentationDuration="PT${durSec.toStringAsFixed(3)}S"'
        : '';

    // Profile: byte-pump keeps the historical on-demand profile. Native mode
    // must NOT declare on-demand — that profile IS the single-blob SegmentBase
    // shape that sends Samsung's GstDashSrc down its broken push path (see
    // _writeSegmentList); enumerated SegmentLists belong to the main profile.
    const String profile = kBiliNativeDash
        ? 'urn:mpeg:dash:profile:isoff-main:2011'
        : 'urn:mpeg:dash:profile:isoff-on-demand:2011';

    // ---- Video Representation attributes (real values, safe defaults) ----
    final DashStreamMeta? vm = entry.videoMeta;
    final String vMime = _attrOr(vm?.mimeType, 'video/mp4');
    final String vCodecs = _attrOr(vm?.codecs, 'avc1.640028');
    final int vBandwidth = (vm?.bandwidth != null && vm!.bandwidth! > 0)
        ? vm.bandwidth!
        : 2000000;
    final StringBuffer vExtra = StringBuffer();
    if ((vm?.width ?? 0) > 0) vExtra.write(' width="${vm!.width}"');
    if ((vm?.height ?? 0) > 0) vExtra.write(' height="${vm!.height}"');
    final String? vFrameRate = _frameRateAttr(vm?.frameRate);
    if (vFrameRate != null) vExtra.write(' frameRate="$vFrameRate"');
    final String? vSar = _sarAttr(vm?.sar);
    if (vSar != null) vExtra.write(' sar="$vSar"');

    final StringBuffer b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" '
        'profiles="$profile" '
        'type="static"'
        '$durAttr '
        'minBufferTime="PT2S">',
      )
      ..writeln('  <Period>')
      // ---- Video ----
      ..writeln(
        '    <AdaptationSet mimeType="${_xmlEscape(vMime)}" '
        'segmentAlignment="true" startWithSAP="1">',
      )
      ..writeln(
        '      <Representation id="v" codecs="${_xmlEscape(vCodecs)}" '
        'bandwidth="$vBandwidth"$vExtra>',
      )
      ..writeln('        <BaseURL>${_xmlEscape(videoUrl)}</BaseURL>');

    // Segment addressing for one Representation, per mode.
    void writeSegments(_SegBase? seg) {
      if (kBiliNativeDash) {
        _writeSegmentList(b, seg, durSec);
      } else {
        _writeSegmentBase(b, seg);
      }
    }

    writeSegments(entry.videoSeg);
    b
      ..writeln('      </Representation>')
      ..writeln('    </AdaptationSet>');

    // ---- Audio ----
    if (hasAudio) {
      final DashStreamMeta? am = entry.audioMeta;
      final String aMime = _attrOr(am?.mimeType, 'audio/mp4');
      final String aCodecs = _attrOr(am?.codecs, 'mp4a.40.2');
      final int aBandwidth = (am?.bandwidth != null && am!.bandwidth! > 0)
          ? am.bandwidth!
          : 128000;
      // Dolby Digital Plus / Atmos. Bilibili's 杜比全景声 tracks (audio ids
      // 30250/30255) are E-AC-3 at 48 kHz carrying a 5.1 bed plus Atmos JOC
      // objects, but the play-url JSON supplies only `codecs: "ec-3"` — no
      // sampling rate or channel count — so those are derived from the codec.
      // DASH-IF / ETSI want E-AC-3 to declare channels via the Dolby scheme
      // (hex speaker bitmask, F801 = 5.1) rather than the MPEG integer scheme,
      // and to advertise the immersive payload with the JOC SupplementalProperty.
      // The Tizen CAPI MediaPlayer (GStreamer libgstdash + eac3 decoder)
      // configures the audio path from these declared values BEFORE it reads the
      // init segment's `dec3` box, so a stereo/44.1k mislabel risks a prepare
      // failure or a forced stereo downmix that defeats passthrough. AAC / FLAC
      // keep the MPEG scheme and their known-good 44.1 kHz / channel defaults.
      final bool isEc3 = aCodecs.toLowerCase().startsWith('ec-3');
      final int aSampling =
          (am?.audioSamplingRate != null && am!.audioSamplingRate! > 0)
              ? am.audioSamplingRate!
              : (isEc3 ? 48000 : 44100);
      final int aChannels = (am?.channels != null && am!.channels! > 0)
          ? am.channels!
          : (isEc3 ? 6 : 2);
      b
        ..writeln(
          '    <AdaptationSet mimeType="${_xmlEscape(aMime)}" '
          'segmentAlignment="true" startWithSAP="1">',
        )
        ..writeln(
          '      <Representation id="a" codecs="${_xmlEscape(aCodecs)}" '
          'bandwidth="$aBandwidth" audioSamplingRate="$aSampling">',
        );
      if (isEc3) {
        // Dolby channel-configuration scheme: hex speaker-position bitmask per
        // ETSI TS 102 366 (A000 = 2.0, F801 = 5.1, FA01 = 7.1). The JOC
        // SupplementalProperty is the manifest-level Atmos signal — supplemental,
        // so a decoder that ignores it still plays the backward-compatible 5.1.
        final String dolbyChannels = switch (aChannels) {
          2 => 'A000',
          8 => 'FA01',
          _ => 'F801',
        };
        b
          ..writeln(
            '        <AudioChannelConfiguration '
            'schemeIdUri="tag:dolby.com,2014:dash:audio_channel_configuration:2011" '
            'value="$dolbyChannels"/>',
          )
          ..writeln(
            '        <SupplementalProperty '
            'schemeIdUri="tag:dolby.com,2018:dash:EC3_ExtensionType:2018" '
            'value="JOC"/>',
          );
      } else {
        b.writeln(
          '        <AudioChannelConfiguration '
          'schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" '
          'value="$aChannels"/>',
        );
      }
      b.writeln('        <BaseURL>${_xmlEscape(audioUrl)}</BaseURL>');
      writeSegments(entry.audioSeg);
      b
        ..writeln('      </Representation>')
        ..writeln('    </AdaptationSet>');
    }

    b
      ..writeln('  </Period>')
      ..writeln('</MPD>');
    return b.toString();
  }

  /// Emit the `<SegmentBase>` child for a Representation from a probed [seg].
  /// With a `sidx` we advertise the full index range; without one we still
  /// declare the initialization range so the demuxer knows where media begins
  /// (the stream then plays as a single self-indexed segment). When [seg] is
  /// null nothing is written and the Representation stays BaseURL-only.
  static void _writeSegmentBase(StringBuffer b, _SegBase? seg) {
    if (seg == null) return;
    if (seg.sidxStart != null && seg.sidxEnd != null) {
      b
        ..writeln(
          '        <SegmentBase indexRange="${seg.sidxStart}-${seg.sidxEnd! - 1}" '
          'indexRangeExact="true">',
        )
        ..writeln('          <Initialization range="0-${seg.initEnd - 1}"/>')
        ..writeln('        </SegmentBase>');
    } else {
      b
        ..writeln('        <SegmentBase>')
        ..writeln('          <Initialization range="0-${seg.initEnd - 1}"/>')
        ..writeln('        </SegmentBase>');
    }
  }

  /// NATIVE mode: emit the Representation's segments as an explicit
  /// `<SegmentList>` — an `<Initialization range>`, a `<SegmentTimeline>` in
  /// the sidx's own timescale, and one `<SegmentURL mediaRange>` per internal
  /// `moof`+`mdat` fragment, all parsed from the stream's own `sidx`.
  ///
  /// Samsung's `GstDashSrc` handles the on-demand single-blob `<SegmentBase
  /// indexRange>` shape by wiring the stream through an appsrc-style push path
  /// this element does not implement (device log: `signal 'need-data-video' is
  /// invalid for instance of type 'GstDashSrc'`), so buffers reach the demuxer
  /// pads before the mandatory stream-start → caps → segment events and prepare
  /// never completes. Segments enumerated IN THE MANIFEST — the shape the
  /// Dailymotion bridge proved on this same engine via SegmentTemplate +
  /// SegmentTimeline — drive its ordinary manifest-driven download loop, which
  /// bootstraps the pad events correctly. `SegmentList` is that same enumerated
  /// machinery applied to Bilibili's single-file layout: each `mediaRange` is a
  /// plain HTTP Range request the engine issues STRAIGHT against the CDN
  /// `BaseURL` (Referer via the patched libdash; zero media bytes through
  /// Dart).
  ///
  /// Without a usable index ([_SidxIndex.leaf] false, zero refs, or no sidx at
  /// all) the whole file becomes ONE enumerated segment (`<SegmentURL/>`, no
  /// range) spanning [durSec] — still list-shaped, so still the good path. With
  /// no [seg] at all the Initialization is omitted too: the single segment then
  /// starts with `ftyp`+`moov`, i.e. it is self-initializing.
  static void _writeSegmentList(StringBuffer b, _SegBase? seg, double? durSec) {
    final _SidxIndex? idx = seg?.index;
    if (idx != null && idx.leaf && idx.sizes.isNotEmpty) {
      b
        ..writeln('        <SegmentList timescale="${idx.timescale}">')
        ..writeln('          <Initialization range="0-${seg!.initEnd - 1}"/>');
      _writeTimeline(b, idx.durations);
      int start = idx.firstMediaOffset;
      for (final int size in idx.sizes) {
        b.writeln(
          '          <SegmentURL mediaRange="$start-${start + size - 1}"/>',
        );
        start += size;
      }
      b.writeln('        </SegmentList>');
      return;
    }
    final int durMs = max(1, ((durSec ?? 0.0) * 1000).round());
    b.writeln('        <SegmentList timescale="1000">');
    if (seg != null) {
      b.writeln('          <Initialization range="0-${seg.initEnd - 1}"/>');
    }
    b
      ..writeln('          <SegmentTimeline>')
      ..writeln('            <S t="0" d="$durMs"/>')
      ..writeln('          </SegmentTimeline>')
      ..writeln('          <SegmentURL/>')
      ..writeln('        </SegmentList>');
  }

  /// Run-length-encode fragment [durations] (sidx ticks) into `<S>` elements:
  /// only the first carries `t`, identical consecutive durations collapse via
  /// `r` (the count of ADDITIONAL repeats) — mirroring the Dailymotion bridge's
  /// proven `_segmentTimeline` emitter, so a near-uniform 2-hour stream emits a
  /// handful of elements rather than thousands.
  static void _writeTimeline(StringBuffer b, List<int> durations) {
    b.writeln('          <SegmentTimeline>');
    int i = 0;
    while (i < durations.length) {
      final int d = durations[i];
      int repeat = 0;
      while (i + repeat + 1 < durations.length &&
          durations[i + repeat + 1] == d) {
        repeat++;
      }
      b.writeln(
        '            <S${i == 0 ? ' t="0"' : ''} d="$d"'
        '${repeat > 0 ? ' r="$repeat"' : ''}/>',
      );
      i += repeat + 1;
    }
    b.writeln('          </SegmentTimeline>');
  }

  /// One-line description of a stream's resolved index for the
  /// `[BILI-NATIVE-DASH]` smoke-test log.
  static String _describeIndex(_SegBase? seg) {
    final _SidxIndex? idx = seg?.index;
    if (idx == null || !idx.leaf || idx.sizes.isEmpty) return 'whole-file';
    return '${idx.sizes.length}frags/ts=${idx.timescale}';
  }

  /// Build a [_SegBase] from Bilibili's supplied `segmentBase` byte ranges,
  /// preferred over [_probeSegmentBase] (no round-trip, authoritative). Returns
  /// null when no usable initialization range is present, so the caller falls
  /// back to probing. The duration is unknown from ranges alone; it is left null
  /// and the manifest instead uses the entry's total duration.
  static _SegBase? _segBaseFromMeta(DashStreamMeta? meta) {
    if (meta == null) return null;
    final List<int>? init = _parseRange(meta.initializationRange);
    if (init == null) return null;
    final List<int>? index = _parseRange(meta.indexRange);
    return _SegBase(
      init[1] + 1, // initEnd is exclusive; Bilibili's range end is inclusive.
      index?[0],
      index != null ? index[1] + 1 : null,
      null,
    );
  }

  /// Parse an inclusive DASH byte range `"first-last"` (e.g. `"823-1381"`) into
  /// `[first, last]`. Returns null when absent or malformed.
  static List<int>? _parseRange(String? range) {
    if (range == null) return null;
    final int dash = range.indexOf('-');
    if (dash <= 0) return null;
    final int? first = int.tryParse(range.substring(0, dash).trim());
    final int? last = int.tryParse(range.substring(dash + 1).trim());
    if (first == null || last == null || first < 0 || last < first) return null;
    return <int>[first, last];
  }

  /// Return [value] when non-empty, else [fallback]. Keeps the manifest valid
  /// when a metadata field is missing.
  static String _attrOr(String? value, String fallback) =>
      (value != null && value.isNotEmpty) ? value : fallback;

  /// Validate a DASH `frameRate` — an integer (`"30"`) or a rational
  /// (`"30000/1001"`). Returns null (attribute omitted) when absent or invalid.
  static String? _frameRateAttr(String? raw) {
    if (raw == null) return null;
    final String v = raw.trim();
    if (v.isEmpty) return null;
    final int slash = v.indexOf('/');
    if (slash < 0) {
      final int? n = int.tryParse(v);
      return (n != null && n > 0) ? '$n' : null;
    }
    final int? numer = int.tryParse(v.substring(0, slash).trim());
    final int? denom = int.tryParse(v.substring(slash + 1).trim());
    if (numer == null || denom == null || numer <= 0 || denom <= 0) return null;
    return '$numer/$denom';
  }

  /// Validate a DASH `sar` (`"x:y"`, e.g. `"1:1"`). Returns null when absent or
  /// invalid so the attribute is simply omitted.
  static String? _sarAttr(String? raw) {
    if (raw == null) return null;
    final String v = raw.trim();
    final int colon = v.indexOf(':');
    if (colon <= 0) return null;
    final int? x = int.tryParse(v.substring(0, colon).trim());
    final int? y = int.tryParse(v.substring(colon + 1).trim());
    if (x == null || y == null || x <= 0 || y <= 0) return null;
    return '$x:$y';
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Copy a single response header from [from] to [to] when present.
  void _copyHeader(HttpClientResponse from, HttpResponse to, String name) {
    final String? value = from.headers.value(name);
    if (value != null) {
      to.headers.set(name, value);
    }
  }

  /// Emit [status] with an empty body, swallowing socket errors.
  Future<void> _respondStatus(HttpRequest request, int status) async {
    await _safeClose(request.response, status);
  }

  Future<void> _safeClose(HttpResponse res, int status) async {
    try {
      res.statusCode = status;
      await res.close();
    } catch (_) {}
  }

  /// Generate an unguessable, URL-safe registry token.
  String _newToken() {
    const String alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 24; i++) {
      sb.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return sb.toString();
  }

  static String _stripSuffix(String value, String suffix) =>
      value.endsWith(suffix)
          ? value.substring(0, value.length - suffix.length)
          : value;

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// Registry record for one registered [MediaSource].
class _ProxyEntry {
  _ProxyEntry({
    required this.videoUri,
    required this.audioUri,
    required this.referer,
    required this.userAgent,
    this.videoMeta,
    this.audioMeta,
    this.durationSec,
  });

  final String videoUri;

  /// Second DASH stream, or `null` for single-url sources.
  final String? audioUri;

  final String referer;
  final String userAgent;

  /// Real DASH metadata for the video/audio stream (codec, dimensions, byte
  /// ranges). [_buildMpd] emits these into the manifest; null fields fall back
  /// to safe AVC/AAC-shaped defaults.
  final DashStreamMeta? videoMeta;
  final DashStreamMeta? audioMeta;

  /// Total media duration in seconds (from Bilibili's `timelength`). Used as the
  /// manifest's `mediaPresentationDuration` fallback when a stream is not probed
  /// for a `sidx` duration (i.e. when Bilibili's `segmentBase` was used). null ⇒
  /// rely solely on the probed value, if any.
  final double? durationSec;

  /// Whether [videoSeg]/[audioSeg] have been resolved yet (set once, up front).
  bool probed = false;

  /// Probed on-demand `SegmentBase` byte-ranges; null when probing failed (the
  /// manifest then falls back to a BaseURL-only Representation).
  _SegBase? videoSeg;
  _SegBase? audioSeg;
}

/// The byte-ranges an on-demand DASH `Representation` needs so a fragmented-MP4
/// stream can be indexed: the initialization segment (`ftyp`+`moov`) and the
/// segment index (`sidx`). Ranges are inclusive-exclusive internally; the MPD
/// emits inclusive `first-last`.
class _SegBase {
  const _SegBase(this.initEnd, this.sidxStart, this.sidxEnd, this.durationSec,
      [this.index]);

  /// Byte one past the end of `moov`; Initialization range = `0-${initEnd - 1}`.
  final int initEnd;

  /// `sidx` box bounds, or null when the stream carries no top-level index.
  final int? sidxStart;
  final int? sidxEnd;

  /// Total media duration in seconds, summed from the `sidx` subsegment
  /// durations; null when there is no parseable index. Feeds the manifest's
  /// `mediaPresentationDuration` (a `static` MPD needs it to build a timeline).
  final double? durationSec;

  /// The sidx's parsed references, when the probed bytes covered the box —
  /// native mode's fragment enumeration ([_writeSegmentList]). Always null from
  /// [_segBaseFromMeta] (byte-pump metadata path), which never needs it.
  final _SidxIndex? index;

  @override
  String toString() =>
      'init=0-${initEnd - 1} sidx=$sidxStart-$sidxEnd dur=$durationSec';
}

/// The parsed contents of a `sidx` box: the per-fragment byte sizes and tick
/// durations that native mode turns into `<SegmentURL mediaRange>` elements and
/// a `<SegmentTimeline>`.
class _SidxIndex {
  const _SidxIndex(
    this.timescale,
    this.firstMediaOffset,
    this.leaf,
    this.sizes,
    this.durations,
  );

  /// Ticks per second of [durations].
  final int timescale;

  /// Absolute file offset of the first indexed fragment: the sidx anchor point
  /// (the first byte after the box) plus the box's `first_offset`.
  final int firstMediaOffset;

  /// False when any reference points at a child `sidx` (hierarchical index)
  /// rather than media — [sizes] then cannot enumerate fragments, though the
  /// duration total remains valid.
  final bool leaf;

  /// Per-reference `referenced_size` (bytes) and `subsegment_duration` (ticks),
  /// in file order.
  final List<int> sizes;
  final List<int> durations;

  /// Total duration in seconds — the value the manifest has always derived
  /// from the sidx.
  double get durationSeconds =>
      durations.fold(0, (int a, int b) => a + b) / timescale;
}
