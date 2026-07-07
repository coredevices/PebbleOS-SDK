#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
#
# Build the picolibc toolchain overlay bundled with the SDK (invoked by
# build-bundle.sh; see picolibc_archive in versions.sh).
#
# Builds picolibc at PICOLIBC_COMMIT (plus patches/picolibc/*.patch) for
# every toolchain multilib, installs into the toolchain sysroot layout,
# packages the result, and smoke-tests it against a pristine toolchain
# tree. The pinned ARM GNU Toolchain comes from --toolchain-archive (the
# bundle build passes the archive it already downloaded) or is downloaded
# for the host. With --cache-dir, a finished overlay is cached (keyed by
# picolibc version, toolchain version, and pinned commit) and reused on
# later runs, so only the first build after a bump pays the ~15 min cost.
#
# Output: dist/picolibc-<version>-<toolchain-version>.tar.gz — an overlay
# rooted at the toolchain install dir (extract with --strip-components=1),
# providing picolibc.specs next to libgcc (lib/gcc/arm-none-eabi/<ver>/) so
# that `arm-none-eabi-gcc -specs=picolibc.specs` works out of the box —
# which is also how the PebbleOS build discovers the pre-built libc
# (`arm-none-eabi-gcc -print-file-name=picolibc.specs`) — plus the
# headers/libs under the arm-none-eabi/picolibc/ sysroot subtree.
#
# Build options match the PebbleOS firmware ABI: C99 formatted I/O with
# long-long support (the firmware printf contract), no thread-local storage
# (libc state is a single global block; the firmware does not program a TLS
# base per task), and 32-bit time_t baked into the installed headers via
# patches/picolibc/ (matches the firmware RTC/storage ABI and its %ld time
# format strings).

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
Usage: $(basename "$0") [--out <dir>] [--cache-dir <dir>] [--toolchain-archive <file>]

Builds dist/picolibc-${PICOLIBC_VERSION}-${ARM_GNU_TOOLCHAIN_VERSION}.tar.gz.

Builds all toolchain multilibs — expect a long build (~15 min on a fast
machine) unless --cache-dir already holds a matching overlay. Requires
meson, ninja, and git on PATH.

Options:
  --out DIR         Output directory (default: ${ROOT_DIR}/dist)
  --cache-dir DIR   Cache the toolchain download and the built overlay in
                    DIR (same cache as build-bundle.sh --cache-dir)
  --toolchain-archive FILE
                    Use an already-downloaded ARM toolchain archive (must
                    be the pinned version for this host) instead of
                    downloading one
  -h, --help        Show this help
EOF
}

OUT_DIR="${ROOT_DIR}/dist"; CACHE_DIR=""; TOOLCHAIN_ARCHIVE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out)               OUT_DIR="$2"; shift 2 ;;
        --cache-dir)         CACHE_DIR="$2"; shift 2 ;;
        --toolchain-archive) TOOLCHAIN_ARCHIVE="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "${CACHE_DIR}" ] && mkdir -p "${CACHE_DIR}"

require_cmd git tar
mkdir -p "${OUT_DIR}"

OS="$(detect_os)"; ARCH="$(detect_arch)"

# ---- check the overlay cache -------------------------------------------------

ARCHIVE_NAME="$(picolibc_archive "${OS}" "${ARCH}")"
TARBALL="${OUT_DIR}/${ARCHIVE_NAME}"

# Cache key includes the pinned commit and the patch content, so a patch
# edit invalidates cached overlays even without a version bump;
# PICOLIBC_VERSION (in the archive name) covers build-option changes per
# the bump policy in versions.sh.
patches_hash="$(cat "${ROOT_DIR}"/patches/picolibc/*.patch 2>/dev/null | sha256_stdin | cut -c1-16)"
overlay_cache_key="${ARCHIVE_NAME%.tar.gz}-${PICOLIBC_COMMIT}-${patches_hash}.tar.gz"
if [ -n "${CACHE_DIR}" ] && [ -f "${CACHE_DIR}/${overlay_cache_key}" ]; then
    log_info "Using cached overlay: ${CACHE_DIR}/${overlay_cache_key}"
    cp "${CACHE_DIR}/${overlay_cache_key}" "${TARBALL}"
    write_sha256 "${OUT_DIR}" "${ARCHIVE_NAME}"
    log_ok "Overlay ready: ${TARBALL}"
    exit 0
fi

require_cmd meson ninja

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
# Resolve symlinks (macOS mktemp yields /var/..., a symlink to /private/var):
# gcc prints physical paths, so the DESTDIR-staged tree only matches
# ${STAGING}${TOOLCHAIN} if ${TOOLCHAIN} is physical too.
WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"

# ---- fetch + extract the pinned toolchain ----------------------------------
# The overlay is coupled to the exact toolchain release: the multilib set and
# the specs/sysroot layout come from it. Always build against a pristine
# archive of the pinned version, never a toolchain already on PATH.

url="$(arm_gnu_toolchain_url "${OS}" "${ARCH}")" \
    || die "no toolchain URL for ${OS}/${ARCH}"
filename="$(basename "${url}")"
if [ -n "${TOOLCHAIN_ARCHIVE}" ]; then
    [ -f "${TOOLCHAIN_ARCHIVE}" ] \
        || die "toolchain archive not found: ${TOOLCHAIN_ARCHIVE}"
    # The archive must be runnable on this host and match the pinned
    # version — exactly the file arm_gnu_toolchain_url names for the host.
    [ "$(basename "${TOOLCHAIN_ARCHIVE}")" = "${filename}" ] \
        || die "toolchain archive $(basename "${TOOLCHAIN_ARCHIVE}") does not match expected ${filename}"
    archive="${TOOLCHAIN_ARCHIVE}"
else
    archive="${WORK_DIR}/${filename}"
    download_cached "${url}" "${archive}" "${CACHE_DIR}"
fi

TOOLCHAIN="${WORK_DIR}/toolchain"
log_info "Extracting toolchain"
extract_archive "${archive}" "${TOOLCHAIN}" 1
export PATH="${TOOLCHAIN}/bin:${PATH}"
SYSROOT="${TOOLCHAIN}/arm-none-eabi"
[ -x "${TOOLCHAIN}/bin/arm-none-eabi-gcc" ] || die "toolchain extraction failed"

# ---- fetch + patch picolibc at the pinned commit -----------------------------

SRC_DIR="${WORK_DIR}/picolibc"
log_info "Fetching picolibc ${PICOLIBC_COMMIT}"
git init -q "${SRC_DIR}"
git -C "${SRC_DIR}" remote add origin https://github.com/picolibc/picolibc.git
git -C "${SRC_DIR}" fetch -q --depth 1 origin "${PICOLIBC_COMMIT}"
git -C "${SRC_DIR}" checkout -q FETCH_HEAD

for patch in "${ROOT_DIR}"/patches/picolibc/*.patch; do
    [ -e "${patch}" ] || continue # unexpanded glob: no patches
    log_info "Applying $(basename "${patch}")"
    git -C "${SRC_DIR}" apply "${patch}"
done

# ---- build -------------------------------------------------------------------
# Every toolchain multilib is built so gcc picks the right variant from
# whatever arch flags a firmware build uses. picocrt/semihost stay enabled:
# the firmware supplies its own startup and syscalls (it links with
# -nostartfiles), and crt0 + semihosting make the overlay usable standalone.

CROSS_FILE="${WORK_DIR}/cross.txt"
cat > "${CROSS_FILE}" <<'EOF'
[binaries]
c = ['arm-none-eabi-gcc', '-nostdlib']
cpp = ['arm-none-eabi-g++', '-nostdlib']
ar = 'arm-none-eabi-ar'
as = 'arm-none-eabi-as'
nm = 'arm-none-eabi-nm'
strip = 'arm-none-eabi-strip'

[host_machine]
system = 'none'
cpu_family = 'arm'
cpu = 'arm'
endian = 'little'

[properties]
skip_sanity_check = true
EOF

BUILD_DIR="${WORK_DIR}/build"
log_info "Configuring picolibc"
meson setup "${BUILD_DIR}" "${SRC_DIR}" \
    --cross-file "${CROSS_FILE}" \
    --buildtype release \
    --prefix "${SYSROOT}" \
    -Dincludedir=picolibc/arm-none-eabi/include \
    -Dlibdir=picolibc/arm-none-eabi/lib \
    -Dsysroot-install=true \
    -Dtests=false \
    -Dio-long-long=true \
    -Dformat-default=long-long \
    -Dthread-local-storage=false

log_info "Building picolibc (all multilibs — this takes a while)"
ninja -C "${BUILD_DIR}"

STAGING="${WORK_DIR}/staging"
# The install log is quieted but must survive a failure: the EXIT trap
# wipes WORK_DIR, so dump the tail before dying.
DESTDIR="${STAGING}" ninja -C "${BUILD_DIR}" install > "${WORK_DIR}/install.log" 2>&1 \
    || { tail -n 40 "${WORK_DIR}/install.log" >&2; die "picolibc install failed"; }

# ---- package -----------------------------------------------------------------
# DESTDIR mirrors absolute install paths; everything lands under the
# toolchain root (specs + headers/libs in the sysroot). Re-root that subtree
# as picolibc-<version>/ so the archive extracts into the toolchain dir with
# --strip-components=1, matching the component manifest entry.

STAGED_ROOT="${STAGING}${TOOLCHAIN}"
[ -d "${STAGED_ROOT}" ] || die "unexpected staging layout (no ${STAGED_ROOT})"
find "${STAGED_ROOT}/lib/gcc" -name picolibc.specs 2>/dev/null | grep -q . \
    || die "picolibc.specs missing from staged install"

PKG_DIR="${WORK_DIR}/pkg"
PKG_NAME="picolibc-${PICOLIBC_VERSION}"
mkdir -p "${PKG_DIR}"
mv "${STAGED_ROOT}" "${PKG_DIR}/${PKG_NAME}"
# meson stages a few empty dirs (e.g. bin/); keep the overlay to real files.
find "${PKG_DIR}" -type d -empty -delete
# Ship the upstream license text alongside the installed headers/libs.
cp "${SRC_DIR}/COPYING.picolibc" \
    "${PKG_DIR}/${PKG_NAME}/arm-none-eabi/picolibc/COPYING.picolibc"

log_info "Creating ${TARBALL}"
tar --create --gzip --file "${TARBALL}" --directory "${PKG_DIR}" "${PKG_NAME}"
write_sha256 "${OUT_DIR}" "${ARCHIVE_NAME}"

# ---- smoke test ---------------------------------------------------------------
# Overlay the produced archive onto the pristine toolchain tree (exactly
# what install.sh does) and verify the contract PebbleOS relies on: gcc
# finds picolibc.specs, time_t is 32-bit, and a program links for every
# (cpu, float-abi) combination the firmware targets.

log_info "Smoke-testing overlay"
tar --extract --gzip --file "${TARBALL}" --directory "${TOOLCHAIN}" --strip-components=1

specs="$(arm-none-eabi-gcc -print-file-name=picolibc.specs)"
if [ "${specs}" = "picolibc.specs" ] || [ ! -f "${specs}" ]; then
    die "gcc does not find picolibc.specs after overlay"
fi

cat > "${WORK_DIR}/smoke.c" <<'EOF'
#include <stdio.h>
#include <time.h>
_Static_assert(sizeof(time_t) == 4, "time_t must be 32-bit");
int main(void) {
    printf("%lld %ld\n", 1LL << 40, (long)time(NULL));
    return 0;
}
EOF
# --oslib/--crt0=semihost stand in for the stdout/gettimeofday the firmware
# provides itself; without an oslib picolibc leaves those to the program.
# Targets mirror the firmware: nRF52 (cortex-m4, softfp fpv4), SF32LB52
# (star-mc1, softfp fpv5), and the soft-float QEMU variants.
for flags in \
    "-mcpu=cortex-m4" \
    "-mcpu=cortex-m4 -mfloat-abi=softfp -mfpu=fpv4-sp-d16" \
    "-mcpu=star-mc1 -mfloat-abi=softfp -mfpu=fpv5-sp-d16" \
    "-mcpu=cortex-m33+nofp+nodsp"; do
    # shellcheck disable=SC2086 # flags is a list on purpose
    arm-none-eabi-gcc -mthumb ${flags} -specs=picolibc.specs \
        --oslib=semihost --crt0=semihost \
        "${WORK_DIR}/smoke.c" -o "${WORK_DIR}/smoke.elf" \
        || die "smoke link failed for: ${flags}"
    log_ok "links with ${flags}"
done

# Cache only a smoke-tested overlay.
if [ -n "${CACHE_DIR}" ]; then
    cp "${TARBALL}" "${CACHE_DIR}/${overlay_cache_key}"
fi

log_ok "Overlay ready: ${TARBALL}"
