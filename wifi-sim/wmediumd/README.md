# wmediumd from AOSP, buildable with plain `make`

wmediumd simulates the radio medium for the Linux `mac80211_hwsim` driver.
It decides which simulated radios hear each other, and with what signal and
loss. This kit builds it from Android's copy of the source, which is newer
than the original GitHub project.

## What's in the kit

| File | What it is |
|---|---|
| `UPSTREAM` | The pinned source: `android.googlesource.com/platform/external/wmediumd` at commit `f44d2af28b8045eb31ff045d3c078e60865afa98` (2024-12-19). |
| `patches/0001-plain-c-main-and-pmsr.patch` | Our one patch (see below). |
| `build.sh` | Fetches that exact commit, checks the hash, applies the patches, builds. |

The wmediumd source itself is not included; `build.sh` fetches it.

## Why Android's copy

The original project, github.com/bcopeland/wmediumd, stops at `717e5d7`
(2021-03-01). Android's copy (used by Cuttlefish) carries about three more
years of fixes: frame bit rates, PMSR (peer measurement), gRPC control.

## The patch

Android builds wmediumd only through `Android.bp`. Its entry point,
`main.cc`, is C++ and depends on android-base and a gRPC server. The plain
`Makefile` links no `main()` and leaves out `pmsr.o`, so `make` fails with
undefined references to `main` and `parse_pmsr_request`.

The patch adds `wmediumd/main.c`, a plain C `main()` that does what
`main.cc` does minus the gRPC server: it creates the eventfd and SysV
message queue that `wmediumd_main()` polls. It also adds `main.o` and
`pmsr.o` to the Makefile's objects. Nothing else is changed.

Not built: `main.cc` and `wmediumd_server/` (C++, gRPC), `Android.bp`,
`util/`, `tests/`.

## Building

On Debian or Ubuntu, aarch64 or x86_64:

```
bash build.sh
```

It installs any missing packages (`git make gcc pkg-config libnl-3-dev
libnl-genl-3-dev libconfig-dev`), using sudo unless run as root. It needs
network access to android.googlesource.com. The binary lands in
`out/wmediumd`, with the commit it was built from in `out/COMMIT`.

`WORK=<dir>` changes the scratch directory (default `/var/tmp/wmediumd-build`).

wmediumd's netlink use works unchanged against `mac80211_hwsim` in Linux
7.0.5 (x86_64) and 7.0.14 (aarch64).

## Licences

- wmediumd: GPL-2.0-or-later (`wmediumd.c`, `config.c`, `per.c`, `pmsr.c`,
  `list.h`); BSD-3-Clause (`lib/`, `inc/usfstl`).
- The patch modifies and adds GPL files, so it is GPL-2.0-or-later.
- `build.sh` and this README: Apache-2.0 (the repo's `LICENSE`).

If you distribute a binary built from this kit, the GPL requires you to
offer its corresponding source: the pinned commit plus the patch.
