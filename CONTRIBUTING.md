# Adding or changing a kit

## Where it goes

`<area>/<kit>/`. Use an existing area if the kit is used with the others
there (`wifi-sim/` for simulated Wi-Fi); otherwise start a new one. Name
the kit after the tool, plus the platform if it only works there
(`mac80211_hwsim-orbstack`).

## What a kit must have

- **`README.md`** that says:
  - what the tool is, and why a kit is needed (what upstream lacks);
  - what each patch changes, and why;
  - how to build it, and which platforms and architectures;
  - what was verified, where and on what versions;
  - the licence of each part.
- **A pin** for every third-party source: a full 40-hex commit in
  `UPSTREAM`, or a sha256 for a tarball. Note how the hash was checked
  (for example against a PGP-signed sums file).
- **`build.sh`** that refuses to build if what it fetched doesn't match the
  pin.
- **Patches**, if any, in `patches/` as numbered `git format-patch` files,
  one change each, with a message that says why.

## Rules

- **No third-party source and no binaries in the repo.** Fetch at build
  time and check against the pin. This keeps GPL code out of an Apache-2.0
  repo, and keeps the repo small.
- **Our files are Apache-2.0**, with
  `# SPDX-License-Identifier: Apache-2.0` near the top of each script. A
  patch takes the licence of the code it patches.
- **Builds run on stock Debian or Ubuntu**, where possible on both aarch64
  and x86_64, installing what they need. They use `sudo` only when not root.
- **Nothing project-internal.** No paths, names or references to private
  repos; a kit must make sense on its own.
- **Moving a pin** to a new upstream version: update `UPSTREAM` (or the
  hash file), rebase the patches, rebuild, and update the README's
  "verified" lines.

## CI

`.github/workflows/check.yml` checks every script's syntax, and builds each
kit that can build on a stock GitHub runner (x86_64 and aarch64). Add a
kit's build there if it can run in CI; say in its README if it can't.
`mac80211_hwsim-orbstack` can't: it needs a running OrbStack kernel.
