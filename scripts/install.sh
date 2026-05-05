#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
#
# PebbleOS SDK bundle installer.
#
# Run from inside an extracted bundle directory. Extracts each bundled
# component archive into <prefix>/<component>/ and writes an env.sh helper.

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${BUNDLE_DIR}/common.sh"
# shellcheck source=lib/platform.sh
. "${BUNDLE_DIR}/platform.sh"
# shellcheck source=../versions.sh
. "${BUNDLE_DIR}/versions.sh"
# shellcheck source=/dev/null
. "${BUNDLE_DIR}/manifest.sh"

DEFAULT_PREFIX="${HOME}/pebbleos-sdk-${BUNDLE_SDK_VERSION}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--prefix DIR] [--defaults] [--force]

Installs the PebbleOS SDK ${BUNDLE_SDK_VERSION} for ${BUNDLE_OS}/${BUNDLE_ARCH}.

Options:
  --prefix DIR   Install path (default: ${DEFAULT_PREFIX})
  --defaults     Use defaults without prompting
  --force        Overwrite an existing install at the target prefix
  -h, --help     Show this help
EOF
}

PREFIX=""; USE_DEFAULTS=0; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)    PREFIX="$2"; shift 2 ;;
        --prefix=*)  PREFIX="${1#--prefix=}"; shift ;;
        --defaults)  USE_DEFAULTS=1; shift ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Sanity check: this bundle must match the host platform.
HOST_OS="$(detect_os)"; HOST_ARCH="$(detect_arch)"
if [ "${HOST_OS}" != "${BUNDLE_OS}" ] || [ "${HOST_ARCH}" != "${BUNDLE_ARCH}" ]; then
    die "bundle is for ${BUNDLE_OS}/${BUNDLE_ARCH}, host is ${HOST_OS}/${HOST_ARCH}"
fi

# Resolve install prefix.
if [ -z "${PREFIX}" ]; then
    if [ "${USE_DEFAULTS}" -eq 1 ] || [ ! -t 0 ]; then
        PREFIX="${DEFAULT_PREFIX}"
    else
        printf 'Install path [%s]: ' "${DEFAULT_PREFIX}" >&2
        read -r answer
        PREFIX="${answer:-${DEFAULT_PREFIX}}"
    fi
fi
# Expand a leading ~/ since interactive input is read literally.
# The literal `~/` is intentional here — we are matching what the user
# typed before doing manual expansion.
# shellcheck disable=SC2088
case "${PREFIX}" in
    "~")    PREFIX="${HOME}" ;;
    "~/"*)  PREFIX="${HOME}/${PREFIX#~/}" ;;
esac

log_info "Installing PebbleOS SDK ${BUNDLE_SDK_VERSION} to ${PREFIX}"

if [ -e "${PREFIX}" ]; then
    if [ "${FORCE}" -eq 1 ]; then
        log_warn "removing existing ${PREFIX}"
        rm -rf "${PREFIX}"
    elif [ -d "${PREFIX}" ] && [ -z "$(ls -A "${PREFIX}" 2>/dev/null || true)" ]; then
        : # empty dir is fine
    else
        die "${PREFIX} already exists (use --force to overwrite)"
    fi
fi
mkdir -p "${PREFIX}"

# Extract each component.
while IFS=: read -r name url_fn dest_subdir strip; do
    [ -n "${name}" ] || continue
    url="$("${url_fn}" "${BUNDLE_OS}" "${BUNDLE_ARCH}")" \
        || die "no URL configured for ${name} on ${BUNDLE_OS}/${BUNDLE_ARCH}"
    archive="${BUNDLE_DIR}/components/$(basename "${url}")"
    [ -f "${archive}" ] || die "missing bundled archive: ${archive}"
    dest="${PREFIX}/${dest_subdir}"
    log_info "Installing ${name} -> ${dest}"
    rm -rf "${dest}"
    extract_archive "${archive}" "${dest}" "${strip}"
    # Some upstream archives ship without the executable bit set on
    # release binaries (notably the QEMU asset). Ensure anything under a
    # `bin/` directory and the dest_subdir-named binary itself is +x.
    if [ -d "${dest}/bin" ]; then
        find "${dest}/bin" -maxdepth 1 -type f -exec chmod +x {} +
    fi
    if [ -f "${dest}/${dest_subdir}" ]; then
        chmod +x "${dest}/${dest_subdir}"
    fi
    log_ok "installed ${name}"
done < <(sdk_components)

# Write env helper.
ENV_FILE="${PREFIX}/env.sh"
cat > "${ENV_FILE}" <<'EOF'
# PebbleOS SDK environment.
# Source this file from your shell to put SDK tools on PATH:
#   . ~/pebbleos-sdk-<version>/env.sh
_pebbleos_sdk_root="$(cd "$(dirname -- "${BASH_SOURCE:-$0}")" && pwd)"
export PEBBLEOS_SDK_ROOT="${_pebbleos_sdk_root}"
export PATH="${_pebbleos_sdk_root}/arm-none-eabi/bin:${_pebbleos_sdk_root}/qemu/bin:${_pebbleos_sdk_root}/sftool:${PATH}"
unset _pebbleos_sdk_root
EOF

# Stamp the install with version metadata.
cat > "${PREFIX}/.sdk-info" <<EOF
sdk_version=${BUNDLE_SDK_VERSION}
os=${BUNDLE_OS}
arch=${BUNDLE_ARCH}
arm_gnu_toolchain_version=${ARM_GNU_TOOLCHAIN_VERSION}
qemu_version=${QEMU_VERSION}
sftool_version=${SFTOOL_VERSION}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log_ok "PebbleOS SDK ${BUNDLE_SDK_VERSION} installed at ${PREFIX}"
log_info "To activate: . ${PREFIX}/env.sh"
