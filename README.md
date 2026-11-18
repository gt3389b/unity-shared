# unity-shared

Build kits and patches we share with collaborators: small, reproducible
recipes for third-party tools we have had to fix or adapt.

A kit holds what is needed to rebuild a tool, not the tool itself. Third-party
source is pinned and fetched, then checked against a hash or commit, and our
changes sit on top as patches. Nothing here is a binary.

## Kits

| Kit | What it gives you | Runs on |
|---|---|---|
| [`wifi-sim/wmediumd`](wifi-sim/wmediumd) | wmediumd, the `mac80211_hwsim` medium simulator, from Android's newer copy of its source, buildable with plain `make` | Debian or Ubuntu, aarch64 or x86_64 |
| [`wifi-sim/mac80211_hwsim-orbstack`](wifi-sim/mac80211_hwsim-orbstack) | The simulated Wi-Fi radio driver (and GRE, nlmon, PPPoE) for OrbStack's kernel, which lacks them | OrbStack on macOS, aarch64 or x86_64 |

The two go together: hwsim gives a machine simulated radios, and wmediumd
decides which of those radios hear each other.

## Layout

```
<area>/<kit>/
  README.md     what it is, why it exists, how to build, what was verified, licences
  UPSTREAM      the pinned source: URL, commit or hash, date, licence
  patches/      our changes, as numbered git patches (0001-..., 0002-...)
  build.sh      fetches the pin, checks it, applies the patches, builds
```

Each area (`wifi-sim/`, …) groups kits that are used together. Not every kit
has every file: `mac80211_hwsim-orbstack` patches nothing, so it has no
`patches/`, and its pins are tarball hashes in `kernels.sha256`.

Adding or changing a kit: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licences

Our scripts and docs are Apache-2.0 ([`LICENSE`](LICENSE)). A patch to
third-party code takes that code's licence: the wmediumd patch is
GPL-2.0-or-later, for example. Each kit's README says which applies.
Third-party source is never committed, only fetched at build time.
