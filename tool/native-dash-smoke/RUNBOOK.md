# ⛔ FINAL VERDICT (2026-07-20): native Bilibili playback blocked by a NON-BUNDLED Samsung lib

Pursued BOTH the DASH path and a NEW **progressive/durl** path all the way down. Five
binary patches landed, each a real, verified fix — the native pipeline now works end
to end EXCEPT the very last stage, which lives in a platform library we don't ship
and can't re-sign. **Keep the `PlayerEngine.general` byte-pump for Bilibili playback.**

**The five landed patches (real infrastructure, reusable):**
1. `libdash` Referer (`e92e2d89`) — DASH-path CDN fetch, no 403.
2. `libgstmmhttpsrc` Referer v2 (`164ee41d`) — progressive-path CDN fetch; v2 fixes a
   `free(): invalid pointer` (the curl slist head wasn't re-nulled per request).
3. `libtracksource_tvplus` NULL-guard (`a46dc873`) — `HttpTrackSource::GstDemuxerNoMorePadsCb_`
   wired 3 fixed A/V/text slots with no NULL check; Bilibili's video-only m4s (empty
   audio/text slots) crashed it. Guard skips empty slots → both A+V wire cleanly.
4. `plusplayer.ini` `use_new_http_demuxer:true` → bundled clearkey-free `GstHttpDemux`
   (the system `libgstffmpeg` won't load — `libclearkey.so.0: Operation not permitted`).
5. `libgsthttpdemux` codec_data (`9320a038`) — `make_video_caps` built H.264 caps
   WITHOUT `codec_data`/`stream-format`/`alignment` (only the audio path attached
   codec_data); patch stamps `video/x-h264, …, stream-format=avc, alignment=au,
   codec_data=<avcC>`, matching the working `ffdemux_dash_mov`.

**The wall (proven on-device + by import analysis):** with all 5 patches, an on-device
`g_log` diagnostic injected into the demuxer prints `BILIHOOK fired H264` + `BILICAPS
cd=PRESENT` — i.e. the demuxer caps are now COMPLETE and spec-correct, and
`libtracksource` extracts codec_data into the platform `Track` without ever copying
NULL (it has a "No caps from pad" branch). Yet the player still stalls at 00:00 with
`gst_mini_object_copy(NULL)` → `gst_caps_get_structure GST_IS_CAPS failed` →
`<omx*dec:src>/<teeElement>/<*sink>` **segment-before-caps** → `GST_IS_CLOCK` →
`PlatformException(Pause/SetVolume)`. `gst_mini_object_copy`/`gst_caps_copy`/
`gst_buffer_copy` are imported by NONE of the durl-path bundled libs (only `libgstdash`,
unused for durl) → the NULL-caps copy + appsrc caps-ordering run inside the proprietary,
non-bundled **`libtrackrenderer.so`** (the appsrc→tee→omxdec pipeline builder).
Dailymotion works through the SAME TrackRenderer via `ffdemux_dash_mov` (SegmentTemplate),
so the residual difference is some caps-push timing/threading in `GstHttpDemux`'s async
path — unpatchable from the bundled libs. **No in-fork lever remains.**

Flags (all default-OFF, so zero behavior change): `BILI_NATIVE_DASH` (dual-stream DASH),
`BILI_NATIVE_VIDEO_ONLY` (diag), `BILI_NATIVE_PROGRESSIVE` (fragmented video-only m4s),
`BILI_NATIVE_DURL` (fnval=1 muxed contiguous mp4 — routes the raw CDN durl to the native
engine). Patch deliverables live OUTSIDE the repo: `~/projects/tizen/bilibili-referer-patch/`,
`bilibili-mmhttpsrc-patch/`, `bilibili-tracksource-patch/`, `bilibili-httpdemux-patch/`.
Diagnostic technique that finally worked on this dlog-disabled retail TV: inject
`g_log(G_LOG_LEVEL_CRITICAL, …)` into a binary patch — it writes to stderr unconditionally
(captured by `flutter-tizen run`), the only way to observe internal state (GST_CAPS debug
yields invalid-object errors; `gst_debug_log` with a private category is threshold-gated
silent; `sdb pull /usr/lib` is path-blocked).

---

# ⛔ EARLIER VERDICT (2026-07-19, DASH path): native DASH playback of Bilibili is INFEASIBLE on this engine

The Referer mechanism **works** (patched `libdash` → native engine fetches Bilibili
CDN segments directly, no 403, bytes reach the decoders — proven on-device). But
the native engine **cannot PREPARE** Bilibili's streams:

- Samsung's closed `libgstdash` `GstDashSrc` has a **stream-start-ordering bug** on
  the **byte-range single-file** path (`SegmentList`/`SegmentBase`): it pushes
  buffers/caps before emitting `stream-start` → caps rejected → `GST_IS_CAPS`/
  `GST_IS_CLOCK` NULL → prepare never completes → `setVolume`/`pause` throw.
- **Fails even for a single video stream** (`--dart-define=BILI_NATIVE_VIDEO_ONLY=true`),
  so it is NOT the dual video+audio topology.
- Our manifest is **byte-perfect** (verified against the real CDN file). Ruled out:
  DRM (clear → drm_type=0), the `need-data-video` "invalid signal" (benign), cert.
- Dailymotion works because it feeds **separate-file `SegmentTemplate`** (different,
  working `GstDashSrc` path). Bilibili serves one file per stream → byte-range only
  → always hits the bug. The engine-accepted shape needs per-fragment URLs = a Dart
  byte-pump (defeats the goal).

**→ Keep the existing `PlayerEngine.general` byte-pump for Bilibili separate-A/V.**
The only zero-byte avenue left is a second binary patch to `libgstdash` to inject the
missing `stream-start` event — deep/high-risk, future only. This branch stays a
flag-gated (default-OFF) spike + the proven `libdash` patch tooling.

On-device log capture that works on this retail S90F (dlog disabled): push
`/home/owner/share/tmp/sdk_tools/<appid>.rpm` with `--tizen-logging-port P`, `sdb
forward tcp:P tcp:P`, launch via **`sdb shell 0 execute <appid>`** (NOT `sdb launch`),
read the TCP socket yourself (debug builds only).

---

# Native-DASH smoke test — does the Referer-patched `libdash` work on PiliPlus?

Goal: prove, **on PiliPlus specifically**, that the native adaptive-streaming
engine + a Referer-patched `libdash.so` can fetch Bilibili CDN segments directly
(no Dart byte-pump). Success here green-lights the full overhaul.

This branch adds a **debug-flagged** native path; with the flag OFF (the default)
PiliPlus behaves exactly as before. Nothing here is production wiring — the
release delivery is the app-owned `Runner.csproj` overlay (a later step).

## What the flag does

`kBiliNativeDash` (`lib/plugin/pl_player/engine/bili_dash_proxy.dart`):
- **OFF (default):** manifest `<BaseURL>` = loopback `/seg/*`, engine = `general`
  (today's byte-pump). Unchanged behavior.
- **ON:** for dual-stream DASH, manifest `<BaseURL>` = the **real Bilibili CDN
  url**, only the ~2 KB manifest is served over loopback, engine =
  `adaptiveStreaming`, UA/Cookie via `streamingProperty`. Referer comes from the
  patched `libdash`. (Single-url `/direct/` sources stay on the byte-pump.)

Enable via `--dart-define=BILI_NATIVE_DASH=true`. If your build flow drops
dart-defines, edit the `defaultValue` to `true` in that file.

## 0. Prerequisite — patch the bundled `libdash` (already done on this host)

The pub-cache libdash for 6.5/7.0/8.0/9.0 is already patched to `e92e2d89`
(backups saved next to each). On any OTHER build host, run:

```bash
tool/native-dash-smoke/patch_pubcache_libdash.sh          # apply (backs up originals)
tool/native-dash-smoke/patch_pubcache_libdash.sh --restore # revert to stock
```

⚠️ The pub-cache git checkout is **shared with the Dailymotion app** — `--restore`
before building Dailymotion (it must stay unpatched).

## 1. Build (signed, debug, native flag ON)

```bash
# --dart-define=IS_TIZEN=true is MANDATORY (see TIZEN_BUILD.md): without it,
# main.dart runs MediaKit.ensureInitialized() (libmpv, absent on Tizen) and the
# app CRASHES at startup — the launcher just spins forever, pre-Flutter.
flutter-tizen build tpk --debug -s jackie \
  --dart-define=IS_TIZEN=true --dart-define=BILI_NATIVE_DASH=true
```

`build tpk -s` re-signs, so the patched `libdash` is covered by the signature.

**Reading logs on the retail S90F:** `sdb dlog`/`sdb shell` are firmware-disabled
(`sdb capability` → `log_enable:disabled`, `intershell_support:disabled`), so the
device-log commands below return nothing. To see `[BILI-NATIVE-DASH]` + player
errors, use the attached run (streams `debugPrint` over the VM service):
```bash
flutter-tizen run -d <ip>:26101 --debug \
  --dart-define=IS_TIZEN=true --dart-define=BILI_NATIVE_DASH=true
```
Launch is via `sdb launch -p com.example.piliplus -e Runner.dll -m run` (shell is
disabled). Release mode does NOT stream over the logging port — use `--debug`.

## 2. Confirm the TPK actually embeds the patched `libdash` (before install)

```bash
unzip -p build/tizen/tpk/*.tpk lib/libdash.so | sha1sum
# EXPECT: e92e2d890849063409033f62893c8a8d2ce794fc   (patched)
#   0823879e… = stock slipped in (patch/overlay didn't take) -> fix before installing
```

## 3. Install

```bash
sdb install build/tizen/tpk/*.tpk       # or: flutter-tizen install -s jackie
```

## 4. Verify on device

Play a **normal multi-quality video** (those use dual-stream DASH; a durl-only /
audio-only title won't exercise the native path).

**a) Did native mode engage? (device logs)**
```bash
sdb dlog | grep -i "BILI-NATIVE-DASH"
# expect: [BILI-NATIVE-DASH] manifest BaseURLs -> v=https://...bilivideo... a=https://...
#         [BILI-NATIVE-DASH] open on adaptiveStreaming engine; manifest url=http://127.0.0.1:...
# (no lines -> the dart-define didn't propagate; flip defaultValue and rebuild)
```

**b) Is the APP's `libdash` the one loaded? (the install-path glob gate)**
```bash
sdb shell
# on device — find the pid, then:
ps -ef | grep -i pili                    # or: pidof Runner.dll / the dotnet launcher
cat /proc/<PID>/maps | grep -i libdash
# EXPECT a mapping under the APP path, e.g.
#   /opt/usr/apps/com.example.piliplus/lib/libdash.so
#   (or /opt/usr/home/owner/apps_rw/com.example.piliplus/lib/libdash.so)
# NOT present, or a /usr/lib/... path -> the --gst-plugin-load glob missed PiliPlus's
#   install location (see bilibili-referer-patch DEPLOYMENT-GATES §2) -> fix packaging first.
```
Confirm it's the PATCHED copy:
```bash
sdb pull /opt/usr/apps/com.example.piliplus/lib/libdash.so /tmp/dev-libdash.so
sha1sum /tmp/dev-libdash.so   # EXPECT e92e2d89…
```

**c) The real proof — does it play?** If a dual-stream title plays past a few
seconds with native mode ON, the CDN accepted the request → the patched
`libdash` attached the Referer → **segments went 403→200 natively on PiliPlus.**
That is the whole thesis proven. A prepare/load error (watch `sdb dlog` for the
player error) means the Referer isn't reaching the wire or the engine isn't using
this `libdash` — cross-check (a) and (b).

## 5. Baseline A/B (optional but clarifying)

Rebuild **without** `--dart-define` (byte-pump) and confirm the same title plays.
That isolates "native path broke" from "this title is just broken."

## 6. Cleanup

```bash
tool/native-dash-smoke/patch_pubcache_libdash.sh --restore   # stock libdash back
```
(The flag defaults OFF, so even a patched cache + this branch = normal behavior
unless you pass the dart-define.)

## Pass / fail summary

| Observed | Meaning |
|---|---|
| native title plays; `libdash` maps to app path (patched sha) | ✅ mechanism works on PiliPlus — proceed to full overhaul (Part B) |
| no `[BILI-NATIVE-DASH]` logs | dart-define didn't propagate → flip `defaultValue`, rebuild |
| logs present, `libdash` NOT in `/proc/maps` | install-path glob miss OR adaptive engine didn't load libdash → packaging/engine issue |
| `libdash` mapped, but prepare 403/errors | Referer not reaching wire (patch/site) — capture the player error, cross-check the sha of the mapped lib |
