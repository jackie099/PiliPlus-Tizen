import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_card_cover.dart';
import 'package:flutter/material.dart';

/// Large 16:9 video card for the TV grid, driven by the feed-agnostic
/// [TvVideoData] adapter (hot / search / dynamics / history feeds).
///
/// Cover (with progress / resume treatment) comes from [TvCardCover]; below it
/// a two-line title and an uploader + stats row. History-sourced cards show
/// the last-watched time in place of the (absent) view/danmaku stats.
class TvDataVideoCard extends StatefulWidget {
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
  State<TvDataVideoCard> createState() => _TvDataVideoCardState();
}

class _TvDataVideoCardState extends State<TvDataVideoCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return TvFocusable(
      onSelect: widget.onSelect,
      onFocusChange: (focused) => setState(() => _focused = focused),
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      onKeyEvent: widget.onKeyEvent,
      borderRadius: TvTheme.cardRadius,
      child: ClipRRect(
        borderRadius: TvTheme.cardRadius,
        child: ColoredBox(
          color: TvTheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TvCardCover(data: data, focused: _focused),
              Expanded(child: _buildInfo(data)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo(TvVideoData data) {
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
          _buildMetaRow(data),
        ],
      ),
    );
  }

  /// Uploader + a trailing cluster, overflow-proof at any card width: the
  /// uploader ellipsizes via [Expanded], while the trailing cluster is capped
  /// to a fraction of the row and scales down via [FittedBox] when it runs
  /// long. The trailing cluster is the view/danmaku stats when present, else
  /// the history "last watched" time.
  Widget _buildMetaRow(TvVideoData data) {
    final stats = <Widget>[
      if (data.viewText case final viewText?)
        _buildStat(
          data.isLive
              ? Icons.remove_red_eye_outlined
              : Icons.play_arrow_rounded,
          viewText,
        ),
      if (data.danmuText case final danmuText?)
        _buildStat(Icons.subtitles_outlined, danmuText),
    ];

    Widget? trailing;
    if (stats.isNotEmpty) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0) const SizedBox(width: TvTheme.metaGap),
            stats[i],
          ],
        ],
      );
    } else if (data.viewAtText case final viewAtText?) {
      trailing = Text(viewAtText, maxLines: 1, style: TvTheme.cardMeta);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Leave the uploader at least ~1/3 of the row before the trailing
        // cluster starts shrinking.
        final double trailingMaxWidth = constraints.maxWidth > TvTheme.metaGap
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
            if (trailing != null) ...[
              const SizedBox(width: TvTheme.metaGap),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: trailingMaxWidth),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: trailing,
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
