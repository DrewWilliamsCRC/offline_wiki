#!/bin/bash
# Builds Wiki Reader for Android from an up-to-date main checkout and uploads it to Google Play's
# internal testing track, where the testers get it from the Play Store. See "Google Play" in
# CLAUDE.md. Two things are kept outside the repository, which is public:
#
#   ~/.android/wiki-reader-upload.properties   the upload key that signs the build (and its .jks)
#   ~/.android/wiki-reader-play.json            a Google Cloud service account's key, which Play
#                                                Console (Users and permissions) lets release to
#                                                testing tracks
#
# Play takes each version code once: raise versionCode in reader/app/build.gradle.kts first.
# The first build of a new app goes up by hand in Play Console; this script does every one after.
#
# Usage: reader/scripts/play-upload.sh
set -euo pipefail

reader="$(cd "$(dirname "$0")/.." && pwd)"
package="dev.offlinewiki.reader"
account="${PLAY_KEY:-$HOME/.android/wiki-reader-play.json}"
[ -f "$account" ] || { echo "No service account key at $account (see Google Play in CLAUDE.md)" >&2; exit 1; }
[ -f "$HOME/.android/wiki-reader-upload.properties" ] || [ -n "${PLAY_UPLOAD_KEY:-}" ] ||
  { echo "No upload key at ~/.android/wiki-reader-upload.properties (see Google Play in CLAUDE.md)" >&2; exit 1; }

# Upload only what main has: never a branch, a stale checkout or uncommitted changes.
branch="$(git -C "$reader" rev-parse --abbrev-ref HEAD)"
[ "$branch" = main ] || { echo "On $branch: upload only from main" >&2; exit 1; }
[ -z "$(git -C "$reader" status --porcelain -- .)" ] || { echo "reader/ has uncommitted changes" >&2; exit 1; }
git -C "$reader" fetch -q origin main
[ "$(git -C "$reader" rev-parse HEAD)" = "$(git -C "$reader" rev-parse origin/main)" ] ||
  { echo "Not at origin/main: pull first" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$reader" && ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}" \
  ./gradlew --no-daemon -q ${PLAY_UPLOAD_KEY:+-PwikiReaderUploadKey="$PLAY_UPLOAD_KEY"} :app:bundlePlay)
bundle="$reader/app/build/outputs/bundle/play/app-play.aab"
jarsigner -verify "$bundle" > /dev/null 2>&1 || { echo "The bundle is not signed: is the upload key there?" >&2; exit 1; }

# Reads one field of a JSON document on standard input: json <key>[.<key>...]
json() { python3 -I -c 'import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v, list) else v.get(k, "")
print(v)' "$1"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# A token for the Play Developer API: a JWT about the service account, signed with its key.
(umask 077; json private_key < "$account" > "$work/key.pem")
email="$(json client_email < "$account")"
token_uri="$(json token_uri < "$account")"
now="$(date +%s)"
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
claims="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"%s","iat":%s,"exp":%s}' \
  "$email" "$token_uri" "$now" "$((now + 3600))" | b64url)"
signature="$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$work/key.pem" | b64url)"
token="$(curl -fsS "$token_uri" --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  --data-urlencode "assertion=$header.$claims.$signature" | json access_token)"
[ -n "$token" ] || { echo "Google did not give a token for $email" >&2; exit 1; }

api="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$package"
call() { # $1 = method, $2 = URL, the rest go to curl; prints the answer, and stops on an error
  local answer status
  answer="$(curl -sS -w '\n%{http_code}' -X "$1" -H "Authorization: Bearer $token" "${@:3}" "$2")"
  status="${answer##*$'\n'}"
  answer="${answer%$'\n'*}"
  if [ "$status" -ge 300 ]; then
    echo "Google Play answered $status: $(echo "$answer" | json error.message 2>/dev/null || echo "$answer")" >&2
    [ "$status" != 404 ] || echo "Has the first build been uploaded by hand in Play Console yet?" >&2
    exit 1
  fi
  echo "$answer"
}

# An edit: the bundle, then a release of it on the internal track, then the commit.
edit="$(call POST "$api/edits" | json id)"
version="$(call POST "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$package/edits/$edit/bundles?uploadType=media" \
  -H 'Content-Type: application/octet-stream' --data-binary @"$bundle" | json versionCode)"
name="$(sed -nE 's/.*versionName = "([^"]+)".*/\1/p' "$reader/app/build.gradle.kts")"
printf '{"track":"internal","releases":[{"name":"%s","versionCodes":["%s"],"status":"completed"}]}' "$name" "$version" > "$work/track.json"
call PUT "$api/edits/$edit/tracks/internal" -H 'Content-Type: application/json' --data-binary @"$work/track.json" > /dev/null
call POST "$api/edits/$edit:commit" > /dev/null

echo "Uploaded $(git -C "$reader" rev-parse --short HEAD) as $name ($version) to internal testing."
echo "Play makes it available to the testers within minutes."
