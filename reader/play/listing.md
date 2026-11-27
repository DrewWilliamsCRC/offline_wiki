# Google Play listing

What Play Console asks for, ready to paste. The graphics are in this folder: `icon-512.png`,
`feature-1024x500.png` and `screenshots/` (Android 16 emulator, 824x1648, font size 1.0). See
"Google Play" in CLAUDE.md for the setup and for uploading builds.

## App details

- **App name** (30 characters at most): `Offline Wiki Reader`, as on the App Store. Avoid "Wikipedia"
  in the name: it is a trademark of the Wikimedia Foundation. Saying the app reads Wikipedia, as
  the descriptions below do, is fine.
- **Default language:** English (United States)
- **App or game:** App. **Free or paid:** Free.
- **Category:** Books & Reference
- **Privacy policy:** https://github.com/DrewWilliamsCRC/offline_wiki/blob/main/PRIVACY.md

## Short description (80 characters at most)

All of English Wikipedia on your device: search and read it with no connection.

## Full description

Wiki Reader puts English Wikipedia on your phone, tablet or e-reader, and reads it with no network
at all: on a plane, in the countryside, or on a device that never goes online.

- Search titles as you type, with well-known articles first, or open one at random.
- Read articles with their sections, links and tables, in plain black on white that suits e-ink
  screens, with page-turn buttons and support for page and volume keys.
- Pick up where you left off: the app reopens the article you were reading, at the same place,
  and lists what you read recently and how far you got.
- Choose a size: all of English Wikipedia (about 54 GB), its best-known articles with or without
  pictures, or just their opening paragraphs (under 1 GB).
- Download over Wi-Fi from inside the app, with pause and resume, and update to newer snapshots
  as they come out. Every file is checked before it is used.

The content is Wikipedia's, packaged by Kiwix and licensed CC BY-SA 4.0. Wiki Reader is not made by
or affiliated with the Wikimedia Foundation or Kiwix. It has no ads, accounts or tracking.

## App content (the declarations)

- **Ads:** No ads.
- **App access:** All functionality is available without special access. (A reviewer chooses a
  folder at first launch, then downloads the smallest size from Downloads: about 0.3 GB.)
- **Content rating:** category Reference, News or Educational. The app shows Wikipedia's articles,
  which describe every subject factually; it has no user-generated content, chat, purchases or
  location sharing, and it does not browse the web.
- **Target audience:** your choice. "13 and over" or older keeps the app out of the Families
  programme and its extra requirements.
- **Data safety:** the app collects and shares no user data. Downloads go over HTTPS. There is no
  account, so nothing to delete on request.
- **News app:** No. **Government app:** No. **Financial features:** None. **Health:** None.

## Permissions, if Play asks

- `INTERNET`, `ACCESS_NETWORK_STATE`: downloading Wikipedia and its index, over Wi-Fi only.
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `WAKE_LOCK`, `POST_NOTIFICATIONS`: a
  download of tens of gigabytes takes hours, so it carries on with the app in the background, with
  a notification showing how far it has got. Foreground service type: data sync, user-initiated.
- No storage permission: the reader chooses one folder with Android's folder picker.
