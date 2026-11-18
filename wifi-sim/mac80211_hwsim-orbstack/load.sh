#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Load (or unload) the kit-built modules for the running OrbStack kernel.
# OrbStack mounts /lib/modules/<kver> read-only, so there is no depmod/modprobe
# path for our modules: OrbStack's own dependencies are modprobe'd, ours are
# insmod'ed in order. Run as root.
#
#   load.sh [hwsim-param=value ...]   load everything (hwsim with radios=0)
#   load.sh unload                     unload ours (keeps OrbStack's)
#
# After the modules it loads this machine's regulatory.db into the kernel
# (regdb.sh), so country hints take at once on every architecture.
#
# hwsim is loaded with radios=0 on purpose: an OrbStack machine is a netns of a
# shared VM kernel, and module-parameter radios are created in init_net where
# the machine cannot see them. Create radios in this netns afterwards with
# hwsim_radio.py (HWSIM_CMD_NEW_RADIO lands in the caller's netns).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KVER=$(uname -r)
OUT=$HERE/out/$KVER

if [ "${1:-}" = unload ]; then
  for m in pppoe pppox nlmon ip6_gre ip_gre gre mac80211_hwsim; do rmmod "$m" 2>/dev/null || true; done
  exit 0
fi
[ -d "$OUT" ] || { echo "no modules for $KVER in $OUT — run build.sh first" >&2; exit 1; }

loaded() { grep -q "^$1 " /proc/modules; }

# Wi-Fi simulation
loaded mac80211_hwsim || { modprobe mac80211; insmod "$OUT/mac80211_hwsim.ko" radios=0 "$@"; }
# GRE (OrbStack ships ip_tunnel / ip6_tunnel as modules; gre/ip_gre/ip6_gre are ours)
loaded gre     || { modprobe ip_tunnel;  insmod "$OUT/gre.ko"; }
loaded ip_gre  || insmod "$OUT/ip_gre.ko"
loaded ip6_gre || { modprobe ip6_tunnel; insmod "$OUT/ip6_gre.ko"; }
# netlink monitor, for the netlink oracle captures (absent from builds before 2026-10-21)
[ -f "$OUT/nlmon.ko" ] && { loaded nlmon || insmod "$OUT/nlmon.ko"; }
# PPPoE (OrbStack ships ppp_generic, pppox/pppoe are ours; absent from builds before 2026-10-27)
[ -f "$OUT/pppoe.ko" ] && { loaded ppp_generic || modprobe ppp_generic; loaded pppox || insmod "$OUT/pppox.ko"; loaded pppoe || insmod "$OUT/pppoe.ko"; }
# The machine's regulatory database, into the kernel (regdb.sh: without it a
# country hint stalls every radio bring-up for hostapd's 5 s timeout)
bash "$HERE/regdb.sh"
