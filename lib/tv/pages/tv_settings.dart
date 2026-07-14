import 'dart:async';

import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/tv/pages/tv_cdn_page.dart';
import 'package:PiliPlus/tv/pages/tv_login.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/tv_option_row.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// TV settings tab: a small focusable list over the existing [Pref] keys
/// (enableShowDanmaku / autoPlayEnable / defaultVideoQa) plus the account
/// entry that routes to [TvLoginPage] or logs out via [Accounts.deleteAll].
///
/// Toggles apply on OK; 默认画质 also steps with Left/Right. Values persist
/// through `GStorage.setting`, so they take effect for new play sessions the
/// same way the mobile settings do.
class TvSettings extends StatefulWidget {
  const TvSettings({super.key});

  @override
  State<TvSettings> createState() => _TvSettingsState();
}

class _TvSettingsState extends State<TvSettings> {
  /// Vertical gap between option rows.
  static const double _rowGap = 16 * TvTheme.designScale;

  final AccountService _accountService = Get.find<AccountService>();

  bool _danmakuOn = Pref.enableShowDanmaku;

  /// Autoplay defaults ON for TV — same key/default the TV video page reads
  /// (`Pref.autoPlayEnable`'s built-in off default is the mobile one).
  bool _autoPlay = GStorage.setting.get(
    SettingBoxKey.autoPlayEnable,
    defaultValue: true,
  );

  int _defaultQa = Pref.defaultVideoQa;

  bool _logoutArmed = false;
  Timer? _logoutArmTimer;

  @override
  void dispose() {
    _logoutArmTimer?.cancel();
    super.dispose();
  }

  void _toggleDanmaku() {
    setState(() => _danmakuOn = !_danmakuOn);
    GStorage.setting.put(SettingBoxKey.enableShowDanmaku, _danmakuOn);
  }

  void _toggleAutoPlay() {
    setState(() => _autoPlay = !_autoPlay);
    GStorage.setting.put(SettingBoxKey.autoPlayEnable, _autoPlay);
  }

  /// Steps through [VideoQuality.values] (ordered high to low); +1 moves to
  /// the next lower quality, wrapping around. Persisted immediately.
  void _stepQuality(int delta) {
    const values = VideoQuality.values;
    final index = values.indexWhere((e) => e.code == _defaultQa);
    final next = values[(index + delta + values.length) % values.length];
    setState(() => _defaultQa = next.code);
    GStorage.setting.put(SettingBoxKey.defaultVideoQa, next.code);
  }

  KeyEventResult _onQualityKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _stepQuality(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _stepQuality(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Opens the CDN speed-test/picker; refreshes the row's value on return so
  /// the newly-chosen line shows immediately.
  Future<void> _openCdnPage() async {
    await Get.to(() => const TvCdnPage());
    if (mounted) setState(() {});
  }

  void _onAccountSelect() {
    if (!_accountService.isLogin.value) {
      Get.to(() => const TvLoginPage());
      return;
    }
    if (!_logoutArmed) {
      // Two-press confirmation instead of a dialog: TV-friendly and safe
      // against an accidental OK.
      setState(() => _logoutArmed = true);
      _logoutArmTimer?.cancel();
      _logoutArmTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _logoutArmed = false);
      });
      return;
    }
    _logoutArmTimer?.cancel();
    setState(() => _logoutArmed = false);
    // Same teardown as the mobile 退出登录: removing the main account fires
    // LoginUtils.onLogoutMain(), which resets AccountService.isLogin.
    Accounts.deleteAll(Set.of(Accounts.account.values)).then(
      (_) => SmartDialog.showToast('已退出登录'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 920 * TvTheme.designScale,
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            TvTheme.screenPadding,
            TvTheme.gridTopPadding,
            TvTheme.screenPadding,
            TvTheme.gridBottomPadding,
          ),
          children: [
            TvOptionRow(
              autofocus: true,
              label: '弹幕默认开启',
              value: _danmakuOn ? '开' : '关',
              onSelect: _toggleDanmaku,
            ),
            const SizedBox(height: _rowGap),
            TvOptionRow(
              label: '自动播放',
              value: _autoPlay ? '开' : '关',
              onSelect: _toggleAutoPlay,
            ),
            const SizedBox(height: _rowGap),
            TvOptionRow(
              label: '默认画质',
              value: VideoQuality.fromCode(_defaultQa).desc,
              onSelect: () => _stepQuality(1),
              onKeyEvent: _onQualityKey,
            ),
            const SizedBox(height: _rowGap),
            TvOptionRow(
              label: 'CDN 线路',
              value: VideoUtils.cdnService.desc,
              onSelect: _openCdnPage,
            ),
            const SizedBox(height: _rowGap),
            Obx(
              () => TvOptionRow(
                label: '账号',
                value: _accountService.isLogin.value
                    ? (_logoutArmed ? '再按一次确认退出' : '退出登录')
                    : '扫码登录',
                onSelect: _onAccountSelect,
              ),
            ),
            const SizedBox(height: 28 * TvTheme.designScale),
            const Text(
              '默认画质可用 ◀ ▶ 或 OK 切换；弹幕与画质设置对新开始的播放生效。'
              '4K 卡顿多为 CDN 线路拥堵，可在「CDN 线路」测速并切换更快的线路。',
              style: TvTheme.cardMeta,
            ),
          ],
        ),
      ),
    );
  }
}
