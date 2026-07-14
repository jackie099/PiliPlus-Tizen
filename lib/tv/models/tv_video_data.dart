import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/horizontal_video_model.dart';
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
}
