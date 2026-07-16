import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_hero_video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

/// Home-page "继续观看" (continue watching) row: a section header over a
/// horizontal list of [TvHeroVideoCard]s, ending in a focusable "查看全部" card
/// that jumps to the full 历史 tab.
///
/// Owns its own focus nodes. Left/Right move within the row (clamped at the
/// ends); Up/Down return `ignored` so the enclosing page's directional
/// traversal carries focus to the tab bar / recommend grid. The focused card is
/// kept centered via [TvFocusable]'s built-in `ensureVisible`.
class TvContinueRow extends StatefulWidget {
  const TvContinueRow({
    super.key,
    required this.items,
    required this.onOpen,
    this.onViewAll,
    this.autofocusFirst = false,
  });

  final List<HistoryItemModel> items;
  final void Function(HistoryItemModel item) onOpen;

  /// Optional trailing "查看全部" card. Omit it when the full history grid is
  /// already on the same page (e.g. the 我的 tab).
  final VoidCallback? onViewAll;

  /// Whether the first hero card requests focus when the row appears (used when
  /// the row, not the recommend grid, owns first focus at cold start).
  final bool autofocusFirst;

  @override
  State<TvContinueRow> createState() => _TvContinueRowState();
}

class _TvContinueRowState extends State<TvContinueRow> {
  final List<FocusNode> _focusNodes = [];

  // items (+ 1 trailing "查看全部" card when onViewAll is provided).
  int get _count => widget.items.length + (widget.onViewAll != null ? 1 : 0);

  void _syncFocusNodes() {
    while (_focusNodes.length < _count) {
      _focusNodes.add(FocusNode(debugLabel: 'TvContinue-${_focusNodes.length}'));
    }
    while (_focusNodes.length > _count) {
      _focusNodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(int index, KeyEvent event) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) return KeyEventResult.handled; // clamp at start
      if (isPress) _focusNodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (index >= _count - 1) return KeyEventResult.handled; // clamp at end
      if (isPress) _focusNodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    // Up / Down: let the page's directional traversal reach tabs / grid.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    _syncFocusNodes();
    const double coverHeight = TvTheme.heroCardWidth * 9 / 16;
    const double cardHeight = coverHeight + TvTheme.heroCardInfoHeight;
    const double rowHeight = cardHeight + TvTheme.heroRowOverscan * 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(
            left: TvTheme.screenPadding,
            top: TvTheme.rowHeaderTopGap,
            bottom: TvTheme.rowHeaderBottomGap,
          ),
          child: Text('继续观看', style: TvTheme.sectionHeader),
        ),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: TvTheme.screenPadding,
              vertical: TvTheme.heroRowOverscan,
            ),
            itemCount: _count,
            separatorBuilder: (_, _) =>
                const SizedBox(width: TvTheme.gridHSpacing),
            itemBuilder: (context, index) {
              if (index < widget.items.length) {
                final item = widget.items[index];
                return TvHeroVideoCard(
                  data: TvVideoData.fromHistory(item),
                  autofocus: widget.autofocusFirst && index == 0,
                  focusNode: _focusNodes[index],
                  onKeyEvent: (node, event) => _onKey(index, event),
                  onSelect: () => widget.onOpen(item),
                );
              }
              return _ViewAllCard(
                coverHeight: coverHeight,
                focusNode: _focusNodes[index],
                onKeyEvent: (node, event) => _onKey(index, event),
                onSelect: widget.onViewAll!,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Trailing "查看全部" card that ends the continue-watching row, sized and
/// top-aligned to the hero covers (not the full card height).
class _ViewAllCard extends StatelessWidget {
  const _ViewAllCard({
    required this.coverHeight,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onSelect,
  });

  final double coverHeight;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: TvTheme.viewAllCardWidth,
        height: coverHeight,
        child: TvFocusable(
          onSelect: onSelect,
          focusNode: focusNode,
          onKeyEvent: onKeyEvent,
          borderRadius: TvTheme.cardRadius,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: TvTheme.surface,
              borderRadius: TvTheme.cardRadius,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.history_rounded,
                  size: TvTheme.resumeGlyphIconSize,
                  color: TvTheme.textSecondary,
                ),
                SizedBox(height: 10 * TvTheme.designScale),
                Text('查看全部', style: TvTheme.viewAllLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
