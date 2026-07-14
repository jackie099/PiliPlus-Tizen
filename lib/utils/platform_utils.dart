import 'dart:io' show Platform;

abstract final class PlatformUtils {
  /// True only for the Tizen (Samsung TV) build.
  ///
  /// flutter-tizen reports `Platform.operatingSystem == 'linux'`, so Tizen
  /// cannot be detected via dart:io. A Tizen-only compile define
  /// (`--dart-define=IS_TIZEN=true`) distinguishes it deterministically at
  /// compile time.
  static const bool isTizen = bool.fromEnvironment('IS_TIZEN');

  /// Readability alias for TV-specific gating.
  static const bool isTV = isTizen;

  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  @pragma("vm:platform-const")
  static final bool _isDesktopOS =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Tizen reports as Linux; exclude it so desktop-only plugins
  /// (window_manager, tray_manager, screen_retriever, desktop_webview_window)
  /// never run on the TV.
  static final bool isDesktop = _isDesktopOS && !isTizen;
}
