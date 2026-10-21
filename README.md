# Logline

Letterboxd activity alerts for iPhone. Track any public Letterboxd member and get a notification when they log a film, write a review, make or change a list, add to their watchlist, like something or follow someone.

Built for iOS 17.0 and up, installed with TrollStore, built entirely on GitHub Actions.

## Getting it onto the phone

1. Push to `main`. The **Build IPA** workflow runs on GitHub's macOS 26 runner, takes a few minutes, and publishes a release tagged `build-N` with `Logline.ipa` attached.
2. On the iPhone, open the release in Safari, download `Logline.ipa`, and share it to TrollStore.
3. After that, Logline checks the repo's releases itself. **Settings → Updates** offers one-tap installs through TrollStore's URL scheme (turn it on in TrollStore's settings first).

The newest IPA always lives at `https://github.com/<you>/<repo>/releases/latest/download/Logline.ipa`.

Every build uses the Actions run number as its build number, so TrollStore always treats a new release as an upgrade and keeps your data.

> If GitHub Desktop doesn't push the `.github/workflows` folder, create the workflow on github.com instead: **Actions → New workflow → set up a workflow yourself**, name it `build.yml`, and paste in the file from this repo.

## Where the activity comes from

Letterboxd has no public API, so Logline reads the two public pages anyone can open:

| Source | What it gives |
|---|---|
| `letterboxd.com/<user>/rss/` | The last 50 diary entries and the member's lists, with poster, rating, like, rewatch flag, watched date and the full review. |
| `letterboxd.com/<user>/` | The profile's **Activity** sidebar: the five most recent actions, including watchlist additions, likes, follows and comments. Also the avatar, stats and a watchlist preview. |

New diary entries are matched by their RSS guid. A review that shows up in the sidebar before RSS catches up is alerted once and quietly upgraded with the poster and text when RSS arrives. Lists are watched for size changes. If a profile ever stops showing its Activity sidebar, Logline falls back to watching the watchlist preview and count.

The first check after adding an account files everything already there as history, so you never get a flood of old alerts.

## "The moment" new activity happens

iOS doesn't let an app run whenever it wants, and real server push needs a paid Apple developer account. A cloud poller isn't a way around that either: scraper vendors note that Letterboxd blocks datacenter IPs, and GitHub's runners are datacenter IPs. Polling from your own phone is the reliable route, so Logline has two modes:

**Instant** (the default) keeps Logline running in the background with a silent, mixable audio session. It never interrupts your music or shows up in Now Playing. Logline checks every 30 seconds to 15 minutes (60 seconds by default), so an alert lands within one interval of a post. Each check also pushes back a "Logline stopped watching" notification. If iOS kills the app or you swipe it away, that notification fires and tells you to reopen it. This costs battery, mostly from the network wakeups.

**Standard** uses Background App Refresh. iOS decides when it runs, usually every 15 minutes to a few hours. **Settings → Background** lists every run iOS actually granted, so you can see what your phone does.

The TrollStore build is fakesigned with the Time Sensitive notification entitlement, so alerts get through Focus modes and the scheduled summary.

**Skip Letterboxd's cache** adds a throwaway query parameter to each request so a CDN copy can't hold back a brand-new post.

## Troubleshooting

- **The build failed.** Open the failed run on the Actions tab. Compiler errors are listed as annotations at the top of the run, so you can copy them out directly.
- **No alerts.** Check **Settings → Notifications**, then **Settings → Diagnostics → Activity log**. Every check, alert, failure and background run is logged there, and the log can be shared.
- **"Letterboxd turned the profile request away."** Letterboxd's bot protection occasionally refuses a request. Logline backs off that profile for 15 minutes; diary entries keep arriving through RSS.
- **Instant mode isn't running.** It starts once at least one account is tracked. A phone call or Siri pauses it briefly and it resumes on its own.

## Building on a Mac

```bash
brew install xcodegen
xcodegen generate
open Logline.xcodeproj
```

`project.yml` is the source of truth. The `.xcodeproj` and `Resources/Info.plist` are generated, so both are gitignored.

## Layout

```
project.yml                     XcodeGen definition (iOS 17.0, unsigned)
.github/workflows/build.yml     Build, fakesign, release on every push to main
Resources/
  Assets.xcassets               App icon, accent and launch colors
  Logline.entitlements          Time Sensitive notifications, applied with ldid
Sources/
  App/                          App entry, delegates, tab shell
  Model/                        Accounts, activity items, preferences, notification text
  Letterboxd/                   Network client, RSS parser, profile parser, HTML helpers
  Engine/                       Polling and change detection, notifications,
                                background tasks, Instant-mode keep-alive, updater
  Support/                      Storage, diagnostics log, formatting
  UI/                           Feed, ticket rows, detail sheet, accounts, settings
```

Logline is a personal tool and isn't affiliated with Letterboxd.
