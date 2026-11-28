# App Store listing

What App Store Connect asks for before the iOS app can be submitted for review, ready to paste.
Most of it was entered through the App Store Connect API in November 2026; this file is the record
of what was entered, and the place to change it. The screenshots are in `AppStore/screenshots/`
(see "Screenshots" below). For uploading builds see "TestFlight" in CLAUDE.md; the Android
equivalent is `reader/play/listing.md`.

## App Information

- **Name** (30 characters at most): `Offline Wiki Reader`. Keep "Wikipedia" out of the name,
  subtitle and keywords: it is the Wikimedia Foundation's trademark, and Apple refuses
  trademarked terms in keywords (guideline 2.3.7). Saying in the description that the app reads
  Wikipedia is fine. On the Home Screen the app is called `Wiki Reader` (`CFBundleDisplayName`).
- **Subtitle** (30 at most): `Encyclopedia with no signal`
- **Category:** Reference; secondary Education.
- **Content rights:** the app contains third-party content (Wikipedia's articles, licensed CC
  BY-SA 4.0, packaged by Kiwix), and the licence gives the rights to show it.
- **Privacy policy:** https://github.com/DrewWilliamsCRC/offline_wiki/blob/main/PRIVACY.md
- **Age rating:** the questionnaire's answers are under "Age rating" below.

## Pricing and Availability

Free. Every country and region except mainland China, which asks for an ICP filing number first
(and blocks Wikipedia anyway).

## App Privacy

**Data Not Collected.** The app has no accounts, analytics, ads or tracking, and sends nothing
about the reader anywhere (see PRIVACY.md). This is answered on the website only: the API has no
way to set it.

## Version information

- **Promotional text** (170 at most; can change without a new version):

  All of English Wikipedia on your iPhone or iPad, to search and read with no connection at all.
  No ads, no accounts, no tracking.

- **Keywords** (100 at most, commas without spaces):
  `offline,encyclopedia,wiki,reader,zim,reference,travel,airplane mode,no internet,library,articles`

- **Support URL:** https://github.com/DrewWilliamsCRC/offline_wiki/issues
- **Marketing URL:** https://github.com/DrewWilliamsCRC/offline_wiki
- **Copyright:** `2026 Drew Williams`

### Description

Wiki Reader puts English Wikipedia on your iPhone or iPad, and reads it with no network at all:
on a plane, in the countryside, or anywhere the signal gives out.

- Search titles as you type, with well-known articles first, or open one at random.
- Read articles with their sections, links and tables. The Sections menu jumps straight to any
  part of a long article.
- Save articles to read later. The app reopens the article you were reading, at the same place,
  and lists what you read recently and how far you got.
- Find a word in an article, share it, or open it on the web.
- Text follows the system's text size, with buttons to make it larger or smaller, and Dark Mode
  is supported. On an iPad, lines keep to a comfortable length.
- Choose a size: all of English Wikipedia (about 54 GB), its best-known articles with or without
  pictures, or just their opening paragraphs (about 0.3 GB).
- Download over Wi-Fi from inside the app. Downloads carry on in the background, and you are told
  when one is ready. Update to newer snapshots as they come out. Every file is checked before it
  is used.

The content is Wikipedia's, packaged by Kiwix and licensed CC BY-SA 4.0. Wiki Reader is not made by
or affiliated with the Wikimedia Foundation or Kiwix. It has no ads, accounts or tracking.

## App Review Information

- **Sign-in required:** no.
- **Contact:** the owner's name, phone and email, entered on the website (not kept here: this
  repository is public).
- **Notes:**

  Wiki Reader reads Wikipedia from a file on the device. It needs no account, and uses the
  network only to download that file when asked.

  On first launch there is no Wikipedia yet. To try the app: tap "Download Wikipedia…", then
  "Download" beside "Best-known articles, introductions only" (0.3 GB, Wi-Fi only). When the
  file has arrived and been checked, the app opens it by itself. Then type in the search field
  (for example "moon") and open an article. In an article, the list button at the bottom opens
  the Sections menu, and the "…" menu at the top has Save, Find in Article, Share and Open on
  Wikipedia.

  The downloads come from this project's GitHub release (the list of sizes and the search
  indexes) and from download.kiwix.org (Wikipedia itself). The content is Wikipedia's, licensed
  CC BY-SA 4.0; the app is not affiliated with the Wikimedia Foundation or Kiwix.

## Age rating

Wikipedia describes every subject factually, so each content category is "infrequent or mild"
rather than none, and nothing is graphic or the purpose of the app. The answers, as the API
names them:

| Question | Answer |
| --- | --- |
| Alcohol, tobacco or drug use or references | Infrequent or mild |
| Guns or other weapons | Infrequent or mild |
| Horror or fear themes | Infrequent or mild |
| Mature or suggestive themes | Infrequent or mild |
| Medical or treatment information | Infrequent or mild |
| Profanity or crude humor | Infrequent or mild |
| Sexual content or nudity | Infrequent or mild |
| Realistic violence | Infrequent or mild |
| Cartoon or fantasy violence | None |
| Graphic sexual content and nudity | None |
| Prolonged, graphic or sadistic realistic violence | None |
| Contests; simulated gambling | None |
| Gambling, loot boxes, advertising | No |
| Unrestricted web access | No: "Open on Wikipedia" hands over to Safari |
| User-generated content, messaging and chat, social media | No |
| Shared location; dating and relationships | No |
| Health or wellness topics (as an app's purpose) | No |
| Parental controls, age assurance | No |
| Made for kids | No |

## Screenshots

Taken in the simulators by `ios/App/UITests/AppStoreScreenshots.swift`, against the full English
Wikipedia, in the order the App Store shows them: an article (Paris, with its infobox), search
results, the Sections menu, Saved and Recently read, and Downloads.

- `AppStore/screenshots/iphone-*.png`: 6.9" iPhone (iPhone 17 Pro Max), 1320x2868.
- `AppStore/screenshots/ipad-*.png`: 13" iPad (iPad Pro 13-inch), 2064x2752.

The comment at the top of the test says how to run it. Clear the status bar first with
`xcrun simctl status_bar <simulator> override --time 9:41 --batteryState charged --batteryLevel 100`,
and uninstall the app so that its lists hold only what the test reads. App Store Connect refuses
screenshots with an alpha channel: `sips -g hasAlpha` should say `no`.
