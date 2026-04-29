#!/usr/bin/env bash
# Ship a new release of GitChop.
# Pattern: build → notarize app → DMG → notarize DMG → generate_appcast →
#          upload to /apps/gitchop/ → MD5-verify live.
#
# See ../../RELEASE.md (workspace) for the full doc on the unified pattern.
#
# To bump the version: edit Resources/Info.plist's CFBundleShortVersionString
# AND CFBundleVersion (Sparkle compares the latter), drop a
# release-notes/<short>.html fragment, then run this script.
#
# To build local DMG + appcast WITHOUT uploading (useful before a real ship
# when you want to inspect the artifacts):
#
#     NO_UPLOAD=1 bash scripts/release.sh

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# === CONFIG ===
APP_NAME="GitChop"
APP_SUBPATH="gitchop"
BUNDLE_ID="com.bendansby.GitChop"
SIGN_IDENTITY="Developer ID Application: Benjamin Dansby (8CYGCS6F34)"
NOTARY_PROFILE="gitchop-notary"

# Version comes from Info.plist so the in-app About box and the DMG
# filename never disagree.
PLIST="$ROOT/Resources/Info.plist"
APP_VERSION_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
APP_VERSION_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

SU_FEED_URL="https://bendansby.com/apps/$APP_SUBPATH/appcast.xml"
DOWNLOAD_URL_PREFIX="https://bendansby.com/apps/$APP_SUBPATH/"

SPARKLE_BIN="$ROOT/build/sparkle-tools"
RELEASES_DIR="$ROOT/build/releases"
APP_PATH="$ROOT/build/$APP_NAME.app"
DMG_NAME="$APP_NAME-$APP_VERSION_SHORT.dmg"
DMG_PATH="$RELEASES_DIR/$DMG_NAME"

# === FTP ===
FTP_HOST="195.179.237.125"
FTP_USER="u113856113"
FTP_REMOTE_BASE="//domains/bendansby.com/public_html"
if [[ -z "${FTP_PASS:-}" ]]; then
    FTP_PASS="$(security find-internet-password -s "$FTP_HOST" -w 2>/dev/null || true)"
fi

# === BUILD ===
echo "==> Building app bundle ($APP_NAME $APP_VERSION_SHORT)"
SIGN_IDENTITY="$SIGN_IDENTITY" INSTALL=0 \
    bash scripts/build-app.sh

# === NOTARIZE THE APP ===
echo "==> Notarizing $APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f "$ZIP"

# === MAKE DMG ===
echo "==> Building DMG: $DMG_NAME"
mkdir -p "$RELEASES_DIR"
RAW="$RELEASES_DIR/$APP_NAME-raw.dmg"
MNT="/tmp/${APP_SUBPATH}-mnt"
rm -f "$DMG_PATH" "$RAW"
mkdir -p "$MNT"
hdiutil create -size 50m -fs HFS+ -volname "$APP_NAME" -layout NONE "$RAW" >/dev/null
hdiutil attach "$RAW" -nobrowse -noverify -noautoopen -mountpoint "$MNT" >/dev/null
ditto "$APP_PATH" "$MNT/$APP_NAME.app"
ln -s /Applications "$MNT/Applications"
# Bundle the sample project for first-time users.
if [[ -d "$ROOT/Sample Project" ]]; then
    ditto --norsrc --noextattr --noacl "$ROOT/Sample Project" "$MNT/Sample Project"
    find "$MNT/Sample Project" -name ".DS_Store" -delete
fi
hdiutil detach "$MNT" >/dev/null
hdiutil convert "$RAW" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RAW"
rmdir "$MNT" 2>/dev/null || true

echo "==> Signing + notarizing DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# === RELEASE NOTES ===
NOTES_FRAGMENT="$ROOT/release-notes/$APP_VERSION_SHORT.html"
NOTES_LAYOUT="$ROOT/release-notes/_layout.html"
NOTES_OUT="$RELEASES_DIR/$APP_NAME-$APP_VERSION_SHORT.html"
if [[ ! -f "$NOTES_FRAGMENT" ]]; then
    echo "!! Missing release-notes/$APP_VERSION_SHORT.html — create one before releasing." >&2
    exit 1
fi
echo "==> Rendering release notes"
RELEASE_DATE="$(date "+%B %-d, %Y")"
awk -v version="$APP_VERSION_SHORT" -v date="$RELEASE_DATE" -v fragfile="$NOTES_FRAGMENT" '
    {
        gsub(/__VERSION__/, version); gsub(/__DATE__/, date)
        if (index($0, "__CONTENT__") > 0) {
            while ((getline line < fragfile) > 0) print line
            close(fragfile)
        } else { print }
    }
' "$NOTES_LAYOUT" > "$NOTES_OUT"

# === APPCAST ===
echo "==> Generating signed appcast"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    "$RELEASES_DIR"
APPCAST="$RELEASES_DIR/appcast.xml"
[[ -f "$APPCAST" ]] || { echo "!! generate_appcast didn't produce $APPCAST"; exit 1; }

# === UPLOAD (skipped via NO_UPLOAD=1) ===
if [[ "${NO_UPLOAD:-0}" == "1" ]]; then
    echo "==> NO_UPLOAD=1 — skipping FTP upload + verify."
    echo
    echo "Local artifacts ready in $RELEASES_DIR:"
    ls -lh "$RELEASES_DIR"
    exit 0
fi

[[ -n "$FTP_PASS" ]] || { echo "!! Set FTP_PASS env var or store the password in Keychain for $FTP_HOST"; exit 1; }
AUTH="$FTP_USER:$FTP_PASS"
upload() {
    local src="$1" dst="$2"
    # --ftp-create-dirs makes any missing remote directories on first
    # upload to a new app subpath. Without it curl errors with
    # "Server denied you to change to the given directory".
    /usr/bin/curl -sS --fail --ftp-create-dirs --user "$AUTH" --upload-file "$src" \
        "ftp://$FTP_HOST$FTP_REMOTE_BASE/$dst"
    echo "  ✓ $dst"
}
echo "==> Uploading to /apps/$APP_SUBPATH/"
upload "$DMG_PATH"   "apps/$APP_SUBPATH/$DMG_NAME"
upload "$DMG_PATH"   "apps/$APP_SUBPATH/$APP_NAME.dmg"        # stable alias for showcase
upload "$APPCAST"    "apps/$APP_SUBPATH/appcast.xml"
upload "$NOTES_OUT"  "apps/$APP_SUBPATH/$(basename "$NOTES_OUT")"
shopt -s nullglob
for delta in "$RELEASES_DIR"/${APP_NAME}*.delta; do
    upload "$delta" "apps/$APP_SUBPATH/$(basename "$delta")"
done
shopt -u nullglob

# === VERIFY ===
echo "==> Verifying live (cache-busted MD5)"
TS=$(date +%s%N)
verify() {
    local url="$1" local_path="$2"
    local live="/tmp/live_$(basename "$local_path")"
    /usr/bin/curl -sS -o "$live" "${url}?x=${TS}"
    local local_md5 live_md5
    local_md5="$(md5 -q "$local_path")"
    live_md5="$(md5 -q "$live")"
    rm -f "$live"
    if [[ "$local_md5" == "$live_md5" ]]; then
        echo "  ✓ $url"
    else
        echo "  ✗ $url   local=$local_md5 live=$live_md5"
        return 1
    fi
}
verify "https://bendansby.com/apps/$APP_SUBPATH/$DMG_NAME"            "$DMG_PATH"
verify "https://bendansby.com/apps/$APP_SUBPATH/$APP_NAME.dmg"        "$DMG_PATH"
verify "https://bendansby.com/apps/$APP_SUBPATH/appcast.xml"          "$APPCAST"
verify "https://bendansby.com/apps/$APP_SUBPATH/$(basename "$NOTES_OUT")"  "$NOTES_OUT"

echo
echo "Done: $APP_NAME $APP_VERSION_SHORT (build $APP_VERSION_BUILD)"
echo "  Appcast:  $SU_FEED_URL"
echo "  Download: ${DOWNLOAD_URL_PREFIX}${DMG_NAME}"
