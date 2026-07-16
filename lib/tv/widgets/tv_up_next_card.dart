import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;

/// Normalized preview of the next video for the "接下来" card, resolved from a
/// [BaseEpisodeItem] (分P / 合集 episode / related), whose title & cover live in
/// different fields per subtype.
class TvUpNextInfo {
  const TvUpNextInfo({required this.title, this.cover, this.label});

  final String title;
  final String? cover;
  final String? label;

  factory TvUpNextInfo.from(BaseEpisodeItem item, {String? fallbackCover}) {
    if (item is Part) {
      return TvUpNextInfo(
        title: (item.part?.isNotEmpty == true ? item.part : item.title) ?? '',
        cover: item.firstFrame ?? fallbackCover,
        label: item.badge ?? '下一分P',
      );
    }
    if (item is EpisodeItem) {
      return TvUpNextInfo(
        title: item.title ?? '',
        cover: item.cover ?? fallbackCover,
        label: item.badge ?? '下一集',
      );
    }
    return TvUpNextInfo(
      title: item.title ?? '',
      cover: item.cover ?? fallbackCover,
      label: item.badge,
    );
  }
}

/// Bottom-right "接下来" auto-play card shown over the finished frame. Runs a
/// 5s countdown ring, then calls [onPlayNow]; pressing OK plays immediately,
/// and any arrow key halts the auto-advance (the ring freezes to a ▶) while
/// keeping the card so OK still works. The whole card is the single focusable.
class TvUpNextCard extends StatefulWidget {
  const TvUpNextCard({
    super.key,
    required this.info,
    required this.onPlayNow,
  });

  final TvUpNextInfo info;
  final VoidCallback onPlayNow;

  @override
  State<TvUpNextCard> createState() => _TvUpNextCardState();
}

class _TvUpNextCardState extends State<TvUpNextCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: TvTheme.upNextCountdown,
  );
  bool _frozen = false;

  @override
  void initState() {
    super.initState();
    _controller
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_frozen) {
          widget.onPlayNow();
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _freeze() {
    if (_frozen) return;
    _controller.stop();
    setState(() => _frozen = true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isPress = event is KeyDownEvent || event is KeyRepeatEvent;
    final key = event.logicalKey;
    final isArrow =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (isArrow) {
      if (isPress) _freeze();
      return KeyEventResult.handled; // keep focus on the card
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: true,
      onSelect: widget.onPlayNow,
      onKeyEvent: _onKey,
      borderRadius: TvTheme.cardRadius,
      focusScale: 1.0,
      dimWhenUnfocused: false,
      ensureVisible: false,
      child: Container(
        width: TvTheme.upNextWidth,
        padding: const EdgeInsets.all(TvTheme.upNextPadding),
        decoration: const BoxDecoration(
          color: TvTheme.upNextSurface,
          borderRadius: TvTheme.cardRadius,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _thumbnail(),
                const SizedBox(width: TvTheme.upNextGap),
                Expanded(child: _info()),
              ],
            ),
            const SizedBox(height: TvTheme.upNextPadding),
            const Divider(height: 1, thickness: 1, color: Color(0x1FFFFFFF)),
            const SizedBox(height: TvTheme.upNextPadding),
            const Text(
              'OK 立即播放  ·  返回 取消',
              textAlign: TextAlign.center,
              style: TvTheme.cardMeta,
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail() {
    return SizedBox(
      width: TvTheme.upNextThumbWidth,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: TvTheme.badgeRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.info.cover case final cover?)
                NetworkImgLayer(
                  src: cover,
                  width: TvTheme.upNextThumbWidth,
                  height: TvTheme.upNextThumbWidth * 9 / 16,
                  borderRadius: BorderRadius.zero,
                )
              else
                const ColoredBox(color: TvTheme.surface),
              const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x59000000)),
              ),
              Center(child: _ring()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ring() {
    return SizedBox(
      width: TvTheme.upNextRingSize,
      height: TvTheme.upNextRingSize,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: TvTheme.resumeGlyphColor,
          shape: BoxShape.circle,
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final remaining =
                (TvTheme.upNextCountdown.inSeconds * (1 - _controller.value))
                    .ceil()
                    .clamp(1, TvTheme.upNextCountdown.inSeconds);
            return Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: const EdgeInsets.all(TvTheme.upNextRingStroke),
                  child: CircularProgressIndicator(
                    value: _frozen ? null : 1 - _controller.value,
                    strokeWidth: TvTheme.upNextRingStroke,
                    backgroundColor: TvTheme.upNextRingTrack,
                    valueColor: const AlwaysStoppedAnimation(TvTheme.brandPink),
                  ),
                ),
                Center(
                  child: _frozen
                      ? const Icon(
                          Icons.play_arrow_rounded,
                          size: TvTheme.resumeGlyphIconSize,
                          color: Colors.white,
                        )
                      : Text('$remaining', style: TvTheme.upNextRingNumber),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _info() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('接下来', style: TvTheme.upNextKicker),
            if (widget.info.label case final label?) ...[
              const SizedBox(width: TvTheme.profileChipGap),
              DecoratedBox(
                decoration: const BoxDecoration(
                  color: TvTheme.chipSurface,
                  borderRadius: TvTheme.badgeRadius,
                ),
                child: Padding(
                  padding: TvTheme.badgePadding,
                  child: Text(
                    label,
                    style: TvTheme.durationBadge.copyWith(
                      color: TvTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: TvTheme.cardTitleGap),
        Text(
          widget.info.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TvTheme.upNextTitle,
        ),
      ],
    );
  }
}
