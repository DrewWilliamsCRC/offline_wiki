# Offline Wikipedia for an Android e-reader

All of English Wikipedia on an e-ink reader, with nothing needing a network connection once it is
copied over. Two pieces:

- **The content:** one `.zim` file published by [Kiwix](https://kiwix.org). The default is the
  `nopic` build: every article in full, without images, about 53 GB.
- **Wiki Reader:** a small Android app in [reader/](reader/), written for this purpose. It reads the
  `.zim` file directly and searches titles through its own compact index, so results appear as you
  type. Kiwix's own app works with the same file, but its title search is slow on a low-power
  device (see [Using Kiwix instead](#using-kiwix-instead)).

Everything is driven by `./wiki.sh` (run `./wiki.sh help` for the list).

## What you need on the Mac

```sh
brew install aria2 libmtp                         # fast downloads; USB file transfer to the e-reader
brew install --cask temurin android-commandlinetools
sdkmanager "platforms;android-34" "build-tools;34.0.0"
```

The last two lines are only for building Wiki Reader. `./wiki.sh serve` additionally needs Docker.

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

## 2. Copy to the e-reader

Plug the e-reader in with a USB cable, unlock it, and choose "File transfer" if it asks.

```sh
./wiki.sh push            # Wiki Reader, the index and Wikipedia, into the Download folder
./wiki.sh verify device   # optional: reads Wikipedia back and re-checks it (as slow as the copy)
```

Files already on the e-reader are skipped, so the same command sends an updated app or index. Keep
the e-reader awake during the big copy; it cannot resume, so an interrupted one starts over.

This uses MTP, the ordinary Android file-transfer mode. `adb` is not used: the Viwoods AiPaper
Reader shows up in adb but refuses its shell, install and file-transfer commands.

## 3. On the e-reader

1. In the file manager, open Download and tap `wiki-reader-….apk` to install it.
2. Open **Wiki Reader**. The first time, tap **Allow file access** and switch on "Allow access to
   manage all files", then go back. It needs this to read a file in Download; the app has no
   internet permission.
3. Type a title. Tap a result to read it.

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
- The `nopic` build has no images, so Wiki Reader hides the empty picture frames.
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

## iPhone and iPad

[ios/](ios/) holds the same reader as an iOS app. Its file reader and search are a Swift port of the
Android app's; on the full Wikipedia file the two return byte-identical articles and the same search
results in the same order. The app has a search screen (results as you type, recently read, a
random article) and an article view with back/forward, a menu of the article's sections, text
size and a dark appearance.

It passes its tests in the iPhone and iPad simulators against the full Wikipedia file, and runs on
an iPhone with that file on board.

To try it in a simulator (needs Xcode, and `brew install xcodegen`):

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

To put it on your own iPhone or iPad, sign in to Xcode with your Apple ID (Settings, Accounts),
pair the device with the Mac, and switch on Developer Mode on the device (Settings, Privacy &
Security). Then build with your team's id and install:

```sh
xcrun devicectl list devices           # the device's id
xcodebuild -project WikiReader.xcodeproj -scheme WikiReader -configuration Release \
  -derivedDataPath DerivedData -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team id> build
xcrun devicectl device install app --device <device id> \
  DerivedData/Build/Products/Release-iphoneos/WikiReader.app
```

With a free Apple ID the installed app stops opening after seven days and has to be installed
again; a paid developer account makes that a year. Installing again keeps the app's files.

On the device the app needs the Wikipedia `.zim` and its `.zim.idx` (about 54 GB together) in
its own folder: connect the device, select it in the Finder, open the Files tab and drag both onto
Wiki Reader. They can also stay on an external drive; the app asks for the folder.

## Working on Wiki Reader

[reader/](reader/) is a Gradle project with three modules:

- `core`: reads ZIM files and searches the title index. Plain Kotlin, shared by the other two.
- `indexer`: the command-line tool behind `./wiki.sh index`. Its `search` and `cat` commands show on
  the Mac exactly what the app would find and display.
- `app`: the Android app. Plain views and a WebView; no AndroidX, no JavaScript.

The app is signed with this Mac's Android debug key (`~/.android/debug.keystore`). Builds from
another machine count as a different app, and Android will ask for the old one to be uninstalled.

Since nothing can be installed or inspected on the e-reader from the Mac, test in an emulator first:
push a small build such as `wikipedia_en_top_nopic` and its `.idx` into the emulator's
`/sdcard/Download`, then `adb install` the APK.

## License

The code in this repository is under the [MIT License](LICENSE). Wikipedia's articles, which
`./wiki.sh` downloads from Kiwix and are not part of this repository, are under Wikipedia's own
license, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
