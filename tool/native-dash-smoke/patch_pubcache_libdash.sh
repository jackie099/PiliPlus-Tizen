#!/usr/bin/env bash
# =============================================================================
# patch_pubcache_libdash.sh — apply (or restore) the Bilibili Referer patch to
# PiliPlus's bundled libdash.so IN PLACE in the resolved pub-cache git checkout.
#
# This is the "for now" delivery for the native-DASH SMOKE TEST (the release
# build will instead ship the patched .so via an app-owned Runner.csproj overlay
# so the shared cache stays pristine). Because the pub-cache git checkout is
# SHARED by every app resolving the same url+ref (the Dailymotion sibling
# resolves the SAME directory), this patches the cache globally:
#   -> RESTORE before building the Dailymotion app.  ./patch_pubcache_libdash.sh --restore
#
# Only the sha1 0823879e build (Tizen 6.5/7.0/8.0/9.0) is patchable; 6.0/10.0
# are different builds and are skipped (they'd need separate reverse-engineering).
# =============================================================================
set -euo pipefail

PLUG="${PLUG:-$HOME/.pub-cache/git/plugins-7ffc99f76631d0f4551ec9da271afebab6ee69e7/packages/video_player_avplay}"
PATCH_PKG="${PATCH_PKG:-$HOME/projects/tizen/bilibili-referer-patch}"
PATCHED_SO="$PATCH_PKG/patch/libdash.patched.so"

STOCK_SHA="0823879eaab6189dc3b0f9c9d116bff60ff9fd6b"
PATCHED_SHA="e92e2d890849063409033f62893c8a8d2ce794fc"
VERSIONS=(6.5 7.0 8.0 9.0)

MODE="apply"
[ "${1:-}" = "--restore" ] && MODE="restore"

sha1() { sha1sum "$1" | cut -d' ' -f1; }

[ -d "$PLUG" ] || { echo "FATAL: plugin path not found: $PLUG"; exit 1; }
if [ "$MODE" = "apply" ]; then
  [ -f "$PATCHED_SO" ] || { echo "FATAL: patched .so not found: $PATCHED_SO"; exit 1; }
  [ "$(sha1 "$PATCHED_SO")" = "$PATCHED_SHA" ] || { echo "FATAL: $PATCHED_SO is not the expected e92e2d89 build"; exit 1; }
fi

echo "== mode: $MODE =="
for v in "${VERSIONS[@]}"; do
  tgt="$PLUG/tizen/lib/armel/$v/libdash.so"
  bak="$tgt.orig-$STOCK_SHA"
  [ -f "$tgt" ] || { echo "  armel/$v: (absent, skip)"; continue; }
  cur="$(sha1 "$tgt")"

  if [ "$MODE" = "restore" ]; then
    if [ -f "$bak" ]; then
      cp -f "$bak" "$tgt"
      echo "  armel/$v: restored  -> $(sha1 "$tgt")"
    elif [ "$cur" = "$STOCK_SHA" ]; then
      echo "  armel/$v: already stock ($STOCK_SHA)"
    else
      echo "  armel/$v: WARN no backup and sha=$cur (leaving as-is)"
    fi
    continue
  fi

  # apply
  case "$cur" in
    "$PATCHED_SHA") echo "  armel/$v: already patched ($PATCHED_SHA)";;
    "$STOCK_SHA")
      [ -f "$bak" ] || cp -f "$tgt" "$bak"        # one-time pristine backup
      cp -f "$PATCHED_SO" "$tgt"
      new="$(sha1 "$tgt")"
      [ "$new" = "$PATCHED_SHA" ] || { echo "  armel/$v: FATAL post-patch sha=$new"; exit 1; }
      echo "  armel/$v: PATCHED   -> $new  (backup: $(basename "$bak"))";;
    *) echo "  armel/$v: SKIP not the patchable build (sha=$cur)";;
  esac
done
echo "== done =="
