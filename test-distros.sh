#!/usr/bin/env bash
#
# Smoke-test the published static redis-cli across many Linux distros via Docker.
#
# Copyright (c) 2026-Present, Redis Ltd.
# All rights reserved.
#
# Licensed under your choice of (a) the Redis Source Available License 2.0
# (RSALv2); or (b) the Server Side Public License v1 (SSPLv1); or (c) the
# GNU Affero General Public License v3 (AGPLv3).
#
# Three checks per run:
#   1. BARE-EXEC  - run the binary on each distro with NOTHING installed.
#                   Passing on musl/minimal/distroless proves it is static.
#   2. STATIC     - `ldd` on glibc and musl must report no dynamic interpreter.
#   3. INSTALL    - run the real `install.sh | sh` flow and confirm it runs.
#
# Usage:
#   test-distros.sh [--arch amd64|arm64] [--base-url URL] [--version V]
#
#   --base-url  download host (default: $REDIS_CLI_BASE_URL)
#   --arch      target arch (default: host; non-host uses QEMU)
#   --version   version to test (default: resolved from <base-url>/latest)
#
# Requires Docker. Exits non-zero if any check fails.
#
set -uo pipefail

ARCH=""; BASE_URL="${REDIS_CLI_BASE_URL:-}"; VERSION="${REDIS_CLI_VERSION:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --base-url) BASE_URL="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '12,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -n "$BASE_URL" ] || { echo "ERROR: --base-url (or \$REDIS_CLI_BASE_URL) is required" >&2; exit 1; }
if [ -z "$ARCH" ]; then case "$(uname -m)" in x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac; fi
PLATFORM="linux/${ARCH}"
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not available" >&2; exit 1; }

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
fails=0
pass() { printf "  ${GREEN}PASS${RST} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${RST} %s ${DIM}(%s)${RST}\n" "$1" "$2"; fails=$((fails+1)); }

[ -n "$VERSION" ] || VERSION="$(curl -fsSL "$BASE_URL/latest" | tr -d '[:space:]')"
echo ">> Testing $PLATFORM, version $VERSION, from $BASE_URL"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
curl -fsSL "$BASE_URL/$VERSION/redis-cli-$VERSION-linux-$ARCH" -o "$WORK/redis-cli" \
    || { echo "ERROR: cannot download binary" >&2; exit 1; }
chmod +x "$WORK/redis-cli"

BARE_IMAGES=(alpine:3.21 ubuntu:24.04 debian:11 rockylinux:9 amazonlinux:2023 fedora:41 busybox:latest gcr.io/distroless/static-debian12)
[ "$ARCH" = amd64 ] && BARE_IMAGES+=(archlinux:latest)

echo; echo "== 1. BARE-EXEC (no packages installed; proves static) =="
for img in "${BARE_IMAGES[@]}"; do
    out="$(docker run --rm --platform "$PLATFORM" -v "$WORK/redis-cli":/redis-cli:ro "$img" /redis-cli --version 2>&1)"
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '^redis-cli'; then pass "$img -> $out"; else fail "$img" "$out"; fi
done

echo; echo "== 2. STATIC LINKAGE (ldd: no dynamic interpreter) =="
g="$(docker run --rm --platform "$PLATFORM" -v "$WORK/redis-cli":/redis-cli:ro ubuntu:24.04 sh -c 'ldd /redis-cli 2>&1' || true)"
printf '%s' "$g" | grep -q 'not a dynamic executable' && pass "glibc: $g" || fail "glibc ldd" "$g"
m="$(docker run --rm --platform "$PLATFORM" -v "$WORK/redis-cli":/redis-cli:ro alpine:3.21 sh -c 'ldd /redis-cli 2>&1' || true)"
printf '%s' "$m" | grep -q 'Not a valid dynamic program' && pass "musl: $m" || fail "musl ldd" "$m"

echo; echo "== 3. INSTALL via install.sh | sh =="
install_test() {
    out="$(docker run --rm --platform "$PLATFORM" "$1" sh -c "
        set -e; $2
        curl -fsSL '$BASE_URL/install.sh' | sh >/dev/null 2>&1
        redis-cli --version" 2>&1)"
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q '^redis-cli'; then pass "$1 -> $out"; else fail "$1" "$out"; fi
}
install_test ubuntu:24.04     "apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null 2>&1"
install_test debian:12        "apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null 2>&1"
install_test alpine:3.21      "apk add --no-cache curl >/dev/null"
install_test rockylinux:9     "dnf install -y -q curl >/dev/null 2>&1 || true"
install_test amazonlinux:2023 "dnf install -y -q curl >/dev/null 2>&1 || true"
install_test fedora:41        "dnf install -y -q curl >/dev/null 2>&1 || true"
install_test opensuse/leap:15 "zypper -n install -y curl >/dev/null 2>&1 || true"

echo
if [ "$fails" -eq 0 ]; then echo "${GREEN}ALL CHECKS PASSED${RST} ($PLATFORM)"; else echo "${RED}${fails} CHECK(S) FAILED${RST} ($PLATFORM)"; fi
exit "$fails"
