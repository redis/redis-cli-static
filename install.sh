#!/usr/bin/env sh
#
# redis-cli installer.
#
# Copyright (c) 2026-Present, Redis Ltd.
# All rights reserved.
#
# Licensed under your choice of (a) the Redis Source Available License 2.0
# (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
# GNU Affero General Public License v3 (AGPLv3).
#
#   curl -fsSL https://REPLACE_ME/install.sh | sh
#
# Detects OS/arch, downloads the matching statically linked redis-cli, verifies
# its SHA-256 checksum, and installs it. The artifact is a single raw (stripped)
# binary -- no tar/gzip -- so this works on minimal images (Amazon Linux,
# openSUSE, distroless, ...). Only a downloader (curl/wget) is required.
#
# Environment overrides:
#   REDIS_CLI_VERSION      version to install: a concrete version (e.g. 8.4.4),
#                          or an alias "stable"/"latest" (default: "stable")
#   REDIS_CLI_INSTALL_DIR  install destination (default: /usr/local/bin, or
#                          ~/.local/bin if the former is not writable)
#   REDIS_CLI_BASE_URL     download base URL (default: the baked-in value below)
#
# All logic lives inside main(), invoked on the last line, so a truncated
# `curl | sh` download can never execute a half-written command.
#
set -eu

DEFAULT_BASE_URL="https://DOWNLOAD_BASE_URL_PLACEHOLDER"

err()  { echo "redis-cli install: $*" >&2; exit 1; }
info() { echo "redis-cli install: $*"; }

main() {
    BASE_URL="${REDIS_CLI_BASE_URL:-$DEFAULT_BASE_URL}"
    VERSION="${REDIS_CLI_VERSION:-stable}"

    case "$(uname -s)" in
        Linux)  OS=linux ;;
        Darwin) OS=darwin ;;
        *) err "unsupported operating system: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) err "unsupported architecture: $(uname -m)" ;;
    esac
    info "detected $OS/$ARCH, version $VERSION"

    if command -v curl >/dev/null 2>&1; then
        dl() { curl -fsSL "$1" -o "$2"; }
    elif command -v wget >/dev/null 2>&1; then
        dl() { wget -qO "$2" "$1"; }
    else
        err "need curl or wget to download"
    fi
    # SHA-256 of a file. Linux ships `sha256sum`; macOS ships `shasum` instead.
    # Prints nothing if neither exists, so the caller can skip verification.
    sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        elif command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1" | awk '{print $1}'
        fi
    }

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/redis-cli-install.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT

    # --- resolve alias: "stable"/"latest" are text files holding a version
    case "$VERSION" in
        stable|latest)
            if dl "${BASE_URL}/${VERSION}" "$TMP/alias" 2>/dev/null && [ -s "$TMP/alias" ]; then
                resolved="$(tr -d ' \t\r\n' < "$TMP/alias")"
                info "$VERSION resolves to $resolved"
                VERSION="$resolved"
            else
                err "could not resolve '$VERSION' from ${BASE_URL}/${VERSION}"
            fi ;;
    esac

    NAME="redis-cli-${VERSION}-${OS}-${ARCH}"
    URL="${BASE_URL}/${VERSION}/${NAME}"

    info "downloading $URL"
    dl "$URL" "$TMP/redis-cli" || err "download failed: $URL"

    if dl "${URL}.sha256" "$TMP/redis-cli.sha256" 2>/dev/null; then
        info "verifying checksum"
        expected="$(awk '{print $1}' "$TMP/redis-cli.sha256")"
        actual="$(sha256_file "$TMP/redis-cli")"
        if [ -z "$actual" ]; then
            info "no sha256 tool found, skipping verification"
        elif [ "$expected" != "$actual" ]; then
            err "checksum mismatch (expected $expected, got $actual)"
        fi
    else
        info "no checksum file published, skipping verification"
    fi

    chmod +x "$TMP/redis-cli"

    if [ -n "${REDIS_CLI_INSTALL_DIR:-}" ]; then
        DEST="$REDIS_CLI_INSTALL_DIR"
    elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        DEST=/usr/local/bin
    elif [ "$(id -u)" = "0" ]; then
        DEST=/usr/local/bin
    else
        DEST="$HOME/.local/bin"
    fi

    # Create the directory and install with the SAME privilege: creating DEST
    # without sudo and then installing with sudo would fail if DEST needed root
    # to create (install does not create parent directories).
    if mkdir -p "$DEST" 2>/dev/null && [ -w "$DEST" ]; then
        install -m 0755 "$TMP/redis-cli" "$DEST/redis-cli"
    elif command -v sudo >/dev/null 2>&1; then
        info "$DEST needs elevated privileges; using sudo"
        sudo mkdir -p "$DEST" && sudo install -m 0755 "$TMP/redis-cli" "$DEST/redis-cli"
    else
        err "cannot write to $DEST and sudo is unavailable; set REDIS_CLI_INSTALL_DIR to a writable path"
    fi

    info "installed redis-cli to $DEST/redis-cli"
    case ":$PATH:" in
        *":$DEST:"*) ;;
        *) info "NOTE: $DEST is not on your PATH; add it to use 'redis-cli' directly" ;;
    esac
    "$DEST/redis-cli" --version || true
}

main "$@"
