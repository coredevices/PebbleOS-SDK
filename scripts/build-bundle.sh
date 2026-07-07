#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
#
# Build a self-contained PebbleOS SDK bundle for a target (os, arch).
#
# Output: dist/pebbleos-sdk-<version>-<os>-<arch>.tar.gz containing all
# component archives plus an install.sh and pinned versions.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/platform.sh
. "${SCRIPT_DIR}/lib/platform.sh"
# shellcheck source=../versions.sh
. "${ROOT_DIR}/versions.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--os <linux|darwin>] [--arch <x86_64|aarch64>] [--out <dir>] [--cache-dir <dir>] [--picolibc <file>]

Builds dist/pebbleos-sdk-<version>-<os>-<arch>.tar.gz.

Options:
  --os ARG          Target OS (default: host OS)
  --arch ARG        Target architecture (default: host arch)
  --out DIR         Output directory (default: ${ROOT_DIR}/dist)
  --cache-dir DIR   Cache downloaded component archives in DIR (reuse on
                    rebuild). Cache is keyed by archive basename.
  --picolibc FILE   Use a pre-built picolibc overlay archive (see
                    scripts/build-picolibc.sh) instead of compiling it
                    during the bundle build
  -h, --help        Show this help
EOF
}

OS=""; ARCH=""; OUT_DIR="${ROOT_DIR}/dist"; CACHE_DIR=""; PICOLIBC_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --os)        OS="$2"; shift 2 ;;
        --arch)      ARCH="$2"; shift 2 ;;
        --out)       OUT_DIR="$2"; shift 2 ;;
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --picolibc)  PICOLIBC_FILE="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "${CACHE_DIR}" ] && mkdir -p "${CACHE_DIR}"

OS="${OS:-$(detect_os)}"
ARCH="${ARCH:-$(detect_arch)}"
case "${OS}" in linux|darwin) ;; *) die "unsupported os: ${OS}" ;; esac
case "${ARCH}" in x86_64|aarch64) ;; *) die "unsupported arch: ${ARCH}" ;; esac

require_cmd tar
# The picolibc compile happens after the (large) downloads; fail on its
# missing tools up front rather than at the end.
[ -n "${PICOLIBC_FILE}" ] || require_cmd git meson ninja
mkdir -p "${OUT_DIR}"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

BUNDLE_NAME="pebbleos-sdk-${SDK_VERSION}-${OS}-${ARCH}"
BUNDLE_ROOT="${STAGE_DIR}/${BUNDLE_NAME}"
mkdir -p "${BUNDLE_ROOT}/components"

log_info "Building bundle: ${BUNDLE_NAME}"

# ---- 1. Download components -------------------------------------------------
# Fetch each downloadable component archive (reusing the cache when
# available — see download_cached). Only `name` and `url_fn` are needed
# here — `dest_subdir` and `strip` are used by install.sh, not the
# builder. picolibc is compiled, not downloaded, and is handled in the
# build step below once the toolchain it needs is present.
while IFS=: read -r name url_fn _ _; do
    [ -n "${name}" ] || continue
    [ "${name}" = "picolibc" ] && continue
    url="$("${url_fn}" "${OS}" "${ARCH}")" \
        || die "no URL configured for ${name} on ${OS}/${ARCH}"
    out="${BUNDLE_ROOT}/components/$(basename "${url}")"
    download_cached "${url}" "${out}" "${CACHE_DIR}"
    log_ok "ready $(basename "${out}") ($(wc -c < "${out}" | awk '{print $1}') bytes)"
done < <(sdk_components)

# ---- 2. Build components ------------------------------------------------------
# picolibc is compiled from source against the toolchain downloaded above.
# --picolibc supplies a pre-built archive instead (CI builds it once in a
# dedicated job and shares it across the bundle matrix); otherwise
# build-picolibc.sh compiles it — with --cache-dir a previously built
# overlay is reused, so only the first run after a bump pays the compile.
picolibc_filename="$(picolibc_archive "${OS}" "${ARCH}")"
picolibc_out="${BUNDLE_ROOT}/components/${picolibc_filename}"
if [ -n "${PICOLIBC_FILE}" ]; then
    [ -f "${PICOLIBC_FILE}" ] || die "picolibc archive not found: ${PICOLIBC_FILE}"
    [ "$(basename "${PICOLIBC_FILE}")" = "${picolibc_filename}" ] \
        || die "picolibc archive $(basename "${PICOLIBC_FILE}") does not match expected ${picolibc_filename} (stale build?)"
    cp "${PICOLIBC_FILE}" "${picolibc_out}"
else
    log_info "Building picolibc"
    # Reuse the toolchain downloaded above when it can run here; for a
    # cross-target bundle build-picolibc.sh fetches the matching host
    # toolchain itself (cache-dir aware).
    toolchain_archive=""
    if [ "${OS}" = "$(detect_os)" ] && [ "${ARCH}" = "$(detect_arch)" ]; then
        toolchain_archive="${BUNDLE_ROOT}/components/$(basename "$(arm_gnu_toolchain_url "${OS}" "${ARCH}")")"
    fi
    "${SCRIPT_DIR}/build-picolibc.sh" --out "${STAGE_DIR}/picolibc" \
        ${toolchain_archive:+--toolchain-archive "${toolchain_archive}"} \
        ${CACHE_DIR:+--cache-dir "${CACHE_DIR}"}
    cp "${STAGE_DIR}/picolibc/${picolibc_filename}" "${picolibc_out}"
fi
log_ok "ready $(basename "${picolibc_out}") ($(wc -c < "${picolibc_out}" | awk '{print $1}') bytes)"

# ---- 3. Pack ------------------------------------------------------------------
# Embed manifest, install script, and pinned versions.
cp "${ROOT_DIR}/versions.sh" "${BUNDLE_ROOT}/versions.sh"
cp "${ROOT_DIR}/scripts/install.sh" "${BUNDLE_ROOT}/install.sh"
cp "${ROOT_DIR}/scripts/lib/common.sh" "${BUNDLE_ROOT}/common.sh"
cp "${ROOT_DIR}/scripts/lib/platform.sh" "${BUNDLE_ROOT}/platform.sh"
chmod +x "${BUNDLE_ROOT}/install.sh"

# Persist target metadata for the embedded installer.
cat > "${BUNDLE_ROOT}/manifest.sh" <<EOF
# Auto-generated by build-bundle.sh — do not edit by hand.
BUNDLE_OS="${OS}"
BUNDLE_ARCH="${ARCH}"
BUNDLE_SDK_VERSION="${SDK_VERSION}"
EOF

# Pack.
TARBALL="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"
log_info "Creating ${TARBALL}"
tar --create --gzip --file "${TARBALL}" --directory "${STAGE_DIR}" "${BUNDLE_NAME}"

# Generate sha256.
if command -v shasum >/dev/null 2>&1; then
    (cd "${OUT_DIR}" && shasum -a 256 "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256")
elif command -v sha256sum >/dev/null 2>&1; then
    (cd "${OUT_DIR}" && sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256")
fi

log_ok "Bundle ready: ${TARBALL}"
