#!/usr/bin/env bash
# Offline English Wikipedia for an Android e-reader: one Wikipedia ZIM file, read either with the
# purpose-built Wiki Reader app in reader/ (fast title search, e-ink friendly) or with Kiwix.
# Run ./wiki.sh help for usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${WIKI_DATA:-$ROOT/data}" # everything downloaded or built; ci/device.sh points it at a scratch folder
ZIM_DIR="$DATA_DIR/zim"
PARTIAL_DIR="$ZIM_DIR/partial" # downloads in progress; a file in ZIM_DIR itself is complete and verified
APK_DIR="$DATA_DIR/apk"        # the Kiwix app, as downloaded
APP_DIR="$DATA_DIR/app"        # the Wiki Reader app, as built from reader/
PUSHED_DIR="$DATA_DIR/pushed"  # checksums of files sent to the e-reader that can change under the same name
READER_DIR="$ROOT/reader"
INDEXER="$READER_DIR/indexer/build/install/indexer/bin/indexer"
ANDROID_SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ZIM_URL="${WIKI_ZIM_URL:-https://download.kiwix.org/zim/wikipedia}" # ci/device.sh serves its own
APK_API="https://api.github.com/repos/kiwix/kiwix-android/releases/latest"
BOOK="${WIKI_BOOK:-wikipedia_en_all}"             # wikipedia_en_ray-charles is a small build for testing
PORT="${WIKI_PORT:-8080}"                         # local preview port
DEVICE_FOLDER="${WIKI_DEVICE_FOLDER:-Download}"    # top-level folder on the e-reader that "push" copies into
MTP_PAUSE="${WIKI_MTP_PAUSE:-3}"                  # seconds between sessions with the e-reader (see mtp_query)
DOWNLOADS_DIR="${WIKI_DOWNLOADS:-$HOME/Downloads}" # where "push" offers to leave the app when no e-reader answers
# Where "publish" puts the indexes and the catalog the apps download from. The apps have this
# repository and tag built in (Catalog.URL in each), so a fork changes them there too.
PUBLISH_REPO="${WIKI_PUBLISH_REPO:-DrewWilliamsCRC/offline_wiki}"
PUBLISH_TAG="downloads"
PUBLISH_BOOKS="${WIKI_PUBLISH:-wikipedia_en_all wikipedia_en_top}" # offered in this order
SERVE_IMAGE="ghcr.io/kiwix/kiwix-serve:latest"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found. ${2:-}"; }
fetch_text() { curl -fsSL --max-time 60 --retry 6 --retry-delay 10 --retry-all-errors "$1"; }
size_of() { stat -f %z "$1"; }
on_disk() { echo $(($(stat -f %b "$1") * 512)); } # bytes actually stored; partial downloads can be sparse
free_in() { df -Pk "$1" | awk 'NR==2 { printf "%.0f", $4 * 1024 }'; }
human() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b / 1e9; else printf "%.0f MB", b / 1e6 }'; }

latest_zim() { # $1 = flavor; newest snapshot listed on the Kiwix download page, or nothing if none is
  local listing
  listing="$(fetch_text "$ZIM_URL/")" || die "could not read the list of files at $ZIM_URL"
  # "|| true": a book or flavor Kiwix does not publish matches nothing, which the caller reports.
  echo "$listing" | grep -oE 'href="[^"]+"' | sed -E 's/^href="//; s/"$//' |
    grep -E "^${BOOK}_$1_[0-9]{4}-[0-9]{2}\.zim$" | sort | tail -1 || true
}

# The Wikipedia file to work with: the one "update" has settled on, else the most recently
# downloaded (and verified) one.
local_zim() {
  local f="${USE_ZIM:-}"
  [ -n "$f" ] || f="$(ls -t "$ZIM_DIR"/"$BOOK"_*.zim 2>/dev/null | head -1 || true)"
  [ -n "$f" ] || die "no downloaded Wikipedia file yet. Run: ./wiki.sh fetch"
  echo "$f"
}

local_apk() { ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1 || true; }

# Keep the Mac awake until this script exits; a sleeping Mac stops long downloads and transfers.
stay_awake() {
  if command -v caffeinate >/dev/null 2>&1; then caffeinate -i -w $$ >/dev/null 2>&1 & fi
}

require_space() { # $1 = folder, $2 = bytes still to write
  [ "$(free_in "$1")" -gt "$2" ] || die "not enough disk space in $1: $(human "$2") needed, $(human "$(free_in "$1")") free"
}

# Single-connection resumable download of URL $1 into file $2 ($3 = size in bytes, looked up if omitted).
download() {
  local url="$1" part="$2" want="${3:-}" have tries=0
  [ ! -e "$part.aria2" ] || die "this download was started with aria2. Install it to resume: brew install aria2"
  [ -n "$want" ] || want="$(curl -fsSIL --max-time 60 --retry 6 --retry-delay 10 --retry-all-errors "$url" |
    tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n }')"
  [ -n "$want" ] || die "could not get the size of $url"
  echo "$want" > "$part.size"
  while :; do
    have=0
    [ -f "$part" ] && have="$(size_of "$part")"
    [ "$have" -eq "$want" ] && break
    [ "$have" -lt "$want" ] || die "$part is bigger than the published file. Delete it and run again."
    require_space "$(dirname "$part")" $((want - have))
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || die "the download kept failing. Run the same command again to resume."
    echo "downloading $(basename "$part"): $(human "$have") of $(human "$want") so far"
    curl -fL --connect-timeout 30 --speed-limit 1024 --speed-time 120 -C - -o "$part" "$url" || sleep 5
  done
  rm -f "$part.size"
}

# Multi-mirror download for big files. Individual Kiwix mirrors are often slow or stall, so aria2
# pulls from several at once, checks every 4 MB piece against the hashes in Kiwix's metalink,
# and resumes on re-run. $1 = canonical URL, $2 = file to write (named as on the server).
download_mirrored() {
  local meta="$2.meta4" want have=0 tries=0
  [ -s "$meta" ] || fetch_text "$1.meta4" > "$meta"
  want="$(sed -nE 's/.*<size>([0-9]+)<\/size>.*/\1/p' "$meta" | head -1)"
  [ -n "$want" ] || die "could not read the file size from $1.meta4"
  echo "$want" > "$2.size"
  [ -f "$2" ] && have="$(on_disk "$2")"
  [ "$have" -ge "$want" ] || require_space "$(dirname "$2")" $((want - have))
  echo "downloading $(basename "$2"): $(human "$(progress_of "$2")") of $(human "$want") so far"
  # falloc reserves the whole file up front. Without it macOS zero-fills gaps mid-download,
  # which stalls every connection at once.
  until aria2c --metalink-file="$meta" --dir="$(dirname "$2")" --continue=true \
    --split=12 --max-connection-per-server=2 --lowest-speed-limit=50K \
    --max-tries=30 --retry-wait=5 --timeout=60 --connect-timeout=30 \
    --file-allocation=falloc --summary-interval=60 --console-log-level=warn; do
    tries=$((tries + 1))
    [ "$tries" -le 20 ] || die "the download kept stopping. Run the same command again to resume."
    echo "download interrupted; retrying in 30 seconds"
    sleep 30
  done
  rm -f "$meta" "$2.size"
}

# Bytes downloaded so far. aria2 reserves the whole file up front, so the file's size says nothing;
# count the finished pieces recorded in its control file instead.
progress_of() {
  if [ -s "$1.aria2" ] && command -v python3 >/dev/null 2>&1; then
    python3 -I -c '
import struct, sys
d = open(sys.argv[1], "rb").read()
o = 10 + struct.unpack(">I", d[6:10])[0]
piece, total, _, n = struct.unpack(">IQQI", d[o:o + 24])
print(min(total, piece * sum(bin(b).count("1") for b in d[o + 24:o + 24 + n])))
' "$1.aria2"
  elif [ -f "$1" ]; then
    size_of "$1"
  else
    echo 0
  fi
}

check_sha256() { # $1 = file, $2 = expected hash
  local got
  echo "verifying $(basename "${1%.part}") ($(human "$(size_of "$1")")); large files take a few minutes"
  got="$(shasum -a 256 "$1" | awk '{ print $1 }')"
  [ "$got" = "$2" ] || die "checksum mismatch for $1 (expected $2, got $got). Delete the file and download it again."
  echo "checksum OK"
}

# SHA-256 that Kiwix publishes for a ZIM file; cached next to the file. Assign its result to a
# variable before using it: inside another command's arguments a failure here would go unnoticed,
# and the comparison would then report a good file as damaged.
published_sha256() { # $1 = final .zim path
  local sum="$1.sha256" hash
  [ -s "$sum" ] || fetch_text "$ZIM_URL/$(basename "$1").sha256" > "$sum" || true
  hash="$(awk '{ print $1; exit }' "$sum")"
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    rm -f "$sum"
    die "could not get Kiwix's checksum for $(basename "$1"). Check the connection and run the command again."
  fi
  echo "$hash"
}

cmd_fetch() {
  local flavor="${1:-nopic}" part name zim want
  case "$flavor" in nopic | mini | maxi) ;; *) die "flavor must be nopic, mini or maxi" ;; esac
  mkdir -p "$PARTIAL_DIR"
  # Finish an interrupted download instead of switching to a newer snapshot half-way through.
  part="$(ls "$PARTIAL_DIR"/"${BOOK}_${flavor}"_*.zim 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$part" ]; then name="$(basename "$part")"; else name="$(latest_zim "$flavor")"; fi
  [ -n "$name" ] || die "no $flavor build of $BOOK found at $ZIM_URL"
  zim="$ZIM_DIR/$name"
  part="$PARTIAL_DIR/$name"
  if [ -f "$zim" ]; then
    echo "$name is already downloaded and verified"
    return
  fi
  want="$(published_sha256 "$zim")"
  stay_awake
  if command -v aria2c >/dev/null 2>&1; then
    download_mirrored "$ZIM_URL/$name" "$part"
  else
    echo "aria2 not found, using a single connection (much faster with: brew install aria2)"
    download "$ZIM_URL/$name" "$part"
  fi
  check_sha256 "$part" "$want"
  mv "$part" "$zim"
  rmdir "$PARTIAL_DIR" 2>/dev/null || true
  echo "ready: $zim"
}

# The Kiwix app comes from the project's GitHub release, which publishes a SHA-256 for each file.
# The "universal" APK runs on any Android 7.1+ device, whatever its processor.
cmd_apk() {
  local name url size want apk
  need python3
  mkdir -p "$APK_DIR"
  read -r name url size want <<< "$(fetch_text "$APK_API" | python3 -I -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    if a["name"].endswith("-universal-standalone.apk"):
        print(a["name"], a["browser_download_url"], a["size"], (a.get("digest") or "").replace("sha256:", ""))
')"
  [ -n "${want:-}" ] || die "could not find the Kiwix APK and its checksum at $APK_API"
  apk="$APK_DIR/kiwix-$name"
  if [ -f "$apk" ]; then
    echo "$(basename "$apk") is already downloaded and verified"
    return
  fi
  download "$url" "$apk.part" "$size"
  check_sha256 "$apk.part" "$want"
  mv "$apk.part" "$apk"
  echo "ready: $apk"
}

# --- Wiki Reader: our own app and the title index it searches ------------------------------------

# Runs Gradle tasks in reader/. Without a daemon: these builds are rare and a daemon would linger.
gradle_build() {
  need java "Install a JDK, version 17 or newer (for example: brew install --cask temurin)."
  [ -d "$ANDROID_SDK/platforms" ] ||
    die "Android SDK not found at $ANDROID_SDK. Install it with: brew install --cask android-commandlinetools && sdkmanager \"platforms;android-34\" \"build-tools;36.0.0\""
  (cd "$READER_DIR" && ANDROID_HOME="$ANDROID_SDK" ./gradlew --no-daemon -q "$@")
}

# Build <wikipedia>.zim.idx, the title index Wiki Reader searches instead of Kiwix's much larger one.
cmd_index() {
  local zim popular
  zim="$(local_zim)"
  gradle_build :indexer:installDist
  # Kiwix's "top articles" build is chosen by page views. The index ranks its articles first, which
  # is what makes "par" suggest Paris and Paracetamol rather than whatever sorts first.
  popular="$(ls -t "$ZIM_DIR"/wikipedia_en_top_nopic_*.zim 2>/dev/null | head -1 || true)"
  if [ -z "$popular" ]; then
    echo "fetching Kiwix's top-articles build (about 3 GB); it tells the index which articles are well known"
    WIKI_BOOK=wikipedia_en_top "$0" fetch nopic
    popular="$(ls -t "$ZIM_DIR"/wikipedia_en_top_nopic_*.zim | head -1)"
  fi
  if [ "$popular" = "$zim" ]; then "$INDEXER" build "$zim"; else "$INDEXER" build "$zim" "$popular"; fi
}

# Build the Wiki Reader app. The file is named after its content, so a changed build gets a new name.
cmd_app() {
  local built="$READER_DIR/app/build/outputs/apk/release/app-release.apk" apk
  gradle_build :app:assembleRelease
  mkdir -p "$APP_DIR"
  apk="$APP_DIR/wiki-reader-$(shasum -a 256 "$built" | cut -c1-8).apk"
  rm -f "$APP_DIR"/wiki-reader-*.apk
  cp "$built" "$apk"
  echo "ready: $apk"
}

local_app() { ls -t "$APP_DIR"/wiki-reader-*.apk 2>/dev/null | head -1 || true; }

cmd_verify() {
  local zim want
  if [ "${1:-}" = "device" ]; then
    verify_device
    return
  fi
  zim="$(local_zim)"
  want="$(published_sha256 "$zim")"
  check_sha256 "$zim" "$want"
}

cmd_serve() {
  need docker "Install Docker Desktop, or open the file in the Kiwix desktop app instead."
  local zim
  zim="$(local_zim)"
  echo "serving $(basename "$zim") at http://localhost:$PORT (Ctrl-C to stop)"
  exec docker run --rm -p "127.0.0.1:$PORT:8080" -v "$ZIM_DIR:/data:ro" "$SERVE_IMAGE" "$(basename "$zim")"
}

# Copy the Wikipedia file (and the Kiwix APK) to an SD card or any folder, then read it back to verify.
cmd_copy() {
  local dest="${1:-}" zim apk dev fs want
  [ -n "$dest" ] || die "usage: ./wiki.sh copy /Volumes/<card>"
  [ -d "$dest" ] && [ -w "$dest" ] || die "$dest is not a writable folder"
  zim="$(local_zim)"
  want="$(published_sha256 "$zim")"
  dev="$(df -P "$dest" | awk 'NR==2 { print $1 }')"
  fs="$(mount | awk -v d="$dev" '$1 == d' | sed -E 's/.*\(([^,)]+).*/\1/' | head -1)"
  if [ "$fs" = "msdos" ] && [ "$(size_of "$zim")" -ge 4294967296 ]; then
    die "$dest is FAT32, which cannot hold files over 4 GB. Reformat the card as exFAT (Disk Utility > Erase > ExFAT) and try again."
  fi
  apk="$(local_apk)"
  require_space "$dest" $(($(size_of "$zim") + $([ -n "$apk" ] && size_of "$apk" || echo 0)))
  echo "copying $(basename "$zim") to $dest"
  rsync -h --progress --partial "$zim" "$dest/"
  check_sha256 "$dest/$(basename "$zim")" "$want"
  if [ -n "$apk" ]; then
    cp -X "$apk" "$dest/"
    echo "copied $(basename "$apk")"
  fi
  # macOS leaves "._name" metadata stubs on SD cards; Kiwix would list the .zim one as a broken book.
  rm -f "$dest/._$(basename "$zim")" "$dest/._$(basename "${apk:-none}")"
}

# --- USB transfer to the e-reader -------------------------------------------------------------
# This uses MTP, the "file transfer" mode every Android device offers, through the libmtp tools.
# adb is deliberately not used: some e-readers (the Viwoods AiPaper Reader, for one) show up in
# adb but refuse its shell, install and file-transfer commands.

# Show a libmtp transfer's progress on one updating line, plus any errors, and drop the rest.
# (The tools separate progress updates with carriage returns, which line-based filters never see.)
mtp_progress() {
  tr '\r' '\n' | awk '
    /^Progress/ { printf "\r%s", $0; p = 1; fflush(); next }
    /^(Error|No devices)/ { if (p) print ""; p = 0; print; fflush() }
    END { if (p) print "" }'
}

# Run a libmtp query and print its output. A connection opened straight after the previous one
# often fails half-way while still exiting 0, so pause first, and retry when the output shows it.
mtp_query() {
  local out tries=0 said_so=no
  while :; do
    sleep "$MTP_PAUSE"
    out="$("$@" 2>&1 || true)"
    case "$out" in
      *"No devices"* | *"No Devices"* | *"no devices"* | *"No raw devices"* | *PANIC* | *"Error "[0-9]*) said_so=yes ;;
      *"File ID:"*) break ;;
      # A file listing with no files in it is usually a connection that failed quietly; that has
      # happened in the first moments after the e-reader switches to file transfer. So it is asked
      # again, and believed only if every try comes back the same: an e-reader with no files yet.
      *) [ "$1" = mtp-files ] || break ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -gt 5 ]; then
      [ "$said_so" = yes ] || break
      die "cannot talk to the e-reader. Plug it in with a USB cable, unlock it, and choose \"File transfer\" if it asks."
    fi
  done
  echo "$out"
}

# The awk programs that read a query's output take the first match and keep reading to the end.
# Stopping at the match ("exit") closes the pipe on whatever is still being written, and on an
# e-reader with a few hundred files that ends the whole script, silently, with status 141.
device_folder_id() {
  mtp_query mtp-folders | awk -F'\t' -v n="$DEVICE_FOLDER" '$2 == n && !found { print $1; found = 1 }'
}

# Prints "<id> <size>" if a file named $1 exists in folder id $2 on the e-reader.
device_file() {
  mtp_query mtp-files | awk -v want="$1" -v folder="$2" '
    /^File ID:/ { id = $3 }
    /^ +Filename:/ { sub(/^ +Filename: /, ""); name = $0 }
    /^ +File size/ { size = $3 }
    /^ +Parent ID:/ { if (name == want && $3 == folder && !found) { print id, size; found = 1 } }'
}

# $1 = local file, $2 = folder id on the e-reader, $3 = "mutable" for a file that can change while
# keeping its name and size (the index): its checksum at the last push is then compared as well.
push_file() {
  local name size found free tries=0 sum="" mark
  name="$(basename "$1")"
  size="$(size_of "$1")"
  mark="$PUSHED_DIR/$name.sha256"
  if [ "${3:-}" = mutable ]; then sum="$(shasum -a 256 "$1" | cut -d' ' -f1)"; fi
  while :; do
    found="$(device_file "$name" "$2")"
    if [ -n "$found" ]; then
      if [ "${found##* }" = "$size" ] && { [ -z "$sum" ] || [ "$(cat "$mark" 2>/dev/null || true)" = "$sum" ]; }; then
        echo "$name ($(human "$size")) is on the e-reader"
        return
      fi
      # MTP can neither resume nor overwrite, so an interrupted or outdated copy is removed first.
      echo "removing an incomplete or outdated copy of $name from the e-reader"
      mtp_query mtp-delfile -n "${found%% *}" >/dev/null
    fi
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || die "could not copy $name to the e-reader. Check the cable, keep the e-reader awake, and run push again."
    free="$(mtp_query mtp-detect | awk '/FreeSpaceInBytes:/ && !found { print $2; found = 1 }')"
    # An app that has a deleted file open keeps its space until it lets go, which is the usual
    # reason for too little room straight after an older snapshot was removed.
    [ "${free:-0}" -gt "$size" ] || die "the e-reader has $(human "${free:-0}") free; $name needs $(human "$size"). If an older Wikipedia was just removed from it, an app may still be holding that space: press the e-reader's home button to leave Wiki Reader (or restart the e-reader), then run the command again."
    echo "copying $name ($(human "$size")) to the e-reader. Keep it plugged in and awake."
    sleep "$MTP_PAUSE"
    # The file keeps its local name on the e-reader; only the folder id in the second argument is used.
    mtp-sendfile "$1" "$2/$name" 2>&1 | mtp_progress || true
    if [ -n "$sum" ]; then
      mkdir -p "$PUSHED_DIR"
      echo "$sum" > "$mark"
    fi
  done
}

# Copy Wikipedia to a USB-connected e-reader, with Wiki Reader and its index, or with Kiwix
# ("push kiwix"). Files already there are skipped, so this is also how updates are sent.
cmd_push() {
  need mtp-sendfile "Install it with: brew install libmtp"
  local zim app folder
  zim="$(local_zim)"
  if [ "${1:-}" = kiwix ]; then
    app="$(local_apk)"
    [ -n "$app" ] || die "download Kiwix first: ./wiki.sh apk"
  else
    app="$(local_app)"
    [ -n "$app" ] || die "build the reader app first: ./wiki.sh app"
    [ -f "$zim.idx" ] || die "build the search index first: ./wiki.sh index"
  fi
  stay_awake
  # This is the first thing asked of the e-reader, so it is where having none shows: mtp_query has
  # then said so. One thing can still be done without it, for our own app. The script ends here
  # either way, because "update" carries on after a push as if the e-reader then had everything.
  if ! folder="$(device_folder_id)"; then
    if [ "${1:-}" != kiwix ] && app_to_downloads "$app"; then exit 0; fi
    exit 1
  fi
  [ -n "$folder" ] || die "the e-reader has no \"$DEVICE_FOLDER\" folder. Set WIKI_DEVICE_FOLDER to one of its top-level folders."
  if [ "${1:-}" != kiwix ]; then
    # Each build of the app has its own file name; earlier ones are only clutter once a newer one is sent.
    device_matching "$folder" "wiki-reader-" | while read -r id name; do
      [ "$name" = "$(basename "$app")" ] && continue
      echo "removing the older $name from the e-reader"
      mtp_query mtp-delfile -n "$id" > /dev/null < /dev/null
    done
  fi
  push_file "$app" "$folder"
  [ "${1:-}" = kiwix ] || push_file "$zim.idx" "$folder" mutable
  push_file "$zim" "$folder"
  echo "done. On the e-reader, open its file manager, go to $DEVICE_FOLDER and tap $(basename "$app") to install it."
  if [ "${1:-}" = kiwix ]; then
    echo "Then open Kiwix and pick the Wikipedia file."
  else
    echo "Then open Wiki Reader; the first time, it asks for access to files so it can read Wikipedia."
  fi
}

# What "push" offers when no e-reader answers: the app, copied to this Mac's Downloads folder, to
# reach the e-reader some other way. The app is small enough for that; Wikipedia is not.
# Succeeds only if the app was copied. This is the one question the script asks, and "read -p"
# shows it only at a terminal: a run with nobody there gets no answer, which is a no, and prints
# and does what it always has.
app_to_downloads() { # $1 = the app
  local name answer=""
  name="$(basename "$1")"
  read -r -p "Without the e-reader, the app alone can go to this Mac's Downloads folder, to be installed some other way."$'\n'"Copy $name to $DOWNLOADS_DIR? [y/N] " answer || true
  case "$answer" in
    [yY] | [yY][eE][sS]) ;;
    *) return 1 ;;
  esac
  [ -d "$DOWNLOADS_DIR" ] || die "there is no folder $DOWNLOADS_DIR. Set WIKI_DOWNLOADS to the folder to copy into."
  cp "$1" "$DOWNLOADS_DIR/"
  echo "copied: $DOWNLOADS_DIR/$name"
  echo "Get that file onto the e-reader, then tap it in the e-reader's file manager to install it."
  echo "Wikipedia and its index still go over USB: plug the e-reader in and run ./wiki.sh push."
}

# Whether an e-reader is plugged in and answering. Unlike mtp_query this does not give up loudly:
# "update" can do its work on the Mac without one.
device_connected() {
  command -v mtp-detect >/dev/null 2>&1 || return 1
  local tries=0
  while [ "$tries" -lt 3 ]; do
    sleep "$MTP_PAUSE"
    case "$(mtp-detect 2>&1 || true)" in *FreeSpaceInBytes*) return 0 ;; esac
    tries=$((tries + 1))
  done
  return 1
}

# Prints "<id> <name>" for every file in folder id $1 on the e-reader whose name starts with $2.
device_matching() {
  mtp_query mtp-files | awk -v folder="$1" -v prefix="$2" '
    /^File ID:/ { id = $3 }
    /^ +Filename:/ { sub(/^ +Filename: /, ""); name = $0 }
    /^ +Parent ID:/ { if ($3 == folder && index(name, prefix) == 1) print id, name }'
}

# Move to the newest snapshot Kiwix has published: download it, index it, swap it onto the e-reader
# and drop the old copies. Neither the Mac nor the e-reader need hold two snapshots at once.
# Each step looks at what is actually there, so it can be run again at any point: without the
# e-reader it prepares everything on the Mac, and with it plugged in later it finishes the swap.
cmd_update() {
  local flavor="${1:-}" mine known latest size partial needed old connected=no folder="" on_device=""
  mkdir -p "$ZIM_DIR"
  mine="$(ls "$ZIM_DIR"/"$BOOK"_*.zim 2>/dev/null | sort | tail -1 || true)"
  if device_connected; then
    connected=yes
    folder="$(device_folder_id)"
    [ -n "$folder" ] || die "the e-reader has no \"$DEVICE_FOLDER\" folder. Set WIKI_DEVICE_FOLDER to one of its top-level folders."
    on_device="$(device_matching "$folder" "${BOOK}_" | awk '$2 ~ /\.zim$/ { print $2 }')"
  fi
  if [ -z "$flavor" ]; then
    # Stay with the flavor already in use. Names look like <book>_<flavor>_<year>-<month>.zim.
    known="$({ [ -z "$mine" ] || basename "$mine"; echo "$on_device"; } | grep -v '^$' | sort | tail -1 || true)"
    flavor="${known#"${BOOK}"_}"
    flavor="${flavor%_*}"
    [ -n "$flavor" ] || flavor=nopic
  fi
  latest="$(latest_zim "$flavor")"
  [ -n "$latest" ] || die "no $flavor build of $BOOK found at $ZIM_URL"
  echo "newest published by Kiwix: $latest"
  echo "on this Mac:               $(if [ -n "$mine" ]; then basename "$mine"; else echo nothing; fi)"
  if [ "$connected" = yes ]; then
    echo "on the e-reader:           $(echo "${on_device:-nothing}" | tr '\n' ' ')"
  else
    echo "on the e-reader:           unknown (not plugged in)"
  fi

  if [ ! -f "$ZIM_DIR/$latest" ]; then
    if echo "$on_device" | grep -qxF "$latest"; then
      echo "the e-reader already has the newest snapshot; nothing to do."
      return
    fi
    size="$(fetch_text "$ZIM_URL/$latest.meta4" | sed -nE 's/.*<size>([0-9]+)<\/size>.*/\1/p' | head -1)"
    [ -n "$size" ] || die "could not get the size of $latest"
    partial="$PARTIAL_DIR/$latest"
    needed="$size"
    [ ! -f "$partial" ] || needed=$((size - $(on_disk "$partial")))
    if [ "$(free_in "$ZIM_DIR")" -le "$needed" ]; then
      for old in "$ZIM_DIR"/"${BOOK}_${flavor}"_*.zim; do
        [ -e "$old" ] || continue
        echo "removing $(basename "$old") from this Mac to make room for the new snapshot"
        rm -f "$old" "$old.idx" "$old.sha256"
      done
    fi
    cmd_fetch "$flavor"
  fi
  # From here on, index and push must mean this snapshot, whatever else is lying in the folder.
  USE_ZIM="$ZIM_DIR/$latest"
  [ "$USE_ZIM.idx" -nt "$USE_ZIM" ] || cmd_index
  [ -n "$(local_app)" ] || cmd_app

  if [ "$connected" != yes ]; then
    echo "$latest is downloaded and indexed. Plug in the e-reader and run ./wiki.sh update again to copy it across."
    return
  fi
  # The e-reader cannot hold two snapshots, so older ones go first. From here until the copy
  # finishes there may be no Wikipedia on it; if the copy is interrupted, run update again.
  device_matching "$folder" "${BOOK}_${flavor}_" | while read -r id name; do
    case "$name" in
      "$latest" | "$latest.idx") ;;
      *)
        echo "removing $name from the e-reader"
        mtp_query mtp-delfile -n "$id" > /dev/null < /dev/null
        ;;
    esac
  done
  cmd_push
  # Only now that the e-reader has the new snapshot are the older copies here surplus.
  for old in "$ZIM_DIR"/"${BOOK}_${flavor}"_*.zim; do
    [ "$old" = "$ZIM_DIR/$latest" ] || rm -f "$old" "$old.idx" "$old.sha256"
  done
  echo "the e-reader is on $latest"
  echo "To offer it in the apps' Downloads too, run ./wiki.sh publish."
}

# Read the Wikipedia file back from the e-reader and compare checksums. It streams through a pipe,
# so it needs no disk space, but it takes about as long as the copy did.
verify_device() {
  need mtp-getfile "Install it with: brew install libmtp"
  local zim name found pipe reader got len want tries=0
  zim="$(local_zim)"
  name="$(basename "$zim")"
  want="$(published_sha256 "$zim")" # before the long read, so a missing checksum is not found out after it
  stay_awake
  found="$(device_file "$name" "$(device_folder_id)")"
  [ -n "$found" ] || die "$name is not in the $DEVICE_FOLDER folder on the e-reader. Run: ./wiki.sh push"
  [ "${found##* }" = "$(size_of "$zim")" ] || die "the copy of $name on the e-reader is incomplete. Run: ./wiki.sh push"
  pipe="$(mktemp -u "${TMPDIR:-/tmp}/wiki-readback.XXXXXX")"
  while :; do
    mkfifo "$pipe"
    tee >(shasum -a 256 > "$pipe.sum") < "$pipe" | wc -c > "$pipe.len" &
    reader=$!
    exec 3> "$pipe" # held open so the checksum only finishes once the transfer has ended
    echo "reading $name ($(human "${found##* }")) back from the e-reader. Keep it plugged in and awake."
    sleep "$MTP_PAUSE"
    mtp-getfile "${found%% *}" "$pipe" 2>&1 | mtp_progress || true
    exec 3>&-
    # Wait for the reader only: a bare "wait" would also wait for stay_awake, which never exits first.
    wait "$reader"
    for _ in 1 2 3 4 5 6 7 8 9 10; do # the checksum process finishes a moment after the reader
      [ ! -s "$pipe.sum" ] || break
      sleep 1
    done
    got="$(awk '{ print $1 }' "$pipe.sum")"
    len="$(tr -d ' ' < "$pipe.len")"
    rm -f "$pipe" "$pipe.sum" "$pipe.len"
    [ "$len" != "${found##* }" ] || break
    # A short read means the connection failed, not that the copy is bad.
    tries=$((tries + 1))
    [ "$tries" -le 2 ] || die "could not read $name back from the e-reader. Check the cable, keep it awake, and try again."
    echo "the transfer was cut short; trying again"
  done
  [ "$got" = "$want" ] ||
    die "the copy on the e-reader does not match the original. Run ./wiki.sh push again."
  echo "the copy on the e-reader matches: checksum OK"
}

# --- What the apps can download ---------------------------------------------------------------

# The words an app shows for a book, from its file name: <book>_<flavor>_<year>-<month>.zim.
book_title() {
  case "$1" in
    wikipedia_en_all_*) echo "All of English Wikipedia" ;;
    wikipedia_en_top_*) echo "English Wikipedia's best-known articles" ;;
    *) echo "${1%_*}" ;;
  esac
}
book_about() {
  local what
  case "$1" in
    *_nopic_*) what="without pictures" ;;
    *_mini_*) what="only the start of each, without pictures" ;;
    *_maxi_*) what="with pictures" ;;
    *) what="" ;;
  esac
  case "$1" in
    wikipedia_en_all_*) echo "Every article${what:+, $what}." ;;
    wikipedia_en_top_*) echo "The most-read articles${what:+, $what}. A quick start on a small device." ;;
    *) echo "A Wikipedia from Kiwix${what:+, $what}." ;;
  esac
}

# One entry of the catalog's "files": $1 = name, $2 = URL, $3 = local copy, $4 = its SHA-256.
catalog_file() {
  printf '        {"name": "%s", "url": "%s", "size": %s, "sha256": "%s"}' "$1" "$2" "$(size_of "$3")" "$4"
}

# Offer the newest downloaded snapshot of each book in PUBLISH_BOOKS to the apps: upload its index
# to the GitHub release they read, with a catalog.json that lists each book's two files. The
# Wikipedia file itself is not uploaded: the apps fetch it from Kiwix, as "fetch" does.
cmd_publish() {
  need gh "Install it with: brew install gh, then sign in with: gh auth login"
  local work book zim name sum want first=yes uploaded line missing=()
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expanded now: the folder is local to this function
  trap "rm -rf '$work'" EXIT
  : > "$work/indexes" # "<name> <sha256> <path>" for each index the catalog names
  {
    echo '{'
    echo '  "format": 1,'
    echo '  "books": ['
  } > "$work/catalog.json"
  for book in $PUBLISH_BOOKS; do
    zim="$(ls "$ZIM_DIR"/"$book"_*.zim 2>/dev/null | sort | tail -1 || true)"
    if [ -z "$zim" ] || [ ! "$zim.idx" -nt "$zim" ]; then
      echo "skipping $book: no snapshot of it here with its index (./wiki.sh fetch, then index)"
      continue
    fi
    name="$(basename "$zim")"
    sum="$(shasum -a 256 "$zim.idx" | cut -d' ' -f1)"
    want="$(published_sha256 "$zim")" # here, not inside the block below, where a failure would go unseen
    echo "$name.idx $sum $zim.idx" >> "$work/indexes"
    [ "$first" = yes ] || echo '    ,' >> "$work/catalog.json"
    first=no
    {
      echo '    {'
      printf '      "id": "%s", "title": "%s", "about": "%s",\n' "${name%_*}" "$(book_title "$name")" "$(book_about "$name")"
      echo '      "files": ['
      # The index first: it is small, and on its own it is harmless (each app looks for a .zim).
      catalog_file "$name.idx" "https://github.com/$PUBLISH_REPO/releases/download/$PUBLISH_TAG/$name.idx" "$zim.idx" "$sum"
      echo ','
      catalog_file "$name" "$ZIM_URL/$name" "$zim" "$want"
      echo
      echo '      ]'
      echo '    }'
    } >> "$work/catalog.json"
    echo "offering $name ($(human "$(size_of "$zim")")) and its index"
  done
  printf '  ]\n}\n' >> "$work/catalog.json"
  [ "$first" = no ] || die "nothing to publish: none of $PUBLISH_BOOKS is here with its index"
  python3 -I -m json.tool "$work/catalog.json" > /dev/null || die "the catalog came out malformed"

  if ! gh release view "$PUBLISH_TAG" --repo "$PUBLISH_REPO" > /dev/null 2>&1; then
    echo "creating the \"$PUBLISH_TAG\" release on $PUBLISH_REPO"
    gh release create "$PUBLISH_TAG" --repo "$PUBLISH_REPO" --latest=false --title "Downloads for Wiki Reader" \
      --notes "What the Wiki Reader apps download: catalog.json lists each Wikipedia the apps offer, with the title index built for it here. Wikipedia itself comes from Kiwix (download.kiwix.org). Content from Wikipedia, CC BY-SA 4.0. Made by ./wiki.sh publish." > /dev/null
  fi
  # An index is sent only if GitHub does not already hold the same bytes: the apps check each
  # download against the checksum in the catalog.
  uploaded="$(gh api "repos/$PUBLISH_REPO/releases/tags/$PUBLISH_TAG" --jq '.assets[] | "\(.name) \(.digest)"')"
  while read -r line; do
    set -- $line
    if echo "$uploaded" | grep -qxF "$1 sha256:$2"; then
      echo "$1 is already uploaded"
    else
      missing+=("$3")
    fi
  done < "$work/indexes"
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "uploading ${#missing[@]} index file(s); the full Wikipedia's is about 0.7 GB"
    gh release upload "$PUBLISH_TAG" "${missing[@]}" --repo "$PUBLISH_REPO" --clobber
  fi
  # The catalog goes last, so that it never names an index that is not there yet.
  gh release upload "$PUBLISH_TAG" "$work/catalog.json" --repo "$PUBLISH_REPO" --clobber
  echo "published: https://github.com/$PUBLISH_REPO/releases/download/$PUBLISH_TAG/catalog.json"
}

cmd_status() {
  local f total
  for f in "$ZIM_DIR"/*.zim "$ZIM_DIR"/*.zim.idx "$APP_DIR"/*.apk "$APK_DIR"/*.apk; do
    [ -e "$f" ] || continue
    echo "ready        $(basename "$f")  $(human "$(size_of "$f")")"
  done
  for f in "$PARTIAL_DIR"/*.zim "$APK_DIR"/*.apk.part; do
    [ -e "$f" ] || continue
    total="$(cat "$f.size" 2>/dev/null || true)"
    echo "downloading  $(basename "${f%.part}")  $(human "$(progress_of "$f")")${total:+ of $(human "$total")}"
  done
}

cmd_help() {
  cat <<'EOF'
usage: ./wiki.sh <command>

  fetch [nopic|mini|maxi]  download English Wikipedia and verify it (default: nopic; resumable)
  index                    build the title index that the Wiki Reader app searches
  app                      build the Wiki Reader app (needs a JDK and the Android SDK)
  push                     copy Wikipedia, its index and Wiki Reader to a USB-connected e-reader (needs libmtp);
                           if no e-reader answers, it offers to copy the app to this Mac's Downloads folder
  update                   move to Kiwix's newest snapshot: download, index, swap it onto the e-reader
  verify device            read the e-reader's copy of Wikipedia back over USB and re-check it
  publish                  let the apps download the Wikipedia here: upload its index and a catalog
                           to this repository's "downloads" release on GitHub (needs gh)
  status                   show what is downloaded
  verify                   re-check the downloaded Wikipedia file
  serve                    browse and search it on this Mac at http://localhost:8080 (needs Docker)

 To use Kiwix instead of Wiki Reader:
  apk                      download the Kiwix app for Android
  push kiwix               copy Wikipedia and the Kiwix app to a USB-connected e-reader
  copy <folder>            copy Wikipedia and the Kiwix app to an SD card and verify the copy

Flavors: nopic = every article, no images (~53 GB); mini = article intros only (~13 GB);
         maxi = every article with images (~120 GB).
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    fetch | index | app | apk | status | verify | serve | copy | push | update | publish | help) "cmd_$cmd" "$@" ;;
    *) cmd_help; exit 1 ;;
  esac
}

# Keep this on one line so editing the script while a long download runs cannot affect it.
main "$@"; exit
