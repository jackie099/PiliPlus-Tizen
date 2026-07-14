import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/home/rcmd/result.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_video_card.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/dimension_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// TV home feed: a spacious, D-pad-navigable grid of [TvVideoCard]s bound to
/// the existing [RcmdController] (recommend feed data layer is reused as-is).
///
/// The first card autofocuses once content arrives; moving focus keeps the
/// focused card visible (handled inside [TvFocusable]); approaching the end
/// of the list triggers [RcmdController.onLoadMore].
class TvHome extends StatefulWidget {
  const TvHome({super.key});

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  static const _controllerTag = 'tv-home';
  final RcmdController _controller = Get.put(
    RcmdController(),
    tag: _controllerTag,
  );
  final List<FocusNode> _focusNodes = [];

  void _syncFocusNodes(int count) {
    while (_focusNodes.length < count) {
      _focusNodes.add(
        FocusNode(debugLabel: 'TvHomeCard-${_focusNodes.length}'),
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
    Get.delete<RcmdController>(tag: _controllerTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => switch (_controller.loadingState.value) {
        Loading() => const Center(
          child: SizedBox(
            width: TvTheme.spinnerSize,
            height: TvTheme.spinnerSize,
            child: CircularProgressIndicator(
              strokeWidth: TvTheme.spinnerStroke,
              color: TvTheme.textSecondary,
            ),
          ),
        ),
        Success(:final response) =>
          response != null &&
                  response.whereType<BaseRcmdVideoItemModel>().isNotEmpty
              ? _buildGrid(
                  response.whereType<BaseRcmdVideoItemModel>().toList(),
                )
              : _TvStatusView(
                  message: '暂无推荐内容',
                  onRetry: _controller.onReload,
                ),
        Error(:final errMsg) => _TvStatusView(
          message: errMsg ?? '加载失败',
          onRetry: _controller.onReload,
        ),
      },
    );
  }

  Widget _buildGrid(List<BaseRcmdVideoItemModel> items) {
    _syncFocusNodes(items.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = TvTheme.gridColumns;
        final cardWidth =
            (constraints.maxWidth -
                TvTheme.screenPadding * 2 -
                TvTheme.gridHSpacing * (columns - 1)) /
            columns;
        final rowExtent = cardWidth * 9 / 16 + TvTheme.cardInfoHeight;
        return GridView.builder(
          controller: _controller.scrollController,
          padding: const EdgeInsets.fromLTRB(
            TvTheme.screenPadding,
            TvTheme.gridTopPadding,
            TvTheme.screenPadding,
            TvTheme.gridBottomPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
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
            if (index >= items.length - columns * 2) {
              _controller.onLoadMore();
            }
            final item = items[index];
            return TvVideoCard(
              item: item,
              autofocus: index == 0,
              focusNode: _focusNodes[index],
              onKeyEvent: (node, event) => _onCardKey(index, event),
              onSelect: () => _openItem(item),
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
      target = index - TvTheme.gridColumns;
      if (target < 0) return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = index + TvTheme.gridColumns;
      if (target >= _focusNodes.length) return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (index % TvTheme.gridColumns == 0) return KeyEventResult.handled;
      target = index - 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (index % TvTheme.gridColumns == TvTheme.gridColumns - 1 ||
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

  /// Opens an item through the existing routes (the player already works on
  /// TV). Mirrors the mobile `VideoCardV.onPushDetail` goto switch, falling
  /// back to [PiliScheme.routePushFromUrl] for anything with a uri.
  Future<void> _openItem(BaseRcmdVideoItemModel item) async {
    switch (item.goto) {
      case 'av':
        final aid = item.aid;
        final rawBvid = item.bvid;
        final bvid = rawBvid?.isNotEmpty == true
            ? rawBvid
            : (aid != null ? IdUtils.av2bv(aid) : null);
        if (bvid == null) return;
        bool isVertical = false;
        if (item is RcmdVideoItemAppModel) {
          if (item.uri case final uri?) {
            isVertical = uri.isVerticalFromUri;
          }
        }
        var cid = item.cid;
        Dimension? dimension;
        if (cid == null) {
          final res = await SearchHttp.ab2cWithDimension(aid: aid, bvid: bvid);
          cid = res?.cid;
          dimension = res?.dimension;
        }
        if (cid != null) {
          PageUtils.toVideoPage(
            aid: aid,
            bvid: bvid,
            cid: cid,
            cover: item.cover,
            title: item.title,
            isVertical: isVertical,
            dimension: dimension,
          );
        }
      case 'bangumi':
        if (item.param != null) {
          PageUtils.viewPgc(epId: item.param);
        } else if (item.uri?.isNotEmpty == true) {
          PiliScheme.routePushFromUrl(item.uri!);
        }
      default:
        if (item.uri?.isNotEmpty == true) {
          PiliScheme.routePushFromUrl(item.uri!);
        }
    }
  }
}

/// Centered empty/error state with a focusable retry button.
class _TvStatusView extends StatelessWidget {
  const _TvStatusView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
          const SizedBox(height: TvTheme.stateActionGap),
          TvFocusable(
            autofocus: true,
            onSelect: onRetry,
            borderRadius: TvTheme.tabRadius,
            focusScale: TvTheme.focusScaleSmall,
            dimWhenUnfocused: false,
            ensureVisible: false,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: TvTheme.surface,
                borderRadius: TvTheme.tabRadius,
              ),
              child: Padding(
                padding: TvTheme.buttonPadding,
                child: Text('重新加载', style: TvTheme.buttonLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
