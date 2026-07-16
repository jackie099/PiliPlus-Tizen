import 'package:flutter/material.dart';

/// Design constants for the TV (D-pad) UI, in one tweakable place.
///
/// All dimensional tokens are **authored in 1920-design px** (sized as if the
/// canvas were 1920x1080 logical) and converted to the device's real logical
/// canvas via [designScale]. The S90F's real canvas is **1200x675 logical**
/// (1920x1080 physical framebuffer at devicePixelRatio 1.6, hardware-upscaled
/// to the 4K panel). The conversion deliberately lives here in the tokens —
/// NOT in the binding scaleFactor or devicePixelRatio — so MediaQuery and the
/// AVPlay hardware-overlay ROI keep the device's native coordinate system.
///
/// The grid derives card width from the live constraint width, so column
/// counts stay correct regardless.
abstract final class TvTheme {
  /// 0.625 — the single TV sizing knob: converts 1920-design px to the real
  /// 1200-wide logical canvas. Dimensionless values (scales, aspect ratios,
  /// line-height multipliers, opacities, column counts) are NOT scaled by it.
  static const double designScale = 1200 / 1920;

  // ---------------------------------------------------------------- focus --
  /// Scale applied to the focused element (tvOS-like pop). Dimensionless.
  ///
  /// Grid spacing must accommodate it: at 5 columns a card is ~333x291 design
  /// px (~208x182 logical), so 1.08x grows it ~8 logical px horizontally /
  /// ~7 vertically per side — safely inside [gridHSpacing]/[gridVSpacing], so
  /// a focused card never touches its neighbours.
  static const double focusScale = 1.08;

  /// Slightly subtler pop for small elements such as tabs/buttons.
  static const double focusScaleSmall = 1.05;

  /// Duration of the focus scale/ring/shadow transition.
  static const Duration focusDuration = Duration(milliseconds: 180);

  /// Duration of the scroll that keeps the focused element visible.
  static const Duration focusScrollDuration = Duration(milliseconds: 220);

  /// Spring-ish overshoot when an element gains focus.
  static const Curve focusInCurve = Curves.easeOutBack;

  /// Calm settle when an element loses focus.
  static const Curve focusOutCurve = Curves.easeOutCubic;

  /// Bright ring drawn around the focused element (kept slim so it stays
  /// crisp on the denser 5-column cards).
  static const Color focusRingColor = Color(0xF2FFFFFF);

  /// Deliberately NOT multiplied by [designScale]: the scaled value (~1.6
  /// logical px) would render as a sub-2-physical-px hairline. Floored at
  /// 2.0 logical px so the ring stays visible from the couch.
  static const double focusRingWidth = 2.0;

  /// Scrim laid over unfocused elements so the focused one reads brighter.
  static const Color unfocusedScrim = Color(0x30000000);

  /// Soft elevation shadow under the focused element.
  static const List<BoxShadow> focusShadow = [
    BoxShadow(
      color: Color(0x99000000),
      blurRadius: 22 * designScale,
      spreadRadius: 1 * designScale,
      offset: Offset(0, 8 * designScale),
    ),
  ];

  // --------------------------------------------------------------- canvas --
  /// Dark cinematic backdrop.
  static const Color background = Color(0xFF0C0E13);

  /// Subtle top-lit gradient variant of [background].
  static const Gradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF161923), Color(0xFF0B0C10)],
  );

  /// Card / surface fill.
  static const Color surface = Color(0xFF1B1E27);

  /// Bilibili brand pink, used sparingly (logo, selected-tab accent).
  static const Color brandPink = Color(0xFFFB7299);

  static const Color textPrimary = Color(0xFFF2F3F5);
  static const Color textSecondary = Color(0xFFA8AEBB);

  // --------------------------------------------------------------- layout --
  /// Horizontal padding of the whole screen.
  static const double screenPadding = 64 * designScale;

  static const double topBarHeight = 100 * designScale;

  /// 5 columns on the 1920-design canvas gives ~333-design-px (~208 logical)
  /// cards — a comfortable 10-foot density on a large 4K panel (4 columns
  /// read oversized). A count, not a dimension: never scaled.
  static const int gridColumns = 5;
  static const double gridHSpacing = 32 * designScale;
  static const double gridVSpacing = 40 * designScale;
  static const double gridTopPadding = 20 * designScale;
  static const double gridBottomPadding = 56 * designScale;

  /// Thickness of the "continue watching" progress bar along a card's cover.
  static const double progressBarHeight = 5 * designScale;

  /// Height of the text block under a card's 16:9 cover, in design px:
  /// 10 + two title lines (2 x 21 x 1.25) + 6 + meta line (18 x 1.2) + 10,
  /// with a little slack absorbed by the title's Expanded. Scales with the
  /// text it contains because every term is in design px too.
  static const double cardInfoHeight = 104 * designScale;

  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(14 * designScale),
  );
  static const BorderRadius tabRadius = BorderRadius.all(
    Radius.circular(28 * designScale),
  );
  static const BorderRadius badgeRadius = BorderRadius.all(
    Radius.circular(8 * designScale),
  );

  // ---------------------------------------------------- shared components --
  /// Padding of the text block under a card's cover.
  static const EdgeInsets cardPadding = EdgeInsets.fromLTRB(
    14 * designScale,
    10 * designScale,
    14 * designScale,
    10 * designScale,
  );

  /// Gap between a card's title block and its meta row.
  static const double cardTitleGap = 6 * designScale;

  /// Icon size of the view/danmaku stats on a card's meta row.
  static const double statIconSize = 18 * designScale;

  /// Gap between a stat icon and its value.
  static const double statIconGap = 4 * designScale;

  /// Gap between meta-row elements (uploader / stats cluster / stats).
  static const double metaGap = 12 * designScale;

  /// Inner padding of the duration badge on a card's cover.
  static const EdgeInsets badgePadding = EdgeInsets.symmetric(
    horizontal: 8 * designScale,
    vertical: 3 * designScale,
  );

  /// Offset of the duration badge from the cover's bottom-right corner.
  static const double badgeInsetRight = 10 * designScale;
  static const double badgeInsetBottom = 8 * designScale;

  /// Loading spinner shared by the feeds, the login QR and the video page.
  static const double spinnerSize = 56 * designScale;
  static const double spinnerStroke = 5 * designScale;

  /// Inner padding of pill buttons (重新加载 / 刷新二维码).
  static const EdgeInsets buttonPadding = EdgeInsets.symmetric(
    horizontal: 40 * designScale,
    vertical: 14 * designScale,
  );

  /// Gap between a status message and its action button.
  static const double stateActionGap = 32 * designScale;

  // ------------------------------------------- continue watching / history --
  /// Icon size of the ✓ on a "已看完" (finished) badge; optically matches the
  /// 16-px badge font.
  static const double badgeIconSize = 16 * designScale;

  /// Bottom inset of the resume badge when it sits above the progress bar
  /// (8-px standard inset + the 5-px bar would collide).
  static const double badgeInsetBottomOverBar = 12 * designScale;

  /// Focus-only "resume" glyph centered on a history cover: a flat dark disc
  /// with a play arrow. Flat paints stay crisp under Skia.
  static const double resumeGlyphSize = 80 * designScale;
  static const double resumeGlyphIconSize = 48 * designScale;
  static const Color resumeGlyphColor = Color(0xB3000000);

  /// Fade-out of the resume glyph when a card loses focus (faster than the
  /// spring-in so it disappears cleanly).
  static const Duration glyphFadeOutDuration = Duration(milliseconds: 120);

  /// Hero ("继续观看") row card: a larger 16:9 cover than the grid card, with a
  /// single-line title + resume line beneath.
  static const double heroCardWidth = 400 * designScale;
  static const double heroCardInfoHeight = 78 * designScale;

  /// Fixed-width trailing "查看全部" card that ends the hero row.
  static const double viewAllCardWidth = 200 * designScale;

  /// Vertical padding around the hero row's horizontal list — headroom for the
  /// focus pop (half the 1.08 growth + a little slack).
  static const double heroRowOverscan = 18 * designScale;

  /// Section header ("继续观看" / "为你推荐") vertical rhythm on the home page.
  static const double rowHeaderTopGap = 20 * designScale;
  static const double rowHeaderBottomGap = 8 * designScale;
  static const double sectionGap = 28 * designScale;

  /// Home continue-watching row fade-in when it resolves (no slide/shimmer).
  static const Duration rowAppearDuration = Duration(milliseconds: 240);

  /// Max in-progress items shown in the home continue-watching row. A count,
  /// not a dimension: never scaled.
  static const int continueRowMaxItems = 12;

  // -------------------------------------------------------- 我的 (My) page --
  /// Profile band: circular avatar + name/level/vip chips + a stats line.
  /// A passive banner (not focusable) when logged in.
  static const double profileAvatarSize = 96 * designScale;
  static const double profileAvatarIconSize = 48 * designScale;
  static const double profileAvatarGap = 28 * designScale;
  static const double profileHeaderTopGap = 12 * designScale;
  static const double profileHeaderBottomGap = 4 * designScale;
  static const double profileChipGap = 14 * designScale;
  static const double profileMetaGap = 10 * designScale;

  /// Level chip fill; the 大会员 chip fill (only when vipStatus == 1).
  static const Color chipSurface = Color(0x14FFFFFF);
  static const Color vipChipSurface = Color(0x26FB7299);

  // ----------------------------------------------------------- typography --
  static const TextStyle brand = TextStyle(
    fontSize: 32 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w800,
    color: brandPink,
  );

  static const TextStyle tabLabel = TextStyle(
    fontSize: 26 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static const TextStyle cardTitle = TextStyle(
    fontSize: 21 * designScale,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static const TextStyle cardMeta = TextStyle(
    fontSize: 18 * designScale,
    height: 1.2,
    color: textSecondary,
  );

  /// Home-page section header ("继续观看" / "为你推荐").
  static const TextStyle sectionHeader = TextStyle(
    fontSize: 28 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: textPrimary,
  );

  /// Single-line title on the larger hero (继续观看) card.
  static const TextStyle heroTitle = TextStyle(
    fontSize: 22 * designScale,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  /// Label of the trailing "查看全部" card in the hero row.
  static const TextStyle viewAllLabel = TextStyle(
    fontSize: 20 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: textSecondary,
  );

  /// 我的-page profile name.
  static const TextStyle profileName = TextStyle(
    fontSize: 34 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: textPrimary,
  );

  /// 我的-page stats line (关注 / 粉丝 / 动态).
  static const TextStyle profileMeta = TextStyle(
    fontSize: 20 * designScale,
    height: 1.2,
    color: textSecondary,
  );

  static const TextStyle durationBadge = TextStyle(
    fontSize: 16 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: Colors.white,
  );

  static const TextStyle stateMessage = TextStyle(
    fontSize: 24 * designScale,
    height: 1.4,
    color: textSecondary,
  );

  static const TextStyle buttonLabel = TextStyle(
    fontSize: 24 * designScale,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );
}
