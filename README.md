# Offline Wikipedia for an Android e-reader, iPhone and iPad

All of English Wikipedia on an e-ink reader, an iPhone or an iPad, with nothing needing a network
connection once it is copied over. The pieces:

- **The content:** one `.zim` file published by [Kiwix](https://kiwix.org). The default is the
  `nopic` build: every article in full, without images, about 53 GB.
- **Wiki Reader for Android:** a small app in [reader/](reader/), written for e-ink readers. It
  reads the `.zim` file directly and searches titles through its own compact index, so results
  appear as you type. Kiwix's own app works with the same file, but its title search is slow on a
  low-power device (see [Using Kiwix instead](#using-kiwix-instead)).
- **Wiki Reader for iOS:** the same reader for iPhone and iPad, in [ios/](ios/). It uses the same
  two files and gives the same search results (see [iPhone and iPad (iOS)](#iphone-and-ipad-ios)).
- **`./wiki.sh`:** a script for the Mac that downloads and verifies the file, builds the index and
  the Android app, and copies everything to the e-reader over USB. `./wiki.sh help` lists its
  commands. The iOS app is built and installed with Xcode's tools.

What Wiki Reader does on both:

- Finds articles by title as you type, well-known ones first, keeps a list of what you read
  recently, and can open an article at random.
- Has a Sections list for moving around a long article, and a text size control.
- Hides the gaps that missing pictures leave behind: empty frames, map labels, flag captions.
- Reads everything from the file. Nothing is fetched from the network.

Where the two differ:

- **On the e-reader** it turns pages a screen at a time, with buttons or the device's page and
  volume keys, and shows articles in plain black on white with nothing animated, which is what
  e-ink displays well. The app has no internet permission.
- **On iPhone and iPad** it scrolls as usual, steps back and forward through the articles you
  opened, and follows the system's dark appearance.

## What you need

- A Mac, for `./wiki.sh`.
- A device with about 54 GB free: an e-reader running Android 9 or later that offers USB "File
  transfer" (MTP), or an iPhone or iPad running iOS 16 or later.
- These, from [Homebrew](https://brew.sh):

```sh
brew install aria2                                # fast downloads
brew install --cask temurin@21 android-commandlinetools
sdkmanager "platforms;android-34" "build-tools;36.0.0"
brew install libmtp                               # for an e-reader: USB file transfer
brew install xcodegen                             # for iOS, along with Xcode from the App Store
```

The JDK and the Android SDK build the title index as well as the Android app, so they are needed
for iOS too. The JDK must be version 17 or newer; 21 is the one this is built and checked with.
`./wiki.sh serve` additionally needs Docker.

## 1. Download, index, build

```sh
./wiki.sh fetch     # English Wikipedia; resumes if interrupted, verified against Kiwix's checksum
./wiki.sh index     # the title index Wiki Reader searches (under a minute; about 750 MB)
./wiki.sh app       # the Wiki Reader app
./wiki.sh status    # what is ready so far
```

Downloads and build results land in `data/` (ignored by git). The first `index` run also downloads
Kiwix's 3 GB "top articles" build: it is chosen by page views, and the index uses it to put
well-known articles first.

`./wiki.sh app` builds the Android app. For an iPhone or iPad, skip it: once `fetch` and `index`
are done, continue at [iPhone and iPad (iOS)](#iphone-and-ipad-ios). Steps 2 and 3 are for the
e-reader.

## 2. Copy to the e-reader

Plug the e-reader in with a USB cable, unlock it, and choose "File transfer" if it asks.

```sh
./wiki.sh push            # Wiki Reader, the index and Wikipedia, into the Download folder
./wiki.sh verify device   # optional: reads Wikipedia back and re-checks it (as slow as the copy)
```

Files already on the e-reader are skipped, so the same command sends an updated app or index. Keep
the e-reader awake during the big copy; it cannot resume, so an interrupted one starts over.

`push` sends the app that `./wiki.sh app` last built; it does not build one. After updating this
repository, run `./wiki.sh app` again, then `push`, and install the new app as in step 3.

This uses MTP, the ordinary Android file-transfer mode. `adb` is not used: the Viwoods AiPaper
Reader shows up in adb but refuses its shell, install and file-transfer commands.

## 3. On the e-reader

1. In the file manager, open Download and tap `wiki-reader-….apk` to install it. A newer one
   installs over the app that is there and keeps its reading history.
2. Open **Wiki Reader**. The first time, tap **Allow file access** and switch on "Allow access to
   manage all files", then go back. It needs this to read a file in Download.
3. Type a title. Tap a result to read it. With the search box empty, the list is what you read
   recently, and **Random** opens an article picked for you.

In an article, the bar at the bottom has Back, Search, Sections, text size (A− / A+), how far
through the article you are, and page-turn buttons (▲ ▼). Volume and page keys turn pages too.
Sections lists the article's headings; tap one to jump to it, and Back returns to where you were.

## How search works, and its limits

The index holds one entry per title or alternative name (16.8 million), sorted so that a search is
a couple of binary searches over a memory-mapped file. It ignores capitals, accents and
punctuation, matches the start of any word in a title, and falls back to "all these words in any
order". Results are ranked by how well known the article is, estimated from Kiwix's top-articles
selection, article length, and how many alternative names point at it.

- It searches **titles**, not article text. For full-text search, use Kiwix with the same file.
- The `nopic` build has no images. Wiki Reader hides what they leave behind: empty picture frames,
  the place-name labels of location maps, and captions such as "Flag" and "Coat of arms".
- Links that leave Wikipedia cannot open; the app says so.

## Using Kiwix instead

```sh
./wiki.sh apk             # download the Kiwix app, verified against its GitHub release checksum
./wiki.sh push kiwix      # copy Wikipedia and the Kiwix app over USB
./wiki.sh copy /Volumes/<card name>   # or onto a microSD card (64 GB or larger, exFAT)
./wiki.sh serve           # or just try it on the Mac at http://localhost:8080
```

## Updating the articles

```sh
./wiki.sh update
```

This checks Kiwix for a newer snapshot and, if there is one, downloads and verifies it, rebuilds the
index, removes the old snapshot from the e-reader, copies the new one over, and deletes the old
copy from the Mac. Allow about an hour, nearly all of it unattended. It can be run at any point and
picks up where things stand: without the e-reader plugged in it prepares everything on the Mac, and
run again with it plugged in it finishes the swap.

Things to know:

- Articles are only as fresh as Kiwix's builds. It publishes the full-text build roughly every three
  months; when there is nothing newer, `update` says so and changes nothing.
- Neither side can hold two 53 GB snapshots. On the e-reader the old one is removed first, so there
  is no Wikipedia on it during the copy (about half an hour). On the Mac the old copy is removed
  before the download whenever there is not room for both.
- It stays with the size you already use. To switch, name one: `./wiki.sh update mini`.

## Other sizes

```sh
./wiki.sh fetch mini   # intros only, ~13 GB, for e-readers with little storage
./wiki.sh fetch maxi   # with images, ~120 GB
```

## iPhone and iPad (iOS)

[ios/](ios/) holds the same reader as an app for iOS 16 and later. Its file reader and search are a
Swift port of the Android app's; on the full Wikipedia file the two return byte-identical articles
and the same search results in the same order. The app has a search screen (results as you type,
recently read, a random article) and an article view with back/forward, a menu of the article's
sections, text size and a dark appearance.

It passes its tests in the iPhone and iPad simulators against the full Wikipedia file, and runs on
an iPhone with that file on board. `./wiki.sh` does not build or install it; the steps are by hand
and need Xcode and XcodeGen.

**On your own iPhone or iPad.** Sign in to Xcode with your Apple ID (Settings, Accounts), pair the
device with the Mac, and switch on Developer Mode on the device (Settings, Privacy & Security). Then
build with your team's id and install:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios && xcodegen generate
xcrun devicectl list devices           # the device's id
xcodebuild -project WikiReader.xcodeproj -scheme WikiReader -configuration Release \
  -derivedDataPath DerivedData -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team id> build
xcrun devicectl device install app --device <device id> \
  DerivedData/Build/Products/Release-iphoneos/WikiReader.app
```

With a free Apple ID the installed app stops opening after seven days and has to be installed
again; a paid developer account makes that a year. Installing again keeps the app's files.

The app needs the Wikipedia `.zim` and its `.zim.idx` (about 54 GB together), the same two files
`./wiki.sh fetch` and `./wiki.sh index` produce. Connect the device, select it in the Finder, open
the Files tab and drag both onto Wiki Reader. They can also stay on an external drive; the app asks
for the folder.

**In a simulator.** No Apple ID is needed, and the app reads the files straight from the Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios && xcodegen generate
xcodebuild -project WikiReader.xcodeproj -scheme WikiReader -derivedDataPath DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl boot "iPhone 17"
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/WikiReader.app
SIMCTL_CHILD_WIKI_DIR=$PWD/../data/zim xcrun simctl launch booted dev.offlinewiki.reader
open -a Simulator
```

## Working on Wiki Reader

[reader/](reader/) is a Gradle project with three modules:

- `core`: reads ZIM files, searches the title index and finds an article's sections. Plain Kotlin,
  shared by the other two.
- `indexer`: the command-line tool behind `./wiki.sh index`. Its `search`, `cat` and `sections`
  commands show on the Mac exactly what the app would find and display.
- `app`: the Android app. Plain views and a WebView; no AndroidX, no JavaScript.

[ios/](ios/) has the same `core` code in Swift (`WikiCore`), the app, and `wikicheck`, a
command-line tool whose `search`, `cat` and `sections` print in the same form as the indexer's. A
change to how either side reads the file, searches or lists sections has to be made in both, and
the two outputs compared.

The Android app is signed with this Mac's Android debug key (`~/.android/debug.keystore`). Builds
from another machine count as a different app, and Android will ask for the old one to be
uninstalled.

Since nothing can be installed or inspected on the e-reader from the Mac, test in an emulator first:
push a small build such as `wikipedia_en_top_nopic` and its `.idx` into the emulator's
`/sdcard/Download`, then `adb install` the APK. The iOS app has UI tests that run in the simulator.

Every pull request is built by CI, which also runs [ci/compare.sh](ci/compare.sh) on a small
Wikipedia to check that the Kotlin and Swift code still agree, and [ci/device.sh](ci/device.sh),
which runs `push`, `update` and `verify device` against a stand-in for the e-reader. CI cannot show
how the apps look or behave, so the emulator and the UI tests remain the check for that.

[CLAUDE.md](CLAUDE.md) has the detailed notes: the commands for all of this, how the pieces fit
together, and the quirks of each device.

## License

The code in this repository is under the [MIT License](LICENSE). Wikipedia's articles, which
`./wiki.sh` downloads from Kiwix and are not part of this repository, are under Wikipedia's own
license, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
