import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// Elevation layer of the focus treatment: a soft shadow that lifts the
/// focused element off the background. Applied as a normal [Decoration]
/// behind the child.
BoxDecoration tvFocusShadow({
  required bool focused,
  BorderRadius borderRadius = TvTheme.cardRadius,
}) {
  return BoxDecoration(
    borderRadius: borderRadius,
    boxShadow: focused ? TvTheme.focusShadow : null,
  );
}

/// Ring + brightness layer of the focus treatment: a bright border around the
/// focused element and a dimming scrim over unfocused ones. Applied as a
/// foreground decoration so it draws on top of the child's edges.
BoxDecoration tvFocusRing({
  required bool focused,
  BorderRadius borderRadius = TvTheme.cardRadius,
  bool dimWhenUnfocused = true,
}) {
  return BoxDecoration(
    borderRadius: borderRadius,
    border: Border.all(
      color: focused ? TvTheme.focusRingColor : Colors.transparent,
      width: TvTheme.focusRingWidth,
    ),
    color: !focused && dimWhenUnfocused
        ? TvTheme.unfocusedScrim
        : Colors.transparent,
  );
}

/// The core focus primitive of the TV UI.
///
/// Wraps any child and, while focused, animates a tvOS-style treatment:
/// ~1.08x scale with a spring-ish curve, a soft elevation shadow, a bright
/// focus ring, and a brightness lift (unfocused siblings are dimmed).
///
/// Activation:
/// * D-pad OK/Enter — the app-level `Shortcuts` in main.dart maps the TV
///   remote's `select`/`gameButtonA` keys to [ActivateIntent] (Enter/Space
///   are mapped by the framework defaults), which this widget handles via
///   [Actions] and forwards to [onSelect].
/// * Tap/click — also invokes [onSelect] (and moves focus here first).
///
/// When focused inside a scrollable, the element is automatically kept
/// visible (centered by default via [scrollAlignment]).
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.onFocusChange,
    this.onKeyEvent,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = TvTheme.cardRadius,
    this.focusScale = TvTheme.focusScale,
    this.dimWhenUnfocused = true,
    this.ensureVisible = true,
    this.scrollAlignment = 0.5,
  });

  final Widget child;

  /// Called on OK/Enter/select while focused, and on tap.
  final VoidCallback? onSelect;

  /// Reports focus gain/loss to the parent.
  final ValueChanged<bool>? onFocusChange;

  /// Optional D-pad override. Return ignored to continue normal directional
  /// traversal (for example, Up from a grid's first row to the tab bar).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Optional external node (owned and disposed by the caller); when null the
  /// widget manages its own node.
  final FocusNode? focusNode;

  final bool autofocus;

  /// Radius of the focus ring/shadow; match it to the child's clip radius.
  final BorderRadius borderRadius;

  /// Scale applied while focused.
  final double focusScale;

  /// Whether to lay [TvTheme.unfocusedScrim] over the child while unfocused
  /// (disable for elements that must stay crisp, e.g. the top bar).
  final bool dimWhenUnfocused;

  /// Whether gaining focus scrolls the enclosing scrollable to reveal this
  /// element.
  final bool ensureVisible;

  /// Alignment used by [Scrollable.ensureVisible]; 0.5 keeps the focused
  /// element near the middle of the viewport.
  final double scrollAlignment;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  FocusNode? _internalNode;
  bool _focused = false;

  FocusNode get _effectiveNode =>
      widget.focusNode ??
      (_internalNode ??= FocusNode(debugLabel: 'TvFocusable'));

  @override
  void dispose() {
    _internalNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    if (focused == _focused) return;
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
    if (focused && widget.ensureVisible && mounted) {
      Scrollable.ensureVisible(
        context,
        alignment: widget.scrollAlignment,
        duration: TvTheme.focusScrollDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _select() => widget.onSelect?.call();

  void _handleTap() {
    _effectiveNode.requestFocus();
    _select();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      child: FocusableActionDetector(
        focusNode: _effectiveNode,
        autofocus: widget.autofocus,
        onFocusChange: _handleFocusChange,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _select();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              _select();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          child: AnimatedScale(
            scale: _focused ? widget.focusScale : 1.0,
            duration: TvTheme.focusDuration,
            curve: _focused ? TvTheme.focusInCurve : TvTheme.focusOutCurve,
            child: AnimatedContainer(
              duration: TvTheme.focusDuration,
              curve: TvTheme.focusOutCurve,
              decoration: tvFocusShadow(
                focused: _focused,
                borderRadius: widget.borderRadius,
              ),
              foregroundDecoration: tvFocusRing(
                focused: _focused,
                borderRadius: widget.borderRadius,
                dimWhenUnfocused: widget.dimWhenUnfocused,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
