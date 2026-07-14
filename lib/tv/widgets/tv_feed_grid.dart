import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_data_video_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// Reusable, D-pad-navigable TV feed grid bound to any
/// [CommonListController]-based data source (hot, search, dynamics, ...).
///
/// Follows the recommend feed's behaviour: loading spinner / error state with
/// a focusable retry, the first card autofocuses once content arrives, the
/// focused card is kept visible (handled inside [TvFocusable]), and nearing
/// the end of the list triggers [CommonListController.onLoadMore].
///
/// Feed models are mapped into the [TvVideoData] adapter via [toData];
/// activating a card calls [onOpen] with the original item.
class TvFeedGrid<T> extends StatefulWidget {
  const TvFeedGrid({
    super.key,
    required this.controller,
    required this.toData,
    required this.onOpen,
    this.emptyMessage = '暂无内容',
    this.autofocusFirst = true,
    this.columns = TvTheme.gridColumns,
    this.padding = const EdgeInsets.fromLTRB(
      TvTheme.screenPadding,
      TvTheme.gridTopPadding,
      TvTheme.screenPadding,
      TvTheme.gridBottomPadding,
    ),
  });

  final CommonListController<dynamic, T> controller;
  final TvVideoData Function(T item) toData;
  final void Function(T item) onOpen;
  final String emptyMessage;

  /// Whether the first card requests focus when the grid content appears.
  final bool autofocusFirst;

  final int columns;
  final EdgeInsets padding;

  @override
  State<TvFeedGrid<T>> createState() => _TvFeedGridState<T>();
}

class _TvFeedGridState<T> extends State<TvFeedGrid<T>> {
  final List<FocusNode> _focusNodes = [];

  void _syncFocusNodes(int count) {
    while (_focusNodes.length < count) {
      _focusNodes.add(
        FocusNode(debugLabel: 'TvFeedCard-${_focusNodes.length}'),
      );
    }
    while (_focusNodes.length > count) {
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

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => switch (widget.controller.loadingState.value) {
        Loading() => const TvLoadingView(),
        Success(:final response) =>
          response != null && response.isNotEmpty
              ? _buildGrid(response)
              : TvStatusView(
                  message: widget.emptyMessage,
                  onRetry: widget.controller.onReload,
                ),
        Error(:final errMsg) => TvStatusView(
          message: errMsg ?? '加载失败',
          onRetry: widget.controller.onReload,
        ),
      },
    );
  }

  Widget _buildGrid(List<T> items) {
    _syncFocusNodes(items.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            (constraints.maxWidth -
                widget.padding.horizontal -
                TvTheme.gridHSpacing * (widget.columns - 1)) /
            widget.columns;
        final rowExtent = cardWidth * 9 / 16 + TvTheme.cardInfoHeight;
        return GridView.builder(
          controller: widget.controller.scrollController,
          padding: widget.padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: widget.columns,
            crossAxisSpacing: TvTheme.gridHSpacing,
            mainAxisSpacing: TvTheme.gridVSpacing,
            mainAxisExtent: rowExtent,
          ),
          // Keep the next rows built so directional focus always has a target.
          scrollCacheExtent: ScrollCacheExtent.pixels(rowExtent * 2),
          itemCount: items.length,
          itemBuilder: (context, index) {
            // Fetch the next page when the last rows come into build range
            // (queryData is re-entrancy-guarded by isLoading).
            if (index >= items.length - widget.columns * 2) {
              widget.controller.onLoadMore();
            }
            final item = items[index];
            return TvDataVideoCard(
              data: widget.toData(item),
              autofocus: widget.autofocusFirst && index == 0,
              focusNode: _focusNodes[index],
              onKeyEvent: (node, event) => _onCardKey(index, event),
              onSelect: () => widget.onOpen(item),
            );
          },
        );
      },
    );
  }

  KeyEventResult _onCardKey(int index, KeyEvent event) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    int? target;

    if (key == LogicalKeyboardKey.arrowUp) {
      target = index - widget.columns;
      if (target < 0) return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = index + widget.columns;
      if (target >= _focusNodes.length) return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (index % widget.columns == 0) return KeyEventResult.ignored;
      target = index - 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (index % widget.columns == widget.columns - 1 ||
          index + 1 >= _focusNodes.length) {
        return KeyEventResult.handled;
      }
      target = index + 1;
    } else {
      return KeyEventResult.ignored;
    }

    if (isPress) _focusNodes[target].requestFocus();
    return KeyEventResult.handled;
  }
}

/// Centered loading spinner matching the TV feeds' style.
class TvLoadingView extends StatelessWidget {
  const TvLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: TvTheme.spinnerSize,
        height: TvTheme.spinnerSize,
        child: CircularProgressIndicator(
          strokeWidth: TvTheme.spinnerStroke,
          color: TvTheme.textSecondary,
        ),
      ),
    );
  }
}

/// Centered empty/error/placeholder state with an optional focusable action.
class TvStatusView extends StatelessWidget {
  const TvStatusView({
    super.key,
    required this.message,
    this.onRetry,
    this.actionLabel = '重新加载',
  });

  final String message;
  final VoidCallback? onRetry;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TvTheme.stateMessage,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: TvTheme.stateActionGap),
            TvFocusable(
              autofocus: true,
              onSelect: onRetry,
              borderRadius: TvTheme.tabRadius,
              focusScale: TvTheme.focusScaleSmall,
              dimWhenUnfocused: false,
              ensureVisible: false,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: TvTheme.surface,
                  borderRadius: TvTheme.tabRadius,
                ),
                child: Padding(
                  padding: TvTheme.buttonPadding,
                  child: Text(actionLabel, style: TvTheme.buttonLabel),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
