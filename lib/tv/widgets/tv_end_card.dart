import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_hero_video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// Shown when a video finishes and there is nothing to auto-advance to
/// (播完暂停, or a single video with no next 分P/合集). A 重新播放 action over the
/// dimmed final frame, plus a 相关视频 row to pick the next thing to watch.
class TvEndCard extends StatefulWidget {
  const TvEndCard({
    super.key,
    required this.title,
    required this.related,
    required this.onReplay,
    required this.onOpenRelated,
  });

  final String title;
  final RelatedController related;
  final VoidCallback onReplay;
  final void Function(HotVideoItemModel item) onOpenRelated;

  @override
  State<TvEndCard> createState() => _TvEndCardState();
}

class _TvEndCardState extends State<TvEndCard> {
  final FocusNode _replayNode = FocusNode(debugLabel: 'TvEndReplay');
  final List<FocusNode> _relNodes = [];
  bool _replayFocused = false;

  @override
  void initState() {
    super.initState();
    // The card mounts into an overlay while the page's root Focus already holds
    // focus, so `autofocus` is a no-op — grab focus explicitly once mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _replayNode.requestFocus();
    });
  }

  void _syncRelNodes(int count) {
    while (_relNodes.length < count) {
      _relNodes.add(FocusNode(debugLabel: 'TvEndRel-${_relNodes.length}'));
    }
    while (_relNodes.length > count) {
      _relNodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _replayNode.dispose();
    for (final n in _relNodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status + actions are left-inset; the related row spans full width
          // (with its own horizontal padding) so a focused edge card isn't
          // clipped by the list bounds.
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: TvTheme.screenPadding,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statusLine(),
                const SizedBox(height: TvTheme.endCardStatusBottomGap),
                _actionsRow(),
              ],
            ),
          ),
          const SizedBox(height: TvTheme.endCardActionGap),
          _relatedRow(),
          const SizedBox(height: TvTheme.endCardBottomInset),
        ],
      ),
    );
  }

  Widget _statusLine() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const Text('已播放完毕', style: TvTheme.cardMeta),
        const SizedBox(width: TvTheme.endCardStatusGap),
        Flexible(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TvTheme.playerTitle,
          ),
        ),
      ],
    );
  }

  Widget _actionsRow() {
    return Row(
      children: [
        _replayPill(),
        const SizedBox(width: TvTheme.endCardActionGap),
        const Text('▼ 选择相关视频  ·  返回 退出', style: TvTheme.cardMeta),
      ],
    );
  }

  Widget _replayPill() {
    return TvFocusable(
      focusNode: _replayNode,
      onSelect: widget.onReplay,
      onFocusChange: (f) => setState(() => _replayFocused = f),
      onKeyEvent: (node, event) {
        final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          if (isPress && _relNodes.isNotEmpty) _relNodes.first.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      borderRadius: TvTheme.tabRadius,
      focusScale: TvTheme.focusScaleSmall,
      dimWhenUnfocused: false,
      ensureVisible: false,
      child: AnimatedContainer(
        duration: TvTheme.focusDuration,
        decoration: BoxDecoration(
          color: _replayFocused ? TvTheme.buttonFocusFill : TvTheme.chipSurface,
          borderRadius: TvTheme.tabRadius,
        ),
        child: const Padding(
          padding: TvTheme.buttonPadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.replay_rounded,
                size: TvTheme.buttonIconSize,
                color: TvTheme.textPrimary,
              ),
              SizedBox(width: TvTheme.buttonIconGap),
              Text('重新播放', style: TvTheme.buttonLabel),
            ],
          ),
        ),
      ),
    );
  }

  Widget _relatedRow() {
    return Obx(() {
      final state = widget.related.loadingState.value;
      if (state is! Success<List<HotVideoItemModel>?>) {
        return const SizedBox.shrink();
      }
      final list = state.response ?? const <HotVideoItemModel>[];
      if (list.isEmpty) return const SizedBox.shrink();
      _syncRelNodes(list.length);

      const double coverHeight = TvTheme.heroCardWidth * 9 / 16;
      const double cardHeight = coverHeight + TvTheme.heroCardInfoHeight;
      const double rowHeight = cardHeight + TvTheme.heroRowOverscan * 2;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: TvTheme.screenPadding),
            child: Text('相关视频', style: TvTheme.sectionHeader),
          ),
          const SizedBox(height: TvTheme.rowHeaderBottomGap),
          SizedBox(
            height: rowHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: TvTheme.screenPadding,
                vertical: TvTheme.heroRowOverscan,
              ),
              itemCount: list.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: TvTheme.gridHSpacing),
              itemBuilder: (context, index) {
                final item = list[index];
                return TvHeroVideoCard(
                  data: TvVideoData.fromHorizontal(item),
                  focusNode: _relNodes[index],
                  onSelect: () => widget.onOpenRelated(item),
                  onKeyEvent: (node, event) =>
                      _onRelKey(index, event, list.length),
                );
              },
            ),
          ),
        ],
      );
    });
  }

  KeyEventResult _onRelKey(int index, KeyEvent event, int count) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (isPress) _replayNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) return KeyEventResult.handled;
      if (isPress) _relNodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (index >= count - 1) return KeyEventResult.handled;
      if (isPress) _relNodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
