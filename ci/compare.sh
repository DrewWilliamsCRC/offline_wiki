#!/bin/bash
# Checks that the Kotlin code in reader/ and its Swift port in ios/ read a Wikipedia file the same
# way: the same search results in the same order, byte-identical articles, the same sections, and
# the same normalized titles. CI runs this on a small Wikipedia; it works on any file.
#
#   ci/compare.sh <file.zim>
#
# Needs both tools built first:
#   (cd reader && ./gradlew --no-daemon -q :indexer:installDist)
#   (cd ios && swift build -c release)
# The title index is built beside the file if it is not there yet.
#
# ALLOWED_NORMALIZE_DIFFERENCES (default 0) is how many titles may normalize differently. On full
# Wikipedia ten do: letters newer than the Unicode version the indexer's JVM knows.
#
# Written for macOS's bash 3.2, like wiki.sh.
set -euo pipefail

zim="${1:-}"
[ -f "$zim" ] || { echo "usage: ci/compare.sh <file.zim>" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kotlin="$root/reader/indexer/build/install/indexer/bin/indexer"
swift="$root/ios/.build/release/wikicheck"
[ -x "$kotlin" ] || { echo "error: build the indexer first: (cd reader && ./gradlew :indexer:installDist)" >&2; exit 2; }
[ -x "$swift" ] || { echo "error: build wikicheck first: (cd ios && swift build -c release)" >&2; exit 2; }
[ -f "$zim.idx" ] || "$kotlin" build "$zim" > /dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
differ() {
  echo "DIFFERENT: $1"
  failures=$((failures + 1))
}

# Search, one query per line below. The indexer's last line is its timing, which wikicheck does
# not print.
searches=0
: > "$work/titles"
while IFS= read -r query; do
  # Words are passed as separate arguments, as a person would type them.
  # shellcheck disable=SC2086
  "$kotlin" search "$zim" $query | sed '$d' > "$work/k"
  # shellcheck disable=SC2086
  "$swift" search "$zim" $query > "$work/s"
  searches=$((searches + 1))
  if ! cmp -s "$work/k" "$work/s"; then
    differ "search for \"$query\""
    diff "$work/k" "$work/s" | head -6 || true
  fi
  cat "$work/k" >> "$work/titles"
done << 'QUERIES'
a
b
c
e
i
m
r
s
t
ra
ray
charles
blues
soul
the
of
new
geo
what
1
19
ray charles
charles ray
the of
new york
united states
QUERIES
found="$(wc -l < "$work/titles" | tr -d ' ')"

# Articles and their sections, for the articles those searches found. A result reads "Title" or
# "Other name  ->  Title", and an article's path is its title with underscores for spaces.
sed -E 's/^.*  ->  //' "$work/titles" | sort -u | head -60 | tr ' ' '_' > "$work/paths"
articles=0
sections=0
while IFS= read -r path; do
  "$kotlin" cat "$zim" "$path" > "$work/k" 2> /dev/null || continue # not every title maps to a path
  "$swift" cat "$zim" "$path" > "$work/s" 2> /dev/null || true
  articles=$((articles + 1))
  cmp -s "$work/k" "$work/s" || differ "the bytes of $path"
  "$kotlin" sections "$zim" "$path" > "$work/k"
  "$swift" sections "$zim" "$path" > "$work/s"
  sections=$((sections + $(wc -l < "$work/k" | tr -d ' ')))
  if ! cmp -s "$work/k" "$work/s"; then
    differ "the sections of $path"
    diff "$work/k" "$work/s" | head -6 || true
  fi
done < "$work/paths"

# Every title, normalized in Swift and compared with what the Kotlin indexer stored in the index.
normalized="$("$swift" normalize "$zim" | tail -1)"
different="$(echo "$normalized" | sed -E 's/^.* ([0-9]+) normalized differently$/\1/')"
allowed="${ALLOWED_NORMALIZE_DIFFERENCES:-0}"
case "$different" in
  '' | *[!0-9]*) differ "normalize printed something unexpected: $normalized" ;;
  *) [ "$different" -le "$allowed" ] || differ "$different titles normalize differently (allowed: $allowed)" ;;
esac

echo "$searches searches ($found results), $articles articles, $sections sections; $normalized"
# A run that found nothing to compare proves nothing.
[ "$found" -ge 20 ] || differ "only $found search results to compare"
[ "$articles" -ge 10 ] || differ "only $articles articles to compare"
[ "$sections" -ge 10 ] || differ "only $sections sections to compare"
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures difference(s) between the Kotlin and Swift implementations"
  exit 1
fi
echo "the Kotlin and Swift implementations agree"
