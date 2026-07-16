import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:flutter/material.dart';

/// A circular user avatar, with a person-icon placeholder when there is no
/// image. Shared by the 我的 profile band and the comment rows.
class TvAvatar extends StatelessWidget {
  const TvAvatar({super.key, required this.face, required this.size, this.iconSize});

  final String? face;
  final double size;

  /// Placeholder icon size; defaults to half the avatar.
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: face?.isNotEmpty == true
            ? NetworkImgLayer(
                src: face,
                width: size,
                height: size,
                borderRadius: BorderRadius.zero,
              )
            : ColoredBox(
                color: TvTheme.surface,
                child: Icon(
                  Icons.person_rounded,
                  size: iconSize ?? size / 2,
                  color: TvTheme.textSecondary,
                ),
              ),
      ),
    );
  }
}
