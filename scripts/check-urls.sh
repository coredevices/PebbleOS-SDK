#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
#
# HEAD-check every download URL declared in versions.sh across every
# supported (os, arch) tuple. Exits non-zero if any URL is unreachable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=../versions.sh
. "${ROOT_DIR}/versions.sh"

require_cmd curl

PLATFORMS=(
    "linux x86_64"
    "linux aarch64"
    "darwin x86_64"
    "darwin aarch64"
)
URL_FNS=(arm_gnu_toolchain_url qemu_url sftool_url)

failed=0
for fn in "${URL_FNS[@]}"; do
    log_info "${fn}"
    for plat in "${PLATFORMS[@]}"; do
        # shellcheck disable=SC2206
        parts=(${plat}); os="${parts[0]}"; arch="${parts[1]}"
        url="$("${fn}" "${os}" "${arch}")" \
            || { log_error "  ${os}/${arch}: no URL configured"; failed=$((failed+1)); continue; }
        code="$(curl --location --output /dev/null --silent --show-error \
                     --max-time 20 --write-out '%{http_code}' --head "${url}" \
                     || echo ERR)"
        if [ "${code}" = "200" ]; then
            printf '  %s %-15s %s\n' "${_C_GREEN}✓${_C_RESET}" "${os}/${arch}:" "${url}"
        else
            printf '  %s %-15s [%s] %s\n' "${_C_RED}x${_C_RESET}" "${os}/${arch}:" "${code}" "${url}"
            failed=$((failed+1))
        fi
    done
done

if [ "${failed}" -gt 0 ]; then
    die "${failed} URL(s) unreachable"
fi
log_ok "all URLs reachable"
