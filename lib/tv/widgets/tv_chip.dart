import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// A small pill label (e.g. `Lv6`, `大会员`, `UP`, `置顶`) reusing the badge
/// tokens. Shared by the 我的 profile band and the comment rows.
class TvChip extends StatelessWidget {
  const TvChip(this.label, {super.key, this.vip = false, this.outlined = false});

  final String label;

  /// 大会员 styling: pink fill + pink text.
  final bool vip;

  /// Outlined (pink border) styling, e.g. the 置顶 badge.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final Color fg = vip || outlined ? TvTheme.brandPink : TvTheme.textSecondary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: vip ? TvTheme.vipChipSurface : TvTheme.chipSurface,
        borderRadius: TvTheme.badgeRadius,
        border: outlined
            ? Border.all(color: TvTheme.brandPink, width: 1)
            : null,
      ),
      child: Padding(
        padding: TvTheme.badgePadding,
        child: Text(
          label,
          style: TvTheme.durationBadge.copyWith(
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}
