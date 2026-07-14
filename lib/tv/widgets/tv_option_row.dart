import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// A focusable label/value row shared by the TV settings page and the
/// in-player options panel: label on the left, the current value (and an
/// optional check mark) on the right, activated with OK via [TvFocusable].
class TvOptionRow extends StatelessWidget {
  const TvOptionRow({
    super.key,
    required this.label,
    this.value,
    this.checked = false,
    this.enabled = true,
    this.onSelect,
    this.onKeyEvent,
    this.focusNode,
    this.autofocus = false,
    this.dense = false,
  });

  final String label;

  /// Current value shown on the trailing side (e.g. "开" / "1080P 高清").
  final String? value;

  /// Shows a check mark, used for the active entry of a submenu.
  final bool checked;

  /// Disabled rows keep their place in the list (and stay focusable so the
  /// D-pad flow is stable) but render dimmed; [onSelect] may explain why.
  final bool enabled;

  final VoidCallback? onSelect;
  final FocusOnKeyEventCallback? onKeyEvent;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Compact vertical padding for long submenus (quality/speed lists).
  final bool dense;

  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(14 * TvTheme.designScale),
  );

  @override
  Widget build(BuildContext context) {
    final labelStyle = enabled
        ? TvTheme.buttonLabel
        : TvTheme.buttonLabel.copyWith(color: TvTheme.textSecondary);
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onSelect: onSelect,
      onKeyEvent: onKeyEvent,
      borderRadius: _radius,
      focusScale: TvTheme.focusScaleSmall,
      dimWhenUnfocused: false,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: TvTheme.surface,
          borderRadius: _radius,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 24 * TvTheme.designScale,
            vertical: (dense ? 14 : 18) * TvTheme.designScale,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 16 * TvTheme.designScale),
                Text(value!, style: TvTheme.cardMeta),
              ],
              if (checked) ...[
                const SizedBox(width: TvTheme.metaGap),
                const Icon(
                  Icons.check_rounded,
                  size: 26 * TvTheme.designScale,
                  color: TvTheme.brandPink,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
