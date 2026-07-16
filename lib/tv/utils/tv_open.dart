import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/horizontal_video_model.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';

/// Opens feed items through the same routes the TV home uses
/// (PageUtils.toVideoPage / viewPgc / PiliScheme), so every TV feed shares
/// one open path with the recommend grid.
abstract final class TvOpen {
  /// Opens hot / search-result items. Mirrors the mobile VideoCardH onTap
  /// flow: pugv -> course page, live -> live room, pgc redirect -> pgc page,
  /// otherwise resolve cid and push the video page.
  static Future<void> openHorizontalVideo(HorizontalVideoModel item) async {
    if (item.isPugv ?? false) {
      return PageUtils.viewPugv(seasonId: item.seasonId);
    }

    if (item.isLive ?? false) {
      PageUtils.toLiveRoom(item.roomId);
      return;
    }

    if (item.redirectUrl?.isNotEmpty == true &&
        PageUtils.viewPgcFromUri(item.redirectUrl!)) {
      return;
    }

    final bvid = item.bvid?.isNotEmpty == true ? item.bvid : null;
    if (item.aid == null && bvid == null) return;
    int? cid = item.cid;
    Dimension? dimension = item.dimension;
    if (cid == null) {
      final res = await SearchHttp.ab2cWithDimension(
        aid: item.aid,
        bvid: bvid,
      );
      cid = res?.cid;
      dimension = res?.dimension;
    }
    if (cid != null) {
      PageUtils.toVideoPage(
        aid: item.aid,
        bvid: bvid,
        cid: cid,
        cover: item.cover,
        title: item.title,
        dimension: dimension,
      );
    }
  }

  /// Opens a video-type dynamic: pgc episodes go to the pgc page, archives
  /// resolve cid and push the video page, anything else falls back to the
  /// item's jump url through the scheme router.
  static Future<void> openDynamic(DynamicItemModel item) async {
    final major = item.modules.moduleDynamic?.major;

    if (major?.pgc case final pgc? when pgc.epid != null) {
      return PageUtils.viewPgc(epId: pgc.epid);
    }

    final archive = major?.archive ?? major?.ugcSeason;
    if (archive != null) {
      final aid = archive.aid;
      final bvid = archive.bvid?.startsWith('BV') == true
          ? archive.bvid
          : (aid != null ? IdUtils.av2bv(aid) : null);
      if (aid != null || bvid != null) {
        final res = await SearchHttp.ab2cWithDimension(aid: aid, bvid: bvid);
        if (res?.cid case final cid?) {
          PageUtils.toVideoPage(
            aid: aid,
            bvid: bvid,
            cid: cid,
            cover: archive.cover,
            title: archive.title,
            dimension: res?.dimension,
          );
          return;
        }
      }
      if (archive.jumpUrl case final jumpUrl? when jumpUrl.isNotEmpty) {
        PiliScheme.routePushFromUrl(jumpUrl);
      }
    }
  }

  /// Opens a watch-history entry, resuming at the saved position. Videos
  /// (archive) resolve cid if needed and push the video page with the resume
  /// offset; bangumi/movie (pgc) go to the pgc page; live goes to the room.
  static Future<void> openHistory(HistoryItemModel item) async {
    final history = item.history;
    // Bilibili reports progress in seconds (-1 == finished); resume only for a
    // real mid-video offset, otherwise start from the beginning.
    final int? resumeMs = (item.progress != null && item.progress! > 0)
        ? item.progress! * 1000
        : null;

    if (history.business == 'pgc' && history.epid != null) {
      return PageUtils.viewPgc(epId: history.epid, progress: resumeMs);
    }
    if (history.business == 'live') {
      return PageUtils.toLiveRoom(history.oid);
    }

    final aid = history.oid;
    final bvid = history.bvid?.isNotEmpty == true ? history.bvid : null;
    if (aid == null && bvid == null) return;
    int? cid = history.cid;
    Dimension? dimension;
    if (cid == null) {
      final res = await SearchHttp.ab2cWithDimension(aid: aid, bvid: bvid);
      cid = res?.cid;
      dimension = res?.dimension;
    }
    if (cid != null) {
      PageUtils.toVideoPage(
        aid: aid,
        bvid: bvid,
        cid: cid,
        cover: item.cover,
        title: item.title,
        progress: resumeMs,
        dimension: dimension,
      );
    }
  }
}
