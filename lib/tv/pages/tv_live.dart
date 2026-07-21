import 'package:PiliPlus/models_new/live/live_feed_index/card_data_list_item.dart';
import 'package:PiliPlus/models_new/live/live_feed_index/card_list.dart';
import 'package:PiliPlus/pages/live/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart';
import 'package:PiliPlus/tv/widgets/tv_hero_video_card.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// TV live discovery (直播): the existing [LiveController] data layer rendered
/// through the shared [TvFeedGrid], with an optional 正在直播的关注 follow rail
/// (from the controller's `topState` follow item) above the recommended-live
/// grid. Cards open the room via [PageUtils.toLiveRoom].
///
/// [LiveController] extends the untyped `CommonListController` (its list is a
/// mix of card types), so the grid is `TvFeedGrid<dynamic>` and each item is
/// cast to [LiveCardList] (the recommended feed only yields `small_card_v1`).
class TvLive extends StatefulWidget {
  const TvLive({super.key});

  @override
  State<TvLive> createState() => _TvLiveState();
}

class _TvLiveState extends State<TvLive> {
  static const _controllerTag = 'tv-live';
  final AccountService _account = Get.find<AccountService>();
  final LiveController _controller = Get.put(
    LiveController(),
    tag: _controllerTag,
  );

  @override
  void dispose() {
    Get.delete<LiveController>(tag: _controllerTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // The follow rail only exists for a logged-in account with live follows.
      final followList = _account.isLogin.value
          ? _controller.topState.value.first?.cardData?.myIdolV1?.list
          : null;
      final showFollow = followList != null && followList.isNotEmpty;
      return Column(
        children: [
          if (showFollow)
            _TvLiveFollowRow(items: followList, autofocusFirst: true),
          Expanded(
            child: TvFeedGrid<dynamic>(
              controller: _controller,
              toData: (item) => TvVideoData.fromLiveCard(
                (item as LiveCardList).cardData!.smallCardV1!,
              ),
              onOpen: (item) => PageUtils.toLiveRoom(
                (item as LiveCardList).cardData?.smallCardV1?.roomid,
              ),
              // When the follow rail is present it owns first focus.
              autofocusFirst: !showFollow,
              emptyMessage: '暂无直播内容',
            ),
          ),
        ],
      );
    });
  }
}

/// 正在直播的关注 follow rail: a section header over a horizontal list of
/// [TvHeroVideoCard]s for the followed anchors that are currently live.
/// Follows the [TvContinueRow] pattern — owns its focus nodes, Left/Right move
/// within the row (clamped at the ends), Up/Down return `ignored` so the page's
/// directional traversal carries focus to the tab bar / grid.
class _TvLiveFollowRow extends StatefulWidget {
  const _TvLiveFollowRow({required this.items, this.autofocusFirst = false});

  final List<CardLiveItem> items;
  final bool autofocusFirst;

  @override
  State<_TvLiveFollowRow> createState() => _TvLiveFollowRowState();
}

class _TvLiveFollowRowState extends State<_TvLiveFollowRow> {
  final List<FocusNode> _focusNodes = [];

  void _syncFocusNodes() {
    while (_focusNodes.length < widget.items.length) {
      _focusNodes.add(
        FocusNode(debugLabel: 'TvLiveFollow-${_focusNodes.length}'),
      );
    }
    while (_focusNodes.length > widget.items.length) {
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
      if (index >= widget.items.length - 1) {
        return KeyEventResult.handled; // clamp at end
      }
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
          child: Text('正在直播的关注', style: TvTheme.sectionHeader),
        ),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: TvTheme.screenPadding,
              vertical: TvTheme.heroRowOverscan,
            ),
            itemCount: widget.items.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: TvTheme.gridHSpacing),
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return TvHeroVideoCard(
                data: TvVideoData.fromLiveCard(item),
                autofocus: widget.autofocusFirst && index == 0,
                focusNode: _focusNodes[index],
                onKeyEvent: (node, event) => _onKey(index, event),
                onSelect: () => PageUtils.toLiveRoom(item.roomid),
              );
            },
          ),
        ),
      ],
    );
  }
}
