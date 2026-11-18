# mac80211_hwsim for OrbStack's kernel

`mac80211_hwsim` is Linux's simulated Wi-Fi radio driver. OrbStack's Linux
kernel (on macOS) does not ship it. This kit builds it, and a few other
modules OrbStack lacks, out of tree for the running OrbStack kernel, on
aarch64 (Apple silicon) or x86_64 (Intel Macs).

**The driver source is not patched.** It is built from the unmodified
mainline kernel tarball. What this kit adds is the work of making a module
built from mainline load into OrbStack's kernel, which differs from mainline
in its headers, its config and (on arm64) its CPU-capability numbering. All
of that is in `build.sh`.

If you are on an ordinary Linux distribution, you almost certainly don't
need this kit: most distribution kernels already ship `mac80211_hwsim`.

## What's in the kit

| File | What it does |
|---|---|
| `build.sh` | Builds the modules for the running OrbStack kernel, checks them against it, and loads them as a test. Run as root inside an OrbStack machine. |
| `kernels.sha256` | The sha256 of each mainline tarball `build.sh` may use. It refuses any tarball not listed. |
| `strip_comments.py` | Strips C comments so OrbStack's headers can be compared with mainline's (see below). |
| `load.sh` | Loads the built modules (`load.sh`), or unloads them (`load.sh unload`). |
| `hwsim_radio.py` | Creates and deletes hwsim radios over netlink, in the caller's network namespace. |
| `regdb.sh` | Loads the machine's `regulatory.db` into the kernel, so country codes take effect at once. |

## What `build.sh` does

1. Reads the running kernel's version (`uname -r`, for example
   `7.0.14-orbstack-00380-ga7e0a2dc9535`) and picks the mainline base
   (`7.0.14`).
2. Downloads `linux-<base>.tar.xz` from cdn.kernel.org and checks it against
   `kernels.sha256`. Each hash there was checked against kernel.org's
   PGP-signed `sha256sums.asc` before it was added.
3. Takes OrbStack's headers from `/sys/kernel/kheaders.tar.xz` and copies
   over mainline only the headers that really differ, plus OrbStack's own.
   The kheaders copies have their comments stripped, so they are compared
   with comments stripped on both sides; otherwise every file looks changed.
4. Derives `.config` from OrbStack's `include/generated/autoconf.h`. OrbStack's
   `/proc/config.gz` is trimmed and can't be used. OrbStack-only Kconfig
   symbols get stub entries so they survive `olddefconfig`.
5. On arm64:
   - rebuilds `arch/arm64/tools/cpucaps` in OrbStack's order, since OrbStack
     adds capabilities (`ARM64_HAS_TSO_APPLE`, …) that renumber the rest, and
     module alternatives are patched by number;
   - drops mainline's forced `select VMAP_STACK`, which OrbStack builds
     without.
   On x86_64 it checks the generated CPU feature masks instead.
6. Builds with the same clang major version OrbStack used (installed from
   apt.llvm.org if needed). Another version only with
   `CLANG_FALLBACK_MAJOR=<major>`.
7. Checks that the result matches OrbStack's kernel:
   - `autoconf.h` differs only in the symbols we add;
   - the generated headers are identical;
   - key struct layouts in our modules (`sk_buff`, `net_device`, `wiphy`,
     `ieee80211_hw`, …) match the running kernel's BTF.
   Any mismatch stops the build before anything is loaded.
8. Builds and collects `mac80211_hwsim.ko`, `gre.ko`, `ip_gre.ko`,
   `ip6_gre.ko`, `nlmon.ko`, `pppox.ko` and `pppoe.ko`.
9. Load test: unloads any earlier copies, loads the modules, creates and
   deletes two radios, and creates two GRE tunnels.

## Building and using

Inside an OrbStack machine (Debian or Ubuntu), as root:

```
sudo bash build.sh                 # -> out/<uname -r>/*.ko, config, KERNEL
sudo bash load.sh                  # after each OrbStack restart
sudo python3 -I hwsim_radio.py new --name wlan-sim-0
```

`build.sh` unloads and reloads the modules as its last step. OrbStack
machines share one kernel, so this affects every machine using hwsim at
the time.

When OrbStack updates its kernel to a new mainline base, add that tarball's
hash to `kernels.sha256` (after checking it against kernel.org's signed
sums) and rerun `build.sh`.

### Radios are created at run time

`load.sh` loads hwsim with `radios=0`. An OrbStack machine is a network
namespace of a shared VM kernel, and radios from the module parameter are
created in the VM's initial namespace, where the machine can't see them.
Create them with `hwsim_radio.py new`: radios made that way land in the
caller's namespace.

## Verified

- aarch64: OrbStack kernels 7.0.14 and 7.2.9.
- x86_64: OrbStack kernel 7.0.5.

## Licences

- The kit's scripts and this README: Apache-2.0 (the repo's `LICENSE`).
- The modules it builds are Linux kernel code, GPL-2.0, compiled from the
  unmodified mainline tarball named in `kernels.sha256`.

If you distribute built `.ko` files, the GPL requires you to offer their
corresponding source: that tarball, plus this kit (for OrbStack's headers,
`build.sh` reads them from the running kernel).
