import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/login.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// QR-login controller for the TV UI.
///
/// Mirrors the mobile 扫码 tab (`LoginPageController.refreshQRCode`): the same
/// [LoginHttp.getHDcode] fetch, the same 1s [LoginHttp.codePoll] loop with a
/// 180s lifetime, and the same session persistence as
/// `LoginPageController.setAccount`. The single TV difference: instead of the
/// mobile account-mode dialog, the fresh login is bound to every
/// [AccountType] (the TV UI is single-account), which routes through
/// `Accounts.set(AccountType.main, ...)` -> `LoginUtils.onLoginMain()` and so
/// refreshes `AccountService.isLogin` app-wide exactly like mobile.
class TvLoginController extends GetxController {
  static const String statusWaitScan = '请使用哔哩哔哩App扫码';
  static const String statusScanned = '扫码成功，请在手机上确认登录';
  static const String statusConfirmed = '登录成功，正在保存…';
  static const String statusExpired = '二维码已过期，请刷新';

  late final Rx<LoadingState<({String authCode, String url})>> codeInfo =
      LoadingState<({String authCode, String url})>.loading().obs;
  final RxInt qrCodeLeftTime = 180.obs;
  final RxString statusQRCode = statusWaitScan.obs;

  Timer? _qrCodeTimer;
  bool _isReq = false;

  @override
  void onInit() {
    super.onInit();
    refreshQRCode();
  }

  @override
  void onClose() {
    _qrCodeTimer?.cancel();
    super.onClose();
  }

  Future<void> refreshQRCode() async {
    _qrCodeTimer?.cancel();
    codeInfo.value = LoadingState.loading();
    statusQRCode.value = statusWaitScan;
    qrCodeLeftTime.value = 180;

    final res = await LoginHttp.getHDcode();
    if (isClosed) return;
    codeInfo.value = res;
    if (res case Success(:final response)) {
      _qrCodeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        final left = 180 - t.tick;
        if (left <= 0) {
          t.cancel();
          qrCodeLeftTime.value = 0;
          statusQRCode.value = statusExpired;
          return;
        }
        qrCodeLeftTime.value = left;
        if (_isReq) return;

        _isReq = true;
        LoginHttp.codePoll(response.authCode).then((value) {
          _isReq = false;
          if (isClosed || !t.isActive) return;
          if (value['status']) {
            t.cancel();
            statusQRCode.value = statusConfirmed;
            _completeLogin(value['data']);
          } else if (value['code'] == 86038) {
            // Server-side expiry can precede the local countdown.
            t.cancel();
            qrCodeLeftTime.value = 0;
            statusQRCode.value = statusExpired;
          } else if (value['code'] == 86090) {
            statusQRCode.value = statusScanned;
          } else if (value['code'] != 86101) {
            // 86101 = not scanned yet: keep the wait-scan hint.
            statusQRCode.value = value['msg']?.toString() ?? '';
          }
        });
      });
    }
  }

  Future<void> _completeLogin(Map<String, dynamic> data) async {
    final account = LoginAccount(
      BiliCookieJar.fromList(data['cookie_info']['cookies']),
      data['access_token'],
      data['refresh_token'],
    );
    // Same persistence as the mobile setAccount.
    await Future.wait([account.onChange(), AnonymousAccount().delete()]);
    // Bind the account to every mode; main last so the app-wide login state
    // flips once everything else is in place.
    for (final type in AccountType.values) {
      if (type != AccountType.main) {
        await Accounts.set(type, account);
      }
    }
    await Accounts.set(AccountType.main, account);
    if (!isClosed) {
      Get.back();
    }
  }
}

/// TV login screen: a room-scannable QR on the left, instructions, live scan
/// status and a focusable refresh action on the right. Back pops the page
/// (unhandled key events reach the app-level BackDetector).
class TvLoginPage extends StatefulWidget {
  const TvLoginPage({super.key});

  @override
  State<TvLoginPage> createState() => _TvLoginPageState();
}

class _TvLoginPageState extends State<TvLoginPage> {
  final TvLoginController _controller = Get.put(TvLoginController());

  /// Design px; large enough after [TvTheme.designScale] (440 physical px on
  /// the 1080p framebuffer) to stay phone-scannable from the couch.
  static const double _qrSize = 440 * TvTheme.designScale;

  @override
  void dispose() {
    Get.delete<TvLoginController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Always dark/cinematic, matching the rest of the TV UI.
    return Theme(
      data: ThemeUtils.darkTheme,
      child: Scaffold(
        backgroundColor: TvTheme.background,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: TvTheme.backgroundGradient,
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildQrCard(),
                const SizedBox(width: 96 * TvTheme.designScale),
                _buildInfoColumn(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrCard() {
    return Container(
      width: _qrSize,
      height: _qrSize,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(
          Radius.circular(24 * TvTheme.designScale),
        ),
      ),
      padding: const EdgeInsets.all(28 * TvTheme.designScale),
      child: Obx(() {
        final info = _controller.codeInfo.value;
        return switch (info) {
          Loading() => const Center(
            child: SizedBox(
              width: TvTheme.spinnerSize,
              height: TvTheme.spinnerSize,
              child: CircularProgressIndicator(
                strokeWidth: TvTheme.spinnerStroke,
                color: TvTheme.background,
              ),
            ),
          ),
          Success(:final response) => Stack(
            fit: StackFit.expand,
            children: [
              PrettyQrView.data(
                data: response.url,
                decoration: const PrettyQrDecoration(
                  shape: PrettyQrSquaresSymbol(color: Colors.black87),
                ),
              ),
              if (_controller.qrCodeLeftTime.value <= 0)
                const ColoredBox(
                  color: Color(0xE6FFFFFF),
                  child: Center(
                    child: Text(
                      '二维码已过期',
                      style: TextStyle(
                        fontSize: 30 * TvTheme.designScale,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF14161C),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Error(:final errMsg) => Center(
            child: Padding(
              padding: const EdgeInsets.all(12 * TvTheme.designScale),
              child: Text(
                errMsg ?? '二维码获取失败',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24 * TvTheme.designScale,
                  height: 1.4,
                  color: Color(0xFF14161C),
                ),
              ),
            ),
          ),
        };
      }),
    );
  }

  Widget _buildInfoColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('扫码登录', style: TvTheme.brand),
        const SizedBox(height: 20 * TvTheme.designScale),
        const Text(
          '使用 bilibili 官方 App 扫描左侧二维码',
          style: TvTheme.stateMessage,
        ),
        const SizedBox(height: 36 * TvTheme.designScale),
        Obx(
          () => Text(
            _controller.statusQRCode.value,
            style: TvTheme.tabLabel,
          ),
        ),
        const SizedBox(height: 12 * TvTheme.designScale),
        Obx(() {
          final left = _controller.qrCodeLeftTime.value;
          final hasCode = _controller.codeInfo.value.isSuccess;
          return Text(
            hasCode && left > 0 ? '剩余有效时间 $left 秒' : ' ',
            style: TvTheme.cardMeta,
          );
        }),
        const SizedBox(height: 40 * TvTheme.designScale),
        TvFocusable(
          autofocus: true,
          onSelect: _controller.refreshQRCode,
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
              child: Text('刷新二维码', style: TvTheme.buttonLabel),
            ),
          ),
        ),
        const SizedBox(height: 28 * TvTheme.designScale),
        const Text('返回 取消登录', style: TvTheme.cardMeta),
      ],
    );
  }
}
