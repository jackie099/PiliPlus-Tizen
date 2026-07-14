<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus-Tizen</h1>
    <p><b>A Samsung Tizen TV (D-pad) port of <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a>, the Flutter Bilibili client.</b></p>
</div>

![platform](https://img.shields.io/badge/platform-Tizen%209.0-blue)
![flutter](https://img.shields.io/badge/flutter--tizen-3.44-02569B)
![license](https://img.shields.io/badge/license-GPL--3.0-green)
![fork](https://img.shields.io/badge/fork%20of-PiliPlus-lightgrey)

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

This is a fork of [**PiliPlus**](https://github.com/bggRGjQaUbCoE/PiliPlus) (a Flutter-based third-party Bilibili client) adapted to run on **Samsung Tizen smart TVs** via [`flutter-tizen`](https://github.com/flutter-tizen/flutter-tizen), driven entirely by the TV remote's **D-pad**. It has been developed and tested on a **Samsung S90F (77" 4K OLED, Tizen 9.0)**.

The mobile/desktop targets from upstream are untouched — all TV code is additive and gated behind `PlatformUtils.isTizen`, so the same tree still builds for Android / iOS / Windows / Linux.

---

## Why a fork (the hard part)

Tizen's Flutter embedder cannot use `media_kit` (upstream's video engine — no libmpv on Tizen), and the platform's native player (`video_player_avplay`, backed by the Tizen CAPI `MediaPlayer`) **cannot** play Bilibili's DASH streams directly:

1. **Split video + audio.** Bilibili DASH ships video and audio as two separate fMP4 URLs; the native player wants one source.
2. **Mandatory `Referer`.** The Bilibili CDN returns `403` without `Referer: https://www.bilibili.com`, and the player drops custom request headers on the media socket.
3. **No external HTTPS streaming.** PlusPlayer/CAPI cannot stream arbitrary external HTTPS reliably.

The solution is a **Dart localhost reverse-proxy** ([`lib/plugin/pl_player/engine/bili_dash_proxy.dart`](lib/plugin/pl_player/engine/bili_dash_proxy.dart)) that:

- Serves a `127.0.0.1` URL to the native player (which it *can* stream).
- Injects the `Referer` / `User-Agent` the player drops, and forwards `Range` requests so seeking works.
- Synthesizes a truthful **static DASH `.mpd`** from the split streams, advertising the real codecs (HEVC / AV1 / FLAC / **E-AC-3**) so the decoder accepts them.

The rest of the port is a from-scratch **TV UI layer** ([`lib/tv/`](lib/tv/)) that reuses upstream's controllers and networking but replaces the touch chrome with a D-pad-navigable interface.

---

## TV features

- **D-pad navigation** — home / trending / search / dynamics / user, a fullscreen video page, and a TV settings screen, all remote-driven.
- **4K HEVC + HDR10** — auto-selects the highest playable tier on the S90F (HDR真彩·H.265). Dolby Vision (126) and 8K (127) are excluded — the S90F's decoder rejects 8K (`Not supported format`) and Samsung never licenses DV.
- **Dolby Atmos (E-AC-3 / ec-3)** — proven to decode on the S90F. The proxy advertises `ec-3` at 48 kHz with the Dolby channel-configuration scheme (`F801` = 5.1) + the JOC `SupplementalProperty`, and an opt-in `preferDolbyAtmos` preference auto-selects the Atmos track on every video that carries one.
- **Apple-TV-style scrubber** — Left/Right nudge a **visual** target (10s taps, hold to accelerate) on a scrub bar with a Bilibili **videoshot thumbnail preview** + target-time/delta; exactly **one** native seek commits on OK or after a short idle. (This replaced per-keypress seeking, which raced the AVPlay pipeline to the end.)
- **CDN line picker + speed test** — Bilibili's per-object CDN throughput varies wildly; when a stream is on a slow mirror the player nudges you to switch lines (in-player and in settings), with a speed test against the *currently playing* stream.
- **In-player options panel** — quality, audio quality, decode format, danmaku toggle, subtitles, chapters (view points), episode / 分P picker + prev/next, aspect ratio, playback speed/order, and like / favourite.

## Architecture

| Layer | Where | Notes |
|------|-------|-------|
| Tizen embedder & manifest | [`tizen/`](tizen/) | flutter-tizen project (`Runner.csproj`, `tizen-manifest.xml`), app icon |
| Vendored native plugin | [`plugins/video_player_avplay/`](plugins/) | Tizen CAPI `MediaPlayer` backend (hole-punched hardware video overlay) |
| Video engine | [`lib/plugin/pl_player/engine/`](lib/plugin/pl_player/engine/) | `AvplayMediaPlayer` + the `BiliDashProxy` + Tizen subtitle overlay |
| TV UI | [`lib/tv/`](lib/tv/) | Home, search, video page, settings, the D-pad options panel |
| Shared edits | `lib/pages/video/controller.dart`, `lib/plugin/pl_player/controller.dart`, … | additive, `PlatformUtils.isTizen`-guarded |

Video renders on a **native hardware overlay** (hole-punched), so Flutter only draws the UI/danmaku on top — which is why the app ships with **Skia** (Impeller's GLES backend renders dense Chinese text noticeably softer, and it doesn't touch the hardware-video path anyway).

## Build & run

Prerequisites: [`flutter-tizen`](https://github.com/flutter-tizen/flutter-tizen) (Flutter 3.44), the Tizen SDK, and a Tizen 9.0 TV in developer mode paired over `sdb`.

```bash
# one-time: point sdb at the TV
sdb connect <TV_IP>:26101

# debug (Skia — for development)
export LD_LIBRARY_PATH="$HOME/projects/tizen/tizen-libs:$LD_LIBRARY_PATH"
flutter-tizen run -d <TV_IP>:26101 --dart-define=IS_TIZEN=true

# release (AOT-optimized, Skia — what you install day-to-day)
flutter-tizen run --release -d <TV_IP>:26101 --dart-define=IS_TIZEN=true
# or build a standalone TPK:
flutter-tizen build tpk --release --dart-define=IS_TIZEN=true
```

`--dart-define=IS_TIZEN=true` sets the compile-time `PlatformUtils.isTizen` flag that routes into the TV UI and the AVPlay engine. Do **not** pass `--enable-impeller` (see the Skia note above).

## Known limitations

- **8K** is excluded — the S90F decoder rejects it (it's a 4K-class decoder).
- **Dolby Vision** video is excluded (Samsung licensing); HDR10 is used instead. Atmos audio is independent and works on DV uploads.
- **Atmos passthrough** to an eARC soundbar depends on the TV's audio settings (eARC = Auto, Digital Output = Pass-Through, Atmos Compatibility = On); the TV's built-in speakers decode the 5.1 core.
- Tested only on the **S90F / Tizen 9.0**; other Tizen TVs are untried.

---

## 声明 / Disclaimer

此项目基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 二次开发，仅用于学习与个人测试，请于下载后 24 小时内删除。所用 API 皆从官方网站收集，不提供任何破解内容。

Upstream lineage: [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) → [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX) → [guozhigq/pilipala](https://github.com/guozhigq/pilipala). Thanks to the original authors for their open-source work.

## 致谢 / Acknowledgements

- Upstream [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) and its lineage
- [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen) and `video_player_avplay`
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)

## License

[GPL-3.0](LICENSE), inherited from upstream PiliPlus.
