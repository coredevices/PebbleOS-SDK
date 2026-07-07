# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
# shellcheck shell=bash
#
# Shared logging, download, and extraction helpers.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'
    _C_BLUE=$'\033[34m'; _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'
else
    _C_RESET=""; _C_BOLD=""; _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""
fi

log_info()  { printf '%s==>%s %s\n' "${_C_BLUE}${_C_BOLD}" "${_C_RESET}" "$*" >&2; }
log_ok()    { printf '%s✓%s %s\n'   "${_C_GREEN}"          "${_C_RESET}" "$*" >&2; }
log_warn()  { printf '%s!%s %s\n'   "${_C_YELLOW}"         "${_C_RESET}" "$*" >&2; }
log_error() { printf '%sx%s %s\n'   "${_C_RED}${_C_BOLD}"  "${_C_RESET}" "$*" >&2; }
die() { log_error "$*"; exit 1; }

require_cmd() {
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
    done
}

# download_to <url> <dest>
download_to() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --show-error --silent --retry 3 --output "${dest}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --output-document="${dest}" "${url}"
    else
        die "neither curl nor wget is available"
    fi
}

# sha256_stdin — print the sha256 hex digest of stdin.
sha256_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        die "neither shasum nor sha256sum is available"
    fi
}

# write_sha256 <dir> <filename> — write <filename>.sha256 next to the file,
# in the `shasum`/`sha256sum` text format (relative filename).
write_sha256() {
    local dir="$1" filename="$2"
    if command -v shasum >/dev/null 2>&1; then
        (cd "${dir}" && shasum -a 256 "${filename}" > "${filename}.sha256")
    elif command -v sha256sum >/dev/null 2>&1; then
        (cd "${dir}" && sha256sum "${filename}" > "${filename}.sha256")
    else
        die "neither shasum nor sha256sum is available"
    fi
}

# download_cached <url> <dest> [cache_dir]
# download_to with an optional archive cache. The cache key is derived from
# the full URL, not the basename: some upstream assets (notably Pebble QEMU)
# reuse the same filename across versions, so a basename-keyed cache would
# serve stale files after a bump.
download_cached() {
    local url="$1" dest="$2" cache_dir="${3:-}"
    local cache_key
    cache_key="$(printf '%s' "${url}" | sha256_stdin | cut -c1-16)-$(basename "${url}")"
    if [ -n "${cache_dir}" ] && [ -f "${cache_dir}/${cache_key}" ]; then
        log_info "Using cached $(basename "${dest}"): ${cache_dir}/${cache_key}"
        cp "${cache_dir}/${cache_key}" "${dest}"
    else
        log_info "Downloading ${url}"
        download_to "${url}" "${dest}"
        if [ -n "${cache_dir}" ]; then
            cp "${dest}" "${cache_dir}/${cache_key}"
        fi
    fi
}

# extract_archive <archive> <dest_dir> [strip_components]
# Auto-detects format from extension; defaults to 1 stripped component.
extract_archive() {
    local archive="$1" dest="$2" strip="${3:-1}"
    mkdir -p "${dest}"
    case "${archive}" in
        *.tar.xz|*.txz)
            tar --extract --xz --file "${archive}" --directory "${dest}" --strip-components="${strip}"
            ;;
        *.tar.gz|*.tgz)
            tar --extract --gzip --file "${archive}" --directory "${dest}" --strip-components="${strip}"
            ;;
        *.tar.bz2|*.tbz2)
            tar --extract --bzip2 --file "${archive}" --directory "${dest}" --strip-components="${strip}"
            ;;
        *.zip)
            require_cmd unzip
            local tmp; tmp="$(mktemp -d)"
            unzip -q "${archive}" -d "${tmp}"
            if [ "${strip}" -gt 0 ]; then
                local inner; inner="$(find "${tmp}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
                [ -n "${inner}" ] || die "zip archive has no top-level directory to strip"
                mv "${inner}"/* "${dest}/"
            else
                mv "${tmp}"/* "${dest}/"
            fi
            rm -rf "${tmp}"
            ;;
        *)
            die "unknown archive format: ${archive}"
            ;;
    esac
}
