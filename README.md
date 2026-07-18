# luci-app-footstrap-updater

The optional self-update package for [luci-theme-footstrap](https://github.com/VizzleTF/luci-theme-footstrap)
on OpenWrt 24.10 (ipk) and 25.12+ (apk).

It adds, to the theme's Appearance popover, a **version check** against GitHub and a **one-click
Update** button. Without it the theme still works and shows its version — it just has no update
controls and makes no network calls.

## What it ships

- `htdocs/luci-static/resources/fs-update.js` — the client: the GitHub check and the installer
  trigger, hosted in the theme's Appearance popover (loaded at runtime, so a missing updater is never
  a hard dependency of the theme).
- `root/usr/libexec/footstrap-selfupdate.sh` — the ACL-gated backend: resolve the release, verify the
  signature, install the package.
- `root/usr/share/rpcd/acl.d/…json` + `release.pub` — the `file.exec` grant for that one script, and
  the ed25519 public key its signature is checked against.

## Two repos, two release streams

Since the split from the theme, the theme and this updater ship from **separate repositories with
their own tags and versions**. The self-updater resolves and installs **both** from their two repos on
one click, verifying each against the one release key, and **skips the updater leg when it is already
current** — an unchanged updater is neither downloaded nor reinstalled. A release that only changes the
theme does not republish the updater, and vice versa.

## Install

One-liner (auto-detects apk/ipk, installs the theme AND this updater):

```sh
wget -qO- https://raw.githubusercontent.com/VizzleTF/luci-app-footstrap-updater/main/install.sh | sh
```

## The trust chain

`install.sh` and `footstrap-selfupdate.sh` hand the downloaded package to apk/opkg with
`--allow-untrusted` — which means the package manager holds no key of ours, **not** that the bytes are
unverified. Verifying them is these scripts' own job: a verified-TLS fetch, an **ed25519 signature**
(`usign`) over each package as the link that actually holds, and the sha256 GitHub publishes below it.
Everything fails **closed**: a missing digest, a missing `.sig` asset, or no `usign` on the box all
refuse. See the header comments in both scripts.

## Development

`luci-app-footstrap-updater/dev-sync.sh <router>` deploys to a dev router. Gates: `npm run check`
(eslint, `@mirror`, changelog, i18n) locally; CI additionally builds the signed packages and runs the
jsmin-equivalence check.

Licensed Apache-2.0.
