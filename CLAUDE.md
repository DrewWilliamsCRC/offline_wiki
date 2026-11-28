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
./wiki.sh publish         # let the apps download every size: indexes + catalog.json to the GitHub release
bash -n wiki.sh           # the only "lint" for the script
```

Building the Gradle project directly (what `index` and `app` do):

```sh
cd reader && ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  ./gradlew --no-daemon -q :indexer:installDist :app:assembleRelease
```

There is no unit test suite and no linter. Verification is done with the indexer's own commands,
which exercise the same `core` code the app runs. `ci/compare.sh <file.zim>` runs them and their
Swift counterparts over a set of searches and articles and fails on any difference, and
`ci/device.sh <file.zim>` runs `push`, `update` and `verify device` against a stand-in e-reader;
CI does both on every pull request (see Conventions).

```sh
I=reader/indexer/build/install/indexer/bin/indexer
$I search data/zim/<file>.zim <words>   # exactly what the app would list, with timing
$I random data/zim/<file>.zim [count]   # articles as the app's Random button would pick them
$I cat data/zim/<file>.zim <Path>       # an article's bytes (follows redirects)
$I sections data/zim/<file>.zim <Path>  # its section headings, as the app's Sections menu lists them
$I info data/zim/<file>.zim
```

Work against a small build rather than the 52.7 GB file: `WIKI_BOOK` selects another Kiwix
Wikipedia, and every command honours it.

```sh
WIKI_BOOK=wikipedia_en_ray-charles ./wiki.sh fetch nopic   # 28 MB; has two published snapshots
WIKI_BOOK=wikipedia_en_top ./wiki.sh fetch nopic           # 2.7 GB; realistic, and also the ranking input
```

## The e-reader, and why testing is indirect

The device is a Viwoods AiPaper Reader, on Android 16 since late 2026, with the Play Store. It
shapes most decisions here:

- **adb is useless on it.** It appears in `adb devices`, but its firmware refuses shell commands,
  `adb install` and `adb push`. Nothing can be installed, launched or inspected from the Mac.
- **Files go over MTP** via the libmtp tools (`mtp-files`, `mtp-sendfile`, ...): Wikipedia and its
  index into the folder Wiki Reader was given (`Wikipedia` at the top of its storage), an APK into
  Download, where the user installs it by tapping it in the e-reader's file manager. Since 1.0 the
  app also comes from Google Play (see "Google Play" below), which installs and updates it.
- So **test in an emulator before pushing**, and expect each on-device round trip to cost the user
  manual steps. An Android 16 AVD shaped like the e-reader's screen (824x1648 at 300 dpi) works;
  `wikitest16` on this Mac (`wikitest` is an Android 14 one, for the oldest behaviour still met):

```sh
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools ADB_MDNS=0
$ANDROID_HOME/emulator/emulator -avd wikitest16 -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect &
adb -e install -r data/app/wiki-reader-*.apk
adb -e shell am start -n dev.offlinewiki.reader/.MainActivity   # then choose its folder: tap through the picker
adb -e push data/zim/wikipedia_en_top_nopic_*.zim /sdcard/Wikipedia/     # and its .idx; or download in the app
adb -e exec-out screencap -p > shot.png                                  # then look at it
adb -e shell settings put system font_scale 1.3                          # reproduces the e-reader's larger text
adb -e shell sync; adb -e shell reboot -p                                # to stop it: a hard stop loses writes
```

  `uiautomator dump` lists what is on screen with its position, for tapping by text through the
  folder picker and the app's own screens.

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
- A file listing with no files in it is asked for again, and believed only when every try says the
  same (an e-reader with nothing on it yet). Any error text in between means "cannot talk to it".
- The awk programs that read a listing must read all of it. One that stops at its first match
  (`exit`) breaks the pipe on an e-reader with a few hundred files, and under `pipefail` that ends
  the script silently with status 141.
- A deleted file that an app still has open keeps its space. Wiki Reader therefore lets go of its
  files whenever it is not on screen (see Architecture); `push` says so when room is short.

The device half of `wiki.sh` is tested without the e-reader by `ci/device.sh <small file.zim>`. It
puts `ci/fake-mtp.sh` first on `PATH` under each libmtp tool's name, backed by a folder that plays
the e-reader, serves "Kiwix's" snapshots from a web server on this machine, and works in a scratch
folder, so it touches neither `data/` nor the network. `publish` goes to a stand-in `gh` there,
which keeps "GitHub's" release in a folder. `wiki.sh` reads these variables for it: `WIKI_DATA`
(where `data/` is), `WIKI_ZIM_URL` (where snapshots are listed and fetched), `WIKI_MTP_PAUSE`
(seconds between sessions, 3 on a real device), `WIKI_DOWNLOADS` (the folder that is the Mac's
`~/Downloads`), and `WIKI_PUBLISH` and `WIKI_PUBLISH_REPO` (the books to publish, and where).
Add a scenario there when you change `push`, `update`, `verify device`, `publish` or `mtp_query`,
and check that it fails without the change.

## Architecture

```
Kiwix .zim ──indexer──▶ <file>.zim.idx ─┐
     │                                   ├─ MTP ─▶ e-reader Wikipedia/ ─▶ Wiki Reader
     └───────────────────────────────────┘
```

`reader/` has three Gradle modules:

- **core** (plain Kotlin, no Android): `ZimFile` reads the archive (directory entries by binary
  search, zstd clusters with a small cache); `TitleIndex` memory-maps and searches the index;
  `SearchText.normalize` turns titles and queries into the form the index is sorted in;
  `ArticleSections` finds an article's headings for the Sections menu.
- **indexer** (JVM, runs on the Mac): `IndexBuilder` holds every title in memory, ranks, sorts and
  writes the index. Needs about 3 GB of heap for full Wikipedia and takes under a minute.
- **app** (Android): one activity swapping a `SearchScreen` and a `ReaderScreen`. Plain views and a
  WebView; no AndroidX, no JavaScript. The network is used only by the Downloads screen.

Things that span files:

- **The index format is a contract between `IndexBuilder.write` and `TitleIndex`.** Its layout is
  documented at the top of `TitleIndex.kt`. Change the layout and you must bump
  `TitleIndex.VERSION`, rebuild the index and push it again; the app refuses other versions.
- **`SearchText.normalize` is shared by the indexer and the app and must give identical results in
  both.** Changing it invalidates existing indexes without changing their version.
- **Search** is binary search for the query's prefix range, then the best-ranked entries of that
  range via stored block maxima (`TitleIndex.Ranks`), in three passes: titles starting with the
  query, titles with a later word starting with it, then all words in any order. A search that
  still has fewer than eight results adds up to eight near misses (`TitleIndex.nearMisses`):
  every spelling one slip from the query (a letter dropped, added, changed, or two swapped, the
  first letter kept), each looked up as a title prefix. It needs nothing new in the index, and
  takes about 0.15 ms a search in Swift on this Mac, on the full file.
- **Ranking** is decided at build time in `IndexBuilder.rankArticles`. The ZIM has no page-view
  data, so rank comes from membership of Kiwix's "top articles" build (passed to `indexer build` as
  a second file), article length, and capped inbound-redirect count. Redirect titles get a fraction
  of their article's rank. Random uses the rank too: it only picks articles at or above
  `TitleIndex.MIN_ARTICLE_RANK`, which the forwarding pages described below fall under.
- **The app finds its data by convention**: a `*.zim` with a `<name>.zim.idx` beside it, in the
  one folder the reader gave it. On Android that is chosen once through the system's folder
  picker, which grants that folder alone, with lasting permission (`Folder.kt`): Google Play does
  not allow "all files access" to an app like this, and Android will not grant the Download folder
  itself, so the folder is `Wikipedia` at the top of storage, where `push` copies to. Files are
  reached as documents, by name, and opened from file descriptors, which is why `ZimFile` and
  `TitleIndex` take a `FileChannel`. On iOS it is the app's Documents folder. Of each
  book (`<book>_<flavor>`, the name without its `_<year>-<month>.zim`) only the newest snapshot
  counts, then the biggest of those wins (`Library.findZim`, `LibraryStore.reload`). Newest before
  biggest, because an update can be smaller than what it replaces (Kiwix's "top" with pictures
  went from 7.8 to 6.5 GB) and an older copy may linger beside it.
- **Both apps hold the files open only while on screen** (`Library.hold` and `release`, called from
  `MainActivity.onStart`/`onStop` and from `RootView`'s scene phase). Out of sight, a read opens
  them for just that read. Otherwise a snapshot deleted over USB would keep its 53 GB and `update`
  could not send the new one. Coming forward, each app compares the files' names, sizes and dates
  with what it opened (`Library.changed`, `LibraryStore.reload`) and starts afresh if they differ,
  which is also how a newly copied index is noticed. On Android the index is memory-mapped and
  only unmapped by the garbage collector, hence the `gc()` in `onStop`.
- **Both apps open where they were left.** The history keeps, per article, how far down it the
  reader was (0 to 1), and whether an article or the search screen was showing. Recently read
  articles reopen at that place; search results open at the top. Android has no scripts, so it
  scrolls after the page has loaded and its height has stopped changing (`ReaderScreen.settle`);
  iOS scrolls with one script call when the page finishes.
- **When titles cannot be searched, the search screen says why** (`Library.indexProblem`): the
  index is missing, cut short, of another version, or built for another file. The wording for the
  first three comes from `TitleIndex` in each language.
- **Both apps can download Wikipedia and its index** (Downloads.kt and DownloadScreen.kt on
  Android; Downloads.swift and DownloadsView.swift on iOS). What they offer is `catalog.json` on
  this repository's GitHub release `downloads`, written and uploaded by `./wiki.sh publish`: each
  book's index (uploaded there, since only this repository builds it) and its `.zim` (fetched
  from Kiwix's own address), each with its size and SHA-256. The address is built into three
  places that must agree: `Catalog.URL` (Kotlin), `Catalog.url` (Swift) and `PUBLISH_REPO` and
  `PUBLISH_TAG` in `wiki.sh`. The catalog is untrusted input: each app accepts only plain
  `.zim`/`.zim.idx` file names, HTTPS addresses and 64-hex checksums.

  `publish` goes through `PUBLISH_BOOKS` (every English size) and offers Kiwix's newest snapshot
  of each. Its index is the one built here, or else the one already on the release, or else the
  snapshot is downloaded, indexed and deleted again; a size this Mac has no room to download is
  skipped with a note. Sizes and checksums come from Kiwix, so no `.zim` has to stay here. Run it
  again when Kiwix publishes: that is how the apps learn of updates. As of 2026-11-27 the release
  offers four sizes; "all, introductions only" (14 GB) and "all, with pictures" (128 GB) await a
  Mac with that much room free. Rules both apps follow:
  - **A file is used only once it is whole and its SHA-256 matches.** Android writes
    `<name>.part` in the folder, carries a stopped one on with an HTTP range from its size as it
    is then (never a listing kept from a moment before), checks it and renames it.
    iOS uses a background `URLSession`, which carries on with the app suspended and leaves resume
    data when stopped; a file that has arrived waits in Application Support/Downloads until it
    is checked, then moves into Documents. Checking 53 GB takes a minute or more.
  - **The index comes first**, the `.zim` last: an index alone is harmless, as both apps look
    for a `.zim`, so Wikipedia appears to the app only when it is complete.
  - **Wi-Fi only, and room checked first** (the space still needed plus 100 MB). One book at a
    time.
  - **Every size Kiwix publishes can be offered**, each a book of its own: all of English
    Wikipedia or its best-known articles, with pictures (`maxi`), without (`nopic`) or only the
    opening paragraphs (`mini`). The reader handles pictures: they sit in uncompressed clusters,
    which `ZimFile` reads directly.
  - **Updates**: a book whose snapshot here is older than the catalog's offers Update. The new
    one downloads beside the old, and the old one (with its index) is deleted once the new one is
    checked and in place. If both will not fit but the new one would without the old, it offers
    Replace instead, which asks, then deletes the old one first. Delete removes a book, also
    after asking (in place on Android, where dialogs animate; a confirmation dialog on iOS).
    Before deleting, each app closes the file if it is the one open (`MainActivity.letGo`,
    `LibraryStore.letGo`), since a deleted file that is still open keeps its space.
  - **A file is flushed to disk before it takes its name**, so that a device that loses power
    just after is not left with an empty file under the final name. (A hard stop of the emulator
    did exactly that to an index before this.)
  - Android runs the download in a foreground service (`dataSync`) with a wake lock, and the
    screen reads `Downloads.status` every two seconds, changing only text that changed (e-ink).
    iOS wakes through `AppDelegate`'s background-session handler.
  - **iOS says how a download ended when the app is out of sight**, with a notification in the
    downloads screen's words (`Downloads.tell`): ready, stopped, or arrived but still to be
    checked. Permission is asked when the first download starts, not at launch. A check that
    starts out of sight asks for background time (`Downloads.holdOn`), which iOS limits to about
    half a minute: enough for the smaller sizes, not for the full Wikipedia's 54 GB. When it runs
    out the notification says to open the app to finish, and never that the book is ready, and
    the check carries on when the app comes forward. A tap on a stopped or unchecked one opens
    the downloads screen. The simulator does not enforce the limit (a check there runs to the end
    out of sight), so that path shows only on a device.
  - A first Wikipedia opens as soon as it arrives, judged at the moment the download ends (not
    later, when a deletion has left nothing open). One that arrives while another is open is not
    switched to on the spot, so as not to pull the reader out of an article: the downloads
    screen offers Open, and otherwise the app moves to it the next time it comes forward, as it
    does for files copied over. On iOS the downloads sheet hangs off `RootView`, not the screen
    beneath, which can change while it is up.
- **Articles are served to the WebView** from `https://wiki.offline/<zim path>` through
  `shouldInterceptRequest`, so the articles' relative links and stylesheets resolve unchanged.
  `ReaderScreen.STYLE` is injected into each article to adapt Wikipedia's CSS for e-ink.
- **The Sections menu** lists what `ArticleSections.parse` finds in the article's HTML: every
  `<h2>` to `<h6>` with an `id`, which is also the anchor to scroll to. Each app reads them as it
  serves the page. The two jump differently. Android has no scripts, so it loads the page's own
  address with `#id`: no reload, and Back returns to where the reader was, as it does after a
  footnote link. iOS scrolls with a script call of its own, which adds nothing to back/forward.
  Both stylesheets set the headings' `scroll-margin-top`, which Wikipedia's skin puts at 75px for
  a sticky header that is not there.
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

As of 2026-11-16 the app builds, its UI tests pass in the iPhone and iPad simulators against the
full Wikipedia file, and it runs on a real iPhone with that file in its Documents folder.

**Look at the device before saying what it has or needs.** Unlike the e-reader, a paired iPhone or
iPad can be inspected and installed to from the Mac, over USB or Wi-Fi:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl list devices                         # paired devices, their ids, whether reachable
xcrun devicectl device info apps --device <id>       # is Wiki Reader installed, and which version
xcrun devicectl device info files --device <id> --domain-type appDataContainer \
  --domain-identifier dev.offlinewiki.reader --subdirectory Documents     # its .zim and .zim.idx

# Build for a device and install. Xcode must be signed in to an Apple developer account. The team
# id goes on the command line, not into project.yml: this repository is public.
cd ios && xcodegen generate
xcodebuild -project WikiReader.xcodeproj -scheme WikiReader -configuration Release \
  -derivedDataPath DerivedData -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=<team id> build
xcrun devicectl device install app --device <id> DerivedData/Build/Products/Release-iphoneos/WikiReader.app
```

Installing over the app keeps its Documents folder, so the 53 GB file is not copied again. Raise
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ios/project.yml` for every build that goes to
a device; otherwise the installed build cannot be told from the one before it. Installing changes
the user's own phone, so ask first.

**TestFlight.** The app also ships through TestFlight, internal testing only: testers are App Store
Connect users on the owner's team (at most 100), and no Beta App Review is involved. Its App Store
Connect record is for bundle ID `dev.offlinewiki.reader`, which can never be changed. The setup
copies the one the owner's Lighthouse Mobile app uses, on the same team.

- **Upload with `ios/scripts/testflight-upload.sh`** from the main checkout at `origin/main`: it
  refuses another branch, a stale checkout or uncommitted changes in `ios/`. It generates the
  project, then archives and uploads with `xcodebuild` and an App Store Connect API key, so the
  Xcode app's own sign-in is not needed. The options are in `ios/ExportOptions-TestFlight.plist`.
  Xcode raises the uploaded build's number past the last upload (`manageAppVersionAndBuildNumber`);
  raise `MARKETING_VERSION` for a new version as before.
- **The key and the team id stay outside the repository**, which is public:
  `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` (mode 600), and `ASC_KEY_ID`,
  `ASC_ISSUER_ID` and `DEVELOPMENT_TEAM` in `~/.appstoreconnect/wiki-reader.env`. It is a Team key
  with the Admin role (Users and Access, Integrations, App Store Connect API), so the same key
  serves every app on the team. Never commit either file or paste the `.p8` into a chat. The export
  options name no team: the export uses the one the archive was signed for.
- **An API key cannot create the App Store Connect record.** It is made once on the website (Apps,
  +, New App), choosing the bundle ID from the list; until then an upload is refused. Testers are added there too: TestFlight, an
  internal group with access to every build, and its members, each already a user of the team.
- **A build stops opening 90 days after its upload.** Upload a new one before then, even with no
  change.
- **The privacy manifest** is `ios/App/PrivacyInfo.xcprivacy`. App Store Connect wants a reason for
  each "required reason" API: it declares `UserDefaults` (`CA92.1`), file timestamps (`C617.1`
  for the Documents folder, `3B52.1` for a folder the reader picked), which `LibraryStore.stamp`
  and the `fstat` in `TitleIndex` use, and disk space (`E174.1`), which `Downloads.start` checks.
  Using another such API (system boot time, the active keyboards) means adding it there.
- **`ITSAppUsesNonExemptEncryption` is `NO`** (`ios/App/Info.plist`): the only encryption is the
  HTTPS of the downloads, through Apple's own `URLSession`, which is exempt. Adding encryption of
  its own means answering Apple's export questions again.
- **Not in CI.** Uploading from CI would need the API key on the runner. CI does check that the
  script parses.

```sh
cd ios && swift build -c release          # WikiCore + wikicheck; needs only the command-line tools
W=ios/.build/release/wikicheck; K=reader/indexer/build/install/indexer/bin/indexer
$W search <file.zim> <words>              # must equal `$K search ...` minus its last (timing) line
$W cat <file.zim> <Path> | shasum         # must equal `$K cat ...`
$W sections <file.zim> <Path>             # must equal `$K sections ...`
$W random <file.zim> [count]              # random picks; not comparable, but the same rule as `$K random`
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

- **There are now two implementations of the index format, the search order,
  `SearchText.normalize` and `ArticleSections`.** A change to any of them in Kotlin must be mirrored
  in Swift, then checked with the commands above, or all at once with `ci/compare.sh <file.zim>`
  (`ALLOWED_NORMALIZE_DIFFERENCES=10` for the full file, `=1` for the "top" one). On the June 2026
  file both return byte-identical articles and identical results for every query tried, and the
  same sections for the 549 articles compared across both files. The rules for sections are
  written out at the top of `ArticleSections.kt`; keep to them exactly, down to which entities
  are decoded.
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
- **A web view can say a page has finished before it knows the page's title** (about one load in
  nine in the iPad simulator). `WebController` therefore watches `title` and files the article in
  the history once both have happened. Reading `webView.title` in `didFinish` blanks the title bar
  and drops the article from the history on those loads.
- **Four UI tests use the network.** `testDownloadsListsWhatCanBeDownloaded` reads the published
  catalog. `NoticeUITests` (`TEST_RUNNER_DOWNLOAD=1`) downloads the 0.3 GB build with the app sent
  to the home screen, waits for the notification that it is ready, taps it, and deletes the book
  again. The first download makes iOS ask about notifications; the tests answer through SpringBoard
  (`allowNotifications`). `DownloadUITests` downloads the best-known articles for real (about 3 GB,
  five minutes or more), pausing, carrying on and relaunching on the way, so it runs only with
  `TEST_RUNNER_DOWNLOAD=1`, and wants a fresh app: `xcrun simctl uninstall <simulator>
  dev.offlinewiki.reader` first. `UpdateUITests` (`TEST_RUNNER_UPDATE=1`) updates an older snapshot
  of the 0.3 GB build and then deletes it; the older snapshot is the catalog's own file copied into
  the app's Documents under an earlier date, as the comment at its top shows. The downloads list
  makes only the rows on screen, so the tests scroll to a book before using it. In the Android
  emulator the same is done by hand: rename a `.zim` and its `.idx` to an earlier date to get
  Update, `fallocate` a file in `/data/local/tmp` to run short of room for Replace, and
  `truncate -s <size>` on a `.part` to see the checksum refuse a damaged file.
- **Wikipedia stays out of backups.** iOS backs up Documents and Application Support to iCloud
  and to a computer. `LibraryStore.keepOutOfBackups` marks each `.zim` and `.zim.idx` in Documents
  as excluded (`isExcludedFromBackup`) every time `reload` looks for files, and after a download
  is moved into place; `Downloads.waiting` is excluded whole. The mark is an extended attribute,
  so it changes neither the size nor the date `LibraryStore.stamp` reads (checked). A folder the
  reader chose is theirs, and left alone.
- **Article text follows the system's text size.** The stored `textSize` is a percent of the
  system's body size; `ArticleView` shows the article at that times `UIFontMetrics`' scale for
  the current Dynamic Type size (capped at 400%), and again when the setting changes. Before 0.7
  it was a percent of WebKit's own size, so `adoptSystemTextSize` converts a stored size once
  (`textSizeFollowsSystem`) to the step that looks the same. `simctl spawn defaults` writes a
  settings file the app does not read; write `<container>/Library/Preferences/dev.offlinewiki.reader`
  instead, by path.
- **Articles are shown in WebKit's mobile mode on iPad too** (`preferredContentMode = .mobile` in
  `WebController.init`). In the desktop mode an iPad gets by default, `-webkit-text-size-adjust`
  does nothing, so A- / A+ never changed an iPad's text (the size test found it), and a page with
  wide content (Paris, with its infobox) was shrunk to fit, its text smaller than other articles'.
  An iPhone is in mobile mode anyway.
- **The article menu** (a `ToolbarItem(.primaryAction)` in `ArticleView`) holds Save (or Remove
  from Saved), Find in Article, the system's find bar (`isFindInteractionEnabled`), and Share and
  Open on Wikipedia. Save, Share and Open use `WebController.article`: the page on screen as filed
  in the history, nil for "Not found" and forwarding pages. The address is
  `https://<language>.wikipedia.org/wiki/<path>`, the language taken from the file's name and the
  path percent-encoded, "?" included. Further article actions belong in this menu: the bottom bar
  is full.
- **Saved articles live in `History`**, beside the recent ones: `History.saved`, newest first, with
  no limit, in `Application Support/saved.json` (backed up, unlike Wikipedia: it is small and
  cannot be downloaded again). Reading places are kept for the articles in either list
  (`History.save` prunes the rest), so a saved article keeps its place after it has left the 40
  recent ones. The search screen lists Saved above Recently read; a row of either is swiped away
  (`forget`, `removeSaved`), and Clear in Recently read's header asks, then empties it
  (`forgetAll`). The Android app has neither yet.
- **The search screen's last line says how old the copy is** ("Wikipedia as of June 2026", from
  the file's name). Past six months it adds that a newer copy may be out and opens Downloads. It
  never checks the catalog itself: the app uses the network only when asked.
- **The UI tests start the app with `-reading NO`**, which overrides for one launch what the app
  remembers about being inside an article. Without it every test would start where the one before
  it stopped. `testReopensWhereTheReaderLeftOff` relaunches without it.
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

## Google Play

The Android app is on Google Play's internal testing track: testers are the people added in Play
Console (up to 100), who install it from the Play Store and get each build automatically.

- **Upload with `reader/scripts/play-upload.sh`** from the main checkout at `origin/main`, as for
  TestFlight. It builds `:app:bundlePlay` (the `play` build type: the release build, signed with the
  upload key) and puts it on the internal track through the Play Developer API. Raise
  `versionCode` (and `versionName`) in `reader/app/build.gradle.kts` for every upload: Play takes
  each version code once.
- **Outside the repository**, which is public: the upload key,
  `~/.android/wiki-reader-upload.jks`, with its password in `~/.android/wiki-reader-upload.properties`
  (both mode 600; keep a copy somewhere safe, as Play takes uploads only signed with it), and a
  Google Cloud service account's JSON key, `~/.android/wiki-reader-play.json`, which Play Console
  (Users and permissions) allows to release to testing tracks. The script makes its token with
  `openssl`, so it needs no Google tools.
- **The first build of a new app goes up by hand** in Play Console (Testing, Internal testing,
  Create new release, the `.aab` from `reader/app/build/outputs/bundle/play/`). The API takes
  every build after that.
- **What the listing needs is in `reader/play/`**: `listing.md` (the texts and the answers to the
  App content declarations), the 512 px icon and 1024x500 feature graphic (drawn from the launcher
  icon's W), and screenshots from the Android 16 emulator. The privacy policy is `PRIVACY.md`.
- **No "all files access"** (see "The app finds its data by convention"): Play grants it only to
  file managers and the like.

## Conventions and constraints

- **`wiki.sh` targets macOS's bash 3.2**: no associative arrays, `mapfile`, or `${var,,}`.
- **Keep `main "$@"; exit` as the last line, on one line.** Bash reads scripts as it runs; this lets
  the file be edited while a multi-hour download is in progress.
- The script runs under `set -euo pipefail`. Pipelines that may legitimately match nothing need
  `|| true`. Do not use a bare `wait`: `stay_awake` leaves a `caffeinate` child that only exits when
  the script does (wait for a specific PID instead).
- **The script asks one question.** When no e-reader answers, `push` offers to copy the app alone
  to the Mac's Downloads folder (`app_to_downloads`), and only `y` or `yes` is a yes. It asks with
  `read -p`, which shows the question only at a terminal, so a run with nobody there prints and
  does exactly what it did before: the error, and status 1. Anything else that asks must behave
  the same, because downloads and transfers run unattended for hours. `ci/device.sh` types its
  answers (`typed=y run ...`); to see the question itself, run `push` at a terminal.
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
- `zstd-jni` is pinned to 1.5.7-4: its native libraries are aligned for 16 KB pages, which Play
  requires, and its `.aar` asks for no particular `compileSdk`; later 1.5.7 releases ask for 37.
  `core` depends on it `compileOnly`; the app supplies the `.aar`, the indexer the plain jar.
- **The app targets Android 16 (API 36)**, as Play requires of a new app. What that changed: the
  app draws edge to edge, and `MainActivity` pads its root by the system bars and the keyboard;
  Back arrives through an `OnBackInvokedCallback` (Android 16 no longer calls `onBackPressed`);
  and Android gives a `dataSync` foreground service six hours a day, after which
  `DownloadService.onTimeout` pauses the download and Carry on resumes it.
- The sideloaded APK (`./wiki.sh app`) is signed with this Mac's Android debug key and named after
  its content hash; a build signed elsewhere cannot update the installed app. The Play build is
  signed with the upload key and installed signed with Google's, so a copy from Play and a
  sideloaded one cannot update each other: switching between them means uninstalling (the
  Wikipedia folder stays).
- **`main` is protected.** Every change needs a pull request (no approvals required), including
  from the owner; force-pushes, deletion and merge commits are blocked. Work on a branch, then
  `gh pr create` and `gh pr merge --rebase --delete-branch`. Wait to be asked before opening or
  merging one.
- **CI** (`.github/workflows/ci.yml`) runs on every pull request and on `main`. Five jobs: the
  scripts parse under macOS's own bash 3.2; the Android app and indexer build; the iOS app and its
  UI tests compile (they are not run); `ci/compare.sh` passes on a 28 MB Wikipedia about Ray
  Charles, fetched with `wiki.sh` and cached; and `ci/device.sh` passes on the same file, with
  stand-ins for the e-reader and for GitHub. It cannot show how the apps look or behave, and it never touches a
  device: a change to a screen or a stylesheet still needs the emulator and the iOS UI tests. A
  red run does not block a merge unless the checks are made required in the branch protection.
- **Dependabot** (`.github/dependabot.yml`) opens weekly pull requests for Gradle (`reader/`), Swift
  (`ios/`) and GitHub Actions. CI builds each one, which is not the whole check for a toolchain
  bump (see the note on checking an upgrade above); nothing auto-merges. `zstd-jni` is ignored
  there on purpose (see the pin above). `.github/workflows/dependency-submission.yml` reports the Gradle project's resolved
  dependencies to GitHub, which is what lets Dependabot raise security alerts for them. It reports
  shipped runtime classpaths only; widening that brings back alerts about the build plugin's own
  libraries (61 of them the first time).
- **E-ink UI rules**: pure black on white, no animation, ripple or elevation, and labels that must
  fit a fixed width go through `Ui.fitOneLine`. Check layouts at `font_scale` 1.3 as well as 1.0.
