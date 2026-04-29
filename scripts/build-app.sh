#!/usr/bin/env bash
# Build a signed GitChop.app bundle for local development.
#
# v0.1 only does the local-dev path: build with swift-pm, wrap in a
# .app, ad-hoc sign, install to /Applications. Notarize/DMG/appcast
# come in scripts/release.sh once the app is past MVP.
#
# Usage:
#   scripts/build-app.sh                    # build, ad-hoc sign, install + launch
#   INSTALL=0 scripts/build-app.sh          # build to build/GitChop.app, don't install
#   SIGN_IDENTITY="Developer ID Application: Benjamin Dansby (8CYGCS6F34)" scripts/build-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="GitChop"
BUNDLE_ID="com.bendansby.GitChop"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # ad-hoc by default
INSTALL="${INSTALL:-1}"

echo "==> Building release binary (universal)"
swift build -c release --arch arm64 --arch x86_64

BUILD_DIR=".build/apple/Products/Release"
BIN="$BUILD_DIR/$APP_NAME"
[[ -f "$BIN" ]] || { echo "!! Expected $BIN after swift build" >&2; exit 1; }

# Stage in /tmp so iCloud File Provider xattrs don't poison codesign.
STAGE="$(mktemp -d -t GitChop-build)"
trap 'rm -rf "$STAGE"' EXIT
APP_DIR="$STAGE/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

ditto --noextattr --noacl "$BIN" "$CONTENTS/MacOS/$APP_NAME"
ditto --noextattr --noacl "Resources/Info.plist" "$CONTENTS/Info.plist"

# ── Sparkle framework ────────────────────────────────────────────────
# SwiftPM resolves Sparkle as a binary XCFramework but doesn't copy the
# framework bundle into the .app for us. We pull it out of the resolved
# artifacts and embed under Contents/Frameworks/Sparkle.framework. The
# macos-arm64_x86_64 slice covers both architectures the universal
# binary above is built for.
SPARKLE_XCFW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"
SPARKLE_SRC="$SPARKLE_XCFW/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "==> Resolving Sparkle (first build only)"
    swift package resolve >/dev/null
fi
[[ -d "$SPARKLE_SRC" ]] || { echo "!! Sparkle.framework not found at $SPARKLE_SRC" >&2; exit 1; }
ditto --noextattr --noacl "$SPARKLE_SRC" "$CONTENTS/Frameworks/Sparkle.framework"

# AppIcon: build/AppIcon.icns from Icon.png if present (regenerated when
# the PNG is newer). Skipped silently if no source PNG yet — the app
# will just show the Mac generic icon, fine for MVP.
if [[ -f Icon.png ]]; then
    if [[ ! -f build/AppIcon.icns || Icon.png -nt build/AppIcon.icns ]]; then
        echo "==> Rebuilding AppIcon.icns from Icon.png"
        mkdir -p build
        ICONSET=build/AppIcon.iconset
        rm -rf "$ICONSET"
        mkdir -p "$ICONSET"
        sips -z 16 16     Icon.png --out "$ICONSET/icon_16x16.png"     >/dev/null
        sips -z 32 32     Icon.png --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
        sips -z 32 32     Icon.png --out "$ICONSET/icon_32x32.png"     >/dev/null
        sips -z 64 64     Icon.png --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
        sips -z 128 128   Icon.png --out "$ICONSET/icon_128x128.png"   >/dev/null
        sips -z 256 256   Icon.png --out "$ICONSET/icon_128x128@2x.png">/dev/null
        sips -z 256 256   Icon.png --out "$ICONSET/icon_256x256.png"   >/dev/null
        sips -z 512 512   Icon.png --out "$ICONSET/icon_256x256@2x.png">/dev/null
        sips -z 512 512   Icon.png --out "$ICONSET/icon_512x512.png"   >/dev/null
        cp Icon.png "$ICONSET/icon_512x512@2x.png"
        iconutil -c icns "$ICONSET" -o build/AppIcon.icns
    fi
    cp build/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist"
fi

xattr -cr "$APP_DIR"

echo "==> Signing (identity: $SIGN_IDENTITY)"
# Hardened runtime + --timestamp are notarization requirements; both
# cause friction (or outright loader failures) under ad-hoc local
# signing. macOS rejects an ad-hoc + hardened-runtime + library-
# validation combo when loading frameworks signed with a different
# (or empty) team identifier. Only opt in for real Developer ID builds.
HELPER_SIGN_FLAGS=(--force)
APP_SIGN_FLAGS=(--force)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    HELPER_SIGN_FLAGS+=(--options runtime --timestamp)
    APP_SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Inside-out signing. Codesign requires nested bundles (XPC services,
# Updater.app, Autoupdate) to be signed before the framework, and the
# framework before the outer app. --preserve-metadata=entitlements
# keeps Sparkle's required entitlements on its helpers; without it
# the XPC services lose their sandbox/entitlement claims and the
# updater silently fails to launch them.
SPARKLE_FW="$CONTENTS/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    for xpc in "$SPARKLE_FW/Versions/B/XPCServices/"*.xpc; do
        [[ -d "$xpc" ]] || continue
        codesign "${HELPER_SIGN_FLAGS[@]}" \
            --preserve-metadata=entitlements \
            --sign "$SIGN_IDENTITY" "$xpc"
    done
    if [[ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]]; then
        codesign "${HELPER_SIGN_FLAGS[@]}" \
            --sign "$SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Autoupdate"
    fi
    if [[ -d "$SPARKLE_FW/Versions/B/Updater.app" ]]; then
        codesign "${HELPER_SIGN_FLAGS[@]}" \
            --preserve-metadata=entitlements \
            --sign "$SIGN_IDENTITY" "$SPARKLE_FW/Versions/B/Updater.app"
    fi
    codesign "${HELPER_SIGN_FLAGS[@]}" \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

if [[ -f GitChop.entitlements ]]; then
    APP_SIGN_FLAGS+=(--entitlements GitChop.entitlements)
fi
codesign "${APP_SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" || true

if [[ "$INSTALL" == "1" ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    pkill -x "$APP_NAME" 2>/dev/null || true
    # Give the kill a beat to release file handles before we replace
    # the bundle. Without this, ditto can race the dying process and
    # produce a half-stale install.
    sleep 0.2
    rm -rf "$DEST"
    ditto --noextattr --noacl "$APP_DIR" "$DEST"

    # Force LaunchServices to re-register the bundle. Without this,
    # `open` against a freshly-replaced .app sometimes returns
    # `_LSOpenURLsWithCompletionHandler() failed with error -600`
    # because LS still has the old inode in its cache. -f registers
    # immediately rather than waiting for the on-disk-change watcher.
    LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [[ -x "$LSREG" ]]; then
        "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
    fi

    # Retry `open` until the process is visible. LSOpenURLsWith… -600
    # is racy; one retry after a 0.5s pause clears it virtually every
    # time, but cap at ~3s so a real failure surfaces instead of
    # hanging.
    launched=0
    for attempt in 1 2 3 4 5 6; do
        open "$DEST" 2>/dev/null || true
        # Give the process a moment to actually start.
        sleep 0.4
        if pgrep -x "$APP_NAME" >/dev/null; then
            launched=1
            break
        fi
    done
    if [[ "$launched" == "1" ]]; then
        echo "==> Launched: $DEST"
    else
        echo "==> Installed: $DEST"
        echo "    (open did not bring the app forward — try double-clicking it)"
    fi
    echo
    echo "Done: $DEST"
else
    OUT="build/$APP_NAME.app"
    rm -rf "$OUT"
    mkdir -p build
    ditto --noextattr --noacl "$APP_DIR" "$OUT"
    echo
    echo "Done: $OUT"
fi
