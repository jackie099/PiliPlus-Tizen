import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// Large 16:9 video card for the TV grid, driven by the feed-agnostic
/// [TvVideoData] adapter (hot / search / dynamics feeds).
///
/// Visual twin of the recommend feed's TvVideoCard: cover with a bottom
/// gradient scrim and duration badge, then a two-line title and an
/// uploader + view/danmaku meta row.
class TvDataVideoCard extends StatelessWidget {
  const TvDataVideoCard({
    super.key,
    required this.data,
    required this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.onKeyEvent,
  });

  final TvVideoData data;
  final VoidCallback onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      borderRadius: TvTheme.cardRadius,
      child: ClipRRect(
        borderRadius: TvTheme.cardRadius,
        child: ColoredBox(
          color: TvTheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCover(),
              Expanded(child: _buildInfo()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            NetworkImgLayer(
              src: data.cover,
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              borderRadius: BorderRadius.zero,
            ),
            // Bottom scrim keeps the duration badge legible on any cover.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.62, 1],
                  colors: [Colors.transparent, Color(0xB3000000)],
                ),
              ),
            ),
            if (data.durationText case final durationText?)
              Positioned(
                right: TvTheme.badgeInsetRight,
                bottom: TvTheme.badgeInsetBottom,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0x8A000000),
                    borderRadius: TvTheme.badgeRadius,
                  ),
                  child: Padding(
                    padding: TvTheme.badgePadding,
                    child: Text(durationText, style: TvTheme.durationBadge),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo() {
    return Padding(
      padding: TvTheme.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              data.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TvTheme.cardTitle,
            ),
          ),
          const SizedBox(height: TvTheme.cardTitleGap),
          _buildMetaRow(),
        ],
      ),
    );
  }

  /// Uploader + trailing stats, overflow-proof at any card width: the
  /// uploader ellipsizes via [Expanded], while the stats cluster is capped
  /// to a fraction of the row and scales down via [FittedBox] (instead of
  /// pushing the row past its bounds) when the numbers run long.
  Widget _buildMetaRow() {
    final stats = <Widget>[
      if (data.viewText case final viewText?)
        _buildStat(Icons.play_arrow_rounded, viewText),
      if (data.danmuText case final danmuText?)
        _buildStat(Icons.subtitles_outlined, danmuText),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Leave the uploader at least ~1/3 of the row before the stats
        // start shrinking.
        final double statsMaxWidth = constraints.maxWidth > TvTheme.metaGap
            ? (constraints.maxWidth - TvTheme.metaGap) * 0.68
            : 0;
        return Row(
          children: [
            Expanded(
              child: Text(
                data.ownerName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TvTheme.cardMeta,
              ),
            ),
            if (stats.isNotEmpty) ...[
              const SizedBox(width: TvTheme.metaGap),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: statsMaxWidth),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < stats.length; i++) ...[
                        if (i > 0) const SizedBox(width: TvTheme.metaGap),
                        stats[i],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildStat(IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: TvTheme.statIconSize, color: TvTheme.textSecondary),
        const SizedBox(width: TvTheme.statIconGap),
        Text(value, style: TvTheme.cardMeta),
      ],
    );
  }
}
