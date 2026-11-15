# Offline Wikipedia for an Android e-reader

English Wikipedia as a single file, read with the free [Kiwix](https://kiwix.org) app. Once the
file and the app are on the e-reader, nothing needs a network connection.

- **Content:** every English article in full, without images (`nopic`), about 53 GB.
- **Search:** article titles as you type, plus full-text search across all articles.
- **Needs:** Android 7.1 or newer, and 53 GB free on the e-reader or its microSD card.

Everything is driven by `./wiki.sh` (run `./wiki.sh help` for the list).

## 1. Download (on the Mac)

```sh
./wiki.sh fetch     # English Wikipedia; resumes if interrupted, verified against Kiwix's checksum
./wiki.sh apk       # the Kiwix app for Android, verified against the GitHub release checksum
./wiki.sh status    # what is downloaded so far
```

Downloads land in `data/` (ignored by git). `fetch` is much faster with aria2 installed
(`brew install aria2`); without it, it falls back to a single slow connection.

To try it before copying anything: `./wiki.sh serve`, then open <http://localhost:8080> (needs Docker).

## 2. Put it on the e-reader

**microSD card** (simplest if the e-reader has a slot; the card must be 64 GB or larger and
formatted exFAT, which is how cards that size are sold):

```sh
./wiki.sh copy /Volumes/<card name>   # copies Wikipedia + the app, then re-reads the copy to verify it
```

Eject the card, put it in the e-reader, and install the Kiwix `.apk` from the e-reader's file manager.

**USB cable** (for internal storage; macOS cannot browse Android storage on its own, so this uses
the `libmtp` tools):

```sh
brew install libmtp
# plug the e-reader in, unlock it, and choose "File transfer" if it asks
./wiki.sh push                        # copies the Kiwix app and Wikipedia to the Download folder
./wiki.sh verify device               # optional: reads the copy back and re-checks it
```

Keep the e-reader awake while it copies; the transfer cannot resume, so an interrupted one starts
over. Then open the e-reader's file manager, go to Download, and tap the Kiwix `.apk` to install it.

`adb` is not used. The Viwoods AiPaper Reader shows up in adb but refuses its shell, install and
file-transfer commands.

## 3. Read

Open Kiwix on the e-reader and allow it to access files when it asks. The Wikipedia file should
appear in its library; if it does not, use the library's open-file button and pick the `.zim`
file. Use the search icon to look things up.

## Other sizes and updates

```sh
./wiki.sh fetch mini   # intros only, ~13 GB, for e-readers with little storage
./wiki.sh fetch maxi   # with images, ~120 GB
```

Kiwix publishes a new snapshot every few months. Running `./wiki.sh fetch` again downloads the
newest one; delete the old `.zim` from `data/zim/` and from the e-reader afterwards.
