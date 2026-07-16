import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/models/user/stat.dart';
import 'package:PiliPlus/models_new/history/list.dart';
import 'package:PiliPlus/pages/history/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/pages/tv_login.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/utils/tv_open.dart';
import 'package:PiliPlus/tv/widgets/tv_avatar.dart';
import 'package:PiliPlus/tv/widgets/tv_chip.dart';
import 'package:PiliPlus/tv/widgets/tv_continue_row.dart';
import 'package:PiliPlus/tv/widgets/tv_data_video_card.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart' show TvLoadingView, TvStatusView;
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// The 我的 (My) personal hub: a passive profile band, the 继续观看 (continue
/// watching) row, then the full 观看历史 (watch history) grid — one vertical
/// scroll. Watch history lives here rather than on the discovery home page.
/// Logged out, the band becomes a placeholder with a 扫码登录 entry.
class TvMy extends StatefulWidget {
  const TvMy({super.key});

  @override
  State<TvMy> createState() => _TvMyState();
}

class _TvMyState extends State<TvMy> with RouteAware, RouteAwareMixin {
  static const _historyTag = 'tv-my';

  final AccountService _account = Get.find<AccountService>();

  // Slim, TV-local profile fetch (mirrors MineController, without its favourites
  // / menu machinery). Seeded from cache for an instant first paint.
  final Rx<UserInfoData?> _userInfo = Rx<UserInfoData?>(Pref.userInfoCache);
  final Rx<UserStat?> _userStat = Rx<UserStat?>(null);

  HistoryController? _history;
  final List<FocusNode> _gridNodes = [];

  @override
  void initState() {
    super.initState();
    if (_account.isLogin.value) {
      _enterLoggedIn();
    }
    // Handle a login completing while this tab is alive.
    _account.isLogin.listen((login) {
      if (login && _history == null && mounted) {
        setState(_enterLoggedIn);
      }
    });
  }

  void _enterLoggedIn() {
    _history = Get.put(HistoryController('archive'), tag: _historyTag);
    _fetchProfile();
  }

  Future<void> _fetchProfile() async {
    final infoRes = await UserHttp.userInfo();
    if (infoRes case Success(:final response)) {
      _userInfo.value = response;
    }
    final statRes = await UserHttp.userStatOwner();
    if (statRes case Success(:final response)) {
      _userStat.value = response;
    }
  }

  /// Refresh history + profile when returning from a pushed route (e.g. the
  /// video page), so a just-watched item jumps to the front of the row.
  @override
  void didPopNext() {
    _history?.onRefresh();
    if (_account.isLogin.value) _fetchProfile();
  }

  void _syncGridNodes(int count) {
    while (_gridNodes.length < count) {
      _gridNodes.add(FocusNode(debugLabel: 'TvMyHistory-${_gridNodes.length}'));
    }
    while (_gridNodes.length > count) {
      _gridNodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final node in _gridNodes) {
      node.dispose();
    }
    if (_history != null) Get.delete<HistoryController>(tag: _historyTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => _account.isLogin.value ? _buildLoggedIn() : _buildLoggedOut(),
    );
  }

  // ---------------------------------------------------------------- logged in

  Widget _buildLoggedIn() {
    final history = _history;
    if (history == null) return const TvLoadingView();

    return Obx(() {
      final slivers = <Widget>[
        SliverToBoxAdapter(child: _profileBand()),
      ];

      switch (history.loadingState.value) {
        case Loading():
          slivers.add(const SliverFillRemaining(child: TvLoadingView()));
        case Success(:final response):
          final list = response ?? const <HistoryItemModel>[];
          if (list.isEmpty) {
            slivers.add(
              const SliverFillRemaining(
                child: TvStatusView(message: '暂无观看记录'),
              ),
            );
          } else {
            slivers.addAll(_contentSlivers(list));
          }
        case Error(:final errMsg):
          slivers.add(
            SliverFillRemaining(
              child: TvStatusView(
                message: errMsg ?? '加载失败',
                onRetry: history.onReload,
              ),
            ),
          );
      }

      return CustomScrollView(
        controller: history.scrollController,
        scrollCacheExtent: const ScrollCacheExtent.pixels(600),
        slivers: slivers,
      );
    });
  }

  List<Widget> _contentSlivers(List<HistoryItemModel> list) {
    // In-progress items for the hero row. Taking the first N in list order is
    // stable across pagination (later pages only append older items).
    final continueItems = <HistoryItemModel>[];
    for (final item in list) {
      final p = item.progress;
      final d = item.duration;
      if (p != null && p > 0 && (d == null || p < d)) {
        continueItems.add(item);
        if (continueItems.length >= TvTheme.continueRowMaxItems) break;
      }
    }
    final hasContinue = continueItems.isNotEmpty;
    _syncGridNodes(list.length);

    return [
      if (hasContinue)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: TvTheme.rowHeaderTopGap),
            child: TvContinueRow(
              items: continueItems,
              onOpen: TvOpen.openHistory,
              autofocusFirst: true,
            ),
          ),
        ),
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(
            left: TvTheme.screenPadding,
            top: TvTheme.sectionGap,
            bottom: TvTheme.rowHeaderBottomGap,
          ),
          child: Text('观看历史', style: TvTheme.sectionHeader),
        ),
      ),
      _historyGrid(list, hasContinue),
    ];
  }

  Widget _historyGrid(List<HistoryItemModel> list, bool hasContinue) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        TvTheme.screenPadding,
        0,
        TvTheme.screenPadding,
        TvTheme.gridBottomPadding,
      ),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          const columns = TvTheme.gridColumns;
          final cardWidth =
              (constraints.crossAxisExtent -
                  TvTheme.gridHSpacing * (columns - 1)) /
              columns;
          final rowExtent = cardWidth * 9 / 16 + TvTheme.cardInfoHeight;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: TvTheme.gridHSpacing,
              mainAxisSpacing: TvTheme.gridVSpacing,
              mainAxisExtent: rowExtent,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index >= list.length - columns * 2) {
                _history?.onLoadMore();
              }
              final item = list[index];
              return TvDataVideoCard(
                data: TvVideoData.fromHistory(item),
                autofocus: index == 0 && !hasContinue,
                focusNode: _gridNodes[index],
                onKeyEvent: (node, event) => _onGridKey(index, event),
                onSelect: () => TvOpen.openHistory(item),
              );
            }, childCount: list.length),
          );
        },
      ),
    );
  }

  KeyEventResult _onGridKey(int index, KeyEvent event) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    int? target;

    if (key == LogicalKeyboardKey.arrowUp) {
      target = index - TvTheme.gridColumns;
      // Row 0 Up: let directional traversal reach the continue row / tabs.
      if (target < 0) return KeyEventResult.ignored;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = index + TvTheme.gridColumns;
      if (target >= _gridNodes.length) return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (index % TvTheme.gridColumns == 0) return KeyEventResult.handled;
      target = index - 1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (index % TvTheme.gridColumns == TvTheme.gridColumns - 1 ||
          index + 1 >= _gridNodes.length) {
        return KeyEventResult.handled;
      }
      target = index + 1;
    } else {
      return KeyEventResult.ignored;
    }

    if (isPress) _gridNodes[target].requestFocus();
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------- profile band

  Widget _profileBand() {
    return Obx(() {
      final info = _userInfo.value;
      final stat = _userStat.value;
      final face = _account.face.value;
      final level = info?.levelInfo?.currentLevel;
      final isVip = info?.vipStatus == 1;

      final stats = <String>[
        if (stat?.following case final n?) '关注 ${NumUtils.numFormat(n)}',
        if (stat?.follower case final n?) '粉丝 ${NumUtils.numFormat(n)}',
        if (stat?.dynamicCount case final n?) '动态 ${NumUtils.numFormat(n)}',
      ];

      return Padding(
        padding: const EdgeInsets.only(
          left: TvTheme.screenPadding,
          right: TvTheme.screenPadding,
          top: TvTheme.profileHeaderTopGap,
          bottom: TvTheme.profileHeaderBottomGap,
        ),
        child: Row(
          children: [
            TvAvatar(
              face: face,
              size: TvTheme.profileAvatarSize,
              iconSize: TvTheme.profileAvatarIconSize,
            ),
            const SizedBox(width: TvTheme.profileAvatarGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          info?.uname ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TvTheme.profileName,
                        ),
                      ),
                      if (level != null) ...[
                        const SizedBox(width: TvTheme.profileChipGap),
                        TvChip('Lv$level'),
                      ],
                      if (isVip) ...[
                        const SizedBox(width: TvTheme.profileChipGap),
                        const TvChip('大会员', vip: true),
                      ],
                    ],
                  ),
                  if (stats.isNotEmpty) ...[
                    const SizedBox(height: TvTheme.profileMetaGap),
                    Text(stats.join('  ·  '), style: TvTheme.profileMeta),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  // --------------------------------------------------------------- logged out

  Widget _buildLoggedOut() {
    return Column(
      children: [
        _profileBand(),
        Expanded(
          child: TvStatusView(
            message: '登录后即可同步你的观看记录',
            actionLabel: '扫码登录',
            onRetry: () => Get.to(() => const TvLoginPage()),
          ),
        ),
      ],
    );
  }
}
