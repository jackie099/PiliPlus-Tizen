import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply_reply/controller.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_avatar.dart';
import 'package:PiliPlus/tv/widgets/tv_chip.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart' show TvLoadingView, TvStatusView;
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// Read-only comments (评论) side panel for the TV player. Binds to the shared
/// gRPC-backed [VideoReplyController] (top-level comments) and opens a comment's
/// 楼中楼 (nested replies) in-place via a [VideoReplyReplyController]. The video
/// keeps playing behind the panel.
class TvCommentsPanel extends StatefulWidget {
  const TvCommentsPanel({
    super.key,
    required this.controller,
    required this.oid,
    required this.replyType,
    required this.upMid,
    required this.onClose,
  });

  final VideoReplyController controller;
  final int oid;
  final int replyType;

  /// The video uploader's mid, to badge their comments with `UP`.
  final int upMid;
  final VoidCallback onClose;

  @override
  State<TvCommentsPanel> createState() => _TvCommentsPanelState();
}

class _TvCommentsPanelState extends State<TvCommentsPanel> {
  VideoReplyController get _ctr => widget.controller;

  // 楼中楼 (nested replies); null while showing the top-level list.
  VideoReplyReplyController? _nested;
  ReplyInfo? _nestedParent;

  final List<FocusNode> _nodes = [];
  final FocusNode _sortNode = FocusNode(debugLabel: 'TvCommentSort');

  @override
  void initState() {
    super.initState();
    if (_ctr.loadingState.value is Loading) {
      _ctr.queryData();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    _sortNode.dispose();
    _disposeNested();
    super.dispose();
  }

  void _disposeNested() {
    if (_nested != null) {
      Get.delete<VideoReplyReplyController>(tag: _nested!.hashCode.toString());
      _nested = null;
      _nestedParent = null;
    }
  }

  void _syncNodes(int count) {
    while (_nodes.length < count) {
      _nodes.add(FocusNode(debugLabel: 'TvComment-${_nodes.length}'));
    }
    while (_nodes.length > count) {
      _nodes.removeLast().dispose();
    }
  }

  void _openNested(ReplyInfo reply) {
    if (reply.count.toInt() <= 0) return;
    final tag = reply.hashCode.toString();
    setState(() {
      _nestedParent = reply;
      _nested = Get.put(
        VideoReplyReplyController(
          hasRoot: true,
          id: null,
          oid: widget.oid,
          rpid: reply.id.toInt(),
          dialog: null,
          replyType: widget.replyType,
        ),
        tag: tag,
      );
    });
  }

  void _closeNested() {
    setState(_disposeNested);
  }

  /// Back: pop 楼中楼 to the list, else close the whole panel.
  void _onBack() {
    if (_nested != null) {
      _closeNested();
    } else {
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
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
          child: _nested != null ? _buildNested() : _buildList(),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- list mode

  Widget _buildList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: TvTheme.rowHeaderBottomGap),
        Expanded(
          child: Obx(() {
            switch (_ctr.loadingState.value) {
              case Loading():
                return const TvLoadingView();
              case Success(:final response):
                final list = response ?? const <ReplyInfo>[];
                if (list.isEmpty) {
                  return const TvStatusView(message: '评论区空空如也');
                }
                return _rows(list);
              case Error(:final errMsg):
                return TvStatusView(
                  message: errMsg ?? '加载失败',
                  onRetry: _ctr.onReload,
                );
            }
          }),
        ),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TvTheme.commentsPanelPadding,
      ),
      child: Row(
        children: [
          const Text('评论', style: TvTheme.sectionHeader),
          const SizedBox(width: TvTheme.profileChipGap),
          Obx(() {
            final n = _ctr.count.value;
            return Text(
              n < 0 ? '' : NumUtils.numFormat(n),
              style: TvTheme.commentMeta,
            );
          }),
          const Spacer(),
          _sortToggle(),
        ],
      ),
    );
  }

  Widget _sortToggle() {
    return TvFocusable(
      focusNode: _sortNode,
      onSelect: _ctr.queryBySort,
      borderRadius: TvTheme.tabRadius,
      focusScale: TvTheme.focusScaleSmall,
      dimWhenUnfocused: false,
      ensureVisible: false,
      child: Obx(() {
        final hot = _ctr.sortType.value != ReplySortType.time;
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: TvTheme.chipSurface,
            borderRadius: TvTheme.tabRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20 * TvTheme.designScale,
              vertical: 8 * TvTheme.designScale,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _seg('热门', hot),
                const SizedBox(width: TvTheme.profileChipGap),
                _seg('最新', !hot),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _seg(String label, bool active) {
    return Text(
      label,
      style: TvTheme.sortSegLabel.copyWith(
        color: active ? TvTheme.brandPink : TvTheme.textSecondary,
      ),
    );
  }

  Widget _rows(List<ReplyInfo> list) {
    _syncNodes(list.length);
    return ListView.builder(
      controller: _ctr.scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: TvTheme.commentsPanelPadding,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        if (index >= list.length - 3) {
          _ctr.onLoadMore();
        }
        final reply = list[index];
        return TvCommentRow(
          reply: reply,
          upMid: widget.upMid,
          autofocus: index == 0,
          focusNode: _nodes[index],
          onSelect: () => _openNested(reply),
          onKeyEvent: (node, event) => _onRowKey(index, event, list.length),
        );
      },
    );
  }

  KeyEventResult _onRowKey(int index, KeyEvent event, int count) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (isPress) _onBack();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index == 0) {
        if (isPress) _sortNode.requestFocus(); // reach the sort toggle
        return KeyEventResult.handled;
      }
      if (isPress) _nodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index >= count - 1) return KeyEventResult.handled;
      if (isPress) _nodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    // Left/Right stay within the panel.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------ 楼中楼 mode

  Widget _buildNested() {
    final nested = _nested!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(
            horizontal: TvTheme.commentsPanelPadding,
          ),
          child: Row(
            children: [
              Icon(
                Icons.arrow_back_rounded,
                size: TvTheme.statIconSize,
                color: TvTheme.textSecondary,
              ),
              SizedBox(width: TvTheme.statIconGap),
              Text('回复', style: TvTheme.sectionHeader),
            ],
          ),
        ),
        const SizedBox(height: TvTheme.rowHeaderBottomGap),
        Expanded(
          child: Obx(() {
            switch (nested.loadingState.value) {
              case Loading():
                return const TvLoadingView();
              case Success(:final response):
                final parent = nested.firstFloor.value ?? _nestedParent;
                final replies = response ?? const <ReplyInfo>[];
                return _nestedList(parent, replies);
              case Error(:final errMsg):
                return TvStatusView(
                  message: errMsg ?? '加载失败',
                  onRetry: nested.onReload,
                );
            }
          }),
        ),
      ],
    );
  }

  Widget _nestedList(ReplyInfo? parent, List<ReplyInfo> replies) {
    _syncNodes(replies.length);
    return ListView.builder(
      controller: _nested!.scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: TvTheme.commentsPanelPadding,
      ),
      itemCount: replies.length + (parent != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (parent != null && index == 0) {
          // The pinned parent comment (not focusable, untruncated).
          return TvCommentRow(
            reply: parent,
            upMid: widget.upMid,
            pinnedParent: true,
          );
        }
        final i = parent != null ? index - 1 : index;
        if (i >= replies.length - 3) {
          _nested!.onLoadMore();
        }
        return Padding(
          padding: const EdgeInsets.only(left: TvTheme.commentIndent),
          child: TvCommentRow(
            reply: replies[i],
            upMid: widget.upMid,
            nested: true,
            autofocus: i == 0,
            focusNode: _nodes[i],
            onKeyEvent: (node, event) =>
                _onNestedKey(i, event, replies.length),
          ),
        );
      },
    );
  }

  KeyEventResult _onNestedKey(int index, KeyEvent event, int count) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (isPress) _onBack();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index == 0) return KeyEventResult.handled;
      if (isPress) _nodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index >= count - 1) return KeyEventResult.handled;
      if (isPress) _nodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// A single comment / reply row: avatar · name (+ Lv / 大会员 / UP chips) · body
/// text · meta (like · time · location · N 回复). Read-only.
class TvCommentRow extends StatefulWidget {
  const TvCommentRow({
    super.key,
    required this.reply,
    required this.upMid,
    this.nested = false,
    this.pinnedParent = false,
    this.autofocus = false,
    this.focusNode,
    this.onSelect,
    this.onKeyEvent,
  });

  final ReplyInfo reply;
  final int upMid;
  final bool nested;

  /// The untruncated, non-focusable parent shown atop the 楼中楼 view.
  final bool pinnedParent;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onSelect;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<TvCommentRow> createState() => _TvCommentRowState();
}

class _TvCommentRowState extends State<TvCommentRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final content = _content();
    if (widget.pinnedParent) return content;
    return TvFocusable(
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      onSelect: widget.onSelect,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: widget.onKeyEvent,
      borderRadius: TvTheme.commentRowRadius,
      focusScale: TvTheme.focusScaleRow,
      dimWhenUnfocused: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _focused ? TvTheme.rowFocusFill : Colors.transparent,
          borderRadius: TvTheme.commentRowRadius,
        ),
        child: content,
      ),
    );
  }

  Widget _content() {
    final reply = widget.reply;
    final member = reply.member;
    final isUp = reply.mid.toInt() == widget.upMid && widget.upMid != 0;
    final isVip = member.vipStatus.toInt() > 0;
    final level = member.level.toInt();
    final double avatarSize = widget.nested
        ? TvTheme.commentAvatarSub
        : TvTheme.commentAvatarSize;

    return Padding(
      padding: TvTheme.commentRowPadding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvAvatar(face: member.face, size: avatarSize),
          const SizedBox(width: TvTheme.commentAvatarGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TvTheme.commentName.copyWith(
                          color: isVip ? TvTheme.brandPink : null,
                        ),
                      ),
                    ),
                    if (level > 0) ...[
                      const SizedBox(width: TvTheme.statIconGap),
                      TvChip('Lv$level'),
                    ],
                    if (isUp) ...[
                      const SizedBox(width: TvTheme.statIconGap),
                      const TvChip('UP', vip: true),
                    ],
                  ],
                ),
                const SizedBox(height: TvTheme.cardTitleGap),
                Text.rich(
                  TextSpan(
                    children: [
                      if (reply.replyControl.isUpTop)
                        const WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: EdgeInsets.only(right: 8 * TvTheme.designScale),
                            child: TvChip('置顶', outlined: true),
                          ),
                        ),
                      TextSpan(text: reply.content.message),
                    ],
                  ),
                  maxLines: widget.pinnedParent ? 6 : 4,
                  overflow: TextOverflow.ellipsis,
                  style: widget.nested
                      ? TvTheme.commentBodySub
                      : TvTheme.commentBody,
                ),
                const SizedBox(height: TvTheme.cardTitleGap),
                Text(_meta(reply), style: TvTheme.commentMeta),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _meta(ReplyInfo reply) {
    final parts = <String>[
      '👍 ${NumUtils.numFormat(reply.like.toInt())}',
      _time(reply.ctime.toInt()),
      if (reply.replyControl.hasLocation()) reply.replyControl.location,
      if (!widget.nested && reply.count.toInt() > 0)
        '${NumUtils.numFormat(reply.count.toInt())} 回复',
    ];
    return parts.join('  ·  ');
  }

  String _time(int ctimeSeconds) {
    if (ctimeSeconds <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ctimeSeconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    String two(int n) => n.toString().padLeft(2, '0');
    if (dt.year == now.year) return '${dt.month}月${dt.day}日';
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }
}
