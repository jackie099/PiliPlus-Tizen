import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/horizontal_video_model.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/models_new/live/live_feed_index/card_data_list_item.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';

/// Lightweight, display-ready view-model consumed by the generic TV feed
/// widgets (TvDataVideoCard / TvFeedGrid).
///
/// The recommend feed keeps using TvVideoCard bound to its concrete model;
/// every other feed (hot, search, dynamics, ...) maps its own model into this
/// shape once, so the grid/card never depend on feed-specific classes. All
/// texts are pre-formatted here; `null` hides the corresponding element.
class TvVideoData {
  const TvVideoData({
    required this.title,
    this.cover,
    this.ownerName,
    this.viewText,
    this.danmuText,
    this.durationText,
    this.progress,
    this.finished = false,
    this.remainingText,
    this.viewAtText,
    this.showPlayGlyph = false,
    this.isLive = false,
  });

  final String title;
  final String? cover;
  final String? ownerName;

  /// Formatted view count (e.g. `12.3万`); null hides the stat.
  final String? viewText;

  /// Formatted danmaku count; null hides the stat.
  final String? danmuText;

  /// Formatted duration badge (e.g. `12:34`); null hides the badge.
  final String? durationText;

  /// Watch progress as a 0..1 fraction, for the "continue watching" bar on the
  /// cover; null hides the bar.
  final double? progress;

  /// Whether the source was watched to the end (shows a "已看完" badge instead
  /// of a progress bar).
  final bool finished;

  /// Pre-formatted remaining-time line for the hero card (e.g. `还剩 8 分钟`);
  /// null hides it.
  final String? remainingText;

  /// Pre-formatted "last watched" timestamp for the history grid meta row
  /// (e.g. `今天 14:32`); null hides it.
  final String? viewAtText;

  /// Whether to show the focus-only ▶ resume glyph (history-sourced cards).
  final bool showPlayGlyph;

  /// Whether this card is a live stream: the cover shows a red LIVE pill in
  /// place of the duration badge, and [viewText] renders with a viewer/eye icon
  /// (the `watchedShow` "N人看过" line) instead of the play-count icon.
  final bool isLive;

  /// Maps hot / search-result items ([HorizontalVideoModel] subclasses).
  static TvVideoData fromHorizontal(HorizontalVideoModel item) {
    final view = item.stat.view;
    final danmu = item.stat.danmu;
    return TvVideoData(
      title: item.title,
      cover: item.cover,
      ownerName: item.owner.name,
      viewText: view == null ? null : NumUtils.numFormat(view),
      danmuText: danmu == null ? null : NumUtils.numFormat(danmu),
      durationText: item.duration > 0
          ? DurationUtils.formatDuration(item.duration)
          : null,
    );
  }

  /// Maps a live-stream card ([CardLiveItem], from the live feed's recommended
  /// list or the 正在直播的关注 follow rail). Live streams have no duration, so
  /// the cover shows a red LIVE pill instead; the `watchedShow` "N人看过" line
  /// becomes the (eye-iconed) view stat.
  static TvVideoData fromLiveCard(CardLiveItem item) {
    return TvVideoData(
      title: item.title ?? '',
      cover: item.systemCover,
      ownerName: item.uname,
      viewText: item.watchedShow?.textLarge,
      isLive: true,
    );
  }

  /// Maps a video-type dynamic (投稿动态). The archive stat texts come
  /// pre-formatted from the API.
  static TvVideoData fromDynamic(DynamicItemModel item) {
    final modules = item.modules;
    final major = modules.moduleDynamic?.major;
    final archive = major?.archive ?? major?.ugcSeason ?? major?.pgc;
    final durationText = archive?.durationText;
    return TvVideoData(
      title: archive?.title ?? modules.moduleDynamic?.desc?.text ?? '动态',
      cover: archive?.cover,
      ownerName: modules.moduleAuthor?.name,
      viewText: archive?.stat?.play,
      danmuText: archive?.stat?.danmu,
      durationText: durationText?.isNotEmpty == true ? durationText : null,
    );
  }

  /// Maps a watch-history entry ([HistoryItemModel]). Surfaces resume state:
  /// mid-progress shows a bar + `position / total` badge + a remaining line;
  /// finished shows a "已看完" badge and no bar. The history payload carries no
  /// view/danmaku stats, so those are omitted (the meta row shows the
  /// last-watched time instead).
  static TvVideoData fromHistory(HistoryItemModel item) {
    final int? dur = item.duration;
    final int? prog = item.progress;
    // progress is in seconds; -1 (or >= duration) means watched to the end.
    final bool finished =
        prog != null && (prog < 0 || (dur != null && dur > 0 && prog >= dur));

    double? fraction;
    String? durationText;
    String? remainingText;
    if (finished) {
      // Badge is rendered as "已看完" by the card; no bar, no duration text.
    } else if (prog != null && prog > 0 && dur != null && dur > 0) {
      fraction = (prog / dur).clamp(0.0, 1.0);
      durationText =
          '${DurationUtils.formatDuration(prog)} / '
          '${DurationUtils.formatDuration(dur)}';
      remainingText = _formatRemaining(prog, dur);
    } else {
      // Barely started / unknown progress: just the total duration.
      durationText = (dur != null && dur > 0)
          ? DurationUtils.formatDuration(dur)
          : null;
    }

    return TvVideoData(
      title: item.title?.isNotEmpty == true
          ? item.title!
          : (item.showTitle ?? ''),
      cover: item.cover,
      ownerName: item.authorName,
      durationText: durationText,
      progress: fraction,
      finished: finished,
      remainingText: remainingText,
      viewAtText: _formatViewAt(item.viewAt),
      showPlayGlyph: true,
    );
  }

  /// `还剩 N 分钟` for the hero row's second line; null when finished/unknown.
  static String? _formatRemaining(int? progress, int? duration) {
    if (progress == null || duration == null || duration <= 0 || progress < 0) {
      return null;
    }
    final int remaining = duration - progress;
    if (remaining <= 0) return null;
    if (remaining < 60) return '还剩不足 1 分钟';
    final int mins = (remaining / 60).ceil();
    if (mins < 60) return '还剩 $mins 分钟';
    final int hours = remaining ~/ 3600;
    final int remMins = ((remaining % 3600) / 60).round();
    return remMins > 0 ? '还剩 $hours 小时 $remMins 分钟' : '还剩 $hours 小时';
  }

  /// Friendly "last watched" time from a Unix-seconds timestamp:
  /// `今天 14:32` / `昨天 20:15` / `7月10日` / `2025-12-31`.
  static String? _formatViewAt(int? viewAt) {
    if (viewAt == null || viewAt <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(viewAt * 1000);
    final now = DateTime.now();
    final int diffDays = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(dt.year, dt.month, dt.day)).inDays;
    String two(int n) => n.toString().padLeft(2, '0');
    final String hm = '${two(dt.hour)}:${two(dt.minute)}';
    if (diffDays <= 0) return '今天 $hm';
    if (diffDays == 1) return '昨天 $hm';
    if (dt.year == now.year) return '${dt.month}月${dt.day}日';
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }
}
