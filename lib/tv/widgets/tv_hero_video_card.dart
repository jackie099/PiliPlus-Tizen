import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_card_cover.dart';
import 'package:flutter/material.dart';

/// Larger, fixed-width 16:9 card for the home "继续观看" (continue watching) row.
///
/// Differs from the grid [TvDataVideoCard] by a fixed [TvTheme.heroCardWidth],
/// a single-line title, and a resume line (`还剩 8 分钟 · 老番茄`) instead of the
/// two-line title + stats. Cover/progress/resume-glyph come from [TvCardCover].
class TvHeroVideoCard extends StatefulWidget {
  const TvHeroVideoCard({
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
  State<TvHeroVideoCard> createState() => _TvHeroVideoCardState();
}

class _TvHeroVideoCardState extends State<TvHeroVideoCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return SizedBox(
      width: TvTheme.heroCardWidth,
      child: TvFocusable(
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvCardCover(data: data, focused: _focused),
                SizedBox(
                  height: TvTheme.heroCardInfoHeight,
                  child: Padding(
                    padding: TvTheme.cardPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          data.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TvTheme.heroTitle,
                        ),
                        const SizedBox(height: TvTheme.cardTitleGap),
                        Text(
                          _secondLine(data),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TvTheme.cardMeta,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `还剩 8 分钟 · 老番茄` — remaining time (decision-relevant) then uploader.
  String _secondLine(TvVideoData data) {
    final parts = <String>[];
    if (data.remainingText case final r?) parts.add(r);
    final owner = data.ownerName;
    if (owner != null && owner.isNotEmpty) parts.add(owner);
    return parts.join(' · ');
  }
}
