# Changelog

Notable changes to `luci-app-footstrap-updater`, newest first. Format is
[Keep a Changelog](https://keepachangelog.com/1.1.0/); commits are
[Conventional Commits](https://www.conventionalcommits.org/), versions are
[SemVer](https://semver.org/). Sections, in fixed order: Added, Changed,
Deprecated, Removed, Fixed, Security, Performance — one of each per release.

[CHANGELOG_ru.md](CHANGELOG_ru.md) mirrors this file. Edit both in one commit.

Every commit writes into `[Unreleased]`. Cutting a tag renames that heading.

## [Unreleased]

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

### Fixed

- **A failing updater refresh no longer reports the whole update as failed after the theme has already
  installed** (carried over). `fetch_verify_install` installs nothing on a verify failure, so the old
  updater stays intact to retry, and the run finalises (drops caches, writes `OK`, the client reloads)
  once the theme is in.
