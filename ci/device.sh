#!/bin/bash
# Runs the half of wiki.sh that talks to the e-reader (push, update, "verify device") against a
# stand-in for it, and checks what ends up where. Nothing here touches a real device, the real
# data/ folder or the network: the e-reader is a folder behind ci/fake-mtp.sh, wiki.sh works in a
# scratch folder (WIKI_DATA), and "Kiwix" is a web server on this machine (WIKI_ZIM_URL).
#
#   ci/device.sh <file.zim>
#
# <file.zim> is any small, real Wikipedia, such as the one ci/compare.sh uses: "update" builds a
# real index for it. Needs the indexer built first:
#   (cd reader && ./gradlew --no-daemon -q :indexer:installDist)
#
# Written for macOS's bash 3.2, like wiki.sh.
set -euo pipefail

source_zim="${1:-}"
[ -f "$source_zim" ] || { echo "usage: ci/device.sh <file.zim>" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$root/reader/indexer/build/install/indexer/bin/indexer" ] ||
  { echo "error: build the indexer first: (cd reader && ./gradlew :indexer:installDist)" >&2; exit 2; }

work="$(mktemp -d)"
server=""
trap '[ -z "$server" ] || { kill "$server" && wait "$server"; } 2> /dev/null || true; rm -rf "$work"' EXIT
book=wikipedia_en_test
zims="$work/data/zim"
device="$work/device"
kiwix="$work/kiwix"
mkdir -p "$zims" "$work/data/app" "$device/Download" "$device/Books" "$kiwix" "$work/bin"
for tool in mtp-detect mtp-folders mtp-files mtp-delfile mtp-sendfile mtp-getfile; do
  ln -s "$root/ci/fake-mtp.sh" "$work/bin/$tool"
done

# "Kiwix": a folder served over HTTP, whose listing links to each file as Kiwix's does.
publish() { # $1 = snapshot name; the file, its checksum and its metalink
  local name="$1" size hash
  cp "$source_zim" "$kiwix/$name"
  size="$(stat -f %z "$kiwix/$name")"
  hash="$(shasum -a 256 "$kiwix/$name" | cut -d' ' -f1)"
  echo "$hash  $name" > "$kiwix/$name.sha256"
  cat > "$kiwix/$name.meta4" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="$name">
    <size>$size</size>
    <hash type="sha-256">$hash</hash>
    <url>http://127.0.0.1:$port/$name</url>
  </file>
</metalink>
EOF
}
port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$kiwix" > "$work/server.log" 2>&1 &
server=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fs "http://127.0.0.1:$port/" > /dev/null 2>&1 && break
  sleep 1
done

# A scenario can name another book or device folder for one run: use_book=... run ...
wiki() {
  WIKI_DATA="$work/data" WIKI_BOOK="${use_book:-$book}" WIKI_DEVICE_FOLDER="${use_folder:-Download}" \
    WIKI_ZIM_URL="http://127.0.0.1:$port" WIKI_MTP_PAUSE=0 \
    FAKE_MTP_DIR="$device" PATH="$work/bin:$PATH" "$root/wiki.sh" "$@"
}

failures=0
checks=0
scenario() { echo; echo "== $1"; }
check() { # $1 = what should be true, the rest = a command that tests it
  local what="$1"
  shift
  checks=$((checks + 1))
  if "$@" > /dev/null 2>&1; then
    echo "ok: $what"
  else
    echo "FAILED: $what"
    failures=$((failures + 1))
  fi
}
# Runs wiki.sh, keeping what it printed in $work/out. $1 = the exit status expected (0, or "fail").
run() {
  local expected="$1" status=0
  shift
  wiki "$@" > "$work/out" 2>&1 || status=$?
  checks=$((checks + 1))
  if { [ "$expected" = 0 ] && [ "$status" -eq 0 ]; } || { [ "$expected" = fail ] && [ "$status" -ne 0 ]; }; then
    echo "ok: wiki.sh $* exits $([ "$expected" = 0 ] && echo 0 || echo "with an error ($status)")"
  else
    echo "FAILED: wiki.sh $* exited $status"
    sed 's/^/    /' "$work/out" | tr '\r' '\n' | tail -15
    failures=$((failures + 1))
  fi
}
says() { tr '\r' '\n' < "$work/out" | grep -qF -- "$1"; }
same() { cmp -s "$1" "$2"; }
gone() { [ ! -e "$1" ]; }
log_lines() { wc -l < "$device/.log" | tr -d ' '; }
before_in_log() { # line $1 comes before line $2 in the device's log
  local a b
  a="$(grep -nxF -- "$1" "$device/.log" | head -1 | cut -d: -f1)"
  b="$(grep -nxF -- "$2" "$device/.log" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

old="${book}_nopic_2026-01.zim"
new="${book}_nopic_2026-02.zim"
app1="wiki-reader-11111111.apk"
app2="wiki-reader-22222222.apk"
publish "$old"
cp "$kiwix/$old" "$zims/$old"
cp "$kiwix/$old.sha256" "$zims/$old.sha256"
touch -t 202601010000 "$zims/$old"           # older than its index, as a downloaded file is
head -c 5000 /dev/urandom > "$zims/$old.idx" # push never looks inside an index
echo "first build" > "$work/data/app/$app1"
: > "$device/.log"
down="$device/Download"

scenario "push to an e-reader that has nothing"
run 0 push
check "the app, the index and Wikipedia are in Download" \
  eval 'same "$work/data/app/$app1" "$down/$app1" && same "$zims/$old.idx" "$down/$old.idx" && same "$zims/$old" "$down/$old"'
check "nothing was put anywhere else" eval '[ -z "$(ls "$device/Books")" ]'

scenario "push again"
sent="$(log_lines)"
run 0 push
check "nothing is sent or deleted a second time" eval '[ "$(log_lines)" = "$sent" ]'
check "it says each file is already there" eval '[ "$(grep -c "is on the e-reader" "$work/out")" = 3 ]'

scenario "an index rebuilt to the same size"
head -c 5000 /dev/urandom > "$zims/$old.idx"
run 0 push
check "the new index replaced the old one" same "$zims/$old.idx" "$down/$old.idx"
check "Wikipedia itself was not sent again" eval '[ "$(grep -cxF "send $old" "$device/.log")" = 1 ]'

scenario "a copy that was interrupted earlier"
head -c 1000 "$zims/$old" > "$down/$old"
run 0 push
check "the partial file was replaced by the whole one" same "$zims/$old" "$down/$old"

scenario "a transfer that stops half-way"
rm -f "$down/$old"
echo 1 > "$device/.cut"
run 0 push
check "it was sent again and arrived whole" same "$zims/$old" "$down/$old"

scenario "a newer build of the app"
rm -f "$work/data/app/$app1"
echo "second build" > "$work/data/app/$app2"
run 0 push
check "the new app is there" same "$work/data/app/$app2" "$down/$app2"
check "the old one was removed" gone "$down/$app1"

scenario "an e-reader with thousands of other files"
# Enough listing after the files wiki.sh looks for that stopping at the first match breaks the pipe.
mkdir -p "$device/Notes"
for i in $(seq 1000 2499); do : > "$device/Notes/note-$i.txt"; : > "$down/zz-other-$i.txt"; done
rm -f "$down/$old.idx"
run 0 push
check "the missing index was sent" same "$zims/$old.idx" "$down/$old.idx"
rm -rf "$device/Notes"
find "$down" -name 'zz-other-*' -delete

scenario "sessions that fail the way back-to-back ones do"
rm -f "$down/$old.idx"
echo 4 > "$device/.flaky"
run 0 push
check "the index still arrived" same "$zims/$old.idx" "$down/$old.idx"

scenario "too little room on the e-reader"
rm -f "$down/$old"
echo 1000 > "$device/.free"
run fail push
check "it says how much room there is and what could be holding it" eval 'says "free;" && says "home button"'
check "nothing was sent" gone "$down/$old"
rm -f "$device/.free"
run 0 push

scenario "an e-reader without the folder"
use_folder=Nowhere run fail push
check "it names the missing folder" says 'no "Nowhere" folder'

scenario "an e-reader that is charging but not sharing files"
: > "$device/.unplugged"
run fail push
check "it says how to connect" says "File transfer"
rm -f "$device/.unplugged"

scenario "verify device"
run 0 verify device
check "the copy matches" says "checksum OK"
echo 1 > "$device/.cut"
run 0 verify device
check "a read that was cut short is tried again" says "trying again"
size="$(stat -f %z "$down/$old")"
head -c "$size" /dev/urandom > "$down/$old"
run fail verify device
check "a damaged copy is reported" says "does not match"
cp "$zims/$old" "$down/$old"

scenario "update when nothing newer is published"
sent="$(log_lines)"
run 0 update
check "the e-reader is left alone" eval '[ "$(log_lines)" = "$sent" ]'
check "the Mac still has its snapshot" eval '[ -f "$zims/$old" ] && [ -f "$zims/$old.idx" ]'

scenario "update to a newer snapshot, without the e-reader"
publish "$new"
# The index ranks by Kiwix's top-articles build, and would download it if it were not there.
cp "$source_zim" "$zims/wikipedia_en_top_nopic_2000-01.zim"
: > "$device/.unplugged"
run 0 update
check "the new snapshot is downloaded and indexed" eval '[ -f "$zims/$new" ] && [ -s "$zims/$new.idx" ]'
check "the download matches what was published" same "$kiwix/$new" "$zims/$new"
check "the old one is kept until the e-reader has the new one" eval '[ -f "$zims/$old" ]'
check "it asks for the e-reader" says "Plug in the e-reader"
check "the e-reader was not touched" eval '[ "$(log_lines)" = "$sent" ]'

scenario "update again, with the e-reader"
rm -f "$device/.unplugged"
# A newer date on the old file: the snapshot to send is chosen by name, never by date.
touch "$zims/$old" "$zims/$old.idx"
run 0 update
check "the e-reader has the new snapshot and its index" \
  eval 'same "$zims/$new" "$down/$new" && same "$zims/$new.idx" "$down/$new.idx"'
check "the old snapshot and its index are gone from the e-reader" eval 'gone "$down/$old" && gone "$down/$old.idx"'
check "the old one was removed before the new one was sent" before_in_log "delete $old" "send $new"
check "the app is still there" same "$work/data/app/$app2" "$down/$app2"
check "the old snapshot is gone from the Mac" eval 'gone "$zims/$old" && gone "$zims/$old.idx" && gone "$zims/$old.sha256"'
check "the top-articles build is not touched" eval '[ -f "$zims/wikipedia_en_top_nopic_2000-01.zim" ]'

scenario "update once more"
sent="$(log_lines)"
run 0 update
check "nothing is left to do" eval '[ "$(log_lines)" = "$sent" ]'

scenario "a Wikipedia that Kiwix does not publish"
use_book=wikipedia_en_nothing run fail fetch nopic
check "it says so" says "no nopic build of wikipedia_en_nothing"

scenario "a checksum that cannot be had"
bad="wikipedia_en_broken_nopic_2026-03.zim"
cp "$source_zim" "$kiwix/$bad"
echo "<html>503 Service Unavailable</html>" > "$kiwix/$bad.sha256"
use_book=wikipedia_en_broken run fail fetch nopic
check "it stops before downloading anything" eval 'says "checksum for $bad" && gone "$zims/partial/$bad"'
check "the bad answer is not kept" gone "$zims/$bad.sha256"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures of $checks checks"
  exit 1
fi
echo "all $checks checks passed"
