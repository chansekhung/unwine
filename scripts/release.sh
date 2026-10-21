#!/bin/bash
# The release steps in one place. It never commits, tags, pushes or publishes: at the end it
# prints those commands for you to run.
#
#   scripts/release.sh new 1.0.4   Starts the next version: adds "## 1.0.4 · not released yet" at the
#                                  top of CHANGELOG.md. Add a "- " line there for each change you make.
#   scripts/release.sh             Releases the newest version in CHANGELOG.md: writes today's date in
#                                  its heading, builds Unwine.app, makes Unwine.dmg, checks both for
#                                  names that must not ship, and writes the GitHub release text from
#                                  the same entry to dist/release-notes.md.
set -euo pipefail
cd "$(dirname "$0")/.."

newest() { awk '/^## [0-9]/ { print $2; exit }' CHANGELOG.md; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }   # is $2 newer than $1?
# Words that must not ship, scrambled (rot13) so that this file does not carry them either.
SCAN_WORDS="$(tr 'a-zA-Z' 'n-za-mN-ZA-M' <<< 'pynhqr|naguebcvp')"

if [ "${1:-}" = "new" ]; then
  NEXT="${2:-}"
  CURRENT="$(newest)"
  [[ "$NEXT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh new 1.0.4"; exit 1; }
  newer "$CURRENT" "$NEXT" || { echo "✗ $NEXT is not newer than $CURRENT, the newest version in CHANGELOG.md"; exit 1; }
  if grep -m1 '^## [0-9]' CHANGELOG.md | grep -q 'not released yet'; then
    echo "✗ $CURRENT is not released yet. Release it first, or change its heading to $NEXT."; exit 1
  fi
  awk -v h="## $NEXT · not released yet" '!done && /^## [0-9]/ { print h; print ""; done = 1 } { print }' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
  echo "✓ CHANGELOG.md now starts with \"## $NEXT · not released yet\"."
  echo "  Add one \"- \" line under it for each change that a player can see. The build needs at least one."
  exit 0
fi
[ $# -eq 0 ] || { echo "Usage: scripts/release.sh            release the newest version in CHANGELOG.md"; echo "       scripts/release.sh new 1.0.4  start the next version"; exit 1; }

VERSION="$(newest)"
TAG="v$VERSION"

# Swift writes this folder's path into the app, so a release comes only from a neutral folder.
if pwd -P | grep -qiE "$SCAN_WORDS|^/private/tmp/|^/tmp/"; then
  echo "✗ Make releases in a neutral folder, such as ~/UnwineRelease. Swift writes this folder's path into the app."; exit 1
fi

# The build must be what you tag: only CHANGELOG.md may have changes that are not committed.
DIRTY="$(git status --porcelain | grep -v ' CHANGELOG.md$' || true)"
[ -z "$DIRTY" ] || { echo "✗ Commit these changes first, so the build matches the tag:"; echo "$DIRTY"; exit 1; }

# Each version is released once, and only after the one before it. GitHub's tags count too.
TAGS="$( { git tag -l; git ls-remote --tags --refs origin 2>/dev/null | sed 's|.*refs/tags/||'; } \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV || true)"
if grep -qx "$TAG" <<< "$TAGS"; then echo "✗ $TAG is already released. Start the next version: scripts/release.sh new <version>"; exit 1; fi
LAST="$(tail -1 <<< "$TAGS")"
if [ -n "$LAST" ] && ! newer "${LAST#v}" "$VERSION"; then echo "✗ $VERSION is not newer than the last release, $LAST"; exit 1; fi

if grep -m1 '^## [0-9]' CHANGELOG.md | grep -q 'not released yet'; then
  TODAY="$(date +%Y-%m-%d)"
  awk -v h="## $VERSION · $TODAY" '!done && /^## [0-9]/ { print h; done = 1; next } { print }' CHANGELOG.md > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
  echo "▸ CHANGELOG.md: $VERSION is dated $TODAY"
fi

# Temporary files stay inside this folder too.
export TMPDIR="$PWD/.build/release-tmp"
rm -rf "$TMPDIR" && mkdir -p "$TMPDIR"
scripts/build.sh
scripts/make-dmg.sh

echo "▸ Checking the app and the DMG for names that must not ship"
MOUNT="$TMPDIR/dmg"
mkdir -p "$MOUNT"
hdiutil attach dist/Unwine.dmg -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true' EXIT
HITS="$(python3 -I - "$SCAN_WORDS" dist/Unwine.app "$MOUNT" <<'PY'
import os, re, sys
pattern = re.compile(sys.argv[1].encode(), re.I)
hits = 0
for top in sys.argv[2:]:
    for folder, _, files in os.walk(top):
        for name in files:
            path = os.path.join(folder, name)
            if os.path.islink(path):
                continue
            with open(path, "rb") as f:
                n = len(pattern.findall(f.read()))
            if n:
                print(f"  {n} in {path}", file=sys.stderr)
                hits += n
print(hits)
PY
)"
[ "$HITS" = "0" ] || { echo "✗ $HITS hits (listed above). Do not publish this build."; exit 1; }
echo "✓ None found"

# The GitHub release text comes from the same entry as the app's "What's new".
PREV="$(awk '/^## [0-9]/ { if (++n == 2) { print $2; exit } }' CHANGELOG.md)"
{
  [ -z "$PREV" ] || printf '**Already on Unwine %s?** Let it update. Your engine, GPTK and settings stay.\n\n' "$PREV"
  printf '**New in %s**\n\n' "$VERSION"
  awk '/^## [0-9]/ { n++; next }
       n == 1 { line[++c] = $0 }
       END { s = 1; while (s <= c && line[s] == "") s++
             e = c; while (e >= s && line[e] == "") e--
             for (i = s; i <= e; i++) print line[i] }' CHANGELOG.md
  printf '\n**Install:** open Unwine.dmg and drag Unwine to Applications.\n'
} > dist/release-notes.md

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo
echo "✓ Unwine $VERSION ($(grep -c '^## [0-9]' CHANGELOG.md)) is ready: dist/Unwine.dmg, with its release text in dist/release-notes.md."
echo "  Open dist/Unwine.app once to check it. Then run these yourself:"
git diff --quiet -- CHANGELOG.md || echo "    git commit -m \"Unwine $VERSION\" CHANGELOG.md"
echo "    git tag $TAG"
if [ "$BRANCH" = "HEAD" ]; then
  echo "    git push origin $TAG        (this folder is on no branch: bring its commits into main too)"
else
  echo "    git push origin $BRANCH $TAG"
fi
echo "    gh release create $TAG dist/Unwine.dmg --title \"Unwine $VERSION\" --notes-file dist/release-notes.md"
