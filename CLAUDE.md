# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

English Wikipedia, fully offline, on an Android e-ink reader. The content is a single `.zim` file
published by Kiwix (the `nopic` build: every article, no images, 52.7 GB). Two things live here:

- [wiki.sh](wiki.sh): a macOS shell script that downloads and verifies the `.zim`, builds the search
  index and the app, and copies everything to the e-reader over USB.
- [reader/](reader/): **Wiki Reader**, a purpose-built Android app that reads the `.zim` directly,
  plus the tool that builds its title index. It exists because Kiwix's own title search is very
  slow on this device.

[README.md](README.md) is the user-facing guide (setup, the on-device steps, how search ranks).

## Commands

```sh
./wiki.sh help            # every command
./wiki.sh fetch           # download + checksum the Wikipedia file into data/zim/
./wiki.sh index           # build data/zim/<file>.zim.idx
./wiki.sh app             # build data/app/wiki-reader-<hash>.apk
./wiki.sh push            # app + index + Wikipedia to the e-reader (skips what is already there)
./wiki.sh update          # move to Kiwix's newest snapshot end to end
bash -n wiki.sh           # the only "lint" for the script
```

Building the Gradle project directly (what `index` and `app` do):

```sh
cd reader && ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  ./gradlew --no-daemon -q :indexer:installDist :app:assembleRelease
```

There is no test suite and no linter. Verification is done with the indexer's own commands, which
exercise the same `core` code the app runs:

```sh
I=reader/indexer/build/install/indexer/bin/indexer
$I search data/zim/<file>.zim <words>   # exactly what the app would list, with timing
$I cat data/zim/<file>.zim <Path>       # an article's bytes (follows redirects)
$I info data/zim/<file>.zim
```

Work against a small build rather than the 52.7 GB file: `WIKI_BOOK` selects another Kiwix
Wikipedia, and every command honours it.

```sh
WIKI_BOOK=wikipedia_en_ray-charles ./wiki.sh fetch nopic   # 28 MB; has two published snapshots
WIKI_BOOK=wikipedia_en_top ./wiki.sh fetch nopic           # 2.7 GB; realistic, and also the ranking input
```

## The e-reader, and why testing is indirect

The device is a Viwoods AiPaper Reader on Android 14. It shapes most decisions here:

- **adb is useless on it.** It appears in `adb devices`, but its firmware refuses shell commands,
  `adb install` and `adb push`. Nothing can be installed, launched or inspected from the Mac.
- **Files go over MTP** via the libmtp tools (`mtp-files`, `mtp-sendfile`, ...). The user installs an
  APK by tapping it in the e-reader's file manager.
- So **test in an emulator before pushing**, and expect each on-device round trip to cost the user
  manual steps. An Android 14 AVD shaped like the e-reader's screen (824x1648 at 300 dpi) works:

```sh
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ADB_MDNS=0
$ANDROID_HOME/emulator/emulator -avd wikitest -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect &
adb -e push data/zim/wikipedia_en_top_nopic_*.zim /sdcard/Download/      # and its .idx
adb -e install -r data/app/wiki-reader-*.apk
adb -e shell appops set dev.offlinewiki.reader MANAGE_EXTERNAL_STORAGE allow
adb -e shell am start -n dev.offlinewiki.reader/.MainActivity
adb -e exec-out screencap -p > shot.png                                  # then look at it
adb -e shell settings put system font_scale 1.3                          # reproduces the e-reader's larger text
```

`adb` hangs at startup on this Mac unless `ADB_MDNS=0` is set.

MTP behaviour that the script works around (keep these in mind when touching `mtp_query`,
`push_file` or `cmd_update`):

- Sessions opened back to back fail while still exiting 0. Signs are `PANIC`, `Error <n>:`,
  "no devices", or a file listing with no files. Pause about 3 seconds between sessions and retry.
- `mtp-sendfile <local> <folder id>/<name>` keeps the **local** file's name; only the folder id in
  the second argument is used.
- There is no resume and no overwrite: a partial or outdated file must be deleted, then sent again.
- The e-reader must be in "File transfer" USB mode. In charge-only mode it is on USB (and in adb)
  but exposes no MTP interface.

The device half of `wiki.sh` can be tested without the e-reader by putting stand-in `mtp-detect`,
`mtp-folders`, `mtp-files`, `mtp-delfile` and `mtp-sendfile` scripts first on `PATH`, backed by a
directory. That is how the `update` scenarios were checked.

## Architecture

```
Kiwix .zim ──indexer──▶ <file>.zim.idx ─┐
     │                                   ├─ MTP ─▶ e-reader Download/ ─▶ Wiki Reader
     └───────────────────────────────────┘
```

`reader/` has three Gradle modules:

- **core** (plain Kotlin, no Android): `ZimFile` reads the archive (directory entries by binary
  search, zstd clusters with a small cache); `TitleIndex` memory-maps and searches the index;
  `SearchText.normalize` turns titles and queries into the form the index is sorted in.
- **indexer** (JVM, runs on the Mac): `IndexBuilder` holds every title in memory, ranks, sorts and
  writes the index. Needs about 3 GB of heap for full Wikipedia and takes under a minute.
- **app** (Android): one activity swapping a `SearchScreen` and a `ReaderScreen`. Plain views and a
  WebView; no AndroidX, no JavaScript, no internet permission.

Things that span files:

- **The index format is a contract between `IndexBuilder.write` and `TitleIndex`.** Its layout is
  documented at the top of `TitleIndex.kt`. Change the layout and you must bump
  `TitleIndex.VERSION`, rebuild the index and push it again; the app refuses other versions.
- **`SearchText.normalize` is shared by the indexer and the app and must give identical results in
  both.** Changing it invalidates existing indexes without changing their version.
- **Search** is binary search for the query's prefix range, then the best-ranked entries of that
  range via stored block maxima (`TitleIndex.Ranks`), in three passes: titles starting with the
  query, titles with a later word starting with it, then all words in any order.
- **Ranking** is decided at build time in `IndexBuilder.rankArticles`. The ZIM has no page-view
  data, so rank comes from membership of Kiwix's "top articles" build (passed to `indexer build` as
  a second file), article length, and capped inbound-redirect count. Redirect titles get a fraction
  of their article's rank.
- **The app finds its data by convention**: the largest `*.zim` in Download (or Documents) that has
  a `<name>.zim.idx` beside it, opened by path. That is why it needs "all files access".
- **Articles are served to the WebView** from `https://wiki.offline/<zim path>` through
  `shouldInterceptRequest`, so the articles' relative links and stylesheets resolve unchanged.
  `ReaderScreen.STYLE` is injected into each article to adapt Wikipedia's CSS for e-ink.
- Wikipedia contains over a million tiny HTML pages that only forward to a section of another
  article (a meta refresh). They are HTML entries, not ZIM redirects, so the index lists them as
  low-ranked articles and the reader passes through them.

ZIM details that are easy to get wrong: this file uses the new namespace scheme (content in `C`,
indexes in `X`), has **no** title pointer list (`titlePtrPos` is all ones; only
`X/listing/titleOrdered/v1` exists), and every content cluster is zstd.

## iOS (ios/)

An iPhone/iPad version that reads the same `.zim` and `.zim.idx` files.

- `ios/Package.swift` defines **WikiCore**, a Swift port of `reader/core` (`ZimFile`, `TitleIndex`,
  `SearchText`), and **wikicheck**, a command-line tool for comparing it with the Kotlin code.
- `ios/App/Sources` is the SwiftUI app: `SearchView`, `ArticleView`, and `WebController`, which
  serves articles to a WKWebView from `wiki://offline/<zim path>` through a `WKURLSchemeHandler`
  (`ArticleServer`). `ios/App/UITests` drives it in the simulator.
- `ios/project.yml` describes the Xcode project; `xcodegen generate` writes `WikiReader.xcodeproj`,
  which is git-ignored.

As of 2026-11-16 the app builds and its UI tests pass in the iPhone and iPad simulators against the
full Wikipedia file. It has **not** been installed on a real device: that needs the user's Apple ID
signed into Xcode and a development team chosen for the target.

```sh
cd ios && swift build -c release          # WikiCore + wikicheck; needs only the command-line tools
W=ios/.build/release/wikicheck; K=reader/indexer/build/install/indexer/bin/indexer
$W search <file.zim> <words>              # must equal `$K search ...` minus its last (timing) line
$W cat <file.zim> <Path> | shasum         # must equal `$K cat ...`
$W normalize <file.zim> [step]            # re-derives the index's normalized titles in Swift

# The app and its UI tests need Xcode itself. xcode-select points at the command-line tools on
# this Mac, so name Xcode per command instead of switching it (which needs sudo):
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios && xcodegen generate
xcodebuild -project WikiReader.xcodeproj -scheme WikiReader -derivedDataPath DerivedData \
  -destination 'generic/platform=iOS Simulator' build
TEST_RUNNER_WIKI_DIR=$PWD/../data/zim TEST_RUNNER_SHOT_DIR=<folder for screenshots> \
  xcodebuild test -project WikiReader.xcodeproj -scheme WikiReader -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Things to know:

- **There are now two implementations of the index format, the search order and
  `SearchText.normalize`.** A change to any of them in Kotlin must be mirrored in Swift, then checked
  with the commands above. On the June 2026 file both return byte-identical articles and identical
  results for every query tried.
- `wikicheck normalize` reports ten differing titles out of 16.8 million. They are letters added to
  Unicode after the version the indexer's JVM knows; that gap cannot be closed from Swift.
- The command-line tools alone cannot compile SwiftUI views: in this SDK `@State` is a macro whose
  plugin ships only with Xcode. `swift build` therefore covers WikiCore and wikicheck, not the app.
- Apple's Compression framework has no zstd, hence the `facebook/zstd` package dependency.
- The app looks for files in its Documents folder (Finder file sharing, or the Files app), in a
  folder the user chose, and in `WIKI_DIR` if that environment variable is set. Simulator apps can
  read the Mac's disk, so `WIKI_DIR` lets the UI tests run against the real 52.7 GB file in
  `data/zim` without copying it. By hand:
  `SIMCTL_CHILD_WIKI_DIR=$PWD/data/zim xcrun simctl launch booted dev.offlinewiki.reader`.
- **Dark appearance in the simulator needs care.** `XCUIDevice.shared.appearance` fails quietly here
  (the test host runs `xcrun simctl` against the command-line tools), and
  `xcrun simctl ui <device> appearance dark` on a headless simulator only takes effect after
  `simctl shutdown` and `boot`. `testDarkAppearance` asserts on screen brightness, so it fails
  rather than passing falsely; set the appearance and restart the simulator before running it.
- **"No images" builds come in two shapes.** The full build removes pictures but leaves their frames
  and captions; the "top" build swaps each picture for a transparent placeholder. The stylesheet
  both apps inject (`ReaderScreen.STYLE` on Android, `ArticleServer.style()` on iOS) hides any
  picture frame without a real picture in it, any location map (`.locmap`) without one, whose
  place-name labels would otherwise land on the rows around it, and settlement infoboxes' flag,
  seal and coat of arms cells (`.ib-settlement-cols-cell` in `td.maptable`) without one. Check
  changes to it against both builds; only the small one fits in the Android emulator, and the iOS
  simulator can use the full one. Rules that hide whole infobox rows must not catch a row holding a
  nested infobox (`infobox-subbox`) or other data, such as the table of neighbouring places some
  `maptable` cells hold (Melbourne).

## Conventions and constraints

- **`wiki.sh` targets macOS's bash 3.2**: no associative arrays, `mapfile`, or `${var,,}`.
- **Keep `main "$@"; exit` as the last line, on one line.** Bash reads scripts as it runs; this lets
  the file be edited while a multi-hour download is in progress.
- The script runs under `set -euo pipefail`. Pipelines that may legitimately match nothing need
  `|| true`. Do not use a bare `wait`: `stay_awake` leaves a `caffeinate` child that only exits when
  the script does (wait for a specific PID instead).
- `data/` is git-ignored. A file directly in `data/zim/` is complete and checksum-verified;
  downloads in progress live in `data/zim/partial/`. Downloaded `.zim` files are untrusted input.
- A snapshot is 53 GB and neither the Mac nor the e-reader has room for two. `update` deletes the
  old copy before fetching or sending the new one; preserve that ordering.
- `update` and `push` must act on a snapshot chosen by **name** (the date suffix), never by
  modification time. `cmd_update` sets `USE_ZIM` for this.
- **Use `./gradlew`, not the system `gradle`.** The wrapper pins Gradle 9.9.1 (with its checksum)
  for Android Gradle Plugin 9.5.1 and Kotlin 2.4.21; Homebrew's Gradle moves on without notice.
  The plugin and Gradle only work in matching major versions, so upgrade them together: Dependabot
  groups them for that reason.
- The Android Gradle Plugin compiles Kotlin itself since version 9, so `app` applies no Kotlin
  plugin and refuses `org.jetbrains.kotlin.android`. The Kotlin version everywhere is the one
  `org.jetbrains.kotlin.jvm` declares in `reader/build.gradle.kts`.
- To check a toolchain upgrade, build the indexes with the old and new indexer and `cmp` them
  (the build is deterministic, so they must be byte-identical), diff `search` and `cat` output, and
  compare emulator screenshots of the old and new APK.
- `zstd-jni` is pinned to 1.5.7-4, the newest release whose `.aar` builds against `compileSdk` 34.
  `core` depends on it `compileOnly`; the app supplies the `.aar`, the indexer the plain jar.
- The APK is signed with this Mac's Android debug key and named after its content hash. A build
  signed elsewhere cannot update the installed app.
- **`main` is protected.** Every change needs a pull request (no approvals required), including
  from the owner; force-pushes, deletion and merge commits are blocked. Work on a branch, then
  `gh pr create` and `gh pr merge --rebase --delete-branch`. Wait to be asked before opening or
  merging one.
- **Dependabot** (`.github/dependabot.yml`) opens weekly pull requests for Gradle (`reader/`), Swift
  (`ios/`) and GitHub Actions. There is no CI that builds the apps, so build and check each one
  locally before merging; nothing auto-merges. `zstd-jni` is ignored there on purpose (see the pin
  above). `.github/workflows/dependency-submission.yml` reports the Gradle project's resolved
  dependencies to GitHub, which is what lets Dependabot raise security alerts for them. It reports
  shipped runtime classpaths only; widening that brings back alerts about the build plugin's own
  libraries (61 of them the first time).
- **E-ink UI rules**: pure black on white, no animation, ripple or elevation, and labels that must
  fit a fixed width go through `Ui.fitOneLine`. Check layouts at `font_scale` 1.3 as well as 1.0.
