<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Core Devices LLC
-->

# PebbleOS SDK

Self-contained firmware SDK for PebbleOS. Bundles the toolchains you need to
build, run, and flash PebbleOS targets:

| Component         | Purpose                                  | Source                                                                 |
| ----------------- | ---------------------------------------- | ---------------------------------------------------------------------- |
| ARM GNU Toolchain | `arm-none-eabi-*` cross compiler         | https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads      |
| Pebble QEMU       | Emulator for PebbleOS targets            | https://github.com/coredevices/qemu/releases                           |
| sftool            | SiFli flashing utility                   | https://github.com/OpenSiFli/sftool/releases                           |

Supported hosts: Linux (x86_64, aarch64) and macOS (x86_64, aarch64).

## Install

One-liner (downloads the bundle for your platform from the latest release):

```sh
curl -LsSf https://github.com/coredevices/PebbleOS-SDK/releases/latest/download/pebbleos-sdk-installer.sh | sh
```

Non-interactive install:

```sh
curl -LsSf https://github.com/coredevices/PebbleOS-SDK/releases/latest/download/pebbleos-sdk-installer.sh \
  | sh -s -- --defaults
```

Pin a specific version or change the install path:

```sh
curl -LsSf https://github.com/coredevices/PebbleOS-SDK/releases/latest/download/pebbleos-sdk-installer.sh \
  | sh -s -- --version 0.1.0 --prefix /opt/pebbleos-sdk --defaults
```

By default the SDK installs at `~/pebbleos-sdk-<version>`.

After install, activate the SDK in your shell:

```sh
. ~/pebbleos-sdk-<version>/env.sh
arm-none-eabi-gcc --version
```

### Offline / pre-downloaded bundle

Each release also publishes a self-contained tarball per platform:

```sh
tar -xzf pebbleos-sdk-<version>-<os>-<arch>.tar.gz
cd pebbleos-sdk-<version>-<os>-<arch>
./install.sh --defaults                      # default prefix
./install.sh --prefix /opt/pebbleos-sdk      # custom prefix
./install.sh --force                         # overwrite existing
```

## Layout after install

```
~/pebbleos-sdk-<version>/
├── arm-none-eabi/   # ARM GNU Toolchain
├── qemu/            # Pebble QEMU
├── sftool/          # sftool binary
├── env.sh           # source this to put tools on PATH
└── .sdk-info        # versions + install metadata
```

## Updating tool versions

`versions.sh` is the single source of truth. Edit the version variables
and, if a release uses different asset naming, adjust the `*_url` function.
Tag a new release (`vX.Y.Z`) and the GitHub Actions workflow rebuilds and
publishes bundles for every supported platform plus a fresh `installer.sh`.

## Building locally

```sh
./scripts/build-bundle.sh                          # host platform
./scripts/build-bundle.sh --os linux --arch aarch64
./scripts/build-bundle.sh --os darwin --arch aarch64 --out /tmp/dist
```

Output lands in `dist/pebbleos-sdk-<version>-<os>-<arch>.tar.gz` along with a
`.sha256`.

## CI

Two workflows:

- **`.github/workflows/ci.yml`** — runs on every PR and push to `main`:
  - shellcheck + bash/sh syntax across all scripts
  - HEAD-checks every download URL declared in `versions.sh` (catches
    drift when upstream renames or rotates assets)
  - cross-platform bundle build for all four target tuples (artifacts kept
    7 days for inspection)
  - real install smoke test on `ubuntu-latest` (linux/x86_64) and
    `macos-latest` (darwin/aarch64): builds the bundle, runs `install.sh
    --defaults`, sources `env.sh`, and exercises every shipped tool
- **`.github/workflows/release.yml`** — runs on `v*` tags: builds all four
  platform bundles and uploads them plus `pebbleos-sdk-installer.sh` to the
  GitHub Release.

Both workflows cache component downloads under `~/.cache/pebbleos-sdk-build`,
keyed on `versions.sh`, so cache-warm runs skip the ~190 MB toolchain
download.

You can run the same checks locally:

```sh
./scripts/check-urls.sh                                           # URL reachability
./scripts/build-bundle.sh --cache-dir ~/.cache/pebbleos-sdk-build # cached build
shellcheck scripts/*.sh scripts/lib/*.sh versions.sh
```

## Repository layout

```
versions.sh               # tool versions + URL functions (single source of truth)
installer.sh              # public curl|sh entry point (POSIX sh)
scripts/
├── build-bundle.sh       # builds a per-platform bundle (--cache-dir aware)
├── install.sh            # bundled installer (gets copied into each bundle)
├── check-urls.sh         # HEAD-checks every configured download URL
└── lib/
    ├── platform.sh       # uname-based OS/arch detection
    └── common.sh         # logging, download, extract helpers
.github/workflows/
├── ci.yml                # PR + main: lint, URL check, build, smoke install
└── release.yml           # tag push: build all platforms, upload release assets
```

## License

Copyright 2026 Core Devices LLC.

This project's source is licensed under the [Apache License, Version 2.0](LICENSE)
(`SPDX-License-Identifier: Apache-2.0`). The third-party tools the SDK
downloads and bundles (ARM GNU Toolchain, Pebble QEMU, sftool) remain under
their respective upstream licenses; their license texts ship inside each
component's archive.
