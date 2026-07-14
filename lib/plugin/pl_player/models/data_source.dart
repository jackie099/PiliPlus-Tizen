import 'package:PiliPlus/plugin/pl_player/engine/abstract_media_player.dart'
    show DashStreamMeta;
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  /// Real DASH metadata for the selected video/audio stream. Populated only for
  /// network (Bilibili DASH) sources; the AVPlay backend threads it into its
  /// localhost proxy so the synthesized MPD advertises the true codec instead of
  /// a hardcoded placeholder. Null for file sources and ignored by media_kit.
  final DashStreamMeta? videoMeta;
  final DashStreamMeta? audioMeta;

  DataSource({
    required this.videoSource,
    required this.audioSource,
    this.videoMeta,
    this.audioMeta,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
    super.videoMeta,
    super.audioMeta,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}
