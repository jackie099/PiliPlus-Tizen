import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/pages/tv_dynamics.dart';
import 'package:PiliPlus/tv/pages/tv_home.dart';
import 'package:PiliPlus/tv/pages/tv_hot.dart';
import 'package:PiliPlus/tv/pages/tv_live.dart';
import 'package:PiliPlus/tv/pages/tv_my.dart';
import 'package:PiliPlus/tv/pages/tv_search.dart';
import 'package:PiliPlus/tv/pages/tv_settings.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

/// A tab in the TV top navigation bar.
class _TvTab {
  const _TvTab({required this.label, required this.builder});

  final String label;
  final WidgetBuilder builder;
}

/// Root of the TV experience: a focusable top tab bar over the content area.
///
/// D-pad: arrows move focus (pressing Up from the top row of content reaches
/// the tabs), OK activates. Back first returns focus to the nav bar; a second
/// Back from the nav bar exits the app. Deeper routes (video page, etc.) pop
/// normally before this handler is reached.
class TvMain extends StatefulWidget {
  const TvMain({super.key});

  @override
  State<TvMain> createState() => _TvMainState();
}

class _TvMainState extends State<TvMain> {
  // To add more sections, append here; the bar, focus handling and Back
  // behaviour support any number of tabs.
  static final List<_TvTab> _tabs = [
    _TvTab(label: '推荐', builder: (_) => const TvHome()),
    _TvTab(label: '热门', builder: (_) => const TvHot()),
    _TvTab(label: '直播', builder: (_) => const TvLive()),
    _TvTab(label: '动态', builder: (_) => const TvDynamics()),
    _TvTab(label: '我的', builder: (_) => const TvMy()),
    _TvTab(label: '搜索', builder: (_) => const TvSearch()),
    _TvTab(label: '设置', builder: (_) => const TvSettings()),
  ];

  void _selectTab(int index) {
    setState(() {
      _index = index;
      _builtTabs.add(index);
    });
  }

  int _index = 0;

  // Tabs are built (and their controllers created) on first visit only, then
  // kept alive by the IndexedStack, so feeds don't all load at startup.
  final Set<int> _builtTabs = {0};

  bool _navHasFocus = false;
  late final List<FocusNode> _tabNodes = List.generate(
    _tabs.length,
    (i) => FocusNode(debugLabel: 'TvTab-${_tabs[i].label}'),
  );

  @override
  void dispose() {
    for (final node in _tabNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    if (!_navHasFocus) {
      // First Back from the content: return focus to the nav bar.
      _tabNodes[_index].requestFocus();
    } else {
      // Back on the nav bar: leave the app.
      SystemNavigator.pop();
    }
  }

  void _onTabFocusChange(int index, bool focused) {
    _navHasFocus = _tabNodes.any((node) => node.hasFocus);
    // Left/Right changes the active section as focus moves. Otherwise Down from
    // a newly focused tab would enter the previously selected tab's content.
    if (focused && index != _index) {
      setState(() {
        _index = index;
        _builtTabs.add(index);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The TV UI is always dark/cinematic regardless of the app theme mode.
    return Theme(
      data: ThemeUtils.darkTheme,
      child: Scaffold(
        backgroundColor: TvTheme.background,
        body: PopScope(
          canPop: false,
          onPopInvokedWithResult: _onPopInvoked,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: TvTheme.backgroundGradient,
            ),
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      // This SDK's IndexedStack keeps hidden children
                      // interactive, so exclude them from D-pad focus
                      // explicitly.
                      for (var i = 0; i < _tabs.length; i++)
                        ExcludeFocus(
                          excluding: i != _index,
                          child: _builtTabs.contains(i)
                              ? _tabs[i].builder(context)
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: TvTheme.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: TvTheme.screenPadding,
        ),
        child: Row(
          children: [
            const Text('PiliPlus', style: TvTheme.brand),
            const SizedBox(width: 56 * TvTheme.designScale),
            for (var i = 0; i < _tabs.length; i++) _buildTab(i),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(int index) {
    final selected = index == _index;
    return Padding(
      padding: const EdgeInsets.only(right: 20 * TvTheme.designScale),
      child: TvFocusable(
        focusNode: _tabNodes[index],
        onSelect: () => _selectTab(index),
        onFocusChange: (focused) => _onTabFocusChange(index, focused),
        borderRadius: TvTheme.tabRadius,
        focusScale: TvTheme.focusScaleSmall,
        dimWhenUnfocused: false,
        ensureVisible: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? const Color(0x24FFFFFF) : Colors.transparent,
            borderRadius: TvTheme.tabRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 28 * TvTheme.designScale,
              vertical: 12 * TvTheme.designScale,
            ),
            child: Text(
              _tabs[index].label,
              style: selected
                  ? TvTheme.tabLabel.copyWith(color: TvTheme.brandPink)
                  : TvTheme.tabLabel.copyWith(color: TvTheme.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
