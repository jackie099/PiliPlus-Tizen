import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// The 16:9 cover shared by the TV video cards (grid feed card + hero card).
///
/// Renders the artwork with a bottom scrim and, depending on [data]:
/// * an in-progress **resume badge** (`12:34 / 24:15`) sitting above a
///   [TvTheme.brandPink] **progress bar**, or a **`已看完`** badge when
///   finished, or the plain total-duration badge otherwise;
/// * a focus-only centered **▶ resume glyph** (when [TvVideoData.showPlayGlyph]),
///   faded/scaled in while [focused].
class TvCardCover extends StatelessWidget {
  const TvCardCover({super.key, required this.data, this.focused = false});

  final TvVideoData data;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            NetworkImgLayer(
              src: data.cover,
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              borderRadius: BorderRadius.zero,
            ),
            // Bottom scrim keeps the badge legible on any cover.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.62, 1],
                  colors: [Colors.transparent, Color(0xB3000000)],
                ),
              ),
            ),
            if (data.isLive)
              _badge(
                bottom: TvTheme.badgeInsetBottom,
                color: TvTheme.liveBadge,
                child: const Text('LIVE', style: TvTheme.durationBadge),
              )
            else if (data.finished)
              _badge(
                bottom: TvTheme.badgeInsetBottom,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.check_rounded,
                      size: TvTheme.badgeIconSize,
                      color: TvTheme.textSecondary,
                    ),
                    const SizedBox(width: TvTheme.statIconGap),
                    Text(
                      '已看完',
                      style: TvTheme.durationBadge.copyWith(
                        color: TvTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
            else if (data.durationText case final durationText?)
              _badge(
                bottom: data.progress != null
                    ? TvTheme.badgeInsetBottomOverBar
                    : TvTheme.badgeInsetBottom,
                child: Text(durationText, style: TvTheme.durationBadge),
              ),
            // "Continue watching" progress bar pinned to the bottom edge.
            if (data.progress case final progress?)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: TvTheme.progressBarHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Color(0x40FFFFFF)),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress.clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: const ColoredBox(color: TvTheme.brandPink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (data.showPlayGlyph) Positioned.fill(child: _resumeGlyph()),
          ],
        ),
      ),
    );
  }

  Widget _badge({
    required double bottom,
    required Widget child,
    Color color = const Color(0x8A000000),
  }) {
    return Positioned(
      right: TvTheme.badgeInsetRight,
      bottom: bottom,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: TvTheme.badgeRadius,
        ),
        child: Padding(padding: TvTheme.badgePadding, child: child),
      ),
    );
  }

  /// Flat dark disc + play arrow, faded/scaled in on focus (spring-in, quick
  /// fade-out). Flat paints stay crisp under Skia.
  Widget _resumeGlyph() {
    final Duration duration = focused
        ? TvTheme.focusDuration
        : TvTheme.glyphFadeOutDuration;
    final Curve curve = focused ? TvTheme.focusInCurve : TvTheme.focusOutCurve;
    return Center(
      child: AnimatedScale(
        scale: focused ? 1.0 : 0.8,
        duration: duration,
        curve: curve,
        child: AnimatedOpacity(
          opacity: focused ? 1.0 : 0.0,
          duration: duration,
          curve: curve,
          child: Container(
            width: TvTheme.resumeGlyphSize,
            height: TvTheme.resumeGlyphSize,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: TvTheme.resumeGlyphColor,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              size: TvTheme.resumeGlyphIconSize,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
