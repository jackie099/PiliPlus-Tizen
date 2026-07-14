import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// A single parsed subtitle cue with an inclusive [start] / exclusive [end]
/// time window and the (already unescaped) [text] to display.
typedef SubtitleCue = ({Duration start, Duration end, String text});

/// Visual configuration for [TizenSubtitleOverlay].
///
/// Defaults are tuned for a 1080p television viewed from across a room:
/// large white glyphs with a hard black outline and a soft drop shadow, sitting
/// on a semi-transparent letterbox band near the bottom of the frame.
class TizenSubtitleStyle {
  const TizenSubtitleStyle({
    this.fontSize = 34,
    this.color = Colors.white,
    this.borderColor = Colors.black,
    this.borderWidth = 2.4,
    this.backgroundColor = const Color(0x99000000),
    this.fontWeight = FontWeight.w600,
    this.bottomPadding = 48,
    this.horizontalPadding = 24,
    this.maxWidthFraction = 0.9,
  });

  /// Glyph height in logical pixels.
  final double fontSize;

  /// Fill colour of the text.
  final Color color;

  /// Colour of the outline stroke painted behind the fill.
  final Color borderColor;

  /// Width of the outline stroke in logical pixels. Set to `0` to disable the
  /// outline (only the drop shadow remains).
  final double borderWidth;

  /// Colour of the band painted behind the text. Use a transparent colour to
  /// disable the band entirely.
  final Color backgroundColor;

  /// Weight of the text.
  final FontWeight fontWeight;

  /// Distance from the bottom of the overlay to the subtitle band.
  final double bottomPadding;

  /// Inner horizontal padding of the subtitle band.
  final double horizontalPadding;

  /// Fraction of the available width the band may occupy (0..1).
  final double maxWidthFraction;
}

/// Renders external subtitles as a Flutter overlay, positioned bottom-centre.
///
/// The Samsung `AVPlay` backend cannot draw external `.vtt` / `.srt` tracks, so
/// they are parsed here and painted by Flutter, driven by the player's
/// [positionStream]. This mirrors the plezy-tizen approach: a stream listener
/// resolves the active cue for the current playback position and calls
/// [State.setState] only when the displayed text actually changes.
///
/// The subtitle payload is supplied via [source] and may be:
///  * a raw WebVTT or SRT document,
///  * a `memory://<data>` uri (the prefix is stripped and the remainder parsed),
///  * an `http`/`https` uri (fetched once with a 15s timeout).
///
/// Pass `null`/empty [source] to show nothing; the overlay collapses to a
/// [SizedBox.shrink] whenever there is no active cue.
class TizenSubtitleOverlay extends StatefulWidget {
  const TizenSubtitleOverlay({
    super.key,
    required this.positionStream,
    this.source,
    this.cues,
    this.style = const TizenSubtitleStyle(),
  });

  /// Playback position stream, typically `AbstractMediaPlayer.positionStream`.
  final Stream<Duration> positionStream;

  /// Raw subtitle payload: a VTT/SRT string, a `memory://` uri, or an http(s)
  /// uri. Ignored when [cues] is provided.
  final String? source;

  /// Pre-parsed cues. When supplied these are used verbatim and [source] is
  /// ignored, letting callers reuse a parse from [TizenSubtitleParser].
  final List<SubtitleCue>? cues;

  /// Visual configuration.
  final TizenSubtitleStyle style;

  @override
  State<TizenSubtitleOverlay> createState() => _TizenSubtitleOverlayState();
}

class _TizenSubtitleOverlayState extends State<TizenSubtitleOverlay> {
  StreamSubscription<Duration>? _positionSub;
  List<SubtitleCue> _cues = const [];

  /// Text of the currently displayed cue, or empty when nothing is shown.
  String _current = '';

  /// Index of the last resolved cue, used as a search hint since positions
  /// generally advance monotonically.
  int _lastIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadCues();
    _positionSub = widget.positionStream.listen(_onPosition);
  }

  @override
  void didUpdateWidget(covariant TizenSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.positionStream, widget.positionStream)) {
      _positionSub?.cancel();
      _positionSub = widget.positionStream.listen(_onPosition);
    }
    if (oldWidget.cues != widget.cues || oldWidget.source != widget.source) {
      _loadCues();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCues() async {
    if (widget.cues != null) {
      _setCues(widget.cues!);
      return;
    }
    final source = widget.source;
    if (source == null || source.isEmpty) {
      _setCues(const []);
      return;
    }
    try {
      final cues = await TizenSubtitleParser.load(source);
      if (mounted) _setCues(cues);
    } catch (_) {
      // A missing or malformed subtitle track must never break playback.
      if (mounted) _setCues(const []);
    }
  }

  void _setCues(List<SubtitleCue> cues) {
    _cues = cues;
    _lastIndex = 0;
    if (_current.isNotEmpty) {
      setState(() => _current = '');
    }
  }

  void _onPosition(Duration position) {
    final text = _cueTextAt(position);
    if (text != _current && mounted) {
      setState(() => _current = text);
    }
  }

  /// Resolves the text of the cue whose window contains [position], or an empty
  /// string when no cue is active. Cues are assumed sorted by [start].
  String _cueTextAt(Duration position) {
    final cues = _cues;
    if (cues.isEmpty) return '';

    // Fast path: the previously matched cue often still applies.
    if (_lastIndex < cues.length) {
      final cue = cues[_lastIndex];
      if (position >= cue.start && position < cue.end) return cue.text;
    }

    // Binary search for the last cue whose start is <= position.
    int lo = 0;
    int hi = cues.length - 1;
    int candidate = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= position) {
        candidate = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (candidate >= 0 && position < cues[candidate].end) {
      _lastIndex = candidate;
      return cues[candidate].text;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (_current.isEmpty) return const SizedBox.shrink();
    final style = widget.style;

    final textStyle = TextStyle(
      color: style.color,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      height: 1.25,
      shadows: const [
        Shadow(color: Color(0xB3000000), blurRadius: 4, offset: Offset(0, 1)),
      ],
    );

    // Outline is achieved by stacking a stroked copy under the filled copy.
    final Widget label = style.borderWidth > 0
        ? Stack(
            children: [
              Text(
                _current,
                textAlign: TextAlign.center,
                style: textStyle.copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = style.borderWidth
                    ..strokeJoin = StrokeJoin.round
                    ..color = style.borderColor,
                ),
              ),
              Text(_current, textAlign: TextAlign.center, style: textStyle),
            ],
          )
        : Text(_current, textAlign: TextAlign.center, style: textStyle);

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth * style.maxWidthFraction
              : double.infinity;
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: style.bottomPadding),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: style.backgroundColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: style.horizontalPadding,
                      vertical: 6,
                    ),
                    child: label,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Dependency-light WebVTT / SubRip (SRT) parser.
///
/// Handles the payload shapes accepted by [TizenSubtitleOverlay]: raw strings,
/// `memory://` data uris, and remote http(s) uris. The two formats are close
/// enough that a single cue-block scanner covers both; the only meaningful
/// differences are the `WEBVTT` header, the numeric index line SRT prepends to
/// each cue, and the timestamp separator (`.` for VTT, `,` for SRT).
abstract final class TizenSubtitleParser {
  static const Duration _fetchTimeout = Duration(seconds: 15);

  /// Loads and parses cues from [source].
  ///
  /// [source] may be a raw VTT/SRT document, a `memory://<data>` uri, or an
  /// `http`/`https` uri. Throws on network failure; returns an empty list for
  /// empty input.
  static Future<List<SubtitleCue>> load(String source) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return const [];

    if (trimmed.startsWith('memory://')) {
      return parse(_stripMemoryPrefix(trimmed));
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return parse(await _fetch(trimmed));
    }
    return parse(source);
  }

  static String _stripMemoryPrefix(String uri) {
    var data = uri.substring('memory://'.length);
    // Some producers percent-encode the payload behind the scheme.
    if (data.contains('%')) {
      try {
        data = Uri.decodeComponent(data);
      } catch (_) {
        // Fall back to the raw substring if it is not valid percent-encoding.
      }
    }
    return data;
  }

  static Future<String> _fetch(String url) async {
    final client = HttpClient()..connectionTimeout = _fetchTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(_fetchTimeout);
      final response = await request.close().timeout(_fetchTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(_fetchTimeout);
    } finally {
      client.close(force: true);
    }
  }

  /// Parses a raw VTT or SRT [content] string into time-sorted cues.
  static List<SubtitleCue> parse(String content) {
    if (content.isEmpty) return const [];

    // Normalise line endings and drop a leading UTF-8 BOM if present.
    final normalized = content
        .replaceFirst('﻿', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final cues = <SubtitleCue>[];
    for (final block in normalized.split('\n\n')) {
      final cue = _parseBlock(block);
      if (cue != null) cues.add(cue);
    }

    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  /// Parses one cue block (a run of lines between blank lines). Returns null for
  /// blocks that carry no timing line (headers, `NOTE`/`STYLE` blocks, etc.).
  static SubtitleCue? _parseBlock(String block) {
    final lines = block.split('\n');
    var i = 0;

    // Skip the WEBVTT header and any leading blank/index/cue-id lines until a
    // timing line ("... --> ...") is found.
    int? timingLine;
    for (; i < lines.length; i++) {
      if (lines[i].contains('-->')) {
        timingLine = i;
        break;
      }
    }
    if (timingLine == null) return null;

    final range = _parseTimingLine(lines[timingLine]);
    if (range == null) return null;

    final text = lines
        .sublist(timingLine + 1)
        .map(_stripTags)
        .join('\n')
        .trim();
    if (text.isEmpty) return null;

    return (start: range.$1, end: range.$2, text: text);
  }

  /// Parses a `start --> end [settings]` line into a `(start, end)` record.
  static (Duration, Duration)? _parseTimingLine(String line) {
    final parts = line.split('-->');
    if (parts.length < 2) return null;

    final start = _parseTimestamp(parts[0]);
    // The end token may be followed by VTT cue settings (e.g. "line:90%").
    final endToken = parts[1].trim().split(RegExp(r'\s+')).first;
    final end = _parseTimestamp(endToken);
    if (start == null || end == null) return null;

    return (start, end);
  }

  /// Parses a timestamp of the form `[HH:]MM:SS[.,]mmm` into a [Duration].
  static Duration? _parseTimestamp(String raw) {
    final token = raw.trim().replaceAll(',', '.');
    if (token.isEmpty) return null;

    final dotIndex = token.lastIndexOf('.');
    final hms = dotIndex >= 0 ? token.substring(0, dotIndex) : token;
    final millisPart = dotIndex >= 0 ? token.substring(dotIndex + 1) : '';

    final segments = hms.split(':');
    if (segments.isEmpty || segments.length > 3) return null;

    int hours = 0;
    int minutes = 0;
    int seconds = 0;
    try {
      if (segments.length == 3) {
        hours = int.parse(segments[0]);
        minutes = int.parse(segments[1]);
        seconds = int.parse(segments[2]);
      } else if (segments.length == 2) {
        minutes = int.parse(segments[0]);
        seconds = int.parse(segments[1]);
      } else {
        seconds = int.parse(segments[0]);
      }
    } on FormatException {
      return null;
    }

    // Pad/truncate the fractional part to exactly three digits (milliseconds).
    var millis = 0;
    if (millisPart.isNotEmpty) {
      final digits = millisPart.padRight(3, '0').substring(0, 3);
      millis = int.tryParse(digits) ?? 0;
    }

    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }

  static final RegExp _tagPattern = RegExp(r'<[^>]*>');

  /// Removes inline VTT/SRT markup (`<b>`, `<c.classname>`, `<00:00.000>`, ...)
  /// and decodes the handful of XML entities the formats use.
  static String _stripTags(String line) {
    return line
        .replaceAll(_tagPattern, '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ');
  }
}
