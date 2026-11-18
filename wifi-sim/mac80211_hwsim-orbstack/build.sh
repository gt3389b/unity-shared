#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the kernel modules OrbStack's kernel lacks (mac80211_hwsim, gre,
# ip_gre, ip6_gre, pppox, pppoe) out-of-tree against the matching mainline source plus
# OrbStack's header changes. See README.md.
#
# Why it is done this way (learned the hard way):
#  * /sys/kernel/kheaders.tar.xz is produced by gen_kheaders.sh, which strips
#    comments, so overlaying it wholesale trips the atomic-header SHA guard and
#    makes every file look modified. We overlay only headers whose
#    comment-stripped content differs from mainline, plus OrbStack-only files.
#  * /proc/config.gz on OrbStack is a trimmed config (no CONFIG_64BIT, no
#    CFG80211/MAC80211 even though those modules ship). The build's real
#    config is include/generated/autoconf.h in kheaders; .config is derived
#    from it and the regenerated autoconf.h is checked against it afterwards.
#  * OrbStack adds arm64 cpucaps (ARM64_HAS_TSO_APPLE/_FIXED), renumbering the
#    ones after them. Module alternatives are patched by cap NUMBER at load, so
#    arch/arm64/tools/cpucaps is reconstructed from OrbStack's generated
#    cpucap-defs.h and the regenerated file is checked for exact equality.
#  * OrbStack-only Kconfig symbols (ARM64_ACTLR_STATE adds a thread_struct
#    field, PARAVIRT_SPINLOCKS, ...) get stub Kconfig entries so olddefconfig
#    keeps them and the #ifdefs in their headers evaluate as in their build.
#  * They build with clang 22; we install the same major from apt.llvm.org so
#    the CC_HAS_* feature-detection symbols match. Another major only with
#    CLANG_FALLBACK_MAJOR=<major> (else exit 7), recorded in KERNEL.
#  * Both OrbStack architectures are supported (uname -m picks ARCH). The
#    cpucaps and VMAP_STACK fixes are arm64-only. On x86_64 cfg80211/mac80211
#    and the tunnel cores are builtin, so their types live in vmlinux BTF and
#    the generated cpufeaturemasks.h is checked instead of cpucap-defs.h.
#
# Run inside the OrbStack machine as root:  sudo bash tools/orbstack-modules/build.sh
# Output: tools/orbstack-modules/out/<uname -r>/{*.ko,config,KERNEL,orbstack-*-headers.txt}
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KVER=$(uname -r)                                   # 7.0.14-orbstack-00380-ga7e0a2dc9535
BASE=${KVER%%-*}                                   # 7.0.14
LOCALVER=${KVER#"$BASE"}                           # -orbstack-00380-ga7e0a2dc9535
MAJOR=${BASE%%.*}
case $(uname -m) in
  aarch64) KARCH=arm64 ;;
  x86_64)  KARCH=x86 ;;
  *) echo "FAIL: unsupported machine $(uname -m)"; exit 7 ;;
esac
WORK=${WORK:-/var/tmp/orbstack-kmod/$KVER}
SRC=$WORK/src
OUT=$HERE/out/$KVER
JOBS=${JOBS:-$(nproc)}
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${BASE}.tar.xz"
SUMS_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/sha256sums.asc"   # reference only; hashes are pinned in kernels.sha256
# Options we add on top of OrbStack's config.
WANT_MODULES="MAC80211_HWSIM NET_IPGRE_DEMUX NET_IPGRE IPV6_GRE NLMON PPPOE"
WANT_BOOLS="NET_IPGRE_BROADCAST"
# Config symbols allowed to differ from OrbStack's autoconf.h: our additions,
# version strings, toolchain feature detection and Rust-for-Linux probes.
# None of these change C struct layout or the module ABI.
ALLOW_DIFF='CONFIG_(MAC80211_HWSIM|NLMON|PPPOE|PPPOX|NET_IPGRE|NET_IPGRE_DEMUX|NET_IPGRE_BROADCAST|IPV6_GRE|OPENVSWITCH_GRE|LOCALVERSION|LOCALVERSION_AUTO|CC_VERSION_TEXT|CLANG_VERSION|AS_VERSION|LD_VERSION|LLD_VERSION|PAHOLE_VERSION|GCC_VERSION|CC_IS_[A-Z]+|LD_IS_[A-Z]+|AS_IS_[A-Z]+|CC_HAS_[A-Z0-9_]+|CC_CAN_[A-Z0-9_]+|LD_CAN_[A-Z0-9_]+|HAVE_CFI_[A-Z0-9_]+|OPENSSL_[A-Z0-9_]+|ARCH_SUPPORTS_PGO_CLANG|WARN_CONTEXT_ANALYSIS|RUST[A-Z0-9_]*|BINDGEN_[A-Z0-9_]+|TOOLS_SUPPORT_RELR|AS_HAS_[A-Z0-9_]+)'
# OrbStack-only symbols for which we must not invent stubs (toolchain probes).
NO_STUB='CONFIG_(CC_|LD_|AS_|HAVE_CFI_|OPENSSL_|RUSTC_|RUST_|BINDGEN_|ARCH_SUPPORTS_PGO|WARN_CONTEXT|PAHOLE|CLANG_|LLD_|GCC_|LOCALVERSION)'

mkdir -p "$WORK" "$OUT"
exec > >(tee -a "$WORK/build.log") 2>&1
echo "== $(date -u +%FT%TZ) building for $KVER (base $BASE, localversion '$LOCALVER', ARCH=$KARCH)"
step() { echo; echo "== $*"; }

step "deps"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq make flex bison bc libelf-dev libssl-dev xz-utils curl pahole python3 kmod ca-certificates gnupg iw iproute2 >/dev/null
# Prefer the clang major OrbStack built with (from kheaders autoconf.h, read
# below); install from apt.llvm.org if the distro does not have it.
mkdir -p "$WORK/ovl"; rm -rf "$WORK/ovl"/*
modprobe kheaders 2>/dev/null || true
test -f /sys/kernel/kheaders.tar.xz
tar -xJf /sys/kernel/kheaders.tar.xz -C "$WORK/ovl"
ORB_AUTOCONF=$WORK/orbstack-autoconf.h
cp "$WORK/ovl/include/generated/autoconf.h" "$ORB_AUTOCONF"
ORB_CLANG=$(sed -n 's/^#define CONFIG_CLANG_VERSION \([0-9]*\)$/\1/p' "$ORB_AUTOCONF"); ORB_CLANG=${ORB_CLANG:0:2}
echo "OrbStack kernel was built with clang major $ORB_CLANG"
if ! command -v "clang-$ORB_CLANG" >/dev/null; then
  . /etc/os-release
  if ! apt-get install -y -qq "clang-$ORB_CLANG" "lld-$ORB_CLANG" "llvm-$ORB_CLANG" >/dev/null 2>&1; then
    echo "distro has no clang-$ORB_CLANG; adding apt.llvm.org"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /etc/apt/keyrings/apt.llvm.org.gpg
    echo "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.gpg] http://apt.llvm.org/$VERSION_CODENAME/ llvm-toolchain-$VERSION_CODENAME-$ORB_CLANG main" > /etc/apt/sources.list.d/llvm-$ORB_CLANG.list
    apt-get update -qq >/dev/null
    apt-get install -y -qq "clang-$ORB_CLANG" "lld-$ORB_CLANG" "llvm-$ORB_CLANG" >/dev/null || true
  fi
fi
# A different major changes the CC_HAS_* feature symbols, so a fallback is
# never silent: it needs CLANG_FALLBACK_MAJOR=<major>, and KERNEL records it
CLANG_FALLBACK=
if command -v "clang-$ORB_CLANG" >/dev/null; then LLVM_SUFFIX="-$ORB_CLANG"; else
  if [ -z "${CLANG_FALLBACK_MAJOR:-}" ]; then
    echo "FAIL: clang-$ORB_CLANG (the OrbStack kernel's major) could not be installed;"
    echo "      set CLANG_FALLBACK_MAJOR=<major> to build with another (CC_HAS_* symbols may differ)"
    exit 7
  fi
  LLVM_SUFFIX="-$CLANG_FALLBACK_MAJOR"; apt-get install -y -qq "clang$LLVM_SUFFIX" "lld$LLVM_SUFFIX" "llvm$LLVM_SUFFIX" >/dev/null
  CLANG_FALLBACK="$ORB_CLANG->$CLANG_FALLBACK_MAJOR"
  echo "WARNING: using clang$LLVM_SUFFIX, not OrbStack's clang-$ORB_CLANG (CLANG_FALLBACK_MAJOR); CC_HAS_* symbols may differ"
fi
CLANG_USED=$("clang$LLVM_SUFFIX" --version | head -1)
echo "$CLANG_USED"

step "fetch $TARBALL_URL"
cd "$WORK"
[ -f "linux-$BASE.tar.xz" ] || curl -fsSLo "linux-$BASE.tar.xz" "$TARBALL_URL"
# Verify against the hash pinned in the repo, not one fetched alongside the
# tarball (that would only catch corruption, not substitution).
grep -E "^[0-9a-f]{64}  linux-$BASE.tar.xz\$" "$HERE/kernels.sha256" > "$WORK/pinned.sha256" \
  || { echo "FAIL: linux-$BASE.tar.xz is not pinned in tools/orbstack-modules/kernels.sha256"; echo "      verify it against $SUMS_URL (and its PGP signature) and add a line"; exit 6; }
sha256sum -c "$WORK/pinned.sha256"

step "extract pristine source"
rm -rf "$SRC" norm-ovl norm-src; mkdir -p "$SRC"
tar -xJf "linux-$BASE.tar.xz" -C "$SRC" --strip-components=1
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)' "$SRC/Makefile" | tr '\n' ' '; echo

step "find OrbStack's substantive header differences"
test -f ovl/include/linux/orbvm.h            # proves this really is OrbStack's tree
( cd ovl && find . -type f | sed 's|^\./||' | grep -v "^include/generated/\|^include/config/\|^arch/$KARCH/include/generated/" | sort ) > overlay.lst
echo "overlay headers considered: $(wc -l < overlay.lst)"
mkdir -p norm-ovl norm-src
while read -r f; do
  mkdir -p "norm-ovl/$(dirname "$f")"; cp "ovl/$f" "norm-ovl/$f"
  if [ -e "$SRC/$f" ]; then mkdir -p "norm-src/$(dirname "$f")"; cp "$SRC/$f" "norm-src/$f"; fi
done < overlay.lst
find norm-ovl norm-src -type f -print0 | xargs -0 -P "$JOBS" -n 200 python3 -I "$HERE/strip_comments.py"
ADDED=$WORK/orbstack-added-headers.txt; MODIFIED=$WORK/orbstack-modified-headers.txt
: > "$ADDED"; : > "$MODIFIED"
while read -r f; do
  if [ ! -e "$SRC/$f" ]; then echo "$f" >> "$ADDED"
  elif ! cmp -s "norm-src/$f" "norm-ovl/$f"; then echo "$f" >> "$MODIFIED"; fi
done < overlay.lst
echo "-- OrbStack-added headers ($(wc -l < "$ADDED")):"; sed 's/^/   /' "$ADDED"
echo "-- OrbStack-modified headers ($(wc -l < "$MODIFIED")):"; sed 's/^/   /' "$MODIFIED"
echo "-- unified diff of modified headers (normalized), first 300 lines:"
while read -r f; do diff -u "norm-src/$f" "norm-ovl/$f" || true; done < "$MODIFIED" | head -300
cat "$ADDED" "$MODIFIED" | while read -r f; do mkdir -p "$SRC/$(dirname "$f")"; cp "ovl/$f" "$SRC/$f"; done
cp "$ADDED" "$MODIFIED" "$OUT/"

step "mirror OrbStack's Kconfig changes we can infer from autoconf.h"
# Mainline arm64 unconditionally `select`s VMAP_STACK; OrbStack's kernel runs
# without it (no task_struct.stack_vm_area in its BTF). Drop the select so the
# option can be off, matching their task_struct layout.
if [ "$KARCH" = arm64 ] && ! grep -q '^#define CONFIG_VMAP_STACK ' "$ORB_AUTOCONF"; then
  TAB=$'\t'
  if grep -q "^${TAB}select VMAP_STACK\$" "$SRC/arch/arm64/Kconfig"; then
    sed -i "/^${TAB}select VMAP_STACK\$/d" "$SRC/arch/arm64/Kconfig"
    echo "arch/arm64/Kconfig: removed 'select VMAP_STACK' (OrbStack builds without it)"
  else
    echo "WARNING: expected 'select VMAP_STACK' in arch/arm64/Kconfig, not found"
  fi
fi

cd "$SRC"
if [ "$KARCH" = arm64 ]; then
step "reconstruct arch/arm64/tools/cpucaps from OrbStack's numbering"
ORB_CAPS=$WORK/ovl/arch/arm64/include/generated/asm/cpucap-defs.h
test -f "$ORB_CAPS"
# gen-cpucaps.awk prepends ARM64_ itself, so the file holds bare names.
{ echo "# Reconstructed from OrbStack's cpucap-defs.h; order == cap number."
  grep -E '^#define ARM64_' "$ORB_CAPS" | grep -v ARM64_NCAPS | sort -k3,3n | awk '{sub(/^ARM64_/, "", $2); print $2}'; } > arch/arm64/tools/cpucaps
echo "caps: $(grep -cv '^#' arch/arm64/tools/cpucaps) (mainline had $(tar -xJOf "$WORK/linux-$BASE.tar.xz" "linux-$BASE/arch/arm64/tools/cpucaps" | grep -cvE '^#|^$'))"
grep -nE 'TSO' arch/arm64/tools/cpucaps
fi

step "config: derive .config from OrbStack's autoconf.h"
sed -nE \
  -e 's/^#define (CONFIG_[A-Za-z0-9_]+)_MODULE 1$/\1=m/p' -e 't' \
  -e 's/^#define (CONFIG_[A-Za-z0-9_]+) 1$/\1=y/p' -e 't' \
  -e 's/^#define (CONFIG_[A-Za-z0-9_]+) (.*)$/\1=\2/p' \
  "$ORB_AUTOCONF" | sort > "$WORK/derived.cfg"
echo "derived entries: $(wc -l < "$WORK/derived.cfg")"
# autoconf.h lists only SET options. Start from allnoconfig so that every
# symbol OrbStack left off is explicitly off (olddefconfig from a sparse
# .config would otherwise switch on hundreds of default-y options).
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH KCONFIG_ALLCONFIG="$WORK/derived.cfg" allnoconfig >/dev/null
scripts/config --set-str LOCALVERSION "$LOCALVER" --disable LOCALVERSION_AUTO --disable RUST
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH olddefconfig >/dev/null
# Pass 2: symbols olddefconfig dropped. '=y' derived from a literal 1 may
# really be an int option with value 1 -> retry as int. Remaining bool
# symbols unknown to mainline Kconfig are OrbStack-only -> stub them.
comm -23 "$WORK/derived.cfg" <(grep -E '^CONFIG_' .config | sort) | grep -vE "^$NO_STUB" > "$WORK/dropped.cfg" || true
if [ -s "$WORK/dropped.cfg" ]; then
  echo "-- dropped by olddefconfig (retrying ints, stubbing OrbStack-only bools):"; sed 's/^/   /' "$WORK/dropped.cfg"
  grep -E '=y$' "$WORK/dropped.cfg" | sed 's/=y$//' | while read -r sym; do scripts/config --set-val "${sym#CONFIG_}" 1; done
  make LLVM="$LLVM_SUFFIX" ARCH=$KARCH olddefconfig >/dev/null
  comm -23 "$WORK/derived.cfg" <(grep -E '^CONFIG_' .config | sort) | grep -vE "^$NO_STUB" > "$WORK/dropped2.raw" || true
  # Stub only symbols mainline Kconfig does not define at all; a symbol that
  # exists but was recomputed (non-visible int/bool) is left to the final
  # autoconf.h comparison to judge.
  # "Defined" means defined for THIS arch: other arch/ trees (x86's
  # PARAVIRT_SPINLOCKS, ...) do not count.
  find . -path ./arch -prune -o -name 'Kconfig*' -type f -print > "$WORK/kconfig.lst"
  find "arch/$KARCH" -name 'Kconfig*' -type f >> "$WORK/kconfig.lst"; echo arch/Kconfig >> "$WORK/kconfig.lst"
  : > "$WORK/dropped2.cfg"
  while IFS='=' read -r sym val; do
    xargs -a "$WORK/kconfig.lst" grep -qsE "^(menu)?config ${sym#CONFIG_}\$" || echo "$sym=$val" >> "$WORK/dropped2.cfg"
  done < "$WORK/dropped2.raw"
  if [ -s "$WORK/dropped2.cfg" ]; then
    { echo "# OrbStack-only Kconfig symbols, stubbed so olddefconfig keeps them (see tools/orbstack-modules/build.sh)";
      while IFS='=' read -r sym val; do
        case "$val" in
          y|m) printf 'config %s\n\tbool\n\tdefault y\n\n' "${sym#CONFIG_}" ;;
          \"*) printf 'config %s\n\tstring\n\tdefault %s\n\n' "${sym#CONFIG_}" "$val" ;;
          *)   printf 'config %s\n\tint\n\tdefault %s\n\n' "${sym#CONFIG_}" "$val" ;;
        esac
      done < "$WORK/dropped2.cfg"; } > Kconfig.orbstack
    echo 'source "Kconfig.orbstack"' >> Kconfig
    echo "-- stubbed:"; grep '^config' Kconfig.orbstack | sed 's/^/   /'
    while IFS='=' read -r sym val; do case "$val" in y|m) scripts/config --enable "${sym#CONFIG_}";; \"*) scripts/config --set-str "${sym#CONFIG_}" "${val//\"/}";; *) scripts/config --set-val "${sym#CONFIG_}" "$val";; esac; done < "$WORK/dropped2.cfg"
    make LLVM="$LLVM_SUFFIX" ARCH=$KARCH olddefconfig >/dev/null
  fi
fi
scripts/config --set-str LOCALVERSION "$LOCALVER" --disable LOCALVERSION_AUTO --disable RUST
for k in $WANT_MODULES; do scripts/config --module "$k"; done
for k in $WANT_BOOLS;   do scripts/config --enable "$k"; done
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH olddefconfig >/dev/null
for k in $WANT_MODULES $WANT_BOOLS MODVERSIONS MODULE_SIG LOCALVERSION MAC80211 CFG80211 WLAN DEBUG_INFO_BTF ARM64_ACTLR_STATE PARAVIRT_SPINLOCKS RUST CLANG_VERSION; do
  grep -E "^(# )?CONFIG_$k[ =]" .config || echo "CONFIG_$k: (absent)"
done

step "modules_prepare"
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH -j"$JOBS" modules_prepare 2>&1 | grep -E 'error|Error|warning: .*(incompatible|redefin)' || true
test -f include/generated/utsrelease.h
UTS=$(sed -n 's/.*"\(.*\)".*/\1/p' include/generated/utsrelease.h)
echo "utsrelease: $UTS"
[ "$UTS" = "$KVER" ] || { echo "FAIL: utsrelease '$UTS' != running '$KVER'"; exit 2; }

step "generated-header checks against OrbStack's"
# kheaders' generated files are comment-stripped: compare #define lines only.
defs() { grep -E '^#define' "$1" | tr -s ' \t' ' '; }
if [ "$KARCH" = arm64 ]; then
  if diff -u <(defs "$ORB_CAPS") <(defs arch/arm64/include/generated/asm/cpucap-defs.h); then echo "cpucap-defs.h: identical"; else echo "FAIL: cpucap numbering differs"; exit 5; fi
  G=$WORK/ovl/arch/arm64/include/generated/asm/sysreg-defs.h
  if diff -q <(defs "$G") <(defs arch/arm64/include/generated/asm/sysreg-defs.h) >/dev/null; then echo "sysreg-defs.h: identical"; else
    echo "sysreg-defs.h differs ($(diff "$G" arch/arm64/include/generated/asm/sysreg-defs.h | grep -c '^[<>]') lines); using OrbStack's"; cp "$G" arch/arm64/include/generated/asm/sysreg-defs.h; fi
else
  # x86 feature masks (REQUIRED/DISABLED_MASK*) decide which alternatives a
  # module compiles in; they are generated from .config + cpufeatures.h.
  # The awk generator's block order is not stable across builds: compare sorted.
  G=$WORK/ovl/arch/x86/include/generated/asm/cpufeaturemasks.h
  if [ -f "$G" ]; then
    if diff -u <(defs "$G" | sort) <(defs arch/x86/include/generated/asm/cpufeaturemasks.h | sort); then echo "cpufeaturemasks.h: identical"; else echo "FAIL: x86 feature masks differ"; exit 5; fi
  else echo "WARNING: OrbStack ships no cpufeaturemasks.h; feature masks unchecked"; fi
fi
# (not a pipeline in an `if`: with pipefail, diff's exit 1 would mask grep's result)
diff -u <(sort "$ORB_AUTOCONF") <(sort include/generated/autoconf.h) | grep -E '^[-+]#define' > "$WORK/autoconf.diff" || true
grep -vE "^[-+]#define $ALLOW_DIFF[ _]" "$WORK/autoconf.diff" > "$WORK/autoconf.bad" || true
echo "-- autoconf.h: allowed differences ($(grep -cE "^[-+]#define $ALLOW_DIFF[ _]" "$WORK/autoconf.diff" || true)):"
grep -E "^[-+]#define $ALLOW_DIFF[ _]" "$WORK/autoconf.diff" | sed 's/^/   /' || true
echo "-- autoconf.h: differences beyond the allowed set ($(wc -l < "$WORK/autoconf.bad")):"
if [ -s "$WORK/autoconf.bad" ]; then sed 's/^/   /' "$WORK/autoconf.bad"; echo "FAIL: autoconf.h differs beyond the intended additions"; exit 4; fi
echo "   (none)"

step "build modules"
# No Module.symvers for the running kernel: in-tree symbols show as undefined
# to modpost; MODVERSIONS is off so that is harmless. Make it a warning.
export KBUILD_MODPOST_WARN=1
for m in drivers/net/wireless/virtual net/ipv4 net/ipv6; do
  make LLVM="$LLVM_SUFFIX" ARCH=$KARCH -j"$JOBS" M=$m modules 2>&1 | grep -vE 'WARNING: modpost|undefined!|^\s*$' || true
done
# nlmon (netlink monitor, for netlink-level captures):
# one file, built out of tree so the rest of drivers/net is not compiled
rm -rf "$WORK/nlmon" && mkdir -p "$WORK/nlmon"
cp drivers/net/nlmon.c "$WORK/nlmon/" && echo 'obj-m := nlmon.o' > "$WORK/nlmon/Makefile"
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH -j"$JOBS" M="$WORK/nlmon" modules 2>&1 | grep -vE 'WARNING: modpost|undefined!|^\s*$' || true

# PPPoE (for PPPoE WAN sessions): OrbStack ships ppp_generic but
# not PPPoX/PPPoE; built from drivers/net/ppp, only those two collected
make LLVM="$LLVM_SUFFIX" ARCH=$KARCH -j"$JOBS" M=drivers/net/ppp modules 2>&1 | grep -vE 'WARNING: modpost|undefined!|^\s*$' || true

step "collect"
cp -v drivers/net/wireless/virtual/mac80211_hwsim.ko net/ipv4/gre.ko net/ipv4/ip_gre.ko net/ipv6/ip6_gre.ko "$WORK/nlmon/nlmon.ko" drivers/net/ppp/pppox.ko drivers/net/ppp/pppoe.ko "$OUT/"
for ko in "$OUT"/*.ko; do printf '%-22s ' "$(basename "$ko")"; modinfo -F vermagic "$ko"; done
cp .config "$OUT/config"; cp Kconfig.orbstack "$OUT/" 2>/dev/null || true
# what these modules were built for and with
ORB_VERSION=$(mac orb version 2>/dev/null | sed -n 's/^Version: //p' | head -1)
{
  echo "kernel=$KVER"
  echo "arch=$(uname -m)"
  echo "orbstack=${ORB_VERSION:-unknown}"
  echo "clang=$CLANG_USED"
  [ -z "$CLANG_FALLBACK" ] || echo "clang_fallback=$CLANG_FALLBACK"
} > "$OUT/KERNEL"

step "layout check: our .ko (DWARF -> BTF) vs BTF of the running kernel"
# Both sides are printed from BTF by the same pahole so the text is
# comparable; printing DWARF directly renders anonymous unions and aligned
# attributes differently and produces false diffs.
modprobe mac80211 || true
pahole -J --btf_encode_detached="$WORK/hwsim.btf" "$OUT/mac80211_hwsim.ko"
pahole -J --btf_encode_detached="$WORK/ipgre.btf" "$OUT/ip_gre.ko"
fail=0
check() { # check <struct> <our .btf> <running btf> [btf_base]
  local s=$1 ours=$2 btf=$3 base=${4:-} a b
  a=$(pahole -F btf -C "$s" "$ours" 2>/dev/null | sed -n '/^struct/,/^};/p') || true
  if [ -n "$base" ]; then b=$(pahole -F btf --btf_base "$base" -C "$s" "$btf" 2>/dev/null | sed -n '/^struct/,/^};/p'); else b=$(pahole -F btf -C "$s" "$btf" 2>/dev/null | sed -n '/^struct/,/^};/p'); fi
  if [ -z "$a" ] || [ -z "$b" ]; then echo "  SKIP $s (not in our BTF or not in running BTF)"; return; fi
  if diff <(echo "$a") <(echo "$b") >/dev/null; then echo "  OK   $s ($(echo "$b" | grep -oE 'size: [0-9]+' | head -1))"
  else echo "  DIFF $s"; diff <(echo "$a") <(echo "$b") | head -40; fail=1; fi
}
V=/sys/kernel/btf/vmlinux
for s in sk_buff net_device wiphy cfg80211_ops ieee80211_hw ieee80211_ops ieee80211_vif ieee80211_sta ieee80211_tx_info ieee80211_rx_status genl_family genl_ops; do
  # mac80211 is a module on arm64 (split BTF on top of vmlinux), builtin on x86.
  if [ -f /sys/kernel/btf/mac80211 ]; then check "$s" "$WORK/hwsim.btf" /sys/kernel/btf/mac80211 "$V"
  else check "$s" "$WORK/hwsim.btf" "$V"; fi
done
for s in sk_buff net_device ip_tunnel ip_tunnel_parm_kern ip_tunnel_encap ip_tunnel_net rtnl_link_ops net task_struct thread_info; do
  check "$s" "$WORK/ipgre.btf" "$V"
done
[ $fail = 0 ] || { echo "FAIL: struct layout differs; not safe to load"; exit 3; }

step "load test (via load.sh: OrbStack's /lib/modules is read-only, so no depmod)"
bash "$HERE/load.sh" unload || true
bash "$HERE/load.sh"
R1=$(python3 -I "$HERE/hwsim_radio.py" new --name hwsim-test-0); R2=$(python3 -I "$HERE/hwsim_radio.py" new --name hwsim-test-1)
sleep 1
iw dev | grep -E 'phy|Interface' | tr -s '\t ' ' ' | paste - - -
python3 -I "$HERE/hwsim_radio.py" del "$R1"; python3 -I "$HERE/hwsim_radio.py" del "$R2"
lsmod | grep -E '^(mac80211_hwsim|gre|ip_gre|ip6_gre|ip_tunnel|ip6_tunnel|mac80211|cfg80211) ' | awk '{print $1}' | tr '\n' ' '; echo
ip link add kit-gre-test type gretap remote 10.255.255.1 local 10.255.255.2 && ip link del kit-gre-test && echo "gretap: OK"
ip link add kit-gre6-test type ip6gretap remote fd00::1 local fd00::2 && ip link del kit-gre6-test && echo "ip6gretap: OK"
dmesg | tail -n 15
echo; echo "== DONE: modules in $OUT"
