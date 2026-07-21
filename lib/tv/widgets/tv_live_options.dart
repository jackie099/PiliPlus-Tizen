import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_option_row.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

enum _PanelMode {
  main('直播选项'),
  quality('清晰度');

  final String title;
  const _PanelMode(this.title);
}

/// Right-side options panel of the TV live-room page: 弹幕开关 / 弹幕不透明度 /
/// 清晰度 (a submenu of [LiveRoomController.acceptQnList]) / 刷新直播 / 点赞, all
/// driven by the existing [LiveRoomController] + [PlPlayerController] (the same
/// paths the mobile live chrome uses — no controller changes).
///
/// D-pad: Up/Down move between rows (explicit focus nodes so focus can never
/// wander into the dormant mobile player chrome), OK activates, Back returns
/// from the 清晰度 submenu or calls [onClose]. Mirrors `TvPlayerOptions`.
class TvLiveOptions extends StatefulWidget {
  const TvLiveOptions({
    super.key,
    required this.liveController,
    required this.onClose,
  });

  final LiveRoomController liveController;
  final VoidCallback onClose;

  @override
  State<TvLiveOptions> createState() => _TvLiveOptionsState();
}

class _TvLiveOptionsState extends State<TvLiveOptions> {
  _PanelMode _mode = _PanelMode.main;

  /// Node pool: grows to the largest list shown and is disposed with the
  /// panel (never shrunk mid-build while old rows may still be attached).
  final List<FocusNode> _nodes = [];
  int _rowCount = 0;

  PlPlayerController get _player => widget.liveController.plPlayerController;

  @override
  void initState() {
    super.initState();
    // The page's root focus node holds focus when the panel opens; move it to
    // the first row once the rows exist.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstRow());
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncNodes(int count) {
    _rowCount = count;
    while (_nodes.length < count) {
      _nodes.add(FocusNode(debugLabel: 'TvLiveOption-${_nodes.length}'));
    }
  }

  void _focusFirstRow() {
    if (mounted && _rowCount > 0) {
      _nodes.first.requestFocus();
    }
  }

  void _setMode(_PanelMode mode) {
    setState(() => _mode = mode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstRow());
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;

    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        if (_mode != _PanelMode.main) {
          _setMode(_PanelMode.main);
        } else {
          widget.onClose();
        }
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (isPress && _rowCount > 0) {
        final current = _nodes.indexWhere((n) => n.hasFocus);
        final target = key == LogicalKeyboardKey.arrowUp
            ? current - 1
            : current + 1;
        if (current != -1 && target >= 0 && target < _rowCount) {
          _nodes[target].requestFocus();
        }
      }
      return KeyEventResult.handled;
    }

    // Keep focus and playback state stable while the panel is up: swallow
    // horizontal/seek/menu keys instead of letting the page act on them.
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.contextMenu) {
      return KeyEventResult.handled;
    }

    // Select/Enter falls through to the app-level Shortcuts -> ActivateIntent
    // on the focused row.
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------- actions --

  /// Live danmaku on/off — the same reactive flag + persistence the mobile
  /// live chrome flips (`enableShowLiveDanmaku`), so bullets show/hide live.
  void _toggleDanmaku() {
    final player = _player;
    final newVal = !player.enableShowLiveDanmaku.value;
    player.enableShowLiveDanmaku.value = newVal;
    if (!player.tempPlayerConf) {
      GStorage.setting.put(SettingBoxKey.enableShowLiveDanmaku, newVal);
    }
  }

  /// Step the shared danmaku opacity in 10% notches (wrapping 100% → 10%), the
  /// same reactive value the mobile 弹幕设置 slider drives.
  void _stepOpacity() {
    final player = _player;
    double next = double.parse(
      (player.danmakuOpacity.value + 0.1).toStringAsFixed(1),
    );
    if (next > 1.0) next = 0.1;
    player.danmakuOpacity.value = next;
    if (!player.tempPlayerConf) {
      DanmakuOptions.save(next);
    }
  }

  void _openQuality() {
    if (widget.liveController.acceptQnList.isEmpty) {
      SmartDialog.showToast('直播加载中，请稍后再试');
      return;
    }
    _setMode(_PanelMode.quality);
  }

  /// Switch quality via the controller's own [LiveRoomController.changeQn]
  /// (re-fetches the play-url + re-inits under the buffering scrim).
  void _switchQn(int code) {
    widget.liveController.changeQn(code);
    widget.onClose();
  }

  /// Re-run the live-url query (recovery when the CDN line stalls).
  void _refresh() {
    widget.liveController.queryLiveUrl();
    widget.onClose();
  }

  /// One like through the controller's tap flow (mirrors a single mobile tap).
  void _like() {
    final ctr = widget.liveController;
    if (!ctr.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    ctr
      ..onLikeTapDown()
      ..onLikeTapUp();
  }

  // ---------------------------------------------------------------- rows --

  /// The 直播选项 rows, as node-injected builders so adding a row never needs
  /// hand-renumbered focus-node indices.
  List<Widget Function(FocusNode)> _mainRowBuilders() {
    final player = _player;
    final ctr = widget.liveController;
    return [
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '弹幕',
          value: player.enableShowLiveDanmaku.value ? '开' : '关',
          onSelect: _toggleDanmaku,
        ),
      ),
      (n) => Obx(
        () => TvOptionRow(
          focusNode: n,
          label: '弹幕不透明度',
          value: '${(player.danmakuOpacity.value * 100).round()}%',
          onSelect: _stepOpacity,
        ),
      ),
      (n) => Obx(() {
        final desc = ctr.currentQnDesc.value;
        return TvOptionRow(
          focusNode: n,
          label: '清晰度',
          value: desc.isEmpty ? '加载中' : desc,
          onSelect: _openQuality,
        );
      }),
      (n) => TvOptionRow(
        focusNode: n,
        label: '刷新直播',
        value: '刷新',
        onSelect: _refresh,
      ),
      (n) => TvOptionRow(
        focusNode: n,
        label: '点赞',
        value: '赞',
        onSelect: _like,
      ),
    ];
  }

  List<Widget> _buildQualityRows() {
    final list = widget.liveController.acceptQnList;
    final cur = widget.liveController.currentQn;
    return [
      for (var i = 0; i < list.length; i++)
        TvOptionRow(
          focusNode: _nodes[i],
          dense: true,
          label: list[i].desc,
          checked: list[i].code == cur,
          onSelect: () => _switchQn(list[i].code),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Materialize main rows once so its count and widgets stay in lockstep.
    final List<Widget Function(FocusNode)>? mainBuilders =
        _mode == _PanelMode.main ? _mainRowBuilders() : null;
    final int rowCount = switch (_mode) {
      _PanelMode.main => mainBuilders!.length,
      _PanelMode.quality => widget.liveController.acceptQnList.length,
    };
    _syncNodes(rowCount);
    final rows = switch (_mode) {
      _PanelMode.main => [
        for (var i = 0; i < mainBuilders!.length; i++)
          mainBuilders[i](_nodes[i]),
      ],
      _PanelMode.quality => _buildQualityRows(),
    };

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          width: 470 * TvTheme.designScale,
          decoration: const BoxDecoration(
            color: Color(0xF2161923),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24 * TvTheme.designScale),
              bottomLeft: Radius.circular(24 * TvTheme.designScale),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            28 * TvTheme.designScale,
            32 * TvTheme.designScale,
            28 * TvTheme.designScale,
            24 * TvTheme.designScale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _mode.title,
                style: TvTheme.cardTitle.copyWith(
                  fontSize: 28 * TvTheme.designScale,
                ),
              ),
              const SizedBox(height: 20 * TvTheme.designScale),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: 12 * TvTheme.designScale),
                  itemBuilder: (_, index) => rows[index],
                ),
              ),
              const SizedBox(height: 16 * TvTheme.designScale),
              Text(
                _mode == _PanelMode.main ? 'OK 选择 · 返回 关闭' : 'OK 选择 · 返回 上一级',
                style: TvTheme.cardMeta,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
