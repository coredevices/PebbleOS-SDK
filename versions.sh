# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
# shellcheck shell=bash
#
# PebbleOS SDK — single source of truth for component versions and URLs.
#
# Bump versions here and the bundle build, release workflow, and installer
# pick them up automatically. Each tool exposes a `<tool>_url <os> <arch>`
# function returning the download URL for the requested host platform.
#
# Supported (os, arch) tuples: linux/x86_64, linux/aarch64,
# darwin/x86_64, darwin/aarch64.

# ---- SDK -------------------------------------------------------------------

SDK_VERSION="${SDK_VERSION:-0.1.0}"

# GitHub repo where bundles + installer are published.
SDK_REPO="${SDK_REPO:-coredevices/PebbleOS-SDK}"

# ---- ARM GNU Toolchain (arm-none-eabi) -------------------------------------
# https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads

ARM_GNU_TOOLCHAIN_VERSION="14.2.rel1"

arm_gnu_toolchain_url() {
    local os="$1" arch="$2"
    local v="${ARM_GNU_TOOLCHAIN_VERSION}"
    local base="https://developer.arm.com/-/media/Files/downloads/gnu/${v}/binrel"
    local host
    case "${os}/${arch}" in
        linux/x86_64)   host="x86_64" ;;
        linux/aarch64)  host="aarch64" ;;
        darwin/x86_64)  host="darwin-x86_64" ;;
        darwin/aarch64) host="darwin-arm64" ;;
        *) return 1 ;;
    esac
    printf '%s/arm-gnu-toolchain-%s-%s-arm-none-eabi.tar.xz\n' "${base}" "${v}" "${host}"
}

# ---- Pebble QEMU -----------------------------------------------------------
# https://github.com/coredevices/qemu/releases
# Asset naming: qemu-pebble-<os>-<arch>.tar.gz where os ∈ {linux, macos}
# and arch ∈ {x86_64, arm64}. Version is in the tag, not the asset name.

QEMU_VERSION="10.1.5-pebble7"
QEMU_TAG="v${QEMU_VERSION}"

qemu_url() {
    local os="$1" arch="$2"
    local base="https://github.com/coredevices/qemu/releases/download/${QEMU_TAG}"
    local os_label arch_label
    case "${os}" in
        linux)   os_label="linux" ;;
        darwin)  os_label="macos" ;;
        *) return 1 ;;
    esac
    case "${arch}" in
        x86_64)  arch_label="x86_64" ;;
        aarch64) arch_label="arm64" ;;
        *) return 1 ;;
    esac
    printf '%s/qemu-pebble-%s-%s.tar.gz\n' "${base}" "${os_label}" "${arch_label}"
}

# ---- sftool ----------------------------------------------------------------
# https://github.com/OpenSiFli/sftool/releases
# Tag is the bare version (no leading "v"). Assets are .tar.xz, named
# sftool-<version>-<rust-triple>.tar.xz. Archive contains a single bare
# `sftool` binary at the root (no top-level directory).

SFTOOL_VERSION="0.2.2"
SFTOOL_TAG="${SFTOOL_VERSION}"

sftool_url() {
    local os="$1" arch="$2"
    local base="https://github.com/OpenSiFli/sftool/releases/download/${SFTOOL_TAG}"
    local triple
    case "${os}/${arch}" in
        linux/x86_64)   triple="x86_64-unknown-linux-gnu" ;;
        linux/aarch64)  triple="aarch64-unknown-linux-gnu" ;;
        darwin/x86_64)  triple="x86_64-apple-darwin" ;;
        darwin/aarch64) triple="aarch64-apple-darwin" ;;
        *) return 1 ;;
    esac
    printf '%s/sftool-%s-%s.tar.xz\n' "${base}" "${SFTOOL_VERSION}" "${triple}"
}

# ---- Component manifest ----------------------------------------------------
#
# Each entry: <name>:<url-fn>:<dest-subdir>:<strip-components>
# - name:             component identifier
# - url-fn:           shell function returning the download URL given (os, arch)
# - dest-subdir:      install path under the SDK prefix
# - strip-components: argument passed to `tar --strip-components` (per-archive
#                     layout: ARM toolchain wraps everything in a versioned
#                     directory, QEMU has `./bin/...`, sftool is a bare binary)

sdk_components() {
    cat <<'EOF'
arm-none-eabi:arm_gnu_toolchain_url:arm-none-eabi:1
qemu:qemu_url:qemu:1
sftool:sftool_url:sftool:0
EOF
}
