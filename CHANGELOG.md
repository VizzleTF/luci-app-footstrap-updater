# Changelog

Notable changes to `luci-app-footstrap-updater`, newest first. Format is
[Keep a Changelog](https://keepachangelog.com/1.1.0/); commits are
[Conventional Commits](https://www.conventionalcommits.org/), versions are
[SemVer](https://semver.org/). Sections, in fixed order: Added, Changed,
Deprecated, Removed, Fixed, Security, Performance — one of each per release.

[CHANGELOG_ru.md](CHANGELOG_ru.md) mirrors this file. Edit both in one commit.

Every commit writes into `[Unreleased]`. Cutting a tag renames that heading.

## [1.0.0] — 2026-07-22

### Added

- **The self-update backend and the Appearance update UI now live in their own repository, with their
  own tags and release stream, independent of the theme.** Extracted from
  `VizzleTF/luci-theme-footstrap`, where the two packages shared one version and one release. The
  updater now versions itself: `fs-update.js` carries `UPD_VERSION` (stamped from this repo's tags),
  and the self-updater compares the installed version against this repo's latest tag so an unchanged
  updater is neither downloaded nor reinstalled — "use the existing one". A release that only touches
  the theme no longer republishes the updater, and vice versa.
- **The self-updater resolves the theme and the updater from their two repos and installs both from a
  single click.** `do_update` hits both release APIs — the theme from `luci-theme-footstrap`, the
  updater from `luci-app-footstrap-updater` — verifies each against the one release key, and skips the
  updater leg when it is already current. The Appearance badge lights for a theme OR an updater update
  (`check` + `check-updater`), and the confirm dialog shows a version step per package that is behind.
- **The one-click Update shows the release notes, the version step and a breaking-change warning
  before it installs** (carried over from the theme). The notes are rendered as a text node (they are
  shown before the signature is verified), and a coloured banner appears when the release flags a
  `### Removed`/`### Security` heading or the word "breaking".
- **A free-space preflight refuses an update that would not fit before the first byte is downloaded**
  (carried over). It sums the asset sizes the API publishes and checks the tmpfs the download lands in
  and the overlay it unpacks into; it fails open, since space is not a security property.

### Changed

- **The updater resolves itself from this repo first and falls back to the theme's release while this
  repo has nothing to offer.** One resolver (`resolve_updater()`) now answers "where does the updater
  come from", and both the install and the badge go through it — a badge reading one source while the
  install reads another either offers an update that never happens or hides one that does. This repo
  wins whenever it publishes an asset, whatever the versions say, so the day it cuts its first release
  is the day every router crosses over with no second decision anywhere. Until then the theme's
  transition release carries a signed updater asset, and that is what gets installed: the same ed25519
  key verifies both sources, so the fallback changes where the bytes come from and never whether they
  are checked. On the fallback path the version comes from the asset FILE NAME (`asset_ver()`, both apk
  and ipk naming) — a theme release's `tag_name` is the theme's version, not this package's.
  **This repo's first tag must be higher than the transition build's version**: opkg refuses a
  downgrade by default ("Not downgrading package …"), exits 0 and installs nothing, so a lower tag
  would strand every 24.10 router on the transition build while reporting success.
- **`$EXT` is resolved once at top level instead of inside `do_update`.** `check-updater` resolves an
  asset too now, and with `$EXT` unset `asset_urls` grepped for a name ending in a bare dot — matching
  nothing, i.e. a silent "no update available" on every router.

### Fixed

- **A failing updater refresh no longer reports the whole update as failed after the theme has already
  installed** (carried over). `fetch_verify_install` installs nothing on a verify failure, so the old
  updater stays intact to retry, and the run finalises (drops caches, writes `OK`, the client reloads)
  once the theme is in.

[1.0.0]: https://github.com/VizzleTF/luci-app-footstrap-updater/commits/v1.0.0
