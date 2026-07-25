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
wget -qO- https://github.com/VizzleTF/luci-app-footstrap-updater/releases/latest/download/install.sh | sh
```

The URL is the **release asset**, not `raw.githubusercontent.com`: GitHub rate-limits raw for
unauthenticated callers (60 requests per hour per source IP), and behind CGNAT that budget is often
already spent by somebody else. Release assets carry no such budget. Neither the installer nor the
update check touches `api.github.com` any more — both read a **signed manifest** published with each
release (theme issue #17).

If the router cannot reach `github.com` at all, both legs can go through a GitHub proxy. The
installer takes it from the environment; **the update backend takes it from UCI and never from the
environment** — rpcd hands that process the caller's environment, so an env-sourced proxy would let
anyone holding the update ACL redirect a root download:

```sh
# one-off install through a proxy
GITHUB_PROXY=https://gh-proxy.com/ sh install.sh
# make the Update button use one, permanently
uci set footstrap.settings.github_proxy=https://gh-proxy.com/ && uci commit footstrap
```

Public proxies that worked when this was written, none of them ours and any of them able to vanish:
`https://gh-proxy.com/`, `https://ghproxy.net/`, `https://ghfast.top/`, `https://gh.llkk.cc/`. What
they deliver is safe regardless: every package is checked against the sha256 in the signed manifest.

## The trust chain

`install.sh` and `footstrap-selfupdate.sh` hand the downloaded package to apk/opkg with
`--allow-untrusted` — which means the package manager holds no key of ours, **not** that the bytes are
unverified. Verifying them is these scripts' own job: a verified-TLS fetch, an **ed25519 signature**
(`usign`) over the release **manifest**, and every package's sha256 carried inside that manifest.

One signature therefore covers every package the release lists. That is why the hash is no longer
taken from `@.assets[*].digest`: GitHub *computes* that from the uploaded bytes, so anyone who could
replace an asset — a leaked write-scoped PAT, no CI run involved — had the digest recomputed for them
and the check verified the attacker's package. A manifest cannot be re-signed that way; the key is a
secret that cannot be read back out.

Everything fails **closed**: a manifest that will not verify, one naming a different repository, a
missing or malformed hash, a checksum mismatch, or no `usign` on the box all refuse. It is also what
makes a proxy or a mirror safe to use — neither can influence a hash that is under the signature. See
the header comments in both scripts.

## Development

`luci-app-footstrap-updater/dev-sync.sh <router>` deploys to a dev router. Gates: `npm run check`
(eslint, `@mirror`, changelog, i18n) locally; CI additionally builds the signed packages and runs the
jsmin-equivalence check.

Licensed Apache-2.0.
