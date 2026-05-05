#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
#
# PebbleOS SDK installer.
#
#   curl -LsSf https://github.com/coredevices/PebbleOS-SDK/releases/latest/download/pebbleos-sdk-installer.sh | sh
#
# Detects the host platform, fetches the matching bundle from GitHub Releases,
# and runs the bundle's install.sh. All forwarded options are passed through.
#
# Options (forwarded to the bundle installer):
#   --prefix DIR    Install path (default: $HOME/pebbleos-sdk-<version>)
#   --defaults      Use defaults without prompting
#   --force         Overwrite an existing install
#
# Installer-only options:
#   --version VER   Install a specific SDK version (default: latest)
#   --repo OWNER/R  Override release repo (default: coredevices/PebbleOS-SDK)
#   -h, --help      Show this help

set -eu

REPO="${PEBBLEOS_SDK_REPO:-coredevices/PebbleOS-SDK}"
VERSION=""

# Forwarded arguments. We rebuild "$@" via shell-quoted FORWARD so it
# survives the eval below, including paths with spaces.
FORWARD=""

# ---- arg parsing -----------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: pebbleos-sdk-installer.sh [options]

Detects the host platform, fetches the matching SDK bundle from GitHub
Releases, and runs the bundle's install.sh.

Options forwarded to the bundle installer:
  --prefix DIR    Install path (default: $HOME/pebbleos-sdk-<version>)
  --defaults      Use defaults without prompting
  --force         Overwrite an existing install

Installer-only options:
  --version VER   Install a specific SDK version (default: latest)
  --repo OWNER/R  Override release repo (default: coredevices/PebbleOS-SDK)
  -h, --help      Show this help
EOF
}

# Append a single argument to FORWARD, single-quote-escaped for `eval`.
forward_append() {
    # Replace any single-quote with the standard ' ' "'" ' ' escape.
    escaped="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    if [ -z "${FORWARD}" ]; then
        FORWARD="'${escaped}'"
    else
        FORWARD="${FORWARD} '${escaped}'"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#--version=}"; shift ;;
        --repo)      REPO="$2"; shift 2 ;;
        --repo=*)    REPO="${1#--repo=}"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --prefix)    forward_append "$1"; forward_append "$2"; shift 2 ;;
        --prefix=*|--defaults|--force)
                     forward_append "$1"; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done

# ---- log helpers -----------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BLUE="$(printf '\033[34;1m')"; GREEN="$(printf '\033[32m')"
    RED="$(printf '\033[31;1m')";  RESET="$(printf '\033[0m')"
else
    BLUE=""; GREEN=""; RED=""; RESET=""
fi
info()  { printf '%s==>%s %s\n' "${BLUE}"  "${RESET}" "$*" >&2; }
ok()    { printf '%s✓%s %s\n'   "${GREEN}" "${RESET}" "$*" >&2; }
die()   { printf '%sx%s %s\n'   "${RED}"   "${RESET}" "$*" >&2; exit 1; }

# ---- platform detection ----------------------------------------------------

case "$(uname -s)" in
    Linux)   OS="linux" ;;
    Darwin)  OS="darwin" ;;
    *) die "unsupported OS: $(uname -s)" ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

info "Detected ${OS}/${ARCH}"

# ---- prerequisites ---------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    DL="curl --fail --location --show-error --silent --retry 3 --output"
elif command -v wget >/dev/null 2>&1; then
    DL="wget --quiet --tries=3 --output-document"
else
    die "curl or wget is required"
fi

command -v tar >/dev/null 2>&1 || die "tar is required"

# ---- choose release URL ----------------------------------------------------

if [ -n "${VERSION}" ]; then
    RELEASE_BASE="https://github.com/${REPO}/releases/download/v${VERSION#v}"
else
    RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
fi

# Latest releases don't expose the version in the URL pattern; we need to
# resolve the actual filename. Use the GitHub redirect to find the version.
if [ -z "${VERSION}" ]; then
    info "Resolving latest release version"
    LATEST_URL="https://github.com/${REPO}/releases/latest"
    if command -v curl >/dev/null 2>&1; then
        REDIRECT="$(curl --silent --location --output /dev/null --write-out '%{url_effective}' "${LATEST_URL}")"
    else
        REDIRECT="$(wget --quiet --max-redirect=5 --output-document=/dev/null --server-response "${LATEST_URL}" 2>&1 | awk '/^  Location:/ {url=$2} END {print url}')"
    fi
    VERSION="${REDIRECT##*/tag/}"
    VERSION="${VERSION#v}"
    [ -n "${VERSION}" ] || die "could not determine latest version from ${LATEST_URL}"
    RELEASE_BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
fi

BUNDLE_NAME="pebbleos-sdk-${VERSION}-${OS}-${ARCH}.tar.gz"
BUNDLE_URL="${RELEASE_BASE}/${BUNDLE_NAME}"

info "Downloading ${BUNDLE_URL}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT INT TERM

BUNDLE_PATH="${TMPDIR}/${BUNDLE_NAME}"
${DL} "${BUNDLE_PATH}" "${BUNDLE_URL}" \
    || die "failed to download ${BUNDLE_URL} (does this platform have a release asset?)"

# Optional: verify checksum if available alongside the bundle.
SHA_URL="${BUNDLE_URL}.sha256"
SHA_PATH="${BUNDLE_PATH}.sha256"
if ${DL} "${SHA_PATH}" "${SHA_URL}" 2>/dev/null; then
    info "Verifying checksum"
    expected="$(awk '{print $1}' "${SHA_PATH}")"
    if command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "${BUNDLE_PATH}" | awk '{print $1}')"
    elif command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "${BUNDLE_PATH}" | awk '{print $1}')"
    else
        actual=""
    fi
    if [ -n "${actual}" ] && [ "${actual}" != "${expected}" ]; then
        die "checksum mismatch: expected ${expected}, got ${actual}"
    fi
    [ -n "${actual}" ] && ok "checksum verified"
fi

# ---- extract & run ---------------------------------------------------------

info "Extracting bundle"
tar --extract --gzip --file "${BUNDLE_PATH}" --directory "${TMPDIR}"

EXTRACTED="${TMPDIR}/pebbleos-sdk-${VERSION}-${OS}-${ARCH}"
[ -d "${EXTRACTED}" ] || die "unexpected bundle layout: ${EXTRACTED} not found"

info "Running bundle installer"
# eval is needed to apply quoting we built up while parsing.
eval "exec \"${EXTRACTED}/install.sh\" ${FORWARD}"
