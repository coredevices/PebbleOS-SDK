# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Core Devices LLC
# shellcheck shell=bash
#
# Platform detection helpers shared by build, install, and installer scripts.

detect_os() {
    case "$(uname -s)" in
        Linux)   printf 'linux\n' ;;
        Darwin)  printf 'darwin\n' ;;
        *)       printf 'unsupported\n'; return 1 ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)        printf 'x86_64\n' ;;
        aarch64|arm64)       printf 'aarch64\n' ;;
        *)                   printf 'unsupported\n'; return 1 ;;
    esac
}

detect_platform() {
    printf '%s-%s\n' "$(detect_os)" "$(detect_arch)"
}
