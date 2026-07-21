# Tizen TV playback: what works and what doesn't

*Consolidated engineering record for the PiliPlus Tizen/TV fork. Replaces the
per-attempt commits and the old native-DASH-smoke runbook. Target device:
retail Samsung S90F, Tizen 9.0, PlusPlayer + GStreamer, `video_player_avplay`.*

Two playback paths are confirmed working on-device. Everything else in this
document is a dead end that was pursued to a hard platform wall; it is recorded
so nobody re-walks it.

---

## 1. What works

Both paths enter through `AvplayMediaPlayer.open()`
(`lib/plugin/pl_player/engine/avplay_media_player.dart:233`), which classifies
the source into exactly three shapes:

| shape | test | proxy route | engine |
|---|---|---|---|
| VOD dual-stream DASH | `effective.hasSeparateAudio` (`:261`) | `/mpd/<token>.mpd` | `PlayerEngine.adaptiveStreaming` |
| LIVE | `videoUri.contains('.m3u8')` (`:271`) | `/live-prog/<token>.mp4` | `PlayerEngine.general` (CAPI) |
| everything else (durl MP4, audio-only) | fallthrough | `/direct/<token>.mp4` | `PlayerEngine.general` |

`adaptive = nativeDash` only (`:275`) — **live does not run on the adaptive
engine.** Everything is served from `BiliDashProxy`, a loopback `HttpServer` on
an ephemeral port (`bili_dash_proxy.dart:77-93`); nothing leaves `127.0.0.1`.

### 1a. VOD — native zero-byte DASH

`BiliDashProxy.urlFor()` (`bili_dash_proxy.dart:111-146`) registers the source
and returns `/mpd/<token>.mpd`. `_serveMpd()` (`:256-284`) probes each stream's
leading `init`+`sidx` region once, then `_buildMpd()` synthesizes a ~2 KB
`type="static"` manifest whose two `AdaptationSet` `<BaseURL>`s are the **real
Bilibili CDN urls**. The adaptive (PlusPlayer) engine then fetches every media
byte itself. **Zero media bytes pass through Dart.**

Two non-obvious constraints make it work — and both are load-bearing:

**(i) The Referer-patched `libdash.so`.** The Bilibili video CDN returns `403`
without `Referer: https://www.bilibili.com`, and the adaptive engine ignores
`httpHeaders` (it honors only User-Agent and Cookie, and only via
`streamingProperty` — `avplay_media_player.dart:312-330`). The Referer is
therefore injected by a **binary patch to the bundled `libdash.so`**
(patched sha1 `e92e2d89…`, stock `0823879e…`). The patch tooling lives outside
this repo (`~/projects/tizen/bilibili-referer-patch/`); the pub-cache helper was
`tool/tizen-libdash-patch/patch_pubcache_libdash.sh`. Verify before installing:
`unzip -p build/tizen/tpk/*.tpk lib/libdash.so | sha1sum`. The pub-cache
checkout is shared with the Dailymotion app, which must stay on stock libdash.

**(ii) The manifest must be `<SegmentList>`-shaped, never `<SegmentBase
indexRange>`.** Samsung's closed `GstDashSrc` routes the on-demand single-blob
`SegmentBase` shape through an appsrc-style push path it does not implement
(device log: `signal 'need-data-video' is invalid for instance of type
'GstDashSrc'`); buffers reach the demuxer pads before the mandatory
`stream-start → caps → segment` events and prepare never completes. So
`_writeSegmentList()` (`bili_dash_proxy.dart:1079-1103`) parses the stream's own
`sidx` (`_parseSidx`, `:873`) and enumerates every internal `moof`+`mdat`
fragment as an explicit `<SegmentURL mediaRange>` plus a `<SegmentTimeline>` in
the sidx timescale. Each `mediaRange` becomes an ordinary HTTP Range request the
engine issues straight at the CDN `BaseURL`. This is the same enumerated
machinery Dailymotion proved on this engine via `SegmentTemplate`. Degenerate
case (no usable sidx): the whole file becomes ONE enumerated segment — still
list-shaped, still the good path. `mediaPresentationDuration` (sidx sum, else
Bilibili's `timelength`) is also required, or the demuxer stalls instead of
building a timeline.

**(iii) The Dart lifecycle guard.** This was the real final blocker and it is
easy to reintroduce. After `initialize()`, the awaited `seek/setVolume/rate/
play` tail can throw `PlatformException(SetVolume)` inside the PlusPlayer preroll
window. If that throw escapes `open()`, it hits
`PlPlayerController._createVideoController`'s catch → `dataStatus=error`,
skipping the success tail (`dataStatus=loaded` / `_initializePlayer` / `onInit`),
so `videoState` never flips true and the view keeps the cover+spinner — **video
decodes and audio plays the whole time, just never displayed.** The tail is
therefore wrapped in `on PlatformException catch` (publish, no rethrow) at
`avplay_media_player.dart:377-398`, while a genuine load failure still rethrows
from the separate `initialize()` try/catch at `:350-360`. Because the throw is
itself a race, removing this guard produces the classic misleading symptom
"some videos work, changing CDN sometimes helps".

**Minimal working stack, verified by stripping each patch on-device: exactly
those two artifacts — the `libdash` Referer patch and the Dart guard.** Proven
UNNECESSARY and removed: the `libgstmmhttpsrc` Referer patch, the
`libtracksource_tvplus` NULL-guard, the `libgsthttpdemux` codec_data patch, the
`plusplayer.ini use_new_http_demuxer:true` flag, and the entire `durl`
(`BILI_NATIVE_DURL`) path. Coverage: H.264, H.265, AV1, 4K, HDR, all qualities.

### 1b. LIVE — HLS → progressive fMP4 concat on the CAPI engine

Bilibili live is a **single MUXED fMP4 stream**. On TV,
`LiveRoomController._initStreamIndex()` (`lib/pages/live_room/controller.dart:256-289`)
forces the `http_hls` / `fmp4` variant, AVC-preferred, via `_selectLiveHlsFmp4()`
(`:297-311`), overriding the mobile FLV-first preference. Quality changes
re-select it through `changeQn → queryLiveUrl`.

`open()` sees the `.m3u8` and calls `urlForLiveProgressive()`
(`bili_dash_proxy.dart:153-172`) → `/live-prog/<token>.mp4`.
`_serveLiveProgressive()` (`:339-439`) then **welds the live fragments into ONE
continuous growing fMP4**: the `EXT-X-MAP` init (`ftyp`+`moov`) exactly once and
first (`:378-385`), then every media fragment in order as it appears, polling the
upstream playlist every 900 ms (`:431`) until the client hangs up (`:352-353`).

Why this works where every manifest-based approach failed: **the player never
sees a manifest, a segment boundary, or a live edge.** It believes it is reading
one progressive file, exactly like a durl MP4 on the `/direct` byte-pump — so
there is nothing for `GstDashSrc` to reload and nothing to re-prepare mid-stream.
The `.mp4` suffix on the loopback url matters too: an extensionless url can stall
GStreamer's demuxer selection (`:143-145`).

**The non-obvious constraint: the fast PARALLEL initial burst.** The CAPI
(`general`) engine needs a solid buffer *immediately* or it intermittently never
latches (the "no decode" failure). So the first pass fetches the **entire current
playlist window with `Future.wait`** and bursts it in order behind the init
segment, followed by a single `flush()` (`:389-411`); only the steady state
fetches one fragment at a time (`:412-423`). Serializing that first window
reintroduces the intermittent no-latch. Do not "simplify" it.

No Referer patch is needed here: the live fMP4 CDN host (`ov-gotcha207` family)
does not enforce anti-hotlinking — verified 200/206 with and without Referer
across every quality tier and multiple rooms. The proxy attaches Referer +
User-Agent anyway (`_fetchBytes` `:443-470`, `_fetchText` `:475-502`).

---

## 2. Rejected approaches

### 2a. Native HLS via `libgsthls` — dead (version skew)

**Tried:** play the live `.m3u8` directly on the adaptive (PlusPlayer) engine, no
proxy at all — the shape described in `docs/tv-live-streaming-ui.md:41-54`.

**How far it got:** `libgsthls.so` would not even `dlopen`. It has
`RPATH $ORIGIN` and a load-time `DT_NEEDED` on `libclearkey.so.0`, and the
firmware's real `libclearkey.so.0` is EPERM-blocked (`Operation not permitted`)
to the app. That was fixed properly: an app-owned **stub `libclearkey.so.0`**
(`tizen/lib-overlay/stub_clearkey.c`, six no-op symbols) shipped into the tpk's
`lib/` beside the bundled GStreamer plugins by a `TizenTpkUserIncludeFiles`
overlay in `tizen/Runner.csproj:19-31`. Bilibili live HLS is unencrypted, so the
symbols only need to *resolve* at dlopen; they are never called. With the stub,
`libgsthls` loads.

**The wall:** the bundled `libgsthls` is **version-skewed against this firmware's
PlusPlayer** and mis-negotiates the video caps — audio decodes cleanly, video
never starts (`bili_dash_proxy.dart:178-180`, `:1270`). The MPEG-TS variant
(`use_new_hls_mpegts_demuxer`) demuxes, but its CDN edge (`ov-gotcha105`) was
flaky/timeout-prone from every probe, so it is not a usable fallback either.

**Why not retry:** the defect is inside a bundled binary whose ABI expectations
do not match the firmware's player. There is no in-fork lever — the app cannot
supply a matching `libgsthls`, and a binary patch would have to reconstruct caps
negotiation rather than flip a flag. The progressive concat (1b) delivers the
same result with pure Dart.

### 2b. HLS → dynamic-DASH remux for live — dead (re-prepare at the live edge)

**Tried:** re-express the live HLS media playlist as a **dynamic** DASH manifest
so live would run through the *working* `libgstdash` path that VOD uses.
Symbols: `urlForLiveHls()` (`bili_dash_proxy.dart:188-207`), route `/live-mpd/`
(`:237-239`), `_serveLiveMpd()` (`:299-332`), `_accumulateLiveSegs()`
(`:528-576`), `_buildLiveMpd()` (`:582-681`), and the `_ProxyEntry` live-DASH
fields (`liveSegs`, `liveAnchorSeq`, `liveAvailStart`, `liveInitUrl`,
`liveSegSec`, `liveMpdFetches` — `:1291-1311`).

**How far it got: further than anything else — it actually decoded.** Getting
there required solving several real problems, all of them correctly:

- **Timeline continuity.** The engine refetches the manifest every
  `minimumUpdatePeriod`; each regeneration must place the same segment at the
  same timeline `t` or playback restarts. Anchored once on the first-seen
  `EXT-X-MEDIA-SEQUENCE` with a pinned `availabilityStartTime`, so global seq `K`
  maps to `t = (K - anchorSeq) * segTicks` forever (`:504-523`, `:558-566`).
- **Enumerated `<SegmentTimeline>`, never a `duration` attribute** — same
  `GstDashSrc` `need-data-video` trap as VOD (`:520-523`).
- **`<UTCTiming urn:mpeg:dash:utc:direct:2014>`** pinned to the same device
  clock used to compute AST, so availability math survives a skewed TV RTC
  (`:632-635`).
- **Live-edge collision avoidance**, in three layers: pre-warm ~28 s of DVR
  before the first manifest is served (`:305-318`); withhold the newest 5
  fragments from the *published* manifest (`:590-597`); start the player ~18 s
  behind that via `suggestedPresentationDelay` (`:603-607`).
- `StreamingPropertyType.isLive: 'TRUE'` so PlusPlayer treats the finite,
  DVR-windowed timeline as an unbounded live edge instead of a seekable VOD —
  otherwise it reports `position == end` and the replay guard fires a `seekTo(0)`
  that fails on a non-rewindable stream (`avplay_media_player.dart:323-328`).

**The wall:** with all of that, the stream decodes — and then, on reaching the
live edge, **PlusPlayer re-prepares its pipeline and the video caps come up
corrupt**, inside the proprietary, non-bundled `libtrackrenderer.so` (the
appsrc→tee→omxdec pipeline builder). `gst_mini_object_copy` / `gst_caps_copy` /
`gst_buffer_copy` are imported by none of the bundled libs on that path, so the
NULL-caps copy and the caps-ordering happen where the fork cannot reach.
`avplay_media_player.dart:266-269` records the verdict: *"decodes but re-prepares
its pipeline at the live edge and the video caps come up broken on this closed
firmware."*

**Why not retry:** every knob on our side of the boundary was already turned —
timeline anchoring, DVR depth, withholding, presentation delay, UTC pinning,
`isLive`. The failure is a re-prepare inside a closed binary triggered by the
manifest path itself. The progressive concat sidesteps the entire class of
problem by removing the manifest.

### 2c. Live FLV — dead (no demuxer on this TV)

**Tried:** the mobile default. Bilibili live serves FLV first.

**The wall:** there is no FLV demuxer on this TV. The CAPI `general` engine
rejects it with `PLAYER_ERROR_NOT_SUPPORTED_FORMAT`
(`docs/tv-live-streaming-ui.md:32-34`). Separately, the FLV CDN host *does*
enforce Referer anti-hotlinking (403 at some tiers), so even a working demuxer
would have needed header injection.

**Why not retry:** a missing platform demuxer is not something an app can fix.
This is precisely why `_selectLiveHlsFmp4()` exists.

### 2d. VOD `SegmentBase` / byte-range DASH, and the `durl` progressive path

Recorded for completeness. `SegmentBase indexRange` (the natural shape for
Bilibili's one-file-per-stream layout) always hits the `GstDashSrc`
stream-start-ordering bug described in §1a(ii) — this is what motivated the
`<SegmentList>` rewrite, and it is why an early verdict wrongly declared native
DASH "infeasible". The separate `BILI_NATIVE_DURL` progressive path (fnval=1
muxed contiguous MP4, with `libgstmmhttpsrc` Referer + the `use_new_http_demuxer`
ini flag) also works, but DASH is simpler and covers all codecs/qualities, so
durl is moot and its scaffolding was removed.

---

## 3. Live pause/resume semantics

**Pause cannot mean "pause" on a welded progressive stream, and resume must
rejoin the live edge.** Rationale, from `lib/tv/pages/tv_live_room_page.dart:226-251`:

The player believes `/live-prog` is one continuous growing file. When it pauses,
it stops draining the loopback socket, so **the pump stalls mid-`flush()`** while
the live stream rolls on. The fragments it would append on resume carry a
`baseMediaDecodeTime` a full pause-length ahead of the last welded byte, and a
PTS-synced sink **waits that gap out in real time** — the picture stays frozen
for exactly as long as you paused. There is no seek to skip it: the stream is not
rewindable and has no timeline the player can address.

So `_togglePlayPause()` is asymmetric:
- **pause** → `PlPlayerController.pause()`;
- **resume** → `liveCtr.queryLiveUrl()` — the same path as 刷新直播: fresh token,
  fresh parallel burst, restart at the current live edge, auto-play. Guarded by
  `if (playerCtr.processing) return` so a double-press cannot run two overlapping
  `setDataSource` calls.

Three supporting invariants, all required:

1. **For live the app is the single source of truth for play-state.** The CAPI
   engine emits a spurious `playing=false` while still decoding, and a later
   `playing=true` that would clobber a genuine user pause. `playingStream` is
   therefore ignored entirely for live — `if (isLive) return` at
   `lib/plugin/pl_player/controller.dart:954`. Suppressing only the `false` half
   leaves `playerStatus` desynced and puts the OK toggle one press out of phase,
   which reads to the user as "play/pause doesn't work".
2. **`play()`/`pause()` must fan out themselves.** Since `playingStream` is
   ignored, `_notifyLiveStatus()` (`controller.dart:1210-1216`, called from
   `play()` `:1200` and `pause()` `:1222`) drives the status listeners — that
   fan-out is what stops/starts the danmaku, the 开播 elapsed timer and the chat
   socket. No-op for VOD.
3. **Never latch `completed` for live** (`controller.dart:1358`, `if (!isLive &&
   isCompleted)`): latching sends the toggle down the VOD replay path (seek to
   zero) on a non-rewindable stream, after which playback can never restart.

---

## 4. Debugging on a retail TV

The retail S90F is far more locked down than a dev unit; several standard
techniques silently return nothing rather than failing loudly.

- **`dlog` is disabled in firmware.** `sdb capability` reports
  `log_enable:disabled`, so `sdb dlog | grep …` prints nothing — an empty grep is
  *not* evidence the code didn't run. Read logs instead over the VM service with
  an attached run: `flutter-tizen run -d <ip>:26101 --debug --dart-define=IS_TIZEN=true`
  (release mode does not stream over the logging port).
- **`IS_TIZEN=true` is mandatory on every build/run.** Without it `main.dart`
  calls `MediaKit.ensureInitialized()` (libmpv, absent on Tizen) and the app
  crashes pre-Flutter — the launcher just spins forever, which looks like a hang,
  not a crash.
- **The video overlay is hole-punched and INVISIBLE to screenshots.** The
  Flutter-layer screenshot tool captures only the Flutter surface, so *working*
  video renders as a black rectangle. This directly caused a wrong
  "no playback / platform wall" verdict that stood for two commits. **Never
  conclude "no playback" from a screenshot — ask the human in front of the TV.**
- **`sdb shell` is blocked** (`intershell_support:disabled`), and
  `sdb pull /usr/lib/...` is path-blocked. So `/proc/<pid>/maps` checks and
  pulling firmware libs for inspection are unavailable; verify the shipped
  `libdash.so` from the **tpk** before install
  (`unzip -p build/tizen/tpk/*.tpk lib/libdash.so | sha1sum`), not from the
  device.
- **To read state inside a native lib, inject `g_log(G_LOG_LEVEL_CRITICAL, …)`
  into a throwaway binary patch.** It writes to stderr unconditionally and is
  captured by `flutter-tizen run`. `GST_DEBUG`-style logging yields
  invalid-object errors, and `gst_debug_log` with a private category is
  threshold-gated silent. This is what finally produced the `BILIHOOK fired
  H264` / `BILICAPS cd=PRESENT` evidence.
- **The TV's IP is DHCP-assigned and changes.** Re-run `sdb connect <TV_IP>:26101`
  and re-check the `-d` argument before blaming the build; a stale IP looks like a
  deploy failure.
- **Beware log-shaped red herrings.** The `segment before caps` /
  `gst_mini_object_copy(NULL)` ordering was chased for hours before a diff proved
  it **byte-identical on a working and a failing open**. When a log pattern
  appears on both, it is not the cause. Diff working-vs-failing before theorizing.

---

## Appendix: symbol map

**Load-bearing (do not "simplify" these away):**
`urlFor`, `_serveMpd`, `_buildMpd`, `_writeSegmentList`, `_parseSidx`,
`_probeIndexed`, route `/mpd/`; `urlForLiveProgressive`, `_serveLiveProgressive`,
`_fetchBytes`, `_fetchText`, route `/live-prog/`; `_serveDirect`, `_proxy`,
route `/direct/`; `_ProxyEntry.isLiveHls` (gate-checked by
`_serveLiveProgressive`).

Two traps in particular: `_fetchText`/`_fetchBytes` were shared by the dead remux
AND the working live pump — deleting them with the remux breaks live playback.
And the `[LIVE-PROG] init+burst` `debugPrint` looks like leftover spike logging,
but on a TV with dlog disabled it is the ONLY evidence that the fragile parallel
initial burst fired. It stays.

**Removed** (this is the code the document above replaces — the reasoning is
preserved here so nobody rebuilds it):
`urlForLiveHls`, `_serveLiveMpd`, `_accumulateLiveSegs`, `_buildLiveMpd`, route
`/live-mpd/`, and the `_ProxyEntry` fields `liveSegs`, `liveAnchorSeq`,
`liveAvailStart`, `liveMpdFetches`, `liveInitUrl`, `liveSegSec` (§2b);
`tizen/lib-overlay/` (`libclearkey.so.0`, `stub_clearkey.c`) plus its
`ItemGroup` in `tizen/Runner.csproj` (§2a); and the unreachable
`StreamingPropertyType.isLive` entry in `avplay_media_player.dart`, which only
ever applied to the remux (`streamingProperty` is built only when `adaptive`, and
live is never adaptive).

**Kept deliberately:** `tool/tizen-libdash-patch/patch_pubcache_libdash.sh`. That
is NOT failed-experiment debt — the working VOD DASH path still requires the
Referer-patched `libdash.so`, and this script is the only in-repo record of how
to reproduce a working build.
