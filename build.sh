#!/usr/bin/env bash
#
# Build a statically linked redis-cli for one OS/arch target.
#
# Copyright (c) 2026-Present, Redis Ltd.
# All rights reserved.
#
# Licensed under your choice of (a) the Redis Source Available License 2.0
# (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
# GNU Affero General Public License v3 (AGPLv3).
#
# Downloads the Redis source for a given version from github.com/redis/redis,
# builds redis-cli with statically linked dependencies (incl. OpenSSL/TLS), and
# writes the raw (stripped) binary + a .sha256 to the output directory.
#
#   - linux  : fully static against musl (built inside Alpine via Docker), so
#              the binary has no libc/openssl runtime dependency at all.
#   - darwin : OpenSSL is linked statically; only macOS system libraries stay
#              dynamic (Apple ships no static libSystem).
#
# Usage:
#   build.sh --version REF [--os linux|darwin] [--arch amd64|arm64]
#            [--output DIR] [--sha256 HASH]
#
#   --version  Redis tag (e.g. 8.8.0) or branch (e.g. unstable)
#   --os/--arch  default to the host
#   --output   default ./dist
#   --sha256   verify against this SHA-256 (the pinned version is checked automatically)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned Redis source checksum, à la docker-library-redis's REDIS_DOWNLOAD_SHA.
# The default build version's tarball is verified against this before building.
# Bump both together when bumping .redis_version. Other versions can be checked
# by passing --sha256 (see below).
PINNED_REF="8.10.1"
PINNED_SHA256="b0f0cf1927b6ff8d5a523eb7f97c5bcaafbfbef96ffa23f643494bd4af527eee"

host_os()   { case "$(uname -s)" in Linux) echo linux;; Darwin) echo darwin;; *) echo "unsupported OS: $(uname -s)" >&2; exit 1;; esac; }
host_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) echo "unsupported arch: $(uname -m)" >&2; exit 1;; esac; }

# sha256_file <file>: print a file's SHA-256 (portable across linux/macOS).
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# fetch_redis <ref> <dest> [sha256]: download + extract the Redis source into
# <dest>. If [sha256] is given, the tarball is verified against it before
# extraction (mismatch aborts); otherwise verification is skipped.
fetch_redis() {
    fr_ref="$1"; fr_dest="$2"; fr_sha="${3:-}"
    fr_url="https://github.com/redis/redis/archive/${fr_ref}.tar.gz"
    fr_tar="$(mktemp "${TMPDIR:-/tmp}/redis-src.XXXXXX.tar.gz")"
    echo ">> Fetching Redis source: $fr_url"
    curl -fsSL "$fr_url" -o "$fr_tar"

    if [ -n "$fr_sha" ]; then
        fr_actual="$(sha256_file "$fr_tar")"
        if [ "$fr_sha" != "$fr_actual" ]; then
            echo "ERROR: source checksum mismatch for $fr_ref" >&2
            echo "  expected $fr_sha" >&2
            echo "  actual   $fr_actual" >&2
            rm -f "$fr_tar"; exit 1
        fi
        echo ">> Verified source checksum ($fr_actual)"
    else
        echo ">> No --sha256 given; skipping source verification"
    fi

    mkdir -p "$fr_dest"
    tar -xzf "$fr_tar" -C "$fr_dest" --strip-components=1
    rm -f "$fr_tar"
}

# compile <os> <arch> <src-root>: build redis-cli with static deps in place,
# producing <src-root>/src/redis-cli. Passes static flags to the upstream
# Redis Makefile (we don't own it, so there's no custom target).
compile() {
    co_os="$1"; co_src="$2"
    jobs="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) )"
    cd "$co_src"

    case "$co_os" in
    linux)
        # Fully static against musl. `-static` + `pkg-config --static` pull in
        # OpenSSL's .a archives; run inside Alpine (build_linux) so libc is musl.
        make -C src redis-cli \
            BUILD_TLS=yes \
            PKG_CONFIG="pkg-config --static" \
            REDIS_LDFLAGS="-static" \
            OPTIMIZATION="-O2" \
            -j"$jobs"
        strip src/redis-cli
        ;;
    darwin)
        prefix="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
        if [ ! -f "$prefix/lib/libssl.a" ]; then
            echo "ERROR: static OpenSSL not found at $prefix/lib/libssl.a (brew install openssl@3)" >&2
            exit 1
        fi
        # Link OpenSSL's .a archives directly so TLS is static.
        make -C src redis-cli \
            BUILD_TLS=yes \
            OPENSSL_PREFIX="$prefix" \
            LIBSSL_LIBS="$prefix/lib/libssl.a" \
            LIBCRYPTO_LIBS="$prefix/lib/libcrypto.a" \
            -j"$jobs"
        strip -x src/redis-cli
        codesign --force --sign - src/redis-cli 2>/dev/null || true  # strip voids the ad-hoc signature
        ;;
    *) echo "unsupported OS: $co_os" >&2; exit 1 ;;
    esac
}

# build_linux <arch> <src-root>: compile inside Alpine for a static musl binary.
build_linux() {
    bl_arch="$1"; bl_src="$2"
    case "$bl_arch" in amd64) platform="linux/amd64";; arm64) platform="linux/arm64";; esac
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker is required for Linux builds but is not available." >&2
        exit 1
    fi
    echo ">> Compiling in alpine ($platform)"
    # The container runs as root and writes root-owned files into the mounted
    # tree; chown them back to the host user at the end so a non-root caller
    # (e.g. a CI runner) can read the artifact and clean up the temp dir.
    docker run --rm --platform "$platform" \
        -v "$bl_src":/src -v "$SCRIPT_DIR":/build-scripts:ro -w /src \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        alpine:3.21 sh -ec '
            apk add --no-cache build-base linux-headers openssl-dev openssl-libs-static pkgconfig perl >/dev/null
            sh /build-scripts/build.sh --compile-only linux /src
            chown -R "$HOST_UID:$HOST_GID" /src'
}

# --- internal: --compile-only <os> <src-root> (used inside container) --------
if [ "${1:-}" = "--compile-only" ]; then
    compile "$2" "$3"
    exit 0
fi

# --- main -------------------------------------------------------------------
OS="$(host_os)"; ARCH="$(host_arch)"; VERSION=""; OUTPUT="$SCRIPT_DIR/dist"; SHA256=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --os) OS="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --sha256) SHA256="$2"; shift 2 ;;
        -h|--help) sed -n '12,29p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$VERSION" ] || { echo "--version is required (Redis tag or branch)" >&2; exit 1; }
case "$OS" in linux|darwin) ;; *) echo "invalid --os: $OS" >&2; exit 1 ;; esac
case "$ARCH" in amd64|arm64) ;; *) echo "invalid --arch: $ARCH" >&2; exit 1 ;; esac

echo ">> Building redis-cli  redis=$VERSION  os=$OS  arch=$ARCH"

# Resolve OUTPUT to an absolute path: compile() cd's into the temp source tree,
# so a relative --output would otherwise resolve against it and be lost.
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/redis-cli-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR" 2>/dev/null || true' EXIT
SRC="$BUILD_DIR/redis"
# Default to the hard-coded checksum when building the pinned version; an
# explicit --sha256 always takes precedence (and enables verifying any version).
if [ -z "$SHA256" ] && [ "$VERSION" = "$PINNED_REF" ]; then
    SHA256="$PINNED_SHA256"
fi
# Fail closed for release builds: when REDIS_CLI_REQUIRE_VERIFIED_SOURCE=1 (set
# by the release workflows), refuse to build a concrete version tag whose source
# checksum isn't known, instead of silently skipping verification. Branch builds
# (e.g. "unstable", which have no stable tarball hash) start with a non-digit and
# are exempt.
if [ -z "$SHA256" ] && [ "${REDIS_CLI_REQUIRE_VERIFIED_SOURCE:-0}" = "1" ] \
   && printf '%s' "$VERSION" | grep -Eq '^[0-9]'; then
    echo "ERROR: refusing to build release '$VERSION' without a verified source checksum." >&2
    echo "       PINNED_REF=$PINNED_REF. Re-pin (.redis_version + PINNED_SHA256) or pass --sha256." >&2
    exit 1
fi
fetch_redis "$VERSION" "$SRC" "$SHA256"

case "$OS" in
    darwin)
        [ "$(host_os)" = "darwin" ] || { echo "ERROR: macOS targets must be built on a macOS host." >&2; exit 1; }
        compile "$OS" "$SRC"
        ;;
    linux) build_linux "$ARCH" "$SRC" ;;
esac

BIN="$SRC/src/redis-cli"
[ -x "$BIN" ] || { echo "ERROR: build did not produce $BIN" >&2; exit 1; }

# --- package: raw binary + .sha256 (no tarball, so the installer needs no tar)
mkdir -p "$OUTPUT"
NAME="redis-cli-${VERSION}-${OS}-${ARCH}"
cp "$BIN" "$OUTPUT/$NAME"
chmod +x "$OUTPUT/$NAME"
( cd "$OUTPUT"
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$NAME" > "$NAME.sha256"
  else sha256sum "$NAME" > "$NAME.sha256"; fi )

echo ">> Done: $OUTPUT/$NAME ($(du -h "$OUTPUT/$NAME" | cut -f1))"
if [ "$OS" = "darwin" ]; then otool -L "$OUTPUT/$NAME" || true; else file "$OUTPUT/$NAME" || true; fi
