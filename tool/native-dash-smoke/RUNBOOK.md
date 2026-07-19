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
