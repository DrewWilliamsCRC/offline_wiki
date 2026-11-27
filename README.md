# Offline Wikipedia for an Android e-reader, iPhone and iPad

All of English Wikipedia on an e-ink reader, an iPhone or an iPad, with nothing needing a network
connection once it is there. It gets there over USB from a Mac, or downloaded in the app over
Wi-Fi. The pieces:

- **The content:** one `.zim` file published by [Kiwix](https://kiwix.org). The default is the
  `nopic` build: every article in full, without images, about 53 GB.
- **Wiki Reader for Android:** a small app in [reader/](reader/), written for e-ink readers. It
  reads the `.zim` file directly and searches titles through its own compact index, so results
  appear as you type. Kiwix's own app works with the same file, but its title search is slow on a
  low-power device (see [Using Kiwix instead](#using-kiwix-instead)).
- **Wiki Reader for iOS:** the same reader for iPhone and iPad, in [ios/](ios/). It uses the same
  two files and gives the same search results (see [iPhone and iPad (iOS)](#iphone-and-ipad-ios)).
- **`./wiki.sh`:** a script for the Mac that downloads and verifies the file, builds the index and
  the Android app, and copies everything to the e-reader over USB. It also publishes the index for
  the apps to download. `./wiki.sh help` lists its commands. The iOS app is built and installed
  with Xcode's tools.

What Wiki Reader does on both:

- Finds articles by title as you type, well-known ones first, and can open an article at random.
- Opens where you left it: on the article you were reading, at the same place. The list of what
  you read recently says how far you got in each, and reopens them there.
- Has a Sections list for moving around a long article, and a text size control.
- Hides the gaps that missing pictures leave behind: empty frames, map labels, flag captions.
- Downloads Wikipedia and its index itself, over Wi-Fi, if they are not copied over (see
  [Downloading in the app](#downloading-in-the-app)).
- Reads everything from the file. Nothing is fetched from the network while you read.

Where the two differ:

- **On the e-reader** it turns pages a screen at a time, with buttons or the device's page and
  volume keys, and shows articles in plain black on white with nothing animated, which is what
  e-ink displays well. It uses the network only on its Downloads screen.
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

First install Wiki Reader on the e-reader and give it its folder (step 3), so that the folder is
there to copy into. Then plug the e-reader in with a USB cable, unlock it, and choose "File
transfer" if it asks.

```sh
./wiki.sh push            # Wikipedia and its index into the Wikipedia folder (and the app into Download)
./wiki.sh verify device   # optional: reads Wikipedia back and re-checks it (as slow as the copy)
```

Files already on the e-reader are skipped, so the same command sends an updated index. Keep the
e-reader awake during the big copy; it cannot resume, so an interrupted one starts over.

Wiki Reader 1.0 and later read Wikipedia only from the folder they were given, not from Download.
If an earlier `push` left it in Download, `push` stops and asks you to move it: in the e-reader's
file manager, move the `.zim` and its `.zim.idx` from Download into the Wikipedia folder, which
takes a moment, then run `push` again.

`push` also sends the app that `./wiki.sh app` last built, for installing by hand; it does not
build one. If no e-reader answers, `push` asks whether to copy that app alone into this Mac's
Downloads folder instead. Wikipedia and its index still need the cable.

This uses MTP, the ordinary Android file-transfer mode. `adb` is not used: the Viwoods AiPaper
Reader shows up in adb but refuses its shell, install and file-transfer commands.

## 3. On the e-reader

1. Install Wiki Reader from the Play Store, as a tester (see
   [Google Play](#google-play)), or tap `wiki-reader-….apk` in Download in the file manager. The
   two cannot update each other: to switch, uninstall the one you have first. The Wikipedia folder
   stays.
2. Open **Wiki Reader**. The first time, it asks for a folder: tap **Choose a folder**, make a new
   folder named **Wikipedia** at the top of the storage (or open the one there), tap **Use this
   folder**, and allow access. The app reads and writes only there.
3. Type a title. Tap a result to read it. With the search box empty, the list is what you read
   recently and how far you got in each; tap one to carry on from there. **Random** opens an
   article picked for you.

Closed and opened again, or restarted by the e-reader, the app returns to the article you were
reading and the place you had reached.

Without a Wikipedia in its folder, the app offers to download one instead (see
[Downloading in the app](#downloading-in-the-app)). The cable is faster.

In an article, the bar at the bottom has Back, Search, Sections, text size (A− / A+), how far
through the article you are, and page-turn buttons (▲ ▼). Volume and page keys turn pages too.
Sections lists the article's headings; tap one to jump to it, and Back returns to where you were.

## Google Play

The Android app is on Google Play for testers (internal testing): people added in Play Console get
an invitation, install Wiki Reader from the Play Store, and get each new build from there. Builds
are uploaded with [reader/scripts/play-upload.sh](reader/scripts/play-upload.sh) from this Mac.
See "Google Play" in [CLAUDE.md](CLAUDE.md) for the setup, and [PRIVACY.md](PRIVACY.md) for the
app's privacy policy (it collects nothing).

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
- A file that an app has open keeps its space even after it is deleted, so Wiki Reader lets go of
  Wikipedia whenever it is not on screen. If `update` reports too little room straight after
  removing the old snapshot, Wiki Reader is probably in front: press the e-reader's home button
  (or restart it) and run `update` again. Back in the app, it finds the new snapshot by itself.

## Downloading in the app

Both apps can fetch Wikipedia and its index themselves, which is how someone without this Mac gets
them: on Android, the **Downloads** line at the end of the recently-read list, or **Download
Wikipedia** when there is none yet; on iPhone and iPad, the download button at the top of the
search screen, or **Download Wikipedia…** at first.

They offer the sizes Kiwix publishes, from all of English Wikipedia to a small start:

| Size | What is in it | About |
|---|---|---|
| All of English Wikipedia, with pictures | every article in full, with its pictures | 128 GB |
| All of English Wikipedia | every article in full, without pictures | 54 GB |
| All of English Wikipedia, introductions only | the opening paragraphs of every article | 14 GB |
| Best-known articles, with pictures | the most-read articles in full, with pictures | 7 GB |
| Best-known articles | the most-read articles in full, without pictures | 3 GB |
| Best-known articles, introductions only | the opening paragraphs of the most-read articles | 0.3 GB |

The app shows the ones that are available now (see below). With more than one on the device, it
reads the biggest; e-ink screens show pictures in grey.

**Updates.** Kiwix publishes new snapshots every few months. When the Downloads screen knows of a
newer one than the device has, it says so and offers **Update**: the new copy downloads beside the
old, which is deleted once the new one is checked and in place. If there is not room for both,
it offers **Replace** instead, which deletes the old one first, after asking. **Delete** removes a
size from the device, also after asking.

Wikipedia comes from Kiwix, and the index from this repository's
[downloads](https://github.com/DrewWilliamsCRC/offline_wiki/releases/tag/downloads) release. Each
file is checked against its SHA-256 before the app uses it. Downloads use Wi-Fi only, carry on
with the app in the background, and pick up where they stopped if interrupted; the app checks
first that there is room. The full Wikipedia takes an hour or more, depending on the connection;
the small ones, a few minutes.

What is on offer is up to `./wiki.sh publish` on this Mac. It looks for Kiwix's newest snapshot of
each size, builds the index of any that has none yet (downloading it for that, then deleting it
again), and uploads the indexes and the list the apps read. Run it after Kiwix publishes, and the
apps offer the update. A size this Mac has no room to download is skipped, with a note saying how
much it needs. It needs the GitHub CLI (`gh`), signed in to an account that can write to this
repository.

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
sections, text size and a dark appearance. Like the Android app, it opens where you left it.

It passes its tests in the iPhone and iPad simulators against the full Wikipedia file, and runs on
an iPhone with that file on board. `./wiki.sh` does not build or install it; the steps are by hand
and need Xcode and XcodeGen.

**Through TestFlight.** The repository's owner uploads builds with
[ios/scripts/testflight-upload.sh](ios/scripts/testflight-upload.sh), for internal testing only:
the testers are people on the owner's App Store Connect team, who get an email invitation. Install
**TestFlight** from the App Store, open the invitation and tap **Install**, and turn on Automatic
Updates for Wiki Reader there. Then open Wiki Reader and download Wikipedia in the app (see
[Downloading in the app](#downloading-in-the-app)). A TestFlight build stops opening 90 days after
it was uploaded. It and a build installed from Xcode replace each other, and either way the app
keeps its files.

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
`./wiki.sh fetch` and `./wiki.sh index` produce. The simplest way is to let the app download them
(see [Downloading in the app](#downloading-in-the-app)). From a Mac it is quicker: connect the
device, select it in the Finder, open the Files tab and drag both onto Wiki Reader. They can also
stay on an external drive; the app asks for the folder.

To move to a newer snapshot, delete the old two files there and drag the new two in. The app lets
go of its files while it is in the background, so the old ones' space is free for the new, and it
picks the new ones up when it comes forward.

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
which runs `push`, `update`, `verify device` and `publish` against stand-ins for the e-reader and
GitHub. CI cannot show
how the apps look or behave, so the emulator and the UI tests remain the check for that.

[CLAUDE.md](CLAUDE.md) has the detailed notes: the commands for all of this, how the pieces fit
together, and the quirks of each device.

## License

The code in this repository is under the [MIT License](LICENSE). Wikipedia's articles, which
`./wiki.sh` downloads from Kiwix and are not part of this repository, are under Wikipedia's own
license, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
