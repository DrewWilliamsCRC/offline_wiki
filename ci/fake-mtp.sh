#!/bin/bash
# Stand-ins for the libmtp tools (mtp-detect, mtp-folders, mtp-files, mtp-delfile, mtp-sendfile,
# mtp-getfile), so the half of wiki.sh that talks to the e-reader can be tested without one.
# ci/device.sh links this file under each tool's name and puts the links first on PATH; which tool
# to be is taken from the name it was started by.
#
# The "e-reader" is the folder FAKE_MTP_DIR. Its sub-folders are the device's top-level folders and
# the files in them are the device's files; ids are inode numbers. It behaves as the real tools and
# the real device do where wiki.sh depends on it: output in libmtp's format, failures that still
# exit 0, a transfer that keeps the local file's name, and no overwriting of a file that is there.
# Files whose names start with a dot steer it:
#
#   .free       free space to report, in bytes (default: plenty)
#   .unplugged  if present, there is no device, as in charge-only USB mode
#   .flaky      a number: that many of the next sessions fail the way back-to-back ones do
#   .cut        a number: that many of the next transfers stop half-way
#   .log        every deletion and transfer, in order, for the test to read
#
# Written for macOS's bash 3.2 and its stat, like wiki.sh.
set -euo pipefail

dev="${FAKE_MTP_DIR:?set FAKE_MTP_DIR to the folder that plays the e-reader}"
tool="$(basename "$0")"

# Succeeds, and counts down, while the number in file $1 is above zero.
take() {
  local n
  n="$(cat "$dev/$1" 2> /dev/null || echo 0)"
  [ "$n" -gt 0 ] || return 1
  echo $((n - 1)) > "$dev/$1"
}

by_id() { find "$dev" -mindepth "$1" -maxdepth "$1" -inum "$2" ! -name '.*' | head -1; } # $1 = 1 folder, 2 file

echo "libmtp version: 1.1.23"
echo
if [ -e "$dev/.unplugged" ]; then
  case "$tool" in
    mtp-detect) echo "   No raw devices found." ;;
    mtp-files) echo "mtp-files: No Devices have been found" ;;
    mtp-folders) echo "mtp-folders: no devices found" ;;
    *) echo "No devices." ;;
  esac
  exit 0
fi
if take .flaky; then
  # mtp-files fails quietly, with a listing that has no files in it; the others say something.
  [ "$tool" = mtp-files ] || echo "LIBMTP PANIC: Unable to read device information on device"
  exit 0
fi

case "$tool" in
  mtp-detect)
    echo "Device 0 (VID=2d95 and PID=6002) is UNKNOWN."
    echo "   Found 1 device(s):"
    echo "      MaxCapacity: 119808000000"
    echo "      FreeSpaceInBytes: $(cat "$dev/.free" 2> /dev/null || echo 900000000000)"
    echo "      FreeSpaceInObjects: 1073741824"
    ;;

  mtp-folders)
    for folder in "$dev"/*/; do
      [ -d "$folder" ] || continue
      printf '%s\t%s\n' "$(stat -f %i "$folder")" "$(basename "$folder")"
    done
    ;;

  mtp-files)
    echo "Listing File Information on Device with name: (NULL)"
    for folder in "$dev"/*/; do
      [ -d "$folder" ] || continue
      parent="$(stat -f %i "$folder")"
      # One stat for the whole folder: thousands of files are part of what is tested.
      find "$folder" -mindepth 1 -maxdepth 1 -type f ! -name '.*' -exec stat -f '%i %z %N' {} + | sort -k3 |
        while read -r id size path; do
          printf 'File ID: %s\n   Filename: %s\n   File size %s (0x%016X) bytes\n   Parent ID: %s\n' \
            "$id" "${path##*/}" "$size" "$size" "$parent"
          printf '   Storage ID: 0x00010001\n   Filetype: Undefined type\n'
        done
    done
    ;;

  mtp-delfile)
    [ "${1:-}" = -n ] && [ -n "${2:-}" ] || { echo "Usage: delfile -n <fileid>"; exit 0; }
    file="$(by_id 2 "$2")"
    [ -n "$file" ] || { echo "Failed to remove file"; exit 0; }
    rm -f "$file"
    echo "delete $(basename "$file")" >> "$dev/.log"
    ;;

  mtp-sendfile)
    [ -f "${1:-}" ] && [ -n "${2:-}" ] || { echo "usage: sendfile <local filename> <remote filename>"; exit 0; }
    folder="$(by_id 1 "${2%%/*}")"
    [ -n "$folder" ] || { echo "Error 2: could not find the parent folder"; exit 0; }
    dest="$folder/$(basename "$1")" # the local name, whatever the second argument says after the id
    size="$(stat -f %z "$1")"
    echo "Sending $1 to $2"
    echo "send $(basename "$1")" >> "$dev/.log"
    if [ -e "$dest" ]; then
      echo "Error 2: PTP Layer error 2002: a file of that name is already there"
      exit 0
    fi
    if take .cut; then
      head -c $((size / 2)) "$1" > "$dest"
      printf 'Progress: %s of %s (50%%)\r' $((size / 2)) "$size"
      printf '\nError sending file.\n'
      exit 0
    fi
    cp "$1" "$dest"
    printf 'Progress: %s of %s (50%%)\rProgress: %s of %s (100%%)\r' $((size / 2)) "$size" "$size" "$size"
    printf '\nNew file ID: %s\n' "$(stat -f %i "$dest")"
    ;;

  mtp-getfile)
    file="$(by_id 2 "${1:-0}")"
    [ -n "$file" ] && [ -n "${2:-}" ] || { echo "Error getting file from MTP device."; exit 0; }
    size="$(stat -f %z "$file")"
    echo "Getting file/track $1 to local file $2"
    if take .cut; then
      head -c $((size / 2)) "$file" > "$2"
      printf 'Progress: %s of %s (50%%)\r\nError getting file from MTP device.\n' $((size / 2)) "$size"
      exit 0
    fi
    cat "$file" > "$2"
    printf 'Progress: %s of %s (100%%)\r\n' "$size" "$size"
    ;;

  *)
    echo "fake-mtp.sh: started as \"$tool\", which is not a tool it stands in for" >&2
    exit 2
    ;;
esac
