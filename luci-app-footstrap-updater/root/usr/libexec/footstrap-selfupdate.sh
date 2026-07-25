#!/bin/sh
# Footstrap theme self-update backend (ships in luci-app-footstrap-updater, NOT in the theme).
#
# Downloads the latest GitHub release packages for the Footstrap theme and installs them with apk
# (25.12+) or opkg (24.10). It installs BOTH the theme (luci-theme-footstrap) and this updater
# (luci-app-footstrap-updater), which since the split ship from their OWN GitHub repos with their own
# tags — so do_update reads two release manifests and skips the updater leg when it is already
# current. The repos and URLs are hard-coded and only fixed keywords are accepted, so the ACL-gated
# LuCI `file.exec` that triggers it has no injection surface.
#
# IT NO LONGER TOUCHES api.github.com — that is issue #17, and the reason is in the MF_* block below.
#
# But note WHAT the ACL gates: file.exec matches the command PATH only — `params` and `env` are the
# caller's. So the keyword is not limited to the two the client sends (`__run` is the privileged
# worker entrypoint — see that branch), and the environment is not ours either: PATH and the loader
# variables are pinned below, because LD_PRELOAD on /bin/sh is code execution as root for anyone
# holding this ACL.
#
# WHY IT DAEMONISES. The install outlives both RPC timeouts — rpc.js aborts the XHR after
# `rpctimeout` (20 s), rpcd kills the exec'd process after `rpcd.@rpcd[0].timeout` (30 s) — so a
# synchronous run reported "XHR request timed out" even when it succeeded, and rpcd could kill apk
# mid-install. The foreground call only spawns a detached worker; the client polls `status`.
#
# Protocol (stdout, one line unless noted):
#   <no args>       -> STARTED | RUNNING       (spawn worker / already running)
#   status          -> RUNNING | OK | ERR: <reason> | IDLE
#   check           -> v<tag> | ERR: <reason>  (latest THEME release tag, cached)
#   check-updater   -> v<tag> | ERR: <reason>  (latest UPDATER release tag, cached)
#   notes           -> <release body> | ""     (THEME release notes, multi-line, cached)
# The client reads the KEYWORD, not the exit code (except `notes`, whose whole stdout is the payload):
# `check`/`check-updater` exit 1 when the API is unreachable, an unknown argument exits 1, the rest 0.

# The CALLER sets this process's environment (above), so nothing may be resolved through an inherited
# PATH — nor through the dynamic loader, which PATH does not cover: /bin/sh is not setuid, so it
# honours LD_PRELOAD/LD_LIBRARY_PATH, and this ACL becomes arbitrary code as root. The proxy variables
# go too: they would redirect the fetch through a host of the caller's choosing.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT IFS http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY GITHUB_PROXY

# State in /var/run (a symlink to /tmp/run), NOT in /tmp. /tmp is 1777: a local unprivileged process
# can pre-create a predictable name there as a symlink, and root's `cp`, `chmod`, `-o` and `>` then
# write through it to a file of the attacker's choosing (CWE-377). /var/run is root-owned 0755, so
# the names below cannot be pre-created. Still tmpfs, so a reboot re-checks.
WD=/var/run/footstrap-update
STATUS="$WD/status"
WORKER="$WD/run.sh"
CACHE="$WD/latest"		# the "ts tag" meta line (THEME latest)
UCACHE="$WD/updater-latest"	# the "ts tag" meta line (UPDATER latest), for `check-updater`
THEME_MF="$WD/theme.mf"		# the VERIFIED theme manifest; feeds `check` (tag), `notes` and do_update
UPD_MF="$WD/updater.mf"		# the VERIFIED updater manifest
NOTES="$WD/notes.md"		# the release notes asset, hash-checked against the theme manifest
LOCK="$WD/lock"		# a DIRECTORY: mkdir is the atomic test-and-set (see the "" branch)

mkdir -p "$WD" 2>/dev/null && chmod 700 "$WD" 2>/dev/null || {
	echo "ERR: cannot create $WD"; exit 1
}

# How long a `check` result stays good. This used to be sized against GitHub's 60-unauthenticated-
# API-calls-per-hour-per-IP budget, which the badge could exhaust on a shared exit — issue #17, and
# the reason the manifest below replaced the API entirely. There is no budget on the release CDN, so
# the TTL is now only about not re-fetching on every page load. 5 minutes, not an hour: the TTL is
# exactly how long a freshly published release stays invisible, and an hour let the badge lag a
# release by most of one.
CACHE_TTL=300

# TWO repos since the split: the theme and the updater ship from their own GitHub repos, each with its
# own tags and release stream. `check`/`notes` (the badge + the confirm dialog) are about the THEME —
# that is what the user updates — so they read the theme's manifest. do_update installs BOTH, each
# from its own repo and each verified against the same key (one release.pub). The updater leg is
# SKIPPED when the installed version already matches the resolved one, so an unchanged updater is
# neither downloaded nor reinstalled.
REPO_THEME="VizzleTF/luci-theme-footstrap"
REPO_UPDATER="VizzleTF/luci-app-footstrap-updater"
PKG_THEME="luci-theme-footstrap"
PKG_UPDATER="luci-app-footstrap-updater"

# NO api.github.com ANYWHERE IN THIS FILE, and that is the point of the manifest.
#
# The API allows 60 unauthenticated requests per hour PER SOURCE IP. This script asks on every
# `check` — i.e. behind the badge, on page loads — so behind CGNAT, a shared exit or a DNS-based
# unblocker the budget is gone before the admin ever clicks anything, and every update path died
# with "cannot reach the GitHub release API" (issue #17). The release CDN has no such budget:
# `releases/latest/download/<file>` answers a 302 with no x-ratelimit-* header at all, and it has
# been serving the packages themselves all along.
#
# So the metadata moved into manifest.txt — a signed, line-oriented file published as a release
# asset, carrying the tag, and every package's name, size and sha256. See resolve_manifest.
MF_THEME="https://github.com/${REPO_THEME}/releases/latest/download/manifest.txt"
MF_UPDATER="https://github.com/${REPO_UPDATER}/releases/latest/download/manifest.txt"
# The mirror on GitHub Pages — a different host, carrying the same signed manifest AND the packages
# it names, for when github.com itself cannot be reached. Requires no trust: the manifest's
# signature and the hashes under it are checked identically whichever host served the bytes.
MIRROR_THEME="https://vizzletf.github.io/luci-theme-footstrap"
MIRROR_UPDATER="https://vizzletf.github.io/luci-app-footstrap-updater"

# An OPTIONAL prefix put in front of every github.com URL, for networks where GitHub is unreachable.
# Empty unless the admin sets it:  uci set footstrap.settings.github_proxy=https://example/ ; uci commit
#
# READ FROM UCI, NEVER FROM THE ENVIRONMENT, and that is the whole design of it. rpcd hands this
# process the CALLER's environment — which is why PATH and the loader variables are pinned above and
# http_proxy is unset — so an env-sourced proxy would let anyone holding this ACL point a root
# download at a host of their choosing. UCI is writable by root alone, so the setting is the
# admin's, not the caller's. GITHUB_PROXY is unset with the rest for the same reason.
#
# Safe to offer because the manifest is signed and every package is hashed against it: a proxy can
# serve the real release or fail, and nothing in between. Unlike install.sh there is no unsigned
# script in the path here — this file is already on disk, installed from a verified package.
GITHUB_PROXY="$(uci -q get footstrap.settings.github_proxy 2>/dev/null)"
case "$GITHUB_PROXY" in
	https://*) ;;
	*) GITHUB_PROXY="" ;;	# anything not https is ignored, silently and safely
esac

# Which package manager this router runs — apk on 25.12+, opkg on 24.10 — and therefore which `pkg`
# line of the manifest applies. Resolved ONCE, at top level, NOT inside do_update: `check-updater`
# reads a manifest too, and an unset $EXT there makes mf_pkg match no line at all — a silent "no
# update available" on every router.
if command -v apk >/dev/null 2>&1; then EXT="apk"
elif command -v opkg >/dev/null 2>&1; then EXT="ipk"
else EXT=""
fi

# The release public key, shipped BY THIS PACKAGE. Read from disk rather than embedded, so the key
# travels with the code that trusts it: a key rotation is then one file in one release, and the router
# that installs that release is the one that starts trusting the new key. install.sh is the one place
# that has to carry a second copy — it runs from `curl | sh`, before any package exists — and CI fails
# if the two ever differ.
PUBKEY=/usr/share/luci-app-footstrap-updater/release.pub

# fetch <url> <max-seconds> [outfile]   — stdout when no outfile.
#
# curl is NOT on a stock OpenWrt router — the base image ships `uclient-fetch`, curl is a separately-
# installed package (dev router: `/usr/bin/curl is owned by curl-8.19.0-r2`). This script hard-required
# it, so on a stock router BOTH the update badge and the Update button died with "ERR: cannot reach the
# GitHub release API" (reproduced by moving /usr/bin/curl aside). Falling back keeps the dep list at
# +luci-base (+luci-theme-footstrap).
#
# Every fetch is BOUNDED: without a timeout a stalled connection leaves STATUS=RUNNING and a live
# $WORKER behind forever — what the "" branch reads as "a run is in progress" — so the button wedges
# until a reboot.
#
# The certificate is always verified. Never add a `-k` / `--no-check-certificate` fallback: a failed
# verification IS the MITM case, and ca-bundle is in OpenWrt's DEFAULT_PACKAGES, so the insecure path
# buys nothing.
#
# BE PRECISE ABOUT WHAT SURVIVES A REDIRECT, because the asset genuinely hops to
# objects.githubusercontent.com and -L has to follow it:
#   - the scheme pin (--proto-redir '=https') exists ONLY on the curl branch. uclient-fetch is tried
#     FIRST and is the only downloader on a stock router (curl is not in the default package set —
#     that is why this fallback chain exists at all), and it has no such flag: it follows up to 10
#     redirects, and an absolute Location: is re-parsed from scratch, so http:// would be followed.
#   - asset_host_ok() pins the host of the INITIAL request only; no backend pins the host across a
#     redirect, and -L is cross-host by design.
# So on the path a stock router actually takes, the ed25519 signature checked below is the ONE layer
# that survives a redirect. That is sound — it is what makes the package trustworthy, and the package
# manager installs --allow-untrusted regardless (it holds no key of ours) — but do not read this
# channel as more than "a verified-certificate delivery of the release metadata".
# @mirror gh/fetch
fetch_direct() {
	_u="$1"; _t="$2"; _o="$3"
	if command -v uclient-fetch >/dev/null 2>&1; then
		if [ -n "$_o" ]; then uclient-fetch -T "$_t" -qO "$_o" "$_u" 2>/dev/null
		else uclient-fetch -T "$_t" -qO- "$_u" 2>/dev/null; fi
		return $?
	fi
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_o" ]; then
			curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time "$_t" -o "$_o" "$_u" 2>/dev/null
		else
			curl -fsSL --proto =https --proto-redir =https --connect-timeout 10 --max-time "$_t" "$_u" 2>/dev/null
		fi
		return $?
	fi
	if command -v wget >/dev/null 2>&1; then
		_s=''
		wget --help 2>&1 | grep -q -- '--https-only' && _s='--https-only'
		if [ -n "$_o" ]; then wget -q $_s -T "$_t" -O "$_o" "$_u"
		else wget -q $_s -T "$_t" -O- "$_u"; fi
		return $?
	fi
	return 1
}
# fetch <url> <max-seconds> [outfile] — the one every caller uses. With no GITHUB_PROXY set (the
# default) it IS fetch_direct; with one set, GitHub URLs are tried through the proxy first and fall
# back to the direct route, so a dead proxy cannot take the install down with it.
#
# Only github hosts are rewritten. A proxy prefix has no business in front of, say, the Pages mirror
# URL, and an unconditional rewrite would send every future URL through a third party by accident.
#
# The proxy can serve wrong bytes; it cannot serve bytes that pass. Everything fetched through here
# is either checked against the signed manifest (packages, notes) or IS the signature check itself
# (the manifest and its .sig). The one thing outside that chain is this script, which is why the
# documented install URL never goes through a proxy — see the GITHUB_PROXY note at the top.
fetch() {
	_fu="$1"; _ft="$2"; _fo="$3"
	if [ -n "$GITHUB_PROXY" ]; then
		case "$_fu" in
			https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*|https://objects.githubusercontent.com/*|https://release-assets.githubusercontent.com/*)
				if fetch_direct "${GITHUB_PROXY%/}/$_fu" "$_ft" "$_fo"; then
					[ -z "$_fo" ] || [ -s "$_fo" ] && return 0
				fi
				[ -n "$_fo" ] && rm -f "$_fo"
				;;
		esac
	fi
	fetch_direct "$_fu" "$_ft" "$_fo"
}
# @endmirror

# The URL comes out of the API answer and the file it names is handed to `apk add --allow-untrusted`
# as root. Pin the host, so a malformed or tampered response cannot point that install at an arbitrary
# server.
# @mirror gh/asset-host
# vizzletf.github.io is the release MIRROR (see resolve_manifest). It is on the list because a
# mirrored install fetches its packages from there — not because being on the list is what makes
# those bytes acceptable: what does that is the sha256 in the signed manifest, which the mirror
# cannot influence.
asset_host_ok() {
	case "$1" in
		https://github.com/*|https://objects.githubusercontent.com/*|https://release-assets.githubusercontent.com/*) return 0 ;;
		https://vizzletf.github.io/*) return 0 ;;
	esac
	return 1
}
# @endmirror

# Pick the asset by package NAME, not by extension. `grep "\.apk$" | head -n1` — what this did — takes
# whichever asset GitHub lists first, and the API sorts assets BY NAME: in v0.8.4, when the release
# still carried separate luci-i18n-footstrap-<lang> packages, that was a 6 KB catalogue installed in
# place of the theme (issue #6). Releases hold ONE package per format per NAME now; the name match is
# the fix for the next such mistake.
#
# `[-_]` is the separator both naming schemes use and is what keeps the two names apart (apk:
# `name-1.2.3-r1.apk`, ipk: `name_1.2.3-r1_all.ipk`); anchoring on `/` in front stops a repo or tag
# containing the package name from matching.
#
# The manifest reader. `pkg` lines are `pkg <name> <ext> <file> <size> <sha256>`; everything else is
# `<key> <value>`. Line-oriented on purpose — awk is in busybox, so this path needs no jsonfilter at
# all, one fewer thing between a router and an update.
# @mirror gh/manifest-parse
mf_get() { awk -v k="$2" '$1==k {print $2; exit}' "$1"; }
mf_pkg() {		# <manifest> <package-name> <ext> -> "<file> <size> <sha256>"
	awk -v n="$2" -v e="$3" '$1=="pkg" && $2==n && $3==e {print $4, $5, $6; exit}' "$1"
}

# The manifest names the asset FILE, and that name becomes both a URL and a path in the working
# directory. The signature is what makes the name trustworthy — but a compromised pipeline signing
# `../../etc/something` must still not become a path traversal as root, and a defence that only
# works when the other defence held is not a defence.
safe_name() {
	case "$1" in
		''|*/*|.*|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
	return 0
}
# @endmirror

# The version the package manager reports as installed, and the package-release suffix stripped so it
# compares against a bare release tag. apk prints `luci-app-footstrap-updater-1.2.3-r1 …`; opkg prints
# `Version: 1.2.3-r1`. The updater tag drives PKG_VERSION (`1.2.3`), so strip the `-rN`/`-N` release
# suffix from both before comparing. Used only to decide whether the updater leg can be SKIPPED.
ver_base() { echo "${1%-*}"; }		# 1.2.3-r1 -> 1.2.3 ; 1.2.3 -> 1.2.3 (no dash: unchanged)

# Is $1 strictly older than $2? Field-by-field numeric compare, so 0.10.0 > 0.9.9 (a string compare
# gets that backwards, and this project has already shipped a 0.9 -> 0.10 boundary). A non-numeric
# field compares as 0 and the answer degrades to "not older", which is the safe direction: it
# permits the install rather than blocking a legitimate one.
ver_lt() {		# 0 iff $1 is strictly older than $2
	_vi=1
	while [ "$_vi" -le 3 ]; do
		_vx=$(echo "$1" | cut -d. -f"$_vi"); _vy=$(echo "$2" | cut -d. -f"$_vi")
		case "$_vx" in ''|*[!0-9]*) _vx=0 ;; esac
		case "$_vy" in ''|*[!0-9]*) _vy=0 ;; esac
		[ "$_vx" -lt "$_vy" ] && return 0
		[ "$_vx" -gt "$_vy" ] && return 1
		_vi=$((_vi + 1))
	done
	return 1
}

# Fetch a repo's signed manifest, VERIFY it, and only then let anything read it. Order matters:
# parsing first would mean acting on unverified text, and every value in there steers a download.
#
# RECORDS WHERE THE MANIFEST CAME FROM, in a file beside it (`<manifest>.base`), because that fact
# outlives this process: `check` caches the manifest and a LATER `notes` reads it back without
# re-resolving. Held in a variable, the origin was lost across that boundary and every mirrored
# router silently went back to github.com for the notes and the package — measured: `check` answered
# from the mirror, `notes` came back empty. A router that could not reach github.com for the manifest
# will not reach it for a package either (a release asset URL redirects THROUGH github.com), so the
# mirror has to serve both, and the signed sha256 is what holds in either case.
#
# Return codes are distinct because the fixes are: 1 = could not fetch, 2 = signature failed (never
# overridable), 3 = verified but describes a DIFFERENT repo. That last one is not pedantry: ONE key
# signs both repos' manifests, so without the `repo` check a manifest lifted from the theme's
# release verifies perfectly as the updater's. A signature proves who wrote a file, never what the
# file is about.
#
# Every name is `_mf*`: sh has no locals and fetch() assigns `_u`, `_t` and `_o` — writing this with
# the obvious names cost an afternoon in the theme's installer, where `_o` came back as the .sig
# path and the tag check silently compared the timeout against "latest".
resolve_manifest() {	# <repo> <manifest-url> <mirror-base> <outfile> <timeout>
	_mfrepo="$1"; _mfurl="$2"; _mfmirror="$3"; _mfout="$4"; _mftmo="$5"
	: > "$_mfout.base"

	if ! { fetch "$_mfurl" "$_mftmo" "$_mfout" && [ -s "$_mfout" ] &&
	       fetch "$_mfurl.sig" "$_mftmo" "$_mfout.sig" && [ -s "$_mfout.sig" ]; }; then
		[ -n "$_mfmirror" ] || return 1
		fetch "$_mfmirror/manifest.txt" "$_mftmo" "$_mfout" && [ -s "$_mfout" ] || return 1
		fetch "$_mfmirror/manifest.txt.sig" "$_mftmo" "$_mfout.sig" && [ -s "$_mfout.sig" ] || return 1
		echo "$_mfmirror" > "$_mfout.base"
	fi

	verify_sig "$_mfout" "$_mfout.sig" "$PUBKEY" || return 2
	[ "$(mf_get "$_mfout" repo)" = "$_mfrepo" ] || return 3
	return 0
}

# The URL to fetch a file the manifest names. Built HERE from the manifest's own tag — never from
# `latest` — because between reading the manifest and fetching the package a newer release can
# become latest, and the sha256 about to be enforced belongs to the release we READ.
mf_asset_url() {	# <manifest> <repo> <file> -> url
	_mfbase="$(cat "$1.base" 2>/dev/null)"
	if [ -n "$_mfbase" ]; then
		echo "$_mfbase/$3"
	else
		echo "https://github.com/$2/releases/download/$(mf_get "$1" tag)/$3"
	fi
}
installed_ver() {	# <pkg> -> installed version, or empty (not installed / manager unknown)
	if command -v apk >/dev/null 2>&1; then
		apk list -I "$1" 2>/dev/null | sed -n "s/^$1-\([0-9][^ ]*\) .*/\1/p" | head -n1
	elif command -v opkg >/dev/null 2>&1; then
		opkg status "$1" 2>/dev/null | sed -n 's/^Version: *//p' | head -n1
	fi
}

# THE UPDATER COMES FROM ITS OWN REPO, and from nowhere else.
#
# There used to be a second source here: the updater was picked out of the THEME release when its own
# repo offered nothing. That fallback existed for exactly one situation — the updater repo had no
# release yet — and it ended the day that repo published v1.0.0. Keeping it meant keeping a path that
# nothing ever exercises and that no test covers, alongside asset_ver(), which existed only to read a
# version out of a file name because a theme release's tag is the theme's version. Both are gone.
#
# Sets U_VER and, on success, leaves the VERIFIED updater manifest in $UPD_MF. Returns 1 when the
# updater repo offers no package for this router's format, which every caller treats as "nothing to
# do", never as an error.
resolve_updater() {	# <fetch-timeout>
	U_VER=""
	resolve_manifest "$REPO_UPDATER" "$MF_UPDATER" "$MIRROR_UPDATER" "$UPD_MF" "$1" || return 1
	[ -n "$(mf_pkg "$UPD_MF" "$PKG_UPDATER" "$EXT")" ] || return 1
	U_VER="$(ver_base "$(mf_get "$UPD_MF" version)")"
	[ -n "$U_VER" ] || return 1
	return 0
}

# usign is on EVERY OpenWrt image — base-files depends on it — so verifying the release signature costs
# no new runtime dependency (see LUCI_DEPENDS in the Makefile: the curl lesson). The key is the
# package's own; it is not added to /etc/apk/keys, so nothing this package does makes footstrap a trust
# anchor for the router's package manager at large.
# @mirror gh/verify-sig
verify_sig() {		# <file> <sigfile> <pubkey-file> -> 0 iff the signature is ours and intact
	command -v usign >/dev/null 2>&1 || return 2
	usign -V -q -m "$1" -x "$2" -p "$3"
}
# @endmirror

# Download ONE asset, verify it, install it. $1 = url, $2 = the sha256 out of the SIGNED manifest.
# Writes ERR: to $STATUS and returns non-zero on any failure.
#
# ONE check now, where there used to be two, and it is the stronger of them. The ed25519 signature is
# still what vouches for the bytes — it is simply checked ONCE, over the manifest, before any of this
# runs (resolve_manifest), and the hash below is the link from that signature to this package. So the
# per-package .sig is not fetched: verifying it would re-prove what the manifest already proved.
#
# It fails CLOSED. A hash that is empty or not hex refuses; a mismatch refuses; a manifest whose
# signature did not verify never reaches this function at all. The `if [ -n "$digest" ]` shape this
# once had fails OPEN — a renamed field or an absent tool leaves the variable empty and the install
# proceeds with no integrity check while reporting OK. Bytes we cannot account for, we do not hand to
# root.
#
# usign's absence is a refusal too, and it happens EARLIER than it used to: verify_sig returns 2, so
# resolve_manifest returns 2 and the caller reports it. Nothing downstream can be reached without it.
fetch_verify_install() {
	url="$1"; want="$2"		# the sha256 from the SIGNED manifest
	pkg="$WD/pkg.$EXT"

	asset_host_ok "$url" || { echo "ERR: asset from an unexpected host" > "$STATUS"; return 1; }

	fetch "$url" 600 "$pkg" || { echo "ERR: download failed" > "$STATUS"; return 1; }
	[ -s "$pkg" ] || { echo "ERR: empty download" > "$STATUS"; rm -f "$pkg"; return 1; }

	# The hash came out of a manifest whose ed25519 signature was checked before it was parsed, so
	# THIS comparison is the signature check, applied to the package. That is why no per-package .sig
	# is fetched here any more: one usign verification over the manifest covers every hash it lists.
	# (The .sig assets are still published — a self-updater already in the field fetches them, and a
	# router's installed updater cannot be fixed remotely.)
	#
	# It is strictly stronger than what it replaced. The old check compared against
	# `@.assets[*].digest`, which GitHub COMPUTES from the uploaded bytes: anyone who could replace
	# an asset (a leaked write-scoped PAT, no CI run involved) had the digest recomputed for them and
	# the check then verified the attacker's package. A manifest cannot be re-signed that way — the
	# key is a secret that cannot be read back out.
	case "$want" in
		[0-9a-fA-F][0-9a-fA-F]*) ;;
		*) echo "ERR: the release manifest lists no sha256 for the asset, refusing to install" > "$STATUS"
		   rm -f "$pkg"; return 1 ;;
	esac
	got="$(sha256sum "$pkg" 2>/dev/null | cut -d' ' -f1)"
	[ -n "$got" ] && [ "$want" = "$got" ] || {
		echo "ERR: checksum mismatch against the signed manifest, refusing to install" > "$STATUS"
		rm -f "$pkg"; return 1
	}

	out="$(install_pkg "$pkg" 2>&1)"; rc=$?
	rm -f "$pkg"
	# The protocol is one line; apk's failure output is many. Flatten and cap it.
	[ "$rc" = 0 ] || {
		reason="$(printf '%s' "$out" | tr '\n\t' '  ' | tail -c 200)"
		echo "ERR: install failed: ${reason}" > "$STATUS"; return 1
	}
}

# Free-space preflight — a UX safety net, NOT a security gate, and it FAILS OPEN. An install that runs
# out of room mid-`apk add` leaves /www/luci-static/footstrap half-written (the worst failure on an
# 8-16 MB device). Sum the sizes the API publishes for the assets we will fetch and check both
# filesystems the update touches BEFORE the first byte is downloaded.
#
# Fails OPEN on purpose: a missing @.size or an unreadable df must NOT block a legitimate,
# correctly-signed update — space is not a security property (contrast the fail-CLOSED trust chain
# below, where a missing digest or signature refuses). Worst case without this check is the
# pre-existing behaviour: apk fails and the client shows its error.
# The sizes are the manifest's now, and therefore SIGNED. They used to come from
# `@.assets[*].size` — an unsigned number, which is a strange thing to have been sizing a root
# install against even for a fail-open check.
# check_space <size>...  -> 0 = enough (or unknown); 1 = short (writes ERR to $STATUS)
check_space() {
	_need=0; _max=0
	for _s in "$@"; do
		case "$_s" in ''|*[!0-9]*) return 0 ;; esac	# size unknown -> skip the check (fail open)
		_need=$((_need + _s))
		[ "$_s" -gt "$_max" ] && _max="$_s"
	done
	_need_kb=$((_need / 1024 + 1))
	_max_kb=$((_max / 1024 + 1))
	# download lands in $WD (tmpfs = RAM), one package at a time (each rm'd after its install);
	# install unpacks into the root overlay (flash), ~2x the compressed size. 512 KB margin each.
	_tmp="$(df -k "$WD" 2>/dev/null | awk 'NR==2{print $4}')"
	_root="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
	case "$_tmp" in ''|*[!0-9]*) _tmp=0 ;; esac
	case "$_root" in ''|*[!0-9]*) _root=0 ;; esac
	if [ "$_tmp" -gt 0 ] && [ "$_tmp" -lt $((_max_kb + 512)) ]; then
		echo "ERR: not enough RAM to download the update (~${_max_kb} KB needed, ${_tmp} KB free in /var/run)" > "$STATUS"
		return 1
	fi
	if [ "$_root" -gt 0 ] && [ "$_root" -lt $((_need_kb * 2 + 512)) ]; then
		echo "ERR: not enough free space to install the update (~$((_need_kb * 2)) KB needed, ${_root} KB free)" > "$STATUS"
		return 1
	fi
	return 0
}

do_update() {
	case "$EXT" in
		apk) install_pkg() { apk add --allow-untrusted "$1"; } ;;
		ipk) install_pkg() { opkg install "$1"; } ;;
		*) echo "ERR: no apk or opkg found" > "$STATUS"; return 1 ;;
	esac

	# --- THEME: from the theme repo -------------------------------------------------------------
	# The theme is the essential package and the one the user updates. Named in the manifest, never
	# picked by a bare `\.$EXT$` glob: a release with more than one same-format asset is a trap for a
	# self-updater that picks by extension (issue #6). Its absence is a broken release, a hard fail.
	#
	# The manifest is re-fetched here rather than reused from `check`'s cache: the cache is up to
	# CACHE_TTL old, and this is the copy whose hashes are about to gate an install as root.
	resolve_manifest "$REPO_THEME" "$MF_THEME" "$MIRROR_THEME" "$THEME_MF" 20; rc=$?
	case "$rc" in
		0) ;;
		2) echo "ERR: BAD SIGNATURE on the release manifest — refusing to install" > "$STATUS"; return 1 ;;
		3) echo "ERR: the release manifest is for a different repository — refusing" > "$STATUS"; return 1 ;;
		*) echo "ERR: cannot fetch the release manifest from github.com" > "$STATUS"; return 1 ;;
	esac
	set -- $(mf_pkg "$THEME_MF" "$PKG_THEME" "$EXT")	# file size sha256
	theme_file="$1"; theme_size="$2"; theme_sha="$3"
	[ -n "$theme_file" ] && [ -n "$theme_sha" ] || {
		echo "ERR: no ${PKG_THEME} .${EXT} in the latest release" > "$STATUS"; return 1
	}
	safe_name "$theme_file" || {
		echo "ERR: the manifest names an implausible asset, refusing" > "$STATUS"; return 1
	}
	theme_url="$(mf_asset_url "$THEME_MF" "$REPO_THEME" "$theme_file")"

	# A DOWNGRADE IS A REFUSAL. A signed manifest stays valid for ever, so an old one replayed at a
	# router — by a stale mirror, by a cache, by someone who kept a copy — would otherwise reinstall
	# an older theme over a newer one, verifying perfectly the whole way. Nothing else in the chain
	# says no to that: the signature is genuine and the hash matches. Equal versions are allowed
	# through, because that is a deliberate reinstall from the Update button.
	if ver_lt "$(mf_get "$THEME_MF" version)" "$(ver_base "$(installed_ver "$PKG_THEME")")"; then
		echo "ERR: the release offers an OLDER theme than the one installed — refusing" > "$STATUS"
		return 1
	fi

	# --- UPDATER: its own repo, SKIPPED when already current -------------------------------------
	# Optional in BOTH directions — nothing to resolve is skipped, and a present-but-failing install
	# is non-fatal once the theme is in (below). ORDER: theme first, updater second — the updater
	# package overwrites THIS running script, which is why the worker runs from a staged copy
	# ($WORKER, see the "" branch).
	#
	# The compare is `!=`, not "newer than": the updater repo is authoritative for its own package.
	updater_url=""; updater_size=""; updater_sha=""
	if resolve_updater 20 && [ "$U_VER" != "$(ver_base "$(installed_ver "$PKG_UPDATER")")" ]; then
		set -- $(mf_pkg "$UPD_MF" "$PKG_UPDATER" "$EXT")
		if [ -n "$1" ] && [ -n "$3" ] && safe_name "$1"; then
			updater_size="$2"; updater_sha="$3"
			updater_url="$(mf_asset_url "$UPD_MF" "$REPO_UPDATER" "$1")"
		fi
	fi

	# Free space, before any download, so a short device fails with a clear cause instead of a
	# half-written tree. The sizes are the signed ones out of each manifest.
	check_space "$theme_size" || return 1
	[ -n "$updater_url" ] && { check_space "$updater_size" || return 1; }

	fetch_verify_install "$theme_url" "$theme_sha" || return 1

	# The theme (the essential package) is now on disk. A failing updater refresh must NOT strand it
	# behind stale caches: fetch_verify_install installs NOTHING on a verify failure — the old,
	# already-verified updater stays intact and retries next time — so a present-but-failing updater is
	# a success for the update as a whole, not a failure that reports ERR and skips the reload. It once
	# did `|| { return 1; }`, which left the new theme on disk while status=ERR, the LuCI caches
	# undropped and the client refusing to reload: the update looked failed and the new theme never
	# visibly applied. Re-assert RUNNING so a poll landing between the transient ERR fetch_verify_install
	# wrote and the OK below never sees it.
	if [ -n "$updater_url" ]; then
		fetch_verify_install "$updater_url" "$updater_sha" || echo "RUNNING" > "$STATUS"
	fi

	# drop the LuCI menu/dispatch + module caches so the new theme is served at once
	rm -f /tmp/luci-indexcache* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null

	echo "OK" > "$STATUS"
}

case "$1" in
check)
	# The router asks GitHub, not the browser: a LAN client often has no route to the internet, and a
	# browser fetch is subject to CORS. Cached in /var/run (root-owned tmpfs — see the CWE-377 note
	# above), so a reboot re-checks. The VERIFIED manifest is kept beside the cache so `notes` can use
	# the same fetch — one request feeds both.
	now=$(date +%s)
	if [ -f "$CACHE" ] && [ -f "$THEME_MF" ]; then
		read -r ts tag < "$CACHE"
		# A truncated cache (full tmpfs) leaves ts empty or non-numeric, and an arithmetic error is
		# FATAL in ash: the script would die here and `check` would answer with an empty string instead
		# of ERR:. Force a miss.
		case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
		if [ -n "$tag" ] && [ $((now - ts)) -lt "$CACHE_TTL" ]; then
			echo "$tag"; exit 0
		fi
	fi

	resolve_manifest "$REPO_THEME" "$MF_THEME" "$MIRROR_THEME" "$THEME_MF" 10; rc=$?
	case "$rc" in
		0) ;;
		2) echo "ERR: BAD SIGNATURE on the release manifest"; exit 1 ;;
		3) echo "ERR: the release manifest is for a different repository"; exit 1 ;;
		*) echo "ERR: cannot fetch the release manifest from github.com"; exit 1 ;;
	esac
	tag="$(mf_get "$THEME_MF" tag)"
	[ -n "$tag" ] || { echo "ERR: the release manifest names no tag"; exit 1; }
	echo "$now $tag" > "$CACHE"
	echo "$tag"
	exit 0
	;;
notes)
	# The release notes, for the confirm dialog (versions + notes + breaking-change banner). They are
	# a release ASSET now, not `@.body` — that field was the last thing keeping api.github.com in this
	# file — and the manifest carries their sha256, so what the dialog shows is covered by the same
	# signature as everything else. It used to be text nobody had ever checked.
	#
	# The OUTPUT IS THE PAYLOAD, not a keyword: the client reads the whole stdout as untrusted display
	# text and renders it as a text node (never markup). Best-effort: any failure yields an empty body
	# and the dialog simply omits the notes — including a hash mismatch, which is the right call for a
	# cosmetic string when the package it describes is verified separately and later.
	[ -f "$THEME_MF" ] || resolve_manifest "$REPO_THEME" "$MF_THEME" "$MIRROR_THEME" "$THEME_MF" 10 >/dev/null 2>&1
	[ -f "$THEME_MF" ] || exit 0
	set -- $(awk '$1=="notes"{print $2, $3; exit}' "$THEME_MF")	# sha256 file
	[ -n "$1" ] && [ -n "$2" ] && safe_name "$2" || exit 0
	if [ ! -f "$NOTES" ] || [ "$(sha256sum "$NOTES" 2>/dev/null | cut -d' ' -f1)" != "$1" ]; then
		fetch "$(mf_asset_url "$THEME_MF" "$REPO_THEME" "$2")" 10 "$NOTES" >/dev/null 2>&1 || exit 0
		[ "$(sha256sum "$NOTES" 2>/dev/null | cut -d' ' -f1)" = "$1" ] || { rm -f "$NOTES"; exit 0; }
	fi
	cat "$NOTES"
	exit 0
	;;
check-updater)
	# The UPDATER's own latest tag, from its own repo — the client compares it against the installed
	# UPD_VERSION (fs-update.js) so the badge can light for an updater-only update too. Cached like
	# `check`, its own file, its own 5-min TTL, so it costs at most one extra API call per window.
	now=$(date +%s)
	if [ -f "$UCACHE" ]; then
		read -r ts tag < "$UCACHE"
		case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
		if [ -n "$tag" ] && [ $((now - ts)) -lt "$CACHE_TTL" ]; then
			echo "$tag"; exit 0
		fi
	fi
	# Resolved through the SAME resolver do_update uses, and that is the point: a badge that reads one
	# source while the install reads another either offers an update that does not happen or hides one
	# that does.
	resolve_updater 10 || { echo "ERR: cannot fetch the updater manifest from github.com"; exit 1; }
	tag="v$U_VER"
	echo "$now $tag" > "$UCACHE"
	echo "$tag"
	exit 0
	;;
status)
	[ -f "$STATUS" ] && cat "$STATUS" || echo "IDLE"
	exit 0
	;;
__run)
	# The privileged worker entrypoint, and it is REACHABLE OVER RPC: the file.exec ACL matches the
	# command PATH only and `params` are free, so any session holding the ACL can call __run directly.
	# That would run do_update in the FOREGROUND and WITHOUT $LOCK — racing a normal spawn into two
	# concurrent `apk add` on the same package (the bug the lock below fixes) — and rpcd would kill it
	# at its 30 s timeout, possibly mid-install, leaving /www/luci-static/footstrap half written.
	#
	# The staged copy is the only legitimate caller: the spawn below execs "$WORKER", so that is what
	# $0 must be. An RPC caller names the installed path and gets nothing.
	[ "$0" = "$WORKER" ] || { echo "ERR: unknown argument"; exit 1; }
	do_update
	rm -f "$WORKER"
	rmdir "$LOCK" 2>/dev/null
	exit 0
	;;
"")
	# Two RPCs arriving together must not both start an install: read-then-write is not atomic, so a
	# status check followed by a spawn had both callers read "not running" and both spawn a worker —
	# two concurrent `apk add` on the same package (reproduced by firing this twice). mkdir is atomic
	# (it fails if the name exists), so it IS the lock.
	#
	# THE LOCK IS THE STATE, and nothing else may decide it:
	#  - No pre-check in front of the mkdir. One used to sit there ("$STATUS says RUNNING and the staged
	#    $WORKER exists → RUNNING") and it wedged the Update button for good: a worker SIGKILLed
	#    mid-`apk add` (OOM on a 128 MB router) leaves both true FOREVER, since only the worker's own
	#    exit clears them, so every later click answered RUNNING, the client polled its 300 s and
	#    reported "timed out waiting for the installer" — until a reboot. It also returned before the
	#    stale-lock reclaim written for exactly that OOM case. It loses nothing: a live run holds the
	#    lock, so mkdir fails and the answer is RUNNING anyway.
	#  - RECLAIM a lock whose worker was OOM-killed from its MTIME, never from $STATUS/$WORKER: those are
	#    written AFTER the mkdir, so a second caller arriving in between sees a held lock with no
	#    evidence behind it, calls it stale and steals it — two installs again (the first attempt; the
	#    router duly spawned two workers). The mtime is set by the atomic mkdir itself, so there is no
	#    window: younger than any plausible run = live (the client gives up after 300 s, an install
	#    takes seconds); older = its worker is gone.
	if ! mkdir "$LOCK" 2>/dev/null; then
		if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
			rmdir "$LOCK" 2>/dev/null
			mkdir "$LOCK" 2>/dev/null || { echo "RUNNING"; exit 0; }
		else
			echo "RUNNING"; exit 0
		fi
	fi
	echo "RUNNING" > "$STATUS"

	# The packages we are about to install overwrite this very script. Run the worker from a copy so
	# the shell keeps reading a file nobody replaces.
	cp "$0" "$WORKER" && chmod 755 "$WORKER" || {
		rmdir "$LOCK" 2>/dev/null
		echo "ERR: cannot stage worker" > "$STATUS"; echo "ERR: cannot stage worker"; exit 1
	}

	# Detach. rpcd reads the exec'd process's stdout until EOF and hands the child more than the three
	# standard descriptors (fd 3 and 9..12 — its own ucode sources), so redirecting 0/1/2 is NOT enough:
	# a grandchild still holding any of them keeps rpcd waiting to its 30 s timeout — the RPC timeout we
	# are here to avoid. start-stop-daemon -b closes everything; where it is missing, close the strays
	# by hand.
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -x "$WORKER" -- __run
	else
		(
			exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 10>&- 11>&- 12>&- 2>/dev/null
			setsid "$WORKER" __run </dev/null >/dev/null 2>&1 &
		) &
	fi
	echo "STARTED"
	exit 0
	;;
*)
	echo "ERR: unknown argument"
	exit 1
	;;
esac
