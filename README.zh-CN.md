<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus-Tizen</h1>
    <p><b>将 Flutter 哔哩哔哩客户端 <a href="https://github.com/bggRGjQaUbCoE/PiliPlus">PiliPlus</a> 移植到三星 Tizen 电视（遥控器 D-pad 操作）。</b></p>
</div>

![platform](https://img.shields.io/badge/platform-Tizen%209.0-blue)
![flutter](https://img.shields.io/badge/flutter--tizen-3.44-02569B)
![license](https://img.shields.io/badge/license-GPL--3.0-green)
![fork](https://img.shields.io/badge/fork%20of-PiliPlus-lightgrey)

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

本项目基于 [**PiliPlus**](https://github.com/bggRGjQaUbCoE/PiliPlus)（一个 Flutter 编写的第三方哔哩哔哩客户端）二次开发，通过 [`flutter-tizen`](https://github.com/flutter-tizen/flutter-tizen) 适配到**三星 Tizen 智能电视**，完全由电视遥控器的 **D-pad（方向键）** 操作。开发与测试均在 **三星 S90F（77 寸 4K OLED，Tizen 9.0）** 上进行。

上游的移动端 / 桌面端目标不受影响——所有电视相关代码均为增量式改动，并通过 `PlatformUtils.isTizen` 隔离，因此同一份代码仍可编译 Android / iOS / Windows / Linux。

---

## 为什么要 Fork（难点所在）

Tizen 的 Flutter embedder 无法使用 `media_kit`（上游的视频引擎——Tizen 上没有 libmpv），而平台原生播放器（`video_player_avplay`，底层为 Tizen CAPI `MediaPlayer`）**无法**直接播放哔哩哔哩的 DASH 流：

1. **音视频分离。** 哔哩哔哩 DASH 将视频与音频拆成两个独立的 fMP4 URL，而原生播放器只接受单一源。
2. **强制 `Referer`。** 不带 `Referer: https://www.bilibili.com` 时哔哩哔哩 CDN 返回 `403`，而播放器会在媒体连接上丢弃自定义请求头。
3. **不支持外部 HTTPS 流。** PlusPlayer/CAPI 无法可靠地流式播放任意外部 HTTPS。

解决方案是一个 **Dart 本地反向代理**（[`lib/plugin/pl_player/engine/bili_dash_proxy.dart`](lib/plugin/pl_player/engine/bili_dash_proxy.dart)）：

- 向原生播放器提供一个 `127.0.0.1` 地址（这个它*能*流式播放）。
- 注入播放器丢弃的 `Referer` / `User-Agent`，并转发 `Range` 请求以支持拖动进度。
- 从分离的音视频流合成一份真实的 **静态 DASH `.mpd`**，声明真实编码（HEVC / AV1 / FLAC / **E-AC-3**），从而让解码器接受它们。

其余部分是从零编写的 **电视 UI 层**（[`lib/tv/`](lib/tv/)），复用上游的控制器与网络层，但用可用 D-pad 导航的界面替换了触摸操作。

---

## 电视端功能

- **D-pad 导航** —— 首页 / 热门 / 搜索 / 动态 / 用户、全屏视频页、电视设置页，全部由遥控器操作。
- **4K HEVC + HDR10** —— 在 S90F 上自动选择可播放的最高画质（HDR真彩·H.265）。杜比视界（126）与 8K（127）被排除——S90F 解码器会拒绝 8K（`Not supported format`），且三星从不授权杜比视界。
- **杜比全景声（E-AC-3 / ec-3）** —— 已验证可在 S90F 上解码。代理以 48 kHz、Dolby 声道配置方案（`F801` = 5.1）加 JOC `SupplementalProperty` 声明 `ec-3`；并提供可选的 `preferDolbyAtmos` 偏好，在每个含 Atmos 音轨的视频上自动选择该音轨。
- **Apple-TV 式进度调节** —— 左右键移动一个**视觉**目标（单击 ±10s，长按加速），进度条上带有哔哩哔哩**视频缩略图预览**与目标时间/差值；仅在 OK 或短暂空闲后提交**一次**原生 seek。（此前的“每次按键都 seek”会把 AVPlay 管线冲到片尾。）
- **CDN 线路选择 + 测速** —— 哔哩哔哩 CDN 的单对象速率差异极大；当某条流位于慢镜像时，播放器会提示切换线路（播放内与设置内均可），并对*当前正在播放*的流进行测速。
- **播放内选项面板** —— 清晰度、音质、解码格式、弹幕开关、字幕、章节（分段）、选集 / 分P 切换与上一集/下一集、画面比例、播放速度/顺序，以及点赞 / 收藏。

## 架构

| 层 | 位置 | 说明 |
|------|-------|------|
| Tizen embedder 与清单 | [`tizen/`](tizen/) | flutter-tizen 工程（`Runner.csproj`、`tizen-manifest.xml`）、应用图标 |
| 原生视频插件 | [`video_player_avplay` fork](https://github.com/jackie099/plugins)（git 依赖） | CAPI `MediaPlayer` 引擎（硬件视频层挖洞叠加），通过 `playerEngine` 选项选择——已向上游提交 [flutter-tizen/plugins#1064](https://github.com/flutter-tizen/plugins/pull/1064) |
| 视频引擎 | [`lib/plugin/pl_player/engine/`](lib/plugin/pl_player/engine/) | `AvplayMediaPlayer` + `BiliDashProxy` + Tizen 字幕叠加层 |
| 电视 UI | [`lib/tv/`](lib/tv/) | 首页、搜索、视频页、设置、D-pad 选项面板 |
| 共享改动 | `lib/pages/video/controller.dart`、`lib/plugin/pl_player/controller.dart`… | 增量式，`PlatformUtils.isTizen` 隔离 |

视频渲染在**原生硬件层**（挖洞叠加），因此 Flutter 只在其上绘制 UI/弹幕——这也是本应用采用 **Skia** 的原因（Impeller 的 GLES 后端会让密集的中文文字明显发虚，且它根本不参与硬件视频路径）。

## 编译与运行

前置条件：[`flutter-tizen`](https://github.com/flutter-tizen/flutter-tizen)（Flutter 3.44）、Tizen SDK，以及一台已开启开发者模式并通过 `sdb` 配对的 Tizen 9.0 电视。

```bash
# 一次性：让 sdb 连接电视
sdb connect <电视IP>:26101

# 调试（Skia——用于开发）
export LD_LIBRARY_PATH="$HOME/projects/tizen/tizen-libs:$LD_LIBRARY_PATH"
flutter-tizen run -d <电视IP>:26101 --dart-define=IS_TIZEN=true

# 发布（AOT 优化，Skia——日常安装用）
flutter-tizen run --release -d <电视IP>:26101 --dart-define=IS_TIZEN=true
# 或构建独立 TPK：
flutter-tizen build tpk --release --dart-define=IS_TIZEN=true
```

`--dart-define=IS_TIZEN=true` 设置编译期 `PlatformUtils.isTizen` 标志，从而进入电视 UI 与 AVPlay 引擎。请**不要**传入 `--enable-impeller`（原因见上文 Skia 说明）。

## 已知限制

- **8K** 被排除——S90F 解码器无法解码（它是 4K 级解码器）。
- **杜比视界**视频被排除（三星授权问题），改用 HDR10。Atmos 音频独立，在杜比视界投稿上同样可用。
- **Atmos 直通**到 eARC 音响取决于电视音频设置（eARC = 自动、数字输出 = 直通、Atmos 兼容 = 开）；电视内置扬声器解码 5.1 核心。
- 仅在 **S90F / Tizen 9.0** 上测试过；其他 Tizen 电视未验证。

---

## 声明

本项目基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 二次开发，仅用于学习与个人测试，请于下载后 24 小时内删除。所用 API 皆从官方网站收集，不提供任何破解内容。

上游脉络：[bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) → [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX) → [guozhigq/pilipala](https://github.com/guozhigq/pilipala)。感谢原作者们的开源精神。

## 致谢

- 上游 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 及其脉络
- [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen) 与 `video_player_avplay`
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)

## 许可证

[GPL-3.0](LICENSE)，继承自上游 PiliPlus。
