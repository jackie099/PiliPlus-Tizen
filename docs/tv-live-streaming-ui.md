# TV Live-Streaming UI — design spec (2026-07-20)

A 10-foot (D-pad / remote) live-streaming UI for the PiliPlus TV shell (`lib/tv/`),
reusing the mobile live stack with **zero controller/model/backend changes**.

## Decisions (signed off)

- **Danmaku bullets: default ON** (Right toggles off; it's the live culture).
- **v1 scope: Phases 1–3** — room + discovery tab + read-only chat rail.
- **Send-danmaku: deferred** (read-only; revisit after the rail ships — Tizen IME is risky).
- **Offline / not-live rooms: reuse the controller's existing dialog** (smoke-test its
  D-pad focusability on Tizen early; fall back to a TV view only if it's remote-dead).

## The keystone

One line makes every already-wired live entry (hot, search, history — all go through
`PageUtils.toLiveRoom(roomId)`) open a TV room, with no other routing work:

```dart
// lib/router/app_pages.dart:117  (mirrors the /videoV isTV branch at :88-90)
page: () => PlatformUtils.isTV ? const TvLiveRoomPage() : const LiveRoomPage(),
```

`roomId = Get.arguments` (bare int) contract is untouched.

## Playback

Live plays natively as **zero-byte HLS**, mirroring the VOD DASH win. A quick probe of
Bilibili's live formats (see `docs/tizen-tv-playback.md`) settled the approach:

- **FLV** (the mobile default) has **no Tizen demuxer** — the CAPI `general` engine
  rejects it with `PLAYER_ERROR_NOT_SUPPORTED_FORMAT`. Dead on this TV.
- **HLS-TS** demuxes (bundled `use_new_hls_mpegts_demuxer`) but its CDN edge
  (`ov-gotcha105`) was flaky/timeout-prone from every probe.
- **HLS-fMP4** (`.../index.m3u8`, fragmented-MP4 `.m4s` segments) demuxes natively **and**
  is served from a CDN host (`ov-gotcha207`) that does **not** enforce Referer
  anti-hotlinking — verified 200/206 with *and* without Referer across every quality
  tier (80–10000) and multiple rooms. FLV's host *does* enforce it (403 at some tiers),
  which is why VOD needed the libdash patch; live fMP4 needs **none**.

Routing the CDN m3u8 straight to the adaptive (PlusPlayer) engine as native HLS was
tried first and **does not work** — `libgsthls` is version-skewed against this
firmware and mis-negotiates the video caps (audio plays, video never starts). So does
re-expressing live as a dynamic DASH manifest. Both walls are documented in
`docs/tizen-tv-playback.md` §2.

What ships instead: the live fMP4 fragments are **welded into ONE continuous
progressive fMP4** by `BiliDashProxy` (`/live-prog/<token>.mp4`) and played on the
CAPI (`general`) engine, which sees a single growing file — no manifest, no live
edge, nothing to reload. Two Dart changes deliver it:

1. `live_room/controller.dart._initStreamIndex()` — on `PlatformUtils.isTV`, force the
   `http_hls`/`fmp4` variant (AVC-preferred) regardless of the mobile stream preference
   (`_selectLiveHlsFmp4()`); quality changes re-select it via `changeQn → queryLiveUrl`.
2. `avplay_media_player.open()` — a live `.m3u8` `videoUri` (only live yields one; VOD is
   dual-stream DASH or a durl MP4) routes to `urlForLiveProgressive` on the general
   engine, alongside the existing native-DASH and `/direct` byte-pump paths.

A **fast parallel initial burst** is load-bearing: the CAPI engine needs a solid buffer
immediately or it intermittently never latches. Pause/resume also has live-specific
semantics — resume must rejoin the live edge rather than continue a stalled pump; see
`docs/tizen-tv-playback.md` §3.

## TvLiveRoomPage (`lib/tv/pages/tv_live_room_page.dart`)

A `tv_video_page.dart` clone with VOD layers (scrubber, related row, up-next, end card)
removed. `Theme(TvTheme) > Scaffold(black) > Focus(root, autofocus, onKeyEvent) > Stack`:

1. **Player** — `Obx`: cover (`roomInfoH5.cover`) + scrim + spinner until `queryLiveUrl`
   resolves, then `PLVideoPlayer(maxWidth/Height: screen, plPlayerController:
   liveCtr.plPlayerController, headerControl: LiveHeaderControl(dormant, never raised),
   danmuWidget: LiveDanmaku(liveCtr, plPlayerController, isFullScreen:true, size:screen))`.
   `videoDetailController`/`introController` omitted (both optional). Portrait rooms:
   letterboxed fullscreen.
2. **Top pill** — always-on back glyph + red 直播 `TvChip` + `Obx(title)` (socket-updated).
3. **Bottom info bar** — auto-hide (`_controlsVisible` + `_hideTimer` + `_scheduleHide`,
   pinned while paused): play-state glyph, anchor uname, `watchedShow` count, 开播-elapsed
   `timeWidget`, `currentQnDesc` chip. **No progress bar** (nothing to scrub).
4. **SuperChat toast** — `Obx(fsSC)`: `SuperChatCard` (verbatim), self-expiring.
5. **Chat rail** — `Obx(_chatVisible)`: slides in from the right **over** the video
   (no resize), read-only auto-scrolling ticker bound to `liveCtr.messages` (uname +
   medal `TvChip` + text; SuperChat rows price-tinted). Bullets keep drawing beneath.
6. **Options** — `Obx(_optionsVisible)`: `TvLiveOptions`.
7. **Feedback pill** — transient 2 s "弹幕 开/关" toast on quick-toggle.

**Lifecycle:** `Get.put(LiveRoomController(heroTag), tag: heroTag)`; port the mobile
`playerListener` (live_room/view.dart:160-170): playing → `startLiveMsg()` +
`startLiveTimer()` + danmaku resume; paused → `closeLiveMsg()` + `cancelLiveTimer()`.
The controller does **not** self-start the socket — this port is mandatory. Port
`tv_video_page._watchBufferingForLag` (live CDN stalls the same way → nudge 刷新/清晰度).
No up-next/end-card/scrubber (existing scrub code self-guards on `isLive`).

## D-pad map

- **OK** = play/pause (`onDoubleTapCenter()`; pause also closes the socket via the listener)
- **Up / ContextMenu** = options panel
- **Down** = toggle chat rail
- **Right** = danmaku bullets quick-toggle (`plPlayerController.enableShowLiveDanmaku`) + feedback pill
- **Left** = peek chrome (never scrub, never switch qn — accidental-reinit guard)
- **Back** = dismiss rail → chrome → pop, in that order
- Chat rail is passive (no focus layer in v1); guard chain stays options → chat → base.
- Options panel owns its own Focus subtree (`tv_player_options.dart` pattern).

## Quality

Info bar shows `currentQnDesc`. Options 清晰度 row → submenu of `acceptQnList`
(already `({int code, String desc})`, the shape `TvOptionRow` wants); OK → `changeQn(code)`
(re-fetch + re-init under the buffering scrim). Recovery: 刷新 row (`queryLiveUrl`) + the
stall watchdog. Never on bare arrows.

## Discovery (`lib/tv/pages/tv_live.dart` + 直播 tab)

`Get.put(LiveController, tag:'tv-live')`; `Column[ _TvLiveFollowRow (正在直播的关注 from
LiveController.topState followItem, TvContinueRow pattern, hidden when empty/logged-out),
Expanded(TvFeedGrid<LiveCardList>) ]`. Cards via `TvVideoData.fromLiveCard(CardLiveItem)`
(title, cover: systemCover, ownerName: uname, viewText: watchedShow, isLive:true); a red
LIVE pill replaces the duration badge; `onOpen → PageUtils.toLiveRoom(roomid)`. Append a
`_TvTab(label:'直播', builder:(_)=>const TvLive())` to `tv_main.dart`. Area chips deferred.

## Build plan (v1 = Phases 1–3)

**Phase 1 — room**
- CREATE `lib/tv/pages/tv_live_room_page.dart` (~550 lines; transcribe tv_video_page, drop VOD layers).
- CREATE `lib/tv/widgets/tv_live_options.dart` (~200 lines; `tv_player_options` pattern: 弹幕开关, 弹幕不透明度, 清晰度 submenu, 刷新直播, 点赞).
- MODIFY `lib/router/app_pages.dart:117` (the keystone branch).
- MODIFY `lib/tv/tv_theme.dart` (live-badge red; chat rail reuses `commentsPanel*` dims).

**Phase 2 — discovery**
- CREATE `lib/tv/pages/tv_live.dart` (~60 lines; `tv_hot` template + follow row).
- MODIFY `lib/tv/models/tv_video_data.dart` (add `isLive`, `fromLiveCard`).
- MODIFY `lib/tv/widgets/tv_card_cover.dart` + `tv_data_video_card.dart` (LIVE pill + viewer icon).
- MODIFY `lib/tv/tv_main.dart` (append 直播 tab).

**Phase 3 — social**
- CREATE `lib/tv/widgets/tv_live_chat_panel.dart` (~250 lines; `tv_comments_panel` template, read-only).
- MODIFY `tv_live_room_page.dart` (rail layer + Down binding + SuperChat toast).

**Zero changes** to: `LiveRoomController`, `LiveController`, `PlPlayerController`,
`PLVideoPlayer`, `LiveDanmaku`, `SuperChatCard`, `PageUtils.toLiveRoom`, `TvOpen`, models.
No API/backend work.
