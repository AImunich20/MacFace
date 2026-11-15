#!/usr/bin/env bash
# Builds a release DMG, signs it for Sparkle and writes the update feed (appcast.xml).
#
#   VERSION=1.3 scripts/release.sh               # prepare build/release/ (nothing is uploaded)
#   VERSION=1.3 PUBLISH=1 scripts/release.sh     # also create the GitHub release in $RELEASES_REPO
#
# Sparkle compares CFBundleVersion (the git commit count), so commit before each release.
#
# Every installed copy of MacFace checks
#   https://github.com/$RELEASES_REPO/releases/latest/download/appcast.xml
# so the releases repo must be public. Release notes: put Markdown/HTML in release-notes/<version>.md
set -euo pipefail

cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION, e.g. VERSION=1.3}"
RELEASES_REPO="${RELEASES_REPO:-AImunich20/MacFace-releases}"
KEY_ACCOUNT="${KEY_ACCOUNT:-macface}"
export VERSION

# Sparkle's tools come from the Swift package Xcode resolves; SPARKLE_BIN overrides the search.
find_sparkle_bin() {
    local dir
    for dir in build/DerivedData/SourcePackages/artifacts ~/Library/Developer/Xcode/DerivedData; do
        [[ -d "$dir" ]] || continue
        dir="$(find "$dir" -type d -path '*sparkle/Sparkle/bin' 2>/dev/null | head -1)"
        [[ -n "$dir" ]] && { echo "$dir"; return; }
    done
}

scripts/build-dmg.sh

SPARKLE_BIN="${SPARKLE_BIN:-$(find_sparkle_bin)}"
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle tools not found; set SPARKLE_BIN=…/Sparkle/bin"; exit 1; }

# Refuse to ship an update that installed copies would reject.
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' MacFace/Info.plist)"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)"
if [[ -z "$KEYCHAIN_KEY" || "$PLIST_KEY" != "$KEYCHAIN_KEY" ]]; then
    echo "SUPublicEDKey in MacFace/Info.plist doesn't match the '$KEY_ACCOUNT' key in your Keychain."
    echo "Create one with: \"$SPARKLE_BIN/generate_keys\" --account $KEY_ACCOUNT"
    exit 1
fi

DMG="build/MacFace-${VERSION}.dmg"
OUT="build/release"
mkdir -p "$OUT"
cp "$DMG" "$OUT/"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$DMG")"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' build/DerivedData/Build/Products/Release/MacFace.app/Contents/Info.plist)"
NOTES_FILE="release-notes/${VERSION}.md"
URL="https://github.com/$RELEASES_REPO/releases/download/v${VERSION}/MacFace-${VERSION}.dmg"

# The feed lives in the repo (appcast.xml) so earlier entries survive a clean build.
python3 - appcast.xml "$VERSION" "$BUILD_NUMBER" "$URL" "$SIGNATURE_ATTRS" "$NOTES_FILE" <<'PY'
import html, os, sys, email.utils
path, version, build, url, attrs, notes_file = sys.argv[1:]
notes = open(notes_file).read() if os.path.exists(notes_file) else f"MacFace {version}"
fmt = "markdown" if notes_file.endswith(".md") else "html"
item = f"""        <item>
            <title>MacFace {version}</title>
            <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <description sparkle:format="{fmt}"><![CDATA[{notes}]]></description>
            <enclosure url="{html.escape(url)}" type="application/octet-stream" {attrs.strip()}/>
        </item>
"""
head = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>MacFace</title>
"""
tail = "    </channel>\n</rss>\n"
old_items = ""
if os.path.exists(path):
    text = open(path).read()
    start = text.find("<item>")
    end = text.rfind("</item>")
    if start != -1:
        old_items = "        " + text[start:end + len("</item>")] + "\n"
        # Drop an earlier entry for the same version (re-running a release).
        marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
        if marker in old_items:
            blocks = old_items.split("</item>")
            old_items = "</item>".join(b for b in blocks if marker not in b)
open(path, "w").write(head + item + old_items + tail)
PY

cp appcast.xml "$OUT/appcast.xml"
echo "Prepared $OUT/MacFace-${VERSION}.dmg and appcast.xml (commit it after publishing)"

if [[ "${PUBLISH:-0}" == "1" ]]; then
    NOTES_ARGS=(--notes "MacFace ${VERSION}")
    [[ -f "$NOTES_FILE" ]] && NOTES_ARGS=(--notes-file "$NOTES_FILE")
    # "MacFace.dmg" gives the download page a link that always points at the newest version.
    cp "$OUT/MacFace-${VERSION}.dmg" "$OUT/MacFace.dmg"
    gh release create "v${VERSION}" -R "$RELEASES_REPO" --title "MacFace ${VERSION}" "${NOTES_ARGS[@]}" \
        "$OUT/MacFace-${VERSION}.dmg" "$OUT/MacFace.dmg" "$OUT/appcast.xml"
    echo "Published v${VERSION} to $RELEASES_REPO"
fi
