import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:PiliPlus/plugin/pl_player/engine/abstract_media_player.dart';
import 'package:PiliPlus/plugin/pl_player/engine/avplay_media_player.dart';
import 'package:PiliPlus/plugin/pl_player/engine/bili_dash_proxy.dart';
import 'package:PiliPlus/plugin/pl_player/engine/media_kit_media_player.dart';
import 'package:PiliPlus/utils/platform_utils.dart';

/// Whether the running build should use the Samsung TV (AVPlay) video engine
/// instead of the vendored media_kit / mpv engine.
///
/// This is a compile-time constant on Tizen (see [PlatformUtils.isTizen]), so
/// the tree-shaker can drop the unused backend from each build.
bool get useAvplayEngine => PlatformUtils.isTizen;

/// Process-wide localhost proxy that stitches Bilibili's separate DASH video and
/// audio urls into a single synthetic manifest (and forwards CDN headers) for
/// the AVPlay backend, which cannot open two streams.
///
/// Created once and shared by every [AvplayMediaPlayer]; the proxy starts its
/// http server lazily on first source that needs it, so constructing it here is
/// cheap and safe even on builds that never play a dual-stream source.
BiliDashProxy? _sharedDashProxy;

/// Lazily-constructed accessor for the shared [BiliDashProxy] singleton.
BiliDashProxy get _dashProxy => _sharedDashProxy ??= BiliDashProxy();

/// Builds the AVPlay-backed player for Samsung Tizen TVs.
///
/// The returned player wraps `video_player_avplay` and is wired to the shared
/// [BiliDashProxy] so dual-stream DASH sources can be muxed on the fly and the
/// mandatory `Referer` injected. Note: the plugin is patched (see
/// `tizen/src/video_player_tizen_plugin.cc`) so localhost-proxy urls use its
/// CAPI `MediaPlayer` backend — which prepares/plays them and renders via the
/// Flutter-window overlay — instead of PlusPlayer, whose prepare fails on them.
/// The proxy spins up its server on demand from [AbstractMediaPlayer.open].
AbstractMediaPlayer createTizenPlayer() {
  return AvplayMediaPlayer(proxy: _dashProxy);
}

/// Wraps an already-constructed media_kit [player] (and its optional
/// [videoController]) in the engine-agnostic surface.
///
/// media_kit's [VideoController] must be built by the caller because it carries
/// UI-facing configuration (hardware acceleration, decoders); the factory only
/// adapts the finished objects, it does not own their lifecycle beyond what the
/// [AbstractMediaPlayer] contract exposes.
AbstractMediaPlayer wrapMediaKit(Player player, VideoController? videoController) {
  return MediaKitMediaPlayer.fromPlayer(player, videoController);
}
