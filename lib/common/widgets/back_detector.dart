import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent;

class BackDetector extends StatelessWidget {
  const BackDetector({
    super.key,
    required this.onBack,
    required this.child,
  });

  final Widget child;

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        behavior: .translucent,
        onPointerDown: _onPointerDown,
        child: child,
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // escape: desktop keyboard / mouse back. goBack + browserBack: TV remote
    // Back button (Tizen delivers it as a Back key, not escape).
    if (event is KeyDownEvent &&
        (event.logicalKey == .escape ||
            event.logicalKey == .goBack ||
            event.logicalKey == .browserBack)) {
      onBack();
      return .handled;
    }
    return .ignored;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons == kBackMouseButton) {
      onBack();
    }
  }
}
