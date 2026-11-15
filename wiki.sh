#!/usr/bin/env bash
# Offline English Wikipedia for an Android e-reader: the Kiwix reader app plus one Wikipedia ZIM file.
# Run ./wiki.sh help for usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIM_DIR="$ROOT/data/zim"
PARTIAL_DIR="$ZIM_DIR/partial" # downloads in progress; a file in ZIM_DIR itself is complete and verified
APK_DIR="$ROOT/data/apk"
ZIM_URL="https://download.kiwix.org/zim/wikipedia"
APK_API="https://api.github.com/repos/kiwix/kiwix-android/releases/latest"
BOOK="${WIKI_BOOK:-wikipedia_en_all}"             # wikipedia_en_climate-change is a small build for testing
PORT="${WIKI_PORT:-8080}"                         # local preview port
DEVICE_FOLDER="${WIKI_DEVICE_FOLDER:-Download}"    # top-level folder on the e-reader that "push" copies into
SERVE_IMAGE="ghcr.io/kiwix/kiwix-serve:latest"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found. ${2:-}"; }
fetch_text() { curl -fsSL --max-time 60 --retry 6 --retry-delay 10 --retry-all-errors "$1"; }
size_of() { stat -f %z "$1"; }
on_disk() { echo $(($(stat -f %b "$1") * 512)); } # bytes actually stored; partial downloads can be sparse
free_in() { df -Pk "$1" | awk 'NR==2 { printf "%.0f", $4 * 1024 }'; }
human() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b / 1e9; else printf "%.0f MB", b / 1e6 }'; }

latest_zim() { # $1 = flavor; newest snapshot listed on the Kiwix download page
  fetch_text "$ZIM_URL/" | grep -oE 'href="[^"]+"' | sed -E 's/^href="//; s/"$//' |
    grep -E "^${BOOK}_$1_[0-9]{4}-[0-9]{2}\.zim$" | sort | tail -1
}

# Most recently downloaded (and verified) Wikipedia file.
local_zim() {
  local f
  f="$(ls -t "$ZIM_DIR"/"$BOOK"_*.zim 2>/dev/null | head -1 || true)"
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

# SHA-256 that Kiwix publishes for a ZIM file; cached next to the file.
published_sha256() { # $1 = final .zim path
  local sum="$1.sha256"
  [ -s "$sum" ] || fetch_text "$ZIM_URL/$(basename "$1").sha256" > "$sum"
  awk '{ print $1; exit }' "$sum"
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

cmd_verify() {
  local zim
  if [ "${1:-}" = "device" ]; then
    verify_device
    return
  fi
  zim="$(local_zim)"
  check_sha256 "$zim" "$(published_sha256 "$zim")"
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
  local dest="${1:-}" zim apk dev fs
  [ -n "$dest" ] || die "usage: ./wiki.sh copy /Volumes/<card>"
  [ -d "$dest" ] && [ -w "$dest" ] || die "$dest is not a writable folder"
  zim="$(local_zim)"
  dev="$(df -P "$dest" | awk 'NR==2 { print $1 }')"
  fs="$(mount | awk -v d="$dev" '$1 == d' | sed -E 's/.*\(([^,)]+).*/\1/' | head -1)"
  if [ "$fs" = "msdos" ] && [ "$(size_of "$zim")" -ge 4294967296 ]; then
    die "$dest is FAT32, which cannot hold files over 4 GB. Reformat the card as exFAT (Disk Utility > Erase > ExFAT) and try again."
  fi
  apk="$(local_apk)"
  require_space "$dest" $(($(size_of "$zim") + $([ -n "$apk" ] && size_of "$apk" || echo 0)))
  echo "copying $(basename "$zim") to $dest"
  rsync -h --progress --partial "$zim" "$dest/"
  check_sha256 "$dest/$(basename "$zim")" "$(published_sha256 "$zim")"
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
  local out tries=0
  while :; do
    sleep 3
    out="$("$@" 2>&1 || true)"
    case "$out" in *"No devices"* | *"No raw devices"* | *PANIC* | *"Error "[0-9]*) ;; *) break ;; esac
    tries=$((tries + 1))
    [ "$tries" -le 5 ] ||
      die "cannot talk to the e-reader. Plug it in with a USB cable, unlock it, and choose \"File transfer\" if it asks."
  done
  echo "$out"
}

device_folder_id() {
  mtp_query mtp-folders | awk -F'\t' -v n="$DEVICE_FOLDER" '$2 == n { print $1; exit }'
}

# Prints "<id> <size>" if a file named $1 exists in folder id $2 on the e-reader.
device_file() {
  mtp_query mtp-files | awk -v want="$1" -v folder="$2" '
    /^File ID:/ { id = $3 }
    /^ +Filename:/ { sub(/^ +Filename: /, ""); name = $0 }
    /^ +File size/ { size = $3 }
    /^ +Parent ID:/ { if (name == want && $3 == folder) { print id, size; exit } }'
}

push_file() { # $1 = local file, $2 = folder id on the e-reader
  local name size found free tries=0
  name="$(basename "$1")"
  size="$(size_of "$1")"
  while :; do
    found="$(device_file "$name" "$2")"
    if [ -n "$found" ]; then
      if [ "${found##* }" = "$size" ]; then
        echo "$name ($(human "$size")) is on the e-reader"
        return
      fi
      # MTP cannot resume, so an interrupted copy has to be removed and sent again.
      echo "removing an incomplete copy of $name from the e-reader"
      mtp_query mtp-delfile -n "${found%% *}" >/dev/null
    fi
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || die "could not copy $name to the e-reader. Check the cable, keep the e-reader awake, and run push again."
    free="$(mtp_query mtp-detect | awk '/FreeSpaceInBytes:/ { print $2; exit }')"
    [ "${free:-0}" -gt "$size" ] || die "the e-reader has $(human "${free:-0}") free; $name needs $(human "$size")"
    echo "copying $name ($(human "$size")) to the e-reader. Keep it plugged in and awake."
    sleep 3
    # The file keeps its local name on the e-reader; only the folder id in the second argument is used.
    mtp-sendfile "$1" "$2/$name" 2>&1 | mtp_progress || true
  done
}

# Copy the Kiwix app and the Wikipedia file to a USB-connected e-reader.
cmd_push() {
  need mtp-sendfile "Install it with: brew install libmtp"
  local zim apk folder
  zim="$(local_zim)"
  apk="$(local_apk)"
  stay_awake
  folder="$(device_folder_id)"
  [ -n "$folder" ] || die "the e-reader has no \"$DEVICE_FOLDER\" folder. Set WIKI_DEVICE_FOLDER to one of its top-level folders."
  [ -z "$apk" ] || push_file "$apk" "$folder"
  push_file "$zim" "$folder"
  echo "done. On the e-reader, open its file manager, go to $DEVICE_FOLDER and tap the Kiwix .apk to"
  echo "install it. Then open Kiwix and pick the Wikipedia file. To double-check the copy: ./wiki.sh verify device"
}

# Read the Wikipedia file back from the e-reader and compare checksums. It streams through a pipe,
# so it needs no disk space, but it takes about as long as the copy did.
verify_device() {
  need mtp-getfile "Install it with: brew install libmtp"
  local zim name found pipe reader got len tries=0
  zim="$(local_zim)"
  name="$(basename "$zim")"
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
    sleep 3
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
  [ "$got" = "$(published_sha256 "$zim")" ] ||
    die "the copy on the e-reader does not match the original. Run ./wiki.sh push again."
  echo "the copy on the e-reader matches: checksum OK"
}

cmd_status() {
  local f total
  for f in "$ZIM_DIR"/*.zim "$APK_DIR"/*.apk; do
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
  apk                      download the Kiwix reader app for Android
  status                   show what is downloaded
  verify                   re-check the downloaded Wikipedia file
  serve                    browse and search it on this Mac at http://localhost:8080 (needs Docker)
  copy <folder>            copy Wikipedia + app to an SD card and verify the copy
  push                     copy Wikipedia + app to a USB-connected e-reader (needs libmtp)
  verify device            read the e-reader's copy back over USB and re-check it

Flavors: nopic = every article, no images (~53 GB); mini = article intros only (~13 GB);
         maxi = every article with images (~120 GB).
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    fetch | apk | status | verify | serve | copy | push | help) "cmd_$cmd" "$@" ;;
    *) cmd_help; exit 1 ;;
  esac
}

# Keep this on one line so editing the script while a long download runs cannot affect it.
main "$@"; exit
