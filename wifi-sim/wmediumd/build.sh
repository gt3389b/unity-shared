#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build wmediumd (the mac80211_hwsim medium simulator) from the pinned AOSP
# commit (UPSTREAM) plus the patches in patches/. The source is fetched, not
# shipped: wmediumd is GPL-2.0-or-later, so this kit holds only the pin, the
# patches (GPL-2.0-or-later) and this script (Apache-2.0).
#
# Runs on Debian or Ubuntu, aarch64 or x86_64 (uname -m; nothing is
# architecture-specific). Needs network access to android.googlesource.com.
#
#   bash build.sh            -> out/wmediumd
#
# Packages it installs if missing: git make gcc pkg-config libnl-3-dev
# libnl-genl-3-dev libconfig-dev (with sudo unless run as root).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
URL=$(sed -n 's/^url: *//p' "$HERE/UPSTREAM")
COMMIT=$(sed -n 's/^commit: *//p' "$HERE/UPSTREAM")
WORK=${WORK:-/var/tmp/wmediumd-build}
SRC=$WORK/src
OUT=$HERE/out
[ ${#COMMIT} -eq 40 ] || { echo "FAIL: UPSTREAM must pin a full 40-hex commit"; exit 2; }

echo "== deps"
pkgs="git make gcc pkg-config libnl-3-dev libnl-genl-3-dev libconfig-dev"
missing=$(for p in $pkgs; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
if [ -n "$missing" ]; then $SUDO apt-get update -qq >/dev/null; $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null; fi

echo "== fetch $URL @ $COMMIT"
rm -rf "$SRC"; mkdir -p "$WORK"
git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$URL" "$COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
got=$(git -C "$SRC" rev-parse HEAD)
[ "$got" = "$COMMIT" ] || { echo "FAIL: fetched $got, pinned $COMMIT"; exit 3; }

echo "== patches"
for p in "$HERE"/patches/*.patch; do
  git -C "$SRC" apply --whitespace=nowarn "$p"
  echo "   applied $(basename "$p")"
done

echo "== build"
make -s -C "$SRC/wmediumd" -j"$(nproc)" 2>&1 | grep -E 'error' || true
mkdir -p "$OUT"
install -m 0755 "$SRC/wmediumd/wmediumd" "$OUT/wmediumd"
echo "$COMMIT" > "$OUT/COMMIT"
"$OUT/wmediumd" -V
echo "== DONE: $OUT/wmediumd"
