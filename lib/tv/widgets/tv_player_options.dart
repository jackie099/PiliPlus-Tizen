import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/cdn_speed_test.dart';
import 'package:PiliPlus/tv/widgets/tv_option_row.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

enum _PanelMode {
  main('播放选项'),
  quality('清晰度'),
  decode('解码格式'),
  audio('音质'),
  subtitle('字幕'),
  chapter('章节'),
  episode('选集'),
  speed('播放速度'),
  cdn('CDN 线路');

  final String title;
  const _PanelMode(this.title);
}

/// Right-side options panel of the TV video page: 弹幕 on/off, 清晰度 / 音质 /
/// 播放速度 submenus and 画面比例 / 播放顺序 cycling rows, all driven by the
/// existing controllers ([PlPlayerController]'s `enableShowDanmaku` /
/// `setPlaybackSpeed` / `toggleVideoFit` / `setPlayRepeat` and
/// [VideoDetailController]'s `currentVideoQa` / `currentAudioQa` +
/// `updatePlayer`, the same paths the mobile header uses).
///
/// D-pad: Up/Down move between rows (handled here with explicit focus nodes
/// so focus can never wander into the dormant mobile player chrome), OK
/// activates, Back returns from a submenu or calls [onClose].
class TvPlayerOptions extends StatefulWidget {
  const TvPlayerOptions({
    super.key,
    required this.plPlayerController,
    required this.videoDetailController,
    required this.introController,
    required this.onClose,
    this.onOpenComments,
  });

  final PlPlayerController plPlayerController;
  final VideoDetailController videoDetailController;

  /// Drives 上一集/下一集/选集 — [CommonIntroController.prevPlay]/[nextPlay] are
  /// universal; arbitrary-jump goes through the UGC/PGC `onChangeEpisode`.
  final CommonIntroController introController;
  final VoidCallback onClose;

  /// Opens the read-only comments panel; null when the video has no replies.
  final VoidCallback? onOpenComments;

  /// Friendly codec label for the on-screen readouts, mapping the play-url
  /// codec ids ([VideoDecodeFormatType]) to household names.
  static String codecLabel(VideoDecodeFormatType format) => switch (format) {
    VideoDecodeFormatType.AVC => 'H.264',
    VideoDecodeFormatType.HEVC => 'H.265',
    VideoDecodeFormatType.AV1 => 'AV1',
    VideoDecodeFormatType.DVH1 => 'Dolby Vision',
  };

  @override
  State<TvPlayerOptions> createState() => _TvPlayerOptionsState();
}

class _TvPlayerOptionsState extends State<TvPlayerOptions> {
  _PanelMode _mode = _PanelMode.main;

  /// Node pool: grows to the largest list shown and is disposed with the
  /// panel (never shrunk mid-build while old rows may still be attached).
  final List<FocusNode> _nodes = [];
  int _rowCount = 0;

  /// Lazily created the first time the CDN submenu opens, so its per-mirror
  /// speed test only runs (and competes with the playing stream) on demand.
  CdnSpeedTest? _cdnTest;

  @override
  void initState() {
    super.initState();
    // The page's root focus node holds focus when the panel opens; move it
    // to the first row once the rows exist.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstRow());
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    _cdnTest?.dispose();
    super.dispose();
  }

  void _syncNodes(int count) {
    _rowCount = count;
    while (_nodes.length < count) {
      _nodes.add(FocusNode(debugLabel: 'TvPlayerOption-${_nodes.length}'));
    }
  }

  void _focusFirstRow() {
    if (mounted && _rowCount > 0) {
      _nodes.first.requestFocus();
    }
  }

  void _setMode(_PanelMode mode) {
    // Start the mirror speed test the first time the CDN submenu is opened,
    // measuring THIS video's own stream so the numbers reflect what's playing
    // (firstVideo is set with currentVideoQa, so the null-check gates it too).
    if (mode == _PanelMode.cdn) {
      final videoCtr = widget.videoDetailController;
      final item = videoCtr.currentVideoQa.value != null
          ? videoCtr.firstVideo
          : null;
      _cdnTest ??= (CdnSpeedTest(videoItem: item)..start());
    }
    setState(() => _mode = mode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstRow());
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;

    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        if (_mode != _PanelMode.main) {
          _setMode(_PanelMode.main);
        } else {
          widget.onClose();
        }
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (isPress && _rowCount > 0) {
        final current = _nodes.indexWhere((n) => n.hasFocus);
        final target = key == LogicalKeyboardKey.arrowUp
            ? current - 1
            : current + 1;
        if (current != -1 && target >= 0 && target < _rowCount) {
          _nodes[target].requestFocus();
        }
      }
      return KeyEventResult.handled;
    }

    // Keep focus and playback state stable while the panel is up: swallow
    // horizontal/seek/menu keys instead of letting the page act on them.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.contextMenu) {
      return KeyEventResult.handled;
    }

    // Select/Enter falls through to the app-level Shortcuts -> ActivateIntent
    // on the focused row.
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------- actions --

  /// Mirrors the mobile danmaku switch (header_control / PlayerFocus keyD):
  /// flip the reactive flag so danmaku shows/hides live, persist unless the
  /// player runs with a temporary config.
  void _toggleDanmaku() {
    final player = widget.plPlayerController;
    final newVal = !player.enableShowDanmaku.value;
    player.enableShowDanmaku.value = newVal;
    if (!player.tempPlayerConf) {
      GStorage.setting.put(SettingBoxKey.enableShowDanmaku, newVal);
    }
  }

  void _openQuality() {
    final videoCtr = widget.videoDetailController;
    if (videoCtr.currentVideoQa.value == null) {
      SmartDialog.showToast('视频加载中，请稍后再试');
      return;
    }
    if (videoCtr.isFileSource || videoCtr.data.dash == null) {
      SmartDialog.showToast('当前视频不支持选择画质');
      return;
    }
    _setMode(_PanelMode.quality);
  }

  /// Same switch path as the mobile header (`showSetVideoQa`): update the
  /// cached/current quality and let `updatePlayer()` re-resolve the stream.
  void _switchQuality(FormatItem item) {
    final videoCtr = widget.videoDetailController;
    final int quality = item.quality!;
    if (videoCtr.currentVideoQa.value?.code != quality) {
      final newQa = VideoQuality.fromCode(quality);
      videoCtr
        ..plPlayerController.cacheVideoQa = newQa.code
        ..currentVideoQa.value = newQa
        ..updatePlayer();
      SmartDialog.showToast('画质已变为：${newQa.desc}');
      // The TV always resolves as the non-cellular slot
      // (ConnectivityUtils.isWiFi is mobile-only), so persist straight to
      // defaultVideoQa — the key `cacheVideoQa` reads on TV.
      if (!widget.plPlayerController.tempPlayerConf) {
        GStorage.setting.put(SettingBoxKey.defaultVideoQa, quality);
      }
    }
    widget.onClose();
  }

  void _openAudioQuality() {
    final videoCtr = widget.videoDetailController;
    if (videoCtr.currentVideoQa.value == null) {
      SmartDialog.showToast('视频加载中，请稍后再试');
      return;
    }
    if (videoCtr.isFileSource ||
        videoCtr.currentAudioQa == null ||
        videoCtr.data.dash?.audio?.isNotEmpty != true) {
      SmartDialog.showToast('当前视频不支持选择音质');
      return;
    }
    _setMode(_PanelMode.audio);
  }

  /// Same switch path as the mobile header (`showSetAudioQa`): update the
  /// cached/current audio quality and let `updatePlayer()` re-resolve the
  /// stream. Persists to the non-cellular slot, same rationale as
  /// [_switchQuality].
  void _switchAudioQuality(AudioItem item) {
    final videoCtr = widget.videoDetailController;
    final int quality = item.id!;
    if (videoCtr.currentAudioQa?.code != quality) {
      final newQa = AudioQuality.fromCode(quality);
      // Dolby Atmos (EC-3, 30250/30255) is sticky via its own pref, and must NOT
      // leak into cacheAudioQa/defaultAudioQa: a dolby code is < 192K (30280)
      // numerically, so the closest-target selector would downgrade a later
      // no-dolby (flac) episode in the same session to 192K. updatePlayer()
      // resolves the audio from currentAudioQa, so the immediate switch still
      // applies without touching cacheAudioQa.
      final bool isDolby = quality == AudioQuality.dolby_30250.code ||
          quality == AudioQuality.dolby_30255.code;
      if (!isDolby) {
        videoCtr.plPlayerController.cacheAudioQa = newQa.code;
      }
      videoCtr
        ..currentAudioQa = newQa
        ..updatePlayer();
      SmartDialog.showToast('音质已变为：${newQa.desc}');
      if (!widget.plPlayerController.tempPlayerConf) {
        if (isDolby) {
          GStorage.setting.put(SettingBoxKey.preferDolbyAtmos, true);
        } else {
          GStorage.setting
            ..put(SettingBoxKey.defaultAudioQa, quality)
            ..put(SettingBoxKey.preferDolbyAtmos, false);
        }
      }
    }
    widget.onClose();
  }

  void _switchSpeed(double speed) {
    widget.plPlayerController.setPlaybackSpeed(speed);
    _setMode(_PanelMode.main);
  }

  /// Fit modes offered on TV. The AVPlay hardware overlay can only be laid
  /// out (see `_fitTizenOverlay` in the player view): `fill` stretches to the
  /// screen, the fixed ratios letterbox to 16:9 / 4:3, and everything else
  /// letterboxes to the video's own ratio — so contain-like variants (cover,
  /// fitWidth, ...) would all render identically to 自动 and are left out.
  static const List<VideoFitType> _tvFits = [
    VideoFitType.contain,
    VideoFitType.fill,
    VideoFitType.ratio_16x9,
    VideoFitType.ratio_4x3,
  ];

  /// Same path as the mobile fit selector (`toggleVideoFit`): updates the
  /// reactive `videoFit` (the Tizen surface relayouts live) and persists it.
  void _cycleVideoFit() {
    final player = widget.plPlayerController;
    final index = _tvFits.indexOf(player.videoFit.value);
    player.toggleVideoFit(_tvFits[(index + 1) % _tvFits.length]);
  }

  /// Same path as the mobile header's 播放顺序 menu (`setPlayRepeat`).
  /// `playRepeat` is a plain field, so rebuild explicitly.
  void _cyclePlayRepeat() {
    final player = widget.plPlayerController;
    const values = PlayRepeat.values;
    final next = values[(player.playRepeat.index + 1) % values.length];
    player.setPlayRepeat(next);
    setState(() {});
  }

  // ---------------------------------------------------------------- rows --

  /// The 播放选项 rows, as node-injected builders so adding a row never needs
  /// hand-renumbered focus-node indices: [build] assigns `_nodes[i]` by position
  /// and derives the row count from the list length.
  List<Widget Function(FocusNode)> _mainRowBuilders() {
    final player = widget.plPlayerController;
    final videoCtr = widget.videoDetailController;
    final intro = widget.introController;
    final episodes = _episodes();
    return [
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '弹幕',
          value: player.enableShowDanmaku.value ? '开' : '关',
          onSelect: _toggleDanmaku,
        ),
      ),
      if (widget.onOpenComments case final open?)
        (n) => TvOptionRow(
          focusNode: n,
          label: '评论',
          value: '查看',
          onSelect: open,
        ),
      // Engagement — clean API toggles that keep the panel open to show the new
      // state (no mobile sheet/page: those aren't D-pad navigable). 投币 is
      // omitted everywhere (it needs a 1/2-coin selection page).
      //
      // 点赞: valid for UGC and PGC-bangumi (UgcIntroController /
      // PgcIntroController both implement a bvid-based actionLikeVideo), but NOT
      // for paid courses (VideoType.pugv) — those have no video-like (the mobile
      // PGC page shows 收藏 via onFavPugv there, not the like/coin/fav triple).
      // Local file sources have no like either.
      if (!videoCtr.isFileSource && videoCtr.videoType != VideoType.pugv)
        (n) => Obx(
          () => TvOptionRow(
            focusNode: n,
            label: '点赞',
            value: intro.hasLike.value ? '已赞' : '赞',
            onSelect: intro.actionLikeVideo,
          ),
        ),
      // 收藏: the generic actionFavVideo is correct ONLY for UGC. PGC/paid-course
      // (pugv) favourites use a different API & state (PgcIntroController.
      // onFavPugv / 追番) that isn't wired for TV, so offering the generic action
      // there would favourite the wrong resource — don't show it.
      if (videoCtr.isUgc && !videoCtr.isFileSource)
        (n) => Obx(
          () => TvOptionRow(
            focusNode: n,
            label: '收藏',
            value: intro.hasFav.value ? '已收藏' : '收藏',
            onSelect: _fav,
          ),
        ),
      // Multi-part (分P) picker + sequential prev/next, shown only for series.
      // prev/next are universal (CommonIntroController); the jump picker covers
      // 分P here (合集/PGC series still navigate via prev/next).
      if (episodes.length > 1)
        (n) => TvOptionRow(
          focusNode: n,
          label: '选集',
          value: '${episodes.length}P',
          onSelect: _openEpisode,
        ),
      if (_isSeries) ...[
        (n) => TvOptionRow(
          focusNode: n,
          label: '上一集',
          onSelect: _prevEpisode,
        ),
        (n) => TvOptionRow(
          focusNode: n,
          label: '下一集',
          onSelect: _nextEpisode,
        ),
      ],
      // Doubles as the "now playing" readout: quality plus codec. The
      // reactive currentVideoQa also guards the late currentDecodeFormats
      // (they are assigned together when the play-url resolves).
      (n) => Obx(() {
        final qa = videoCtr.currentVideoQa.value;
        return TvOptionRow(
          focusNode: n,
          label: '清晰度',
          value: qa == null
              ? '加载中'
              : '${qa.desc} · '
                    '${TvPlayerOptions.codecLabel(videoCtr.currentDecodeFormats)}',
          onSelect: _openQuality,
        );
      }),
      // Decode format (codec) — sits by 清晰度. TV defaults HEVC-first; letting
      // the user force AVC/AV1 helps when a codec misbehaves on the panel.
      (n) => Obx(() {
        final loaded = videoCtr.currentVideoQa.value != null;
        return TvOptionRow(
          focusNode: n,
          label: '解码格式',
          value: loaded
              ? TvPlayerOptions.codecLabel(videoCtr.currentDecodeFormats)
              : '加载中',
          onSelect: _openDecode,
        );
      }),
      // Sits next to 清晰度 because it's the lever for the same problem: a
      // congested CDN mirror starves high resolutions. Switching re-resolves
      // the current stream on the new mirror live (see [_switchCdn]).
      (n) => TvOptionRow(
        focusNode: n,
        label: 'CDN 线路',
        value: VideoUtils.cdnService.name,
        onSelect: () => _setMode(_PanelMode.cdn),
      ),
      // currentAudioQa is a plain field; observing currentVideoQa refreshes
      // this row when the play-url resolves (both are set by the same query).
      (n) => Obx(() {
        final loaded = videoCtr.currentVideoQa.value != null;
        return TvOptionRow(
          focusNode: n,
          label: '音质',
          value: !loaded ? '加载中' : videoCtr.currentAudioQa?.desc ?? '无',
          onSelect: _openAudioQuality,
        );
      }),
      // Subtitles: [subtitles] is a reactive list, [vttSubtitlesIndex] the
      // active track (0 = off, 1..N). The Tizen render pipeline is already
      // wired (TizenSubtitleOverlay); this row just drives setSubtitle.
      (n) => Obx(() {
        final loaded = videoCtr.currentVideoQa.value != null;
        return TvOptionRow(
          focusNode: n,
          label: '字幕',
          value: !loaded ? '加载中' : _subtitleLabel(),
          onSelect: _openSubtitle,
        );
      }),
      // Chapters (view points) — a seekable section list; empty unless the
      // showViewPoints pref is on and the video ships them.
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '章节',
          value: videoCtr.viewPointList.isEmpty
              ? '无'
              : '${videoCtr.viewPointList.length} 段',
          onSelect: _openChapter,
        ),
      ),
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '播放速度',
          value: '${player.playbackSpeed}x',
          onSelect: () => _setMode(_PanelMode.speed),
        ),
      ),
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '画面比例',
          value: player.videoFit.value.desc,
          onSelect: _cycleVideoFit,
        ),
      ),
      // playRepeat is a plain field: no Obx, [_cyclePlayRepeat] setStates.
      (n) => TvOptionRow(
        focusNode: n,
        label: '播放顺序',
        value: player.playRepeat.label,
        onSelect: _cyclePlayRepeat,
      ),
    ];
  }

  /// Current-subtitle summary for the main row: 无 (none available), 关 (off),
  /// else the active track's language.
  String _subtitleLabel() {
    final videoCtr = widget.videoDetailController;
    final subs = videoCtr.subtitles;
    if (subs.isEmpty) return '无';
    final idx = videoCtr.vttSubtitlesIndex.value;
    if (idx <= 0 || idx > subs.length) return '关';
    final sub = subs[idx - 1];
    return sub.lanDoc ?? sub.lan;
  }

  void _openSubtitle() {
    final videoCtr = widget.videoDetailController;
    if (videoCtr.currentVideoQa.value == null) {
      SmartDialog.showToast('视频加载中，请稍后再试');
      return;
    }
    if (videoCtr.subtitles.isEmpty) {
      SmartDialog.showToast('当前视频无字幕');
      return;
    }
    _setMode(_PanelMode.subtitle);
  }

  /// setSubtitle(0) turns off; 1..N selects a track. Applies live (the overlay
  /// updates immediately), so close the panel to reveal the result.
  void _switchSubtitle(int index) {
    widget.videoDetailController.setSubtitle(index);
    widget.onClose();
  }

  /// 关闭 + one row per loaded subtitle track (1-based to match setSubtitle).
  List<Widget> _buildSubtitleRows() {
    final videoCtr = widget.videoDetailController;
    final subs = videoCtr.subtitles;
    return [
      Obx(
        () => TvOptionRow(
          focusNode: _nodes[0],
          dense: true,
          label: '关闭',
          checked: videoCtr.vttSubtitlesIndex.value <= 0,
          onSelect: () => _switchSubtitle(0),
        ),
      ),
      for (var i = 0; i < subs.length; i++)
        Obx(
          () => TvOptionRow(
            focusNode: _nodes[i + 1],
            dense: true,
            label: subs[i].lanDoc ?? subs[i].lan,
            checked: videoCtr.vttSubtitlesIndex.value == i + 1,
            onSelect: () => _switchSubtitle(i + 1),
          ),
        ),
    ];
  }

  // ---------------------------------------------------------- decode format --

  /// Distinct decode formats offered by the current quality's video streams,
  /// excluding Dolby Vision (the Samsung panel can't decode it).
  List<VideoDecodeFormatType> _availableDecodeFormats() {
    final videoCtr = widget.videoDetailController;
    final qa = videoCtr.currentVideoQa.value?.code;
    final videos = videoCtr.data.dash?.video;
    if (qa == null || videos == null) return const [];
    final set = <VideoDecodeFormatType>{};
    for (final v in videos) {
      if (v.id != qa || v.codecs == null) continue;
      try {
        final fmt = VideoDecodeFormatType.fromString(v.codecs!);
        if (fmt != VideoDecodeFormatType.DVH1) set.add(fmt);
      } catch (_) {}
    }
    return set.toList();
  }

  void _openDecode() {
    final videoCtr = widget.videoDetailController;
    if (videoCtr.currentVideoQa.value == null) {
      SmartDialog.showToast('视频加载中，请稍后再试');
      return;
    }
    if (videoCtr.isFileSource || videoCtr.data.dash == null) {
      SmartDialog.showToast('当前视频不支持切换解码格式');
      return;
    }
    if (_availableDecodeFormats().length < 2) {
      SmartDialog.showToast('当前画质仅有一种解码格式');
      return;
    }
    _setMode(_PanelMode.decode);
  }

  /// Set the codec and re-resolve: [VideoDetailController.updatePlayer] →
  /// `findVideoByQa` returns the stream matching `currentDecodeFormats`, so the
  /// new codec takes effect at the current position.
  void _switchDecodeFormat(VideoDecodeFormatType fmt) {
    final videoCtr = widget.videoDetailController;
    if (videoCtr.currentDecodeFormats != fmt) {
      videoCtr
        ..currentDecodeFormats = fmt
        ..updatePlayer();
      SmartDialog.showToast('解码格式已切换：${TvPlayerOptions.codecLabel(fmt)}');
    }
    widget.onClose();
  }

  List<Widget> _buildDecodeRows() {
    final videoCtr = widget.videoDetailController;
    final formats = _availableDecodeFormats();
    return [
      for (var i = 0; i < formats.length; i++)
        Obx(
          () => TvOptionRow(
            focusNode: _nodes[i],
            dense: true,
            label: TvPlayerOptions.codecLabel(formats[i]),
            checked: videoCtr.currentVideoQa.value != null &&
                videoCtr.currentDecodeFormats == formats[i],
            onSelect: () => _switchDecodeFormat(formats[i]),
          ),
        ),
    ];
  }

  // -------------------------------------------------------- chapters (VP) --

  void _openChapter() {
    if (widget.videoDetailController.viewPointList.isEmpty) {
      SmartDialog.showToast('当前视频无章节信息');
      return;
    }
    _setMode(_PanelMode.chapter);
  }

  /// Seek to a chapter's start second ([ViewPointSegment.from]).
  void _seekChapter(ViewPointSegment vp) {
    final from = vp.from;
    if (from != null) {
      widget.plPlayerController.seekTo(Duration(seconds: from));
    }
    widget.onClose();
  }

  List<Widget> _buildChapterRows() {
    final vps = widget.videoDetailController.viewPointList;
    return [
      for (var i = 0; i < vps.length; i++)
        TvOptionRow(
          focusNode: _nodes[i],
          dense: true,
          label: vps[i].title ?? '章节${i + 1}',
          value: _fmtTime(vps[i].from),
          onSelect: () => _seekChapter(vps[i]),
        ),
    ];
  }

  static String _fmtTime(int? sec) {
    if (sec == null) return '';
    final d = Duration(seconds: sec);
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
  }

  // ------------------------------------------------------------- episodes --

  /// The 分P part list when this video has more than one part; empty otherwise
  /// (合集/PGC series are navigated by prev/next, not this jump picker).
  List<BaseEpisodeItem> _episodes() {
    final pages = widget.introController.videoDetail.value.pages;
    return (pages != null && pages.length > 1)
        ? pages
        : const <BaseEpisodeItem>[];
  }

  /// Whether prev/next make sense — multi-part or part of a 合集.
  bool get _isSeries {
    final vd = widget.introController.videoDetail.value;
    return (vd.pages?.length ?? 0) > 1 || vd.ugcSeason != null;
  }

  void _prevEpisode() {
    if (!widget.introController.prevPlay()) {
      SmartDialog.showToast('已经是第一集');
    }
    widget.onClose();
  }

  void _nextEpisode() {
    if (!widget.introController.nextPlay()) {
      SmartDialog.showToast('已经是最后一集');
    }
    widget.onClose();
  }

  void _openEpisode() {
    if (_episodes().length <= 1) {
      SmartDialog.showToast('当前视频无分集');
      return;
    }
    _setMode(_PanelMode.episode);
  }

  /// Jump to a part via the source-specific `onChangeEpisode` (not on the
  /// abstract base, so dispatched by type here).
  void _playEpisode(BaseEpisodeItem ep) {
    if (ep.cid != widget.introController.cid.value) {
      final ic = widget.introController;
      if (ic is UgcIntroController) {
        ic.onChangeEpisode(ep);
      } else if (ic is PgcIntroController) {
        ic.onChangeEpisode(ep);
      }
    }
    widget.onClose();
  }

  List<Widget> _buildEpisodeRows() {
    final eps = _episodes();
    final curCid = widget.introController.cid.value;
    return [
      for (var i = 0; i < eps.length; i++)
        TvOptionRow(
          focusNode: _nodes[i],
          dense: true,
          label: _episodeLabel(eps[i], i),
          checked: eps[i].cid == curCid,
          onSelect: () => _playEpisode(eps[i]),
        ),
    ];
  }

  static String _episodeLabel(BaseEpisodeItem ep, int i) {
    if (ep is Part) return ep.part ?? '第${ep.page ?? i + 1}P';
    return ep.title ?? '第${i + 1}集';
  }

  // ----------------------------------------------------------- engagement --

  /// Quick-favourite toggle to the default folder — no bottom sheet (the mobile
  /// folder picker isn't D-pad navigable). Keeps the panel open to show state.
  void _fav() {
    if (!widget.introController.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    widget.introController.actionFavVideo(isQuick: true);
  }

  /// The CDN-mirror rows: every [CDNService], checked at the active one, with a
  /// live speed-test value ([CdnSpeedTest]) as it streams in. Selecting switches
  /// the mirror and re-resolves the current stream on it.
  List<Widget> _buildCdnRows() {
    final tester = _cdnTest;
    return [
      for (var i = 0; i < CDNService.values.length; i++)
        ValueListenableBuilder<String?>(
          // tester is created in _setMode before this ever builds; guard anyway.
          valueListenable:
              tester?.results[i] ?? const AlwaysStoppedAnimation<String?>(null),
          builder: (context, result, _) => TvOptionRow(
            focusNode: _nodes[i],
            dense: true,
            label: CDNService.values[i].desc,
            value: result,
            checked: VideoUtils.cdnService == CDNService.values[i],
            onSelect: () => _switchCdn(CDNService.values[i]),
          ),
        ),
    ];
  }

  /// Switch the CDN mirror and re-resolve the current stream on it live, then
  /// persist like the 设置 → CDN 线路 picker.
  ///
  /// The re-resolve path depends on the source: [VideoDetailController.updatePlayer]
  /// only handles DASH (it calls `findVideoByQa` / `data.dash!.audio!`), so for a
  /// non-DASH source (durl MP4/FLV, where `data.dash` is null even though
  /// `currentVideoQa` is set) it would crash. Those re-resolve through
  /// `queryVideoUrl`, whose durl branch re-runs [VideoUtils.getCdnUrl]. Both read
  /// [VideoUtils.cdnService], so the new mirror takes effect either way.
  void _switchCdn(CDNService cdn) {
    if (VideoUtils.cdnService != cdn) {
      VideoUtils.cdnService = cdn;
      if (!widget.plPlayerController.tempPlayerConf) {
        GStorage.setting.put(SettingBoxKey.CDNService, cdn.name);
      }
      final videoCtr = widget.videoDetailController;
      // Only re-resolve live once the play-url has loaded: before that
      // `data` is an uninitialized `late` field (LateInitializationError) and
      // `currentVideoQa` is null. `data` is always assigned before
      // `currentVideoQa`, so that null-check gates the `data` access too. During
      // loading we just persist the pref — the in-flight resolve picks it up.
      if (videoCtr.currentVideoQa.value != null) {
        if (videoCtr.data.dash != null) {
          videoCtr.updatePlayer();
        } else {
          videoCtr.queryVideoUrl(fromReset: true);
        }
      }
      SmartDialog.showToast('CDN 线路已切换：${cdn.desc}');
    }
    widget.onClose();
  }

  /// The quality tiers offered for this video, minus the ones the S90F can't
  /// decode (Dolby Vision 126 / 8K 127 / HDR-Vivid 129); HDR10 (125) stays. Used
  /// for BOTH the rendered rows and the focus-node count in build(), so the two
  /// never diverge — a mismatch would strand FocusNodes and break D-pad nav.
  List<FormatItem> _qualityFormats() =>
      widget.videoDetailController.data.supportFormats!
          .where(
            (f) => f.quality == null || VideoQuality.isTizenSupported(f.quality!),
          )
          .toList();

  List<Widget> _buildQualityRows() {
    final videoCtr = widget.videoDetailController;
    final List<FormatItem> formats = _qualityFormats();
    final availableIds = videoCtr.data.dash!.video!.map((e) => e.id).toSet();
    return [
      for (var i = 0; i < formats.length; i++)
        Obx(() {
          final item = formats[i];
          final available = availableIds.contains(item.quality);
          return TvOptionRow(
            focusNode: _nodes[i],
            dense: true,
            label: item.newDesc ?? item.displayDesc ?? '',
            enabled: available,
            checked: videoCtr.currentVideoQa.value?.code == item.quality,
            onSelect: available
                ? () => _switchQuality(item)
                : () => SmartDialog.showToast(
                    '标灰画质需要bilibili会员（已是会员？请关闭无痕模式）',
                  ),
          );
        }),
    ];
  }

  List<Widget> _buildAudioRows() {
    final videoCtr = widget.videoDetailController;
    // Same source as the mobile audio sheet: the play-url dash audio streams
    // (guarded non-empty by [_openAudioQuality]).
    final List<AudioItem> audios = videoCtr.data.dash!.audio!;
    return [
      for (var i = 0; i < audios.length; i++)
        TvOptionRow(
          focusNode: _nodes[i],
          dense: true,
          label: audios[i].quality,
          checked: videoCtr.currentAudioQa?.code == audios[i].id,
          onSelect: () => _switchAudioQuality(audios[i]),
        ),
    ];
  }

  List<Widget> _buildSpeedRows() {
    final player = widget.plPlayerController;
    final speeds = player.speedList;
    return [
      for (var i = 0; i < speeds.length; i++)
        Obx(
          () => TvOptionRow(
            focusNode: _nodes[i],
            dense: true,
            label: '${speeds[i]}x',
            checked: player.playbackSpeed == speeds[i],
            onSelect: () => _switchSpeed(speeds[i]),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Materialize main rows once so its count and widgets stay in lockstep.
    final List<Widget Function(FocusNode)>? mainBuilders =
        _mode == _PanelMode.main ? _mainRowBuilders() : null;
    final int rowCount = switch (_mode) {
      _PanelMode.main => mainBuilders!.length,
      _PanelMode.quality => _qualityFormats().length,
      _PanelMode.decode => _availableDecodeFormats().length,
      _PanelMode.audio => widget.videoDetailController.data.dash!.audio!.length,
      _PanelMode.subtitle => widget.videoDetailController.subtitles.length + 1,
      _PanelMode.chapter => widget.videoDetailController.viewPointList.length,
      _PanelMode.episode => _episodes().length,
      _PanelMode.speed => widget.plPlayerController.speedList.length,
      _PanelMode.cdn => CDNService.values.length,
    };
    _syncNodes(rowCount);
    final rows = switch (_mode) {
      _PanelMode.main => [
        for (var i = 0; i < mainBuilders!.length; i++) mainBuilders[i](_nodes[i]),
      ],
      _PanelMode.quality => _buildQualityRows(),
      _PanelMode.decode => _buildDecodeRows(),
      _PanelMode.audio => _buildAudioRows(),
      _PanelMode.subtitle => _buildSubtitleRows(),
      _PanelMode.chapter => _buildChapterRows(),
      _PanelMode.episode => _buildEpisodeRows(),
      _PanelMode.speed => _buildSpeedRows(),
      _PanelMode.cdn => _buildCdnRows(),
    };

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          width: 470 * TvTheme.designScale,
          decoration: const BoxDecoration(
            color: Color(0xF2161923),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24 * TvTheme.designScale),
              bottomLeft: Radius.circular(24 * TvTheme.designScale),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            28 * TvTheme.designScale,
            32 * TvTheme.designScale,
            28 * TvTheme.designScale,
            24 * TvTheme.designScale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _mode.title,
                style: TvTheme.cardTitle.copyWith(
                  fontSize: 28 * TvTheme.designScale,
                ),
              ),
              const SizedBox(height: 20 * TvTheme.designScale),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: 12 * TvTheme.designScale),
                  itemBuilder: (_, index) => rows[index],
                ),
              ),
              const SizedBox(height: 16 * TvTheme.designScale),
              Text(
                _mode == _PanelMode.main
                    ? 'OK 选择 · 返回 关闭'
                    : 'OK 选择 · 返回 上一级',
                style: TvTheme.cardMeta,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
