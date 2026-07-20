import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/models_new/live/live_medal_wall/uinfo_medal.dart';
import 'package:PiliPlus/models_new/live/live_superchat/item.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_chip.dart';
import 'package:PiliPlus/utils/color_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Read-only live-chat rail for the TV live room. Slides in from the right as
/// an OVERLAY over the video (the player is never resized) and auto-scrolls to
/// the tail as new messages arrive. Bound to [LiveRoomController.messages] — the
/// same mixed danmaku (`DanmakuMsg`) + SuperChat (`SuperChatItem`) stream the
/// mobile chat panel renders.
///
/// Deliberately passive: no input field, no [FocusNode], no focusable rows. The
/// root [Focus] of the page keeps the D-pad, and the danmaku bullets keep
/// drawing on the canvas beneath this panel. Modelled on [TvCommentsPanel]
/// (its slide/width/surface language), minus every interactive affordance.
class TvLiveChatPanel extends StatefulWidget {
  const TvLiveChatPanel({super.key, required this.liveController});

  final LiveRoomController liveController;

  @override
  State<TvLiveChatPanel> createState() => _TvLiveChatPanelState();
}

class _TvLiveChatPanelState extends State<TvLiveChatPanel> {
  LiveRoomController get _ctr => widget.liveController;

  /// The rail's own scroll controller — intentionally NOT the controller's
  /// `scrollController` (which drives the mobile panel's user-scroll / jump-to-
  /// bottom state). This rail only ever pins itself to the tail.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToTail() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    // A visual-only overlay: absorb no pointer, request no focus, so the D-pad
    // stays with the page's root Focus and the bullets keep drawing beneath.
    return IgnorePointer(
      child: Align(
        alignment: Alignment.centerRight,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 1, end: 0),
          duration: TvTheme.overlayEnterDuration,
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Transform.translate(
            offset: Offset(TvTheme.commentsPanelWidth * t, 0),
            child: child,
          ),
          child: Container(
            width: TvTheme.commentsPanelWidth,
            decoration: const BoxDecoration(
              color: TvTheme.commentsPanelSurface,
              borderRadius: TvTheme.commentsPanelRadius,
            ),
            padding: const EdgeInsets.symmetric(
              vertical: TvTheme.commentsPanelPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: TvTheme.rowHeaderBottomGap),
                Expanded(child: _list()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TvTheme.commentsPanelPadding,
      ),
      child: Row(
        children: [
          const Text('聊天', style: TvTheme.sectionHeader),
          const Spacer(),
          Obx(() {
            final watched = _ctr.watchedShow.value;
            if (watched == null || watched.isEmpty) {
              return const SizedBox.shrink();
            }
            return Text(watched, style: TvTheme.commentMeta);
          }),
        ],
      ),
    );
  }

  Widget _list() {
    return Obx(() {
      final messages = _ctr.messages;
      final count = messages.length; // reactive read -> tracks new messages
      // Keep the rail pinned to the tail whenever the list grows.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTail());
      if (count == 0) {
        return const Center(
          child: Text('等待弹幕…', style: TvTheme.stateMessage),
        );
      }
      return ListView.builder(
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(
          horizontal: TvTheme.commentsPanelPadding,
        ),
        itemCount: count,
        itemBuilder: (context, index) {
          final item = messages[index];
          if (item is SuperChatItem) return _scRow(item);
          if (item is DanmakuMsg) return _dmRow(item);
          return const SizedBox.shrink();
        },
      );
    });
  }

  // ------------------------------------------------------------ danmaku row

  /// A danmaku line: optional medal chip · uname · (optional @reply) · text.
  Widget _dmRow(DanmakuMsg item) {
    final medalLabel = _medalLabel(item.medalInfo);
    return Padding(
      padding: const EdgeInsets.only(bottom: _rowGap),
      child: Text.rich(
        TextSpan(
          children: [
            if (medalLabel != null)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: _medalGap),
                  child: TvChip(medalLabel),
                ),
              ),
            TextSpan(text: '${item.name}：', style: _nameStyle),
            if (item.reply case final reply?)
              TextSpan(text: '@${reply.name} ', style: _mentionStyle),
            TextSpan(text: item.text, style: _textStyle),
          ],
        ),
      ),
    );
  }

  static String? _medalLabel(UinfoMedal? medal) {
    if (medal == null) return null;
    final name = medal.name;
    if (name == null || name.isEmpty) return null;
    final level = medal.level;
    return level == null ? name : '$name $level';
  }

  // ----------------------------------------------------------- SuperChat row

  /// A SuperChat line, tinted with the item's own price-tier palette so higher
  /// tiers read as brighter / warmer highlights (the mobile [SuperChatCard]
  /// colours, flattened into a compact rail row).
  Widget _scRow(SuperChatItem item) {
    final topColor = ColourUtils.parseColor(item.backgroundColor);
    final bottomColor = ColourUtils.parseColor(item.backgroundBottomColor);
    final priceColor = ColourUtils.parseColor(item.backgroundPriceColor);
    final msgColor = ColourUtils.parseColor(item.messageFontColor);
    final nameColor = ColourUtils.parseColor(item.userInfo.nameColor);
    return Padding(
      padding: const EdgeInsets.only(bottom: _rowGap),
      child: Container(
        decoration: BoxDecoration(
          color: bottomColor,
          borderRadius: TvTheme.commentRowRadius,
          border: Border.all(color: topColor),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: 16 * TvTheme.designScale,
          vertical: 12 * TvTheme.designScale,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.userInfo.uname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _nameStyle.copyWith(color: nameColor),
                  ),
                ),
                const SizedBox(width: TvTheme.statIconGap),
                Text(
                  '￥${item.price}',
                  style: _nameStyle.copyWith(
                    color: priceColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: TvTheme.cardTitleGap),
            Text(
              item.message,
              style: _textStyle.copyWith(color: msgColor),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- tokens

  static const double _rowGap = 12 * TvTheme.designScale;
  static const double _medalGap = 8 * TvTheme.designScale;

  static const TextStyle _nameStyle = TextStyle(
    fontSize: 22 * TvTheme.designScale,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: TvTheme.textSecondary,
  );

  static const TextStyle _textStyle = TextStyle(
    fontSize: 22 * TvTheme.designScale,
    height: 1.3,
    color: TvTheme.textPrimary,
  );

  static const TextStyle _mentionStyle = TextStyle(
    fontSize: 22 * TvTheme.designScale,
    height: 1.3,
    color: TvTheme.mentionColor,
  );
}
