#!/bin/bash
# Archives Wiki Reader for iOS from an up-to-date main checkout and uploads it to TestFlight
# (internal testing only). Runs without the Xcode app: signing and upload use an App Store Connect
# API key, kept outside the repository. See "TestFlight" in CLAUDE.md.
#
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8   the key (Team key, Admin), mode 600
#   ~/.appstoreconnect/wiki-reader.env                        ASC_KEY_ID=..., ASC_ISSUER_ID=... and
#                                                             DEVELOPMENT_TEAM=<team id>
#
# The team id is kept there and not in the project because this repository is public.
#
# Usage: ios/scripts/testflight-upload.sh
set -euo pipefail

ios="$(cd "$(dirname "$0")/.." && pwd)"
conf="${ASC_CONFIG:-$HOME/.appstoreconnect/wiki-reader.env}"
if [ -f "$conf" ]; then
  # shellcheck disable=SC1090
  . "$conf"
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID in $conf (see TestFlight in CLAUDE.md)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in $conf (see TestFlight in CLAUDE.md)}"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM in $conf (see TestFlight in CLAUDE.md)}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$key" ] || { echo "No API key at $key" >&2; exit 1; }
command -v xcodegen > /dev/null || { echo "xcodegen not found. Install it with: brew install xcodegen" >&2; exit 1; }

# Upload only what main has: never a branch, a stale checkout or uncommitted changes.
branch="$(git -C "$ios" rev-parse --abbrev-ref HEAD)"
[ "$branch" = main ] || { echo "On $branch: upload only from main" >&2; exit 1; }
[ -z "$(git -C "$ios" status --porcelain -- .)" ] || { echo "ios/ has uncommitted changes" >&2; exit 1; }
git -C "$ios" fetch -q origin main
[ "$(git -C "$ios" rev-parse HEAD)" = "$(git -C "$ios" rev-parse origin/main)" ] ||
  { echo "Not at origin/main: pull first" >&2; exit 1; }

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
auth=(-allowProvisioningUpdates
  -authenticationKeyPath "$key"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# The project is generated, not kept (see ios/project.yml).
(cd "$ios" && xcodegen generate --quiet)
xcodebuild archive -project "$ios/WikiReader.xcodeproj" -scheme WikiReader -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$work/WikiReader.xcarchive" \
  -derivedDataPath "$work/dd" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" "${auth[@]}" -quiet
# The export takes the team the archive was signed for: the options file names none.
xcodebuild -exportArchive -archivePath "$work/WikiReader.xcarchive" \
  -exportOptionsPlist "$ios/ExportOptions-TestFlight.plist" \
  -exportPath "$work/export" "${auth[@]}"

echo "Uploaded $(git -C "$ios" rev-parse --short HEAD). App Store Connect processes it in a few minutes,"
echo "then TestFlight offers it to the internal testers."
