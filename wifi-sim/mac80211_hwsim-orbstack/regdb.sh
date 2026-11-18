#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Load this machine's regulatory database (wireless-regdb's
# /lib/firmware/regulatory.db) into the running OrbStack kernel. Run as root.
#
#   regdb.sh           load it, verify a country hint takes, restore the global country
#   regdb.sh --check   report only (no change)
#
# Why: cfg80211 reads regulatory.db through the firmware loader, which
# resolves paths in the VM's root filesystem, not the machine's. Where the
# VM root has no database (the x86_64 OrbStack kernel, cfg80211 builtin),
# every country hint — hostapd's country_code included — is sent
# to a userspace CRDA that does not exist and dropped after cfg80211's
# 3.142 s timeout. hostapd waits for that hint's channel-list update and,
# never seeing it, gives up after its own fixed 5 s (src/ap/hostapd.c,
# channel_list_update_timeout): every radio bring-up, and so every Wi-Fi
# restart, costs 5 s.
#
# How: the VM sees each machine's filesystem at /data/<root subvolume>
# (verified 2026-10-20 by pointing the loader at a corrupt file: the reload
# failed with ENODATA only through that path). The loader's extra search
# path (firmware_class.path) is pointed at this machine's /lib/firmware,
# `iw reg reload` reads and signature-checks the database, and the path is
# cleared again: the database stays in kernel memory until the VM reboots,
# the same lifetime as the hwsim modules, so this runs with load.sh.
set -euo pipefail

PARAM=/sys/module/firmware_class/parameters/path
DB=/lib/firmware/regulatory.db
SUBVOL=$(awk '$5 == "/" { print $4; exit }' /proc/self/mountinfo)
VMPATH="/data${SUBVOL}/lib/firmware"
global() { iw reg get 2>/dev/null | awk '/^global/ { g = 1; next } g && /^country/ { sub(":", "", $2); print $2; exit }'; }

if [ "${1:-}" = --check ]; then
  echo "regulatory.db: machine copy $([ -f "$DB" ] && echo present || echo MISSING) ($DB, wireless-regdb $(dpkg-query -W -f='${Version}' wireless-regdb 2>/dev/null || echo '?'))"
  echo "regulatory.db: VM path $VMPATH; global country now $(global)"
  echo "regulatory.db: loaded into the kernel by \`cargo xtask setup\` / load.sh once per VM boot (verified there: a hint must take within 1 s)"
  exit 0
fi

[ -f "$DB" ] || { echo "regdb: $DB missing — install wireless-regdb (cargo xtask setup)" >&2; exit 1; }
[ -w "$PARAM" ] || { echo "regdb: $PARAM not writable (run as root)" >&2; exit 1; }
command -v iw >/dev/null || { echo "regdb: iw missing (cargo xtask setup)" >&2; exit 1; }

before=$(global)
printf '%s' "$VMPATH" > "$PARAM"
status=0
out=$(iw reg reload 2>&1) || status=$?
printf '\n' > "$PARAM"   # an empty write is ignored; a newline clears it
if [ $status -ne 0 ]; then
  echo "regdb: reload through $VMPATH failed: $out" >&2
  exit 1
fi

# verify: a hint for a country other than the current one takes at once only
# with a database in the kernel (without one it would sit for 3.142 s, then revert)
probe=DE; [ "$before" = DE ] && probe=GB
iw reg set "$probe"
took=no
for _ in $(seq 1 20); do
  [ "$(global)" = "$probe" ] && { took=yes; break; }
  sleep 0.05
done
[ -n "$before" ] && iw reg set "$before" 2>/dev/null || true
if [ $took != yes ]; then
  echo "regdb: reloaded, but a $probe hint did not take within 1 s (global $(global)) — the kernel has no usable database" >&2
  exit 1
fi
echo "regdb: loaded $DB into the kernel (wireless-regdb $(dpkg-query -W -f='${Version}' wireless-regdb 2>/dev/null || echo '?')); a $probe hint took; global country back to ${before:-unchanged}"
