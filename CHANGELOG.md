# Changelog

Notable changes to `luci-app-footstrap-updater`, newest first. Format is
[Keep a Changelog](https://keepachangelog.com/1.1.0/); commits are
[Conventional Commits](https://www.conventionalcommits.org/), versions are
[SemVer](https://semver.org/). Sections, in fixed order: Added, Changed,
Deprecated, Removed, Fixed, Security, Performance — one of each per release.

[CHANGELOG_ru.md](CHANGELOG_ru.md) mirrors this file. Edit both in one commit.

Every commit writes into `[Unreleased]`. Cutting a tag renames that heading.

## [2.0.0] — 2026-08-01

### Removed

- **This package is retired, and installing this release uninstalls it.** It existed because a theme installed from a downloaded file is one the package manager knows no origin for and will never upgrade — so something had to check GitHub and fetch the next version. The theme's installer adds the owfeed-packages feed now, so `apk upgrade` does that job, for every package on the router, against an index signature the feed already carries. The final release hands the theme over and gets out of the way: `postinst` detaches `footstrap-updater-retire.sh`, which waits for the package database lock, adds the feed if it is missing (key, repository, and a `keep.d` entry so a firmware upgrade does not undo it), re-installs the theme *from* the feed — on apk that also clears the content-hash pin `apk add ./file.apk` leaves in `/etc/apk/world`, which is the reason a file-installed theme never upgrades — and only then removes this package. Detached and delayed because a package cannot uninstall itself inside its own install transaction: the manager holds the lock, and `apk del` there would block or corrupt it. Every step fails soft and the removal is gated on the theme actually being installed, so the worst outcome allowed is a router that still has the updater. `logread -e footstrap-retire` shows what happened.

## [1.2.1] — 2026-07-29

### Changed

- **Every released package carries this repository's own signature, and the release manifest is written by `owfeed release`.** [owfeed-packages](https://github.com/owfeed/owfeed-packages) now refuses a package it cannot attribute: the feed signs its index and not the packages it carries, so a published `.apk` held no evidence of who built it, and "the author is responsible for this package" rested on nothing checkable. `owfeed sign` puts an EC signature inside each package before the manifest is written — signing appends bytes, so the reverse order would describe files that no longer exist — and the public half is pinned in the feed. It changes nothing about installing: apk takes its trust from the signed index either way. The manifest itself now comes from `owfeed release` rather than from a shell loop here, and the usign signatures with it, so this repository and the theme stop carrying two implementations of one format. **The format identifier changes from `footstrap-manifest` to `owfeed-manifest`, and updaters already on routers are unaffected** — both readers parse positionally and never look at the first line, and owfeed's `pkg` line carries the same five tokens in the same order, appending the architecture as a sixth. Checked against a manifest owfeed actually produced, not inferred: file, size and sha256 come back identical, and `tag`, `version` and `notes` resolve as before.

## [1.2.0] — 2026-07-28

### Added

- **A router that has the package feed updates through it, and stops pinning itself out of future updates.** `check` reads the version its own package manager already has in its index — no request to github.com, no manifest, nothing to cache — and the Update button then runs `apk add --upgrade` (or `opkg upgrade`) instead of downloading a file. The release path stays exactly where it was, for a router with no repository and for the `curl | sh` install that cannot have one yet. What this fixes is not tidiness: every install this script ever did ran `apk add --allow-untrusted <file>`, and apk records that as a constraint on the package's **content hash** in `/etc/apk/world` — a line that survives sysupgrade and quietly opts the router out of the feed for good. `apk add --upgrade` is the one form that both rewrites that line to the bare name and moves the version; a bare `apk add` clears the pin and installs nothing, and `apk upgrade` on a pinned package succeeds while changing nothing, which is the worst shape a failure can take. Measured on live 25.12 and 24.10 routers: 0.11.5 pinned to a hash, `check` answers `v0.11.6` from the feed, the update lands 0.11.6 and leaves `luci-theme-footstrap` unpinned. The theme and this package are named in one call, so a theme release needing a newer updater cannot arrive without it.

### Security

- **A high-severity advisory in the dev toolchain is closed (`brace-expansion`).** Nothing shipped was affected — the npm tree exists only for the CI gates, and `luci.mk` copies neither it nor `package.json` — but a lint toolchain should not sit on a known advisory. Transitive, so only the lockfile changed: brace-expansion 5.0.8.

## [1.1.0] — 2026-07-25

### Added

- **An optional `GITHUB_PROXY`, read from UCI.** For networks where GitHub is unreachable at all. `uci set footstrap.settings.github_proxy=https://your-proxy/` prefixes github URLs, tried first with the direct route as fallback. Never read from the environment — rpcd hands this backend the caller's environment, so an env-sourced proxy would let anyone holding the update ACL point a root download at a host of their choosing; `GITHUB_PROXY` joins `http_proxy` in the unset list. Safe because the manifest is signed and every package is hashed against it.

- **A signed release manifest replaces `api.github.com` everywhere in this package.** `check`, `check-updater`, `notes`, the free-space preflight and the install itself all read `manifest.txt` + `manifest.txt.sig` from `releases/latest/download/` — the release CDN, which has no request budget. The REST API allows **60 unauthenticated requests per hour per source IP**, and this backend asked on every `check`, i.e. behind the update badge on page loads: behind CGNAT or a shared exit the budget was gone before the admin clicked anything, and every path died with `ERR: cannot reach the GitHub release API` (theme issue #17). Measured: the API answers `x-ratelimit-limit: 60`, `releases/latest/download/…` answers a 302 with no `x-ratelimit-*` header at all.

- **A release mirror on GitHub Pages, carrying the manifest and the packages.** A second host for a router that cannot reach `github.com` at all — and it has to carry the packages too, because a release asset URL redirects *through* `github.com`. It requires no trust: the manifest is signed, the packages are hashed against it, so the mirror can serve the real release or fail. Which host a manifest came from is recorded beside it on disk, because `check` caches the manifest and a later `notes` reads it back in another process; held in a variable, the origin was lost across that boundary and a mirrored router silently went back to `github.com` for the notes and the package.

### Changed

- **One signature check now covers the package, instead of two checks that answered different attackers.** The sha256 came from `@.assets[*].digest`, which GitHub computes from the uploaded bytes — replace an asset and the digest is recomputed for you — so an ed25519 signature over each package sat beside it. The hash now lives in the signed manifest, so verifying the manifest once covers every package it lists and the per-package `.sig` is not fetched. One request less per install, and a strictly stronger check.

- **The confirm dialog's release notes and the free-space preflight are signed data now.** The notes were `@.body` — text nothing had ever verified — and the preflight sized a root install against an unsigned `@.assets[*].size`. The notes are a `notes.md` asset whose sha256 the manifest carries (a mismatch simply shows no notes, which is right for a cosmetic string), and the sizes come out of the manifest.

- **The cache TTL is no longer a rate-limit budget.** 300 s stays, but for the CDN's sake rather than to ration 60 calls an hour.

### Removed

- **The fallback that picked this package out of the THEME's release, and the `asset_ver()` that supported it.** It existed for exactly one situation — this repo had no release yet — which ended when v1.0.0 shipped. Keeping it meant keeping a path nothing exercises, alongside a helper that existed only to read a version out of a file name because a theme release's tag is the theme's version.

### Fixed

- **A replayed manifest can no longer downgrade the theme.** A signed manifest is valid for ever, so an old one from a stale mirror or a cache would have installed an older theme over a newer one with every check passing. Strictly-older is now refused; equal still installs, because that is the Update button's deliberate reinstall.

- **A manifest naming a different repository is refused.** One key signs both repos' manifests, so without that check the theme's manifest would verify perfectly as this package's.

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

[2.0.0]: https://github.com/VizzleTF/luci-app-footstrap-updater/compare/v1.2.1...v2.0.0
[1.2.1]: https://github.com/VizzleTF/luci-app-footstrap-updater/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/VizzleTF/luci-app-footstrap-updater/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/VizzleTF/luci-app-footstrap-updater/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/VizzleTF/luci-app-footstrap-updater/commits/v1.0.0
