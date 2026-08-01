#!/bin/sh
# THE LAST THING THIS PACKAGE DOES: hand the theme over to the package manager, then delete itself.
#
# WHY THE PACKAGE IS RETIRED. luci-app-footstrap-updater existed for one reason: a theme installed
# from a downloaded file is one apk/opkg knows no origin for and will never upgrade, so somebody had
# to check GitHub and fetch the next version. The theme's installer adds the owfeed-packages feed
# now, so `apk upgrade` does that job — and it does it for every package on the router, with the
# index signature the feed already carries, instead of a settings page reaching the network.
#
# So this script finishes the migration on routers that have the old updater installed:
#   1. add the feed, if it is not configured (key, repository, keep.d)
#   2. re-install the theme FROM the feed, so the package manager owns it from now on
#   3. remove this package
#
# IT RUNS DETACHED, FROM postinst, AFTER A DELAY, and that is not a style choice: a package cannot
# uninstall itself from inside its own install transaction — apk/opkg holds the database lock, and
# `apk del` would either block forever or corrupt the transaction. The delay plus the lock-wait below
# is what lets the installing process finish and release it first.
#
# EVERY STEP FAILS SOFT. The worst outcome allowed here is "the updater is still installed": it is a
# working package, its removal is housekeeping, and a router left with a stale updater is fine.
# Removing the theme, or leaving the router with neither theme nor feed, is not fine — so step 3
# only runs when step 2 says the theme is in place.
set -u

LOG="logger -t footstrap-retire"
$LOG "starting: hand luci-theme-footstrap to the package feed, then remove this package"

FEED_HOST="https://repo.owfeed.org"
FEED_NAME="owfeed-packages"
THEME="luci-theme-footstrap"
SELF="luci-app-footstrap-updater"

if command -v apk >/dev/null 2>&1; then PM=apk; else PM=opkg; fi

# Wait for the install that spawned us to release the package database. Bounded: if something else
# holds it for two minutes, this is not our emergency — leave the router alone and try again on the
# next upgrade of this package.
i=0
while [ $i -lt 60 ]; do
	if [ "$PM" = apk ]; then
		apk list --installed "$SELF" >/dev/null 2>&1 && break
	else
		opkg status "$SELF" >/dev/null 2>&1 && break
	fi
	i=$((i + 1)); sleep 2
done

# Which release branch the feed serves for this router.
BRANCH=""
[ -f /etc/openwrt_release ] && . /etc/openwrt_release 2>/dev/null
case "${DISTRIB_RELEASE:-}" in
	''|*SNAPSHOT*) : ;;
	*) BRANCH=$(printf '%s' "$DISTRIB_RELEASE" | cut -d. -f1,2) ;;
esac
case "$BRANCH" in
	[0-9][0-9].[0-9][0-9]) : ;;
	*) $LOG "no feed branch for '${DISTRIB_RELEASE:-unknown}' — leaving the updater installed"; exit 0 ;;
esac

fetch() {	# <url> <outfile>
	if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -T 30 -O "$2" "$1"
	elif command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 30 -o "$2" "$1"
	else wget -q -T 30 -O "$2" "$1"; fi
}

add_feed() {
	if [ "$PM" = apk ]; then
		[ -f /etc/apk/keys/owfeed-packages.pem ] && return 0
		arch=$(cat /etc/apk/arch 2>/dev/null) || return 1
		[ -n "$arch" ] || return 1
		apk add --quiet ca-bundle libustream-mbedtls >/dev/null 2>&1
		fetch "$FEED_HOST/owfeed-packages.pem" /tmp/owfeed-packages.pem || return 1
		mkdir -p /etc/apk/keys /etc/apk/repositories.d
		mv /tmp/owfeed-packages.pem /etc/apk/keys/owfeed-packages.pem
		printf '%s/releases/%s/%s/packages.adb\n' "$FEED_HOST" "$BRANCH" "$arch" \
			> /etc/apk/repositories.d/owfeed-packages.list
		# or a firmware upgrade takes the feed away again and the router is back where it started
		mkdir -p /lib/upgrade/keep.d
		printf '%s\n' /etc/apk/keys/owfeed-packages.pem \
			/etc/apk/repositories.d/owfeed-packages.list > /lib/upgrade/keep.d/owfeed-packages
	else
		grep -q "$FEED_NAME" /etc/opkg/customfeeds.conf 2>/dev/null && return 0
		arch="${DISTRIB_ARCH:-}"
		[ -n "$arch" ] || return 1
		opkg update >/dev/null 2>&1
		opkg install ca-bundle libustream-mbedtls >/dev/null 2>&1
		fetch "$FEED_HOST/9040356b214084da" /tmp/9040356b214084da || return 1
		mkdir -p /etc/opkg/keys
		mv /tmp/9040356b214084da /etc/opkg/keys/9040356b214084da
		printf 'src/gz %s %s/releases/%s/%s\n' "$FEED_NAME" "$FEED_HOST" "$BRANCH" "$arch" \
			>> /etc/opkg/customfeeds.conf
		mkdir -p /lib/upgrade/keep.d
		printf '%s\n' /etc/opkg/keys/9040356b214084da /etc/opkg/customfeeds.conf \
			> /lib/upgrade/keep.d/owfeed-packages
	fi
	$LOG "feed added: $FEED_HOST/releases/$BRANCH"
	return 0
}

add_feed || { $LOG "could not add the feed — leaving the updater installed"; exit 0; }

# Re-install the theme FROM the feed. On apk this is what clears the content-hash pin that
# `apk add ./file.apk` wrote into /etc/apk/world — the pin survives sysupgrade and is exactly why a
# file-installed theme never upgrades. `apk fix` re-resolves the world entry against the repository.
if [ "$PM" = apk ]; then
	apk update >/dev/null 2>&1 || { $LOG "apk update failed — leaving the updater installed"; exit 0; }
	apk add --upgrade "$THEME" >/dev/null 2>&1 || apk fix "$THEME" >/dev/null 2>&1
	apk list --installed "$THEME" >/dev/null 2>&1 || { $LOG "$THEME is not installed after the feed step — refusing to remove the updater"; exit 0; }
else
	opkg update >/dev/null 2>&1 || { $LOG "opkg update failed — leaving the updater installed"; exit 0; }
	opkg upgrade "$THEME" >/dev/null 2>&1
	opkg status "$THEME" >/dev/null 2>&1 || { $LOG "$THEME is not installed after the feed step — refusing to remove the updater"; exit 0; }
fi
$LOG "$THEME now comes from the feed"

# …and go. --no-cache/--force-depends is deliberately NOT used: the theme does not depend on this
# package (the dependency points the other way), so a clean removal is possible and a forced one
# would only hide it if that ever changed.
if [ "$PM" = apk ]; then
	apk del "$SELF" >/dev/null 2>&1
else
	opkg remove "$SELF" >/dev/null 2>&1
fi
$LOG "removed $SELF — the theme upgrades with the router from now on"
exit 0
