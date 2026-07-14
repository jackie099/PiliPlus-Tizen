import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Runs the Bilibili CDN mirror speed test and exposes one [ValueNotifier] per
/// [CDNService], so any widget can render a live "x.x MB/s" label per line.
///
/// Shared by the TV settings CDN page and the in-player CDN submenu. Each mirror
/// is measured by host-rewriting the same sample stream (via
/// [VideoUtils.getCdnUrl]) and timing a short range download. Sequential — one
/// socket at a time — because many concurrent sockets are unstable on the Tizen
/// runtime.
class CdnSpeedTest {
  /// Per-test byte cap and timeout — small enough to keep the sweep responsive
  /// (and to limit how much bandwidth it steals from a concurrently-playing
  /// stream), large enough to be meaningful.
  static const int _capBytes = 4 * 1024 * 1024; // 4 MiB
  static const Duration _perTestTimeout = Duration(seconds: 8);

  /// [videoItem] — when given (e.g. the currently-playing stream), each mirror
  /// is measured against THIS video's own URL, so the numbers reflect what the
  /// user is actually watching. CDN throughput is per-object, so a fixed sample
  /// can read fast while the real stream's mirror is slow. Falls back to a fixed
  /// public sample when null (e.g. the standalone settings page).
  CdnSpeedTest({this.videoItem})
    : results = List<ValueNotifier<String?>>.generate(
        CDNService.values.length,
        (_) => ValueNotifier<String?>(null),
        growable: false,
      );

  final BaseItem? videoItem;

  /// Result label per [CDNService] index: null = not tested yet,
  /// '测速中…' = in progress, else 'x.x MB/s' or a short failure reason.
  final List<ValueNotifier<String?>> results;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: _perTestTimeout,
      headers: {
        'user-agent': BrowserUa.pc,
        'referer': HttpString.baseUrl,
      },
    ),
  );

  CancelToken? _active;
  bool _started = false;
  bool _disposed = false;

  /// Kick off the sweep. Idempotent — a second call is ignored.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _run();
  }

  void dispose() {
    _disposed = true;
    _active?.cancel();
    _dio.close(force: true);
    for (final n in results) {
      n.dispose();
    }
  }

  Future<void> _run() async {
    final BaseItem? sample = await _sampleItem();
    if (_disposed) return;
    if (sample == null) {
      for (final n in results) {
        n.value = '无法获取测速样本';
      }
      return;
    }
    for (int i = 0; i < CDNService.values.length; i++) {
      if (_disposed) return;
      results[i].value = '测速中…';
      final String label = await _measure(CDNService.values[i], sample);
      if (_disposed) return;
      results[i].value = label;
    }
  }

  /// The stream to test each mirror against: the currently-playing video when
  /// provided, otherwise a small fixed public sample (the mobile dialog's one).
  Future<BaseItem?> _sampleItem() async {
    if (videoItem != null) return videoItem;
    try {
      final res = await VideoHttp.videoUrl(
        cid: 196018899,
        bvid: 'BV1fK4y1t7hj',
        tryLook: false,
        videoType: VideoType.ugc,
      );
      return res.dataOrNull?.dash?.video?.first;
    } catch (_) {
      return null;
    }
  }

  /// Download a short range of [sample] through [cdn] and return a MB/s label
  /// (or a short failure reason). Never throws.
  Future<String> _measure(CDNService cdn, BaseItem sample) async {
    final CancelToken token = CancelToken();
    _active = token;
    final Stopwatch sw = Stopwatch()..start();
    int bytes = 0;
    try {
      final String url = VideoUtils.getCdnUrl(
        sample.playUrls,
        defaultCDNService: cdn,
      );
      final Response<ResponseBody> resp = await _dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'range': 'bytes=0-${_capBytes - 1}'},
        ),
      );
      await for (final chunk in resp.data!.stream) {
        bytes += chunk.length;
        if (bytes >= _capBytes ||
            sw.elapsedMilliseconds >= _perTestTimeout.inMilliseconds) {
          break;
        }
      }
      token.cancel();
      return _label(bytes, sw.elapsedMicroseconds);
    } on DioException catch (e) {
      token.cancel();
      final int? code = e.response?.statusCode;
      if (code != null && code >= 400 && code < 500) {
        return '不支持该线路';
      }
      return _label(bytes, sw.elapsedMicroseconds);
    } catch (_) {
      token.cancel();
      return _label(bytes, sw.elapsedMicroseconds);
    }
  }

  /// MB/s = bytes / microseconds (both /1e6 cancel out); '测速失败' if nothing
  /// transferred (or a cap/timeout break surfaced with partial bytes).
  static String _label(int bytes, int us) {
    if (bytes <= 0 || us <= 0) return '测速失败';
    return '${(bytes / us).toStringAsFixed(2)} MB/s';
  }
}
